-- Unit test runner: `lua tests/unit/run.lua [file_test.lua ...]` (Lua 5.4).
--
-- Finds tests/unit/*_test.lua (or runs the files given). A test file returns
-- a table name -> function; the runner provides the global `t` (assertions)
-- and a `node` stub (tests/unit/stubs/node.lua) standing in for the server.
-- Every test starts from fresh resource modules and a reset stub.
-- Exit 0 when everything passed, 1 otherwise. No dependencies.

local sep = package.config:sub(1, 1)
local windows = sep == "\\"

local script = arg and arg[0] or "tests/unit/run.lua"
local unit_dir = script:match("^(.*)[/\\][^/\\]+$") or "."
local root = unit_dir .. sep .. ".." .. sep .. ".."

local function join(...)
    return (table.concat({ ... }, sep))
end

package.path = table.concat({
    join(root, "resources", "warden", "server", "?.lua"),
    join(root, "tests", "gate", "hooks", "?.lua"),
    join(root, "tools", "lib", "?.lua"),
    join(unit_dir, "?.lua"),
    join(unit_dir, "stubs", "?.lua"),
    package.path,
}, ";")

WD_ROOT = root -- luacheck: ignore 111 (the stub reads lang/ from the real resource)

-- ---------------------------------------------------------------------------
-- assertions
-- ---------------------------------------------------------------------------

local function repr(v, depth)
    depth = depth or 0
    if type(v) == "string" then return string.format("%q", v) end
    if type(v) ~= "table" then return tostring(v) end
    if depth > 4 then return "{...}" end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = "[" .. repr(k, depth + 1) .. "]=" .. repr(v[k], depth + 1) end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function deep_eq(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not deep_eq(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local T = {}

function T.fail(msg)
    error({ unit_failure = true, msg = msg or "failed" }, 2)
end

local function prefix(msg)
    return msg and (msg .. ": ") or ""
end

function T.eq(actual, expected, msg)
    if not deep_eq(actual, expected) then
        T.fail(string.format("%sexpected %s, got %s", prefix(msg), repr(expected), repr(actual)))
    end
end

function T.ne(actual, unexpected, msg)
    if deep_eq(actual, unexpected) then T.fail(string.format("%sdid not expect %s", prefix(msg), repr(unexpected))) end
end

function T.truthy(v, msg)
    if not v then T.fail(string.format("%sexpected a truthy value, got %s", prefix(msg), repr(v))) end
end

function T.falsy(v, msg)
    if v then T.fail(string.format("%sexpected a falsy value, got %s", prefix(msg), repr(v))) end
end

function T.match(s, pattern, msg)
    if type(s) ~= "string" or not s:find(pattern) then
        T.fail(string.format("%sexpected %s to match %q", prefix(msg), repr(s), pattern))
    end
end

function T.errors(fn, pattern, msg)
    local ok, err = pcall(fn)
    if ok then T.fail(prefix(msg) .. "expected an error, none was raised") end
    if type(err) == "table" and err.unit_failure then error(err, 0) end
    local text = tostring(type(err) == "table" and (err.message or repr(err)) or err)
    if pattern and not text:find(pattern) then
        T.fail(string.format("%serror %q does not match %q", prefix(msg), text, pattern))
    end
    return err
end

T.repr = repr
T.deep_eq = deep_eq
t = T -- luacheck: ignore 111

-- ---------------------------------------------------------------------------
-- discovery and run
-- ---------------------------------------------------------------------------

local function list_tests()
    local files = {}
    local cmd = windows and ('dir /b "' .. unit_dir .. '\\*_test.lua" 2>nul') or ('ls "' .. unit_dir .. '" 2>/dev/null')
    local p = io.popen(cmd)
    if p then
        for line in p:lines() do
            line = line:gsub("[\r\n]", "")
            if line:match("_test%.lua$") then files[#files + 1] = join(unit_dir, line) end
        end
        p:close()
    end
    table.sort(files)
    return files
end

local files = {}
if arg and #arg > 0 then
    for i = 1, #arg do files[#files + 1] = arg[i] end
else
    files = list_tests()
end
if #files == 0 then
    io.stderr:write("no *_test.lua found under " .. unit_dir .. "\n")
    os.exit(1)
end

-- the resource's module domains (folders under server/): required fresh per test
local DOMAINS = { "core", "identity", "perms", "moderation", "vehicles", "votekick", "commands", "ui", "integration", "dev" }

local function is_resource_module(name)
    for _, domain in ipairs(DOMAINS) do
        if name:sub(1, #domain + 1) == domain .. "." then return true end
    end
    return false
end

local function reset_modules()
    for name in pairs(package.loaded) do
        if is_resource_module(name) then package.loaded[name] = nil end
    end
    node = require("node") -- luacheck: ignore 111
    node._reset()
end

local passed, failed = 0, 0
local failures = {}

for _, file in ipairs(files) do
    local short = file:match("([^/\\]+)%.lua$") or file
    reset_modules()
    local chunk, load_err = loadfile(file)
    if not chunk then
        failed = failed + 1
        failures[#failures + 1] = short .. ": " .. tostring(load_err)
        print("[FAIL] " .. short .. " - " .. tostring(load_err))
    else
        local ok, tests = pcall(chunk)
        if not ok or type(tests) ~= "table" then
            failed = failed + 1
            local why = ok and "did not return a table of tests" or tostring(tests)
            failures[#failures + 1] = short .. ": " .. why
            print("[FAIL] " .. short .. " - " .. why)
        else
            local names = {}
            for name in pairs(tests) do names[#names + 1] = name end
            table.sort(names)
            for _, name in ipairs(names) do
                reset_modules()
                local okt, err = xpcall(tests[name], function(e)
                    if type(e) == "table" and e.unit_failure then return e.msg end
                    return debug.traceback(tostring(type(e) == "table" and (e.message or repr(e)) or e), 2)
                end)
                if okt then
                    passed = passed + 1
                    print("[PASS] " .. short .. ":" .. name)
                else
                    failed = failed + 1
                    failures[#failures + 1] = short .. ":" .. name .. " - " .. tostring(err)
                    print("[FAIL] " .. short .. ":" .. name .. " - " .. tostring(err))
                end
            end
        end
    end
end

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
    for _, f in ipairs(failures) do io.stderr:write("  " .. f .. "\n") end
    os.exit(1)
end
os.exit(0)
