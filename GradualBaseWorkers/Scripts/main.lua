--============================================================================
-- GradualBaseWorkers — Configuration
-- Edit these values to your liking, then restart the game.
--============================================================================

-- Workers gained per base level (level 1 = 1x, level 20 = 20x, etc.)
local WORKERS_PER_LEVEL = 5

-- Maximum bases per guild at each tier.
-- Set this to override ALL levels to a flat value, or nil to keep the game defaults.
local BASE_COUNT_OVERRIDE = 5

--============================================================================
-- End of configuration — do not edit below unless you know what you're doing.
--============================================================================

local MOD_NAME = "GradualBaseWorkers"
local applied = false

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, message))
end

local function getRowName(rowName)
    if type(rowName) == "string" then return rowName end
    local ok, result = pcall(function() return rowName:ToString() end)
    if ok and type(result) == "string" then return result end
    return tostring(rowName)
end

local function modifyBaseCampLevels()
    local dataTable = StaticFindObject("/Game/Pal/DataTable/BaseCamp/DT_BaseCampLevelData.DT_BaseCampLevelData")
    if not dataTable then
        log("DataTable not found")
        return false
    end

    local validOk, valid = pcall(function() return dataTable:IsValid() end)
    if not validOk or not valid then
        log("DataTable not valid")
        return false
    end

    local modified = 0
    local ok, err = pcall(function()
        dataTable:ForEachRow(function(rowName, rowData)
            local name = getRowName(rowName)
            local level = tonumber(name)
            if not level then return end

            local newWorkers = level * WORKERS_PER_LEVEL
            rowData.WorkerMaxNum = newWorkers

            if BASE_COUNT_OVERRIDE then
                rowData.BaseCampMaxNumInGuild = BASE_COUNT_OVERRIDE
            end

            modified = modified + 1

            if level <= 3 or level % 10 == 0 then
                local baseInfo = ""
                if BASE_COUNT_OVERRIDE then
                    baseInfo = string.format(", %d bases", BASE_COUNT_OVERRIDE)
                end
                log(string.format("Level %d -> %d workers%s", level, newWorkers, baseInfo))
            end
        end)
    end)

    if not ok then
        log("ForEachRow failed: " .. tostring(err))
        return false
    end

    local summary = string.format("Done: %d levels (workers = level x %d", modified, WORKERS_PER_LEVEL)
    if BASE_COUNT_OVERRIDE then
        summary = summary .. string.format(", bases = %d", BASE_COUNT_OVERRIDE)
    end
    summary = summary .. ")"
    log(summary)
    applied = true
    return modified > 0
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    if not applied then
        modifyBaseCampLevels()
    end
end)

RegisterHook("/Script/Engine.PlayerController:ServerAcknowledgePossession", function()
    if not applied then
        modifyBaseCampLevels()
    end
end)

local loadMsg = string.format("Loaded (workers = level x %d", WORKERS_PER_LEVEL)
if BASE_COUNT_OVERRIDE then
    loadMsg = loadMsg .. string.format(", bases = %d", BASE_COUNT_OVERRIDE)
end
loadMsg = loadMsg .. ")"
log(loadMsg)
