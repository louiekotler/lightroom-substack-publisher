--[[
    The smallest thing that counts passes and failures, shared by the test
    files so each one is only the tests themselves.
]]

local harness = { failures = 0 }

function harness.check(name, condition, detail)
    if condition then
        print('  ok   ' .. name)
    else
        harness.failures = harness.failures + 1
        print('  FAIL ' .. name .. (detail and ('  — ' .. detail) or ''))
    end
end

--- Print the tally and exit with a status a shell can act on.
function harness.finish()
    print(harness.failures == 0 and '\nall tests passed'
        or ('\n' .. harness.failures .. ' test(s) failed'))
    os.exit(harness.failures == 0 and 0 or 1)
end

return harness
