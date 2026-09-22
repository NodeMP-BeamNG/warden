-- identity: who a player is across sessions. The key is the directory
-- account ("acct:<id>") when there is one, else the address ("ip:<addr>") --
-- a guest, or every player of a server without a [Directory]. Records live
-- in data/players.json: the group, the names seen, first/last seen, joins,
-- warnings, the mute, the language, and what the rank rule needs while the
-- player is offline (level, the directory's ADM flag; perms.remember).
--
--   identity.init()
--   identity.key(player) -> "acct:12" | "ip:1.2.3.4"
--   identity.record(key, create?) -> record | nil
--   identity.record_of(player) -> record (created)
--   identity.touch(player)             on join: names, joins, last_seen
--   identity.is_ip(text) -> bool        an IPv4 or IPv6 literal
--   identity.parse_key(text) -> key | nil   "acct:<id>", "ip:<literal>", or a key a store
--                                      holds exactly (identity.add_key_source)
--   identity.find(text, opts) -> key, player | nil, code, params
--                                      "#12" (pid), a key, or a name -- exact and
--                                      case-insensitive, never a guess (see below)
--   identity.candidates(name, online_only) -> array of { key, pid?, player?, online, guest, name }
--   identity.describe(candidates, reveal) -> text for err.ambiguous
--   identity.display(key) -> the last name seen under the key
--   identity.is_guest(player) -> no account behind the name
--   identity.mask_ip(ip) / mask_key(key) / mask(value)   IPs hidden from those without mod.ban
--   identity.mark()                    after editing a record
--
-- A name is an unverified thing on a server that admits guests (the
-- directory vouches for an account's name only), so a name resolves to one
-- player only when it is not in doubt:
--   * an exact match among the connected players wins; several connected
--     players of that name (case variants) are `ambiguous` unless one is
--     spelt exactly as typed;
--   * offline records of that name (their newest name) are candidates too
--     unless opts.online_only; one connected, signed-in player of the name
--     wins over them, anything else with several candidates is `ambiguous`
--     (the caller says which keys, so the admin can type #pid or the key);
--   * with opts.strict_guest a name that ends up on a guest (an ip: key) is
--     refused as `guest_by_name`: privileges by name go to accounts only;
--   * opts.fuzzy allows a unique prefix among the connected players (the
--     read-only kinds); everything else needs the whole name.
--
-- Guest records are bounded: past MAX_GUEST_RECORDS ip: records, the oldest
-- one that carries nothing (no group, warnings, mute, language, flag) is
-- dropped for a new one.

local store = require("core.store")
local util = require("core.util")

local M = {}

M.MAX_NAMES = 10
M.MAX_GUEST_RECORDS = 5000

local file = nil
local key_sources = {}   -- fn(key) -> bool: a store that holds the key exactly (bans meta)
local guest_count = nil  -- ip: records, counted lazily

function M.init()
    file = store.open("players", function() return {} end)
    guest_count = nil
    file:on_reload(function() guest_count = nil end)
    M.trim_guests()
end

function M.is_guest(player)
    return player.accountId == nil
end

function M.key(player)
    if player.accountId ~= nil then return "acct:" .. tostring(math.tointeger(player.accountId) or player.accountId) end
    return "ip:" .. tostring(player.ip or "?")
end

-- ---------------------------------------------------------------------------
-- addresses and keys
-- ---------------------------------------------------------------------------

local function is_ipv4(s)
    local a, b, c, d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if a == nil then return false end
    for _, o in ipairs({ a, b, c, d }) do
        if #o > 3 or tonumber(o) > 255 then return false end
    end
    return true
end

local function is_ipv6(s)
    if not s:match("^[%x:%.]+$") or not s:find(":", 1, true) then return false end
    -- an embedded IPv4 tail ("::ffff:1.2.3.4") stands for two groups
    local head, tail = s:match("^(.*:)(%d+%.%d+%.%d+%.%d+)$")
    if head then
        if not is_ipv4(tail) then return false end
        s = head .. "0:0"
    elseif s:find(".", 1, true) then
        return false
    end
    if s:find(":::", 1, true) then return false end
    local _, gaps = s:gsub("::", "")
    if gaps > 1 then return false end
    local n = 0
    for g in s:gmatch("[^:]+") do
        if #g > 4 then return false end
        n = n + 1
    end
    if gaps == 1 then return n <= 7 end
    if s:sub(1, 1) == ":" or s:sub(-1) == ":" then return false end
    return n == 8
end

function M.is_ip(text)
    if type(text) ~= "string" or text == "" or #text > 45 then return false end
    return is_ipv4(text) or is_ipv6(text)
end

-- a store that holds keys of its own (bans meta) so an exact stored key is accepted
function M.add_key_source(fn)
    key_sources[#key_sources + 1] = fn
end

function M.parse_key(text)
    if type(text) ~= "string" then return nil end
    local acct = text:match("^acct:(%d+)$")
    if acct then return "acct:" .. tostring(math.tointeger(tonumber(acct)) or acct) end
    local ip = text:match("^ip:(.+)$")
    if ip and M.is_ip(ip) then return text end
    if file and file.data[text] ~= nil then return text end
    for _, fn in ipairs(key_sources) do
        if fn(text) then return text end
    end
    return nil
end

function M.looks_like_key(text)
    return type(text) == "string" and (text:match("^acct:") or text:match("^ip:")) ~= nil
end

-- the ip / account id a key stands for (what node.bans takes)
function M.ban_target(key)
    if type(key) ~= "string" then return nil end
    local acct = key:match("^acct:(%d+)$")
    if acct then return math.tointeger(tonumber(acct)) end
    local ip = key:match("^ip:(.+)$")
    if ip and M.is_ip(ip) then return ip end
    return nil
end

function M.mask_ip(ip)
    if type(ip) ~= "string" then return ip end
    if is_ipv4(ip) then return (ip:gsub("^(%d+%.%d+)%.%d+%.%d+$", "%1.*.*")) end
    if is_ipv6(ip) then
        local a, b = ip:match("^([^:]*):([^:]*)")
        return (a or "") .. ":" .. (b or "") .. ":*"
    end
    return ip
end

function M.mask_key(key)
    if type(key) ~= "string" then return key end
    local ip = key:match("^ip:(.+)$")
    if ip then return "ip:" .. M.mask_ip(ip) end
    return key
end

-- a copy of value with every address, bare or as an ip: key, masked
function M.mask(value)
    local tv = type(value)
    if tv == "string" then
        if value:match("^ip:") then return M.mask_key(value) end
        if M.is_ip(value) then return M.mask_ip(value) end
        return value
    end
    if tv ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = M.mask(v) end
    return out
end

-- ---------------------------------------------------------------------------
-- records
-- ---------------------------------------------------------------------------

local function is_guest_key(key)
    return type(key) == "string" and key:sub(1, 3) == "ip:"
end

-- a record nobody would miss: no group, warnings, mute, language or flag
local function bare(rec)
    return type(rec) == "table" and rec.group == nil and (rec.warns == nil or #rec.warns == 0) and rec.mute == nil
        and rec.lang == nil and not rec.owner_role
end

local function count_guests()
    if guest_count == nil then
        guest_count = 0
        for key in pairs(file.data) do
            if is_guest_key(key) then guest_count = guest_count + 1 end
        end
    end
    return guest_count
end

-- drops the n oldest bare ip: records; returns how many went
local function evict_guests(n)
    if n <= 0 then return 0 end
    local list = {}
    for key, rec in pairs(file.data) do
        if is_guest_key(key) and bare(rec) then list[#list + 1] = { key = key, seen = rec.last_seen or 0 } end
    end
    table.sort(list, function(a, b)
        if a.seen ~= b.seen then return a.seen < b.seen end
        return a.key < b.key
    end)
    local gone = 0
    for i = 1, math.min(n, #list) do
        file.data[list[i].key] = nil
        gone = gone + 1
    end
    if gone > 0 then
        if guest_count ~= nil then guest_count = guest_count - gone end
        file:mark()
    end
    return gone
end

-- the guest records back within MAX_GUEST_RECORDS (init, and a reload)
function M.trim_guests()
    return evict_guests(count_guests() - M.MAX_GUEST_RECORDS)
end

function M.record(key, create)
    local rec = file.data[key]
    if rec == nil and create then
        if is_guest_key(key) then
            if count_guests() >= M.MAX_GUEST_RECORDS then evict_guests(count_guests() - M.MAX_GUEST_RECORDS + 1) end
            guest_count = count_guests() + 1
        end
        rec = { group = nil, names = {}, first_seen = util.now(), last_seen = util.now(), joins = 0, warns = {} }
        file.data[key] = rec
        file:mark()
    end
    return rec
end

function M.record_of(player)
    return M.record(M.key(player), true)
end

function M.mark()
    if file then return file:mark() end
    return false
end

function M.touch(player)
    local rec = M.record_of(player)
    local name = player.name
    if type(name) == "string" and name ~= "" then
        for i, n in ipairs(rec.names) do
            if n == name then table.remove(rec.names, i) break end
        end
        table.insert(rec.names, 1, name)
        while #rec.names > M.MAX_NAMES do table.remove(rec.names) end
    end
    rec.joins = (rec.joins or 0) + 1
    rec.last_seen = util.now()
    rec.last_ip = player.ip
    file:mark()
    return rec
end

function M.display(key)
    local rec = file.data[key]
    if rec and rec.names and rec.names[1] then return rec.names[1] end
    return key
end

function M.all()
    return file.data
end

function M.guest_count()
    return count_guests()
end

-- ---------------------------------------------------------------------------
-- finding a player
-- ---------------------------------------------------------------------------

function M.online_by_key(key)
    for _, p in ipairs(node.players.all()) do
        if M.key(p) == key then return p end
    end
    return nil
end

local function online_candidate(p)
    return { key = M.key(p), pid = p.id, player = p, online = true, guest = M.is_guest(p), name = p.name }
end

-- every player of that exact name (case-insensitive): the connected ones,
-- then, unless online_only, the offline records whose newest name it is
function M.candidates(name, online_only)
    local lower = tostring(name):lower()
    local out, seen, exact_case = {}, {}, {}
    for _, p in ipairs(node.players.all()) do
        if type(p.name) == "string" and p.name:lower() == lower then
            local key = M.key(p)
            if not seen[key] then
                seen[key] = true
                local c = online_candidate(p)
                out[#out + 1] = c
                if p.name == name then exact_case[#exact_case + 1] = c end
            end
        end
    end
    if #out > 1 and #exact_case == 1 then
        out, seen = exact_case, { [exact_case[1].key] = true }
    end
    if online_only then return out end
    for key, rec in pairs(file.data) do
        local n = type(rec) == "table" and rec.names and rec.names[1]
        if not seen[key] and type(n) == "string" and n:lower() == lower then
            seen[key] = true
            out[#out + 1] = { key = key, online = false, guest = is_guest_key(key), name = n }
        end
    end
    table.sort(out, function(a, b)
        if a.online ~= b.online then return a.online end
        return a.key < b.key
    end)
    return out
end

-- the connected players whose name starts with the text (the read-only kinds only)
local function prefix_candidates(text)
    local lower = text:lower()
    local out = {}
    for _, p in ipairs(node.players.all()) do
        if type(p.name) == "string" and p.name:lower():sub(1, #lower) == lower then
            out[#out + 1] = online_candidate(p)
        end
    end
    return out
end

-- the candidates as one line: key (#pid when connected, "guest" for an ip: key);
-- the addresses masked unless `reveal`
function M.describe(list, reveal)
    local parts = {}
    for _, c in ipairs(list or {}) do
        local shown = reveal and c.key or M.mask_key(c.key)
        if c.online then shown = shown .. " #" .. tostring(c.pid) end
        if c.guest then shown = shown .. " guest" end
        parts[#parts + 1] = shown
    end
    return table.concat(parts, ", ")
end

-- opts: online_only (connected players only), fuzzy (a unique prefix among
-- them), strict_guest (a name on a guest is refused), prefer_pid (a
-- candidate that is this connected player wins: the self kinds)
function M.find(text, opts)
    opts = opts or {}
    text = util.trim(text)
    if text == "" or #text > 128 then return nil, "bad_arg", { field = "target" } end
    local pid = text:match("^#(%d+)$")
    if pid then
        local p = node.players.get(tonumber(pid))
        if p and p:isConnected() then return M.key(p), p end
        return nil, "offline"
    end
    if M.looks_like_key(text) then
        local key = M.parse_key(text)
        if key == nil then return nil, "bad_key", { target = text } end
        local online = M.online_by_key(key)
        if opts.online_only and online == nil then return nil, "offline" end
        return key, online
    end
    local list = M.candidates(text, opts.online_only)
    if #list == 0 and opts.fuzzy then list = prefix_candidates(text) end
    if #list == 0 then return nil, "no_target", { target = text } end
    if #list > 1 then
        local picked = nil
        if opts.prefer_pid ~= nil then
            for _, c in ipairs(list) do
                if c.pid == opts.prefer_pid then picked = c end
            end
        end
        if picked == nil then
            -- one connected, signed-in player of that name beats offline records and guests
            local signed = {}
            for _, c in ipairs(list) do
                if c.online and not c.guest then signed[#signed + 1] = c end
            end
            if #signed == 1 then picked = signed[1] end
        end
        if picked == nil then return nil, "ambiguous", { target = text, candidates = list } end
        list = { picked }
    end
    local c = list[1]
    if c.guest and opts.strict_guest then
        return nil, "guest_by_name", { target = text, key = c.key, pid = c.pid }
    end
    return c.key, c.player
end

return M
