import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
await Deno.mkdir(join(root, "dist"), { recursive: true });
const status = await new Deno.Command(Deno.execPath(), {
  cwd: root,
  args: [
    "compile",
    "--frozen",
    "--allow-read",
    "--allow-run",
    "--allow-env",
    "--output",
    join(root, "dist", Deno.build.os === "windows" ? "agent.exe" : "agent"),
    "src/launch.ts",
  ],
  stdin: "null",
  stdout: "inherit",
  stderr: "inherit",
}).spawn().status;
if (!status.success) throw new Error(`agent compilation exited ${status.code}`);
