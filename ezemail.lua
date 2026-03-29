local helpers = require('scripts/ezlibs-scripts/helpers')
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local ezbus = require('scripts/ezlibs-scripts/ezbus')
local CONFIG = require('scripts/ezlibs-scripts/ezconfig')

local ezemail = {}
-- tweak these
local NEW_MAIL_MESSAGE_DELAY = CONFIG.NEW_MAIL_MESSAGE_DELAY or 1.5        -- seconds: wait after ring before message_player
local ENABLE_TEST_EMAIL_ON_JOIN = false    -- set false after you finish tuning
local TEST_EMAIL_DELAY = 2.0              -- seconds (start same as NEW_MAIL_MESSAGE_DELAY)
local EZEMAIL_DEBUG = true -- set false after verified
local ANNOUNCEMENTS_FEED_MODULE = 'scripts/ezlibs-scripts/announcements_feed'


local function _preload_email_assets(player_id, mail)
  if not (Net and Net.provide_asset_for_player) then return end
  if not mail then return end

  -- Email system requires mug paths anyway; but keep these checks safe.
  if mail.mug_texture_path and mail.mug_texture_path ~= "" then
    pcall(Net.provide_asset_for_player, player_id, mail.mug_texture_path)
  end

  if mail.mug_animation_path and mail.mug_animation_path ~= "" then
    pcall(Net.provide_asset_for_player, player_id, mail.mug_animation_path)
  end
end

local function _get_bucket(player_id)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local mem = ezmemory.get_player_memory(safe_secret)
    mem.emails = mem.emails or {}
    mem.emails.by_id = mem.emails.by_id or {}
    return safe_secret, mem.emails.by_id
end

local function _dbg(...)
    if EZEMAIL_DEBUG then
        print("[ezemail]", ...)
    end
end

local function _percent_decode(s)
    s = tostring(s or "")
    return (s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

local function _get_tombstone_set()
  local ok, feed = pcall(require, ANNOUNCEMENTS_FEED_MODULE)
  if not ok or type(feed) ~= "table" then
    return {}
  end

  local t = feed.tombstones
  if type(t) ~= "table" then
    return {}
  end

  local set = {}

  -- supports list-style: { "ID1", "ID2" }
  for _, id in ipairs(t) do
    id = tostring(id)
    set[id] = true
    set[_percent_decode(id)] = true
  end

  -- also supports map-style: { ID1=true, ID2=true }
  for k, v in pairs(t) do
    if v == true then
      k = tostring(k)
      set[k] = true
      set[_percent_decode(k)] = true
    end
  end

  return set
end

local function _find_mail_in_bucket(bucket, email_id)
    if not bucket or not email_id then return nil, nil end
    email_id = tostring(email_id)

    -- 1) direct
    if bucket[email_id] then return bucket[email_id], email_id end

    -- 2) decoded comparisons (handles %XX mismatch)
    local want = _percent_decode(email_id)

    for k, v in pairs(bucket) do
        if k == email_id then
            return v, k
        end
        if _percent_decode(k) == want then
            return v, k
        end
        if _percent_decode(email_id) == _percent_decode(k) then
            return v, k
        end
    end

    return nil, nil
end

local function _mark_email_read(player_id, email_id)
    if not player_id or not email_id then return end

    local safe_secret, bucket = _get_bucket(player_id)
    local stored, key = _find_mail_in_bucket(bucket, email_id)

    if not stored then
        _dbg("email_read fired but mail id not found in memory:", tostring(email_id))
        return
    end

    if stored.read ~= true then
        stored.read = true
        ezmemory.save_player_memory(safe_secret)
        _dbg("marked read:", tostring(key))
    else
        _dbg("already read:", tostring(key))
    end
end

local function _notify_new_mail(player_id, msg, delay_seconds)
    msg = msg or "Looks like you got an e-mail."
    delay_seconds = delay_seconds or NEW_MAIL_MESSAGE_DELAY

    pcall(function()
        if Net.ring_player_hud then
            Net.ring_player_hud(player_id)
        end
    end)

    if not Net.message_player then
        return
    end

    local function send_msg()
        pcall(function()
            local mug = Net.get_player_mugshot(player_id)
            Net.message_player(player_id, msg, mug.texture_path, mug.animation_path)
        end)
    end

    -- Delay so ring isn't interrupted
    if Async and Async.sleep and delay_seconds and delay_seconds > 0 then
        Async.sleep(delay_seconds).and_then(send_msg)
    else
        send_msg()
    end
end

function ezemail.resend_all(player_id)
    if not Net.send_player_email then
        return
    end

    local ok, safe_secret, bucket = pcall(function()
        local ss, b = _get_bucket(player_id)
        return ss, b
    end)

    if not ok or not bucket then
        return
    end

    local dirty = false
    local tombstones = _get_tombstone_set()

    -- Remove tombstoned emails from memory so they will no longer be restored
    if tombstones and next(tombstones) ~= nil then
      local to_delete = {}

      for key, stored in pairs(bucket) do
        local id = tostring((stored and stored.id) or key)
        if tombstones[id] or tombstones[key] or tombstones[_percent_decode(id)] or tombstones[_percent_decode(key)] then
          to_delete[#to_delete + 1] = key
        end
      end

      if #to_delete > 0 then
        for _, key in ipairs(to_delete) do
          bucket[key] = nil
        end
        dirty = true
        _dbg("pruned tombstoned mails:", #to_delete)
      end
    end

    for _, stored in pairs(bucket) do
      local mail = helpers.deep_copy(stored)

      -- TEMP: treat restored mail as already read
      mail.read = true

      -- Optional: migrate memory so old mail stays read even after engine fixes email_read
      if stored.read ~= true then
        stored.read = true
        dirty = true
      end

      pcall(function()
        _preload_email_assets(player_id, mail)
        Net.send_player_email(player_id, mail)
      end)
    end

    if dirty then
      ezmemory.save_player_memory(safe_secret)
    end
end

-- Sends + saves (only notifies the FIRST time this mail id is ever sent to this player)
-- opts = { notify=true/false, notify_message="...", notify_use_player_mug=true/false }
function ezemail.send_once(player_id, mail, opts)
    opts = opts or {}
    if not mail or not mail.id then
        return
    end
    local tombstones = _get_tombstone_set()
    if tombstones[mail.id] or tombstones[_percent_decode(mail.id)] then
      _dbg("send_once blocked (tombstoned):", tostring(mail.id))
      return
    end
    if not Net.send_player_email then
        return
    end

    local safe_secret, bucket = _get_bucket(player_id)
    local first_time = (bucket[mail.id] == nil)

    if first_time then
        bucket[mail.id] = mail
        if bucket[mail.id].read == nil then
            bucket[mail.id].read = false
        end
        ezmemory.save_player_memory(safe_secret)
    end

    -- Always send to current session (mailbox is session-only)
    pcall(function()
        _preload_email_assets(player_id, mail)
        Net.send_player_email(player_id, mail)
        ezbus:emit("email_sent", {
            player_id = player_id,
            email_id = mail.id,
            persistent = true
        })
    end)

    -- Notify only the first time (ring -> wait -> message)
    if first_time and opts.notify ~= false then
        local msg = opts.notify_message or "Looks like you got an e-mail."
        local delay = opts.notify_delay or NEW_MAIL_MESSAGE_DELAY
        _notify_new_mail(player_id, msg, delay)
    end
end

-- Sends an email WITHOUT saving it (session-only).
-- Still supports notify timing (ring -> wait -> message).
function ezemail.send_temp(player_id, mail, opts)
    opts = opts or {}
    if not mail or not mail.id then return end
    if not Net.send_player_email then return end

    pcall(function()
        _preload_email_assets(player_id, mail)
        Net.send_player_email(player_id, mail)
        ezbus:emit("email_sent", {
            player_id = player_id,
            email_id = mail.id,
            persistent = false
        })
    end)

    if opts.notify ~= false then
        local msg = opts.notify_message or "Looks like you got an e-mail."
        local delay = opts.notify_delay or NEW_MAIL_MESSAGE_DELAY
        _notify_new_mail(player_id, msg, delay)
    end
end

function ezemail.send_test_email(player_id, delay_seconds)
    if not Net.send_player_email then
        return
    end

    local safe_secret = helpers.get_safe_player_secret(player_id)
    local mail = {
        id = "EZTEST_" .. tostring(safe_secret) .. "_" .. tostring(os.time()),
        icon = 1,
        title = "Test",
        from = "MailSys",
        body = "Testing email notification delay.\n\nDelay: " .. tostring(delay_seconds or TEST_EMAIL_DELAY) .. " seconds.",
        mug_texture_path = "/server/assets/ezlibs-assets/eznpcs/mug/denpa-warp-sf2.png",
        mug_animation_path = "/server/assets/ezlibs-assets/eznpcs/mug/mug.animation",
        read = false,
    }

    pcall(function()
        ezemail.send_temp(player_id, mail, { notify = true })
    end)

end

-- Silent restore on login (no ring/message)
Net:on("player_join", function(event)
    if not event or not event.player_id then return end

    -- If ezmemory isn't loaded yet, the player will be kicked by ezmemory anyway.
    if ezmemory and ezmemory.is_loaded and not ezmemory.is_loaded() then
        return
    end

    ezemail.resend_all(event.player_id)
    pcall(function()
      local ezannounce = require('scripts/ezlibs-scripts/ezannounce/ezannounce')
      ezannounce.send_missing(event.player_id)
    end)
    if ENABLE_TEST_EMAIL_ON_JOIN then
        ezemail.send_test_email(event.player_id, TEST_EMAIL_DELAY)
    end
end)

-- Handle email_read events: mark the email as read in player memory
Net:on("email_read", function(event)
  local player_id = event.player_id
  local email_id = event.email_id

  _dbg("email_read fired for player", player_id, "email", email_id)

  -- Mark the email as read in persistent memory
  _mark_email_read(player_id, email_id)
end)

return ezemail