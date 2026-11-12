-- muxd: session core for mux, a tmux-like terminal multiplexer for OpenOS.
--
-- A "session" is a set of windows, each window a binary split tree of panes.
-- Every pane runs a full shell (or a command) in its own process (coroutine)
-- with a private environment whose component layer virtualizes the GPU:
-- each pane sees a real GPU text buffer (VRAM page) as its whole screen, so
-- vt100/tty/term AND direct gpu users are confined to the pane bounds.
-- mux composites dirty panes onto the physical screen with bitblt and owns
-- the keyboard, routing input (or mux commands after the ^B prefix) to panes.
--
-- Detach re-parents pane wakeups to the init process and quits the client;
-- panes keep running (minus keyboard). Re-attach re-parents them to the new
-- mux process.

local process = require("process")
local pipe = require("pipe")
local event = require("event")
local component = require("component")
local computer = require("computer")
local keyboard = require("keyboard")
local term = require("term")
local fs = require("filesystem")
local buffer = require("buffer")
local thread = require("thread")

local unicode = require("unicode")
local RAWKEYS = {
	b = 0x30, c = 0x2E, d = 0x20, q = 0x10, w = 0x11, x = 0x2D, z = 0x2C,
	o = 0x18, n = 0x31, p = 0x19, h = 0x23, j = 0x24, k = 0x25, l = 0x26,
	left = 0xCB, right = 0xCD, up = 0xC8, down = 0xD0,
}
local keys = setmetatable({}, {__index = function(_, name)
	local ok, value = pcall(function() return keyboard.keys[name] end)
	if ok and value then
		return value
	end
	return RAWKEYS[name]
end})

local muxd = {}

local SESSION_KEY = "mux_session"

-- PC scancodes of the modifier keys. A shifted command key like % or " arrives
-- as three events: shift-down, key-down, key-up.
local MODIFIER_CODES = {
	[0x1D] = true, [0x9D] = true,	-- left / right control
	[0x2A] = true, [0x36] = true,	-- left / right shift
	[0x38] = true, [0xB8] = true,	-- left / right alt
	[0x3A] = true,					-- caps lock
}

local INPUT = {
	key_down = true, key_up = true, clipboard = true,
	touch = true, drag = true, drop = true, scroll = true,
	interrupted = true,
}

-- Modifier state has to be maintained by mux. OpenOS feeds
-- keyboard.pressedCodes/pressedChars from the listener its init boot script
-- registers (boot/92_keyboard.lua), and handler tables are per process: neither
-- a mux client (a child of some shell) nor a pane process ever dispatches
-- init's handlers, so isControlDown() would stay false forever - the ^B prefix
-- would never arm and a pane would never read ^D as EOF. mux observes every key
-- signal, so it keeps that state current itself, and panes share these very same
-- tables (see makeEnv) so programs inside a pane see the real modifiers.
-- While detached init dispatches again and feeds the same tables.
keyboard.pressedCodes = keyboard.pressedCodes or {}
keyboard.pressedChars = keyboard.pressedChars or {}

local function trackKeys(sig)
	if sig[1] ~= "key_down" and sig[1] ~= "key_up" then
		return
	end
	local down = sig[1] == "key_down"
	if sig[3] ~= nil then
		keyboard.pressedChars[sig[3]] = down or nil
	end
	if sig[4] ~= nil then
		keyboard.pressedCodes[sig[4]] = down or nil
	end
end

-- what we believe about the keyboard can go stale: a key may have been released
-- while no mux client was pulling, or stolen by the client we are replacing
local function forgetKeys()
	for k in pairs(keyboard.pressedCodes) do
		keyboard.pressedCodes[k] = nil
	end
	for k in pairs(keyboard.pressedChars) do
		keyboard.pressedChars[k] = nil
	end
end

local rootProc
do
	for _, p in pairs(process.list) do
		if not p.parent then
			rootProc = p
			break
		end
	end
end

local session = _G[SESSION_KEY]
local realGpu, screenAddr, kbAddr
local clientToken

local uptime = computer.uptime

local function noteError(s, msg)
	s.lastError = msg
	s.errorExpire = uptime() + 8
end

local function ensureHardware()
	if not component.isAvailable("gpu") or not component.isAvailable("screen") then
		return nil, "mux needs a gpu and a screen"
	end
	realGpu = component.gpu
	screenAddr = realGpu.getScreen()
	if not screenAddr then
		return nil, "the gpu is not bound to a screen"
	end
	kbAddr = component.isAvailable("keyboard") and component.keyboard.address or nil
	return true
end

local function screenSize()
	return realGpu.getViewport()
end

local function allPanes(s)
	local result = {}
	for _, win in ipairs(s.windows) do
		for _, pane in ipairs(win.panes) do
			if not pane.dead then
				result[#result + 1] = pane
			end
		end
	end
	return result
end

-------------------------------------------------------------------------------
-- pane registration: parked panes wake through the handlers table of whatever
-- process is pumping signals (mux while attached, init while detached)

local function paneInterval(pane)
	if pane.pullDeadline then
		return math.max(0, pane.pullDeadline - uptime())
	end
	return math.huge
end

local function paneRegister(pane)
	if pane.dead or not pane.parentHandlers then
		return
	end
	pane.regId = event.register(nil, pane.wake, paneInterval(pane), 1, pane.parentHandlers)
	pane.regHandler = pane.parentHandlers[pane.regId]
end

local function paneUnregister(pane)
	local id, h = pane.regId, pane.regHandler
	pane.regId, pane.regHandler = nil, nil
	if id and pane.parentHandlers and pane.parentHandlers[id] == h then
		pane.parentHandlers[id] = nil
	end
end

local function paneSetParent(pane, handlers)
	local wasParked = pane.regId ~= nil
	paneUnregister(pane)
	pane.parentHandlers = handlers
	if wasParked then
		paneRegister(pane)
	end
end

-------------------------------------------------------------------------------
-- the resume engine: drives a pane coroutine chain until it parks in a pull

local function resumeChain(pane, args, nargs)
	args, nargs = args or {}, nargs or 0
	for _ = 1, 96 do
		if pane.dead then
			return
		end
		pane.wantSignal = false
		local r = table.pack(pane.pco.resume(pane.co, table.unpack(args, 1, nargs)))
		if pane.pco.status(pane.co) == "dead" or not r[1] then
			muxd.paneFinalize(pane)
			return
		end
		if pane.wantSignal then
			paneRegister(pane) -- parked in pullSignal: wait for the next signal/deadline
			return
		end
		-- mid-stack yield (pipe machinery): re-resume the chain with the same values
		if r.n >= 2 then
			for i = 2, r.n do
				args[i - 1] = r[i]
			end
			nargs = r.n - 1
		else
			nargs = 0
		end
	end
	-- yielding wildly without ever pulling: re-arm to stay responsive
	paneRegister(pane)
end

-------------------------------------------------------------------------------
-- signal routing decisions (attached: computed up front in the client pull;
-- detached: decided in the wake itself)

local function attached()
	return session and session.clientToken ~= nil
end

local function deliverableDetached(name)
	return not name or not INPUT[name]
end

local function paneWake(pane, name, ...)
	if pane.dead then
		return
	end
	paneUnregister(pane)
	if attached() then
		if pane.deliverArgs then
			local d = pane.deliverArgs
			pane.deliverArgs = nil
			resumeChain(pane, d, d.n)
		elseif not name then
			resumeChain(pane, {}, 0) -- pull timeout
		else
			paneRegister(pane) -- this signal is not for us
		end
	else
		if deliverableDetached(name) then
			local d = table.pack(name, ...)
			resumeChain(pane, d, d.n)
		else
			paneRegister(pane) -- the keyboard belongs to whoever owns the terminal
		end
	end
end

-------------------------------------------------------------------------------
-- virtual gpu: presents one VRAM page to the pane as its whole screen

local function makeVgpu(pane)
	local v = {}
	local st = {fg = table.pack(realGpu.getForeground()), bg = table.pack(realGpu.getBackground())}

	local function act()
		realGpu.setActiveBuffer(pane.expect)
	end

	local function restore()
		realGpu.setActiveBuffer(0)
	end

	local function syncColors()
		realGpu.setForeground(st.fg[1], st.fg[2] or nil)
		realGpu.setBackground(st.bg[1], st.bg[2] or nil)
	end

	v.address = realGpu.address
	v.type = "gpu"

	v.set = function(x, y, value, vertical)
		act(); syncColors()
		local result, reason = realGpu.set(x, y, value, vertical)
		restore()
		pane.dirty = true
		return result, reason
	end

	v.get = function(x, y)
		act()
		local result = table.pack(realGpu.get(x, y))
		restore()
		return table.unpack(result, 1, result.n)
	end

	v.copy = function(x, y, w, h, tx, ty)
		act()
		local result, reason = realGpu.copy(x, y, w, h, tx, ty)
		restore()
		pane.dirty = true
		return result, reason
	end

	v.fill = function(x, y, w, h, value)
		act(); syncColors()
		local result, reason = realGpu.fill(x, y, w, h, value)
		restore()
		pane.dirty = true
		return result, reason
	end

	if realGpu.render then
		v.render = function(x, y, bitbuf)
			act()
			local result, reason = realGpu.render(x, y, bitbuf)
			restore()
			pane.dirty = true
			return result, reason
		end
	end

	if realGpu.blit then
		v.blit = function(x, y, ch, fg, bg)
			act()
			local result, reason = realGpu.blit(x, y, ch, fg, bg)
			restore()
			pane.dirty = true
			return result, reason
		end
	end

	local function setdims(w, h)
		if type(w) ~= "number" or type(h) ~= "number" or w < 1 or h < 1 then
			return false
		end
		w = math.min(math.floor(w), pane.bufw)
		h = math.min(math.floor(h), pane.bufh)
		local changed = w ~= pane.lw or h ~= pane.lh
		pane.lw, pane.lh = w, h
		muxd.syncWindow(pane)
		pane.dirty = true
		return changed
	end

	v.getResolution = function() return pane.lw, pane.lh end
	v.maxResolution = function() return pane.bufw, pane.bufh end
	v.setResolution = function(w, h) return setdims(w, h) end
	v.setViewport = function(w, h) return setdims(w, h) end
	v.getViewport = function() return pane.lw, pane.lh end

	v.getDepth = function() return realGpu.getDepth() end
	v.maxDepth = function() return realGpu.maxDepth() end
	v.setDepth = function(d) return realGpu.setDepth(d) end
	v.setMaxDepth = function() return realGpu.maxDepth() end

	v.getForeground = function() return st.fg[1], st.fg[2] end
	v.getBackground = function() return st.bg[1], st.bg[2] end

	v.setForeground = function(value, palette)
		local oval, opal = st.fg[1], st.fg[2]
		st.fg[1], st.fg[2] = value, not not palette
		return oval, opal and oval or nil
	end

	v.setBackground = function(value, palette)
		local oval, opal = st.bg[1], st.bg[2]
		st.bg[1], st.bg[2] = value, not not palette
		return oval, opal and oval or nil
	end

	v.bind = function() return true end
	v.bindSafe = function() return true end
	v.unbind = function() return true end
	v.getScreen = function() return screenAddr end

	v.allocateBuffer = function(w, h)
		if (w or pane.bufw) * (h or pane.bufh) > realGpu.freeMemory() then
			return nil, "not enough video memory"
		end
		return realGpu.allocateBuffer(w, h)
	end

	v.freeBuffer = function(index)
		index = index or pane.expect
		if index == pane.buf then
			return nil, "cannot free the terminal buffer"
		end
		return realGpu.freeBuffer(index)
	end

	v.freeAllBuffers = function()
		return nil, "not permitted inside mux"
	end

	v.getActiveBuffer = function() return pane.expect end

	v.setActiveBuffer = function(index)
		if index == nil or index == 0 then
			index = pane.buf
		end
		if index ~= pane.buf and not realGpu.getBufferSize(index) then
			return nil, "invalid buffer index"
		end
		local prev = pane.expect
		pane.expect = index
		return prev
	end

	v.bitblt = function(dst, col, row, w, h, src, fromCol, fromRow)
		local dstIdx = (dst == nil or dst == 0) and pane.buf or dst
		local srcIdx = (src == nil) and pane.expect or src
		local bw, bh = realGpu.getBufferSize(dstIdx)
		local result, reason = realGpu.bitblt(dstIdx, col or 1, row or 1,
			w or bw, h or bh, srcIdx, fromCol or 1, fromRow or 1)
		if dstIdx == pane.buf then
			pane.dirty = true
		end
		return result, reason
	end

	v.buffers = function() return realGpu.buffers() end
	v.totalMemory = function() return realGpu.totalMemory() end
	v.freeMemory = function() return realGpu.freeMemory() end
	v.getBufferSize = function(index) return realGpu.getBufferSize(index or pane.expect) end

	for _, name in ipairs({"size", "dumpSignal", "fetchSignal"}) do
		if realGpu[name] then
			v[name] = function(...) return realGpu[name](...) end
		end
	end

	return v
end

-------------------------------------------------------------------------------
-- component layer for the pane env: gpu calls go to the pane vgpu

local function makeComponent(pane)
	local v = pane.vgpu
	local gpuAddress = realGpu.address

	local function isGpu(address)
		return component.get(address, "gpu") == gpuAddress
	end

	local comp = setmetatable({}, {__index = function(_, key)
		if key == "gpu" then
			return v
		end
		return component[key]
	end})

	comp.invoke = function(address, method, ...)
		if isGpu(address) then
			local m = v[method]
			if not m then
				return nil, "no such method " .. tostring(method)
			end
			return m(...)
		end
		return component.invoke(address, method, ...)
	end

	comp.proxy = function(address)
		if isGpu(address) then
			return v
		end
		return component.proxy(address)
	end

	comp.getPrimary = function(kind)
		if kind == "gpu" then
			return v
		end
		return component.getPrimary(kind)
	end

	return comp
end

-------------------------------------------------------------------------------
-- pane process plumbing

local function paneRawPull(pane, timeout)
	pane.wantSignal = true
	pane.pullDeadline = timeout and (uptime() + timeout) or nil
	return coroutine.yield()
end

local BOOT = [=[
	local process = require("process")
	local event = require("event")

	-- per process handler routing (mirrors what /lib/thread.lua does globally)
	do
		local handlers = event.handlers
		local mt = getmetatable(handlers)
		mt.__index = function(_, key) return process.info().data.handlers[key] end
		mt.__newindex = function(_, key, value) process.info().data.handlers[key] = value end
		mt.__pairs = function() return pairs(process.info().data.handlers) end
		mt.__call = function(...) return process.info().data.pull(...) end
	end
	local data = process.info().data
	if not data.handlers then
		data.handlers = {}
	end

	local tty = require("tty")
	local buffer = require("buffer")
	local shell = require("shell")

	local mux = _ENV.__mux
	tty.window = mux.window
	tty.bind(mux.vgpu)

	local ttyIn = buffer.new("r", tty.stream)
	local ttyOut = buffer.new("w", tty.stream)
	local ttyErr = buffer.new("w", setmetatable({
		write = function(_, str) return tty.stream:write("\27[31m" .. str .. "\27[37m") end
	}, {__index = tty.stream}))
	ttyIn.tty = true
	ttyOut.tty = true
	ttyErr.tty = true
	ttyOut:setvbuf("no")
	ttyErr:setvbuf("no")
	io.input(ttyIn)
	io.output(ttyOut)
	io.error(ttyErr)

	local sh = assert(shell.getShell())
	if mux.command and #mux.command > 0 then
		return sh(table.unpack(mux.command))
	end
	return sh()
]=]

local function makeEnv(pane)
	local e = {}
	for _, key in ipairs({"assert", "error", "pcall", "xpcall", "type", "tostring",
		"tonumber", "ipairs", "pairs", "select", "unpack", "getmetatable", "setmetatable",
		"rawget", "rawset", "rawequal", "rawlen", "next", "print", "load",
		"os", "math", "string", "table", "coroutine", "debug"}) do
		e[key] = _G[key]
	end

	-- loadfile/dofile must default to the PANE env, not the host env
	e.loadfile = function(path, mode, _env)
		if type(path) ~= "string" then
			return nil, "bad path"
		end
		if path:sub(1, 1) ~= "/" then
			path = ((e.os.getenv and e.os.getenv("PWD")) or "/") .. "/" .. path
		end
		local handle, reason = fs.open(path, "r")
		if not handle then
			return nil, reason
		end
		local parts = {}
		while true do
			local data, err = handle:read(4096)
			if not data then
				if err then
					handle:close()
					return nil, err
				end
				break
			end
			parts[#parts + 1] = data
		end
		handle:close()
		return load(table.concat(parts), "=" .. path, mode, _env or e)
	end
	e.dofile = function(path)
		local chunk, reason = e.loadfile(path)
		if not chunk then
			error(tostring(reason) .. ":" .. tostring(path), 0)
		end
		return chunk()
	end
	e._VERSION = _G._VERSION
	for _, key in ipairs({"checkArg", "_OSVERSION", "save"}) do
		if _G[key] ~= nil then
			e[key] = _G[key]
		end
	end
	if _G.utf8 then
		e.utf8 = _G.utf8
	end
	if _G.bit32 then
		e.bit32 = _G.bit32
	end
	e._G = e
	e.io = io
	e.unicode = unicode
	e.component = makeComponent(pane)

	local c2 = {}
	for k, value in pairs(computer) do
		c2[k] = value
	end
	c2.pullSignal = function(timeout) return paneRawPull(pane, timeout) end
	e.computer = c2

	-- private module cache: fresh tty/term/event/shell/... per pane,
	-- shared state where sharing is mandatory (process table, mounts, pipes)
	local pkg = loadfile("/lib/package.lua", "bt", e)()
	pkg.loaded.component = e.component
	pkg.loaded.computer = c2
	pkg.loaded.unicode = unicode
	pkg.loaded.process = process
	pkg.loaded.pipe = pipe
	pkg.loaded.thread = thread
	pkg.loaded.filesystem = fs
	pkg.loaded.buffer = buffer
	-- keyboard state is physical, not per pane: panes read (and mux writes) the
	-- one shared module instance, which is what makes ^D/^C/^arrows work inside a
	-- pane at all - no boot script runs inside a pane to populate it otherwise.
	pkg.loaded.keyboard = keyboard

	e.__mux = {pane = pane, window = pane.window, vgpu = pane.vgpu, command = pane.command}
	return e
end

-------------------------------------------------------------------------------
-- layout

function muxd.syncWindow(pane)
	local win = pane.window
	if win then
		win.width, win.height = pane.lw, pane.lh
		win.x = math.max(1, math.min(win.x, pane.lw))
		win.y = math.max(1, math.min(win.y, pane.lh))
	end
end

local function notifyResize(pane)
	if pane.co and not pane.dead and not pane.deliverArgs then
		pane.deliverArgs = table.pack("screen_resized")
	end
end

local function allocBuffer(pane, w, h)
	if w < 1 or h < 1 then
		return false
	end
	local buf = realGpu.allocateBuffer(w, h)
	if not buf then
		noteError(session, "not enough video memory")
		return false
	end
	local ow, oh, obuf = pane.bufw, pane.bufh, pane.buf
	if obuf and ow > 0 and oh > 0 then
		-- keep existing content, clipped to the overlap
		realGpu.bitblt(buf, 1, 1, math.min(w, ow), math.min(h, oh), obuf, 1, 1)
		realGpu.freeBuffer(obuf)
	end
	pane.buf, pane.expect = buf, buf
	pane.bufw, pane.bufh = w, h
	pane.lw, pane.lh = w, h
	muxd.syncWindow(pane)
	if ow ~= w or oh ~= h then
		notifyResize(pane)
	end
	pane.dirty = true
	return true
end

local function layoutNode(win, node, x, y, w, h)
	node.sep = nil
	if node.pane then
		local pane = node.pane
		if w >= 1 and h >= 1 then
			if not pane.dead and (pane.bufw ~= w or pane.bufh ~= h) then
				allocBuffer(pane, w, h)
			end
			pane.rect = {x = x, y = y, w = w, h = h}
			-- zoom belongs to the window being laid out: a zoom in another window
			-- must not blank this one's panes
			pane.hidden = (win.zoom ~= nil and win.zoom ~= pane)
			-- any relayout may change what the composite looks like (window
			-- switch, zoom, splits): force a re-blit of this pane
			pane.dirty = true
		else
			pane.hidden = true
		end
		return
	end
	if node.dir == "v" then
		local inner = math.max(1, w - 1) -- the divider column
		local wa = math.floor(inner * node.frac)
		wa = math.max(1, math.min(inner - 1, wa))
		node.sep = {dir = "v", x = x + wa, y = y, w = 1, h = h}
		layoutNode(win, node.a, x, y, wa, h)
		layoutNode(win, node.b, x + wa + 1, y, inner - wa, h)
	else
		local inner = math.max(1, h - 1) -- the divider row
		local ha = math.floor(inner * node.frac)
		ha = math.max(1, math.min(inner - 1, ha))
		node.sep = {dir = "h", x = x, y = y + ha, w = w, h = 1}
		layoutNode(win, node.a, x, y, w, ha)
		layoutNode(win, node.b, x, y + ha + 1, w, inner - ha)
	end
end

local function workArea()
	local w, h = screenSize()
	return w, math.max(1, h - 1)
end

local function layoutWindow(win, x, y, w, h)
	local z = win.zoom
	if z and not z.dead then
		for _, p in ipairs(win.panes) do
			p.hidden = (p ~= z)
		end
		if z.bufw ~= w or z.bufh ~= h then
			allocBuffer(z, w, h)
		end
		z.rect = {x = x, y = y, w = w, h = h}
		z.dirty = true
		return
	end
	layoutNode(win, win.tree, x, y, w, h)
end

function muxd.relayout()
	if not session then
		return
	end
	local W, H = workArea()
	session.w, session.h = W, H
	for _, win in ipairs(session.windows) do
		layoutWindow(win, 1, 1, W, H)
	end
	session.statusDirty = true
end

-------------------------------------------------------------------------------
-- panes & windows

local function findNode(node, pane)
	if node.pane then
		return node.pane == pane and node or nil
	end
	return findNode(node.a, pane) or findNode(node.b, pane)
end

-- the pane a collapsed subtree leads with (top/left-most)
local function firstPane(node)
	if node.pane then
		return node.pane
	end
	if node.a then
		return firstPane(node.a) or firstPane(node.b)
	end
end

local function findParentNode(node, target)
	if node.pane then
		return nil
	end
	if node.a == target or node.b == target then
		return node
	end
	return findParentNode(node.a, target) or findParentNode(node.b, target)
end

local function removeNode(node, target)
	if node.pane or not node.a then
		return false
	end
	if node.a == target or node.b == target then
		local keep = (node.a == target) and node.b or node.a
		node.pane, node.a, node.b, node.dir, node.frac, node.sep =
			keep.pane, keep.a, keep.b, keep.dir, keep.frac, keep.sep
		return true
	end
	return removeNode(node.a, target) or removeNode(node.b, target)
end

local function activeWindow()
	if session and session.windows[session.wi] then
		return session.windows[session.wi]
	end
end

local function newPane(title, command)
	return {
		title = title or "shell",
		command = command,
		rect = {x = 1, y = 1, w = 1, h = 1},
		buf = nil, expect = nil, bufw = 0, bufh = 0, lw = 0, lh = 0,
		dirty = false, dead = false, hidden = false,
		wantSignal = false, pullDeadline = nil,
		deliverArgs = nil, regId = nil, regHandler = nil, parentHandlers = nil,
		window = {
			fullscreen = false, blink = false, nowrap = false, output_buffer = "",
			dx = 0, dy = 0, width = 0, height = 0, x = 1, y = 1,
			keyboard = kbAddr,
		},
	}
end

local function startPane(pane)
	pane.vgpu = makeVgpu(pane)
	pane.env = makeEnv(pane)
	local main = load(BOOT, "=mux", "bt", pane.env)
	pane.co = process.load(main, nil, nil, "mux:" .. pane.title)
	if not pane.co then
		if pane.buf then
			pcall(realGpu.freeBuffer, pane.buf)
			pane.buf = nil
		end
		return nil, "failed to load pane process"
	end
	pane.proc = process.list[pane.co]
	pane.proc.env = pane.env -- for intercept_load fallbacks inside the pane
	pane.pco = pipe.createCoroutineStack(pane.co, nil, "mux:" .. pane.title)
	pane.proc.data.pull = function(_, timeout) return paneRawPull(pane, timeout) end
	if not pane.proc.data.handlers then
		pane.proc.data.handlers = {}
	end
	pane.wake = function(name, ...) paneWake(pane, name, ...) end
	if session.clientProcData then
		pane.parentHandlers = session.clientProcData.handlers
	else
		pane.parentHandlers = rootProc.data.handlers
	end
	paneRegister(pane)
	resumeChain(pane, {}, 0)
	return pane
end

function muxd.paneFinalize(pane)
	if pane.dead then
		return
	end
	pane.dead = true
	paneUnregister(pane)
	if pane.buf then
		pcall(realGpu.freeBuffer, pane.buf)
		pane.buf = nil
	end
	if not session then
		return
	end
	for wi, win in ipairs(session.windows) do
		local found = false
		for pi, p in ipairs(win.panes) do
			if p == pane then
				table.remove(win.panes, pi)
				found = true
				break
			end
		end
		if not found then
			goto continue -- the pane lives in another window
		end
		local leaf = findNode(win.tree, pane)
		local neighbor
		if leaf then
			local parent = findParentNode(win.tree, leaf)
			if parent then
				neighbor = firstPane(parent.a == leaf and parent.b or parent.a)
			end
			removeNode(win.tree, leaf)
		end
		if #win.panes == 0 then
			table.remove(session.windows, wi)
			if session.wi > #session.windows then
				session.wi = math.max(1, #session.windows)
			end
			if #session.windows == 0 then
				session.empty = true
				if not session.clientToken then
					muxd.destroy()
				end
			end
		else
			if win.active == pane then
				-- focus the pane that took over the space, not just the first one
				win.active = (neighbor and not neighbor.dead) and neighbor or win.panes[1]
			end
			if win.zoom == pane then
				win.zoom = nil
				session.zoom = nil
			end
			muxd.relayout()
		end
		break
		-- NOTE: false positive in luals?
		--- @diagnostic disable-next-line: code-after-break
		::continue::
	end
	session.statusDirty = true
end

function muxd.spawn(title, command)
	if not session then
		return nil, "no session"
	end
	local W, H = workArea()
	local pane = newPane(title, command)
	if not allocBuffer(pane, W, H) then
		return nil, session.lastError or "cannot allocate video memory"
	end
	if not startPane(pane) then
		return nil, "failed to load pane process"
	end
	-- every spawned pane gets its own window
	local win = {title = pane.title, panes = {pane}, tree = {pane = pane}, active = pane, zoom = nil}
	session.windows[#session.windows + 1] = win
	session.wi = #session.windows
	muxd.setFocus(win, pane)
	muxd.relayout()
	session.statusDirty = true
	return pane
end

function muxd.splitPane(dir)
	local win = activeWindow()
	if not win then
		return nil, "no active window"
	end
	local W, H = workArea()
	if W * H > realGpu.freeMemory() then
		noteError(session, "not enough video memory to split")
		return nil, session.lastError
	end
	local old = win.active
	local leaf = findNode(win.tree, old)
	if not (leaf and leaf.pane == old) then
		return nil, "cannot split"
	end
	-- one cell per half plus the divider between them
	local span = (dir == "v") and old.rect.w or old.rect.h
	if span < 3 then
		noteError(session, "pane too small to split")
		return nil, session.lastError
	end
	if win.zoom then
		win.zoom = nil -- a split inside a zoomed window un-zooms it, like tmux
		session.zoom = nil
	end
	-- Grow the layout (this allocates the new pane's buffer at its final
	-- size) BEFORE spawning the program, so the pane's first writes land
	-- in a correctly sized vt100 window instead of a 1x1 placeholder.
	local pane = newPane("shell", nil)
	leaf.pane = nil
	leaf.dir = dir
	leaf.frac = 0.5
	leaf.a = {pane = old}
	leaf.b = {pane = pane}
	table.insert(win.panes, pane)
	muxd.relayout()
	if not startPane(pane) then
		table.remove(win.panes, #win.panes)
		leaf.pane, leaf.a, leaf.b, leaf.dir, leaf.frac, leaf.sep = old, nil, nil, nil, nil, nil
		win.active = old
		muxd.relayout()
		return nil, "failed to load pane process"
	end
	muxd.setFocus(win, pane)
	session.statusDirty = true
	return pane
end

function muxd.setFocus(win, pane)
	for _, p in ipairs(win.panes) do
		if p.window then
			p.window.blink = (p == pane) and not win.zoom
		end
	end
	win.active = pane
	session.statusDirty = true
end

function muxd.newWindow(command, title)
	return muxd.spawn(title or (command and table.concat(command, " ") or "shell"), command)
end

function muxd.killPane(pane)
	muxd.paneFinalize(pane)
	if session and session.empty then
		if session.clientToken then
			session.detachRequested = true -- last pane died while attached: leave
		else
			muxd.destroy()
		end
	end
	return true
end

function muxd.killWindow(win)
	for _, pane in ipairs({table.unpack(win.panes)}) do
		muxd.paneFinalize(pane)
	end
	return true
end

-------------------------------------------------------------------------------
-- navigation & resize

local function paneByDelta(win, pane, dx, dy)
	local r = pane.rect
	local best, bestScore
	for _, p in ipairs(win.panes) do
		if p ~= pane and not p.hidden and not p.dead then
			local pr = p.rect
			local ok = (dx > 0 and pr.x >= r.x + r.w) or (dx < 0 and pr.x + pr.w <= r.x) or
								 (dy > 0 and pr.y >= r.y + r.h) or (dy < 0 and pr.y + pr.h <= r.y)
			if ok then
				local cx, cy = pr.x + pr.w * .5, pr.y + pr.h * .5
				local ox, oy = r.x + r.w * .5, r.y + r.h * .5
				local along = dx ~= 0 and math.abs(cx - ox) or math.abs(cy - oy)
				local across = dx ~= 0 and math.abs(cy - oy) or math.abs(cx - ox)
				local score = along + across * 2
				if not best or score < bestScore then
					best, bestScore = p, score
				end
			end
		end
	end
	return best
end

function muxd.focusDelta(ddir)
	local win = activeWindow()
	if not win then
		return
	end
	local nx, ny = 0, 0
	if ddir == "left" then nx = -1
	elseif ddir == "right" then nx = 1
	elseif ddir == "up" then ny = -1
	elseif ddir == "down" then ny = 1 end
	local target = paneByDelta(win, win.active, nx, ny)
	if target then
		muxd.setFocus(win, target)
		muxd.relayout()
	end
end

function muxd.cyclePane()
	local win = activeWindow()
	if not win or #win.panes < 2 then
		return
	end
	for i, p in ipairs(win.panes) do
		if p == win.active then
			muxd.setFocus(win, win.panes[i % #win.panes + 1])
			break
		end
	end
	muxd.relayout()
end

function muxd.resizeActive(ddir)
	local win = activeWindow()
	if not win then
		return
	end
	local wantDir = (ddir == "left" or ddir == "right") and "v" or "h"
	local node = findNode(win.tree, win.active)
	if not node then
		return
	end
	local parent
	while node and node ~= win.tree do
		local p = findParentNode(win.tree, node)
		if p and p.dir == wantDir then
			parent = p
			break
		end
		node = p
	end
	if not parent then
		return
	end
	local inA = findNode(parent.a, win.active) ~= nil
	local grow = (ddir == "right" or ddir == "down") and 1 or -1
	if not inA then
		grow = -grow
	end
	local span
	if parent.dir == "v" then
		span = (parent.a.pane and parent.a.pane.rect.w) or (parent.b.pane and parent.b.pane.rect.w) or session.w
	else
		span = (parent.a.pane and parent.a.pane.rect.h) or (parent.b.pane and parent.b.pane.rect.h) or session.h
	end
	span = math.max(4, span or 8)
	parent.frac = math.min(0.9, math.max(0.1, parent.frac + grow / span))
	muxd.relayout()
end

function muxd.toggleZoom()
	local win = activeWindow()
	if not win then
		return
	end
	if win.zoom then
		win.zoom = nil
	else
		win.zoom = win.active
	end
	session.zoom = win.zoom
	muxd.setFocus(win, win.active)
	muxd.relayout()
end

-------------------------------------------------------------------------------
-- session commands (after the ^B prefix)

local function windowHint(s)
	return s.prefix and "mux+" or "mux"
end

local function windowSelect(s, index)
	if s.windows[index] then
		s.wi = index
		muxd.relayout()
	end
end

function muxd.command(sig)
	local s = session
	if sig[1] ~= "key_down" then
		return
	end
	local char, code = sig[3], sig[4]
	local ctrl = keyboard.isControlDown()
	local win = activeWindow()

	if code == keys.b and ctrl then
		s.prefix = false -- ^B^B cancels
		s.statusDirty = true
		return
	end

	if code == keys.c and ctrl then
		s.prefix = false
		if win and win.active then
			win.active.deliverArgs = table.pack("interrupted")
		end
		return
	end

	if char and char >= 49 and char <= 57 then -- chars "1".."9" (shift aware, unlike scancodes)
		windowSelect(s, char - 48)
	elseif char == 48 then -- "0" selects window 1 (tmux style)
		windowSelect(s, 1)
	elseif char == 37 then -- %
		muxd.splitPane("v")
	elseif char == 34 then -- "
		muxd.splitPane("h")
	elseif code == keys.x then
		if win and win.active then
			muxd.killPane(win.active)
		end
	elseif char == 38 then -- &
		if win then
			muxd.killWindow(win)
		end
	elseif code == keys.c then
		muxd.newWindow(nil, nil)
	elseif code == keys.n then
		if #s.windows > 0 then
			s.wi = s.wi % #s.windows + 1
			muxd.relayout()
		end
	elseif code == keys.p then
		if #s.windows > 0 then
			s.wi = (s.wi - 2) % #s.windows + 1
			muxd.relayout()
		end
	elseif code == keys.o then
		muxd.cyclePane()
	elseif code == keys.z then
		muxd.toggleZoom()
	elseif code == keys.d then
		s.detachRequested = true
	elseif code == keys.h then
		muxd.focusDelta("left")
	elseif code == keys.j then
		muxd.focusDelta("down")
	elseif code == keys.k then
		muxd.focusDelta("up")
	elseif code == keys.l then
		muxd.focusDelta("right")
	elseif code == keys.left then
		muxd.resizeActive("left")
	elseif code == keys.right then
		muxd.resizeActive("right")
	elseif code == keys.up then
		muxd.resizeActive("up")
	elseif code == keys.down then
		muxd.resizeActive("down")
	elseif code == keys.w then
		s.renameRequested = true
	elseif code == keys.q then
		muxd.destroy()
		s.detachRequested = true
	end
	s.prefix = false
	s.statusDirty = true
end

-------------------------------------------------------------------------------
-- attached client: per signal routing (runs before pane wakes)

local function findPaneAt(win, cx, cy)
	for _, p in ipairs(win.panes) do
		local r = p.rect
		if not p.hidden and not p.dead and
			 cx >= r.x and cx < r.x + r.w and cy >= r.y and cy < r.y + r.h then
			return p
		end
	end
end

function muxd.onSignal(sig)
	local s = session
	local name = sig[1]
	trackKeys(sig)

	if name == "screen_resized" then
		muxd.relayout()
	end

	if s.renameRequested and INPUT[name] then
		return -- the status line prompt owns the keyboard
	end

	for _, pane in ipairs(allPanes(s)) do
		pane.deliverArgs = nil
	end

	if name == "key_down" and not s.prefix and
		 sig[4] == keys.b and keyboard.isControlDown() then
		s.prefix = true
		s.statusDirty = true
		return
	end

	if s.prefix then
		if MODIFIER_CODES[sig[4]] then
			s.statusDirty = true
			return -- still waiting for the key the prefix actually commands
		end
		muxd.command(sig)
		return
	end

	local win = activeWindow()

	if INPUT[name] then
		if name == "key_down" or name == "key_up" or name == "clipboard" or name == "interrupted" then
			if win and win.active then
				win.active.deliverArgs = sig
			end
		elseif name == "touch" or name == "drag" or name == "drop" or name == "scroll" then
			if sig[2] ~= screenAddr or not win then
				return -- another screen, or nothing to click
			end
			local cx, cy = sig[3], sig[4]
			if cx ~= math.floor(cx) then -- precise (sub cell) coordinates
				cx = math.floor(cx) + 1
				cy = math.floor(cy) + 1
			end
			local pane = findPaneAt(win, cx, cy)
			if not pane then
				return
			end
			if name == "touch" and pane ~= win.active then
				muxd.setFocus(win, pane)
				muxd.relayout()
			end
			pane.deliverArgs = table.pack(name, screenAddr,
				cx - pane.rect.x + 1, cy - pane.rect.y + 1, sig[5])
		end
	else
		for _, pane in ipairs(allPanes(s)) do
			pane.deliverArgs = sig
		end
	end
end

-------------------------------------------------------------------------------
-- rendering

local STATUS_BG = 0x008000
local STATUS_FG = 0x000000
local STATUS_ACTIVE_FG = 0xffff00

local MEM_BG = 0x000000
local MEM_GOOD_FG = 0x00ff00
local MEM_WARN_FG = 0xffff00
local MEM_BAD_FG = 0xff4040

local function freePercent(total, free)
	if type(total) ~= "number" or type(free) ~= "number" or total <= 0 then
		return nil
	end
	return math.max(0, math.min(100, math.floor(free / total * 100 + .5)))
end

local function memFg(percent)
	if percent >= 50 then
		return MEM_GOOD_FG
	elseif percent >= 25 then
		return MEM_WARN_FG
	end
	return MEM_BAD_FG
end

local function wtruncTo(text, cells)
	if cells <= 0 then
		return ""
	end
	local w = unicode.wlen(text)
	if cells >= w then
		return text
	end
	return unicode.wtrunc(text, cells + 1)
end

local function memorySegments()
	local out = {}
	local function push(label, total, free)
		local percent = freePercent(total, free)
		if not percent then
			return
		end
		local text = " " .. label .. " " .. percent .. "%"
		out[#out + 1] = {text = text, fg = memFg(percent), bg = MEM_BG,
			w = unicode.wlen(text)}
	end
	local ok, total, free = pcall(function()
		return computer.totalMemory(), computer.freeMemory()
	end)
	if ok then
		push("RAM", total, free)
	end
	ok, total, free = pcall(function()
		return realGpu.totalMemory(), realGpu.freeMemory()
	end)
	if ok then
		push("VRAM", total, free)
	end
	return out
end

local function clampRow(segs, limit)
	local used = 0
	for i, part in ipairs(segs) do
		if part.w > 0 then
			if used + part.w > limit then
				local keep = limit - used
				part.text = wtruncTo(part.text, keep)
				part.w = math.max(0, keep)
				for j = i + 1, #segs do
					segs[j] = nil
				end
				break
			end
			used = used + part.w
		end
	end
	return segs
end

local function statusLine()
	local s = session
	local W, H = screenSize()
	local clock
	do
		local ok, t = pcall(os.date, "%H:%M")
		clock = ok and t or ""
	end

	local seg = {}
	local function add(text, fg, bg, w)
		if text == "" then
			return
		end
		seg[#seg + 1] = {text = text, fg = fg or STATUS_FG, bg = bg,
			w = w or unicode.wlen(text)}
	end
	local function width(parts)
		local sum = 0
		for _, part in ipairs(parts) do
			sum = sum + part.w
		end
		return sum
	end

	-- the erase takes the current background, which is set before writing
	add(string.format("\27[%d;1H\27[0K", H), STATUS_FG, STATUS_BG, 0)
	local hint = " " .. windowHint(s) .. " "
	local leftW = unicode.wlen(hint)
	add(hint)

	local zoom = ""
	local win = activeWindow()
	if win and win.zoom then
		zoom = " [zoom] "
	end
	local core = (clock ~= "" and clock .. " " or "") .. W .. "x" .. H
	local err = ""
	if s.lastError and uptime() - (s.errorExpire or 0) < 8 then
		err = "! " .. s.lastError .. " "
	end
	local mem = memorySegments()

	-- the right hand end, in drawing order: zoom, clock, screen size, memory
	local function buildRight(zoomText, coreText)
		local parts = {}
		if zoomText ~= "" then
			parts[#parts + 1] = {text = zoomText, fg = STATUS_FG, w = unicode.wlen(zoomText)}
		end
		parts[#parts + 1] = {text = coreText, fg = STATUS_FG, w = unicode.wlen(coreText)}
		if #mem > 0 then
			parts[#parts + 1] = {text = " ", fg = STATUS_FG, w = 1}
			for _, part in ipairs(mem) do
				parts[#parts + 1] = part
			end
		end
		return parts
	end
	local right = buildRight(zoom, core)
	if leftW + width(right) > W then
		right = buildRight("", core) -- the zoom marker gives way first
	end
	if leftW + width(right) > W then
		-- last resort: the memory block stays, the clock/size text gives way
		right = buildRight("", wtruncTo(core, W - leftW - width(mem) - 1))
	end

	local labels = {}
	for i, wn in ipairs(s.windows) do
		local text = i .. ":" .. (wn.title or "shell") .. " "
		labels[i] = {text = text, fg = i == s.wi and STATUS_ACTIVE_FG or STATUS_FG,
			w = unicode.wlen(text)}
	end
	local budget = math.max(0, W - leftW - width(right))
	if width(labels) <= budget then
		for _, label in ipairs(labels) do
			add(label.text, label.fg)
		end
	else
		-- fit what fits, mark the cut, and keep room for the selected window so
		-- that it is never the one that silently disappears
		local MARKER = "... " -- the gap also separates it from what follows
		local markerW = unicode.wlen(MARKER)
		local active = labels[s.wi] or {text = "", fg = STATUS_ACTIVE_FG, w = 0}
		local function pack(reserve)
			local used, shown = 0, 0
			for i, label in ipairs(labels) do
				if used + label.w > budget - reserve then
					break
				end
				used, shown = used + label.w, i
			end
			return used, shown
		end
		local used, shown = pack(markerW)
		if s.wi > shown then
			used, shown = pack(markerW + active.w)
		end
		if shown == 0 then
			add(wtruncTo(active.text, budget), active.fg)
		else
			for i = 1, shown do
				add(labels[i].text, labels[i].fg)
			end
			add(MARKER, STATUS_ACTIVE_FG)
			if s.wi > shown then
				add(active.text, active.fg)
			end
		end
	end

	-- a pending error only gets whatever slack the trimmed list left over
	local usedW = 0
	for _, part in ipairs(seg) do
		usedW = usedW + part.w
	end
	local slack = math.max(0, W - usedW - width(right))
	if err ~= "" then
		err = wtruncTo(err, slack)
		if err ~= "" then
			add(err)
		end
	end
	add(string.rep(" ", math.max(0, slack - unicode.wlen(err))))
	for _, part in ipairs(right) do
		add(part.text, part.fg, part.bg)
	end
	return clampRow(seg, W)
end

local function writeStatusLine()
	local ofg, opal = realGpu.getForeground()
	local obg, obpal = realGpu.getBackground()
	local drawnFg, drawnBg
	for _, part in ipairs(statusLine()) do
		local bg = part.bg or STATUS_BG
		if bg ~= drawnBg then
			realGpu.setBackground(bg, false)
			drawnBg = bg
		end
		if part.fg ~= drawnFg then
			realGpu.setForeground(part.fg, false)
			drawnFg = part.fg
		end
		term.write(part.text)
	end
	realGpu.setForeground(ofg, opal)
	realGpu.setBackground(obg, obpal)
end

local SEPARATOR_CH = {v = "|", h = "-"}
local SEPARATOR_FG = 0xaaaaaa
local SEPARATOR_ACTIVE_FG = 0x00ff00
local SEPARATOR_BG = 0x000000

local function splitNodes(node, out)
	if node.pane or not node.a then
		return out
	end
	out[#out + 1] = node
	splitNodes(node.a, out)
	splitNodes(node.b, out)
	return out
end

local function subtreeHasPane(node, pane)
	if node.pane then
		return node.pane == pane
	end
	return (node.a and subtreeHasPane(node.a, pane)) or
				 (node.b and subtreeHasPane(node.b, pane))
end

local function paintSeparators()
	local win = activeWindow()
	if not win or win.zoom then
		return -- zoomed pane covers the whole work area, no dividers in its way
	end
	local nodes = splitNodes(win.tree, {})
	if #nodes == 0 then
		return
	end
	local ofg, opal = realGpu.getForeground()
	local obg, obpal = realGpu.getBackground()
	realGpu.setBackground(SEPARATOR_BG, false)
	local active = win.active
	for _, node in ipairs(nodes) do
		local sep = node.sep
		if sep then
			local ch = SEPARATOR_CH[sep.dir]
			local len = (sep.dir == "v") and sep.h or sep.w
			local firstHalf = math.ceil(len / 2)
			local lit
			if active and not active.dead then
				if subtreeHasPane(node.a, active) then
					lit = 1
				elseif subtreeHasPane(node.b, active) then
					lit = 2
				end
			end
			for part = 1, 2 do
				local from = (part == 1) and 1 or (firstHalf + 1)
				local count = (part == 1) and firstHalf or (len - firstHalf)
				if count > 0 then
					realGpu.setForeground((part == lit) and SEPARATOR_ACTIVE_FG or SEPARATOR_FG, false)
					if sep.dir == "v" then
						realGpu.set(sep.x, sep.y + from - 1, string.rep(ch, count), true)
					else
						realGpu.set(sep.x + from - 1, sep.y, string.rep(ch, count))
					end
				end
			end
		end
	end
	realGpu.setForeground(ofg, opal)
	realGpu.setBackground(obg, obpal)
end

function muxd.render()
	local s = session
	if not s then
		return
	end
	realGpu.setActiveBuffer(0)
	local win = activeWindow()
	if win then
		for _, pane in ipairs(win.panes) do
			if not pane.dead and not pane.hidden and pane.dirty and pane.buf then
				local r = pane.rect
				local ok, err = pcall(realGpu.bitblt, 0, r.x, r.y, r.w, r.h, pane.buf, 1, 1)
				if ok then
					pane.dirty = false
				else
					noteError(s, tostring(err))
				end
			end
		end
	end
	paintSeparators()
	if s.statusDirty then
		writeStatusLine()
		s.statusDirty = false
	end
end

-------------------------------------------------------------------------------
-- session lifecycle

function muxd.exists()
	return session ~= nil
end

function muxd.create(command)
	if session then
		return session
	end
	local ok, reason = ensureHardware()
	if not ok then
		return nil, reason
	end
	local W, H = workArea()
	session = {
		windows = {}, wi = 1, w = W, h = H,
		prefix = false, clientToken = nil, clientProcData = nil,
		detachRequested = false, renameRequested = false,
		statusDirty = true, lastError = nil, empty = false, zoom = nil,
	}
	_G[SESSION_KEY] = session
	local pane = muxd.spawn(command and table.concat(command, " ") or "shell", command)
	if not pane then
		local err = session.lastError
		muxd.destroy()
		return nil, err or "cannot create the first pane"
	end
	return session
end

function muxd.destroy()
	if not session then
		return
	end
	for _, pane in ipairs(allPanes(session)) do
		pane.dead = true
		paneUnregister(pane)
		if pane.buf then
			pcall(realGpu.freeBuffer, pane.buf)
			pane.buf = nil
		end
	end
	session = nil
	_G[SESSION_KEY] = nil
end

function muxd.list()
	if not session then
		return nil, "no mux session is running"
	end
	local result = {}
	for i, win in ipairs(session.windows) do
		result[#result + 1] = string.format("%d: %s (%d pane(s))%s",
			i, win.title or "shell", #win.panes, i == session.wi and " [active]" or "")
	end
	return result
end

-- becomes the client for the session (call from the mux process)
function muxd.attach()
	if not session then
		return nil, "no session"
	end
	local ok, reason = ensureHardware()
	if not ok then
		return nil, reason
	end
	clientToken = {}
	session.clientToken = clientToken
	session.detachRequested = false
	forgetKeys()

	local proc = process.info()
	session.clientProcData = proc.data

	local rawPull = rootProc.data.pull
	proc.data.pull = function(_, timeout)
		local sig = table.pack(rawPull(_, timeout))
		if sig.n > 0 then
			muxd.onSignal(sig)
		end
		return table.unpack(sig, 1, sig.n)
	end

	-- if ^C reaches us directly (alt+^C), route it to the active pane instead of dying
	proc.data.signal = function()
		local win = activeWindow()
		if win and win.active then
			win.active.deliverArgs = table.pack("interrupted")
		end
	end

	-- watchdog: if this mux process dies without detaching, hand the panes back to init
	process.addHandle({close = function()
		if session and session.clientToken == clientToken then
			muxd.release()
		end
	end}, proc)

	for _, pane in ipairs(allPanes(session)) do
		paneSetParent(pane, proc.data.handlers)
	end
	muxd.relayout()
	for _, pane in ipairs(allPanes(session)) do
		pane.dirty = true
	end
	local win = activeWindow()
	if win then
		muxd.setFocus(win, win.active)
	end
	return true
end

-- panes go back to being pumped by init (the shell); client state is cleared
function muxd.release()
	if not session then
		return
	end
	for _, pane in ipairs(allPanes(session)) do
		paneSetParent(pane, rootProc.data.handlers)
	end
	if session.clientProcData then
		session.clientProcData.pull = nil
		session.clientProcData.signal = nil
	end
	session.clientToken = nil
	session.clientProcData = nil
end

function muxd.detach()
	if session and session.clientToken == clientToken then
		muxd.release()
	end
	if session then
		session.statusDirty = true
	end
end

-- one pump iteration; returns "ok", "stolen", "rename", "detach" or "empty"
function muxd.pump(timeout)
	if not session then
		return "empty"
	end
	if session.clientToken ~= clientToken then
		return "stolen"
	end
	if session.renameRequested then
		return "rename"
	end
	local ok, err = pcall(event.pull, timeout)
	if not ok then
		noteError(session, tostring(err))
	end
	muxd.render()
	if session.renameRequested then
		return "rename"
	end
	if session.empty then
		return "empty"
	end
	if session.detachRequested then
		return "detach"
	end
	return "ok"
end

function muxd.renameWindow()
	local win = activeWindow()
	if not win then
		return
	end
	local H = select(2, screenSize())
	local ofg, opal = realGpu.getForeground()
	local obg, obpal = realGpu.getBackground()
	realGpu.setBackground(STATUS_BG, false)
	realGpu.setForeground(STATUS_FG, false)
	term.write(string.format("\27[%d;1H\27[0Ktitle: ", H))
	local line = term.read()
	realGpu.setForeground(ofg, opal)
	realGpu.setBackground(obg, obpal)
	session.renameRequested = false
	if line then
		line = line:gsub("^%s+", ""):gsub("%s+$", "")
		if line ~= "" then
			win.title = line
		end
	end
	session.statusDirty = true
end

return muxd
