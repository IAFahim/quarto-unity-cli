# Unity Runner v2

Live-execute code blocks in Quarto documents against a running Unity Editor.

## Architecture

Three components, one protocol:

```
  Quarto doc (.qmd)          bridge.py            Unity Editor
  ┌──────────────┐      ┌──────────────┐      ┌──────────────┐
  │ .unity blocks │─ws──▶│  WebSocket   │─cli──▶│  unity-cli   │
  │  (browser)    │◀─ws──│  bridge:7890 │◀─────│  responses   │
  └──────────────┘      └──────────────┘      └──────────────┘
```

The Lua filter transforms `.unity` code blocks into interactive widgets.
The JS runtime connects to `bridge.py` over WebSocket protocol v2.
The bridge spawns `unity-cli` subprocesses and streams output back.


## Quick Start

```sh
pip install websockets
python bridge.py          # terminal 1
quarto preview example.qmd  # terminal 2
```

## Block Syntax

Every executable block carries the `.unity` class. Two orthogonal axes compose freely:

### Kind (how to run)

| Classes      | Kind   | Mechanism                        |
|-------------|--------|----------------------------------|
| `.unity`    | `cli`  | Shell command (piped to bridge)  |
| `.cs .unity`| `exec` | C# via `unity-cli exec`         |

### Intent (why to run)

| Class        | Intent     | Behavior                                     |
|-------------|------------|----------------------------------------------|
| *(none)*    | `run`      | Standard execution                           |
| `.query`    | `query`    | Read-only inspection (cyan indicator)        |
| `.assert`   | `assert`   | Verify output matches `expected` attribute   |
| `.setup`    | `setup`    | Run once, cached on subsequent executions    |
| `.teardown` | `teardown` | Cleanup action                               |

### Attributes

| Attribute  | Purpose                                         |
|------------|------------------------------------------------|
| `title`    | Toolbar label                                   |
| `name`     | Block identifier (for `depends` references)     |
| `depends`  | Comma-separated block names to run first        |
| `usings`   | C# using directives (exec kind only)            |
| `expected` | Expected output string (assert intent only)     |
| `timeout`  | Per-block timeout in seconds (default: 300)     |
| `format`   | Output format: `auto`, `json`, `raw`            |
| `cache`    | Explicit cache control for setup blocks         |
| `group`    | Named group for batch operations                |

### Examples

Standard CLI block:

````qmd
```{.unity title="Editor Status"}
unity-cli status
```
````

C# exec with usings:

````qmd
```{.cs .unity title="Frame Count" usings="UnityEngine"}
return Time.frameCount.ToString();
```
````

Setup block (runs once, then cached):

````qmd
```{.unity .setup title="Enter Play Mode" name="play"}
unity-cli editor play --wait
```
````

Assert block:

````qmd
```{.cs .unity .assert title="Check Version" depends="play" expected="6000"}
return Application.unityVersion.Split('.')[0];
```
````

Query with JSON auto-format:

````qmd
```{.cs .unity .query title="All Systems" depends="play" format="json"}
return JsonConvert.SerializeObject(systemNames);
```
````


## Dependencies

Blocks declare dependencies by name:

```
  [setup: play] ──▶ [query: frame-count]
                ──▶ [assert: check-version]
                ──▶ [exec: scene-objects]
```

Running any downstream block auto-resolves the DAG and executes
predecessors first. Setup blocks replay from cache after their
first successful run.


## Keyboard Shortcuts

| Shortcut              | Action                                    |
|----------------------|-------------------------------------------|
| `Ctrl+Enter`         | Run focused block (resolves dependencies) |
| `Ctrl+Shift+Enter`   | Run all blocks sequentially               |


## Protocol v2

Client→Bridge messages:

| type        | fields                                      |
|------------|---------------------------------------------|
| `handshake` | `version`                                   |
| `run`       | `id`, `code`, `kind`, `usings`, `timeout`   |
| `cancel`    | `id`                                        |
| `ping`      | `seq`                                       |

Bridge→Client messages:

| type        | fields                                      |
|------------|---------------------------------------------|
| `handshake` | `version`, `bridge`                         |
| `stdout`    | `id`, `data`                                |
| `stderr`    | `id`, `data`                                |
| `exit`      | `id`, `code`, `elapsed_ms`                  |
| `error`     | `id`, `message`                             |
| `pong`      | `seq`                                       |

The bridge writes structured JSON journal lines to stderr for
debugging and audit.
