-- Drone client: motor sound, prop spin and gimbal animation

local DRONES = VSFPV_CFG.DRONES
local FX = VSFPV_CFG.FX
local CRASH = VSFPV_CFG.CRASH
local DEBUG_LOG = VSFPV_CFG.DEBUG_LOG
local WRECK_REPORT_AFTER = VSFPV_CFG.WRECK_REPORT_AFTER

local clamp = VSFPV_FRAME.clamp
local log = VSFPV_DIAG.log

-- Hurries through the middle of the rpm range, it sounds rough there
local function soundRpm(r)
	if r <= 0.0 then
		return 0.0
	end
	if r >= 1.0 then
		return 1.0
	end
	if r < FX.SND_LO_IN then
		return r / FX.SND_LO_IN * FX.SND_LO_OUT
	elseif r < FX.SND_HI_IN then
		return FX.SND_LO_OUT + (r - FX.SND_LO_IN) / (FX.SND_HI_IN - FX.SND_LO_IN) * (FX.SND_HI_OUT - FX.SND_LO_OUT)
	end
	return FX.SND_HI_OUT + (r - FX.SND_HI_IN) / (1.0 - FX.SND_HI_IN) * (1.0 - FX.SND_HI_OUT)
end

-- Parameter ranges live in the FMOD bank, Lua only sees the names (Data/Audio/GUIDs.txt)
-- "load" picks the recorded layer, only a fixed low loadFix gets the long one (lowload 5.72 s, highload 0.40 s)
local function driveVoice(snd, r, loadFix)
	snd:setParameter("rpm", soundRpm(r))
	snd:setParameter("load", loadFix or (0.5 + 0.5 * r))
end

-- setAnimEnabled throws when the model has no skeleton for the clip
local function tryEnableClip(interactable, clip)
	local ok = pcall(function()
		interactable:setAnimEnabled(clip, true)
	end)
	return ok
end

function FpvDrone:client_onCreate()
	local cfg = DRONES[tostring(self.shape:getShapeUuid())]
	local propBones = cfg.propBones or FX.PROP_BONES
	local hasGimbal = cfg.gimbal == true
	-- Voices start once and never get stop(), it doesn't end a hosted ElectricEngine sound and
	-- isPlaying() lies after it, so a restart stacks voices that whine on after the drone is gone
	self.cl = {
		rpm = 0.0,
		phase = 0.0,
		blastAge = nil, -- nil until it explodes
		wreckReported = false,
		animOn = false,
		animOff = false,
		gimbalOn = false,
		gimbalOff = not hasGimbal,
		gimbalFrac = FX.GIMBAL_NEUTRAL,
		sounds = {},
		nSounds = #propBones,
		started = {},
		starts = 0,
		propBones = propBones,
	}
	self:cl_buildVoice()
	log("general", "Drone CL created")
end

-- One voice per prop bone, started on the first spin-up
function FpvDrone:cl_buildVoice()
	local v = FX.MOTOR_VOICE
	self.cl.sounds = {}
	self.cl.started = {}
	for slot, bone in ipairs(self.cl.propBones) do
		self.cl.sounds[slot] = sm.effect.createEffect(v.prop, self.interactable, bone)
	end
	log("snd", "voice %s: %d created", v.prop, self.cl.nSounds)
end

-- "break": stopBreakSustain, the only thing that silences a live part's voice
-- "destroy": only once the part is gone, destroy() on a live part detaches the sound for good
function FpvDrone:cl_silenceSounds(tag, mode)
	if not (self.cl and self.cl.sounds) then
		return
	end
	for i = 1, self.cl.nSounds do
		local snd = self.cl.sounds[i]
		if snd and sm.exists(snd) then
			local pb, bs0
			if DEBUG_LOG.snd then
				pb = snd:isPlaying()
				bs0 = snd:isBreakSustaining()
			end
			snd:setParameter("rpm", 0.0) -- mute first so the fade is silent
			snd:setParameter("load", 0.0)
			if mode == "destroy" then
				snd:destroy()
				self.cl.sounds[i] = nil
			else
				snd:stopBreakSustain()
			end
			self.cl.started[i] = false
			if DEBUG_LOG.snd then
				-- Sustain goes false->true here, a whine after that is an older voice
				local bs1 = nil
				if sm.exists(snd) then
					bs1 = snd:isBreakSustaining()
				end
				log(
					"snd",
					"%s %s snd[%d] wasPlaying=%s sustain %s->%s",
					tostring(tag),
					tostring(mode),
					i,
					tostring(pb),
					tostring(bs0),
					tostring(bs1)
				)
			end
		end
	end
end

function FpvDrone:cl_killSound()
	log("snd", "cl_killSound FIRED")
	-- Every client gets this, so any of them can report a wreck
	self.cl.blastAge = 0.0
	self.cl.wreckReported = false
	self:cl_motorsDead("kill")
end

function FpvDrone:cl_motorsDead(tag)
	self.cl.dead = true
	self.cl.rpm = 0.0
	self:cl_silenceSounds(tag, "break")
end

-- Sinks for a moment before the server removes it
function FpvDrone:cl_drowned()
	self:cl_motorsDead("drown")
end

-- The part stays, so the motor won't stop on its own
function FpvDrone:cl_crash(data)
	self:cl_motorsDead("crash")
	local tier = data.tier
	local pos = data.pos
	local params = { Material = CRASH.DEBRIS_MATERIAL, Volume = CRASH.DEBRIS_VOLUME[tier] }
	sm.effect.playEffect(CRASH.DEBRIS_FX, pos, nil, nil, nil, params)
end

function FpvDrone:client_onDestroy()
	log("snd", "client_onDestroy FIRED")
	self:cl_silenceSounds("destroy", "destroy")
end

function FpvDrone:cl_rpm(value)
	self.cl.rpm = value
end

-- Once per frame so every voice gets the same value
function FpvDrone:cl_stepSoundRpm(dt)
	local a = clamp(dt / math.max(1e-3, FX.RPM_SND_TAU), 0.0, 1.0)
	local prev = self.cl.rpmSnd or self.cl.rpm
	self.cl.rpmSnd = prev + (self.cl.rpm - prev) * a
end

-- 0..1 animation progress
function FpvDrone:cl_gimbal(frac)
	self.cl.gimbalFrac = frac
end

function FpvDrone:client_onUpdate(dt)
	self:cl_reportWreck(dt)
	self:cl_stepPropSpin(dt)
	self:cl_stepGimbal()
	if not self.cl.dead then
		self:cl_stepMotorSound(dt)
	end
end

function FpvDrone:cl_reportWreck(dt)
	if self.cl.blastAge and not self.cl.wreckReported then
		self.cl.blastAge = self.cl.blastAge + dt
		if self.cl.blastAge >= WRECK_REPORT_AFTER then
			self.cl.wreckReported = true
			local alive = sm.exists(self.shape)
			log(
				"det",
				"client, %.1f s after the blast: wreck %s",
				self.cl.blastAge,
				alive and "still in the world" or "gone"
			)
		end
	end
end

function FpvDrone:cl_stepPropSpin(dt)
	-- No spin animation: fail once and give up, or it logs a skeleton error every frame
	if not self.cl.animOn and not self.cl.animOff then
		local ok = tryEnableClip(self.interactable, FX.PROP_SPIN_NAME)
		self.cl.animOn, self.cl.animOff = ok, not ok
	end
	if self.cl.animOn then
		if self.cl.rpm > 0.0 then
			self.cl.phase = self.cl.phase + FX.PROP_SPIN_HZ * self.cl.rpm * dt
			if self.cl.phase >= 1.0 then
				self.cl.phase = self.cl.phase - math.floor(self.cl.phase)
			end
		end
		self.interactable:setAnimProgress(FX.PROP_SPIN_NAME, self.cl.phase)
	end
end

-- Second animation on the props' armature
function FpvDrone:cl_stepGimbal()
	if not self.cl.gimbalOn and not self.cl.gimbalOff then
		local ok = tryEnableClip(self.interactable, FX.GIMBAL_ANIM_NAME)
		self.cl.gimbalOn, self.cl.gimbalOff = ok, not ok
	end
	if self.cl.gimbalOn then
		self.interactable:setAnimProgress(FX.GIMBAL_ANIM_NAME, self.cl.gimbalFrac)
	end
end

function FpvDrone:cl_stepMotorSound(dt)
	self:cl_stepSoundRpm(dt)
	local rpm = self.cl.rpmSnd -- smoothed, the raw one drives the props
	local vel, speed = self:cl_airframeVelocity(dt)
	self:cl_drivePropVoices(rpm, vel)
	if DEBUG_LOG.snd then
		self.cl.rpmLogT = (self.cl.rpmLogT or 0.0) + dt
		if self.cl.rpmLogT >= 2.0 then
			self.cl.rpmLogT = 0.0
			log("snd", "rpm %.2f | speed %.1f m/s", rpm, speed)
		end
	end
end

-- shape.velocity isn't reliable on a client
function FpvDrone:cl_airframeVelocity(dt)
	local vel = nil
	local pos = self.shape:getInterpolatedWorldPosition()
	if self.cl.lastPos and dt > 1e-4 then
		local d = (pos - self.cl.lastPos) * (1.0 / dt)
		local dl = d:length()
		if dl > FX.MOTOR_VEL_MAX then
			d = d * (FX.MOTOR_VEL_MAX / dl) -- a teleport isn't a fly-by
		end
		vel = self.cl.velEst and (self.cl.velEst + (d - self.cl.velEst) * FX.MOTOR_VEL_SMOOTH) or d
	end
	self.cl.lastPos = pos
	self.cl.velEst = vel
	return vel, vel and vel:length() or 0.0
end

function FpvDrone:cl_drivePropVoices(rpm, vel)
	for i = 1, self.cl.nSounds do
		local snd = self.cl.sounds[i]
		if snd then
			if rpm > 0.01 and not self.cl.started[i] then
				snd:start()
				self.cl.started[i] = true
				self.cl.starts = self.cl.starts + 1
				log("snd", "snd[%d] START (#%d this flight)", i, self.cl.starts)
			end
			if self.cl.started[i] then
				local d = FX.MOTOR_DETUNE[((i - 1) % #FX.MOTOR_DETUNE) + 1]
				local r = clamp(rpm * (1.0 + d), 0.0, 1.0)
				driveVoice(snd, r, FX.MOTOR_VOICE.loadFix)
				if vel then
					snd:setVelocity(vel) -- pitch shift on a fly-by
				end
			end
		end
	end
end
