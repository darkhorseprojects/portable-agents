# Portable Agents

A small Zig library for compiling Lua and Markdown packages and invoking a
configured entry module in independent Lua 5.5 states.

An `Agent` owns compiled source, an HTTP client, and per-state limits. Trusted
package code and its third-party dependencies use normal Lua libraries and
`require`. Host operations live in `require("pa")`. An entry returns a callable
table whose direct functions can form Eval's `self`; caller Imports expose
native Lua members through `require(name)`. Root and callable Import entries
exchange bytes; Import members transfer native Lua arguments and results.
`pa.imports()` lists the granted Import names. An Import member receives its
private config first, followed by the caller's positional Lua arguments. Eval
views copy nil, booleans, numbers, strings, and acyclic tables between isolated
Lua states; table results are rendered as Lua text. Trusted package modules and
pure Lua dependencies are compiled into the Image, while native modules load
from the package's `native/` directory. PA fixes `package.path` to empty and
`package.cpath` to that directory's absolute native-module pattern; ambient
`LUA_PATH` and `LUA_CPATH` do not add modules. Eval can make caller-owned tables
callable, but exposes no general metatable access.

The TypeScript SDK targets Effect 4. Each scoped `agent call` process reads one
protocol-1 JSON request from stdin and writes newline-delimited result frames to
stdout. `Agent.call` returns the terminal bytes; `Agent.stream` also exposes
opaque bytes emitted through `pa.emit(bytes)` and incremental bytes appended to
the current message through `pa.emit(bytes, "append")`. PA does not classify
model reasoning or content. Trusted code can record bounded stage names with
`pa.log`; Lua failures carry a bounded traceback. Profiled log frames include `atUs`, microseconds since the child entered the protocol call, on the child's monotonic clock; ordinary log frames retain their original shape. The SDK's optional fourth `Agent.stream` argument enables profiling (`false` by default); trusted packages can check `pa.profile` to emit extra stage markers only for profiled calls. These child timestamps must not be compared directly with the embedder's clock. `pa.http` can enforce a
response-byte limit and deliver bounded chunks to a Lua callback. The
SDK contains no FFI or runtime-specific APIs.

Requires Zig 0.16.x. The wiki documents the package language, authority model,
and embedding APIs.
