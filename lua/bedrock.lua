local cjson = require("cjson.safe")
local AWS = require("resty.aws")
local sign_request = require("resty.aws.request.sign")
local http = require("resty.http")

local _M = {}

local function region()
    return os.getenv("BEDROCK_AWS_DEFAULT_REGION") or os.getenv("AWS_REGION") or "us-east-1"
end

local function signed_headers(method, host, path, body)
    local aws = AWS({
        region = region(),
        endpointPrefix = "bedrock",
        signatureVersion = "v4",
    })
    local access_key = os.getenv("AWS_ACCESS_KEY_ID")
    local secret_key = os.getenv("AWS_SECRET_ACCESS_KEY")
    if access_key == "" then
        access_key = nil
    end
    if secret_key == "" then
        secret_key = nil
    end
    local session_token = os.getenv("AWS_SESSION_TOKEN")
    if session_token == "" then
        session_token = nil
    end
    if access_key and secret_key then
        aws.config.credentials = aws:Credentials({
            accessKeyId = access_key,
            secretAccessKey = secret_key,
            sessionToken = session_token,
        })
    end
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
        return nil, "Bedrock model listing returned status " .. response.status
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