local helpers = require('scripts/ezlibs-scripts/helpers')
local eztriggers = require('scripts/ezlibs-scripts/eztriggers')
local ezcache = require('scripts/ezlibs-scripts/ezcache')
local ezencounters = require('scripts/ezlibs-scripts/ezencounters/main')
eznpcs = require('scripts/ezlibs-scripts/eznpcs/eznpcs')
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local ezmystery = require('scripts/ezlibs-scripts/ezmystery')
local ezweather = require('scripts/ezlibs-scripts/ezweather')
local ezwarps = require('scripts/ezlibs-scripts/ezwarps/main')
local ezfarms = require('scripts/ezlibs-scripts/ezfarms')

local custom_script_path = 'scripts/ezlibs-custom/custom'
local custom_plugin = helpers.safe_require(custom_script_path)

eznpcs.load_npcs()