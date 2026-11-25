#!/usr/bin/env python3
"""Regression check for MCP stdio framing with a held-open stdin pipe."""

from __future__ import annotations

import json
import select
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / ".build" / "out" / "Products" / "Debug" / "paperdesk-mcp"


def read_line(process: subprocess.Popen[bytes], timeout: float = 3.0) -> dict:
    assert process.stdout is not None
    ready, _, _ = select.select([process.stdout], [], [], timeout)
    if not ready:
        raise AssertionError("MCP helper did not respond while stdin remained open")
    line = process.stdout.readline()
    if not line:
        stderr = process.stderr.read().decode(errors="replace") if process.stderr else ""
        raise AssertionError(f"MCP helper closed stdout unexpectedly: {stderr}")
    return json.loads(line)


def send(process: subprocess.Popen[bytes], message: dict) -> None:
    assert process.stdin is not None
    process.stdin.write((json.dumps(message, separators=(",", ":")) + "\n").encode())
    process.stdin.flush()


def main() -> None:
    helper = Path(sys.argv[1]).expanduser() if len(sys.argv) == 2 else HELPER
    if len(sys.argv) > 2:
        raise SystemExit("usage: check-mcp-stdio.py [PATH-TO-paperdesk-mcp]")
    if not helper.is_file():
        raise SystemExit(f"missing helper; build first: {helper}")

    with tempfile.TemporaryDirectory(prefix="paperdesk-mcp-", dir="/private/tmp") as temp_dir:
        process = subprocess.Popen(
            [str(helper), "--library", str(Path(temp_dir) / "library")],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            send(
                process,
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {
                        "protocolVersion": "2024-11-05",
                        "capabilities": {},
                        "clientInfo": {"name": "stdio-regression", "version": "1.0"},
                    },
                },
            )
            initialize = read_line(process)
            assert initialize.get("id") == 1, initialize
            assert initialize.get("result"), initialize

            send(process, {"jsonrpc": "2.0", "method": "notifications/initialized"})
            send(process, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
            tools = read_line(process)
            assert tools.get("id") == 2, tools
            assert tools.get("result", {}).get("tools"), tools
        finally:
            if process.stdin is not None:
                process.stdin.close()
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=3)

    print("MCP stdio held-open regression passed")


if __name__ == "__main__":
    main()
