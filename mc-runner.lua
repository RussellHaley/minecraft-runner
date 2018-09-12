local cqueues = require "cqueues"
--- lua-http websockets
local websocket = require "http.websocket"
local request = require "http.request"
local request = require "http.request"
local http_server = require "http.server"
local websocket = require "http.websocket"
local http_headers = require "http.headers"
local rolling_logger = require "logging.rolling_file"
local dkjson = require "dkjson"
local persist = require "persist"
local env, err, errno = persist.open_or_new("version_db")
local mcs_versions = env:open_or_new_db("minecraft_server")


local req_timeout = 10
local ShutDown = false
local Sessions = {}

local conf = require('config')

local logger = rolling_logger(conf.base_path .. "/" .. conf.debug_file_name, conf.file_roll_size or 1024*1024*10, conf.max_log_files or 31)
if not logger then
    print("logger failed")
    os.exit(0)
end

local conlog_name = conf.base_path .. "/" .. conf.debug_file_name
print(conlog_name)
local connection_log = rolling_logger(conf.base_path .. "/" .. conf.debug_file_name, conf.file_roll_size or 1024*1024*10, conf.max_log_files or 31)

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
print('one')
	req = request.new_from_uri(uri)
	headers, stream = req:go(req_timeout)
	print('teo')
	if headers then
		for k,v in headers:each() do
			print(k,v)
		end
		local name = dest..'/'.. name
		print(name)
		local file = io.open(name,'w')
		local ok = stream:save_body_to_file(file)
		if ok then
			
			return ok
		end
	else
		--FREAKOUT
		return nil, 'failed to get the file'
	end

end


local function check_for_file()
local counter = 0
	repeat
		local uri, jar = check_mcs_version(conf.start_page)
		if not mcs_versions:item_exists(jar) then
			mcs_versions:add_item(jar, {jar = jar, uri = uri, timestamp = os.date("%Y-%m-%d_%H%M%S")}) 
			logger:info(string.format('Found new file: %s - %s', jar, uri))
			local f = function() 
					print(uri, conf.download_dir, jar)
					local ok, emsg = download_file(uri, conf.download_dir, jar)
					if ok  then
						logger:info("Download Complete.")
						print('Yes!')
					else
						logger:error(emsg)
					end	
				end
				f()
		else
			print('version exists')
			--~ do nothing right now
		end
		cqueues.sleep(2)
		counter = counter + 1
	until counter == 10
end

local function ProcessWebsocketMessage(t, msg)

    if msg.type then

        local type = msg.type:upper()

        if type == "STATUS" then
            t.last_status = os.date()
            local bt = tonumber(msg.body.board_temperature)
            if bt and bt > 158 then
                print("too hot")
                local reply = mbase.New(msg)
                reply.body.response = "Too Damn Hot!"

                t.websocket:send(dkjson.encode(reply))
                logger:info(pt(reply))
            end

            --Log status for each client
        elseif type == "AUTH" then

        elseif type == "DATADUMP" then

        elseif type == "UNIT-RESPONSE" then
        else
            logger:info("Type=" .. msg.type)
            logger:info(pt(msg))
        end
    end
end

--- Get a UUID from the OS
-- return: Returns a system generated UUID
-- such as "4f1c1fbe-87a7-11e6-b146-0c54a518c15b"
-- usage: 4f1c1fbe-87a7-11e6-b146-0c54a518c15b
local function GetUUID()
    local handle = io.popen("uuidgen")
    local val, lines
    if handle then
        val = handle:read("*a")
        --Don't remembe what this does, I think
        -- it strips whitespace?
        val = val:gsub("^%s*(.-)%s*$", "%1")
        handle:close()
    else
        logger:error(0, "Failed to generate UUID");
    end
    return val
end
--- ProcessRequest is where we process the request from the client.
-- The system upgrades to a websocket if the ws or wss protocols are used.
-- @param server ?
-- @param An open stream to the client. Raw socket abstraction?
local function ProcessRequest(server, stream)

    local request_headers = assert(stream:get_headers())
    local request_method = request_headers:get ":method"


    --how do I get the client url and mac?
    connection_log:info(string.format('[%s] "%s %s HTTP/%g"  "%s" "%s" ',
        os.date("%d/%b/%Y:%H:%M:%S %z"),
        request_headers:get(":method") or "",
        request_headers:get(":path") or "",
        stream.connection.version,
        request_headers:get("referer") or "-",
        request_headers:get("user-agent") or "-"
        ))


    local id = GetUUID()

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
                    ProcessWebsocketMessage(t, msg)
                else
                    logger:info("message could not be parsed")
                    logger:info(pos, err)
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
        --standard HTTP request. Need to still do something with it.
        local request_content_type = request_headers:get("content-type")
        local req_body = assert(stream:get_body_as_string(timeout))
        logger:info(req_body)
        local response_headers = http_headers.new()
        response_headers:append(":status", "200")
        response_headers:append("content-type", "text/plain")
        response_headers:append("content-type", request_content_type  or "text/html")

        assert(stream:write_headers(response_headers, request_method == "HEAD"))
        -- Send headers to client; end the stream immediately if this was a HEAD request
        if request_method == "HEAD" then return end;
        -- Send body, ending the stream
        local body = [[<html><head><head><body bgcolor="light blue">This server doesn't like http right now. Please use a websocket</body></html>]]
        --resp:set_body([[<html><head><head><body bgcolor="light blue">This server doesn't like http right now. Please use a websocket</body></html>]])
        assert(stream:write_chunk(body, true))
    end
end

local function Run()

	local app_server = http_server.listen {
		host = '127.0.0.1';
		port = 8080;
		onstream = ProcessRequest;
	}
	--~ debug_file = io.open(i.debug_file_path, 'a')

	--~ LogInfo("Starting client service on " .. os.date("%b %d, %Y %X"))

	cq = cqueues.new()
	cq:wrap(check_for_file)
	cq:wrap(function()
    -- Manually call :listen() so that we are bound before calling :localname()
		assert(app_server:listen())
		do
			print(app_server:localname())
			--~ print(string.format("Now listening on port %d\n", app_server.port))
			print(string.format("Now listening on port %d\n", 8080))
		end
		local cq_ok, err, errno = app_server:loop()
		if not cq_ok then
			print(err, errno, "Http server process ended.", debug.traceback())
		end
	end)


	local cq_ok, err, errno = cq:loop()
	if not cq_ok then
		print(err, errno, "Jumped the loop.", debug.traceback())
	end
    
end

Run()