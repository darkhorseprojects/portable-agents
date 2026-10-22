# Portable Agents 0.2.0

- Protocol stdout uses a private non-inheritable descriptor on POSIX and Windows.
- Protocol 3 replaces separate log/traceback frames with structured diagnostics.
- Both SDKs retain error detail/context and explicit diagnostic limit failures.
- Native stderr is drained independently of the protocol stream.
- Six-platform native/SDK builds remain; inline runtime fixtures are removed.

Install matching native binaries, Janet sources and TypeScript SDKs together. Package version 0.2.0 is independent of
protocol version 3.
