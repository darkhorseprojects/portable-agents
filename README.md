# Portable Agents

Bounded, bidirectional JSON messages over a process connection. Applications own authentication, dispatch, process
lifetime, execution, delivery, and persistence.

## Install

Install the local Janet checkout into JPM's normal shared module directory:

```sh
jpm deps
jpm install
```

Set `JANET_PATH` if that directory is not the runtime default. Do not copy the library into an agent checkout.

## API

- Janet: `pa/read(stream, pending, maximum-bytes)` and `pa/write(stream, message, maximum-bytes)`.
- TypeScript: `Message`, `encode(message, maximumBytes)`, `decode(readable, maximumBytes)` from `sdk/mod.ts`.

Readers yield complete frames immediately, without waiting for EOF. Both codecs validate envelopes, UTF-8, and byte
limits. Owners verify readiness and correlate overlapping calls in both directions. Handles identify authors, not
credentials; transport IDs do not identify durable work or authorize replay.

See [spec.md](spec.md) for the wire protocol and [interaction.md](interaction.md) for the optional application contract.
Codecs do not interpret application events. Run `deno task check` for formatting, lint, and TypeScript checks.
