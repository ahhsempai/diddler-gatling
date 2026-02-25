local s,u=game:HttpGet("https://raw.githubusercontent.com/ahhsempai/diddler-gatling/main/diddler.lua")
local f=loadstring(s)
if type(f)\~="function" then
    -- Hercules fix: force eval
    f=loadstring(s:gsub("return%s*(%b())","return %1()")) or error("Hercules broke loadstring")
end
return f()
