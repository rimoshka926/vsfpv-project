-- PG-7 night vision, key 8

local NV = VSFPV_CFG.NV
local log = VSFPV_DIAG.log
local fault = VSFPV_DIAG.fault
local try = VSFPV_DIAG.try

function FpvController:cl_nvRange()
	if self.cl.nvRange then
		return self.cl.nvRange
	end
	local r = NV.RANGE_FALLBACK
	local d = sm.render.getDrawDistance()
	if d and d > 100.0 then
		r = d * NV.RANGE_MUL
	end
	self.cl.nvRange = r
	return r
end

local function nvColor(c)
	return sm.color.new(c[1], c[2], c[3], c[4])
end

-- there's no resetOutdoorLighting. Creative and Survival set it every frame but Challenge and custom
-- games don't, so the world would stay dark until a reload
function FpvController:cl_captureOutdoorLighting()
	self.cl.nvOutdoorRestore = sm.render.getOutdoorLighting()
end

function FpvController:cl_restoreOutdoorLighting()
	local v = self.cl.nvOutdoorRestore
	self.cl.nvOutdoorRestore = nil
	if v then
		sm.render.setOutdoorLighting(v)
	end
end

local function resetRender()
	sm.render.resetGI()
	sm.render.resetCameraLight()
	sm.render.resetFog()
end

-- Every frame, Creative and Survival reset the render state themselves
-- fog goes separately so a failure there keeps the monochrome
function FpvController:cl_stepNightRender()
	local ok, err = pcall(function()
		sm.render.setGI(NV.GI)
		sm.render.setOutdoorLighting(NV.OUTDOOR)
		local light = nvColor(NV.LIGHT)
		local range = self:cl_nvRange()
		sm.render.setCameraLight(NV.INTENSITY, range, light, NV.FAR_INTENSITY, range, light)
	end)
	if not ok then
		fault("night vision", err)
		self.cl.nvBroken = true
		self.cl.nvLive = false
		-- Half of it may have gone through, and cl_stopNightRender skips once nvLive is false.
		-- The rollback uses the same API, so it may refuse too
		try("night vision rollback", resetRender)
		try("outdoor lighting restore", self.cl_restoreOutdoorLighting, self)
		log("general", "night vision off")
		self:cl_applyVision() -- nvBroken is set, no loop
		return
	end
	if self.cl.nvFogLost then
		return
	end
	local f = NV.FOG
	local fogOk, fogErr = pcall(function()
		sm.render.setFog(
			f.start,
			f.fin,
			f.falloff,
			nvColor(f.startColor),
			nvColor(f.endColor),
			f.vOpacity,
			f.vFade,
			f.vFalloff,
			f.vStart,
			f.vEnd,
			nvColor(f.vStartColor),
			nvColor(f.vEndColor),
			f.fade
		)
	end)
	if not fogOk then
		fault("night vision fog", fogErr)
		self.cl.nvFogLost = true
		log("general", "night vision fog off, monochrome only")
	end
end

function FpvController:cl_stopNightRender()
	if not self.cl.nvLive then
		return
	end
	self.cl.nvLive = false
	resetRender()
	self:cl_restoreOutdoorLighting()
end

-- VisionPhosphor tints what the camera light can't reach (sky, self-lit surfaces)
-- keep it faint, a strong wash turns the shadows murky
function FpvController:cl_applyVision()
	local on = (self.cl.visionMode == 1) and self.cl.active and self.cl.visionModes
	if not on then
		self:cl_closeVision()
		return
	end
	if not self.cl.nvBroken then
		if not self.cl.nvLive then
			self:cl_captureOutdoorLighting() -- before our first write
		end
		self.cl.nvLive = true
		self:cl_stepNightRender()
	end
	if not self.cl.visionGui then
		self.cl.visionGui = self:cl_openOverlay("$CONTENT_DATA/Gui/Layouts/Hud_FpvVision.layout", false)
	end
	local gui = self.cl.visionGui
	local label = self.cl.nvBroken and "NIGHT VISION UNAVAILABLE" or "NIGHT VISION"
	gui:setVisible("VisionPhosphor", not self.cl.nvBroken)
	gui:setText("VisionLabel", label)
	gui:setVisible("VisionLabel", true)
end

function FpvController:cl_closeVision()
	self:cl_stopNightRender()
	if self.cl.visionGui then
		self.cl.visionGui:setVisible("VisionPhosphor", false)
		self.cl.visionGui:setVisible("VisionLabel", false)
	end
end

function FpvController:cl_destroyVision()
	self:cl_stopNightRender()
	self:cl_closeOverlay("visionGui")
end
