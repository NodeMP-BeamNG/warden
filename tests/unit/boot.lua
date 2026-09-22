-- boot: runs the resource's server/main.lua against the stub the way the
-- server would, with node.config set first. Returns the modules a test
-- wants to poke at. Every call is a fresh start (the runner resets the
-- modules and the stub between tests).
--
--   local W = require("boot")(config_overrides)
--   W.chat.handle(player, "/kick Bob")
--   W.protocol.handle(player, '{"id":1,"op":"players.list"}')

local sep = package.config:sub(1, 1)

local function deep_merge(base, over)
    for k, v in pairs(over) do
        if type(v) == "table" and type(base[k]) == "table" then deep_merge(base[k], v) else base[k] = v end
    end
    return base
end

return function(overrides)
    node.config = deep_merge({}, overrides or {})
    local main = table.concat({ WD_ROOT, "resources", "warden", "server", "main.lua" }, sep)
    local chunk, err = loadfile(main)
    if not chunk then error(err) end
    chunk()
    return {
        config = require("core.config"), settings = require("core.settings"), store = require("core.store"),
        audit = require("core.audit"), i18n = require("core.i18n"), say = require("core.say"),
        identity = require("identity.identity"), groups = require("perms.groups"), perms = require("perms.perms"),
        bans = require("moderation.bans"), whitelist = require("moderation.whitelist"),
        mutes = require("moderation.mutes"), caps = require("vehicles.caps"), votekick = require("votekick.votekick"),
        registry = require("commands.registry"), chat = require("commands.chat"),
        protocol = require("ui.protocol"), ops = require("ui.ops"), push = require("ui.push"),
    }
end
