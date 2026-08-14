--[[
    Picking the JPEG of a RAW+JPEG pair. Run from the repository root:

        lua tests/test_sources.lua
]]

package.path = 'tests/?.lua;lightroom/SubstackPost.lrplugin/?.lua;' .. package.path
require('lrstub').install()

local Sources = require 'Sources'
local check = require('harness').check
local finish = require('harness').finish

local TMP = (os.getenv('TMPDIR') or '/tmp/') .. 'substack-sources-test/'
os.execute('rm -rf ' .. TMP .. ' && mkdir -p ' .. TMP)

local function touch(name)
    local handle = assert(io.open(TMP .. name, 'w'))
    handle:write('x')
    handle:close()
    return TMP .. name
end

print('Sources.isRaw')

-- Cameras write these in caps; a case-sensitive check would never fire.
for _, name in ipairs { 'a.DNG', 'a.ARW', 'a.CR2', 'a.NEF', 'a.RAF' } do
    check('recognises ' .. name, Sources.isRaw(TMP .. name))
end
for _, name in ipairs { 'a.dng', 'a.arw', 'a.cr3' } do
    check('recognises ' .. name, Sources.isRaw(TMP .. name))
end
for _, name in ipairs { 'a.jpg', 'a.JPG', 'a.tif', 'a.png', 'a' } do
    check(name .. ' is not raw', not Sources.isRaw(TMP .. name))
end
check('an empty path is not raw', not Sources.isRaw(''))
check('a nil path is not raw', not Sources.isRaw(nil))

print('Sources.siblingJpeg')

local raw = touch('R0001436.DNG')
local jpeg = touch('R0001436.JPG')
check('finds an uppercase JPEG beside the raw', Sources.siblingJpeg(raw) == jpeg)

check('finds nothing when there is no JPEG',
    Sources.siblingJpeg(touch('R0001437.DNG')) == nil)
check('never looks beside a file that is not raw',
    Sources.siblingJpeg(touch('R0001438.JPG')) == nil)

-- A .tif beside the raw is not a JPEG, however much it looks like a sidecar.
touch('R0001439.DNG')
touch('R0001439.TIF')
check('ignores a sibling that is not a JPEG',
    Sources.siblingJpeg(TMP .. 'R0001439.DNG') == nil)

print('Sources.chooseFile')

local RENDER = '/tmp/render.jpg'

local chosen, why = Sources.chooseFile(RENDER, raw, 'render', false)
check('keeps the render in render mode', chosen == RENDER and why == 'render')

chosen, why = Sources.chooseFile(RENDER, raw, 'jpeg', false)
check('takes the sibling JPEG in jpeg mode',
    chosen == jpeg and why == 'sidecar-jpeg')

chosen, why = Sources.chooseFile(RENDER, raw, 'jpeg', true)
check('a virtual copy keeps the render, edits being the point of one',
    chosen == RENDER and why == 'render:virtual-copy')

chosen, why = Sources.chooseFile(RENDER, TMP .. 'R0001437.DNG', 'jpeg', false)
check('falls back to the render when the JPEG is missing',
    chosen == RENDER and why == 'render')

chosen, why = Sources.chooseFile(RENDER, nil, 'jpeg', false)
check('falls back to the render with no original path',
    chosen == RENDER and why == 'render')

chosen, why = Sources.chooseFile(RENDER, TMP .. 'R0001438.JPG', 'jpeg', false)
check('a photo that is already a JPEG uses its render',
    chosen == RENDER and why == 'render')

os.execute('rm -rf ' .. TMP)
finish()
