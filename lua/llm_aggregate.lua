-- Aggregate /llm/v1 endpoint: one OpenAI-compatible base URL for every
-- backend in LLM_ROUTES_JSON, selected by a backend-prefixed model id.
--
--   GET  /llm/v1/models   merged listing; each id carries its route key as a
--                         prefix ("bedrock/openai.gpt-oss-20b-1:0"). Backends
--                         that do not answer are omitted.
--   POST /llm/v1/...      the "model" prefix (up to the first "/") selects the
--                         backend; the upstream receives the remainder verbatim.
--
-- The listing cache and the per-backend cooldown are availability state:
-- module-local, per worker, and only decide whether a backend is worth
-- contacting. Governance (rules, audit) never reads them.
local cjson = require("cjson.safe")

-- Re-encoding must not turn [] into {}, escape "/" or round numbers.
local json = require("cjson.safe").new()
if json.decode_array_with_array_mt then
    json.decode_array_with_array_mt(true)
end
if json.encode_escape_forward_slash then
    json.encode_escape_forward_slash(false)
end
pcall(json.encode_number_precision, 16)

local unpack = unpack or rawget(table, "unpack")

local _M = {}

local DEFAULT_COOLDOWN_SECONDS = 180
local LIST_CACHE_TTL_SECONDS = 45
local PROBE_TIMEOUT_MS = 2500
local CONNECT_TIMEOUT_MS = 1000
-- Bodies past these limits pass through without the re-prefix.
local MAX_JSON_BODY_BYTES = 8 * 1024 * 1024
local MAX_SSE_EVENT_BYTES = 1024 * 1024
local ROUTE_URL_PATTERN = "^https?://[^%s/#@]+[^%s#@]*$"
-- Per-backend credential sent by the client, named after the route key
-- (X-Provost-Backend-Key-openwire). config/librechat.yaml fills these from
-- the key variables each backend used before (OPENAI_API_KEY, ...).
local BACKEND_KEY_HEADER = "x-provost-backend-key-"

local function configured_cooldown()
    local raw = os.getenv("PROVOST_BACKEND_COOLDOWN_SECONDS")
    if raw == nil or raw == "" then
        return DEFAULT_COOLDOWN_SECONDS
    end
    local value = tonumber(raw)
    if value and value >= 0 then
        return value
    end
    if ngx and ngx.log then
        ngx.log(ngx.WARN, "invalid PROVOST_BACKEND_COOLDOWN_SECONDS '", raw, "'; using ",
                DEFAULT_COOLDOWN_SECONDS)
    end
    return DEFAULT_COOLDOWN_SECONDS
end

-- Read once when the module loads; changing it requires a container reload.
_M.cooldown_seconds = configured_cooldown()

local routes_cache
function _M.routes()
    if routes_cache == nil then
        local decoded = cjson.decode(os.getenv("LLM_ROUTES_JSON") or "")
        routes_cache = type(decoded) == "table" and decoded or false
    end
    return routes_cache or nil
end

-- ------------------------------------------------------------------
-- Backend availability (passive cooldown)
-- ------------------------------------------------------------------

-- name -> { down_until = epoch }. An entry outlives its cooldown so the
-- next successful contact can log the recovery.
local backend_state = {}
local list_cache

function _M.is_down(name)
    local state = backend_state[name]
    return state ~= nil and ngx.now() < state.down_until
end

-- Logs only the transition: a backend already inside its cooldown is not
-- re-marked, so at most one line per backend per cooldown window.
function _M.mark_down(name, reason)
    if _M.is_down(name) then
        return
    end
    backend_state[name] = { down_until = ngx.now() + _M.cooldown_seconds }
    list_cache = nil
    ngx.log(ngx.WARN, "backend ", name, " marked down (", reason, ")")
end

-- The recovery line is logged at WARN: the inbound server's error_log
-- threshold is warn, and an INFO line would never reach container stdout.
function _M.mark_up(name)
    if not backend_state[name] then
        return
    end
    backend_state[name] = nil
    list_cache = nil
    ngx.log(ngx.WARN, "backend ", name, " recovered")
end

function _M.reset()
    backend_state = {}
    list_cache = nil
end

-- ------------------------------------------------------------------
-- Per-backend credentials
-- ------------------------------------------------------------------

-- Authorization for one backend: the client's key header for that backend,
-- otherwise the client's own Authorization, forwarded as before.
function _M.backend_authorization(headers, name, authorization)
    local key = headers and headers[BACKEND_KEY_HEADER .. name:lower()]
    if type(key) == "table" then
        key = key[1]
    end
    if type(key) == "string" and key ~= "" then
        return "Bearer " .. key
    end
    return authorization
end

-- Dispatch: sends the selected backend its own key and drops every
-- per-backend key header, so no upstream sees another backend's key.
function _M.apply_backend_key(name)
    local headers = ngx.req.get_headers()
    local authorization = _M.backend_authorization(headers, name, nil)
    for header in pairs(headers) do
        if header:lower():sub(1, #BACKEND_KEY_HEADER) == BACKEND_KEY_HEADER then
            ngx.req.clear_header(header)
        end
    end
    if authorization then
        ngx.req.set_header("Authorization", authorization)
    end
end

-- ------------------------------------------------------------------
-- Aggregate listing
-- ------------------------------------------------------------------

local function probe_failure(err)
    err = tostring(err or "unknown error")
    if err == "timeout" then
        return "probe timeout"
    end
    return "probe failed: " .. err:sub(1, 200)
end

local function probe_bedrock()
    local models, err = require("bedrock").models()
    if not models then
        if tostring(err):match("^Bedrock model listing returned status 4%d%d") then
            return nil
        end
        return nil, probe_failure(err)
    end
    return models.data or {}
end

local function probe_http(url, authorization)
    local httpc = require("resty.http").new()
    httpc:set_timeout(PROBE_TIMEOUT_MS)
    local response, err = httpc:request_uri(url:gsub("/$", "") .. "/models", {
        method = "GET",
        headers = { Authorization = authorization },
    })
    if not response then
        return nil, probe_failure(err)
    end
    if response.status >= 400 and response.status < 500 then
        return nil
    end
    if response.status < 200 or response.status >= 300 then
        return nil, "probe failed: status " .. response.status
    end
    local payload = cjson.decode(response.body or "")
    if type(payload) ~= "table" or type(payload.data) ~= "table" then
        return nil, "probe failed: invalid model listing"
    end
    return payload.data
end

-- Returns models (upstream ids), or nil and a reason. nil without a reason
-- means omitted but not down: Bedrock is disabled, or the backend answered
-- with a 4xx (for example it rejects the forwarded key), so it is reachable
-- and chat requests to it must not fail as PROVOST_BACKEND_DOWN.
function _M.probe(name, url, authorization)
    if name == "bedrock" then
        if os.getenv("BEDROCK_ENABLED") ~= "true" then
            return nil
        end
        return probe_bedrock()
    end
    if type(url) ~= "string" or not url:match(ROUTE_URL_PATTERN) then
        return nil, "invalid route URL"
    end
    return probe_http(url, authorization)
end

-- Probes all targets concurrently under one deadline, so a listing takes
-- at most about PROBE_TIMEOUT_MS however many backends hang.
local function probe_all(targets)
    local results = {}
    if #targets == 0 then
        return results
    end

    local function run(name, url, authorization)
        local ok, models, err = pcall(_M.probe, name, url, authorization)
        if not ok then
            return name, nil, probe_failure(models)
        end
        return name, models, err
    end

    local threads, waiting = {}, {}
    for _, target in ipairs(targets) do
        threads[target.name] = ngx.thread.spawn(run, target.name, target.url, target.authorization)
        waiting[#waiting + 1] = target.name
    end
    -- spawn needs a Lua function; ngx.sleep is a C builtin.
    local deadline = ngx.thread.spawn(function()
        ngx.sleep(PROBE_TIMEOUT_MS / 1000 + 0.5)
    end)

    while #waiting > 0 do
        local handles = {}
        for _, name in ipairs(waiting) do
            handles[#handles + 1] = threads[name]
        end
        handles[#handles + 1] = deadline
        local _, name, models, err = ngx.thread.wait(unpack(handles))
        if name == nil then
            break
        end
        results[name] = { models = models, err = err }
        for index, pending in ipairs(waiting) do
            if pending == name then
                table.remove(waiting, index)
                break
            end
        end
    end

    for _, name in ipairs(waiting) do
        ngx.thread.kill(threads[name])
        results[name] = { err = "probe timeout" }
    end
    ngx.thread.kill(deadline)
    return results
end

local function sorted_names(routes)
    local names = {}
    for name in pairs(routes) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

-- Merged OpenAI listing. Same model on two backends is listed twice; the
-- prefix tells them apart. Backends inside their cooldown are not probed.
-- Each probe carries that backend's key (see backend_authorization).
function _M.list_models(routes, authorization, headers)
    if list_cache and ngx.now() < list_cache.expires then
        return list_cache.listing
    end

    local targets = {}
    for _, name in ipairs(sorted_names(routes)) do
        if not _M.is_down(name) then
            targets[#targets + 1] = {
                name = name,
                url = routes[name],
                authorization = _M.backend_authorization(headers, name, authorization),
            }
        end
    end

    local results = probe_all(targets)
    local data = {}
    for _, target in ipairs(targets) do
        local result = results[target.name] or {}
        if result.models then
            _M.mark_up(target.name)
            for _, model in ipairs(result.models) do
                if type(model) == "table" and type(model.id) == "string" then
                    local entry = {}
                    for key, value in pairs(model) do
                        entry[key] = value
                    end
                    entry.id = target.name .. "/" .. model.id
                    data[#data + 1] = entry
                end
            end
        elseif result.err then
            _M.mark_down(target.name, result.err)
        else
            _M.mark_up(target.name)
        end
    end

    local listing = { object = "list", data = data }
    list_cache = { expires = ngx.now() + LIST_CACHE_TTL_SECONDS, listing = listing }
    return listing
end

function _M.encode_listing(listing)
    if json.array_mt then
        setmetatable(listing.data, json.array_mt)
    end
    return json.encode(listing)
end

-- ------------------------------------------------------------------
-- Dispatch
-- ------------------------------------------------------------------

-- Splits on the first "/" only; everything after it is the upstream id.
function _M.split_model(model)
    if type(model) ~= "string" then
        return nil
    end
    local slash = model:find("/", 1, true)
    if not slash then
        return nil
    end
    return model:sub(1, slash - 1), model:sub(slash + 1)
end

-- Resolves the backend from the request body. Returns
-- { backend, model, upstream_model } or nil, status, error_code, message.
-- There is no default backend: an unprefixed id is rejected.
function _M.resolve(body, routes)
    local decoded = cjson.decode(body or "")
    local model = type(decoded) == "table" and decoded.model or nil
    if type(model) ~= "string" then
        return nil, 400, "LLM_MODEL_UNPREFIXED",
            "Request body must carry a model id of the form <backend>/<model>"
    end
    local backend, upstream_model = _M.split_model(model)
    if not backend or upstream_model == "" then
        return nil, 400, "LLM_MODEL_UNPREFIXED",
            "Model id '" .. model .. "' has no backend prefix; use <backend>/<model>"
    end
    if type(routes[backend]) ~= "string" then
        return nil, 404, "LLM_BACKEND_UNKNOWN", "Unknown LLM backend: " .. backend
    end
    return { backend = backend, model = model, upstream_model = upstream_model }
end

local ERROR_TYPES = {
    [400] = "invalid_request_error",
    [404] = "invalid_request_error",
    [503] = "server_error",
}

function _M.reject(status, error_code, message)
    local body = cjson.encode({
        error = {
            code = error_code,
            message = message,
            type = ERROR_TYPES[status] or "server_error",
        },
    })
    ngx.var.resp_body = body
    require("audit_error").emit("provost_request_error", status, error_code, message, {
        resp_body = body,
    })
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.say(body)
    return ngx.exit(status)
end

local function route_endpoint(name, url)
    if name == "bedrock" then
        return require("bedrock").runtime_host(), 443
    end
    local scheme, authority = url:match("^(https?)://([^/]+)")
    local host, port = authority:match("^(.-):(%d+)$")
    if not host then
        host = authority
        port = scheme == "https" and 443 or 80
    end
    return host, tonumber(port)
end

-- Fail-fast gate before proxying. A backend inside its cooldown fails with
-- no network contact; otherwise a short TCP connect decides.
function _M.ensure_available(name, url)
    if _M.is_down(name) then
        return false
    end
    local host, port = route_endpoint(name, url)
    local sock = ngx.socket.tcp()
    sock:settimeout(CONNECT_TIMEOUT_MS)
    local ok, err = sock:connect(host, port)
    if not ok then
        _M.mark_down(name, err == "timeout" and "connect timeout" or ("connect failed: " .. tostring(err)))
        return false
    end
    sock:close()
    _M.mark_up(name)
    return true
end

local function literal_pattern(value)
    return (value:gsub("%p", "%%%0"))
end

-- A JSON string may or may not escape "/"; try both spellings.
local function encoded_forms(value)
    local plain = json.encode(value)
    local escaped = plain:gsub("/", "\\/")
    if escaped == plain then
        return { plain }
    end
    return { plain, escaped }
end

-- Replaces the value of a "model" key in raw JSON, leaving every other byte
-- alone. Returns nil unless the key/value pair occurs exactly once.
local function replace_model(raw, from, to)
    local replacement = json.encode(to)
    for _, form in ipairs(encoded_forms(from)) do
        local pattern = '("model"%s*:%s*)' .. literal_pattern(form)
        local _, count = raw:gsub(pattern, "")
        if count == 1 then
            return (raw:gsub(pattern, function(key)
                return key .. replacement
            end))
        end
    end
    return nil
end

-- Request body for the upstream: the prefixed id swapped for the stripped
-- one. Falls back to re-encoding only when the raw value cannot be found.
function _M.strip_model(body, resolved)
    local replaced = replace_model(body, resolved.model, resolved.upstream_model)
    if replaced then
        return replaced
    end
    local decoded = json.decode(body)
    if type(decoded) ~= "table" then
        return body
    end
    decoded.model = resolved.upstream_model
    return json.encode(decoded) or body
end

-- ------------------------------------------------------------------
-- Response re-prefix (client copy only; runs after audit_body.capture)
-- ------------------------------------------------------------------

local function rewrite_payload(payload, model)
    local decoded = cjson.decode(payload)
    if type(decoded) ~= "table" or type(decoded.model) ~= "string" or decoded.model == model then
        return payload
    end
    return replace_model(payload, decoded.model, model) or payload
end

local function rewrite_event(event, model)
    return (event:gsub("[^\r\n]+", function(line)
        if line:sub(1, 5) ~= "data:" then
            return line
        end
        return "data:" .. rewrite_payload(line:sub(6), model)
    end))
end

local function event_boundary(value)
    local lf_start, lf_end = value:find("\n\n", 1, true)
    local crlf_start, crlf_end = value:find("\r\n\r\n", 1, true)
    if crlf_start and (not lf_start or crlf_start < lf_start) then
        return crlf_start, crlf_end
    end
    return lf_start, lf_end
end

local JsonRewriter = {}
JsonRewriter.__index = JsonRewriter

function JsonRewriter:feed(chunk, eof)
    if self.passthrough then
        return chunk
    end
    self.buffer[#self.buffer + 1] = chunk
    self.bytes = self.bytes + #chunk
    if self.bytes > MAX_JSON_BODY_BYTES then
        self.passthrough = true
        return table.concat(self.buffer)
    end
    if not eof then
        return ""
    end
    return rewrite_payload(table.concat(self.buffer), self.model)
end

local SseRewriter = {}
SseRewriter.__index = SseRewriter

function SseRewriter:feed(chunk, eof)
    self.buffer = self.buffer .. chunk
    local out = {}
    while true do
        local first, last = event_boundary(self.buffer)
        if not first then
            break
        end
        out[#out + 1] = rewrite_event(self.buffer:sub(1, first - 1), self.model)
        out[#out + 1] = self.buffer:sub(first, last)
        self.buffer = self.buffer:sub(last + 1)
    end
    if eof then
        out[#out + 1] = rewrite_event(self.buffer, self.model)
        self.buffer = ""
    elseif #self.buffer > MAX_SSE_EVENT_BYTES then
        out[#out + 1] = self.buffer
        self.buffer = ""
    end
    return table.concat(out)
end

-- kind is "json" or "sse"; model is the prefixed id the client selected.
function _M.new_rewriter(kind, model)
    if kind == "sse" then
        return setmetatable({ model = model, buffer = "" }, SseRewriter)
    end
    return setmetatable({ model = model, buffer = {}, bytes = 0 }, JsonRewriter)
end

-- Backend of the dispatched aggregate request, nil before dispatch.
function _M.backend()
    local target = ngx.ctx.llm_aggregate
    return target and target.backend
end

-- Header phase: a rewritten body no longer matches the upstream length.
function _M.header_filter()
    local target = ngx.ctx.llm_aggregate
    if not target then
        return
    end
    local kind = require("display_format").response_kind(
        ngx.header.content_type,
        ngx.header.content_encoding
    )
    if kind then
        target.rewriter = _M.new_rewriter(kind, target.model)
        ngx.header.content_length = nil
    end
end

-- Body phase: returns the client-bound chunk with the prefixed model id.
function _M.body_filter(chunk, eof)
    local target = ngx.ctx.llm_aggregate
    local rewriter = target and target.rewriter
    if not rewriter then
        return chunk
    end
    return rewriter:feed(chunk or "", eof)
end

return _M
