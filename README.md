# Portable Agents

Bounded JSON messages over a bidirectional process connection.

```sh
jpm deps
jpm install
```

Install into the shared Janet module directory; set `JANET_PATH` if needed. Do not copy the module into agent checkouts.
Zinc installs PA as a dependency; no separate PA installation is required.

Serve an agent with `(pa/serve {:invoke invoke})`. The SDK reads `PA_HANDLE` and `PA_FRAME_BYTES`, decodes byte input,
and constructs callable imports. Inside a call `(dyn :pa/root)` identifies the live caller; never persist this object.
Optional application methods are registered in the same table. The built-in `describe` method lists supported methods
even for invoke-only agents.

`Connection.invoke` is the matching TypeScript interface. `openAgent` starts the configured Janet process and bounds
startup and shutdown. The caller authorizes imports; agents own their configuration, persistence, and execution policy.

[spec.md](spec.md) defines the wire protocol and calling convention.
