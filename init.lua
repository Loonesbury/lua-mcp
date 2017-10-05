-- a basic MCP 2.1 implementation in Lua
local mcp = {
	_VERSION = 1.0,
}

local chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
local digits = {}
for i, c in string.gmatch(chars, "()(.)") do
	digits[i - 1] = c
	digits[c] = i - 1
end
function mcp.incrtag(tag)
	local carry = true
	tag = string.reverse(string.gsub(string.reverse(tag), ".", function(c)
		if carry then
			local i = digits[c]
			local ret = (i + 1) % #chars
			carry = (ret < i)
			return digits[ret]
		end
	end))
	if carry then
		return "1" .. tag
	end
	return tag
end

-- returns the highest version that both client and server support
-- if completely incompatible, returns nil
function mcp.checkversion(clmin, clmax, svmin, svmax)
	if clmax >= svmin and svmax >= clmin then
		return math.min(svmax, clmax)
	end
	return nil
end

-- collapses sequences of backslashes, and replaces unescaped quotes with "\1"
local function repl(esc, char)
	if #esc % 2 == 0 then
		return string.sub(esc, 1, #esc*0.5) .. (char == '"' and "\1" or char)
	end
	return string.sub(esc, 1, (#esc - 1)*0.5) .. char
end

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

	if self.debug then
		print("\27[38;5;81m" .. raw:sub(4) .. "\27[0m")
	end

	local msg, argstr = raw:gsub("(\\*)(.?)", repl):match("^#$#(%S*)(.-)$")
	if not msg:find("^[%a_][%w%-_]*$") then
		return nil, "invalid message '" .. msg .. "'"
	end

	local auth
	if msg ~= "mcp" then
		auth, argstr = argstr:match("^ ([^ ]+)(.-)$")
		if not auth then
			if msg == "*" or msg == ":" then
				return nil, "multiline message with no tag"
			end
			return nil, "invalid syntax (no auth key)"
		end
	end

	-- continue multi-line message
	if msg == "*" then
		local args = self.data[auth]
		if not args then
			return nil, "multiline message with unused tag '" .. auth .. "'"
		end
		local key, pval = argstr:match("^ ([^ :]+): (.-)$")
		if not key then
			return nil, "invalid syntax"
		end
		local prev = args[key]
		args[key] = prev .. pval .. "\n"
		return true

	-- finish multi-line message
	elseif msg == ":" then
		local args = self.data[auth]
		if not args then
			return nil, "multiline message with unused tag '" .. auth .. "'"
		end

		self.data[auth] = nil
		args["_data-tag"] = nil

		return self:handlemsg(table.remove(args, 1), args)

	elseif msg ~= "mcp" and auth ~= self.auth then
		return nil, "incorrect auth key '" .. tostring(auth) .. "'"
	end

	local args = {}
	local multi
	local i, len = 1, #argstr
	while i <= len do
		local s, e, key, val = argstr:find("^ ([^ :]+): \1([^\1]*)\1", i)
		if not s then
			s, e, key, val = argstr:find("^ ([^ :]+): ([^ \1]*)", i)
			if not s then
				return nil, "invalid syntax (bad key-value pair)"
			end
		end

		if key:sub(-1) == "*" then
			key = key:sub(1, -2)
			multi = true
			val = #val > 0 and (val .. "\n") or val
		end
		args[key] = val
		i = e + 1
	end

	if not multi then
		return self:handlemsg(msg, args)
	end

	local tag = args["_data-tag"]
	if not tag then
		return nil, "multiline message started with no _data-tag"
	elseif tag:find("[\"*:\\ ]") then
		return nil, "multiline message started with invalid _data-tag '" .. tag .. "'"
	elseif self.data[tag] then
		return nil, "multiline message started with existing _data-tag '" .. tag .. "'"
	else
		args[1] = msg
		self.data[tag] = args
		return true
	end
end

-- converts a float or an integer to a string, with at least 1 decimal place
-- we need this because Fuzzball 6 and HellMOO will refuse to accept integers
-- in protocol and package version numbers.
local function VER(n)
	return ("%f"):format(n):gsub("0+$", ""):gsub("%.$", ".0")
end

function mcp:handlemsg(msg, args)
	-- only allow 'mcp' until we've settled on a version
	if self.version then
		if self.version < 0 then
			return nil, "remote sent '" .. msg .. "' after version mismatch"
		elseif msg == "mcp" then
			return nil, "remote re-sent 'mcp'"
		end
	elseif msg ~= "mcp" then
		return nil, "got '" .. msg .. "' before 'mcp'"
	end

	if msg == "mcp" then
		-- ignore renegotiation
		if self.version then
			return nil, "remote re-sent 'mcp'"
		end

		local remote = self.remote
		remote.minver, remote.maxver = tonumber(args["version"]), tonumber(args["to"])

		self.version = mcp.checkversion(
			self.minver, self.maxver,
			remote.minver, remote.maxver
		) or -1

		if self.version <= 0 then
			-- version mismatches aren't reported as an error
			-- only if they try to send stuff afterwards.
			return true
		end

		-- the standard isn't explicit on who MUST send a key.
		-- Fuzzball MUCK seems to generate a random key if the client
		-- doesn't send one, but that's the only place I've seen this
		-- done, so let's not bother imitating it.
		if self.server then
			self.auth = args["authentication-key"]
		end

		if self.client then
			self:sendmcp("mcp", {
				["authentication-key"] = self.auth,
				["version"] = VER(self.minver),
				["to"] = VER(self.maxver),
			}, true)
		end
		for k, v in pairs(self.packages) do
			self:sendmcp("mcp-negotiate-can", {
				["package"] = k,
				["min-version"] = VER(v.minver),
				["max-version"] = VER(v.maxver),
			}, true)
		end
		self:sendmcp("mcp-negotiate-end", nil, true)
		self.negotiating = true

	else
		local fn = self.handlers[msg:lower()]
		if not fn then
			return nil, "unhandled message '" .. msg .. "'"
		end
		fn(self, msg, args)
		return true
	end
end

function mcp:supports(pkg)
	return self.packages[pkg] and self.packages[pkg].version
end

function mcp:sendmcp(msg, args, nocheck)
	if not nocheck then
		assert(self.version, "server does not support MCP, or negotiation not yet begun")
		assert(self:supports(msg), "sent unsupported message '" .. msg .. "'")
	end
	local res = (msg == "mcp") and {msg} or {msg, self.auth}
	local multi = {}

	for k, v in pairs(args or {}) do
		k, v = tostring(k), tostring(v)
		if not k:find("^%a[^\"*:\\ ]*$") then
			error("invalid key '" .. k .. "'", 2)
		end

		if v:find("\n") then
			multi[k] = v
			res[#res + 1] = k .. '*: ""'
		elseif v:find(" ") then
			res[#res + 1] = ('%s: "%s"'):format(k, v:gsub("[\"\\]", "\\%1"))
		else
			res[#res + 1] = ("%s: %s"):format(k, v)
		end
	end

	if not next(multi) then
		self:sendraw("#$#" .. table.concat(res, " "))
	else
		self.lasttag = self.lasttag + 1
		local tag = ("%x"):format(self.lasttag)

		self:sendraw("#$#" .. table.concat(res, " ") .. " _data-tag: " .. tag)
		for key, val in pairs(multi) do
			for line in string.gmatch(val .. "\n", "([^\n]*)\n") do
				self:sendraw(("#$#: %s %s: %s"):format(tag, key, line))
			end
		end
		self:sendraw("#$#* " .. tag)
	end
end

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

-- if calling this on the server, 'auth' should always be nil
-- 'pkgs' is an array of packages to support
function mcp.new(auth, pkgs)
	assert(not auth:find("[\"*:\\ ]"), "invalid auth key '" .. auth .. "'")

	local obj = setmetatable({
		-- "nil" if MCP is not in use
		version = nil,
		minver = 2.1,
		maxver = 2.1,

		auth = auth,
		server = (auth == nil),
		client = (auth ~= nil),

		-- multi-line data cache
		data = {},
		lasttag = 0,

		-- packages we support
		-- supported packages will have 'version' != nil
		packages = {
			["mcp-negotiate"] = require("mcp.packages.mcp-negotiate"),
		},
		-- full message name => func
		handlers = {},

		remote = {
			minver = nil,
			maxver = nil,

			-- all packages they support (including any we don't)
			packages = {
				["mcp-negotiate"] = {
					-- MCP2.1 requires AT LEAST mcp-negotiate 1.0.
					-- also mcp-negotiate 1.0 is terrible and doesn't negotiate
					-- support for *itself*.
					minver = 1.0,
					maxver = 1.0
				}
			}
		},
	}, {__index = mcp})

	-- as recommended by MCP2.1, we start out with mcp-negotiate 2.0 since
	-- it's compatible with 1.0 and 1.0 is required for MCP2.1 compliance.
	obj.packages["mcp-negotiate"].version = 2.0

	-- load and verify additional packages
	for k, v in pairs(pkgs or {}) do
		obj.packages[k] = v
	end
	for pkgname, v in pairs(obj.packages) do
		assert(v.minver, "package '" .. pkgname .. "' has no 'minver'")
		assert(v.maxver, "package '" .. pkgname .. "' has no 'maxver'")

		for msgname, fn in pairs(v.funcs or {}) do
			local key = pkgname
			if #msgname > 0 then
				key = key .. "-" .. msgname
			end
			obj.handlers[key:lower()] = fn
		end

		if v.init then
			v.init(obj)
		end
	end

	return obj
end

return mcp
