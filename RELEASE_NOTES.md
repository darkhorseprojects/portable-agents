# Portable Agents 0.2.0

PA provides opaque byte calls, named process-crossing tools, streamed output/diagnostics and independent execution. It
uses four Janet modules and has no runtime dependencies, daemon or application database.

## Boundary

Protocol 6 requires explicit frame, nesting, in-flight, handle and admission-time limits. Earlier protocols are
rejected. Strict decoding checks Unicode, object keys, Base64 and terminal framing. The Janet JSON codec round-trips its
`:json-null` decoder marker.

The controller retains the full grant catalog and private configurations. Programs see only their permitted names.
Imports have explicit member lists and optional narrower delegation. Named targets retain the invoker's configuration;
generated requests cannot create a grant or launcher permission.

Janet owns module resolution and environments. Markdown adds a loader for complete documents and exact `janet` fences.
Every call starts a process. Resident applications must provide their own service and persistent environment; PA
supplies no session framework.

## Independent work

Spawn accepts the complete request and delegated grants before acknowledging admission. Collection begins immediately;
ephemeral handles cache immutable completion bytes or failures for optional/repeated awaits. Applications must commit
durable outcomes before returning.

Independent events and raw output are not forwarded. Losing observation does not cancel accepted execution. A lost
admission acknowledgment is ambiguous, and PA does not deduplicate or retry work.

The Effect 4.0.2 SDK exposes `call` and `stream`, using the consumer's process services. The invoker owns OS
confinement, quotas, deadlines, signals, process groups and termination. Loopback authentication is not a same-user
sandbox; executing children cannot survive the loss of their OS scope merely because they were spawned independently.
