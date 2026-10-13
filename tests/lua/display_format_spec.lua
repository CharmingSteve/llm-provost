package.path = package.path .. ";lua/?.lua"

local cjson = require("cjson.safe")

-- Loads display_format with REASONING_DISPLAY set to mode (nil = unset),
-- exercising the real read-once-at-load path.
local function load_display_format(mode)
    local function getenv(name)
        if name == "REASONING_DISPLAY" then
            return mode
        end
        return os.getenv(name)
    end
    local environment = setmetatable({
        os = setmetatable({ getenv = getenv }, { __index = os }),
    }, { __index = _G })
    local chunk
    if setfenv then
        chunk = assert(loadfile("lua/display_format.lua"))
        setfenv(chunk, environment)
    else
        chunk = assert(loadfile("lua/display_format.lua", "t", environment))
    end
    return chunk()
end

local display_format = load_display_format(nil)

local function read_fixture(name)
    local file = assert(io.open("tests/fixtures/" .. name, "rb"))
    local value = file:read("*a")
    file:close()
    return value
end

-- Feeds chunks through one splitter and flushes at the end.
local function split_chunks(mode, chunks)
    local splitter = display_format.new_splitter(mode)
    local content, reasoning = {}, {}
    for _, chunk in ipairs(chunks) do
        local c, r = splitter:feed(chunk)
        content[#content + 1] = c
        reasoning[#reasoning + 1] = r
    end
    local c, r = splitter:flush()
    content[#content + 1] = c
    reasoning[#reasoning + 1] = r
    return table.concat(content), table.concat(reasoning)
end

local function transform(mode, kind, chunks)
    local transformer = display_format.new_transformer(mode, kind)
    local out = {}
    for index, chunk in ipairs(chunks) do
        out[#out + 1] = transformer:feed(chunk, index == #chunks)
    end
    return table.concat(out)
end

local function sse_event(content, extra)
    local choice = { index = 0, delta = { content = content }, finish_reason = cjson.null }
    for key, value in pairs(extra or {}) do
        choice[key] = value
    end
    return "data: " .. assert(cjson.encode({
        id = "chatcmpl-test",
        object = "chat.completion.chunk",
        model = "openai.gpt-oss-20b-1:0",
        choices = { choice },
    })) .. "\n\n"
end

local function sse_stream(contents)
    local events = {}
    for _, content in ipairs(contents) do
        events[#events + 1] = sse_event(content)
    end
    events[#events + 1] = sse_event(nil, { delta = {}, finish_reason = "stop" })
    events[#events + 1] = "data: [DONE]\n\n"
    return table.concat(events)
end

-- Parses every SSE event (failing on invalid JSON) and joins the deltas.
local function parse_sse(raw)
    assert.is_truthy(raw:sub(-2) == "\n\n", "stream must end on an event boundary")
    local content, reasoning, events, saw_done = {}, {}, 0, false
    for event in raw:gmatch("(.-)\n\n") do
        local data = assert(event:match("^data: (.*)$"), "unexpected SSE event: " .. event)
        events = events + 1
        if data == "[DONE]" then
            saw_done = true
        else
            local payload = assert(cjson.decode(data), "invalid SSE JSON: " .. data)
            for _, choice in ipairs(payload.choices) do
                local delta = choice.delta or {}
                content[#content + 1] = type(delta.content) == "string" and delta.content or ""
                reasoning[#reasoning + 1] = type(delta.reasoning_content) == "string"
                    and delta.reasoning_content or ""
            end
        end
    end
    return table.concat(content), table.concat(reasoning), events, saw_done
end

local function json_message(body)
    return assert(cjson.decode(body)).choices[1].message
end

local function chat_body(content)
    return assert(cjson.encode({
        id = "chatcmpl-test",
        object = "chat.completion",
        choices = { { index = 0, message = { role = "assistant", content = content }, finish_reason = "stop" } },
    }))
end

-- Mirrors the /llm/ location hooks in default.conf: audit_body.capture reads
-- ngx.arg[1] first, then display_format rewrites the client-bound copy.
local function run_filter_chain(module, content_type, chunks)
    local previous_ngx = _G.ngx
    local previous_access = package.loaded.audit_access
    local headers = { content_type = content_type, content_length = 503 }
    local response = {}
    local audit_partials = {}
    _G.ngx = { ctx = {}, header = headers, var = response, arg = {} }
    package.loaded.audit_access = {
        emit_chunk = function(resp_body)
            audit_partials[#audit_partials + 1] = resp_body
            return true
        end,
    }

    local client = {}
    local ok, err = pcall(function()
        if module.enabled then
            module.header_filter()
        end
        for index, chunk in ipairs(chunks) do
            ngx.arg[1], ngx.arg[2] = chunk, index == #chunks
            require("audit_body").capture(ngx.arg[1], ngx.arg[2])
            if module.enabled then
                ngx.arg[1] = module.body_filter(ngx.arg[1], ngx.arg[2])
            end
            client[#client + 1] = ngx.arg[1]
        end
    end)
    package.loaded.audit_access = previous_access
    _G.ngx = previous_ngx
    assert(ok, err)
    return table.concat(client), response.resp_body, headers, audit_partials
end

local MULTI = "<reasoning>First, analyse.</reasoning>\n\n<reasoning>Then decide.</reasoning>The answer is 5."

describe("display_format configuration", function()
    it("defaults to off when REASONING_DISPLAY is unset or empty", function()
        assert.equals("off", load_display_format(nil).mode)
        assert.is_false(load_display_format(nil).enabled)
        assert.is_false(load_display_format("").enabled)
    end)

    it("accepts openai and think case-insensitively", function()
        assert.equals("openai", load_display_format("OpenAI").mode)
        assert.equals("think", load_display_format("think").mode)
        assert.is_true(load_display_format("think").enabled)
    end)

    it("treats unknown values as off", function()
        local module = load_display_format("verbose")
        assert.equals("off", module.mode)
        assert.is_false(module.enabled)
    end)

    it("only rewrites uncompressed JSON and SSE responses", function()
        assert.equals("sse", display_format.response_kind("text/event-stream; charset=utf-8"))
        assert.equals("json", display_format.response_kind("application/json"))
        assert.equals("json", display_format.response_kind("application/json", "identity"))
        assert.is_nil(display_format.response_kind("application/json", "gzip"))
        assert.is_nil(display_format.response_kind("text/plain"))
        assert.is_nil(display_format.response_kind(nil))
    end)
end)

describe("display_format splitter", function()
    it("splits a single tag pair", function()
        assert.same({ "5", "Think." }, { display_format.split("openai", "<reasoning>Think.</reasoning>5") })
        assert.same(
            { "<think>Think.</think>5", "" },
            { display_format.split("think", "<reasoning>Think.</reasoning>5") }
        )
    end)

    it("merges multiple tag pairs into one reasoning span", function()
        assert.same(
            { "The answer is 5.", "First, analyse.\n\nThen decide." },
            { display_format.split("openai", MULTI) }
        )
        assert.same(
            { "<think>First, analyse.\n\nThen decide.</think>The answer is 5.", "" },
            { display_format.split("think", MULTI) }
        )
    end)

    it("keeps whitespace after the last closing tag as content", function()
        assert.same(
            { "\n\nAnswer", "R" },
            { display_format.split("openai", "<reasoning>R</reasoning>\n\nAnswer") }
        )
    end)

    it("passes plain and empty content through unchanged", function()
        for _, mode in ipairs({ "openai", "think" }) do
            assert.same({ "Just an answer.", "" }, { display_format.split(mode, "Just an answer.") })
            assert.same({ "", "" }, { display_format.split(mode, "") })
        end
    end)

    it("leaves a literal tag later in the answer alone", function()
        local text = "Use a <reasoning> element like <reasoning>x</reasoning>."
        assert.same({ text, "" }, { display_format.split("openai", text) })
        assert.same({ text, "" }, { display_format.split("think", text) })
    end)

    it("does not reopen a tag after the answer has started", function()
        local text = "<reasoning>R</reasoning>Answer <reasoning>quoted</reasoning>"
        assert.same({ "Answer <reasoning>quoted</reasoning>", "R" }, { display_format.split("openai", text) })
    end)

    it("handles an empty reasoning block and a reasoning-only message", function()
        assert.same({ "A", "" }, { display_format.split("openai", "<reasoning></reasoning>A") })
        assert.same({ "", "R" }, { display_format.split("openai", "<reasoning>R</reasoning>") })
        assert.same({ "<think>R</think>", "" }, { display_format.split("think", "<reasoning>R</reasoning>") })
    end)

    it("splits identically at every byte boundary", function()
        local expected = {
            openai = { "The answer is 5.", "First, analyse.\n\nThen decide." },
            think = { "<think>First, analyse.\n\nThen decide.</think>The answer is 5.", "" },
        }
        for mode, want in pairs(expected) do
            for first = 0, #MULTI do
                for second = first, #MULTI do
                    local chunks = { MULTI:sub(1, first), MULTI:sub(first + 1, second), MULTI:sub(second + 1) }
                    local content, reasoning = split_chunks(mode, chunks)
                    assert.equals(want[1], content, mode .. " split at " .. first .. "," .. second)
                    assert.equals(want[2], reasoning, mode .. " split at " .. first .. "," .. second)
                end
            end
        end
    end)

    it("streams one byte at a time without dropping or duplicating bytes", function()
        local chunks = {}
        for index = 1, #MULTI do
            chunks[index] = MULTI:sub(index, index)
        end
        local content, reasoning = split_chunks("openai", chunks)
        local tag_bytes = 2 * (#"<reasoning>" + #"</reasoning>")
        assert.equals(#MULTI - tag_bytes, #content + #reasoning)
        assert.same({ "The answer is 5.", "First, analyse.\n\nThen decide." }, { content, reasoning })
    end)

    it("flushes a partial tag at stream end as literal text", function()
        assert.same({ "<reaso", "" }, { split_chunks("openai", { "<rea", "so" }) })
        assert.same({ "<reaso", "" }, { split_chunks("think", { "<reaso" }) })
        assert.same({ "", "abc</reas" }, { split_chunks("openai", { "<reasoning>abc</re", "as" }) })
        assert.same({ "<think>abc</reas", "" }, { split_chunks("think", { "<reasoning>abc</reas" }) })
        assert.same({ "Hi <reaso", "" }, { split_chunks("openai", { "Hi <reaso" }) })
        assert.same({ " \n", "R" }, { split_chunks("openai", { "<reasoning>R</reasoning> \n" }) })
        assert.same({ "<think>R</think>\n<rea", "" }, { split_chunks("think", { "<reasoning>R</reasoning>\n<rea" }) })
    end)

    it("keeps per-instance state isolated when interleaved", function()
        local first = display_format.new_splitter("openai")
        local second = display_format.new_splitter("openai")
        assert.same({ "", "" }, { first:feed("<reason") })
        assert.same({ "plain ", "" }, { second:feed("plain ") })
        assert.same({ "", "A" }, { first:feed("ing>A") })
        assert.same({ "<reasoning>x", "" }, { second:feed("<reasoning>x") })
        assert.same({ "done", "" }, { first:feed("</reasoning>done") })
        assert.same({ "", "" }, { second:flush() })
        assert.same({ "", "" }, { first:flush() })
    end)
end)

describe("display_format non-streaming JSON", function()
    it("moves reasoning into reasoning_content in openai mode", function()
        local out = transform("openai", "json", { chat_body(MULTI) })
        local message = json_message(out)
        assert.equals("The answer is 5.", message.content)
        assert.equals("First, analyse.\n\nThen decide.", message.reasoning_content)
        assert.equals("assistant", message.role)
    end)

    it("renames tags in think mode", function()
        local message = json_message(transform("think", "json", { chat_body("<reasoning>R</reasoning>A") }))
        assert.equals("<think>R</think>A", message.content)
        assert.is_nil(message.reasoning_content)
    end)

    it("appends to an existing reasoning_content field", function()
        local body = assert(cjson.encode({
            choices = { { message = { content = "<reasoning>B</reasoning>A", reasoning_content = "A-" } } },
        }))
        local message = json_message(transform("openai", "json", { body }))
        assert.equals("A-B", message.reasoning_content)
        assert.equals("A", message.content)
    end)

    it("returns bodies without tags byte-identical", function()
        local bodies = {
            chat_body("Plain answer with a / slash."),
            chat_body(""),
            '{"choices":[{"message":{"content":null,"tool_calls":[]}}],"created":1791921742}',
            '{"error":{"message":"The model is overloaded","type":"server_error","code":503}}',
            '{"message":"Unauthorized"}',
            "upstream timeout",
            "",
        }
        for _, mode in ipairs({ "openai", "think" }) do
            for _, body in ipairs(bodies) do
                assert.equals(body, transform(mode, "json", { body }))
            end
        end
    end)

    it("preserves arrays, nulls and slashes when re-encoding", function()
        local body = '{"choices":[{"logprobs":null,"message":{"content":"<reasoning>R</reasoning>a/b",'
            .. '"tool_calls":[]}}],"usage":{"total_tokens":108}}'
        local out = transform("openai", "json", { body })
        assert.is_truthy(out:find('"tool_calls":[]', 1, true))
        assert.is_truthy(out:find('"logprobs":null', 1, true))
        assert.is_truthy(out:find('"content":"a/b"', 1, true))
    end)

    it("buffers until the body is complete", function()
        local body = chat_body("<reasoning>R</reasoning>A")
        local transformer = display_format.new_transformer("openai", "json")
        assert.equals("", transformer:feed(body:sub(1, 20), false))
        local out = transformer:feed(body:sub(21), true)
        assert.equals("A", json_message(out).content)
    end)

    it("rewrites the recorded Bedrock gpt-oss response", function()
        local fixture = read_fixture("bedrock_gpt_oss_chat.json")
        local message = json_message(transform("openai", "json", { fixture }))
        assert.equals("5", message.content)
        assert.equals('The user asks: "What is 2+3? Answer briefly." So answer "5".', message.reasoning_content)
        assert.is_nil(message.content:find("<reasoning>", 1, true))
        local think = json_message(transform("think", "json", { fixture }))
        assert.equals('<think>The user asks: "What is 2+3? Answer briefly." So answer "5".</think>5', think.content)
    end)
end)

describe("display_format streaming SSE", function()
    local expected = {
        openai = { "The answer is 5.", "First, analyse.\n\nThen decide." },
        think = { "<think>First, analyse.\n\nThen decide.</think>The answer is 5.", "" },
    }

    it("separates reasoning split across deltas at every boundary", function()
        for mode, want in pairs(expected) do
            for split = 0, #MULTI do
                local raw = sse_stream({ MULTI:sub(1, split), MULTI:sub(split + 1) })
                local content, reasoning, _, saw_done = parse_sse(transform(mode, "sse", { raw }))
                assert.equals(want[1], content, mode .. " split at " .. split)
                assert.equals(want[2], reasoning, mode .. " split at " .. split)
                assert.is_true(saw_done)
            end
        end
    end)

    it("produces the same output however the wire bytes are chunked", function()
        local raw = sse_stream({ "<reasoning>Fi", "rst</reaso", "ning><reasoning>B</reasoning>", "Answer" })
        for _, mode in ipairs({ "openai", "think" }) do
            local whole = transform(mode, "sse", { raw })
            for split = 0, #raw do
                assert.equals(whole, transform(mode, "sse", { raw:sub(1, split), raw:sub(split + 1) }))
            end
        end
    end)

    it("passes events without tags through byte-identical", function()
        local raw = ": keep-alive\n\n" .. sse_stream({ "Hello", " world" })
        for _, mode in ipairs({ "openai", "think" }) do
            assert.equals(raw, transform(mode, "sse", { raw }))
        end
    end)

    it("keeps non-data fields and CRLF framing when rewriting", function()
        local prefix = "event: message\r\nid: 7\r\ndata: "
        local raw = prefix .. '{"choices":[{"index":0,"delta":{"content":"<reasoning>R</reasoning>A"}}]}\r\n\r\n'
        local out = transform("openai", "sse", { raw })
        assert.equals(prefix, out:sub(1, #prefix))
        assert.equals("\r\n\r\n", out:sub(-4))
        local payload = assert(cjson.decode(out:match("data: (.-)\r\n")))
        assert.equals("A", payload.choices[1].delta.content)
        assert.equals("R", payload.choices[1].delta.reasoning_content)
    end)

    it("flushes held text into the finish_reason chunk", function()
        local raw = sse_event("<reasoning>R</rea") .. sse_event(nil, { delta = {}, finish_reason = "stop" })
            .. "data: [DONE]\n\n"
        local content, reasoning, events = parse_sse(transform("openai", "sse", { raw }))
        assert.equals("", content)
        assert.equals("R</rea", reasoning)
        assert.equals(3, events)
    end)

    it("emits a synthetic chunk for text held when the stream ends", function()
        local raw = sse_event("Hi") .. sse_event("<rea")
        for _, tail in ipairs({ "data: [DONE]\n\n", "" }) do
            local stream = sse_event("<rea") .. tail
            local content = parse_sse(transform("openai", "sse", { stream }))
            assert.equals("<rea", content)
        end
        local content = parse_sse(transform("think", "sse", { raw }))
        assert.equals("Hi<rea", content)
    end)

    it("frames an unterminated final event before the flushed text", function()
        local raw = sse_event("<reasoning>R</reasoning>") .. 'data: {"choices":[]}'
        local out = transform("think", "sse", { raw })
        local content = parse_sse(out)
        assert.equals("<think>R</think>", content)
    end)

    it("tracks choices by index", function()
        local raw = 'data: {"choices":[{"index":0,"delta":{"content":"<reasoning>A"}},'
            .. '{"index":1,"delta":{"content":"plain"}}]}\n\n'
            .. 'data: {"choices":[{"index":1,"delta":{"content":" text"}},'
            .. '{"index":0,"delta":{"content":"</reasoning>B"}}]}\n\n'
        local out = transform("openai", "sse", { raw })
        local first, second = out:match("data: (.-)\n\ndata: (.-)\n\n")
        first, second = assert(cjson.decode(first)), assert(cjson.decode(second))
        assert.equals("A", first.choices[1].delta.reasoning_content)
        assert.equals("plain", first.choices[2].delta.content)
        assert.equals(" text", second.choices[1].delta.content)
        assert.equals("B", second.choices[2].delta.content)
    end)

    it("rewrites the recorded Bedrock gpt-oss stream and keeps the usage chunk", function()
        local fixture = read_fixture("bedrock_gpt_oss_stream.sse")
        local usage_event = fixture:match("(data: {\"choices\":%[%][^\n]*\n\n)")
        assert.is_truthy(usage_event)
        local reasoning_text = 'The user asks: "What is 2+3? Answer briefly." So answer "5."'

        local out = transform("openai", "sse", { fixture })
        local content, reasoning, _, saw_done = parse_sse(out)
        assert.equals("5", content)
        assert.equals(reasoning_text, reasoning)
        assert.is_true(saw_done)
        assert.is_truthy(out:find(usage_event, 1, true))

        local think = parse_sse(transform("think", "sse", { fixture }))
        assert.equals("<think>" .. reasoning_text .. "</think>5", think)
    end)
end)

describe("display_format in the /llm/ body filter chain", function()
    local fixture_json = read_fixture("bedrock_gpt_oss_chat.json")
    local fixture_sse = read_fixture("bedrock_gpt_oss_stream.sse")

    local function chunked(raw, size)
        local chunks = {}
        for offset = 1, #raw, size do
            chunks[#chunks + 1] = raw:sub(offset, offset + size - 1)
        end
        return chunks
    end

    it("leaves every response byte-identical when off", function()
        local module = load_display_format(nil)
        for _, case in ipairs({
            { "application/json", fixture_json },
            { "text/event-stream", fixture_sse },
        }) do
            local client, _, headers = run_filter_chain(module, case[1], chunked(case[2], 37))
            assert.equals(case[2], client)
            assert.equals(503, headers.content_length)
        end
    end)

    for _, mode in ipairs({ "openai", "think" }) do
        it("audits the original tags while rewriting the client copy (" .. mode .. ", JSON)", function()
            local module = load_display_format(mode)
            local client, audit, headers = run_filter_chain(module, "application/json", chunked(fixture_json, 64))
            assert.is_truthy(audit:find("<reasoning>The user asks", 1, true))
            assert.is_nil(client:find("<reasoning>", 1, true))
            assert.is_nil(headers.content_length)
            local message = json_message(client)
            if mode == "openai" then
                assert.equals("5", message.content)
                assert.is_truthy(message.reasoning_content:find("^The user asks"))
            else
                assert.is_truthy(message.content:find("^<think>The user asks"))
            end
        end)

        it("audits the original tags while rewriting the client copy (" .. mode .. ", SSE)", function()
            local module = load_display_format(mode)
            local client, audit = run_filter_chain(module, "text/event-stream", chunked(fixture_sse, 50))
            local audited = assert(cjson.decode(audit))
            assert.is_truthy(audited.content:find("^<reasoning>The user asks"))
            assert.is_nil(client:find("<reasoning>", 1, true))
            local content, reasoning = parse_sse(client)
            if mode == "openai" then
                assert.equals("5", content)
                assert.is_truthy(reasoning:find("^The user asks"))
            else
                assert.is_truthy(content:find("^<think>The user asks"))
            end
        end)
    end

    it("passes compressed and non-JSON responses through untouched", function()
        local module = load_display_format("openai")
        local previous_ngx = _G.ngx
        _G.ngx = {
            ctx = {},
            header = { content_type = "application/json", content_encoding = "gzip", content_length = 9 },
        }
        module.header_filter()
        assert.equals("\31\139binary", module.body_filter("\31\139binary", true))
        assert.equals(9, ngx.header.content_length)
        _G.ngx = previous_ngx

        local client = run_filter_chain(module, "text/plain", { "<reasoning>R</reasoning>A" })
        assert.equals("<reasoning>R</reasoning>A", client)
    end)

    it("keeps concurrent requests isolated in ngx.ctx", function()
        local module = load_display_format("openai")
        local previous_ngx = _G.ngx
        local first = { ctx = {}, header = { content_type = "text/event-stream" } }
        local second = { ctx = {}, header = { content_type = "text/event-stream" } }
        local raw_first = sse_stream({ "<reasoning>One", "</reasoning>A" })
        local raw_second = sse_stream({ "<reasoning>Two", "</reasoning>B" })
        local out_first, out_second = {}, {}
        local half_first, half_second = math.floor(#raw_first / 2), math.floor(#raw_second / 2)

        _G.ngx = first
        out_first[1] = module.body_filter(raw_first:sub(1, half_first), false)
        _G.ngx = second
        out_second[1] = module.body_filter(raw_second:sub(1, half_second), false)
        _G.ngx = first
        out_first[2] = module.body_filter(raw_first:sub(half_first + 1), true)
        _G.ngx = second
        out_second[2] = module.body_filter(raw_second:sub(half_second + 1), true)
        _G.ngx = previous_ngx

        local content, reasoning = parse_sse(table.concat(out_first))
        assert.same({ "A", "One" }, { content, reasoning })
        content, reasoning = parse_sse(table.concat(out_second))
        assert.same({ "B", "Two" }, { content, reasoning })
    end)
end)
