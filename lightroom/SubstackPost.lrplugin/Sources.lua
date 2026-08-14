--[[
    Choosing which file to post for a photo.

    A photo shot RAW+JPEG is one photo in Lightroom — the raw file, with the
    JPEG attached beside it — so posting renders the raw and the camera's own
    JPEG is never seen. When that JPEG is the wanted version, this picks it up
    instead.

    Lightroom does not expose its RAW+JPEG pairing to plug-ins, so the pairing
    is found on the filesystem: the JPEG sitting next to the catalog's file.
]]

local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'

local Sources = {}

Sources.RAW_PLUS_JPEG_MODES = { 'render', 'jpeg' }

local RAW_SUFFIXES = {
    dng = true, arw = true, cr2 = true, cr3 = true, nef = true, nrw = true,
    raf = true, orf = true, rw2 = true, pef = true, srw = true, raw = true,
    erf = true, iiq = true, ['3fr'] = true,
}

-- Probed in order. Both cases are tried because a case-sensitive volume answers
-- only to the exact spelling, while a case-insensitive one answers to all of
-- them for a single file — hence stopping at the first hit.
local JPEG_SPELLINGS = { 'JPG', 'jpg', 'JPEG', 'jpeg' }

--- Cameras write .ARW, .DNG, .CR2 in caps, so fold case before comparing — a
-- case-sensitive match would never fire and would look like the setting is
-- simply off.
function Sources.isRaw(path)
    if not path or path == '' then return false end
    return RAW_SUFFIXES[string.lower(LrPathUtils.extension(path))] == true
end

--- The JPEG sitting beside a raw file, if there is one.
function Sources.siblingJpeg(original)
    if not Sources.isRaw(original) then return nil end
    local base = LrPathUtils.removeExtension(original)
    for _, spelling in ipairs(JPEG_SPELLINGS) do
        local candidate = LrPathUtils.addExtension(base, spelling)
        if LrFileUtils.exists(candidate) == 'file' then
            return candidate
        end
    end
    return nil
end

--- Return the file to post, and why.
-- Falls back to Lightroom's render whenever the JPEG cannot be used, rather
-- than failing: the sibling may have been deleted or its volume unmounted, and
-- a posted photo beats a failed one.
function Sources.chooseFile(rendered, original, mode, isVirtualCopy)
    if mode ~= 'jpeg' or not original or original == '' then
        return rendered, 'render'
    end

    -- A virtual copy is a deliberate request for a different edit.
    if isVirtualCopy then
        return rendered, 'render:virtual-copy'
    end

    local jpeg = Sources.siblingJpeg(original)
    if jpeg then
        return jpeg, 'sidecar-jpeg'
    end
    return rendered, 'render'
end

return Sources
