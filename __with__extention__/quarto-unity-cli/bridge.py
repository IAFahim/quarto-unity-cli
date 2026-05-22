import asyncio
import json
import sys

try:
    import websockets
    from websockets.exceptions import ConnectionClosedError, ConnectionClosedOK
except ImportError:
    print("Missing dependency: pip install websockets")
    sys.exit(1)

LISTEN_HOST = ""
LISTEN_PORT = 7890
PROCESS_TIMEOUT_S = 300


async def stream_lines(pipe, websocket, block_id, stream_name):
    while True:
        line = await pipe.readline()
        if not line:
            break
        await websocket.send(json.dumps({
            "type": stream_name,
            "id": block_id,
            "data": line.decode(errors="replace"),
        }))


async def execute_block(websocket, processes, block_id, code, exec_type):
    if block_id in processes:
        await kill_process(processes, block_id)

    try:
        if exec_type == "exec":
            proc = await asyncio.create_subprocess_exec(
                "unity-cli", "exec", code,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        else:
            proc = await asyncio.create_subprocess_shell(
                code,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )

        processes[block_id] = proc

        stdout_task = asyncio.create_task(
            stream_lines(proc.stdout, websocket, block_id, "stdout")
        )
        stderr_task = asyncio.create_task(
            stream_lines(proc.stderr, websocket, block_id, "stderr")
        )

        try:
            await asyncio.wait_for(
                asyncio.gather(stdout_task, stderr_task),
                timeout=PROCESS_TIMEOUT_S,
            )
        except asyncio.TimeoutError:
            proc.kill()
            await websocket.send(json.dumps({
                "type": "stderr",
                "id": block_id,
                "data": f"Timed out after {PROCESS_TIMEOUT_S}s\n",
            }))

        exit_code = await proc.wait()
        processes.pop(block_id, None)

        await websocket.send(json.dumps({
            "type": "exit",
            "id": block_id,
            "code": exit_code,
        }))

    except (ConnectionClosedError, ConnectionClosedOK):
        processes.pop(block_id, None)

    except FileNotFoundError as exc:
        processes.pop(block_id, None)
        await websocket.send(json.dumps({
            "type": "error",
            "id": block_id,
            "message": str(exc),
        }))

    except Exception as exc:
        processes.pop(block_id, None)
        await websocket.send(json.dumps({
            "type": "error",
            "id": block_id,
            "message": f"Bridge error: {exc}",
        }))


async def kill_process(processes, block_id):
    proc = processes.pop(block_id, None)
    if proc is None or proc.returncode is not None:
        return
    proc.terminate()
    try:
        await asyncio.wait_for(proc.wait(), timeout=3)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()


async def handler(websocket):
    processes = {}
    tasks = {}

    try:
        async for raw in websocket:
            msg = json.loads(raw)
            msg_type = msg.get("type")

            if msg_type == "run":
                block_id = msg["id"]
                code = msg.get("code", "")
                exec_type = msg.get("exec_type", "cli")

                if block_id in tasks:
                    old_task = tasks.pop(block_id)
                    if not old_task.done():
                        await kill_process(processes, block_id)
                        old_task.cancel()

                task = asyncio.create_task(
                    execute_block(websocket, processes, block_id, code, exec_type)
                )
                tasks[block_id] = task

            elif msg_type == "cancel":
                block_id = msg["id"]
                await kill_process(processes, block_id)

                if block_id in tasks:
                    tasks.pop(block_id).cancel()

                await websocket.send(json.dumps({
                    "type": "exit",
                    "id": block_id,
                    "code": -1,
                }))

    except (ConnectionClosedError, ConnectionClosedOK):
        pass

    finally:
        for block_id in list(processes.keys()):
            await kill_process(processes, block_id)
        for task in tasks.values():
            task.cancel()


async def main():
    async with websockets.serve(handler, LISTEN_HOST, LISTEN_PORT):
        print(f"Unity bridge → ws://127.0.0.1:{LISTEN_PORT}")
        await asyncio.get_running_loop().create_future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nStopped")
