local bot = GetBot()
local botName = bot:GetUnitName()
if bot == nil or bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return end

local J = require( GetScriptDirectory()..'/FunLib/jmz_func' )

local bHumanAlly = nil
local lastDesireTime = -90

local function HasHumanAlly()
	if bHumanAlly ~= nil then return bHumanAlly end
	local teamPlayerIDList = GetTeamPlayers( GetTeam() )
	for i = 1, #teamPlayerIDList do
		if not IsPlayerBot( teamPlayerIDList[i] ) then
			bHumanAlly = true
			return true
		end
	end
	bHumanAlly = false
	return false
end

local function GetClosestHumanAlly()
	if not HasHumanAlly() then return nil end
	local closestDist = 99999
	local closestHuman = nil
	local allyList = GetUnitList( UNIT_LIST_ALLIED_HEROES )
	for _, ally in pairs( allyList ) do
		if J.IsValidHero( ally ) and not ally:IsBot() and not ally:IsIllusion() then
			local dist = GetUnitToUnitDistance( bot, ally )
			if dist < closestDist then
				closestDist = dist
				closestHuman = ally
			end
		end
	end
	return closestHuman, closestDist
end

function GetDesire()
	if not HasHumanAlly() then return BOT_MODE_DESIRE_NONE end
	if not bot:IsAlive() then return BOT_MODE_DESIRE_NONE end
	if DotaTime() < 0 then return BOT_MODE_DESIRE_NONE end
	if DotaTime() < lastDesireTime + 0.5 then return BOT_MODE_DESIRE_NONE end
	lastDesireTime = DotaTime()

	-- Comms: !help command — come to human's location
	if J.Comms ~= nil then
		local cmd = J.Comms.GetCurrentCommand()
		if cmd ~= nil and cmd.type == "help" and J.Comms.IsCommandFresh(15) then
			local humanAlly = GetClosestHumanAlly()
			if humanAlly ~= nil then
				local dist = GetUnitToUnitDistance(bot, humanAlly)
				J.Comms.LogVerbose(bot:GetUnitName() .. " assemble desire (help cmd, dist=" .. string.format("%.0f", dist) .. ")")
				return RemapValClamped(dist, 500, 5000, BOT_MODE_DESIRE_VERYHIGH, BOT_MODE_DESIRE_MODERATE)
			end
		end
	end

	local humanAlly, humanDist = GetClosestHumanAlly()
	if humanAlly == nil then return BOT_MODE_DESIRE_NONE end

	-- Detect nearby teamfight involving the human
	local teamfightLoc = J.GetTeamFightLocation( bot )
	if teamfightLoc ~= nil then
		local humanDistToFight = GetUnitToLocationDistance( humanAlly, teamfightLoc )
		local botDistToFight = GetUnitToLocationDistance( bot, teamfightLoc )
		if humanDistToFight < 2500 and botDistToFight < 4000 then
			return RemapValClamped( botDistToFight, 500, 4000, BOT_MODE_DESIRE_VERYHIGH, BOT_MODE_DESIRE_MODERATE )
		end
	end

	-- If human ally is fighting (recently damaged or attacking a hero), group up
	if humanDist < 3000
		and ( humanAlly:WasRecentlyDamagedByAnyHero( 3.0 )
			or ( humanAlly:GetAttackTarget() ~= nil and humanAlly:GetAttackTarget():IsHero() ) )
	then
		return RemapValClamped( humanDist, 500, 3000, BOT_MODE_DESIRE_HIGH, BOT_MODE_DESIRE_LOW )
	end

	-- If human is pushing with the bot nearby, loosely group
	if humanDist < 2000 then
		local enemyNearHuman = J.GetEnemiesNearLoc( humanAlly:GetLocation(), 1600 )
		if #enemyNearHuman >= 2 then
			return BOT_MODE_DESIRE_MODERATE
		end
	end

	return BOT_MODE_DESIRE_NONE
end

function Think()
	if J.CanNotUseAction( bot ) then return end

	local humanAlly = GetClosestHumanAlly()
	if humanAlly == nil then return end

	-- Move toward the human ally
	local targetLoc = humanAlly:GetLocation()
	local dist = GetUnitToUnitDistance( bot, humanAlly )

	if dist > 500 then
		bot:Action_MoveToLocation( targetLoc )
	end
end
