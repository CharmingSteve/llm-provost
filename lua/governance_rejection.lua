local cjson = require("cjson.safe")
local intervention = require("intervention")

local _M = {}

function _M.reject(status, error_code, detail, audit_tag)
    if status == ngx.HTTP_FORBIDDEN then
        detail = intervention.brand(detail)
    else
        detail = tostring(detail or "Request rejected")
    end

    local body = cjson.encode({
        error = error_code,
        detail = detail,
    }) or "{}"

    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.var.resp_body = body
    require("audit_error").emit(audit_tag, status, error_code, detail, {
        resp_body = body,
    })
    ngx.say(body)
    return ngx.exit(status)
end

return _M
