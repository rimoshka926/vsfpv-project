-- One class for all three drones. The pilot sits in the transmitter (fpv_controller.lua), which
-- writes the input into VSFPV_LINK.drones, and the drone reads it every tick.
-- The part is mounted pitched 90 degrees, so getUp() is the nose

-- Bump per release. Never touch "version" in description.json, that's the game's content version
-- and a higher one makes the game refuse the mod
local VERSION = "1.4"
print("[VSFPV] " .. VERSION)

dofile("$CONTENT_DATA/Scripts/fpv_config.lua")
dofile("$CONTENT_DATA/Scripts/fpv_frame.lua")
dofile("$CONTENT_DATA/Scripts/fpv_diag.lua")

FpvDrone = class()

-- Shared by every VSFPV part on the server, either one may load first
VSFPV_LINK = VSFPV_LINK or {}
VSFPV_LINK.drones = VSFPV_LINK.drones or {}
-- Parts the jet went through, waiting to see if they blow up on their own
VSFPV_LINK.carveQueue = VSFPV_LINK.carveQueue or {}

dofile("$CONTENT_DATA/Scripts/fpv_drone_warhead.lua")
dofile("$CONTENT_DATA/Scripts/fpv_drone_rth.lua")
dofile("$CONTENT_DATA/Scripts/fpv_drone_sound.lua")
dofile("$CONTENT_DATA/Scripts/fpv_drone_flight.lua")

local THRUST = VSFPV_CFG.THRUST
local ACRO = VSFPV_CFG.ACRO
local ANGLE = VSFPV_CFG.ANGLE
local MASK = VSFPV_CFG.MASK
local WARHEAD = VSFPV_CFG.WARHEAD
local WATER = VSFPV_CFG.WATER
local CRASH = VSFPV_CFG.CRASH
local FLOOR = VSFPV_CFG.FLOOR
local DRONES = VSFPV_CFG.DRONES
local GIMBAL_MIN = VSFPV_CFG.GIMBAL_MIN
local GIMBAL_MAX = VSFPV_CFG.GIMBAL_MAX
local DEBUG_LOG = VSFPV_CFG.DEBUG_LOG
local FLIGHT_DIAG_EVERY = VSFPV_CFG.FLIGHT_DIAG_EVERY
local TELEM_INTERVAL = VSFPV_CFG.TELEM_INTERVAL

local UP = VSFPV_FRAME.UP
local CAM_FIX = VSFPV_FRAME.CAM_FIX
local NOSE_SIGN = VSFPV_FRAME.NOSE_SIGN
local clamp = VSFPV_FRAME.clamp
local log = VSFPV_DIAG.log
local try = VSFPV_DIAG.try
-- Not cfg[key] or dflt, that loses an explicit false
local function pick(cfg, key, dflt)
	local v = cfg[key]
	if v == nil then
		return dflt
	end
	return v
end

-- Server

function FpvDrone:server_onCreate()
	self.cfg = DRONES[tostring(self.shape:getShapeUuid())]
	local cfg = self.cfg
	self.tune = {
		twrMax = pick(cfg, "twrMax", THRUST.TWR_MAX),
		dragCdA = pick(cfg, "dragCdA", THRUST.DRAG_CD_A), -- when dragAniso is off
		dragAniso = pick(cfg, "dragAniso", false), -- per-axis drag, PG-7
		dragAxial = pick(cfg, "dragAxial", THRUST.DRAG_AXIAL),
		dragFrontal = pick(cfg, "dragFrontal", THRUST.DRAG_FRONTAL),
		dragLateral = pick(cfg, "dragLateral", THRUST.DRAG_LATERAL),
		rotorDiskA = pick(cfg, "rotorDiskA", THRUST.ROTOR_DISK_A),
		rotorRadius = pick(cfg, "rotorRadius", THRUST.ROTOR_RADIUS),
		maxPrRate = pick(cfg, "maxPrRate", ACRO.MAX_PR_RATE),
		prTau = pick(cfg, "prTau", 0.0), -- smoothing on mouse pitch/roll, 0 = off
		rateKp = pick(cfg, "rateKp", ACRO.RATE_KP),
		maxAngAcc = pick(cfg, "maxAngAcc", ACRO.MAX_ANG_ACC),
		crashPropsSpeed = pick(cfg, "crashPropsSpeed", CRASH.PROPS_SPEED),
		crashKillSpeed = pick(cfg, "crashKillSpeed", CRASH.KILL_SPEED),
		crashDestroySpeed = pick(cfg, "crashDestroySpeed", CRASH.DESTROY_SPEED),
	}
	self.angleModes = cfg.angleModes -- nil on ACRO
	self.angleModeIdx = cfg.angleModeDefault or 1
	self.sv = {
		piloted = false, -- linked to a seat
		throttle = 0.0, -- commanded, 0..1
		rpm = 0.0, -- actual, lags behind throttle
		yawCmd = 0.0, -- rad/s
		heldHeading = nil, -- Mavic, nil until captured
		yawIdle = 0.0, -- seconds since the last turn
		rollCmd = 0.0,
		pitchCmd = 0.0,
		flightT = 0.0,
		flightTick = 0,
		flightVPrev = 0.0,
		propSign = 1.0, -- see sv_captureFrame
		homeZ = 0.0, -- OSD altitude is relative to this
		armed = false, -- never cleared
		exploded = false,
		detonateDelay = 0, -- see sv_detonate
		rpmTick = 0,
		levelTimer = 0.0, -- auto-level after takeoff
		targetAlt = 0.0,
		broken = false, -- props broken, stays in the world
		camDead = false,
		smashed = false,
		smashTicks = 0,
		drowned = false,
		drownPending = false, -- handled next tick
		drownTicks = 0,
		destroyed = false, -- see sv_destroySelf
		destroyTries = 0,
		floorPrevPos = nil, -- sv_terrainFloor
		floorTunnel = false, -- went through the ground, still correcting
		waterTick = 0,
		waterProbe = nil,
		telem = 0.0,
		-- RTH, kept here so it carries on when the pilot leaves the seat
		homeSet = false,
		homeMsg = nil,
		homeMsgSeq = 0,
		homePos = nil,
		rth = {
			tapCount = 0,
			tapLast = -1000,
			reqSeen = 0,
			active = false,
			phase = "cruise", -- "cruise" towards home, then "descend"
			dir = nil,
			el = 0.0, -- degrees, > 0 goes over something
			scanT = 0.0,
			climbVz = 0.0,
			-- wall following once it stops getting closer, reset in sv_rthToggle
			state = "seek", -- or "follow"
			bestDist = 1e9,
			stuckT = 0.0,
			followHand = 1, -- wall on the right (1) or left (-1)
			followDist = 0.0,
			followEntry = nil,
			followT = 0.0,
			leanFwd = 0.0, -- -1..1, negative brakes
			leanRight = 0.0,
		},
	}
	self:sv_attachWaterProbe()
	VSFPV_LINK.drones[self.shape] = {
		claimedBy = nil, -- controller shape, nil = free
		inThrottle = 0.0, -- W/S, -1..1
		inYaw = 0.0, -- A/D, -1..1
		lookX = 0.0, -- summed by the controller
		lookY = 0.0,
		altCmd = 0.0, -- LMB/RMB
		throttleSteps = 0, -- wheel notches from the seat
		rpm = 0.0, -- the rest is for the OSD
		spd = 0.0,
		alt = 0.0,
		mode = self.cfg.mode,
		name = self.cfg.shortName or self.cfg.name,
		zoomMax = self.cfg.zoomMax,
		visionModes = self.cfg.visionModes,
		horizonOsd = self.cfg.horizonOsd,
		analogCam = self.cfg.analogCam,
		subMeshes = self.cfg.subMeshes, -- meshes the pilot doesn't see in flight
		camOffset = self.cfg.camOffset,
		angleModeIdx = self.angleModeIdx,
		modeName = self.angleModes and self.angleModes[self.angleModeIdx].name or nil,
		gimbalScale = self.angleModes and self.angleModes[self.angleModeIdx].gimbalScale or 1.0,
		camPitch = 0.0,
		broken = false, -- can't be linked again
		camDead = false,
		rthReq = 0, -- bumped on key 4
		rthActive = false,
		homeSet = false,
		homeMsg = nil,
		homeMsgSeq = 0,
		homeDist = 0.0,
	}
	log("general", "Drone SV created + registered")
end

function FpvDrone:sv_attachWaterProbe()
	self.sv.waterProbe = sm.areaTrigger.createAttachedBox(
		self.interactable,
		sm.vec3.new(WATER.PROBE_HALF, WATER.PROBE_HALF, WATER.PROBE_HALF),
		nil,
		nil,
		sm.areaTrigger.filter.areaTrigger
	)
	self.sv.waterProbe:bindOnStay("sv_onWaterStay", self)
	log("water", "water probe created + bound")
end

function FpvDrone:sv_syncAngleMode(e)
	if not (self.angleModes and e) then
		return
	end
	local idx = math.floor(e.angleModeIdx)
	if idx < 1 then
		idx = 1
	elseif idx > #self.angleModes then
		idx = #self.angleModes
	end
	self.angleModeIdx = idx
	e.angleModeIdx = idx
	e.modeName = self.angleModes[idx].name
	e.gimbalScale = self.angleModes[idx].gimbalScale
end

-- Comes before server_onDestroy when the chunk unloads, so a drone that flew away is saved, not blown up.
-- Vanilla Prospector.lua keeps its loot the same way
function FpvDrone:server_onUnload()
	self.sv.unloaded = true
end

function FpvDrone:server_onDestroy()
	-- Something removed it some other way (mod weapons), plain blast at the last position, no jet
	if
		self.sv
		and not self.sv.unloaded
		and self.cfg
		and self.cfg.warhead
		and not self.sv.exploded
		and not self.sv.drowned
		and self.sv.armed
	then
		self.sv.exploded = true
		local pos = self.sv.lastPos
		if not pos and sm.exists(self.shape) then
			pos = self.shape:getWorldPosition()
		end
		if pos then
			-- other mods hook explode, the cleanup below has to run whatever they do
			try("detached warhead blast", function()
				sm.physics.explode(
					pos,
					WARHEAD.EXP_LEVEL,
					WARHEAD.DETACHED_DESTROY_R,
					WARHEAD.EXP_IMPULSE_R,
					WARHEAD.EXP_MAGNITUDE,
					WARHEAD.HEATJET_EFFECT
				)
			end)
		end
	end
	VSFPV_LINK.drones[self.shape] = nil
	if self.sv and self.sv.waterProbe then
		-- an attached trigger can go together with its host
		if sm.exists(self.sv.waterProbe) then
			sm.areaTrigger.destroy(self.sv.waterProbe)
		end
		self.sv.waterProbe = nil
	end
end

-- Tiers: 1 props broken, 2 camera dead too, 3 removed. Only ever goes up
function FpvDrone:sv_crash(atPos, tier)
	local e = VSFPV_LINK.drones[self.shape]
	atPos = atPos or self.shape:getWorldPosition()
	local changed = false
	if not self.sv.broken then
		self.sv.broken = true
		self.sv.throttle = 0.0
		if e then
			e.broken = true
		end
		changed = true
	end
	if tier >= 2 and not self.sv.camDead then
		self.sv.camDead = true
		if e then
			e.camDead = true
		end
		changed = true
	end
	if tier >= 3 and not self.sv.smashed then
		self.sv.smashed = true
		self.sv.smashTicks = CRASH.SMASH_TICKS
		changed = true
	end
	if changed then
		self.network:sendToClients("cl_crash", { pos = atPos, tier = tier })
	end
end

function FpvDrone:sv_crashOnImpact(impact, atPos)
	if impact >= self.tune.crashDestroySpeed then
		self:sv_crash(atPos, 3)
	elseif impact >= self.tune.crashKillSpeed then
		self:sv_crash(atPos, 2)
	elseif impact >= self.tune.crashPropsSpeed then
		self:sv_crash(atPos, 1)
	end
end

-- Below the speed floor plain collisions are enough, and a slow drone skimming a wall must not break
function FpvDrone:sv_sweepAhead(dt, ctx, prox, mask)
	local speed = ctx.v:length()
	if speed < prox.PROX_MIN_SPEED then
		return false
	end
	local dir = ctx.v / speed
	local to = ctx.pos + dir * (speed * dt + prox.PROX_STANDOFF)
	local hit, r = sm.physics.spherecast(ctx.pos, to, prox.PROX_RADIUS, self.shape, mask)
	return hit, r, speed
end

-- Collisions are checked once per tick and the DJI FPV moves about a metre per tick flat out, so it
-- can skip a wall or bounce off before server_onCollision says anything. Spherecast ahead instead
function FpvDrone:sv_crashProximity(dt, ctx)
	if self.cfg.warhead then
		return -- sv_warheadProximity
	end
	local hit, r, speed = self:sv_sweepAhead(dt, ctx, CRASH, MASK.SOLID)
	if not hit then
		return
	end
	local n = r and r.normalWorld
	local impact = (n and math.abs(ctx.v:dot(n))) or speed
	self:sv_crashOnImpact(impact, (r and r.pointWorld) or ctx.pos)
end

-- Same for the warhead: under load a fast PG-7 can bounce off without exploding, or go off late with
-- the nose already tipped up. A tick early the jet still points where the nose does
function FpvDrone:sv_warheadProximity(dt, ctx)
	if not self.cfg.warhead then
		return false
	end
	if not self.sv.armed or self.sv.exploded then
		return false
	end
	local hit, res = self:sv_sweepAhead(dt, ctx, WARHEAD, MASK.SOLID_CHAR)
	if hit then
		self:sv_detonate(res and res.pointWorld)
		return true
	end
	return false
end

-- A freshly placed drone is safe to build with: warheads need arming, the others a link
function FpvDrone:server_onCollision(other, collisionPosition, selfPointVelocity, otherPointVelocity, collisionNormal)
	if self:sv_ignoresHits() then
		return
	end
	if self.cfg.warhead then
		if not self.sv.armed then
			return
		end
		local t = type(other)
		if t == "Shape" or t == "Body" or t == "Character" then
			self:sv_detonate(collisionPosition)
			return
		end
		local closing = (selfPointVelocity - otherPointVelocity):length()
		if closing >= WARHEAD.IMPACT_SPEED then
			self:sv_detonate(collisionPosition)
		end
		return
	end
	if self.sv.smashed then
		return
	end
	if not (self.sv.piloted or self.sv.broken) then
		return
	end
	if not (selfPointVelocity and otherPointVelocity and collisionNormal) then
		return
	end
	local impact = math.abs((selfPointVelocity - otherPointVelocity):dot(collisionNormal))
	self:sv_crashOnImpact(impact, collisionPosition)
end

function FpvDrone:sv_ignoresHits()
	return self.sv.destroyed or not sm.exists(self.shape) or self.sv.exploded or self.sv.drowned
end

-- A never linked drone is removed outright, so a gun clears a parked one
function FpvDrone:server_onProjectile(
	hitPos,
	hitTime,
	hitVelocity,
	_,
	attacker,
	damage,
	userData,
	hitNormal,
	projectileUuid
)
	self:sv_struck(hitPos)
end

function FpvDrone:server_onMelee(hitPos, attackingCharacter, damage, power, hitDirection)
	self:sv_struck(hitPos)
end

function FpvDrone:sv_struck(hitPos)
	if self:sv_ignoresHits() then
		return
	end
	if self.cfg.warhead and self.sv.armed then
		self:sv_detonate(hitPos)
	elseif not self.sv.smashed then
		self:sv_crash(hitPos, (self.sv.piloted or self.sv.broken) and 2 or 3)
	end
end

-- The prop axis sign is unknown, but at link time the drone stands on its legs, so up has z > 0
function FpvDrone:sv_captureFrame()
	local pu = sm.quat.getAt(self.shape.worldRotation * CAM_FIX)
	self.sv.propSign = (pu.z < 0.0) and -1.0 or 1.0
end

-- A shaped charge fires where it points, whichever way the drone drifts
function FpvDrone:sv_noseAxis()
	return (sm.quat.getUp(self.shape.worldRotation * CAM_FIX) * NOSE_SIGN):normalize()
end

function FpvDrone:sv_propAxis()
	return (sm.quat.getAt(self.shape.worldRotation * CAM_FIX) * self.sv.propSign):normalize()
end

-- Only thrust * cos(tilt) holds it up, so hover throttle rises with the lean or it sinks while moving
function FpvDrone:sv_tiltHover()
	local cosT = clamp(self:sv_propAxis():dot(UP), ANGLE.ALT_TILT_MIN, 1.0)
	return (1.0 / math.sqrt(self.tune.twrMax)) / math.sqrt(cosT)
end

local function anyWater(contents)
	for _, c in ipairs(contents) do
		local ud = sm.exists(c) and c:getUserData() -- a blast can take a listed trigger with its drone
		if type(ud) == "table" and ud.water then
			return true
		end
	end
	return false
end

-- Vanilla water triggers carry a water field in userData. Fires where getContents misses the water
function FpvDrone:sv_onWaterStay(trigger, results)
	if self.sv.drownPending or self.sv.drowned then
		return
	end
	if results and anyWater(results) then
		self.sv.drownPending = true
		log("water", "onStay detected water -> drown")
	end
end

function FpvDrone:sv_inWater()
	if not self.sv.waterProbe then
		return false
	end
	local wet = false
	-- vanilla only ever calls trigger:getContents(), this form may not exist
	try("water check", function()
		local contents = sm.areaTrigger.getContents(self.sv.waterProbe)
		if contents then
			wet = anyWater(contents)
		end
	end)
	return wet
end

-- Not body.mass: welded to a building that's the building's mass, and the thrust spins the building
local function droneMass(shape)
	local m = shape.mass
	if m == nil or m ~= m or m <= 0.0 then
		m = shape:getBody().mass
	end
	return m
end

-- nil on a NaN velocity
function FpvDrone:sv_motion()
	local body = self.shape:getBody()
	local mass = droneMass(self.shape)
	local v = body:getVelocity()
	if v:length() ~= v:length() then
		return nil
	end
	return body, mass, v
end

-- one-way push, so it doesn't fight the buoyancy and bob on the surface
function FpvDrone:sv_sink()
	local _, mass, v = self:sv_motion()
	if not v then
		return
	end
	local dvz = (v.z > WATER.SINK_VZ) and -WATER.SINK_PUSH or 0.0
	local dv = sm.vec3.new(-v.x * WATER.DAMP_KP, -v.y * WATER.DAMP_KP, dvz)
	sm.physics.applyImpulse(self.shape, dv * mass, true)
end

-- A fast dive can pass through the ground between ticks, that counts as the hit the collision missed
function FpvDrone:sv_terrainFloor(dt)
	local pos = self.shape:getWorldPosition()
	-- Before any return, so the check covers exactly one tick
	local prev = self.sv.floorPrevPos
	self.sv.floorPrevPos = pos
	local top = pos + sm.vec3.new(0, 0, FLOOR.PROBE_UP)
	local hit, res =
		sm.physics.raycast(top, top - sm.vec3.new(0, 0, FLOOR.PROBE_UP + FLOOR.PROBE_DOWN), self.shape, MASK.WORLD)
	if not hit then
		return
	end
	local depth = res.pointWorld.z - pos.z -- > 0 = under the surface
	if depth <= 0.0 or depth > FLOOR.PEN_MAX then
		self.sv.floorTunnel = false
		return
	end
	local _, mass, v = self:sv_motion()
	if not v then
		return
	end
	-- Flying under a roof looks the same, so only a surface actually crossed this tick counts
	local newlyTunnelled = false
	if not self.sv.floorTunnel then
		if v.z > -FLOOR.MIN_SINK then
			return
		end
		if not (prev and sm.physics.raycast(prev, pos, self.shape, MASK.WORLD)) then
			return -- a ceiling
		end
		self.sv.floorTunnel = true
		newlyTunnelled = true
	end
	local sink = -v.z
	if sink > 0.0 then
		sm.physics.applyImpulse(self.shape, sm.vec3.new(0, 0, sink) * mass, true)
	end
	sm.physics.applyImpulse(self.shape, sm.vec3.new(0, 0, depth * FLOOR.KP) * (mass * dt), true)
	if newlyTunnelled and sink > 0.0 then
		if self.cfg.warhead then
			if self.sv.armed and sink >= WARHEAD.IMPACT_SPEED then
				self:sv_detonate(res.pointWorld)
			end
		elseif not self.sv.smashed then
			self:sv_crashOnImpact(sink, pos)
		end
	end
end

function FpvDrone:server_onFixedUpdate(dt)
	VSFPV_LINK.sweepCarve()
	-- Before any return: mod weapons remove the part directly and server_onDestroy blasts here
	if sm.exists(self.shape) then
		self.sv.lastPos = self.shape:getWorldPosition()
	end
	if self:sv_tearDown(dt) then
		return
	end
	-- Teardowns run first, so an error in the flight code only costs this tick
	self:sv_flightTick(dt)
end

function FpvDrone:sv_flightTick(dt)
	local e = VSFPV_LINK.drones[self.shape]
	if not e then
		return
	end

	-- RTH flies on with nobody in the seat
	self:sv_rthPoll(e)
	-- before the claim check, so the home message survives the pilot leaving
	e.homeMsg, e.homeMsgSeq = self.sv.homeMsg, self.sv.homeMsgSeq

	if self:sv_syncClaim(dt, e) then
		return
	end

	local ctx = self:sv_readBody()
	if not ctx then
		return
	end

	if self:sv_warheadProximity(dt, ctx) then
		return
	end
	-- Doesn't end the tick: a drone that breaks here still runs the steps below
	self:sv_crashProximity(dt, ctx)

	self:sv_readInput(dt, e, ctx)
	self:sv_spoolRpm(dt)
	self:sv_environment(ctx)
	self:sv_applyThrust(dt, ctx)
	self:sv_applyDrag(dt, ctx)
	self:sv_applyAttitude(dt, ctx)
	self:sv_speedSafety(ctx)
	self:sv_terrainFloor(dt)
	self:sv_publishOsd(e, ctx)
	self:sv_pushClientUpdates(e)
	self:sv_telemetry(dt, e, ctx)
end

function FpvDrone:sv_tearDown(dt)
	if self.sv.exploded then
		self:sv_teardownExploded()
		return true
	end
	if self.sv.drowned then
		self:sv_teardownDrowned()
		return true
	end
	if self.sv.broken then
		self:sv_teardownBroken(dt)
		return true
	end
	if self:sv_detectDrowning() then
		return true
	end
	return false
end

-- Every removal comes through here, destroyPart on a shape that's already gone is an error
-- "Lua call buffer - call has an invalid scriptRef ... 'server_onCollision'" in the log is the engine
-- dropping a queued callback before our code runs. Harmless
function FpvDrone:sv_destroySelf()
	if self.sv.destroyed then
		return
	end
	if not sm.exists(self.shape) then
		self.sv.destroyed = true
		return
	end
	self.sv.destroyTries = self.sv.destroyTries + 1
	local destructable = self.shape:getBody().destructable
	local why = nil
	local function note(step, err)
		why = (why and why .. " | " or "") .. step .. ": " .. tostring(err)
	end
	-- destroyPart does nothing on an indestructible body, vanilla Explosive.lua checks it too
	if destructable == false then
		local ok, err = pcall(function()
			self.shape:getBody():setDestructable(true)
		end)
		if not ok then
			note("setDestructable", err)
		end
	end
	local ok, err = pcall(function()
		sm.shape.destroyPart(self.shape)
	end)
	if not ok then
		note("destroyPart", err)
	end
	if sm.exists(self.shape) and self.sv.destroyTries > 1 then
		local okShape, errShape = pcall(function()
			self.shape:destroyShape() -- what vanilla world scripts use
		end)
		if not okShape then
			note("destroyShape", errShape)
		end
	end
	-- The part goes at the end of the tick, so it still exists right after destroyPart
	self.sv.destroyed = not sm.exists(self.shape)
	if not self.sv.destroyed and self.sv.destroyTries > 1 and self.sv.destroyTries <= 6 then
		log(
			"det",
			"wreck still there after destroy try %d (destructable=%s): %s",
			self.sv.destroyTries,
			tostring(destructable),
			why or "no errors, the engine just kept it"
		)
	end
end

function FpvDrone:sv_teardownExploded()
	if self.sv.detonateDelay > 0 then
		self.sv.detonateDelay = self.sv.detonateDelay - 1
		if self.sv.detonateDelay <= 0 then
			self:sv_destroySelf()
		end
		return
	end
	if not self.sv.destroyed then
		self:sv_destroySelf()
	end
end

function FpvDrone:sv_teardownDrowned()
	if self.sv.drownTicks > 0 then
		self.sv.drownTicks = self.sv.drownTicks - 1
		self:sv_sink()
		if self.sv.drownTicks <= 0 then
			self:sv_destroySelf() -- also what finally stops the motor sound
		end
	end
end

function FpvDrone:sv_teardownBroken(dt)
	if self.sv.smashTicks > 0 then
		self.sv.smashTicks = self.sv.smashTicks - 1
		if self.sv.smashTicks <= 0 then
			self:sv_destroySelf()
			return
		end
	end
	self.sv.throttle = 0.0
	self:sv_coastRpm(dt)
	self:sv_terrainFloor(dt) -- a hard landing can still kill the camera
	local e = VSFPV_LINK.drones[self.shape] -- OSD keeps going while it falls
	if e then
		e.rpm = self.sv.rpm
		e.spd = self.shape:getBody():getVelocity():length()
		e.alt = self.shape:getWorldPosition().z - self.sv.homeZ
	end
end

-- Backup for sv_onWaterStay
function FpvDrone:sv_detectDrowning()
	if not self.sv.drownPending and self.sv.waterProbe then
		self.sv.waterTick = self.sv.waterTick + 1
		if self.sv.waterTick >= WATER.POLL_EVERY then
			self.sv.waterTick = 0
			if self:sv_inWater() then
				self.sv.drownPending = true
				log("water", "poll detected water -> drown")
			end
		end
	end
	if not self.sv.drownPending then
		return false
	end
	self.sv.drowned = true
	-- A soft landing in water doesn't set it off, but it's still indestructible
	self.shape:getBody():setDestructable(true)
	self.sv.throttle = 0.0
	self.sv.rpm = 0.0
	self.sv.drownTicks = WATER.DROWN_TICKS
	VSFPV_LINK.drones[self.shape] = nil -- the controller lets go
	self.network:sendToClients("cl_drowned")
	log("water", "DROWNED -> sinking, part despawns in " .. tostring(WATER.DROWN_TICKS) .. " ticks")
	self:sv_sink()
	return true
end

-- true = tick over (unlinked, no RTH)
function FpvDrone:sv_syncClaim(dt, e)
	if not e.claimedBy and not self.sv.rth.active then
		if self.sv.piloted then
			self.sv.piloted = false
			self:sv_resetControls()
		end
		self:sv_coastRpm(dt)
		return true
	end
	if not self.sv.piloted then
		self.sv.piloted = true
		self:sv_resetControls()
		self.sv.rpm = 0.0
		self.sv.flightT, self.sv.flightTick, self.sv.flightVPrev = 0.0, 0, 0.0
		self.sv.homeZ = self.shape:getWorldPosition().z
		self.sv.targetAlt = self.sv.homeZ
		-- Linking doesn't arm the warhead, the first spin-up does
		self.sv.levelTimer = ACRO.LEVEL_TIME
		self:sv_captureFrame()
	end
	return false
end

function FpvDrone:sv_resetControls()
	self.sv.throttle = 0.0
	self.sv.yawCmd = 0.0
	self.sv.heldHeading = nil
	self.sv.rollCmd, self.sv.pitchCmd = 0.0, 0.0
end

-- Indestructible once armed: a hard hit would otherwise destroy the part outright, the game calls
-- server_onDestroy instead of onProjectile and the drone breaks without exploding
function FpvDrone:sv_armWarhead()
	self.sv.armed = true
	if self.cfg.warhead then
		self.shape:getBody():setDestructable(false)
	end
end

function FpvDrone:sv_publishOsd(e, ctx)
	e.rpm = self.sv.rpm
	e.spd = ctx.vl
	e.alt = ctx.pos.z - self.sv.homeZ
end

function FpvDrone:sv_pushClientUpdates(e)
	if self:sv_streamRpm() and self.cfg.mode == "angle" then
		local frac = clamp((e.camPitch - GIMBAL_MIN) / (GIMBAL_MAX - GIMBAL_MIN), 0.0, 1.0)
		self.network:sendToClients("cl_gimbal", frac)
	end
end

function FpvDrone:sv_telemetry(dt, e, ctx)
	if DEBUG_LOG.flight then
		self.sv.flightT = self.sv.flightT + dt
		self.sv.flightTick = self.sv.flightTick + 1
		if self.sv.flightTick >= FLIGHT_DIAG_EVERY then
			local sampleDt = self.sv.flightTick * dt
			local vH = math.sqrt(ctx.v.x * ctx.v.x + ctx.v.y * ctx.v.y)
			local aH = (vH - self.sv.flightVPrev) / sampleDt
			log(
				"flight",
				"t=%5.2f vH=%5.1f vFull=%5.1f aH=%+5.2f vz=%+5.1f thr=%.2f rpm=%.2f",
				self.sv.flightT,
				vH * 3.6,
				ctx.vl * 3.6,
				aH,
				ctx.v.z,
				self.sv.throttle,
				self.sv.rpm
			)
			self.sv.flightVPrev = vH
			self.sv.flightTick = 0
		end
	end
	self.sv.telem = self.sv.telem + dt
	if self.sv.telem >= TELEM_INTERVAL then
		self.sv.telem = 0.0
		if DEBUG_LOG.flight then
			local tilt = math.deg(math.acos(clamp(ctx.upAxis:dot(UP), -1.0, 1.0)))
			log(
				"flight",
				"thr=%3.0f%% rpm=%3.0f%% T/W=%.2f | tilt=%2.0f up.z=%+.2f | pR=%+.1f rR=%+.1f | in:thr=%+.2f yaw=%+.2f | w=%4.0f spd=%.1f",
				self.sv.throttle * 100,
				self.sv.rpm * 100,
				ctx.thrust / ctx.weight,
				tilt,
				ctx.upAxis.z,
				ctx.pitchRate,
				ctx.rollRate,
				e.inThrottle,
				e.inYaw,
				math.deg(ctx.angVel:length()),
				ctx.vl
			)
		end
	end
end
