-- core.say: a line to a player in their language. Through player:tell (the
-- `chat` resource shows it as a system line) and, when the client has the
-- warden-ui half, as a wd:event notice too, so the panel can show it.
--
--   say.tell(player, code, params)
--   say.all(code, params)                  everyone, each in their language
--   say.lang_of(player) -> "en" | "ru"
--   say.set_lang(player, lang)
--   say.on_notice(fn)                      fn(player, text, code, params) -- ui.push hooks in

local i18n = require("core.i18n")
local identity = require("identity.identity")

local M = {}

local notice_listeners = {}

function M.on_notice(fn)
    notice_listeners[#notice_listeners + 1] = fn
end

function M.lang_of(player)
    if type(player) ~= "table" or player.console then return i18n.DEFAULT end
    local rec = identity.record(identity.key(player))
    if rec and i18n.has(rec.lang) then return rec.lang end
    return i18n.DEFAULT
end

function M.set_lang(player, lang)
    lang = i18n.normalize(lang)
    local rec = identity.record_of(player)
    rec.lang = lang
    identity.mark()
    return lang
end

function M.text(player, code, params)
    return i18n.t(M.lang_of(player), code, params)
end

function M.tell(player, code, params)
    if type(player) ~= "table" then return false end
    if player.console then
        node.log("[warden] " .. i18n.t(i18n.DEFAULT, code, params))
        return true
    end
    local text = M.text(player, code, params)
    if type(player.tell) == "function" then pcall(player.tell, player, text) end
    for _, fn in ipairs(notice_listeners) do pcall(fn, player, text, code, params) end
    return true
end

function M.all(code, params)
    for _, p in ipairs(node.players.all()) do M.tell(p, code, params) end
end

return M
