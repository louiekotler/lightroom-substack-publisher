--[[
    Tests for SubstackCLI: the arguments it builds, and what it makes of the
    replies. Run from the repository root:

        lua tests/test_substack_cli.lua

    Nothing here contacts Substack. tests/fake-substack-post stands in for the
    real tool and records the arguments it was given; tests/broken-substack-post
    fails the way the real one does.
]]

package.path = 'tests/?.lua;lightroom/SubstackPost.lrplugin/?.lua;' .. package.path
require('lrstub').install()

local SubstackCLI = require 'SubstackCLI'
local check = require('harness').check
local finish = require('harness').finish

local FAKE = 'tests/fake-substack-post'
local BROKEN = 'tests/broken-substack-post'
local SILENT = '/usr/bin/true'  -- exits 0, says nothing
local ARGV_RECORD = 'tests/.last-argv.json'

--- The arguments the fake tool received last, space-joined and padded, so a
-- plain substring search can match whole arguments.
local function receivedArguments()
    local handle = assert(io.open(ARGV_RECORD, 'r'))
    local raw = handle:read('*a')
    handle:close()
    local args = {}
    for value in string.gmatch(raw, '"(.-)"') do
        table.insert(args, value)
    end
    return ' ' .. table.concat(args, ' ') .. ' '
end

local function contains(haystack, needle)
    return string.find(haystack, needle, 1, true) ~= nil
end

local function settings(overrides)
    local base = {
        command = FAKE,
        envFile = '/tmp/somewhere/.env',
        title = 'Olympic Peninsula',
        subtitle = 'August 2026',
        publishMode = 'draft',
        sendEmail = true,
        notify = false,
    }
    for key, value in pairs(overrides or {}) do base[key] = value end
    return base
end

print('SubstackCLI.post')

local result = SubstackCLI.post(settings(), '/tmp/batch folder')
check('reports the URL', result.ok and
    result.url == 'https://example.substack.com/p/example', result.message)
check('reports the status', result.status == 'draft')
check('reports the photo count', result.photos == 3)

local args = receivedArguments()
check('passes the folder, spaces and all', contains(args, ' /tmp/batch folder '))
check('passes the title', contains(args, ' Olympic Peninsula '))
check('passes the subtitle', contains(args, ' August 2026 '))
check('passes the env file', contains(args, ' --env-file /tmp/somewhere/.env '))
check('never lets the tool prompt', contains(args, ' --yes '))
check('asks for kv output', contains(args, ' --format kv '))
check('does not publish a draft', not contains(args, ' --publish '))
check('omits email and notify flags for a draft',
    not contains(args, ' --no-email ') and not contains(args, ' --notify '))

SubstackCLI.post(settings { publishMode = 'publish', sendEmail = false }, '/tmp/b')
args = receivedArguments()
check('publishes when asked', contains(args, ' --publish '))
check('suppresses the subscriber email when asked', contains(args, ' --no-email '))

SubstackCLI.post(settings { publishMode = 'publish', notify = true }, '/tmp/b')
args = receivedArguments()
check('passes notify', contains(args, ' --notify '))
-- The contacts file is found beside the env file, so naming it would only be
-- a second place for the path to be wrong.
check('never names a contacts file', not contains(args, ' --notify-list '))

SubstackCLI.post(settings { notify = true }, '/tmp/b')
check('never notifies for a draft', not contains(receivedArguments(), ' --notify '))

result = SubstackCLI.post(settings { publishMode = 'schedule', notify = true,
    sendEmail = false }, '/tmp/b', nil, nil, '2026-10-28T08:00')
args = receivedArguments()
check('schedules at the time given', contains(args, ' --schedule 2026-10-28T08:00 '))
check('a scheduled post is not published now', not contains(args, ' --publish '))
check('passes email and notify for a scheduled post',
    contains(args, ' --no-email ') and contains(args, ' --notify '))
check('reports a scheduled status', result.ok and result.status == 'scheduled',
    tostring(result.message))
check('reports whether the texts can reach Messages', result.messagesCheck == 'ok')

result = SubstackCLI.post(settings(), '/tmp/b')
check('no Messages check without a schedule', result.messagesCheck == '')

SubstackCLI.post(settings { title = "Anna's birthday" }, '/tmp/b')
check('survives an apostrophe in the title',
    contains(receivedArguments(), " Anna's birthday "))

SubstackCLI.post(settings { signoff = 'See you next time', captionFormat = '%B %Y' },
    '/tmp/b')
args = receivedArguments()
check('passes the optional post settings',
    contains(args, ' --signoff See you next time ') and
    contains(args, ' --caption-format %B %Y '))

print('SubstackCLI.post: watching it run')

-- The point of the whole arrangement: the caller has to hear about the post
-- *while* it is being made. Before this the command blocked until it was
-- finished, so the plug-in had nothing to show for its entire duration —
-- which is most of the wait.
local WATCHED = '/tmp/substack-watched-position'
local seen = {}
local watched = SubstackCLI.post(settings(), '/tmp/b', WATCHED, function()
    local LrFileUtils = import 'LrFileUtils'
    if LrFileUtils.exists(WATCHED) then
        local text = LrFileUtils.readFile(WATCHED) or ''
        local step = string.match(text, 'step=(%d+)')
        if step then seen[step] = true end
    end
end)
os.remove(WATCHED)

local distinct = 0
for _ in pairs(seen) do distinct = distinct + 1 end

check('the post still succeeds while being watched', watched.ok == true,
    tostring(watched.message))
check('the position is seen moving, not just its final value', distinct > 1,
    distinct .. ' distinct position(s) seen')
check('the position file is passed to the tool',
    contains(receivedArguments(), ' --progress-file ' .. WATCHED .. ' '))

SubstackCLI.post(settings(), '/tmp/b')
check('and is absent when none is wanted',
    not contains(receivedArguments(), ' --progress-file '))

print('SubstackCLI.post, continued')

result = SubstackCLI.post(settings { command = '' }, '/tmp/b')
check('refuses without a command path', not result.ok and
    contains(result.message, 'No substack-post path'))

result = SubstackCLI.post(settings { command = BROKEN }, '/tmp/b')
check('shows the tool\'s own explanation of a failure', not result.ok and
    contains(result.message, 'incorrect password'), result.message)

result = SubstackCLI.post(settings { command = SILENT }, '/tmp/b')
check('treats a silent success as a failure', not result.ok)

print('SubstackCLI.check')

result = SubstackCLI.check(FAKE, '/tmp/somewhere/.env')
check('reports the publication', result.ok and
    result.publication == 'https://example.substack.com', result.message)
check('reports the user', result.user == 'Example Person')
check('passes --check and the env file',
    contains(receivedArguments(), ' --check ') and
    contains(receivedArguments(), ' --env-file /tmp/somewhere/.env '))
check('refuses without a command path', not SubstackCLI.check('').ok)
check('surfaces a failure', not SubstackCLI.check(BROKEN).ok)
check('treats an unconfirmed sign-in as a failure', not SubstackCLI.check(SILENT).ok)

os.remove(ARGV_RECORD)
finish()
