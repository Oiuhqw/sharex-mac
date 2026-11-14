#!/usr/bin/env python3
"""Stand in for the Anthropic and OpenAI model endpoints on loopback.

The client harness points Claude Code and Codex at this server. The server
records each request body, so the harness can read the tool names that each
client offers a model. An Anthropic Messages request gets a fixed script: call
targets_list, call screenshot on the target named by --target-name, then stop.
Every other model request gets HTTP 500. The server binds 127.0.0.1 only, sends
nothing off the machine, and needs no credential.
"""

import argparse
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading


LOOPBACK = "127.0.0.1"
DONE = "STANDIN_DONE"
TOOL_NOT_OFFERED = "STANDIN_TOOL_NOT_OFFERED"
TARGETS_UNREADABLE = "STANDIN_COULD_NOT_READ_TARGETS"
TARGET_MISSING = "STANDIN_TARGET_NOT_FOUND"


def tool_results(body):
    found = []
    for message in body.get("messages", []):
        content = message.get("content") if isinstance(message, dict) else None
        for block in content if isinstance(content, list) else []:
            if isinstance(block, dict) and block.get("type") == "tool_result":
                inner = block.get("content")
                found.append(inner if isinstance(inner, str) else "".join(
                    part.get("text", "") for part in inner or [] if isinstance(part, dict)))
    return found


def offered_tool(body, name):
    names = [tool.get("name", "") for tool in body.get("tools", []) if isinstance(tool, dict)]
    return next((offered for offered in names if "sharex" in offered.lower() and offered.endswith("__" + name)), None)


def scripted_step(body, target_name):
    results = tool_results(body)
    if not results:
        tool = offered_tool(body, "targets_list")
        return (tool, {}) if tool else (None, TOOL_NOT_OFFERED)
    if len(results) > 1:
        return None, DONE
    tool = offered_tool(body, "screenshot")
    if not tool:
        return None, TOOL_NOT_OFFERED
    try:
        targets = json.loads(results[0])["result"]["targets"]
    except (ValueError, KeyError, TypeError):
        return None, TARGETS_UNREADABLE
    token = next((target.get("token") for target in targets
                  if isinstance(target, dict) and target.get("name") == target_name), None)
    return (tool, {"target": token}) if token else (None, TARGET_MISSING)


def anthropic_message(body, target_name):
    tool, value = scripted_step(body, target_name)
    if tool:
        block = {"type": "tool_use", "id": f"toolu_standin_{len(tool_results(body)) + 1}", "name": tool, "input": value}
    else:
        block = {"type": "text", "text": value}
    return {"id": "msg_standin", "type": "message", "role": "assistant", "model": body.get("model", "standin"),
            "content": [block], "stop_reason": "tool_use" if tool else "end_turn", "stop_sequence": None,
            "usage": {"input_tokens": 10, "output_tokens": 5,
                      "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}


def anthropic_events(message):
    block = message["content"][0]
    if block["type"] == "tool_use":
        opened = dict(block, input={})
        delta = {"type": "input_json_delta", "partial_json": json.dumps(block["input"])}
    else:
        opened = {"type": "text", "text": ""}
        delta = {"type": "text_delta", "text": block["text"]}
    return [{"type": "message_start", "message": dict(message, content=[], stop_reason=None)},
            {"type": "content_block_start", "index": 0, "content_block": opened},
            {"type": "content_block_delta", "index": 0, "delta": delta},
            {"type": "content_block_stop", "index": 0},
            {"type": "message_delta", "delta": {"stop_reason": message["stop_reason"], "stop_sequence": None},
             "usage": {"output_tokens": 5}},
            {"type": "message_stop"}]


def sse(events):
    return "".join(f"event: {event['type']}\ndata: {json.dumps(event)}\n\n" for event in events).encode()


def recorded_bodies(capture, path_suffix):
    if not Path(capture).is_file():
        return []
    rows = [json.loads(line) for line in Path(capture).read_text(encoding="utf-8").splitlines() if line.strip()]
    return [row["body"] for row in rows
            if row.get("method") == "POST" and row["path"].split("?")[0].endswith(path_suffix)]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, kind, payload):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self.server.record({"method": "GET", "path": self.path})
        self.reply(200, "application/json", b'{"data": []}')

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        try:
            body = json.loads(raw)
        except ValueError:
            body = {"unparsed": raw[:2000].decode("utf-8", "replace")}
        self.server.record({"method": "POST", "path": self.path, "body": body})
        path = self.path.split("?")[0]
        if path.endswith("/count_tokens"):
            self.reply(200, "application/json", b'{"input_tokens": 10}')
        elif path.endswith("/v1/messages") and isinstance(body, dict):
            message = anthropic_message(body, self.server.target_name)
            if body.get("stream"):
                self.reply(200, "text/event-stream", sse(anthropic_events(message)))
            else:
                self.reply(200, "application/json", json.dumps(message).encode())
        else:
            self.reply(500, "application/json", b'{"error": {"message": "The stand-in records this request only."}}')


class StandinServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, capture, target_name):
        super().__init__((LOOPBACK, 0), Handler)
        self.capture = Path(capture)
        self.target_name = target_name
        self.lock = threading.Lock()

    def record(self, entry):
        with self.lock, self.capture.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", type=Path, required=True)
    parser.add_argument("--ready", type=Path, required=True)
    parser.add_argument("--target-name", required=True)
    args = parser.parse_args()
    server = StandinServer(args.capture, args.target_name)
    host, port = server.server_address[:2]
    temporary = args.ready.with_name(args.ready.name + ".tmp")
    temporary.write_text(json.dumps({"host": host, "port": port}), encoding="utf-8")
    os.replace(temporary, args.ready)
    server.serve_forever()


if __name__ == "__main__":
    main()
