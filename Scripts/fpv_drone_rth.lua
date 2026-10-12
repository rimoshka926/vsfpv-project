-- Mavic return to home. Scripts get no pathfinding, so it's reactive: a spherecast fan around the
-- home bearing picks the heading, and once it stops getting closer it follows the wall instead

local RTH = VSFPV_CFG.RTH

local UP = VSFPV_FRAME.UP
local CAM_FIX = VSFPV_FRAME.CAM_FIX
local NOSE_SIGN = VSFPV_FRAME.NOSE_SIGN
local clamp = VSFPV_FRAME.clamp
local log = VSFPV_DIAG.log

function FpvDrone:sv_isGrounded()
	local pos = self.shape:getWorldPosition()
	local from = pos + sm.vec3.new(0, 0, 0.1)
	local hit, res =
		sm.physics.raycast(from, from - sm.vec3.new(0, 0, RTH.HOME_GROUND_MAX + 0.6), self.shape, RTH.GROUND_MASK)
	if not hit then
		return false
	end
	return (pos.z - res.pointWorld.z) <= RTH.HOME_GROUND_MAX
end

function FpvDrone:sv_rthPoll(e)
	if self.cfg.mode ~= "angle" then
		return
	end
	local req = e.rthReq
	if req ~= self.sv.rth.reqSeen then
		self.sv.rth.reqSeen = req
		self:sv_rthToggle()
	end
	e.rthActive = self.sv.rth.active
	e.homeSet = self.sv.homeSet
	if self.sv.homeSet and self.sv.homePos then
		local p = self.shape:getWorldPosition()
		local dx, dy = self.sv.homePos.x - p.x, self.sv.homePos.y - p.y
		e.homeDist = math.sqrt(dx * dx + dy * dy)
	else
		e.homeDist = 0.0
	end
end

-- Seq tells a new message from a repeat of the same text
function FpvDrone:sv_homeNotify(msg)
	self.sv.homeMsg = msg
	self.sv.homeMsgSeq = self.sv.homeMsgSeq + 1
end

function FpvDrone:sv_rthStop(z)
	self.sv.rth.active = false
	self.sv.rth.leanFwd, self.sv.rth.leanRight = 0.0, 0.0
	self.sv.targetAlt = z
end

function FpvDrone:sv_forgetHome(msg)
	self.sv.homeSet = false
	self.sv.homePos = nil
	self:sv_homeNotify(msg)
end

function FpvDrone:sv_clearHome()
	self:sv_rthStop(self.shape:getWorldPosition().z)
	self:sv_forgetHome("HOME CLEARED")
	log("general", "RTH home point CLEARED")
end

-- Key 4: set home on the ground, fly home in the air, cancel a return
-- a third quick tap clears home, the first two still do their normal thing
function FpvDrone:sv_rthToggle()
	local rth = self.sv.rth
	local tick = sm.game.getCurrentTick()
	if tick - rth.tapLast <= RTH.CLEAR_TAP_GAP then
		rth.tapCount = rth.tapCount + 1
	else
		rth.tapCount = 1
	end
	rth.tapLast = tick
	if rth.tapCount >= RTH.CLEAR_TAPS then
		rth.tapCount = 0
		self:sv_clearHome()
		return
	end

	if rth.active then
		self:sv_rthStop(self.shape:getWorldPosition().z) -- hold height, no jump
		log("general", "RTH cancelled -> control returned")
		return
	end
	if self:sv_isGrounded() then
		self.sv.homePos = self.shape:getWorldPosition()
		self.sv.homeSet = true
		self:sv_homeNotify("HOME SET")
		log("general", "RTH home point SET")
		return
	end
	if self.sv.homeSet and self.sv.homePos then
		rth.active = true
		rth.phase = "cruise"
		rth.dir = nil
		rth.el = 0.0
		rth.scanT = 0.0
		rth.climbVz = 0.0
		rth.state = "seek"
		rth.bestDist = 1e9
		rth.stuckT = 0.0
		rth.followT = 0.0
		rth.followEntry = nil
		log("general", "RTH START -> flying home")
	else
		log("general", "RTH: no home point yet (land + press 4 to set one)")
	end
end

function FpvDrone:sv_castObstacle(from, dir, maxDist)
	local hit, res = sm.physics.spherecast(from, from + dir * maxDist, RTH.BODY_RADIUS, self.shape, RTH.AVOID_MASK)
	if not hit then
		return maxDist
	end
	if res.type == "character" or res.type == "areaTrigger" then
		return maxDist
	end
	local d = (res.pointWorld - from):length()
	return clamp(d, 0.0, maxDist)
end

local function rotZ(dir, deg)
	local r = math.rad(deg)
	local c, s = math.cos(r), math.sin(r)
	return sm.vec3.new(dir.x * c - dir.y * s, dir.x * s + dir.y * c, 0.0)
end

-- score = progress + room - climb - turn, so around vs over is just whichever scores better
-- nothing flyable: straight up if the sky is clear, else the most open direction
function FpvDrone:sv_rthAnalyze(pos, home)
	local goal3 = (home - pos):normalize()
	local flat = sm.vec3.new(home.x - pos.x, home.y - pos.y, 0.0)
	local bearing = (flat:length() > 1e-3) and flat:normalize() or sm.vec3.new(0, 1, 0)
	local curDir = self.sv.rth.dir or bearing

	local best, bestDir, bestEl, bestClear = -1e9, bearing, 0.0, 0.0
	local anyFlyable = false
	local fbDir, fbClear = bearing, -1.0
	for _, az in ipairs(RTH.AZ_OFFSETS) do
		local azDir = rotZ(bearing, az)
		for _, el in ipairs(RTH.EL_OFFSETS) do
			local ce, se = math.cos(math.rad(el)), math.sin(math.rad(el))
			local d = sm.vec3.new(azDir.x * ce, azDir.y * ce, se)
			local c = self:sv_castObstacle(pos, d, RTH.PROBE_DIST)
			if c > fbClear then
				fbClear, fbDir = c, azDir
			end
			if c >= RTH.SAFE_CLEAR then
				anyFlyable = true
				local progress = d:dot(goal3)
				local room = clamp(c / RTH.PROBE_DIST, 0.0, 1.0)
				local turn = 1.0 - clamp(azDir:dot(curDir), -1.0, 1.0) -- 0 = same heading, 2 = reverse
				local score = RTH.W_PROGRESS * progress + RTH.W_ROOM * room - RTH.W_CLIMB * se - RTH.W_TURN * turn
				if score > best then
					best, bestDir, bestEl, bestClear = score, azDir, el, c
				end
			end
		end
	end

	if not anyFlyable then
		local upClear = self:sv_castObstacle(pos, UP, RTH.CEILING_PROBE)
		if upClear >= RTH.SAFE_CLEAR then
			return bearing, RTH.ESCAPE_EL, upClear, false
		end
		return fbDir, 0.0, fbClear, false
	end
	return bestDir, bestEl, bestClear, true
end

-- Wall on the followHand side (1 right, -1 left): blocked ahead turns away, wall gone turns in
function FpvDrone:sv_rthWallFollow(pos)
	local h = self.sv.rth.dir
	local hand = self.sv.rth.followHand
	local fwdClr = self:sv_castObstacle(pos, h, RTH.PROBE_DIST)
	local sideClr = self:sv_castObstacle(pos, rotZ(h, -90 * hand), RTH.PROBE_DIST)
	local diagClr = self:sv_castObstacle(pos, rotZ(h, -45 * hand), RTH.PROBE_DIST)
	if fwdClr < RTH.WALL_AHEAD then
		h = rotZ(h, RTH.WALL_TURN * hand)
	elseif sideClr > RTH.WALL_DIST + RTH.WALL_HYST and diagClr > RTH.WALL_DIST then
		h = rotZ(h, -RTH.WALL_TURN * hand)
	end
	return h
end

-- Height follows the ground at CRUISE_AGL and only climbs to get over things
function FpvDrone:sv_rthFlight(dt, pos, v)
	local rth = self.sv.rth
	local home = self.sv.homePos

	local fwd = sm.quat.getUp(self.shape.worldRotation * CAM_FIX) * NOSE_SIGN
	local fwdFlat = sm.vec3.new(fwd.x, fwd.y, 0.0)
	if fwdFlat:length() < 1e-3 then
		fwdFlat = sm.vec3.new(0, 1, 0)
	else
		fwdFlat = fwdFlat:normalize()
	end

	local toHome = sm.vec3.new(home.x - pos.x, home.y - pos.y, 0.0)
	local horiz = toHome:length()
	local homeDir = (horiz > 1e-3) and toHome:normalize() or fwdFlat

	-- The real ground, home.z can sit a bit above it and a landing drone would just hover
	local groundZ = home.z
	do
		local hit, res = sm.physics.raycast(pos, pos - sm.vec3.new(0, 0, RTH.GROUND_PROBE), self.shape, RTH.GROUND_MASK)
		if hit then
			groundZ = res.pointWorld.z
		end
	end
	local agl = pos.z - groundZ

	if horiz <= RTH.ARRIVE_RADIUS then
		rth.phase = "descend"
	end

	local travelDir = homeDir
	local targetZ, climbCap, maxSpeed, ramp = pos.z, RTH.CLIMB_RATE, 0.0, 1.0
	rth.climbVz = 0.0

	if rth.phase == "descend" then
		if agl < RTH.TOUCHDOWN_AGL or (agl < RTH.LAND_HEIGHT and math.abs(v.z) < RTH.TOUCHDOWN_VZ) then
			self:sv_rthStop(pos.z) -- or altitude hold lifts it again
			self.sv.throttle = 0.0
			self.sv.yawCmd = 0.0
			self:sv_forgetHome("HOME REACHED")
			log("rth", "LAND hAbove=%.2f vz=%.2f z=%.1f gz=%.1f home.z=%.1f", agl, v.z, pos.z, groundZ, home.z)
			log("general", "RTH COMPLETE (landed at home)")
			return
		end
		targetZ = groundZ - 1.0 -- keep sinking until it touches
		climbCap = RTH.DESCEND_RATE
		maxSpeed = clamp(horiz * RTH.APPROACH_KP, 0.0, 2.5)
	else
		-- Stuck only counts once up, the takeoff climb makes no horizontal progress
		if horiz < rth.bestDist - RTH.STUCK_EPS then
			rth.bestDist = horiz
			rth.stuckT = 0.0
		elseif agl > RTH.CRUISE_AGL * 0.7 then
			rth.stuckT = rth.stuckT + dt
		end

		self:sv_rthScanHeading(dt, pos, home, homeDir, horiz, agl)
		travelDir = rth.dir
		local chosenEl = rth.el

		-- Climb rate rather than extra height, or a tall wall leaves us stuck just under its top
		targetZ = groundZ + RTH.CRUISE_AGL
		climbCap = RTH.CLIMB_RATE
		rth.climbVz = clamp(chosenEl / RTH.CLIMBVZ_MAXEL, 0.0, 1.0) * RTH.CLIMB_RATE

		targetZ = self:sv_rthCeilingCap(pos, targetZ)

		-- sqrt(2a * (clearance - margin)), along the wanted heading and the actual drift
		local brakeClear = self:sv_castObstacle(pos, travelDir, RTH.PROBE_DIST)
		local vh = sm.vec3.new(v.x, v.y, 0.0)
		if vh:length() > 1.0 then
			brakeClear = math.min(brakeClear, self:sv_castObstacle(pos, vh:normalize(), RTH.PROBE_DIST))
		end
		maxSpeed = clamp(horiz * RTH.APPROACH_KP, 0.0, RTH.CRUISE_SPEED)
		maxSpeed = math.min(maxSpeed, math.sqrt(2.0 * RTH.BRAKE_ACCEL * math.max(0.0, brakeClear - RTH.STOP_MARGIN)))
		ramp = clamp(agl / (RTH.CRUISE_AGL * 0.6), 0.0, 1.0)
	end

	local cross = fwdFlat.x * travelDir.y - fwdFlat.y * travelDir.x
	local dotft = clamp(fwdFlat:dot(travelDir), -1.0, 1.0)
	local yawErr = math.atan2(cross, dotft)
	self.sv.yawCmd = clamp(yawErr * RTH.YAW_KP, -RTH.YAW_MAX, RTH.YAW_MAX)

	-- Lean on the velocity error, so too fast at a wall means leaning back to brake
	local vDesMag = maxSpeed * ramp
	local eVx, eVy = travelDir.x * vDesMag - v.x, travelDir.y * vDesMag - v.y
	local headRight = sm.vec3.new(fwdFlat.y, -fwdFlat.x, 0.0)
	rth.leanFwd = clamp((eVx * fwdFlat.x + eVy * fwdFlat.y) * RTH.VEL_KP, -1.0, 1.0)
	rth.leanRight = clamp((eVx * headRight.x + eVy * headRight.y) * RTH.VEL_KP, -1.0, 1.0)

	local tiltHover = self:sv_tiltHover()
	local vzDes = clamp((targetZ - pos.z) * RTH.ALT_PKP, -RTH.DESCEND_RATE, climbCap)
	-- Without the > 0 check a zero climb rate cancels descents and it never lands
	if rth.climbVz > 0.0 and rth.climbVz > vzDes then
		vzDes = rth.climbVz
	end
	self.sv.throttle = clamp(tiltHover + RTH.ALT_VKP * (vzDes - v.z), 0.0, 1.0)
end

function FpvDrone:sv_rthScanHeading(dt, pos, home, homeDir, horiz, agl)
	local rth = self.sv.rth
	rth.scanT = rth.scanT - dt
	if rth.scanT <= 0.0 or not rth.dir then
		rth.scanT = RTH.SCAN_TIME

		-- Only leave closer than where following started, or it hits the same wall again
		if rth.state == "follow" then
			local homeClr = self:sv_castObstacle(pos, homeDir, RTH.PROBE_DIST)
			local progressed = horiz < rth.followDist - RTH.LEAVE_EPS
			local climbedOut = rth.el >= RTH.ESCAPE_EL - 1.0
			if homeClr >= RTH.LANE_CLEAR and (progressed or climbedOut) then
				rth.state = "seek"
				rth.stuckT = 0.0
				rth.bestDist = horiz
			end
		end

		if rth.state == "seek" then
			local bdir, bel = self:sv_rthAnalyze(pos, home)
			rth.dir, rth.el = bdir, bel
			-- Going round in circles
			if rth.stuckT >= RTH.STUCK_TIME then
				local rC = self:sv_castObstacle(pos, rotZ(homeDir, -60), RTH.PROBE_DIST)
				local lC = self:sv_castObstacle(pos, rotZ(homeDir, 60), RTH.PROBE_DIST)
				rth.followHand = (lC > rC) and 1 or -1
				rth.state = "follow"
				rth.followDist = horiz
				rth.followEntry = pos
				rth.followT = 0.0
			end
		end

		if rth.state == "follow" then
			rth.followT = rth.followT + RTH.SCAN_TIME
			rth.dir = self:sv_rthWallFollow(pos)
			rth.el = 0.0
			-- Back at the entry point or following too long: boxed in, climb out
			local entry = rth.followEntry
			local dx, dy = entry and (pos.x - entry.x) or 1e9, entry and (pos.y - entry.y) or 1e9
			local looped = entry and rth.followT > 3.0 and (dx * dx + dy * dy) < RTH.LOOP_RADIUS * RTH.LOOP_RADIUS
			if looped or rth.followT > RTH.FOLLOW_MAXT then
				rth.el = RTH.ESCAPE_EL
			end
		end

		log(
			"rth",
			"%s hand=%d el=%.0f | d=%.0f best=%.0f stuck=%.1f agl=%.1f",
			rth.state,
			rth.followHand,
			rth.el,
			horiz,
			rth.bestDist,
			rth.stuckT,
			agl
		)
	end
end

-- Normal check so a cliff face isn't taken for a roof
function FpvDrone:sv_rthCeilingCap(pos, targetZ)
	local from = pos + sm.vec3.new(0, 0, 0.2)
	local hit, res = sm.physics.raycast(from, from + sm.vec3.new(0, 0, RTH.CEILING_PROBE), self.shape, RTH.AVOID_MASK)
	if hit and res.type ~= "character" and res.type ~= "areaTrigger" and res.normalWorld.z < RTH.CEILING_NRM then
		local capZ = res.pointWorld.z - RTH.CEILING_MARGIN
		if targetZ > capZ then
			targetZ = capZ
		end
		if pos.z + RTH.CEILING_MARGIN >= capZ then
			self.sv.rth.climbVz = 0.0
		end
	end
	return targetZ
end
