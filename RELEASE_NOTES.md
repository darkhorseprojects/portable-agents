# Unreleased

- Full controller catalog separated from program-visible Imports; private delegation preserves authority without
  exposing it to generated code.
- Explicit member grants and discrete/append byte emits.
- Terminal shutdown drains pending socket traffic; ignored child handles no longer turn committed results into reset
  failures.
- Plain Error-based AgentError with Effect failure-channel handling.
- Strict framing/Unicode/Base64 and independent/repeated-await regression probes.

# 0.2.0

PA is a small execution boundary for ordinary Janet programs, not an agent framework or job system.

- Four Janet modules: `pa`, `protocol`, `markdown`, and `main`. No runtime dependencies, native build, or daemon.
- Opaque byte calls, named process-crossing tool grants, explicit grant delegation, and streamed diagnostics/output.
- Janet's standard loader, explicit package/dependency roots, and the complete Markdown loader hook.
- Protocol 6 at the CLI and SDK boundary. Earlier protocols and spool options have no compatibility paths.
- Independent admission and completion use inherited private pipes. Worker RPC uses nonce-authenticated loopback TCP
  with private-pipe endpoint confirmation, bounded peer candidates, and an admission deadline.
- Internal JSON frames have an ASCII length header for stdio portability. No transport directories, result files, socket
  paths, filesystem polling, or cleanup responsibility.
- Independent spawn accepts the full request and delegated grants. Losing its observation pipes does not cancel accepted
  work. Running independent events are not forwarded; raw output, including delegated tools, goes to the OS null device.
- Collection and process waiting start immediately. Single-writer futures cache decoded immutable outcomes for optional,
  repeated, and concurrent awaits. Proxy handles eagerly transfer completion once and release controller reservations.
- Mandatory invoker-selected frame, depth, in-flight RPC, proxy-handle, and admission-time bounds. Capacity failures use
  `ResourceLimit`; there is no PA queue or retry.
- Reused JSON/Markdown PEG grammars, native JSON string accumulation/escaping and bounded SDK byte collection, canonical
  Base64 checks without re-encoding, strict flat SDK frames, and bounded in-memory traceback capture.
- Stable Effect 4.0.2 SDK with `call` and `stream`, consumer-owned process services, strict decoding, and schema-capable
  typed errors.
- Programs own durable completion and application-defined idempotency. A lost spawn acknowledgment is ambiguous;
  duplicate execution is possible. PA does not deduplicate, retry, append results, or recover task IDs.

The invoker owns trusted source snapshots, credential scrubbing, OS confinement and aggregate quotas, execution
deadlines, process groups/jobs, termination, and unfinished work. All PA-launched processes use Janet `:d`. The CLI
handles POSIX `SIGPIPE`; library embedders own signal handling. Local bounds and loopback authentication are not a
sandbox or a denial-of-service guarantee. PA cannot recover a dead executing child or escape its OS scope.
