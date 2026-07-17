# Port 8000 is in use by another process

Godot AI's Python server listens on HTTP port `8000` (and WebSocket port
`9500`). Port `8000` is a popular default for other dev tools — Django,
`python -m http.server`, and many local servers grab it — so a genuinely
foreign occupant is not rare.

When a **non-godot-ai** process is already bound to `8000`, the dock can't
reclaim the port (it has no proof it owns whatever is there), so it stops and
shows a message like:

> Port 8000 is occupied by an incompatible server. Port 8001 is free — set
> `godot_ai/http_port` in Editor Settings, then update your client config.

The crash panel names a concrete free port for you. This guide covers the
second half: changing the port and pointing your MCP clients at the new one.

> If the dock instead offers a **Restart Server** button, the occupant is an
> older godot-ai server it *can* reclaim — click that rather than changing the
> port. This guide is only for the foreign-process case.

## 1. Pick free ports

The plugin uses **two** ports: HTTP (`8000`, the one your MCP clients talk to)
and WebSocket (`9500`, used internally between the server and the editor). The
crash body suggests a free value for each (e.g. HTTP `8001`, WS `9501`). On
Windows those suggestions are checked against the Hyper-V / WSL2 / Docker
reservation table, so they won't themselves fail with `WinError 10013`. You can
use the suggested ports or choose your own free ones.

If only port `8000` is taken, you technically only need to move the HTTP port —
but the incompatible-server case that lands you here can hold both, so changing
both settings is the reliable fix.

## 2. Change `godot_ai/http_port` and `godot_ai/ws_port` in Editor Settings

1. In the Godot editor, open **Editor → Editor Settings**.
2. Search for `godot_ai/http_port` and set it to the free HTTP port from step 1
   (e.g. `8001`).
3. Search for `godot_ai/ws_port` and set it to the free WS port from step 1
   (e.g. `9501`).
4. Reload the plugin (toggle it off/on in **Project → Project Settings →
   Plugins**, or restart the editor).

> **Note:** both are **Editor Settings**, not project settings — they are
> stored per editor install, so the change applies to *every* project you open
> with this editor. If you only hit the conflict on one machine, remember to
> revert them later if the foreign process goes away.

## 3. Reconfigure your MCP clients

Editor Settings only moves the *server*. Every MCP client still points at the
old URL (`http://127.0.0.1:8000/mcp`), so they'll silently fail to connect
until you update them too.

The fastest way is the dock itself: each client row's **Configure** button
rewrites that client's config with the current server URL, so once the server
is on the new port, click **Configure** (or **Configure all**) again to rewrite
every already-configured client.

If you configured a client by hand, update its URL to use the new port. For
example, for Claude Code:

```bash
claude mcp remove godot-ai
claude mcp add --scope user --transport http godot-ai http://127.0.0.1:8001/mcp
```

For config-file clients (Codex, Grok Build, Antigravity, Cursor, …), edit the
`url` / `serverUrl` field to match the new port. See the **Manual Client
Configuration** section in the [README](../README.md) for each client's file
and format. Grok Build uses `~/.grok/config.toml`
(`[mcp_servers.godot-ai]`).

## Independent editors in separate worktrees

EditorSettings ports are deliberately machine-wide, so they are the wrong seam
when two agents need independent checkouts, Python sources, and server
lifecycles. Launch each Godot process with a distinct HTTP/WS pair instead:

```bash
# Worktree / agent A
GODOT_AI_HTTP_PORT=18101 \
GODOT_AI_WS_PORT=19601 \
GODOT_AI_CLIENT_ID=codex \
CODEX_HOME="$HOME/.codex-lanes/godot-ai-a" \
script/open-godot-here

# Worktree / agent B (run from B's checkout)
GODOT_AI_HTTP_PORT=18102 \
GODOT_AI_WS_PORT=19602 \
GODOT_AI_CLIENT_ID=codex \
CODEX_HOME="$HOME/.codex-lanes/godot-ai-b" \
script/open-godot-here
```

Environment ports take precedence only for that editor process. The plugin
also keeps each lane's PID and managed server record (including its WS auth
token) under `user://godot_ai_servers/<http-port>/`, so stopping or restarting
lane A does not clear lane B's ownership state.

Use both port variables and choose a stable, unique pair for each live lane.
Before launching, check that both ports are free. The HTTP port is also the
lane's lifecycle key, so do not reuse one HTTP port concurrently. Supplying
only one variable, an invalid value, or the same value for both ports fails
closed: the plugin does not fall back to the shared 8000/9500 server. Fix the
pair and relaunch the editor.

`GODOT_AI_CLIENT_ID` (or comma-separated `GODOT_AI_CLIENT_IDS`) only scopes the
dock rows and status checks. It does **not** isolate a client's own config. Two
Codex processes need separate `CODEX_HOME` values (and both the editor and the
corresponding Codex process must inherit the same value), or manually distinct
MCP entries that point at the two URLs. Other clients need the equivalent
per-process config home or workspace-local configuration.

For divergent Python branches, either let each editor auto-spawn from its own
checkout, or run the matching external dev server explicitly:

```bash
script/serve-this-worktree --port 18101 --ws-port 19601
```

The existing shared-server mode is still useful when every editor intentionally
uses the same Python source. It is not strict agent isolation: the default
active editor is server-global, resources follow that global selection, and
closing an editor can affect a server it adopted. In shared mode, pass an exact
`session_id` on every tool call and avoid racing `session_activate`.

## Reverting

For a normal EditorSettings override, set `godot_ai/http_port` back to `8000`
and `godot_ai/ws_port` back to `9500` (or clear the overrides), reload the
plugin, and re-run **Configure all**.

For an isolated worktree lane, first stop that editor and unset
`GODOT_AI_HTTP_PORT`, `GODOT_AI_WS_PORT`, and any
`GODOT_AI_CLIENT_ID(S)` selector before relaunching. EditorSettings cannot
override a still-present lane environment. Also launch the client without the
lane-specific config-home override (such as `CODEX_HOME`), or reconfigure the
intended client home to point back at `http://127.0.0.1:8000/mcp`.
