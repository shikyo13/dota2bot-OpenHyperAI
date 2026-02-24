--------------------------------------------------------------------
-- aba_comms.lua  -  Bot Intelligence & Communication System
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
-- Logging (delegates to centralized J.Log when available)
--------------------------------------------------------------------
local function Log(msg)
	if J ~= nil and J.Log ~= nil then
		J.Log.Info("COMMS", msg)
	else
		print("[COMMS] " .. tostring(msg))
	end
end

local function LogVerbose(msg)
	if J ~= nil and J.Log ~= nil then
		J.Log.Debug("COMMS", msg)
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
local PING_COMBAT_RADIUS      = 1600    -- if pinged enemy is within this of a teamfight -> focus
local ANNOUNCE_COOLDOWNS = {
	on_my_way  = 15,
	missing    = 30,
	retreat    = 10,
	need_help  = 12,
	ganking    = 20,
	warding    = 20,
	back       = 10,
	tp_rescue  = 15,
	item       = 30,
	danger     = 20,
}

local MISSING_THRESHOLD          = 18    -- seconds before announcing missing
local MISSING_ANNOUNCE_COOLDOWN  = 30    -- per-lane cooldown (already in AnnounceMissing)
local LANING_END_TIME            = 15 * 60  -- stop missing calls after 15 min

--------------------------------------------------------------------
-- State  (module-level, shared across all bots on the team)
--------------------------------------------------------------------
local bInitDone          = false
local currentCommand     = nil    -- {type, lane, location, target_id, time, source}
local announceCooldowns  = {}     -- ["pid_type"] = last DotaTime()
local wardingMissions    = {}     -- [playerID] = {active, type, startTime, spots, spotIdx}
local lastPingCheck      = -999
local lastPingData       = nil
local enemyLastSeen      = {}     -- [enemyPlayerID] = {time, location, lane}
local lastMissingCheck   = -999
local lastItemCounts     = {}     -- [playerID] = item count (for detecting new purchases)
local pendingAnnouncements = {}  -- [playerID] = { {message, allChat, pingLoc, pingDanger}, ... }
local tTPWaitStart = {}          -- [playerID] = DotaTime() when TP wait started

--------------------------------------------------------------------
-- Item display names for major item announcements (cost > 3000)
--------------------------------------------------------------------
local ITEM_DISPLAY_NAMES = {
	item_blink                  = "Blink Dagger",
	item_black_king_bar         = "BKB",
	item_monkey_king_bar        = "MKB",
	item_butterfly              = "Butterfly",
	item_heart                  = "Heart",
	item_satanic                = "Satanic",
	item_rapier                 = "Divine Rapier",
	item_assault                = "Assault Cuirass",
	item_desolator              = "Desolator",
	item_skadi                  = "Skadi",
	item_sheepstick             = "Scythe of Vyse",
	item_shivas_guard           = "Shiva's Guard",
	item_radiance               = "Radiance",
	item_manta                  = "Manta Style",
	item_abyssal_blade          = "Abyssal Blade",
	item_refresher              = "Refresher Orb",
	item_sphere                 = "Linken's Sphere",
	item_pipe                   = "Pipe of Insight",
	item_guardian_greaves        = "Guardian Greaves",
	item_bloodthorn             = "Bloodthorn",
	item_nullifier              = "Nullifier",
	item_silver_edge            = "Silver Edge",
	item_ethereal_blade         = "Ethereal Blade",
	item_dagon_5                = "Dagon 5",
	item_octarine_core          = "Octarine Core",
	item_aghanims_scepter       = "Aghanim's Scepter",
	item_travel_boots            = "Boots of Travel",
	item_travel_boots_2          = "Travels 2",
	item_overwhelming_blink     = "Overwhelming Blink",
	item_swift_blink            = "Swift Blink",
	item_arcane_blink           = "Arcane Blink",
	item_disperser              = "Disperser",
	item_harpoon                = "Harpoon",
	item_khanda                 = "Khanda",
	item_parasma                = "Parasma",
}

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

local function GetLaneFromLocation(loc)
	if loc == nil then return nil end
	local x, y = loc.x or 0, loc.y or 0
	-- Rough lane boundaries based on Dota 2 map geometry
	if y > 2000 or (x < -4000 and y > -1000) then
		return LANE_TOP
	elseif y < -2000 or (x > 4000 and y < 1000) then
		return LANE_BOT
	else
		return LANE_MID
	end
end

local function GetHumanPlayer()
	local teamPlayers = GetTeamPlayers(GetTeam())
	if teamPlayers == nil then return nil end
	for i = 1, #teamPlayers do
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
		return true  -- any bot can ward when commanded
	elseif cmdType == "gank" or cmdType == "smoke" then
		return IsGanker(bot)
	elseif cmdType == "help" then
		-- nearest bots respond
		return true
	end
	-- push, defend, roshan, retreat -> all bots
	return true
end

local function FindBestResponder(cmdType)
	local team = GetTeamPlayers(GetTeam())
	local bestBot = nil
	local bestPriority = 999

	for i = 1, #team do
		local member = GetTeamMember(i)
		if member ~= nil and member:IsBot() and member:IsAlive() then
			local pos = 3  -- default mid priority
			if J ~= nil then pos = J.GetPosition(member) or 3 end

			local priority = 99
			if cmdType == "gank" or cmdType == "smoke" then
				-- Prefer pos 2 (mid ganker) or pos 4 (roamer)
				if pos == 2 then priority = 1
				elseif pos == 4 then priority = 2
				elseif pos == 3 then priority = 3
				else priority = 10 end
			elseif cmdType == "ward_obs" or cmdType == "deward" then
				-- Prefer pos 5, then pos 4, then anyone
				if pos == 5 then priority = 1
				elseif pos == 4 then priority = 2
				elseif pos == 3 then priority = 5
				elseif pos == 2 then priority = 6
				else priority = 7 end
			else
				-- For push/defend/roshan/retreat/help: any alive bot, prefer cores
				priority = pos  -- pos 1 = highest priority, pos 5 = lowest
			end

			if priority < bestPriority then
				bestPriority = priority
				bestBot = member
			end
		end
	end

	return bestBot
end

--------------------------------------------------------------------
-- Chat Callback
--------------------------------------------------------------------
local function OnChatMessage(tChat)
	if tChat == nil then return end

	local senderId = tChat.player_id
	if IsPlayerBot(senderId) then return end  -- ignore bot messages

	local msg = tChat.string
	if msg == nil or string.sub(msg, 1, 1) ~= "!" then return end

	-- Non-command all-chat is ignored; ! commands are processed from any channel

	-- Split message: "!gank top" -> {"!gank", "top"}
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
	Log(">>> COMMAND RECEIVED: '" .. msg .. "' -> type=" .. cmdType .. (lane ~= nil and (", lane=" .. tostring(lane)) or ""))

	-- Acknowledge command to human player
	if cmdType == "ward_obs" or cmdType == "deward" then
		-- Acknowledgment -- mission announcements also fire below
		local responder = FindBestResponder(cmdType)
		if responder ~= nil then
			local wardMsg = cmdType == "ward_obs" and "Warding!" or "Dewarding!"
			X.Announce(responder, "warding", wardMsg)
		end
	else
		local responder = FindBestResponder(cmdType)
		if responder ~= nil then
			local laneNames = {[LANE_TOP] = "top", [LANE_MID] = "mid", [LANE_BOT] = "bot"}
			local laneName = lane and laneNames[lane] or ""

			if cmdType == "gank" then
				X.Announce(responder, "ganking", "Ganking " .. laneName .. "!")
			elseif cmdType == "push" then
				X.Announce(responder, "on_my_way", "Pushing " .. laneName .. "!")
			elseif cmdType == "defend" then
				X.Announce(responder, "on_my_way", "Defending " .. laneName .. "!")
			elseif cmdType == "roshan" then
				X.Announce(responder, "on_my_way", "Going Rosh!")
			elseif cmdType == "retreat" then
				X.Announce(responder, "back", "Falling back!")
			elseif cmdType == "smoke" then
				X.Announce(responder, "ganking", "Smoke gank!")
			elseif cmdType == "help" then
				X.Announce(responder, "on_my_way", "On my way!")
			end
		end
	end

	-- Chat echo the command acknowledgment
	if J ~= nil and J.Log ~= nil then
		local echoBot = FindBestResponder(cmdType)
		if echoBot ~= nil then
			J.Log.ChatEcho(echoBot, "Command received: " .. cmdType)
		end
	end

	-- Trigger ward/deward mission: prefer support, fallback to any alive bot
	if cmdType == "ward_obs" or cmdType == "deward" then
		local missionBot = FindBestResponder(cmdType)
		if missionBot ~= nil then
			if cmdType == "ward_obs" then
				X.StartWardingMission(missionBot)
			else
				X.StartDewardingMission(missionBot)
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

	local pingLoc = ping.location
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
			-- FOCUS TARGET -- set as priority attack target
			currentCommand = {
				type      = "focus",
				lane      = nil,
				location  = pingOnEnemy:GetLocation(),
				target_id = pingOnEnemy:GetPlayerID(),
				time      = DotaTime(),
				source    = "ping",
			}
			Log("Ping on enemy " .. pingOnEnemy:GetUnitName() .. " IN COMBAT -> focus target")
		else
			-- GANK REQUEST -- boost roam desire to that hero
			currentCommand = {
				type      = "gank",
				lane      = nil,
				location  = pingOnEnemy:GetLocation(),
				target_id = pingOnEnemy:GetPlayerID(),
				time      = DotaTime(),
				source    = "ping",
			}
			Log("Ping on enemy " .. pingOnEnemy:GetUnitName() .. " OUT OF COMBAT -> gank request")
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
		Log("Ping near Roshan -> roshan command")
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

	-- No game-state gate needed: Think() is only called from mode scripts
	-- which start during PRE_GAME. hero_selection.lua proves InstallChatCallback
	-- works before GAME_IN_PROGRESS. We want !ward to work during pre-game.

	-- Use pcall so errors don't silently kill the init chain
	local ok, err = pcall(function()
		-- Lazy-load J and W to avoid circular require issues
		J = require(GetScriptDirectory()..'/FunLib/jmz_func')
		W = require(GetScriptDirectory()..'/FunLib/aba_ward_utility')
		-- No InstallChatCallback here: SetReplyHumanTime (ability_item_usage_generic.lua)
		-- is the surviving callback and forwards ! commands to X.HandleChat.
	end)

	if ok then
		bInitDone = true
		print("[COMMS] Comms system initialized -- ! commands forwarded via SetReplyHumanTime")
	else
		-- Print error but DON'T set bInitDone -- will retry next tick
		print("[COMMS] *** INIT FAILED: " .. tostring(err) .. " -- will retry ***")
	end
end

--------------------------------------------------------------------
-- Missing Hero Tracking
--------------------------------------------------------------------
local function TrackMissingHeroes(bot)
	local now = DotaTime()
	local enemyTeam = GetOpposingTeam()
	local enemyIDs = GetTeamPlayers(enemyTeam)
	if enemyIDs == nil then return end

	for _, enemyID in pairs(enemyIDs) do
		local info = GetHeroLastSeenInfo(enemyID)
		if info ~= nil and info[1] ~= nil then
			local dInfo = info[1]
			local timeSinceSeen = dInfo.time_since_seen or 0
			local lastLoc = dInfo.location

			-- Update tracking
			if timeSinceSeen < 2 and lastLoc ~= nil then
				-- Enemy is visible, update last-seen
				enemyLastSeen[enemyID] = {
					time = now,
					location = lastLoc,
					lane = GetLaneFromLocation(lastLoc),
				}
			end

			-- Check for missing announcement
			local tracked = enemyLastSeen[enemyID]
			if tracked ~= nil and tracked.lane ~= nil then
				local elapsed = now - tracked.time
				if elapsed > MISSING_THRESHOLD and elapsed < MISSING_THRESHOLD + 10 then
					-- Only announce from a bot assigned to that lane
					local assignedLane = bot:GetAssignedLane()
					if assignedLane == tracked.lane then
						X.AnnounceMissing(bot, tracked.lane)
					end
				end
			end
		end
	end
end

--------------------------------------------------------------------
-- Danger Warning (2+ enemies missing heading toward a lane)
--------------------------------------------------------------------
local function CheckDangerWarnings(bot)
	local now = DotaTime()

	-- Count missing enemies per lane they were last seen in
	local missingPerLane = { [LANE_TOP] = 0, [LANE_MID] = 0, [LANE_BOT] = 0 }
	for _, data in pairs(enemyLastSeen) do
		if data.lane ~= nil and (now - data.time) > MISSING_THRESHOLD then
			missingPerLane[data.lane] = (missingPerLane[data.lane] or 0) + 1
		end
	end

	-- If 2+ enemies missing from one lane, warn the OTHER lanes
	for lane, count in pairs(missingPerLane) do
		if count >= 2 then
			local botLane = bot:GetAssignedLane()
			-- Warn if bot is NOT in the lane they disappeared from
			if botLane ~= nil and botLane ~= lane then
				local laneNames = { [LANE_TOP] = "top", [LANE_MID] = "mid", [LANE_BOT] = "bot" }
				local fromName = laneNames[lane] or "somewhere"
				local dangerKey = bot:GetPlayerID() .. "_danger_" .. tostring(botLane)
				local lastWarn = announceCooldowns[dangerKey] or -999
				if now - lastWarn >= 20 then
					announceCooldowns[dangerKey] = now
					X.Announce(bot, "danger", count .. " missing " .. fromName .. "! Care!")
				end
			end
		end
	end
end

--------------------------------------------------------------------
-- Flush queued announcements (only for GetBot(), one per tick)
--------------------------------------------------------------------
function X.FlushAnnouncements()
	local bot = GetBot()
	if bot == nil then return end
	local pid = bot:GetPlayerID()
	local queue = pendingAnnouncements[pid]
	if queue == nil or #queue == 0 then return end

	-- Process one announcement per tick to avoid spam
	local entry = table.remove(queue, 1)
	bot:ActionImmediate_Chat(entry.message, entry.allChat)
	if entry.pingLoc ~= nil then
		bot:ActionImmediate_Ping(entry.pingLoc.x, entry.pingLoc.y, entry.pingDanger or false)
	end
end

--------------------------------------------------------------------
-- Think (called from mode scripts, cached at 0.2s)
--------------------------------------------------------------------
function X.Think(bot)
	if not bInitDone then X.Init() end

	X.FlushAnnouncements()

	InterpretPings()

	-- The rest requires a valid bot and the game to be running
	if bot == nil or J == nil then return end
	local now = DotaTime()
	if now < 30 then return end  -- skip pre-game

	-- Throttle per-bot thinking to every 1s
	local thinkKey = bot:GetPlayerID() .. "_think"
	local lastThink = announceCooldowns[thinkKey] or -999
	if now - lastThink < 1.0 then return end
	announceCooldowns[thinkKey] = now

	-- === Missing hero tracking (laning phase only) ===
	if now < LANING_END_TIME then
		local ok2, err2 = pcall(function()
			TrackMissingHeroes(bot)
		end)
		if not ok2 then
			LogVerbose("TrackMissingHeroes error: " .. tostring(err2))
		end
	end

	-- === Danger warning: 2+ enemies missing from same lane ===
	if now < LANING_END_TIME then
		local ok3, err3 = pcall(function()
			CheckDangerWarnings(bot)
		end)
		if not ok3 then
			LogVerbose("CheckDangerWarnings error: " .. tostring(err3))
		end
	end
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
		Log(bot:GetUnitName() .. " ward mission timed out after " .. MISSION_TIMEOUT .. "s")
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
		X.AnnounceWardingComplete(bot)
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
	local key = bot:GetPlayerID() .. "_" .. announceType
	local lastTime = announceCooldowns[key] or -999

	if now - lastTime < cd then return false end

	announceCooldowns[key] = now

	local pid = bot:GetPlayerID()
	if pendingAnnouncements[pid] == nil then pendingAnnouncements[pid] = {} end
	table.insert(pendingAnnouncements[pid], {
		message = message,
		allChat = false,
		pingLoc = nil,
		pingDanger = false,
	})
	LogVerbose(bot:GetUnitName() .. " queued: " .. message)
	return true
end

function X.AnnounceOnMyWay(bot, dest)
	if X.Announce(bot, "on_my_way", "On my way!") then
		if dest ~= nil then
			local pid = bot:GetPlayerID()
			local q = pendingAnnouncements[pid]
			if q and #q > 0 then
				q[#q].pingLoc = dest
				q[#q].pingDanger = false
			end
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

	local pid = bot:GetPlayerID()
	if pendingAnnouncements[pid] == nil then pendingAnnouncements[pid] = {} end
	table.insert(pendingAnnouncements[pid], {
		message = laneName .. " missing!",
		allChat = false,
		pingLoc = nil,
		pingDanger = false,
	})
	return true
end

function X.AnnounceRetreat(bot, loc)
	if X.Announce(bot, "retreat", "Back!") then
		if loc ~= nil then
			local pid = bot:GetPlayerID()
			local q = pendingAnnouncements[pid]
			if q and #q > 0 then
				q[#q].pingLoc = loc
				q[#q].pingDanger = true
			end
		end
		return true
	end
	return false
end

function X.AnnounceNeedHelp(bot)
	local loc = bot:GetLocation()
	if X.Announce(bot, "need_help", "Help!") then
		local pid = bot:GetPlayerID()
		local q = pendingAnnouncements[pid]
		if q and #q > 0 then
			q[#q].pingLoc = loc
			q[#q].pingDanger = true
		end
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

function X.AnnounceTPRescue(bot, ally)
	local allyName = "ally"
	if ally ~= nil and ally.GetUnitName then
		allyName = string.gsub(ally:GetUnitName(), "npc_dota_hero_", "")
	end
	return X.Announce(bot, "on_my_way", "TP to save " .. allyName .. "!")
end

function X.AnnounceDefending(bot, lane)
	local laneNames = { [LANE_TOP] = "top", [LANE_MID] = "mid", [LANE_BOT] = "bot" }
	local laneName = laneNames[lane] or ""
	return X.Announce(bot, "on_my_way", "Defending " .. laneName)
end

function X.AnnounceWardingComplete(bot)
	return X.Announce(bot, "warding", "Warding done!")
end

function X.AnnounceObjective(bot, objType)
	if objType == "roshan" then
		return X.Announce(bot, "on_my_way", "Let's Rosh!")
	elseif objType == "tower" then
		return X.Announce(bot, "on_my_way", "Push now!")
	end
	return false
end

function X.AnnounceDanger(bot, message)
	return X.Announce(bot, "danger", message or "Danger!")
end

function X.AnnounceItemPurchase(bot, itemName)
	if bot == nil or itemName == nil then return false end
	-- Only announce items with a display name (major items)
	local displayName = ITEM_DISPLAY_NAMES[itemName]
	if displayName == nil then return false end
	local msg = "Got " .. displayName .. "!"
	if X.Announce(bot, "item", msg) then
		if J ~= nil and J.Log ~= nil then
			J.Log.ChatEcho(bot, msg)
		end
		return true
	end
	return false
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
	local pid = bot:GetPlayerID()
	if tTPWaitStart[pid] == nil then
		tTPWaitStart[pid] = DotaTime()
	end
	if DotaTime() - tTPWaitStart[pid] < roleDelay then
		return false
	end
	tTPWaitStart[pid] = nil
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
				local distFromFountain = J.GetDistanceFromAncient(enemy, true)
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
	-- Extend focus to 15s during active combat, 8s otherwise
	local maxAge = 8
	if J ~= nil and J.IsInTeamFight ~= nil and J.IsInTeamFight(bot, 1500) then
		maxAge = 15
	end
	if DotaTime() - cmd.time > maxAge then return nil end

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

-- Expose the chat handler so other scripts can forward messages
function X.HandleChat(tChat)
	OnChatMessage(tChat)
end

return X
