-- Pilot preferences, kept per player in the mod folder instead of the world.
-- Client only: in multiplayer the server would write to the host's disk

local PREFS = VSFPV_CFG.PREFS
local log = VSFPV_DIAG.log
local fault = VSFPV_DIAG.fault
local try = VSFPV_DIAG.try

local prefs = nil

local function readPrefs()
	local out = { pitchInverted = PREFS.PITCH_INVERTED_DEFAULT, helpHidden = {} }
	local ok, err = pcall(function()
		if not sm.json.fileExists(PREFS.PATH) then
			return
		end
		local data = sm.json.open(PREFS.PATH)
		if type(data) ~= "table" then
			return
		end
		if type(data.pitchInverted) == "boolean" then
			out.pitchInverted = data.pitchInverted
		end
		if type(data.helpHidden) == "table" then
			for model, hidden in pairs(data.helpHidden) do
				if type(model) == "string" and hidden == true then
					out.helpHidden[model] = true
				end
			end
		end
	end)
	if not ok then
		fault("prefs read", err)
	end
	return out
end

local function writePrefs(p)
	try(
		"prefs save",
		sm.json.save,
		{ pitchInverted = p.pitchInverted, helpHidden = p.helpHidden },
		PREFS.PATH
	)
end

function FpvController:cl_prefs()
	if not prefs then
		prefs = readPrefs()
	end
	return prefs
end

function FpvController:cl_togglePitchInverted()
	local p = self:cl_prefs()
	p.pitchInverted = not p.pitchInverted
	writePrefs(p)
	self:cl_notify(p.pitchInverted and "INVERT PITCH ON" or "INVERT PITCH OFF")
	log("general", "invert pitch " .. (p.pitchInverted and "on" or "off"))
end

-- Only hidden models are stored, so a new model shows its help
function FpvController:cl_helpHidden(model)
	return model ~= nil and self:cl_prefs().helpHidden[model] == true
end

function FpvController:cl_setHelpHidden(model, hidden)
	if model == nil then
		return
	end
	local p = self:cl_prefs()
	p.helpHidden[model] = hidden or nil
	writePrefs(p)
end
