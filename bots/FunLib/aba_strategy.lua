--------------------------------------------------------------------
-- Strategic Intelligence Module
-- Centralized tracking of enemy positions, team power assessment,
-- respawn awareness, and shared team objective management.
--
-- NOTE: This module does NOT require jmz_func.lua to avoid
-- circular dependencies. It uses the Dota 2 API directly and
-- requires aba_log independently.
--------------------------------------------------------------------

local X = {}

--------------------------------------------------------------------
-- Dependencies (no jmz_func to avoid circular require)
--------------------------------------------------------------------
local Log = nil
local function SafeLog(level, category, msg)
    if Log == nil then
        local ok, logMod = pcall(require, GetScriptDirectory()..'/FunLib/aba_log')
        if ok and logMod then Log = logMod end
    end
    if Log == nil then return end
    if level == "info" then
        Log.Info(category, msg)
    elseif level == "debug" then
        if Log.IsEnabled and Log.IsEnabled(category, 4) then
            Log.Debug(category, msg)
        end
    elseif level == "warn" then
        Log.Warn(category, msg)
    end
end

--------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------
local CATEGORY = "STRATEGY"

-- Lane boundary heuristics (approximate X coordinates on the Dota 2 map)
-- Top lane runs roughly from (-6500, 6000) to (6000, 6500)
-- Mid lane runs roughly along the diagonal (-4000, -4000) to (4000, 4000)
-- Bot lane runs roughly from (-6000, -6500) to (6500, -6000)
local LANE_BOUNDARIES = {
    top  = { yMin = 2000 },   -- high Y values
    bot  = { yMax = -2000 },  -- low Y values
    -- mid is the diagonal band not covered by top/bot
}

-- Threat level thresholds (seconds missing)
local THREAT_LOW      = 0
local THREAT_MEDIUM   = 10
local THREAT_HIGH     = 20
local THREAT_EXTREME  = 30

-- Power spike items
local POWER_SPIKE_ITEMS = {
    item_bfury             = 2.0,
    item_radiance          = 3.0,
    item_blink             = 2.0,
    item_black_king_bar    = 2.0,
    item_orchid             = 2.0,
    item_bloodthorn        = 2.5,
    item_desolator         = 1.5,
    item_monkey_king_bar   = 1.5,
    item_satanic           = 2.0,
    item_heart             = 2.0,
    item_butterfly         = 2.0,
    item_assault           = 2.0,
    item_sheepstick        = 2.5,
    item_refresher         = 2.0,
    item_skadi             = 1.5,
    item_shivas_guard      = 1.5,
    item_sphere            = 1.5,
    item_overwhelming_blink = 2.5,
    item_arcane_blink       = 2.5,
    item_swift_blink        = 2.5,
}

-- Level power spikes
local LEVEL_SPIKES = {
    [6]  = 1.5,
    [12] = 1.3,
    [18] = 1.2,
    [25] = 1.5,
}

-- Objective time estimates (seconds)
local OBJECTIVE_TIME = {
    tower    = 20,
    barracks = 30,
    roshan   = 70,
}

-- Known ganker heroes (more dangerous when missing)
local GANKER_HEROES = {
    npc_dota_hero_spirit_breaker = true,
    npc_dota_hero_pudge          = true,
    npc_dota_hero_bounty_hunter  = true,
    npc_dota_hero_riki           = true,
    npc_dota_hero_nyx_assassin   = true,
    npc_dota_hero_earth_spirit   = true,
    npc_dota_hero_tusk           = true,
    npc_dota_hero_storm_spirit   = true,
    npc_dota_hero_tinker         = true,
    npc_dota_hero_nature_prophet = true,
    npc_dota_hero_spectre        = true,
    npc_dota_hero_mirana         = true,
    npc_dota_hero_bloodseeker    = true,
    npc_dota_hero_slark          = true,
    npc_dota_hero_night_stalker  = true,
    npc_dota_hero_clockwerk      = true,
    npc_dota_hero_batrider       = true,
}

--------------------------------------------------------------------
-- State
--------------------------------------------------------------------
local enemyState = {}      -- [playerID] = { lastSeen, lastLocation, lastLane, timeMissing, threatLevel, heroName, isAlive }
local teamObjective = {
    type       = "farm",
    lane       = nil,
    target     = nil,
    setTime    = 0,
    confidence = 0,
}

X._lastObjectiveEval = -999
X._lastTrackUpdate   = -999
local initialized = false
local enemyIDs = nil

--------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------
local function EnsureInit()
    if initialized then return true end

    local ok, _ = pcall(function()
        enemyIDs = GetTeamPlayers(GetOpposingTeam())
    end)
    if not ok or enemyIDs == nil then return false end

    for _, id in pairs(enemyIDs) do
        enemyState[id] = {
            lastSeen     = 0,
            lastLocation = nil,
            lastLane     = "unknown",
            timeMissing  = 999,
            threatLevel  = "LOW",
            heroName     = "",
            isAlive      = true,
        }
        -- Try to get hero name
        local nameOk, name = pcall(GetSelectedHeroName, id)
        if nameOk and name ~= nil then
            enemyState[id].heroName = name
        end
    end

    initialized = true
    SafeLog("info", CATEGORY, "Strategic intelligence initialized")
    return true
end

--------------------------------------------------------------------
-- Utility: Distance between two Vectors
--------------------------------------------------------------------
local function VectorDistance(a, b)
    if a == nil or b == nil then return 99999 end
    local dx = a[1] - b[1]
    local dy = a[2] - b[2]
    return math.sqrt(dx * dx + dy * dy)
end

--------------------------------------------------------------------
-- Utility: Determine lane from a map position
--------------------------------------------------------------------
local function GetLaneFromLocation(loc)
    if loc == nil then return "unknown" end

    local x = loc[1]
    local y = loc[2]

    -- Near fountain areas (far corners)
    if x < -5500 and y < -5500 then return "base_radiant" end
    if x > 5500 and y > 5500 then return "base_dire" end

    -- Top lane: high Y, or far left X with moderate Y
    if y > 2000 or (x < -4000 and y > -1000) then
        return "top"
    end

    -- Bot lane: low Y, or far right X with moderate negative Y
    if y < -2000 or (x > 4000 and y < 1000) then
        return "bot"
    end

    -- Mid lane: roughly along the diagonal
    if math.abs(x - y) < 3000 then
        return "mid"
    end

    -- Jungle: everything else
    return "jungle"
end

--------------------------------------------------------------------
-- Utility: Get threat level string from seconds missing
--------------------------------------------------------------------
local function GetThreatString(seconds)
    if seconds < THREAT_MEDIUM then return "LOW"
    elseif seconds < THREAT_HIGH then return "MEDIUM"
    elseif seconds < THREAT_EXTREME then return "HIGH"
    else return "EXTREME"
    end
end

--------------------------------------------------------------------
-- A. Enemy State Manager
--------------------------------------------------------------------
function X.UpdateEnemyTracking()
    if not EnsureInit() then return end

    local now = DotaTime()
    if now < 0 then return end  -- Pre-game

    -- Throttle updates to every 0.5s
    if now - X._lastTrackUpdate < 0.5 then return end
    X._lastTrackUpdate = now

    for _, id in pairs(enemyIDs) do
        local state = enemyState[id]
        if state == nil then goto continue end

        -- Check if alive and detect alive->dead transitions
        local aliveOk, alive = pcall(IsHeroAlive, id)
        if aliveOk then
            if state.isAlive and not alive then
                -- Hero just died: record death time
                state.deathTime = now
            end
            state.isAlive = alive
        end

        if not state.isAlive then
            state.timeMissing = 0
            state.threatLevel = "DEAD"
            goto continue
        end

        -- Get last seen info
        local infoOk, info = pcall(GetHeroLastSeenInfo, id)
        if infoOk and info ~= nil then
            local dInfo = info[1]
            if dInfo ~= nil then
                local timeSince = dInfo.time_since_seen or 999
                state.timeMissing = timeSince

                if timeSince < 3.0 then
                    state.lastSeen = now
                    state.lastLocation = dInfo.location
                    state.lastLane = GetLaneFromLocation(dInfo.location)
                end

                state.threatLevel = GetThreatString(timeSince)
            else
                state.timeMissing = 999
                state.threatLevel = "EXTREME"
            end
        end

        -- Update hero name if we don't have it yet
        if state.heroName == "" then
            local nameOk, name = pcall(GetSelectedHeroName, id)
            if nameOk and name ~= nil then
                state.heroName = name
            end
        end

        ::continue::
    end
end

function X.GetEnemyState()
    return enemyState
end

function X.GetMissingHeroes()
    if not EnsureInit() then return {} end

    local missing = {}
    for _, id in pairs(enemyIDs) do
        local state = enemyState[id]
        if state ~= nil
            and state.isAlive
            and state.timeMissing > 15
        then
            table.insert(missing, {
                id          = id,
                name        = state.heroName,
                timeMissing = state.timeMissing,
                lastLane    = state.lastLane,
                threatLevel = state.threatLevel,
            })
        end
    end
    return missing
end

function X.GetLaneDangerLevel(lane)
    if not EnsureInit() then return 0 end

    local danger = 0
    local now = DotaTime()
    if now < 0 then return 0 end

    -- Check night time bonus
    -- DotaTime() % 600: 0-300 is day, 300-600 is night (approximately)
    local isNight = (now % 600) >= 300

    -- Adjacent lanes for danger assessment
    local adjacentLanes = {
        top = { "mid", "jungle" },
        mid = { "top", "bot", "jungle" },
        bot = { "mid", "jungle" },
    }
    local relevantLanes = adjacentLanes[lane]
    if relevantLanes == nil then return 0 end

    for _, id in pairs(enemyIDs) do
        local state = enemyState[id]
        if state == nil or not state.isAlive then goto continue end

        -- Missing hero from adjacent lane = danger
        if state.timeMissing > 10 then
            local fromAdjacentLane = false
            for _, adjLane in pairs(relevantLanes) do
                if state.lastLane == adjLane then
                    fromAdjacentLane = true
                    break
                end
            end

            local heroDanger = 0
            if state.timeMissing > 10 and state.timeMissing <= 20 then
                heroDanger = 0.15
            elseif state.timeMissing > 20 and state.timeMissing <= 30 then
                heroDanger = 0.25
            elseif state.timeMissing > 30 then
                heroDanger = 0.3
            end

            -- Ganker heroes are extra dangerous
            if GANKER_HEROES[state.heroName] then
                heroDanger = heroDanger * 1.5
            end

            -- More dangerous from adjacent lane
            if fromAdjacentLane then
                heroDanger = heroDanger * 1.3
            end

            danger = danger + heroDanger
        end

        ::continue::
    end

    -- Night time increases gank danger
    if isNight then
        danger = danger * 1.2
    end

    -- Clamp to 0-1
    if danger > 1.0 then danger = 1.0 end
    if danger < 0 then danger = 0 end

    return danger
end

function X.PredictGankTarget()
    if not EnsureInit() then return nil end

    local missingByLastLane = { top = {}, mid = {}, bot = {}, jungle = {} }
    for _, id in pairs(enemyIDs) do
        local state = enemyState[id]
        if state ~= nil and state.isAlive and state.timeMissing > 10 then
            local lane = state.lastLane
            if missingByLastLane[lane] ~= nil then
                table.insert(missingByLastLane[lane], state)
            end
        end
    end

    -- If 2+ heroes missing from same area, predict gank on adjacent lane
    local adjacentTargets = {
        top = { "mid" },
        mid = { "top", "bot" },
        bot = { "mid" },
    }

    for lane, heroes in pairs(missingByLastLane) do
        if #heroes >= 2 then
            local targets
            if lane == "jungle" then
                -- Jungle: pick nearest lane based on average position of missing heroes
                local avgY = 0
                for _, h in pairs(heroes) do
                    if h.lastLocation ~= nil then
                        avgY = avgY + (h.lastLocation[2] or 0)
                    end
                end
                avgY = avgY / #heroes
                if avgY > 1000 then
                    targets = { "top" }
                elseif avgY < -1000 then
                    targets = { "bot" }
                else
                    targets = { "mid" }
                end
            else
                targets = adjacentTargets[lane] or { "mid" }
            end

            local confidence = math.min(1.0, #heroes * 0.3)
            return {
                targetLane    = targets,
                confidence    = confidence,
                missingHeroes = heroes,
            }
        end
    end

    return nil
end

--------------------------------------------------------------------
-- B. Dynamic Power Assessment
--------------------------------------------------------------------
function X.GetHeroPowerLevel(hero)
    if hero == nil then return 0 end

    local power = 0

    -- 1. Level component (0-30 base)
    local levelOk, level = pcall(function() return hero:GetLevel() end)
    if not levelOk or level == nil then level = 1 end

    power = level * 1.2  -- Base: level * 1.2 (max ~36 at level 30)

    -- Level spike bonuses
    for spikeLevel, bonus in pairs(LEVEL_SPIKES) do
        if level >= spikeLevel then
            power = power + bonus
        end
    end

    -- 2. Net worth / items (0-40 range)
    local nwOk, netWorth = pcall(function() return hero:GetNetWorth() end)
    if nwOk and netWorth ~= nil then
        -- Logarithmic scaling: diminishing returns on gold
        power = power + math.log(1 + netWorth / 500) * 3
    end

    -- Power spike item bonuses
    for itemName, bonus in pairs(POWER_SPIKE_ITEMS) do
        local hasOk, hasItem = pcall(function()
            local slot = hero:FindItemSlot(itemName)
            return slot ~= nil and slot >= 0
        end)
        if hasOk and hasItem then
            power = power + bonus
        end
    end

    -- 3. Current HP/mana percentage
    local hpOk, hpPct = pcall(function() return hero:GetHealth() / hero:GetMaxHealth() end)
    if hpOk and hpPct ~= nil then
        if hpPct < 0.3 then
            power = power * 0.4
        elseif hpPct < 0.5 then
            power = power * 0.7
        end
    end

    local mpOk, mpPct = pcall(function() return hero:GetMana() / math.max(1, hero:GetMaxMana()) end)
    if mpOk and mpPct ~= nil then
        if mpPct < 0.15 then
            power = power * 0.85
        end
    end

    -- 4. Ultimate availability
    local ultOk, ultReady = pcall(function()
        local ult = hero:GetAbilityInSlot(5)
        return ult ~= nil and ult:IsFullyCastable()
    end)
    if ultOk and ultReady then
        power = power + 5
    end

    -- Clamp to 0-100
    if power > 100 then power = 100 end
    if power < 0 then power = 0 end

    return power
end

function X.GetTeamPowerBalance()
    local allyPower = 0
    local enemyPower = 0
    local allyCount = 0
    local enemyCount = 0

    -- Ally power
    local allyOk, allyList = pcall(function() return GetUnitList(UNIT_LIST_ALLIED_HEROES) end)
    if allyOk and allyList ~= nil then
        for _, hero in pairs(allyList) do
            local validOk, valid = pcall(function()
                return hero ~= nil and hero:IsAlive() and not hero:IsIllusion()
                    and hero:GetUnitName() ~= nil
                    and string.find(hero:GetUnitName(), "npc_dota_hero_") ~= nil
            end)
            if validOk and valid then
                allyPower = allyPower + X.GetHeroPowerLevel(hero)
                allyCount = allyCount + 1
            end
        end
    end

    -- Enemy power
    local enemyOk, enemyList = pcall(function() return GetUnitList(UNIT_LIST_ENEMY_HEROES) end)
    if enemyOk and enemyList ~= nil then
        for _, hero in pairs(enemyList) do
            local validOk, valid = pcall(function()
                return hero ~= nil and hero:IsAlive() and not hero:IsIllusion()
                    and hero:GetUnitName() ~= nil
                    and string.find(hero:GetUnitName(), "npc_dota_hero_") ~= nil
            end)
            if validOk and valid then
                enemyPower = enemyPower + X.GetHeroPowerLevel(hero)
                enemyCount = enemyCount + 1
            end
        end
    end

    -- For dead enemies we can't see, estimate based on level
    if enemyIDs ~= nil then
        for _, id in pairs(enemyIDs) do
            local state = enemyState[id]
            if state ~= nil and not state.isAlive then
                -- Dead enemy contributes 0
            elseif state ~= nil and state.isAlive and state.timeMissing > 3 then
                -- Missing alive enemy: estimate power from level
                local lvlOk, lvl = pcall(GetHeroLevel, id)
                if lvlOk and lvl ~= nil and lvl > 0 then
                    local estimatedPower = lvl * 1.2 + math.log(1 + lvl * 300) * 3
                    -- Only add if this enemy wasn't already counted in the visible list
                    enemyPower = enemyPower + estimatedPower
                    enemyCount = enemyCount + 1
                end
            end
        end
    end

    -- Avoid division by zero
    local ratio = 1.0
    if enemyPower > 0 then
        ratio = allyPower / enemyPower
    elseif allyPower > 0 then
        ratio = 2.0
    end

    local advantage = "even"
    if ratio > 1.4 then advantage = "strong"
    elseif ratio > 1.1 then advantage = "even"
    elseif ratio > 0.7 then advantage = "weak"
    else advantage = "desperate"
    end

    return {
        allyPower  = allyPower,
        enemyPower = enemyPower,
        allyCount  = allyCount,
        enemyCount = enemyCount,
        ratio      = ratio,
        advantage  = advantage,
    }
end

function X.IsTeamPowerSpike()
    -- Check if any ally hero just reached a power spike level
    local allyIDs = nil
    local ok, _ = pcall(function()
        allyIDs = GetTeamPlayers(GetTeam())
    end)
    if not ok or allyIDs == nil then return false end

    for _, id in pairs(allyIDs) do
        local lvlOk, lvl = pcall(GetHeroLevel, id)
        if lvlOk and lvl ~= nil then
            -- Individual spike: hero is within 1 level of a spike level (just hit it)
            for spikeLevel, _ in pairs(LEVEL_SPIKES) do
                if lvl >= spikeLevel and lvl <= spikeLevel + 1 then
                    return true
                end
            end
        end
    end

    return false
end

function X.GetGamePhase()
    local now = DotaTime()
    if now < 0 then return "early" end

    local allyIDs = nil
    local ok, _ = pcall(function()
        allyIDs = GetTeamPlayers(GetTeam())
    end)
    if not ok or allyIDs == nil then
        -- Fallback to time-based
        if now < 15 * 60 then return "early"
        elseif now < 30 * 60 then return "mid"
        else return "late"
        end
    end

    local totalLevel = 0
    local count = 0
    for _, id in pairs(allyIDs) do
        local lvlOk, lvl = pcall(GetHeroLevel, id)
        if lvlOk and lvl ~= nil then
            totalLevel = totalLevel + lvl
            count = count + 1
        end
    end

    if count == 0 then
        if now < 15 * 60 then return "early"
        elseif now < 30 * 60 then return "mid"
        else return "late"
        end
    end

    local avgLevel = totalLevel / count

    -- Dynamic phase detection using both level and time
    if avgLevel < 8 and now < 20 * 60 then
        return "early"
    elseif avgLevel >= 16 or now > 35 * 60 then
        return "late"
    else
        return "mid"
    end
end

--------------------------------------------------------------------
-- C. Respawn Timer Awareness
--------------------------------------------------------------------
function X.GetDeadEnemyCount()
    if not EnsureInit() then return 0 end

    local count = 0
    for _, id in pairs(enemyIDs) do
        local state = enemyState[id]
        if state ~= nil and not state.isAlive then
            count = count + 1
        end
    end
    return count
end

function X.GetAliveAllyCount()
    local allyIDs = nil
    local ok, _ = pcall(function()
        allyIDs = GetTeamPlayers(GetTeam())
    end)
    if not ok or allyIDs == nil then return 5 end

    local count = 0
    for _, id in pairs(allyIDs) do
        local aliveOk, alive = pcall(IsHeroAlive, id)
        if aliveOk and alive then
            count = count + 1
        end
    end
    return count
end

function X.GetAliveEnemyCount()
    if not EnsureInit() then return 5 end

    local count = 0
    for _, id in pairs(enemyIDs) do
        local aliveOk, alive = pcall(IsHeroAlive, id)
        if aliveOk and alive then
            count = count + 1
        end
    end
    return count
end

function X.GetEnemyRespawnInfo()
    if not EnsureInit() then return {} end

    local deadEnemies = {}
    local now = DotaTime()

    for _, id in pairs(enemyIDs) do
        local state = enemyState[id]
        if state ~= nil and not state.isAlive then
            -- Estimate respawn time based on level and game time
            local lvlOk, lvl = pcall(GetHeroLevel, id)
            if not lvlOk or lvl == nil then lvl = 10 end

            -- Dota 2 respawn formula approximation:
            -- Base respawn = level * 2.5 + some time scaling
            local estimatedRespawn = lvl * 2.5
            if now > 30 * 60 then
                estimatedRespawn = estimatedRespawn + 10
            end

            -- Calculate remaining respawn using tracked deathTime
            local remainingRespawn = estimatedRespawn
            if state.deathTime ~= nil then
                remainingRespawn = math.max(0, state.deathTime + estimatedRespawn - now)
            end

            -- Buyback cost estimation (level-based heuristic)
            local estimatedBBCost = 200 + lvl * lvl * 1.5 + now / 60 * 15
            local hasBuyback = false  -- We can't know enemy gold; conservative estimate

            table.insert(deadEnemies, {
                id             = id,
                name           = state.heroName,
                respawnEstimate = remainingRespawn,
                hasBuyback     = hasBuyback,
            })
        end
    end

    return deadEnemies
end

function X.IsSafeToCommitObjective(objectiveType)
    objectiveType = objectiveType or "tower"
    local timeNeeded = OBJECTIVE_TIME[objectiveType] or 25

    local deadEnemies = X.GetEnemyRespawnInfo()
    if #deadEnemies == 0 then
        return { safe = false, timeWindow = 0, riskyHeroes = {} }
    end

    -- Find the shortest time until an enemy respawns
    local minRespawn = 999
    local riskyHeroes = {}
    for _, enemy in pairs(deadEnemies) do
        if enemy.respawnEstimate < minRespawn then
            minRespawn = enemy.respawnEstimate
        end
        if enemy.respawnEstimate < timeNeeded + 15 then -- +15 for TP + walk
            table.insert(riskyHeroes, enemy.name)
        end
    end

    -- Add TP scroll time + some walk time
    local effectiveWindow = minRespawn + 3 + 5  -- 3s TP, 5s walk avg
    local safe = effectiveWindow > timeNeeded

    return {
        safe        = safe,
        timeWindow  = effectiveWindow,
        riskyHeroes = riskyHeroes,
    }
end

function X.GetObjectiveWindow()
    local deadEnemies = X.GetEnemyRespawnInfo()
    if #deadEnemies == 0 then return 0 end

    -- Time until ALL enemies are back
    local maxRespawn = 0
    for _, enemy in pairs(deadEnemies) do
        if enemy.respawnEstimate > maxRespawn then
            maxRespawn = enemy.respawnEstimate
        end
    end

    -- Add TP + walk time
    return maxRespawn + 8
end

--------------------------------------------------------------------
-- D. Shared Team Objective
--------------------------------------------------------------------

-- Score: should the team farm?
function X.ScoreFarmObjective()
    local score = 0.3  -- Base desire to farm

    local balance = X.GetTeamPowerBalance()

    -- Weaker teams should farm more
    if balance.advantage == "weak" then
        score = score + 0.3
    elseif balance.advantage == "desperate" then
        score = score + 0.5
    elseif balance.advantage == "strong" then
        score = score - 0.1
    end

    -- Early game favors farming
    local phase = X.GetGamePhase()
    if phase == "early" then
        score = score + 0.2
    elseif phase == "late" then
        score = score - 0.1
    end

    -- No enemies dead = safer to farm
    local deadEnemies = X.GetDeadEnemyCount()
    if deadEnemies == 0 then
        score = score + 0.1
    elseif deadEnemies >= 2 then
        score = score - 0.3  -- Should be pushing, not farming
    end

    if score < 0 then score = 0 end
    if score > 1 then score = 1 end
    return score
end

-- Score: should the team push?
function X.ScorePushObjective()
    local score = 0

    local deadEnemies = X.GetDeadEnemyCount()
    local aliveAllies = X.GetAliveAllyCount()

    -- Dead enemies = push opportunity
    if deadEnemies >= 3 then
        score = score + 0.7
    elseif deadEnemies >= 2 then
        score = score + 0.5
    elseif deadEnemies >= 1 then
        score = score + 0.2
    end

    -- Need allies alive to push
    if aliveAllies <= 2 then
        score = score - 0.4
    elseif aliveAllies >= 4 then
        score = score + 0.1
    end

    -- Power advantage helps
    local balance = X.GetTeamPowerBalance()
    if balance.advantage == "strong" then
        score = score + 0.15
    elseif balance.advantage == "desperate" then
        score = score - 0.3
    end

    -- Check if any enemy tower is vulnerable
    local towerVulnerable = false
    local ok, _ = pcall(function()
        for _, lane in pairs({LANE_TOP, LANE_MID, LANE_BOT}) do
            local amount = GetLaneFrontAmount(GetTeam(), lane, false)
            if amount ~= nil and amount > 0.4 then
                towerVulnerable = true
            end
        end
    end)
    if towerVulnerable then
        score = score + 0.1
    end

    if score < 0 then score = 0 end
    if score > 1 then score = 1 end
    return score
end

-- Score: should the team gank?
function X.ScoreGankObjective()
    local score = 0.1

    local phase = X.GetGamePhase()
    -- Ganking is most effective mid-game
    if phase == "mid" then
        score = score + 0.15
    elseif phase == "early" then
        score = score + 0.1
    end

    -- Check for isolated enemies (visible but alone)
    local visibleEnemyCount = 0
    if enemyIDs ~= nil then
        for _, id in pairs(enemyIDs) do
            local state = enemyState[id]
            if state ~= nil and state.isAlive and state.timeMissing < 5 then
                visibleEnemyCount = visibleEnemyCount + 1
            end
        end
    end

    -- If few enemies visible and alive, others might be grouped
    local aliveEnemies = X.GetAliveEnemyCount()
    if visibleEnemyCount == 1 and aliveEnemies >= 3 then
        -- One enemy isolated, others missing = possible gank target
        score = score + 0.3
    elseif visibleEnemyCount <= 2 and aliveEnemies >= 4 then
        score = score + 0.2
    end

    -- Need enough allies alive for ganking
    local aliveAllies = X.GetAliveAllyCount()
    if aliveAllies < 3 then
        score = score - 0.3
    end

    -- Power advantage helps ganking
    local balance = X.GetTeamPowerBalance()
    if balance.advantage == "strong" then
        score = score + 0.1
    elseif balance.advantage == "desperate" then
        score = score - 0.2
    end

    if score < 0 then score = 0 end
    if score > 1 then score = 1 end
    return score
end

-- Score: should the team take Roshan?
function X.ScoreRoshanObjective()
    local score = 0

    -- Check if Roshan is alive (use the API if available)
    local roshanAlive = true
    local rsOk, rsTime = pcall(GetRoshanKillTime)
    if rsOk and rsTime ~= nil and rsTime > 0 then
        local now = DotaTime()
        -- Roshan respawns between 8-11 minutes after kill
        if now - rsTime < 8 * 60 then
            roshanAlive = false
        end
    end

    if not roshanAlive then
        return 0
    end

    local deadEnemies = X.GetDeadEnemyCount()
    local aliveAllies = X.GetAliveAllyCount()

    -- Need dead enemies for safe Roshan
    if deadEnemies >= 3 then
        score = score + 0.6
    elseif deadEnemies >= 2 then
        score = score + 0.4
    elseif deadEnemies >= 1 then
        score = score + 0.15
    end

    -- Need enough allies
    if aliveAllies <= 2 then
        score = score - 0.5
    elseif aliveAllies >= 4 then
        score = score + 0.1
    end

    -- Mid to late game favors Roshan more
    local phase = X.GetGamePhase()
    if phase == "early" then
        score = score - 0.2
    elseif phase == "late" then
        score = score + 0.15
    end

    -- Power advantage
    local balance = X.GetTeamPowerBalance()
    if balance.advantage == "strong" then
        score = score + 0.1
    elseif balance.advantage == "weak" or balance.advantage == "desperate" then
        score = score - 0.2
    end

    if score < 0 then score = 0 end
    if score > 1 then score = 1 end
    return score
end

-- Score: should the team defend?
function X.ScoreDefendObjective()
    local score = 0

    -- Check if enemies are pushing our towers
    local enemiesPushing = false
    local ok, _ = pcall(function()
        for _, lane in pairs({LANE_TOP, LANE_MID, LANE_BOT}) do
            local amount = GetLaneFrontAmount(GetOpposingTeam(), lane, false)
            if amount ~= nil and amount > 0.6 then
                enemiesPushing = true
                score = score + 0.3  -- Getting deep
            elseif amount ~= nil and amount > 0.4 then
                enemiesPushing = true
                score = score + 0.2
            end
        end
    end)

    -- Check if enemy heroes are near our towers
    if enemyIDs ~= nil then
        for _, id in pairs(enemyIDs) do
            local state = enemyState[id]
            if state ~= nil and state.isAlive and state.timeMissing < 5 and state.lastLocation ~= nil then
                -- Check distance to our ancient
                local ancientOk, ancient = pcall(function() return GetAncient(GetTeam()) end)
                if ancientOk and ancient ~= nil then
                    local distOk, dist = pcall(function()
                        return VectorDistance(state.lastLocation, ancient:GetLocation())
                    end)
                    if distOk and dist ~= nil and dist < 4000 then
                        score = score + 0.4  -- Enemy near our base
                    end
                end
            end
        end
    end

    -- More allies dead = harder to defend, but more important
    local aliveAllies = X.GetAliveAllyCount()
    if aliveAllies <= 2 then
        if enemiesPushing then
            score = score + 0.2  -- Desperate defense
        else
            score = score - 0.2  -- Can't defend with 2 heroes
        end
    end

    if score < 0 then score = 0 end
    if score > 1 then score = 1 end
    return score
end

-- Determine best lane for push/defend objectives
local function GetBestPushLane()
    local bestLane = nil
    local bestAmount = 0

    local ok, _ = pcall(function()
        for _, lane in pairs({LANE_TOP, LANE_MID, LANE_BOT}) do
            local amount = GetLaneFrontAmount(GetTeam(), lane, false)
            if amount ~= nil and amount > bestAmount then
                bestAmount = amount
                bestLane = lane
            end
        end
    end)

    return bestLane
end

local function GetMostThreatenedLane()
    local worstLane = nil
    local worstAmount = 0

    local ok, _ = pcall(function()
        for _, lane in pairs({LANE_TOP, LANE_MID, LANE_BOT}) do
            local amount = GetLaneFrontAmount(GetOpposingTeam(), lane, false)
            if amount ~= nil and amount > worstAmount then
                worstAmount = amount
                worstLane = lane
            end
        end
    end)

    return worstLane
end

function X.EvaluateTeamObjective()
    local scores = {
        farm   = X.ScoreFarmObjective(),
        push   = X.ScorePushObjective(),
        gank   = X.ScoreGankObjective(),
        roshan = X.ScoreRoshanObjective(),
        defend = X.ScoreDefendObjective(),
    }

    -- Find best objective
    local best = "farm"
    local bestScore = 0
    for obj, s in pairs(scores) do
        if s > bestScore then
            bestScore = s
            best = obj
        end
    end

    teamObjective.type = best
    teamObjective.confidence = bestScore
    teamObjective.setTime = DotaTime()

    -- Set lane context for push/defend
    if best == "push" then
        teamObjective.lane = GetBestPushLane()
    elseif best == "defend" then
        teamObjective.lane = GetMostThreatenedLane()
    else
        teamObjective.lane = nil
    end

    teamObjective.target = nil

    SafeLog("debug", CATEGORY,
        "Objective: " .. best
        .. " (score=" .. string.format("%.2f", bestScore) .. ")"
        .. " farm=" .. string.format("%.2f", scores.farm)
        .. " push=" .. string.format("%.2f", scores.push)
        .. " gank=" .. string.format("%.2f", scores.gank)
        .. " rosh=" .. string.format("%.2f", scores.roshan)
        .. " def=" .. string.format("%.2f", scores.defend)
    )
end

function X.GetTeamObjective()
    return teamObjective
end

function X.GetObjectiveScores()
    return {
        farm   = X.ScoreFarmObjective(),
        push   = X.ScorePushObjective(),
        gank   = X.ScoreGankObjective(),
        roshan = X.ScoreRoshanObjective(),
        defend = X.ScoreDefendObjective(),
    }
end

--------------------------------------------------------------------
-- E. Think Function
--------------------------------------------------------------------
function X.Think()
    local now = DotaTime()
    if now < 0 then return end  -- Skip pre-game

    -- Update enemy tracking (internally throttled to 0.5s)
    X.UpdateEnemyTracking()

    -- Evaluate team objective every 5 seconds
    if now - (X._lastObjectiveEval or -999) > 5 then
        X._lastObjectiveEval = now
        X.EvaluateTeamObjective()
    end
end

return X
