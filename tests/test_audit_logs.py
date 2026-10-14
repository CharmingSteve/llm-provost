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


def fluent_conf(name: str) -> str:
	return (ROOT_DIR / "fluent-bit" / "conf.d" / name).read_text(encoding="utf-8")


def test_local_outputs_are_complete_json_lines() -> None:
	nginx_config = (ROOT_DIR / "default.conf").read_text(encoding="utf-8")
	output = fluent_conf("output-local-file.conf")
	encode = fluent_conf("filter-encode.conf")
	fluent_config = (
		ROOT_DIR / "fluent-bit" / "fluent-bit.conf"
	).read_text(encoding="utf-8")
	enrich = fluent_conf("filter-enrich.conf")

	assert output.count("Template  {schema_json}") == 2
	assert "tag=provost_llm_to_mcp_access json_full" in nginx_config
	assert "access_log /dev/stdout" not in nginx_config
	assert "error_log /dev/stderr warn;" in nginx_config
	assert "Match     provost.access.*" in output
	assert "Match     provost.error.*" in output
	assert "Script        /fluent-bit/etc/lua/encode_record.lua" in encode
	assert "@INCLUDE conf.d/filter-encode.conf" in fluent_config
	assert "filter-local-copy" not in fluent_config
	assert "Remove                pid" in enrich


def test_every_sink_receives_the_same_encoded_records() -> None:
	"""S3, the local file and the debug stdout tee share one tag and one encoding."""
	fluent_config = (ROOT_DIR / "fluent-bit" / "fluent-bit.conf").read_text(encoding="utf-8")
	debug_config = (ROOT_DIR / "fluent-bit" / "fluent-bit-debug.conf").read_text(encoding="utf-8")
	encode = fluent_conf("filter-encode.conf")
	sinks = {
		name: fluent_conf(name)
		for name in ("output-s3.conf", "output-local-file.conf", "output-stdout-debug.conf")
	}

	includes = re.findall(r"@INCLUDE conf\.d/(\S+)", fluent_config)
	assert includes.index("filter-append-hour.conf") < includes.index("filter-encode.conf")
	assert includes.index("filter-encode.conf") < includes.index("output-local-file.conf")
	for pattern in ("provost.access.*", "provost.error.*"):
		assert re.search(rf"Match\s+{re.escape(pattern)}\n", encode)
		for name, config in sinks.items():
			assert re.search(rf"Match\s+{re.escape(pattern)}\n", config), (name, pattern)
	assert sinks["output-s3.conf"].count("log_key               schema_json") == 2
	assert sinks["output-stdout-debug.conf"].count("Template  {schema_json}") == 2
	assert "output-stdout-debug.conf" not in fluent_config
	assert "@INCLUDE fluent-bit.conf" in debug_config
	assert "@INCLUDE conf.d/output-stdout-debug.conf" in debug_config


def test_access_records_are_ingested_once_from_the_access_files() -> None:
	nginx_config = (ROOT_DIR / "default.conf").read_text(encoding="utf-8")
	inputs = fluent_conf("input-syslog.conf")
	tail_filter = fluent_conf("filter-access-tail.conf")
	rewrite = fluent_conf("filter-rewrite-tag.conf")

	assert "access_log /var/run/provost/llm-access.log json_full;" in nginx_config
	assert "access_log /var/run/provost/mcp-api-access.log json_full;" in nginx_config
	assert "Path                  /var/run/provost/llm-access.log" in inputs
	assert "Path                  /var/run/provost/mcp-api-access.log" in inputs
	assert inputs.count("Key                   message") == 2
	assert "Record        ident provost_llm_to_mcp_access" in tail_filter
	assert "Record        ident provost_mcp_to_api_access" in tail_filter
	assert "Rule          $log_type ^access$ provost.access false" in tail_filter
	# Syslog access copies are not re-tagged; error-log audit lines still are.
	assert "provost.access true" not in rewrite
	assert "Rule                  message .*PROVOST_AUDIT_ERROR.* provost.error true" in rewrite


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