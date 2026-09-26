# Portable Agents v0.1.2

Portable Agents now uses an installed Lua 5.5 shared runtime instead of
embedding Lua in `agent`. Its package format, protocol 1, and TypeScript SDK API
are unchanged. This corrects the runtime contract used by Agent Connector and
Zinc: all three must use an ABI-compatible system Lua 5.5 installation.

## Runtime requirements

Install Lua 5.5 separately before using `agent`. The release archives contain
only `agent`, README, and LICENSE; they do not contain Lua. On Ubuntu 26.04,
install `liblua5.5-0` (and `liblua5.5-dev` to build from source). On macOS,
install Homebrew's `lua`. On Windows, install the matching MSYS2 Lua package:
UCRT64 for x86-64 or CLANGARM64 for ARM64. The Lua runtime must be available to
the operating system's library loader.

Builds use the installed Lua 5.5 headers and library discovered through
`pkg-config`; neither a bundled-Lua mode nor a manually supplied include path is
required. Native Lua modules such as Zinc's SQLite extension must use this same
runtime.

The unchanged TypeScript SDK is published as
[`@darkhorseprojects/portable-agents@0.1.2`](https://jsr.io/@darkhorseprojects/portable-agents/0.1.2).
It does not contain a native binary or Lua runtime.

## Downloads

| Platform            | Asset                                         |
| ------------------- | --------------------------------------------- |
| Linux x86-64        | `portable-agents-v0.1.2-linux-x86_64.tar.gz`  |
| Linux ARM64         | `portable-agents-v0.1.2-linux-aarch64.tar.gz` |
| macOS Intel         | `portable-agents-v0.1.2-macos-x86_64.tar.gz`  |
| macOS Apple Silicon | `portable-agents-v0.1.2-macos-aarch64.tar.gz` |
| Windows x86-64      | `portable-agents-v0.1.2-windows-x86_64.zip`   |
| Windows ARM64       | `portable-agents-v0.1.2-windows-aarch64.zip`  |

Verify downloads against the release's `SHA256SUMS`. See the
[wiki](https://github.com/darkhorseprojects/portable-agents/wiki) for package
and embedding documentation.
