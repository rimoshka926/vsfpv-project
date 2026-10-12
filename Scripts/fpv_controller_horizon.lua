-- PG-7 artificial horizon. GUI widgets can't move at runtime, so each glyph is a world icon placed
-- far in front of the camera and the engine projects it (roll, pitch and FOV for free)

local HORIZON_OSD = VSFPV_CFG.HORIZON_OSD
local UP = VSFPV_FRAME.UP
local log = VSFPV_DIAG.log
local fault = VSFPV_DIAG.fault
local try = VSFPV_DIAG.try

local CHEVRON_COUNT = math.floor(360 / HORIZON_OSD.ROLL_STEP + 0.5)

local function scaledPx(px, screenHeight)
	return math.max(1, math.floor(px * screenHeight / HORIZON_OSD.REF_HEIGHT + 0.5))
end

-- a zero height would shrink every glyph to one pixel
local function screenHeight()
	local _, h = sm.gui.getScreenSize()
	return h > 0 and h or HORIZON_OSD.REF_HEIGHT
end

local function chevronImage(index)
	return string.format(HORIZON_OSD.CHEVRON_IMAGE, index)
end

local function createGui(px)
	local gui = sm.gui.createWorldIconGui(px, px)
	gui:setRequireLineOfSight(false) -- draw over terrain
	gui:setMaxRenderDistance(HORIZON_OSD.MAX_RENDER_DISTANCE)
	return gui
end

local function destroyGui(gui)
	try("horizon icon close", function()
		gui:close()
	end)
	try("horizon icon destroy", function()
		gui:destroy()
	end)
end

local function destroyGlyph(g)
	if g.gui then
		destroyGui(g.gui)
	end
	g.gui, g.image, g.open = nil, nil, false
end

local function setGlyphImage(g, image)
	if g.image ~= image then
		g.gui:setImage("Icon", image)
		g.image = image
	end
end

local function showGlyph(g, on)
	if g.open == on then
		return
	end
	g.open = on
	if on then
		g.gui:open()
	else
		g.gui:close()
	end
end

-- POOL chevrons per side, reticle last
function FpvController:cl_buildHorizon(height)
	local marker, reticle = scaledPx(HORIZON_OSD.MARKER_PX, height), scaledPx(HORIZON_OSD.RETICLE_PX, height)
	local h = { height = height, glyphs = {} }
	local ok, err = pcall(function()
		for i = 1, HORIZON_OSD.POOL * 2 do
			h.glyphs[i] = { gui = createGui(marker), image = nil, open = false }
		end
		h.glyphs[#h.glyphs + 1] = { gui = createGui(reticle), image = nil, open = false }
	end)
	if not ok then
		fault("artificial horizon build", err)
		for _, g in ipairs(h.glyphs) do
			destroyGlyph(g)
		end
		return nil
	end
	return h
end

-- Screen angle of the horizon line, ccw from screen right. Aiming the chevrons at world down
-- instead fans them out to the edges when pitched
local function lineAngleOnScreen(cam, ahead, side)
	local a = math.rad(HORIZON_OSD.MAX)
	local l = ahead * math.cos(a) - side * math.sin(a)
	local r = ahead * math.cos(a) + side * math.sin(a)
	local lx, ly = l:dot(cam.right) / l:dot(cam.fwd), l:dot(cam.up) / l:dot(cam.fwd)
	local rx, ry = r:dot(cam.right) / r:dot(cam.fwd), r:dot(cam.up) / r:dot(cam.fwd)
	return math.deg(math.atan2(ry - ly, rx - lx))
end

-- Image 0 = level, tip down (ground side), so inverted flight points it up
local function chevronIndex(lineDeg)
	local turns = (lineDeg % 360.0) / HORIZON_OSD.ROLL_STEP
	return math.floor(turns + 0.5) % CHEVRON_COUNT
end

local function parkGlyph(g, cam, dir, image)
	g.gui:setWorldPosition(cam.pos + dir * HORIZON_OSD.DISTANCE)
	setGlyphImage(g, image)
end

-- Chevrons at fixed world headings so they slide when yawing, GAP only while the reticle is on the line
local function placeGlyphs(h)
	local cam = {
		pos = sm.camera.getPosition(),
		fwd = sm.camera.getDirection(),
		right = sm.camera.getRight(),
		up = sm.camera.getUp(),
	}
	local level = cam.fwd - UP * cam.fwd:dot(UP)
	local levelLen = level:length()
	local pool = HORIZON_OSD.POOL * 2
	local used = 0
	if levelLen >= HORIZON_OSD.MIN_LEVEL then
		local ahead = level * (1.0 / levelLen)
		local image = chevronImage(chevronIndex(lineAngleOnScreen(cam, ahead, ahead:cross(UP))))
		local onHorizon = math.abs(math.deg(math.asin(cam.fwd:dot(UP)))) <= HORIZON_OSD.CENTRE_HIDE_DEG
		local gap = onHorizon and HORIZON_OSD.GAP or 0.0
		local heading = math.deg(math.atan2(level.y, level.x))
		local step = HORIZON_OSD.STEP
		local first = math.floor((heading - HORIZON_OSD.MAX) / step)
		local last = math.ceil((heading + HORIZON_OSD.MAX) / step)
		for k = first, last do
			local az = k * step
			local delta = (az - heading + 180.0) % 360.0 - 180.0
			local off = math.abs(delta)
			if off >= gap and off <= HORIZON_OSD.MAX and used < pool then
				used = used + 1
				local a = math.rad(az)
				parkGlyph(h.glyphs[used], cam, sm.vec3.new(math.cos(a), math.sin(a), 0.0), image)
			end
		end
	end
	for i = 1, pool do
		showGlyph(h.glyphs[i], i <= used)
	end
	local reticle = h.glyphs[pool + 1]
	parkGlyph(reticle, cam, cam.fwd, HORIZON_OSD.RETICLE_IMAGE)
	showGlyph(reticle, true)
end

-- After the camera is placed. A GUI error turns it off for the session instead of breaking the camera
function FpvController:cl_stepHorizon()
	if not self.cl.horizonOsd or self.cl.filming or self.cl.horizonBroken then
		self:cl_hideHorizon()
		return
	end
	local height = screenHeight()
	if self.cl.horizon and self.cl.horizon.height ~= height then
		self:cl_destroyHorizon()
	end
	if not self.cl.horizon then
		self.cl.horizon = self:cl_buildHorizon(height)
	end
	local h = self.cl.horizon
	if h then
		local ok, err = pcall(placeGlyphs, h)
		if ok then
			return
		end
		fault("artificial horizon", err)
	end
	self.cl.horizonBroken = true
	self:cl_destroyHorizon()
	log("general", "artificial horizon off")
end

function FpvController:cl_hideHorizon()
	local h = self.cl.horizon
	if not h then
		return
	end
	for _, g in ipairs(h.glyphs) do
		try("horizon hide", showGlyph, g, false)
	end
end

function FpvController:cl_destroyHorizon()
	local h = self.cl.horizon
	if not h then
		return
	end
	for _, g in ipairs(h.glyphs) do
		destroyGlyph(g)
	end
	self.cl.horizon = nil
end
