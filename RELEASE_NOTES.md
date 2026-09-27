# Portable Agents v0.1.3

Portable Agents now gives its macOS Lua dependency a relocatable install name.
macOS release binaries request `@rpath/liblua.5.5.dylib` instead of recording
the package manager's absolute library path. Linux and Windows retain their
existing system-library contracts. The package format, protocol 1, and
TypeScript SDK API are unchanged.

## Runtime requirements

`agent` requires an architecture-compatible Lua 5.5 shared library discoverable
by the operating system's dynamic loader. It requests `liblua5.5.so.0` on Linux,
`@rpath/liblua.5.5.dylib` on macOS, and `lua55.dll` on Windows. The release
archives contain only `agent`, README, and LICENSE; they do not contain Lua.

Builds discover Lua 5.5 headers and libraries through `pkg-config`. Native Lua
modules loaded by Portable Agents must target the same Lua 5.5 ABI. Agent
Connector does not provide or configure Lua; launched agents inherit the parent
environment unchanged.

The unchanged TypeScript SDK is published as
[`@darkhorseprojects/portable-agents@0.1.3`](https://jsr.io/@darkhorseprojects/portable-agents/0.1.3).
It does not contain a native binary or Lua runtime.

## Downloads

| Platform            | Asset                                         |
| ------------------- | --------------------------------------------- |
| Linux x86-64        | `portable-agents-v0.1.3-linux-x86_64.tar.gz`  |
| Linux ARM64         | `portable-agents-v0.1.3-linux-aarch64.tar.gz` |
| macOS Intel         | `portable-agents-v0.1.3-macos-x86_64.tar.gz`  |
| macOS Apple Silicon | `portable-agents-v0.1.3-macos-aarch64.tar.gz` |
| Windows x86-64      | `portable-agents-v0.1.3-windows-x86_64.zip`   |
| Windows ARM64       | `portable-agents-v0.1.3-windows-aarch64.zip`  |

Verify downloads against the release's `SHA256SUMS`. See the
[wiki](https://github.com/darkhorseprojects/portable-agents/wiki) for package
and embedding documentation.
