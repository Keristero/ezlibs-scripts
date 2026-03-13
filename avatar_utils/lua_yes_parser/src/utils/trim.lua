local function trim (str)
    if str == '' then
      return str
    else
      local startPos = 1
      local endPos   = #str
  
      while (startPos <= endPos and str:byte(startPos) <= 32) do
        startPos = startPos + 1
      end
  
      if startPos > endPos then
        return ''
      else
        while (endPos > startPos and str:byte(endPos) <= 32) do
          endPos = endPos - 1
        end
  
        return str:sub(startPos, endPos)
      end
    end
  end

  return trim