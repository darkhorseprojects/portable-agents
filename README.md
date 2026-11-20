# Portable Agents

A small process protocol and SDK for calling agents and streaming bytes.

Serve a Janet agent with `(pa/serve {:invoke invoke})`. Install the module with `jpm deps` and `jpm install`. The SDK
reads `PA_HANDLE` and `PA_FRAME_BYTES`, decodes byte input, and constructs callable imports. Inside a call,
`(dyn :pa/root)` identifies the live caller; never persist this object.

The TypeScript SDK provides `Connection` for a pair of byte streams, and `encode` and `decode` for individual frames. It
runs on Deno 2.9 and Bun 1.4. It doesn't start a process or authorize imports.

```ts
import { decode, encode } from "jsr:@darkhorseprojects/portable-agents";

const bytes = encode({ type: "ready", handle: "example" }, 1024);
for await (const frame of decode(ReadableStream.from([bytes]), 1024)) console.log(frame);
```

[spec.md](spec.md) defines the wire protocol and calling convention.
