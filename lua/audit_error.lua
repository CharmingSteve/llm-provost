local cjson = require("cjson.safe")

local _M = {}

local function audit_entry(status_code, error_code, error_detail)
    local context = ngx.ctx or {}
    local var = ngx.var or {}
    local entry = {
        timestamp = ngx.utctime(),
        method = ngx.req.get_method(),
        uri = var.uri or "",
        status = status_code or ngx.status,
        request_id = var.request_id or "",
        user_id = context.user_id or var.provost_user_id or "steve",
        customer_id = context.customer_id or var.provost_customer_id or "craig",
        conversation_id = context.conversation_id or var.provost_conversation_id or "none",
        error_code = error_code,
        error_detail = error_detail,
    }

    if context.is_mcp_path then
        entry.tool_name = context.tool_name
        entry.destination = context.mcp_destination
    end

    return entry
end

function _M.emit(status_code, error_code, error_detail)
    ngx.log(ngx.ERR, "PROVOST_AUDIT_ERROR ", cjson.encode(audit_entry(
        status_code,
        error_code,
        error_detail
    )))
end

if ngx.get_phase and ngx.get_phase() == "log" then
    ngx.log(ngx.INFO, "PROVOST_AUDIT ", cjson.encode(audit_entry()))
end

return _M