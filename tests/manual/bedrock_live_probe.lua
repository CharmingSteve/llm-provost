-- Live AWS test: incurs small inference charges and may use cross-region profiles.
-- From the repository root, using the existing proxy container:
-- docker exec -i llm-provost resty \
--   --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' \
--   -e 'assert(loadfile("/dev/stdin"))()' < tests/manual/bedrock_live_probe.lua
local cjson = require("cjson.safe")
local AWS = require("resty.aws")
local sign_request = require("resty.aws.request.sign")
local http = require("resty.http")
local signing_utils = require("resty.aws.request.signatures.utils")

local region = os.getenv("BEDROCK_AWS_DEFAULT_REGION") or os.getenv("AWS_REGION") or "us-east-1"
local profile = os.getenv("AWS_PROFILE")
if not profile or profile == "" then profile = "default" end
local control_host = "bedrock." .. region .. ".amazonaws.com"
local runtime_host = "bedrock-runtime." .. region .. ".amazonaws.com"

local function credentials()
    local access = os.getenv("AWS_ACCESS_KEY_ID")
    local secret = os.getenv("AWS_SECRET_ACCESS_KEY")
    local token = os.getenv("AWS_SESSION_TOKEN")
    if access and access ~= "" and secret and secret ~= "" then
        return access, secret, token ~= "" and token or nil
    end
    local path = os.getenv("AWS_SHARED_CREDENTIALS_FILE") or "/home/provost/.aws/credentials"
    local file = assert(io.open(path, "r"), "cannot open AWS shared credentials file")
    local section, values = nil, {}
    for line in file:lines() do
        local heading = line:match("^%s*%[(.-)%]%s*$")
        if heading then
            section = heading
        elseif section == profile then
            local key, value = line:match("^%s*([%w_]+)%s*=%s*(%S+)%s*$")
            if key then values[key] = value end
        end
    end
    file:close()
    assert(values.aws_access_key_id and values.aws_secret_access_key,
        "selected AWS profile lacks static credentials")
    return values.aws_access_key_id, values.aws_secret_access_key, values.aws_session_token
end

local access, secret, token = credentials()
local aws = AWS({ region = region, endpointPrefix = "bedrock", signatureVersion = "v4" })
aws.config.credentials = aws:Credentials({
    accessKeyId = access, secretAccessKey = secret, sessionToken = token,
})

local function request(method, host, path, payload, query, stream)
    local body = payload and assert(cjson.encode(payload)) or ""
    local signed = assert(sign_request(aws.config, {
        method = method, host = host, port = 443, path = path,
        -- Bedrock SigV4 double-encodes percent escapes in native model URL paths.
        canonicalURI = signing_utils.canonicalise_path(path):gsub("%%", "%%25"),
        query = query, body = body,
        headers = {
            ["Content-Type"] = "application/json",
            Accept = stream and "text/event-stream" or "application/json",
        },
    }))
    local client = http.new()
    client:set_timeouts(10000, 10000, 90000)
    local started = ngx.now()
    local response, err = client:request_uri(
        "https://" .. host .. path .. (query and ("?" .. query) or ""), {
            method = method, headers = signed.headers, body = body ~= "" and body or nil,
            ssl_server_name = host, ssl_verify = true, keepalive = false,
        })
    ngx.update_time()
    return response, err, math.floor((ngx.now() - started) * 1000)
end

local function listing(path, field, parameters)
    local items, next_token, seen = {}, nil, {}
    repeat
        local query = parameters or ""
        if next_token then
            assert(not seen[next_token], "AWS repeated a pagination token")
            seen[next_token] = true
            query = query .. (query ~= "" and "&" or "") .. "nextToken=" .. ngx.escape_uri(next_token)
        end
        local response, err = request("GET", control_host, path, nil, query ~= "" and query or nil)
        assert(response, err)
        assert(response.status == 200,
            "discovery failed: HTTP " .. response.status .. " " .. (response.body or ""):sub(1, 600))
        local decoded = assert(cjson.decode(response.body))
        assert(type(decoded[field]) == "table", "invalid AWS listing: " .. field)
        for _, item in ipairs(decoded[field]) do items[#items + 1] = item end
        next_token = decoded.nextToken
        if next_token == cjson.null then next_token = nil end
        assert(next_token == nil or type(next_token) == "string", "invalid AWS pagination token")
    until not next_token or next_token == ""
    return items
end

local foundation = listing("/foundation-models", "modelSummaries")
local profiles = listing("/inference-profiles", "inferenceProfileSummaries", "typeEquals=SYSTEM_DEFINED")
local models_by_id, profiles_by_model = {}, {}
for _, model in ipairs(foundation) do models_by_id[model.modelId] = model end
for _, inference_profile in ipairs(profiles) do
    if inference_profile.status == "ACTIVE" then
        for _, model in ipairs(inference_profile.models or {}) do
            -- Profile summaries contain modelArn, not modelId.
            local base = (model.modelArn or ""):match(":foundation%-model/(.+)$")
            if base then
                profiles_by_model[base] = profiles_by_model[base] or {}
                profiles_by_model[base][inference_profile.inferenceProfileId] = true
            end
        end
    end
end

local selected = {
    "openai.gpt-oss-20b-1:0",
    "openai.gpt-oss-120b-1:0",
    "meta.llama4-scout-17b-instruct-v1:0",
    "amazon.nova-lite-v1:0",
    "mistral.mistral-small-2402-v1:0",
    "anthropic.claude-haiku-4-5-20251001-v1:0",
}
local configured = os.getenv("BEDROCK_PROBE_MODELS_JSON")
if configured then
    selected = assert(cjson.decode(configured), "invalid BEDROCK_PROBE_MODELS_JSON")
    assert(type(selected) == "table" and #selected > 0, "expected a nonempty model ID array")
end
local geographic_prefix = ({ us = "us.", eu = "eu.", ap = "apac." })[region:match("^(%a+)%-")]
local report = {
    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    region = region,
    credential_profile = profile,
    foundation_count = #foundation,
    system_profile_count = #profiles,
    prompt = "Reply with just the word OK.",
    max_output_tokens = 64,
    models = {},
    results = {},
}

local function validate_chat(body, stream)
    if not stream then
        local decoded = cjson.decode(body)
        local choice = type(decoded) == "table" and type(decoded.choices) == "table"
            and decoded.choices[1]
        return type(choice) == "table" and type(choice.message) == "table"
            and choice.message.role == "assistant" and not decoded.error
    end
    local chunks, finished, done = 0, false, false
    for line in body:gmatch("[^\r\n]+") do
        local data = line:match("^data:%s*(.+)$")
        if data == "[DONE]" then
            done = true
        elseif data then
            local decoded = cjson.decode(data)
            if type(decoded) ~= "table" or decoded.error then return false end
            if type(decoded.choices) == "table" and decoded.choices[1] then
                local choice = decoded.choices[1]
                if type(choice.delta) ~= "table" then return false end
                chunks = chunks + 1
                if type(choice.finish_reason) == "string" then finished = true end
            end
        elseif line:match("^event:%s*error") then
            return false
        end
    end
    return chunks > 0 and finished and done
end

local function probe(base, id, kind, api)
    local stream = api == "chat_stream"
    local path, payload
    if api == "converse" then
        path = "/model/" .. ngx.escape_uri(id) .. "/converse"
        payload = {
            messages = { { role = "user", content = { { text = report.prompt } } } },
            inferenceConfig = { maxTokens = report.max_output_tokens },
        }
    else
        path = "/openai/v1/chat/completions"
        payload = {
            model = id, messages = { { role = "user", content = report.prompt } },
            max_completion_tokens = report.max_output_tokens, stream = stream,
        }
    end
    io.stderr:write(api .. " " .. id .. " ... ")
    io.stderr:flush()
    local response, err, elapsed = request("POST", runtime_host, path, payload, nil, stream)
    local result = {
        base_model_id = base, invocation_id = id, id_kind = kind, api = api,
        elapsed_ms = elapsed, status = response and response.status or 0, success = false,
    }
    if not response then
        result.error = err
    elseif response.status >= 200 and response.status < 300 then
        if api == "converse" then
            local decoded = cjson.decode(response.body)
            local message = type(decoded) == "table" and type(decoded.output) == "table"
                and decoded.output.message
            result.success = type(message) == "table" and message.role == "assistant"
                and type(message.content) == "table" and #message.content > 0
        else
            result.success = validate_chat(response.body, stream)
        end
        if not result.success then result.error = "HTTP success but invalid/incomplete response shape" end
    else
        local decoded = cjson.decode(response.body or "")
        local error_value = type(decoded) == "table" and (decoded.error or decoded.message)
        if type(error_value) == "table" then error_value = error_value.message end
        result.error = tostring(error_value or response.body or ""):sub(1, 800)
    end
    io.stderr:write(tostring(result.status) .. (result.success and " PASS" or " FAIL") .. "\n")
    report.results[#report.results + 1] = result
end

for _, base in ipairs(selected) do
    assert(type(base) == "string" and base ~= "", "invalid model ID")
    local model = models_by_id[base]
    local discovered = {}
    for id in pairs(profiles_by_model[base] or {}) do discovered[#discovered + 1] = id end
    table.sort(discovered)
    report.models[#report.models + 1] = {
        id = base, discovered = model ~= nil,
        inference_types = model and model.inferenceTypesSupported or {},
        profiles = discovered,
    }
    local variants = { { id = base, kind = "base" } }
    for _, id in ipairs(discovered) do
        local regional = geographic_prefix and id:sub(1, #geographic_prefix) == geographic_prefix
        if id:sub(1, 7) == "global." or regional then
            variants[#variants + 1] = { id = id, kind = "discovered_profile" }
        end
    end
    if geographic_prefix and not (profiles_by_model[base] or {})[geographic_prefix .. base] then
        variants[#variants + 1] = { id = geographic_prefix .. base, kind = "unlisted_prefix_negative_control" }
    end
    for _, variant in ipairs(variants) do
        for _, api in ipairs({ "chat", "chat_stream", "converse" }) do
            probe(base, variant.id, variant.kind, api)
        end
    end
end
print(assert(cjson.encode(report)))
