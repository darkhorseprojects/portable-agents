# Portable Agents v0.2.0

## Requirements

Runtime installations need the platform's Lua 5.5 shared library. Native package modules must use the same ABI.
Builds need Zig 0.16.x and Lua 5.5 development headers.

## Update callers

Use protocol version 2. External named-member calls set `member` to a direct entry function name;
root calls omit it. Input, config, and output remain bytes encoded as padded base64 on the wire.

Terminal failures now use `error: {code, message, detail}` in the result frame.
Read diagnostic detail from that failure, not a separate traceback frame. Keep it private.

SDK calls use the options object as their third argument:

```ts
const output = yield* agent.call(input, config, {
  imports: [],
  member: "describe",
  profile: false,
});
```

Use a package declaring `describe` for this example. `stream` accepts the same options.
See [Embedding](https://github.com/darkhorseprojects/portable-agents/wiki/Embedding) for complete programs and wire examples.

Native `Agent.init` accepts an optional diagnostic sink; `Agent.call` accepts `CallOptions`.
Results are owned output bytes or Zig errors, with diagnostics delivered through the sink.

## Eval failures

Ordinary source failures remain `{ok, value}` tuples. Instruction exhaustion aborts the call with `InstructionLimit`;
cancellation, allocation, and setup failures also remain call-level failures.
Source diagnostics identify `eval:1`, `eval:2`, and subsequent inputs.
