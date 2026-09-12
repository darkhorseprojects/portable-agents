# Portable Agents

A small Zig library for compiling immutable Lua/Markdown Images and invoking
byte capabilities in independent Lua 5.5 states.

Trusted package code receives normal Lua libraries and explicit host mechanisms.
Generated Eval code runs in a separate restricted state and can reach only the
selected entry capability's exports and caller Imports. Public modules return
`pa.capability`, and Lua values never cross state boundaries.

The TypeScript SDK targets Effect 4. Each scoped `agent call` process receives
one JSON request on stdin and returns one JSON result on stdout. The SDK
contains no FFI or runtime-specific APIs.

Requires Zig 0.16.x. See the project wiki for language, authority, and embedding
details.
