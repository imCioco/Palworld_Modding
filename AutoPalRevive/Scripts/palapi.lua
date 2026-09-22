local U = require "util"

local P = {}
P.HEALTH = {
    Healthful     = 0,
    MinorInjury   = 1,
    Severe        = 2,
    Dying         = 3,
    DeadBody      = 4,
    CloudCemetery = 5,
}

P.HEALTH_NAME = {
    [0] = "Healthful",
    [1] = "MinorInjury",
    [2] = "Severe",
    [3] = "Dying",
    [4] = "DeadBody",
    [5] = "CloudCemetery",
}

function P.palUtility()
    local o = U.global("StaticFindObject", "/Script/Pal.Default__PalUtility")
    if U.valid(o) then return o end
    return nil
end

function P.uiUtility()
    local o = U.global("StaticFindObject", "/Script/Pal.Default__PalUIUtility")
    if U.valid(o) then return o end
    return nil
end
local textLibrary = nil
function P.makeText(str)
    if not U.valid(textLibrary) then
        textLibrary = U.global("StaticFindObject", "/Script/Engine.Default__KismetTextLibrary")
    end
    local ktl = textLibrary
    if not U.valid(ktl) then return nil end

    for _, fn in ipairs({ "Conv_StringToText", "MakeLiteralText" }) do
        local text = U.callv(ktl, fn, tostring(str))
        if text ~= nil then return text end
    end
    return nil
end
local UI_CONDITION_FALLBACK = {
    None = 0, Happy = 1, Unhappy = 2, MinorInjury = 3, Severe = 4,
    Dying = 5, Hunger = 6, Starvation = 7, Cold = 8, Sprain = 9,
    Bulimia = 10, GastricUlcer = 11, Fracture = 12, Weakness = 13,
    DepressionSprain = 14, DisturbingElement = 15,
}

local uiConditions = nil

local function loadUiConditions()
    if uiConditions ~= nil then return uiConditions end

    local enum = U.global("StaticFindObject", "/Script/Pal.EPalUIConditionType")
    if not U.valid(enum) then return nil end

    local map = {}
    for value = 0, 31 do
        local raw = U.str(U.callv(enum, "GetNameByValue", value), nil)
        if raw and raw ~= "" then
            local short = raw:match("::([%w_]+)$") or raw
            if UI_CONDITION_FALLBACK[short] ~= nil then map[short] = value end
        end
    end

    if next(map) == nil then return nil end
    uiConditions = map
    return uiConditions
end

function P.uiCondition(name)
    local map = loadUiConditions()
    if map and map[name] ~= nil then return map[name] end
    return UI_CONDITION_FALLBACK[name]
end

function P.playerController()
    local first = U.global("FindFirstOf", "PalPlayerController")
    if U.valid(first) and U.bool(U.callv(first, "IsLocalPlayerController"), false) then
        return first
    end
    local found
    U.each(U.global("FindAllOf", "PalPlayerController"), function(pc)
        if found == nil and U.valid(pc)
           and U.bool(U.callv(pc, "IsLocalPlayerController"), false) then found = pc end
    end)
    return found
end

function P.playerPawn()
    local pc = P.playerController()
    if not U.valid(pc) then return nil end
    for _, fn in ipairs({ "GetDefaultPlayerCharacter", "GetControlPalCharacter" }) do
        local c = U.callv(pc, fn)
        if U.valid(c) then return c end
    end
    local p = U.get(pc, "Pawn")
    if U.valid(p) then return p end
    return nil
end

function P.inWorld()
    return P.playerController() ~= nil
end
function P.guidKey(g)
    g = U.unwrap(g)
    if g == nil then return nil end

    local ok, a, b, c, d = pcall(function() return g.A, g.B, g.C, g.D end)
    if not ok or a == nil then return nil end

    local na = U.num(a, 0) or 0
    local nb = U.num(b, 0) or 0
    local nc = U.num(c, 0) or 0
    local nd = U.num(d, 0) or 0
    if na == 0 and nb == 0 and nc == 0 and nd == 0 then return "0" end
    return string.format("%.0f-%.0f-%.0f-%.0f", na, nb, nc, nd)
end
function P.individualKey(param)
    local id = U.unwrap(U.get(param, "IndividualId") or U.callv(param, "GetIndividualID"))
    if id ~= nil then
        local instance = P.guidKey(U.get(id, "InstanceId"))
        if instance and instance ~= "0" then
            local owner = P.guidKey(U.get(id, "PlayerUId")) or "?"
            return owner .. "/" .. instance
        end
    end

    local full = U.callv(param, "GetFullName")
    if full then return "obj:" .. U.str(full, "?") end
    return nil
end

function P.localPlayerUid()
    local pc = P.playerController()
    if U.valid(pc) then
        local key = P.guidKey(U.callv(pc, "GetPlayerUId"))
        if key and key ~= "0" then return key end
    end

    local util = P.palUtility()
    if U.valid(util) then
        local key = P.guidKey(U.callv(util, "GetLocalPlayerUID", pc))
        if key and key ~= "0" then return key end
    end

    return nil
end

function P.otomoHolder()
    local util = P.palUtility()
    if U.valid(util) then
        for _, owner in ipairs({ P.playerController(), P.playerPawn() }) do
            if U.valid(owner) then
                local comp = U.callv(util, "GetOtomoHolderComponent", owner)
                if U.valid(comp) then return comp end
            end
        end
    end
    local pc, pawn = P.playerController(), P.playerPawn()
    local function same(a, b)
        if not (U.valid(a) and U.valid(b)) then return false end
        local name = U.callv(a, "GetFullName")
        return name ~= nil and name == U.callv(b, "GetFullName")
    end
    local found = nil
    U.each(U.global("FindAllOf", "PalOtomoHolderComponentBase"), function(comp)
        if found == nil and U.valid(comp) then
            local owner = U.callv(comp, "GetOwner")
            if same(owner, pc) or same(owner, pawn) then found = comp end
        end
    end)
    return found
end
function P.partyKeys()
    local keys, params = {}, {}

    local holder = P.otomoHolder()
    if not U.valid(holder) then return keys, params, false end

    local function take(handle)
        handle = U.unwrap(handle)
        if not U.valid(handle) then return end
        local param = U.unwrap(U.callv(handle, "TryGetIndividualParameter"))
        if not U.valid(param) then return end
        local key = P.individualKey(param)
        if key and not keys[key] then
            keys[key] = true
            params[#params + 1] = param
        end
    end

    local list = U.callv(holder, "GetAllIndividualHandle")
    U.each(list, take)
    local count = U.num(U.callv(holder, "GetMaxOtomoNum"), nil)
    local slotsReadable = count ~= nil and count >= 0
    if slotsReadable then
        for i = 0, math.min(count, 256) - 1 do
            take(U.callv(holder, "GetOtomoIndividualHandle", i))
        end
    end

    return keys, params, slotsReadable or list ~= nil
end
local saveRoute = nil
local SAVE_ROUTES = { "SaveParameter", "SaveParameterMirror", "RawSaveParameter" }

local function saveParam(param)
    if saveRoute then
        local s = U.get(param, saveRoute)
        if s ~= nil then return s end
    end
    for _, name in ipairs(SAVE_ROUTES) do
        local s = U.get(param, name)
        if s ~= nil then
            local ok = pcall(function() return s.PalReviveTimer end)
            if ok and U.get(s, "PalReviveTimer") ~= nil then
                saveRoute = name
                return s
            end
        end
    end
    return nil
end

function P.timerRouteName()
    return saveRoute
end

function P.physicalHealthFast(param)
    local s = saveParam(param)
    if s ~= nil then
        local v = U.num(U.get(s, "PhysicalHealth"), nil)
        if v ~= nil then return v end
    end
    return nil
end

function P.physicalHealth(param)
    local v = U.num(U.callv(param, "GetPhysicalHealth"), nil)
    if v ~= nil then return v end
    v = U.num(U.callv(param, "GetSaveParameterValue_PhysicalHealth"), nil)
    if v ~= nil then return v end
    return P.physicalHealthFast(param)
end
function P.hpFast(param)
    local s = saveParam(param)
    if s ~= nil then
        local hp    = U.num(U.get(s, "Hp"), nil)
        local maxhp = U.num(U.get(s, "MaxHP"), nil)
        if hp ~= nil and maxhp ~= nil then return hp, maxhp end
    end
    return nil, nil
end

function P.hp(param)
    local hp    = U.num(U.callv(param, "GetHP"), nil)
    local maxhp = U.num(U.callv(param, "GetMaxHP"), nil)
    if hp ~= nil and maxhp ~= nil then return hp, maxhp end

    local fhp, fmax = P.hpFast(param)
    return hp or fhp, maxhp or fmax
end
local fastOk = nil

function P.probeFastReads(param)
    if fastOk == false then return false end

    local trueHealth = U.num(U.callv(param, "GetPhysicalHealth"), nil)
    local trueHp     = U.num(U.callv(param, "GetHP"), nil)
    local trueMax    = U.num(U.callv(param, "GetMaxHP"), nil)
    if trueHealth == nil or trueHp == nil or trueMax == nil then
        return fastOk -- Insufficient data for this Pal.
    end

    local fastHealth = P.physicalHealthFast(param)
    local fastHp, fastMax = P.hpFast(param)

    local agrees = fastHealth == trueHealth
        and fastHp  ~= nil and ((fastHp  <= 0) == (trueHp  <= 0))
        and fastMax ~= nil and ((fastMax >  0) == (trueMax >  0))

    if not agrees then
        fastOk = false
    elseif fastOk == nil then
        fastOk = true
    end
    return fastOk
end

function P.fastReadsUsable()
    return fastOk == true
end

function P.fastReadsVerdict()
    if fastOk == nil then return "not probed yet" end
    return fastOk and "struct reads agree with the game" or "struct reads disagree, using accessors"
end

function P.readInfo(param)
    local i = { param = param }
    local save = saveParam(param)

    i.health   = P.physicalHealth(param)
    i.hp, i.maxhp = P.hp(param)
    i.isPlayer = U.bool(U.get(save, "IsPlayer"), nil)
    i.owner    = P.guidKey(U.get(save, "OwnerPlayerUId"))
    i.level    = U.num(U.callv(param, "GetLevel") or U.get(save, "Level"), nil)

    i.nick = U.str(U.callv(param, "GetNickname") or U.get(save, "NickName"), nil)
    if i.nick == nil or i.nick == "" then
        i.nick = U.str(U.callv(param, "GetCharacterID") or U.get(save, "CharacterID"), nil)
    end
    if i.nick == nil or i.nick == "" then i.nick = "Pal" end

    return i
end

function P.label(info)
    local name = info.nick or "Pal"
    if info.level then return string.format("%s (Lv%d)", name, info.level) end
    return name
end

function P.getReviveTimer(param)
    local s = saveParam(param)
    if s ~= nil then
        local v = U.num(U.get(s, "PalReviveTimer"), nil)
        if v ~= nil then return v end
    end
    return U.num(U.callv(param, "GetRespawnTime"), nil)
end

function P.setReviveTimer(param, value)
    local s = saveParam(param)
    if s == nil then return false end
    return (U.set(s, "PalReviveTimer", value))
end

function P.getReviveSpeed(param)
    return U.num(U.get(param, "PalReviveSpeedMultiplier"), nil)
end

function P.setReviveSpeed(param, value)
    return (U.set(param, "PalReviveSpeedMultiplier", value))
end
local polarity = nil -- "elapsed" | "remaining" | nil while unresolved

function P.timerPolarity()
    if polarity then return polarity end

    local ui  = P.uiUtility()
    local ctx = P.playerController()
    if not (U.valid(ui) and U.valid(ctx)) then return nil end

    local fn = "ConvertReviveTimerToUIDisplayRemainReviveTime"
    local low  = U.num(U.callv(ui, fn, ctx, 0.0,   1.0), nil)
    local high = U.num(U.callv(ui, fn, ctx, 120.0, 1.0), nil)
    if low == nil or high == nil or math.abs(high - low) < 0.0001 then
        return nil -- Retry the probe next tick.
    end

    polarity = (high < low) and "elapsed" or "remaining"
    return polarity
end

local function broadcastReviveUpdate(param, value, speed)
    local delegate = U.get(param, "OnUpdateReviveTimerDelegate")
    if delegate == nil then return false end
    return (pcall(function() delegate:Broadcast(value, speed) end))
end
function P.showCountdown(param, remainingSeconds, totalSeconds)
    local speed = P.getReviveSpeed(param)
    if speed == nil or speed < 1.0 then
        P.setReviveSpeed(param, 1.0)
        speed = 1.0
    end

    if remainingSeconds < 0 then remainingSeconds = 0 end
    local value
    if (P.timerPolarity() or "elapsed") == "elapsed"
       and totalSeconds and totalSeconds > 0 then
        value = totalSeconds - remainingSeconds
        if value < 0 then value = 0 end
        if value > totalSeconds then value = totalSeconds end
    else
        value = remainingSeconds
    end

    P.setReviveTimer(param, value)
    broadcastReviveUpdate(param, value, speed)
end

function P.clearCountdown(param)
    P.setReviveTimer(param, 0.0)
    broadcastReviveUpdate(param, 0.0, P.getReviveSpeed(param) or 1.0)
end
local function forceFullHp(param)
    local s = saveParam(param)
    if s == nil then return false end

    local maxhp = U.get(s, "MaxHP")
    if maxhp == nil then return false end

    U.set(s, "Hp", maxhp)

    local hp = U.get(s, "Hp")
    if hp ~= nil then
        for _, field in ipairs({ "Value", "value", "RawValue" }) do
            local mv = nil
            pcall(function() mv = maxhp[field] end)
            if mv ~= nil then
                U.set(hp, field, mv)
                break
            end
        end
    end
    return true
end

local function healthName(v)
    return P.HEALTH_NAME[v] or tostring(v)
end
-- Clear the health state before restoring HP.
function P.revive(param)
    local before = P.physicalHealth(param)
    if before == P.HEALTH.CloudCemetery then return false, "hardcore-lost Pal" end

    local okHealth = U.call(param, "SetPhysicalHealth", P.HEALTH.Healthful)
    local okHp     = U.call(param, "FullRecoveryHP")

    if not okHealth and not okHp then
        return false, "neither SetPhysicalHealth nor FullRecoveryHP could be called"
    end

    local hp, maxhp = P.hp(param)

    if hp ~= nil and hp <= 0 then
        U.call(param, "FullRecoveryHP")
        hp, maxhp = P.hp(param)
    end
    if hp ~= nil and maxhp ~= nil and hp < maxhp then
        U.call(param, "SetPhysicalHealth", P.HEALTH.Healthful)
        -- Unsummoned Pals may require a direct HP update.
        forceFullHp(param)
        hp, maxhp = P.hp(param)
    end

    local after = P.physicalHealth(param)

    if after ~= nil and after ~= P.HEALTH.Healthful then
        return false, string.format("state stayed %s (hp %s/%s)",
            healthName(after), tostring(hp), tostring(maxhp))
    end
    if hp ~= nil and hp <= 0 then
        return false, string.format("HP stayed at 0 (state %s, max %s)",
            healthName(after), tostring(maxhp))
    end

    if after == nil or hp == nil or maxhp == nil or maxhp <= 0 then
        return false, "could not verify health and HP after revival"
    end
    if hp < maxhp then
        return false, string.format("HP not full (%s/%s)", tostring(hp), tostring(maxhp))
    end
    P.clearCountdown(param)
    return true, string.format("%s -> Healthful, HP %s/%s",
        healthName(before), tostring(hp), tostring(maxhp))
end
-- PalBoxReviveTime is measured in minutes.
function P.applyPalBoxReviveTime(minutes)
    local applied = 0

    local all = U.global("FindAllOf", "PalGameSetting")
    U.each(all, function(setting)
        if U.valid(setting) then
            if U.set(setting, "PalBoxReviveTime", minutes) then
                applied = applied + 1
            end
        end
    end)

    local cdo = U.global("StaticFindObject", "/Script/Pal.Default__PalGameSetting")
    if U.valid(cdo) then
        if U.set(cdo, "PalBoxReviveTime", minutes) then applied = applied + 1 end
    end

    return applied
end

function P.readPalBoxReviveTime()
    local value = nil
    local all = U.global("FindAllOf", "PalGameSetting")
    U.each(all, function(setting)
        if value == nil and U.valid(setting) then
            value = U.num(U.get(setting, "PalBoxReviveTime"), nil)
        end
    end)
    return value
end

return P
