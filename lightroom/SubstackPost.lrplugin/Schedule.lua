--[[
    When a scheduled post goes live: the default, whether a choice is still
    usable, and how it is written for people and for substack-post.

    Choosing is done by DatePicker.js, since Lightroom's SDK has no date or
    time control. This file is plain Lua and the standard os library, so it
    can be tested outside Lightroom.
]]

local Schedule = {}

--- How far ahead a post must be scheduled: long enough to upload it first.
Schedule.LEAD = 5 * 60

--- The next time it is `hour`:`minute` that is far enough ahead: today if
-- there is still time, otherwise tomorrow.
function Schedule.default(now, hour, minute)
    local day = os.date('*t', now)
    for offset = 0, 1 do
        -- Built from the calendar date rather than by adding seconds, so a
        -- DST change cannot move it to the wrong day or hour.
        local moment = os.time { year = day.year, month = day.month,
            day = day.day + offset, hour = hour, min = minute, sec = 0 }
        if moment >= now + Schedule.LEAD then return moment end
    end
end

--- Whether `moment` is still far enough ahead to schedule. The picker only
-- offers such times, but one can pass while the dialog sits open.
function Schedule.usable(moment, now)
    return moment ~= nil and moment >= now + Schedule.LEAD
end

--- The hour and minute of `moment`, for remembering a usual time.
function Schedule.timeOfDay(moment)
    local t = os.date('*t', moment)
    return t.hour, t.min
end

--- "Tue, Oct 27, 2026 at 8:00 AM"
function Schedule.describe(moment)
    return os.date('%a, %b ', moment) .. tonumber(os.date('%d', moment))
        .. os.date(', %Y at ', moment)
        .. tonumber(os.date('%I', moment)) .. os.date(':%M %p', moment)
end

--- "2026-10-27T08:00", local time, for substack-post --schedule.
function Schedule.argument(moment)
    return os.date('%Y-%m-%dT%H:%M', moment)
end

return Schedule
