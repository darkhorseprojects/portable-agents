import { spawn } from "node:child_process";

const [operation, frame, depth, admission] = Deno.args;
const frameBytes = Number(frame);
const seconds = Number(admission);
if (
  operation !== "spawn" || Deno.args.length !== 4 ||
  !Number.isInteger(frameBytes) || frameBytes < 1 || frameBytes > 0x7fffffff ||
  !Number.isInteger(Number(depth)) || Number(depth) < 2 || Number(depth) > 0x7fffffff ||
  !Number.isFinite(seconds) || seconds <= 0
) throw new Error("usage: agent spawn FRAME-BYTES DEPTH ADMISSION-SECONDS");

const input = new Uint8Array(frameBytes);
let used = 0;
while (used < input.length) {
  const count = await Deno.stdin.read(input.subarray(used));
  if (count === null) break;
  used += count;
}
if (used === frameBytes && await Deno.stdin.read(new Uint8Array(1)) !== null) throw new Error("TransportLimit");
const bytes = input.subarray(0, used);
const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
if (!text.endsWith("\n") || text.indexOf("\n") !== text.length - 1) throw new Error("InvalidProtocol");
const request = JSON.parse(text);
const command: unknown = request.program?.command ?? ["janet"];
if (
  !Array.isArray(command) || !command.length ||
  command.some((arg) => typeof arg !== "string" || !arg || arg.includes("\0"))
) {
  throw new Error("InvalidProgram");
}
const child = spawn(command[0], [
  ...command.slice(1),
  "-e",
  "(import portable-agents/src/main) (main/main ;(tuple/slice (dyn :args) 2))",
  frame,
  depth,
  admission,
], {
  detached: true,
  shell: false,
  stdio: ["pipe", "pipe", request.observe ? "inherit" : "ignore"],
  env: { ...Deno.env.toObject(), PA_EXECUTABLE: Deno.execPath() },
});
const status = Promise.withResolvers<number>();
child.once("error", status.reject);
child.once("close", (code) => status.resolve(code ?? 1));
child.stdin!.on("error", () => {});
child.stdin!.end(bytes);
let observing = true;
let admitted = false;
let prefix = "";
const timer = setTimeout(() => {
  console.error("AdmissionTimeout: execution may have accepted the request");
  Deno.exit(1);
}, seconds * 1000);
try {
  for await (const chunk of child.stdout!) {
    if (!admitted) {
      prefix += new TextDecoder().decode(chunk);
      const end = prefix.indexOf("\n");
      if ((end === -1 ? prefix.length : end + 1) > frameBytes) throw new Error("TransportLimit");
      if (end !== -1) {
        admitted = true;
        clearTimeout(timer);
      }
    }
    if (observing) {
      try {
        let offset = 0;
        while (offset < chunk.length) offset += await Deno.stdout.write(chunk.subarray(offset));
      } catch {
        observing = false;
      }
    }
  }
  Deno.exitCode = await status.promise;
} finally {
  clearTimeout(timer);
}
