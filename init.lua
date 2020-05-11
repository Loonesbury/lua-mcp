-- a basic MCP 2.1 implementation in Lua
local mcp = {
	_VERSION = 1.0,
}

local function fixminor(str)
	local major, minor = string.match(str, "^(%-?%d+)%.?(%d-)$")
	return major*1000 + (tonumber(minor) or 0)
end
local function unfixminor(f)
	return math.floor(f*0.001) .. "." .. (f % 1000)
end

-- returns the highest shared version between [low, high] and [min, max]
-- if the ranges do not overlap, returns nil
function mcp.checkversion(low, high, min, max)

	low, high = fixminor(low), fixminor(high)
	min, max  = fixminor(min), fixminor(max)

	if high >= min and low <= max then
		return unfixminor(math.min(high, max))
	end
	return nil

end

local function check_ident(str) return str:find("^[%a_][%w%-_]*$") end
local function check_simple(str) return not str:find('["*:\\ ]') end

-- parses a raw incoming message
-- returns (true) on valid MCP
-- returns (true, output-str) if no MCP
-- returns (nil, error-str) on invalid MCP
function mcp:parse(raw)

	if raw:sub(1, 3) == "#$\"" then
		return true, raw:sub(4)
	elseif raw:sub(1, 3) ~= "#$#" then
		return true, raw
	end

	local msg, argstr = raw:match("^#$#([^ ]*)(.-)$")
	if #msg == 0 then
		return nil, "empty message name"
	elseif msg ~= "*" and msg ~= ":" and not check_ident(msg) then
		return nil, "invalid message name '" .. msg .. "'"
	end

	msg = msg:lower()
	-- handle escaped chars, replace unescaped quotes with "\1"
	argstr = argstr:gsub("(\\*)([\\\"])", function(esc, ch)
		if #esc % 2 == 0 and ch == '"' then
			ch = "\1"
		end
		return esc:sub(1, math.floor(#esc/2)) .. ch
	end)

	-- weird juggling because 'mcp' doesn't include an auth key
	local auth
	if msg ~= "mcp" then
		auth, argstr = argstr:match("^ +([^ ]+)(.-)$")
		if auth then
			if auth:sub(-1) == ":" then
				return nil, "no auth key"
			elseif not check_simple(auth) then
				return nil, "invalid authkey '" .. auth .. "'"
			end
		elseif msg == "*" or msg == ":" then
			return nil, "multiline with no datatag"
		else
			return nil, "no auth key"
		end
	end

	-- continue multi-line message
	if msg == "*" then
		local args = self.multilines[auth]
		if not args then
			return nil, "multiline message with unused tag '" .. auth .. "'"
		end
		local key, pval = argstr:match("^ +([^ :]+): (.-)$")
		if not key then
			return nil, "invalid multiline syntax"
		end
		table.insert(args[key:lower()], pval)
		return true

	-- finish multi-line message
	elseif msg == ":" then
		local args = self.multilines[auth]
		if not args then
			return nil, "multiline message with unused tag '" .. auth .. "'"
		end
		for k, v in pairs(args) do
			if type(v) == "table" then
				args[k] = table.concat(v, "\n")
			end
		end

		self.multilines[auth] = nil
		args["_data-tag"] = nil

		return self:handlemcp(table.remove(args, 1), args)

	elseif msg ~= "mcp" and auth ~= self.auth then
		return nil, "incorrect auth key '" .. auth .. "'"
	end

	local args = {}
	local multi
	local i, len = 1, #argstr
	while i <= len do
		local s, e, key, val = argstr:find("^ +([^ :]+): +\1([^\1]*)\1", i)
		if not s then
			s, e, key, val = argstr:find("^ +([^ :]+): +([^ \1]+)", i)
			if not s then
				return nil, "invalid arguments"
			elseif not check_simple(val) then
				return nil, "'" .. key .. "' has invalid simple value '" .. val .. "'"
			end
		end

		if key:sub(-1) == "*" then
			multi = true
			key = key:sub(1, -2)
			-- value is required syntactically, but is ignored
			val = {}
		end
		if not check_ident(key) then
			return nil, "invalid keyword '" .. key .. "'"
		elseif args[key:lower()] then
			return nil, "duplicate keyword '" .. key .. "'"
		end
		args[key:lower()] = val
		i = e + 1
	end

	-- if none of the args were multi-line, we can just handle it now
	if not multi then
		return self:handlemcp(msg, args)
	end

	-- otherwise, store it and wait for the continuation lines
	local tag = args["_data-tag"]
	if not tag then
		return nil, "multiline started with no _data-tag"
	elseif #tag == 0 or not check_simple(tag) then
		return nil, "multiline started with invalid _data-tag '" .. tag .. "'"
	elseif self.multilines[tag] then
		return nil, "multiline started with existing _data-tag '" .. tag .. "'"
	else
		args[1] = msg
		self.multilines[tag] = args
		return true
	end

end

function mcp:handlemcp(msg, args)

	-- NOTE: we allow renegotiation, but this isn't mentioned in the standard
	-- so you probably shouldn't actually try to trigger it yourself
	if msg:lower() == "mcp" then
		if not tonumber(args.version) then
			return nil, "mcp: invalid 'version'"
		elseif not tonumber(args.to) then
			return nil, "mcp: invalid 'to'"
		end

		if self.version ~= nil then
			self:reset()
		end

		local remote = self.remote
		remote.minver, remote.maxver = args.version, args.to

		self.version = mcp.checkversion(
			self.minver, self.maxver,
			remote.minver, remote.maxver
		) or "0.0"

		if self.version == "0.0" then
			-- version mismatches aren't reported as an error
			-- only if they try to send stuff afterwards.
			return true
		end

		if self.server then
			self.auth = args["authentication-key"]
		end

		if self.client then
			self:sendmcp("mcp", {
				["authentication-key"] = self.auth,
				["version"] = self.minver,
				["to"] = self.maxver,
			}, true)
		end
		for k, v in pairs(self.packages) do
			self:sendmcp("mcp-negotiate-can", {
				["package"] = k,
				["min-version"] = v.minver,
				["max-version"] = v.maxver,
			}, true)
		end
		self:sendmcp("mcp-negotiate-end", nil, true)
		self.negotiating = true
		return true

	elseif self.version and self.version ~= "0.0" then
		local fn = self.handlers[msg]
		if not fn then
			return nil, "unhandled message '" .. msg .. "'"
		end
		local err = fn(self, args)
		if err then
			return nil, msg .. ": " .. err
		end
		return true

	else
		return nil, "received '" .. msg .. "' before negotiation"
	end

end

-- sends an MCP message to the remote.
-- 'args' is a dictionary of str "key" => str "value"
-- set 'nocheck' to true to send messages before negotiation
-- if any arguments contain newlines, they will be automatically sent
-- in a multi-line message.
function mcp:sendmcp(msg, args, nocheck)

	if not nocheck then
		assert(self.version, "sent message before negotiation")
		assert(self.version ~= "0.0", "cannot send to incompatible remote")
		-- argh argh argh
		assert(self:supports(msg) or self:supports(msg:gsub("%-[^%-]+$", "")),
			"sent unsupported message '" .. msg .. "'"
		)
	end
	local res = (msg:lower() == "mcp") and {msg} or {msg, self.auth}
	local multi = {}

	for k, v in pairs(args or {}) do
		k, v = tostring(k), tostring(v)
		assert(check_ident(k), "invalid keyword '" .. k .. "'")

		if v:find("\n") then
			multi[k] = v
			res[#res + 1] = k .. '*: ""'
		elseif not check_simple(v) then
			res[#res + 1] = ('%s: "%s"'):format(k, v:gsub("[\"\\]", "\\%1"))
		else
			res[#res + 1] = ("%s: %s"):format(k, v)
		end
	end

	if not next(multi) then
		self:sendraw("#$#" .. table.concat(res, " "))
	else
		self.lasttag = (self.lasttag + 1) % 0xFFFFFFFF
		local tag = ("%x"):format(self.lasttag)

		self:sendraw("#$#" .. table.concat(res, " ") .. " _data-tag: " .. tag)
		for key, val in pairs(multi) do
			for line in string.gmatch(val .. "\n", "([^\n]*)\n") do
				self:sendraw(("#$#* %s %s: %s"):format(tag, key, line))
			end
		end
		self:sendraw("#$#: " .. tag)
	end

end

-- sends a line of non-MCP output, escaping "#$#" if necessary
function mcp:send(str)

	if str:sub(1, 3) == "#$#" then
		str = "#$\"" .. str
	end
	self:sendraw(str)

end

-- called to send out a message
function mcp:sendraw(str) end

-- called when negotiation is finished
function mcp:onready() end

-- if we support the given package, returns its version number
function mcp:supports(pkg)
	pkg = pkg:lower()
	return self.packages[pkg] and self.packages[pkg].version
end

-- for servers: sends the initial MCP header that tells the client
-- that it can start negotiation
function mcp:greet()

	assert(self.server, "cannot use 'greet' as a client")

	-- format it ourselves, so it doesn't look stupid for non-MCP clients
	-- if the args are out-of-order, dict ordering not being guaranteed
	return self:sendraw("#$#mcp version: " .. self.minver .. " to: " .. self.maxver)

end

-- if the server does not support MCP, returns nil
-- if server supports an incompatible MCP version, returns 0, 0
-- otherwise, returns major and minor version
function mcp:getversion()
	if not self.version then
		return nil
	end
	local major, minor = string.match(self.version, "^(%-?%d+)%.?(%d-)$")
	return tonumber(major), tonumber(minor) or 0
end

-- resets the MCP state to default values
function mcp:reset()

	if self.server then
		self.auth = nil
	end
	for k, v in pairs(self.packages) do
		v.version = nil
	end

	self.remote.minver, self.remote.maxver = nil, nil
	self.remote.packages = {
		["mcp-negotiate"] = {
			-- MCP2.1 requires AT LEAST mcp-negotiate 1.0, which won't
			-- negotiate support for itself, so we have to assume it's there
			minver = "1.0",
			maxver = "1.0"
		}
	}

	-- as recommended by MCP2.1, we start out using mcp-negotiate 2.0 since
	-- it's compatible with 1.0 and 1.0 is required for MCP2.1 compliance.
	self.packages["mcp-negotiate"].version = "2.0"

	for k, v in pairs(self.packages) do
		if v.init then
			v.init(self)
		end
	end

end

-- if calling this on the server, 'auth' should always be nil
-- 'pkgs' is an array of packages to support
function mcp.new(auth, pkgs)

	if auth and auth:find("[\"*:\\ ]") then
		error("invalid auth key '" .. auth .. "'")
	end

	local obj = setmetatable({
		-- The maximum MCP version that local and remote both support
		-- nil if MCP is not in use
		version = nil,
		minver = "2.1",
		maxver = "2.1",

		auth = auth,
		server = (auth == nil),
		client = (auth ~= nil),

		-- multi-line data cache
		multilines = {},
		-- last _data-tag we used. we start from a random value and increment
		-- it for each multiline message. this is not perfect, but it avoids
		-- potentially re-using a _data-tag when the user's sendraw()
		-- implementation is able to interleave output lines.
		self.lasttag = math.random(0x0, 0xFFFFFFFF - 1)

		-- packages we support
		-- supported packages will have 'version' != nil
		packages = {
			["mcp-negotiate"] = require("mcp.packages.mcp-negotiate"),
			["mcp-cord"]      = require("mcp.packages.mcp-cord"),
		},
		-- full message name => func
		handlers = {},

		remote = {
			minver = nil,
			maxver = nil,

			-- all packages they support (including any we don't)
			packages = {}
		},
	}, {__index = mcp})

	-- load and verify additional packages
	for k, v in pairs(pkgs or {}) do
		if type(v) == "string" then
			v = require("mcp.packages." .. v:lower())
		end
		if type(v) == "table" then
			obj.packages[k:lower()] = v
		end
	end
	for pkgname, v in pairs(obj.packages) do
		v.minver = assert(v.minver, "package '" .. pkgname .. "' has no 'minver'")
		v.maxver = assert(v.maxver, "package '" .. pkgname .. "' has no 'maxver'")

		for msgname, fn in pairs(v.funcs or {}) do
			local key = pkgname
			if #msgname > 0 then
				key = key .. "-" .. msgname
			end
			obj.handlers[key:lower()] = fn
		end
	end

	obj:reset()

	return obj

end

return mcp
