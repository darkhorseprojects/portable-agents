# Portable Agents

A small Zig library for compiling immutable Lua/Markdown Images and calling
ordinary Lua interfaces in fresh Lua 5.5 states.

The TypeScript SDK targets Effect 4 and talks to the `agent` executable over a
duplex newline-delimited JSON protocol. In `agent call`, stdin and stdout are
reserved for that protocol; diagnostics belong on stderr. The SDK contains no
FFI or runtime-specific APIs.

Requires Zig 0.16.x. See the project wiki for the package language, authority
model, and embedding APIs.
