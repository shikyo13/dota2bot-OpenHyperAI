local Utils = require( GetScriptDirectory()..'/FunLib/utils')
local J = require( GetScriptDirectory()..'/FunLib/jmz_func')
local Support = require( GetScriptDirectory()..'/FunLib/aba_support')

local bot = GetBot()
if bot == nil then return end
local botName = bot:GetUnitName()
if bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return end

local local_mode_laning_generic = nil
local nAllyCreeps = nil
local nEnemyCreeps = nil
local nFurthestEnemyAttackRange = 0
local nInRangeEnemy = nil
local botAssignedLane = nil
local botAttackRange = bot:GetAttackRange()
local attackDamage = bot:GetAttackDamage()

if Utils.BuggyHeroesDueToValveTooLazy[botName] then local_mode_laning_generic = dofile( GetScriptDirectory().."/FunLib/override_generic/mode_laning_generic" ) end

function GetDesire()
	local ok, result = xpcall(function()
		if bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return BOT_MODE_DESIRE_NONE end

		-- Ensure comms chat callback is installed (processes !ward, !push, etc.)
		if J.Comms ~= nil then J.Comms.Think() end

		-- Periodic status dump
		if J.Log ~= nil then J.Log.StatusDump() end

		-- Track mode transitions for decision tracing
		if J.Log ~= nil then J.Log.TraceTransition(bot) end

		local botLV = bot:GetLevel()
		local currentTime = DotaTime()

		botAttackRange = bot:GetAttackRange()
		nAllyCreeps = bot:GetNearbyLaneCreeps(1200, false)
		nEnemyCreeps = bot:GetNearbyLaneCreeps(1200, true)
		nInRangeEnemy = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE)
		nFurthestEnemyAttackRange = GetFurthestEnemyAttackRange(nInRangeEnemy)
		if local_mode_laning_generic then
			botAssignedLane = local_mode_laning_generic.GetBotTargetLane()
		else
			botAssignedLane = bot:GetAssignedLane()
		end
		attackDamage = bot:GetAttackDamage()
		if bot:GetItemSlotType(bot:FindItemSlot("item_quelling_blade")) == ITEM_SLOT_TYPE_MAIN then
			if bot:GetAttackRange() > 310 or bot:GetUnitName() == "npc_dota_hero_templar_assassin" then
				attackDamage = attackDamage + 4
			else
				attackDamage = attackDamage + 8
			end
		end

		if GetGameMode() == 23 then currentTime = currentTime * 1.65 end
		if currentTime < 0 then return BOT_MODE_DESIRE_NONE end

		if J.GetEnemiesAroundAncient(bot, 3200) > 0 then
			return BOT_MODE_DESIRE_NONE
		end

		if bot:WasRecentlyDamagedByAnyHero(5)
		and #J.Utils.GetLastSeenEnemyIdsNearLocation(bot:GetLocation(), 800) > 0 then
			local nLaneFrontLocation = GetLaneFrontLocation(GetTeam(), bot:GetAssignedLane(), 0)
			local nDistFromLane = GetUnitToLocationDistance(bot, nLaneFrontLocation)
			if not J.WeAreStronger(bot, 1200) or (nDistFromLane > 700 and J.GetHP(bot) < 0.7) then
				return BOT_MODE_DESIRE_NONE
			end
		end

		if J.Utils.IsTeamPushingSecondTierOrHighGround(bot) then
			return BOT_MODE_DESIRE_NONE
		end

		if local_mode_laning_generic or (J.GetPosition(bot) == 1 and J.IsPosxHuman(5)) then
			if J.IsInLaningPhase() then
				local hitCreep, _ = GetBestLastHitCreep(nEnemyCreeps)
				if J.IsValid(hitCreep) then
					if J.GetPosition(bot) <= 3 or not J.IsThereNonSelfCoreNearby(700)
					then
						return 0.9
					end
				end
			end
		end
		if local_mode_laning_generic and local_mode_laning_generic.GetDesire ~= nil then return local_mode_laning_generic.GetDesire() end

		if GetGameMode() == GAMEMODE_1V1MID or GetGameMode() == GAMEMODE_MO then
			return 1
		end

		local desireResult
		if currentTime <= 10 then desireResult = 0.268
		elseif currentTime <= 9 * 60 and botLV <= 7 then desireResult = 0.446
		elseif currentTime <= 12 * 60 and botLV <= 11 then desireResult = 0.369
		elseif botLV <= 14 and J.GetCoresAverageNetworth() < 7000 then desireResult = 0.2
		else
			J.Utils.GameStates.passiveLaningTime = true
			if #nEnemyCreeps > 0 then desireResult = 0.25
			else desireResult = 0.05
			end
		end

		-- Trace laning desire
		if J.Log ~= nil then
			J.Log.Trace("LANING", bot, "desire=" .. string.format("%.2f", desireResult) .. " ecreep=" .. tostring(#nEnemyCreeps) .. " acreep=" .. tostring(#nAllyCreeps))
		end

		return desireResult
	end, function(err)
		if J and J.Log then
			J.Log.Error("MODE", "laning GetDesire: " .. tostring(err) .. "\n" .. (debug.traceback and debug.traceback() or ""))
		elseif J and J.Log and J.Log._realPrint then
			J.Log._realPrint("[ERROR][MODE] laning GetDesire: " .. tostring(err))
		end
	end)
	if not ok then return 0 end
	return result or 0
end

function GetFurthestEnemyAttackRange(enemyList)
	local attackRange = 0
	for _, enemy in pairs(enemyList) do
		if J.IsValidHero(enemy) and not J.IsSuspiciousIllusion(enemy) then
			local enemyAttackRange = enemy:GetAttackRange()
			if enemyAttackRange > attackRange then
				attackRange = enemyAttackRange
			end
		end
	end

	return attackRange
end

function GetBestLastHitCreep(hCreepList)
	local dmgDelta = attackDamage * 0.7

	local moveToCreep = nil
	for _, creep in pairs(hCreepList) do
		if J.IsValid(creep) and J.CanBeAttacked(creep) then
			local nDelay = J.GetAttackProDelayTime(bot, creep)
			if J.WillKillTarget(creep, attackDamage, DAMAGE_TYPE_PHYSICAL, nDelay) then
				return creep, false
			end
			if J.WillKillTarget(creep, attackDamage + dmgDelta, DAMAGE_TYPE_PHYSICAL, nDelay) then
				moveToCreep = creep
			end
		end
	end
	if moveToCreep then
		return moveToCreep, true
	end

	return nil
end

function GetBestDenyCreep(hCreepList)
	for _, creep in pairs(hCreepList)
	do
		if J.IsValid(creep)
		and J.GetHP(creep) < 0.49
		and J.CanBeAttacked(creep)
		and creep:GetHealth() <= attackDamage
		then
			return creep
		end
	end

	return nil
end

--------------------------------------------------------------------
-- Support pull/stack helper (called from Think for supports)
--------------------------------------------------------------------
local function TrySupportTasks(bot)
	if J.GetPosition(bot) < 4 then return false end
	if not J.IsInLaningPhase() then return false end

	local desire = Support.GetDesireValue(bot)
	if desire >= 0.5 then
		local executed = Support.Think(bot)
		if executed then return true end
		-- Support.Think decided not to act (e.g. not pull timing), fall through to laning
	end
	return false
end

--------------------------------------------------------------------
-- Support harass + creep equilibrium helper
--------------------------------------------------------------------
local lastHarassTime = 0  -- track when we last harassed for de-aggro

local function TryDeaggro(bot)
	-- If bot recently harassed and creeps are targeting us, attack ally creep to drop aggro
	if DotaTime() - lastHarassTime < 2.0 and bot:WasRecentlyDamagedByCreeps(1.5) then
		local allyCreeps2 = bot:GetNearbyCreeps(500, false)
		if allyCreeps2 ~= nil and #allyCreeps2 > 0 then
			bot:Action_AttackUnit(allyCreeps2[1], true)
			return true
		end
	end
	return false
end

local function TrySupportLaneActions(bot)
	if J.GetPosition(bot) < 4 then return false end
	if not J.IsInLaningPhase() then return false end

	-- De-aggro takes priority (drop creep aggro after a recent harass)
	if TryDeaggro(bot) then return true end

	-- Support harass: score-based target selection
	local botHP = bot:GetHealth() / bot:GetMaxHealth()
	if botHP < 0.5 then
		-- Too low to harass, skip to equilibrium logic below
	else
		local nearbyEnemies = bot:GetNearbyHeroes(botAttackRange + 100, true, BOT_MODE_NONE)
		if nearbyEnemies ~= nil and #nearbyEnemies > 0 then
			-- Don't harass if too many enemy creeps nearby (we'll draw heavy aggro)
			local enemyCreeps2 = bot:GetNearbyCreeps(500, true)
			if enemyCreeps2 == nil or #enemyCreeps2 < 4 then
				-- Find safest enemy to harass using scoring
				local target = nil
				local bestScore = -1
				for _, enemy in pairs(nearbyEnemies) do
					if J.IsValidHero(enemy) and not enemy:IsInvulnerable()
					and J.CanBeAttacked(enemy) and enemy:IsAlive() then
						local dist = GetUnitToUnitDistance(bot, enemy)
						local enemyHP = enemy:GetHealth() / enemy:GetMaxHealth()
						-- Score: prefer close, low-HP enemies
						local score = (1 - dist / 1000) + (1 - enemyHP) * 0.5
						-- Penalty: enemy can burst us down
						if enemy:GetEstimatedDamageToTarget(false, bot, 3.0, DAMAGE_TYPE_ALL) > bot:GetHealth() * 0.3 then
							score = score - 0.5
						end
						if score > bestScore then
							bestScore = score
							target = enemy
						end
					end
				end

				if target ~= nil and bestScore > 0.2 then
					if J.Log ~= nil and J.Log.IsEnabled("LANING", 4) then
						J.Log.Debug("LANING", string.gsub(botName, "npc_dota_hero_", "") .. " harassing " .. string.gsub(target:GetUnitName(), "npc_dota_hero_", "") .. " (score=" .. string.format("%.2f", bestScore) .. ")")
					end
					bot:Action_AttackUnit(target, true)
					lastHarassTime = DotaTime()
					return true
				end
			end
		end
	end

	-- Creep equilibrium: if lane is pushed, supports only deny
	local laneFrontAmt = GetLaneFrontAmount(GetTeam(), botAssignedLane, false)
	if laneFrontAmt > 0.55 then
		local denyCreep2 = GetBestDenyCreep(nAllyCreeps)
		if J.IsValid(denyCreep2) then
			bot:SetTarget(denyCreep2)
			bot:Action_AttackUnit(denyCreep2, true)
			return true
		end
		local holdPos = GetLaneFrontLocation(GetTeam(), botAssignedLane, -300)
		bot:Action_MoveToLocation(holdPos + RandomVector(30))
		return true
	end

	return false
end

if local_mode_laning_generic or (J.GetPosition(bot) == 1 and J.IsPosxHuman(5)) then
	function Think()
		local ok, _ = xpcall(function()
			-- Support pull/stack takes priority during laning
			if TrySupportTasks(bot) then
				if J.Log ~= nil then J.Log.Trace("LANING", bot, "think action=support_task") end
				return
			end

			local hitCreep, moveToCreep = GetBestLastHitCreep(nEnemyCreeps)
			if J.IsValid(hitCreep) then
				if J.GetPosition(bot) <= 3 or not J.IsThereNonSelfCoreNearby(700)
				then
					if GetUnitToUnitDistance(bot, hitCreep) > botAttackRange
					or (moveToCreep and GetUnitToUnitDistance(bot, hitCreep) > botAttackRange * 0.8) then
						bot:Action_MoveToUnit(hitCreep)
						if J.Log ~= nil then J.Log.Trace("LANING", bot, "think action=move_to_lasthit") end
						return
					else
						bot:SetTarget(hitCreep)
						bot:Action_AttackUnit(hitCreep, true)
						if J.Log ~= nil then J.Log.Trace("LANING", bot, "think action=lasthit") end
						return
					end
				end
			end

			local denyCreep = GetBestDenyCreep(nAllyCreeps)
			if J.IsValid(denyCreep) then
				bot:SetTarget(denyCreep)
				bot:Action_AttackUnit(denyCreep, true)
				if J.Log ~= nil then J.Log.Trace("LANING", bot, "think action=deny") end
				return
			end

			-- Support harass + equilibrium
			if TrySupportLaneActions(bot) then
				if J.Log ~= nil then J.Log.Trace("LANING", bot, "think action=support_lane") end
				return
			end

			if local_mode_laning_generic then
				local_mode_laning_generic.Think()
			end

			local fLaneFrontAmount = GetLaneFrontAmount(GetTeam(), botAssignedLane, false)
			local fLaneFrontAmount_enemy = GetLaneFrontAmount(GetOpposingTeam(), botAssignedLane, false)

			local nLongestAttackRange = math.max(botAttackRange, 250, nFurthestEnemyAttackRange)

			local target_loc = GetLaneFrontLocation(GetTeam(), botAssignedLane, -nLongestAttackRange)
			if fLaneFrontAmount_enemy < fLaneFrontAmount then
				target_loc = GetLaneFrontLocation(GetOpposingTeam(), botAssignedLane, -nLongestAttackRange)
			end

			bot:Action_MoveToLocation(target_loc + RandomVector(50))
		end, function(err)
			if J and J.Log then
				J.Log.Error("MODE", "laning Think(override): " .. tostring(err) .. "\n" .. (debug.traceback and debug.traceback() or ""))
			end
		end)
	end
else
	-- Fallback Think for non-override heroes (includes most supports)
	function Think()
		local ok, _ = xpcall(function()
			-- Support pull/stack takes priority during laning
			if TrySupportTasks(bot) then
				if J.Log ~= nil then J.Log.Trace("LANING", bot, "think action=support_task") end
				return
			end

			-- Deny creeps
			local denyCreep = GetBestDenyCreep(nAllyCreeps)
			if J.IsValid(denyCreep) then
				bot:SetTarget(denyCreep)
				bot:Action_AttackUnit(denyCreep, true)
				if J.Log ~= nil then J.Log.Trace("LANING", bot, "think action=deny") end
				return
			end

			-- Last-hit when no allied core is nearby (don't waste free CS)
			local nearbyAllies = bot:GetNearbyHeroes(1200, false, BOT_MODE_NONE)
			local coreNearby = false
			if nearbyAllies ~= nil then
				for _, ally in pairs(nearbyAllies) do
					if ally ~= bot and J.IsValid(ally) and J.GetPosition(ally) <= 3 then
						coreNearby = true
						break
					end
				end
			end
			if not coreNearby then
				local hitCreep, _ = GetBestLastHitCreep(nEnemyCreeps)
				if J.IsValid(hitCreep) then
					bot:Action_AttackUnit(hitCreep, true)
					if J.Log ~= nil then J.Log.Trace("LANING", bot, "think action=lasthit_no_core") end
					return
				end
			end

			-- Support harass + equilibrium
			if TrySupportLaneActions(bot) then
				if J.Log ~= nil then J.Log.Trace("LANING", bot, "think action=support_lane") end
				return
			end

			-- Default: move toward lane front
			local fLaneFrontAmount = GetLaneFrontAmount(GetTeam(), botAssignedLane, false)
			local fLaneFrontAmount_enemy = GetLaneFrontAmount(GetOpposingTeam(), botAssignedLane, false)

			local nLongestAttackRange = math.max(botAttackRange, 250, nFurthestEnemyAttackRange)

			local target_loc = GetLaneFrontLocation(GetTeam(), botAssignedLane, -nLongestAttackRange)
			if fLaneFrontAmount_enemy < fLaneFrontAmount then
				target_loc = GetLaneFrontLocation(GetOpposingTeam(), botAssignedLane, -nLongestAttackRange)
			end

			bot:Action_MoveToLocation(target_loc + RandomVector(50))
		end, function(err)
			if J and J.Log then
				J.Log.Error("MODE", "laning Think(fallback): " .. tostring(err) .. "\n" .. (debug.traceback and debug.traceback() or ""))
			end
		end)
	end
end
