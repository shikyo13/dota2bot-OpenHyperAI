--------------------------------------------------------------------
-- aba_comms.lua  –  Bot Intelligence & Communication System
--
-- Handles:
--   1. Chat command parsing (!ward, !deward, !gank, !push, etc.)
--   2. Ping interpretation (context-sensitive: focus vs gank)
--   3. Bot announcements with per-type cooldowns
--   4. Warding / dewarding mission state
--   5. TP-rescue evaluation
--   6. Gank target coordination
--------------------------------------------------------------------

local X = {}

local J     -- set lazily via X.Init()
local W     -- ward utility, set lazily

--------------------------------------------------------------------
-- Logging
--------------------------------------------------------------------
X.LOG_ENABLED = true   -- set to false to silence all [COMMS] output
X.LOG_VERBOSE = false  -- set to true for extra detail (desire values, ping data, etc.)

local function Log(msg)
	if X.LOG_ENABLED then
		print("[COMMS] " .. tostring(msg))
	end
end

local function LogVerbose(msg)
	if X.LOG_ENABLED and X.LOG_VERBOSE then
		print("[COMMS] " .. tostring(msg))
	end
end

-- Expose so mode scripts can log through the same system
function X.Log(msg) Log(msg) end
function X.LogVerbose(msg) LogVerbose(msg) end

--------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------
local COMMAND_EXPIRE_TIME     = 30      -- seconds before a command goes stale
local MISSION_TIMEOUT         = 60      -- warding mission hard timeout
local PING_COMBAT_RADIUS      = 1600    -- if pinged enemy is within this of a teamfight → focus
local ANNOUNCE_COOLDOWNS = {
	on_my_way  = 15,
	missing    = 30,
	retreat    = 10,
	need_help  = 12,
	ganking    = 20,
	warding    = 20,
	back       = 10,
}

--------------------------------------------------------------------
-- State  (module-level, shared across all bots on the team)
--------------------------------------------------------------------
local bInitDone          = false
local currentCommand     = nil    -- {type, lane, location, target_id, time, source}
local announceCooldowns  = {}     -- ["on_my_way"] = last DotaTime()
local wardingMissions    = {}     -- [playerID] = {active, type, startTime, spots, spotIdx}
local lastPingCheck      = -999
local lastPingData       = nil

--------------------------------------------------------------------
-- Chat command dispatch table
--------------------------------------------------------------------
local COMMAND_ALIASES = {
	["!ward"]    = "ward_obs",
	["!w"]       = "ward_obs",
	["!deward"]  = "deward",
	["!dw"]      = "deward",
	["!gank"]    = "gank",
	["!g"]       = "gank",
	["!push"]    = "push",
	["!def"]     = "defend",
	["!defend"]  = "defend",
	["!rosh"]    = "roshan",
	["!roshan"]  = "roshan",
	["!back"]    = "retreat",
	["!b"]       = "retreat",
	["!smoke"]   = "smoke",
	["!help"]    = "help",
	["!h"]       = "help",
}

local LANE_ALIASES = {
	["top"]  = LANE_TOP,
	["mid"]  = LANE_MID,
	["bot"]  = LANE_BOT,
	["bottom"] = LANE_BOT,
}

--------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------
local function ParseLane(text)
	if text == nil then return nil end
	local lower = string.lower(text)
	return LANE_ALIASES[lower]
end

local function IsSupport(bot)
	if J == nil then return false end
	local pos = J.GetPosition(bot)
	return pos >= 4
end

local function IsGanker(bot)
	if J == nil then return false end
	local pos = J.GetPosition(bot)
	return pos == 2 or pos == 4
end

local function GetHumanPlayer()
	for i = 1, #GetTeamPlayers(GetTeam()) do
		local member = GetTeamMember(i)
		if member ~= nil and not member:IsBot() and member:IsAlive() then
			return member
		end
	end
	return nil
end

local function GetHumanPlayerID()
	for _, id in pairs(GetTeamPlayers(GetTeam())) do
		if not IsPlayerBot(id) then
			return id
		end
	end
	return nil
end

local function ShouldBotRespondToCommand(bot, cmdType)
	if cmdType == "ward_obs" or cmdType == "deward" then
		return IsSupport(bot)
	elseif cmdType == "gank" or cmdType == "smoke" then
		return IsGanker(bot)
	elseif cmdType == "help" then
		-- nearest bots respond
		return true
	end
	-- push, defend, roshan, retreat → all bots
	return true
end

--------------------------------------------------------------------
-- Chat Callback
--------------------------------------------------------------------
local function OnChatMessage(tChat)
	if tChat == nil then return end
	if tChat.team_only == false then return end  -- ignore all-chat

	local senderId = tChat.player_id
	if IsPlayerBot(senderId) then return end  -- ignore bot messages

	local msg = tChat.string
	if msg == nil or string.sub(msg, 1, 1) ~= "!" then return end

	-- Split message: "!gank top" → {"!gank", "top"}
	local parts = {}
	for word in string.gmatch(msg, "%S+") do
		table.insert(parts, string.lower(word))
	end

	local cmd = parts[1]
	local cmdType = COMMAND_ALIASES[cmd]
	if cmdType == nil then return end

	local lane = ParseLane(parts[2])

	-- Build command object
	local command = {
		type      = cmdType,
		lane      = lane,
		location  = nil,
		target_id = nil,
		time      = DotaTime(),
		source    = "chat",
	}

	-- For help command, try to get human's location
	if cmdType == "help" then
		local human = GetHumanPlayer()
		if human ~= nil then
			command.location = human:GetLocation()
		end
	end

	currentCommand = command
	Log("Command received: '" .. msg .. "' → type=" .. cmdType .. (lane ~= nil and (", lane=" .. tostring(lane)) or ""))

	-- Trigger ward/deward missions for supports
	if cmdType == "ward_obs" or cmdType == "deward" then
		for i = 1, #GetTeamPlayers(GetTeam()) do
			local member = GetTeamMember(i)
			if member ~= nil and member:IsBot() and IsSupport(member) then
				if cmdType == "ward_obs" then
					X.StartWardingMission(member)
				else
					X.StartDewardingMission(member)
				end
			end
		end
	end
end

--------------------------------------------------------------------
-- Ping Interpreter
--------------------------------------------------------------------
local function InterpretPings()
	local now = DotaTime()
	if now - lastPingCheck < 0.2 then return end
	lastPingCheck = now

	local human = GetHumanPlayer()
	if human == nil then return end

	local ping = human:GetMostRecentPing()
	if ping == nil then return end
	if ping.time == nil then return end

	-- Avoid re-processing same ping
	if lastPingData ~= nil and lastPingData.time == ping.time then return end
	lastPingData = ping

	-- Only process recent pings (within 2 seconds)
	if GameTime() - ping.time > 2.0 then return end

	local pingLoc = Vector(ping.location_x, ping.location_y, 0)
	local isNormalPing = ping.normal_ping
	local isAlertPing = not isNormalPing

	-- Check if ping is near an enemy hero
	local pingOnEnemy = nil
	local enemies = GetUnitList(UNIT_LIST_ENEMY_HEROES)
	for _, enemy in pairs(enemies) do
		if J.IsValidHero(enemy) and J.GetDistance(enemy:GetLocation(), pingLoc) < 400 then
			pingOnEnemy = enemy
			break
		end
	end

	if pingOnEnemy ~= nil then
		-- Context: are we in a teamfight near the ping?
		local nearbyAllies = J.GetAlliesNearLoc(pingLoc, PING_COMBAT_RADIUS)
		local nearbyEnemies = J.GetEnemiesNearLoc(pingLoc, PING_COMBAT_RADIUS)
		local inCombat = #nearbyAllies >= 2 and #nearbyEnemies >= 2

		if inCombat then
			-- FOCUS TARGET — set as priority attack target
			currentCommand = {
				type      = "focus",
				lane      = nil,
				location  = pingOnEnemy:GetLocation(),
				target_id = pingOnEnemy:GetPlayerID(),
				time      = DotaTime(),
				source    = "ping",
			}
			Log("Ping on enemy " .. pingOnEnemy:GetUnitName() .. " IN COMBAT → focus target")
		else
			-- GANK REQUEST — boost roam desire to that hero
			currentCommand = {
				type      = "gank",
				lane      = nil,
				location  = pingOnEnemy:GetLocation(),
				target_id = pingOnEnemy:GetPlayerID(),
				time      = DotaTime(),
				source    = "ping",
			}
			Log("Ping on enemy " .. pingOnEnemy:GetUnitName() .. " OUT OF COMBAT → gank request")
		end
		return
	end

	-- Check if ping is near Roshan
	local roshanLoc = J.GetCurrentRoshanLocation()
	if roshanLoc ~= nil and J.GetDistance(pingLoc, roshanLoc) < 1200 then
		currentCommand = {
			type      = "roshan",
			lane      = nil,
			location  = roshanLoc,
			target_id = nil,
			time      = DotaTime(),
			source    = "ping",
		}
		Log("Ping near Roshan → roshan command")
		return
	end

	-- Existing ping behavior (tower defense/push) is preserved in the mode scripts
	-- We don't override those here
end

--------------------------------------------------------------------
-- Init (call once per game)
--------------------------------------------------------------------
function X.Init()
	if bInitDone then return end
	bInitDone = true

	-- Lazy-load J and W to avoid circular require issues
	J = require(GetScriptDirectory()..'/FunLib/jmz_func')
	W = require(GetScriptDirectory()..'/FunLib/aba_ward_utility')

	-- Install our chat callback
	InstallChatCallback(function(tChat) OnChatMessage(tChat) end)
	Log("Initialized — chat callback installed, LOG_VERBOSE=" .. tostring(X.LOG_VERBOSE))
end

--------------------------------------------------------------------
-- Think (called from mode scripts, cached at 0.2s)
--------------------------------------------------------------------
function X.Think()
	if not bInitDone then X.Init() end
	InterpretPings()
end

--------------------------------------------------------------------
-- Command Query API
--------------------------------------------------------------------
function X.GetCurrentCommand()
	if currentCommand == nil then return nil end
	if DotaTime() - currentCommand.time > COMMAND_EXPIRE_TIME then
		currentCommand = nil
		return nil
	end
	return currentCommand
end

function X.IsCommandFresh(maxAge)
	local cmd = X.GetCurrentCommand()
	if cmd == nil then return false end
	return DotaTime() - cmd.time <= (maxAge or 15)
end

function X.GetCommandType()
	local cmd = X.GetCurrentCommand()
	if cmd == nil then return nil end
	return cmd.type
end

function X.ClearCommand()
	currentCommand = nil
end

--------------------------------------------------------------------
-- Warding Mission System
--------------------------------------------------------------------
function X.StartWardingMission(bot)
	if not bInitDone then X.Init() end
	local pid = bot:GetPlayerID()
	local spots = {}
	if W ~= nil then
		spots = W.GetAvailabeObserverWardSpots(bot) or {}
	end
	wardingMissions[pid] = {
		active    = true,
		type      = "obs",
		startTime = DotaTime(),
		spots     = spots,
		spotIdx   = 1,
	}
	Log(bot:GetUnitName() .. " started WARD mission (" .. #spots .. " spots)")
	X.Announce(bot, "warding", "Warding")
end

function X.StartDewardingMission(bot)
	if not bInitDone then X.Init() end
	local pid = bot:GetPlayerID()
	local spots = {}
	if W ~= nil and W.GetEnemyLikelyObsSpots then
		spots = W.GetEnemyLikelyObsSpots(bot) or {}
	end
	wardingMissions[pid] = {
		active    = true,
		type      = "sentry",
		startTime = DotaTime(),
		spots     = spots,
		spotIdx   = 1,
	}
	Log(bot:GetUnitName() .. " started DEWARD mission (" .. #spots .. " spots)")
	X.Announce(bot, "warding", "Dewarding")
end

function X.IsOnWardingMission(bot)
	local pid = bot:GetPlayerID()
	local m = wardingMissions[pid]
	if m == nil or not m.active then return false end
	-- Timeout check
	if DotaTime() - m.startTime > MISSION_TIMEOUT then
		m.active = false
		return false
	end
	return true
end

function X.GetMissionTarget(bot)
	local pid = bot:GetPlayerID()
	local m = wardingMissions[pid]
	if m == nil or not m.active then return nil end

	-- Advance past already-visited spots
	while m.spotIdx <= #m.spots do
		local spot = m.spots[m.spotIdx]
		if spot ~= nil and spot.location ~= nil then
			return spot
		end
		m.spotIdx = m.spotIdx + 1
	end

	-- No more spots
	m.active = false
	return nil
end

function X.AdvanceMissionSpot(bot)
	local pid = bot:GetPlayerID()
	local m = wardingMissions[pid]
	if m == nil then return end
	m.spotIdx = m.spotIdx + 1
	if m.spotIdx > #m.spots then
		m.active = false
		Log(bot:GetUnitName() .. " completed " .. m.type .. " mission (all spots done)")
	else
		LogVerbose(bot:GetUnitName() .. " advancing to spot " .. m.spotIdx .. "/" .. #m.spots)
	end
end

function X.GetMissionType(bot)
	local pid = bot:GetPlayerID()
	local m = wardingMissions[pid]
	if m == nil then return nil end
	return m.type
end

function X.EndMission(bot)
	local pid = bot:GetPlayerID()
	if wardingMissions[pid] ~= nil then
		wardingMissions[pid].active = false
	end
end

--------------------------------------------------------------------
-- Announcement System (with per-type cooldowns)
--------------------------------------------------------------------
function X.Announce(bot, announceType, message)
	local now = DotaTime()
	local cd = ANNOUNCE_COOLDOWNS[announceType] or 15
	local lastTime = announceCooldowns[announceType] or -999

	if now - lastTime < cd then return false end

	announceCooldowns[announceType] = now
	bot:ActionImmediate_Chat(message, true)
	LogVerbose(bot:GetUnitName() .. " announced: " .. message)
	return true
end

function X.AnnounceOnMyWay(bot, dest)
	if X.Announce(bot, "on_my_way", "On my way!") then
		if dest ~= nil then
			bot:ActionImmediate_Ping(dest.x, dest.y, false)
		end
		return true
	end
	return false
end

function X.AnnounceMissing(bot, lane)
	local laneNames = { [LANE_TOP] = "Top", [LANE_MID] = "Mid", [LANE_BOT] = "Bot" }
	local laneName = laneNames[lane] or "Lane"
	-- Per-lane cooldown key
	local key = "missing_" .. tostring(lane)
	local now = DotaTime()
	local lastTime = announceCooldowns[key] or -999
	if now - lastTime < 30 then return false end
	announceCooldowns[key] = now
	bot:ActionImmediate_Chat(laneName .. " missing!", true)
	return true
end

function X.AnnounceRetreat(bot, loc)
	if X.Announce(bot, "retreat", "Back!") then
		if loc ~= nil then
			bot:ActionImmediate_Ping(loc.x, loc.y, true)
		end
		return true
	end
	return false
end

function X.AnnounceNeedHelp(bot)
	local loc = bot:GetLocation()
	if X.Announce(bot, "need_help", "Help!") then
		bot:ActionImmediate_Ping(loc.x, loc.y, true)
		return true
	end
	return false
end

function X.AnnounceGanking(bot, lane)
	local laneNames = { [LANE_TOP] = "top", [LANE_MID] = "mid", [LANE_BOT] = "bot" }
	local laneName = laneNames[lane] or ""
	return X.Announce(bot, "ganking", "Ganking " .. laneName)
end

function X.AnnounceWarding(bot)
	return X.Announce(bot, "warding", "Going to ward")
end

--------------------------------------------------------------------
-- TP Rescue Evaluation
--------------------------------------------------------------------
function X.ShouldTPToSave(bot, ally)
	if J == nil then return false end
	if ally == nil or not J.IsValidHero(ally) then return false end
	if not ally:IsAlive() or ally:IsIllusion() then return false end

	-- Don't TP if in our own fight
	if J.IsInTeamFight(bot, 1200) then return false end

	-- Ally must be outnumbered and taking damage
	local allyLoc = ally:GetLocation()
	local nearbyEnemies = J.GetEnemiesNearLoc(allyLoc, 1200)
	local nearbyAllies  = J.GetAlliesNearLoc(allyLoc, 1200)
	if #nearbyEnemies == 0 then return false end
	if #nearbyAllies >= #nearbyEnemies then return false end
	if not ally:WasRecentlyDamagedByAnyHero(3.0) then return false end

	-- Ally HP must be above 15% (not already dead)
	if J.GetHP(ally) < 0.15 then return false end

	-- Bot must have TP
	local tp = J.Utils.GetItemFromFullInventory(bot, 'item_tpscroll')
	if tp == nil or not tp:IsFullyCastable() then return false end

	-- Role-based delay: supports respond instantly, cores wait
	local pos = J.GetPosition(bot)
	local roleDelay = 0
	if pos <= 1 then roleDelay = 3.0
	elseif pos <= 3 then roleDelay = 1.5
	end

	-- Check if we haven't already been waiting to TP
	if bot.commsTPWaitStart == nil then
		bot.commsTPWaitStart = DotaTime()
	end
	if DotaTime() - bot.commsTPWaitStart < roleDelay then
		return false
	end
	bot.commsTPWaitStart = nil
	Log(bot:GetUnitName() .. " TP rescue approved for " .. ally:GetUnitName() .. " (HP=" .. string.format("%.0f%%", J.GetHP(ally)*100) .. ")")
	return true
end

function X.GetBestTPTarget(bot)
	if J == nil then return nil end
	local bestAlly = nil
	local bestScore = 0

	for i = 1, #GetTeamPlayers(GetTeam()) do
		local member = GetTeamMember(i)
		if member ~= nil and member ~= bot and member:IsAlive()
		and not member:IsIllusion() and member:WasRecentlyDamagedByAnyHero(3.0) then
			local hp = J.GetHP(member)
			local nearbyEnemies = J.GetEnemiesNearLoc(member:GetLocation(), 1200)
			if #nearbyEnemies >= 1 and hp > 0.15 and hp < 0.6 then
				-- Score: lower HP = higher priority, human > carry > support
				local score = (1 - hp) * 10
				if not member:IsBot() then score = score + 20 end  -- human priority
				local pos = J.GetPosition(member)
				if pos <= 2 then score = score + 5 end  -- carry priority

				if score > bestScore then
					bestScore = score
					bestAlly = member
				end
			end
		end
	end

	return bestAlly
end

--------------------------------------------------------------------
-- Gank Target Coordination
--------------------------------------------------------------------
function X.GetBestGankTarget(bot, radius)
	if J == nil then return nil end
	radius = radius or 99999

	-- 1. Chat/ping commanded target
	local cmd = X.GetCurrentCommand()
	if cmd ~= nil and cmd.target_id ~= nil and (cmd.type == "gank" or cmd.type == "focus") then
		local enemies = GetUnitList(UNIT_LIST_ENEMY_HEROES)
		for _, enemy in pairs(enemies) do
			if J.IsValidHero(enemy) and enemy:GetPlayerID() == cmd.target_id then
				if GetUnitToUnitDistance(bot, enemy) <= radius or radius >= 99999 then
					return enemy
				end
			end
		end
	end

	-- 2. Closest low-HP overextended enemy
	local bestTarget = nil
	local bestScore  = 0
	local enemies = bot:GetNearbyHeroes(radius, true, BOT_MODE_NONE)
	if enemies ~= nil then
		for _, enemy in pairs(enemies) do
			if J.IsValidHero(enemy) and J.CanBeAttacked(enemy) then
				local hp = J.GetHP(enemy)
				local distFromFountain = J.GetDistanceFromAncient(enemy, false)
				-- Lower HP + farther from safety = better target
				local score = (1 - hp) * 5 + (distFromFountain / 3000)
				if score > bestScore then
					bestScore  = score
					bestTarget = enemy
				end
			end
		end
	end

	return bestTarget
end

--------------------------------------------------------------------
-- Focus Target (ping in combat)
--------------------------------------------------------------------
function X.GetFocusTarget(bot)
	local cmd = X.GetCurrentCommand()
	if cmd == nil or cmd.type ~= "focus" then return nil end
	if DotaTime() - cmd.time > 8 then return nil end  -- focus expires quickly

	local enemies = GetUnitList(UNIT_LIST_ENEMY_HEROES)
	for _, enemy in pairs(enemies) do
		if J.IsValidHero(enemy) and enemy:GetPlayerID() == cmd.target_id then
			if GetUnitToUnitDistance(bot, enemy) <= 2000 then
				return enemy
			end
		end
	end
	return nil
end

return X
