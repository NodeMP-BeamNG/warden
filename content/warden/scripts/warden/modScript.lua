-- warden content zip: the game runs this when the zip is mounted (at game
-- start when it sits in mods/, at join when the NodeMP launcher installs it
-- into mods/multiplayer/ from the server's content/ folder).
--
-- The zip carries one thing the streamed resource cannot: the input action
-- "Toggle Warden panel" (lua/ge/extensions/core/input/actions/warden.json),
-- which the game reads from disk only. Its category is a plain table entry
-- of core_input_categories; the streamed panel adds it too at runtime, this
-- is for the Controls screen before a warden server was joined. The action's
-- onDown calls the global nodemp_wd.toggle() the streamed panel defines,
-- guarded, so the key does nothing on a server without warden.
local function register()
    if type(extensions) ~= "table" then return false end
    local cats = rawget(_G, "core_input_categories")
    if type(cats) ~= "table" then
        if type(extensions.load) == "function" then pcall(extensions.load, "core_input_categories") end
        cats = rawget(_G, "core_input_categories")
        if type(cats) ~= "table" and type(rawget(extensions, "core_input_categories")) == "table" then
            cats = extensions.core_input_categories
        end
    end
    if type(cats) ~= "table" then return false end
    if type(cats.warden) ~= "table" then
        cats.warden = { order = 9998, icon = "security", title = "Warden", desc = "Warden admin panel" }
    end
    return true
end

local ok, registered = pcall(register)
if type(log) == "function" then
    log("I", "warden", "content zip mounted; input category " .. ((ok and registered) and "registered" or "deferred"))
end
