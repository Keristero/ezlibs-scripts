local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local helpers = require('scripts/ezlibs-scripts/helpers')

local ezquests = {
    quests={}
}

function ezquests.add_quest(quest)
    if not quest.name then
        warn('[ezquests] quest has no name')
        return
    end
    if not quest.handle_event_async then
        warn('[ezquests] quest',quest.name,'needs a handle_event function')
        return
    end
    if not quest.determine_state then
        warn('[ezquests] quest',quest.name,'needs a determine_state function')
        return
    end
    if ezquests.quests[quest.name] then
        warn('[ezquests] quest',quest.name,'already exists and will be replaced')
    end
    ezquests.quests[quest.name] = quest
end

function ezquests.set_player_quest_flag(player_id,quest_name,flag_name,flag_state)
    print('[ezquests]',quest_name,'flag(',flag_name,')set to',flag_state,'for player',player_id)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_memory = ezmemory.get_player_memory(safe_secret)
    if not player_memory["quests"] then
        player_memory["quests"] = {}
    end
    if not player_memory["quests"][quest_name] then
        player_memory["quests"][quest_name] = {}
    end
    player_memory["quests"][quest_name][flag_name] = flag_state
    ezmemory.save_player_memory(safe_secret)
end

function ezquests.get_player_quest_flag(player_id,quest_name,flag_name,flag_state)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_memory = ezmemory.get_player_memory(safe_secret)
    if not player_memory["quests"] then
        return nil
    end
    if not player_memory["quests"][quest_name] then
        return nil
    end
    return player_memory["quests"][quest_name][flag_name]
end

function ezquests.clear_player_quest_flags(player_id,quest_name)
    print('[ezquests] clearing all flags for quest',quest_name,'for player',player_id)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_memory = ezmemory.get_player_memory(safe_secret)
    if not player_memory["quests"] then
        player_memory["quests"] = {}
    end
    player_memory["quests"][quest_name] = {}
    ezmemory.save_player_memory(safe_secret)
end

function ezquests.get_quest(quest_name)
    local quest = ezquests.quests[quest_name]
    if quest then
        return quest
    else
        warn('[ezquests] no quest with name ',quest_name)
    end
end

function ezquests.get_player_quest_state(player_id,quest_name)
    local quest = ezquests.get_quest(quest_name)
    return quest:determine_state(player_id)
end

function ezquests.quest_event(player_id,quest_name,event_value)
    local quest = ezquests.get_quest(quest_name)
    print('[ezquests] quest=',quest)
    return quest:handle_event_async(player_id,event_value)
end


--testing quest
--handle_event_async must return a promise
local quest_get_punched = {
    name = "Get Punched",
    handle_event_async = function (self,player_id,event_value)
        return async(function ()
            local accpeted = ezquests.get_player_quest_flag(player_id,self.name,'accepted')
            if accpeted or event_value == "accepted" then
                --set the flag if the quest is accepted, or we are accpeting it
                ezquests.set_player_quest_flag(player_id,self.name,event_value,true)
            end
            if event_value == 'reset' then
                ezquests.clear_player_quest_flags(player_id,self.name)
            end
        end)
    end,
    determine_state = function (self,player_id)
        if ezquests.get_player_quest_flag(player_id,self.name,'punched') then
            return "punched"
        end
        if ezquests.get_player_quest_flag(player_id,self.name,'accepted') then
            return "accepted"
        end
        return "unaccepted"
    end
}
ezquests.add_quest(quest_get_punched)

return ezquests