-- core.limiter: sliding-window rate limits, one bucket per key (a player id,
-- an op). Pure: the caller passes the clock.
--
--   local lim = limiter.new({ { n = 10, window = 1 }, { n = 120, window = 60 } })
--   lim:allow(key, now) -> true | false, retry_after_sec
--   lim:forget(key)
--   lim:reset()

local M = {}

local Limiter = {}
Limiter.__index = Limiter

function M.new(rules)
    local self = setmetatable({ rules = {}, buckets = {} }, Limiter)
    for _, r in ipairs(rules or {}) do
        self.rules[#self.rules + 1] = { n = r.n, window = r.window }
    end
    return self
end

-- one rule shorthand
function M.simple(n, window)
    return M.new({ { n = n, window = window } })
end

function Limiter.allow(self, key, now)
    now = now or os.time()
    local stamps = self.buckets[key]
    if stamps == nil then
        stamps = {}
        self.buckets[key] = stamps
    end
    -- drop what fell out of the longest window
    local longest = 0
    for _, r in ipairs(self.rules) do
        if r.window > longest then longest = r.window end
    end
    local keep = {}
    for _, ts in ipairs(stamps) do
        if now - ts < longest then keep[#keep + 1] = ts end
    end
    self.buckets[key] = keep
    stamps = keep
    for _, r in ipairs(self.rules) do
        local n, oldest = 0, nil
        for _, ts in ipairs(stamps) do
            if now - ts < r.window then
                n = n + 1
                if oldest == nil or ts < oldest then oldest = ts end
            end
        end
        if n >= r.n then
            return false, math.max(1, math.ceil(r.window - (now - oldest)))
        end
    end
    stamps[#stamps + 1] = now
    return true
end

function Limiter.forget(self, key)
    self.buckets[key] = nil
end

function Limiter.reset(self)
    self.buckets = {}
end

return M
