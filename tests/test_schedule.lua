--[[
    Tests for Schedule: the default time, whether a time can still be used,
    and how it is written. Run from the repository root:

        lua tests/test_schedule.lua

    Times are built with os.time in local time, as Lightroom's are, so these
    hold in any time zone. Choosing a time is DatePicker.js, which needs a
    screen and is not tested here.
]]

package.path = 'tests/?.lua;lightroom/SubstackPost.lrplugin/?.lua;' .. package.path

local Schedule = require 'Schedule'
local check = require('harness').check
local finish = require('harness').finish

local function at(year, month, day, hour, min)
    return os.time { year = year, month = month, day = day, hour = hour,
                     min = min or 0, sec = 0 }
end

print('Schedule.default')

local night = at(2026, 10, 26, 23, 40)
check('late at night, the usual time is tomorrow',
    Schedule.default(night, 8, 0) == at(2026, 10, 27, 8))
check('early, it is later today',
    Schedule.default(at(2026, 10, 27, 6, 0), 8, 0) == at(2026, 10, 27, 8))
check('too close to it today, it is tomorrow',
    Schedule.default(at(2026, 10, 27, 7, 58), 8, 0) == at(2026, 10, 28, 8))
check('crosses the end of the month',
    Schedule.default(at(2026, 10, 31, 22, 0), 8, 0) == at(2026, 11, 1, 8))

print('Schedule.usable')

check('far enough ahead is fine', Schedule.usable(at(2026, 10, 27, 8), night))
check('a passed time is not', not Schedule.usable(at(2026, 10, 26, 23, 0), night))
check('nor one only moments away', not Schedule.usable(night + 60, night))
check('nor none at all', not Schedule.usable(nil, night))

print('Schedule.describe and argument')

local morning = at(2026, 10, 27, 8, 5)
check('said back with the year', Schedule.describe(morning) == 'Tue, Oct 27, 2026 at 8:05 AM',
    Schedule.describe(morning))
check('written for substack-post in local time',
    Schedule.argument(morning) == '2026-10-27T08:05', Schedule.argument(morning))
local h, m = Schedule.timeOfDay(at(2026, 10, 27, 20, 15))
check('the time of day to remember', h == 20 and m == 15)

finish()
