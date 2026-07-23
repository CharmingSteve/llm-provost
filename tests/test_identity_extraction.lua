local cjson = require("cjson.safe")

local function run_policy(options)
    local loaded_audit_error = package.loaded.audit_error
    local loaded_routes = package.loaded.routes
    local loaded_rules_engine = package.loaded.rules_engine
    local preload_audit_error = package.preload.audit_error
    local preload_routes = package.preload.routes
    local preload_rules_engine = package.preload.rules_engine
    package.loaded.audit_error = nil
    package.loaded.routes = nil
    package.loaded.rules_engine = nil
    package.preload.audit_error = function()
        return {
            emit = function()
                return nil
            end,
        }
    end
    package.preload.routes = function()
        return {
            get = function()
                return "http://mcp-server:8088"
            end,
        }
    end
    package.preload.rules_engine = function()
        return {
            check_request = function()
                return true
            end,
        }
    end

    local headers = options.headers or {}
    local body = options.body or ""
    ngx = {
        ctx = {},
        var = {
            uri = options.uri,
            request_id = options.request_id or "generated-request-id",
            provost_req_id = "",
            provost_user_id = "steve",
            provost_customer_id = "craig",
            provost_conversation_id = "none",
        },
        req = {
            get_headers = function()
                return headers
            end,
            read_body = function()
                return nil
            end,
            get_body_data = function()
                if options.body_file then
                    return nil
                end
                return body
            end,
            get_body_file = function()
                return options.body_file
            end,
            get_method = function()
                return "POST"
            end,
        },
        shared = {
            rules = {
                get = function()
                    return nil
                end,
            },
        },
        decode_base64 = function()
            return options.jwt_claims or "{}"
        end,
    }

    local policy_environment = setmetatable({ngx = ngx}, {__index = _G})
    local policy
    if setfenv then
        policy = assert(loadfile("lua/http_policy.lua"))
        setfenv(policy, policy_environment)
    else
        policy = assert(loadfile("lua/http_policy.lua", "t", policy_environment))
    end
    policy()
    package.loaded.audit_error = loaded_audit_error
    package.loaded.routes = loaded_routes
    package.loaded.rules_engine = loaded_rules_engine
    package.preload.audit_error = preload_audit_error
    package.preload.routes = preload_routes
    package.preload.rules_engine = preload_rules_engine
    return ngx
end

describe("four-layer identity extraction", function()
    it("extracts chat identity from a Cognito JWT", function()
        local result = run_policy({
            uri = "/v1/chat/completions",
            headers = {Authorization = "Bearer header.payload.signature"},
            jwt_claims = '{"sub":"chat-user"}',
        })
        assert.equals("generated-request-id", result.var.provost_req_id)
        assert.equals("chat-user", result.var.provost_user_id)
        assert.equals("craig", result.var.provost_customer_id)
        assert.equals("none", result.var.provost_conversation_id)
    end)

    it("defaults a chat user when no JWT is present", function()
        local result = run_policy({uri = "/v1/chat/completions"})
        assert.equals("steve", result.var.provost_user_id)
    end)

    it("extracts an MCP user from X-Cognito-User", function()
        local result = run_policy({
            uri = "/mcp/trading",
            headers = {["X-Cognito-User"] = "mcp-user"},
        })
        assert.equals("mcp-user", result.var.provost_user_id)
    end)

    it("defaults an MCP user when X-Cognito-User is absent", function()
        local result = run_policy({uri = "/mcp/trading"})
        assert.equals("steve", result.var.provost_user_id)
    end)

    it("extracts an MCP customer from tool arguments", function()
        local result = run_policy({
            uri = "/mcp/trading",
            body = cjson.encode({
                method = "tools/call",
                params = {
                    name = "get_account",
                    arguments = {customer_id = "customer-42"},
                },
            }),
        })
        assert.equals("customer-42", result.var.provost_customer_id)
    end)

    it("defaults an MCP customer when tool arguments omit identity", function()
        local result = run_policy({
            uri = "/mcp/trading",
            body = cjson.encode({
                method = "tools/call",
                params = {name = "get_account", arguments = {}},
            }),
        })
        assert.equals("craig", result.var.provost_customer_id)
    end)

    it("extracts conversation identity on chat and MCP paths", function()
        for _, uri in ipairs({"/v1/chat/completions", "/mcp/trading"}) do
            local result = run_policy({
                uri = uri,
                headers = {["X-Conversation-Id"] = "conversation-7"},
            })
            assert.equals("conversation-7", result.var.provost_conversation_id)
        end
    end)

    it("defaults conversation identity on chat and MCP paths", function()
        for _, uri in ipairs({"/v1/chat/completions", "/mcp/trading"}) do
            local result = run_policy({uri = uri})
            assert.equals("none", result.var.provost_conversation_id)
        end
    end)

    it("stores the request body for access and error logs", function()
        local result = run_policy({
            uri = "/v1/chat/completions",
            body = '{"message":"hello"}',
        })
        assert.equals('{"message":"hello"}', result.var.req_body)
    end)

    it("reads file-backed request bodies without bypassing identity extraction", function()
        local body = cjson.encode({
            method = "tools/call",
            params = {
                name = "get_records",
                arguments = {
                    customer_id = "file-backed-customer",
                    padding = string.rep("x", 32768),
                },
            },
        })
        local body_file = os.tmpname()
        local file = assert(io.open(body_file, "wb"))
        file:write(body)
        file:close()

        local result = run_policy({
            uri = "/mcp/dummy",
            body_file = body_file,
        })
        os.remove(body_file)

        assert.equals(body, result.var.req_body)
        assert.equals(body, result.ctx.request_body)
        assert.equals("file-backed-customer", result.var.provost_customer_id)
        assert.equals("http://mcp-server:8088", result.ctx.mcp_destination)
    end)
end)