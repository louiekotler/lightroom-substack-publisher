--[[
    Calls the substack-post command line tool.

    LrTasks.execute only returns an exit status, so output is redirected to a
    temporary file and read back. The tool is asked for key=value output, which
    avoids bundling a JSON parser into this plugin.

    Commands are started in the background and waited on in a loop, rather than
    run to completion in one call: execute does not return until the process
    exits, so a caller has nothing to report — and Lightroom nothing to
    redraw — for as long as a post takes.

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

--- Run a command in the background, calling `onPoll` every so often until it
-- finishes.
--
-- Waiting in a loop of our own, rather than letting execute block, is what
-- makes progress possible at all: the sleep yields, so Lightroom gets to redraw
-- and the caller gets to look at how far along the tool says it is. It also
-- costs no second task, and assumes nothing about what Lightroom schedules
-- while execute is blocked.
--
-- The exit status is written to a file rather than read from the shell, since
-- the shell being waited on is the one that launched the job, not the job.
local function run(command, onPoll)
    local outPath = tempFile()
    local donePath = tempFile()

    LrTasks.execute('{ ' .. command .. ' ; printf %s "$?" > ' .. quote(donePath)
        .. ' ; } > ' .. quote(outPath) .. ' 2>&1 &')

    local status = nil
    while true do
        if LrFileUtils.exists(donePath) then
            -- The file appears before it is written, so an empty read means
            -- "a moment more", not "finished with no status".
            status = tonumber(LrFileUtils.readFile(donePath) or '')
            if status then break end
        end
        if onPoll then onPoll() end
        LrTasks.sleep(0.2)
    end

    local output = ''
    if LrFileUtils.exists(outPath) then
        output = LrFileUtils.readFile(outPath) or ''
    end
    LrFileUtils.delete(outPath)
    LrFileUtils.delete(donePath)
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
-- @param progressPath optional file for the tool to keep its position in, so a
--   caller can watch it while the post is being made
-- @param onPoll optional function called every so often while the tool runs
-- @param scheduleAt when publishMode is 'schedule', the local time to go live
--   as "YYYY-MM-DDTHH:MM"
-- @return table with ok, status, url, photos, messagesCheck, message
function SubstackCLI.post(settings, folder, progressPath, onPoll, scheduleAt)
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

    if settings.publishMode == 'publish' or settings.publishMode == 'schedule' then
        if settings.publishMode == 'publish' then
            table.insert(parts, '--publish')
        else
            table.insert(parts, '--schedule')
            table.insert(parts, quote(scheduleAt or ''))
        end
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
    if progressPath then
        table.insert(parts, '--progress-file')
        table.insert(parts, quote(progressPath))
    end

    local status, output = run(table.concat(parts, ' '), onPoll)
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
        -- For a scheduled post: whether the job that will text contacts can
        -- reach Messages — 'ok', 'failed: <why>', 'pending', or '' if none.
        messagesCheck = values.messages_check or '',
    }
end

--- Verify the configuration without posting anything.
-- @param onPoll optional function called every so often while the tool runs
-- @return table with ok, publication, user, message
function SubstackCLI.check(command, envFile, onPoll)
    if not command or command == '' then
        return { ok = false, message = 'No path to substack-post was entered.' }
    end

    local parts = baseArguments({ command = command, envFile = envFile })
    table.insert(parts, '--check')
    table.insert(parts, '--format')
    table.insert(parts, 'kv')

    local status, output = run(table.concat(parts, ' '), onPoll)
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
