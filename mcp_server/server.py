#!/usr/bin/env python3
import json
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


HOST = "0.0.0.0"
PORT = 8088


class MCPRequestHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_error(405, "Method Not Allowed")

    def do_POST(self):
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            request = json.loads(self.rfile.read(content_length))
        except (ValueError, json.JSONDecodeError):
            self._send_error(None, -32700, "Parse error")
            return

        if not isinstance(request, dict) or not request.get("method"):
            self._send_error(None, -32600, "Invalid Request")
            return

        method = request["method"]
        print(f"[mcp-server] {method} from {self.client_address}", flush=True)

        if method == "notifications/initialized" and "id" not in request:
            self.send_response(202)
            self.end_headers()
            return

        request_id = request.get("id")
        if method == "initialize":
            self._send_result(
                request_id,
                {
                    "protocolVersion": "2025-11-25",
                    "capabilities": {"tools": {}},
                    "serverInfo": {
                        "name": "llm-provost-dummy-mcp",
                        "version": "0.1.0",
                    },
                },
                session_id=str(uuid.uuid4()),
            )
            return

        if method == "tools/list":
            self._send_result(request_id, {"tools": self._tools()})
            return

        if method == "tools/call":
            self._call_tool(request_id, request.get("params", {}))
            return

        self._send_error(request_id, -32601, "Method not found")

    def _call_tool(self, request_id, params):
        if not isinstance(params, dict):
            self._send_error(request_id, -32600, "Invalid Request")
            return

        name = params.get("name")
        arguments = params.get("arguments", {})
        if not isinstance(arguments, dict):
            self._send_error(request_id, -32600, "Invalid Request")
            return

        if name == "identify_user":
            result = {"provost_user_id": arguments.get("name", "steve")}
        elif name == "identify_customer":
            result = {"customer_id": arguments.get("name", "craig")}
        else:
            self._send_error(request_id, -32601, "Method not found")
            return

        content = [{"type": "text", "text": json.dumps(result)}]
        self._send_result(request_id, {"content": content})

    @staticmethod
    def _tools():
        optional_name_schema = {
            "type": "object",
            "properties": {"name": {"type": "string"}},
        }
        return [
            {
                "name": "identify_user",
                "description": "Identifies the user from their introduction.",
                "inputSchema": optional_name_schema,
            },
            {
                "name": "identify_customer",
                "description": "Identifies the customer from the conversation.",
                "inputSchema": optional_name_schema,
            },
        ]

    def _send_result(self, request_id, result, session_id=None):
        response = {"jsonrpc": "2.0", "id": request_id, "result": result}
        self._send_json(response, session_id=session_id)

    def _send_error(self, request_id, code, message):
        response = {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": code, "message": message},
        }
        self._send_json(response)

    def _send_json(self, response, session_id=None):
        body = json.dumps(response).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if session_id:
            self.send_header("Mcp-Session-Id", session_id)
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    print(f"[mcp-server] Listening on {HOST}:{PORT}", flush=True)
    ThreadingHTTPServer((HOST, PORT), MCPRequestHandler).serve_forever()