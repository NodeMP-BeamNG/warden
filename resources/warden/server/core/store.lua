-- core.store: the JSON files under data/ (inside the resource folder, through
-- node.fs, which never writes outside it).
--
--   local groups = store.open("groups", function() return {...} end)
--   groups.data                the table (edit it in place)
--   groups:mark()              changed: saved within SAVE_DELAY_MS, many marks -> one write
--   groups:save()              write now (tmp + rename = atomic; the previous file kept as .bak)
--   groups:reload() -> bool    re-read from disk (a hoster edited the file)
--   groups:on_reload(fn)       fn(data) after a reload that came from the file watcher
--   store.flush_all()          every dirty store written (shutdown, unload)
--
-- A file that does not parse is not overwritten: the .bak is tried, then the
-- default, and the store stays read-only for that file until a reload succeeds
-- (a warning names the file). node.fs.watch, when the server has it, re-reads
-- a file changed by someone else about a second after the change; a write of
-- our own within the last WATCH_IGNORE_S seconds is ignored.

local log = require("core.log")
local util = require("core.util")

local M = {}

M.DIR = "data"
M.SAVE_DELAY_MS = 1000
M.WATCH_IGNORE_S = 3

local stores = {}   -- name -> store

local Store = {}
Store.__index = Store

local function path_of(name)
    return M.DIR .. "/" .. name .. ".json"
end

local function read_json(path)
    local text = node.fs.read(path)
    if text == nil or text == "" then return nil, "missing" end
    local ok, data = pcall(node.json.decode, text)
    if not ok or type(data) ~= "table" then return nil, "unreadable" end
    return data
end

local function ensure_dir()
    if node.fs.mkdir then pcall(node.fs.mkdir, M.DIR) end
end

function Store.mark(self)
    if self.readonly then return false end
    self.dirty = true
    if self.timer == nil then
        self.timer = node.after(M.SAVE_DELAY_MS, function()
            self.timer = nil
            self:save()
        end)
    end
    return true
end

function Store.save(self)
    if self.readonly then return false end
    if self.timer ~= nil then
        node.cancel(self.timer)
        self.timer = nil
    end
    self.dirty = false
    ensure_dir()
    local ok, text = pcall(node.json.encode, self.data, { pretty = true })
    if not ok then
        log.error("store %s: cannot encode: %s", self.name, tostring(text))
        return false
    end
    local tmp = self.path .. ".tmp"
    if not node.fs.write(tmp, text) then
        log.error("store %s: cannot write %s", self.name, tmp)
        return false
    end
    if node.fs.copy and node.fs.exists and node.fs.exists(self.path) == "file" then
        pcall(node.fs.copy, self.path, self.path .. ".bak")
    end
    local renamed = false
    if node.fs.rename then
        renamed = node.fs.rename(tmp, self.path) and true or false
    end
    if not renamed then
        -- a server before ABI 2.3: write in place and drop the tmp
        renamed = node.fs.write(self.path, text) and true or false
        if node.fs.remove then pcall(node.fs.remove, tmp) end
    end
    self.written_at = util.now()
    return renamed
end

-- reads the file (or its .bak, or the default); returns true when the file
-- itself was read
local function load_into(self)
    local data, why = read_json(self.path)
    if data ~= nil then
        self.data = data
        self.readonly = false
        return true
    end
    if why == "unreadable" then
        local bak = read_json(self.path .. ".bak")
        if bak ~= nil then
            log.warn("store %s: %s does not parse; using %s.bak (the file is left alone until it parses again)",
                self.name, self.path, self.path)
            self.data = bak
        else
            log.warn("store %s: %s does not parse and there is no .bak; running on defaults, read-only",
                self.name, self.path)
            self.data = self.default()
        end
        self.readonly = true
        return false
    end
    self.data = self.default()
    self.readonly = false
    return false
end

function Store.reload(self)
    local had = load_into(self)
    if had then
        for _, fn in ipairs(self.listeners) do
            local ok, err = pcall(fn, self.data)
            if not ok then log.error("store %s: reload listener failed: %s", self.name, tostring(err)) end
        end
    end
    return had
end

function Store.on_reload(self, fn)
    self.listeners[#self.listeners + 1] = fn
end

local function watch(self)
    if type(node.fs.watch) ~= "function" then return end
    local ok, id = pcall(node.fs.watch, self.path, function(_, what)
        if what ~= "changed" then return end
        if self.written_at and util.now() - self.written_at < M.WATCH_IGNORE_S then return end
        if self:reload() then log.info("store %s: %s changed on disk, reloaded", self.name, self.path) end
    end)
    if ok and id then self.watch_id = id end
end

function M.open(name, default)
    if stores[name] then return stores[name] end
    local self = setmetatable({
        name = name, path = path_of(name), default = default or function() return {} end,
        data = nil, dirty = false, timer = nil, readonly = false, listeners = {}, written_at = nil,
    }, Store)
    local existed = load_into(self)
    if not existed and not self.readonly then
        -- first run: write the defaults so the hoster has a file to edit
        self:save()
    end
    watch(self)
    stores[name] = self
    return self
end

function M.flush_all()
    local n = 0
    for _, s in pairs(stores) do
        if s.dirty or s.timer ~= nil then
            if s:save() then n = n + 1 end
        end
    end
    return n
end

-- the tests reopen stores between cases
function M._reset()
    for _, s in pairs(stores) do
        if s.timer then node.cancel(s.timer) end
        if s.watch_id and node.fs.unwatch then pcall(node.fs.unwatch, s.watch_id) end
    end
    stores = {}
end

return M
