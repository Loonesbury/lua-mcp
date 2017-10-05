local mcp = require("mcp")

return {
	minver = 1.0,
	maxver = 2.0,

	funcs = {
		["can"] = function(obj, msg, args)
			local rem = {
				minver = tonumber(args["min-version"]),
				maxver = tonumber(args["max-version"]),
			}
			obj.remote.packages[args.package] = rem

			local loc = obj.packages[args.package]
			if loc then
				loc.version = mcp.checkversion(loc.minver, loc.maxver, rem.minver, rem.maxver)
			end
		end,

		["end"] = function(obj)
			obj.negotiating = false
			obj:onready()
		end,
	}
}
