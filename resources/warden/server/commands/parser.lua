-- commands.parser: the words of a chat line. `/kick "Bob Smith" too fast`
-- -> name = "kick", words = { "Bob Smith", "too", "fast" }. Double quotes
-- group words; a backslash escapes a quote inside them. rest(i) gives the
-- raw text from word i on (a reason keeps its own spacing).
--
--   parser.parse(line) -> { name, words, raw, rest = fn(i) } | nil (not a command)

local util = require("core.util")

local M = {}

M.PREFIX = "/"

function M.words(text)
    local out, starts = {}, {}
    local i, n = 1, #text
    while i <= n do
        while i <= n and text:sub(i, i):match("%s") do i = i + 1 end
        if i > n then break end
        local start = i
        local buf = {}
        if text:sub(i, i) == '"' then
            i = i + 1
            while i <= n do
                local c = text:sub(i, i)
                if c == "\\" and i < n then
                    buf[#buf + 1] = text:sub(i + 1, i + 1)
                    i = i + 2
                elseif c == '"' then
                    i = i + 1
                    break
                else
                    buf[#buf + 1] = c
                    i = i + 1
                end
            end
        else
            while i <= n and not text:sub(i, i):match("%s") do
                buf[#buf + 1] = text:sub(i, i)
                i = i + 1
            end
        end
        out[#out + 1] = table.concat(buf)
        starts[#starts + 1] = start
    end
    return out, starts
end

function M.parse(line, prefix)
    prefix = prefix or M.PREFIX
    line = util.clean(line, 512)
    if line:sub(1, #prefix) ~= prefix then return nil end
    local body = line:sub(#prefix + 1)
    local words, starts = M.words(body)
    if #words == 0 then return nil end
    local name = table.remove(words, 1):lower()
    table.remove(starts, 1)
    return {
        name = name, words = words, raw = line,
        -- the text from word i (1-based among the arguments) to the end, as typed
        rest = function(i)
            local s = starts[i]
            if s == nil then return "" end
            return util.trim(body:sub(s))
        end,
    }
end

return M
