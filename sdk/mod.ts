export type Identity = Uint8Array;

export interface Entry {
  readonly module: string;
  readonly members?: readonly string[];
}

export interface Mount {
  readonly name: string;
  readonly call: (input: Uint8Array) => Promise<Uint8Array>;
}

export interface AgentOptions {
  readonly source: string;
  readonly identity?: Identity;
  readonly mounts?: readonly Mount[];
  readonly luaBytes?: number;
  readonly luaSteps?: bigint;
}

export interface Agent {
  readonly identity: Identity;

  call(entry: Entry, input: Uint8Array): Promise<Uint8Array>;

  close(): Promise<void>;
}

export class AgentError extends Error {
  constructor(readonly code: string) {
    super(code);
    this.name = "AgentError";
  }
}
