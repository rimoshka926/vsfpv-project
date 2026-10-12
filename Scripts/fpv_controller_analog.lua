-- PG-7 analog camera. No post-processing in SM, so it's full screen images stacked in Hud_FpvAnalog.layout

local ANALOG = VSFPV_CFG.ANALOG

local FIELD = 1.0 / ANALOG.FIELD_RATE

local function image(name)
	return ANALOG.IMAGE_DIR .. name .. ".png"
end

local function setImage(gui, widget, name)
	gui:setImage(widget, image(name))
end

local function nextGap()
	return ANALOG.GLITCH_GAP[1] + math.random() * (ANALOG.GLITCH_GAP[2] - ANALOG.GLITCH_GAP[1])
end

-- Every pool has at least 3 frames so this always ends
local function pickFrame(n, a, b)
	local f
	repeat
		f = math.random(0, n - 1)
	until f ~= a and f ~= b
	return f
end

local function newGlitch()
	if math.random() < 0.6 then
		return { kind = "burst", left = math.random(ANALOG.BURST_LENGTH[1], ANALOG.BURST_LENGTH[2]) }
	end
	return { kind = "roll", frame = math.random(0, ANALOG.ROLL_START) }
end

function FpvController:cl_openAnalog()
	if self.cl.analogGui then
		return
	end
	self.cl.analogGui = self:cl_openOverlay("$CONTENT_DATA/Gui/Layouts/Hud_FpvAnalog.layout", false)
	self.cl.analogClock = FIELD -- first field right away
	self.cl.analogGap = nextGap()
	self.cl.analogGlitch = nil
end

function FpvController:cl_closeAnalog()
	self:cl_closeOverlay("analogGui")
end

-- Every client gets the unbind, only the pilot sees static
function FpvController:cl_analogCameraLost()
	if self.cl.active and self.cl.analogCam then
		self.cl.analogStatic = ANALOG.STATIC_HOLD
	end
end

local function motorLevel(throttle)
	local level = 0
	for i, step in ipairs(ANALOG.MOTOR_STEPS) do
		if throttle > step then
			level = i
		end
	end
	return level
end

-- Two grain layers so the pattern doesn't visibly loop
function FpvController:cl_drawAnalogField()
	local cl, gui = self.cl, self.cl.analogGui
	local shown = cl.analogShown
	local g1 = pickFrame(ANALOG.GRAIN_FRAMES, shown.Grain, shown.Grain2)
	local g2 = pickFrame(ANALOG.GRAIN_FRAMES, g1, shown.Grain2)
	shown.Grain, shown.Grain2 = g1, g2
	setImage(gui, "Grain", string.format("grain_%d", g1))
	setImage(gui, "Grain2", string.format("grain_%d", g2))

	local level = motorLevel(cl.throttle)
	gui:setVisible("Motor", level > 0)
	if level > 0 then
		shown.Motor = pickFrame(ANALOG.MOTOR_FRAMES, shown.Motor)
		setImage(gui, "Motor", string.format("motor_%d_%d", level, shown.Motor))
	end

	cl.analogGap = cl.analogGap - FIELD
	if not cl.analogGlitch and cl.analogGap <= 0 then
		cl.analogGlitch = newGlitch()
		cl.analogGap = nextGap()
	end
	local g = cl.analogGlitch
	if not g then
		gui:setVisible("Glitch", false)
		return
	end
	gui:setVisible("Glitch", true)
	if g.kind == "burst" then
		shown.Glitch = pickFrame(ANALOG.BURST_FRAMES, shown.Glitch)
		setImage(gui, "Glitch", string.format("burst_%d", shown.Glitch))
		g.left = g.left - 1
		if g.left <= 0 then
			cl.analogGlitch = nil
		end
	else
		setImage(gui, "Glitch", string.format("roll_%d", g.frame))
		g.frame = g.frame + math.random(ANALOG.ROLL_STEP[1], ANALOG.ROLL_STEP[2])
		if g.frame >= ANALOG.ROLL_FRAMES then
			cl.analogGlitch = nil
		end
	end
end

-- Fixed field rate, the noise has to look the same at any fps
function FpvController:cl_stepAnalog(dt)
	local cl = self.cl
	local feed = cl.active and cl.analogCam
	local snowing = cl.analogStatic > 0
	if not (feed or snowing) then
		self:cl_closeAnalog()
		return
	end
	self:cl_openAnalog()
	local gui = cl.analogGui
	if snowing then
		cl.analogStatic = cl.analogStatic - dt
		gui:setVisible("Static", cl.analogStatic > 0)
	end
	cl.analogClock = cl.analogClock + dt
	if cl.analogClock < FIELD then
		return
	end
	cl.analogClock = cl.analogClock % FIELD
	if snowing then
		cl.analogShown.Static = pickFrame(ANALOG.STATIC_FRAMES, cl.analogShown.Static)
		setImage(gui, "Static", string.format("static_%d", cl.analogShown.Static))
	elseif feed then
		self:cl_drawAnalogField()
	end
end
