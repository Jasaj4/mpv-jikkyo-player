-- main.lua — mpv script directory entry point
-- mpv loads this when the project is installed as:
--   ~/.config/mpv/scripts/jikkyo-player/ -> this project
-- mp.get_script_directory() returns the project root, so lib/ is directly accessible.

local mp = require 'mp'

local script_dir = mp.get_script_directory()
package.path = script_dir .. "/lib/?.lua;" .. package.path

dofile(script_dir .. "/mpv/jikkyo-player.lua")
