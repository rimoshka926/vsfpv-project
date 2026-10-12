-- PG-7 shaped charge: penetration, behind-armour effects, jet push, blast damage, detonation

local MASK = VSFPV_CFG.MASK
local WARHEAD = VSFPV_CFG.WARHEAD
local JETTRAIL = VSFPV_CFG.JETTRAIL
local PEN = VSFPV_CFG.PEN
local PEN_ARMOR = VSFPV_CFG.PEN_ARMOR
local SHRAP = VSFPV_CFG.SHRAP
local RICO = VSFPV_CFG.RICO
local JET_IMP = VSFPV_CFG.JET_IMP
local BLAST_DMG = VSFPV_CFG.BLAST_DMG
local SELF_DMG = VSFPV_CFG.SELF_DMG
local DETONATE_DESTROY_DELAY = VSFPV_CFG.DETONATE_DESTROY_DELAY
local DEBUG_LOG = VSFPV_CFG.DEBUG_LOG
local CHAIN = VSFPV_CFG.CHAIN

local UP = VSFPV_FRAME.UP
local clamp = VSFPV_FRAME.clamp
local log = VSFPV_DIAG.log
local try = VSFPV_DIAG.try

-- Scripted parts (propane, modded bombs) get the chain signal and a few ticks to go off, destroyPart just deletes them
local function jetThroughPart(shape, pos)
	local scripted = nil
	local ia = shape:getInteractable()
	if ia and ia:getType() == "scripted" then
		scripted = ia
	end
	local q = VSFPV_LINK.carveQueue
	if not scripted or #q >= CHAIN.SWEEP_MAX then
		-- several fragments can reach one part in a tick, and removal waits for the end of it
		try("jet destroyPart", function()
			sm.shape.destroyPart(shape)
		end)
		return
	end
	-- instant runs the other part's script right here, its errors included
	try("jet chain signal", function()
		sm.event.sendToInteractable(scripted, CHAIN.SIGNAL, pos, sm.event.types.instant)
	end)
	q[#q + 1] = { shape = shape, due = sm.game.getCurrentTick() + CHAIN.SWEEP_TICKS }
	log("pen", "jet signalled a scripted part, sweeping in %d ticks (queue %d)", CHAIN.SWEEP_TICKS, #q)
end

-- On VSFPV_LINK because the drone that queued them is gone by then
function VSFPV_LINK.sweepCarve()
	local q = VSFPV_LINK.carveQueue
	if not q or #q == 0 then
		return
	end
	local now = sm.game.getCurrentTick()
	local waiting = {}
	for i = 1, #q do
		local item = q[i]
		if now < item.due then
			waiting[#waiting + 1] = item
		elseif sm.exists(item.shape) then
			-- this runs inside every drone and transmitter tick
			try("carve sweep", function()
				sm.shape.destroyPart(item.shape)
			end)
		else
			log("pen", "a signalled part removed itself before the sweep, it detonated")
		end
	end
	VSFPV_LINK.carveQueue = waiting
end

local function perpBasis(n)
	local ref = (math.abs(n.z) < 0.9) and UP or sm.vec3.new(1, 0, 0)
	local a = n:cross(ref):normalize()
	return a, n:cross(a):normalize()
end

local function coneSample(dir, t1, t2, cosMax)
	local z = cosMax + (1.0 - cosMax) * math.random()
	local s = math.sqrt(math.max(0.0, 1.0 - z * z))
	local phi = math.random() * 2.0 * math.pi
	return (dir * z + t1 * (s * math.cos(phi)) + t2 * (s * math.sin(phi))):normalize()
end

local function hitShape(r)
	if r.type == "body" then
		return r:getShape()
	end
	return nil
end

local function blockCell(shp, worldPos)
	local lp = shp:getClosestBlockLocalPosition(worldPos)
	return math.floor(lp.x + 0.5), math.floor(lp.y + 0.5), math.floor(lp.z + 0.5)
end

-- Rough 3x3 on the hit face, the grid follows the normal so an angled hit still gets a full 3x3
-- returns the cells left standing, for the entry fire
local function carveMouth(shp, entryPos, n)
	if not (shp and sm.exists(shp) and entryPos and n and n:length() >= 0.5) then
		return
	end
	local u, w = perpBasis(n)
	local eIn = entryPos - n * 0.06 -- into the wall so we sample its cell
	local cx, cy, cz = blockCell(shp, eIn)
	local function breakAt(oa, ob)
		-- an edge cell can be empty or outside the shape
		try("jet mouth", function()
			local x, y, z = blockCell(shp, eIn + u * (0.25 * oa) + w * (0.25 * ob))
			shp:destroyBlock(
				sm.vec3.new(clamp(x, cx - 1, cx + 1), clamp(y, cy - 1, cy + 1), clamp(z, cz - 1, cz + 1)),
				sm.vec3.new(1, 1, 1)
			)
		end)
	end
	breakAt(0, 0)
	local ring = { { -1, -1 }, { -1, 0 }, { -1, 1 }, { 0, -1 }, { 0, 1 }, { 1, -1 }, { 1, 0 }, { 1, 1 } }
	for i = #ring, 2, -1 do
		local j = math.random(i)
		ring[i], ring[j] = ring[j], ring[i]
	end
	local intact = PEN.ENTRY_INTACT_MIN + math.random(0, PEN.ENTRY_INTACT_MAX - PEN.ENTRY_INTACT_MIN)
	for i = 1, 8 - intact do
		breakAt(ring[i][1], ring[i][2])
	end
	local survivors = {}
	for i = 9 - intact, 8 do
		survivors[#survivors + 1] = entryPos + u * (0.25 * ring[i][1]) + w * (0.25 * ring[i][2])
	end
	return survivors
end

-- Every cell the line passes through, so diagonal channels have no see-through gaps
local function carveCellLine(shp, aW, bW)
	if not (shp and sm.exists(shp)) then
		return
	end
	local function kill(cx, cy, cz)
		if sm.exists(shp) then
			try("jet bore", function()
				shp:destroyBlock(sm.vec3.new(cx, cy, cz), sm.vec3.new(1, 1, 1))
			end)
		end
	end
	local x, y, z = blockCell(shp, aW)
	local x1, y1, z1 = blockCell(shp, bW)
	kill(x, y, z)
	local dx, dy, dz = x1 - x, y1 - y, z1 - z
	local sx = (dx > 0 and 1) or (dx < 0 and -1) or 0
	local sy = (dy > 0 and 1) or (dy < 0 and -1) or 0
	local sz = (dz > 0 and 1) or (dz < 0 and -1) or 0
	dx, dy, dz = math.abs(dx), math.abs(dy), math.abs(dz)
	if dx >= dy and dx >= dz then
		local ey, ez = 2 * dy - dx, 2 * dz - dx
		for _ = 1, dx do
			if ey >= 0 then
				y = y + sy
				kill(x, y, z)
				ey = ey - 2 * dx
			end
			if ez >= 0 then
				z = z + sz
				kill(x, y, z)
				ez = ez - 2 * dx
			end
			ey = ey + 2 * dy
			ez = ez + 2 * dz
			x = x + sx
			kill(x, y, z)
		end
	elseif dy >= dx and dy >= dz then
		local ex, ez = 2 * dx - dy, 2 * dz - dy
		for _ = 1, dy do
			if ex >= 0 then
				x = x + sx
				kill(x, y, z)
				ex = ex - 2 * dy
			end
			if ez >= 0 then
				z = z + sz
				kill(x, y, z)
				ez = ez - 2 * dy
			end
			ex = ex + 2 * dx
			ez = ez + 2 * dz
			y = y + sy
			kill(x, y, z)
		end
	else
		local ex, ey = 2 * dx - dz, 2 * dy - dz
		for _ = 1, dz do
			if ex >= 0 then
				x = x + sx
				kill(x, y, z)
				ex = ex - 2 * dz
			end
			if ey >= 0 then
				y = y + sy
				kill(x, y, z)
				ey = ey - 2 * dz
			end
			ex = ex + 2 * dx
			ey = ey + 2 * dy
			z = z + sz
			kill(x, y, z)
		end
	end
end

-- Dug by hand the way the Drillbot does it (DrillAttack.lua): a wide sphere for the crater, then
-- small ones down the channel to endPos
function FpvDrone:sv_craterVoxel(entryPos, axis, endPos)
	local world = self.shape.body:getWorld()
	local function dig(p, r)
		world:sphereVoxelDensitySubtraction(p, r, PEN.VOXEL_FILTER, PEN.CRATER_STRENGTH)
	end
	dig(entryPos, PEN.CRATER_R)
	local depth = math.max(0.0, (endPos - entryPos):dot(axis))
	local steps = math.min(PEN.CRATER_MAX, math.floor(depth / PEN.CRATER_STEP))
	for i = 1, steps do
		dig(entryPos + axis * (PEN.CRATER_STEP * i), PEN.CHANNEL_R)
	end
	log("pen", "crater voxel depth=%.2f spheres=%d", depth, steps + 1)
end

-- The channel is cut one cell at a time with destroyBlock, explode() can't make a one block hole.
-- Scan the whole line first, raycasts into freshly carved geometry aren't reliable. Runs before the blast
function FpvDrone:sv_penetrate(atPos, axis)
	local mask = MASK.SOLID
	local far = atPos + axis * PEN.DEPTH
	local from = atPos - axis * PEN.BACKOFF
	local ignore = self.shape
	local segs = {}
	local exitedAir = false -- last layer opens into free air
	local g = 0
	while g < PEN.SCAN_MAX_HITS do
		g = g + 1
		local h, r = sm.physics.raycast(from, far, ignore, mask)
		if not h then
			exitedAir = true
			break
		end
		local shp = hitShape(r)
		-- Terrain = heightmap or asset, indestructible. part = solid with no shape (joint, bearing)
		-- the raycast type is "voxelTerrain" in lower camel case
		local kind, harv
		if shp then
			kind = "shape"
		elseif r.type == "voxelTerrain" then
			kind = "voxel"
		elseif r.type == "harvestable" then
			kind = "harvest"
			harv = r:getHarvestable()
		elseif r.type == "terrainSurface" or r.type == "terrainAsset" then
			kind = "terrain"
		else
			kind = "part"
		end
		local isTerrain = (kind == "voxel") or (kind == "terrain")
		segs[#segs + 1] = {
			point = r.pointWorld,
			normal = r.normalWorld,
			shape = shp,
			kind = kind,
			harvestable = harv,
		}
		if DEBUG_LOG.pen then
			local isBlk, sid = "-", "-"
			if shp and sm.exists(shp) then
				isBlk = tostring(sm.item.isBlock(shp.shapeUuid))
				sid = tostring(shp.id)
			end
			log(
				"pen",
				"seg#%d type=%s kind=%s shape=%s isBlock=%s id=%s d=%.2f",
				#segs,
				tostring(r.type),
				kind,
				shp and "yes" or "no",
				isBlk,
				sid,
				(r.pointWorld - atPos):dot(axis)
			)
		end
		if shp then
			from = r.pointWorld + axis * 0.02
			ignore = shp
		elseif isTerrain then
			break
		else
			-- Trees and unresolved parts can't be the raycast ignore
			from = r.pointWorld + axis * PEN.THIN_STEP
			ignore = nil
		end
		if (from - atPos):dot(axis) > PEN.DEPTH then
			break
		end
	end
	if #segs == 0 then
		return nil
	end
	local entryPos = segs[1].point
	local hitBody = nil
	if segs[1].shape and sm.exists(segs[1].shape) then
		hitBody = segs[1].shape.body
	end

	local mouthShape, mouthPos = nil, nil
	if segs[1].shape and sm.exists(segs[1].shape) and sm.item.isBlock(segs[1].shape.shapeUuid) then
		local n = segs[1].normal
		if not n or n:length() < 0.5 then
			n = axis * -1
		end
		local survivors = carveMouth(segs[1].shape, entryPos, n)
		mouthShape, mouthPos = segs[1].shape, entryPos -- so the casing burst skips this face
		if survivors then
			for _, cellPos in ipairs(survivors) do
				sm.fire.igniteSphere(cellPos, PEN.ENTRY_FIRE_R, true)
			end
		end
	end

	-- Every cell and air gap past GAP_FREE costs budget, what's left drives the damage behind
	local budget = PEN.BUDGET
	local atk = self:sv_attacker()
	local prevExit = nil
	local jetEnd = entryPos

	-- Open air, no wall close by
	if (segs[1].point - atPos):dot(axis) > 0.6 then
		self:sv_behindArmor(atPos - axis * 0.5, axis, budget / PEN.BUDGET, atk)
	end

	for i = 1, #segs do
		local seg = segs[i]
		local frontFace = seg.point
		if (frontFace - entryPos):dot(axis) > PEN.DEPTH then
			break
		end

		-- Reverse cast, don't ignore the shape: ignoring it hits the next wall and bills the gap as solid
		local nxtPt = (segs[i + 1] and segs[i + 1].point) or far
		local exitFace
		if seg.shape and sm.exists(seg.shape) then
			local castFrom = nxtPt - axis * 0.04
			local castTo = frontFace + axis * 0.04
			local bk, bkRes = sm.physics.raycast(castFrom, castTo, self.shape, mask)
			exitFace = bk and bkRes.pointWorld or nxtPt
		elseif seg.kind == "part" or seg.kind == "harvest" then
			-- Charge only the step past it, or one tree eats the whole budget
			exitFace = frontFace + axis * math.min(PEN.THIN_STEP, math.max(0.0, (nxtPt - frontFace):dot(axis)))
		else
			exitFace = nxtPt -- terrain, the jet stops in it
		end

		if prevExit then
			local gap = (frontFace - prevExit):dot(axis)
			if gap > PEN.GAP_FREE then
				budget = budget - (gap - PEN.GAP_FREE) * PEN.GAP_COST
				log("pen", "gap=%.2fm cost=%.2f P=%.2f", gap, (gap - PEN.GAP_FREE) * PEN.GAP_COST, budget)
			end
		end
		if budget <= 0 then
			break
		end

		local thickness = math.max(0.0, (exitFace - frontFace):dot(axis))
		local cells = math.max(1.0, thickness / PEN.CELL)
		local cellCost
		if seg.shape and sm.exists(seg.shape) then
			cellCost = PEN_ARMOR[tostring(seg.shape.shapeUuid)] or PEN.DEFAULT_COST
		elseif seg.kind == "voxel" or seg.kind == "terrain" then
			cellCost = PEN.TERRAIN_COST
		else
			cellCost = PEN.PART_COST
		end
		local fullCost = cells * cellCost
		local stoppedInside = fullCost >= budget
		local carveEnd = exitFace
		if stoppedInside then
			local penDepth = math.min(thickness, (budget / cellCost) * PEN.CELL)
			carveEnd = frontFace + axis * penDepth
		end
		budget = budget - fullCost
		log(
			"pen",
			"wall#%d thick=%.2f cells=%.1f cost/c=%.2f total=%.2f P=%.2f%s",
			i,
			thickness,
			cells,
			cellCost,
			fullCost,
			budget,
			stoppedInside and " STOP" or ""
		)

		if seg.shape and sm.exists(seg.shape) then
			if sm.item.isBlock(seg.shape.shapeUuid) then
				carveCellLine(seg.shape, frontFace + axis * 0.06, carveEnd - axis * 0.02)
			else
				jetThroughPart(seg.shape, frontFace)
			end
		elseif seg.kind == "harvest" then
			-- Not during the scan, it needs everything intact
			-- one tree can give two segments, this may be its second destroy
			if seg.harvestable and sm.exists(seg.harvestable) then
				try("jet tree", function()
					seg.harvestable:destroy()
				end)
			end
		elseif seg.kind == "voxel" then
			self:sv_craterVoxel(frontFace, axis, carveEnd)
		elseif seg.kind == "terrain" then
			log("pen", "wall#%d non-voxel terrain: no destruction API, jet absorbed", i)
		end

		prevExit = exitFace
		jetEnd = carveEnd

		-- Fragments only where the jet breaks into open space, never inside solid material
		local nxt = segs[i + 1]
		local intoOpen
		if nxt then
			intoOpen = (nxt.point - exitFace):dot(axis) >= PEN.GAP_FREE
		else
			intoOpen = exitedAir and not stoppedInside
		end
		local budgetFrac = math.max(0.0, budget) / PEN.BUDGET
		if intoOpen and budgetFrac >= SHRAP.MIN_BUDGET then
			-- Another wall ahead = enclosed space, a vehicle interior
			local dmgMult = (nxt ~= nil) and SHRAP.INTERIOR_DMG_MULT or 1.0
			self:sv_behindArmor(exitFace, axis, budgetFrac, atk, dmgMult)
		end

		if budget <= 0 then
			break
		end
	end

	self:sv_jetTrail(entryPos, jetEnd, axis)

	return hitBody, mouthShape, mouthPos
end

function FpvDrone:sv_jetTrail(from, to, axis)
	local seg = to - from
	local len = seg:length()
	if len < 0.06 then
		return
	end
	local dir = seg:normalize()
	local rot = sm.vec3.getRotation(UP, dir)
	local n = math.max(1, math.min(JETTRAIL.MAX, math.floor(len / JETTRAIL.STEP)))
	for i = 0, n do
		local p = from + dir * (len * (i / n))
		sm.effect.playEffect(JETTRAIL.FX, p, nil, rot)
	end
end

-- Uniform over the cone
local function scatterDir(dir, deg)
	if deg <= 0 then
		return dir
	end
	local t1, t2 = perpBasis(dir)
	return coneSample(dir, t1, t2, math.cos(math.rad(deg)))
end

-- The rest of the jet (one ray, deadly up close) plus a cone of fragments that hit, break and ricochet
-- dmgMult scales the jet damage and the fragment count, per-fragment damage stays
function FpvDrone:sv_behindArmor(exitPos, axis, budgetFrac, atk, dmgMult)
	if budgetFrac < SHRAP.MIN_BUDGET or not atk then
		return
	end
	dmgMult = dmgMult or 1.0
	axis = axis:normalize()
	local mask = MASK.SOLID
	-- the PvP mod hooks meleeAttack, so another mod's code runs in these
	try("jet core damage", function()
		sm.melee.meleeAttack(
			SHRAP.MELEE_UUID,
			SHRAP.JET_CORE_DMG * budgetFrac * dmgMult,
			exitPos,
			axis * SHRAP.JET_CORE_RANGE,
			atk
		)
	end)
	local n = math.max(1, math.floor(SHRAP.COUNT * budgetFrac * dmgMult + 0.5))
	local fDmg = SHRAP.DAMAGE * budgetFrac
	local cosMax = math.cos(math.rad(SHRAP.CONE))
	local t1, t2 = perpBasis(axis)
	local nHit, nWreck, nRico = 0, 0, 0
	for _ = 1, n do
		local fd = coneSample(axis, t1, t2, cosMax)
		-- Share of full damage, reach and break chance left
		local origin, dir, energy = exitPos, fd, 1.0
		for bounce = 0, RICO.MAX_BOUNCES do
			try("fragment damage", function()
				sm.melee.meleeAttack(SHRAP.MELEE_UUID, fDmg * energy, origin, dir * (SHRAP.RANGE * energy), atk)
			end)
			local h, r = sm.physics.raycast(origin, origin + dir * (SHRAP.RANGE * energy), self.shape, mask)
			if not h then
				break
			end
			nHit = nHit + 1
			local hitShp = hitShape(r)
			if hitShp and sm.exists(hitShp) and math.random() < SHRAP.BREAK_CHANCE * budgetFrac * energy then
				if sm.item.isBlock(hitShp.shapeUuid) then
					-- an earlier fragment may have taken this cell already
					try("fragment destroyBlock", function()
						local x, y, z = blockCell(hitShp, r.pointWorld + dir * 0.02)
						hitShp:destroyBlock(sm.vec3.new(x, y, z), sm.vec3.new(1, 1, 1))
					end)
				else
					jetThroughPart(hitShp, r.pointWorld)
				end
				nWreck = nWreck + 1
			end
			sm.effect.playEffect(SHRAP.FX, r.pointWorld, nil, sm.vec3.getRotation(UP, dir * -1.0))
			-- Bounce chance = how glancing the hit is
			if bounce >= RICO.MAX_BOUNCES then
				break
			end
			local nrm = r.normalWorld
			if not nrm then
				break
			end
			local cosI = math.abs(dir:dot(nrm)) -- 1 = straight on, 0 = glancing
			local graze = 1.0 - cosI
			if math.random() > graze then
				break
			end
			local newEnergy = energy * RICO.ENERGY * (0.6 + 0.4 * graze)
			if newEnergy < RICO.MIN_ENERGY then
				break
			end
			local refl = (dir - nrm * (2.0 * dir:dot(nrm))):normalize()
			dir = scatterDir(refl, RICO.SCATTER)
			origin = r.pointWorld + dir * 0.02 -- off the surface or the next cast hits it again
			energy = newEnergy
			nRico = nRico + 1
		end
	end
	log(
		"pen",
		"behindArmour frac=%.2f mult=%.2f frags=%d hit=%d wreck=%d rico=%d",
		budgetFrac,
		dmgMult,
		n,
		nHit,
		nWreck,
		nRico
	)
end

-- applied at the hit point so an off-centre hit spins the target, fixed force whatever the mass
function FpvDrone:sv_jetImpulse(atPos, axis, hitBody)
	local function punch(body, scale)
		if not (body and sm.exists(body) and body:isDynamic()) then
			return
		end
		local rel = atPos - body.worldPosition
		sm.physics.applyImpulse(body, axis * (JET_IMP.FORCE * scale), true, rel)
	end
	punch(hitBody, 1.0)
	local contacts = sm.physics.getSphereContacts(atPos, JET_IMP.RADIUS)
	for _, body in pairs(contacts.bodies or {}) do
		if body ~= hitBody then
			local f = 1.0 - (body.worldPosition - atPos):length() / JET_IMP.RADIUS
			if f > 0.0 then
				punch(body, f)
			end
		end
	end
	for _, char in pairs(contacts.characters or {}) do
		if sm.exists(char) then
			local f = 1.0 - (char.worldPosition - atPos):length() / JET_IMP.RADIUS
			if f > 0.0 then
				sm.physics.applyImpulse(char, axis * (JET_IMP.FORCE * f / JET_IMP.CHAR_DIV), true)
			end
		end
	end
end

-- explode() damage is flat, so each player gets a meleeAttack aimed at them and cover blocks it
function FpvDrone:sv_blastWave(jetPos, contactPos, source)
	if not source then
		return
	end
	-- Only the worse of the two points, on a nose hit they're the same spot
	local hardest = {} -- character -> { dmg, from }
	local function score(atPos, radius, maxDmg, pow, toSurface)
		if not atPos then
			return
		end
		-- Contact radius is smaller than a character
		local contacts = sm.physics.getSphereContacts(atPos, radius + 2.0)
		for _, char in pairs(contacts.characters or {}) do
			if sm.exists(char) and char:getPlayer() then
				local charPos = char.worldPosition
				local d = (charPos - atPos):length()
				if toSurface then
					-- To the body surface, a drone at your legs is touching you
					local off = charPos - atPos
					local dz = math.max(0.0, math.abs(off.z) - BLAST_DMG.CHAR_HALF_H)
					local flat = math.sqrt(off.x * off.x + off.y * off.y)
					d = math.max(0.0, math.sqrt(flat * flat + dz * dz) - BLAST_DMG.CHAR_RADIUS)
				end
				if d < radius then
					local dmg = maxDmg * ((1.0 - d / radius) ^ pow)
					local prev = hardest[char]
					if not prev or dmg > prev.dmg then
						hardest[char] = { dmg = dmg, from = atPos }
					end
				end
			end
		end
	end
	score(jetPos, BLAST_DMG.R, BLAST_DMG.MAX, BLAST_DMG.FALLOFF_POW, false)
	score(contactPos, BLAST_DMG.CONTACT_R, BLAST_DMG.CONTACT_MAX, BLAST_DMG.CONTACT_FALLOFF_POW, true)
	for char, hit in pairs(hardest) do
		if sm.exists(char) and char:getPlayer() then
			local atPos = hit.from
			local to = char.worldPosition - atPos
			local d = to:length()
			local dmg = hit.dmg
			if dmg >= BLAST_DMG.MIN then
				local dir = (d > 1e-3) and (to / d) or UP
				if char:getPlayer() == source then
					-- The PvP mod blocks melee on yourself, so a projectile from the drone (half damage, hence 2x)
					-- it has to cross the hitbox, from above when the blast is too close
					local cpos = char.worldPosition
					local away = cpos - atPos
					local adist = away:length()
					local firePos, fvel
					if adist > SELF_DMG.STANDOFF then
						firePos, fvel = atPos, (away / adist) * SELF_DMG.SPEED
					else
						firePos, fvel = cpos + UP * SELF_DMG.STANDOFF, UP * -SELF_DMG.SPEED
					end
					-- Both in the shape's own frame, vanilla MountedPotatoGun fires from (0, 0, 0.375)
					local toLocal = self.shape.worldRotation:inverse()
					local localPos = toLocal * (firePos - self.shape.worldPosition)
					local localVel = toLocal * fvel
					sm.projectile.shapeProjectileAttack(SELF_DMG.PROJECTILE, dmg * SELF_DMG.SCALE, localPos, localVel, self.shape)
				else
					try("blast damage pvp", function() -- the PvP mod hook again
						sm.melee.meleeAttack(SHRAP.MELEE_UUID, dmg, atPos, dir * (d + 0.5), source)
					end)
				end
			end
		end
	end
end

-- meleeAttack needs a player source, the pilot keeps teams and the kill feed right
function FpvDrone:sv_attacker()
	local e = VSFPV_LINK.drones[self.shape]
	local ctrl = e and e.claimedBy
	if ctrl and sm.exists(ctrl) then
		local ia = ctrl.interactable
		local ch = ia and ia:getSeatCharacter()
		local p = ch and ch:getPlayer()
		if p then
			return p
		end
	end
	return sm.player.getAllPlayers()[1]
end

-- Cast from behind the drone, on a fast dive it can already be clipped into the wall
function FpvDrone:sv_jetOrigin(axis)
	local dronePos = self.shape:getWorldPosition()
	local jetPos = dronePos + axis * PEN.JET_ORIGIN_FWD
	local h, r = sm.physics.raycast(
		dronePos - axis * PEN.AIM_SCAN_BACK,
		dronePos + axis * PEN.AIM_SCAN_REACH,
		self.shape,
		MASK.SOLID
	)
	if h then
		jetPos = r.pointWorld
	end
	return dronePos, jetPos
end

-- Side, top or back hits: the same rough 3x3, no channel, nothing behind
function FpvDrone:sv_casingBurst(dronePos, contactPos, mouthShape, mouthPos)
	if not contactPos then
		return
	end
	local dir = contactPos - dronePos
	local reach = dir:length()
	if reach < 1e-3 then
		return
	end
	dir = dir / reach
	-- From behind the drone to catch contacts already flush with the wall
	local hit, r =
		sm.physics.raycast(dronePos - dir * 0.10, contactPos + dir * WARHEAD.CONTACT_REACH, self.shape, MASK.SOLID)
	if not (hit and r and r.type == "body") then
		return
	end
	local shp = r:getShape()
	if not (shp and sm.exists(shp) and sm.item.isBlock(shp.shapeUuid)) then
		log("det", "casing burst: contact was not a build block (" .. tostring(r.type) .. ")")
		return
	end
	local dur = sm.item.getDurabilityRating(shp.shapeUuid) or 0
	if dur > WARHEAD.CONTACT_MAX_DUR then
		log("det", "casing burst: durability %d > %d, face holds", dur, WARHEAD.CONTACT_MAX_DUR)
		return
	end
	-- Carving again would fill in the rough edges of the jet's hole
	if mouthShape == shp and mouthPos and (r.pointWorld - mouthPos):length() < WARHEAD.CONTACT_SAME_FACE then
		log("det", "casing burst suppressed, the jet already cratered this face")
		return
	end
	carveMouth(shp, r.pointWorld, r.normalWorld)
	log("det", "casing burst carved a mouth (durability %d)", dur)
end

-- The part goes DETONATE_DESTROY_DELAY ticks later, once the clients got cl_killSound
-- contactPos: the fuse fires early, a blast centred on the drone would go off in the air
function FpvDrone:sv_detonate(contactPos)
	if self.sv.exploded then
		return
	end
	self.sv.exploded = true
	-- timer goes first, so the part still gets removed if a step below throws
	self.sv.detonateDelay = DETONATE_DESTROY_DELAY
	-- Camera off now, a wreck that won't go away shouldn't keep the view
	self.sv.camDead = true
	local e = VSFPV_LINK.drones[self.shape]
	if e then
		e.camDead = true
		e.exploded = true -- see FpvController:sv_wreckBackstop
	end
	-- sv_armWarhead made it indestructible
	local wasDestructable = self.shape:getBody().destructable
	self.shape:getBody():setDestructable(true)
	log(
		"det",
		"detonate: armed=%s destructable=%s delay=%d",
		tostring(self.sv.armed),
		tostring(wasDestructable),
		self.sv.detonateDelay
	)
	local axis = self:sv_noseAxis()
	local dronePos, jetPos = self:sv_jetOrigin(axis)
	-- One failing step shouldn't cancel the rest. The scan goes first, it needs the geometry intact
	local hitBody, mouthShape, mouthPos = nil, nil, nil
	try("detonation step penetrate", function()
		hitBody, mouthShape, mouthPos = self:sv_penetrate(jetPos, axis)
	end)
	-- BLAST_EFFECT is empty, no vanilla fireball
	try("detonation step explode", function()
		sm.physics.explode(
			jetPos,
			WARHEAD.EXP_LEVEL,
			WARHEAD.EXP_DESTROY_R,
			WARHEAD.EXP_IMPULSE_R,
			WARHEAD.EXP_MAGNITUDE,
			WARHEAD.BLAST_EFFECT,
			self.shape
		)
	end)
	try("detonation step casingBurst", function()
		self:sv_casingBurst(dronePos, contactPos, mouthShape, mouthPos)
	end)
	try("detonation step jetImpulse", function()
		self:sv_jetImpulse(jetPos, axis, hitBody)
	end)
	try("detonation step blastWave", function()
		self:sv_blastWave(jetPos, contactPos, self:sv_attacker())
	end)
	local rot = sm.vec3.getRotation(UP, axis)
	sm.effect.playEffect(WARHEAD.HEATJET_EFFECT, jetPos, nil, rot)
	self.network:sendToClients("cl_killSound") -- while the part still exists
end
