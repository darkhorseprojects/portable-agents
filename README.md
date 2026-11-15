# Portable Agents

Bounded JSON messages over a bidirectional process connection.

```sh
jpm deps
jpm install
```

Install into the shared Janet module directory; set `JANET_PATH` if needed. Do not copy the module into agent checkouts.

- Janet: `pa/read(stream, pending, maximum-bytes)`, `pa/write(stream, message, maximum-bytes)`.
- TypeScript: `Message`, `encode(message, maximumBytes)`, `decode(readable, maximumBytes)` from `sdk/mod.ts`.

Codecs validate envelopes, UTF-8 frames, and byte limits. Readers yield complete frames immediately. Applications handle
identity, dispatch, lifetime, and persistence. Handles identify authors; transport IDs only correlate calls. In Janet,
use `:null` for required JSON null fields; nil-valued dictionary entries are absent.

[spec.md](spec.md) defines the wire protocol; [interaction.md](interaction.md) defines optional application payloads.
Run `deno task check` for formatting, lint, and type checks.
