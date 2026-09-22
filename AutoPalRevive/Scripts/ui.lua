local U = require "util"
local P = require "palapi"

local UI = {}

local PREFIX = "Recovering"

local lookup    = nil    -- function(param) -> remaining seconds, or nil
local anyDown   = nil    -- function() -> bool
local installed = false
local reentrant = false  -- guards the urgency probe against its own hook
local calmUrgency = nil
local dyingValue  = nil
local PartyIcons = require "partyicons"

function UI.configurePartyIcons(resolver)
    PartyIcons.configure(resolver)
end

function UI.installPartyIconHooks()
    PartyIcons.installHooks()
end

function UI.resetPartyIcons()
    PartyIcons.reset()
end

function UI.updatePartyTimers(tracked)
    PartyIcons.update(tracked)
end

local function setText(outParam, str)
    local text = P.makeText(str)
    if text == nil then return false end
    if pcall(function() outParam:set(text) end) then return true end
    return (pcall(function() outParam:set(str) end))
end

local function remainingFor(handle)
    if lookup == nil then return nil end
    handle = U.unwrap(handle)
    if not U.valid(handle) then return nil end
    local param = U.unwrap(U.callv(handle, "TryGetIndividualParameter"))
    if not U.valid(param) then return nil end
    return lookup(param)
end

local function isDying(conditionValue)
    if dyingValue == nil then dyingValue = P.uiCondition("Dying") end
    return dyingValue ~= nil and U.num(U.unwrap(conditionValue), nil) == dyingValue
end
-- Use the urgency value of the Happy condition.
local function getCalmUrgency(ctx)
    if calmUrgency ~= nil then return calmUrgency end
    if reentrant then return nil end

    local ui = P.uiUtility()
    local happy = P.uiCondition("Happy")
    if not (U.valid(ui) and happy) then return nil end

    reentrant = true
    calmUrgency = U.num(U.callv(ui, "GetPalConditionUrgency", ctx, happy), nil)
    reentrant = false

    return calmUrgency
end
local function onWorkerComment(_Context, _ctx, targetHandle, outName)
    if reentrant or lookup == nil or outName == nil then return end
    local remaining = remainingFor(targetHandle)
    if remaining == nil then return end
    setText(outName, PREFIX .. " - " .. U.duration(remaining))
end
local function onConditionName(_Context, _ctx, conditionType, outName)
    if reentrant or outName == nil then return end
    if anyDown == nil or not anyDown() then return end
    if not isDying(conditionType) then return end
    setText(outName, PREFIX)
end
local function onConditionUrgency(_Context, ctx, condition)
    if reentrant then return end
    if anyDown == nil or not anyDown() then return end
    if not isDying(condition) then return end

    local calm = getCalmUrgency(ctx)
    if calm == nil then return end
    return calm
end

local HOOKS = {
    { "/Script/Pal.PalUIUtility:GetWorkerComment",        onWorkerComment    },
    { "/Script/Pal.PalUIUtility:GetPalConditionName",     onConditionName    },
    { "/Script/Pal.PalUIUtility:GetPalConditionUrgency",  onConditionUrgency },
}

local function noop() end
function UI.install(lookupFn, anyDownFn)
    lookup  = lookupFn
    anyDown = anyDownFn
    if installed then return end

    local done, failed = 0, {}
    for _, entry in ipairs(HOOKS) do
        local path, post = entry[1], entry[2]
        local ok = pcall(RegisterHook, path, noop, function(...)
            local good, err = pcall(post, ...)
            if not good then
                U.verbose("UI hook %s: %s", path, tostring(err))
                return
            end
            return err
        end)
        if ok then done = done + 1 else failed[#failed + 1] = path end
    end

    installed = true

    if done > 0 then
        U.info("UI text hooked (%d/%d) - knocked-out Pals now read \"%s - <time>\"",
            done, #HOOKS, PREFIX)
    end
    for _, path in ipairs(failed) do
        U.warn("could not hook %s - that part of the UI keeps its vanilla text", path)
    end
end

return UI
