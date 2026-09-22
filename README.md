# Portable Agents

A small Zig library for compiling Lua and Markdown packages and invoking a
configured entry module in independent Lua 5.5 states.

An `Agent` owns compiled source, an HTTP client, and per-state limits. Trusted
package code and its third-party dependencies use normal Lua libraries and
`require`. Host operations live in `require("pa")`. An entry returns a callable
table whose direct functions can form Eval's `self`; caller Imports expose
configured external entries. Root and Import calls exchange bytes. Eval views
copy nil, booleans, numbers, strings, and acyclic tables between isolated Lua
states; table results are rendered as Lua text. Eval can make caller-owned
tables callable, but exposes no general metatable access.

The TypeScript SDK targets Effect 4. Each scoped `agent call` process reads one
protocol-1 JSON request from stdin and writes newline-delimited result frames to
stdout. `Agent.call` returns the terminal bytes; `Agent.stream` also exposes
opaque bytes emitted incrementally through `pa.emit`. The SDK contains no FFI or
runtime-specific APIs.

Requires Zig 0.16.x. The wiki documents the package language, authority model,
and embedding APIs.
