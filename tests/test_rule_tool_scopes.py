"""Configuration contracts; --live also checks the running upstream MCP servers."""

import copy
import io
import json
from pathlib import Path
import re
import sys
import unittest
from unittest.mock import patch
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
# These shipped global examples are not tied to a particular MCP server.
# New tool policies belong under mcp_servers so discovery can verify their scope.
GLOBAL_RULES = {
    "tool_allowlist", "tool_blocklist", "rate_limits", "token_caps",
    "time_based_rules", "logging_rules", "llm_rules",
}


def configured_scopes(config):
    unexpected = set(config) - GLOBAL_RULES - {"mcp_servers"}
    assert not unexpected, (
        f"Put new tool rules under mcp_servers with params.apply_to_tools: {sorted(unexpected)}"
    )
    scopes = {}
    for server, rules in config["mcp_servers"].items():
        scopes[server] = {}
        for name, rule in rules.items():
            location = f"mcp_servers.{server}.{name}"
            params = rule.get("params", {})
            if name == "forbidden_endpoints":
                # REST method/path selectors are not MCP tool names.
                endpoints = params.get("tools")
                assert isinstance(endpoints, list) and endpoints, location
                assert all(isinstance(item, str) and re.fullmatch(
                    r"(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) /[^ ]*", item
                ) for item in endpoints), location
                continue
            selector = "tools" if name in {"tool_allowlist", "tool_blocklist"} else "apply_to_tools"
            tools = params.get(selector)
            assert isinstance(tools, list), f"{location}: params.{selector} must be a list"
            # An explicitly disabled allow/blocklist may intentionally be empty.
            assert tools or (
                selector == "tools" and rule.get("enabled") is False
            ), f"{location}: params.{selector} must explicitly name tools"
            assert all(isinstance(tool, str) and tool.strip() == tool and tool
                       for tool in tools), f"{location}: invalid tool name"
            assert len(tools) == len(set(tools)), f"{location}: duplicate tool names"
            scopes[server][name] = set(tools)
    return scopes


def validate_available_tools(scopes, available):
    for server, rules in scopes.items():
        assert server in available, f"{server}: no upstream tool discovery result"
        for name, tools in rules.items():
            missing = tools - available[server]
            assert not missing, (
                f"mcp_servers.{server}.{name}: tools renamed, withdrawn or misspelled: "
                f"{sorted(missing)}"
            )


def discover_tools(url):
    """Query upstream directly: proxy-filtered discovery could hide blocked tools."""
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}

    def rpc(method, params, request_id):
        payload = {"jsonrpc": "2.0", "method": method, "params": params}
        if request_id is not None:
            payload["id"] = request_id
        request = Request(url, data=json.dumps(payload).encode(), headers=headers)
        with urlopen(request, timeout=45) as response:
            session = response.headers.get("Mcp-Session-Id")
            if session:
                headers["Mcp-Session-Id"] = session
            if request_id is None:
                return None
            if "text/event-stream" in response.headers.get("Content-Type", ""):
                data = []
                for line in response:
                    line = line.decode().rstrip("\r\n")
                    if line.startswith("data:"):
                        data.append(line[5:].lstrip(" "))
                    elif not line and data:
                        message = json.loads("\n".join(data))
                        data = []
                        if message.get("id") == request_id:
                            break
                else:
                    raise AssertionError(f"{url}: no RPC result for {method}")
            else:
                message = json.load(response)
            assert message.get("id") == request_id and "result" in message, (
                f"{url}: {method} failed: {message}"
            )
            return message["result"]

    initialized = rpc("initialize", {
        "protocolVersion": "2025-03-26", "capabilities": {},
        "clientInfo": {"name": "provost-rule-contract", "version": "1.0"},
    }, 1)
    headers["MCP-Protocol-Version"] = initialized["protocolVersion"]
    rpc("notifications/initialized", {}, None)
    tools, cursors, params = set(), set(), {}
    while True:
        result = rpc("tools/list", params, 2)
        for tool in result["tools"]:
            assert isinstance(tool["name"], str) and tool["name"], f"{url}: invalid tool name"
            tools.add(tool["name"])
        cursor = result.get("nextCursor")
        if not cursor:
            break
        assert cursor not in cursors, f"{url}: repeated tools/list cursor"
        cursors.add(cursor)
        params = {"cursor": cursor}
    assert tools, f"{url}: tools/list returned no tools"
    return tools


class RuleToolScopeTests(unittest.TestCase):
    def setUp(self):
        self.config = json.loads((ROOT / "rules.json").read_text())

    def test_shipped_rules_have_explicit_scopes(self):
        configured_scopes(self.config)

    def test_new_rules_require_nonempty_explicit_scope_even_when_disabled(self):
        for enabled in (True, False):
            for params in ({}, {"apply_to_tools": []}, {"apply_to_tools": "create"},
                           {"apply_to_tools": [""]}, {"apply_to_tools": [None]}):
                with self.subTest(enabled=enabled, params=params):
                    config = copy.deepcopy(self.config)
                    config["mcp_servers"]["fhir"]["future_rule"] = {
                        "enabled": enabled, "params": params,
                    }
                    with self.assertRaisesRegex(AssertionError, "future_rule"):
                        configured_scopes(config)

    def test_existing_rules_cannot_drop_their_scope(self):
        for server, rules in self.config["mcp_servers"].items():
            for name, rule in rules.items():
                if "apply_to_tools" not in rule["params"]:
                    continue
                with self.subTest(server=server, rule=name):
                    config = copy.deepcopy(self.config)
                    del config["mcp_servers"][server][name]["params"]["apply_to_tools"]
                    with self.assertRaisesRegex(AssertionError, name):
                        configured_scopes(config)

    def test_new_global_rule_cannot_avoid_server_scoping(self):
        self.config["future_rule"] = {"enabled": True, "params": {}}
        with self.assertRaisesRegex(AssertionError, "future_rule"):
            configured_scopes(self.config)

    def test_tool_inventory_accepts_current_names(self):
        scopes = configured_scopes(self.config)
        available = {
            server: set().union(*rules.values()) for server, rules in scopes.items()
        }
        validate_available_tools(scopes, available)
        for server, tools in available.items():
            for tool in tools:
                for replacement in (set(), {tool + "_renamed"}):
                    with self.subTest(server=server, tool=tool, replacement=replacement):
                        changed = copy.deepcopy(available)
                        changed[server] = (tools - {tool}) | replacement
                        with self.assertRaisesRegex(AssertionError, tool):
                            validate_available_tools(scopes, changed)

    def test_renamed_withdrawn_or_wrong_server_tools_fail(self):
        scopes = {"fhir": {"example": {"create"}}}
        for available in ({"fhir": {"create_v2"}}, {"fhir": set()},
                          {"fhir": {"CREATE"}}, {"alpaca": {"create"}}):
            with self.subTest(available=available):
                with self.assertRaises(AssertionError):
                    validate_available_tools(scopes, available)

    def test_discovery_handles_json_sse_sessions_and_pagination(self):
        for content_type in ("application/json", "text/event-stream"):
            with self.subTest(content_type=content_type):
                replies = []
                for request_id, result in (
                    (1, {"protocolVersion": "2025-03-26"}),
                    (None, None),
                    (2, {"tools": [{"name": "create"}], "nextCursor": "page-2"}),
                    (2, {"tools": [{"name": "read"}]}),
                ):
                    body = json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result})
                    if content_type == "text/event-stream":
                        body = f": keepalive\n\nevent: message\ndata: {body}\n\n"
                    response = io.BytesIO(body.encode())
                    response.headers = {
                        "Content-Type": content_type, "Mcp-Session-Id": "test-session",
                    }
                    replies.append(response)
                with patch(f"{__name__}.urlopen", side_effect=replies) as send:
                    self.assertEqual({"create", "read"}, discover_tools("http://mcp.test/mcp"))
                requests = [call.args[0] for call in send.call_args_list]
                payloads = [json.loads(request.data) for request in requests]
                self.assertEqual(
                    ["initialize", "notifications/initialized", "tools/list", "tools/list"],
                    [payload["method"] for payload in payloads],
                )
                self.assertNotIn("id", payloads[1])
                self.assertEqual({"cursor": "page-2"}, payloads[-1]["params"])
                self.assertEqual("test-session", requests[-1].get_header("Mcp-session-id"))
                self.assertEqual("2025-03-26", requests[-1].get_header("Mcp-protocol-version"))

    def test_discovery_errors_are_failures_not_empty_inventories(self):
        response = io.BytesIO(json.dumps({
            "jsonrpc": "2.0", "id": 1, "error": {"code": -32603, "message": "unavailable"},
        }).encode())
        response.headers = {"Content-Type": "application/json"}
        with patch(f"{__name__}.urlopen", return_value=response):
            with self.assertRaisesRegex(AssertionError, "initialize failed"):
                discover_tools("http://mcp.test/mcp")


if __name__ == "__main__":
    if sys.argv[1:] == ["--live"]:
        config = json.loads(Path("/etc/nginx/rules.json").read_text())
        routes = json.loads(Path("/etc/nginx/mcp_routes/mcp_routes.json").read_text())
        scopes = configured_scopes(config)
        validate_available_tools(scopes, {
            server: discover_tools(routes[server]) for server in scopes
        })
        print("All configured MCP rule tools exist in upstream tools/list")
    else:
        unittest.main()
