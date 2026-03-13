local Delimiters <const> = {
    UNSET = '',
    COMMA = ',',
    SPACE = ' '
}

local ElementTypes <const> = {
    STANDARD = 'standard',
    GLOBAL = 'global',
    COMMENT = 'comment',
    ATTRIBUTE = 'attribute'
}

local Glyphs <const> = {
    NONE = string.byte(''),
    EQUAL = string.byte('='),
    AT = string.byte('@'),
    BANG = string.byte('!'),
    HASH = string.byte('#'),
    SPACE = string.byte(' '),
    COMMA = string.byte(','),
    QUOTE = string.byte('"')
}

local glyphForType = function(type)
    if type == ElementTypes.GLOBAL then
        return Glyphs.BANG
    end
    if type == ElementTypes.ATTRIBUTE then
        return Glyphs.AT
    end
    if type == ElementTypes.COMMENT then
        return Glyphs.HASH
    end

    -- unknown or standard element
    return Glyphs.NONE
end

local glyphIsReserved = function(glyph) 
    for _,v in pairs(Glyphs) do
        if glyph == v then
            return true
        end
    end

    return false
end

local ErrorTypes <const> = {
    BADTOKEN_AT = 'Element using attribute prefix out-of-place.',
    BADTOKEN_BANG = 'Element using global prefix out-of-place.',
    EOL_NO_DATA = 'Nothing to parse (EOL).',
    EOL_MISSING_ELEMENT = 'Missing element identifier (EOL).',
    EOL_MISSING_ATTRIBUTE = 'Missing attribute identifier (EOL).',
    EOL_MISSING_GLOBAL = 'Missing global identifier (EOL).',
    UNTERMINATED_QUOTE = 'Missing end quote in expression.',
    RUNTIME = 'Unexpected runtime error.' -- Reserved for misc. parsing issues
}

return {
    Delimiters = Delimiters,
    ElementTypes = ElementTypes,
    Glyphs = Glyphs,
    glyphForType = glyphForType,
    glyphIsReserved = glyphIsReserved,
    ErrorTypes = ErrorTypes
}