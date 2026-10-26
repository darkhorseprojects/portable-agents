# Portable Agents 0.2.0

- One native `agent run` entrypoint; no protocol relay or alternate interpreter launcher.
- Standard Janet printing and errors replace PA emissions and diagnostics; module and entrypoint output inherit the
  worker sinks.
- Library imports are `portable-agents/protocol` and `portable-agents/markdown`; string and buffer payloads share the
  byte contract.
- Janet processes/fibers replace PA spawning, handles and awaiting.
- The TypeScript SDK only encodes requests and decodes bounded output streams.
- Lazy Remarkable parsing replaces the custom Markdown grammar; `document` is data.
- Worker detachment, private protocol output and broken-pipe handling remain native.
- Markdown registration runs at worker startup; Windows workers and native modules share `janet.dll`.
- One six-target workflow builds all three projects and publishes permission-preserving release archives.
- Package version is 0.2.0; wire schema is 1. Install matching components together.
