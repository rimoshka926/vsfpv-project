-- Flight model: stick input, rotor spool, thrust, drag and attitude. sv_flightTick runs it every tick

local THRUST = VSFPV_CFG.THRUST
local ACRO = VSFPV_CFG.ACRO
local ANGLE = VSFPV_CFG.ANGLE
local MASK = VSFPV_CFG.MASK
local RTH = VSFPV_CFG.RTH
local WARHEAD = VSFPV_CFG.WARHEAD
local FX = VSFPV_CFG.FX

local UP = VSFPV_FRAME.UP
local clamp = VSFPV_FRAME.clamp

-- Each notch lands on the next whole step in its direction, 45.4% goes to 46% or 45%.
-- The 1e-6 keeps 0.46 (really 45.999...) from counting as below the grid
local function wheelThrottle(throttle, steps)
	local unit = ACRO.WHEEL_THROTTLE_STEP
	local onGrid = throttle / unit
	local target
	if steps > 0 then
		target = math.floor(onGrid + 1e-6) + steps
	else
		target = math.ceil(onGrid - 1e-6) + steps
	end
	return clamp(target * unit, 0.0, 1.0)
end

local function airDensity(altitude)
	return THRUST.AIR_DENSITY0 * math.exp(-altitude / THRUST.SCALE_HEIGHT)
end

-- Climbing eats thrust: it scales by vi / (vi + Vc), vi = induced velocity at hover, Vc = climb rate.
-- Bigger disk, lower vi, softer climb limit
local function climbFactor(thrustHover, rho, climbRate, rotorDiskA)
	local disk = 2.0 * rho * rotorDiskA
	if disk <= 0 then
		return 1.0
	end
	local vi = math.sqrt(math.max(0.0, thrustHover) / disk)
	if vi < 0.01 then
		return 1.0
	end
	-- Only valid for Vc > -vi, past that it divides by zero and goes negative, i.e. a thrust cut right
	-- when a dive needs stopping (Mavic vi ~9.8 m/s, Sport descends at 7.5)
	if climbRate <= -vi then
		return THRUST.CLIMB_FACT_MAX
	end
	return clamp(vi / (vi + climbRate), THRUST.CLIMB_FACT_MIN, THRUST.CLIMB_FACT_MAX)
end

function FpvDrone:sv_readBody()
	local body, mass, v = self:sv_motion()
	if not body then
		return nil
	end
	return { body = body, mass = mass, v = v, pos = self.shape:getWorldPosition() }
end

function FpvDrone:sv_readInput(dt, e, ctx)
	ctx.rollRate, ctx.pitchRate = 0.0, 0.0
	ctx.angleFwd, ctx.angleRight = 0.0, 0.0
	self:sv_syncAngleMode(e)
	ctx.am = self.angleModes and self.angleModes[self.angleModeIdx] or nil
	if self.cfg.mode == "angle" and self.sv.rth.active then
		self:sv_readInputRth(dt, e, ctx)
	elseif self.cfg.mode == "angle" then
		self:sv_readInputAngle(dt, e, ctx)
	else
		self:sv_readInputAcro(dt, e, ctx)
	end
	e.throttleSteps = 0 -- the Mavic and RTH just drop them
end

function FpvDrone:sv_readInputRth(dt, e, ctx)
	self:sv_rthFlight(dt, ctx.pos, ctx.v)
	ctx.angleFwd, ctx.angleRight = self.sv.rth.leanFwd, self.sv.rth.leanRight
	self.sv.heldHeading, self.sv.yawIdle = nil, 0.0
	e.inThrottle, e.inYaw, e.altCmd, e.lookX, e.lookY = 0.0, 0.0, 0.0, 0.0, 0.0
end

function FpvDrone:sv_readInputAngle(dt, e, ctx)
	local am = ctx.am
	local altRate = am.altRate
	ctx.angleFwd = e.inThrottle * ANGLE.MOVE_FB_SIGN
	ctx.angleRight = e.inYaw * ANGLE.MOVE_LR_SIGN
	-- Or diagonals lean 1.4x more
	local stick = math.sqrt(ctx.angleFwd * ctx.angleFwd + ctx.angleRight * ctx.angleRight)
	if stick > 1.0 then
		ctx.angleFwd, ctx.angleRight = ctx.angleFwd / stick, ctx.angleRight / stick
	end
	local yawIn = e.lookX
	e.lookX, e.lookY = 0.0, 0.0
	local tiltHover = self:sv_tiltHover()
	local altCmd = e.altCmd
	if altCmd ~= 0.0 then
		self.sv.throttle = clamp(tiltHover + ANGLE.ALT_VKP * (altCmd * altRate - ctx.v.z), 0.0, 1.0)
		self.sv.targetAlt = ctx.pos.z
	elseif math.abs(ctx.v.z) > ANGLE.ALT_STOP_VZ then
		self.sv.throttle = clamp(tiltHover - ANGLE.ALT_KD * ctx.v.z, 0.0, 1.0)
		self.sv.targetAlt = ctx.pos.z
	else
		self.sv.throttle =
			clamp(tiltHover + ANGLE.ALT_KP * (self.sv.targetAlt - ctx.pos.z) - ANGLE.ALT_KD * ctx.v.z, 0.0, 1.0)
	end
	local yawTarget = clamp(yawIn * ANGLE.YAW_GAIN, -ANGLE.YAW_RATE, ANGLE.YAW_RATE) * ANGLE.YAW_SIGN
	self:sv_easeYaw(dt, yawTarget, ACRO.YAW_TAU_UP)
	if yawTarget ~= 0.0 then
		self.sv.heldHeading, self.sv.yawIdle = nil, 0.0
	end
end

function FpvDrone:sv_readInputAcro(dt, e, ctx)
	local rollTarget = clamp(
		e.lookX * ACRO.MOUSE_GAIN * ACRO.ROLL_SIGN,
		-self.tune.maxPrRate,
		self.tune.maxPrRate
	)
	local pitchTarget = clamp(
		e.lookY * ACRO.MOUSE_GAIN * ACRO.PITCH_SIGN,
		-self.tune.maxPrRate,
		self.tune.maxPrRate
	)
	e.lookX, e.lookY = 0.0, 0.0
	local prA = (self.tune.prTau > 0.0) and (1.0 - math.exp(-dt / self.tune.prTau)) or 1.0
	self.sv.rollCmd = self.sv.rollCmd + (rollTarget - self.sv.rollCmd) * prA
	self.sv.pitchCmd = self.sv.pitchCmd + (pitchTarget - self.sv.pitchCmd) * prA
	ctx.rollRate, ctx.pitchRate = self.sv.rollCmd, self.sv.pitchCmd
	-- Clamped so W + LMB doesn't ramp twice as fast
	local throttleInput = clamp(e.inThrottle + e.altCmd, -1.0, 1.0)
	self.sv.throttle = clamp(self.sv.throttle + throttleInput * THRUST.THROTTLE_RATE * dt, 0.0, 1.0)
	if e.throttleSteps ~= 0 then
		self.sv.throttle = wheelThrottle(self.sv.throttle, e.throttleSteps)
	end
	local yawTarget = e.inYaw * ACRO.YAW_RATE * ACRO.YAW_SIGN
	self:sv_easeYaw(dt, yawTarget, ACRO.YAW_TAU_UP)
end

function FpvDrone:sv_easeYaw(dt, target, tauUp)
	local tau = (target == 0.0) and ACRO.YAW_TAU_DOWN or tauUp
	self.sv.yawCmd = self.sv.yawCmd + (target - self.sv.yawCmd) * (1.0 - math.exp(-dt / tau))
end

function FpvDrone:sv_spoolRpm(dt)
	local k = 1.0 - math.exp(-dt / THRUST.SPOOL_TAU)
	self.sv.rpm = self.sv.rpm + (self.sv.throttle - self.sv.rpm) * k
	if not self.sv.armed and self.sv.rpm >= WARHEAD.ARM_RPM then
		self:sv_armWarhead()
	end
end

function FpvDrone:sv_streamRpm()
	self.sv.rpmTick = self.sv.rpmTick + 1
	if self.sv.rpmTick < FX.RPM_SEND_EVERY then
		return false
	end
	self.sv.rpmTick = 0
	self.network:sendToClients("cl_rpm", self.sv.rpm)
	return true
end

function FpvDrone:sv_coastRpm(dt)
	-- Gradually, the clients use rpm for the props and sound
	if self.sv.rpm > 0.01 then
		self.sv.rpm = self.sv.rpm * math.exp(-dt / THRUST.COAST_TAU)
		self:sv_streamRpm()
	elseif self.sv.rpm ~= 0.0 then
		self.sv.rpm = 0.0
		self.network:sendToClients("cl_rpm", 0.0)
	end
end

function FpvDrone:sv_environment(ctx)
	ctx.weight = ctx.mass * THRUST.GRAVITY
	ctx.rho = airDensity(ctx.pos.z)
	ctx.rhoRel = ctx.rho / THRUST.AIR_DENSITY0

	local ground = 1.0
	do
		local from = ctx.pos - sm.vec3.new(0, 0, 0.15)
		local hit, res = sm.physics.raycast(from, from - sm.vec3.new(0, 0, THRUST.GROUND_PROBE), nil, MASK.SOLID)
		if hit then
			local z = math.max((from.z - res.pointWorld.z), self.tune.rotorRadius * 0.5)
			local r = self.tune.rotorRadius / (4.0 * z)
			ground = clamp(1.0 / (1.0 - r * r), 1.0, THRUST.GROUND_MAX)
		end
	end
	ctx.ground = ground
end

-- getAt(worldRotation * CAM_FIX) is the prop axis, getUp the nose. Thrust ~ rpm^2 along the prop axis
function FpvDrone:sv_applyThrust(dt, ctx)
	local upAxis = self:sv_propAxis()
	local fwdAxis = self:sv_noseAxis()
	local rightAxis = fwdAxis:cross(upAxis):normalize()
	ctx.upAxis, ctx.fwdAxis, ctx.rightAxis = upAxis, fwdAxis, rightAxis

	local rpm2 = self.sv.rpm * self.sv.rpm
	local tHover = self.tune.twrMax * rpm2 * ctx.weight * ctx.rhoRel * ctx.ground
	-- A leaning Mavic has lots of speed along its tilted prop axis without climbing, counted as climb it
	-- sinks while moving. ACRO keeps the axial speed, the PG-7's tuning depends on it
	local axialRate = (self.cfg.mode == "angle") and ctx.v.z or ctx.v:dot(upAxis)
	local kClimb = climbFactor(tHover, ctx.rho, axialRate, self.tune.rotorDiskA)
	local thrust = tHover * kClimb
	sm.physics.applyImpulse(self.shape, upAxis * (thrust * dt), true)
	ctx.thrust = thrust
end

-- PG-7 drag per axis: fast nose first, slow falling flat
function FpvDrone:sv_applyDrag(dt, ctx)
	local vl = ctx.v:length()
	if self.tune.dragAniso then
		local half = 0.5 * ctx.rho
		local va = ctx.v:dot(ctx.upAxis)
		local vf = ctx.v:dot(ctx.fwdAxis)
		local vs = ctx.v:dot(ctx.rightAxis)
		local force = ctx.upAxis * (-half * self.tune.dragAxial * math.abs(va) * va)
			+ ctx.fwdAxis * (-half * self.tune.dragFrontal * math.abs(vf) * vf)
			+ ctx.rightAxis * (-half * self.tune.dragLateral * math.abs(vs) * vs)
		sm.physics.applyImpulse(self.shape, force * dt, true)
	elseif vl > 1e-4 then
		local dragCdA = (ctx.am and ctx.am.dragCdA) or self.tune.dragCdA
		local dragMag = 0.5 * ctx.rho * dragCdA * vl
		sm.physics.applyImpulse(self.shape, ctx.v * (-dragMag * dt), true)
	end
	ctx.vl = vl
end

function FpvDrone:sv_applyAttitude(dt, ctx)
	local upAxis, fwdAxis, rightAxis = ctx.upAxis, ctx.fwdAxis, ctx.rightAxis
	local wLevel = sm.vec3.new(0, 0, 0)
	if self.cfg.mode ~= "angle" and self.sv.rpm > ACRO.ARM_RPM and self.sv.levelTimer > 0.0 then
		-- It may have stood on a slope
		self.sv.levelTimer = self.sv.levelTimer - dt
		local levelStr = clamp(self.sv.levelTimer / ACRO.LEVEL_TIME, 0.0, 1.0)
		wLevel = upAxis:cross(UP) * (ACRO.LEVEL_KP * levelStr)
	end
	local angVel = ctx.body:getAngularVelocity()
	local angOk = angVel:length() == angVel:length() -- NaN
	if angOk and self.sv.rpm > ACRO.ARM_RPM then
		local wDes
		if self.cfg.mode == "angle" then
			local headFwd = fwdAxis - UP * fwdAxis:dot(UP)
			if headFwd:length() < 1e-3 then
				headFwd = sm.vec3.new(0, 1, 0)
			else
				headFwd = headFwd:normalize()
			end
			local headRight = headFwd:cross(UP):normalize()
			local lean = self.sv.rth.active and RTH.LEAN or ctx.am.lean
			local angleKp = self.sv.rth.active and RTH.ANGLE_KP or ctx.am.angleKp
			local desiredUp = (UP + headFwd * (ctx.angleFwd * lean) + headRight * (ctx.angleRight * lean)):normalize()
			local swing = upAxis:cross(desiredUp) * angleKp
			wDes = swing + upAxis * self:sv_angleYawRate(dt, upAxis, fwdAxis, angVel, swing)
		else
			wDes = fwdAxis * ctx.rollRate + rightAxis * ctx.pitchRate + upAxis * self.sv.yawCmd + wLevel
		end
		local acc = (wDes - angVel) * self.tune.rateKp
		if self.cfg.mode == "angle" then
			acc = self:sv_angleAccel(acc, upAxis)
		else
			local al = acc:length()
			if al > self.tune.maxAngAcc then
				acc = acc * (self.tune.maxAngAcc / al)
			end
		end
		-- applyTorque takes an impulse like applyImpulse, hence the dt
		sm.physics.applyTorque(ctx.body, acc * (ctx.mass * ACRO.INERTIA_COEF * dt), true)
	end
	ctx.angVel = angVel
end

-- Heading is the nose as it would be levelled. Leaning two ways at once yaws the drone by itself
-- (the W+A drift), that's swing.UP / (1 + up.UP) and gets subtracted. The held heading covers the rest
function FpvDrone:sv_angleYawRate(dt, upAxis, fwdAxis, angVel, swing)
	local c = upAxis:dot(UP)
	if c < ANGLE.HOLD_MIN_UP then
		self.sv.heldHeading, self.sv.yawIdle = nil, 0.0
		return self.sv.yawCmd
	end
	local inv = 1.0 / (1.0 + c)
	local k = upAxis:cross(UP)
	local nose = fwdAxis * c + k:cross(fwdAxis) + k * (k:dot(fwdAxis) * inv)
	nose = nose - UP * nose:dot(UP)
	nose = nose:normalize()
	local hold = 0.0
	if not self.sv.rth.active then
		if not self.sv.heldHeading then
			self.sv.yawIdle = self.sv.yawIdle + dt
			local headingRate = angVel:dot(upAxis + UP) * inv
			if
				math.abs(self.sv.yawCmd) < ANGLE.HOLD_CAPTURE_RATE
				and (math.abs(headingRate) < ANGLE.HOLD_CAPTURE_RATE or self.sv.yawIdle >= ANGLE.HOLD_SETTLE)
			then
				self.sv.heldHeading = nose
			end
		end
		local held = self.sv.heldHeading
		if held then
			local err = math.atan2(nose:cross(held):dot(UP), nose:dot(held))
			hold = clamp(err * ANGLE.HOLD_KP, -ANGLE.HOLD_MAX_RATE, ANGLE.HOLD_MAX_RATE)
		end
	end
	return self.sv.yawCmd + hold - swing:dot(UP) * inv
end

-- Yaw first, tilt gets what's left, or a big lean crowds out the yaw fix. YAW_TORQUE_MATCH: the game
-- reacts slower to yaw than to tilt
function FpvDrone:sv_angleAccel(acc, upAxis)
	local maxAcc = self.tune.maxAngAcc
	local yaw = clamp(acc:dot(upAxis), -maxAcc, maxAcc)
	local tilt = acc - upAxis * acc:dot(upAxis)
	local budget = math.sqrt(maxAcc * maxAcc - yaw * yaw)
	local tl = tilt:length()
	if tl > budget then
		tilt = tilt * (budget / tl)
	end
	return tilt + upAxis * (yaw * ANGLE.YAW_TORQUE_MATCH)
end

function FpvDrone:sv_speedSafety(ctx)
	if ctx.vl > THRUST.MAX_SPEED then
		sm.physics.applyImpulse(self.shape, ctx.v * (-((ctx.vl - THRUST.MAX_SPEED) / ctx.vl) * ctx.mass), true)
	end
end
