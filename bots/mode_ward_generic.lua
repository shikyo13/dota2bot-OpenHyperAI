if GetBot():IsInvulnerable() or not GetBot():IsHero() or not string.find(GetBot():GetUnitName(), "hero") or  GetBot():IsIllusion() then
	return
end

local X = {}

local bot = GetBot()
local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local W = require(GetScriptDirectory() ..'/FunLib/aba_ward_utility')
local Customize = require(GetScriptDirectory()..'/Customize/general')
Customize.ThinkLess = Customize.Enable and Customize.ThinkLess or 1

local Deward = nil
local bDewardLoaded = false
local function EnsureDeward()
	if not bDewardLoaded then
		local ok, mod = pcall(require, GetScriptDirectory()..'/FunLib/aba_deward')
		if ok and mod then Deward = mod end
		bDewardLoaded = true
	end
	return Deward ~= nil
end

local nObserverWardCastRange = 500
local nSentryWardCastRange = 500

local ObserverWard = nil
local SentryWard = nil

local hTargetSpot = nil
local fLastWardPlantTime = -math.huge
local bDewardMode = false       -- true when executing deward instead of normal ward
local vDewardTarget = nil       -- deward target location

--------------------------------------------------------------------
-- Ward Expiry Tracking
--------------------------------------------------------------------
local wardPlantLog = {}         -- { location, plantTime, wardType }
local OBSERVER_DURATION = 360
local SENTRY_DURATION   = 420
local EXPIRY_WARNING    = 30    -- warn 30s before expiry
local lastExpiryCheck   = -999

local function TrackWardPlant(location, wardType)
	if location == nil then return end
	table.insert(wardPlantLog, {
		location  = location,
		plantTime = DotaTime(),
		wardType  = wardType or "observer",
	})
end

local function GetExpiringWards()
	local now = DotaTime()
	if now - lastExpiryCheck < 5 then return {} end
	lastExpiryCheck = now

	local expiring = {}
	for i = #wardPlantLog, 1, -1 do
		local w = wardPlantLog[i]
		local duration = w.wardType == "observer" and OBSERVER_DURATION or SENTRY_DURATION
		local remaining = (w.plantTime + duration) - now
		if remaining < 0 then
			table.remove(wardPlantLog, i)  -- expired, clean up
		elseif remaining < EXPIRY_WARNING then
			table.insert(expiring, w)
		end
	end
	return expiring
end

function GetDesire()
	-- Position gate removed: any bot can ward when commanded or holding wards
	local cacheKey = 'GetWardDesire'..tostring(bot:GetPlayerID())
	local cachedVar = J.Utils.GetCachedVars(cacheKey, 0.6 * (1 + Customize.ThinkLess))
	if cachedVar ~= nil then return cachedVar end
	local res = GetDesireHelper()
	J.Utils.SetCachedVars(cacheKey, res)
	return res
end
function GetDesireHelper()
	-- Comms: warding/dewarding mission override (highest priority)
	-- Human-commanded warding bypasses IsSuitableToWard safety checks
	if J.Comms ~= nil and J.Comms.IsOnWardingMission(bot) then
		-- Only block mission if bot is disabled or dead (not soft conditions like "recently damaged")
		if bot:IsChanneling() or not bot:IsAlive() then
			return BOT_MODE_DESIRE_NONE
		end
		local missionTarget = J.Comms.GetMissionTarget(bot)
		if missionTarget then
			hTargetSpot = missionTarget
			if J.Log ~= nil then
				J.Log.Debug("WARD", bot:GetUnitName() .. " on ward mission, type=" .. tostring(J.Comms.GetMissionType(bot)))
			end
			-- Find appropriate ward item for mission
			local missionType = J.Comms.GetMissionType(bot)
			if missionType == "obs" then
				ObserverWard = nil
				for i = 0, 5 do
					local hItem = bot:GetItemInSlot(i)
					if hItem then
						local sItemName = hItem:GetName()
						if sItemName == 'item_ward_observer' or sItemName == 'item_ward_dispenser' then
							ObserverWard = hItem
							break
						end
					end
				end
				if ObserverWard == nil then
					-- No ward item -- end mission, can't complete
					J.Comms.EndMission(bot)
					if J.Log ~= nil then J.Log.Info("WARD", bot:GetUnitName() .. " ward mission aborted: no observer wards") end
					return BOT_MODE_DESIRE_NONE
				end
			else
				SentryWard = nil
				for i = 0, 5 do
					local hItem = bot:GetItemInSlot(i)
					if hItem then
						local sItemName = hItem:GetName()
						if sItemName == 'item_ward_sentry' or sItemName == 'item_ward_dispenser' then
							SentryWard = hItem
							break
						end
					end
				end
				if SentryWard == nil then
					J.Comms.EndMission(bot)
					if J.Log ~= nil then J.Log.Info("WARD", bot:GetUnitName() .. " deward mission aborted: no sentry wards") end
					return BOT_MODE_DESIRE_NONE
				end
			end
			if J.Log ~= nil then J.Log.Debug("WARD", bot:GetUnitName() .. " ward desire=VERYHIGH (mission " .. tostring(J.Comms.GetMissionType(bot)) .. ")") end
			return BOT_MODE_DESIRE_VERYHIGH
		else
			J.Comms.EndMission(bot)
		end
	end

	-- Comms: !ward or !deward command (even if not on mission yet)
	-- This catches the case where mission was started but GetMissionTarget returned nil
	if J.Comms ~= nil then
		local cmd = J.Comms.GetCurrentCommand()
		if cmd ~= nil and (cmd.type == "ward_obs" or cmd.type == "deward") and J.Comms.IsCommandFresh(25) then
			return BOT_MODE_DESIRE_HIGH
		end
	end

	-- Deward: check if we should actively deward (visible enemy wards / command)
	if EnsureDeward() then
		Deward.ScanForEnemyWards()
		local shouldDeward, dewardLoc = Deward.ShouldDeward(bot)
		if shouldDeward and dewardLoc ~= nil then
			bDewardMode = true
			vDewardTarget = dewardLoc
			hTargetSpot = nil  -- clear normal ward target
			return BOT_MODE_DESIRE_HIGH
		end
	end
	bDewardMode = false
	vDewardTarget = nil

	-- Autonomous warding: safety checks apply
    if not X.IsSuitableToWard() then
        return BOT_MODE_DESIRE_NONE
    end

	-- Autonomous warding: supports ward eagerly, cores only when convenient
	local botPos = J.GetPosition(bot)
	local wardDesireMultiplier = 1.0
	if botPos <= 2 then
		wardDesireMultiplier = 0.3  -- pos 1-2: only ward if very close & safe
	elseif botPos == 3 then
		wardDesireMultiplier = 0.5  -- pos 3: moderate willingness
	end
	-- pos 4-5: multiplier stays 1.0 (full desire)

	-- 如果在打高地 就别撤退去干别的
	if J.Utils.IsTeamPushingSecondTierOrHighGround(bot) then
		return BOT_MODE_DESIRE_NONE
	end
	local enemiesAtAncient = J.Utils.CountEnemyHeroesNear(GetAncient(GetTeam()):GetLocation(), 3200)
    if enemiesAtAncient >= 1 then
        return BOT_MODE_DESIRE_NONE
    end

    for i = 0, 5 do
        local hItem = bot:GetItemInSlot(i)
        if hItem then
            local sItemName = hItem:GetName()
            if sItemName == 'item_ward_observer' or sItemName == 'item_ward_dispenser' then
                ObserverWard = hItem
				break
            end
        end
    end

    -- Observer
    if J.CanCastAbility(ObserverWard) then
        local hAvailabeObserverWardSpots = W.GetAvailabeObserverWardSpots(bot)
        hTargetSpot = W.GetClosestObserverWardSpot(bot, hAvailabeObserverWardSpots)
		if hTargetSpot and (not X.IsEnemyCloserToWardLocation(hTargetSpot.location) or J.IsRealInvisible(bot)) then
			if DotaTime() < 0 and DotaTime() > (J.IsModeTurbo() and -45 or -60) then
				return BOT_MODE_DESIRE_ABSOLUTE * wardDesireMultiplier
			end

			if DotaTime() > fLastWardPlantTime + 1.0 then
				if GetUnitToLocationDistance(bot, hTargetSpot.location) <= 3200 then
					return BOT_MODE_DESIRE_VERYHIGH * wardDesireMultiplier
				end
			end
		end
    end

	for i = 0, 5 do
        local hItem = bot:GetItemInSlot(i)
        if hItem then
            local sItemName = hItem:GetName()
            if sItemName == 'item_ward_sentry' or sItemName == 'item_ward_dispenser' then
                SentryWard = hItem
				break
            end
        end
    end

    -- Sentry
    if J.CanCastAbility(SentryWard) then
        local hPossibleSentryWardSpots = W.GetPossibleSentryWardSpots(bot)
        hTargetSpot = W.GetClosestSentryWardSpot(bot, hPossibleSentryWardSpots)
		if hTargetSpot and (not X.IsEnemyCloserToWardLocation(hTargetSpot.location) or J.IsRealInvisible(bot)) then
			if DotaTime() > fLastWardPlantTime + 1.0 then
				if GetUnitToLocationDistance(bot, hTargetSpot.location) <= 3200 then
					return BOT_MODE_DESIRE_VERYHIGH * wardDesireMultiplier
				end
			end
		end
    end

	-- Ward expiry: boost desire if our wards are about to expire
	if J.CanCastAbility(ObserverWard) and botPos ~= nil and botPos >= 4 then
		local expiringWards = GetExpiringWards()
		if #expiringWards > 0 then
			-- Re-evaluate available spots (the expiring location should now be available)
			local hAvailSpots = W.GetAvailabeObserverWardSpots(bot)
			hTargetSpot = W.GetClosestObserverWardSpot(bot, hAvailSpots)
			if hTargetSpot and GetUnitToLocationDistance(bot, hTargetSpot.location) <= 4000 then
				return BOT_MODE_DESIRE_HIGH * wardDesireMultiplier
			end
		end
	end

	return BOT_MODE_DESIRE_NONE
end

function Think()
	if J.CanNotUseAction(bot) then return end
	if J.Utils.IsBotThinkingMeaningfulAction(bot, Customize.ThinkLess, "ward") then return end

	-- Re-validate ward items (may have been used/sold since GetDesire cached them)
	ObserverWard = nil
	SentryWard = nil
	for i = 0, 5 do
		local hItem = bot:GetItemInSlot(i)
		if hItem then
			local sItemName = hItem:GetName()
			if sItemName == 'item_ward_observer' or sItemName == 'item_ward_dispenser' then
				if ObserverWard == nil then ObserverWard = hItem end
			end
			if sItemName == 'item_ward_sentry' or sItemName == 'item_ward_dispenser' then
				if SentryWard == nil then SentryWard = hItem end
			end
		end
	end

	-- Announce warding if on mission
	if J.Comms ~= nil and J.Comms.IsOnWardingMission(bot) then
		J.Comms.AnnounceWarding(bot)
	end

	-- Deward mode: execute deward instead of normal warding
	if bDewardMode and vDewardTarget ~= nil and EnsureDeward() then
		Deward.ExecuteDeward(bot, vDewardTarget)
		return
	end

	if hTargetSpot then
		if ObserverWard and J.CanCastAbility(ObserverWard) then
			if GetUnitToLocationDistance(bot, hTargetSpot.location) <= nObserverWardCastRange then
				if ObserverWard:GetName() == 'item_ward_observer' then
					bot:Action_UseAbilityOnLocation(ObserverWard, hTargetSpot.location)
				else
					if ObserverWard:GetToggleState() == false then
						bot:Action_UseAbilityOnEntity(ObserverWard, bot)
						return
					else
						bot:Action_UseAbilityOnLocation(ObserverWard, hTargetSpot.location)
					end
				end

				hTargetSpot.plant_time_obs = DotaTime()
				fLastWardPlantTime = DotaTime()
				TrackWardPlant(hTargetSpot.location, "observer")
				-- Advance mission to next spot
				if J.Comms ~= nil and J.Comms.IsOnWardingMission(bot) then
					J.Comms.AdvanceMissionSpot(bot)
				end
				return
			else
				bot:Action_MoveToLocation(hTargetSpot.location)
				return
			end
		end

		if SentryWard and J.CanCastAbility(SentryWard) then
			if GetUnitToLocationDistance(bot, hTargetSpot.location) <= nSentryWardCastRange then
				local fLength = 0
				if W.IsOtherWardClose(hTargetSpot.location, 'npc_dota_observer_wards', 300, true, false) then
					fLength = 30
				end

				if SentryWard:GetName() == 'item_ward_sentry' then
					bot:Action_UseAbilityOnLocation(SentryWard, hTargetSpot.location + RandomVector(fLength))
				else
					if SentryWard:GetToggleState() == true then
						bot:Action_UseAbilityOnEntity(SentryWard, bot)
						return
					else
						bot:Action_UseAbilityOnLocation(SentryWard, hTargetSpot.location + RandomVector(fLength))
					end
				end

				hTargetSpot.plant_time_sentry = DotaTime()
				fLastWardPlantTime = DotaTime()
				TrackWardPlant(hTargetSpot.location, "sentry")
				-- Advance mission to next spot
				if J.Comms ~= nil and J.Comms.IsOnWardingMission(bot) then
					J.Comms.AdvanceMissionSpot(bot)
				end
				return
			else
				bot:Action_MoveToLocation(hTargetSpot.location)
				return
			end
		end
	end
end

function X.IsSuitableToWard()
	local nEnemyHeroes = bot:GetNearbyHeroes(1200, true, BOT_MODE_NONE)

	local botActiveMode = bot:GetActiveMode()
    local botActiveModeDesire = bot:GetActiveModeDesire()

	if (J.IsRetreating(bot) and botActiveModeDesire > 0.75)
	or (botActiveMode == BOT_MODE_RUNE and DotaTime() > 0)
	or (botActiveMode == BOT_MODE_DEFEND_ALLY)
	or (nEnemyHeroes ~= nil and #nEnemyHeroes >= 1 and X.IsIBecameTheTarget(nEnemyHeroes))
    or J.IsDefending(bot)
	or J.IsGoingOnSomeone(bot)
	or bot:WasRecentlyDamagedByAnyHero(5.0)
	then
		return false
	end

	return true
end

function X.IsIBecameTheTarget(unitList)
	for _, unit in pairs(unitList) do
		if J.IsValid(unit)
        and not J.IsSuspiciousIllusion(unit)
		and unit:GetAttackTarget() == bot
		then
			return true
		end
	end

	return false
end

function X.IsEnemyCloserToWardLocation(vLocation)
	for _, id in pairs(GetTeamPlayers(GetOpposingTeam())) do
		if IsHeroAlive(id) then
			local info = GetHeroLastSeenInfo(id)
			if info ~= nil then
				local dInfo = info[1]
				if  dInfo ~= nil
				and dInfo.time_since_seen < 3.0
				and J.GetDistance(dInfo.location, vLocation) < GetUnitToLocationDistance(bot, vLocation)
				then
					local nAllyHeroes = J.GetAlliesNearLoc(vLocation, 1200)
					local nEnemyHeroes = J.GetEnemiesNearLoc(vLocation, 1200)
					if #nEnemyHeroes > #nAllyHeroes then
						return true
					end
				end
			end
		end
	end

	return false
end