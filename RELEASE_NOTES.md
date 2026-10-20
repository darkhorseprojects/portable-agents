# 0.3.0

Protocol 2 uses native Spork JSON, UTF-8 and Base64 codecs. PA validates consumed fields and transport bounds rather
than duplicate keys, canonical encodings, unknown fields or a configurable JSON depth. Install matching binaries, Janet
sources and TypeScript SDKs; there is no protocol-1 adapter.

The CLI takes `spawn FRAME-BYTES ADMISSION-SECONDS`. Input/config decoding precedes source loading and acceptance. The
TypeScript SDK uses bounded streaming UTF-8 decoding. Both SDKs preserve admission ordering, terminal uniqueness, EOF,
exit checks and observation cancellation without killing accepted work.

CI caches Janet/Jpm bootstrap independently of PA dependencies, saves it before installing PA, and exports the matching
installed toolchain separately. Downstream toolchain calls skip redundant PA regressions. Native codec and streaming
boundary regressions run on PA changes; ordinary changes build three platforms, releases and manual runs all six.
