-- core.audit: the audit log -- one JSON object per line under
-- data/audit/YYYY-MM-DD.jsonl. Every mutating action and every refusal goes
-- through audit.log(); the panel and /audit read the tail.
--
--   audit.init(cfg)
--   audit.log({ actor = {...}, op = "kick", target = {...}, args = {...}, result = "ok" | "denied", reason = ... })
--   audit.tail(n) -> the last n rows, newest first (from memory, at most MEMORY_ROWS)
--   audit.flush()                 write what is buffered (shutdown)
--   audit.pending() -> rows buffered, rows dropped
--
-- A row is capped at MAX_ROW_BYTES: past it the args and the detail go
-- (`truncated = true`), then the names. The rows are buffered and written
-- once a second (FLUSH_DELAY_MS): node.fs has no append, so the current
-- file is read back and rewritten with the buffer behind it (tmp + rename);
-- to keep that bounded a day continues in <day>.2.jsonl, .3.jsonl ... once a
-- file passes MAX_FILE_BYTES. Nothing but the buffer and the last
-- MEMORY_ROWS rows (for tail) stays in memory. Files older than
-- audit.retain_days are removed at init. A disk that refuses writes keeps
-- the buffer for the next flush, up to MAX_PENDING rows (older ones are
-- dropped and counted).

local log = require("core.log")
local util = require("core.util")

local M = {}

M.DIR = "data/audit"
M.FLUSH_DELAY_MS = 1000
M.MEMORY_ROWS = 500          -- rows kept for tail() across days
M.MAX_ROW_BYTES = 1024       -- a row past this loses its args / detail, then its names
M.MAX_FILE_BYTES = 1024 * 1024
M.MAX_PENDING = 2000

local enabled = true
local retain_days = 90
local day = nil       -- "YYYY-MM-DD" of the open file
local part = 1        -- the file of the day being appended to
local pending = {}    -- encoded rows not on disk yet
local dropped = 0     -- rows lost to a disk that would not take them
local recent = {}     -- the last MEMORY_ROWS rows (tables), oldest first
local timer = nil
local seq = 0

local function file_of(d, p)
    return M.DIR .. "/" .. d .. ((p or 1) > 1 and ("." .. p) or "") .. ".jsonl"
end

-- the day files on disk, oldest first: { day, part, name }
local function files_on_disk()
    if not node.fs.list then return {} end
    local list = node.fs.list(M.DIR)
    local out = {}
    for _, entry in ipairs(type(list) == "table" and list or {}) do
        local d, p = tostring(entry.name):match("^(%d%d%d%d%-%d%d%-%d%d)%.?(%d*)%.jsonl$")
        if d then out[#out + 1] = { day = d, part = tonumber(p) or 1, name = entry.name } end
    end
    table.sort(out, function(a, b)
        if a.day ~= b.day then return a.day < b.day end
        return a.part < b.part
    end)
    return out
end

local function open_day(d)
    day, part = d, 1
    for _, f in ipairs(files_on_disk()) do
        if f.day == d and f.part > part then part = f.part end
    end
end

local function write()
    if timer then
        node.cancel(timer)
        timer = nil
    end
    if #pending == 0 or day == nil then return true end
    if node.fs.mkdir then pcall(node.fs.mkdir, M.DIR) end
    local text = table.concat(pending, "\n") .. "\n"
    local path = file_of(day, part)
    local existing = node.fs.read(path) or ""
    if existing ~= "" and #existing + #text > M.MAX_FILE_BYTES then
        part = part + 1
        path = file_of(day, part)
        existing = node.fs.read(path) or ""
    end
    if existing ~= "" and existing:sub(-1) ~= "\n" then existing = existing .. "\n" end
    local whole = existing .. text
    local tmp = path .. ".tmp"
    if not node.fs.write(tmp, whole) then
        log.error("audit: cannot write %s (%d row(s) kept for the next flush)", tmp, #pending)
        return false
    end
    local ok
    if node.fs.rename and node.fs.rename(tmp, path) then
        ok = true
    else
        ok = node.fs.write(path, whole) and true or false
        if node.fs.remove then pcall(node.fs.remove, tmp) end
    end
    if ok then
        pending = {}
    else
        log.error("audit: cannot write %s (%d row(s) kept for the next flush)", path, #pending)
    end
    return ok
end

local function prune()
    if not node.fs.remove then return end
    local cutoff = util.date(util.now() - retain_days * 86400)
    for _, f in ipairs(files_on_disk()) do
        if f.day < cutoff then pcall(node.fs.remove, M.DIR .. "/" .. f.name) end
    end
end

-- the last rows of the newest files, for tail() right after a start
local function warm()
    local files = files_on_disk()
    local rows = {}
    for i = #files, 1, -1 do
        local text = node.fs.read(M.DIR .. "/" .. files[i].name) or ""
        local these = {}
        for line in text:gmatch("[^\n]+") do
            local ok, row = pcall(node.json.decode, line)
            if ok and type(row) == "table" then these[#these + 1] = row end
        end
        for j = #these, 1, -1 do
            table.insert(rows, 1, these[j])
            if #rows >= M.MEMORY_ROWS then break end
        end
        if #rows >= M.MEMORY_ROWS then break end
    end
    recent = rows
end

function M.init(cfg)
    enabled = cfg.audit.enabled ~= false
    retain_days = cfg.audit.retain_days or 90
    day, part, pending, dropped, recent, timer, seq = nil, 1, {}, 0, {}, nil, 0
    if not enabled then return end
    prune()
    warm()
    for _, row in ipairs(recent) do
        if type(row.seq) == "number" and row.seq > seq then seq = row.seq end
    end
end

local function slim_actor(a)
    if type(a) ~= "table" then return a end
    return { pid = a.pid, key = a.key, name = a.name, console = a.console or nil }
end

-- the row as text within MAX_ROW_BYTES, or nil when it cannot be encoded
local function encode(entry)
    local ok, text = pcall(node.json.encode, entry)
    if not ok then return nil end
    if #text <= M.MAX_ROW_BYTES then return text end
    entry.args, entry.detail, entry.truncated = nil, nil, true
    ok, text = pcall(node.json.encode, entry)
    if not ok then return nil end
    if #text <= M.MAX_ROW_BYTES then return text end
    for _, who in ipairs({ entry.actor, entry.target }) do
        if type(who) == "table" then
            who.name = util.clean(who.name, 32)
            who.key = util.clean(who.key, 64)
        end
    end
    if type(entry.reason) == "string" then entry.reason = util.clean(entry.reason, 64) end
    ok, text = pcall(node.json.encode, entry)
    if not ok or #text > M.MAX_ROW_BYTES then return nil end
    return text
end

function M.log(row)
    if not enabled then return nil end
    local now = util.now()
    seq = seq + 1
    local entry = {
        seq = seq, ts = now, at = util.iso(now),
        actor = slim_actor(row.actor), op = row.op, target = slim_actor(row.target),
        args = row.args, result = row.result or "ok", reason = row.reason, detail = row.detail,
        dropped = row.dropped,
    }
    local text = encode(entry)
    if text == nil then
        log.error("audit: cannot encode a row for %s", tostring(row.op))
        return nil
    end
    local d = util.date(now)
    if d ~= day then
        write()
        open_day(d)
    end
    pending[#pending + 1] = text
    while #pending > M.MAX_PENDING do
        table.remove(pending, 1)
        dropped = dropped + 1
    end
    recent[#recent + 1] = entry
    while #recent > M.MEMORY_ROWS do table.remove(recent, 1) end
    if timer == nil then
        timer = node.after(M.FLUSH_DELAY_MS, function()
            timer = nil
            write()
        end)
    end
    return entry
end

function M.tail(n)
    n = math.max(1, math.min(tonumber(n) or 50, M.MEMORY_ROWS))
    local out = {}
    for i = #recent, math.max(1, #recent - n + 1), -1 do
        out[#out + 1] = recent[i]
    end
    return out
end

function M.flush()
    return write()
end

function M.pending()
    return #pending, dropped
end

function M.enabled()
    return enabled
end

return M
