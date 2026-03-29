local condition = {}
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local ezquests = require('scripts/ezlibs-scripts/ezquests')
local helpers = require('scripts/ezlibs-scripts/helpers')

function condition.date_before(date_string)
    return helpers.is_now_before_date(date_string)
end

function condition.date_after(date_string)
    return not helpers.is_now_before_date(date_string)
end

function condition.item(player_id, item_name, amount, consume)
    amount = amount or 1
    local has = ezmemory.count_player_item(player_id, item_name) >= amount
    if has and consume then
        ezmemory.remove_player_item(player_id, item_name, amount)
    end
    return has
end

function condition.money(player_id, amount, consume)
    amount = amount or 1
    local has = ezmemory.get_player_money(player_id) >= amount
    if has and consume then
        ezmemory.spend_player_money(player_id, amount)
    end
    return has
end

function condition.fragments(player_id, amount, consume)
    amount = amount or 1
    local has = ezmemory.get_player_fragments(player_id) >= amount
    if has and consume then
        return ezmemory.spend_player_fragments(player_id, amount)
    end
    return has
end

function condition.tokens(player_id, amount, consume)
    amount = amount or 1
    local has = ezmemory.get_player_tokens(player_id) >= amount
    if has and consume then
        return ezmemory.spend_player_tokens(player_id, amount)
    end
    return has
end

function condition.quest_flag(player_id, quest_name, flag_name, expected, op)
    local value = ezquests.get_player_quest_flag(player_id, quest_name, flag_name)
    if expected == nil then
        return not (value == nil or value == false or value == "false")
    end
    op = op or "=="
    if op == "==" then
        return tostring(value) == tostring(expected)
    elseif op == "!=" then
        return tostring(value) ~= tostring(expected)
    else
        local a = tonumber(value)
        local b = tonumber(expected)
        if a and b then
            if op == ">=" then return a >= b end
            if op == "<=" then return a <= b end
            if op == ">"  then return a > b end
            if op == "<"  then return a < b end
        end
        return tostring(value) == tostring(expected)
    end
end

function condition.evaluate(player_id, cond)
    if not cond or not cond.type then return true end
    if cond.type == "date_before" then
        return condition.date_before(cond.date)
    elseif cond.type == "date_after" then
        return condition.date_after(cond.date)
    elseif cond.type == "item" then
        return condition.item(player_id, cond.name, cond.amount, cond.consume)
    elseif cond.type == "money" then
        return condition.money(player_id, cond.amount, cond.consume)
    elseif cond.type == "fragments" then
        return condition.fragments(player_id, cond.amount, cond.consume)
    elseif cond.type == "tokens" then
        return condition.tokens(player_id, cond.amount, cond.consume)
    elseif cond.type == "quest_flag" then
        return condition.quest_flag(player_id, cond.quest, cond.flag, cond.value, cond.op)
    end
    return true
end

return condition