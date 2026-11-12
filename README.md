# Portable Agents

Portable Agents supplies bounded process framing and envelopes. Applications own processes, authority, execution,
delivery and persistence. See [the specification](spec.md).

TypeScript exports `Message`, `encode(message, maximumBytes)` and `decode(readable, maximumBytes)` from `sdk/mod.ts`.
Decode yields complete envelopes immediately on a live connection. The connection owner checks readiness and correlates
overlapping calls in both directions by their connection-local IDs. `ready.handle` and `call.caller` identify authors,
not credentials. Calls may carry a flat `imports` documentation map; applications retain routing and authority.

Install the Janet package independently with JPM, using its configured system or user module directory:

```sh
jpm install https://github.com/darkhorseprojects/portable-agents.git
```

JPM installs PA and its declared dependencies. Do not copy PA into an agent or use another application's dependency
tree. Standard JPM module-path configuration applies on Linux, macOS and Windows.

```janet
(import pa)
(def pending @"")
(def call (pa/read stdin pending 1048576))
(pa/write stdout {:type "result" :id (call :id) :value :null} 1048576)
```

`pa/read` accepts a file or readable stream and a connection-local buffer. It returns nil at clean EOF; `pa/write`
accepts a writable file or stream. Both validate envelopes, UTF-8 and frame bounds. Blocking file IO belongs on an IO
thread when an application also runs an event loop.

Neither implementation owns a scheduler, database, installer or process manager. Deno uses its normal package cache for
the TypeScript module; JPM uses its normal installation paths for Janet.

Run `deno task check` for formatting, lint and TypeScript checks.
