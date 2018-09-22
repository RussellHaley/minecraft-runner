local cqueues = require "cqueues"
local request = require "http.request"
local http_server = require "http.server"
local websocket = require "http.websocket"
local http_headers = require "http.headers"
local new_headers = require "http.headers".new
local http_util = require "http.util"
local http_version = require "http.version"
local lpeg = require "lpeg"
local uri_patts = require "lpeg_patterns.uri"
local ce = require "cqueues.errno"
local rolling_logger = require "logging.rolling_file"
local dkjson = require "dkjson"
--~ local persist = require "persist"
local uuid = require "uuid"
local lpty = require "lpty"
local lfs = require 'lfs'
local serpent = require "serpent"

--~ local pty
--~ local env, err, errno = persist.open_or_new("version_db")
--~ local mcs_versions = env:open_or_new_db("minecraft_server")
uuid.randomseed(12365843213246849613)
local req_timeout = 10
local ShutDown = false
local Sessions = {}
local uri_reference = uri_patts.uri_reference * lpeg.P(-1)
local conf = require('config')

--~ Placeholder for the function that writes websocke messages to the minecraft server.
--~  I can either use a scriptwide pty or a set the pty through a funciton in Run(). I chose the later.
local write_to_process

local logger = rolling_logger(conf.base_path .. "/" .. conf.debug_file_name, conf.file_roll_size or 1024*1024*10, conf.max_log_files or 31)
if not logger then
	print("logger failed")
	os.exit(0)
end

local connection_log = rolling_logger(conf.base_path .. "/" .. conf.connection_log, conf.file_roll_size or 1024*1024*10, conf.max_log_files or 31)

local function check_mcs_version(uri)

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


	local dl_uri, jar = body:match(conf.pattern)
	
	if not dl_uri then
		logger:error('Failed to parse uri filename')
		return nil, 'No URI'
	end

	if not jar then
		logger:error('Failed to parse jar filename')
		return nil, 'No jar file'
	end
	return dl_uri, jar
	
end

local function download_file(uri, dest, name)
	req = request.new_from_uri(uri)
	headers, stream = req:go(req_timeout)
	if headers then
		local name = dest..'/'.. name
		local file = io.open(name,'w')
		local ok = stream:save_body_to_file(file)
		return ok
	else
		--FREAKOUT
		return nil, 'failed to get the file'
	end

end

local function check_fs_for_mc(check_path, jar_name)
	
	local i, t, popen = 0, {}, io.popen
	local command = 'ls -a '.. check_path ..'/' .. jar_name .. ' 2> /dev/null'

	local pfile = popen(command)
	for filename in pfile:lines() do
		i = i + 1
		t[i] = filename
	end
	pfile:close()
	
	if #t == 0 then
		return nil
	else
		return t
	end
	
end

local function shutdown(pty)

	local count = 1
	--~ Ask Nicely
	while pty:hasproc() and count <= 10 do
		pty:send("/stop\n")
		cqueues.sleep(1) 
		count = count + 1
	end

	--~ NOTE: THIS DOESN'T WORK???
	--~ KILL
	if pty:hasproc() then
		pty:endproc(true)
		logger:warn('Had to SIGKIL Minecraft.')
	else
		logger:info('Minecraft stopped.')
	end
	
	return not pty:hasproc()
end


--- Get a UUID from the OS
-- return: Returns a system generated UUID
-- such as "4f1c1fbe-87a7-11e6-b146-0c54a518c15b"
local function get_uuid()
	local u = uuid()
	return u
end


local default_server = string.format("%s/%s", http_version.name, http_version.version)

local xml_escape do
	local escape_table = {
		["'"] = "&apos;";
		["\""] = "&quot;";
		["<"] = "&lt;";
		[">"] = "&gt;";
		["&"] = "&amp;";
	}
	function xml_escape(str)
		str = string.gsub(str, "['&<>\"]", escape_table)
		str = string.gsub(str, "[%c\r\n]", function(c)
			return string.format("&#x%x;", string.byte(c))
		end)
		return str
	end
end

local human do -- Utility function to convert to a human readable number
	local suffixes = {
		[0] = "";
		[1] = "K";
		[2] = "M";
		[3] = "G";
		[4] = "T";
		[5] = "P";
	}
	local log = math.log
	if _VERSION:match("%d+%.?%d*") < "5.1" then
		log = require "compat53.module".math.log
	end
	function human(n)
		if n == 0 then return "0" end
		local order = math.floor(log(n, 2) / 10)
		if order > 5 then order = 5 end
		n = math.ceil(n / 2^(order*10))
		return string.format("%d%s", n, suffixes[order])
	end
end


local function static_reply(myserver, stream, req_headers) -- luacheck: ignore 212

	-- Read in headers
	assert(req_headers)
	local req_method = req_headers:get ":method"

	-- Log request to stdout
	assert(io.stdout:write(string.format('[%s] "%s %s HTTP/%g"  "%s" "%s"\n',
		os.date("%d/%b/%Y:%H:%M:%S %z"),
		req_method or "",
		req_headers:get(":path") or "",
		stream.connection.version,
		req_headers:get("referer") or "-",
		req_headers:get("user-agent") or "-"
	)))

	-- Build response headers
	local res_headers = new_headers()
	res_headers:append(":status", nil)
	res_headers:append("server", default_server)
	res_headers:append("date", http_util.imf_date())

	if req_method ~= "GET" and req_method ~= "HEAD" then
		res_headers:upsert(":status", "405")
		assert(stream:write_headers(res_headers, true))
		return
	end

	local path = req_headers:get(":path")
	local uri_t = assert(uri_reference:match(path), "invalid path")
	path = http_util.resolve_relative_path("/", uri_t.path)
	local real_path = conf.static_dir .. path
	print(path, real_path)
	local file_type = lfs.attributes(real_path, "mode")
	print(string.format("file type: %s", file_type)) 
	if file_type == "directory" then
		--~ directory listing
		path = path:gsub("/+$", "") .. "/"
		res_headers:upsert(":status", "200")
		res_headers:append("content-type", "text/html; charset=utf-8")
		assert(stream:write_headers(res_headers, req_method == "HEAD"))
		if req_method ~= "HEAD" then

			assert(stream:write_chunk(string.format([[
<!DOCTYPE html>
<html>
<head>
	<title>Index of %s</title>
	<style>
		a {
			float: left;
		}
		a::before {
			width: 1em;
			float: left;
			content: "\0000a0";
		}
		a.directory::before {
			
			content: "\0000a0";
		}
		table {
			width: 800px;
		}
		td {
			padding: 0 5px;
			white-space: nowrap;
		}
		td:nth-child(2) {
			text-align: right;
			width: 3em;
		}
		td:last-child {
			width: 1px;
		}
	</style>
</head>
<body>
	<h1>Index of %s</h1>
	<table>
		<thead><tr>
			<th>File Name</th><th>Size</th><th>Modified</th>
		</tr></thead>
		<tbody>
]], xml_escape(path), xml_escape(path)), false))
			-- lfs doesn't provide a way to get an errno for attempting to open a directory
			-- See https://github.com/keplerproject/luafilesystem/issues/87
			for filename in lfs.dir(real_path) do
				if not (filename == ".." and path == "/") then -- Exclude parent directory entry listing from top level
					local stats = lfs.attributes(real_path .. "/" .. filename)
					if stats.mode == "directory" then
						filename = filename .. "/"
					end
					assert(stream:write_chunk(string.format("\t\t\t<tr><td><a class='%s' href='%s'>%s</a></td><td title='%d bytes'>%s</td><td><time>%s</time></td></tr>\n",
						xml_escape(stats.mode:gsub("%s", "-")),
						xml_escape(http_util.encodeURI(path .. filename)),
						xml_escape(filename),
						stats.size,
						xml_escape(human(stats.size)),
						xml_escape(os.date("!%Y-%m-%d %X", stats.modification))
					), false))
				end
			end
			assert(stream:write_chunk([[
		</tbody>
	</table>
</body>
</html>
]], true))
		end
	elseif file_type == "file" then
	
		local fd, err, errno = io.open(real_path, "rb")
		local code
		if not fd then
			if errno == ce.ENOENT then
				code = "404"
			elseif errno == ce.EACCES then
				code = "403"
			else
				code = "503"
			end
			res_headers:upsert(":status", code)
			res_headers:append("content-type", "text/plain")
			assert(stream:write_headers(res_headers, req_method == "HEAD"))
			if req_method ~= "HEAD" then
				assert(stream:write_body_from_string("Fail!\n"..err.."\n"))
			end
		else
			res_headers:upsert(":status", "200")
			res_headers:append("content-type", "text/plain")
			res_headers:append("content-type", "text/html")
			--~ local mime_type = mdb and mdb:file(real_path) or "application/octet-stream"
			--~ res_headers:append("content-type", mime_type)
			assert(stream:write_headers(res_headers, req_method == "HEAD"))
			if req_method ~= "HEAD" then
				assert(stream:write_body_from_file(fd))
			end
		end
	elseif file_type == nil then
	
		res_headers:upsert(":status", "404")
		assert(stream:write_headers(res_headers, true))
	else
		res_headers:upsert(":status", "403")
		assert(stream:write_headers(res_headers, true))
	end
end


local function websocket_reply(t, msg)
	if msg.cmd then
		local cmd = msg.cmd:upper()

		if cmd == "STATUS" then

			--Log status for each client
		elseif cmd == "AUTH" then

		elseif cmd == "HELP" then
			write_to_process(msg.cmd..'\n')
		elseif cmd == "UNIT-RESPONSE" then
		else
			logger:info("Type=" .. msg.cmd)
			write_to_process(msg.cmd..'\n')
		end
	end
end


--- process_request is where we process the request from the client.
-- The system upgrades to a websocket if the ws or wss protocols are used.
-- @param server ?
-- @param An open stream to the client. Raw socket abstraction?
local function process_request(server, stream)

	local request_headers = assert(stream:get_headers())
	local request_method = request_headers:get ":method"


	local id = get_uuid()
	--how do I get the client url and mac?
	connection_log:info(string.format('[%s] "%s %s HTTP/%g"  "%s" "%s" ',
		id,
		request_headers:get(":method") or "",
		request_headers:get(":path") or "",
		stream.connection.version,
		request_headers:get("referer") or "-",
		request_headers:get("user-agent") or "-"
		));

	local ws = websocket.new_from_stream(stream, request_headers)
	if ws then
		local t = {}
		t.session_id = id
		t.session_start = os.date()
		t.websocket = ws
		Sessions[id] = t

		assert(ws:accept())
		assert(ws:send("Welcome To exb Server"))
		assert(ws:send("Your client id is " .. t.session_id))

		--Send an Authenticate required message
		repeat
			local data, err, errno = ws:receive()
			if data then
				local msg, pos, err = dkjson.decode(data, 1, nil)
				if msg then
					if DEBUG then
						logger:info(serpent.block(msg))
					end
					websocket_reply(t, msg)
				else
					logger:info("message could not be parsed")
					logger:info(pos, err)
					ws:send(string.format("I only speak json, sorry. %s - %s", data, t.session_id))
				end
			else
				--Add valid reason codes for the data to be nil?
				if errno == 1 then

				else
					logger:error(err, errno, "Recieve Failed")
				end
			end

		until not data
		logger:info("removed " .. id)
		Sessions[id] = nil
	else
		static_reply(server, stream, request_headers)
	end
end
	




local function Listen(app_server)

	-- Manually call :listen() so that we are bound before calling :localname()
	assert(app_server:listen())
	do
		
		logger:info(string.format("Now listening on %s port %d\n", app_server:localname(), conf.port))
	end
	local cq_ok, err, errno = app_server:loop()
	if not cq_ok then
		print(err, errno, "Http server process ended.", debug.traceback())
	end

end

local function read_process(pty)
	Shutdown = false
	repeat
		local ok = pty:readok(0.1)
		if ok then
			data = pty:read(0.1)
		for i,v in pairs(Sessions) do
			v.websocket:send(data)
		end
			print( '*', data, data:len() )
		else
		  --Do nothing right now.
		end
		cqueues.sleep(1)
	until Shutdown
	print('exited')
end




local function StartMineCraft(pty, jar_path, jar_name, start_page, retries)
	if not retries or type(retries) ~= 'number' then retries = 1 end
	
	local err = string.format('Failed to start minecraft after %d attempts', retries)
	if not jar_path or not jar_name then 
		local str = "Cannot start minecraft without a path and jar name."
		logger:error(str)
		return nil, str
	end

	repeat
		local jar = check_fs_for_mc(jar_path, jar_name)
		
		if jar then 
			local cur_dir = lfs.currentdir()
			lfs.chdir(jar_path)
			local command = 'java'
			--HACK: I don't want to pass around memory configurations. So I'm hacking in the
			-- scriptwide conf. It's a cheat.
			local xmx = string.format('-Xmx%dM',conf.memory_max)
			local xms = string.format('-Xms%dM',conf.memory_min)
			
			local args = {xms, xmx, '-jar', jar_name,  'nogui'}
			local ok = pty:startproc(command, table.unpack(args))
			lfs.chdir(cur_dir)
			if not ok then
				local str = "Failed to start pty"
				logger:error(str)
			else 
				if not pty:hasproc() then
					local str = string.format('Failed to start Process: Path %s, jar file: %s', jar_path, jar_name)
					logger:error(str)
				end
			end
			logger:info('Minecraft started.')
			return true
		else
			if start_page then
				logger:info('Minecraft Jar not found. Downloading...')
				local uri, name = check_mcs_version(start_page)
				if uri and name then
					local ok, emsg = download_file(uri, jar_path, name)
					if ok  then
						logger:info("Download Complete.")
					else
						logger:error(emsg)
					end
				else
					logger:error(string.format('Failed to find a uri or filename at %s', start_page))
				end
			end
		end
		retries = retries - 1
	until retries == 0
	
	return nil
end



local function check_web_for_latest(pty, start_page, mc_dir)
	local counter = 0
	repeat
		local uri, jar = check_mcs_version(start_page)
		if not check_fs_for_mc(mc_dir, jar) then
	--~ if not mcs_versions:item_exists(jar) then
		--~ mcs_versions:add_item(jar, {jar = jar, uri = uri, timestamp = os.date("%Y-%m-%d_%H%M%S")}) 
			logger:info(string.format('Found new file: %s - %s', jar, uri))
			
			--~ print(uri, mc_dir, jar)
			local ok, emsg = download_file(uri, mc_dir, jar)

			if ok  then
				logger:info("Download Complete.")
				
				if not shutdown(pty) then
					local str = 'Failed to shutdown PTY in any sane way. Killing everything and restarting.'
					logger:error(str)
					error(str)
				end
				if not StartMineCraft(pty, mc_dir, jar, nil, 3) then
					logger:fatal('Failed to start the minecraft server. Could not download a new copy. Dying now.')
					pty = nil
					os.exit(-1)
				end
			else
				logger:error(emsg)
			end
			
		end
	cqueues.sleep(2)
	  --NOTE: Count will never equal 1!
	  --         counter = counter + 1
	until counter == 1
end

local function Init()
	return nil
end

local function Run()
	--~ local _, jar = check_mcs_version("http://jiberish.com") --conf.start_page)
	local _, jar = check_mcs_version(conf.start_page)
	if not jar then
		logger:fatal('You have to read jar info from the web first. See start_page in the config.lua file.')
		os.exit(-1) 
	end

	logger:info(string.format('Latest minecrafter server version is %s', jar))
	
	local pty = lpty.new({raw_mode=true})
	if not pty then
		logger:fatal('Failed to start a pty.')
		os.exit(-1)
	end
	
	--~ NOTE: os.exit() LEAVES THE PTY OPEN. ASSERT JUST RESTARTS THE RUN() FUNCTION
	if not StartMineCraft(pty, conf.minecraft_dir, jar, conf.start_page, 3) then
		logger:fatal('Failed to start the minecraft server. Could not download a new copy. Dying now.')
		pty = nil --testing this, don't know if it works
		os.exit(-1)
	end

	cq = cqueues.new()

	cq:wrap(function() 
			read_process(pty) 
		end);
		
	cq:wrap(function()
			check_web_for_latest(pty, conf.start_page, conf.minecraft_dir)
		end);

	write_to_process = function(str)
	--~ NEED TO TEST FOR PTY. 
	--~ This isn't a great pattern. I need to test the pty
	--~ as well as allow it to be shutdown  and restarted
	--~ without breaking things
		pty:send(str)
		print("sent: " .. str)
	end

	local app_server = http_server.listen {
	host = conf.host;
	port = conf.port;
	onstream = process_request;
	}
	cq:wrap(function()
			Listen(app_server)
		end);

	--cq:wrap(open_mc)


	local cq_ok, err, errno = cq:loop()
	if not cq_ok then
	logger:fatal("%d - %s\n%s", errno or -1, err, debug.traceback())
	print(err, errno, "Jumped the loop.", debug.traceback())
	end
end

-- call Run with pcall and if it dies, restart it. We can then add a proper handler in cqueues for signals
repeat
	Run()
	logger:error("Restarting services. Check yer logs.")
until not true

