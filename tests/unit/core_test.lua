-- core: config coercion, the store (atomic + coalesced + reload), the
-- limiter, the parser, i18n, the audit log.

local boot = require("boot")

local tests = {}

-- config ----------------------------------------------------------------------

tests.config_coerces_and_bounds = function()
    local config = require("core.config")
    local spec = config.SCHEMA["votekick.threshold"]
    t.eq(config.coerce(spec, "0.75"), 0.75)
    t.eq(config.coerce(spec, 1.5), nil)
    t.eq(config.coerce(config.SCHEMA["allow_guests"], "false"), false)
    t.eq(config.coerce(config.SCHEMA["owner_ids"], { 1, "2" }), { 1, 2 })
    t.eq(config.coerce(config.SCHEMA["owner_ids"], { "x" }), nil)
    t.eq(config.coerce(config.SCHEMA["language"], "de"), nil)
    local cfg, warnings = config.load({ votekick = { min_players = 1 }, ui = { key = "F7" } })
    t.eq(#warnings, 1)
    t.eq(cfg.votekick.min_players, 4)
    t.eq(cfg.ui.key, "F7")
    t.eq(cfg.limits.ui_per_min, 120)
end

-- store -------------------------------------------------------------------------

tests.store_writes_tmp_then_renames = function()
    local store = require("core.store")
    local s = store.open("things", function() return { a = 1 } end)
    t.eq(s.data.a, 1)
    -- the first save happened at open: tmp written, then renamed into place
    t.eq(node._writes[1], "data/things.json.tmp")
    t.truthy(node._files["data/things.json"])
    t.falsy(node._files["data/things.json.tmp"])
    s.data.a = 2
    s:mark()
    s:mark()
    s:mark()
    t.eq(#node._writes, 1, "marks coalesce: nothing written yet")
    node._advance(999)
    t.eq(#node._writes, 1)
    node._advance(1)
    t.eq(#node._writes, 2, "one write for three marks")
    t.match(node._files["data/things.json"], '"a": 2')
    t.truthy(node._files["data/things.json.bak"], "the previous file is kept")
end

tests.store_keeps_a_broken_file_read_only = function()
    node._files["data/things.json"] = "{ not json"
    node._files["data/things.json.bak"] = '{"a": 5}'
    local store = require("core.store")
    local s = store.open("things", function() return { a = 1 } end)
    t.eq(s.data.a, 5, "the .bak is used")
    t.truthy(s.readonly)
    s.data.a = 6
    t.falsy(s:mark())
    node._advance(5000)
    t.eq(node._files["data/things.json"], "{ not json", "never overwritten")
    t.match(node._log_text("warn"), "does not parse")
    -- the hoster fixes the file: the watcher reloads and writes resume
    node._files["data/things.json"] = '{"a": 7}'
    node._advance(4000)
    node._touch("data/things.json")
    t.eq(s.data.a, 7)
    t.falsy(s.readonly)
end

tests.store_reload_from_watch_ignores_own_writes = function()
    local store = require("core.store")
    local s = store.open("things", function() return { a = 1 } end)
    local reloads = 0
    s:on_reload(function() reloads = reloads + 1 end)
    node._touch("data/things.json")
    t.eq(reloads, 0, "right after our own write: ignored")
    node._advance(4000)
    node._files["data/things.json"] = '{"a": 9}'
    node._touch("data/things.json")
    t.eq(reloads, 1)
    t.eq(s.data.a, 9)
end

tests.flush_all_writes_dirty_stores = function()
    local store = require("core.store")
    local a = store.open("a", function() return {} end)
    local b = store.open("b", function() return {} end)
    a.data.x = 1
    a:mark()
    b.data.y = 1
    b:mark()
    t.eq(store.flush_all(), 2)
    t.eq(node._timer_count(), 0, "the pending timers were cancelled")
end

-- limiter -----------------------------------------------------------------------

tests.limiter_sliding_windows = function()
    local limiter = require("core.limiter")
    local lim = limiter.new({ { n = 2, window = 1 }, { n = 3, window = 60 } })
    t.truthy(lim:allow("a", 100))
    t.truthy(lim:allow("a", 100))
    local ok, retry = lim:allow("a", 100)
    t.falsy(ok)
    t.eq(retry, 1)
    t.truthy(lim:allow("a", 101), "the second window")
    ok, retry = lim:allow("a", 102)
    t.falsy(ok, "three per minute reached")
    t.truthy(retry >= 57)
    t.truthy(lim:allow("b", 102), "another key is separate")
    lim:forget("a")
    t.truthy(lim:allow("a", 102))
end

-- parser ------------------------------------------------------------------------

tests.parser_words_and_quotes = function()
    local parser = require("commands.parser")
    local c = parser.parse('/kick "Bob Smith" too   fast  ')
    t.eq(c.name, "kick")
    t.eq(c.words, { "Bob Smith", "too", "fast" })
    t.eq(c.rest(2), "too   fast")
    t.eq(c.rest(1), '"Bob Smith" too   fast')
    t.eq(c.rest(4), "")
    t.eq(parser.parse("hello"), nil)
    t.eq(parser.parse("/"), nil)
    t.eq(parser.parse("/KICK x").name, "kick")
    t.eq(parser.parse('/say "a \\"quoted\\" word"').words, { 'a "quoted" word' })
end

-- i18n --------------------------------------------------------------------------

tests.i18n_dictionaries_match = function()
    local i18n = require("core.i18n")
    i18n.init("en")
    t.eq(i18n.missing("ru"), {}, "every English code has a Russian line")
    t.truthy(#i18n.codes("en") > 50)
    t.eq(i18n.t("ru", "done.kick", { target = "Bob", reason = "afk" }), "Кикнут Bob: afk")
    t.eq(i18n.t("xx", "done.unban", { target = "Bob" }), "Unbanned Bob.", "unknown language -> default")
    t.eq(i18n.t("en", "no.such.code"), "no.such.code")
    t.eq(i18n.t("en", "done.vote", { yes = 2, needed = 3.0 }), "Vote counted: 2/3 yes.")
    -- every placeholder used in ru exists in en (no stray {names})
    for _, code in ipairs(i18n.codes("en")) do
        local en = i18n.t("en", code)
        for name in i18n.t("ru", code):gmatch("{([%w_]+)}") do
            t.truthy(en:find("{" .. name .. "}", 1, true), code .. ": ru uses {" .. name .. "} that en lacks")
        end
    end
end

-- audit -------------------------------------------------------------------------

tests.audit_rows_tail_and_files = function()
    boot({})
    local audit = require("core.audit")
    for i = 1, 5 do audit.log({ actor = { name = "a" }, op = "kick", args = { i = i }, result = "ok" }) end
    local tail = audit.tail(3)
    t.eq(#tail, 3)
    t.eq(tail[1].args.i, 5, "newest first")
    t.eq(tail[1].seq, 5)
    t.falsy(node._files["data/audit/2023-11-14.jsonl"], "coalesced")
    node._advance(1000)
    local text = node._files["data/audit/2023-11-14.jsonl"]
    t.truthy(text)
    local n = select(2, text:gsub("\n", ""))
    t.eq(n, 5)
    -- a new day opens a new file
    node._unix = node._unix + 86400
    audit.log({ actor = { name = "a" }, op = "ban", result = "ok" })
    node._advance(1000)
    t.truthy(node._files["data/audit/2023-11-15.jsonl"])
    t.eq(#audit.tail(10), 6)
end

tests.audit_prunes_old_files_and_warms_the_tail = function()
    node._files["data/audit/2000-01-01.jsonl"] = '{"seq":1,"op":"old"}\n'
    node._files["data/audit/2023-11-13.jsonl"] = '{"seq":7,"op":"warm","ts":1}\n{"seq":8,"op":"warm2","ts":2}\n'
    boot({})
    local audit = require("core.audit")
    t.falsy(node._files["data/audit/2000-01-01.jsonl"], "older than retain_days: removed")
    t.truthy(node._files["data/audit/2023-11-13.jsonl"])
    local tail = audit.tail(5)
    t.eq(tail[1].op, "warm2")
    local row = audit.log({ actor = { name = "a" }, op = "x" })
    t.eq(row.seq, 9, "the sequence continues after the warmed rows")
end

tests.audit_off = function()
    boot({ audit = { enabled = false } })
    local audit = require("core.audit")
    t.eq(audit.log({ op = "x" }), nil)
    t.eq(audit.tail(5), {})
end

return tests
