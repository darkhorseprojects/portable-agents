# Portable Agents

Portable Agents defines a process-boundary protocol and its TypeScript codec. Applications own invocation, authority,
execution, delivery and persistence. See [the specification](spec.md).

The SDK exports `Message`, `encode` and `decode` from `sdk/mod.ts`.

- `Message` is the version-1 union of call, ready, event, result and error envelopes.
- `encode(message, maximumBytes)` validates a message and returns one UTF-8 JSON line, including its final newline in
  the byte limit.
- `decode(readable, maximumBytes)` yields validated envelopes. It checks chunk boundaries, UTF-8, frame bounds,
  lifecycle order, EOF and trailing data. Calls and terminal responses are withheld until EOF; events stream
  immediately.

Application parameters, result values and replay decisions are not protocol state. The codec owns no process, scheduler
or database and does not provide execution durability. Applications may use other transports for their internal
services.

## Development

Run `deno task check` for formatting, lint and TypeScript checks. There is no native build.
