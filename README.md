# Portable Agents

Bounded JSON messages over a bidirectional process connection.

```sh
jpm install
```

This installs declared dependencies too. Install into the shared Janet module directory; set `JANET_PATH` if needed. Do
not copy the module into agent checkouts. Zinc installs PA as a dependency; no separate PA installation is required.

- Janet: `pa/read`, `pa/write`, and `pa/serve(handle, maximum-bytes, handler)`.
- TypeScript: `Message`, `encode`, `decode`, `Connection`, `RemoteError`, and `diagnostic` from `sdk/mod.ts`.

`serve` dispatches ordinary calls concurrently. Its handler receives the envelope and a connection-bound
`reverse(method, params)` function. `Connection` takes readable/writable streams, the authenticated peer handle, and a
frame limit. `call(caller, method, params, dispatch, signal)` retains a reverse-call handler per outstanding root.

Codecs validate envelopes, UTF-8 frames, and byte limits. Readers yield complete frames immediately. The shared
connection code handles correlation and connection failure; applications own authentication, authorization and
persistence. Handles identify authors; transport IDs only correlate calls. In Janet, use `:null` for required JSON null
fields; nil-valued dictionary entries are absent.

Agents export `invoke(input, config, imports)`: bytes, opaque agent configuration, and ordinary Janet bindings. The
agent owns its entry point and execution; PA supplies only transport utilities. Output can be a supplied function.

[spec.md](spec.md) defines the wire protocol and calling convention. Run `deno task check` for formatting, lint, and
type checks.
