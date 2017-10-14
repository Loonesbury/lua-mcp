local mcp = require("mcp")

return {
	minver = "1.0",
	maxver = "2.0",

	funcs = {
		["can"] = function(obj, args)

			if not args.package then
				return "invalid 'package'"
			elseif not tonumber(args["min-version"]) then
				return "invalid 'min-version'"
			elseif not tonumber(args["max-version"]) then
				return "invalid 'max-version'"
			end

			local rem = {
				minver = args["min-version"],
				maxver = args["max-version"],
			}

			obj.remote.packages[args.package] = rem

			local loc = obj.packages[args.package]
			if loc then
				loc.version = mcp.checkversion(loc.minver, loc.maxver, rem.minver, rem.maxver)
			end

		end,

		["end"] = function(obj, args)

			obj.negotiating = false
			obj:onready()

		end,
	}
}
