-- luacheck configuration: `luacheck resources tests tools`
std = "lua54"
max_line_length = 120
codes = true

exclude_files = { "tests/gate/_tmp/**", "dist/**", ".server/**" }

-- the server's prelude builds `node` for every resource
globals = { "node" }

files["resources/warden/server/**/*.lua"] = {
    -- the server half: `node` and the Lua 5.4 standard library
}

files["tests/unit/**/*.lua"] = {
    globals = { "node", "t", "WD_ROOT" },
    max_line_length = 140,
}

files["tests/gate/hooks/**/*.lua"] = {
    globals = { "node" },
}

files["tools/**/*.lua"] = {
    globals = { "node", "WD_ROOT" },
}

-- unused self (212) is fine in method-style modules
ignore = { "212/self" }
