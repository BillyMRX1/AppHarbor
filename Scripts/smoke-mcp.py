#!/usr/bin/env python3
"""Exercise AppHarborMCP's stdio protocol without displaying inventory data."""

from __future__ import annotations

import json
import os
import selectors
import subprocess
import sys
import time
from collections import deque
from pathlib import Path
from typing import Any


PROTOCOL_VERSION = "2025-11-25"
REQUEST_TIMEOUT_SECONDS = 8.0
MAX_STDOUT_LINE_BYTES = 1_048_576
MAX_STDERR_BYTES = 65_536


class SmokeError(Exception):
    pass


class MCPProcess:
    def __init__(self, executable: Path) -> None:
        self.process = subprocess.Popen(
            [str(executable)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        assert self.process.stdin and self.process.stdout and self.process.stderr
        self.stdin = self.process.stdin
        self.stdout = self.process.stdout
        self.stderr = self.process.stderr
        self.selector = selectors.DefaultSelector()
        self.stdout_fd = self.stdout.fileno()
        self.stderr_fd = self.stderr.fileno()
        os.set_blocking(self.stdout_fd, False)
        os.set_blocking(self.stderr_fd, False)
        self.selector.register(self.stdout_fd, selectors.EVENT_READ, "stdout")
        self.selector.register(self.stderr_fd, selectors.EVENT_READ, "stderr")
        self.stdout_buffer = bytearray()
        self.stderr_size = 0
        self.lines: deque[bytes] = deque()
        self.next_id = 1
        self.selector_closed = False

    def send(self, message: dict[str, Any]) -> None:
        if self.process.poll() is not None:
            raise SmokeError("MCP helper exited before completing the exchange.")
        try:
            encoded = json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode("utf-8") + b"\n"
            self.stdin.write(encoded)
            self.stdin.flush()
        except (BrokenPipeError, OSError) as exc:
            raise SmokeError("MCP helper closed its input unexpectedly.") from exc

    def notify(self, method: str, params: dict[str, Any] | None = None) -> None:
        message: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)

    def request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        request_id = self.next_id
        self.next_id += 1
        message: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)
        deadline = time.monotonic() + REQUEST_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            for response in self._read_messages(deadline):
                if response.get("jsonrpc") != "2.0":
                    raise SmokeError("MCP helper emitted a non-JSON-RPC message.")
                if "id" not in response:
                    # Server notifications do not carry inventory data in this handshake.
                    continue
                if response.get("id") != request_id:
                    raise SmokeError("MCP helper returned an unexpected request ID.")
                return response
        raise SmokeError(f"Timed out waiting for the MCP {method} response.")

    def _read_messages(self, deadline: float) -> list[dict[str, Any]]:
        messages: list[dict[str, Any]] = []
        while self.lines:
            messages.append(self._decode_line(self.lines.popleft()))
        if messages:
            return messages

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return []
        for key, _ in self.selector.select(remaining):
            try:
                data = os.read(key.fd, 16_384)
            except BlockingIOError:
                continue
            if not data:
                try:
                    self.selector.unregister(key.fd)
                except KeyError:
                    pass
                if key.data == "stdout" and self.stdout_buffer:
                    raise SmokeError("MCP helper closed stdout with an incomplete message.")
                continue

            if key.data == "stderr":
                # Drain diagnostics to avoid blocking the child, but never display them.
                self.stderr_size = min(MAX_STDERR_BYTES, self.stderr_size + len(data))
                continue

            self.stdout_buffer.extend(data)
            if len(self.stdout_buffer) > MAX_STDOUT_LINE_BYTES and b"\n" not in self.stdout_buffer:
                raise SmokeError("MCP helper emitted an oversized stdio message.")
            while b"\n" in self.stdout_buffer:
                line, _, rest = self.stdout_buffer.partition(b"\n")
                self.stdout_buffer = bytearray(rest)
                if len(line) > MAX_STDOUT_LINE_BYTES:
                    raise SmokeError("MCP helper emitted an oversized stdio message.")
                if line.strip():
                    self.lines.append(line)
        while self.lines:
            messages.append(self._decode_line(self.lines.popleft()))
        return messages

    @staticmethod
    def _decode_line(line: bytes) -> dict[str, Any]:
        try:
            message = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise SmokeError("MCP helper emitted invalid JSON on stdout.") from exc
        if not isinstance(message, dict):
            raise SmokeError("MCP helper emitted a non-object JSON-RPC message.")
        return message

    def close(self) -> None:
        if not self.stdin.closed:
            self.stdin.close()
        forced = False
        try:
            return_code = self.process.wait(timeout=3.0)
        except subprocess.TimeoutExpired:
            forced = True
            self.process.terminate()
            try:
                return_code = self.process.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                self.process.kill()
                return_code = self.process.wait(timeout=1.0)
        self._close_io()
        if forced:
            raise SmokeError("MCP helper did not exit after stdin EOF; it was stopped after the timeout.")
        if return_code != 0:
            raise SmokeError(f"MCP helper exited with status {return_code} after stdin EOF.")

    def abort(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=1.0)
        self._close_io()

    def _close_io(self) -> None:
        if not self.selector_closed:
            self.selector.close()
            self.selector_closed = True
        for stream in (self.stdout, self.stderr):
            if not stream.closed:
                stream.close()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SmokeError(message)


def require_result(response: dict[str, Any], *, label: str) -> dict[str, Any]:
    require("error" not in response, f"MCP {label} returned a JSON-RPC error.")
    result = response.get("result")
    require(isinstance(result, dict), f"MCP {label} did not return an object result.")
    return result


def tool_error_text(result: dict[str, Any]) -> str:
    content = result.get("content")
    require(isinstance(content, list), "Tool error did not contain a content list.")
    texts = [item.get("text", "") for item in content if isinstance(item, dict) and item.get("type") == "text"]
    return "\n".join(value for value in texts if isinstance(value, str))


def require_rejected(
    client: MCPProcess,
    name: str,
    arguments: Any,
    expected_error: str,
) -> None:
    response = client.request("tools/call", {"name": name, "arguments": arguments})
    result = require_result(response, label=f"invalid {name}")
    require(result.get("isError") is True, f"Invalid {name} call was not marked as an error.")
    require(expected_error.lower() in tool_error_text(result).lower(), f"Invalid {name} did not fail validation as expected.")


def validate_tools(tools: Any) -> None:
    expected: dict[str, tuple[dict[str, str], set[str], dict[str, bool]]] = {
        "appharbor_list_installations": (
            {"query": "string", "offset": "integer", "limit": "integer"},
            set(),
            {"readOnlyHint": True, "openWorldHint": False},
        ),
        "appharbor_list_sources": ({}, set(), {"readOnlyHint": True, "openWorldHint": False}),
        "appharbor_get_installation": (
            {"installation_id": "string"},
            {"installation_id"},
            {"readOnlyHint": True, "openWorldHint": False},
        ),
        "appharbor_refresh_inventory": (
            {},
            set(),
            {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": False, "openWorldHint": True},
        ),
        "appharbor_request_removal": (
            {"installation_id": "string", "request_id": "string"},
            {"installation_id", "request_id"},
            {"readOnlyHint": False, "destructiveHint": True, "idempotentHint": True, "openWorldHint": True},
        ),
        "appharbor_request_update": (
            {"installation_id": "string", "request_id": "string"},
            {"installation_id", "request_id"},
            {"readOnlyHint": False, "destructiveHint": True, "idempotentHint": True, "openWorldHint": True},
        ),
        "appharbor_get_request_status": (
            {"request_id": "string"},
            {"request_id"},
            {"readOnlyHint": True, "openWorldHint": False},
        ),
    }
    require(isinstance(tools, list), "tools/list did not return a tools array.")
    names = [tool.get("name") for tool in tools if isinstance(tool, dict)]
    require(len(names) == len(tools) and len(set(names)) == len(names), "tools/list contained malformed or duplicate entries.")
    require(set(names) == set(expected), "tools/list did not expose exactly the seven expected AppHarbor tools.")

    for tool in tools:
        assert isinstance(tool, dict)
        name = tool["name"]
        properties, required, annotations = expected[name]
        schema = tool.get("inputSchema")
        require(isinstance(schema, dict) and schema.get("type") == "object", f"{name} has no object input schema.")
        actual_properties = schema.get("properties")
        require(isinstance(actual_properties, dict), f"{name} has no properties object.")
        require(set(actual_properties) == set(properties), f"{name} exposes unexpected input properties.")
        for property_name, property_type in properties.items():
            definition = actual_properties[property_name]
            require(isinstance(definition, dict) and definition.get("type") == property_type,
                    f"{name}.{property_name} has the wrong input type.")
        actual_required = schema.get("required", [])
        require(isinstance(actual_required, list) and set(actual_required) == required and len(actual_required) == len(required),
                f"{name} has an incorrect required-field list.")
        require(schema.get("additionalProperties") is False, f"{name} does not reject additional input fields.")
        actual_annotations = tool.get("annotations")
        require(isinstance(actual_annotations, dict) and actual_annotations == annotations,
                f"{name} has unexpected safety annotations.")


def run_smoke(executable: Path) -> None:
    client = MCPProcess(executable)
    closed = False
    try:
        initialize = client.request(
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "appharbor-mcp-smoke", "version": "1.0"},
            },
        )
        result = require_result(initialize, label="initialize")
        require(result.get("protocolVersion") == PROTOCOL_VERSION, "MCP helper did not negotiate the supported protocol revision.")
        capabilities = result.get("capabilities")
        require(isinstance(capabilities, dict) and isinstance(capabilities.get("tools"), dict),
                "MCP helper did not advertise tool support.")
        client.notify("notifications/initialized")

        listed = require_result(client.request("tools/list"), label="tools/list")
        validate_tools(listed.get("tools"))

        require_rejected(client, "appharbor_unknown_tool", {}, "Unknown AppHarbor tool")
        require_rejected(client, "appharbor_list_sources", {"unexpected": True}, "Unknown tool argument")
        require_rejected(client, "appharbor_get_installation", {"installation_id": "invalid"}, "lowercase SHA-256")
        require_rejected(
            client,
            "appharbor_request_removal",
            {"installation_id": "0" * 64, "request_id": "not-a-uuid"},
            "request_id must be a UUID",
        )
        require_rejected(client, "appharbor_list_installations", {"offset": -1}, "offset must be a non-negative integer")
        require_rejected(client, "appharbor_list_installations", {"limit": 101}, "limit must be an integer from 1 to 100")
        require_rejected(client, "appharbor_list_installations", {"limit": "10"}, "limit must be an integer")
        require_rejected(client, "appharbor_get_installation", {}, "installation_id")

        malformed = client.request("tools/call", {"arguments": {}, "unexpected": "missing name"})
        require("error" in malformed and isinstance(malformed["error"], dict),
                "Malformed tools/call request was not rejected at the JSON-RPC boundary.")

        read = require_result(
            client.request("tools/call", {"name": "appharbor_list_sources", "arguments": {}}),
            label="read-only list_sources",
        )
        if read.get("isError") is True:
            error_text = tool_error_text(read).lower()
            require("open appharbor" in error_text and "try again" in error_text,
                    "An unavailable app did not return actionable guidance for a valid read request.")
            read_summary = "valid read returned actionable guidance because AppHarbor is unavailable"
        else:
            # Do not inspect or print the result: it may contain private inventory data.
            read_summary = "valid read succeeded; response payload was not displayed"

        client.close()
        closed = True
        print(f"MCP stdio smoke passed: handshake, seven tool schemas, validation rejections, {read_summary}, and clean EOF exit.")
    finally:
        if not closed:
            client.abort()


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("Usage: Scripts/smoke-mcp.py /absolute/path/to/AppHarborMCP", file=sys.stderr)
        return 2
    executable = Path(argv[1])
    if not executable.is_absolute():
        print("AppHarborMCP path must be absolute.", file=sys.stderr)
        return 2
    if not executable.is_file() or not os.access(executable, os.X_OK):
        print("AppHarborMCP must be an executable file.", file=sys.stderr)
        return 2
    try:
        run_smoke(executable)
    except (SmokeError, OSError, ValueError) as exc:
        # Error text is locally generated; never print helper stdout/stderr or tool data.
        print(f"MCP stdio smoke failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
