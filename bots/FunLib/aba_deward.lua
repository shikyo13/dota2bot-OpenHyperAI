local X = {}

local J  -- lazy loaded
local W  -- aba_ward_utility (lazy)

--------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------
local SENTRY_RANGE          = 900   -- sentry true sight radius
local SENTRY_CAST_RANGE     = 500   -- how close bot must be to plant
local DEWARD_CHECK_INTERVAL = 8     -- seconds between full scans
local WARD_PROXIMITY_MERGE  = 150   -- merge wards closer than this
local OBSERVER_DURATION     = 360
local MAX_DEWARD_DISTANCE   = 4000  -- don't deward if target is farther

--------------------------------------------------------------------
-- State (shared across all bots via module-level tables)
--------------------------------------------------------------------
local lastDewardCheck = -999
local knownEnemyWards = {}   -- { location, firstSeen, handle, wardType }
local dewardAssignments = {} -- playerID -> target location (prevents double-up)

--------------------------------------------------------------------
-- Lazy loaders
--------------------------------------------------------------------
local function EnsureJ()
    if J == nil then
        local ok, mod = pcall(require, GetScriptDirectory()..'/FunLib/jmz_func')
        if ok and mod then J = mod end
    end
    return J ~= nil
end

local function EnsureW()
    if W == nil then
        local ok, mod = pcall(require, GetScriptDirectory()..'/FunLib/aba_ward_utility')
        if ok and mod then W = mod end
    end
    return W ~= nil
end

--------------------------------------------------------------------
-- Core: Scan for visible enemy wards
--------------------------------------------------------------------
function X.ScanForEnemyWards()
    local now = DotaTime()
    if now < 0 then return end
    if now - lastDewardCheck < DEWARD_CHECK_INTERVAL then return end
    lastDewardCheck = now

    local enemyWards = GetUnitList(UNIT_LIST_ENEMY_WARDS)
    if enemyWards == nil then return end

    for _, ward in pairs(enemyWards) do
        if ward ~= nil and ward:IsAlive() then
            local loc = ward:GetLocation()
            if loc ~= nil then
                local isNew = true
                for _, known in pairs(knownEnemyWards) do
                    if known.location ~= nil
                    and GetUnitToLocationDistance(ward, known.location) < WARD_PROXIMITY_MERGE
                    then
                        -- Update handle in case it changed
                        known.handle = ward
                        isNew = false
                        break
                    end
                end
                if isNew then
                    local wType = "observer"
                    if string.find(ward:GetUnitName(), "sentry") then
                        wType = "sentry"
                    end
                    table.insert(knownEnemyWards, {
                        location  = loc,
                        firstSeen = now,
                        handle    = ward,
                        wardType  = wType,
                    })
                    if EnsureJ() and J.Log ~= nil then
                        J.Log.Info("DEWARD", "Enemy " .. wType .. " ward spotted")
                    end
                end
            end
        end
    end

    -- Clean up destroyed/expired wards
    for i = #knownEnemyWards, 1, -1 do
        local w = knownEnemyWards[i]
        if w.handle == nil
        or not w.handle:IsAlive()
        or now - w.firstSeen > OBSERVER_DURATION + 60  -- generous timeout
        then
            table.remove(knownEnemyWards, i)
        end
    end
end

--------------------------------------------------------------------
-- Get predicted deward spots based on game phase
--------------------------------------------------------------------
function X.GetPredictedDewardSpots(team)
    local spots = {}
    local now = DotaTime()

    -- Use aba_ward_utility's comprehensive enemy ward spot database
    if EnsureW() and W.GetEnemyLikelyObsSpots then
        local bot = GetBot()
        if bot ~= nil then
            local utilitySpots = W.GetEnemyLikelyObsSpots(bot)
            if utilitySpots ~= nil then
                for _, spot in pairs(utilitySpots) do
                    if spot.location ~= nil then
                        table.insert(spots, {
                            location = spot.location,
                            priority = 0.7,
                            source   = "ward_utility",
                        })
                    end
                end
            end
        end
    end

    -- Phase-based high-priority spots
    if now < 10 * 60 then
        -- Early game: rune vision wards
        table.insert(spots, { location = Vector(-2350, 1810, 256),  priority = 0.85, source = "rune_top" })
        table.insert(spots, { location = Vector(2950, -2600, 256),  priority = 0.85, source = "rune_bot" })
        -- Common mid-lane observer spots
        table.insert(spots, { location = Vector(-500, 2370, 256),   priority = 0.75, source = "mid_high" })
        table.insert(spots, { location = Vector(860, 1690, 256),    priority = 0.75, source = "mid_river" })
    elseif now < 25 * 60 then
        -- Mid game: jungle entries and Roshan
        table.insert(spots, { location = Vector(-2000, 1500, 256),  priority = 0.9,  source = "roshan" })
        if team == TEAM_RADIANT then
            table.insert(spots, { location = Vector(-4330, -1040, 256), priority = 0.8, source = "rad_jungle" })
            table.insert(spots, { location = Vector(4610, 760, 256),    priority = 0.7, source = "dire_tri" })
        else
            table.insert(spots, { location = Vector(4610, 760, 256),    priority = 0.8, source = "dire_jungle" })
            table.insert(spots, { location = Vector(-4330, -1040, 256), priority = 0.7, source = "rad_tri" })
        end
    else
        -- Late game: high ground and ancient approaches
        table.insert(spots, { location = Vector(-2000, 1500, 256),  priority = 0.95, source = "roshan_late" })
        if team == TEAM_RADIANT then
            table.insert(spots, { location = Vector(3430, 960, 256),   priority = 0.85, source = "dire_hg_mid" })
            table.insert(spots, { location = Vector(4580, 2900, 256),  priority = 0.8,  source = "dire_hg_top" })
            table.insert(spots, { location = Vector(5370, 1200, 256),  priority = 0.8,  source = "dire_hg_bot" })
        else
            table.insert(spots, { location = Vector(-3540, -510, 256),  priority = 0.85, source = "rad_hg_mid" })
            table.insert(spots, { location = Vector(-4200, 360, 256),   priority = 0.8,  source = "rad_hg_top" })
            table.insert(spots, { location = Vector(-1290, -4350, 256), priority = 0.8,  source = "rad_hg_bot" })
        end
    end

    return spots
end

--------------------------------------------------------------------
-- Should this bot deward? Returns (shouldDeward, targetLocation)
--------------------------------------------------------------------
function X.ShouldDeward(bot)
    if bot == nil or not bot:IsAlive() then return false, nil end
    if not EnsureJ() then return false, nil end

    local pos = J.GetPosition(bot)
    if pos == nil or pos < 4 then return false, nil end  -- only supports deward

    -- Safety: don't deward while in danger
    if bot:WasRecentlyDamagedByAnyHero(3.0) then return false, nil end

    local pid = bot:GetPlayerID()

    -- 1. Known VISIBLE enemy wards (highest priority -- we can see them)
    X.ScanForEnemyWards()
    for _, ward in pairs(knownEnemyWards) do
        if ward.handle ~= nil and ward.handle:IsAlive() and ward.location ~= nil then
            local dist = GetUnitToLocationDistance(bot, ward.location)
            if dist < MAX_DEWARD_DISTANCE then
                -- Check no other bot is already assigned to this ward
                local alreadyAssigned = false
                for otherPid, assignedLoc in pairs(dewardAssignments) do
                    if otherPid ~= pid
                    and assignedLoc ~= nil
                    and J.GetDistance(assignedLoc, ward.location) < WARD_PROXIMITY_MERGE
                    then
                        alreadyAssigned = true
                        break
                    end
                end
                if not alreadyAssigned then
                    dewardAssignments[pid] = ward.location
                    return true, ward.location
                end
            end
        end
    end

    -- 2. Commanded deward: check if there's an active deward command
    if J.Comms ~= nil then
        local cmd = J.Comms.GetCurrentCommand()
        if cmd ~= nil and cmd.type == "deward" and J.Comms.IsCommandFresh(30) then
            local spots = X.GetPredictedDewardSpots(GetTeam())
            if #spots > 0 then
                -- Sort by priority then distance
                table.sort(spots, function(a, b)
                    if a.priority ~= b.priority then
                        return a.priority > b.priority
                    end
                    return GetUnitToLocationDistance(bot, a.location) < GetUnitToLocationDistance(bot, b.location)
                end)
                local bestSpot = spots[1]
                if bestSpot ~= nil and bestSpot.location ~= nil then
                    dewardAssignments[pid] = bestSpot.location
                    return true, bestSpot.location
                end
            end
        end
    end

    -- 3. Autonomous: if bot has a sentry and is near a predicted spot, deward opportunistically
    if X.HasSentryWard(bot) and DotaTime() > 5 * 60 then
        local spots = X.GetPredictedDewardSpots(GetTeam())
        for _, spot in pairs(spots) do
            if spot.location ~= nil and spot.priority >= 0.8 then
                local dist = GetUnitToLocationDistance(bot, spot.location)
                if dist < 1500 then
                    dewardAssignments[pid] = spot.location
                    return true, spot.location
                end
            end
        end
    end

    -- Clear assignment if nothing found
    dewardAssignments[pid] = nil
    return false, nil
end

--------------------------------------------------------------------
-- Execute deward: walk to target and plant sentry
--------------------------------------------------------------------
function X.ExecuteDeward(bot, targetLocation)
    if bot == nil or targetLocation == nil then return false end

    local dist = GetUnitToLocationDistance(bot, targetLocation)

    -- Phase 1: Walk to target
    if dist > SENTRY_CAST_RANGE then
        bot:Action_MoveToLocation(targetLocation)
        return true  -- still in progress
    end

    -- Phase 2: Place sentry
    local sentry = X.GetSentryItem(bot)
    if sentry ~= nil then
        bot:Action_UseAbilityOnLocation(sentry, targetLocation)
        if EnsureJ() and J.Log ~= nil then
            local heroShort = string.gsub(bot:GetUnitName(), "npc_dota_hero_", "")
            J.Log.Info("DEWARD", heroShort .. " placing deward sentry")
        end
        -- Clear assignment after placing
        dewardAssignments[bot:GetPlayerID()] = nil
        return true
    end

    -- No sentry available
    dewardAssignments[bot:GetPlayerID()] = nil
    return false
end

--------------------------------------------------------------------
-- Inventory helpers
--------------------------------------------------------------------
function X.HasSentryWard(bot)
    if bot == nil then return false end
    for i = 0, 8 do
        local item = bot:GetItemInSlot(i)
        if item ~= nil and item:GetName() == "item_ward_sentry" then
            return true
        end
    end
    return false
end

function X.GetSentryItem(bot)
    if bot == nil then return nil end
    for i = 0, 8 do
        local item = bot:GetItemInSlot(i)
        if item ~= nil then
            local name = item:GetName()
            if name == "item_ward_sentry" then
                return item
            end
            -- Ward dispenser in sentry mode (toggle state false = sentry)
            -- TODO: Verify in-game that GetToggleState() == false means sentry mode
            if name == "item_ward_dispenser" and item:GetToggleState() == false then
                return item
            end
        end
    end
    return nil
end

--------------------------------------------------------------------
-- Accessors for other modules
--------------------------------------------------------------------
function X.GetKnownEnemyWards()
    return knownEnemyWards
end

function X.GetDewardAssignments()
    return dewardAssignments
end

function X.ClearAssignment(pid)
    dewardAssignments[pid] = nil
end

return X
