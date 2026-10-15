local cjson = require("cjson.safe")
local llm_aggregate = require("llm_aggregate")

local routes = llm_aggregate.routes()
if not routes then
    ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ error = "LLM backend routing is not configured" }))
    return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

local listing = llm_aggregate.list_models(routes, ngx.var.http_authorization, ngx.req.get_headers())
ngx.header["Content-Type"] = "application/json"
ngx.say(llm_aggregate.encode_listing(listing))
