#!/usr/bin/env lua
--[[
Verbosely fetches an HTTP resource
If a body is given, use a POST request

Usage: lua examples/simple_request.lua <URI> [<body>]
]]

local uri = assert(arg[1], "URI needed")
local dest = assert(arg[2], "Destination directory required")

local req_timeout = 10

local request = require "http.request"

local req = request.new_from_uri(uri)

local headers, stream = req:go(req_timeout)
if headers == nil then
        io.stderr:write(tostring(stream), "\n")
        os.exit(1)
end

local body, err = stream:get_body_as_string()
if not body and err then
        io.stderr:write(tostring(err), "\n")
        os.exit(1)
end
print('Survey says')
local pattern = "(https://launcher.mojang.com/v1/objects/.*/server.jar).*(minecraft_server%..*%.jar)"
local dl_uri, jar = body:match(pattern)

if dl_uri then
        print(dl_uri)
else
        print('no match')
end

if jar then
        print(jar)
else
        print('no jar')
end

req = request.new_from_uri(dl_uri)
headers, stream = req:go(req_timeout)
if headers then
        for k,v in headers:each() do
                print(k,v)
        end
        local name = dest..'/'.. jar
        print(name)
        local file = io.open(name,'w')
        local ok = stream:save_body_to_file(file)
        if ok then
                print(ok)
        end
else

end
