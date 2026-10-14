import base64
import json
import os
import pathlib
import shutil
import subprocess
import time

root = pathlib.Path(__file__).resolve().parents[1]
state = root / "tests" / ".state"
state.mkdir()
command = [str(root / "dist" / ("agent.exe" if os.name == "nt" else "agent")), "spawn", "1048576", "32", "3"]
environment = {**os.environ, "JANET_PATH": str(root.parent)}


def packet(entry, value, config=b""):
    return (json.dumps({"version": 1, "program": {"sourceDir": str(root), "entryModule": "tests/fixture.janet", "entry": entry},
                        "input": base64.b64encode(value).decode(), "config": base64.b64encode(config).decode(), "observe": True}) + "\n").encode()


try:
    result = subprocess.run(command, input=packet("echo", b"bytes\x00\xff"), env=environment, capture_output=True, timeout=10)
    frames = [json.loads(line) for line in result.stdout.splitlines()]
    assert result.returncode == 0 and frames[0]["type"] == "ready"
    assert frames[1]["type"] == "emit" and base64.b64decode(frames[-1]["output"]) == b"bytes\x00\xff"
    assert b"raw output" in result.stderr
    destination = state / "nested"
    result = subprocess.run(command, input=packet("nested", b"nested", str(destination).encode()), env=environment, capture_output=True, timeout=10)
    assert json.loads(result.stdout.splitlines()[-1])["type"] == "result", result.stdout
    assert destination.read_bytes() == b"nested"
    destination = state / "independent"
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
    child.stdin.write(packet("finish", b"independent", str(destination).encode()))
    child.stdin.close()
    assert json.loads(child.stdout.readline())["type"] == "ready"
    child.kill()
    child.wait(timeout=5)
    until = time.monotonic() + 5
    while not destination.exists() and time.monotonic() < until:
        time.sleep(0.02)
    assert destination.read_bytes() == b"independent"
    child.stdout.close()
    child.stderr.close()
    for input in [b"{}\n{}\n", b"{\xff}\n", b"{}"]:
        result = subprocess.run(command, input=input, env=environment, capture_output=True, timeout=10)
        assert result.returncode != 0
    print("PA bytes, output separation, repeated await, observer death and malformed input passed")
finally:
    shutil.rmtree(state)
