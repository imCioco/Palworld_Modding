local U = require "util"
local P = require "palapi"
local Icons = {}
local CLASS = "WBP_PalCommonCharacterSlot_C"
local visible, collapsed = 3, 1
local known, touched, trackedRef = {}, {}, {}
local resolver, busy = nil, false
local installed, lastHookAttempt = {}, nil
local seeded, lastScan = false, nil
local announced, warned = false, false
local unmatchedSince, lastError = nil, nil

local function guarded(fn)
    if busy then return end
    busy = true
    local ok, err = pcall(fn)
    busy = false
    if not ok then
        lastError = tostring(err)
        U.verbose("party icon refresh: %s", lastError)
    end
end

local function parameter(widget)
    local param = U.unwrap(U.get(widget, "CurrentBoundParameter"))
    if U.valid(param) then return param end
    local handle = U.unwrap(U.get(widget, "LastHandle"))
    if not U.valid(handle) then
        local slot = U.unwrap(U.get(widget, "targetSlot"))
        handle = U.unwrap(U.callv(slot, "GetHandle"))
    end
    param = U.unwrap(U.callv(handle, "TryGetIndividualParameter"))
    if U.valid(param) then return param end
    return nil
end

local function isDown(param)
    if not U.valid(param) then return false end
    local health = P.physicalHealth(param)
    if health == P.HEALTH.CloudCemetery then return false end
    if health == P.HEALTH.Dying or health == P.HEALTH.DeadBody then return true end
    local hp, maxhp = P.hp(param)
    return hp ~= nil and maxhp ~= nil and maxhp > 0 and hp <= 0
end

local function widgetId(widget)
    if not U.valid(widget) then return nil end
    local id = U.str(U.callv(widget, "GetFullName"), nil)
    if id and not id:find("Default__", 1, true) then return id end
end

-- Native callbacks can invalidate the cached label.
local function writeLabel(state, value, force)
    if force then
        if U.str(U.callv(state.label, "GetText"), nil) == value then
            state.text = value
            return
        end
    elseif state.text == value then return end
    local text = P.makeText(value)
    if text ~= nil then
        local ok, err = U.call(state.label, "SetText", text)
        if ok then state.text = value else lastError = tostring(err) end
    end
end

local function visibility(state, value, force)
    if force then
        if U.num(U.callv(state.overlay, "GetVisibility"), nil) == value then
            state.visibility = value
            return
        end
    elseif state.visibility == value then return end
    if U.call(state.overlay, "SetVisibility", value) then state.visibility = value end
end

local function clear(state, force)
    visibility(state, collapsed, force)
    writeLabel(state, "", force)
end

local function restore(state, param)
    U.set(state.widget, "isDisplayReviveTimer", state.display)
    clear(state, true)
    -- Restore native recovery only for a downed Pal.
    if state.display and isDown(param) then
        U.call(state.widget, "OnUpdateReviveTimer_Binded",
            P.getReviveTimer(param) or 0, P.getReviveSpeed(param) or 1)
    end
    state.active = false
end

local function paint(widget, entry, key, id, force)
    local state = touched[id]
    if not state then
        local overlay, label = U.get(widget, "Overlay_Revive"), U.get(widget, "Text_ReviveTimer")
        local display = U.bool(U.get(widget, "isDisplayReviveTimer"), nil)
        if not (U.valid(overlay) and U.valid(label)) or display == nil then return false end
        state = {widget = widget, overlay = overlay, label = label, display = display}
        touched[id] = state
    end
    if not (U.valid(state.overlay) and U.valid(state.label)) then
        touched[id] = nil
        return false
    end
    local changed = not state.active or state.key ~= key
    state.active, state.key = true, key
    if changed or force then U.set(widget, "isDisplayReviveTimer", true) end
    local seconds = math.max(0, math.ceil(entry.remaining))
    local value = entry.reviving and "Retrying"
        or string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
    writeLabel(state, value, force or changed)
    visibility(state, visible, force or changed)
    return true
end

local function refreshWidget(widget, resolve, empty, force, timerOnly)
    local id = widgetId(widget)
    if not id then return false end
    local state = touched[id]
    -- Ignore timer broadcasts for untouched icons.
    if timerOnly and not state then return false end
    if not timerOnly then known[id] = widget end
    local param = not empty and parameter(widget) or nil
    local key = param and P.individualKey(param)
    local entry = key and trackedRef[key]
    if key and resolve and resolver then entry = resolver(param) end
    if entry and entry.scope == "party" and isDown(param) then
        return paint(widget, entry, key, id, force)
    elseif state then
        if state.active then restore(state, param)
        elseif force and key == state.key and not isDown(param) then clear(state, true) end
    end
    return false
end

local common = "/Game/Pal/Blueprint/UI/Thumbnails/Character/WBP_PalCommonCharacterSlot.WBP_PalCommonCharacterSlot_C:"
local function updateAll(tracked)
    trackedRef = tracked
    local partyCount = 0
    for _, entry in pairs(tracked) do
        if entry.scope == "party" then partyCount = partyCount + 1 end
    end
    local now = os.time()
    -- Scan once per world; repeat only if binding hooks are unavailable.
    local bindingReady = installed[common .. "OnSetValidSlot_Binded"]
        and installed[common .. "On Update Slot Binded"]
    if partyCount > 0 and (not seeded or (not bindingReady and now - lastScan >= 15)) then
        U.each(U.global("FindAllOf", CLASS), function(widget)
            local id = widgetId(widget)
            if id then known[id] = widget end
        end)
        seeded, lastScan = true, now
    end
    local found, bound, updated = 0, 0, 0
    for id, widget in pairs(known) do
        if not U.valid(widget) then known[id], touched[id] = nil, nil
        elseif partyCount > 0 or (touched[id] and touched[id].active) then
            found = found + 1
            if U.valid(parameter(widget)) then bound = bound + 1 end
            if refreshWidget(widget, false, false, false) then updated = updated + 1 end
        end
    end
    if updated > 0 then
        unmatchedSince = nil
        if not announced then
            announced = true
            U.info("party icon recovery overlay connected (%d widgets)", updated)
        end
    elseif partyCount > 0 then
        unmatchedSince = unmatchedSince or now
        if not warned and now - unmatchedSince >= 10 then
            warned = true
            U.warn("party icon countdown unavailable: %d slots found, %d bound, %d recovering Pals; last error: %s",
                found, bound, partyCount, tostring(lastError))
        end
    else unmatchedSince = nil end
end

function Icons.configure(findEntry) resolver = findEntry end
function Icons.update(tracked) guarded(function() updateAll(tracked) end) end
function Icons.reset()
    guarded(function()
        for _, state in pairs(touched) do
            if state.active and U.valid(state.widget) then restore(state, nil) end
        end
        known, touched, trackedRef = {}, {}, {}
        seeded, lastScan, unmatchedSince = false, nil, nil
    end)
end

function Icons.installHooks()
    local now = os.time()
    if lastHookAttempt and now - lastHookAttempt < 5 then return end
    lastHookAttempt = now
    for _, name in ipairs({"OnInitialized", "OnUpdateReviveTimer_Binded", "On Update HP Binded",
        "On Update Slot Binded", "OnSetValidSlot_Binded", "On Set Empty Binded"}) do
        local path = common .. name
        if not installed[path] and U.valid(U.global("StaticFindObject", path)) then
            local empty = name == "On Set Empty Binded"
            local timerOnly = name == "OnUpdateReviveTimer_Binded"
            local ok, err = pcall(RegisterHook, path, function(context)
                guarded(function()
                    refreshWidget(U.unwrap(context), not timerOnly, empty, true, timerOnly)
                end)
            end)
            if ok then installed[path] = true else lastError = tostring(err) end
        end
    end
end

return Icons
