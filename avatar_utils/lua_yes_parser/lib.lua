local enums = require('scripts/ezlibs-scripts/avatar_utils/lua_yes_parser/src/enums')
local element = require('scripts/ezlibs-scripts/avatar_utils/lua_yes_parser/src/element')

local Collector = {}

Collector.new = function()
    local self = {
        lineCount = 0,
        pendingAttrs = {},
        elements = {},
        errors = {}
    }

    self.handleLine = function(line)
        self.lineCount = self.lineCount + 1
        local p = element.read(line)

        if(p.error ~= nil) then
            self.errors[#self.errors+1] = {
                line=self.lineCount,
                type=p.error
            }
            return
        end

        if(p.element.type == enums.ElementTypes.ATTRIBUTE) then
            self.pendingAttrs[#self.pendingAttrs+1] = p.element
            return
        elseif p.element.type == enums.ElementTypes.STANDARD then
            p.element.setAttributes(self.pendingAttrs)
            self.pendingAttrs = {}
        end

        self.elements[#self.elements+1] = p.element
    end

    return self
end

local function parse(path)
    local c = Collector.new()

    for line in io.lines(path) do
        c.handleLine(line)
    end
    return c.elements, c.errors
end

return {
    parse=parse,
    enums=enums,
    element=element
}