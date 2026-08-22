--[[
    Just enough of the Lightroom SDK to run SubstackCLI.lua outside Lightroom.

    LrTasks.execute really does run the command, so argument quoting is tested
    for real rather than approximated — which is the whole point, since quoting
    is where a plug-in that shells out usually breaks.
]]

local stub = {}

local modules = {}

modules.LrPathUtils = {
    child = function(dir, name)
        return dir .. '/' .. name
    end,
    getStandardFilePath = function(_)
        return os.getenv('TMPDIR') or '/tmp'
    end,
    leafName = function(path)
        return string.match(path, '[^/]+$') or path
    end,
    extension = function(path)
        return string.match(path, '%.([^./]+)$') or ''
    end,
    removeExtension = function(path)
        return (string.gsub(path, '%.[^./]+$', ''))
    end,
    addExtension = function(path, extension)
        return path .. '.' .. extension
    end,
}

modules.LrFileUtils = {
    exists = function(path)
        local handle = io.open(path, 'r')
        if handle then handle:close() return 'file' end
        return false
    end,
    readFile = function(path)
        local handle = io.open(path, 'r')
        if not handle then return nil end
        local contents = handle:read('*a')
        handle:close()
        return contents
    end,
    delete = function(path)
        os.remove(path)
    end,
    copy = function(from, to)
        local source = io.open(from, 'rb')
        if not source then return false end
        local destination = io.open(to, 'wb')
        destination:write(source:read('*a'))
        source:close()
        destination:close()
        return true
    end,
}

modules.LrTasks = {
    execute = function(command)
        -- Lightroom hands back a plain exit status; Lua 5.2+ returns a triple.
        local ok, _, code = os.execute(command)
        if type(ok) == 'number' then return ok end
        return ok and 0 or (code or 1)
    end,
    -- Lightroom yields here, which is what lets the UI redraw while a command
    -- runs. Outside it, actually waiting is what makes the polling loop poll.
    sleep = function(seconds)
        os.execute('sleep ' .. tostring(seconds))
    end,
}

function stub.install()
    _G.import = function(name)
        local module = modules[name]
        if not module then
            error('lrstub has no module named ' .. tostring(name))
        end
        return module
    end
end

return stub
