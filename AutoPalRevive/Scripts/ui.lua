-- ui.lua -- make the game's own UI say what is actually happening.
--
-- The Base Info worker list has no "recovering" state of its own: a knocked
-- out Pal is EPalUIConditionType::Dying, which renders as a red
-- "Incapacitated" chip and the line "Unconscious. Take it to the Palbox!".
-- Under this mod that instruction is simply wrong.
--
-- Three UPalUIUtility functions produce that row, and all three are
-- blueprint-callable, so they can be hooked:
--
--   GetWorkerComment(ctx, targetHandle, outName:FText)   <- per Pal
--   GetPalConditionName(ctx, ConditionType, outName:FText)
--   GetPalConditionUrgency(ctx, Condition) -> int        <- drives the colour
--
-- The first one knows which Pal it is being asked about, so it gets the live
-- countdown. The other two only know the condition, so they are only touched
-- while at least one Pal is actually recovering.

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
local partyRows = {}
local hudInstalled = false
local hudWarning = false
local hudSeen = false
local hudWaitStarted = nil

-- Only plain Lua values are retained for drawing; no Pal or widget objects.
function UI.updatePartyTimers(tracked)
    partyRows = {}
    for key, entry in pairs(tracked) do
        if entry.scope == "party" then
            local remaining = math.max(0, entry.remaining)
            local total = entry.elapsed + remaining
            partyRows[#partyRows + 1] = {
                key = key,
                text = entry.label .. " - " .. (entry.reviving and "Retrying" or U.duration(remaining)),
                progress = total > 0 and U.clamp(entry.elapsed / total, 0, 1) or 1,
            }
        end
    end
    table.sort(partyRows, function(a, b) return a.key < b.key end)
    if #partyRows == 0 then
        hudWaitStarted = nil
    elseif hudInstalled and not hudSeen and not hudWarning then
        hudWaitStarted = hudWaitStarted or os.time()
        if os.time() - hudWaitStarted >= 10 then
            hudWarning = true
            U.warn("HUD draw event has not fired; party countdown overlay unavailable, revival continues")
        end
    end
end

local function drawPartyTimers(context, sizeX, sizeY)
    local hud = U.unwrap(context)
    if not U.valid(hud) then return end
    hudSeen = true
    if #partyRows == 0 then return end
    local owner = U.get(hud, "PlayerOwner")
    if not U.valid(owner) or not U.bool(U.callv(owner, "IsLocalPlayerController"), false) then return end
    if not U.valid(U.get(hud, "Canvas")) then return end
    local scale = U.clamp((U.num(U.unwrap(sizeY), 1080) or 1080) / 1080, 0.65, 2)
    local x, y, width = 28 * scale, 220 * scale, 310 * scale
    local font = U.global("StaticFindObject", "/Engine/EngineFonts/Roboto.Roboto")
    if not U.valid(font) then font = U.global("FindFirstOf", "Font") end
    if not U.valid(font) then return end
    local white = {R = 0.93, G = 0.98, B = 0.95, A = 1}
    local green = {R = 0.20, G = 0.85, B = 0.48, A = 1}
    local background = {R = 0.02, G = 0.03, B = 0.03, A = 0.8}
    local function draw(fn, ...)
        local ok, err = U.call(hud, fn, ...)
        if not ok and not hudWarning then
            hudWarning = true
            U.warn("party countdown drawing failed: %s", tostring(err))
        end
    end
    draw("DrawRect", background, x - 8 * scale, y - 6 * scale, width + 16 * scale,
        (28 + #partyRows * 40) * scale)
    draw("DrawText", "Party recovery", green, x, y, font, scale, false)
    for i, row in ipairs(partyRows) do
        local rowY = y + (24 + (i - 1) * 40) * scale
        draw("DrawText", row.text, white, x, rowY, font, scale, false)
        draw("DrawRect", green, x, rowY + 24 * scale, width * row.progress, 3 * scale)
    end
end

function UI.installHud()
    if hudInstalled then return end
    local ok, err = pcall(RegisterHook, "/Script/Engine.HUD:ReceiveDrawHUD", function(...)
        local good, detail = pcall(drawPartyTimers, ...)
        if not good and not hudWarning then
            hudWarning = true
            U.warn("party countdown drawing failed: %s", tostring(detail))
        end
    end)
    hudInstalled = ok
    if not ok then U.warn("party HUD hook unavailable: %s", tostring(err)) end
end

--==========================================================================
-- helpers
--==========================================================================

local function setText(outParam, str)
    local text = P.makeText(str)
    if text == nil then return false end
    if pcall(function() outParam:set(text) end) then return true end
    -- Some builds accept the raw string for a TextProperty.
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

-- Rather than guess which integer means "calm", ask the game what it
-- reports for a condition that is unambiguously fine and reuse that.
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

--==========================================================================
-- hooks
--==========================================================================

-- "Unconscious. Take it to the Palbox!" -> "Recovering - 1m 23s"
local function onWorkerComment(_Context, _ctx, targetHandle, outName)
    if reentrant or lookup == nil or outName == nil then return end
    local remaining = remainingFor(targetHandle)
    if remaining == nil then return end
    setText(outName, PREFIX .. " - " .. U.duration(remaining))
end

-- "Incapacitated" -> "Recovering"
local function onConditionName(_Context, _ctx, conditionType, outName)
    if reentrant or outName == nil then return end
    if anyDown == nil or not anyDown() then return end
    if not isDying(conditionType) then return end
    setText(outName, PREFIX)
end

-- Red chip -> whatever colour the game uses for a Pal that is fine.
local function onConditionUrgency(_Context, ctx, condition)
    if reentrant then return end
    if anyDown == nil or not anyDown() then return end
    if not isDying(condition) then return end

    local calm = getCalmUrgency(ctx)
    if calm == nil then return end
    return calm
end

--==========================================================================
-- install
--==========================================================================

local HOOKS = {
    { "/Script/Pal.PalUIUtility:GetWorkerComment",        onWorkerComment    },
    { "/Script/Pal.PalUIUtility:GetPalConditionName",     onConditionName    },
    { "/Script/Pal.PalUIUtility:GetPalConditionUrgency",  onConditionUrgency },
}

local function noop() end

-- lookupFn(param) -> remaining seconds or nil; anyDownFn() -> bool
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
