"""Run inside llm-provost: deterministic FHIR REST mock, real WSO2 MCP server."""

import json
import os
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


PATIENT = {"resourceType": "Patient", "id": "provost-synthetic-ci", "active": True}
CONVERSATION_ID = "fhir-integration-" + uuid.uuid4().hex
CAPABILITIES = {
    "resourceType": "CapabilityStatement",
    "status": "active",
    "kind": "instance",
    "fhirVersion": "4.0.1",
    "format": ["json"],
    "rest": [{
        "mode": "server",
        "resource": [{
            "type": "Patient",
            "interaction": [{"code": "read"}, {"code": "search-type"}],
            "searchParam": [{"name": "_count", "type": "number"}],
        }],
    }],
}


class FHIRMock(BaseHTTPRequestHandler):
    calls = []

    def do_GET(self):
        self.calls.append((self.command, self.path))
        path = urlsplit(self.path).path.rstrip("/")
        if path == "/baseR4/metadata":
            payload = CAPABILITIES
        elif self.path.startswith("/baseR4/Patient?"):
            payload = {
                "resourceType": "Bundle", "type": "searchset", "total": 1,
                "entry": [{"resource": PATIENT}],
            }
        elif path == "/baseR4/Patient/provost-synthetic-ci":
            payload = PATIENT
        else:
            self.send_error(404)
            return
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/fhir+json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_args):
        pass


def request(url, body=None, method=None, user="fhir-ci"):
    headers = {
        "Accept": "application/json, text/event-stream",
        "Content-Type": "application/json",
        "X-Provost-Token": os.environ["PROVOST_TOKEN"],
        "X-Cognito-User": user,
        "X-Conversation-Id": CONVERSATION_ID,
    }
    data = None if body is None else json.dumps(body).encode()
    req = Request(url, data=data, headers=headers, method=method)
    try:
        with urlopen(req, timeout=45) as response:
            return response.status, json.loads(response.read())
    except HTTPError as error:
        return error.code, json.loads(error.read())


def rpc(method, params, request_id=1, user="fhir-ci"):
    return request("http://127.0.0.1:8000/mcp/fhir", {
        "jsonrpc": "2.0", "id": request_id, "method": method, "params": params,
    }, user=user)


def tool(name, arguments, request_id=2, user="fhir-ci"):
    return rpc("tools/call", {"name": name, "arguments": arguments}, request_id, user)


def tool_payload(response):
    result = response["result"]
    assert not result.get("isError"), response
    return result["structuredContent"]["result"]


def patients(payload):
    if isinstance(payload, list):
        return [patient for item in payload for patient in patients(item)]
    if isinstance(payload, dict):
        if payload.get("resourceType") == "Patient":
            return [payload]
        if payload.get("resourceType") == "Bundle":
            return patients([entry.get("resource", {}) for entry in payload.get("entry", [])])
    return []


def wait_for_audit(predicate, start_line, inbound=False):
    for _ in range(60):
        records = []
        for line in Path("/var/run/provost/llm-access.log").read_text().splitlines()[start_line:]:
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue
        if any(predicate(record) and (not inbound or (
            record.get("conversation_id") == CONVERSATION_ID
            and record.get("user_id") == "fhir-ci"
        )) for record in records):
            return
        time.sleep(0.5)
    raise AssertionError("Expected FHIR audit entry not found")


def main():
    live = "--live" in sys.argv
    start_line = len(Path("/var/run/provost/llm-access.log").read_text().splitlines())
    server = None
    if not live:
        server = ThreadingHTTPServer(("127.0.0.1", 18089), FHIRMock)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for attempt in range(60):
            try:
                status, initialized = rpc("initialize", {
                    "protocolVersion": "2025-03-26", "capabilities": {},
                    "clientInfo": {"name": "provost-fhir-ci", "version": "1.0"},
                })
                if status == 200 and "result" in initialized:
                    break
            except (URLError, TimeoutError):
                pass
            time.sleep(1)
        else:
            raise AssertionError("FHIR MCP initialize did not succeed")

        status, listed = rpc("tools/list", {})
        assert status == 200, listed
        names = {item["name"] for item in listed["result"]["tools"]}
        assert {"search", "read", "get_capabilities", "get_user",
                "create", "update", "delete"} <= names, names

        status, capabilities = tool("get_capabilities", {"type": "Patient"})
        assert status == 200 and tool_payload(capabilities).get("type") == "Patient", capabilities
        status, result = tool("search", {"type": "Patient", "searchParam": {"_count": "1"}})
        assert status == 200 and patients(tool_payload(result)), result

        if not live:
            assert patients(tool_payload(result)) == [PATIENT], result
            status, read = tool("read", {"type": "Patient", "id": PATIENT["id"]})
            assert status == 200 and tool_payload(read) == PATIENT, read
            assert any(urlsplit(path).path == "/baseR4/metadata"
                       for _, path in FHIRMock.calls), FHIRMock.calls
            assert any(path.startswith("/baseR4/Patient?") and "_count=1" in path
                       for _, path in FHIRMock.calls), FHIRMock.calls
            def concurrent_search(index):
                status, response = tool("search", {
                    "type": "Patient",
                    "searchParam": {"_count": "1", "_id": CONVERSATION_ID + "-" + str(index)},
                }, user="fhir-ci-" + str(index))
                assert status == 200 and patients(tool_payload(response)) == [PATIENT], response

            with ThreadPoolExecutor(max_workers=8) as pool:
                list(pool.map(concurrent_search, range(8)))
            for index in range(8):
                marker = CONVERSATION_ID + "-" + str(index)
                wait_for_audit(lambda record:
                               marker in record.get("request", "")
                               and int(record.get("status", 0)) == 200
                               and record.get("user_id") == "unknown", start_line)
            calls_before = list(FHIRMock.calls)

        for name in ("create", "update", "delete", "unapproved_tool"):
            status, denied = tool(name, {"type": "Patient", "id": PATIENT["id"],
                                        "payload": PATIENT}, 99)
            assert status == 403 and "allowlist" in denied.get("reason", ""), denied

        # The second boundary must also block direct REST writes, not just tools.
        for method in ("POST", "PUT", "PATCH", "DELETE"):
            status, denied = request("http://127.0.0.1:8081/fhir/Patient",
                                     PATIENT, method)
            assert status == 403 and "read-only" in denied["error"], denied
        if not live:
            assert calls_before == FHIRMock.calls, FHIRMock.calls

        wait_for_audit(lambda record:
                       record.get("request", "").startswith("GET /fhir/Patient?")
                       and int(record.get("status", 0)) == 200
                       and record.get("user_id") == "unknown"
                       and record.get("customer_id") == "unknown"
                       and record.get("conversation_id") == "none", start_line)
        wait_for_audit(lambda record:
                       "/mcp/fhir" in record.get("request", "")
                       and int(record.get("status", 0)) == 403
                       and "create" in record.get("request_body", ""), start_line, inbound=True)
        wait_for_audit(lambda record:
                       record.get("request", "").startswith("DELETE /fhir/Patient ")
                       and int(record.get("status", 0)) == 403, start_line)
        print("FHIR initialize/list/read, write denials, REST routing and audit passed")
    finally:
        if server:
            server.shutdown()


if __name__ == "__main__":
    main()
