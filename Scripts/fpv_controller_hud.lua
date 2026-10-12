-- Pilot HUD: the OSD readouts, the controls help, notifications and the zoom readout

local NOTIFY_FRAMES = VSFPV_CFG.NOTIFY_FRAMES

-- The Mavic holds its own altitude, so the flight mode takes the throttle spot
function FpvController:cl_applyOsdMode()
	local gui = self.cl.gui
	if not gui then
		return
	end
	local isAngle = (self.cl.mode == "angle")
	gui:setVisible("ThrValue", not isAngle)
	gui:setVisible("ThrLabel", not isAngle)
	gui:setVisible("ModeValue", isAngle)
	gui:setVisible("ModeLabel", isAngle)
end

-- Never takes the keys or the cursor. Filming's hideGui(true) hides all of them at once
function FpvController:cl_openOverlay(layout, hidesHotbar)
	local gui = sm.gui.createGuiFromLayout(
		layout,
		false,
		{ isHud = true, isInteractive = false, needsCursor = false, hidesHotbar = hidesHotbar }
	)
	gui:open()
	return gui
end

function FpvController:cl_closeOverlay(field)
	local gui = self.cl[field]
	if gui then
		gui:close()
		gui:destroy()
		self.cl[field] = nil
	end
end

local HELP_ROWS_MIN = 4
local HELP_ROWS_MAX = 11

function FpvController:cl_openHelp()
	if self.cl.helpGui then
		return
	end
	self.cl.helpGui = self:cl_openOverlay("$CONTENT_DATA/Gui/Layouts/Hud_FpvControls.layout", false)
	self:cl_applyHelp()
end

function FpvController:cl_closeHelp()
	self:cl_closeOverlay("helpGui")
end

function FpvController:cl_syncHelp()
	if self.cl.helpOpen then
		self:cl_openHelp()
	else
		self:cl_closeHelp()
	end
end

function FpvController:cl_applyHelp()
	local gui = self.cl.helpGui
	if not gui then
		return
	end
	local isAngle = (self.cl.mode == "angle")
	local keys, acts = {}, {}
	local function row(k, a)
		keys[#keys + 1] = k
		acts[#acts + 1] = a
	end
	-- Held inputs, then number keys in keyboard order (0 last), then exit
	row("WASD", isAngle and "Move" or "Throttle / Yaw")
	row("Mouse", isAngle and "Look / Camera" or "Pitch / Roll")
	if isAngle then
		row("LMB / RMB", "Up / Down")
	end
	if self.cl.zoomMax and self.cl.zoomMax > 1.0 then
		row("Wheel", string.format("Zoom 1-%.0fx", self.cl.zoomMax))
	elseif not isAngle then
		row("Wheel", "Throttle +/- 1%")
	end
	if isAngle then
		row("1 2 3", "Flight mode")
		row("4", "Return to Home")
	end
	row("5", "Filming (hide HUD)")
	if isAngle then
		row("6", "Horizon lock")
	else
		row("7", "Invert pitch")
	end
	if self.cl.visionModes then
		row("8", "Night vision")
	end
	row("9", "Hide this help")
	row("0", "Unbind drone")
	row("SPACE / E", "Exit")
	local dname = self.cl.droneName or (isAngle and "MAVIC" or "FPV")
	-- Widgets can't be resized at runtime, so there's a background per row count
	local bg = math.max(HELP_ROWS_MIN, math.min(HELP_ROWS_MAX, #keys))
	gui:setText("HelpTitle", "CONTROLS / " .. dname)
	gui:setText("KeysCol", table.concat(keys, "\n"))
	gui:setText("DescCol", table.concat(acts, "\n"))
	for n = HELP_ROWS_MIN, HELP_ROWS_MAX do
		gui:setVisible("HelpBg" .. n, n == bg)
	end
end

-- Takes the hotbar away. The stats and Tab hints stay, hiding them would blank the OSD too
function FpvController:cl_openHud()
	if self.cl.gui then
		return
	end
	self.cl.gui = self:cl_openOverlay("$CONTENT_DATA/Gui/Layouts/Hud_FpvOsd.layout", true)
	self:cl_applyOsdMode()
end

function FpvController:cl_closeHud()
	self:cl_closeOverlay("gui")
end

function FpvController:cl_osd(data)
	self.cl.gimbalScale = data.g
	self.cl.throttle = data.t
	self.cl.rthActive = data.rth and true or false
	-- The first update only takes the counter, so an old message doesn't pop up
	if self.cl.notifySeq == nil then
		self.cl.notifySeq = data.hq
	elseif data.hq ~= self.cl.notifySeq then
		self.cl.notifySeq = data.hq
		self.cl.notifyText = data.hmsg or ""
		self.cl.notifyFrames = NOTIFY_FRAMES
	end

	local gui = self.cl.gui
	if not gui then
		return
	end
	gui:setText("SpeedValue", tostring(data.s))
	gui:setText("AltValue", tostring(data.a))
	if self.cl.mode ~= "angle" then
		gui:setText("ThrValue", tostring(data.t))
	elseif data.m then
		gui:setText("ModeValue", tostring(data.m))
	end
	if self.cl.mode == "angle" and data.rth then
		gui:setText("RthValue", "RTH  " .. tostring(data.hd) .. " M")
		gui:setVisible("RthValue", true)
	elseif self.cl.notifyFrames > 0 and self.cl.notifyText ~= "" then
		gui:setText("RthValue", self.cl.notifyText)
		gui:setVisible("RthValue", true)
	else
		gui:setVisible("RthValue", false)
	end
end

function FpvController:cl_setFilming(on)
	self.cl.filming = on
	sm.gui.hideGui(on)
end

-- Drawn right away instead of on the next OSD update. RTH keeps the spot while it runs
function FpvController:cl_notify(text)
	self.cl.notifyText = text
	self.cl.notifyFrames = NOTIFY_FRAMES
	if self.cl.gui and not self.cl.rthActive then
		self.cl.gui:setText("RthValue", text)
		self.cl.gui:setVisible("RthValue", true)
	end
end

function FpvController:cl_updateNotifyTimer()
	if self.cl.notifyFrames > 0 then
		self.cl.notifyFrames = self.cl.notifyFrames - 1
		if self.cl.notifyFrames <= 0 and not self.cl.rthActive and self.cl.gui then
			self.cl.gui:setVisible("RthValue", false)
		end
	end
end

function FpvController:cl_updateZoomOsd()
	if self.cl.gui and self.cl.zoomMax and self.cl.zoomMax > 1.0 then
		self.cl.gui:setText("ZoomValue", string.format("%.1fx", self.cl.zoom))
		self.cl.gui:setVisible("ZoomValue", self.cl.zoom > 1.05)
	end
end
