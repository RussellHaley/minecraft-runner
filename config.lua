local c = {
host='192.168.1.99',
port=8000,
base_path = '.',
data_dir_name = 'data',
debug_file_name = 'server.log',
connection_log = 'connections.log',
file_roll_size = 10485760,
max_log_files=31,
polling_default_seconds = 5,
start_page = "https://minecraft.net/en-us/download/server",
pattern = "(https://launcher.mojang.com/v1/objects/.*/server.jar).*(minecraft_server%..*%.jar)",
download_dir = 'minecraft',
req_timeout = 30
}

return c