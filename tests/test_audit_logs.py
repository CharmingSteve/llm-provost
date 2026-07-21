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