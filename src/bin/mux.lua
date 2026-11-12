-- mux: a tmux-like terminal multiplexer for opencomputers (on openos).
--
--	 mux					attach to the session, creating it if needed
--	 mux attach				same
--	 mux new CMD...			run CMD in a new window of the session
--	 mux list				list windows
--	 mux kill-session		end the session
--
-- While attached, ^B is the prefix key (like tmux ^A/^B).

local muxd = require("muxd")
local shell = require("shell")
local term = require("term")
local event = require("event")
local computer = require("computer")
local process = require("process")

local args, options = shell.parse(...)

local function restoreScreen()
	term.clear()
	term.setCursorBlink(true)
end

local function client()
	local ok, blinkWas = pcall(function()
	local was = term.getCursorBlink()
	term.setCursorBlink(false)
	return was
	end)
	if not ok then
	blinkWas = true
	end

	local timer = event.timer(1, function()
	if muxd.exists() then
		local s = _G.mux_session
		s.statusDirty = true
	end
	end, math.huge)

	local status
	while true do
	status = muxd.pump(1)
	if status == "rename" then
		muxd.renameWindow()
	elseif status == "detach" or status == "stolen" or status == "empty" then
		break
	end
	end

	event.cancel(timer)
	if status == "detach" then
	muxd.detach()
	end
	if status == "empty" then
	muxd.destroy() -- last pane died: free the session and its buffers
	end
	restoreScreen()
	if status ~= "empty" then
	local note = "mux detached; session keeps running - `mux` to reattach"
	if status == "stolen" then
		note = "mux terminal was taken over by another client"
	end
	io.stderr:write(note .. "\n")
	end
	return 0
end

local cmd = args[1]

if cmd == nil or cmd == "attach" then
	if not muxd.exists() then
	local session, reason = muxd.create()
	if not session then
		io.stderr:write("mux: " .. tostring(reason) .. "\n")
		return 1
	end
	term.clear()
	end
	if not muxd.exists() then
	io.stderr:write("mux: no session\n")
	return 1
	end
	local ok, reason = muxd.attach()
	if not ok then
	io.stderr:write("mux: " .. tostring(reason) .. "\n")
	return 1
	end
	return client()
elseif cmd == "new" then
	if #args < 2 then
	io.stderr:write("usage: mux new CMD...\n")
	return 1
	end
	if not muxd.exists() then
	local _, reason = muxd.create(table.pack(table.unpack(args, 2)))
	if reason then
		io.stderr:write("mux: " .. reason .. "\n")
		return 1
	end
	print("mux: session created")
	return 0
	end
	local pane, reason = muxd.newWindow(table.pack(table.unpack(args, 2)))
	if not pane then
	io.stderr:write("mux: " .. tostring(reason) .. "\n")
	return 1
	end
	return 0
elseif cmd == "list" then
	local list, reason = muxd.list()
	if not list then
	io.stderr:write("mux: " .. reason .. "\n")
	return 1
	end
	for _, line in ipairs(list) do
	print(line)
	end
	return 0
elseif cmd == "kill-session" then
	if not muxd.exists() then
	io.stderr:write("mux: no session\n")
	return 1
	end
	-- safe even if a client is pumping: the client notices the empty session
	muxd.destroy()
	restoreScreen()
	print("mux: session killed")
	return 0
elseif cmd == "--help" or options.help then
	print("usage: mux [attach | new CMD... | list | kill-session]")
	print("prefix ^B then: %  left/right  \" top/bottom  x kill-pane  & kill-window")
	print("                c new-window  n/p window  0-9 window  o next-pane")
	print("                h j k l focus  arrows resize  z zoom  w title  d detach")
	return 0
else
	io.stderr:write("mux: unknown command `" .. tostring(cmd) .. "` (try `mux --help`)\n")
	return 1
end
