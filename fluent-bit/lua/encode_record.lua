local function encode_string(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(character)
        local escapes = {
            ['"'] = '\\"',
            ['\\'] = '\\\\',
            ['\b'] = '\\b',
            ['\f'] = '\\f',
            ['\n'] = '\\n',
            ['\r'] = '\\r',
            ['\t'] = '\\t',
        }
        return escapes[character] or string.format("\\u%04x", character:byte())
    end) .. '"'
end

local function is_array(value)
    local count = 0
    local highest = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return false, 0
        end
        count = count + 1
        highest = math.max(highest, key)
    end
    return count == highest, highest
end

local encode_value

local function encode_table(value)
    local array, length = is_array(value)
    local parts = {}
    if array then
        for index = 1, length do
            parts[index] = encode_value(value[index])
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end

    for key, child in pairs(value) do
        parts[#parts + 1] = encode_string(tostring(key)) .. ":" .. encode_value(child)
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ",") .. "}"
end

encode_value = function(value)
    local value_type = type(value)
    if value_type == "nil" then
        return "null"
    end
    if value_type == "boolean" then
        return value and "true" or "false"
    end
    if value_type == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "null"
        end
        return tostring(value)
    end
    if value_type == "table" then
        return encode_table(value)
    end
    return encode_string(tostring(value))
end

function encode_record(_, timestamp, record)
    return 2, timestamp, { schema_json = encode_value(record) }
end