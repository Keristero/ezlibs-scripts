local enums = require('scripts/ezlibs-scripts/avatar_utils/lua_yes_parser/src/enums')
local KeyVal = require('scripts/ezlibs-scripts/avatar_utils/lua_yes_parser/src/keyval')
local trim = require('scripts/ezlibs-scripts/avatar_utils/lua_yes_parser/src/utils/trim')

local Element = {}
Element.new = function()
    local this = {
        attributes = {},
        text = '',
        args = {},
        type = enums.ElementTypes.STANDARD
    }

    local __tostring = function(self)
        local token = ''
        local glyph <const> = enums.glyphForType(self.type)
        if glyph ~= enums.Glyphs.NONE then
            token = string.char(glyph)
        end
        return token..self.text..' '..self.printArgs()
    end

    this.setAttributes = function(attrs)
        this.attributes = {}
        for i in ipairs(attrs) do
            local a = attrs[i]
            -- Perform a sanity check
            if a.type ~= enums.ElementTypes.ATTRIBUTE then
                error('Element is not an attribute!')
            end
            this.attributes[#this.attributes+1] = a
        end
    end

    -- helper func 
    local findKey = function(key)
        if key == nil then return -1 end
        for i in ipairs(this.args) do
            local e = this.args[i]
            if e.key ~= nil and string.lower(e.key) == string.lower(key) then
                return i
            end
        end
        return -1
    end

    -- public funcs

    this.upsert = function(keyval)
        local idx <const> = findKey(keyval.key)

        -- Insert if no match was found
        if idx == -1 then
            this.args[#this.args+1] = keyval
            return
        end

        -- Update by replacing
        this.args[idx] = keyval
    end

    this.hasKey = function(key)
        return findKey(key) > -1
    end

    this.hasKeys = function(keyList)
        for i in pairs(keyList) do
            if findKey(keyList[i]) == -1 then
                return false
            end
        end

        return true
    end

    this.getKeyValue = function(key, orValue)
        local idx <const> = findKey(key)

        if idx ~= -1 then
            return this.args[idx].val
        end

        -- return default value
        return orValue
    end

    this.getKeyValueAsInt = function(key, orValue)
        -- Lua does not have strict integer types,
        -- so we just round to the nearest whole number
        local num = this.getKeyValueAsNumber(key, orValue)
        if num >= 0 then num = math.floor(num + 0.5) else num = math.ceil(num - 0.5) end
        return num
    end

    this.getKeyValueAsBool = function(key, orValue)
        -- Get and parse the arg by key
        local val = this.getKeyValue(key, orValue)
        
        if val ~= nil then
            -- Anything else is considered falsey
            return string.lower(val) == 'true'
        end

        return orValue
    end

    this.getKeyValueAsNumber = function(key, orValue)
        -- Get and parse the arg by key
        local val = tonumber(this.getKeyValue(key, orValue))

        if val ~= nil then return val end

        return orValue
    end

    this.printArgs = function()
        local res = ''
        local len <const> = #this.args
        for i = 1, len, 1 do
            res = res..tostring(this.args[i])
            if i < len then
                res = res..', '
            end
        end

        return res
    end

    local mt = {
        __tostring = __tostring
    }

    return setmetatable(this, mt)
end

local ElementParser = {}
ElementParser.new = function()
    local self = {
        delimiter = enums.Delimiters.UNSET,
        element = nil,
        error = nil,
        lineNumber = -1
    }

    local setDelimiterType = function(type)
        if self.delimiter == enums.Delimiters.UNSET then
            self.delimiter = type
            return true
        end

        return self.delimiter == type
    end
    
    local evaluateDelimiter = function(input, start)
        local quoted = false
        local len <const> = #input
        local curr = start

        -- Step 1: skip string literals which are wrapped in matching quotes
        while curr <= len do
            ::continue::
            local quotePos = input:find(string.char(enums.Glyphs.QUOTE), curr, true)
            if quoted then
                if quotePos == nil then
                    self.error = enums.ErrorTypes.UNTERMINATED_QUOTE
                    return len
                end
                quoted = false
                start = quotePos
                curr = start + 1
                goto continue
            end

            local spacePos = input:find(string.char(enums.Glyphs.SPACE), curr, true)
            local commaPos = input:find(string.char(enums.Glyphs.COMMA), curr, true)

            if quotePos == nil then
                quotePos = -1
            end

            if spacePos ~= nil then
                if quotePos > spacePos then
                    quotePos = -1
                end
            else
                spacePos = -1
            end

            if commaPos ~= nil then
                if quotePos > commaPos then
                    quotePos = -1
                end
            else
                commaPos = -1
            end

            if quotePos > -1 then
                quoted = true
                start = quotePos
                curr = start + 1
                goto continue
            elseif spacePos == commaPos then
                -- EOL
                return len
            end

            -- Use the first valid delimiter
            if spacePos == -1 and commaPos > -1 then
                curr = commaPos
            elseif spacePos > -1 and commaPos == -1 then
                curr = spacePos
            elseif spacePos > -1 and commaPos > -1 then
                curr = math.min(spacePos, commaPos)
            end
            break
        end

        -- Step 2: Determine delimiter if not set
        local space = -1
        local equal = -1
        local quote = -1
        while self.delimiter == enums.Delimiters.UNSET and curr <= len do
            local c <const> = input:byte(curr)

            if c == enums.Glyphs.COMMA then
                setDelimiterType(enums.Delimiters.COMMA)
                break
            end

            if c == enums.Glyphs.SPACE and space == -1 then
                space = curr
            end

            if c == enums.Glyphs.EQUAL and equal == -1 and quote == -1 then
                equal = curr
            end

            -- Ensure quotes are toggled, if tokens was reached
            if c == enums.Glyphs.QUOTE then
                if quote == -1 then
                    quote = curr
                else
                    quote = -1
                end
            end

            curr = curr + 1
        end

        -- Case: EOL with no delimiter found
        if self.delimiter == enums.Delimiters.UNSET then
            if space == -1 then return len end

            setDelimiterType(enums.Delimiters.SPACE)
            curr = space
        end

        -- Step 3: use delimiter type to find the next end pos
        -- which will result in the range [start,end] to be the next token
        local idx <const> = input:find(self.delimiter, start, true)
        if idx == nil then
            return len
        end
        
        return math.min(len, idx)
    end

    local evaluateToken = function(input, start, nd)
        -- Sanity check.
        if self.element == nil then
            error('Element was not initialized.')
        end

        local token <const> = trim(input:sub(start, nd))
        --print('token: <'..token..'>, start='..start..', end='..nd..', input='..input)
        local equalPos <const> = token:find(string.char(enums.Glyphs.EQUAL), 1, true)
        if equalPos ~= nil then
            local key <const> = trim(token:sub(1, equalPos-1))
            local val <const> = trim(token:sub(equalPos + 1, #token))
            self.element.upsert(KeyVal.new(key, val))
            return
        end

        self.element.upsert(KeyVal.new(nil, token))
    end
    
    local parseTokenStep = function(input, start)
        local len <const> = #input
        
        -- Find first non-space character
        while start <= len do
            ::continue::
            if input:byte(start) == enums.Glyphs.SPACE then
                start = start + 1
                goto continue
            end

            -- else, current char is non-space
            break
        end

        if start > len then
            return len
        end

        local nd <const> = evaluateDelimiter(input, start)
        evaluateToken(input, start, nd)
        return nd
    end

    -- public 

    self.parseTokens = function(input, start)
        local nd = start
        while nd < #input do
            nd = parseTokenStep(input, nd+1)
            if self.error ~= nil then break end
        end
    end

    return self
end

local read <const> = function(line)
    local parser <const> = ElementParser.new()

    -- Step 1: Trim whitespace and start at the first valid character
    line = trim(line)
    local len <const> = #line

    if len == 0 then
        parser.error = enums.ErrorTypes.EOL_NO_DATA
        return parser
    end

    local pos = 1
    local type = enums.ElementTypes.STANDARD

    while pos <= len do
        ::continue::
 
        local glyph <const> = line:byte(pos)

        -- Find first non-space character
        if glyph == enums.Glyphs.SPACE then
            pos = pos + 1
            goto continue
        end

        -- Potential user-defined element found
        if not enums.glyphIsReserved(glyph) then
            break
        end

        -- Step 2: If the first valid character is a reserved prefix,
        -- then tag the element and continue searching for the name start pos
        if glyph == enums.Glyphs.HASH then
            if type == enums.ElementTypes.STANDARD then
                -- All characters beyond the hash is treated as a comment
                parser.element = Element.new()
                parser.element.text = line:sub(pos+1)
                parser.element.type = enums.ElementTypes.COMMENT
                return parser
            end
        elseif glyph == enums.Glyphs.AT then
            if type ~= enums.ElementTypes.STANDARD then
                parser.error = enums.ErrorTypes.BADTOKEN_AT
                return parser
            end
            type = enums.ElementTypes.ATTRIBUTE
            pos = pos + 1
            goto continue
        elseif glyph == enums.Glyphs.BANG then
            if type ~= enums.ElementTypes.STANDARD then
                parser.error = enums.ElementTypes.BADTOKEN_BANG
                return parser
            end
            type = enums.ElementTypes.GLOBAL
            pos = pos + 1
            goto continue
        end

        -- Terminates
        break
    end

    -- Step 3: find the end of the element name (first space or EOL)
    pos = math.min(pos, len)
    local idx = line:find(string.char(enums.Glyphs.SPACE), pos, true)
    if idx == nil then
        idx = len
    end

    local nd <const> = math.min(len, idx)
    local text <const> = line:sub(pos, nd-1)

    -- EOL
    if #text == 0 then
        local err = enums.ErrorTypes.EOL_MISSING_ELEMENT
        if type == enums.ElementTypes.ATTRIBUTE then
            err = enums.ErrorTypes.EOL_MISSING_ATTRIBUTE
        elseif type == enums.ElementTypes.GLOBAL then
            err = enums.ErrorTypes.EOL_MISSING_GLOBAL
        end

        parser.error = err
        return parser
    end

    parser.element = Element.new()
    parser.element.type = type
    parser.element.text = text

    -- Step 4: parse remaining tokens, if any, and return results
    parser.parseTokens(line, nd)
    return parser
end

return {read=read,Element=Element}