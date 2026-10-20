# 0.3.0

The TypeScript `spawn` API is now a native async generator, with no Effect dependency. Consume it with `for await`;
failures throw `AgentError` with a stable `code`. An optional abort signal interrupts blocked reads and exit waits
without killing accepted execution. Breaking iteration also closes observation.

Janet observers and the CLI share admission and terminal validation in the protocol reader. Repeated Janet awaits still
return the cached outcome. The collector, not an arbitrary awaiter, owns completion-channel closure, including
concurrent awaits. TypeScript duplicate-key validation counts lexical keys against decoded own keys without a second key
decoder; strict framing, canonical Base64, EOF and exit checks remain.

Protocol version remains 1. Install matching native binaries and Janet sources. The SDK API change has no compatibility
adapter.

Base64 uses the pinned native Spork codec while retaining PA's canonical encoding and byte-bound checks. TypeScript
observation uses standard stream cancellation and process-exit promises.

Native executable-path discovery uses a managed growth buffer. CI checks the SDK once, builds native artifacts and
exports the matching installed PA/Janet/Jpm toolchain. Ordinary changes build three platforms; tags and manual runs
build all six. Build artifacts are uploaded only for tags and manual runs.
