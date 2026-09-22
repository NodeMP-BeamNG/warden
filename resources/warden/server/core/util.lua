-- core.util: small pure helpers shared by every module. Nothing here touches
-- node.* except `now()` (the server clock) so the unit tests can drive them
-- with plain values.

local M = {}

-- unix seconds (integer); the stub clock in the tests, os.time otherwise
function M.now()
    if node and node.server and node.server.unixTime then
        return math.floor(node.server.unixTime())
    end
    return os.time()
end

function M.trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- a string without control characters, cut to max bytes on a UTF-8 boundary
function M.clean(s, max)
    s = tostring(s or ""):gsub("%c", "")
    max = max or 256
    if #s <= max then return s end
    local i = max + 1
    while i > 1 do
        i = i - 1
        local b = s:byte(i)
        if b < 0x80 or b >= 0xC0 then break end
    end
    return s:sub(1, i - 1)
end

function M.is_int(v)
    return math.type(v) == "integer"
end

-- "30m", "2h", "7d", "90s", "45" (minutes) -> seconds; nil when unreadable
function M.parse_duration(text)
    text = M.trim(text):lower()
    if text == "" then return nil end
    local n, unit = text:match("^(%d+)([smhdw]?)$")
    if not n then return nil end
    n = tonumber(n)
    local mult = { [""] = 60, s = 1, m = 60, h = 3600, d = 86400, w = 604800 }
    return n * mult[unit]
end

-- seconds -> "2h 5m" style text
function M.format_duration(sec)
    sec = math.floor(tonumber(sec) or 0)
    if sec <= 0 then return "0s" end
    local parts = {}
    local units = { { 86400, "d" }, { 3600, "h" }, { 60, "m" }, { 1, "s" } }
    for _, u in ipairs(units) do
        if sec >= u[1] then
            parts[#parts + 1] = string.format("%d%s", sec // u[1], u[2])
            sec = sec % u[1]
            if #parts == 2 then break end
        end
    end
    return table.concat(parts, " ")
end

function M.copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = M.copy(v) end
    return out
end

function M.keys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

function M.contains(list, value)
    for _, v in ipairs(list or {}) do
        if v == value then return true end
    end
    return false
end

function M.count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- the parts of "a.b.c"
function M.split_key(key)
    local out = {}
    for part in tostring(key):gmatch("[^%.]+") do out[#out + 1] = part end
    return out
end

-- nested read: get(t, "a.b.c")
function M.get_path(t, key)
    local cur = t
    for _, part in ipairs(M.split_key(key)) do
        if type(cur) ~= "table" then return nil end
        cur = cur[part]
    end
    return cur
end

function M.set_path(t, key, value)
    local parts = M.split_key(key)
    local cur = t
    for i = 1, #parts - 1 do
        if type(cur[parts[i]]) ~= "table" then cur[parts[i]] = {} end
        cur = cur[parts[i]]
    end
    cur[parts[#parts]] = value
end

-- decode JSON text (or pass a table through); nil when it does not parse
function M.decode(raw)
    if type(raw) == "table" then return raw end
    if type(raw) ~= "string" or raw == "" then return nil end
    local ok, v = pcall(node.json.decode, raw)
    if ok and type(v) == "table" then return v end
    return nil
end

function M.date(ts)
    return os.date("!%Y-%m-%d", ts or M.now())
end

function M.iso(ts)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", ts or M.now())
end

return M
