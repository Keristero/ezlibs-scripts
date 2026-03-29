local helpers  = require('scripts/ezlibs-scripts/helpers')
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local ezemail  = require('scripts/ezlibs-scripts/ezemail') -- <-- adjust path to wherever your ezemail.lua is
local ezbus = require('scripts/ezlibs-scripts/ezbus')

local ezannounce = {}
local FEED_MODULE = 'scripts/ezlibs-scripts/ezannounce/announcements_feed'
local POLL_SECONDS = 10

local _feed_cache = nil
local _feed_sig = nil
local _watch_started = false
local _online = {}

-- Your server's announcement feed (edit this list to publish new posts)
ezannounce.ANNOUNCEMENTS = {
  -- Example:
  -- {
  --   id = "ANN_2026_02_17_PATCH_01",
  --   icon = 1,
  --   title = "Patch Notes - Feb 17, 2026",
  --   from = "Server News",
  --   body = "• Added HP jukebox support\n• Fixed X\n• Buffed Y\n",
  --   mug_texture_path = "/server/assets/ezlibs-assets/eznpcs/mug/denpa-warp-sf2.png",
  --   mug_animation_path = "/server/assets/ezlibs-assets/eznpcs/mug/mug.animation",
  --   starts_at = 0,     -- optional: os.time() gate
  --   ends_at = nil,     -- optional: expire
  --   priority = 0,      -- higher = more likely to be the one that rings
  --   notify_message = "New server announcement in your inbox!",
  -- },

--  {
--    id = "ANN_180226_1",
--	icon = 1,
--	title = "Welcome",
--	from = "ShaDisNX255",
--	body = "Hey there, welcome to my server. I hope you have fun. We've got fishing, ice puzzles, dueling and a bit of a story in WCity. Feel free to leave your suggestions over at the BBS!\n -ShaDis",
--	mug_texture_path = "/server/assets/ezlibs-assets/eznpcs/mug/luigi-idle.png",
--	mug_animation_path = "/server/assets/ezlibs-assets/eznpcs/mug/mug.animation",
--	notify_message = "Looks like you got a new e-mail",
--  },
}

local function _get_email_bucket(player_id)
  local safe_secret = helpers.get_safe_player_secret(player_id)
  local mem = ezmemory.get_player_memory(safe_secret)
  mem.emails = mem.emails or {}
  mem.emails.by_id = mem.emails.by_id or {}
  return mem.emails.by_id
end

local function _is_active(ann, now)
  now = now or os.time()
  if ann.starts_at and now < ann.starts_at then return false end
  if ann.ends_at and now >= ann.ends_at then return false end
  return true
end

local function _feed_signature(feed)
  -- Only care about ids (because re-sending edited bodies with same id is usually not desired)
  local ids = {}
  for i, ann in ipairs(feed or {}) do
    ids[#ids+1] = tostring(ann.id or "")
  end
  return table.concat(ids, "|")
end

local function _reload_feed()
  if package and package.loaded then
    package.loaded[FEED_MODULE] = nil
  end

  local ok, feed = pcall(require, FEED_MODULE)
  if not ok or type(feed) ~= "table" then
    print("[ezannounce] feed reload failed:", tostring(feed))
    return false
  end

  local sig = _feed_signature(feed)
  if sig == _feed_sig then
    _feed_cache = feed -- still update cache in case table identity matters
    return false
  end

  _feed_cache = feed
  _feed_sig = sig
  print("[ezannounce] feed reloaded, entries:", tostring(#feed))
  return true
end

function ezannounce.get_feed()
  if not _feed_cache then
    _reload_feed()
  end
  return _feed_cache or {}
end

function ezannounce.send_missing(player_id)
  if not player_id then return end
  if ezmemory and ezmemory.is_loaded and not ezmemory.is_loaded() then return end

  local bucket = _get_email_bucket(player_id)
  local now = os.time()
  _online[player_id] = true

  -- Collect announcements the player has never received
  local feed = ezannounce.get_feed()

  -- Build a tombstone set from feed.tombstones (supports list or map style)
  local tomb = {}
  if type(feed.tombstones) == "table" then
    for _, id in ipairs(feed.tombstones) do
      tomb[tostring(id)] = true
    end
    for k, v in pairs(feed.tombstones) do
      if v == true then
        tomb[tostring(k)] = true
      end
    end
  end

  -- Collect announcements the player has never received (skip tombstones)
  local pending = {}
  for _, ann in ipairs(feed) do
    if ann and ann.id and not tomb[ann.id] and _is_active(ann, now) and not bucket[ann.id] then
      table.insert(pending, ann)
    end
  end

  if #pending == 0 then return end

  -- Pick ONE to do the ring/message (highest priority, then newest starts_at)
  table.sort(pending, function(a, b)
    local pa, pb = tonumber(a.priority or 0), tonumber(b.priority or 0)
    if pa ~= pb then return pa > pb end
    local sa, sb = tonumber(a.starts_at or 0), tonumber(b.starts_at or 0)
    return sa > sb
  end)

  local did_notify = false
  for _, ann in ipairs(pending) do
    local mail = {
      id = ann.id,
      icon = ann.icon or 1,
      title = ann.title or "Announcement",
      from = ann.from or "Server",
      body = ann.body or "",
      mug_texture_path = ann.mug_texture_path,
      mug_animation_path = ann.mug_animation_path,
      read = false,
    }

    ezemail.send_once(player_id, mail, {
      notify = not did_notify,
      notify_message = ann.notify_message or ("New announcement: " .. (mail.title or "Update")),
      notify_delay = ann.notify_delay,
    })
    did_notify = true

    ezbus:emit("announcement_sent", {
        player_id = player_id,
        announcement_id = ann.id
    })
  end
end

Net:on("player_disconnect", function(ev)
  if ev and ev.player_id then _online[ev.player_id] = nil end
end)

function ezannounce.broadcast_missing_to_online()
  for pid, _ in pairs(_online) do
    ezannounce.send_missing(pid)
  end
end

function ezannounce.start_watch(interval)
  if _watch_started then return end
  _watch_started = true
  interval = interval or POLL_SECONDS

  local function loop()
    local changed = _reload_feed()
    if changed then
      ezannounce.broadcast_missing_to_online()
    end

    if Async and Async.sleep then
      Async.sleep(interval).and_then(loop)
    end
  end

  loop()
end

ezannounce.start_watch()

return ezannounce