local ezconfig = nil
print('[ezconfig] loading config...')
ezconfig = require('ezlibs-config')
if ezconfig == nil then
    error('[ezconfig] ezlibs requires a ezlibs-config.lua in the root of your server!')
end
return ezconfig