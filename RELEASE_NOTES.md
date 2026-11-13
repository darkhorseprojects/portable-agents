# Release notes

The separate Connector application interaction contract documents profile discovery, opaque work/navigation/cursors and
committed output. All deployed agents are Janet programs. PA's envelopes and both codecs remain unchanged; no execution
schema, scheduler, version field or Zinc-specific work model is added to the wire protocol.

Handle provisioning and configuration formats belong to connection owners. The specification no longer prescribes UUID
generation or ac.yaml storage. Envelopes and codecs are unchanged; no agent executable or profile field is required.

PA uses fixed, unversioned envelopes in both directions. Readiness identifies the loaded author; calls carry the
authenticated caller, binding name, argument value and optional flat binding documentation. Connection owners enforce
readiness and directional correlation. Handles do not authenticate callers or preserve permissions.

Both SDKs retain bounded UTF-8 framing and originating diagnostics. Applications own routes, grants, execution and
persistence. Transport IDs confer neither work identity nor a safe-replay guarantee.
