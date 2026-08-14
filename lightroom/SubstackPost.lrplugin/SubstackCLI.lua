--[[
    Calls the substack-post command line tool.

    LrTasks.execute only returns an exit status, so output is redirected to a
    temporary file and read back. The tool is asked for key=value output, which
    avoids bundling a JSON parser into this plugin.

    Everything here must run inside a task — LrTasks.execute yields, and calling
    it straight from a UI callback throws. Callers from button actions have to
    wrap the call in LrTasks.startAsyncTask.
]]

local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrTasks = import 'LrTasks'

local SubstackCLI = {}

local function quote(value)
    return "'" .. string.gsub(tostring(value), "'", "'\\''") .. "'"
end

local function tempFile()
    local name = 'substack-post-' .. tostring(math.random(100000, 999999)) .. '.txt'
    return LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), name)
end

local function run(command)
    local outPath = tempFile()
    local status = LrTasks.execute(command .. ' > ' .. quote(outPath) .. ' 2>&1')

    local output = ''
    if LrFileUtils.exists(outPath) then
        output = LrFileUtils.readFile(outPath) or ''
        LrFileUtils.delete(outPath)
    end
    return status, output
end

local function parseKeyValues(text)
    local result = {}
    for line in string.gmatch(text, '[^\r\n]+') do
        local key, value = string.match(line, '^([%w_]+)=(.*)$')
        if key then result[key] = value end
    end
    return result
end

-- The tool prints 'error: <message>' for anything it can explain. Anything
-- else means it fell over in a way it did not anticipate, and the raw output
-- is more use to the reader than a summary of it would be.
local function failureMessage(status, output)
    local message = string.match(output, 'error:%s*(.-)\r?\n')
        or string.match(output, 'error:%s*(.*)$')
    if message == nil or message == '' then
        message = output ~= '' and output
            or ('substack-post exited with status ' .. tostring(status))
    end
    return message
end

local function baseArguments(settings)
    local parts = { quote(settings.command), }
    if settings.envFile and settings.envFile ~= '' then
        table.insert(parts, '--env-file')
        table.insert(parts, quote(settings.envFile))
    end
    return parts
end

--- Publish one folder of photos as a post.
-- @param settings the export settings, plus command/envFile from preferences
-- @param folder a directory holding only this post's photos
-- @return table with ok, status, url, photos, message
function SubstackCLI.post(settings, folder)
    if not settings.command or settings.command == '' then
        return { ok = false,
                 message = 'No substack-post path set in the plug-in settings.' }
    end

    local parts = baseArguments(settings)
    table.insert(parts, quote(folder))
    table.insert(parts, '--title')
    table.insert(parts, quote(settings.title or ''))
    if settings.subtitle and settings.subtitle ~= '' then
        table.insert(parts, '--subtitle')
        table.insert(parts, quote(settings.subtitle))
    end

    if settings.publishMode == 'publish' then
        table.insert(parts, '--publish')
        if not settings.sendEmail then
            table.insert(parts, '--no-email')
        end
        if settings.notify then
            -- No --notify-list: substack-post looks beside the env file we
            -- always name, which is where the contacts file belongs.
            table.insert(parts, '--notify')
        end
    end

    if settings.signoff and settings.signoff ~= '' then
        table.insert(parts, '--signoff')
        table.insert(parts, quote(settings.signoff))
    end
    if settings.captionFormat and settings.captionFormat ~= '' then
        table.insert(parts, '--caption-format')
        table.insert(parts, quote(settings.captionFormat))
    end

    -- Lightroom gives the subprocess no terminal, so the tool must not prompt.
    -- The confirmation the user saw before this call is the plug-in's own.
    table.insert(parts, '--yes')
    table.insert(parts, '--format')
    table.insert(parts, 'kv')

    local status, output = run(table.concat(parts, ' '))
    if status ~= 0 then
        return { ok = false, message = failureMessage(status, output) }
    end

    local values = parseKeyValues(output)
    if not values.url or values.url == '' then
        return { ok = false,
                 message = 'substack-post reported no post URL:\n\n' .. output }
    end

    return {
        ok = true,
        status = values.status,
        url = values.url,
        photos = tonumber(values.photos),
        notifiedOk = tonumber(values.notified_ok) or 0,
        notifiedFailed = tonumber(values.notified_failed) or 0,
    }
end

--- Verify the configuration without posting anything.
-- @return table with ok, publication, user, message
function SubstackCLI.check(command, envFile)
    if not command or command == '' then
        return { ok = false, message = 'No path to substack-post was entered.' }
    end

    local parts = baseArguments({ command = command, envFile = envFile })
    table.insert(parts, '--check')
    table.insert(parts, '--format')
    table.insert(parts, 'kv')

    local status, output = run(table.concat(parts, ' '))
    if status ~= 0 then
        return { ok = false, message = failureMessage(status, output) }
    end

    local values = parseKeyValues(output)
    if values.ok ~= '1' then
        return { ok = false,
                 message = 'substack-post ran but did not confirm the sign-in:\n\n'
                     .. output }
    end
    return { ok = true, publication = values.publication, user = values.user }
end

return SubstackCLI
