local X = {}
local bot = GetBot()

local J = require( GetScriptDirectory()..'/FunLib/jmz_func' )
local Minion = dofile( GetScriptDirectory()..'/FunLib/aba_minion' )
local sTalentList = J.Skill.GetTalentList( bot )
local sAbilityList = J.Skill.GetAbilityList( bot )
local sRole = J.Item.GetRoleItemsBuyList( bot )

local tTalentTreeList = {
						['t25'] = {0, 10},
						['t20'] = {10, 0},
						['t15'] = {0, 10},
						['t10'] = {10, 0},
}

local tAllAbilityBuildList = {
						{1,3,1,2,1,6,1,3,3,3,6,2,2,2,6},--pos4: Q max, E, W, R
						{3,1,3,2,3,6,3,1,1,1,6,2,2,2,6},--pos5: E max, Q, W, R
}

local nAbilityBuildList = J.Skill.GetRandomBuild( tAllAbilityBuildList )

local nTalentBuildList = J.Skill.GetTalentBuild( tTalentTreeList )

local sRoleItemsBuyList = {}

sRoleItemsBuyList['pos_1'] = sRoleItemsBuyList['pos_1'] or {
	"item_tank_outfit",
	"item_echo_sabre",
	"item_black_king_bar",
	"item_aghanims_shard",
	"item_assault",
	"item_heart",
	"item_ultimate_scepter",
	"item_travel_boots",
	"item_moon_shard",
	"item_ultimate_scepter_2",
}

sRoleItemsBuyList['pos_2'] = sRoleItemsBuyList['pos_1']

sRoleItemsBuyList['pos_3'] = {
	"item_tank_outfit",
	"item_echo_sabre",
	"item_pipe",
	"item_aghanims_shard",
	"item_crimson_guard",
	"item_ultimate_scepter",
	"item_assault",
	"item_travel_boots",
	"item_heart",
	"item_moon_shard",
	"item_ultimate_scepter_2",
}

sRoleItemsBuyList['pos_4'] = {
	"item_tank_outfit",
	"item_ancient_janggo",
	"item_pipe",
	"item_aghanims_shard",
	"item_force_staff",
	"item_ultimate_scepter",
	"item_boots_of_bearing",
	"item_travel_boots",
	"item_octarine_core",
	"item_moon_shard",
	"item_ultimate_scepter_2",
}

sRoleItemsBuyList['pos_5'] = {
	'item_mage_outfit',
	"item_ancient_janggo",
	"item_glimmer_cape",
	"item_aghanims_shard",
	"item_force_staff",
	"item_boots_of_bearing",
	"item_pipe",
	"item_ultimate_scepter",
	"item_octarine_core",
	"item_moon_shard",
	"item_ultimate_scepter_2",
}


X['sBuyList'] = sRoleItemsBuyList[sRole]


X['sSellList'] = {
	"item_ultimate_scepter",
	"item_magic_wand",

	"item_ancient_janggo",
	"item_magic_wand",
}


if J.Role.IsPvNMode() or J.Role.IsAllShadow() then X['sBuyList'], X['sSellList'] = { 'PvN_tank' }, {} end

nAbilityBuildList, nTalentBuildList, X['sBuyList'], X['sSellList'] = J.SetUserHeroInit( nAbilityBuildList, nTalentBuildList, X['sBuyList'], X['sSellList'] )

X['sSkillList'] = J.Skill.GetSkillList( sAbilityList, nAbilityBuildList, sTalentList, nTalentBuildList )

X['bDeafaultAbility'] = false
X['bDeafaultItem'] = true

function X.MinionThink(hMinionUnit)
	if Minion.IsValidUnit( hMinionUnit )
	then
		if J.IsValidHero(hMinionUnit) and hMinionUnit:IsIllusion()
		then
			Minion.IllusionThink( hMinionUnit )
		end
	end
end

local CatchyLick      = bot:GetAbilityByName( 'largo_catchy_lick' )
local Frogstomp        = bot:GetAbilityByName( 'largo_frogstomp' )
local CroakOfGenius    = bot:GetAbilityByName( 'largo_croak_of_genius' )

local CatchyLickDesire, CatchyLickTarget
local FrogstompDesire, FrogstompLocation
local CroakOfGeniusDesire, CroakOfGeniusTarget

function X.SkillsComplement()
	if J.CanNotUseAbility(bot) then return end

	CatchyLickDesire, CatchyLickTarget = X.ConsiderCatchyLick()
	if CatchyLickDesire > 0
	then
		bot:Action_UseAbilityOnEntity(CatchyLick, CatchyLickTarget)
		return
	end

	FrogstompDesire, FrogstompLocation = X.ConsiderFrogstomp()
	if FrogstompDesire > 0
	then
		bot:Action_UseAbilityOnLocation(Frogstomp, FrogstompLocation)
		return
	end

	CroakOfGeniusDesire, CroakOfGeniusTarget = X.ConsiderCroakOfGenius()
	if CroakOfGeniusDesire > 0
	then
		bot:Action_UseAbilityOnEntity(CroakOfGenius, CroakOfGeniusTarget)
		return
	end
end


function X.ConsiderCatchyLick()
	if not CatchyLick:IsFullyCastable()
	then
		return BOT_ACTION_DESIRE_NONE, nil
	end

	local nCastRange = CatchyLick:GetCastRange()
	local nDamage = CatchyLick:GetSpecialValueInt('damage')
	local nDamageType = DAMAGE_TYPE_MAGICAL
	local botTarget = J.GetProperTarget(bot)

	local nEnemyHeroes = J.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE)
	local nAllyHeroes = J.GetNearbyHeroes(bot, nCastRange, false, BOT_MODE_NONE)

	-- Save ally: pull retreating ally to safety
	for _, allyHero in pairs(nAllyHeroes)
	do
		if J.IsValidHero(allyHero)
		and J.IsNotSelf(bot, allyHero)
		and not allyHero:IsIllusion()
		and not allyHero:IsInvulnerable()
		and J.IsRetreating(allyHero)
		and J.GetHP(allyHero) < 0.35
		and allyHero:WasRecentlyDamagedByAnyHero(2.0)
		then
			return BOT_ACTION_DESIRE_HIGH, allyHero
		end
	end

	-- Dispel ally: pull ally out of disables
	for _, allyHero in pairs(nAllyHeroes)
	do
		if J.IsValidHero(allyHero)
		and J.IsNotSelf(bot, allyHero)
		and not allyHero:IsIllusion()
		and not allyHero:IsInvulnerable()
		and J.IsDisabled(allyHero)
		then
			return BOT_ACTION_DESIRE_HIGH, allyHero
		end
	end

	-- Kill target
	for _, enemyHero in pairs(nEnemyHeroes)
	do
		if J.IsValidHero(enemyHero)
		and J.CanCastOnNonMagicImmune(enemyHero)
		and not J.IsSuspiciousIllusion(enemyHero)
		and J.CanKillTarget(enemyHero, nDamage, nDamageType)
		then
			return BOT_ACTION_DESIRE_HIGH, enemyHero
		end
	end

	-- Going on someone
	if J.IsGoingOnSomeone(bot)
	then
		if J.IsValidHero(botTarget)
		and J.CanCastOnNonMagicImmune(botTarget)
		and not J.IsSuspiciousIllusion(botTarget)
		and J.IsInRange(bot, botTarget, nCastRange)
		then
			return BOT_ACTION_DESIRE_HIGH, botTarget
		end
	end

	-- Retreating: pull enemy chasing us
	if J.IsRetreating(bot)
	then
		if nEnemyHeroes ~= nil and #nEnemyHeroes >= 1
		and J.IsValidHero(nEnemyHeroes[1])
		and J.CanCastOnNonMagicImmune(nEnemyHeroes[1])
		and J.IsInRange(bot, nEnemyHeroes[1], nCastRange)
		and nEnemyHeroes[1]:IsFacingLocation(bot:GetLocation(), 30)
		and not J.IsSuspiciousIllusion(nEnemyHeroes[1])
		then
			return BOT_ACTION_DESIRE_HIGH, nEnemyHeroes[1]
		end
	end

	-- Roshan
	if J.IsDoingRoshan(bot)
	then
		if J.IsRoshan(botTarget)
		and J.CanCastOnNonMagicImmune(botTarget)
		and J.IsInRange(bot, botTarget, nCastRange)
		and J.IsAttacking(bot)
		then
			return BOT_ACTION_DESIRE_HIGH, botTarget
		end
	end

	return BOT_ACTION_DESIRE_NONE, nil
end


function X.ConsiderFrogstomp()
	if not Frogstomp:IsFullyCastable()
	then
		return BOT_ACTION_DESIRE_NONE, nil
	end

	local nCastRange = Frogstomp:GetCastRange()
	local nRadius = Frogstomp:GetSpecialValueInt('radius')
	local botTarget = J.GetProperTarget(bot)
	local nEnemyHeroes = J.GetNearbyHeroes(bot, nCastRange + nRadius, true, BOT_MODE_NONE)

	-- Teamfight: AoE where enemies cluster
	if nEnemyHeroes ~= nil and #nEnemyHeroes >= 2
	then
		local bestLoc = J.GetCenterOfUnits(nEnemyHeroes)
		if bestLoc ~= nil
		and GetUnitToLocationDistance(bot, bestLoc) <= nCastRange
		then
			return BOT_ACTION_DESIRE_HIGH, bestLoc
		end
	end

	-- Going on someone
	if J.IsGoingOnSomeone(bot)
	then
		if J.IsValidHero(botTarget)
		and J.CanCastOnNonMagicImmune(botTarget)
		and J.IsInRange(bot, botTarget, nCastRange)
		and not J.IsSuspiciousIllusion(botTarget)
		then
			return BOT_ACTION_DESIRE_HIGH, botTarget:GetLocation()
		end
	end

	-- Farming
	if J.IsLaning(bot) or J.IsFarming(bot)
	then
		local nCreeps = bot:GetNearbyCreeps(nCastRange, true)
		if nCreeps ~= nil and #nCreeps >= 3
		then
			local bestLoc = J.GetCenterOfUnits(nCreeps)
			if bestLoc ~= nil
			and GetUnitToLocationDistance(bot, bestLoc) <= nCastRange
			then
				return BOT_ACTION_DESIRE_MODERATE, bestLoc
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE, nil
end


function X.ConsiderCroakOfGenius()
	if not CroakOfGenius:IsFullyCastable()
	then
		return BOT_ACTION_DESIRE_NONE, nil
	end

	local nCastRange = CroakOfGenius:GetCastRange()
	local nAllyHeroes = J.GetNearbyHeroes(bot, nCastRange, false, BOT_MODE_NONE)

	-- Buff the strongest nearby core ally going on someone
	for _, allyHero in pairs(nAllyHeroes)
	do
		if J.IsValidHero(allyHero)
		and not allyHero:IsIllusion()
		and not allyHero:IsInvulnerable()
		and not allyHero:HasModifier('modifier_largo_croak_of_genius')
		and J.IsGoingOnSomeone(allyHero)
		and J.IsCore(allyHero)
		then
			return BOT_ACTION_DESIRE_HIGH, allyHero
		end
	end

	-- Buff core ally in teamfight
	local nEnemyHeroes = J.GetNearbyHeroes(bot, 1200, true, BOT_MODE_NONE)
	if nEnemyHeroes ~= nil and #nEnemyHeroes >= 2
	then
		for _, allyHero in pairs(nAllyHeroes)
		do
			if J.IsValidHero(allyHero)
			and not allyHero:IsIllusion()
			and not allyHero:IsInvulnerable()
			and not allyHero:HasModifier('modifier_largo_croak_of_genius')
			and J.IsCore(allyHero)
			then
				return BOT_ACTION_DESIRE_HIGH, allyHero
			end
		end
	end

	-- During push/roshan, buff strongest nearby
	if J.IsDoingRoshan(bot) or J.IsPushing(bot)
	then
		for _, allyHero in pairs(nAllyHeroes)
		do
			if J.IsValidHero(allyHero)
			and not allyHero:IsIllusion()
			and not allyHero:HasModifier('modifier_largo_croak_of_genius')
			and J.IsCore(allyHero)
			then
				return BOT_ACTION_DESIRE_MODERATE, allyHero
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE, nil
end

return X
