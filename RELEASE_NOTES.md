# Portable Agents v0.1.1

This patch release fixes builds against an external Lua 5.5 runtime. The default
standalone `agent` binaries still bundle Lua; their package format and protocol
are unchanged from v0.1.0.

## System Lua build fix

When building with `-Dsystem-lua=true`, pass the directory containing `lua.h`
using `-Dlua-include=...`, as well as the Lua installation prefix for linking:

```sh
zig build -Doptimize=ReleaseSafe -Dsystem-lua=true -Dlua-include=/path/to/lua/include --search-prefix /path/to/lua
```

Previously, the header path reached the linker but not the ZigLua C-header
translator. The translator therefore failed with `lua.h` not found even when Lua
5.5 headers were installed. Dynamic builds can now share Lua with package native
modules, as required by Agent Connector and Zinc.

The TypeScript SDK is published on JSR as
[`@darkhorseprojects/portable-agents@0.1.1`](https://jsr.io/@darkhorseprojects/portable-agents/0.1.1).
Its API is unchanged; the JSR package does not contain the native executable.

## Downloads

| Platform            | Asset                                         |
| ------------------- | --------------------------------------------- |
| Linux x86-64        | `portable-agents-v0.1.1-linux-x86_64.tar.gz`  |
| Linux ARM64         | `portable-agents-v0.1.1-linux-aarch64.tar.gz` |
| macOS Intel         | `portable-agents-v0.1.1-macos-x86_64.tar.gz`  |
| macOS Apple Silicon | `portable-agents-v0.1.1-macos-aarch64.tar.gz` |
| Windows x86-64      | `portable-agents-v0.1.1-windows-x86_64.zip`   |
| Windows ARM64       | `portable-agents-v0.1.1-windows-aarch64.zip`  |

Each archive contains `agent`, README, and LICENSE. Verify downloads using the
included `SHA256SUMS` release asset. See the
[wiki](https://github.com/darkhorseprojects/portable-agents/wiki) for package
and embedding documentation.
