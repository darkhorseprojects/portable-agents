# Complete segments only

The request observation switch and append frame/mode are removed. Programs emit complete application segments. Janet
spawn drains intermediate frames immediately without accumulating them; ignoring a handle does not stop collection.
Closed observation pipes still do not cancel accepted execution. Install matching binaries and sources together; old
request flags and append frames are rejected rather than adapted.

# Silent observation cancellation

SDK stdout uses a cancellable readable-stream adapter instead of awaiting an async iterator's return behind a pending
read. Observer release does not wait for a silent execution to produce output and does not kill accepted execution.

# Development baseline

PA now has one spawn boundary and one NDJSON transport. TCP workers, nonce admission, RPC registries, program-shaped
import grants and call/invoke APIs are removed.

The native bootstrap launches independent Janet execution on each platform. SDK cleanup closes observation pipes rather
than killing a process tree. Programs own durable outcomes and must commit before returning.

Capability proxies are ordinary Janet libraries. PA declares no application-specific self or world policy. Programs
select their public export explicitly.

Install the matching compiled agent and Janet sources together. This is a development API change; no old
protocol/configuration adapters are supplied. Protocol version remains 1.
