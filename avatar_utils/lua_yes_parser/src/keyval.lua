local KeyVal = {}
KeyVal.new = function(key, val)
    local this = {
        key=key,
        val=val
    }

    local __tostring = function(self)
        if self.key == nil then
            return tostring(self.val)
        end

        return tostring(self.key)..'='..tostring(self.val)
    end

    local mt = {
        __tostring = __tostring
    }
    return setmetatable(this, mt)
end

return KeyVal