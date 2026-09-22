local U = {}

U.PREFIX = "[AutoPalRevive] "
-- Log levels: 1 = normal, 2 = verbose, 3 = debug.
U.level  = 1

local pack   = table.pack or function(...) return { n = select("#", ...), ... } end
local unpack = table.unpack or unpack

function U.raw(msg)
    print(U.PREFIX .. tostring(msg) .. "\n")
end

local function fmt(f, ...)
    if select("#", ...) == 0 then return tostring(f) end
    local ok, s = pcall(string.format, f, ...)
    if ok then return s end
    return tostring(f)
end

function U.logf(lvl, f, ...)
    if U.level < lvl then return end
    U.raw(fmt(f, ...))
end

function U.info(f, ...)    U.logf(1, f, ...) end
function U.verbose(f, ...) U.logf(2, f, ...) end
function U.debug(f, ...)   U.logf(3, f, ...) end
function U.warn(f, ...)    U.raw("WARN  " .. fmt(f, ...)) end
function U.err(f, ...)     U.raw("ERROR " .. fmt(f, ...)) end
function U.global(name, ...)
    local g = _G[name]
    if type(g) ~= "function" then return nil end
    local args = pack(...)
    local ok, res = pcall(function() return g(unpack(args, 1, args.n)) end)
    if ok then return res end
    return nil
end

function U.valid(obj)
    if obj == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    if ok then return v == true end
    return false
end
function U.has(obj, name)
    if obj == nil then return false end
    local ok, v = pcall(function() return obj[name] end)
    return ok and v ~= nil
end
function U.call(obj, name, ...)
    if obj == nil then return false, "nil object" end
    local args = pack(...)
    return pcall(function()
        local fn = obj[name]
        if fn == nil then error("no member '" .. tostring(name) .. "'", 0) end
        return fn(obj, unpack(args, 1, args.n))
    end)
end
function U.callv(obj, name, ...)
    local ok, res = U.call(obj, name, ...)
    if ok then return res end
    return nil
end

function U.get(obj, name, default)
    if obj == nil then return default end
    local ok, v = pcall(function() return obj[name] end)
    if ok and v ~= nil then return v end
    return default
end

function U.set(obj, name, value)
    if obj == nil then return false, "nil object" end
    return pcall(function() obj[name] = value end)
end
function U.unwrap(v)
    if v == nil then return nil end
    local ok, inner = pcall(function() return v:get() end)
    if ok and inner ~= nil then return inner end
    return v
end
function U.num(v, default)
    if v == nil then return default end
    if type(v) == "number" then return v end
    if type(v) == "boolean" then return v and 1 or 0 end
    if type(v) == "string" then return tonumber(v) or default end

    local n = nil
    pcall(function() n = tonumber(v) end)
    if n then return n end

    for _, field in ipairs({ "Value", "value", "RawValue" }) do
        local ok, inner = pcall(function() return v[field] end)
        if ok and inner ~= nil then
            local m = tonumber(inner)
            if m then return m end
        end
    end

    local ok, inner = pcall(function() return v:get() end)
    if ok and inner ~= nil and inner ~= v then
        return U.num(inner, default)
    end

    return default
end

function U.bool(v, default)
    if v == nil then return default end
    if type(v) == "boolean" then return v end
    local n = U.num(v, nil)
    if n ~= nil then return n ~= 0 end
    return default
end
function U.str(v, default)
    if v == nil then return default end
    if type(v) == "string" then return v end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" then return s end
    ok, s = pcall(function() return v:get():ToString() end)
    if ok and type(s) == "string" then return s end
    ok, s = pcall(tostring, v)
    if ok then return s end
    return default
end
function U.each(arr, fn)
    if arr == nil then return 0 end

    local count = 0
    local ok = pcall(function()
        arr:ForEach(function(index, element)
            count = count + 1
            pcall(fn, U.unwrap(element), index)
        end)
    end)
    if ok then return count end

    if type(arr) == "table" then
        for i, e in ipairs(arr) do
            count = count + 1
            pcall(fn, U.unwrap(e), i)
        end
        return count
    end

    local n = U.num(U.callv(arr, "GetArrayNum"), nil)
    if n then
        for i = 1, n do
            local ok2, e = pcall(function() return arr[i] end)
            if ok2 and e ~= nil then
                count = count + 1
                pcall(fn, U.unwrap(e), i)
            end
        end
    end
    return count
end

function U.round(x)
    if x == nil then return nil end
    return math.floor(x + 0.5)
end

function U.clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end
function U.duration(seconds)
    if seconds == nil then return "?" end
    if seconds < 0 then seconds = 0 end
    local m = math.floor(seconds / 60)
    local s = math.floor(seconds % 60)
    if m > 0 then return string.format("%dm %02ds", m, s) end
    return string.format("%ds", s)
end

return U
