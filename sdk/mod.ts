export type Identity = Uint8Array;

export interface Entry {
  module: string;
  members?: readonly string[];
}

export interface Agent {
  readonly identity: Identity;

  call(entry: Entry, input: Uint8Array): Promise<Uint8Array>;

  close(): void;
}

export interface Mount {
  readonly name: string;
}

export interface AgentOptions {
  source: string;
  identity?: Identity;
  mounts?: readonly Mount[];
}

export interface Backend {
  open(options: AgentOptions): Promise<Agent>;
}
