-- util.lua -- logging + defensive UObject access helpers.
-- Everything that touches the game goes through pcall: a renamed property
-- after a game patch should downgrade the mod, not crash Palworld.

local U = {}

U.PREFIX = "[CustomCraftingMultiplier] "
-- 1 = load line, the table-patched line, and one line per recipe changed.
-- Raise to 2 here to log every row the mod looks at; it is not a
-- config.ini setting on purpose.
U.level  = 1

local pack   = table.pack or function(...) return { n = select("#", ...), ... } end
local unpack = table.unpack or unpack

--==========================================================================
-- logging
--==========================================================================

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
function U.warn(f, ...)    U.raw("WARN  " .. fmt(f, ...)) end
function U.err(f, ...)     U.raw("ERROR " .. fmt(f, ...)) end

--==========================================================================
-- object access
--==========================================================================

-- Global UE4SS function call that may not exist / may throw.
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

-- returns ok, result_or_error
function U.call(obj, name, ...)
    if obj == nil then return false, "nil object" end
    local args = pack(...)
    return pcall(function()
        local fn = obj[name]
        if fn == nil then error("no member '" .. tostring(name) .. "'", 0) end
        return fn(obj, unpack(args, 1, args.n))
    end)
end

-- returns result or nil
function U.callv(obj, name, ...)
    local ok, res = U.call(obj, name, ...)
    if ok then return res end
    return nil
end

-- Read a property off a UObject or a data-table row struct. UE4SS raises
-- rather than returning nil for a name the struct does not have, so this
-- always goes through pcall.
function U.get(obj, name)
    if obj == nil then return nil end
    local ok, v = pcall(function() return obj[name] end)
    if ok then return v end
    return nil
end

-- Write a property back. UDataTable:FindRow hands out a reference, so this
-- lands in the table itself. Returns true when the write went through.
function U.set(obj, name, value)
    if obj == nil then return false end
    return (pcall(function() obj[name] = value end))
end

-- Unwrap a UE4SS RemoteUnrealParam if that is what we got.
function U.unwrap(v)
    if v == nil then return nil end
    local ok, inner = pcall(function() return v:get() end)
    if ok and inner ~= nil then return inner end
    return v
end

--==========================================================================
-- value coercion
--==========================================================================

function U.num(v, default)
    if v == nil then return default end
    if type(v) == "number" then return v end
    if type(v) == "boolean" then return v and 1 or 0 end
    if type(v) == "string" then return tonumber(v) or default end

    local n = nil
    pcall(function() n = tonumber(v) end)
    if n then return n end

    local ok, inner = pcall(function() return v:get() end)
    if ok and inner ~= nil and inner ~= v then
        return U.num(inner, default)
    end

    return default
end

-- FName / FString / plain string
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

--==========================================================================
-- misc
--==========================================================================

function U.clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

return U
