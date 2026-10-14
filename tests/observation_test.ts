import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { Effect, Stream } from "effect";
import { spawn } from "../sdk/mod.ts";

Deno.test("closing SDK observation does not terminate accepted execution", async () => {
  const directory = fileURLToPath(new URL("../", import.meta.url));
  const output = Deno.cwd() + "/.observation-check";
  const encoder = new TextEncoder();
  try {
    await Effect.runPromise(Stream.runDrain(
      spawn(
        {
          program: { sourceDir: directory, entryModule: "tests/fixture.janet", entry: "finish" },
          limits: { frameBytes: 1048576, depth: 32, admissionSeconds: 3 },
          command: [directory + "dist/" + (Deno.build.os === "windows" ? "agent.exe" : "agent")],
          environment: { JANET_PATH: directory + "/.." },
        },
        encoder.encode("committed"),
        encoder.encode(output),
      ).pipe(Stream.take(1)),
    ));
    await new Promise((resolve) => setTimeout(resolve, 1000));
    assert.equal(await Deno.readTextFile(output), "committed");
  } finally {
    await Deno.remove(output);
  }
});
