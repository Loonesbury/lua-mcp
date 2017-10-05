-- XXX: this whole thing is pretty ugly to use.
-- need clean up the API a little.
local meta = {}

-- return a new cord object
function meta.new(obj, id, type)

	local cord = {
		obj = obj,
		_id = id,
		_type = type,
		hooks = {},
	}
	return setmetatable(cord, {__index = meta})

end

function meta:sendmsg(msg, args)

	args = args or {}
	args._id = self._id
	args._message = msg

	self.obj:sendmcp("mcp-cord", args)

end

function meta:close()

	self.obj:sendmcp("mcp-cord-closed", {_id = self._id})
	self.obj.cords[self._id] = nil
	self:onclosed()

end

-- called for every message the cord receives
function meta:onreceived(msg, args) end
-- 'remote' is true if the remote closed it
function meta:onclosed(remote) end

-- sets a _message hook
function meta:bind(msg, fn)

	self.hooks[msg] = fn

end

-- add mcp convenience functions
local mcp = require("mcp")

-- creates and returns a new outgoing cord
function mcp:newcord(type)

	self.last_cord = self.last_cord + 1

	local id = (self.server and "I" or "R") .. ("%x"):format(self.last_cord)
	local cord = meta.new(self, id, type)
	self.cords[id] = cord

	self:sendmcp("mcp-cord-open", {_id = id, _type = type})

	return cord

end

-- if 'type' is in the form "type", 'fn' is called when we receive a cord of
-- the given type.
--
-- if 'type' is in the form "type:message", 'fn' is called when a cord of the
-- given type receives the given message.
function mcp:bindcord(type, fn)

	if type:find(":", 1, true) then
		self.cordmsghooks[type] = fn
	else
		self.cordhooks[type] = fn
	end

end

return {
	minver = 1.0,
	maxver = 1.0,

	init = function(obj)
		obj.last_cord = 0
		obj.cords = {}
		obj.cordhooks = {}
		obj.cordmsghooks = {}
	end,

	funcs = {
		-- the remote opened a new cord with us
		["open"] = function(obj, msg, args)

			local cord = meta.new(obj, args._id, args._type)
			obj.cords[cord._id] = cord

			if obj.cordhooks[cord._type] then
				obj.cordhooks[cord._type](cord, args)
			end

		end,

		-- the remote sent us a message over a cord
		[""] = function(obj, _, args)
			local cord = obj.cords[args._id]
			if not cord then
				return nil, "remote used unknown cord '" .. args._id .. "'"
			end

			local msg = args._message
			local fullmsg = cord._type .. ":" .. args._message

			cord:onreceived(msg, args)

			local hook = cord.hooks[msg]
			if hook then
				hook(cord, args)
			end

			local mcphook = obj.cordmsghooks[fullmsg]
			if mcphook then
				mcphook(cord, args)
			end
		end,

		-- the remote closed a cord
		["closed"] = function(obj, msg, args)

			local cord = obj.cords[args._id]
			if not cord then
				return nil, "remote closed unknown cord '" .. args._id .. "'"
			end
			cord:onclosed(true)

			obj.cords[args._id] = nil

		end,
	},
}
