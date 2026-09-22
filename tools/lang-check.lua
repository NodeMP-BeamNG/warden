-- lang-check: the dictionaries under resources/warden/lang agree -- every
-- code of en.json is in ru.json and back, and the {placeholders} a Russian
-- line uses exist in the English one. Exit 1 on a difference.
--
--   lua tools/lang-check.lua

local sep = package.config:sub(1, 1)

local function script_dir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*)[/\\][^/\\]+$") or "."
end

local root = script_dir() .. sep .. ".."
package.path = root .. sep .. "tools" .. sep .. "lib" .. sep .. "?.lua;" .. package.path
local json = require("json")

local LANG = root .. sep .. "resources" .. sep .. "warden" .. sep .. "lang" .. sep

local function read(path)
    local f = assert(io.open(path, "rb"), "cannot read " .. path)
    local text = f:read("a")
    f:close()
    return text
end

local function placeholders(text)
    local set = {}
    for name in tostring(text):gmatch("{([%w_]+)}") do set[name] = true end
    return set
end

local en = json.decode(read(LANG .. "en.json"))
local ru = json.decode(read(LANG .. "ru.json"))
local problems, n = 0, 0

local function problem(msg)
    problems = problems + 1
    io.stderr:write(msg .. "\n")
end

for code, text in pairs(en) do
    n = n + 1
    if type(text) ~= "string" then problem("en." .. code .. " is not a string") end
    if ru[code] == nil then
        problem("ru.json lacks " .. code)
    else
        local pe, pr = placeholders(text), placeholders(ru[code])
        for name in pairs(pr) do
            if not pe[name] then problem(code .. ": ru uses {" .. name .. "} that en lacks") end
        end
        for name in pairs(pe) do
            if not pr[name] then problem(code .. ": ru drops {" .. name .. "}") end
        end
    end
end
for code in pairs(ru) do
    if en[code] == nil then problem("en.json lacks " .. code) end
end

if problems > 0 then
    io.stderr:write(problems .. " dictionary problem(s)\n")
    os.exit(1)
end
print(string.format("lang: %d codes, en and ru agree", n))
