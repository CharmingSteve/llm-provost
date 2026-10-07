local cjson = require("cjson.safe")
local bedrock = require("bedrock")

local models, err = bedrock.models()
if not models then
    ngx.log(ngx.ERR, "Bedrock model listing failed: ", err or "unknown error")
    ngx.status = ngx.HTTP_SERVICE_UNAVAILABLE
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ error = { message = "Bedrock model listing unavailable", type = "server_error" } }))
    return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
end

ngx.header["Content-Type"] = "application/json"
ngx.say(cjson.encode(models))