![portable-agents](https://chaosdiscovery.s-ul.eu/Gtamrmmy)

[![Zig version](https://img.shields.io/badge/zig-0.16.0-black?style=flat&logo=zig&logoColor=F7A41D&labelColor=black)](https://github.com/darkhorseprojects/portable-agents/releases/latest)
[![JSR](https://jsr.io/badges/@darkhorseprojects/portable-agents?style=flat-square&color=083344)](https://jsr.io/@darkhorseprojects/portable-agents)

# Portable Agents

Portable Agents (PA) is a small Zig runtime and library for packaging Lua and
Markdown agents and calling them in isolated Lua 5.5 states. It gives trusted
package code a narrow host interface, supports explicit agent Imports, and keeps
each invocation behind caller-configured resource limits.

PA is an execution and embedding layer, not a model, orchestration service, or
ready-made agent. Packages define their own behavior and decide which
capabilities to use.

## What you get

- Compile a package's Lua modules and Markdown documents into a Portable Agents
  Image.
- Invoke its configured entry module with byte input and config, or expose it as
  an Import to another agent.
- Use `require("pa")` for host operations and `require(name)` for explicitly
  granted Import modules.
- Run Eval functions in independent states, passing supported native Lua values
  between them.
- Stream opaque output bytes, incremental append bytes, and bounded stage logs
  over protocol 1.
- Limit Lua memory and instructions, and bound HTTP response bytes and chunks.

The [wiki](https://github.com/darkhorseprojects/portable-agents/wiki) explains
package structure, the authority model, and embedding. PA does not add ambient
Lua modules through `LUA_PATH` or `LUA_CPATH`; native modules are loaded from
the package's `native/` directory.

## Requirements

- Zig 0.16.x
- An architecture-compatible Lua 5.5 shared library discoverable by the
  operating system's dynamic loader. Release archives do not include Lua.
- Deno for the TypeScript SDK

At runtime, `agent` requests `liblua5.5.so.0` on Linux,
`@rpath/liblua.5.5.dylib` on macOS, or `lua55.dll` on Windows. To build `agent`,
install the matching development headers and make its `lua5.5` pkg-config
metadata discoverable, then run `zig build -Doptimize=ReleaseSafe`.

The executable is `agent`. The TypeScript SDK is in `sdk/mod.ts`; it uses Effect
4 and starts one `agent call` child process per invocation. `Agent.call` returns
terminal bytes. `Agent.stream` exposes protocol events, including optional
profiling when explicitly enabled.

## Learn more

- [Portable Agents wiki](https://github.com/darkhorseprojects/portable-agents/wiki)
  — package language, authority model, protocol, and embedding APIs
- [Zinc](https://github.com/darkhorseprojects/zinc) — a memory-enabled Portable
  Agents package
- [Agent Connector](https://github.com/darkhorseprojects/agent-connector) — a
  Discord integration for Portable Agents policies

License: [AGPL-3.0-only](LICENSE).
