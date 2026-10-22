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
            if name == "AWS_CONFIG_FILE" then return "/nonexistent/aws-config" end
            if name == "AWS_ACCESS_KEY_ID" or name == "AWS_SECRET_ACCESS_KEY"
                or name == "AWS_SESSION_TOKEN" or name == "AWS_PROFILE"
                or name == "BEDROCK_AWS_DEFAULT_REGION" or name == "AWS_REGION"
                or name == "AWS_DEFAULT_REGION" then
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
            "openai.gpt-oss-20b-1:0",
            "us.anthropic.claude-opus-4-8",
        }, ids(catalog))
        assert.equals("list", catalog.object)
    end)

    it("prefers global profiles, even over on-demand ids, when global inference is allowed", function()
        local catalog = bedrock.build_catalog({
            model("openai.gpt-oss-20b-1:0", { "ON_DEMAND" }),
            model("anthropic.claude-opus-4-8", { "INFERENCE_PROFILE" }),
            model("meta.llama3-1-8b-instruct-v1:0", { "INFERENCE_PROFILE" }),
            model("amazon.nova-pro-v1:0", { "ON_DEMAND", "INFERENCE_PROFILE" }),
        }, {
            profile("global.anthropic.claude-opus-4-8", "anthropic.claude-opus-4-8"),
            profile("us.anthropic.claude-opus-4-8", "anthropic.claude-opus-4-8"),
            profile("global.meta.llama3-1-8b-instruct-v1:0", "meta.llama3-1-8b-instruct-v1:0"),
            profile("global.amazon.nova-pro-v1:0", "amazon.nova-pro-v1:0"),
        }, "us.", true)
        assert.same({
            "global.amazon.nova-pro-v1:0",
            "global.anthropic.claude-opus-4-8",
            "global.meta.llama3-1-8b-instruct-v1:0",
            "openai.gpt-oss-20b-1:0",
        }, ids(catalog))
    end)

    it("never uses another geography's profile", function()
        local catalog = bedrock.build_catalog({ model("a.b", { "INFERENCE_PROFILE" }) },
            { profile("us.a.b", "a.b"), profile("global.a.b", "a.b") }, "eu.")
        assert.same({}, ids(catalog))
    end)

    it("uses the global profile when the region has no geography prefix and global is allowed", function()
        local catalog = bedrock.build_catalog({ model("a.b", { "INFERENCE_PROFILE" }) },
            { profile("us.a.b", "a.b"), profile("global.a.b", "a.b") }, nil, true)
        assert.same({ "global.a.b" }, ids(catalog))
    end)
end)

describe("bedrock region and global inference settings", function()
    local saved, env, config_file, dict

    local function load(imds)
        local environment = setmetatable({
            os = setmetatable({ getenv = function(name) return env[name] end }, { __index = os }),
        }, { __index = _G })
        dict = {}
        _G.ngx = {
            shared = { bedrock_creds = {
                get = function(_, key) return dict[key] end,
                set = function(_, key, value) dict[key] = value; return true end,
            } },
            log = function() end,
            ERR = 1, NOTICE = 2,
        }
        package.loaded["resty.aws"] = function() return {} end
        package.loaded["resty.aws.request.sign"] = function() return {} end
        package.loaded["resty.http"] = imds and { new = function()
            return {
                set_timeout = function() end,
                request_uri = function(_, url)
                    if url:find("/api/token", 1, true) then return { status = 200, body = "tok" } end
                    return { status = 200, body = imds }
                end,
            }
        end } or {}
        local chunk
        if setfenv then
            chunk = assert(loadfile("lua/bedrock.lua"))
            setfenv(chunk, environment)
        else
            chunk = assert(loadfile("lua/bedrock.lua", "t", environment))
        end
        return chunk()
    end

    local function write_config(text)
        local file = assert(io.open(config_file, "w"))
        file:write(text)
        file:close()
    end

    before_each(function()
        saved = { ngx = _G.ngx, aws = package.loaded["resty.aws"],
            sign = package.loaded["resty.aws.request.sign"], http = package.loaded["resty.http"] }
        config_file = os.tmpname()
        os.remove(config_file)
        env = { AWS_CONFIG_FILE = config_file }
    end)

    after_each(function()
        os.remove(config_file)
        _G.ngx = saved.ngx
        package.loaded["resty.aws"] = saved.aws
        package.loaded["resty.aws.request.sign"] = saved.sign
        package.loaded["resty.http"] = saved.http
    end)

    it("prefers the explicit BEDROCK_AWS_DEFAULT_REGION pin", function()
        write_config("[default]\nregion = eu-west-1\n")
        env.BEDROCK_AWS_DEFAULT_REGION = "eu-central-1"
        env.AWS_REGION = "us-east-1"
        assert.equals("eu-central-1", load("ap-south-1").region())
    end)

    it("reads the region of the active profile from the AWS config file", function()
        write_config("[default]\nregion = us-east-1\n\n[profile dassie]\nregion = us-east-2\n")
        env.AWS_REGION = "us-west-2"
        assert.equals("us-east-1", load().region())
        env.AWS_PROFILE = "dassie"
        assert.equals("us-east-2", load().region())
    end)

    it("accepts a bare [name] profile section", function()
        write_config("[dassie]\nregion = eu-west-3\n")
        env.AWS_PROFILE = "dassie"
        assert.equals("eu-west-3", load().region())
    end)

    it("falls back to instance metadata, then AWS_REGION, then us-east-1", function()
        env.AWS_REGION = "eu-north-1"
        assert.equals("ap-southeast-2", load("ap-southeast-2").region())
        env.AWS_EC2_METADATA_DISABLED = "true"
        assert.equals("eu-north-1", load("ap-southeast-2").region())
        env.AWS_REGION = nil
        env.AWS_DEFAULT_REGION = "ca-central-1"
        assert.equals("ca-central-1", load().region())
        env.AWS_DEFAULT_REGION = nil
        assert.equals("us-east-1", load().region())
    end)

    it("ignores malformed region values", function()
        env.BEDROCK_AWS_DEFAULT_REGION = "evil.com/x"
        write_config("[default]\nregion = us-east-1.attacker\n")
        env.AWS_REGION = "eu-west-1"
        assert.equals("eu-west-1", load("<html>").region())
    end)

    it("caches the resolved region", function()
        env.AWS_REGION = "eu-west-1"
        local bedrock = load()
        assert.equals("eu-west-1", bedrock.region())
        env.AWS_REGION = "us-west-2"
        assert.equals("eu-west-1", bedrock.region())
        assert.equals("eu-west-1", dict.region)
    end)

    it("rejects explicit global profiles unless global inference is enabled", function()
        local cjson = require("cjson")
        local bedrock = load()
        dict["catalog:us-east-1:regional"] = cjson.encode({ object = "list", data = {
            { id = "us.anthropic.claude-opus-4-8" }, { id = "openai.gpt-oss-20b-1:0" } } })
        dict["catalog:us-east-1:global"] = cjson.encode({ object = "list", data = {
            { id = "global.anthropic.claude-opus-4-8" } } })
        assert.is_false(bedrock.global_inference_enabled())
        assert.is_true(bedrock.check_model("us.anthropic.claude-opus-4-8"))
        assert.is_true(bedrock.check_model("openai.gpt-oss-20b-1:0"))
        local ok, err, status, code = bedrock.check_model("global.anthropic.claude-opus-4-8")
        assert.is_nil(ok)
        assert.matches("disabled", err)
        assert.equals(403, status)
        assert.equals("BEDROCK_GLOBAL_INFERENCE_DISABLED", code)
        assert.is_nil(bedrock.check_model("GLOBAL.anthropic.claude-opus-4-8"))
        assert.is_nil(bedrock.check_model(
            "arn:aws:bedrock:us-east-1:123456789012:inference-profile/global.anthropic.claude-opus-4-8"))
        env.BEDROCK_GLOBAL_INFERENCE = "true"
        assert.is_true(bedrock.global_inference_enabled())
        assert.is_true(bedrock.check_model("global.anthropic.claude-opus-4-8"))
    end)

    it("allows only on-demand ids from the catalog", function()
        local cjson = require("cjson")
        local bedrock = load()
        dict["catalog:us-east-1:regional"] = cjson.encode({ object = "list", data = {
            { id = "openai.gpt-oss-20b-1:0" } } })
        assert.is_true(bedrock.check_model("openai.gpt-oss-20b-1:0"))
        for _, id in ipairs({
            "amazon.titan-text-premier-v1:0",
            "arn:aws:bedrock:us-east-1:123456789012:provisioned-model/abc123",
            "arn:aws:sagemaker:us-east-1:123456789012:endpoint/marketplace-llm",
            "arn:aws:bedrock:us-east-1:123456789012:custom-model-deployment/xyz",
            "arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/p1",
            "", 42,
        }) do
            local ok, _, status, code = bedrock.check_model(id)
            assert.is_nil(ok, tostring(id))
            assert.equals(403, status)
            assert.equals("BEDROCK_MODEL_NOT_ALLOWED", code)
        end
    end)

    it("fails closed when the catalog cannot be loaded", function()
        local bedrock = load()
        bedrock.models = function() return nil, "boom" end
        local ok, _, status, code = bedrock.check_model("openai.gpt-oss-20b-1:0")
        assert.is_nil(ok)
        assert.equals(503, status)
        assert.equals("BEDROCK_CATALOG_UNAVAILABLE", code)
    end)
end)

