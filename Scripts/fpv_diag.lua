-- Debug logging, CFG.DEBUG_LOG in fpv_config.lua picks the channels
if VSFPV_DIAG then
	return
end

local DEBUG_LOG = VSFPV_CFG.DEBUG_LOG

local CHANNELS = {
	general = { tag = "[VSFPV] ", chat = true },
	water = { tag = "[VSFPV-WATER] ", chat = true },
	rth = { tag = "[VSFPV-RTH] " },
	snd = { tag = "[VSFPV-SND] " },
	pen = { tag = "[VSFPV-PEN] " },
	det = { tag = "[VSFPV-DET] " },
	flight = { tag = "[VSFPV-FLIGHT] " },
}

-- Once per distinct message, so an error that repeats every frame can't flood the log
local reported = {}
local function fault(where, err)
	local msg = where .. ": " .. tostring(err)
	if not reported[msg] then
		reported[msg] = true
		print("[VSFPV] error in " .. msg)
	end
end

local function try(where, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		fault(where, err)
	end
end

local function log(channel, fmt, ...)
	if not DEBUG_LOG[channel] then
		return
	end
	local ch = CHANNELS[channel]
	local msg = ch.tag .. (select("#", ...) > 0 and string.format(fmt, ...) or fmt)
	print(msg)
	if ch.chat then
		sm.gui.chatMessage(msg)
	end
end

VSFPV_DIAG = {
	log = log,
	fault = fault,
	try = try,
}
