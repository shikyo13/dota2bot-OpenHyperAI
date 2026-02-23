--------------------------------------------------------------------
-- aba_log.lua  –  Centralized Logging & Debugging System
--
-- Provides:
--   1. Log levels: ERROR(1), WARN(2), INFO(3), DEBUG(4)
--   2. Category filtering: COMMS, ITEMS, STRATEGY, WARD, SUPPORT, LANING, MODE, GENERAL
--   3. Per-category level overrides
--   4. Chat echo for important events (throttled)
--   5. Periodic bot status dump
--   6. Lazy settings: works before J.Customize exists
--------------------------------------------------------------------

local X = {}

--------------------------------------------------------------------
-- Log levels
--------------------------------------------------------------------
local LEVEL_ERROR = 1
local LEVEL_WARN  = 2
local LEVEL_INFO  = 3
local LEVEL_DEBUG = 4

local LEVEL_NAMES = {
    [LEVEL_ERROR] = "ERROR",
    [LEVEL_WARN]  = "WARN",
    [LEVEL_INFO]  = "INFO",
    [LEVEL_DEBUG] = "DEBUG",
}

--------------------------------------------------------------------
-- Default settings (safe until LoadSettings is called)
--------------------------------------------------------------------
local settings = {
    Level = LEVEL_WARN,
    Categories = {},
    Chat_Echo = true,
    Status_Dump = true,
    Status_Dump_Interval = 5,
}

local lastStatusDumpTime = -999
local lastChatEchoTime = {}  -- [botPlayerID] = last echo time
local CHAT_ECHO_THROTTLE = 5  -- seconds between chat echoes per bot
local getPositionFn = nil  -- injected by jmz_func to avoid circular require

--------------------------------------------------------------------
-- Settings loader
--------------------------------------------------------------------
function X.LoadSettings(customize)
    if customize == nil then return end
    if customize.Log == nil then return end

    local log = customize.Log
    if log.Level ~= nil then settings.Level = log.Level end
    if log.Categories ~= nil then settings.Categories = log.Categories end
    if log.Chat_Echo ~= nil then settings.Chat_Echo = log.Chat_Echo end
    if log.Status_Dump ~= nil then settings.Status_Dump = log.Status_Dump end
    if log.Status_Dump_Interval ~= nil then settings.Status_Dump_Interval = log.Status_Dump_Interval end
end

function X.SetGetPositionFn(fn)
    getPositionFn = fn
end

--------------------------------------------------------------------
-- Level check
--------------------------------------------------------------------
function X.IsEnabled(category, level)
    -- Per-category override
    local catLevel = settings.Categories[category]
    if catLevel ~= nil then
        return level <= catLevel
    end
    return level <= settings.Level
end

--------------------------------------------------------------------
-- Core log function
--------------------------------------------------------------------
local function LogMessage(level, category, msg)
    if level == LEVEL_ERROR then
        -- ERROR always prints
        print("[ERROR][" .. category .. "] " .. tostring(msg))
        return
    end
    if not X.IsEnabled(category, level) then return end
    local levelName = LEVEL_NAMES[level] or "???"
    print("[" .. levelName .. "][" .. category .. "] " .. tostring(msg))
end

--------------------------------------------------------------------
-- Public API: log at each level
--------------------------------------------------------------------
function X.Error(category, msg)
    LogMessage(LEVEL_ERROR, category, msg)
end

function X.Warn(category, msg)
    LogMessage(LEVEL_WARN, category, msg)
end

function X.Info(category, msg)
    LogMessage(LEVEL_INFO, category, msg)
end

function X.Debug(category, msg)
    LogMessage(LEVEL_DEBUG, category, msg)
end

--------------------------------------------------------------------
-- Chat echo (team chat, throttled)
--------------------------------------------------------------------
function X.ChatEcho(bot, msg)
    if not settings.Chat_Echo then return end
    if bot == nil then return end
    -- Only chat if this bot is the currently executing bot
    if GetBot == nil or bot ~= GetBot() then return end

    local pid = bot:GetPlayerID()
    local now = DotaTime()
    if lastChatEchoTime[pid] ~= nil and now - lastChatEchoTime[pid] < CHAT_ECHO_THROTTLE then
        return
    end
    lastChatEchoTime[pid] = now
    bot:ActionImmediate_Chat("[AI] " .. tostring(msg), false)
end

--------------------------------------------------------------------
-- Status dump (periodic bot state summary)
--------------------------------------------------------------------
function X.StatusDump()
    if not settings.Status_Dump then return end

    local now = DotaTime()
    if now < 0 then return end  -- skip pre-game

    local interval = settings.Status_Dump_Interval * 60
    if now - lastStatusDumpTime < interval then return end
    lastStatusDumpTime = now

    local minutes = math.floor(now / 60)

    -- Gather bot data
    local teamPlayers = GetTeamPlayers(GetTeam())
    local lines = {}
    table.insert(lines, "=== BOT STATUS DUMP @ " .. minutes .. " min ===")

    for i = 1, #teamPlayers do
        local hero = GetTeamMember(i)
        if hero ~= nil and hero:IsHero() and not hero:IsIllusion() then
            local name = string.gsub(hero:GetUnitName(), "npc_dota_hero_", "")
            local pos = "?"
            if getPositionFn ~= nil then
                local ok, p = pcall(getPositionFn, hero)
                if ok and p ~= nil then pos = tostring(p) end
            end

            local hpPct = "?"
            if hero:IsAlive() then
                hpPct = tostring(math.floor(hero:GetHealth() / hero:GetMaxHealth() * 100)) .. "%"
            else
                hpPct = "DEAD"
            end

            local gold = tostring(hero:GetGold())

            local mode = "NONE"
            local desire = 0
            if hero:IsAlive() then
                local activeMode = hero:GetActiveMode()
                local modeNames = {
                    [BOT_MODE_LANING]      = "LANE",
                    [BOT_MODE_ATTACK]      = "ATTACK",
                    [BOT_MODE_ROAM]        = "ROAM",
                    [BOT_MODE_RETREAT]      = "RETREAT",
                    [BOT_MODE_SECRET_SHOP]  = "SHOP",
                    [BOT_MODE_SIDE_SHOP]    = "SIDE_SHOP",
                    [BOT_MODE_PUSH_TOWER_TOP]  = "PUSH",
                    [BOT_MODE_PUSH_TOWER_MID]  = "PUSH",
                    [BOT_MODE_PUSH_TOWER_BOT]  = "PUSH",
                    [BOT_MODE_DEFEND_TOWER_TOP] = "DEFEND",
                    [BOT_MODE_DEFEND_TOWER_MID] = "DEFEND",
                    [BOT_MODE_DEFEND_TOWER_BOT] = "DEFEND",
                    [BOT_MODE_ASSEMBLE]    = "ASSEMBLE",
                    [BOT_MODE_TEAM_ROAM]   = "TEAM_ROAM",
                    [BOT_MODE_FARM]        = "FARM",
                    [BOT_MODE_DEFEND_ALLY] = "DEF_ALLY",
                    [BOT_MODE_EVASIVE_MANEUVERS] = "EVADE",
                    [BOT_MODE_ROSHAN]      = "ROSHAN",
                    [BOT_MODE_ITEM]        = "ITEM",
                    [BOT_MODE_WARD]        = "WARD",
                    [BOT_MODE_RUNE]        = "RUNE",
                }
                mode = modeNames[activeMode] or tostring(activeMode)
                desire = hero:GetActiveModeDesire()
            end

            local line = string.format("  [%d] %-18s | pos=%s | HP=%-5s | gold=%-5s | mode=%-9s | desire=%.2f",
                i, name, pos, hpPct, gold, mode, desire)
            table.insert(lines, line)
        end
    end

    table.insert(lines, "=== END STATUS DUMP ===")

    for _, line in ipairs(lines) do
        print(line)
    end
end

return X
