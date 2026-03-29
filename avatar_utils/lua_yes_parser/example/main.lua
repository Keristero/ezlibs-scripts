package.path = "../?.lua;" .. package.path
local yes <const> = require('lib')
local elements, errors = yes.parse('doc.cut')

-- print all elements
print('Number of parsed elements: '..#elements)
for i in ipairs(elements) do
    local v <const> = elements[i]
    if v.type == yes.enums.ElementTypes.COMMENT then
        goto continue
    end
    print(v.text)
    for j in ipairs(v.args) do
        print('args['..j..']: key=<'..tostring(v.args[j].key)..'>, val=<'..tostring(v.args[j].val)..'>')
    end
    ::continue::
end

-- print errors with line numbers, if any
for i in ipairs(errors) do
    -- do not report empty lines
    local e <const> = errors[i]
    if e.type ~= yes.enums.ErrorTypes.EOL_NO_DATA then
        print('[Line '..e.line..'] Error: '..e.type)
    end
end
