package = "minecraft-runner"
version = "0.0.1-1"
source = {
   url = "git+https://github.com/russellhaley/minecraft-runner"
}
description = {
   summary = "Runs Minecraft server from a pty and forwards I/O to a websocket. Performs updates to the server.jar file.",
   detailed = [[Minecraft Runner allows one to run a minecraft server without the use of screen or tmux. It runs the server ina pty and forwards all IO to any open websocket. It has a built in webserver. The system also checks for updates to the server version and downloads the file. It should perform installation soon.]],
   homepage = "https://github.com/russellhaley/minecraft-runner",
   license = "FreeBSD"
}
dependencies = {
   "lua >= 5.3",
   "serpent >= 0.28",
   "cqueues",
   "http",
   "lualogging",
   "dkjson",
   "uuid",
   "lpty",
   "lfs"   
}

build = {
   type = "builtin",
   modules = {
      ["persist/ptable"] = "persist/ptable.lua",
      ["persist/errors"] = "persist/errors.lua",
      ["persist/defaults"] = "persist/defaults.lua",
      ["persist/serpent_helpers"] = "persist/serpent_helpers.lua",
      ["persist/"] = "persist/init.lua"
   },
   copy_directories = {
      "doc"
   }
}
