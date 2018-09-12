local persist = require "persist"
local env, err, errno = persist.open_or_new("version_db")
local mcs_versions = env:open_or_new_db("minecraft_server")
local s = require "serpent"
d = mcs_versions:get_all()

for i,v in pairs(d) do
	print(i, s.block(v))
	
end


