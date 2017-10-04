local meta = {}

local function mcp_version(clmin, clmax, svmin, svmax)
	if clmax >= svmin and svmax >= clmin then
		return math.min(svmax, clmax)
	end
	return nil
end

local function handle_msg(self, msg, args)
	-- local tmp = {"MCP: '" .. msg .. "' {"}
	-- for k, v in pairs(args) do
		-- if v:find(" ") then
			-- tmp[#tmp + 1] = k .. ": \"" .. v:gsub("[\"\\]", "\\%1") .. "\""
		-- else
			-- tmp[#tmp + 1] = k .. ": " .. v
		-- end
	-- end
	-- tmp[#tmp + 1] = "}"
	-- print(table.concat(tmp, " "))

	if not self.enabled then
		return
	elseif msg == "mcp" then
		self:send("mcp", {
			["authentication-key"] = self.auth,
			["version"] = self.version,
			["to"] = self.to,
		})
		for k, v in pairs(self.localpkg) do
			self:send("mcp-negotiate-can", {
				["package"] = k,
				["min-version"] = v[1],
				["max-version"] = v[2],
			})
		end
	elseif msg == "mcp-negotiate-can" then
		self.remotepkg[args.package] = {args["min-version"], args["max-version"]}
	elseif msg == "mcp-negotiate-end" then
		-- XXX: probably won't bother implementing this
		-- because each version has different negotiation mechanics
	elseif msg == "mcp-cord-open" then
		self:opencord(args._id, args._type)
	elseif msg == "mcp-cord" then
		mcp:cord(args._id, args._message, args)
	elseif msg == "mcp-cord-closed" then
		mcp:closecord(args._id, args._message)
	end
end

local function repl(esc, char)
	if #esc % 2 == 0 then
		return string.sub(esc, 1, #esc*0.5) .. (char == '"' and "\1" or char)
	end
	return string.sub(esc, 1, (#esc - 1)*0.5) .. char
end

function meta:parse(line)
	if line:sub(1, 3) == "#$\"" then
		return true, line:sub(4)
	elseif line:sub(1, 3) ~= "#$#" then
		return true, line
	end
	if self.debug then
		MsgC(Color(137, 222, 255), "[SV] ", line:sub(4), "\n")
	end
	local msg, argstr = line:gsub("(\\*)(.?)", repl):match("^#$#(%S+)(.-)$")
	if not msg then
		print("MCP: Syntax error (1): " .. line)
		return
	end

	local auth
	if msg ~= "mcp" then
		auth, argstr = argstr:match("^ ([^ ]+)(.-)$")
		if not auth then
			if msg == "*" or msg == ":" then
				print("MCP: Multiline has no datatag!")
				return
			end
			print("MCP: Syntax error (2): " .. line)
			return
		elseif msg ~= "*" and msg ~= ":" and auth ~= self.auth then
			print("MCP: Invalid auth key '" .. auth .. "'!")
			return
		end
	end

	if msg == "*" then
		local args = self.data[auth]
		if not args then
			print("MCP: Continuation with invalid tag '" .. auth .. "'!")
			return
		end
		local key, pval = argstr:match("^ ([^ :]+): (.-)$")
		if not key then
			print("MCP: Syntax error (3): " .. line)
			return
		end
		-- print("MCP: Cont. multiline '" .. args[1] .. "' " .. key .. ": " .. pval)
		args[key] = args[key] .. "\n" .. pval
		return
	elseif msg == ":" then
		local args = self.data[auth]
		if not args then
			print("MCP: Ending with invalid tag '" .. auth .. "'!")
			return
		end
		self.data[auth] = nil
		args["_data-tag"] = nil
		handle_msg(self, table.remove(args, 1), args)
		return
	end

	local args = {}
	local multi
	local i, len = 1, #argstr
	while i <= len do
		local s, e, key, val = argstr:find("^ ([^ :]+): \1([^\1]*)\1", i)
		if not s then
			s, e, key, val = argstr:find("^ ([^ :]+): ([^ \1]*)", i)
			if not s then
				print("MCP: Syntax error (4): " .. line)
				return
			end
		end
		-- print(i, key .. ":", val)
		if key:sub(-1) == "*" then
			key, multi = key:sub(1, -2), true
		end
		args[key] = val
		i = e + 1
	end

	if not multi then
		handle_msg(self, msg, args)
		return
	end
	local tag = args["_data-tag"]
	if not tag then
		print("MCP: Multiline with no _data-tag!")
	elseif self.data[tag] then
		print("MCP: Multiline re-uses tag '" .. tag .. "'!")
	else
		-- print("MCP: Start multiline '" .. msg .. "'")
		args[1] = msg
		self.data[tag] = args
	end
end

function meta:format(msg, args)
	local res = msg == "mcp" and {msg} or {msg, self.auth}
	for k, v in pairs(args) do
		v = tostring(v)
		if v:find(" ") then
			res[#res + 1] = ('%s: "%s"'):format(k, v:gsub("[\"\\]", "\\%1"))
		else
			res[#res + 1] = ("%s: %s"):format(k, v)
		end
	end
	return "#$#" .. table.concat(res, " ")
end

function meta:send(msg, args)
	self:rawsend(self:format(msg, args))
end

function meta:rawsend(str) end

function meta:support(pkg, from, to)
	self.localpkg[pkg] = {from, to}
end

function meta:opencord() end
function meta:cord() end
function meta:closecord() end

return function()
	return setmetatable({
		enabled = true,
		auth = tostring(os.time()),

		-- version = "1.0",
		version = "2.1",
		to = "2.1",

		localpkg = {
			["mcp-negotiate"] = {"1.0", "2.0"},
			["mcp-cord"] = {"1.0", "1.0"},
		},
		remotepkg = {},

		data = {},
		cords = {},
	}, {__index = meta})
end
