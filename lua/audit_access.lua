local cjson = require("cjson.safe")
local logger = require("resty.logger.socket")

local _M = {}

local function text(value)
    return tostring(value or "")
end

local function base_record(resp_body)
    return {
        time_local = text(ngx.var.time_local),
        remote_addr = text(ngx.var.remote_addr),
        request = text(ngx.var.request),
        status = text(ngx.status),
        body_bytes_sent = text(ngx.var.body_bytes_sent),
        request_time = text(ngx.var.request_time),
        upstream_response_time = text(ngx.var.upstream_response_time),
        request_id = text(ngx.var.provost_req_id),
        user_id = text(ngx.var.provost_user_id),
        customer_id = text(ngx.var.provost_customer_id),
        conversation_id = text(ngx.var.provost_conversation_id),
        request_body = text(ngx.var.req_body),
        resp_body = resp_body,
    }
end

function _M.init()
    if logger.initted() then
        return true
    end
    return logger.init({
        host = "fluent-bit",
        port = 5141,
        sock_type = "tcp",
        flush_limit = 8192,
        drop_limit = 67108864,
        timeout = 1000,
        periodic_flush = 1,
    })
end

function _M.emit_chunk(resp_body, chunk)
    local record = base_record(resp_body)
    local transport_record = {
        time_local = record.time_local,
        remote_addr = record.remote_addr,
        request = record.request,
        status = record.status,
        body_bytes_sent = record.body_bytes_sent,
        request_time = record.request_time,
        upstream_response_time = record.upstream_response_time,
        request_id = record.request_id,
        user_id = record.user_id,
        customer_id = record.customer_id,
        conversation_id = record.conversation_id,
        request_body = chunk == 1 and record.request_body or "",
        resp_body = record.resp_body,
        pri = "190",
        host = text(ngx.var.hostname ~= "" and ngx.var.hostname or "llm-provost"),
        ident = "provost_llm_to_mcp_access",
        message = "stream response chunk " .. text(chunk),
        log_type = "access",
    }
    local encoded = cjson.encode(transport_record)
    local stdout_record = cjson.encode(record)
    if not encoded or not stdout_record then
        return nil, "unable to encode streaming access record"
    end

    local bytes, err = logger.log(encoded .. "\n")
    if not bytes or bytes == 0 then
        return nil, err or "streaming access logger dropped record"
    end
    io.stdout:write(stdout_record .. "\n")
    io.stdout:flush()
    return true
end

function _M.emit_error(encoded_error)
    local record = cjson.decode(encoded_error)
    if type(record) ~= "table" then
        return nil, "unable to decode structured error record"
    end
    record.pri = "187"
    record.host = text(ngx.var.hostname ~= "" and ngx.var.hostname or "llm-provost")
    record.ident = "provost_error"

    local encoded = cjson.encode(record)
    if not encoded then
        return nil, "unable to encode structured error transport record"
    end
    local bytes, err = logger.log(encoded .. "\n")
    if not bytes or bytes == 0 then
        return nil, err or "structured error logger dropped record"
    end
    return true
end

return _M