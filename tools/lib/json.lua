-- A small JSON encoder/decoder in plain Lua 5.4, for the tools and the unit
-- test stub (the server has node.json; the game has jsonEncode/jsonDecode).
-- Encodes tables with consecutive integer keys 1..n as arrays, everything
-- else as objects with string keys (sorted, so output is stable); an empty
-- table is {}. Decodes the full grammar; numbers with a fraction or exponent
-- become floats, others integers.
--
--   json.encode(value, opts?) -> text     opts = { pretty = true | <indent> }
--   json.decode(text) -> value            raises on malformed input
--   json.null                             the decoded null (a sentinel); encode() writes nil/null for it

local M = {}

M.null = setmetatable({}, { __tostring = function() return "null" end })

local escapes = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encode_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return escapes[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if math.type(k) ~= "integer" or k < 1 then return false end
        n = n + 1
    end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true, n
end

local function encode(v, indent, level, out)
    local tv = type(v)
    if v == nil or v == M.null then
        out[#out + 1] = "null"
    elseif tv == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            out[#out + 1] = "null"
        elseif math.type(v) == "integer" then
            out[#out + 1] = tostring(v)
        else
            local s = string.format("%.17g", v)
            if not s:find("[%.eEn]") then s = s .. ".0" end
            out[#out + 1] = s
        end
    elseif tv == "string" then
        out[#out + 1] = encode_string(v)
    elseif tv == "table" then
        local arr, n = is_array(v)
        local nl = indent and ("\n" .. string.rep(" ", indent * (level + 1))) or ""
        local close = indent and ("\n" .. string.rep(" ", indent * level)) or ""
        if arr then
            if n == 0 then
                out[#out + 1] = "[]"
                return
            end
            out[#out + 1] = "["
            for i = 1, n do
                if i > 1 then out[#out + 1] = "," end
                out[#out + 1] = nl
                encode(v[i], indent, level + 1, out)
            end
            out[#out + 1] = close .. "]"
        else
            local keys = {}
            for k in pairs(v) do
                if type(k) ~= "string" and type(k) ~= "number" then error("json: unsupported key type " .. type(k)) end
                keys[#keys + 1] = k
            end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            out[#out + 1] = "{"
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                out[#out + 1] = nl .. encode_string(tostring(k)) .. (indent and ": " or ":")
                encode(v[k], indent, level + 1, out)
            end
            out[#out + 1] = close .. "}"
        end
    else
        error("json: cannot encode a " .. tv)
    end
end

function M.encode(v, opts)
    local indent = nil
    if type(opts) == "table" and opts.pretty then
        indent = opts.pretty == true and 2 or tonumber(opts.pretty) or 2
    end
    local out = {}
    encode(v, indent, 0, out)
    return table.concat(out)
end

-- decoder --------------------------------------------------------------------

local function skip(s, i)
    return s:find("[^ \t\r\n]", i) or (#s + 1)
end

local decode_value

local function decode_string(s, i)
    -- i is at the opening quote
    local buf = {}
    i = i + 1
    while true do
        local c = s:sub(i, i)
        if c == "" then error("json: unterminated string") end
        if c == '"' then return table.concat(buf), i + 1 end
        if c == "\\" then
            local e = s:sub(i + 1, i + 1)
            local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
            if map[e] then
                buf[#buf + 1] = map[e]
                i = i + 2
            elseif e == "u" then
                local hex = s:sub(i + 2, i + 5)
                if not hex:match("^%x%x%x%x$") then error("json: bad \\u escape") end
                local cp = tonumber(hex, 16)
                i = i + 6
                if cp >= 0xD800 and cp <= 0xDBFF and s:sub(i, i + 1) == "\\u" then
                    local lo = tonumber(s:sub(i + 2, i + 5), 16)
                    if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                        i = i + 6
                    end
                end
                buf[#buf + 1] = utf8.char(cp)
            else
                error("json: bad escape \\" .. e)
            end
        else
            buf[#buf + 1] = c
            i = i + 1
        end
    end
end

local function decode_number(s, i)
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if not num or num == "" or num == "-" then error("json: bad number at " .. i) end
    local v
    if num:find("[%.eE]") then v = tonumber(num) else v = math.tointeger(tonumber(num)) or tonumber(num) end
    if v == nil then error("json: bad number " .. num) end
    return v, i + #num
end

decode_value = function(s, i)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "{" then
        local obj = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while true do
            i = skip(s, i)
            if s:sub(i, i) ~= '"' then error("json: expected a key at " .. i) end
            local key
            key, i = decode_string(s, i)
            i = skip(s, i)
            if s:sub(i, i) ~= ":" then error("json: expected ':' at " .. i) end
            local v
            v, i = decode_value(s, i + 1)
            obj[key] = v
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "," then i = i + 1
            elseif d == "}" then return obj, i + 1
            else error("json: expected ',' or '}' at " .. i) end
        end
    elseif c == "[" then
        local arr = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while true do
            local v
            v, i = decode_value(s, i)
            arr[#arr + 1] = v
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "," then i = i + 1
            elseif d == "]" then return arr, i + 1
            else error("json: expected ',' or ']' at " .. i) end
        end
    elseif c == '"' then
        return decode_string(s, i)
    elseif s:sub(i, i + 3) == "true" then return true, i + 4
    elseif s:sub(i, i + 4) == "false" then return false, i + 5
    elseif s:sub(i, i + 3) == "null" then return nil, i + 4
    else
        return decode_number(s, i)
    end
end

function M.decode(text)
    if type(text) ~= "string" then error("json: expected a string") end
    local v, i = decode_value(text, 1)
    i = skip(text, i)
    if i <= #text then error("json: trailing characters at " .. i) end
    return v
end

return M
