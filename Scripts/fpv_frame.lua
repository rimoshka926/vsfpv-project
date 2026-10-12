-- Axis helpers for both part scripts
if VSFPV_FRAME then
	return
end

local UP = sm.vec3.new(0, 0, 1)

-- setRotation looks down +Z, a block's +Z is up
local CAM_FIX = sm.quat.angleAxis(math.rad(-90.0), sm.vec3.new(1, 0, 0))

-- meshes face backwards (inventory icon), 1.0 after a re-export
local NOSE_SIGN = -1.0

-- same flip for the camera, about the prop axis
local function noseFrame(rot)
	return sm.quat.angleAxis(math.pi, sm.quat.getAt(rot)) * rot
end

local function clamp(v, lo, hi)
	if v < lo then
		return lo
	elseif v > hi then
		return hi
	end
	return v
end

VSFPV_FRAME = {
	UP = UP,
	CAM_FIX = CAM_FIX,
	NOSE_SIGN = NOSE_SIGN,
	noseFrame = noseFrame,
	clamp = clamp,
}
