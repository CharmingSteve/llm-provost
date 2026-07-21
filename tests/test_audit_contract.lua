local function read_file(path)
    local file = assert(io.open(path, "r"))
    local content = file:read("*a")
    file:close()
    return content
end

local function extract_fields(block)
    local fields = {}
    for field in block:gmatch('"([%a_]+)"%s*:') do
        fields[#fields + 1] = field
    end
    if #fields > 0 then
        return fields
    end
    for field in block:gmatch('{%s*"([%a_]+)"%s*,') do
        fields[#fields + 1] = field
    end
    return fields
end

local function load_with_environment(path, environment)
    local chunk
    if setfenv then
        chunk = assert(loadfile(path))
        setfenv(chunk, environment)
    else
        chunk = assert(loadfile(path, "t", environment))
    end
    return chunk()
end

describe("Phase 4 audit contract", function()
    local config = read_file("default.conf")
    local audit_lua = read_file("lua/audit_error.lua")
    local access_block = assert(config:match(
        "log_format%s+json_full%s+escape=json%s*(.-)'}';"
    ))
    local error_block = assert(audit_lua:match(
        "local fields%s*=%s*{(.-)\n%s*}"
    ))
    local access_fields = extract_fields(access_block)
    local error_fields = extract_fields(error_block)

    local expected_access_fields = {
        "time_local",
        "remote_addr",
        "request",
        "status",
        "body_bytes_sent",
        "request_time",
        "upstream_response_time",
        "request_id",
        "user_id",
        "customer_id",
        "conversation_id",
        "request_body",
        "resp_body",
    }
    local expected_error_fields = {
        "time_local",
        "remote_addr",
        "request",
        "status",
        "request_id",
        "user_id",
        "customer_id",
        "conversation_id",
        "request_body",
        "resp_body",
        "error_code",
        "error_detail",
        "stream_tag",
        "log_type",
        "date",
    }

    it("defines the complete access and error schemas in order", function()
        assert.same(expected_access_fields, access_fields)
        assert.same(expected_error_fields, error_fields)
    end)

    it("includes identity and body fields in both schemas", function()
        local required = {
            customer_id = true,
            conversation_id = true,
            request_body = true,
            resp_body = true,
        }
        for _, fields in ipairs({access_fields, error_fields}) do
            local present = {}
            for _, field in ipairs(fields) do
                present[field] = true
            end
            for field in pairs(required) do
                assert.is_true(present[field], field .. " is missing")
            end
        end
    end)

    it("does not expose authorization fields", function()
        for _, fields in ipairs({access_fields, error_fields}) do
            for _, field in ipairs(fields) do
                assert.not_equals("authorization", field:lower())
            end
        end
    end)

    it("captures request and response bodies with a bounded filter", function()
        assert.truthy(access_block:find('"request_body":"$req_body"', 1, true))
        assert.truthy(access_block:find('"resp_body":"$resp_body"', 1, true))
        assert.truthy(config:find('set $req_body "";', 1, true))
        assert.truthy(config:find('set $resp_body "";', 1, true))
        local v1_location = assert(config:match("location /v1/ {(.-)proxy_pass"))
        assert.truthy(v1_location:find("body_filter_by_lua_block", 1, true))
        assert.truthy(v1_location:find("local MAX_CAPTURE_BYTES = 65536", 1, true))
    end)

    it("uses ordered error JSON and the Fluent Bit prefix", function()
        local emit_block = assert(audit_lua:match("function _M.emit(.-)\nend\n\nreturn _M"))
        assert.truthy(audit_lua:find("local function ordered_json", 1, true))
        assert.truthy(emit_block:find("encode_or_fallback(fields)", 1, true))
        assert.falsy(emit_block:find("cjson.encode(", 1, true))
        assert.truthy(emit_block:find(
            'ngx.log(ngx.ERR, "PROVOST_AUDIT_ERROR " .. encoded)',
            1,
            true
        ))
        assert.falsy(audit_lua:find("ngx.get_phase", 1, true))
        assert.falsy(config:find("log_by_lua", 1, true))
    end)

    it("adds MCP routing fields immediately after conversation identity", function()
        assert.truthy(audit_lua:find(
            'table.insert(fields, 9, {"tool_name", bounded_value(ngx.ctx.tool_name, 96)})',
            1,
            true
        ))
        assert.truthy(audit_lua:find(
            'table.insert(fields, 10, {"destination", bounded_value(ngx.ctx.mcp_destination, 256)})',
            1,
            true
        ))
    end)

    it("keeps oversized error records valid and below the Nginx line limit", function()
        local cjson = require("cjson.safe")
        local emitted
        local mock_ngx = {
            ERR = "error",
            ctx = {
                is_mcp_path = true,
                user_id = "user",
                customer_id = "customer",
                conversation_id = "conversation",
                tool_name = "forbidden_tool",
                mcp_destination = "http://mcp-server:8088",
            },
            var = {
                time_local = "time",
                remote_addr = "127.0.0.1",
                request = "POST /mcp/dummy HTTP/1.1",
                request_id = "request-id",
                req_body = string.rep("x", 40000),
                resp_body = '{"error":"blocked"}',
            },
            req = {
                get_headers = function()
                    return {}
                end,
            },
            utctime = function()
                return "2026-07-22 00:00:00"
            end,
            log = function(_, message)
                emitted = message
            end,
        }
        local environment = setmetatable({ngx = mock_ngx}, {__index = _G})
        local audit = load_with_environment("lua/audit_error.lua", environment)
        audit.emit("provost_governance_error", 403, "GOVERNANCE_VIOLATION", "blocked")

        assert.truthy(emitted:find("PROVOST_AUDIT_ERROR ", 1, true))
        assert.is_true(#emitted < 3000)
        local record = assert(cjson.decode(emitted:sub(#"PROVOST_AUDIT_ERROR " + 1)))
        assert.truthy(record.request_body:find("[truncated]", 1, true))
        assert.equals('{"error":"blocked"}', record.resp_body)
    end)
end)