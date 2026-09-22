-- Persistent identity/name bindings for supported items, never executable Lua.
local S = require 'storage'
local U = require 'util'
local Categories = require('discovery').categories
local Ini = require 'ini'
local M = {}
local function safeKey(name)
    if type(name) ~= 'string' then return nil end
    name = name:gsub('[%z\1-\31\127]', ' '):gsub('=', '＝'):gsub('^[ \t\r\n]+', ''):gsub('[ \t\r\n]+$', '')
    if name == '' or name == 'None' then return nil end
    if name:match('^[;#%[]') then name = 'Item ' .. name end
    return name
end
local function encode(s)
    return (s:gsub('%%','%%25'):gsub('\t','%%09'):gsub('\r','%%0D'):gsub('\n','%%0A'))
end
local function decode(s)
    return (s:gsub('%%(%x%x)',function(h) return string.char(tonumber(h,16)) end))
end
function M.new(root, seeds)
    local self = {items={}, records={}, byId={}, path=root .. '/Scripts/Data/catalog-cache.tsv', errors={}}
    local occupied = {}
    local function add(id, category, name, display, seed)
        if not Categories[category] or not id or id=='' or id:find('[%z\1-\31\127]') then return nil end
        name = safeKey(name)
        if not name then return nil end
        local original, suffix = name, 2
        local function key(n) return category:lower() .. '|' .. Ini.key(n) end
        while occupied[key(name)] or Ini.key(name)=='categorymultiplier' do
            name = original .. ' (' .. suffix .. ')'; suffix = suffix+1
        end
        occupied[key(name)] = id
        local item = {id=id, category=category, name=name, display=display or name, seed=seed}
        self.records[id]=item; self.items[#self.items+1]=item
        if seed then self.byId[id]=item end
        return item
    end
    -- Seed keys remain stable for existing users. Cached discoveries get the
    -- same key after restarting, even if the game's display language changes.
    for _, item in ipairs(seeds) do add(item.id,item.category,item.name,item.name,true) end
    local cached = S.recover(self.path)
    if cached then
        for line in cached:gmatch('[^\r\n]+') do
            if line:sub(1,1)~='#' then
                local id,category,name,display = line:match('^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$')
                if id then
                    id,category,name,display=decode(id),decode(category),decode(name),decode(display)
                    if not self.records[id] then add(id,category,name,display,false) end
                end
            end
        end
    end
    function self:reconcile(candidates)
        local ids = {}
        for id in pairs(candidates) do ids[#ids+1]=id end
        table.sort(ids)
        local added = 0
        for _, id in ipairs(ids) do
            local candidate, item = candidates[id], self.records[id]
            if candidate.category == false then self.byId[id] = nil
            elseif candidate.category then
                if not item and candidate.name then
                    item=add(id,candidate.category,candidate.name,candidate.name,false)
                    if item then added=added+1 end
                end
                if item then
                    if candidate.name then item.display=candidate.name end
                    self.byId[id]=item
                end
            end
        end
        table.sort(self.items,function(a,b)
            if a.category~=b.category then return a.category<b.category end
            return a.name:lower()<b.name:lower()
        end)
        if added>0 then U.info('discovered %d new craftable materials/consumables',added) end
        return added
    end
    function self:save()
        local lines={'# CustomCraftingMultiplier catalog v1: item ID, category, setting name, latest display name'}
        local sorted={}
        for _,item in ipairs(self.items) do sorted[#sorted+1]=item end
        table.sort(sorted,function(a,b) return a.id<b.id end)
        for _,item in ipairs(sorted) do
            lines[#lines+1]=table.concat({encode(item.id),encode(item.category),encode(item.name),encode(item.display)},'\t')
        end
        local wanted=table.concat(lines,'\n') .. '\n'
        local old,err,code=S.recover(self.path)
        if old==nil and code~=2 then
            if self.errors.save~=err then U.warn('catalog save deferred: %s',tostring(err)); self.errors.save=err end
            return false
        end
        if old==wanted then return true end
        local ok,failure=S.replace(self.path,old,wanted)
        if not ok then
            if self.errors.save~=failure then U.warn('catalog save deferred: %s',tostring(failure)); self.errors.save=failure end
        else self.errors.save=nil end
        return ok
    end
    return self
end
return M
