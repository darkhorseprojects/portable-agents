import { spawn } from "node:child_process";

export function run(
  directory: string,
  input: Uint8Array,
  executable = "pa",
): Promise<Uint8Array> {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, ["run", directory]);
    const chunks: Buffer[] = [];
    const errors: Buffer[] = [];
    child.stdout.on("data", (chunk: Buffer) => chunks.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => errors.push(chunk));
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) return reject(new Error(Buffer.concat(errors).toString()));
      const bytes = Buffer.concat(chunks);
      let offset = 0;
      while (offset + 5 <= bytes.length) {
        const kind = bytes[offset];
        const length = bytes.readUInt32LE(offset + 1);
        offset += 5;
        if (offset + length > bytes.length) return reject(new Error("truncated pa frame"));
        const value = bytes.subarray(offset, offset + length);
        offset += length;
        if (kind === 1 && offset === bytes.length) return resolve(new Uint8Array(value));
      }
      reject(new Error("missing pa return frame"));
    });
    const header = Buffer.allocUnsafe(4);
    header.writeUInt32LE(input.byteLength);
    child.stdin.end(Buffer.concat([header, Buffer.from(input)]));
  });
}
