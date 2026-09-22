-- core.audit: the audit log -- one JSON object per line under
-- data/audit/YYYY-MM-DD.jsonl. Every mutating action and every refusal goes
-- through audit.log(); the panel and /audit read the tail.
--
--   audit.init(cfg)
--   audit.log({ actor = {...}, op = "kick", target = {...}, args = {...}, result = "ok" | "denied", reason = ... })
--   audit.tail(n) -> the last n rows, newest first
--   audit.flush()                 write what is buffered (shutdown)
--
-- node.fs has no append, so the day's file is kept in memory (read once when
-- the day opens) and rewritten atomically, coalesced like the stores. Files
-- older than audit.retain_days are removed at init.

local log = require("core.log")
local util = require("core.util")

local M = {}

M.DIR = "data/audit"
M.FLUSH_DELAY_MS = 1000
M.MEMORY_ROWS = 500   -- rows kept for tail() across days

local enabled = true
local retain_days = 90
local day = nil       -- "YYYY-MM-DD" of the open file
local lines = {}      -- the open file's lines
local recent = {}     -- the last MEMORY_ROWS rows (tables), oldest first
local dirty = false
local timer = nil
local seq = 0

local function file_of(d)
    return M.DIR .. "/" .. d .. ".jsonl"
end

local function open_day(d)
    day = d
    lines = {}
    local text = node.fs.read(file_of(d))
    if text and text ~= "" then
        for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
    end
end

local function write()
    if timer then
        node.cancel(timer)
        timer = nil
    end
    if not dirty or day == nil then return true end
    dirty = false
    if node.fs.mkdir then pcall(node.fs.mkdir, M.DIR) end
    local path = file_of(day)
    local text = table.concat(lines, "\n") .. "\n"
    local tmp = path .. ".tmp"
    if not node.fs.write(tmp, text) then
        log.error("audit: cannot write %s", tmp)
        return false
    end
    if node.fs.rename and node.fs.rename(tmp, path) then return true end
    local ok = node.fs.write(path, text)
    if node.fs.remove then pcall(node.fs.remove, tmp) end
    return ok and true or false
end

local function prune()
    if not node.fs.list then return end
    local list = node.fs.list(M.DIR)
    if type(list) ~= "table" then return end
    local cutoff = util.date(util.now() - retain_days * 86400)
    for _, entry in ipairs(list) do
        local d = tostring(entry.name):match("^(%d%d%d%d%-%d%d%-%d%d)%.jsonl$")
        if d and d < cutoff and node.fs.remove then
            pcall(node.fs.remove, M.DIR .. "/" .. entry.name)
        end
    end
end

-- the last rows of the newest files, for tail() right after a start
local function warm()
    if not node.fs.list then return end
    local list = node.fs.list(M.DIR)
    if type(list) ~= "table" then return end
    local days = {}
    for _, entry in ipairs(list) do
        local d = tostring(entry.name):match("^(%d%d%d%d%-%d%d%-%d%d)%.jsonl$")
        if d then days[#days + 1] = d end
    end
    table.sort(days)
    local rows = {}
    for i = #days, 1, -1 do
        local text = node.fs.read(file_of(days[i])) or ""
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
    day, lines, recent, dirty, timer, seq = nil, {}, {}, false, nil, 0
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

function M.log(row)
    if not enabled then return nil end
    local now = util.now()
    seq = seq + 1
    local entry = {
        seq = seq, ts = now, at = util.iso(now),
        actor = slim_actor(row.actor), op = row.op, target = slim_actor(row.target),
        args = row.args, result = row.result or "ok", reason = row.reason, detail = row.detail,
    }
    local ok, text = pcall(node.json.encode, entry)
    if not ok then
        log.error("audit: cannot encode a row for %s", tostring(row.op))
        return nil
    end
    local d = util.date(now)
    if d ~= day then
        write()
        open_day(d)
    end
    lines[#lines + 1] = text
    recent[#recent + 1] = entry
    while #recent > M.MEMORY_ROWS do table.remove(recent, 1) end
    dirty = true
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

function M.enabled()
    return enabled
end

return M
