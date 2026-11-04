# Portable Agents

Portable Agents defines a small process-boundary protocol and supplies its TypeScript codec. It does not install,
launch, schedule, or supervise agents.

The SDK exports exactly `Message`, `encode`, and `decode` from `sdk/mod.ts`. Both agent invocations and capability calls
use the same message grammar and lifecycle. See [the specification](spec.md).

## SDK

`Message` is the version-1 discriminated union of call, ready, event, result, and error messages. Diagnostics belong to
the error message; there is no separate exception hierarchy.

`encode(message, maximumBytes)` validates a message and returns one UTF-8 JSON line. The byte limit includes the
newline. It owns no stream or process.

`decode(readable, maximumBytes)` yields validated messages from a readable byte stream. It handles chunk boundaries,
strict UTF-8, frame bounds, lifecycle ordering, EOF, and trailing-data rejection. Calls and terminal responses are
withheld until EOF; intermediate events stream immediately.

Application parameters and result values remain application data. Invocation approaches, runtime inference, installation
paths, authorization, credentials, database schemas, task continuation, and delivery belong to their respective
implementations.

Janet agents implement this language-neutral protocol in their own source. This package contains no Janet runtime,
executable, manifest, document loader, or shared-library installation scheme.

## Development

Run `deno task check` for formatting, lint, and TypeScript checks. There is no native build.
