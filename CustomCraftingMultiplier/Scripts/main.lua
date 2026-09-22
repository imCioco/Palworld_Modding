-- CustomCraftingMultiplier 1.0: live catalog discovery and additive config repair.
local Ini = require 'ini'
local U = require 'util'
local seedOk, Seeds = pcall(require, 'catalog')
if not seedOk or type(Seeds)~='table' then Seeds = {} end
local Discovery = require 'discovery'
local Registry = require 'registry'
local Sync = require 'config_sync'
local src = (debug.getinfo(1, 'S').source or ''):gsub('^@', ''):gsub('\\', '/')
local ROOT = src:match('^(.*)/[Ss]cripts/[^/]+$') or '.'
local CONFIG = ROOT .. '/config.ini'
require('storage').configure(ROOT)
local registry = Registry.new(ROOT, Seeds)
local Items, byId = registry.items, registry.byId
local providers = {}
local C, signature, configError = nil, nil, nil
local states, statesByAddress = {}, {}
local ticks, worldAt, warnedSlow = 0, nil, false
local function finite(n)
    return type(n) == 'number' and n == n and n > -math.huge and n < math.huge
end
local function loadConfig()
    local data, err = Ini.load(CONFIG)
    if not data then
        if configError ~= err then U.warn('%s; keeping last loaded settings', tostring(err)) end
        configError = err
        if C then return end
        data = {}
    else configError = nil end
    local warnings, values = {}, {}
    local function number(section, key)
        local raw = Ini.str(data, section, key, nil)
        local n = raw == nil and 1 or tonumber(raw)
        if not finite(n) then
            warnings[#warnings+1] = string.format('[%s] %s is invalid; using 1', section, key)
            n = 1
        elseif n < 1 or n > 100 then
            warnings[#warnings+1] = string.format('[%s] %s is outside 1..100; clamping', section, key)
        end
        n = U.clamp(n, 1, 100)
        values[#values+1] = section .. '.' .. key .. '=' .. tostring(raw or '1')
        return n
    end
    local enabled = Ini.bool(data, 'Global', 'Enabled', true)
    local global = number('Global', 'GlobalMultiplier')
    local categories = {}
    for _, item in ipairs(Items) do categories[item.category] = true end
    local categoryValues, orderedCategories = {}, {}
    for name in pairs(categories) do orderedCategories[#orderedCategories+1] = name end
    table.sort(orderedCategories)
    for _, name in ipairs(orderedCategories) do categoryValues[name] = number(name, 'CategoryMultiplier') end
    local effective, active = {}, 0
    for _, item in ipairs(Items) do
        local mult = global * categoryValues[item.category] * number(item.category, item.name)
        effective[item.id] = enabled and math.min(mult, 100) or 1
        if effective[item.id] ~= 1 then active = active + 1 end
    end
    local nextSignature = tostring(enabled) .. '|' .. table.concat(values, '|')
    if nextSignature ~= signature then
        C = { effective=effective, enabled=enabled }
        signature = nextSignature
        for _, warning in ipairs(warnings) do U.warn('%s', warning) end
        U.info('config loaded: %d of %d supported items have a yield multiplier; enabled=%s', active, #Items, tostring(enabled))
    end
end
-- Distinguish replacement data tables when UE4SS exposes their address.
local function identity(dt)
    local address = U.callv(dt, 'GetAddress')
    return address ~= nil and tostring(address) or nil
end
local function patchTable(provider)
    local path, dt = provider.path, provider.object
    if not U.valid(dt) then return false end
    local names = U.callv(dt, 'GetRowNames')
    if type(names) ~= 'table' then return false end
    local address = identity(dt)
    local state = states[path]
    if not state or (address and state.address and state.address ~= address) then
        state = address and statesByAddress[address] or nil
        state = state or { address=address, rows={} }
        states[path] = state
        if address then statesByAddress[address] = state end
    end
    local matched = 0
    for _, name in ipairs(names) do
        local rowName = U.str(name, nil)
        local row = rowName and U.callv(dt, 'FindRow', rowName) or nil
        local product = U.str(U.get(row, 'Product_Id'), nil)
        local previous = state.rows[rowName]
        local item = byId[product]
        -- If live item metadata now excludes a formerly supported product,
        -- restore only the count this session owned before ceasing to patch it.
        if not item and previous and previous.product==product and previous.owned then
            item = registry.records[product]
        end
        if item then
            local current = U.num(U.get(row, 'Product_Count'), nil)
            if finite(current) and current >= 1 and current <= 2147483647 and current % 1 == 0 then
                matched = matched + 1
                local record = state.rows[rowName]
                if not record or record.product ~= product then
                    record = { product=product, base=current, owned=false }
                    state.rows[rowName] = record
                end
                local mult = byId[product] and C.effective[product] or 1
                local target = math.min(2147483647, math.floor(record.base * mult + 0.5))
                -- Default settings do not overwrite another mod's live changes.
                if mult ~= 1 or record.owned then
                    if current ~= target then
                        local ok = U.set(row, 'Product_Count', target)
                        local actual = U.num(U.get(row, 'Product_Count'), nil)
                        if ok and actual == target then
                            U.info('%s [%s]: %d -> %d per craft', item.name, rowName, current, target)
                            record.owned = mult ~= 1
                            record.failed = nil
                        elseif not record.failed then
                            U.warn('could not update Product_Count for %s; will retry', rowName)
                            record.failed = true
                        end
                    else
                        record.owned = mult ~= 1
                        record.failed = nil
                    end
                end
            elseif not state.badRows or not state.badRows[rowName] then
                state.badRows = state.badRows or {}
                state.badRows[rowName] = true
                U.warn('invalid Product_Count for %s; leaving this row unchanged', rowName)
            end
        end
    end
    if state.matched ~= matched then
        U.info('recipe table ready: %d supported recipe rows of %d in %s', matched, #names, path)
        state.matched = matched
    end
    return matched > 0
end
local function apply()
    local found = false
    for _, provider in ipairs(providers) do if patchTable(provider) then found = true end end
    if not found and worldAt and ticks-worldAt >= 60 and not warnedSlow then
        warnedSlow = true
        U.warn('no supported recipe rows found after world load; check recipe table paths and supported product IDs')
    end
end
local lastPending
local function refresh()
    local candidates, pending
    providers, candidates, pending = Discovery.scan(ticks)
    registry:reconcile(candidates)
    if #providers>0 then
        registry:save()
        Sync.heal(CONFIG, Items)
        if pending>0 and pending~=lastPending then
            U.info('item type/name data pending for %d recipe products; discovery will retry',pending)
        end
        lastPending = pending
    end
    loadConfig()
    apply()
end
loadConfig()
U.info('v1.0 loaded: %d catalog entries; discovery and settings refresh every 10 seconds', #Items)
local function worldReady()
    worldAt, warnedSlow = ticks, false
    local ok, err = pcall(refresh)
    if not ok then U.err('world setup failed: %s', tostring(err)) end
end
for _, path in ipairs({ '/Script/Engine.PlayerController:ClientRestart', '/Script/Engine.PlayerController:ServerAcknowledgePossession' }) do
    local ok, err = pcall(RegisterHook, path, worldReady)
    if not ok then U.warn('could not register %s: %s; periodic table checks remain active', path, tostring(err)) end
end
local pending, lastError = false, nil
LoopAsync(1000, function()
    ticks = ticks + 1
    if not pending and (ticks == 1 or ticks % 10 == 0) then
        pending = true
        local ok, err = pcall(ExecuteInGameThread, function()
            pending = false
            local success, failure = pcall(refresh)
            if not success then
                local message = tostring(failure)
                if message ~= lastError then U.err('recipe refresh failed: %s', message) end
                lastError = message
            else lastError = nil end
        end)
        if not ok then
            pending = false
            U.warn('could not schedule recipe refresh: %s', tostring(err))
        end
    end
    return false
end)
