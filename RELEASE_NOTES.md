# Portable Agents v0.2.0

Coordinated breaking update for Zinc and Agent Connector. These notes describe
the source release; publication is a separate step.

- Protocol 2 supports an optional named entry `member`.
- Terminal errors contain `{code,message,detail}`. There are no separate
  traceback wire frames.
- Lua bytecode retains source locations. Compiler and HTTP callback failures
  retain useful diagnostics.
- Eval sources are named `eval:1`, `eval:2`, and so on. Ordinary source failures
  remain result tuples; exhausted instruction quotas abort the call.
- SDK `call` and `stream` take `{imports,member,profile}` as their third
  argument.
- Native `Agent.init` accepts an optional diagnostic sink; `Agent.call` accepts
  `CallOptions`.
- Behavior-test fixtures and CI behavior tests have been removed. CI retains
  formatting, builds, ABI inspection, and archive verification.

## Requirements

Build with Zig 0.16.x and Lua 5.5 development headers. Runtime binaries require
an architecture-compatible shared Lua library: `liblua5.5.so.0` on Linux,
`@rpath/liblua.5.5.dylib` on macOS, or `lua55.dll` on Windows. Archives contain
`agent`, README, and LICENSE, not Lua. Native package modules must use the same
Lua ABI.

Protocol 1 callers and the old SDK call signature must be updated together.
Native calls still return owned output bytes or a Zig error; embedders receive
diagnostic events through their sink.

## Publication

Publish PA binaries and SDK 0.2.0 before Agent Connector and Zinc. Connector's
registry lock must be refreshed against the published SDK before its frozen
registry build. The local coordinated build uses the SDK source directly and
does not require publication.

Release jobs target Linux x86-64/ARM64, macOS Intel/Apple Silicon, and Windows
x86-64/ARM64. Verify published downloads against `SHA256SUMS`. Local validation
does not establish that every target binary has been executed.
