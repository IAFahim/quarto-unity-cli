import asyncio
import json
import sys
import time

try:
    import websockets
    from websockets.exceptions import ConnectionClosedError, ConnectionClosedOK
except ImportError:
    print("pip install websockets", file=sys.stderr)
    sys.exit(1)

PROTOCOL_VERSION = 2
LISTEN_HOST = ""
LISTEN_PORT = 7890
DEFAULT_TIMEOUT_S = 300
BRIDGE_IDENTITY = "unity-runner/2.0"


def journal(event, **fields):
    record = {"t": time.time(), "event": event, **fields}
    print(json.dumps(record, separators=(",", ":")), file=sys.stderr, flush=True)


async def stream_pipe(pipe, websocket, block_id, stream_name):
    while True:
        line = await pipe.readline()
        if not line:
            break
        await websocket.send(json.dumps({
            "type": stream_name,
            "id": block_id,
            "data": line.decode(errors="replace"),
        }))


def build_exec_argv(code, usings):
    argv = ["unity-cli", "exec"]
    if usings:
        argv.extend(["--usings", usings])
    argv.append(code)
    return argv


async def execute_block(websocket, live, block_id, code, kind, usings, timeout_s):
    if block_id in live:
        await terminate(live, block_id)

    start = time.monotonic()
    journal("run_start", id=block_id, kind=kind)

    try:
        if kind == "exec":
            proc = await asyncio.create_subprocess_exec(
                *build_exec_argv(code, usings),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        else:
            proc = await asyncio.create_subprocess_shell(
                code,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )

        live[block_id] = proc

        pipe_tasks = asyncio.gather(
            stream_pipe(proc.stdout, websocket, block_id, "stdout"),
            stream_pipe(proc.stderr, websocket, block_id, "stderr"),
        )

        try:
            await asyncio.wait_for(pipe_tasks, timeout=timeout_s)
        except asyncio.TimeoutError:
            proc.kill()
            await websocket.send(json.dumps({
                "type": "stderr",
                "id": block_id,
                "data": f"timeout after {timeout_s}s\n",
            }))

        exit_code = await proc.wait()
        live.pop(block_id, None)
        elapsed_ms = int((time.monotonic() - start) * 1000)
        journal("run_exit", id=block_id, code=exit_code, ms=elapsed_ms)

        await websocket.send(json.dumps({
            "type": "exit",
            "id": block_id,
            "code": exit_code,
            "elapsed_ms": elapsed_ms,
        }))

    except (ConnectionClosedError, ConnectionClosedOK):
        live.pop(block_id, None)

    except FileNotFoundError as exc:
        live.pop(block_id, None)
        journal("run_error", id=block_id, error=str(exc))
        await websocket.send(json.dumps({
            "type": "error", "id": block_id, "message": str(exc),
        }))

    except Exception as exc:
        live.pop(block_id, None)
        journal("run_error", id=block_id, error=str(exc))
        await websocket.send(json.dumps({
            "type": "error", "id": block_id, "message": f"bridge: {exc}",
        }))


async def terminate(live, block_id):
    proc = live.pop(block_id, None)
    if proc is None or proc.returncode is not None:
        return
    proc.terminate()
    try:
        await asyncio.wait_for(proc.wait(), timeout=3)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()


async def handshake(websocket):
    raw = await asyncio.wait_for(websocket.recv(), timeout=5)
    msg = json.loads(raw)
    if msg.get("type") != "handshake":
        await websocket.close(4001, "expected handshake")
        return None
    client_version = msg.get("version", 1)
    negotiated = min(client_version, PROTOCOL_VERSION)
    await websocket.send(json.dumps({
        "type": "handshake",
        "version": negotiated,
        "bridge": BRIDGE_IDENTITY,
    }))
    journal("handshake", client=client_version, negotiated=negotiated)
    return negotiated


async def session(websocket):
    version = await handshake(websocket)
    if version is None:
        return

    live = {}
    tasks = {}

    try:
        async for raw in websocket:
            msg = json.loads(raw)
            msg_type = msg.get("type")

            if msg_type == "run":
                block_id = msg["id"]
                if block_id in tasks:
                    old = tasks.pop(block_id)
                    if not old.done():
                        await terminate(live, block_id)
                        old.cancel()
                tasks[block_id] = asyncio.create_task(
                    execute_block(
                        websocket, live, block_id,
                        msg.get("code", ""),
                        msg.get("kind", "cli"),
                        msg.get("usings", ""),
                        msg.get("timeout", DEFAULT_TIMEOUT_S),
                    )
                )

            elif msg_type == "cancel":
                block_id = msg["id"]
                await terminate(live, block_id)
                if block_id in tasks:
                    tasks.pop(block_id).cancel()
                await websocket.send(json.dumps({
                    "type": "exit", "id": block_id, "code": -1, "elapsed_ms": 0,
                }))

            elif msg_type == "ping":
                await websocket.send(json.dumps({
                    "type": "pong", "seq": msg.get("seq", 0),
                }))

    except (ConnectionClosedError, ConnectionClosedOK):
        pass
    finally:
        for bid in list(live):
            await terminate(live, bid)
        for t in tasks.values():
            t.cancel()
        journal("session_end")


async def main():
    journal("bridge_start", port=LISTEN_PORT, protocol=PROTOCOL_VERSION)
    async with websockets.serve(session, LISTEN_HOST, LISTEN_PORT):
        print(f"unity-runner bridge v{PROTOCOL_VERSION} → ws://127.0.0.1:{LISTEN_PORT}")
        await asyncio.get_running_loop().create_future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        journal("bridge_stop", reason="keyboard")
