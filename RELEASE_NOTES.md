# Portable Agents v0.1.5

The Windows ARM64 ReleaseSafe binary is no longer stripped. The v0.1.4 ARM64
binary crashed on a real `agent call`; the v0.1.5 binary passes that call on a
native ARM64 runner before packaging. All six binaries are tested on their
target platforms. The package format, protocol 1, and TypeScript SDK API are
unchanged.

## Runtime requirements

`agent` requires an architecture-compatible Lua 5.5 shared library discoverable
by the operating system's dynamic loader. It requests `liblua5.5.so.0` on Linux,
`@rpath/liblua.5.5.dylib` on macOS, and `lua55.dll` on Windows. Release archives
contain only `agent`, README, and LICENSE; they do not contain Lua.

Native builds discover Lua 5.5 through `pkg-config`. Cross-builds may provide an
explicit target import library with `-Dlua-library`. Native Lua modules loaded
by Portable Agents must target the same Lua 5.5 ABI.

The TypeScript SDK is published as
[`@darkhorseprojects/portable-agents@0.1.5`](https://jsr.io/@darkhorseprojects/portable-agents/0.1.5).
It does not contain a native binary or Lua runtime.

## Downloads

| Platform            | Asset                                         |
| ------------------- | --------------------------------------------- |
| Linux x86-64        | `portable-agents-v0.1.5-linux-x86_64.tar.gz`  |
| Linux ARM64         | `portable-agents-v0.1.5-linux-aarch64.tar.gz` |
| macOS Intel         | `portable-agents-v0.1.5-macos-x86_64.tar.gz`  |
| macOS Apple Silicon | `portable-agents-v0.1.5-macos-aarch64.tar.gz` |
| Windows x86-64      | `portable-agents-v0.1.5-windows-x86_64.zip`   |
| Windows ARM64       | `portable-agents-v0.1.5-windows-aarch64.zip`  |

Verify downloads against the release's `SHA256SUMS`.
