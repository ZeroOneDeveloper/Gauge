#!/usr/bin/env python3
"""Read-only protocol smoke test. No existing credentials or profiles are accessed."""
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time

candidates = [
    "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
    "/Applications/Codex.app/Contents/Resources/codex",
    "/opt/homebrew/bin/codex",
    "/usr/local/bin/codex",
]
binary = next((p for p in candidates if os.access(p, os.X_OK)), None)
if not binary:
    raise SystemExit("Codex executable not found")

with tempfile.TemporaryDirectory(prefix="gauge-codex-smoke-") as home:
    env = dict(os.environ)
    for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_CONFIG", "CODEX_ACCESS_TOKEN"]:
        env.pop(key, None)
    env["CODEX_HOME"] = home
    process = subprocess.Popen(
        [binary, "app-server", "-c", 'cli_auth_credentials_store="keyring"', "-c", "analytics.enabled=false"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        cwd=home, env=env,
    )
    buffer = b""

    def send(message):
        process.stdin.write(json.dumps(message).encode() + b"\n")
        process.stdin.flush()

    def response(identifier):
        global buffer
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                payload = json.loads(line)
                if payload.get("id") == identifier:
                    assert "error" not in payload, "RPC error (details omitted)"
                    return payload["result"]
            ready, _, _ = select.select([process.stdout], [], [], 1)
            if ready:
                data = os.read(process.stdout.fileno(), 65536)
                if not data:
                    raise RuntimeError("Server exited before replying")
                buffer += data
        raise TimeoutError("Codex RPC timed out")

    try:
        send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "gauge", "title": "Gauge", "version": "1.0.0"}}})
        response(1)
        send({"method": "initialized", "params": {}})
        send({"id": 2, "method": "account/read", "params": {"refreshToken": False}})
        account = response(2)
        assert account.get("account") is None, "Temporary profile unexpectedly authenticated"
        assert not Path(home, "auth.json").exists(), "Unexpected file credential storage"
        print("PASS: initialize → initialized → account/read; isolated, signed out, keyring configured")
    finally:
        process.stdin.close()
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
