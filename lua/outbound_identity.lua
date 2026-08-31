-- outbound_identity.lua
-- Resolve the 4-layer identity for the outbound MCP-to-API hop (port 8081).
--
-- The inbound hop (http_policy.lua) stores the request identity in the
-- provost_ctx shared dict keyed by provost request id, plus "last known"
-- fallbacks. The MCP server may strip provost headers on its outbound REST
-- calls, so this module restores identity from the shared dict and exposes
-- it via ngx.var for the json_full audit log format.

local cjson = require("cjson.safe")

local _M = {}

local CTX_TTL_SECONDS = 900

local function nonempty(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

function _M.store(request_id, user_id, customer_id, conversation_id)
    if type(ngx) ~= "table" or type(ngx.shared) ~= "table" then
        return
    end
    local ctx_store = ngx.shared.provost_ctx
    if not ctx_store or not nonempty(request_id) then
        return
    end

    local encoded = cjson.encode({
        user_id = user_id,
        customer_id = customer_id,
        conversation_id = conversation_id,
        timestamp = ngx.now(),
    })
    ctx_store:set("req:" .. request_id, encoded, CTX_TTL_SECONDS)
    ctx_store:set("last:request_id", request_id, CTX_TTL_SECONDS)
    if nonempty(user_id) then
        ctx_store:set("last:user_id", user_id, CTX_TTL_SECONDS)
    end
    if nonempty(customer_id) then
        ctx_store:set("last:customer_id", customer_id, CTX_TTL_SECONDS)
    end
    if nonempty(conversation_id) then
        ctx_store:set("last:conversation_id", conversation_id, CTX_TTL_SECONDS)
    end
end

function _M.resolve()
    local headers = ngx.req.get_headers() or {}
    local ctx_store = ngx.shared.provost_ctx

    local req_body = ngx.req.get_body_data()
    if req_body then
        ngx.var.req_body = req_body
    end

    local request_id = nonempty(ngx.var.http_x_provost_request_id)
        or nonempty(headers["X-Provost-Request-Id"])
        or nonempty(headers["x-provost-request-id"])

    local user_id, customer_id, conversation_id

    if ctx_store and request_id then
        local ctx_json = ctx_store:get("req:" .. request_id)
        local ctx = ctx_json and cjson.decode(ctx_json)
        if type(ctx) == "table" then
            user_id = nonempty(ctx.user_id)
            customer_id = nonempty(ctx.customer_id)
            conversation_id = nonempty(ctx.conversation_id)
        end
    end

    if ctx_store and not user_id then
        request_id = request_id or nonempty(ctx_store:get("last:request_id"))
        user_id = nonempty(ctx_store:get("last:user_id"))
        customer_id = customer_id or nonempty(ctx_store:get("last:customer_id"))
        conversation_id = conversation_id or nonempty(ctx_store:get("last:conversation_id"))
    end

    request_id = request_id
        or nonempty(ngx.var.request_id)
        or (ngx.now() * 1000000 .. "-" .. math.random(100000, 999999))

    ngx.var.provost_req_id = request_id
    ngx.var.provost_user_id = user_id or "steve"
    ngx.var.provost_customer_id = customer_id or "craig"
    ngx.var.provost_conversation_id = conversation_id or "none"
    ngx.req.set_header("X-Provost-Request-Id", request_id)
end

-- Buffered response capture so the hop's access log carries the full body.
function _M.capture_response(chunk, eof)
    local MAX_CAPTURE_BYTES = 65536
    local buffered = ngx.ctx.buffered or ""
    if #buffered < MAX_CAPTURE_BYTES and chunk and #chunk > 0 then
        local remaining = MAX_CAPTURE_BYTES - #buffered
        if #chunk > remaining then
            buffered = buffered .. string.sub(chunk, 1, remaining)
        else
            buffered = buffered .. chunk
        end
        ngx.ctx.buffered = buffered
    end
    if eof then
        ngx.var.resp_body = buffered

        -- Cache discovered Alpaca account_id from successful account payloads.
        if ngx.status >= 200 and ngx.status < 300 then
            local payload = cjson.decode(buffered)
            local discovered = payload and (payload.id or payload.account_id)
            if type(discovered) == "string"
               and discovered ~= ""
               and type(payload) == "table"
               and (payload.account_number or payload.currency or payload.buying_power) then
                ngx.shared.provost_ctx:set("alpaca:account_id", discovered, 300)
            end
        end
    end
end

return _M
