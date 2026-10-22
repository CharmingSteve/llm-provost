local cjson = require("cjson.safe")
local AWS = require("resty.aws")
local sign_request = require("resty.aws.request.sign")
local http = require("resty.http")

local _M = {}

local function region()
    return os.getenv("BEDROCK_AWS_DEFAULT_REGION") or os.getenv("AWS_REGION") or "us-east-1"
end

-- Explicitly parse the shared credentials file (ini format).
-- Resolution: env vars first, then AWS_SHARED_CREDENTIALS_FILE, profile [default].
local function resolve_credentials()
    local access_key = os.getenv("AWS_ACCESS_KEY_ID")
    local secret_key = os.getenv("AWS_SECRET_ACCESS_KEY")
    local session_token = os.getenv("AWS_SESSION_TOKEN")
    if access_key == "" then access_key = nil end
    if secret_key == "" then secret_key = nil end
    if session_token == "" then session_token = nil end
    if access_key and secret_key then
        return access_key, secret_key, session_token, "env"
    end

    local path = os.getenv("AWS_SHARED_CREDENTIALS_FILE") or "/home/provost/.aws/credentials"
    local profile = os.getenv("AWS_PROFILE")
    if profile == "" or not profile then profile = "default" end

    local file = io.open(path, "r")
    if not file then
        return nil, nil, nil, "credentials file not found: " .. path
    end
    local current, found = nil, nil
    for line in file:lines() do
        local section = line:match("^%s*%[(.+)%]%s*$")
        if section then
            current = section
        elseif current == profile then
            local k, v = line:match("^%s*([%w_]+)%s*=%s*(%S+)%s*$")
            if k and v then
                found = found or {}
                found[k] = v
            end
        end
    end
    file:close()
    if not found or not found.aws_access_key_id or not found.aws_secret_access_key then
        return nil, nil, nil, "profile [" .. profile .. "] missing in " .. path
    end
    return found.aws_access_key_id, found.aws_secret_access_key, found.aws_session_token, "file:" .. profile
end

-- Credentials are resolved once and cached in a shared dict so the ini file is
-- not re-read on every Bedrock request. The TTL is a safety net for rotated
-- file-based credentials; auth failures invalidate the cache immediately.
local CACHE_KEY = "credentials"
local CACHE_TTL = 300

local function creds_cache()
    return ngx.shared and ngx.shared.bedrock_creds
end

function _M.invalidate()
    local dict = creds_cache()
    if dict then
        dict:delete(CACHE_KEY)
    end
end

local function get_credentials()
    local dict = creds_cache()
    local cached = dict and dict:get(CACHE_KEY)
    if cached then
        local decoded = cjson.decode(cached)
        if type(decoded) == "table" and decoded.access_key and decoded.secret_key then
            return decoded.access_key, decoded.secret_key, decoded.session_token
        end
    end

    local access_key, secret_key, session_token, source = resolve_credentials()
    if not access_key then
        return nil, nil, nil, source
    end
    ngx.log(ngx.INFO, "bedrock: resolved credentials from ", source,
            " key=", string.sub(access_key, 1, 8), "...")
    if dict then
        dict:set(CACHE_KEY, cjson.encode({
            access_key = access_key,
            secret_key = secret_key,
            session_token = session_token,
        }), CACHE_TTL)
    end
    return access_key, secret_key, session_token
end

-- One AWS client per worker; only the credentials change between calls.
local aws_client
local function client()
    if not aws_client then
        aws_client = AWS({
            region = region(),
            endpointPrefix = "bedrock",
            signatureVersion = "v4",
        })
    end
    return aws_client
end

local function signed_headers(method, host, path, body, query)
    local access_key, secret_key, session_token, err = get_credentials()
    if not access_key then
        return nil, "no AWS credentials resolved: " .. tostring(err)
    end
    local aws = client()
    aws.config.credentials = aws:Credentials({
        accessKeyId = access_key,
        secretAccessKey = secret_key,
        sessionToken = session_token,
    })
    local request = {
        method = method,
        host = host,
        port = 443,
        path = path,
        query = query,
        body = body or "",
        headers = {},
    }
    if path:sub(1, 7) == "/model/" then
        -- Bedrock verifies native model paths with percent escapes encoded twice.
        request.canonicalURI = (path:gsub("%%", "%%25"))
    end
    local signed, sign_err = sign_request(aws.config, request)
    return signed and signed.headers or nil, sign_err
end

function _M.runtime_host()
    return "bedrock-runtime." .. region() .. ".amazonaws.com"
end

function _M.prepare_request(body, path)
    local host = _M.runtime_host()
    local headers, err = signed_headers(ngx.req.get_method(), host, path or ngx.var.bedrock_path, body)
    if not headers then
        return nil, err
    end
    ngx.req.set_header("Authorization", headers.Authorization)
    ngx.req.set_header("X-Amz-Date", headers["X-Amz-Date"])
    if headers["X-Amz-Security-Token"] then
        ngx.req.set_header("X-Amz-Security-Token", headers["X-Amz-Security-Token"])
    end
    return host
end

-- Anything that is not a plain text chat model: speech, video understanding
-- and rerankers answer Converse with a validation error.
local NON_CHAT_PATTERNS = { "^twelvelabs%.", "rerank", "sonic" }

local GEO_PREFIX = { us = "us.", eu = "eu.", ap = "apac.", ca = "ca.", jp = "jp.", au = "au." }

local function contains(list, value)
    for _, item in ipairs(list or {}) do
        if item == value then
            return true
        end
    end
    return false
end

local function is_chat_model(model)
    if type(model.modelId) ~= "string" or not contains(model.outputModalities, "TEXT") then
        return false
    end
    if contains(model.outputModalities, "SPEECH") or contains(model.inputModalities, "SPEECH") then
        return false
    end
    -- AWS blocks LEGACY models for accounts that have not used them recently.
    if type(model.modelLifecycle) == "table" and model.modelLifecycle.status == "LEGACY" then
        return false
    end
    for _, pattern in ipairs(NON_CHAT_PATTERNS) do
        if model.modelId:find(pattern) then
            return false
        end
    end
    return true
end

-- Picks the id Converse accepts for a model: the plain id when AWS serves it
-- on demand, otherwise a system inference profile (region geography first,
-- then global).
local function invocation_id(model, profile_ids, geo_prefix)
    if contains(model.inferenceTypesSupported, "ON_DEMAND") then
        return model.modelId
    end
    if not contains(model.inferenceTypesSupported, "INFERENCE_PROFILE") then
        return nil
    end
    local geo, global, other
    for _, id in ipairs(profile_ids or {}) do
        if geo_prefix and id:sub(1, #geo_prefix) == geo_prefix then
            geo = geo or id
        elseif id:sub(1, 7) == "global." then
            global = global or id
        else
            other = other or id
        end
    end
    return geo or global or other
end

-- Pure: builds the OpenAI model listing from the two AWS listings.
function _M.build_catalog(foundation_models, inference_profiles, geo_prefix)
    local profiles_by_model = {}
    for _, profile in ipairs(inference_profiles or {}) do
        if profile.status == "ACTIVE" and type(profile.inferenceProfileId) == "string" then
            for _, model in ipairs(profile.models or {}) do
                local base = tostring(model.modelArn or ""):match(":foundation%-model/(.+)$")
                if base then
                    profiles_by_model[base] = profiles_by_model[base] or {}
                    table.insert(profiles_by_model[base], profile.inferenceProfileId)
                end
            end
        end
    end
    local models = {}
    for _, model in ipairs(foundation_models or {}) do
        if is_chat_model(model) then
            local ids = profiles_by_model[model.modelId]
            if ids then
                table.sort(ids)
            end
            local id = invocation_id(model, ids, geo_prefix)
            if id then
                table.insert(models, { id = id, object = "model", owned_by = "amazon-bedrock" })
            end
        end
    end
    table.sort(models, function(a, b) return a.id < b.id end)
    return { object = "list", data = models }
end

local function list_pages(host, path, field, query)
    local items, token = {}, nil
    for _ = 1, 10 do
        local page_query = query
        if token then
            page_query = (query and (query .. "&") or "") .. "nextToken=" .. ngx.escape_uri(token)
        end
        local headers, err = signed_headers("GET", host, path, "", page_query)
        if not headers then
            return nil, err
        end
        local requester = http.new()
        requester:set_timeout(30000)
        local response, request_err = requester:request_uri(
            "https://" .. host .. path .. (page_query and ("?" .. page_query) or ""), {
                method = "GET",
                headers = headers,
                ssl_server_name = host,
                ssl_verify = true,
            })
        if not response then
            return nil, request_err
        end
        if response.status == 401 or response.status == 403 then
            _M.invalidate()
        end
        if response.status < 200 or response.status >= 300 then
            -- Surface the REAL AWS error so it lands in the logs.
            return nil, "Bedrock model listing returned status " .. response.status
                .. " body: " .. string.sub(response.body or "", 1, 500)
        end
        local payload = cjson.decode(response.body)
        if type(payload) ~= "table" or type(payload[field]) ~= "table" then
            return nil, "invalid Bedrock model listing response"
        end
        for _, item in ipairs(payload[field]) do
            items[#items + 1] = item
        end
        token = type(payload.nextToken) == "string" and payload.nextToken ~= "" and payload.nextToken or nil
        if not token then
            return items
        end
    end
    return items
end

local CATALOG_KEY = "catalog:"
local CATALOG_TTL = 3600

-- The listing is derived from AWS metadata (no per-model probing) and cached
-- for an hour; it is therefore static between refreshes.
function _M.models()
    local region_name = region()
    local dict = creds_cache()
    local key = CATALOG_KEY .. region_name
    local cached = dict and dict:get(key)
    if cached then
        local decoded = cjson.decode(cached)
        if type(decoded) == "table" and type(decoded.data) == "table" then
            return decoded
        end
    end

    local host = "bedrock." .. region_name .. ".amazonaws.com"
    local foundation, err = list_pages(host, "/foundation-models", "modelSummaries")
    if not foundation then
        return nil, err
    end
    local profiles, profile_err = list_pages(host, "/inference-profiles", "inferenceProfileSummaries",
        "maxResults=1000&typeEquals=SYSTEM_DEFINED")
    if not profiles then
        return nil, profile_err
    end
    local catalog = _M.build_catalog(foundation, profiles, GEO_PREFIX[region_name:match("^(%a+)%-") or ""])
    if dict and #catalog.data > 0 then
        dict:set(key, cjson.encode(catalog), CATALOG_TTL)
    end
    return catalog
end

return _M
