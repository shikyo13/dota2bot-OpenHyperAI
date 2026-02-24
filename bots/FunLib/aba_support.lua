--------------------------------------------------------------------
-- aba_support.lua  -  Support Intelligence (Pull, Stack, Zone)
--
-- Makes pos 4-5 supports perform camp pulling, camp stacking,
-- and lane zoning during the laning phase.
--------------------------------------------------------------------

local X = {}

local J   -- set lazily
local Log -- set lazily (direct ref to avoid circular dep)

--------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------
local PULL_CAMP_RADIUS       = 300    -- how close to be to "be at" the camp
local PULL_CREEP_AGGRO_RANGE = 500    -- range to aggro neutral creeps
local STACK_WINDOW_START     = 45     -- start watching for stack at :45
local STACK_WINDOW_END       = 57     -- must attack by :57
local STACK_ATTACK_TIME      = 54     -- default attack time for stacking
local LANE_EQUILIBRIUM_POINT = 0.50   -- lane front > this = pushed (at or past midpoint)

--------------------------------------------------------------------
-- Pull camp locations (hardcoded for reliability)
-- Radiant safe (bot) lane small camp + Dire safe (top) lane small camp
--------------------------------------------------------------------
local PULL_CAMPS = {
    -- Radiant pos 5 pulls from bottom small camp
    [TEAM_RADIANT] = {
        [LANE_BOT] = {
            camp = Vector(-1740, -4280, 256),   -- small camp location
            drag_to = Vector(-1200, -3400, 256), -- drag toward lane
            attack_time = 15,  -- attack at :15 or :45 of game clock
        },
        [LANE_TOP] = {
            camp = Vector(-3472, 384, 256),     -- offlane pull camp
            drag_to = Vector(-4200, 400, 256),
            attack_time = 17,
        },
    },
    [TEAM_DIRE] = {
        [LANE_TOP] = {
            camp = Vector(1060, 4096, 256),    -- small camp location
            drag_to = Vector(1200, 3200, 256),  -- drag toward lane
            attack_time = 15,
        },
        [LANE_BOT] = {
            camp = Vector(3472, -384, 256),
            drag_to = Vector(4200, -400, 256),
            attack_time = 17,
        },
    },
}

--------------------------------------------------------------------
-- Stack camp locations (expanded from aba_site.lua CStackLoc)
--------------------------------------------------------------------
local STACK_CAMPS = {
    [TEAM_RADIANT] = {
        { camp = Vector(-1740, -4280, 256),  stack_to = Vector(-2200, -3200, 256), time = 55 },  -- small camp bot
        { camp = Vector(-3200, -4530, 256),  stack_to = Vector(-2500, -5300, 256), time = 55 },  -- medium camp bot
        { camp = Vector(-600, -3200, 256),   stack_to = Vector(-1200, -2400, 256), time = 55 },  -- large camp
        -- TODO: Verify ancient camp coords in-game. (4200, -3600) is in Dire jungle quadrant,
        -- may be wrong side of map for Radiant ancient camp. Expected ~(-3400, -700) area.
        { camp = Vector(4200, -3600, 256),   stack_to = Vector(3000, -4400, 256),  time = 54 },  -- ancient camp
    },
    [TEAM_DIRE] = {
        { camp = Vector(1060, 4096, 256),    stack_to = Vector(2200, 3200, 256),   time = 55 },  -- small camp top
        { camp = Vector(3200, 4530, 256),    stack_to = Vector(2500, 5300, 256),   time = 55 },  -- medium camp top
        { camp = Vector(600, 3200, 256),     stack_to = Vector(1200, 2400, 256),   time = 55 },  -- large camp
        { camp = Vector(-4200, 3600, 256),   stack_to = Vector(-3000, 4400, 256),  time = 54 },  -- ancient camp
    },
}

--------------------------------------------------------------------
-- State tracking
--------------------------------------------------------------------
local supportState = {}  -- [playerID] = {task, phase, target, startTime}

local function GetState(bot)
    local pid = bot:GetPlayerID()
    if supportState[pid] == nil then
        supportState[pid] = { task = "idle", phase = 0, target = nil, startTime = 0 }
    end
    return supportState[pid]
end

local function SetState(bot, task, phase, target)
    local s = GetState(bot)
    s.task = task
    s.phase = phase or 0
    s.target = target
    s.startTime = DotaTime()
end

--------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------
local function EnsureJ()
    if J == nil then
        local ok, mod = pcall(require, GetScriptDirectory()..'/FunLib/jmz_func')
        if ok then J = mod end
    end
    return J ~= nil
end

local function EnsureLog()
    if Log == nil then
        local ok, mod = pcall(require, GetScriptDirectory()..'/FunLib/aba_log')
        if ok then Log = mod end
    end
    return Log ~= nil
end

local function Trace(bot, msg)
    if EnsureLog() then Log.Trace("SUPPORT", bot, msg) end
end

local function GetGameSeconds()
    local t = DotaTime()
    if t < 0 then return -1 end
    return t % 60
end

local function IsLanePushed(bot, lane)
    local front = GetLaneFrontAmount(GetTeam(), lane, false)
    return front > LANE_EQUILIBRIUM_POINT
end

local function GetNearbyNeutralCount(location, radius)
    -- Use a bot reference to check for neutrals
    local neutrals = GetUnitList(UNIT_LIST_NEUTRAL_CREEPS)
    local count = 0
    for _, creep in pairs(neutrals) do
        if creep ~= nil and creep:IsAlive() then
            local dist = GetUnitToLocationDistance(creep, location)
            if dist ~= nil and dist < radius then
                count = count + 1
            end
        end
    end
    return count
end

local function HasEnemyNearby(bot, range)
    if not EnsureJ() then return false end
    local enemies = J.GetNearbyHeroes(bot, range, true, BOT_MODE_NONE)
    return enemies ~= nil and #enemies > 0
end

local function HasAllyCarryInLane(bot, range)
    if not EnsureJ() then return false end
    local allies = bot:GetNearbyHeroes(range, false, BOT_MODE_NONE)
    if allies == nil then return false end
    for _, ally in pairs(allies) do
        if ally ~= nil and J.IsValidHero(ally) and ally ~= bot then
            local pos = J.GetPosition(ally)
            if pos ~= nil and pos <= 3 then
                return true
            end
        end
    end
    return false
end

--------------------------------------------------------------------
-- Large camp locations for pull-through
--------------------------------------------------------------------
local LARGE_CAMPS = {
    [TEAM_RADIANT] = {
        [LANE_BOT] = Vector(-3200, -4530, 256),  -- Radiant medium/large camp near bot
        [LANE_TOP] = Vector(-4400, 400, 256),     -- Radiant offlane large camp
    },
    [TEAM_DIRE] = {
        [LANE_TOP] = Vector(3200, 4530, 256),    -- Dire medium/large camp near top
        [LANE_BOT] = Vector(4400, -400, 256),     -- Dire offlane large camp
    },
}

--------------------------------------------------------------------
-- Roam Detection
--------------------------------------------------------------------
function X.ShouldRoamFromLane(bot)
    if not EnsureJ() then return false, nil end

    local pos = J.GetPosition(bot)
    if pos == nil or pos < 4 then return false, nil end
    if not J.IsInLaningPhase() then return false, nil end
    if not bot:IsAlive() then return false, nil end

    -- Check 1: Is our carry safe without us?
    local lane = bot:GetAssignedLane()
    local allies = bot:GetNearbyHeroes(2000, false, BOT_MODE_NONE)
    local carryPresent = false
    local carrySafe = false

    if allies ~= nil then
        for _, ally in pairs(allies) do
            if ally ~= nil and J.IsValidHero(ally) and ally ~= bot then
                local allyPos = J.GetPosition(ally)
                if allyPos ~= nil and allyPos <= 2 then
                    carryPresent = true
                    local allyHP = ally:GetHealth() / ally:GetMaxHealth()
                    local enemies = ally:GetNearbyHeroes(1200, true, BOT_MODE_NONE)
                    if allyHP > 0.7 and (enemies == nil or #enemies <= 1) then
                        carrySafe = true
                    end
                end
            end
        end
    end

    if not carryPresent or not carrySafe then return false, nil end

    -- Check 2: Does another lane need help?
    local teamPlayers = GetTeamPlayers(GetTeam())
    for i = 1, #teamPlayers do
        local member = GetTeamMember(i)
        if member ~= nil and member:IsAlive() and member ~= bot then
            local memberLane = member:GetAssignedLane()
            if memberLane ~= lane then
                local memberHP = member:GetHealth() / member:GetMaxHealth()
                local memberEnemies = member:GetNearbyHeroes(1200, true, BOT_MODE_NONE)
                local enemyCount = (memberEnemies ~= nil) and #memberEnemies or 0

                -- Teammate is in trouble: low HP and outnumbered
                if memberHP < 0.5 and enemyCount >= 2 then
                    return true, member:GetLocation()
                end

                -- Gank opportunity: enemy is alone and we can kill
                if enemyCount == 1 and memberHP > 0.6 then
                    local enemy = memberEnemies[1]
                    if enemy ~= nil and enemy:GetHealth() / enemy:GetMaxHealth() < 0.7 then
                        return true, enemy:GetLocation()
                    end
                end
            end
        end
    end

    return false, nil
end

--------------------------------------------------------------------
-- Execute Roam
--------------------------------------------------------------------
local function ExecuteRoam(bot)
    local state = GetState(bot)
    if state.target == nil or state.target.location == nil then
        SetState(bot, "idle")
        return
    end

    local dist = GetUnitToLocationDistance(bot, state.target.location)
    if dist > 300 then
        bot:Action_MoveToLocation(state.target.location)
    else
        -- Arrived at roam target, let normal mode take over
        SetState(bot, "idle")
    end

    -- Timeout after 20 seconds
    if DotaTime() - state.startTime > 20 then
        SetState(bot, "idle")
    end
end

--------------------------------------------------------------------
-- Should Pull
--------------------------------------------------------------------
function X.ShouldPullCamp(bot)
    if not EnsureJ() then return false end

    local pos = J.GetPosition(bot)
    if pos == nil or pos < 4 then return false end
    if not J.IsInLaningPhase() then return false end
    if not bot:IsAlive() then return false end

    local lane = bot:GetAssignedLane()
    local team = GetTeam()

    -- Check if lane is pushed
    if not IsLanePushed(bot, lane) then
        local front = GetLaneFrontAmount(GetTeam(), lane, false)
        Trace(bot, "pull_skip reason=lane_not_pushed front=" .. string.format("%.2f", front))
        return false
    end

    -- Must have a pull camp defined for this lane
    local camps = PULL_CAMPS[team]
    if camps == nil or camps[lane] == nil then return false end

    -- Need a carry nearby to not leave them alone
    if not HasAllyCarryInLane(bot, 2000) then
        Trace(bot, "pull_skip reason=no_carry_nearby")
        return false
    end

    -- Check timing: pull at :13-:17 or :43-:47
    local secs = GetGameSeconds()
    local pullTime = camps[lane].attack_time
    if not ((secs >= pullTime - 3 and secs <= pullTime + 2)
        or (secs >= pullTime + 30 - 3 and secs <= pullTime + 30 + 2)) then
        Trace(bot, "pull_skip reason=bad_timing secs=" .. string.format("%.0f", secs))
        return false
    end

    -- Check if enemy support is near the pull camp (they'll contest/block)
    local campLoc = camps[lane].camp
    local nearbyEnemies = bot:GetNearbyHeroes(1500, true, BOT_MODE_NONE)
    if nearbyEnemies ~= nil then
        for _, enemy in pairs(nearbyEnemies) do
            if enemy ~= nil and enemy:IsAlive() then
                local enemyToCamp = GetUnitToLocationDistance(enemy, campLoc)
                if enemyToCamp < 800 then
                    Trace(bot, "pull_skip reason=enemy_near_camp dist=" .. string.format("%.0f", enemyToCamp))
                    return false
                end
            end
        end
    end

    return true
end

--------------------------------------------------------------------
-- Should Stack
--------------------------------------------------------------------
function X.ShouldStackCamp(bot)
    if not EnsureJ() then return false end

    local pos = J.GetPosition(bot)
    if pos == nil or pos < 4 then return false end
    -- Allow stacking during laning and into mid-game (up to 25 min)
    local gameTime = DotaTime()
    if gameTime > 25 * 60 then return false end
    if not J.IsInLaningPhase() then
        -- Post-laning stacking: only if not in danger (covers ~8-25 min)
        if HasEnemyNearby(bot, 1500) then
            Trace(bot, "stack_skip reason=enemy_nearby_postlaning")
            return false
        end
    end
    if not bot:IsAlive() then return false end

    local secs = GetGameSeconds()
    if secs < STACK_WINDOW_START or secs > STACK_WINDOW_END then return false end

    -- Don't stack if in danger
    if HasEnemyNearby(bot, 1000) then
        Trace(bot, "stack_skip reason=enemy_nearby dist=1000")
        return false
    end

    return true
end

--------------------------------------------------------------------
-- Get best stack target
--------------------------------------------------------------------
function X.GetBestStackTarget(bot)
    local team = GetTeam()
    local camps = STACK_CAMPS[team]
    if camps == nil then return nil end

    local bestCamp = nil
    local bestDist = 99999

    for _, camp in pairs(camps) do
        local dist = GetUnitToLocationDistance(bot, camp.camp)
        -- Only consider camps we can reach in time
        if dist < 2500 then
            -- Check if camp has creeps (not already cleared/stacked too much)
            local neutralCount = GetNearbyNeutralCount(camp.camp, 500)
            if neutralCount > 0 and neutralCount <= 5 then  -- 1-5 = not over-stacked
                if dist < bestDist then
                    bestDist = dist
                    bestCamp = camp
                end
            end
        end
    end

    return bestCamp
end

--------------------------------------------------------------------
-- Execute Pull
--------------------------------------------------------------------
local function ExecutePull(bot)
    local state = GetState(bot)
    local lane = bot:GetAssignedLane()
    local team = GetTeam()
    local camp = PULL_CAMPS[team] and PULL_CAMPS[team][lane]
    if camp == nil then
        SetState(bot, "idle")
        return
    end

    if state.phase == 0 then
        -- Phase 0: Walk to camp
        local dist = GetUnitToLocationDistance(bot, camp.camp)
        if dist > PULL_CAMP_RADIUS then
            bot:Action_MoveToLocation(camp.camp)
        else
            SetState(bot, "pulling", 1, camp)
        end
    elseif state.phase == 1 then
        -- Phase 1: Attack a neutral creep to aggro
        local neutrals = GetUnitList(UNIT_LIST_NEUTRAL_CREEPS)
        local closest = nil
        local closestDist = 99999
        for _, n in pairs(neutrals) do
            if n ~= nil and n:IsAlive() then
                local d = GetUnitToLocationDistance(n, camp.camp)
                if d < 600 and d < closestDist then
                    closest = n
                    closestDist = d
                end
            end
        end

        if closest ~= nil then
            -- Issue attack command. We store the attack start time and
            -- only transition to phase 2 after 0.5s so the attack has
            -- time to register and draw aggro.
            if state.attackStartTime == nil then
                bot:Action_AttackUnit(closest, true)
                state.attackStartTime = DotaTime()
            elseif DotaTime() - state.attackStartTime > 0.5 then
                state.attackStartTime = nil
                SetState(bot, "pulling", 2, camp)
            end
        else
            SetState(bot, "idle")
        end
    elseif state.phase == 2 then
        -- Phase 2: Drag creeps toward lane
        bot:Action_MoveToLocation(camp.drag_to)
        -- After 3 seconds, check if should pull through to large camp
        if DotaTime() - state.startTime > 3 then
            -- Check neutrals near the bot (they follow us), not at drag_to
            local neutralCount = GetNearbyNeutralCount(bot:GetLocation(), 600)
            if neutralCount >= 2 then
                -- Pull through: attack large camp to chain
                local lane2 = bot:GetAssignedLane()
                local team2 = GetTeam()
                local largeCampLoc = LARGE_CAMPS[team2] and LARGE_CAMPS[team2][lane2]
                if largeCampLoc ~= nil then
                    SetState(bot, "pulling", 3, { camp = camp, largeCamp = largeCampLoc })
                else
                    SetState(bot, "idle")
                end
            else
                SetState(bot, "idle")
            end
        end
    elseif state.phase == 3 then
        -- Phase 3: Pull-through to large camp
        local pullTarget = state.target
        if pullTarget == nil or pullTarget.largeCamp == nil then
            SetState(bot, "idle")
            return
        end
        local largeCampLoc = pullTarget.largeCamp

        local dist = GetUnitToLocationDistance(bot, largeCampLoc)
        if dist > 300 then
            bot:Action_MoveToLocation(largeCampLoc)
        else
            -- Attack a neutral near large camp to aggro them
            local neutrals = GetUnitList(UNIT_LIST_NEUTRAL_CREEPS)
            local closest = nil
            local closestDist = 99999
            for _, n in pairs(neutrals) do
                if n ~= nil and n:IsAlive() then
                    local d = GetUnitToLocationDistance(n, largeCampLoc)
                    if d < 600 and d < closestDist then
                        closest = n
                        closestDist = d
                    end
                end
            end
            if closest ~= nil then
                bot:Action_AttackUnit(closest, true)
            end
        end

        -- Timeout for pull-through
        if DotaTime() - state.startTime > 6 then
            SetState(bot, "idle")
        end
    end
end

--------------------------------------------------------------------
-- Execute Stack
--------------------------------------------------------------------
local function ExecuteStack(bot)
    local state = GetState(bot)
    local camp = state.target

    if camp == nil then
        SetState(bot, "idle")
        return
    end

    local secs = GetGameSeconds()

    if state.phase == 0 then
        -- Phase 0: Walk to camp before stack time
        local dist = GetUnitToLocationDistance(bot, camp.camp)
        if dist > PULL_CAMP_RADIUS then
            bot:Action_MoveToLocation(camp.camp)
        else
            SetState(bot, "stacking", 1, camp)
        end
    elseif state.phase == 1 then
        -- Phase 1: Wait until adjusted stack attack time, then attack
        -- Adjust timing based on distance and attack range
        local dist = GetUnitToLocationDistance(bot, camp.camp)
        local attackRange = bot:GetAttackRange()
        local adjustedTime = camp.time
        if attackRange > 500 then
            adjustedTime = adjustedTime - 1  -- ranged heroes can stack earlier
        end
        if dist > 200 then
            adjustedTime = adjustedTime - 1  -- if not right at camp, start earlier
        end
        if secs >= adjustedTime then
            local neutrals = GetUnitList(UNIT_LIST_NEUTRAL_CREEPS)
            local closest = nil
            local closestDist = 99999
            for _, n in pairs(neutrals) do
                if n ~= nil and n:IsAlive() then
                    local d = GetUnitToLocationDistance(n, camp.camp)
                    if d < 600 and d < closestDist then
                        closest = n
                        closestDist = d
                    end
                end
            end
            if closest ~= nil then
                bot:Action_AttackUnit(closest, true)
                SetState(bot, "stacking", 2, camp)
            else
                SetState(bot, "idle")
            end
        end
        -- else keep waiting at camp
    elseif state.phase == 2 then
        -- Phase 2: Run away to pull creeps out of spawn box
        bot:Action_MoveToLocation(camp.stack_to)
        -- After 4 seconds, done stacking
        if DotaTime() - state.startTime > 4 then
            SetState(bot, "idle")
        end
    end
end

--------------------------------------------------------------------
-- Main Think (called from mode_laning_generic.lua for supports)
--------------------------------------------------------------------
function X.Think(bot)
    if not EnsureJ() then return false end

    local state = GetState(bot)

    -- Timeout: if stuck in any task for > 15 seconds, reset
    -- Roaming gets a longer 20-second timeout
    local timeout = 15
    if state.task == "roaming" then timeout = 20 end
    if state.task ~= "idle" and DotaTime() - state.startTime > timeout then
        SetState(bot, "idle")
        return false
    end

    -- Execute active tasks
    if state.task == "roaming" then
        ExecuteRoam(bot)
        return true
    end

    if state.task == "pulling" then
        ExecutePull(bot)
        return true
    end

    if state.task == "stacking" then
        ExecuteStack(bot)
        return true
    end

    -- Check if we should roam to help another lane (before pull/stack)
    local shouldRoam, roamTarget = X.ShouldRoamFromLane(bot)
    if shouldRoam and roamTarget ~= nil then
        if J ~= nil and J.Log ~= nil then
            J.Log.Info("SUPPORT", string.gsub(bot:GetUnitName(), "npc_dota_hero_", "") .. " roaming to help at " .. tostring(roamTarget))
        end
        SetState(bot, "roaming", 0, { location = roamTarget })
        ExecuteRoam(bot)
        return true
    end

    -- Decide what to do
    if X.ShouldPullCamp(bot) then
        local lane = bot:GetAssignedLane()
        local team = GetTeam()
        local camp = PULL_CAMPS[team] and PULL_CAMPS[team][lane]
        if camp ~= nil then
            if J ~= nil and J.Log ~= nil then
                local secs = GetGameSeconds()
                J.Log.Info("SUPPORT", string.gsub(bot:GetUnitName(), "npc_dota_hero_", "") .. " pulling camp at :" .. tostring(math.floor(secs)))
            end
            SetState(bot, "pulling", 0, camp)
            ExecutePull(bot)
            return true
        end
    end

    if X.ShouldStackCamp(bot) then
        local camp = X.GetBestStackTarget(bot)
        if camp ~= nil then
            if J ~= nil and J.Log ~= nil then
                local secs = GetGameSeconds()
                J.Log.Info("SUPPORT", string.gsub(bot:GetUnitName(), "npc_dota_hero_", "") .. " stacking camp at :" .. tostring(math.floor(secs)))
            end
            SetState(bot, "stacking", 0, camp)
            ExecuteStack(bot)
            return true
        end
    end

    return false
end

--------------------------------------------------------------------
-- Query API for mode script
--------------------------------------------------------------------
function X.GetDesireValue(bot)
    if not EnsureJ() then return 0 end

    local pos = J.GetPosition(bot)
    if pos == nil or pos < 4 then return 0 end
    if not bot:IsAlive() then return 0 end

    local inLaning = J.IsInLaningPhase()
    local gameTime = DotaTime()

    -- Pull and roam are laning-phase only
    if inLaning then
        -- Pull camp desire (high during laning when lane is pushed)
        if X.ShouldPullCamp(bot) then
            return 0.75  -- BOT_MODE_DESIRE_HIGH
        end

        -- Roam desire (moderate-high, helps other lanes)
        local shouldRoam, _ = X.ShouldRoamFromLane(bot)
        if shouldRoam then
            return 0.65  -- BOT_MODE_DESIRE_MODERATE_HIGH
        end
    end

    -- Stack camp desire (moderate, time-sensitive) - works up to 25 min
    if gameTime >= 0 and gameTime <= 1500 then
        if X.ShouldStackCamp(bot) then
            local camp = X.GetBestStackTarget(bot)
            if camp ~= nil then
                return 0.5  -- BOT_MODE_DESIRE_MODERATE
            end
        end
    end

    return 0
end

return X
