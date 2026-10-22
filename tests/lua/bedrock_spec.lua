package.path = package.path .. ";lua/?.lua"

describe("bedrock credential caching", function()
    local bedrock, dict, signs, clients, credential_file, saved

    local function fake_dict()
        local store = {}
        return {
            get = function(_, key) return store[key] end,
            set = function(_, key, value) store[key] = value; return true end,
            delete = function(_, key) store[key] = nil end,
        }
    end

    before_each(function()
        saved = {
            os_getenv = os.getenv,
            ngx = _G.ngx,
            aws = package.loaded["resty.aws"],
            sign = package.loaded["resty.aws.request.sign"],
            http = package.loaded["resty.http"],
        }
        signs, clients = 0, 0
        dict = fake_dict()
        credential_file = os.tmpname()
        local file = assert(io.open(credential_file, "w"))
        file:write("[default]\naws_access_key_id = AKIAFILEKEY1234\naws_secret_access_key = secret1\n")
        file:close()

        local function getenv(name)
            if name == "AWS_SHARED_CREDENTIALS_FILE" then return credential_file end
            if name == "AWS_ACCESS_KEY_ID" or name == "AWS_SECRET_ACCESS_KEY"
                or name == "AWS_SESSION_TOKEN" or name == "AWS_PROFILE" then
                return nil
            end
            return saved.os_getenv(name)
        end
        local environment = setmetatable({
            os = setmetatable({ getenv = getenv }, { __index = os }),
        }, { __index = _G })
        _G.ngx = {
            shared = { bedrock_creds = dict },
            log = function() end,
            INFO = 1,
        }
        package.loaded["resty.aws"] = setmetatable({}, {
            __call = function()
                clients = clients + 1
                return {
                    config = {},
                    Credentials = function(_, creds) return creds end,
                }
            end,
        })
        package.loaded["resty.aws.request.sign"] = function(config)
            signs = signs + 1
            return { headers = { Authorization = "AWS4 " .. config.credentials.accessKeyId } }
        end
        package.loaded["resty.http"] = {}
        local chunk
        if setfenv then
            chunk = assert(loadfile("lua/bedrock.lua"))
            setfenv(chunk, environment)
        else
            chunk = assert(loadfile("lua/bedrock.lua", "t", environment))
        end
        bedrock = chunk()
    end)

    after_each(function()
        os.remove(credential_file)
        _G.ngx = saved.ngx
        package.loaded["resty.aws"] = saved.aws
        package.loaded["resty.aws.request.sign"] = saved.sign
        package.loaded["resty.http"] = saved.http
    end)

    local function sign()
        _G.ngx.var = { bedrock_path = "/openai/v1/chat/completions" }
        ngx.req = {
            get_method = function() return "POST" end,
            set_header = function(name, value) ngx.var["h_" .. name] = value end,
        }
        return bedrock.prepare_request("{}")
    end

    it("isolates the environment mock from the global os library", function()
        assert.equals(saved.os_getenv, os.getenv)
        assert.is_truthy(sign())
        assert.equals("AWS4 AKIAFILEKEY1234", ngx.var.h_Authorization)
        assert.equals(saved.os_getenv, os.getenv)
    end)

    it("reads the credentials file once across requests", function()
        assert.equals("bedrock-runtime.us-east-1.amazonaws.com", sign())
        assert.equals("AWS4 AKIAFILEKEY1234", ngx.var.h_Authorization)
        os.remove(credential_file) -- a second read would now fail
        assert.equals("bedrock-runtime.us-east-1.amazonaws.com", sign())
        assert.equals(2, signs)
        assert.equals(1, clients)
    end)

    it("re-resolves credentials after invalidate()", function()
        sign()
        bedrock.invalidate()
        local file = assert(io.open(credential_file, "w"))
        file:write("[default]\naws_access_key_id = AKIAROTATED5678\naws_secret_access_key = secret2\n")
        file:close()
        sign()
        assert.equals("AWS4 AKIAROTATED5678", ngx.var.h_Authorization)
    end)

    it("still parses the default profile from the ini file", function()
        local access_key = sign()
        assert.is_truthy(access_key)
        assert.equals("AWS4 AKIAFILEKEY1234", ngx.var.h_Authorization)
    end)

    it("returns an error and caches nothing when credentials are missing", function()
        os.remove(credential_file)
        local host, err = sign()
        assert.is_nil(host)
        assert.matches("no AWS credentials resolved", err)
        assert.is_nil(dict:get("credentials"))
    end)

    it("works without a shared dict", function()
        ngx.shared = {}
        assert.is_truthy(sign())
    end)
end)

describe("bedrock model catalog", function()
    local bedrock

    setup(function()
        package.loaded["resty.aws"] = function() return {} end
        package.loaded["resty.aws.request.sign"] = function() return {} end
        package.loaded["resty.http"] = {}
        package.loaded.bedrock = nil
        bedrock = require("bedrock")
    end)

    local function profile(id, base)
        return { inferenceProfileId = id, status = "ACTIVE",
            models = { { modelArn = "arn:aws:bedrock:us-east-1::foundation-model/" .. base } } }
    end

    local function model(id, types, extra)
        local entry = { modelId = id, inferenceTypesSupported = types, inputModalities = { "TEXT" },
            outputModalities = { "TEXT" }, modelLifecycle = { status = "ACTIVE" } }
        for key, value in pairs(extra or {}) do entry[key] = value end
        return entry
    end

    local function ids(catalog)
        local out = {}
        for _, item in ipairs(catalog.data) do out[#out + 1] = item.id end
        return out
    end

    it("lists the id Converse accepts for each chat model and drops the rest", function()
        local catalog = bedrock.build_catalog({
            model("openai.gpt-oss-20b-1:0", { "ON_DEMAND" }),
            model("anthropic.claude-opus-4-8", { "INFERENCE_PROFILE" }),
            model("meta.llama3-1-8b-instruct-v1:0", { "INFERENCE_PROFILE" }),
            model("only.provisioned", { "PROVISIONED" }),
            model("amazon.nova-2-sonic-v1:0", { "ON_DEMAND" }, { outputModalities = { "SPEECH", "TEXT" } }),
            model("cohere.rerank-v3-5:0", { "ON_DEMAND" }),
            model("twelvelabs.pegasus-1-5-v1:0", { "INFERENCE_PROFILE" }),
            model("writer.palmyra-x5-v1:0", { "ON_DEMAND" }, { modelLifecycle = { status = "LEGACY" } }),
            model("amazon.titan-embed-text-v2:0", { "ON_DEMAND" }, { outputModalities = { "EMBEDDING" } }),
            model("no.profile.yet", { "INFERENCE_PROFILE" }),
        }, {
            profile("global.anthropic.claude-opus-4-8", "anthropic.claude-opus-4-8"),
            profile("us.anthropic.claude-opus-4-8", "anthropic.claude-opus-4-8"),
            profile("global.meta.llama3-1-8b-instruct-v1:0", "meta.llama3-1-8b-instruct-v1:0"),
            { inferenceProfileId = "us.meta.llama3-1-8b-instruct-v1:0", status = "INACTIVE",
                models = { { modelArn = "arn:x::foundation-model/meta.llama3-1-8b-instruct-v1:0" } } },
        }, "us.")
        assert.same({
            "global.meta.llama3-1-8b-instruct-v1:0",
            "openai.gpt-oss-20b-1:0",
            "us.anthropic.claude-opus-4-8",
        }, ids(catalog))
        assert.equals("list", catalog.object)
    end)

    it("uses the global profile when the region has no geography prefix", function()
        local catalog = bedrock.build_catalog({ model("a.b", { "INFERENCE_PROFILE" }) },
            { profile("us.a.b", "a.b"), profile("global.a.b", "a.b") }, nil)
        assert.same({ "global.a.b" }, ids(catalog))
    end)
end)

