package.path = package.path .. ";lua/?.lua"

local cjson = require("cjson.safe")

local ROUTES = {
    bedrock = "https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1",
    ollama = "http://xps:11434/v1",
    vllm = "http://vllm-host:8000/v1",
}
local ROUTES_JSON = assert(cjson.encode(ROUTES))

-- Loads a fresh copy of a module with os.getenv overridden by env (falling
-- back to the real environment), exercising the read-once-at-load paths.
local function load_with_env(path, env)
    local function getenv(name)
        if env[name] ~= nil then
            return env[name]
        end
        return os.getenv(name)
    end
    local environment = setmetatable({
        os = setmetatable({ getenv = getenv }, { __index = os }),
    }, { __index = _G })
    local chunk
    if setfenv then
        chunk = assert(loadfile(path))
        setfenv(chunk, environment)
    else
        chunk = assert(loadfile(path, "t", environment))
    end
    return chunk()
end

local function load_aggregate(env)
    env = env or {}
    if env.BEDROCK_ENABLED == nil then
        env.BEDROCK_ENABLED = "true"
    end
    return load_with_env("lua/llm_aggregate.lua", env)
end

-- Upstream model listings keyed by backend name; a string value is the
-- error the probe returns ("timeout" for a hung backend).
local upstream, upstream_calls, upstream_auth, connects, sockets_created
local clock, logs, said

local function install_mocks()
    upstream = {
        bedrock = { "openai.gpt-oss-20b-1:0" },
        ollama = { "gpt-oss:20b", "llama3.1:8b" },
        vllm = { "gpt-oss:20b" },
    }
    upstream_calls = {}
    upstream_auth = {}
    connects = {}
    sockets_created = 0
    clock = 1000
    logs = {}
    said = nil

    local function listing(name)
        local value = upstream[name]
        upstream_calls[name] = (upstream_calls[name] or 0) + 1
        if type(value) == "string" or type(value) == "number" then
            return nil, value
        end
        local data = {}
        for _, id in ipairs(value) do
            data[#data + 1] = { id = id, object = "model" }
        end
        return data
    end

    package.loaded["resty.http"] = {
        new = function()
            return {
                set_timeout = function() end,
                request_uri = function(_, url, opts)
                    for name, base in pairs(ROUTES) do
                        if url == base .. "/models" then
                            upstream_auth[name] = opts.headers.Authorization
                            local data, err = listing(name)
                            if type(err) == "number" then
                                return { status = err, body = "{}" }
                            end
                            if not data then
                                return nil, err
                            end
                            return { status = 200, body = cjson.encode({ object = "list", data = data }) }
                        end
                    end
                    return nil, "connection refused"
                end,
            }
        end,
    }
    package.loaded.bedrock = {
        check_model = function() return true end,
        models = function()
            local data, err = listing("bedrock")
            if type(err) == "number" then
                return nil, "Bedrock model listing returned status " .. err .. " body: {}"
            end
            if not data then
                return nil, err
            end
            return { object = "list", data = data }
        end,
        runtime_host = function() return "bedrock-runtime.us-east-1.amazonaws.com" end,
    }
    package.loaded.audit_error = { emit = function() end }

    _G.ngx = {
        WARN = "warn",
        INFO = "info",
        HTTP_SERVICE_UNAVAILABLE = 503,
        now = function() return clock end,
        -- A C builtin, like the real ngx.sleep.
        sleep = os.clock,
        log = function(level, ...)
            logs[#logs + 1] = { level = level, message = table.concat({ ... }) }
        end,
        ctx = {},
        var = {},
        header = {},
        say = function(value) said = value end,
        exit = function(status) return status end,
        thread = {
            spawn = function(fn, ...)
                assert(type(fn) == "function" and debug.getinfo(fn, "S").what ~= "C",
                    "ngx.thread.spawn requires a Lua function")
                local function pack(...) return { n = select("#", ...), ... } end
                return { results = pack(fn(...)) }
            end,
            wait = function(handle)
                return true, (unpack or rawget(table, "unpack"))(handle.results, 1, handle.results.n)
            end,
            kill = function() return true end,
        },
        socket = {
            tcp = function()
                sockets_created = sockets_created + 1
                local sock = {}
                function sock:settimeout(ms) self.timeout = ms end
                function sock:connect(host, port)
                    connects[#connects + 1] = { host = host, port = port, timeout = self.timeout }
                    local name = host == "xps" and "ollama" or host:match("^bedrock") and "bedrock" or "vllm"
                    if type(upstream[name]) == "string" then
                        return nil, upstream[name]
                    end
                    return 1
                end
                function sock:close() end
                return sock
            end,
        },
    }
end

local function ids(listing)
    local result = {}
    for _, model in ipairs(listing.data) do
        result[#result + 1] = model.id
    end
    return result
end

local function logged(level, needle)
    local count = 0
    for _, entry in ipairs(logs) do
        if entry.level == level and entry.message:find(needle, 1, true) then
            count = count + 1
        end
    end
    return count
end

local original_ngx
local mocked = { "resty.http", "bedrock", "audit_error", "audit_body", "routes", "rules_engine",
    "governance_rejection", "llm_aggregate" }

before_each(function()
    original_ngx = _G.ngx
    install_mocks()
end)

after_each(function()
    _G.ngx = original_ngx
    for _, name in ipairs(mocked) do
        package.loaded[name] = nil
    end
end)

describe("llm_aggregate prefix split", function()
    local aggregate

    before_each(function() aggregate = load_aggregate() end)

    it("splits on the first slash only", function()
        assert.same({ "ollama", "library/llama3:8b" }, { aggregate.split_model("ollama/library/llama3:8b") })
    end)

    it("passes ids containing ':' and '.' through verbatim", function()
        local backend, model = aggregate.split_model("bedrock/openai.gpt-oss-20b-1:0")
        assert.equals("bedrock", backend)
        assert.equals("openai.gpt-oss-20b-1:0", model)
        local resolved = aggregate.resolve('{"model":"ollama/gpt-oss:20b"}', ROUTES)
        assert.equals("gpt-oss:20b", resolved.upstream_model)
        assert.equals("ollama/gpt-oss:20b", resolved.model)
    end)

    it("rejects an id without a slash as LLM_MODEL_UNPREFIXED, never guessing a backend", function()
        local resolved, status, code = aggregate.resolve('{"model":"gpt-oss:20b"}', ROUTES)
        assert.is_nil(resolved)
        assert.equals(400, status)
        assert.equals("LLM_MODEL_UNPREFIXED", code)
    end)

    it("rejects a missing model and an empty remainder as LLM_MODEL_UNPREFIXED", function()
        assert.equals("LLM_MODEL_UNPREFIXED", select(3, aggregate.resolve("{}", ROUTES)))
        assert.equals("LLM_MODEL_UNPREFIXED", select(3, aggregate.resolve("not json", ROUTES)))
        assert.equals("LLM_MODEL_UNPREFIXED", select(3, aggregate.resolve('{"model":"ollama/"}', ROUTES)))
    end)

    it("rejects an unknown prefix as LLM_BACKEND_UNKNOWN", function()
        local resolved, status, code, message = aggregate.resolve('{"model":"openai/gpt-5"}', ROUTES)
        assert.is_nil(resolved)
        assert.equals(404, status)
        assert.equals("LLM_BACKEND_UNKNOWN", code)
        assert.truthy(message:find("openai", 1, true))
    end)

    it("prefers a backend's key header over the client's Authorization", function()
        local headers = { ["x-provost-backend-key-openwire"] = "ow" , ["x-provost-backend-key-ollama"] = "" }
        assert.equals("Bearer ow", aggregate.backend_authorization(headers, "openwire", "Bearer llm"))
        assert.equals("Bearer llm", aggregate.backend_authorization(headers, "ollama", "Bearer llm"))
        assert.equals("Bearer llm", aggregate.backend_authorization(headers, "vllm", "Bearer llm"))
        assert.is_nil(aggregate.backend_authorization(nil, "vllm", nil))
    end)

    it("renders errors in the structured error.code shape", function()
        aggregate.reject(404, "LLM_BACKEND_UNKNOWN", "Unknown LLM backend: openai")
        local body = cjson.decode(said)
        assert.equals("LLM_BACKEND_UNKNOWN", body.error.code)
        assert.equals("Unknown LLM backend: openai", body.error.message)
        assert.equals(404, ngx.status)
    end)

    it("strips only the prefix in the upstream body, leaving other bytes alone", function()
        local body = '{"model": "bedrock/openai.gpt-oss-20b-1:0","stream":true,"messages":[]}'
        local resolved = aggregate.resolve(body, ROUTES)
        assert.equals('{"model": "openai.gpt-oss-20b-1:0","stream":true,"messages":[]}',
            aggregate.strip_model(body, resolved))
    end)

    it("strips a prefix written with an escaped slash", function()
        local body = '{"model":"ollama\\/gpt-oss:20b","messages":[]}'
        local resolved = aggregate.resolve(body, ROUTES)
        assert.equals('{"model":"gpt-oss:20b","messages":[]}', aggregate.strip_model(body, resolved))
    end)
end)

describe("llm_aggregate listing", function()
    it("merges every backend with its route key as prefix, same model listed twice", function()
        local aggregate = load_aggregate()
        local listing = aggregate.list_models(ROUTES)
        assert.same({
            "bedrock/openai.gpt-oss-20b-1:0",
            "ollama/gpt-oss:20b",
            "ollama/llama3.1:8b",
            "vllm/gpt-oss:20b",
        }, ids(listing))
        assert.equals("list", listing.object)
        assert.equals("model", listing.data[1].object)
    end)

    it("silently omits a backend that does not answer", function()
        local aggregate = load_aggregate()
        upstream.ollama = "timeout"
        local listing = aggregate.list_models(ROUTES)
        assert.same({ "bedrock/openai.gpt-oss-20b-1:0", "vllm/gpt-oss:20b" }, ids(listing))
    end)

    it("serves a cached list within the TTL without contacting upstreams", function()
        local aggregate = load_aggregate()
        aggregate.list_models(ROUTES)
        clock = clock + 30
        aggregate.list_models(ROUTES)
        assert.equals(1, upstream_calls.ollama)
        assert.equals(1, upstream_calls.bedrock)
        clock = clock + 31
        aggregate.list_models(ROUTES)
        assert.equals(2, upstream_calls.ollama)
    end)

    it("omits a disabled Bedrock backend without marking it down", function()
        local aggregate = load_aggregate({ BEDROCK_ENABLED = "false" })
        local listing = aggregate.list_models(ROUTES)
        assert.same({ "ollama/gpt-oss:20b", "ollama/llama3.1:8b", "vllm/gpt-oss:20b" }, ids(listing))
        assert.is_nil(upstream_calls.bedrock)
        assert.equals(0, #logs)
    end)

    it("sends each backend its own key header, others the client's Authorization", function()
        local aggregate = load_aggregate()
        aggregate.list_models(ROUTES, "Bearer llm-key", {
            ["x-provost-backend-key-ollama"] = "ollama-key",
            ["x-provost-backend-key-openwire"] = "openwire-key",
        })
        assert.equals("Bearer ollama-key", upstream_auth.ollama)
        assert.equals("Bearer llm-key", upstream_auth.vllm)
    end)

    it("encodes an empty listing as a JSON array", function()
        local aggregate = load_aggregate()
        local encoded = aggregate.encode_listing({ object = "list", data = {} })
        assert.truthy(encoded:find('"data":[]', 1, true))
    end)
end)

describe("llm_aggregate backend availability", function()
    local LIST_TTL = 46

    it("marks a failed backend down for the cooldown and skips probing it", function()
        local aggregate = load_aggregate()
        upstream.ollama = "timeout"
        aggregate.list_models(ROUTES)
        assert.is_true(aggregate.is_down("ollama"))
        assert.equals(1, upstream_calls.ollama)

        upstream.ollama = { "gpt-oss:20b" }
        for _ = 1, 3 do
            clock = clock + LIST_TTL
            local listing = aggregate.list_models(ROUTES)
            assert.same({ "bedrock/openai.gpt-oss-20b-1:0", "vllm/gpt-oss:20b" }, ids(listing))
        end
        assert.equals(1, upstream_calls.ollama)
        assert.equals(4, upstream_calls.vllm)
    end)

    it("logs exactly one WARN on down and one recovery line, nothing per poll", function()
        local aggregate = load_aggregate()
        upstream.ollama = "timeout"
        for _ = 1, 4 do
            aggregate.list_models(ROUTES)
            clock = clock + LIST_TTL
        end
        assert.equals(1, logged("warn", "backend ollama marked down (probe timeout)"))
        assert.equals(1, #logs)

        upstream.ollama = { "gpt-oss:20b" }
        clock = clock + 180
        local listing = aggregate.list_models(ROUTES)
        assert.truthy(ids(listing)[2] == "ollama/gpt-oss:20b")
        clock = clock + LIST_TTL
        aggregate.list_models(ROUTES)
        assert.equals(1, logged("warn", "backend ollama recovered"))
        assert.equals(2, #logs)
    end)

    it("re-probes lazily on the first listing after the cooldown expires", function()
        local aggregate = load_aggregate()
        upstream.ollama = "connection refused"
        aggregate.list_models(ROUTES)
        clock = clock + 179
        assert.is_true(aggregate.is_down("ollama"))
        clock = clock + 2
        assert.is_false(aggregate.is_down("ollama"))
        assert.equals(1, upstream_calls.ollama)
        aggregate.list_models(ROUTES)
        assert.equals(2, upstream_calls.ollama)
        assert.is_true(aggregate.is_down("ollama"))
        assert.equals(2, logged("warn", "backend ollama marked down (probe failed: connection refused)"))
    end)

    it("honors PROVOST_BACKEND_COOLDOWN_SECONDS", function()
        local aggregate = load_aggregate({ PROVOST_BACKEND_COOLDOWN_SECONDS = "60" })
        assert.equals(60, aggregate.cooldown_seconds)
        upstream.ollama = "timeout"
        aggregate.list_models(ROUTES)
        clock = clock + 59
        assert.is_true(aggregate.is_down("ollama"))
        clock = clock + 2
        assert.is_false(aggregate.is_down("ollama"))
    end)

    it("defaults the cooldown to 180 seconds and ignores invalid values", function()
        assert.equals(180, load_aggregate().cooldown_seconds)
        assert.equals(180, load_aggregate({ PROVOST_BACKEND_COOLDOWN_SECONDS = "soon" }).cooldown_seconds)
    end)

    it("omits a backend answering 4xx without marking it down", function()
        local aggregate = load_aggregate()
        upstream.ollama = 401
        upstream.bedrock = 403
        local listing = aggregate.list_models(ROUTES)
        assert.same({ "vllm/gpt-oss:20b" }, ids(listing))
        assert.is_false(aggregate.is_down("ollama"))
        assert.is_false(aggregate.is_down("bedrock"))
        assert.equals(0, #logs)
    end)

    it("marks a backend answering 5xx down", function()
        local aggregate = load_aggregate()
        upstream.ollama = 502
        aggregate.list_models(ROUTES)
        assert.equals(1, logged("warn", "backend ollama marked down (probe failed: status 502)"))
    end)

    it("marks a route with an invalid URL down once and then skips it", function()
        local aggregate = load_aggregate()
        local routes = { ollama = ROUTES.ollama, typo = "xps:11434/v1" }
        aggregate.list_models(routes)
        clock = clock + LIST_TTL
        aggregate.list_models(routes)
        assert.equals(1, logged("warn", "backend typo marked down (invalid route URL)"))
    end)
end)

describe("llm_aggregate fail-fast dispatch", function()
    it("returns false on an unreachable backend after a short connect test", function()
        local aggregate = load_aggregate()
        upstream.ollama = "connection refused"
        assert.is_false(aggregate.ensure_available("ollama", ROUTES.ollama))
        assert.equals(1, #connects)
        assert.equals("xps", connects[1].host)
        assert.equals(11434, connects[1].port)
        assert.is_true(connects[1].timeout <= 1000)
        assert.equals(1, logged("warn", "backend ollama marked down (connect failed: connection refused)"))
    end)

    it("fails instantly with no connect test when the backend is already marked down", function()
        local aggregate = load_aggregate()
        upstream.ollama = "timeout"
        aggregate.list_models(ROUTES)
        assert.is_false(aggregate.ensure_available("ollama", ROUTES.ollama))
        assert.equals(0, sockets_created)
    end)

    it("connect-tests Bedrock against the signed runtime host", function()
        local aggregate = load_aggregate()
        assert.is_true(aggregate.ensure_available("bedrock", ROUTES.bedrock))
        assert.same({ host = "bedrock-runtime.us-east-1.amazonaws.com", port = 443, timeout = 1000 }, connects[1])
    end)
end)

describe("llm_aggregate response re-prefix", function()
    local audit_body = require("audit_body")

    -- Mirrors the /llm/v1/ location hooks in default.conf: audit capture,
    -- then display_format (off here), then the re-prefix.
    local function run_filters(content_type, chunks)
        local aggregate = load_aggregate()
        package.loaded.llm_aggregate = aggregate
        ngx.header = { content_type = content_type }
        ngx.ctx = {
            llm_aggregate = {
                backend = "bedrock",
                model = "bedrock/openai.gpt-oss-20b-1:0",
                upstream_model = "openai.gpt-oss-20b-1:0",
            },
        }
        ngx.var = {}
        package.loaded.audit_access = { emit_chunk = function() return true end }
        aggregate.header_filter()
        local out = {}
        for index, chunk in ipairs(chunks) do
            local eof = index == #chunks
            audit_body.capture(chunk, eof)
            out[#out + 1] = aggregate.body_filter(chunk, eof)
        end
        package.loaded.audit_access = nil
        return table.concat(out), ngx.var.resp_body
    end

    it("rewrites a non-streaming body for the client, audit keeps the upstream id", function()
        local body = '{"id":"c1","object":"chat.completion","model":"openai.gpt-oss-20b-1:0",'
            .. '"choices":[{"index":0,"message":{"role":"assistant","content":"hi"}}]}'
        local client, audit = run_filters("application/json", { body:sub(1, 40), body:sub(41) })
        assert.equals(body:gsub("openai%.gpt%-oss", "bedrock/openai.gpt-oss", 1), client)
        assert.truthy(audit:find("openai.gpt-oss-20b-1:0", 1, true))
        assert.falsy(audit:find("bedrock/openai", 1, true))
        assert.is_nil(ngx.header.content_length)
    end)

    it("rewrites the model in every SSE chunk, audit keeps the upstream id", function()
        local function event(content)
            return "data: " .. cjson.encode({
                id = "c1", object = "chat.completion.chunk", model = "openai.gpt-oss-20b-1:0",
                choices = { { index = 0, delta = { content = content } } },
            }) .. "\n\n"
        end
        local stream = event("Hel") .. event("lo") .. "data: [DONE]\n\n"
        local client, audit = run_filters("text/event-stream", {
            stream:sub(1, 25), stream:sub(26, 140), stream:sub(141),
        })
        local _, prefixed = client:gsub('"model":"bedrock/openai.gpt%-oss%-20b%-1:0"', "")
        assert.equals(2, prefixed)
        assert.truthy(client:find("data: [DONE]\n\n", 1, true))
        assert.equals(stream:gsub("openai%.gpt%-oss", "bedrock/openai.gpt-oss"), client)
        assert.falsy(audit:find("bedrock/openai", 1, true))
    end)

    it("passes responses through untouched before dispatch", function()
        local aggregate = load_aggregate()
        ngx.ctx = {}
        assert.equals("abc", aggregate.body_filter("abc", true))
    end)
end)

describe("http_policy aggregate dispatch", function()
    local checks, set_body, signed, set_headers, cleared

    -- Runs http_policy.lua for one request; returns ngx for inspection.
    local function run(uri, body, backend_name, request_headers)
        checks, set_body, signed, set_headers, cleared = {}, nil, nil, {}, {}
        request_headers = request_headers or {}
        package.loaded.audit_body = { compact_request = function(raw) return raw end }
        package.loaded.routes = { get = function() return nil end }
        package.loaded.rules_engine = {
            check_request = function(method, request_uri, request_body)
                checks[#checks + 1] = { method = method, body = request_body }
                return true, nil, request_body
            end,
        }
        package.loaded.bedrock = setmetatable({
            prepare_request = function(signed_body)
                signed = signed_body
                return "bedrock-runtime.us-east-1.amazonaws.com"
            end,
        }, { __index = package.loaded.bedrock })
        package.loaded.llm_aggregate = package.loaded.llm_aggregate or load_aggregate()

        ngx.HTTP_FORBIDDEN, ngx.HTTP_UNAUTHORIZED = 403, 401
        ngx.HTTP_INTERNAL_SERVER_ERROR, ngx.HTTP_NOT_FOUND = 500, 404
        ngx.shared = {}
        ngx.ctx = {}
        ngx.header = {}
        ngx.status = nil
        ngx.var = { uri = uri, request_id = "r", backend_name = backend_name }
        ngx.decode_base64 = function() return nil end
        ngx.req = {
            get_headers = function() return request_headers end,
            get_method = function() return "POST" end,
            read_body = function() end,
            get_body_data = function() return body end,
            set_body_data = function(value) set_body = value end,
            set_header = function(name, value) set_headers[name] = value end,
            clear_header = function(name) cleared[#cleared + 1] = name end,
        }
        load_with_env("lua/http_policy.lua", { LLM_ROUTES_JSON = ROUTES_JSON, BEDROCK_ENABLED = "true" })
        return ngx
    end

    it("routes a prefixed request through the same pipeline as the per-backend path", function()
        local direct_body = '{"model":"gpt-oss:20b","messages":[]}'
        run("/llm/ollama/v1/chat/completions", direct_body, "ollama")
        local direct = { target = ngx.var.llm_target_url, checks = checks }

        local body = '{"model":"ollama/gpt-oss:20b","messages":[]}'
        run("/llm/v1/chat/completions", body)
        assert.equals(direct.target, ngx.var.llm_target_url)
        assert.equals("http://xps:11434/v1/chat/completions", ngx.var.llm_target_url)
        assert.equals(1, #checks)
        assert.equals(#direct.checks, #checks)
        assert.equals("POST", checks[1].method)
        -- Audit and rules see the id the user selected; the upstream gets it stripped.
        assert.equals(body, checks[1].body)
        assert.equals(body, ngx.var.req_body)
        assert.equals(direct_body, set_body)
        assert.equals("ollama/gpt-oss:20b", ngx.ctx.llm_aggregate.model)
    end)

    it("signs the stripped body for a Bedrock-prefixed request", function()
        local body = '{"model":"bedrock/openai.gpt-oss-20b-1:0","messages":[{"role":"user","content":"hi"}]}'
        run("/llm/v1/chat/completions", body)
        -- The upstream copy is the stripped id translated to a Converse request.
        local converse = require("cjson.safe").decode(signed)
        assert.same({ { role = "user", content = { { text = "hi" } } } }, converse.messages)
        assert.is_nil(converse.model)
        assert.equals("/model/openai.gpt-oss-20b-1%3A0/converse", ngx.var.bedrock_path)
        assert.equals("https://bedrock-runtime.us-east-1.amazonaws.com/model/openai.gpt-oss-20b-1%3A0/converse",
            ngx.var.llm_target_url)
        assert.equals(body, ngx.var.req_body)
        assert.equals("openai.gpt-oss-20b-1:0", ngx.ctx.bedrock_converse.model)
    end)

    it("sends the selected backend only its own key and strips every key header", function()
        local keys = {
            ["x-provost-backend-key-ollama"] = "ollama-key",
            ["x-provost-backend-key-openwire"] = "openwire-key",
            authorization = "Bearer llm-key",
        }
        run("/llm/v1/chat/completions", '{"model":"ollama/gpt-oss:20b"}', nil, keys)
        assert.equals("Bearer ollama-key", set_headers.Authorization)
        table.sort(cleared)
        assert.same({ "x-provost-backend-key-ollama", "x-provost-backend-key-openwire" }, cleared)

        run("/llm/v1/chat/completions", '{"model":"vllm/gpt-oss:20b"}', nil, keys)
        assert.is_nil(set_headers.Authorization)
        assert.equals(2, #cleared)
    end)

    it("leaves per-backend requests without aggregate state", function()
        run("/llm/ollama/v1/chat/completions", '{"model":"gpt-oss:20b"}', "ollama",
            { ["x-provost-backend-key-ollama"] = "ollama-key" })
        assert.is_nil(ngx.ctx.llm_aggregate)
        assert.is_nil(set_body)
        assert.same({}, set_headers)
        assert.same({}, cleared)
        assert.equals(0, sockets_created)
    end)

    it("answers an unprefixed id with 400 LLM_MODEL_UNPREFIXED before any rules", function()
        run("/llm/v1/chat/completions", '{"model":"gpt-oss:20b"}')
        assert.equals(400, ngx.status)
        assert.equals("LLM_MODEL_UNPREFIXED", cjson.decode(said).error.code)
        assert.equals(0, #checks)
    end)

    it("answers an unknown prefix with 404 LLM_BACKEND_UNKNOWN", function()
        run("/llm/v1/chat/completions", '{"model":"openai/gpt-5"}')
        assert.equals(404, ngx.status)
        assert.equals("LLM_BACKEND_UNKNOWN", cjson.decode(said).error.code)
    end)

    it("answers an unreachable backend with an immediate 503 PROVOST_BACKEND_DOWN", function()
        upstream.ollama = "connection refused"
        run("/llm/v1/chat/completions", '{"model":"ollama/gpt-oss:20b"}')
        assert.equals(503, ngx.status)
        assert.equals("PROVOST_BACKEND_DOWN", cjson.decode(said).error.code)
        assert.is_nil(set_body)
        assert.is_nil(ngx.ctx.llm_aggregate)
        assert.equals(1, sockets_created)

        run("/llm/v1/chat/completions", '{"model":"ollama/gpt-oss:20b"}')
        assert.equals(503, ngx.status)
        assert.equals(1, sockets_created)
        assert.equals(1, logged("warn", "backend ollama marked down"))
    end)

    it("lets the aggregate listing through without resolving a backend", function()
        run("/llm/v1/models", "")
        assert.is_nil(ngx.status)
        assert.equals(1, #checks)
        assert.is_nil(ngx.ctx.llm_aggregate)
    end)
end)
