-- Add missing settings in-place without regenerating the user's document.
local Ini = require 'ini'
local S = require 'storage'
local U = require 'util'
local M = {}
local lastError
function M.heal(path, items)
    local original, err, code = S.recover(path)
    if original == nil and code ~= 2 then
        if err ~= lastError then U.warn('config repair deferred: %s', tostring(err)); lastError = err end
        return false
    end
    local text = original or ''
    local parsed = Ini.parse(text)
    local additions, order, count = {}, {}, 0
    local function ensure(section, key, value)
        local data = parsed[section:lower()]
        if data and data[Ini.key(key)] ~= nil then return end
        if not additions[section:lower()] then
            additions[section:lower()] = {name=section, lines={}}
            order[#order+1] = section:lower()
        end
        local lines = additions[section:lower()].lines
        lines[#lines+1] = key .. ' = ' .. value
        count = count + 1
        parsed[section:lower()] = data or {}
        parsed[section:lower()][Ini.key(key)] = value
    end
    ensure('Global', 'Enabled', 'true')
    ensure('Global', 'GlobalMultiplier', '1')
    for _, item in ipairs(items) do
        ensure(item.category, 'CategoryMultiplier', '1')
        ensure(item.category, item.name, '1')
    end
    if count == 0 then lastError = nil; return true end
    local newline = text:find('\r\n', 1, true) and '\r\n' or '\n'
    local sections, position, current = {}, 1, nil
    for raw in (text .. '\n'):gmatch('(.-)\n') do
        local line = raw:gsub('^\239\187\191', ''):gsub('\r$', '')
        local name = line:match('^%s*%[%s*([^%]]-)%s*%]%s*$')
        if name then
            if current then sections[current] = position end
            current = name:lower()
        end
        position = position + #raw + 1
    end
    if current then sections[current] = #text+1 end
    local inserts, tail = {}, {}
    for _, key in ipairs(order) do
        local addition = additions[key]
        local block = table.concat(addition.lines, newline) .. newline
        if sections[key] then
            inserts[#inserts+1] = {at=sections[key], text=newline .. block}
        else
            tail[#tail+1] = '[' .. addition.name .. ']' .. newline .. block
        end
    end
    table.sort(inserts, function(a,b) return a.at > b.at end)
    for _, insert in ipairs(inserts) do
        text = text:sub(1,insert.at-1) .. insert.text .. text:sub(insert.at)
    end
    if #tail > 0 then text = text .. newline .. table.concat(tail,newline) end
    local ok, failure = S.replace(path, original, text)
    if not ok then
        if failure ~= lastError then U.warn('config repair deferred: %s', tostring(failure)); lastError = failure end
        return false
    end
    lastError = nil
    U.info('config repaired: added %d missing settings', count)
    return true
end
return M
