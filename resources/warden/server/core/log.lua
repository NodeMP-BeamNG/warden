-- core.log: node.log with the "[warden]" prefix and three levels. Kept as a
-- module so a test can read what was logged through the stub.

local M = {}

local function fmt(msg, ...)
    if select("#", ...) > 0 then
        local ok, text = pcall(string.format, tostring(msg), ...)
        if ok then return text end
    end
    return tostring(msg)
end

function M.info(msg, ...)
    node.log("[warden] " .. fmt(msg, ...))
end

function M.warn(msg, ...)
    if node.log.warn then node.log.warn("[warden] " .. fmt(msg, ...)) else M.info(msg, ...) end
end

function M.error(msg, ...)
    if node.log.error then node.log.error("[warden] " .. fmt(msg, ...)) else M.info(msg, ...) end
end

return M
