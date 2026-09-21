-- diag.lua -- runtime dump of the classes this mod depends on.
--
-- Written once per session to AutoPalRevive-dump.txt next to config.ini. It
-- lists the real properties and functions of the live classes, which is the
-- fastest way to find out what a game patch renamed. Costs nothing and there
-- is no reason to make it a setting.

local U = require "util"
local P = require "palapi"

local D = {}

local CLASSES = {
    "/Script/Pal.PalPlayerController",
    "/Script/Pal.PalUtility",
    "/Script/Pal.PalIndividualCharacterParameter",
    -- The save struct is where PhysicalHealth / HP / PalReviveTimer live.
    "/Script/Pal.PalIndividualCharacterSaveParameter",
    "/Script/Pal.PalIndividualCharacterHandle",
    "/Script/Pal.PalOtomoHolderComponentBase",
    "/Script/Pal.PalGameSetting",
    "/Script/Pal.PalUIUtility",
    "/Script/Pal.PalNetworkBaseCampComponent",
    "/Script/Pal.PalIndividualCharacterParameterUtility",
}

local FUNCTIONS = {
    "/Script/Pal.PalIndividualCharacterParameter:GetHP",
    "/Script/Pal.PalIndividualCharacterParameter:GetMaxHP",
    "/Script/Pal.PalIndividualCharacterParameter:CleanupOnRevive",
    "/Script/Pal.PalOtomoHolderComponentBase:GetAllIndividualHandle",
    "/Script/Pal.PalOtomoHolderComponentBase:GetMaxOtomoNum",
    "/Script/Pal.PalOtomoHolderComponentBase:GetOtomoIndividualHandle",
    "/Script/Pal.PalIndividualCharacterHandle:TryGetIndividualParameter",
    "/Script/Pal.PalPlayerController:GetPlayerUId",
    "/Script/Pal.PalUtility:GetLocalPlayerUID",
    "/Script/Pal.PalUIUtility:ConvertReviveTimerToUIDisplayRemainReviveTime",
    "/Script/Pal.PalIndividualCharacterParameter:SetPhysicalHealth",
    "/Script/Pal.PalIndividualCharacterParameter:FullRecoveryHP",
    -- These four drive the Base Info worker list: which badge it shows, what
    -- colour it is, and the "Unconscious. Take it to the Palbox!" line. Their
    -- signatures decide whether that text can be corrected from Lua.
    "/Script/Pal.PalUIUtility:GetUIDisplayPalCondition",
    "/Script/Pal.PalUIUtility:GetPalConditionName",
    "/Script/Pal.PalUIUtility:GetPalConditionUrgency",
    "/Script/Pal.PalUIUtility:GetWorkerComment",
    "/Script/Engine.KismetTextLibrary:Conv_StringToText",
    "/Script/Pal.PalNetworkBaseCampComponent:RequestMoveWorkerToPalBox_ToServer",
}

local function structName(s)
    local n = U.str(U.callv(s, "GetFullName"), nil)
    if n then return n end
    return U.str(U.callv(s, "GetFName"), "?")
end

local function describeProperty(prop)
    local name = U.str(U.callv(prop, "GetFName"), nil)
        or U.str(U.callv(prop, "GetName"), "?")
    local class = U.callv(prop, "GetClass")
    local kind = "?"
    if class then
        kind = U.str(U.callv(class, "GetFName"), nil)
            or U.str(U.callv(class, "GetName"), "?")
    end
    return string.format("    %-48s %s", name, kind)
end

local function dumpStruct(out, struct, header)
    out[#out + 1] = ""
    out[#out + 1] = "=========================================================="
    out[#out + 1] = header
    out[#out + 1] = "  full name: " .. structName(struct)

    local super = U.callv(struct, "GetSuperStruct")
    if U.valid(super) then
        out[#out + 1] = "  super:     " .. structName(super)
    end

    out[#out + 1] = "  -- properties --"
    local props = 0
    pcall(function()
        struct:ForEachProperty(function(prop)
            props = props + 1
            out[#out + 1] = describeProperty(prop)
        end)
    end)
    if props == 0 then out[#out + 1] = "    (none readable)" end

    out[#out + 1] = "  -- functions --"
    local fns = 0
    pcall(function()
        struct:ForEachFunction(function(fn)
            fns = fns + 1
            local name = U.str(U.callv(fn, "GetFName"), "?")
            out[#out + 1] = "    " .. name
        end)
    end)
    if fns == 0 then out[#out + 1] = "    (none readable)" end
end

-- Parameter list of a single UFunction, in declaration order. Handy for
-- checking a signature before anything tries to call it.
function D.functionParams(path)
    local fn = U.global("StaticFindObject", path)
    if not U.valid(fn) then return nil end

    local params = {}
    local ok = pcall(function()
        fn:ForEachProperty(function(prop)
            local name = U.str(U.callv(prop, "GetFName"), nil)
                or U.str(U.callv(prop, "GetName"), "?")
            local class = U.callv(prop, "GetClass")
            local kind = class and (U.str(U.callv(class, "GetFName"), "?")) or "?"
            params[#params + 1] = { name = name, kind = kind }
        end)
    end)
    if not ok then return nil end
    return params
end

function D.dump(path)
    local out = {}
    out[#out + 1] = "AutoPalRevive class dump"
    out[#out + 1] = "generated: " .. os.date("%Y-%m-%d %H:%M:%S")
    out[#out + 1] = ""

    local keys, params, partyOk = P.partyKeys()
    out[#out + 1] = "Local player UID = " .. tostring(P.localPlayerUid())
    out[#out + 1] = "Party readable = " .. tostring(partyOk) .. "; parameters = " .. #params
    for _, param in ipairs(params) do
        local info = P.readInfo(param)
        out[#out + 1] = string.format("Party: %s; key=%s; owner=%s; state=%s; HP=%s/%s",
            P.label(info), tostring(P.individualKey(param)), tostring(info.owner),
            tostring(info.health), tostring(info.hp), tostring(info.maxhp))
    end
    local palbox = P.readPalBoxReviveTime()
    out[#out + 1] = "PalGameSetting.PalBoxReviveTime (live) = " .. tostring(palbox)
    out[#out + 1] = "save-parameter route in use            = " ..
        tostring(P.timerRouteName())
    out[#out + 1] = "PalReviveTimer polarity (probed)       = " ..
        tostring(P.timerPolarity())
    out[#out + 1] = "fast struct reads                      = " ..
        tostring(P.fastReadsVerdict())

    for _, cls in ipairs(CLASSES) do
        local obj = U.global("StaticFindObject", cls)
        if U.valid(obj) then
            dumpStruct(out, obj, "CLASS " .. cls)
        else
            out[#out + 1] = ""
            out[#out + 1] = "MISSING CLASS " .. cls
        end
    end

    for _, fnPath in ipairs(FUNCTIONS) do
        out[#out + 1] = ""
        out[#out + 1] = "=========================================================="
        out[#out + 1] = "FUNCTION " .. fnPath
        local params = D.functionParams(fnPath)
        if params == nil then
            out[#out + 1] = "  (not found)"
        elseif #params == 0 then
            out[#out + 1] = "  (no parameters)"
        else
            for i, p in ipairs(params) do
                out[#out + 1] = string.format("  %d. %-40s %s", i, p.name, p.kind)
            end
        end
    end

    out[#out + 1] = ""

    local file = io.open(path, "w")
    if not file then
        U.warn("could not write the diagnostics dump to %s", tostring(path))
        return false
    end
    file:write(table.concat(out, "\n"))
    file:close()
    U.info("diagnostics dump written to %s", tostring(path))
    return true
end

return D
