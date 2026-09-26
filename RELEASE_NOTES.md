# Portable Agents v0.1.0

First public release of the Portable Agents runtime and TypeScript SDK. Portable Agents packages Lua and Markdown modules into an Image and invokes them inside isolated Lua 5.5 states. It is an execution and embedding layer, not a model or an agent service.

## Runtime and SDK

- `agent check <source> <entry>` validates and loads a package; `agent call` accepts a protocol-1 request on stdin and emits newline-delimited JSON frames on stdout.
- Packages can grant named Imports, expose callable members, use bounded host operations, and run Eval functions in independent states. Calls have caller-configured Lua memory and instruction limits.
- Streaming distinguishes new output from append output and reports bounded operator logs. The TypeScript SDK in `sdk/mod.ts` provides `Agent.call` for terminal bytes and `Agent.stream` for protocol events; it uses Effect 4 and starts an `agent call` child process per invocation.
- The SDK is published as [`@darkhorseprojects/portable-agents`](https://jsr.io/@darkhorseprojects/portable-agents) on JSR at version `0.1.0`. The JSR package is the SDK; it does **not** contain a native `agent` executable.

## Downloads

| Platform | Asset |
| --- | --- |
| Linux x86-64 | `portable-agents-v0.1.0-linux-x86_64.tar.gz` |
| Linux ARM64 | `portable-agents-v0.1.0-linux-aarch64.tar.gz` |
| macOS Intel | `portable-agents-v0.1.0-macos-x86_64.tar.gz` |
| macOS Apple Silicon | `portable-agents-v0.1.0-macos-aarch64.tar.gz` |
| Windows x86-64 | `portable-agents-v0.1.0-windows-x86_64.zip` |
| Windows ARM64 | `portable-agents-v0.1.0-windows-aarch64.zip` |

Each archive contains the `agent` executable, README, and license. The default build bundles Lua; a compatible dynamic Lua 5.5 installation is required only when building with `-Dsystem-lua=true`. Release asset hashes are in `SHA256SUMS`. Package content, host authority, and embedding details are documented in the [wiki](https://github.com/darkhorseprojects/portable-agents/wiki).
