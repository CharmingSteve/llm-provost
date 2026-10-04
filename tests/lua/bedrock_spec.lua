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
            bedrock = package.loaded.bedrock,
        }
        signs, clients = 0, 0
        dict = fake_dict()
        credential_file = os.tmpname()
        local file = assert(io.open(credential_file, "w"))
        file:write("[default]\naws_access_key_id = AKIAFILEKEY1234\naws_secret_access_key = secret1\n")
        file:close()

        os.getenv = function(name)
            if name == "AWS_SHARED_CREDENTIALS_FILE" then return credential_file end
            if name == "AWS_ACCESS_KEY_ID" or name == "AWS_SECRET_ACCESS_KEY"
                or name == "AWS_SESSION_TOKEN" or name == "AWS_PROFILE" then
                return nil
            end
            return saved.os_getenv(name)
        end
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
        package.loaded.bedrock = nil
        bedrock = require("bedrock")
    end)

    after_each(function()
        os.remove(credential_file)
        os.getenv = saved.os_getenv
        _G.ngx = saved.ngx
        package.loaded["resty.aws"] = saved.aws
        package.loaded["resty.aws.request.sign"] = saved.sign
        package.loaded["resty.http"] = saved.http
        package.loaded.bedrock = saved.bedrock
    end)

    local function sign()
        _G.ngx.var = { bedrock_path = "/openai/v1/chat/completions" }
        ngx.req = {
            get_method = function() return "POST" end,
            set_header = function(name, value) ngx.var["h_" .. name] = value end,
        }
        return bedrock.prepare_request("{}")
    end

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
