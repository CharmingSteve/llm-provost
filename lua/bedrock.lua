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

local function signed_headers(method, host, path, body)
    local aws = AWS({
        region = region(),
        endpointPrefix = "bedrock",
        signatureVersion = "v4",
    })
    local access_key, secret_key, session_token, source = resolve_credentials()
    if not access_key then
        return nil, "no AWS credentials resolved: " .. tostring(source)
    end
    ngx.log(ngx.INFO, "bedrock: signing with credentials from ", source,
            " key=", string.sub(access_key, 1, 8), "...")
    aws.config.credentials = aws:Credentials({
        accessKeyId = access_key,
        secretAccessKey = secret_key,
        sessionToken = session_token,
    })
    local signed, err = sign_request(aws.config, {
        method = method,
        host = host,
        port = 443,
        path = path,
        body = body or "",
        headers = {},
    })
    return signed and signed.headers or nil, err
end

function _M.runtime_host()
    return "bedrock-runtime." .. region() .. ".amazonaws.com"
end

function _M.prepare_request(body)
    local host = _M.runtime_host()
    local headers, err = signed_headers(ngx.req.get_method(), host, ngx.var.bedrock_path, body)
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

function _M.models()
    local host = "bedrock." .. region() .. ".amazonaws.com"
    local headers, err = signed_headers("GET", host, "/foundation-models", "")
    if not headers then
        return nil, err
    end
    local client = http.new()
    client:set_timeout(30000)
    local response, request_err = client:request_uri("https://" .. host .. "/foundation-models", {
        method = "GET",
        headers = headers,
        ssl_server_name = host,
        ssl_verify = true,
    })
    if not response then
        return nil, request_err
    end
    if response.status < 200 or response.status >= 300 then
        -- Surface the REAL AWS error so it lands in the logs.
        return nil, "Bedrock model listing returned status " .. response.status
            .. " body: " .. string.sub(response.body or "", 1, 500)
    end
    local payload = cjson.decode(response.body)
    if type(payload) ~= "table" or type(payload.modelSummaries) ~= "table" then
        return nil, "invalid Bedrock model listing response"
    end
    local models = {}
    for _, model in ipairs(payload.modelSummaries) do
        for _, modality in ipairs(model.outputModalities or {}) do
            if modality == "TEXT" then
                table.insert(models, { id = model.modelId, object = "model", owned_by = "amazon-bedrock" })
                break
            end
        end
    end
    return { object = "list", data = models }
end

return _M
