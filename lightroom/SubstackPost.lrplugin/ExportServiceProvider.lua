--[[
    A Lightroom export destination that turns the selected photos into one
    Substack post.

    A post is a one-time push, not a synchronised collection, which is why this
    is an export service rather than a publish service: every rendition arrives
    in a single processRenderedPhotos call, and that call is the post.

    Order and captions come from each photo's EXIF capture time, read by
    substack-post from the rendered file — so an export that strips metadata
    silently loses both. See the warning in the dialog below.
]]

local LrView = import 'LrView'
local LrColor = import 'LrColor'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrHttp = import 'LrHttp'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope = import 'LrProgressScope'

local SubstackCLI = require 'SubstackCLI'
local Sources = require 'Sources'
local Schedule = require 'Schedule'

local provider = {}

provider.exportPresetFields = {
    { key = 'title', default = '' },
    { key = 'subtitle', default = '' },
    { key = 'publishMode', default = 'draft' },
    -- Seconds since 1970. Set afresh each time the dialog opens; only the
    -- time of day carries over, through preferences.
    { key = 'scheduleAt', default = 0 },
    { key = 'sendEmail', default = true },
    { key = 'notify', default = false },
    { key = 'signoff', default = '' },
    { key = 'captionFormat', default = '' },
    { key = 'rawPlusJpeg', default = 'jpeg' },
    -- Mirrored from the plug-in's preferences so processRenderedPhotos has
    -- them; see updateExportSettings.
    { key = 'command', default = '' },
    { key = 'envFile', default = '' },
}

-- Lightroom renders to a temporary folder when the destination is hidden,
-- which is what we want: the photos exist only long enough to be uploaded.
-- File names go the same way — the plug-in renames every rendition anyway.
provider.hideSections = { 'exportLocation', 'fileNaming', 'video' }
provider.allowFileFormats = { 'JPEG' }
provider.allowColorSpaces = { 'sRGB' }
provider.canExportVideo = false

local METADATA_STRIPPED =
    'Photos are ordered and captioned by the date they were taken,\n'
    .. 'which this Metadata setting removes. Choose one that keeps\n'
    .. 'EXIF, or the post comes out unordered and uncaptioned.'

local function stripsCaptureTime(propertyTable)
    return propertyTable.LR_embeddedMetadataOption == 'copyrightOnly'
        or propertyTable.LR_minimizeEmbeddedMetadata == true
end

-- Runs on every keystroke in the observed fields; re-writing an unchanged
-- value makes Lightroom redo the dialog for nothing.
local function setIfChanged(propertyTable, key, value)
    if propertyTable[key] ~= value then
        propertyTable[key] = value
    end
end

local function updateWarnings(propertyTable)
    setIfChanged(propertyTable, 'metadataWarning',
        stripsCaptureTime(propertyTable) and METADATA_STRIPPED or '')

    -- Emailing subscribers and texting contacts only mean anything when the
    -- post is actually going out, now or later.
    setIfChanged(propertyTable, 'publishing',
        propertyTable.publishMode ~= 'draft')
    local scheduling = propertyTable.publishMode == 'schedule'
    setIfChanged(propertyTable, 'scheduling', scheduling)

    setIfChanged(propertyTable, 'scheduleText',
        scheduling and Schedule.describe(propertyTable.scheduleAt) or 'Now')

    -- Refusing here greys out Lightroom's own Export button with the reason
    -- attached, which beats failing after every photo has been rendered.
    local reason = nil
    if (propertyTable.command or '') == '' then
        reason = 'Set the path to substack-post in the Substack Post settings.'
    elseif (propertyTable.title or '') == '' then
        reason = 'Enter a title for the post.'
    end
    setIfChanged(propertyTable, 'LR_cantExportBecause', reason)
end

function provider.startDialog(propertyTable)
    local prefs = LrPrefs.prefsForPlugin()
    propertyTable.command = prefs.command or ''
    propertyTable.envFile = prefs.envFile or ''

    -- Export preset fields persist between exports. A title belongs to one
    -- post, so inheriting the last one is how the wrong headline gets used.
    propertyTable.title = ''
    propertyTable.subtitle = ''

    -- A date belongs to one post too. The time of day is the usual one.
    propertyTable.scheduleAt = Schedule.default(os.time(),
        prefs.scheduleHour or 8, prefs.scheduleMinute or 0)

    for _, key in ipairs { 'title', 'command', 'publishMode',
                           'scheduleAt',
                           'LR_embeddedMetadataOption',
                           'LR_minimizeEmbeddedMetadata' } do
        propertyTable:addObserver(key, updateWarnings)
    end
    updateWarnings(propertyTable)
end

function provider.endDialog(propertyTable)
    local prefs = LrPrefs.prefsForPlugin()
    prefs.command = propertyTable.command
    prefs.envFile = propertyTable.envFile
end

-- Called before every export, including one run straight from a saved preset
-- where the dialog never opened. The paths live in preferences, so this is the
-- only place guaranteed to put current ones into the export settings.
function provider.updateExportSettings(exportSettings)
    local prefs = LrPrefs.prefsForPlugin()
    exportSettings.command = prefs.command or ''
    exportSettings.envFile = prefs.envFile or ''
end

local function testConnection(propertyTable)
    LrTasks.startAsyncTask(function()
        -- Errors are trapped with a function context, not pcall: LrTasks.execute
        -- yields, and Lua 5.1 cannot yield across a pcall boundary.
        LrFunctionContext.callWithContext('testSubstackPost', function(context)
            context:addFailureHandler(function(_, message)
                LrDialogs.message('Test failed', tostring(message), 'critical')
            end)
            local result = SubstackCLI.check(propertyTable.command,
                propertyTable.envFile)
            if result.ok then
                LrDialogs.message('substack-post is working',
                    'Signed in as ' .. (result.user ~= '' and result.user or 'your account')
                        .. '.\nPublication: ' .. (result.publication or 'unknown'))
            else
                LrDialogs.message('Could not reach Substack', result.message, 'warning')
            end
        end)
    end)
end

--- Ask for a date and time with macOS's own picker (DatePicker.js), which
-- Lightroom's SDK has no equivalent of, and remember the time of day. The
-- picker offers nothing too soon to schedule.
local function chooseTime(propertyTable)
    LrTasks.startAsyncTask(function()
        local now = os.time()
        local out = LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'),
            'substack-post-date-' .. tostring(math.random(100000, 999999)))
        LrTasks.execute(string.format(
            "osascript -l JavaScript '%s' %d %d 'Schedule' > '%s'",
            LrPathUtils.child(_PLUGIN.path, 'DatePicker.js'),
            propertyTable.scheduleAt or now, now + Schedule.LEAD, out))
        local chosen = tonumber(LrFileUtils.exists(out)
            and LrFileUtils.readFile(out) or '')
        LrFileUtils.delete(out)
        if not chosen then return end  -- cancelled

        propertyTable.scheduleAt = chosen
        local prefs = LrPrefs.prefsForPlugin()
        prefs.scheduleHour, prefs.scheduleMinute = Schedule.timeOfDay(chosen)
    end)
end

function provider.sectionsForTopOfDialog(f, propertyTable)
    local bind = LrView.bind

    return {
        {
            title = 'Substack Post',
            f:row {
                spacing = f:control_spacing(),
                f:static_text {
                    title = 'Title:',
                    alignment = 'right',
                    width = LrView.share 'label_width',
                },
                f:edit_field {
                    value = bind 'title',
                    fill_horizontal = 1,
                    immediate = true,
                },
            },
            f:row {
                spacing = f:control_spacing(),
                f:static_text {
                    title = 'Subtitle:',
                    alignment = 'right',
                    width = LrView.share 'label_width',
                },
                f:edit_field {
                    value = bind 'subtitle',
                    fill_horizontal = 1,
                    immediate = true,
                },
            },
            f:row {
                spacing = f:control_spacing(),
                f:static_text {
                    title = 'Send as:',
                    alignment = 'right',
                    width = LrView.share 'label_width',
                },
                f:radio_button {
                    title = 'Draft',
                    value = bind 'publishMode',
                    checked_value = 'draft',
                },
                f:radio_button {
                    title = 'Publish now',
                    value = bind 'publishMode',
                    checked_value = 'publish',
                },
                f:radio_button {
                    title = 'Schedule',
                    value = bind 'publishMode',
                    checked_value = 'schedule',
                },
                f:checkbox {
                    title = 'Email subscribers',
                    value = bind 'sendEmail',
                    enabled = bind 'publishing',
                },
                f:checkbox {
                    title = 'Notify contacts',
                    value = bind 'notify',
                    enabled = bind 'publishing',
                },
            },
            f:row {
                spacing = f:control_spacing(),
                f:static_text {
                    title = 'When:',
                    alignment = 'right',
                    width = LrView.share 'label_width',
                },
                f:static_text {
                    title = bind 'scheduleText',
                    -- Lightroom sizes text once, when the dialog opens, and
                    -- clips it if it grows. So this fits the widest date that
                    -- can appear, "Wed, May 30, 2026 at 10:00 PM": 168 points
                    -- in the 11-point font Lightroom's dialogs use.
                    width = 172,
                },
                f:push_button {
                    title = 'Choose…',
                    -- Hidden rather than disabled: beside "Now" it means
                    -- nothing, and would sit a whole date's width away.
                    visible = bind 'scheduling',
                    -- Runs a process, which needs a task; see testConnection.
                    action = function() chooseTime(propertyTable) end,
                },
            },
            f:static_text {
                title = 'A draft can be edited and discarded in Substack. '
                    .. 'Publishing cannot be undone.',
                width_in_chars = 60,
                height_in_lines = 2,
            },
            f:static_text {
                title = bind 'metadataWarning',
                text_color = LrColor(0.6, 0, 0),
                height_in_lines = 3,
            },
        },
        {
            title = 'Post Options',
            synopsis = 'Sign-off and caption format',
            f:row {
                spacing = f:control_spacing(),
                f:static_text {
                    title = 'Sign-off:',
                    alignment = 'right',
                    width = LrView.share 'options_label_width',
                },
                f:edit_field {
                    value = bind 'signoff',
                    fill_horizontal = 1,
                    immediate = true,
                    tooltip = 'Text at the end of the post. Leave blank for the '
                        .. 'default from substack-post.',
                },
            },
            f:row {
                spacing = f:control_spacing(),
                f:static_text {
                    title = 'Caption format:',
                    alignment = 'right',
                    width = LrView.share 'options_label_width',
                },
                f:edit_field {
                    value = bind 'captionFormat',
                    width_in_chars = 20,
                    immediate = true,
                    tooltip = 'strftime format for each photo\'s date caption, '
                        .. 'e.g. %B {day}, %Y. Leave blank for the default.',
                },
            },
            f:row {
                spacing = f:control_spacing(),
                f:static_text {
                    title = 'RAW+JPEG:',
                    alignment = 'right',
                    width = LrView.share 'options_label_width',
                },
                f:popup_menu {
                    value = bind 'rawPlusJpeg',
                    items = {
                        { title = 'Post the camera\'s JPEG', value = 'jpeg' },
                        { title = 'Post Lightroom\'s render', value = 'render' },
                    },
                },
            },
            f:static_text {
                -- Wrapped by hand: width_in_chars sets a width without making
                -- Lightroom wrap to it, so long prose is clipped instead.
                title = 'A photo shot RAW+JPEG is one photo in Lightroom, and\n'
                    .. 'this chooses which half to post. The camera\'s JPEG\n'
                    .. 'carries none of your develop edits. Virtual copies\n'
                    .. 'keep the render, as does a raw with no JPEG beside it.',
                height_in_lines = 4,
            },
        },
        {
            title = 'Setup',
            synopsis = 'Where substack-post and its .env file live',
            f:row {
                spacing = f:control_spacing(),
                f:static_text {
                    title = 'substack-post path:',
                    alignment = 'right',
                    width = LrView.share 'setup_label_width',
                },
                f:edit_field {
                    value = bind 'command',
                    fill_horizontal = 1,
                    immediate = true,
                    tooltip = 'Full path to the substack-post executable.',
                },
                f:push_button {
                    title = 'Test',
                    -- Button actions run on the UI thread, where LrTasks.execute
                    -- cannot be called; without a task the click does nothing.
                    action = function() testConnection(propertyTable) end,
                },
            },
            f:row {
                spacing = f:control_spacing(),
                f:static_text {
                    title = '.env file:',
                    alignment = 'right',
                    width = LrView.share 'setup_label_width',
                },
                f:edit_field {
                    value = bind 'envFile',
                    fill_horizontal = 1,
                    immediate = true,
                    tooltip = 'Full path to the .env holding your Substack '
                        .. 'credentials.',
                },
            },
        },
    }
end

--- A directory of our own, holding this post's photos and nothing else.
-- substack-post takes every supported image in the folder it is given, so the
-- folder can never be shared or reused.
local function makeBatchFolder()
    local name = 'substack-post-' .. tostring(os.time())
        .. '-' .. tostring(math.random(100000, 999999))
    local path = LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), name)
    LrFileUtils.createAllDirectories(path)
    return path
end

local function cleanUp(folder, files)
    for _, path in ipairs(files) do
        LrFileUtils.delete(path)
    end
    LrFileUtils.delete(folder)
end

--- "3 photos" / "1 photo". Avoids "photo(s)", which no one writes by hand.
local function photoCount(n)
    return n .. (n == 1 and ' photo' or ' photos')
end

--- Run something that takes a while, showing how far along it is.
--
-- A scope of its own rather than the export's: Lightroom's export progress
-- belongs to rendering, and rendering has finished by the time any of this
-- starts. Everything after it — uploading, drafting, publishing, texting — is
-- the longer wait of the two and the one with nothing else on screen.
--
-- The scope is tied to the export's function context, so it is taken down
-- however the export ends, including on an error.
--
-- @param work function(progressPath, onPoll) -> result
-- @return whatever `work` returned
local function withProgress(context, title, work)
    local path = LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'),
        'substack-post-progress-' .. tostring(math.random(100000, 999999)))

    local scope = LrProgressScope { title = title, functionContext = context }

    local function onPoll()
        local text = LrFileUtils.exists(path) and LrFileUtils.readFile(path) or nil
        if not text then return end
        -- substack-post overwrites this file with where it has got to, so a
        -- half-written read simply fails to match and the next poll picks it
        -- up. There is nothing here worth locking for.
        local step = tonumber(string.match(text, 'step=(%d+)'))
        local total = tonumber(string.match(text, 'total=(%d+)'))
        local label = string.match(text, 'label=([^\r\n]*)')
        if not step or not total or total == 0 then return end
        if label and label ~= '' then scope:setCaption(label) end
        -- `step` is the one being started, so it is not finished yet.
        scope:setPortionComplete(step - 1, total)
    end

    local result = work(path, onPoll)

    scope:done()
    LrFileUtils.delete(path)
    return result
end

--- Ask before doing something irreversible, naming the publication it will
-- happen to. The check also fails early, before a single photo is uploaded.
local function confirmPublish(context, settings, photos, fromCamera, moment)
    -- Signing in is a round trip to Substack, and the export's own bar is
    -- finished by now, so this would otherwise be a few seconds of nothing
    -- before the dialog appears.
    local check = withProgress(context, 'Checking your Substack account',
        function(_, onPoll)
            return SubstackCLI.check(settings.command, settings.envFile, onPoll)
        end)
    if not check.ok then
        return false, check.message
    end

    local lines = {}
    if moment then
        table.insert(lines, 'Goes live: ' .. Schedule.describe(moment))
    end
    table.insert(lines, 'Photos: ' .. photos)
    table.insert(lines, 'Publication: ' .. (check.publication or 'unknown'))
    table.insert(lines, 'Email: '
        .. (settings.sendEmail and 'yes, all subscribers' or 'no (web only)'))
    if settings.notify then
        table.insert(lines, 'Notify: yes, your contacts will be texted')
    end
    if fromCamera > 0 then
        table.insert(lines, 'From the camera\'s JPEG, unedited: ' .. fromCamera)
    end

    local body = table.concat(lines, '\n')
    if not moment then
        body = body .. '\n\nPublishing cannot be undone.'
    end

    local choice = LrDialogs.confirm(
        moment and ('Schedule "' .. settings.title .. '" on Substack?')
            or ('Publish "' .. settings.title .. '" to Substack?'),
        body,
        moment and 'Schedule' or 'Publish',
        'Cancel')
    return choice == 'ok', nil
end

--- What the result dialog says about texts for a scheduled post.
local function scheduledTextsNote(check)
    if check == 'ok' then
        return 'Contacts will be texted when it goes live.'
    elseif check == 'pending' then
        return 'Texts need Messages access. Allow Python in System Settings ▸ '
            .. 'Privacy & Security ▸ Automation.'
    end
    return 'Texts cannot be sent: ' .. string.gsub(check, '^failed:%s*', '')
end

local function showResult(result, settings, fromCamera, moment)
    local published = result.status == 'published'
    local scheduled = result.status == 'scheduled'
    local body = published and 'Your post is live.'
        or scheduled and ('Goes live ' .. Schedule.describe(moment) .. '.')
        or 'Your draft is ready to edit.'
    if fromCamera > 0 then
        body = body .. '\n\n' .. fromCamera .. ' photo(s) came from the camera\'s '
            .. 'JPEG rather than Lightroom\'s render, so your develop edits are '
            .. 'not in them.'
    end
    if published and settings.notify then
        body = body .. '\n\nContacts texted: ' .. result.notifiedOk
        if result.notifiedFailed > 0 then
            body = body .. ', failed: ' .. result.notifiedFailed
        end
    end
    if scheduled and settings.notify then
        body = body .. '\n\n' .. scheduledTextsNote(result.messagesCheck)
    end

    local choice = LrDialogs.confirm(
        published and 'Published to Substack'
            or scheduled and 'Scheduled on Substack'
            or 'Draft created on Substack',
        body .. '\n\n' .. result.url,
        'Open in browser',
        'Done')
    if choice == 'ok' then
        LrHttp.openUrlInBrowser(result.url)
    end
end

function provider.processRenderedPhotos(functionContext, exportContext)
    local settings = exportContext.propertyTable
    local total = exportContext.exportSession:countRenditions()

    -- The dialog refuses to export without these, but a saved export preset can
    -- be run without ever opening it.
    if (settings.command or '') == '' then
        LrDialogs.message('Substack Post is not set up',
            'Set the path to substack-post in the Plug-in Manager.', 'critical')
        return
    end
    if (settings.title or '') == '' then
        LrDialogs.message('This post has no title',
            'Export again and enter a title, rather than saving one into a '
                .. 'preset — a title belongs to a single post.', 'critical')
        return
    end

    -- Checked before rendering: a time that has passed since it was chosen
    -- should stop the export before any work, not after it.
    local moment = nil
    if settings.publishMode == 'schedule' then
        moment = settings.scheduleAt
        if not Schedule.usable(moment, os.time()) then
            LrDialogs.message('Cannot schedule this post',
                'The scheduled time has passed.', 'critical')
            return
        end
    end

    local progress = exportContext:configureProgress {
        title = total > 1
            and ('Preparing ' .. total .. ' photos for Substack')
            or 'Preparing one photo for Substack',
    }

    local folder = makeBatchFolder()
    local files = {}
    local failures = {}
    local fromCamera = 0

    for _, rendition in exportContext:renditions { stopIfCanceled = true } do
        local rendered, pathOrMessage = rendition:waitForRender()
        if progress:isCanceled() then break end

        if not rendered then
            table.insert(failures, pathOrMessage or 'Lightroom could not render a photo.')
            rendition:uploadFailed(pathOrMessage
                or 'Lightroom could not render this photo.')
        else
            local photo = rendition.photo
            local source, why = Sources.chooseFile(pathOrMessage,
                photo:getRawMetadata('path'), settings.rawPlusJpeg,
                photo:getRawMetadata('isVirtualCopy'))

            -- substack-post orders by capture time and breaks ties by filename,
            -- so the index keeps undated photos in the order they were selected.
            local name = string.format('%04d_%s', #files + 1,
                LrPathUtils.leafName(source))
            local destination = LrPathUtils.child(folder, name)

            if why == 'sidecar-jpeg' then
                -- Copy: this one lives in the user's library. Only the render
                -- is ours to move.
                LrFileUtils.copy(source, destination)
                LrFileUtils.delete(pathOrMessage)
                fromCamera = fromCamera + 1
            else
                LrFileUtils.move(pathOrMessage, destination)
            end

            if LrFileUtils.exists(destination) then
                table.insert(files, destination)
            else
                table.insert(failures, 'Could not stage ' .. name .. ' for upload.')
                rendition:uploadFailed('Could not stage this photo for upload.')
            end
        end
    end

    if progress:isCanceled() then
        cleanUp(folder, files)
        return
    end

    if #files == 0 then
        cleanUp(folder, files)
        LrDialogs.message('Nothing to post',
            #failures > 0 and failures[1]
                or 'None of the selected photos could be rendered.',
            'critical')
        return
    end

    if settings.publishMode ~= 'draft' then
        local confirmed, problem = confirmPublish(functionContext, settings, #files,
            fromCamera, moment)
        if problem then
            cleanUp(folder, files)
            LrDialogs.message('Could not reach Substack', problem, 'critical')
            return
        end
        if not confirmed then
            cleanUp(folder, files)
            return
        end
    end

    local result = withProgress(functionContext,
        (settings.publishMode == 'publish' and 'Publishing '
            or settings.publishMode == 'schedule' and 'Scheduling '
            or 'Drafting ')
            .. photoCount(#files) .. ' on Substack',
        function(progressPath, onPoll)
            return SubstackCLI.post(settings, folder, progressPath, onPoll,
                moment and Schedule.argument(moment))
        end)
    cleanUp(folder, files)

    if not result.ok then
        LrDialogs.message('Substack post failed', result.message, 'critical')
        return
    end

    if #failures > 0 then
        LrDialogs.message('Some photos were left out',
            #failures .. ' photo(s) could not be rendered and are not in the '
                .. 'post:\n\n' .. failures[1], 'warning')
    end

    showResult(result, settings, fromCamera, moment)
end

return provider
