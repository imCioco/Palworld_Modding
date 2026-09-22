-- Recoverable writes for generated catalog data and additive config repairs.
local S = {}
local locations = {}
local function backup(path) return locations[path] and locations[path].backup or path .. '.bak' end
local function temporary(path) return locations[path] and locations[path].temp or path .. '.tmp' end
function S.configure(root)
    local data = root .. '/Scripts/Data'
    locations[root .. '/config.ini'] = {backup=data .. '/config.ini.bak',temp=data .. '/config.ini.tmp'}
    -- The Data directory ships with the mod. Migrate older installations once;
    -- never replace a newer cache/backup already present in the new location.
    for _, name in ipairs({'catalog-cache.tsv','catalog-cache.tsv.bak','config.ini.bak'}) do
        local source, destination = root .. '/' .. name, data .. '/' .. name
        if S.read(source) ~= nil then
            local current, _, code = S.read(destination)
            if current == nil and code == 2 then
                local ok, err = os.rename(source,destination)
                if not ok then require('util').warn('could not move %s into Scripts/Data: %s',name,tostring(err)) end
            end
        end
    end
    return data
end
function S.read(path)
    local file, err, code = io.open(path, 'rb')
    if not file then return nil, err, code end
    local text, failure = file:read('*a')
    file:close()
    return text, failure
end
function S.recover(path)
    local current, err, code = S.read(path)
    if current ~= nil or code ~= 2 then return current, err, code end
    local previous = S.read(backup(path))
    if previous then
        local ok, failure = os.rename(backup(path), path)
        if not ok then return nil, failure end
        return previous
    end
    return nil, err, code
end
function S.replace(path, expected, content)
    local now, err, code = S.read(path)
    if now ~= expected or (now == nil and code ~= 2) then return false, err or 'file changed during repair; retrying' end
    if content == now then return true end
    local temp = temporary(path)
    local file, failure = io.open(temp, 'wb')
    if not file then return false, failure end
    local ok, writeError = file:write(content)
    local closed, closeError = file:close()
    if not ok or not closed then os.remove(temp); return false, writeError or closeError end
    local verified = S.read(temp)
    if verified ~= content then os.remove(temp); return false, 'temporary file verification failed' end
    now, err, code = S.read(path)
    if now ~= expected or (now == nil and code ~= 2) then os.remove(temp); return false, err or 'file changed during repair; retrying' end
    if expected ~= nil then
        -- Windows rename does not replace existing files. Keep a rollback copy.
        if S.read(backup(path)) ~= nil then
            local removed, removeError = os.remove(backup(path))
            if not removed then os.remove(temp); return false, removeError end
        end
        local moved, moveError = os.rename(path, backup(path))
        if not moved then os.remove(temp); return false, moveError end
    end
    local moved, moveError = os.rename(temp, path)
    if not moved then
        if expected ~= nil then os.rename(backup(path), path) end
        os.remove(temp)
        return false, moveError
    end
    return true
end
return S
