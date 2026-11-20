# Release notes

Both libraries now own concurrent root/reverse-call correlation and connection failure. Root IDs scope reverse calls; no
invocation context field, runner, application scheduler, or protocol version was added.

PA retains only generic readiness, call, result and error envelopes. Routing context, import metadata and application
notifications are no longer envelope fields. Agents export an ordinary `invoke(input, config, imports)` function; the
agent's process entry point owns dispatch and imported bindings. Applications own discovery and process startup. Publish
bytes through `chunk`, using one final chunk for a complete item or several for a stream. RPC results remain separate.
No package or protocol version number changed.
