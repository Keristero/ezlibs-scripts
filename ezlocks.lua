-- ezlocks.lua - Reusable lock/unlock behaviors
local helpers = require('scripts/ezlibs-scripts/helpers')
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local ezbus = require('scripts/ezlibs-scripts/ezbus')

local ezlocks = {}

-- Password check
function ezlocks.check_password(player_id, prompt_message, correct_password)
    return async(function()
        if #prompt_message > 0 then
            await(Async.message_player(player_id, prompt_message))
        end
        local input = await(Async.prompt_player(player_id))
        local passed = (input == correct_password)
        ezbus:emit("lock_attempt", player_id, "password", passed)
        return passed
    end)
end

-- Money check
function ezlocks.check_money(player_id, prompt_message, amount, consume)
    return async(function()
        local passed = false
        local choice = 1
        if #prompt_message > 0 then
            choice = await(Async.question_player(player_id, prompt_message))
            if choice == 0 then return nil end
        end
        if choice == 1 then
            if consume then
                passed = ezmemory.spend_player_money(player_id, amount)
            else
                passed = Net.get_player_money(player_id) >= amount
            end
        end
        ezbus:emit("lock_attempt", player_id, "money", passed, amount, consume)
        return passed
    end)
end

-- Item check
function ezlocks.check_item(player_id, prompt_message, required_item, amount,
                            consume)
    return async(function()
        local passed = false
        local choice = 1
        if #prompt_message > 0 then
            choice = await(Async.question_player(player_id, prompt_message))
            if choice == 0 then return nil end
        end
        if choice == 1 then
            passed = ezmemory.count_player_item(player_id, required_item) >=
                         amount
            if passed and consume then
                ezmemory.remove_player_item(player_id, required_item, amount)
            end
        end
        ezbus:emit("lock_attempt", player_id, "item", passed, required_item,
                   amount, consume)
        return passed
    end)
end

return ezlocks
