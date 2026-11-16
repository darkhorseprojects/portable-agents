# Release notes

PA retains only generic readiness, call, result and error envelopes. Routing context, import metadata and application
notifications are no longer envelope fields. Agents export an ordinary `invoke(input, config, imports)` function; the
agent's process entry point owns dispatch and imported bindings. The application interaction contract has been removed.
No package or protocol version number changed.
