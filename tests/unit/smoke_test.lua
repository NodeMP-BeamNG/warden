-- The resource boots against the stub with an empty config and logs ready.

local boot = require("boot")

return {
    boots_with_defaults = function()
        local W = boot({})
        t.match(node._log_text("info"), "warden .- ready: 5 group%(s%)")
        t.eq(W.settings.get("allow_guests"), true)
        t.eq(W.settings.get("votekick.threshold"), 0.6)
        t.eq(node._log_text("warn"), "", "no config warnings on an empty config")
        -- the first start wrote the default files
        t.truthy(node._files["data/groups.json"])
        t.truthy(node._files["data/players.json"])
        t.truthy(node._files["data/whitelist.json"])
        t.truthy(node._files["data/settings.json"])
        t.truthy(node._files["data/bans_meta.json"])
        -- and announced itself on the bus
        t.eq(#node._bus_of("warden:ready"), 1)
    end,

    bad_config_values_fall_back = function()
        boot({ votekick = { threshold = "lots" }, limits = { ui_per_sec = 0 }, language = "xx" })
        local warn = node._log_text("warn")
        t.match(warn, "votekick%.threshold")
        t.match(warn, "limits%.ui_per_sec")
        t.match(warn, "language")
        t.eq(require("core.settings").get("votekick.threshold"), 0.6)
        t.eq(require("core.settings").get("language"), "en")
    end,

    every_handler_is_registered = function()
        boot({})
        for _, name in ipairs({ "playerConnectRequest", "playerJoined", "playerLeft", "vehicleSpawnRequest",
            "chat:send", "wd:req", "serverShutdown", "resourceUnload" }) do
            t.eq(node._handler_count(name), 1, name)
        end
        t.eq(#(node._bus_handlers["chat:command"] or {}), 1)
        t.eq(#(node._bus_handlers["warden:getGroup"] or {}), 1)
    end,

    chat_fallback_reads_the_wire_instead_of_the_bus = function()
        boot({ chat_fallback = true })
        t.eq(node._handler_count("chat:send"), 2, "the mute notice and the command reader")
        t.eq(#(node._bus_handlers["chat:command"] or {}), 0)
    end,
}
