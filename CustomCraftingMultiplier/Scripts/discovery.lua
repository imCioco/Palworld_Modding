-- Read live recipes, item classifications and names. No numeric enum ordinals.
local U = require 'util'
local M = {}
local recipePaths = {
    '/Game/Pal/DataTable/Item/DT_ItemRecipeDataTable_Common.DT_ItemRecipeDataTable_Common',
    '/Game/Pal/DataTable/Item/DT_ItemRecipeDataTable.DT_ItemRecipeDataTable',
}
local itemPaths = {
    '/Game/Pal/DataTable/Item/DT_ItemDataTable_Common.DT_ItemDataTable_Common',
    '/Game/Pal/DataTable/Item/DT_ItemDataTable.DT_ItemDataTable',
}
local namePaths = {
    '/Game/L10N/en/Pal/DataTable/Text/DT_ItemNameText_Common.DT_ItemNameText_Common',
    '/Game/Pal/DataTable/Text/DT_ItemNameText_Common.DT_ItemNameText_Common',
}
local extraRecipes, extraItems, extraNames, staticObjects = {}, {}, {}, {}
local lastEnumeration = -1000
local lastAssetRequest = -1000
local enumCache, enumObjects = {A={},B={}}, {}
local excludedA = {Weapon=true, Armor=true, Accessory=true, Glider=true, Essential=true,
    Blueprint=true, CaptureItemModifier=true}
local allowedCategories = {Medical=true, Recovery=true, Remedies=true, Elixirs=true,
    PalEnhancements=true, Spheres=true, Ammunition=true, Grenades=true, Materials=true,
    Ingots=true, FishingBait=true, Food=true, Summoning=true, Utilities=true, Currency=true}
M.categories = allowedCategories
local function each(collection, fn)
    if collection ~= nil and U.get(collection,'ForEach') ~= nil then
        U.call(collection,'ForEach',function(key,value) fn(U.unwrap(key),U.unwrap(value)) end)
    elseif type(collection) == 'table' then
        for key,value in pairs(collection) do fn(key,U.unwrap(value)) end
    end
end
local function text(value)
    local result
    if type(value) == 'string' then result = value
    else result = U.callv(U.unwrap(value), 'ToString') end
    if type(result) ~= 'string' or result == '' or result == 'None' then return nil end
    return result
end
local function enum(value, kind)
    local stringValue = text(value)
    if stringValue and not tonumber(stringValue) then
        return stringValue:match('::([^:]+)$') or stringValue
    end
    local n = U.num(value,nil)
    if n then
        if enumCache[kind][n] then return enumCache[kind][n] end
        local object = enumObjects[kind] or U.global('StaticFindObject', '/Script/Pal.EPalItemType' .. kind)
        if object then enumObjects[kind]=object end
        local name = text(U.callv(object, 'GetNameByValue', n))
        if name then
            name=name:match('::([^:]+)$') or name
            enumCache[kind][n]=name
            return name
        end
    end
    return nil
end
local function objectPath(dt)
    local full = text(U.callv(dt,'GetFullName'))
    return full and (full:match('(/[^ ]+)$') or full) or tostring(U.callv(dt,'GetAddress') or dt)
end
local function tables(paths, extras)
    local result, seen = {}, {}
    local function add(dt, path)
        if not U.valid(dt) then return end
        local address = U.callv(dt,'GetAddress')
        local key = address and tostring(address) or path
        if seen[key] then return end
        local names = U.callv(dt,'GetRowNames')
        if type(names) ~= 'table' then return end
        seen[key] = true
        result[#result+1] = {object=dt, path=path, names=names}
    end
    for _, path in ipairs(paths) do add(U.global('StaticFindObject',path),path) end
    for _, dt in ipairs(extras) do add(dt,objectPath(dt)) end
    return result
end
local function enumerate(tick)
    if tick-lastEnumeration < 60 then return end
    lastEnumeration = tick
    extraRecipes, extraItems, extraNames, staticObjects = {}, {}, {}, {}
    each(U.global('FindAllOf','DataTable'), function(_,dt)
        if not U.valid(dt) then return end
        local path = objectPath(dt)
        local structure = U.callv(dt,'GetRowStruct')
        local structName = text(U.callv(structure,'GetFullName')) or ''
        local rows = U.callv(dt,'GetRowNames')
        local first = type(rows)=='table' and rows[1] and U.callv(dt,'FindRow',U.str(rows[1],'')) or nil
        if structName:match('%.PalItemRecipe$') or
            (U.get(first,'Product_Id') ~= nil and U.get(first,'Product_Count') ~= nil and
             U.get(first,'WorkAmount') ~= nil and U.get(first,'Material1_Id') ~= nil) then
            extraRecipes[#extraRecipes+1] = dt
        elseif structName:match('%.PalStaticItemDataStruct$') or
            (U.get(first,'TypeA') ~= nil and U.get(first,'TypeB') ~= nil and U.get(first,'MaxStackCount') ~= nil) then
            extraItems[#extraItems+1] = dt
        elseif (path:find('ItemNameText',1,true) or
            (type(rows)=='table' and text(rows[1]) and text(rows[1]):match('^ITEM_NAME_') and U.get(first,'TextData')~=nil)) and
            (not path:find('/L10N/',1,true) or path:find('/L10N/en/',1,true)) then
            extraNames[#extraNames+1] = dt
        end
    end)
    -- The live data asset is preferred; this also covers games/mods that expose
    -- the static objects but no longer keep the source item DataTable loaded.
    each(U.global('FindAllOf','PalStaticItemDataBase'), function(_,obj)
        if U.valid(obj) then
            local id = text(U.get(obj,'ID'))
            if id then staticObjects[id] = obj end
        end
    end)
end

function M.classify(id, meta, name)
    local a,b = enum(U.get(meta,'TypeA'),'A'), enum(U.get(meta,'TypeB'),'B')
    if not a or not b then return nil end -- unavailable; retry after loading
    if id:match('^QuestItem_') then return false end
    if b == 'WeaponThrowObject' and a == 'Weapon' then
        return id=='PalHealingGrenade' and 'Recovery' or 'Grenades'
    end
    if excludedA[a] then return false end
    if a == 'SpecialWeapon' then return b=='SPWeaponCaptureBall' and 'Spheres' or false end
    if a == 'Ammo' then return 'Ammunition' end
    if a == 'Food' then return 'Food' end
    if a == 'Material' then
        if id:match('^PalUpgradeStone') then return 'PalEnhancements' end
        if b=='Money' then return 'Currency' end
        if b=='MaterialIngot' then return 'Ingots' end
        return 'Materials'
    end
    if a ~= 'Consume' then return false end
    if b=='ConsumeFishingBait' then return 'FishingBait' end
    if b=='ConsumePalAwakening' or b=='ConsumePalTalentUp' or b=='ConsumePalGainExp' then return 'PalEnhancements' end
    if b=='ConsumeGainStatusPoints' then
        return (id:match('_01$') or (name or ''):lower():find('remedy',1,true)) and 'Remedies' or 'Elixirs'
    end
    if b=='ConsumePalRevive' or id:match('^Potion') then return 'Recovery' end
    if b=='Medicine' or b=='Drug' then return 'Medical' end
    if id:match('^PalSummon_') then return 'Summoning' end
    return 'Utilities'
end

function M.scan(tick)
    enumCache, enumObjects = {A={},B={}}, {}
    enumerate(tick)
    local recipes, itemTables, nameTables = tables(recipePaths,extraRecipes), tables(itemPaths,extraItems), tables(namePaths,extraNames)
    -- Some hosts do not load UI name/source tables until requested. Called
    -- only by main's game-thread refresh, and at most once per minute.
    if #recipes>0 and tick-lastAssetRequest>=60 and (#itemTables==0 or #nameTables==0) then
        lastAssetRequest=tick
        if #itemTables==0 then
            U.global('LoadAsset',itemPaths[1]:match('^(.-)%.'))
            itemTables=tables(itemPaths,extraItems)
        end
        if #nameTables==0 then
            U.global('LoadAsset',namePaths[1]:match('^(.-)%.'))
            nameTables=tables(namePaths,extraNames)
            if #nameTables==0 then
                U.global('LoadAsset',namePaths[2]:match('^(.-)%.'))
                nameTables=tables(namePaths,extraNames)
            end
        end
    end
    local products, metadata, candidates = {}, {}, {}
    for _, provider in ipairs(recipes) do
        for _, rowName in ipairs(provider.names) do
            local row = U.callv(provider.object,'FindRow',U.str(rowName,''))
            local id = text(U.get(row,'Product_Id'))
            local count = U.num(U.get(row,'Product_Count'),nil)
            if id and count and count >= 1 and count < math.huge then products[id] = true end
        end
    end
    -- Source tables: match row IDs. Static data asset below overrides them.
    for id in pairs(products) do
        for _, provider in ipairs(itemTables) do
            local row = U.callv(provider.object,'FindRow',id)
            if row ~= nil then metadata[id]=row; break end
        end
        if U.valid(staticObjects[id]) then metadata[id] = staticObjects[id] end
    end
    local assets = {}
    local known = U.global('StaticFindObject','/Game/Pal/DataAsset/Item/DA_StaticItemDataAsset.DA_StaticItemDataAsset')
    if U.valid(known) then assets[#assets+1] = known end
    -- FindAllOf on this small asset class allows a moved/renamed asset as well.
    each(U.global('FindAllOf','PalStaticItemDataAsset'),function(_,obj) if U.valid(obj) then assets[#assets+1]=obj end end)
    for _, asset in ipairs(assets) do
        each(U.get(asset,'StaticItemDataMap'),function(key,obj)
            local id = text(key) or text(U.get(obj,'ID'))
            if products[id] and U.valid(obj) then metadata[id] = obj end
        end)
    end
    local function displayName(id, meta)
        local override = text(U.get(meta,'OverrideNameMsgID')) or text(U.get(meta,'OverrideName'))
        local base = text(U.get(meta,'ItemBaseName')) or id
        local keys = {override or ('ITEM_NAME_' .. base), 'ITEM_NAME_' .. id}
        for _, provider in ipairs(nameTables) do
            for _, key in ipairs(keys) do
                local row = U.callv(provider.object,'FindRow',key)
                local name = text(U.get(row,'TextData'))
                if name then return name end
            end
        end
        return nil
    end
    local unresolved = 0
    for id in pairs(products) do
        local meta = metadata[id]
        if meta then
            local category = M.classify(id,meta,nil)
            local name
            if category then
                name=displayName(id,meta)
                category=M.classify(id,meta,name)
            end
            candidates[id] = {id=id, name=name, category=category}
            if category == nil or (category and not name) then unresolved=unresolved+1 end
        else unresolved=unresolved+1 end
    end
    return recipes, candidates, unresolved
end
return M
