local Ini = require "ini"
local U   = require "util"
local P   = require "palapi"
local UI  = require "ui"

local VERSION = "1.0"
local TICK_SECONDS  = 1     -- countdown step, and how fast a KO is noticed
local POOL_SECONDS  = 15    -- how often the full object-array scan re-runs
local MAX_POOL      = 4000  -- upper bound on Pals held in the scan pool
local RETRY_SECONDS = 5     -- wait before retrying a revive that did not take
local MAX_RETRIES   = 60

local function modRoot()
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", ""):gsub("\\", "/")
    return src:match("^(.*)/[Ss]cripts/[^/]+$")
end

local ROOT        = modRoot()
local CONFIG_PATH = (ROOT or ".") .. "/config.ini"

local C = {}

local function loadConfig(quiet)
    local data, err = Ini.load(CONFIG_PATH)
    if not data then
        data = {}
        U.warn("%s - falling back to 600 seconds for party and base", tostring(err))
    end

    C.partyEnabled = Ini.bool(data, "Party", "Enabled", true)
    C.partySeconds = math.max(0, Ini.num(data, "Party", "ReviveSeconds", 600))
    C.baseEnabled  = Ini.bool(data, "Base",  "Enabled", true)
    C.baseSeconds  = math.max(0, Ini.num(data, "Base",  "ReviveSeconds", 600))

    if not quiet then
        U.info("party=%s  base=%s",
            C.partyEnabled and (C.partySeconds .. " s") or "off",
            C.baseEnabled  and (C.baseSeconds  .. " s") or "off")
    end
end

local function secondsFor(scope)
    return (scope == "party") and C.partySeconds or C.baseSeconds
end

local function enabledFor(scope)
    if scope == "party" then return C.partyEnabled end
    return C.baseEnabled
end
local tracked = {}

local lastRun       = nil
local lastPool      = nil
local pool          = {}    -- Pal parameters, refreshed every POOL_SECONDS
local pending       = false
local warnedNoUid   = false
local warnedNoState = false
local uiWindow      = nil   -- PalBoxReviveTime in seconds, for the UI timer
local partyCache, partyCacheAt, partyCacheOk = {}, nil, false
local lastBaseCheck = nil
local function downedByHealth(health)
    if health == nil then return nil end
    if health == P.HEALTH.CloudCemetery then return false end -- hardcore, gone
    return health == P.HEALTH.Dying or health == P.HEALTH.DeadBody
end

local function zeroHp(param)
    local hp, maxhp = P.hp(param)
    return maxhp ~= nil and maxhp > 0 and hp ~= nil and hp <= 0
end
-- Use validated struct reads for the cached Pal scan.
local function looksDown(param)
    if P.fastReadsUsable() then
        if downedByHealth(P.physicalHealthFast(param)) == true then return true end
        local hp, maxhp = P.hpFast(param)
        return maxhp ~= nil and maxhp > 0 and hp ~= nil and hp <= 0
    end

    if downedByHealth(P.physicalHealth(param)) == true then return true end
    return zeroHp(param)
end

local function isDowned(info)
    local byHealth = downedByHealth(info.health)
    if byHealth == true then return true end
    if info.health == P.HEALTH.CloudCemetery then return false end
    return info.maxhp ~= nil and info.maxhp > 0
       and info.hp ~= nil and info.hp <= 0
end

local function stillDowned(param)
    local health = P.physicalHealth(param)
    if health == P.HEALTH.CloudCemetery then return false end
    if downedByHealth(health) == true then return true end
    return zeroHp(param)
end

local function ownedByMe(info, myUid)
    if info.owner == nil or info.owner == "0" then return false end -- wild
    if myUid == nil then
        if not warnedNoUid then
            warnedNoUid = true
            U.warn("could not read your player id; base revival paused until your player id is readable")
        end
        return false
    end
    return info.owner == myUid
end

local function track(param, scope, key, info)
    local entry = tracked[key]
    if entry then
        entry.param = param
        if entry.scope ~= scope then
            entry.remaining = math.max(0, secondsFor(scope) - entry.elapsed)
        end
        entry.scope = scope
        entry.label = P.label(info)
        return entry
    end

    entry = {
        param     = param,
        scope     = scope,
        label     = P.label(info),
        remaining = secondsFor(scope),
        failures  = 0,
        elapsed   = 0,
        lastAdvanced = os.time(),
    }
    tracked[key] = entry

    U.info("%s went down [%s %s hp %s/%s] - back up in %s",
        entry.label,
        scope,
        P.HEALTH_NAME[info.health] or ("state?=" .. tostring(info.health)),
        tostring(info.hp), tostring(info.maxhp),
        U.duration(entry.remaining))

    P.showCountdown(param, entry.remaining, uiWindow)
    return entry
end

local function consider(param, scope, myUid)
    if not U.valid(param) then return nil end

    local key = P.individualKey(param)
    if key == nil then return nil end

    local info = P.readInfo(param)
    if info.isPlayer ~= false then return key end
    if scope ~= "party" and not ownedByMe(info, myUid) then return key end

    if isDowned(info) then
        track(param, scope, key, info)
    elseif tracked[key] and not tracked[key].reviving then
        U.verbose("%s recovered on its own", P.label(info))
        tracked[key] = nil
    elseif scope == "party" and not warnedNoState
           and info.health == nil and info.hp == nil then
        warnedNoState = true
        U.warn("cannot read health or HP for %s - party Pals will not be detected",
            P.label(info))
    end

    return key
end
-- Health and binding events reuse an existing countdown.
local function resolvePartyEntry(param)
    if not C.partyEnabled or not U.valid(param) then return nil end
    local key = P.individualKey(param)
    if not key then return nil end
    local entry = tracked[key]
    if not stillDowned(param) then
        if entry and not entry.reviving then tracked[key] = nil end
        return nil
    end
    if entry and entry.scope == "party" then
        entry.param = param
        return entry
    end
    local now = os.time()
    if partyCacheAt ~= now then
        local keys, _, ok = P.partyKeys()
        partyCache, partyCacheOk = keys, ok
        partyCacheAt = now
    end
    if partyCacheOk and partyCache[key] then
        local info = P.readInfo(param)
        if info.isPlayer == false then return track(param, "party", key, info) end
    end
    return nil
end

local function discover(now, myUid)
    local partyKeys, partyParams, ok = P.partyKeys()
    partyCache, partyCacheAt, partyCacheOk = partyKeys, now, ok
    if not ok then
        if not warnedNoState then
            warnedNoState = true
            U.warn("party slots not readable; revival paused to avoid using the wrong timer")
        end
        return false
    end
    for key, entry in pairs(tracked) do
        local scope = partyKeys[key] and "party" or "base"
        if not enabledFor(scope) then
            tracked[key] = nil
        elseif entry.scope ~= scope then
            entry.remaining = math.max(0, secondsFor(scope) - entry.elapsed)
            entry.scope = scope
        end
    end

    if C.partyEnabled then
        for _, param in ipairs(partyParams) do
            consider(param, "party", myUid)
        end
    else
        for key in pairs(partyKeys) do tracked[key] = nil end
    end
    if not C.baseEnabled then return true end
    if lastBaseCheck and now - lastBaseCheck < 2 then return true end
    lastBaseCheck = now
    -- Refresh the object pool every 15 seconds; check cached Pals every two seconds.
    if lastPool == nil or (now - lastPool) >= POOL_SECONDS then
        lastPool = now
        pool = {}
        U.each(U.global("FindAllOf", "PalIndividualCharacterParameter"), function(param)
            if #pool < MAX_POOL and U.valid(param) then
                pool[#pool + 1] = param
            end
        end)
        local before = P.fastReadsUsable()
        for i = 1, math.min(#pool, 3) do P.probeFastReads(pool[i]) end
        if before ~= P.fastReadsUsable() then
            U.verbose("fast state reads: %s", P.fastReadsVerdict())
        end
    end
    for i = 1, #pool do
        local param = pool[i]
        if U.valid(param) and looksDown(param) then
            local key = P.individualKey(param)
            if key ~= nil then
                local scope = partyKeys[key] and "party" or "base"
                local enabled = enabledFor(scope)
                if enabled then
                    consider(param, scope, myUid)
                end
            end
        end
    end
    return true
end

local function advance(key, entry, delta)
    local param = entry.param

    local now = os.time()
    delta = math.min(delta, math.max(0, now - entry.lastAdvanced))
    entry.lastAdvanced = now
    entry.elapsed = entry.elapsed + delta
    entry.remaining = entry.remaining - delta
    P.showCountdown(param, entry.remaining, uiWindow)

    if entry.remaining > 0 then return end

    entry.reviving = true
    local ok, detail = P.revive(param)
    if ok then
        U.info("%s is back on its feet (%s)", entry.label, tostring(detail))
        tracked[key] = nil
        return
    end

    entry.failures  = entry.failures + 1
    entry.remaining = RETRY_SECONDS
    if entry.failures == 1 or entry.failures % 12 == 0 then
        U.warn("could not revive %s: %s (attempt %d, retrying)",
            entry.label, tostring(detail), entry.failures)
    end
    if entry.failures >= MAX_RETRIES then
        U.err("giving up on %s after %d attempts: %s",
            entry.label, entry.failures, tostring(detail))
        tracked[key] = nil
    end
end

local function tick(delta)
    if not P.inWorld() then return end
    if not (C.partyEnabled or C.baseEnabled) then return end

    if not discover(os.time(), P.localPlayerUid()) then return end

    for key, entry in pairs(tracked) do
        if not enabledFor(entry.scope) or not U.valid(entry.param) then
            tracked[key] = nil
        elseif P.physicalHealth(entry.param) == P.HEALTH.CloudCemetery then
            tracked[key] = nil
        elseif not entry.reviving and not stillDowned(entry.param) then
            U.verbose("%s recovered on its own", entry.label)
            tracked[key] = nil
        else
            advance(key, entry, delta)
        end
    end
    local uiOk, uiErr = pcall(UI.updatePartyTimers, tracked)
    if not uiOk then U.verbose("party icon update failed: %s", tostring(uiErr)) end
end
-- PalBoxReviveTime uses minutes; config values use seconds.
local function syncPalBoxTime()
    if C.baseEnabled then
        local before = P.readPalBoxReviveTime()
        local n = P.applyPalBoxReviveTime(C.baseSeconds / 60)
        if n > 0 and before ~= C.baseSeconds / 60 then
            U.verbose("Palbox revive time %s -> %s s", tostring(before and before * 60), C.baseSeconds)
        end
    end
    uiWindow = (P.readPalBoxReviveTime() or C.baseSeconds / 60) * 60
end

local function anyTracked()
    return next(tracked) ~= nil
end
local function remainingFor(param)
    if next(tracked) == nil then return nil end
    local key = P.individualKey(param)
    if key == nil then return nil end
    local entry = tracked[key]
    if entry == nil then return nil end
    return math.max(0, entry.remaining)
end

local function onWorldReady()
    loadConfig(true)

    tracked  = {}
    UI.resetPartyIcons()
    local uiOk, uiErr = pcall(UI.updatePartyTimers, tracked)
    if not uiOk then U.verbose("party icon update failed: %s", tostring(uiErr)) end
    warnedNoUid = false
    warnedNoState = false
    lastRun  = nil
    lastPool = nil
    pool     = {}
    partyCache, partyCacheAt, partyCacheOk = {}, nil, false
    lastBaseCheck = nil

    syncPalBoxTime()
    UI.install(remainingFor, anyTracked)

end

loadConfig(false)
U.info("v%s loaded", VERSION)
UI.configurePartyIcons(resolvePartyEntry)
UI.updatePartyTimers(tracked)

local healthEventBusy = false
local function onHealthChanged(context)
    if healthEventBusy then return end
    healthEventBusy = true
    local ok, err = pcall(function()
        local param = U.unwrap(context)
        if not U.valid(param) then return end
        local key = P.individualKey(param)
        local before = key and tracked[key]
        local entry = resolvePartyEntry(param)
        if entry or before then UI.updatePartyTimers(tracked) end
    end)
    healthEventBusy = false
    if not ok then U.verbose("party health event: %s", tostring(err)) end
end

for _, name in ipairs({"SetPhysicalHealth", "FullRecoveryHP"}) do
    local ok, err = pcall(RegisterHook, "/Script/Pal.PalIndividualCharacterParameter:" .. name,
        function() end, onHealthChanged)
    if not ok then U.warn("could not hook %s: %s", name, tostring(err)) end
end

NotifyOnNewObject("/Script/Pal.PalGameSetting", function(setting)
    if C.baseEnabled then
        U.set(setting, "PalBoxReviveTime", C.baseSeconds / 60)
    end
end)

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    local ok, err = pcall(onWorldReady)
    if not ok then U.err("world setup failed: %s", tostring(err)) end
end)

RegisterHook("/Script/Engine.PlayerController:ServerAcknowledgePossession", function()
    local ok, err = pcall(onWorldReady)
    if not ok then U.err("world setup failed: %s", tostring(err)) end
end)

LoopAsync(1000, function()
    UI.installPartyIconHooks()
    if pending then return false end
    pending = true
    ExecuteInGameThread(function()
        pending = false
        local now = os.time()
        if lastRun == nil then lastRun = now end
        local delta = now - lastRun
        local ok, err
        if delta >= TICK_SECONDS then
            lastRun = now
            -- Limit elapsed time after a loading screen.
            delta = math.min(delta, 8)
            ok, err = pcall(tick, delta)
        else
            ok = true
        end
        if not ok then U.err("tick failed: %s", tostring(err)) end
    end)
    return false
end)
