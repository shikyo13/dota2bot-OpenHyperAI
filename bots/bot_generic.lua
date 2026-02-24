local bot = GetBot()
if bot == nil then return end
local botName = bot:GetUnitName()
if bot:IsInvulnerable() or not bot:IsHero() or not string.find(botName, "hero") or bot:IsIllusion() then return end

local Utils = require( GetScriptDirectory()..'/FunLib/utils' )

local ok_build, BotBuild = pcall(dofile, GetScriptDirectory() .. "/BotLib/" .. string.gsub(botName, "npc_dota_", ""))
if not ok_build then
	local ok_log, Log = pcall(require, GetScriptDirectory()..'/FunLib/aba_log')
	if ok_log and Log then
		Log.Error("INIT", 'FAILED to load hero config for ' .. botName .. ': ' .. tostring(BotBuild))
	else
		print('[ERROR][INIT] FAILED to load hero config for ' .. botName .. ': ' .. tostring(BotBuild))
	end
	BotBuild = nil
end

if BotBuild == nil
then
	local ok_log, Log = pcall(require, GetScriptDirectory()..'/FunLib/aba_log')
	if ok_log and Log then
		Log.Error("GENERAL", 'No build config file found for bot: '..botName)
	else
		print('[ERROR][GENERAL] No build config file found for bot: '..botName)
	end
	return
end

function MinionThink(hMinionUnit)
	if not Utils.IsValidUnit(hMinionUnit) then return end
	if hMinionUnit.lastMinionFrameProcessTime == nil then hMinionUnit.lastMinionFrameProcessTime = DotaTime() end
	if DotaTime() - hMinionUnit.lastMinionFrameProcessTime < 0.3 then return end
	hMinionUnit.lastMinionFrameProcessTime = DotaTime()

	BotBuild.MinionThink(hMinionUnit)
end
