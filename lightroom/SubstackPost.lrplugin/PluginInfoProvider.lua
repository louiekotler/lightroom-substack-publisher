local LrView = import 'LrView'
local LrPrefs = import 'LrPrefs'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'

local SubstackCLI = require 'SubstackCLI'

local provider = {}

function provider.sectionsForTopOfDialog(f, propertyTable)
    local prefs = LrPrefs.prefsForPlugin()
    local bind = LrView.bind

    return {
        {
            title = 'Substack Post Publisher',
            -- An unconstrained static_text reports its whole unwrapped width as
            -- its minimum, which widens the section past the panel and clips
            -- everything to its right. width_in_chars is what makes it wrap.
            f:static_text {
                title = 'Posts the photos you export to Substack, via the '
                    .. 'substack-post command line tool. Set these paths once; '
                    .. 'everything else is per-post, in the Export dialog.',
                width_in_chars = 50,
                height_in_lines = 3,
            },
            f:row {
                spacing = f:control_spacing(),
                f:static_text {
                    title = 'substack-post path:',
                    alignment = 'right',
                    width = LrView.share 'info_label_width',
                },
                f:edit_field {
                    value = bind { key = 'command', object = prefs },
                    fill_horizontal = 1,
                    immediate = true,
                },
                f:push_button {
                    title = 'Test',
                    action = function()
                        LrTasks.startAsyncTask(function()
                            LrFunctionContext.callWithContext('testSubstackPost',
                                function(context)
                                    context:addFailureHandler(function(_, message)
                                        LrDialogs.message('Test failed',
                                            tostring(message), 'critical')
                                    end)
                                    local result = SubstackCLI.check(prefs.command,
                                        prefs.envFile)
                                    if result.ok then
                                        LrDialogs.message('substack-post is working',
                                            'Publication: '
                                                .. (result.publication or 'unknown'))
                                    else
                                        LrDialogs.message('Could not reach Substack',
                                            result.message, 'warning')
                                    end
                                end)
                        end)
                    end,
                },
            },
            f:row {
                spacing = f:control_spacing(),
                f:static_text {
                    title = '.env file:',
                    alignment = 'right',
                    width = LrView.share 'info_label_width',
                },
                f:edit_field {
                    value = bind { key = 'envFile', object = prefs },
                    fill_horizontal = 1,
                    immediate = true,
                },
            },
            f:row {
                spacing = f:control_spacing(),
                f:static_text {
                    title = 'Notify contacts:',
                    alignment = 'right',
                    width = LrView.share 'info_label_width',
                },
                f:edit_field {
                    value = bind { key = 'notifyList', object = prefs },
                    fill_horizontal = 1,
                    immediate = true,
                },
            },
            f:static_text {
                title = 'Your Substack credentials live in the .env file, never '
                    .. 'in Lightroom.',
                width_in_chars = 50,
                height_in_lines = 2,
            },
        },
    }
end

return provider
