-- ==========================================================================
--  AutoPalRevive
--  Knocked-out Pals recover on a timer wherever they are: in your party,
--  lying in a base, or sitting in the Palbox.
--
--  Four settings, in ..\config.ini. Everything else is fixed on purpose.
-- ==========================================================================

local Ini = require "ini"
local U   = require "util"
local P   = require "palapi"
local D   = require "diag"
local UI  = require "ui"

local VERSION = "1.3.1"

-- Deliberately not configurable: these have one sensible value and turning
-- them into knobs only adds ways to break the mod.
local TICK_SECONDS  = 2     -- countdown step, and how fast a KO is noticed
local POOL_SECONDS  = 15    -- how often the full object-array scan re-runs
local MAX_POOL      = 4000  -- upper bound on Pals held in the scan pool
local RETRY_SECONDS = 5     -- wait before retrying a revive that did not take
local MAX_RETRIES   = 60

--==========================================================================
-- paths
--==========================================================================

local function modRoot()
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", ""):gsub("\\", "/")
    return src:match("^(.*)/[Ss]cripts/[^/]+$")
end

local ROOT        = modRoot()
local CONFIG_PATH = (ROOT or ".") .. "/config.ini"
local DUMP_PATH   = (ROOT or ".") .. "/AutoPalRevive-dump.txt"

--==========================================================================
-- config
--==========================================================================

local C = {}

local function loadConfig(quiet)
    local data, err = Ini.load(CONFIG_PATH)
    if not data then
        data = {}
        U.warn("%s - falling back to 10 minutes for party and base", tostring(err))
    end

    C.partyEnabled = Ini.bool(data, "Party", "Enabled", true)
    C.partyMinutes = math.max(0, Ini.num(data, "Party", "ReviveMinutes", 10))
    C.baseEnabled  = Ini.bool(data, "Base",  "Enabled", true)
    C.baseMinutes  = math.max(0, Ini.num(data, "Base",  "ReviveMinutes", 10))

    if not quiet then
        U.info("party=%s  base=%s",
            C.partyEnabled and (C.partyMinutes .. " min") or "off",
            C.baseEnabled  and (C.baseMinutes  .. " min") or "off")
    end
end

local function minutesFor(scope)
    return (scope == "party") and C.partyMinutes or C.baseMinutes
end

local function enabledFor(scope)
    if scope == "party" then return C.partyEnabled end
    return C.baseEnabled
end

--==========================================================================
-- state
--==========================================================================

-- individualKey -> { param, scope, label, remaining, failures }
local tracked = {}

local lastRun       = nil
local lastPool      = nil
local pool          = {}    -- Pal parameters, refreshed every POOL_SECONDS
local pending       = false
local dumped        = false
local warnedNoUid   = false
local warnedNoState = false
local uiWindow      = nil   -- PalBoxReviveTime in seconds, for the UI timer

--==========================================================================
-- predicates
--==========================================================================

-- nil = the health state could not be read
local function downedByHealth(health)
    if health == nil then return nil end
    if health == P.HEALTH.CloudCemetery then return false end -- hardcore, gone
    return health == P.HEALTH.Dying or health == P.HEALTH.DeadBody
end

local function zeroHp(param)
    local hp, maxhp = P.hp(param)
    return maxhp ~= nil and maxhp > 0 and hp ~= nil and hp <= 0
end

-- Pre-filter run over every loaded Pal several times a second. It uses the
-- cheap struct reads only once those have been verified against the game's
-- own accessors on this build; otherwise it pays for the accessors.
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
    -- Safety net: a Pal on 0 HP is down whatever the state field says.
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

--==========================================================================
-- discovery
--==========================================================================

local function track(param, scope, key, info)
    local entry = tracked[key]
    if entry then
        entry.param = param
        if entry.scope ~= scope then
            entry.remaining = math.max(0, minutesFor(scope) * 60 - entry.elapsed)
        end
        entry.scope = scope
        entry.label = P.label(info)
        return entry
    end

    entry = {
        param     = param,
        scope     = scope,
        label     = P.label(info),
        remaining = minutesFor(scope) * 60,
        failures  = 0,
        elapsed   = 0,
        fresh     = true,
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
    -- Local party membership proves ownership even if the UID accessor is absent.
    if scope ~= "party" and not ownedByMe(info, myUid) then return key end

    if isDowned(info) then
        track(param, scope, key, info)
    elseif tracked[key] and not tracked[key].reviving then
        U.verbose("%s recovered on its own", P.label(info))
        tracked[key] = nil
    elseif scope == "party" and not warnedNoState
           and info.health == nil and info.hp == nil then
        -- Neither signal readable means this Pal could never be seen as
        -- down. Say so once rather than silently doing nothing.
        warnedNoState = true
        U.warn("cannot read health or HP for %s - party Pals will not be detected",
            P.label(info))
    end

    return key
end

local function discover(now, myUid)
    -- The party is read every tick: it is only a handful of Pals, and the
    -- otomo holder is the one place that knows which slots are party slots.
    local partyKeys, partyParams, ok = P.partyKeys()
    if not ok then
        if not warnedNoState then
            warnedNoState = true
            U.warn("party slots not readable; revival paused to avoid using the wrong timer")
        end
        return false
    end

    -- Moving a Pal between party and base must immediately honor its new scope,
    -- even when that scope is disabled and consider() will never run for it.
    for key, entry in pairs(tracked) do
        local scope = partyKeys[key] and "party" or "base"
        if not enabledFor(scope) then
            tracked[key] = nil
        elseif entry.scope ~= scope then
            entry.remaining = math.max(0, minutesFor(scope) * 60 - entry.elapsed)
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

    if not C.baseEnabled and not C.partyEnabled then return end

    -- Walking the whole UObject array is the expensive part, so do that on a
    -- slow cadence and re-test the cached Pals every tick. A KO is then
    -- noticed within one tick rather than one full scan.
    if lastPool == nil or (now - lastPool) >= POOL_SECONDS then
        lastPool = now
        pool = {}
        U.each(U.global("FindAllOf", "PalIndividualCharacterParameter"), function(param)
            if #pool < MAX_POOL and U.valid(param) then
                pool[#pool + 1] = param
            end
        end)

        -- Re-check that the cheap reads still match the game's accessors.
        local before = P.fastReadsUsable()
        for i = 1, math.min(#pool, 3) do P.probeFastReads(pool[i]) end
        if before ~= P.fastReadsUsable() then
            U.verbose("fast state reads: %s", P.fastReadsVerdict())
        end
    end

    -- The sweep also covers party slots. Going through the otomo holder is
    -- the only way to know a Pal *is* a party Pal, but it is not a reliable
    -- way to reach every one of them - if a slot is missed there, the Pal
    -- used to fall through both paths and stay down forever. Seeing a Pal
    -- twice is harmless: tracking is keyed by individual id.
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

--==========================================================================
-- countdown
--==========================================================================

local function advance(key, entry, delta)
    local param = entry.param

    if entry.fresh then delta = 0; entry.fresh = false end
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
        U.err("giving up on %s after %d attempts - see %s",
            entry.label, entry.failures, DUMP_PATH)
        tracked[key] = nil
    end
end

--==========================================================================
-- tick
--==========================================================================

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
    UI.updatePartyTimers(tracked)
end

--==========================================================================
-- world lifecycle
--==========================================================================

-- PalGameSetting.PalBoxReviveTime is in minutes. It is both the vanilla
-- Palbox timer and the window the on-screen countdown is drawn against, so
-- keep it in step with [Base].
local function syncPalBoxTime()
    if C.baseEnabled then
        local before = P.readPalBoxReviveTime()
        local n = P.applyPalBoxReviveTime(C.baseMinutes)
        if n > 0 and before ~= C.baseMinutes then
            U.verbose("Palbox revive time %s -> %d min", tostring(before), C.baseMinutes)
        end
    end
    uiWindow = (P.readPalBoxReviveTime() or C.baseMinutes) * 60
end

--==========================================================================
-- what the UI hooks ask us
--==========================================================================

local function anyTracked()
    return next(tracked) ~= nil
end

-- Remaining seconds for a Pal the UI is drawing, or nil if we are not
-- counting that one down. Only walks the table while something is down.
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
    UI.updatePartyTimers(tracked)
    warnedNoUid = false
    warnedNoState = false
    lastRun  = nil
    lastPool = nil
    pool     = {}

    syncPalBoxTime()
    UI.install(remainingFor, anyTracked)

    if not dumped then
        dumped = true
        D.dump(DUMP_PATH)
    end
end

--==========================================================================
-- boot
--==========================================================================

loadConfig(false)
U.info("v%s loaded", VERSION)
UI.installHud()

NotifyOnNewObject("/Script/Pal.PalGameSetting", function(setting)
    if C.baseEnabled then
        U.set(setting, "PalBoxReviveTime", C.baseMinutes)
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
    local now = os.time()
    if lastRun == nil then
        lastRun = now
        return false
    end

    local delta = now - lastRun
    if delta < TICK_SECONDS then return false end
    lastRun = now

    -- Never let a loading screen dump a huge chunk of time into the timers.
    if delta > TICK_SECONDS * 4 then delta = TICK_SECONDS * 4 end

    if pending then return false end
    pending = true

    ExecuteInGameThread(function()
        pending = false
        local ok, err = pcall(tick, delta)
        if not ok then U.err("tick failed: %s", tostring(err)) end
    end)

    return false -- keep looping
end)
