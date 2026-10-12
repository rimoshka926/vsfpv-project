-- has to be global, dofile'd scripts don't see our locals
if VSFPV_CFG then
	return
end

local CFG = {}

CFG.THRUST = {
	THROTTLE_RATE = 1.50, -- per second on W/S
	SPOOL_TAU = 0.20,
	COAST_TAU = 1.00,
	TWR_MAX = 3.0, -- hover at rpm 1/sqrt(TWR)
	GRAVITY = 9.82,
	MAX_SPEED = 60.0,
	AIR_DENSITY0 = 1.225,
	SCALE_HEIGHT = 8500.0,
	-- the game adds ~0.016 on top of this
	DRAG_CD_A = 0.075,
	-- per axis, tuned by dropping it with the motors off
	DRAG_AXIAL = 0.139,
	DRAG_FRONTAL = 0.012,
	DRAG_LATERAL = 0.060, -- not measured
	ROTOR_DISK_A = 0.18,
	ROTOR_RADIUS = 0.55,
	GROUND_PROBE = 6.0,
	GROUND_MAX = 1.30,
	CLIMB_FACT_MIN = 0.35,
	CLIMB_FACT_MAX = 1.40,
}

-- Linear on purpose. With expo it twitched, a tick only gets 1-2 mouse frames.
CFG.ACRO = {
	YAW_RATE = math.rad(134),
	YAW_SIGN = -1.0,
	YAW_TAU_UP = 0.18,
	YAW_TAU_DOWN = 0.05,
	MOUSE_GAIN = 15.0,
	MAX_PR_RATE = math.rad(500),
	PITCH_SIGN = -1.0, -- like a stick, key 7 flips it
	ROLL_SIGN = -1.0,
	RATE_KP = 14.4,
	MAX_ANG_ACC = 72.0,
	LEVEL_TIME = 1.5, -- auto-level after takeoff, 0 = off
	LEVEL_KP = 6.0,
	INERTIA_COEF = 0.010, -- per kg, one block is about 0.0104
	ARM_RPM = 0.05,
	WHEEL_THROTTLE_STEP = 0.01, -- one wheel notch, 1% on the OSD
}

CFG.ANGLE = {
	ALT_VKP = 0.30,
	ALT_KP = 0.35,
	ALT_KD = 0.35,
	ALT_STOP_VZ = 0.30,
	ALT_TILT_MIN = 0.30,
	YAW_RATE = math.rad(250),
	YAW_GAIN = 44.0,
	YAW_SIGN = 1.0,
	MOVE_FB_SIGN = 1.0,
	MOVE_LR_SIGN = 1.0,
	-- heading hold (tilting on two axes at once adds a little yaw)
	HOLD_KP = 4.0, -- well below the rate loop, no ringing
	HOLD_MAX_RATE = math.rad(60),
	HOLD_CAPTURE_RATE = math.rad(3),
	HOLD_SETTLE = 0.4,
	HOLD_MIN_UP = 0.3, -- past ~72 degrees it's a tumble
	-- Yaw reacts slower than tilt to the same torque
	YAW_TORQUE_MATCH = 1.6,
}

CFG.MASK = {}
-- static stuff only, so a drone parked on a vehicle doesn't get pushed
-- (voxelTerrain is a separate filter since 1.0)
CFG.MASK.WORLD = sm.physics.filter.terrainSurface
	+ sm.physics.filter.terrainAsset
	+ sm.physics.filter.voxelTerrain
	+ sm.physics.filter.staticBody
CFG.MASK.SOLID = CFG.MASK.WORLD + sm.physics.filter.dynamicBody
CFG.MASK.SOLID_CHAR = CFG.MASK.SOLID + sm.physics.filter.character

-- Mavic Return to Home (fpv_drone_rth.lua)
CFG.RTH = {
	CRUISE_AGL = 12.0,
	CRUISE_SPEED = 12.0,
	APPROACH_KP = 0.45,
	LEAN = 0.45,
	ANGLE_KP = 4.5,
	YAW_KP = 2.6,
	YAW_MAX = math.rad(150),
	VEL_KP = 0.30,
	BRAKE_ACCEL = 4.0,
	STOP_MARGIN = 7.0,
	CLIMB_RATE = 5.0,
	DESCEND_RATE = 2.2,
	ALT_VKP = 0.32,
	ALT_PKP = 0.45,
	GROUND_PROBE = 80.0,
	ARRIVE_RADIUS = 3.0,
	LAND_HEIGHT = 1.0,
	TOUCHDOWN_AGL = 0.35,
	TOUCHDOWN_VZ = 0.4,
	HOME_GROUND_MAX = 1.5,
	CLEAR_TAPS = 3,
	CLEAR_TAP_GAP = 12, -- ticks, short so a normal start/cancel doesn't clear home
	-- sphere casts, plain rays kept missing trees
	PROBE_DIST = 28.0,
	BODY_RADIUS = 1.3, -- big on purpose, smooths bumpy cliffs
	CEILING_PROBE = 30.0,
	CEILING_MARGIN = 2.5,
	CEILING_NRM = -0.30, -- a cliff face (normal.z ~0) isn't a roof
	AZ_OFFSETS = { 0, 25, -25, 50, -50, 75, -75, 100, -100 },
	EL_OFFSETS = { 0, 20, 40 }, -- never dives to dodge
	SCAN_TIME = 0.15,
	SAFE_CLEAR = 9.0,
	W_PROGRESS = 1.00,
	W_ROOM = 0.45,
	W_CLIMB = 0.40,
	W_TURN = 0.12,
	CLIMBVZ_MAXEL = 40.0,
	ESCAPE_EL = 80.0,
	STUCK_TIME = 3.0,
	STUCK_EPS = 2.0,
	LANE_CLEAR = 18.0,
	WALL_DIST = 5.0,
	WALL_HYST = 2.0,
	WALL_AHEAD = 11.0,
	WALL_TURN = 16.0,
	LEAVE_EPS = 3.0,
	FOLLOW_MAXT = 8.0,
	LOOP_RADIUS = 6.0,
	-- Trees and stones count, characters and triggers are dropped
	AVOID_MASK = sm.physics.filter.all,
	GROUND_MASK = CFG.MASK.SOLID,
}

-- PG-7 warhead. The jet itself is done in sv_penetrate.
CFG.WARHEAD = {
	ARM_RPM = 0.02,
	IMPACT_SPEED = 3.0, -- terrain only, anything else on touch
	EXP_LEVEL = 7,
	-- explode() breaks nothing below 0.125 and a whole 3x3 above it, the jet does the real damage
	EXP_DESTROY_R = 0.08,
	CONTACT_MAX_DUR = 4, -- casing burst only breaks durability 4 and under (metal 1 is 5)
	CONTACT_REACH = 0.30,
	CONTACT_SAME_FACE = 0.55,
	EXP_IMPULSE_R = 3.0, -- most of the push is JET_IMP
	DETACHED_DESTROY_R = 1.5,
	EXP_MAGNITUDE = 200.0,
	PROX_MIN_SPEED = 6.0,
	PROX_RADIUS = 0.35, -- bigger and it goes off skimming past things
	PROX_STANDOFF = 0.25,
}
CFG.WARHEAD.HEATJET_EFFECT = "VSFPV - HeatJet"
CFG.JETTRAIL = { FX = "VSFPV - JetTrail", STEP = 0.22, MAX = 28 }
-- empty effect so explode() doesn't play the vanilla fireball
CFG.WARHEAD.BLAST_EFFECT = "VSFPV - Blank"
-- Penetration. Each cell and air gap the jet crosses uses up budget.
CFG.PEN = {
	DEPTH = 7.8,
	BACKOFF = 0.6,
	SCAN_MAX_HITS = 24,
	-- in cells of metal 3, this is the main knob
	BUDGET = 4.55,
	CELL = 0.25,
	DEFAULT_COST = 0.6,
	PART_COST = 0.4,
	TERRAIN_COST = 2.0,
	GAP_FREE = 0.35, -- a shaped charge likes a bit of standoff
	GAP_COST = 0.8,
	-- crater and channel are dug by hand, see sv_craterVoxel
	CRATER_R = 0.80,
	CHANNEL_R = 0.30,
	CRATER_STEP = 0.22, -- < CHANNEL_R so they join up
	CRATER_STRENGTH = 10.0, -- vanilla uses 10
	CRATER_MAX = 10,
	THIN_STEP = 0.35, -- past parts with no Shape (joints, bearings, lifts)
	AIM_SCAN_BACK = 1.5,
	AIM_SCAN_REACH = 4.0,
	JET_ORIGIN_FWD = 0.47,
	ENTRY_INTACT_MIN = 2,
	ENTRY_INTACT_MAX = 3,
	ENTRY_FIRE_R = 0.25, -- vanilla flame size
}
-- Same materials vanilla explosives dig
do
	local vf = sm.world.voxelFilter
	CFG.PEN.VOXEL_FILTER = vf.material0 + vf.material1 + vf.material2 + vf.material3
end

-- Budget per cell, metal 3 = 1.0
CFG.PEN_ARMOR = {
	-- Metal
	["c0dfdea5-a39d-433a-b94a-299345a5df46"] = 1.00, -- blk_metal3
	["1016cafc-9f6b-40c9-8713-9019d399783f"] = 0.85, -- blk_metal2
	["027bd4ec-b16d-47d2-8756-e18dc2af3eb6"] = 0.85, -- blk_spaceshipmetal
	["8aedf6c2-94e1-4506-89d4-a0227c552f1e"] = 0.65, -- blk_metal1
	["f7d4bfed-1093-49b9-be32-394c872a1ef4"] = 0.65, -- blk_treadplate
	["073f92af-f37e-4aff-96b3-d66284d5081c"] = 0.60, -- blk_lights
	["3e3242e4-1791-4f70-8d1d-0ae9ba3ee94c"] = 0.60, -- blk_warehousefloor
	["920b40c8-6dfc-42e7-84e1-d7e7e73128f6"] = 0.55, -- blk_restroom
	["1f7ac0bb-ad45-4246-9817-59bdf7f7ab39"] = 0.50, -- blk_scrapmetal
	["d740a27d-cc0f-4866-9e07-6a5c516ad719"] = 0.50, -- blk_wornmetal
	["4ad97d49-c8a5-47f3-ace3-d56ba3affe50"] = 0.50, -- blk_spaceshipfloor
	["220b201e-aa40-4995-96c8-e6007af160de"] = 0.40, -- blk_metalbricks
	["25a5ffe7-11b1-4d3e-8d7a-48129cbaf05e"] = 0.30, -- blk_beam
	["3d0b7a6e-5b40-474c-bbaf-efaa54890e6a"] = 0.25, -- blk_crossnet
	["4aa2a6f0-65a4-42e3-bf96-7dec62570e0b"] = 0.20, -- blk_metalnet
	["ea6864db-bb4f-4a89-b9ec-977849b6713a"] = 0.20, -- blk_tryponet
	["a479066d-4b03-46b5-8437-e99fec3f43ee"] = 0.20, -- blk_stripednet
	["b4fa180c-2111-4339-b6fd-aed900b57093"] = 0.20, -- blk_squarenet
	-- Stone and concrete
	["e281599c-2343-4c86-886e-b2c1444e8810"] = 0.70, -- blk_concrete3
	["ff234e42-5da4-43cc-8893-940547c97882"] = 0.55, -- blk_concrete2
	["a6c6ce30-dd47-4587-b475-085d55c6a3b4"] = 0.45, -- blk_concrete1
	["0603b36e-0bdb-4828-b90c-ff19abcdfe34"] = 0.45, -- blk_bricks
	["8ca49bff-eeef-4b43-abd0-b527a567f1b7"] = 0.45, -- blk_tiles
	["cd0eff89-b693-40ee-bd4c-3500b23df44e"] = 0.45, -- blk_concretetiles
	["30a2288b-e88e-4a92-a916-1edbfc2b2dac"] = 0.40, -- blk_scrapstone
	["f5ceb7e3-5576-41d2-82d2-29860cf6e20e"] = 0.40, -- blk_crackedconcrete
	["b145d9ae-4966-4af6-9497-8fca33f9aee3"] = 0.30, -- blk_drywall
	["c56700d9-bbe5-4b17-95ed-cef05bd8be1b"] = 0.30, -- blk_sand
	-- Glass
	["b5ee5539-75a2-4fef-873b-ef7c9398b3f5"] = 0.40, -- blk_armoredglass
	["5f41af56-df4c-4837-9b3c-10781335757f"] = 0.20, -- blk_glass
	["749f69e0-56c9-488c-adf6-66c58531818f"] = 0.20, -- blk_glasstile
	-- Wood
	["061b5d4b-0a6a-4212-b0ae-9e9681f1cbfb"] = 0.35, -- blk_wood3
	["1897ee42-0291-43e4-9645-8c5a5d310398"] = 0.30, -- blk_wood2
	["df953d9c-234f-4ac2-af5e-f0490b223e71"] = 0.25, -- blk_wood1
	["1fc74a28-addb-451a-878d-c3c605d63811"] = 0.25, -- blk_scrapwood
	-- Plastic and soft stuff
	["628b2d61-5ceb-43e9-8334-a4135566df7a"] = 0.30, -- blk_plastic
	["e981c337-1c8a-449c-8602-1dd990cbba3a"] = 0.30, -- blk_plasticwall
	["09ca2713-28ee-4119-9622-e85490034758"] = 0.30, -- blk_caution
	["9be6047c-3d44-44db-b4b9-9bcf8a9aab20"] = 0.15, -- blk_insulation
	["febce8a6-6c05-4e5d-803b-dfa930286944"] = 0.15, -- blk_carpet
	["f406bf6e-9fd5-4aa0-97c1-0b3c2118198e"] = 0.12, -- blk_bubblewrap
	["f0cba95b-2dc4-4492-8fd9-36546a4cb5aa"] = 0.12, -- blk_cardboard
}
-- shrapnel damage goes through the PvP mod's meleeAttack hook, so cover works
CFG.SHRAP = {
	MELEE_UUID = sm.uuid.new("e7fa1286-152e-463b-a126-100478f50aa8"), -- sledgehammer, the PvP mod reads it
	JET_CORE_DMG = 150.0,
	JET_CORE_RANGE = 4.0,
	DAMAGE = 55.0,
	COUNT = 29, -- the main strength setting
	CONE = 35.0,
	RANGE = 4.0,
	MIN_BUDGET = 0.12,
	BREAK_CHANCE = 0.85,
	FX = "VSFPV - Spall", -- Effects/Database/EffectSets/vsfpv.json
	INTERIOR_DMG_MULT = 1.80,
}
CFG.RICO = {
	MAX_BOUNCES = 2,
	ENERGY = 0.55,
	SCATTER = 14.0,
	MIN_ENERGY = 0.20,
}
CFG.JET_IMP = {
	RADIUS = 6.0,
	FORCE = 900.0,
	CHAR_DIV = 8.0,
}
-- the PvP mod's explode hook only does flat damage, falloff is ours
CFG.BLAST_DMG = {
	R = 5.0,
	-- ~140 at 1.2 m, 20 at 3 m
	MAX = 320.0, -- players have 100 in the PvP mod
	MIN = 6.0, -- no scratches or kill feed spam at the edge
	FALLOFF_POW = 3.0,
	-- contact with the drone body itself, the jet point can be metres ahead
	CONTACT_R = 0.75,
	CONTACT_MAX = 70.0,
	CONTACT_FALLOFF_POW = 1.0,
	CHAR_HALF_H = 0.85,
	CHAR_RADIUS = 0.25,
}
CFG.SELF_DMG = {
	-- the PvP mod blocks melee on yourself, a projectile gets through (at half damage)
	PROJECTILE = sm.uuid.new("5e8eeaae-b5c1-4992-bb21-dec5254ce722"), -- projectile_potato
	SCALE = 2.0,
	SPEED = 90.0,
	STANDOFF = 2.5,
}
-- Just long enough for cl_killSound
CFG.DETONATE_DESTROY_DELAY = 2

-- chain reactions: destroyPart doesn't set off explosive parts, and onExplosion needs 5 ticks
CFG.CHAIN = {
	-- Explosive.lua ignores the arguments
	SIGNAL = "server_onExplosion",
	SWEEP_TICKS = 10, -- longer than vanilla's 5 tick fuse
	SWEEP_MAX = 64,
}

-- Water is an area trigger, there's no collider
CFG.WATER = {
	PROBE_HALF = 0.30,
	SINK_VZ = -2.0,
	SINK_PUSH = 0.35,
	DAMP_KP = 0.15,
	POLL_EVERY = 2,
	-- Removing the part is what ends the looping sound
	DROWN_TICKS = 24,
}

-- Crash tiers for drones without a warhead: props break, then the camera, then the drone is gone.
CFG.CRASH = {
	PROPS_SPEED = 4.0,
	KILL_SPEED = 9.0,
	DESTROY_SPEED = 18.0,
	SMASH_TICKS = 3, -- so cl_crash gets there first
	PROX_MIN_SPEED = 6.0,
	PROX_RADIUS = 0.35,
	PROX_STANDOFF = 0.15,
	DEBRIS_FX = "Sledgehammer - Destroy",
	DEBRIS_MATERIAL = 8.0, -- plastic
	DEBRIS_VOLUME = { 2.0, 5.0, 9.0 },
}

CFG.FLOOR = {
	PROBE_UP = 1.5,
	PROBE_DOWN = 6.0,
	PEN_MAX = 1.5, -- further up is a ceiling
	KP = 80.0,
	MIN_SINK = 8.0,
}

-- keyed by shape uuid
CFG.DRONES = {
	["c9e2b1b3-4f9b-4e8c-8c7a-9a8b7c6d5e4f"] = {
		name = "PG-7 Kamikaze",
		shortName = "PG-7",
		mode = "acro",
		warhead = true,
		visionModes = true,
		horizonOsd = true,
		analogCam = true,
		subMeshes = { "drone" },
		dragAniso = true,
		twrMax = 3.5, -- the flat-fall drag also slowed the climb
		rateKp = 17.3,
		maxAngAcc = 86.0,
	},

	["188d229e-24d7-4033-9d81-510f0dffe0bf"] = {
		name = "Mavic 3 Cine",
		shortName = "Mavic",
		mode = "angle",
		warhead = false,
		propBones = { "prop1", "prop2", "prop3", "prop4" },
		gimbal = true,
		zoomMax = 7.0,
		subMeshes = { "material_0", "material_1" },
		-- The measured -0.065 sees through the ground when parked
		camOffset = { fwd = 0.155, up = -0.015 },
		twrMax = 2.5,
		dragCdA = 0.020,
		rotorDiskA = 0.10,
		rotorRadius = 0.36,
		crashPropsSpeed = 3.5,
		crashKillSpeed = 8.0,
		crashDestroySpeed = 16.0,
		angleModeDefault = 2,
		angleModes = {
			{
				name = "CINE",
				lean = 0.50,
				angleKp = 2.56,
				altRate = 3.0,
				gimbalScale = 1.2,
			},
			{
				name = "NORMAL",
				lean = 0.55,
				angleKp = 4.8,
				altRate = 4.0,
				gimbalScale = 1.0,
			},
			-- Top speed ~ CdA^-0.31, measured
			{
				name = "SPORT",
				lean = 0.75,
				angleKp = 4.76,
				altRate = 7.5,
				gimbalScale = 1.0,
				dragCdA = 0.0098,
			}, -- ~75 km/h
		},
	},

	-- the real one is 0.795 kg and does ~140 km/h
	["0066004c-5ff6-40c6-9531-6a2f5022ab04"] = {
		name = "DJI FPV",
		shortName = "DJI",
		subMeshes = { "waike", "jiangye", "jibi", "jishen_2", "boli", "neibu" },
		camOffset = { fwd = 0.04, up = -0.015 },
		mode = "acro",
		warhead = false,
		propBones = { "prop1", "prop2", "prop3", "prop4" },
		-- Cruise barely follows twrMax, the game's drag dominates
		twrMax = 6.5,
		dragAniso = true,
		dragAxial = 0.020, -- flat fall ~65 km/h
		dragFrontal = 0.0029, -- nose-first ~115
		dragLateral = 0.009,
		rotorDiskA = 0.05,
		rotorRadius = 0.24,
		-- light enough that it snapped around without a bit of smoothing
		prTau = 0.084,
		maxPrRate = math.rad(430),
		crashPropsSpeed = 7.0,
		crashKillSpeed = 15.0,
		crashDestroySpeed = 28.0,
	},
}

-- Real Mavic 3 range
CFG.GIMBAL_MIN = math.rad(-90)
CFG.GIMBAL_MAX = math.rad(35)
-- gimbal anim frames 1..24 come from the Blender rig
CFG.FX = {
	PROP_SPIN_NAME = "Armature|spin",
	PROP_SPIN_HZ = 10.0,
	RPM_SEND_EVERY = 4,
	-- Stepped rpm makes the pitch jump at every update
	RPM_SND_TAU = 0.08,
	GIMBAL_ANIM_NAME = "Armature|gimbal",
	MOTOR_VEL_MAX = 60.0, -- a network correction can spike the interpolated speed
	MOTOR_VEL_SMOOTH = 0.35,
	PROP_BONES = { "prop", "prop2", "prop3", "prop4" },
	MOTOR_DETUNE = { -0.030, -0.012, 0.012, 0.030 },
	SND_LO_IN = 0.40, -- rough band is 30-50% rpm
	SND_LO_OUT = 0.30,
	SND_HI_IN = 0.46,
	SND_HI_OUT = 0.50,
}
-- mods can't add FMOD banks, this is a vanilla engine sound in our own effect
CFG.FX.MOTOR_VOICE = { prop = "VSFPV - Snd ElEngine2", loadFix = 0.05 } -- long 5.72 s layer

CFG.FX.GIMBAL_NEUTRAL = (0.0 - CFG.GIMBAL_MIN) / (CFG.GIMBAL_MAX - CFG.GIMBAL_MIN)

-- debug log channels to print: general, water, rth, snd, pen, det, flight. general and water also go to chat
CFG.DEBUG_LOG = {}
CFG.WRECK_REPORT_AFTER = 2.0
CFG.FLIGHT_DIAG_EVERY = 8 -- ticks
CFG.TELEM_INTERVAL = 1.0

-- Transmitter

CFG.PAIR_RADIUS = 15.0
CFG.FOV_BASE = 90.0
-- Real lens: fov = 2 atan(tan(base/2) / zoom)
CFG.ZOOM_STEP = 0.5
CFG.ZOOM_LERP = 9.0
-- Shapes can't hide at runtime, hence an effect
CFG.TX_HELD_EFFECT = "VSFPV - TransmitterHeld"
-- pose0 collapses the mesh, needs FpvController.poseWeightCount
CFG.TX_POSE = 0

-- Part frame, x right, y up, z forward
CFG.TX_HELD_FALLBACK = sm.vec3.new(0.0, 0.83, 0.25)
CFG.TX_HELD_NUDGE = sm.vec3.new(0.0, 0.0, 0.010)

-- Screen tipped 30 degrees towards the face
CFG.TX_HELD_ROT = sm.quat.angleAxis(math.rad(180.0), sm.vec3.new(0, 0, 1))
	* sm.quat.angleAxis(math.rad(-120.0), sm.vec3.new(1, 0, 0))

-- Effects draw in metres, parts in blocks
CFG.TX_SCALE = 0.25
CFG.CAM_LERP = 80.0
CFG.WRECK_BACKSTOP_TICKS = 40
-- PG-7 lens, between the front motors
CFG.CAM_OFFSET = { fwd = 0.22, up = 0.0 }
CFG.CAM_RELEASE_RETRY = 30
CFG.NOTIFY_FRAMES = 200
CFG.SEAT_GUARD_FRAMES = 20
CFG.OSD_EVERY = 3
CFG.GIMBAL_GAIN = 0.10
CFG.GIMBAL_SIGN = 1.0
-- off is DJI's FPV gimbal mode (the horizon rolls with the drone), on is like their Follow mode
CFG.HORIZON_LOCK_DEFAULT = false
CFG.HORIZON_LOCK_MIN_UP = 0.15 -- cos(81 deg), a crash, never a lean
-- PG-7 analog camera look
CFG.ANALOG = {
	IMAGE_DIR = "$CONTENT_DATA/Gui/Images/Analog/",
	FIELD_RATE = 30,
	GRAIN_FRAMES = 16,
	MOTOR_FRAMES = 16, -- per level
	MOTOR_STEPS = { 30, 60, 85 }, -- throttle %
	GLITCH_GAP = { 8.0, 25.0 },
	BURST_FRAMES = 5,
	BURST_LENGTH = { 3, 6 },
	ROLL_FRAMES = 12,
	ROLL_START = 3,
	ROLL_STEP = { 1, 2 },
	STATIC_FRAMES = 6,
	STATIC_HOLD = 1.2,
}
-- Never shipped, so an update can't overwrite it
CFG.PREFS = {
	PATH = "$CONTENT_DATA/pilot_settings.json",
	PITCH_INVERTED_DEFAULT = false,
}

CFG.HORIZON_OSD = {
	DISTANCE = 2000.0,
	STEP = 6.0,
	GAP = 4.5,
	MAX = 22.0,
	POOL = 4, -- icons per side
	ROLL_STEP = 5, -- world icons can't rotate, one image per step
	MARKER_PX = 25,
	RETICLE_PX = 42,
	REF_HEIGHT = 1080,
	MIN_LEVEL = 0.05,
	CHEVRON_IMAGE = "$CONTENT_DATA/Gui/Images/Horizon/fpv_chevron_%02d.png", -- 0..71
	RETICLE_IMAGE = "$CONTENT_DATA/Gui/Images/fpv_reticle.png",
	-- Far away so world icons keep their size
	MAX_RENDER_DISTANCE = 100000.0,
	CENTRE_HIDE_DEG = 2.5,
}

-- Night vision. Mods can't add a LUT, so it's a green light plus green fog.
CFG.NV = {
	LIGHT = { 0.06, 1.0, 0.20, 1.0 },
	-- Beat the ~0.5 ambient, colours return under 2.5
	INTENSITY = 3.5,
	FAR_INTENSITY = 2.0,
	-- Follows the draw distance, past it colours return
	RANGE_MUL = 1.15,
	RANGE_FALLBACK = 2000.0,
	GI = 0.0,
	-- Time of day: 0 and 1 midnight, 0.5 noon
	OUTDOOR = 0.0,
	-- Vanilla night fog (tod_night.rendersettings), green instead of blue
	FOG = {
		start = 0.0,
		fin = 1226.19,
		falloff = 0.311,
		startColor = { 0.020, 0.100, 0.030, 0.711 },
		endColor = { 0.020, 0.140, 0.030, 1.0 },
		vOpacity = 0.5,
		vFade = 642.851,
		vFalloff = 0.871,
		vStart = -103.18,
		vEnd = 71.42,
		vStartColor = { 0.010, 0.080, 0.020, 0.0 },
		vEndColor = { 0.010, 0.090, 0.020, 0.301 },
		fade = 873.01,
	},
}

VSFPV_CFG = CFG
