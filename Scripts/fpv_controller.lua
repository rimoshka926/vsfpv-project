-- FPV Transmitter, a scripted seat. The seat component has to be nested inside "scripted" in the
-- shapeset, as a sibling it disables the script.
-- The link survives leaving the seat and only breaks on key 0 or when there's nothing left to see through

dofile("$CONTENT_DATA/Scripts/fpv_config.lua")
dofile("$CONTENT_DATA/Scripts/fpv_frame.lua")
dofile("$CONTENT_DATA/Scripts/fpv_diag.lua")

FpvController = class()
-- The pose that hides the model, otherwise the engine reports zero poses
FpvController.poseWeightCount = 1

-- Passenger seat: a steering seat animates a wheel and spams "doesn't have a skeleton"
FpvController.maxParentCount = 0
FpvController.maxChildCount = 0

VSFPV_LINK = VSFPV_LINK or {}
VSFPV_LINK.drones = VSFPV_LINK.drones or {}

-- After class(), these add methods
dofile("$CONTENT_DATA/Scripts/fpv_controller_vision.lua")
dofile("$CONTENT_DATA/Scripts/fpv_controller_horizon.lua")
dofile("$CONTENT_DATA/Scripts/fpv_controller_prefs.lua")
dofile("$CONTENT_DATA/Scripts/fpv_controller_analog.lua")
dofile("$CONTENT_DATA/Scripts/fpv_controller_hud.lua")

local DEBUG_LOG = VSFPV_CFG.DEBUG_LOG
local TELEM_INTERVAL = VSFPV_CFG.TELEM_INTERVAL
local UP = VSFPV_FRAME.UP
local CAM_FIX = VSFPV_FRAME.CAM_FIX
local noseFrame = VSFPV_FRAME.noseFrame
local log = VSFPV_DIAG.log
local fault = VSFPV_DIAG.fault
local try = VSFPV_DIAG.try
local PAIR_RADIUS = VSFPV_CFG.PAIR_RADIUS
local FOV_BASE = VSFPV_CFG.FOV_BASE
local ZOOM_STEP = VSFPV_CFG.ZOOM_STEP
local ZOOM_LERP = VSFPV_CFG.ZOOM_LERP
local TX_HELD_EFFECT = VSFPV_CFG.TX_HELD_EFFECT
local TX_POSE = VSFPV_CFG.TX_POSE
local TX_HELD_FALLBACK = VSFPV_CFG.TX_HELD_FALLBACK
local TX_HELD_NUDGE = VSFPV_CFG.TX_HELD_NUDGE
local TX_HELD_ROT = VSFPV_CFG.TX_HELD_ROT
local TX_SCALE = VSFPV_CFG.TX_SCALE
local CAM_LERP = VSFPV_CFG.CAM_LERP
local WRECK_BACKSTOP_TICKS = VSFPV_CFG.WRECK_BACKSTOP_TICKS
local CAM_OFFSET = VSFPV_CFG.CAM_OFFSET
local CAM_RELEASE_RETRY = VSFPV_CFG.CAM_RELEASE_RETRY
local SEAT_GUARD_FRAMES = VSFPV_CFG.SEAT_GUARD_FRAMES
local OSD_EVERY = VSFPV_CFG.OSD_EVERY
local GIMBAL_GAIN = VSFPV_CFG.GIMBAL_GAIN
local GIMBAL_SIGN = VSFPV_CFG.GIMBAL_SIGN
local GIMBAL_MIN = VSFPV_CFG.GIMBAL_MIN
local GIMBAL_MAX = VSFPV_CFG.GIMBAL_MAX
local HORIZON_LOCK_DEFAULT = VSFPV_CFG.HORIZON_LOCK_DEFAULT
local HORIZON_LOCK_MIN_UP = VSFPV_CFG.HORIZON_LOCK_MIN_UP

-- Server

function FpvController:server_onCreate()
	-- bindExclude: the drone key 0 just let go of, so the next link picks another one
	self.sv = {
		drone = nil,
		wreck = nil, -- exploded drone still in the world, see sv_wreckBackstop
		wreckTicks = 0,
		wasDriving = false,
		bindExclude = nil,
		telem = 0.0,
		osdTick = 0,
		fwd = false,
		back = false,
		left = false,
		right = false,
		climb = false,
		descend = false,
	}
	log("general", "Controller SV created")
end

-- Any client can call a network method by name, the sender comes in as the third argument.
-- Only whoever sits in this seat flies its drone
function FpvController:sv_isPilot(caller)
	local pilot = self.interactable:getSeatCharacter()
	return pilot ~= nil and pilot:getPlayer() == caller
end

-- One NaN in the look input would stay in the attitude loop for good
local function finite(v)
	if type(v) == "number" and v == v and v > -math.huge and v < math.huge then
		return v
	end
	return nil
end

-- owner nil frees the drone
local function setClaim(e, owner)
	e.claimedBy, e.inThrottle, e.inYaw, e.lookX, e.lookY, e.altCmd = owner, 0.0, 0.0, 0.0, 0.0, 0.0
	e.throttleSteps = 0
end

function FpvController:sv_claimedEntry()
	local e = self.sv.drone and VSFPV_LINK.drones[self.sv.drone]
	if e and e.claimedBy == self.shape then
		return e
	end
	return nil
end

function FpvController:sv_input(data, caller)
	if not self:sv_isPilot(caller) then
		return
	end
	if data.fwd ~= nil then
		self.sv.fwd = data.fwd
	end
	if data.back ~= nil then
		self.sv.back = data.back
	end
	if data.left ~= nil then
		self.sv.left = data.left
	end
	if data.right ~= nil then
		self.sv.right = data.right
	end
	if data.climb ~= nil then
		self.sv.climb = data.climb
	end
	if data.descend ~= nil then
		self.sv.descend = data.descend
	end
end

-- The game doesn't always send a key release when you leave the seat or unbind
function FpvController:sv_clearKeys()
	self.sv.fwd, self.sv.back, self.sv.left, self.sv.right, self.sv.climb, self.sv.descend =
		false, false, false, false, false, false
end

-- A scripted seat has no exit, seating the character that's already in it takes them out
function FpvController:sv_exit(_, caller)
	local ch = self.interactable:getSeatCharacter()
	if ch and ch:getPlayer() == caller then
		self.interactable:setSeatCharacter(ch)
	end
end

-- lost = the camera is gone rather than a key 0 hop, the client shows the feed cutting out
function FpvController:sv_release(lost)
	if self.sv.drone then
		local e = self:sv_claimedEntry()
		if e then
			setClaim(e, nil)
		end
		self.sv.drone = nil
		self.network:sendToClients("cl_bind", { drone = nil, lost = lost })
	end
end

-- Key 0
function FpvController:sv_unbindManual(_, caller)
	if not self:sv_isPilot(caller) then
		return
	end
	self.sv.bindExclude = self.sv.drone -- before sv_release clears it
	self:sv_release()
	log("general", "drone UNBOUND (key 0), hopping to the next drone in range")
end

function FpvController:server_onDestroy()
	self:sv_release()
end

function FpvController:sv_look(data, caller)
	if not self.sv.drone or not self:sv_isPilot(caller) then
		return
	end
	local x, y = finite(data.x), finite(data.y)
	local e = self:sv_claimedEntry()
	if e and x and y then
		e.lookX = e.lookX + x
		e.lookY = e.lookY + y
	end
end

-- So everyone sees the Mavic gimbal move
function FpvController:sv_gimbal(data, caller)
	if not self.sv.drone or not self:sv_isPilot(caller) then
		return
	end
	local pitch = finite(data.p)
	local e = self:sv_claimedEntry()
	if e and pitch then
		e.camPitch = pitch
	end
end

-- Keys 1/2/3, the drone clamps the index to its own modes
function FpvController:sv_setMode(data, caller)
	if not self.sv.drone or not self:sv_isPilot(caller) then
		return
	end
	local idx = finite(data.idx)
	local e = self:sv_claimedEntry()
	if e and idx then
		e.angleModeIdx = idx
	end
end

-- Key 4, the logic is in the drone's sv_rthToggle
function FpvController:sv_rthKey(_, caller)
	if not self.sv.drone or not self:sv_isPilot(caller) then
		return
	end
	local e = self:sv_claimedEntry()
	if e then
		e.rthReq = e.rthReq + 1
	end
end

-- One notch per message, the drone applies it on its next tick
function FpvController:sv_throttleStep(data, caller)
	if not self.sv.drone or not self:sv_isPilot(caller) then
		return
	end
	local e = self:sv_claimedEntry()
	local n = finite(data.n)
	if e and n and n ~= 0 then
		e.throttleSteps = e.throttleSteps + ((n > 0) and 1 or -1)
	end
end

function FpvController:server_onFixedUpdate(dt)
	-- jet-hit parts, the drone that queued them may be gone
	if VSFPV_LINK.sweepCarve then
		VSFPV_LINK.sweepCarve()
	end
	self:sv_autoUnbindCheck()
	local driver = self.interactable:getSeatCharacter()
	self:sv_telemetry(dt, driver)
	if not driver then
		self:sv_handleEmptySeat()
		return
	end
	self:sv_autoBindNearest()
	self:sv_relayControls()
	self.sv.wasDriving = true
end

-- Broken props but a working camera stays linked, key 0 unlinks it
function FpvController:sv_autoUnbindCheck()
	self:sv_wreckBackstop()
	if self.sv.drone then
		local e = VSFPV_LINK.drones[self.sv.drone]
		local gone = (not e) or (not sm.exists(self.sv.drone))
		if gone or e.camDead then
			if e and e.exploded and sm.exists(self.sv.drone) then
				self.sv.wreck = self.sv.drone
				self.sv.wreckTicks = WRECK_BACKSTOP_TICKS
			end
			self:sv_release(true)
		end
	end
end

-- The drone removes itself after exploding, unless its script stopped. Then the seat does it
function FpvController:sv_wreckBackstop()
	local wreck = self.sv.wreck
	if not wreck then
		return
	end
	if not sm.exists(wreck) then
		self.sv.wreck = nil
		return
	end
	self.sv.wreckTicks = self.sv.wreckTicks - 1
	if self.sv.wreckTicks > 0 then
		return
	end
	self.sv.wreck = nil
	wreck:getBody():setDestructable(true) -- armed warheads are indestructible
	-- The drone's own teardown may have queued it for removal this tick already
	try("wreck backstop destroyPart", function()
		sm.shape.destroyPart(wreck)
	end)
	if sm.exists(wreck) then
		try("wreck backstop destroyShape", function()
			wreck:destroyShape()
		end)
	end
	log(
		"det",
		"SEAT backstop fired on an exploded wreck the drone never removed, still present: %s",
		tostring(sm.exists(wreck))
	)
end

function FpvController:sv_telemetry(dt, driver)
	if not DEBUG_LOG.flight then
		return
	end
	self.sv.telem = self.sv.telem + dt
	if self.sv.telem >= TELEM_INTERVAL then
		self.sv.telem = 0.0
		log(
			"flight",
			"CTRL driver=%s WASD=%d%d%d%d alt=%+d drone=%s",
			tostring(driver ~= nil),
			self.sv.fwd and 1 or 0,
			self.sv.back and 1 or 0,
			self.sv.left and 1 or 0,
			self.sv.right and 1 or 0,
			(self.sv.climb and 1 or 0) - (self.sv.descend and 1 or 0),
			tostring(self.sv.drone ~= nil)
		)
	end
end

-- Keep the link, zero the input, the drone flies on by itself
function FpvController:sv_handleEmptySeat()
	self:sv_clearKeys()
	local e = self:sv_claimedEntry()
	if e then
		e.inThrottle, e.inYaw, e.altCmd = 0.0, 0.0, 0.0
	end
	self.sv.bindExclude = nil
	self.sv.wasDriving = false
end

function FpvController:sv_autoBindNearest()
	if self.sv.drone then
		return
	end
	local cp = self.shape:getWorldPosition()
	local best, bestd = nil, PAIR_RADIUS
	for shp, e in pairs(VSFPV_LINK.drones) do
		if e.claimedBy == nil and not e.broken and sm.exists(shp) and shp ~= self.sv.bindExclude then
			local d = (shp:getWorldPosition() - cp):length()
			if d < bestd then
				best, bestd = shp, d
			end
		end
	end
	if best then
		local e = VSFPV_LINK.drones[best]
		setClaim(e, self.shape)
		self.sv.drone = best
		self.sv.bindExclude = nil
		self:sv_clearKeys()
		self.network:sendToClients("cl_bind", {
			drone = best,
			mode = e.mode,
			name = e.name,
			zoomMax = e.zoomMax,
			visionModes = e.visionModes,
			horizonOsd = e.horizonOsd,
			analogCam = e.analogCam,
			subMeshes = e.subMeshes,
			camOffset = e.camOffset,
		})
		log("general", "drone linked (%.1f m)", bestd)
	elseif not self.sv.wasDriving then
		log("general", "no free FPV drone within range")
	end
end

function FpvController:sv_relayControls()
	if not self.sv.drone then
		return
	end
	local e = VSFPV_LINK.drones[self.sv.drone]
	if not e then
		return
	end
	e.claimedBy = self.shape
	e.inThrottle = (self.sv.fwd and 1.0 or 0.0) - (self.sv.back and 1.0 or 0.0)
	e.inYaw = (self.sv.right and 1.0 or 0.0) - (self.sv.left and 1.0 or 0.0)
	-- LMB/RMB: altitude on the Mavic, throttle on ACRO
	e.altCmd = (self.sv.climb and 1.0 or 0.0) - (self.sv.descend and 1.0 or 0.0)

	-- About 13 times a second, integers to keep it small
	self.sv.osdTick = self.sv.osdTick + 1
	if self.sv.osdTick >= OSD_EVERY then
		self.sv.osdTick = 0
		self.network:sendToClients("cl_osd", {
			s = math.floor(e.spd * 3.6 + 0.5), -- km/h
			a = math.floor(e.alt + 0.5), -- above where it was linked
			t = math.floor(e.rpm * 100.0 + 0.5), -- throttle %
			m = e.modeName, -- CINE/NORMAL/SPORT, nil for ACRO
			g = e.gimbalScale,
			rth = e.rthActive,
			hd = math.floor(e.homeDist + 0.5),
			hmsg = e.homeMsg,
			hq = e.homeMsgSeq,
		})
	end
end

-- Client

function FpvController:client_onCreate()
	self.cl = {
		drone = nil,
		mode = nil, -- "acro" or "angle"
		camPitch = 0.0, -- Mavic, 0 = straight ahead
		horizonLock = HORIZON_LOCK_DEFAULT,
		horizonLockByDrone = {}, -- shape id -> last key 6 setting for that drone
		gimbalScale = 1.0,
		rthActive = false,
		notifySeq = nil, -- see cl_osd
		notifyText = "",
		notifyFrames = 0,

		active = false,
		releaseFrames = 0, -- see cl_idleCameraRetry
		seatGuardFrames = 0, -- or the E that seated you gets you straight out
		camPos = sm.vec3.new(0, 0, 0),
		camRot = sm.quat.identity(),
		zoomMax = nil,
		zoom = 1.0,
		zoomTarget = 1.0,
		visionModes = nil,
		horizonOsd = nil,
		analogCam = nil,
		analogGui = nil,
		analogClock = 0.0,
		analogGap = 0.0,
		analogGlitch = nil,
		analogShown = {}, -- widget name -> frame currently shown
		analogStatic = 0.0, -- seconds
		throttle = 0,
		subMeshes = nil,
		camOffset = nil, -- nil = CAM_OFFSET
		hiddenAirframe = nil, -- { drone, subMeshes } we're currently hiding
		horizon = nil,
		horizonBroken = false,
		visionMode = 0, -- 0 = normal, 1 = night vision
		nvLive = false,
		nvBroken = false,
		nvFogLost = false,
		nvRange = nil,
		filming = false, -- key 5
		visionGui = nil,
		gui = nil, -- OSD
		helpGui = nil,
		helpOpen = true,
		txHeld = nil, -- transmitter model in the pilot's hands
	}
	log("general", "Controller CL created")
end

local function restoreDefaultCamera()
	sm.camera.setCameraState(sm.camera.state.default)
end

function FpvController:client_onDestroy()
	self:cl_stopHeldTransmitter()
	self:cl_closeHud()
	self:cl_closeHelp()
	self:cl_destroyVision()
	self:cl_destroyHorizon()
	self:cl_closeAnalog()
	-- The blast can take the transmitter too, then nothing else gives the camera back
	if self.cl.active then
		self.cl.active = false
		self:cl_updateAirframe(nil)
		restoreDefaultCamera()
		if self.cl.filming then
			self:cl_setFilming(false)
		end
	end
end

function FpvController:cl_bind(data)
	self.cl.drone = data.drone
	self.cl.mode = data.mode
	self.cl.droneName = data.name
	self.cl.zoomMax = data.zoomMax
	self.cl.zoom, self.cl.zoomTarget = 1.0, 1.0
	self.cl.visionModes = data.visionModes
	self.cl.horizonOsd = data.horizonOsd
	if data.lost then
		self:cl_analogCameraLost() -- before analogCam gets overwritten
	end
	self.cl.analogCam = data.analogCam
	self.cl.subMeshes = data.subMeshes
	self.cl.camOffset = data.camOffset
	self.cl.visionMode = 0
	local remembered = data.drone and self.cl.horizonLockByDrone[data.drone.id]
	if remembered == nil then
		remembered = HORIZON_LOCK_DEFAULT
	end
	self.cl.horizonLock = remembered
	self:cl_applyVision()
	-- An unbind has no model and leaves it as it is
	if data.name then
		self.cl.helpOpen = not self:cl_helpHidden(data.name)
		if self.cl.active then
			self:cl_syncHelp()
		end
	end
	self.cl.notifySeq = nil
	self:cl_applyOsdMode()
	self:cl_applyHelp()
end

-- The game won't seat anyone in a scripted part by itself
function FpvController:client_canInteract(character)
	sm.gui.setInteractionText("", sm.gui.getKeyBinding("Use", true), "Sit in FPV Controller")
	return true
end

function FpvController:client_onInteract(character, state)
	if not state then
		return
	end
	self.interactable:setSeatCharacter(character)
	self.cl.seatGuardFrames = SEAT_GUARD_FRAMES
end

function FpvController:cl_isDriver()
	local me = sm.localPlayer.getPlayer()
	if not me then
		return false
	end
	local myChar = me.character
	if not myChar then
		return false
	end
	return self.interactable:getSeatCharacter() == myChar
end

-- Built on first use, sm.interactable.actions can't be read at load time. create = LMB, attack = RMB
local heldInputField
do
	local fieldOf = nil
	heldInputField = function(action)
		if not fieldOf then
			local actions = sm.interactable.actions
			fieldOf = {
				[actions.forward] = "fwd",
				[actions.backward] = "back",
				[actions.left] = "left",
				[actions.right] = "right",
				[actions.create] = "climb",
				[actions.attack] = "descend",
			}
		end
		return fieldOf[action]
	end
end

-- true = key used, no hotbar slot. Keys that don't apply return false and stay hotbar keys
-- item0 is the "1" key
function FpvController:client_onAction(action, state)
	local actions = sm.interactable.actions
	local held = heldInputField(action)
	if held then
		self.network:sendToServer("sv_input", { [held] = state })
		return true
	end
	-- 1/2/3 Mavic flight modes
	local modeIdx = (action == actions.item0 and 1) or (action == actions.item1 and 2) or (action == actions.item2 and 3)
	if modeIdx then
		if self.cl.mode == "angle" then
			if state then
				self.network:sendToServer("sv_setMode", { idx = modeIdx })
			end
			return true
		end
		return false
	-- 4 return to home
	elseif action == actions.item3 then
		if self.cl.mode == "angle" then
			if state then
				self.network:sendToServer("sv_rthKey")
			end
			return true
		end
		return false
	-- 5 filming, whole HUD hidden
	elseif action == actions.item4 then
		if self.cl.active then
			if state then
				self:cl_setFilming(not self.cl.filming)
			end
			return true
		end
		return false
	-- 6 horizon lock, Mavic only. On ACRO the camera is bolted on and the tilt is what you fly by
	elseif action == actions.item5 then
		if self.cl.active and self.cl.mode == "angle" then
			if state then
				self.cl.horizonLock = not self.cl.horizonLock
				if self.cl.drone then
					self.cl.horizonLockByDrone[self.cl.drone.id] = self.cl.horizonLock
				end
				self:cl_notify(self.cl.horizonLock and "HORIZON LOCK ON" or "HORIZON LOCK OFF")
				log("general", "horizon lock " .. (self.cl.horizonLock and "on" or "off"))
			end
			return true
		end
		return false
	-- 7 invert pitch, ACRO only (mouse Y moves the Mavic camera)
	elseif action == actions.item6 then
		if self.cl.active and self.cl.mode ~= "angle" then
			if state then
				self:cl_togglePitchInverted()
			end
			return true
		end
		return false
	-- 8 night vision
	elseif action == actions.item7 then
		if self.cl.active and self.cl.visionModes then
			if state then
				self.cl.visionMode = (self.cl.visionMode + 1) % 2
				self:cl_applyVision()
			end
			return true
		end
		return false
	-- 9 controls help
	elseif action == actions.item8 then
		if not self.cl.active then
			return false
		end
		if state then
			self.cl.helpOpen = not self.cl.helpOpen
			self:cl_syncHelp()
			self:cl_setHelpHidden(self.cl.droneName, not self.cl.helpOpen)
		end
		return true
	-- 0 next drone
	elseif action == actions.item9 then
		if state then
			self.network:sendToServer("sv_unbindManual")
		end
		return true
	-- Wheel: zoom where the drone has it, otherwise throttle on ACRO. zoomIn is the wheel pushed away
	elseif action == actions.zoomIn or action == actions.zoomOut then
		if self.cl.active and self.cl.zoomMax and self.cl.zoomMax > 1.0 then
			if state then
				local step = (action == actions.zoomIn) and ZOOM_STEP or -ZOOM_STEP
				self.cl.zoomTarget = math.max(1.0, math.min(self.cl.zoomMax, self.cl.zoomTarget + step))
			end
			return true
		end
		if self.cl.active and self.cl.mode ~= "angle" then
			if state then
				self.network:sendToServer("sv_throttleStep", { n = (action == actions.zoomIn) and 1 or -1 })
			end
			return true
		end
		return false
	elseif action == actions.jump then
		if state then
			self.network:sendToServer("sv_exit")
		end
		return true
	elseif action == actions.use then
		if state and self.cl.seatGuardFrames <= 0 and self:cl_isDriver() then
			self.network:sendToServer("sv_exit")
			return true
		end
		return false
	end
	return false
end

function FpvController:cl_releaseCamera()
	self.cl.active = false
	self.cl.releaseFrames = CAM_RELEASE_RETRY
	self:cl_closeHud() -- also brings the hotbar back
	self:cl_closeHelp()
	self.cl.visionMode = 0
	self:cl_closeVision()
	self:cl_hideHorizon()
	if self.cl.filming then
		self:cl_setFilming(false)
	end
	restoreDefaultCamera()
end

function FpvController:client_onUpdate(dt)
	if self.cl.seatGuardFrames > 0 then
		self.cl.seatGuardFrames = self.cl.seatGuardFrames - 1
	end

	self:cl_updateTransmitterVisuals()
	self:cl_updateNotifyTimer()

	local drone = self.cl.drone
	local canFly = self:cl_canFly(drone)
	self:cl_updatePilotingState(drone, canFly)
	self:cl_updateAirframe(drone)
	self:cl_stepAnalog(dt) -- the static runs on after the flight ends
	if not self.cl.active then
		self:cl_stopNightRender()
		self:cl_hideHorizon()
		self:cl_idleCameraRetry()
		return
	end

	self:cl_relayMouseInput()
	self:cl_updateFpvCamera(dt, drone)
	self:cl_stepHorizon() -- after the camera moves
	if self.cl.nvLive then
		self:cl_stepNightRender()
	end
	self:cl_updateZoomOsd()
end

-- setSubMeshVisible is client only, and the drone may be gone already
local function setAirframeVisible(drone, subMeshes, visible)
	if not sm.exists(drone) then
		return
	end
	local i = drone.interactable
	for _, name in ipairs(subMeshes) do
		i:setSubMeshVisible(name, visible)
	end
end

-- The drone you fly would show up in front of your own camera
function FpvController:cl_updateAirframe(drone)
	local hidden = self.cl.hiddenAirframe
	local want = (self.cl.active and self.cl.subMeshes) and drone or nil
	if hidden and hidden.drone ~= want then
		setAirframeVisible(hidden.drone, hidden.subMeshes, true)
		self.cl.hiddenAirframe = nil
	end
	if want then
		self.cl.hiddenAirframe = self.cl.hiddenAirframe or { drone = want, subMeshes = self.cl.subMeshes }
		setAirframeVisible(want, self.cl.subMeshes, false)
	end
end

-- Reading a destroyed shape can throw and freeze the camera
local function droneExists(drone)
	return drone ~= nil and sm.exists(drone)
end

function FpvController:cl_canFly(drone)
	return droneExists(drone) and self:cl_isDriver()
end

-- (right, at, up)
function FpvController:cl_toPartFrame(world)
	local d = world - self.shape:getWorldPosition()
	local rot = self.shape:getWorldRotation()
	return sm.vec3.new(d:dot(sm.quat.getRight(rot)), d:dot(sm.quat.getAt(rot)), d:dot(sm.quat.getUp(rot)))
end

-- getTpBonePos ignores the ragdoll pose, so this is a fixed spot near the hands
function FpvController:cl_handMidpoint(character)
	local l = character:getTpBonePos("jnt_left_hand")
	local r = character:getTpBonePos("jnt_right_hand")
	if not (l and r) then
		return nil
	end
	local p = self:cl_toPartFrame((l + r) * 0.5)
	-- Unknown joint names return the origin, no error
	if p:length() < 0.01 then
		return nil
	end
	-- Effect offsets are Y-up, the part frame is Z-up
	return sm.vec3.new(p.x, p.z, p.y)
end

function FpvController:cl_stopHeldTransmitter()
	if self.cl.txHeld ~= nil then
		self.cl.txHeld:stop()
		self.cl.txHeld = nil
	end
end

-- Seated: the part hides with a pose and an effect copy sits in the pilot's hands
function FpvController:cl_updateTransmitterVisuals()
	local seated = self.interactable:getSeatCharacter()

	self.interactable:setPoseWeight(TX_POSE, (seated ~= nil) and 1.0 or 0.0)

	if seated == nil then
		self:cl_stopHeldTransmitter()
		return
	end

	if self.cl.txHeld == nil then
		local fx = sm.effect.createEffect(TX_HELD_EFFECT, self.interactable)
		fx:setScale(sm.vec3.new(TX_SCALE, TX_SCALE, TX_SCALE))
		fx:setOffsetRotation(TX_HELD_ROT)
		fx:start()
		self.cl.txHeld = fx
	end
	-- Every frame, the character settles for a moment after sitting down
	self.cl.txHeld:setOffsetPosition((self:cl_handMidpoint(seated) or TX_HELD_FALLBACK) + TX_HELD_NUDGE)
end

-- Up from worldRotation directly, CAM_FIX stays out of it
function FpvController:cl_lensPosition(drone, noseRot)
	local off = self.cl.camOffset or CAM_OFFSET
	return drone:getWorldPosition() + sm.quat.getUp(noseRot) * off.fwd + sm.quat.getUp(drone.worldRotation) * off.up
end

function FpvController:cl_updatePilotingState(drone, canFly)
	if canFly and not self.cl.active then
		local rot0 = noseFrame(drone.worldRotation * CAM_FIX)
		self.cl.camPos = self:cl_lensPosition(drone, rot0)
		self.cl.camRot = rot0
		self.cl.active = true
		self.cl.releaseFrames = 0
		self.cl.camPitch = 0.0
		self.cl.zoom, self.cl.zoomTarget = 1.0, 1.0
		self:cl_openHud()
		if self.cl.helpOpen then
			self:cl_openHelp()
		end
		log("general", "piloting: W/S = throttle   A/D = yaw   mouse = pitch/roll   (exit the seat to stop)")
	elseif (not canFly) and self.cl.active then
		-- The drone can vanish here before the unbind arrives, the static still has to show
		if drone ~= nil and not droneExists(drone) then
			self:cl_analogCameraLost()
		end
		self:cl_releaseCamera()
		log("general", "piloting ended")
	end
end

-- One call can get lost (the player dying in the same blast) and the camera sticks until a reload
function FpvController:cl_idleCameraRetry()
	if self.cl.releaseFrames > 0 then
		self.cl.releaseFrames = self.cl.releaseFrames - 1
		restoreDefaultCamera()
	end
end

function FpvController:cl_relayMouseInput()
	local dx, dy = sm.localPlayer.getMouseDelta()
	if self.cl.mode == "angle" then
		-- The autopilot steers during RTH, looking up and down still works
		if dx ~= 0 and not self.cl.rthActive then
			self.network:sendToServer("sv_look", { x = dx, y = 0 })
		end
		if dy ~= 0 then
			self.cl.camPitch = math.max(
				GIMBAL_MIN,
				math.min(GIMBAL_MAX, self.cl.camPitch + dy * GIMBAL_GAIN * GIMBAL_SIGN * self.cl.gimbalScale)
			)
			self.network:sendToServer("sv_gimbal", { p = self.cl.camPitch })
		end
	elseif dx ~= 0 or dy ~= 0 then
		if self:cl_prefs().pitchInverted then
			dy = -dy -- here, so each pilot keeps their own setting
		end
		self.network:sendToServer("sv_look", { x = dx, y = dy })
	end
end

-- Whatever throws in here, the camera still has to go back to the player
function FpvController:cl_updateFpvCamera(dt, drone)
	local ok, err = pcall(function()
		local targetRot = noseFrame(drone.worldRotation * CAM_FIX)
		-- Before the tilt, or the offset swings around
		local targetPos = self:cl_lensPosition(drone, targetRot)
		-- Horizon lock: drone up back to world up, heading untouched. Up is getAt of the rotated frame,
		-- the raw worldRotation is 90 degrees off because of CAM_FIX. Skipped near vertical so it can't flip
		if self.cl.mode == "angle" and self.cl.horizonLock then
			local bodyUp = sm.quat.getAt(targetRot)
			local upDot = bodyUp:dot(UP)
			if math.abs(upDot) > HORIZON_LOCK_MIN_UP then
				if upDot < 0.0 then
					bodyUp = bodyUp * -1.0
				end
				targetRot = sm.vec3.getRotation(bodyUp, UP) * targetRot
			end
		end
		if self.cl.mode == "angle" and self.cl.camPitch ~= 0.0 then
			targetRot = targetRot * sm.quat.angleAxis(self.cl.camPitch, sm.vec3.new(1, 0, 0))
		end
		local step = 1.0 - math.exp(-CAM_LERP * dt)
		self.cl.camPos = self.cl.camPos + (targetPos - self.cl.camPos) * step
		self.cl.camRot = sm.quat.slerp(self.cl.camRot, targetRot, step)
		-- On tan(fov) like a real lens, dividing the fov feels wrong at high zoom
		local zstep = 1.0 - math.exp(-ZOOM_LERP * dt)
		self.cl.zoom = self.cl.zoom + (self.cl.zoomTarget - self.cl.zoom) * zstep
		local fov = math.deg(2.0 * math.atan(math.tan(math.rad(FOV_BASE * 0.5)) / self.cl.zoom))
		sm.camera.setCameraState(3)
		sm.camera.setPosition(self.cl.camPos)
		sm.camera.setRotation(self.cl.camRot)
		sm.camera.setFov(fov)
	end)
	if not ok then
		fault("FPV camera", err)
		if not droneExists(drone) then
			self:cl_analogCameraLost()
		end
		self:cl_releaseCamera()
		log("general", "piloting ended (drone lost)")
	end
end
