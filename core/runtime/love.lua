-- The `love` table, as far as the runtime still asks for one.
--
-- `core/runtime/*.lua` was written against LÖVE, and LÖVE is gone (.robot/docs/engine.robot). The names it still
-- calls are here, backed by the engine (engine/src): byte utilities, a clock, pixel buffers, the
-- runtime's own location. `love.graphics` draws into nothing (see below). Whatever would need
-- LÖVE's own work to reach the frame -- a readback, GLSL, physics -- is a feature that has not
-- been ported to the engine yet, and says so the moment it is *called*: an offline run exits with
-- status 3, and a serve session fails that one request in words and carries on.
--
-- Called, not looked up: the runtime probes for features (`gfx.readbackTexture and ...`) on
-- paths it then never takes, and a probe must not end the run.

local E = ...

ENGINE_NOT_PORTED = E.not_ported
-- What the engine itself offers the runtime beyond the `love` names (physics, for one).
MOONSPLICE_ENGINE = E

local function needs(what)
  return function()
    local msg = ("%s is not ported to the engine yet (.robot/docs/engine.robot, phases 2-3)"):format(what)
    -- A serve session is a conversation with the app: one frame that cannot be drawn is an
    -- answer to that request, not the end of the session.
    if ENGINE_SERVING then error(msg, 0) end
    io.stdout:flush()
    io.stderr:write("moonsplice-engine: " .. msg .. "\n")
    -- Which line asked, when the question is where an unported feature is used.
    if os.getenv("MOONSPLICE_ENGINE_TRACE") == "1" then io.stderr:write(debug.traceback() .. "\n") end
    io.stderr:flush()
    os.exit(E.not_ported)
  end
end

-- For the runtime to name an unported feature itself, before it reaches for LÖVE's.
MOONSPLICE_NOT_PORTED = function(what) needs(what)() end

-- A module this host does not have: every function on it says it is not ported.
local function absent(name, extra)
  local t = extra or {}
  return setmetatable(t, { __index = function(_, k) return needs(name .. "." .. tostring(k)) end })
end

love = {}

love.arg = {
  -- LÖVE strips its own flags; this host has none, so the game's arguments are all of them.
  parseGameArguments = function(a)
    local out = {}
    for i = 1, #a do out[i] = a[i] end
    return out
  end,
}

-- FileData: bytes with a name. `newImageData` reads it; nothing else on the direct path does.
local FileData = {}
FileData.__index = FileData
function FileData:getString() return self.__bytes end
function FileData:getSize() return #self.__bytes end
function FileData:getFilename() return self.__name end
function FileData:type() return "FileData" end
function FileData:release() return true end

love.filesystem = absent("love.filesystem", {
  getSource = function() return E.runtime end,
  newFileData = function(bytes, name)
    return setmetatable({ __bytes = bytes, __name = name or "" }, FileData)
  end,
})

love.data = absent("love.data", {
  hash = function(algo, s)
    if type(s) ~= "string" and s.getString then s = s:getString() end
    return E.hash(algo, s)
  end,
  encode = function(container, format, s)
    assert(container == "string", "love.data.encode: only the string container is on this host")
    if format == "hex" then return E.hex(s) end
    if format == "base64" then return E.base64_encode(s) end
    error("love.data.encode: unknown format " .. tostring(format))
  end,
  decode = function(container, format, s)
    assert(container == "string", "love.data.decode: only the string container is on this host")
    if format == "hex" then return E.unhex(s) end
    if format == "base64" then return E.base64_decode(s) end
    error("love.data.decode: unknown format " .. tostring(format))
  end,
})

love.timer = absent("love.timer", {
  getTime = E.now,
  sleep = E.sleep,
})

-- The comp sandbox seeds both generators; nothing on the direct path draws from LÖVE's.
love.math = absent("love.math", {
  setRandomSeed = function() end,
})

love.image = absent("love.image", {
  newImageData = function(a, b, c, d)
    if type(a) == "table" and a.__bytes then
      local img, why, not_ported = E.image_decode(a.__bytes)
      if img then return img end
      if not_ported then needs(why)() end
      error("love.image.newImageData: " .. tostring(why), 2)
    end
    if type(a) == "string" then needs("love.image.newImageData(filename)")() end
    return E.image_new(a, b, c, d)
  end,
})

-- `love.graphics`: everything it draws is thrown away, except what is read back.
--
-- On the direct path the painter still pushes transforms, sets blend modes, fills stencils and
-- draws shadow canvases through LÖVE as it walks the nodes -- onto a hidden window nobody reads,
-- because the frame is the buffer `scene/` fills. So drawing here does nothing, and costs
-- nothing. LÖVE's pixels can reach a frame in exactly one way: by being read back into an
-- ImageData (a canvas's `newImageData`, `readbackTexture`). That is a perspective slot, a GLSL
-- effect, a love-drawn kind, the whole canvas path. A readback is therefore where the comp is
-- handed to LÖVE, along with anything that reads a number off LÖVE (font metrics, a texture's
-- size), since a number can steer the frame as surely as a pixel can.
local HANDOVER = {
  newImageData = true, getImageData = true, readbackTexture = true, readbackTextureAsync = true,
  captureScreenshot = true, getWidth = true, getHeight = true, getDimensions = true,
  getPixelWidth = true, getPixelHeight = true, getPixelDimensions = true, getWrap = true,
  getAscent = true, getDescent = true, getBaseline = true, getLineHeight = true,
  hasGlyphs = true, getKerning = true, getSupported = true, getSystemLimits = true,
  isSupported = true, getTextureTypes = true, getImageFormats = true, getCanvasFormats = true,
  getStats = true, getRendererInfo = true, isGammaCorrect = true, getDPIScale = true,
}
-- Getters whose answer only feeds LÖVE's own state back into LÖVE (save, then restore).
local NEUTRAL = {
  getBlendMode = function() return "alpha", "alphamultiply" end,
  getCanvas = function() return nil end,
  getStencilTest = function() return "always", 0 end,
  getColor = function() return 1, 1, 1, 1 end,
  getShader = function() return nil end,
  getScissor = function() return nil end,
  getLineWidth = function() return 1 end,
  getPointSize = function() return 1 end,
  isWireframe = function() return false end,
}

local sink -- an object or module whose drawing goes nowhere
local function sink_index(name)
  return function(_, k)
    if HANDOVER[k] then return needs(name .. "." .. tostring(k)) end
    if NEUTRAL[k] then return NEUTRAL[k] end
    -- constructors hand back something to draw with; everything else returns nothing
    if type(k) == "string" and k:match("^new") then return function() return sink(k:sub(4)) end end
    return function() end
  end
end
sink = function(name)
  return setmetatable({}, { __index = sink_index(name) })
end

love.graphics = sink("love.graphics")

love.physics = absent("love.physics")
love.window = absent("love.window")
love.event = absent("love.event")
love.audio = absent("love.audio")
love.system = absent("love.system")
love.font = absent("love.font")

setmetatable(love, { __index = function(_, k) return absent("love." .. tostring(k)) end })
