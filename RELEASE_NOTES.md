# Portable Agents 0.2.0

- Janet encoded-frame accounting now matches the TypeScript SDK's single LF delimiter, including error-size reporting.
- Reusable native packaging passes the current Python interpreter to project-owned asset builders.
- The stream-only SDK shares a bounded byte-level LineDecoder with application record consumers; Markdown registration
  runs once.
- Connector releases retain versioned, external Janet libraries beside the executable.
- Wire protocol remains 1. No state management, instance registry or scheduler is added to PA.
