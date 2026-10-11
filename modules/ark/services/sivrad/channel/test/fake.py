"""Stand-ins for what the channel talks to, for test/run.sh: Codex's
app-server on a unix socket (JSON-RPC 2.0, one message per line, no
`jsonrpc` field) and Kanidm's userinfo endpoint over HTTP. Standard
library only.

The agent answers by the second line of the turn's input:
  - "tool"   calls phone_tool over the channel's MCP endpoint (MCP_URL),
             then answers with the tool's result;
  - "files"  calls reply with a workspace file attached to a trusted
             Signal chat (which fails without signal-cli; the error text is
             the answer), then answers with a MEDIA: line;
  - "quiet"  answers [SILENT];
  - "fail"   fails the turn;
  - anything else echoes the input's header line.
Every turn also asks for a command approval first, which the channel must
decline.
"""

import json
import os
import socketserver
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.request import Request, urlopen

MCP_URL = os.environ["MCP_URL"]
LOG = os.environ["FAKE_LOG"]


def log(entry):
    with open(LOG, "a") as f:
        f.write(json.dumps(entry) + "\n")


def mcp(method, params, id=1):
    body = json.dumps({"jsonrpc": "2.0", "id": id, "method": method, "params": params}).encode()
    req = Request(MCP_URL, data=body, headers={"Content-Type": "application/json"}, method="POST")
    with urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def tool(name, arguments):
    r = mcp("tools/call", {"name": name, "arguments": arguments})
    return r["result"]["content"][0]["text"], bool(r["result"].get("isError"))


def answer_for(text):
    header = text.splitlines()[0]
    fields = dict(kv.split("=", 1) for kv in header.split()[1:])
    chat = fields["chat_id"]
    word = text.splitlines()[1].strip()
    if word == "fail":
        return None
    if word == "quiet":
        return "[SILENT]"
    if word == "tool":
        result, err = tool("phone_tool", {"chat_id": chat, "name": "set_timer", "arguments": {"seconds": 5}})
        return f"error: {result}" if err else f"timer: {result}"
    if word == "files":
        result, _ = tool("reply", {"chat_id": "signal:+15550000001", "text": "", "files": ["shot.png"]})
        return f"{result}\nMEDIA: shot.png"
    return header


class AppServer(socketserver.StreamRequestHandler):
    """One connection: one app-server."""

    counter = 0
    lock = threading.Lock()

    def say(self, message):
        self.wfile.write((json.dumps(message) + "\n").encode())
        self.wfile.flush()

    def handle(self):
        log({"connection": "open"})
        for raw in self.rfile:
            m = json.loads(raw)
            method, id = m.get("method"), m.get("id")
            if method is None:
                # the channel's answer to our approval request
                log({"approval": m.get("result")})
                continue
            params = m.get("params") or {}
            if method == "initialize":
                self.say({"id": id, "result": {"userAgent": "fake", "codexHome": "/nowhere"}})
            elif method == "initialized":
                pass
            elif method == "thread/start":
                with AppServer.lock:
                    AppServer.counter += 1
                    thread = f"thr_{AppServer.counter}"
                log({"thread/start": params})
                self.say({"id": id, "result": {"thread": {"id": thread}}})
                self.say({"method": "thread/started", "params": {"thread": {"id": thread}}})
            elif method == "thread/resume":
                log({"thread/resume": params["threadId"]})
                self.say({"id": id, "result": {"thread": {"id": params["threadId"]}}})
            elif method == "turn/start":
                text = params["input"][0]["text"]
                thread = params["threadId"]
                with AppServer.lock:
                    AppServer.counter += 1
                    turn = f"turn_{AppServer.counter}"
                log({"turn": turn, "thread": thread, "header": text.splitlines()[0]})
                self.say({"id": id, "result": {"turn": {"id": turn, "status": "inProgress"}}})
                self.say({"method": "turn/started", "params": {"turn": {"id": turn}}})
                self.say({"id": 9000, "method": "item/commandExecution/requestApproval",
                          "params": {"threadId": thread, "turnId": turn, "itemId": "i0", "command": ["rm", "-rf"]}})
                answer = answer_for(text)
                if answer is None:
                    self.say({"method": "error", "params": {"threadId": thread, "turnId": turn,
                                                            "error": {"message": "the model is out"}}})
                    self.say({"method": "turn/completed", "params": {"turn": {"id": turn, "status": "failed",
                                                                              "error": {"message": "the model is out"}}}})
                    continue
                self.say({"method": "item/completed", "params": {"threadId": thread, "turnId": turn,
                          "item": {"type": "agentMessage", "id": "i1", "text": "on it"}}})
                self.say({"method": "item/completed", "params": {"threadId": thread, "turnId": turn,
                          "item": {"type": "agentMessage", "id": "i2", "text": answer}}})
                self.say({"method": "turn/completed", "params": {"turn": {"id": turn, "status": "completed"}}})
            else:
                self.say({"id": id, "error": {"code": -32601, "message": f"unknown {method}"}})
        log({"connection": "closed"})


class Userinfo(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, payload):
        data = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        # Kanidm's userinfo: the bearer token is the username.
        if self.path == "/userinfo":
            auth = self.headers.get("Authorization", "")
            if not auth.startswith("Bearer ") or auth == "Bearer bad":
                return self.send(401, {"error": "invalid_token"})
            return self.send(200, {"preferred_username": auth[len("Bearer "):]})
        self.send(404, {})


class Threaded(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class ThreadedHttp(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    socket_path, port = sys.argv[1], int(sys.argv[2])
    app = Threaded(socket_path, AppServer)
    threading.Thread(target=app.serve_forever, daemon=True).start()
    ThreadedHttp(("127.0.0.1", port), Userinfo).serve_forever()
