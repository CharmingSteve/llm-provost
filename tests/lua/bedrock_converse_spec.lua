package.path = package.path .. ";lua/?.lua"

local cjson = require("cjson.safe")
local converse = require("bedrock_converse")

local function frame(event_type, payload, message_type)
    local function header(name, value)
        return string.char(#name) .. name .. string.char(7)
            .. string.char(math.floor(#value / 256), #value % 256) .. value
    end
    local headers = header(":event-type", event_type) .. header(":message-type", message_type or "event")
    local total = 16 + #headers + #payload
    local function u32(n)
        return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
            math.floor(n / 256) % 256, n % 256)
    end
    return u32(total) .. u32(#headers) .. "\0\0\0\0" .. headers .. payload .. "\0\0\0\0"
end

local function data_events(sse)
    local events = {}
    for line in sse:gmatch("[^\r\n]+") do
        local data = line:match("^data: (.+)$")
        if data and data ~= "[DONE]" then
            events[#events + 1] = cjson.decode(data)
        end
    end
    return events
end

describe("bedrock converse request translation", function()
    local function translate(request)
        local result, err = converse.translate_request(cjson.encode(request))
        assert.is_truthy(result, err)
        return result, cjson.decode(result.body)
    end

    it("maps system, user and sampling parameters", function()
        local result, body = translate({
            model = "us.anthropic.claude-opus-4-8", max_tokens = 50, temperature = 0.2, top_p = 0.9, stop = "END",
            messages = {
                { role = "system", content = "be brief" },
                { role = "user", content = "hi" },
            },
        })
        assert.equals("/model/us.anthropic.claude-opus-4-8/converse", result.path)
        assert.same({ { text = "be brief" } }, body.system)
        assert.same({ { role = "user", content = { { text = "hi" } } } }, body.messages)
        assert.same({ maxTokens = 50, temperature = 0.2, topP = 0.9, stopSequences = { "END" } }, body.inferenceConfig)
    end)

    it("escapes the model id in the path and selects the stream endpoint", function()
        local result = translate({ model = "amazon.nova-pro-v1:0", stream = true,
            messages = { { role = "user", content = "hi" } } })
        assert.equals("/model/amazon.nova-pro-v1%3A0/converse-stream", result.path)
        assert.is_true(result.state.stream)
    end)

    it("merges consecutive same-role messages and converts tool history", function()
        local _, body = translate({
            model = "m",
            messages = {
                { role = "user", content = "a" },
                { role = "user", content = "b" },
                { role = "assistant", content = "", tool_calls = { {
                    id = "t1", type = "function", ["function"] = { name = "lookup", arguments = '{"q":1}' } } } },
                { role = "tool", tool_call_id = "t1", content = "result" },
            },
        })
        assert.equals(3, #body.messages)
        assert.equals(2, #body.messages[1].content)
        assert.same({ toolUseId = "t1", name = "lookup", input = { q = 1 } }, body.messages[2].content[1].toolUse)
        assert.equals("user", body.messages[3].role)
        assert.equals("t1", body.messages[3].content[1].toolResult.toolUseId)
    end)

    it("converts tools and tool_choice", function()
        local _, body = translate({
            model = "m", messages = { { role = "user", content = "x" } },
            tool_choice = "required",
            tools = { { type = "function", ["function"] = {
                name = "get_weather", description = "d",
                parameters = { type = "object", properties = {}, required = cjson.empty_array } } } },
        })
        assert.equals("get_weather", body.toolConfig.tools[1].toolSpec.name)
        assert.same({}, body.toolConfig.tools[1].toolSpec.inputSchema.json.required)
        assert.same({ any = {} }, body.toolConfig.toolChoice)
    end)

    it("converts base64 images and rejects remote image urls", function()
        local _, body = translate({ model = "m", messages = { { role = "user", content = {
            { type = "text", text = "see" },
            { type = "image_url", image_url = { url = "data:image/png;base64,AAAA" } },
        } } } })
        assert.same({ image = { format = "png", source = { bytes = "AAAA" } } }, body.messages[1].content[2])
        local result, err = converse.translate_request(cjson.encode({ model = "m", messages = { { role = "user",
            content = { { type = "image_url", image_url = { url = "http://x/y.png" } } } } } }))
        assert.is_nil(result)
        assert.matches("base64", err)
    end)

    it("rejects malformed requests with a client message", function()
        assert.is_nil(converse.translate_request("not json"))
        assert.is_nil(converse.translate_request('{"messages":[]}'))
        local result, err = converse.translate_request('{"model":"m","messages":[{"role":"tool","content":"x"}]}')
        assert.is_nil(result)
        assert.matches("tool_call_id", err)
        assert.is_nil(converse.translate_request('{"model":"m","messages":[{"role":"system","content":"s"}]}'))
    end)
end)

describe("bedrock converse response translation", function()
    it("converts text, reasoning, tool calls and usage", function()
        local raw = cjson.encode({
            output = { message = { role = "assistant", content = {
                { reasoningContent = { reasoningText = { text = "think" } } },
                { text = "hello" },
                { toolUse = { toolUseId = "t1", name = "f", input = { a = 1 } } },
            } } },
            stopReason = "tool_use",
            usage = { inputTokens = 3, outputTokens = 4, totalTokens = 7 },
        })
        local out = cjson.decode(converse.convert_response(raw, { model = "bedrock/x" }))
        assert.equals("chat.completion", out.object)
        assert.equals("bedrock/x", out.model)
        assert.equals("hello", out.choices[1].message.content)
        assert.equals("think", out.choices[1].message.reasoning_content)
        assert.equals("tool_calls", out.choices[1].finish_reason)
        assert.equals('{"a":1}', out.choices[1].message.tool_calls[1]["function"].arguments)
        assert.same({ prompt_tokens = 3, completion_tokens = 4, total_tokens = 7 }, out.usage)
    end)

    it("maps stop reasons", function()
        local function reason(stop)
            local raw = cjson.encode({ output = { message = { role = "assistant", content = { { text = "x" } } } },
                stopReason = stop })
            return cjson.decode(converse.convert_response(raw, { model = "m" })).choices[1].finish_reason
        end
        assert.equals("stop", reason("end_turn"))
        assert.equals("length", reason("max_tokens"))
        assert.equals("content_filter", reason("guardrail_intervened"))
    end)

    it("shapes AWS errors as OpenAI errors", function()
        local out = cjson.decode(converse.convert_error('{"message":"nope"}', 429, "ThrottlingException:http://x"))
        assert.equals("nope", out.error.message)
        assert.equals("rate_limit_error", out.error.type)
        assert.equals("ThrottlingException", out.error.code)
        assert.equals("server_error", cjson.decode(converse.convert_error("", 500, nil)).error.type)
    end)
end)

describe("bedrock converse event stream", function()
    local function run(frames, state, chunk_size)
        local ctx = { bedrock_converse = state }
        _G.ngx = { ctx = ctx, header = { content_type = "application/vnd.amazon.eventstream" }, status = 200,
            var = { request_id = "rid" } }
        converse.header_filter()
        local blob, out = table.concat(frames), {}
        chunk_size = chunk_size or #blob
        local pos = 1
        repeat
            local piece = blob:sub(pos, pos + chunk_size - 1)
            pos = pos + chunk_size
            out[#out + 1] = converse.body_filter(piece, pos > #blob)
        until pos > #blob
        return table.concat(out)
    end

    local function json(value) return cjson.encode(value) end
    local base = {
        frame("messageStart", json({ role = "assistant" })),
        frame("contentBlockDelta", json({ contentBlockIndex = 0, delta = { text = "Hel" } })),
        frame("contentBlockDelta", json({ contentBlockIndex = 0, delta = { text = "lo" } })),
        frame("contentBlockStart", json({ contentBlockIndex = 1,
            start = { toolUse = { toolUseId = "t1", name = "f" } } })),
        frame("contentBlockDelta", json({ contentBlockIndex = 1, delta = { toolUse = { input = '{"a":1}' } } })),
        frame("messageStop", json({ stopReason = "tool_use" })),
        frame("metadata", json({ usage = { inputTokens = 1, outputTokens = 2 } })),
    }

    it("converts frames to OpenAI chunks even when split at arbitrary byte boundaries", function()
        for _, size in ipairs({ 1, 7, 50, 100000 }) do
            local out = run(base, { model = "bedrock/m", stream = true, include_usage = true }, size)
            assert.equals("text/event-stream", ngx.header.content_type)
            local events = data_events(out)
            local text, args = "", ""
            for _, event in ipairs(events) do
                local choice = event.choices[1]
                if choice and choice.delta.content then text = text .. choice.delta.content end
                local call = choice and choice.delta.tool_calls and choice.delta.tool_calls[1]
                if call and call["function"].arguments then args = args .. call["function"].arguments end
            end
            assert.equals("Hello", text)
            assert.equals('{"a":1}', args)
            assert.equals("tool_calls", events[#events - 1].choices[1].finish_reason)
            assert.equals(2, events[#events].usage.completion_tokens)
            assert.matches("data: %[DONE%]\n\n$", out)
        end
    end)

    it("omits the usage chunk unless requested", function()
        local out = run(base, { model = "m", stream = true })
        for _, event in ipairs(data_events(out)) do assert.is_nil(event.usage) end
    end)

    it("reports exception frames as an error event", function()
        local out = run({ frame("throttlingException", json({ message = "slow down" }), "exception") },
            { model = "m", stream = true })
        local event = data_events(out)[1]
        assert.equals("slow down", event.error.message)
        assert.equals("rate_limit_error", event.error.type)
    end)

    it("fails closed on corrupt framing", function()
        local out = run({ string.rep("\255", 40) }, { model = "m", stream = true })
        assert.equals("server_error", data_events(out)[1].error.type)
    end)

    it("does not terminate a truncated stream with [DONE]", function()
        local out = run({ base[1], base[2] }, { model = "m", stream = true })
        assert.is_nil(out:find("[DONE]", 1, true))
    end)

    it("buffers and converts non-streaming JSON, and rewrites error bodies", function()
        _G.ngx = { ctx = { bedrock_converse = { model = "m" } }, header = { content_type = "application/json" },
            status = 200, var = {} }
        converse.header_filter()
        local raw = cjson.encode({ output = { message = { role = "assistant", content = { { text = "ok" } } } },
            stopReason = "end_turn" })
        assert.equals("", converse.body_filter(raw:sub(1, 10), false))
        local out = cjson.decode(converse.body_filter(raw:sub(11), true))
        assert.equals("ok", out.choices[1].message.content)

        _G.ngx = { ctx = { bedrock_converse = { model = "m" } }, header = { content_type = "application/json",
            ["x-amzn-ErrorType"] = "ValidationException:" }, status = 400, var = {} }
        converse.header_filter()
        local err = cjson.decode(converse.body_filter('{"message":"bad"}', true))
        assert.equals("bad", err.error.message)
        assert.equals("invalid_request_error", err.error.type)
    end)

    it("is a no-op for requests that were not translated", function()
        _G.ngx = { ctx = {}, header = {}, status = 200, var = {} }
        converse.header_filter()
        assert.equals("raw", converse.body_filter("raw", true))
    end)
end)
