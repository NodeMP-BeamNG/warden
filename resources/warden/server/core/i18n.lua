-- core.i18n: the server's lines in the player's language. Dictionaries are
-- lang/<code>.json (flat: code -> text with {name} placeholders); a code the
-- dictionary lacks falls back to English, then to the code itself, so a
-- missing line is visible rather than silent.
--
--   i18n.init(default_lang)
--   i18n.t(lang, code, params) -> text
--   i18n.has(lang) -> bool
--   i18n.LANGS -> { "en", "ru" }
--   i18n.missing(lang) -> codes en has and lang lacks (tools/lang-check)

local M = {}

M.LANGS = { "en", "ru" }
M.DEFAULT = "en"

local dicts = {}

local function load(lang)
    local text = node.fs.read("lang/" .. lang .. ".json")
    if not text then return {} end
    local ok, data = pcall(node.json.decode, text)
    if ok and type(data) == "table" then return data end
    node.log("[warden] lang/" .. lang .. ".json does not parse")
    return {}
end

function M.init(default_lang)
    dicts = {}
    for _, lang in ipairs(M.LANGS) do dicts[lang] = load(lang) end
    if M.has(default_lang) then M.DEFAULT = default_lang end
end

function M.has(lang)
    return type(lang) == "string" and dicts[lang] ~= nil
end

function M.normalize(lang)
    if type(lang) ~= "string" then return M.DEFAULT end
    lang = lang:lower():sub(1, 2)
    if dicts[lang] then return lang end
    return M.DEFAULT
end

local function interpolate(text, params)
    if type(params) ~= "table" then return text end
    return (text:gsub("{([%w_]+)}", function(key)
        local v = params[key]
        if v == nil then return "{" .. key .. "}" end
        if math.type(v) == "float" then return string.format("%g", v) end
        return tostring(v)
    end))
end

function M.t(lang, code, params)
    lang = M.normalize(lang)
    local text = dicts[lang] and dicts[lang][code]
    if text == nil and dicts.en then text = dicts.en[code] end
    if text == nil then return code end
    return interpolate(text, params)
end

function M.missing(lang)
    local out = {}
    for code in pairs(dicts.en or {}) do
        if dicts[lang] == nil or dicts[lang][code] == nil then out[#out + 1] = code end
    end
    table.sort(out)
    return out
end

function M.codes(lang)
    local out = {}
    for code in pairs(dicts[lang] or {}) do out[#out + 1] = code end
    table.sort(out)
    return out
end

return M
