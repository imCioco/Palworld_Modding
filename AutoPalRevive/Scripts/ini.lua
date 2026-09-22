local Ini = {}

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Ini.parse(text)
    local data = {}
    local section = "general"
    data[section] = {}

    for rawline in tostring(text):gmatch("[^\r\n]+") do
        local line = trim(rawline)
        local first = line:sub(1, 1)

        if line == "" or first == ";" or first == "#" then

        else
            local name = line:match("^%[%s*([^%]]-)%s*%]$")
            if name then
                section = name:lower()
                data[section] = data[section] or {}
            else
                local key, value = line:match("^([^=]+)=(.*)$")
                if key then
                    value = trim(value)
                    local cut = value:find("[;#]")
                    if cut then value = trim(value:sub(1, cut - 1)) end
                    value = value:match('^"(.*)"$') or value
                    data[section][trim(key):lower()] = value
                end
            end
        end
    end

    return data
end

function Ini.load(path)
    local file = io.open(path, "r")
    if not file then return nil, "could not open " .. tostring(path) end
    local text = file:read("*a")
    file:close()
    if type(text) ~= "string" then return nil, "empty file" end
    return Ini.parse(text)
end

local function raw(data, section, key)
    if type(data) ~= "table" then return nil end
    local s = data[tostring(section):lower()]
    if type(s) ~= "table" then return nil end
    return s[tostring(key):lower()]
end

function Ini.str(data, section, key, default)
    local v = raw(data, section, key)
    if v == nil or v == "" then return default end
    return v
end

function Ini.num(data, section, key, default)
    local v = tonumber(raw(data, section, key))
    if v == nil then return default end
    return v
end

local TRUE  = { ["1"] = true, ["true"] = true, ["yes"] = true, ["on"]  = true, ["enabled"]  = true }
local FALSE = { ["0"] = true, ["false"] = true, ["no"] = true, ["off"] = true, ["disabled"] = true }

function Ini.bool(data, section, key, default)
    local v = raw(data, section, key)
    if v == nil then return default end
    v = tostring(v):lower()
    if TRUE[v]  then return true  end
    if FALSE[v] then return false end
    return default
end
function Ini.enum(data, section, key, allowed, default)
    local v = raw(data, section, key)
    if v == nil then return default end
    v = tostring(v):lower()
    for _, a in ipairs(allowed) do
        if v == a then return v end
    end
    return default
end

return Ini
