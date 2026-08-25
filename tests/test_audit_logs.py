import json
import re
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[1]
REQUIRED_FIELDS = {
	"request_id",
	"user_id",
	"customer_id",
	"conversation_id",
	"request_body",
	"resp_body",
}
FORBIDDEN_FIELDS = {"authorization", "token", "provost_token"}
FLUENT_ACCESS_FIELDS = {
	"pri",
	"host",
	"ident",
	"stream_tag",
	"log_type",
	"Region",
	"Instance_ID",
	"message",
}
FLUENT_ERROR_FIELDS = {"pri", "host", "ident", "Region", "Instance_ID"}


def extract_access_fields(config: str) -> set[str]:
	match = re.search(
		r"log_format\s+json_full\s+escape=json\s*(.*?)\s*;",
		config,
		re.DOTALL,
	)
	assert match, "log_format json_full escape=json block not found"
	return set(re.findall(r'"([a-z_]+)"\s*:', match.group(1)))


def extract_error_fields(audit_lua: str) -> set[str]:
	match = re.search(
		r"function\s+_M\.emit\(.*?local fields\s*=\s*\{(.*?)\n\s*\}",
		audit_lua,
		re.DOTALL,
	)
	assert match, "ordered fields table in audit_error.emit() not found"
	return set(re.findall(r'\{\s*"([a-z_]+)"\s*,', match.group(1)))


def test_access_and_error_audit_schemas() -> None:
	config = (ROOT_DIR / "default.conf").read_text(encoding="utf-8")
	audit_lua = (ROOT_DIR / "lua" / "audit_error.lua").read_text(encoding="utf-8")

	schemas = {
		"access": extract_access_fields(config),
		"error": extract_error_fields(audit_lua),
	}

	for schema_name, fields in schemas.items():
		assert REQUIRED_FIELDS <= fields, (
			f"{schema_name} schema missing fields: {sorted(REQUIRED_FIELDS - fields)}"
		)
		assert FORBIDDEN_FIELDS.isdisjoint(fields), (
			f"{schema_name} schema exposes forbidden fields: "
			f"{sorted(FORBIDDEN_FIELDS & fields)}"
		)


def test_emitters_exactly_match_immutable_schema_requirements() -> None:
	config = (ROOT_DIR / "default.conf").read_text(encoding="utf-8")
	audit_lua = (ROOT_DIR / "lua" / "audit_error.lua").read_text(encoding="utf-8")
	access_schema = json.loads(
		(ROOT_DIR / "schemas" / "access_log_schema.json").read_text(encoding="utf-8")
	)
	error_schema = json.loads(
		(ROOT_DIR / "schemas" / "error_log_schema.json").read_text(encoding="utf-8")
	)

	assert access_schema["additionalProperties"] is False
	assert error_schema["additionalProperties"] is False
	assert set(access_schema["required"]) == extract_access_fields(config) | FLUENT_ACCESS_FIELDS
	assert set(error_schema["required"]) == extract_error_fields(audit_lua) | FLUENT_ERROR_FIELDS


def test_local_outputs_are_complete_json_lines() -> None:
	nginx_config = (ROOT_DIR / "default.conf").read_text(encoding="utf-8")
	output = (
		ROOT_DIR / "fluent-bit" / "conf.d" / "output-local-file.conf"
	).read_text(encoding="utf-8")
	local_copy = (
		ROOT_DIR / "fluent-bit" / "conf.d" / "filter-local-copy.conf"
	).read_text(encoding="utf-8")
	fluent_config = (
		ROOT_DIR / "fluent-bit" / "fluent-bit.conf"
	).read_text(encoding="utf-8")
	enrich = (
		ROOT_DIR / "fluent-bit" / "conf.d" / "filter-enrich.conf"
	).read_text(encoding="utf-8")

	assert output.count("Template  {schema_json}") == 2
	assert "tag=provost_llm_to_mcp_access json_full" in nginx_config
	assert "access_log /dev/stdout json_full;" in nginx_config
	assert "error_log /dev/stderr warn;" in nginx_config
	assert "Match     provost.local.access" in output
	assert "Match     provost.local.error" in output
	assert "Match         provost.local.*" in local_copy
	assert "Script        /fluent-bit/etc/lua/encode_record.lua" in local_copy
	assert "@INCLUDE conf.d/filter-local-copy.conf" in fluent_config
	assert "Remove                pid" in enrich


def test_streaming_access_input_uses_internal_json_transport() -> None:
	input_config = (
		ROOT_DIR / "fluent-bit" / "conf.d" / "input-tcp-audit.conf"
	).read_text(encoding="utf-8")
	audit_access = (ROOT_DIR / "lua" / "audit_access.lua").read_text(encoding="utf-8")
	compose = (ROOT_DIR / "docker-compose.yml").read_text(encoding="utf-8")

	assert "Tag           provost.direct" in input_config
	assert "Port          5141" in input_config
	assert "Format        json" in input_config
	assert 'host = "fluent-bit"' in audit_access
	assert "port = 5141" in audit_access
	assert 'log_type = "access"' in audit_access
	assert "function _M.emit_error" in audit_access
	assert '"5141:' not in compose