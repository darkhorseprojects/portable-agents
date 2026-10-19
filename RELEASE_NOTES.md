# 0.3.0

The TypeScript `spawn` API is now a native async generator, with no Effect dependency. Consume it with `for await`;
failures throw `AgentError` with a stable `code`. An optional abort signal interrupts blocked reads and exit waits
without killing accepted execution. Breaking iteration also closes observation.

Janet observers and the CLI share admission and terminal validation in the protocol reader. Repeated Janet awaits still
return the cached outcome.

Protocol version remains 1. Install matching native binaries and Janet sources. The SDK API change has no compatibility
adapter.

Native executable-path discovery uses a managed growth buffer. CI checks the SDK once, exercises native transport and
caches the toolchain. Ordinary changes build three platforms; tags and manual runs build all six. Build artifacts are
uploaded only for tags and manual runs.
