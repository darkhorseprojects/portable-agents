# Portable Agents

A small Zig library for compiling immutable Lua/Markdown Images and invoking
byte capabilities in independent Lua 5.5 states.

Trusted package code receives normal Lua libraries and explicit host mechanisms.
Generated Eval code runs in a separate restricted VM and can reach only named
capabilities offered by the package or granted for that invocation. Lua values
never cross VM boundaries.

The TypeScript SDK targets Effect 4 and talks to the `agent` executable over a
duplex newline-delimited JSON protocol. In `agent call`, stdin and stdout are
reserved for that protocol; diagnostics belong on stderr. The SDK contains no
FFI or runtime-specific APIs.

Requires Zig 0.16.x. See the project wiki for the package language, authority
model, and embedding APIs.
