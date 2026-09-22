-- config-doc: the [config] keys of resources/warden/resource.toml as the
-- markdown table of the README, generated from the schema in
-- server/core/config.lua (the single source of keys, types, bounds and
-- defaults). The descriptions live here, in English and Russian; a schema
-- key without one, or one here without a schema key, fails the run, so the
-- READMEs cannot drift from the code.
--
--   lua tools/config-doc.lua [en|ru]                 print the table
--   lua tools/config-doc.lua --check README.md [ru]  exit 1 unless the block between
--                                                    <!-- config-doc:begin --> and
--                                                    <!-- config-doc:end --> equals it (CI)
--   lua tools/config-doc.lua --write README.md [ru]  replace that block

local sep = package.config:sub(1, 1)

local function script_dir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*)[/\\][^/\\]+$") or "."
end

local root = script_dir() .. sep .. ".."
package.path = table.concat({
    root .. sep .. "resources" .. sep .. "warden" .. sep .. "server" .. sep .. "?.lua",
    root .. sep .. "tools" .. sep .. "lib" .. sep .. "?.lua",
    package.path,
}, ";")

node = node or { json = require("json") } -- luacheck: ignore 111 (the modules touch node only in functions)

local config = require("core.config")

local BEGIN, END = "<!-- config-doc:begin -->", "<!-- config-doc:end -->"

local DESCRIPTIONS = {
    en = {
        ["language"] = "Language of the server's own lines (`en` / `ru`); a player picks their own with `/lang`.",
        ["owner_ids"] = "Directory account ids that are owners whatever the records say.",
        ["directory_admin_is_owner"] = "A directory administrator (role `ADM`) is an owner.",
        ["allow_guests"] = "Admit players without a directory account (keyed by IP).",
        ["role_tag"] = "Show the group as the tag beside the nickname.",
        ["default_group"] = "The group a first-time player lands in.",
        ["chat_fallback"] = "Read `chat:send` directly instead of the `chat` resource's bus event (no chat resource installed).",
        ["chat_veto_event"] = "Name of the cancellable chat event once the platform ships it (server #43); mutes then drop lines.",
        ["whitelist.enabled"] = "Only players in `data/whitelist.json` may join.",
        ["votekick.enabled"] = "Vote-kick on or off.",
        ["votekick.threshold"] = "Share of eligible voters that must say yes (0.6 = 60 %).",
        ["votekick.min_players"] = "No vote with fewer players connected.",
        ["votekick.window_sec"] = "Seconds a vote stays open.",
        ["votekick.cooldown_sec"] = "Seconds before the same target or starter can be in a vote again.",
        ["votekick.immune_level"] = "Players at this level or above cannot be vote-kicked.",
        ["limits.commands_per_10s"] = "Chat commands one player may run per 10 s.",
        ["limits.ui_per_sec"] = "`wd:req` frames one client may send per second.",
        ["limits.ui_per_min"] = "`wd:req` frames one client may send per minute.",
        ["audit.enabled"] = "Write `data/audit/YYYY-MM-DD.jsonl`.",
        ["audit.retain_days"] = "Audit files older than this are removed at start.",
        ["ui.key"] = "The key that opens the panel, a Dear ImGui key name (`F9`, `F7`); `/wd` toggles it too.",
    },
    ru = {
        ["language"] = "Язык сообщений сервера (`en` / `ru`); игрок выбирает свой командой `/lang`.",
        ["owner_ids"] = "Id аккаунтов directory, которые являются владельцами независимо от записей.",
        ["directory_admin_is_owner"] = "Администратор directory (роль `ADM`) — владелец.",
        ["allow_guests"] = "Пускать игроков без аккаунта directory (ключ — IP).",
        ["role_tag"] = "Показывать группу тегом рядом с ником.",
        ["default_group"] = "Группа, в которую попадает новый игрок.",
        ["chat_fallback"] = "Читать `chat:send` напрямую вместо события шины ресурса `chat` (когда ресурс chat не установлен).",
        ["chat_veto_event"] = "Имя отменяемого события чата, когда платформа его выпустит (server #43); мьют тогда глушит строки.",
        ["whitelist.enabled"] = "Пускать только игроков из `data/whitelist.json`.",
        ["votekick.enabled"] = "Голосование за кик включено.",
        ["votekick.threshold"] = "Доля голосующих, которые должны сказать «да» (0.6 = 60 %).",
        ["votekick.min_players"] = "Нет голосования, если игроков меньше.",
        ["votekick.window_sec"] = "Сколько секунд длится голосование.",
        ["votekick.cooldown_sec"] = "Секунд до следующего голосования против той же цели или от того же инициатора.",
        ["votekick.immune_level"] = "Игроков этого уровня и выше нельзя кикнуть голосованием.",
        ["limits.commands_per_10s"] = "Сколько чат-команд игрок может выполнить за 10 с.",
        ["limits.ui_per_sec"] = "Сколько кадров `wd:req` клиент может послать в секунду.",
        ["limits.ui_per_min"] = "Сколько кадров `wd:req` клиент может послать в минуту.",
        ["audit.enabled"] = "Писать `data/audit/YYYY-MM-DD.jsonl`.",
        ["audit.retain_days"] = "Файлы аудита старше этого удаляются при старте.",
        ["ui.key"] = "Клавиша панели: имя клавиши Dear ImGui (`F9`, `F7`, `Insert`); `/wd` в чате тоже переключает её.",
    },
}

local HEADERS = {
    en = { "Key", "Type", "Default", "Runtime", "Description" },
    ru = { "Ключ", "Тип", "По умолчанию", "На лету", "Описание" },
}

local function render_default(v)
    if type(v) == "table" then
        if #v == 0 then return "`[]`" end
        local parts = {}
        for i, x in ipairs(v) do parts[i] = tostring(x) end
        return "`[" .. table.concat(parts, ", ") .. "]`"
    end
    if type(v) == "string" then return '`"' .. v .. '"`' end
    if math.type(v) == "float" then return "`" .. string.format("%g", v) .. "`" end
    return "`" .. tostring(v) .. "`"
end

local function render_type(spec)
    local t = spec.type
    if spec.enum then t = t .. " (" .. table.concat(spec.enum, " / ") .. ")" end
    if spec.min ~= nil or spec.max ~= nil then
        t = t .. " " .. tostring(spec.min ~= nil and spec.min or "") .. ".." .. tostring(spec.max ~= nil and spec.max or "")
    end
    return t
end

local function table_for(lang)
    local desc = DESCRIPTIONS[lang]
    if desc == nil then error("no descriptions for " .. tostring(lang)) end
    for key in pairs(desc) do
        if config.SCHEMA[key] == nil then error("config-doc: description for unknown key " .. key) end
    end
    local h = HEADERS[lang]
    local out = {
        "| " .. table.concat(h, " | ") .. " |",
        "|---|---|---|---|---|",
    }
    for _, key in ipairs(config.ORDER) do
        local spec = config.SCHEMA[key]
        if desc[key] == nil then error("config-doc: no " .. lang .. " description for " .. key) end
        out[#out + 1] = string.format("| `%s` | %s | %s | %s | %s |", key, render_type(spec), render_default(spec.default),
            spec.runtime and "yes" or "", desc[key])
    end
    return table.concat(out, "\n")
end

local function read(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("a")
    f:close()
    return text
end

local function replace_block(text, block)
    local s = text:find(BEGIN, 1, true)
    local e = text:find(END, 1, true)
    if not s or not e then return nil end
    return text:sub(1, s + #BEGIN - 1) .. "\n" .. block .. "\n" .. text:sub(e)
end

local mode, file, lang = arg[1], arg[2], arg[3]
if mode ~= "--check" and mode ~= "--write" then
    lang = mode or "en"
    io.write(table_for(lang), "\n")
    os.exit(0)
end
lang = lang or "en"
local block = table_for(lang)
local text = read(file)
local updated = replace_block(text:gsub("\r\n", "\n"), block)
if updated == nil then
    io.stderr:write(file .. ": no " .. BEGIN .. " / " .. END .. " markers\n")
    os.exit(1)
end
if mode == "--check" then
    if updated ~= text:gsub("\r\n", "\n") then
        io.stderr:write(file .. ": the config table is out of date; run: lua tools/config-doc.lua --write " .. file ..
            " " .. lang .. "\n")
        os.exit(1)
    end
    print(file .. ": config table up to date")
    os.exit(0)
end
local f = assert(io.open(file, "wb"))
f:write(updated)
f:close()
print(file .. ": config table written")
