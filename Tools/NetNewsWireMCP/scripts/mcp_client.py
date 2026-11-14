"""Minimal MCP stdio client used by the acceptance scripts.

It speaks newline-delimited JSON-RPC over stdin/stdout, which is exactly the
transport contract of the server. Every line read from stdout must be valid
JSON; a non-JSON line fails immediately, so the scripts also prove that logs
never leak into stdout.
"""

from __future__ import annotations

import json
import os
import queue
import subprocess
import sys
import threading
from pathlib import Path


def default_binary() -> str:
    package = Path(__file__).resolve().parent.parent
    for configuration in ("release", "debug"):
        candidate = package / ".build" / configuration / "NetNewsWireMCP"
        if candidate.exists():
            return str(candidate)
    raise SystemExit(
        "找不到 NetNewsWireMCP 构建产物；先运行 "
        "`swift build -c release --package-path Tools/NetNewsWireMCP`"
    )


class MCPClient:
    def __init__(self, binary: str, environment: dict[str, str] | None = None):
        env = os.environ.copy()
        if environment:
            env.update(environment)
        self.process = subprocess.Popen(
            [binary],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=env,
        )
        self._stdout_lines: queue.Queue[str | None] = queue.Queue()
        self._stderr_lines: list[str] = []
        self._stdout_thread = threading.Thread(target=self._read_stdout, daemon=True)
        self._stderr_thread = threading.Thread(target=self._read_stderr, daemon=True)
        self._stdout_thread.start()
        self._stderr_thread.start()
        self._next_id = 1

    def _read_stdout(self) -> None:
        assert self.process.stdout is not None
        for line in self.process.stdout:
            self._stdout_lines.put(line)
        self._stdout_lines.put(None)

    def _read_stderr(self) -> None:
        assert self.process.stderr is not None
        for line in self.process.stderr:
            self._stderr_lines.append(line.rstrip("\n"))

    def _read_message(self, timeout: float) -> dict:
        try:
            line = self._stdout_lines.get(timeout=timeout)
        except queue.Empty:
            raise TimeoutError(
                f"等待 MCP 响应超时（{timeout}s）；stderr:\n{self.stderr_text()}"
            ) from None
        if line is None:
            raise RuntimeError(
                f"服务端提前关闭 stdout；stderr:\n{self.stderr_text()}"
            )
        try:
            message = json.loads(line)
        except json.JSONDecodeError as error:
            raise RuntimeError(f"stdout 出现非 JSON 行：{line!r}（{error}）") from None
        return message

    def send(self, message: dict) -> None:
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(message, ensure_ascii=False) + "\n")
        self.process.stdin.flush()

    def request(self, method: str, params: dict | None = None, timeout: float = 60) -> dict:
        request_id = self._next_id
        self._next_id += 1
        message = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)
        while True:
            response = self._read_message(timeout)
            if response.get("id") != request_id:
                continue
            if "error" in response:
                raise RuntimeError(f"{method} 返回 JSON-RPC 错误：{response['error']}")
            return response

    def notify(self, method: str, params: dict | None = None) -> None:
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)

    def initialize(self, protocol_version: str = "2025-06-18") -> dict:
        response = self.request(
            "initialize",
            {
                "protocolVersion": protocol_version,
                "capabilities": {},
                "clientInfo": {"name": "nnw-mcp-acceptance", "version": "1.0.0"},
            },
        )
        self.notify("notifications/initialized")
        return response

    def list_tools(self) -> dict:
        return self.request("tools/list", {})

    def call_tool(self, name: str, arguments: dict | None = None, timeout: float = 60) -> dict:
        params: dict = {"name": name}
        if arguments is not None:
            params["arguments"] = arguments
        return self.request("tools/call", params, timeout=timeout)

    def stderr_text(self) -> str:
        return "\n".join(self._stderr_lines)

    def close(self) -> str:
        try:
            if self.process.stdin:
                self.process.stdin.close()
        except OSError:
            pass
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=10)
        self._stdout_thread.join(timeout=5)
        self._stderr_thread.join(timeout=5)
        return self.stderr_text()

    def __enter__(self) -> "MCPClient":
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        self.close()


def tool_text(result: dict) -> str:
    return result["result"]["content"][0]["text"]


def run_startup(binary: str, environment: dict[str, str], timeout: float = 30):
    """Starts the server with EOF on stdin and captures the startup result."""
    env = os.environ.copy()
    env.update(environment)
    return subprocess.run(
        [binary],
        input="",
        capture_output=True,
        text=True,
        timeout=timeout,
        env=env,
    )


if __name__ == "__main__":
    print(default_binary())
    sys.exit(0)
