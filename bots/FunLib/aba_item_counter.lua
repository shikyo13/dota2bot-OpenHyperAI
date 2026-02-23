--------------------------------------------------------------------
-- aba_item_counter.lua  –  Counter-Item Intelligence
--
-- Analyzes enemy team composition and recommends counter items
-- to inject into the existing per-hero buy lists.
--------------------------------------------------------------------

local X = {}

local J  -- set lazily

--------------------------------------------------------------------
-- Hero threat classifications
--------------------------------------------------------------------
local MAGIC_HEROES = {
    npc_dota_hero_zeus = true, npc_dota_hero_lina = true, npc_dota_hero_lion = true,
    npc_dota_hero_lich = true, npc_dota_hero_crystal_maiden = true,
    npc_dota_hero_skywrath_mage = true, npc_dota_hero_pugna = true,
    npc_dota_hero_leshrac = true, npc_dota_hero_invoker = true,
    npc_dota_hero_tinker = true, npc_dota_hero_queen_of_pain = true,
    npc_dota_hero_storm_spirit = true, npc_dota_hero_rubick = true,
    npc_dota_hero_necrolyte = true, npc_dota_hero_jakiro = true,
    npc_dota_hero_shadow_shaman = true, npc_dota_hero_disruptor = true,
}

local EVASION_HEROES = {
    npc_dota_hero_phantom_assassin = true, npc_dota_hero_windrunner = true,
    npc_dota_hero_brewmaster = true, npc_dota_hero_arc_warden = true,
}

local ILLUSION_HEROES = {
    npc_dota_hero_phantom_lancer = true, npc_dota_hero_chaos_knight = true,
    npc_dota_hero_naga_siren = true, npc_dota_hero_terrorblade = true,
    npc_dota_hero_morphling = true,
}

local HEAL_HEROES = {
    npc_dota_hero_witch_doctor = true, npc_dota_hero_dazzle = true,
    npc_dota_hero_chen = true, npc_dota_hero_huskar = true,
    npc_dota_hero_necrolyte = true, npc_dota_hero_enchantress = true,
    npc_dota_hero_oracle = true, npc_dota_hero_omniknight = true,
    npc_dota_hero_abaddon = true,
}

local INVIS_HEROES = {
    npc_dota_hero_riki = true, npc_dota_hero_bounty_hunter = true,
    npc_dota_hero_clinkz = true, npc_dota_hero_weaver = true,
    npc_dota_hero_sand_king = true, npc_dota_hero_nyx_assassin = true,
    npc_dota_hero_mirana = true, npc_dota_hero_invoker = true,
    npc_dota_hero_templar_assassin = true, npc_dota_hero_treant = true,
}

local HIGH_ARMOR_HEROES = {
    npc_dota_hero_dragon_knight = true, npc_dota_hero_shredder = true,
    npc_dota_hero_sven = true, npc_dota_hero_terrorblade = true,
    npc_dota_hero_morphling = true, npc_dota_hero_ogre_magi = true,
}

--------------------------------------------------------------------
-- Threat analysis (cached per game, refreshed every 60s)
--------------------------------------------------------------------
local cachedThreats = nil
local cacheTime = -999

local function AnalyzeEnemyThreats()
    local now = DotaTime()
    if cachedThreats ~= nil and now - cacheTime < 60 then
        return cachedThreats
    end

    local threats = {
        magic_heavy = false,
        evasion = false,
        illusion_heavy = false,
        heal_heavy = false,
        invis_heavy = false,
        high_armor = false,
    }

    local enemyTeam = GetOpposingTeam()
    local enemyPlayers = GetTeamPlayers(enemyTeam)

    local magicCount = 0
    local healCount = 0
    local invisCount = 0
    local armorCount = 0

    for _, id in pairs(enemyPlayers) do
        local heroName = GetSelectedHeroName(id)
        -- Fallback: check visible enemy heroes
        if heroName == nil or heroName == "" then
            local enemies = GetUnitList(UNIT_LIST_ENEMY_HEROES)
            for _, e in pairs(enemies) do
                if e:GetPlayerID() == id then
                    heroName = e:GetUnitName()
                    break
                end
            end
        end

        if heroName ~= nil and heroName ~= "" then
            if MAGIC_HEROES[heroName] then magicCount = magicCount + 1 end
            if EVASION_HEROES[heroName] then threats.evasion = true end
            if ILLUSION_HEROES[heroName] then threats.illusion_heavy = true end
            if HEAL_HEROES[heroName] then healCount = healCount + 1 end
            if INVIS_HEROES[heroName] then invisCount = invisCount + 1 end
            if HIGH_ARMOR_HEROES[heroName] then armorCount = armorCount + 1 end
        end
    end

    threats.magic_heavy = magicCount >= 3
    threats.heal_heavy = healCount >= 2
    threats.invis_heavy = invisCount >= 2
    threats.high_armor = armorCount >= 2

    cachedThreats = threats
    cacheTime = now
    return threats
end

--------------------------------------------------------------------
-- Check if bot already has item in inventory or buy list
--------------------------------------------------------------------
local function BotHasOrBuying(bot, itemName, buyList)
    -- Check inventory (slots 0-14)
    for s = 0, 14 do
        local it = bot:GetItemInSlot(s)
        if it ~= nil and it:GetName() == itemName then
            return true
        end
    end
    -- Check buy list
    if buyList ~= nil then
        for _, item in pairs(buyList) do
            if item == itemName then return true end
        end
    end
    return false
end

--------------------------------------------------------------------
-- Main API: Get counter items to inject
--------------------------------------------------------------------
function X.GetCounterItems(bot, position, buyList)
    if J == nil then
        local ok, mod = pcall(require, GetScriptDirectory()..'/FunLib/jmz_func')
        if ok then J = mod end
    end

    local threats = AnalyzeEnemyThreats()
    local counterItems = {}
    local gameTime = DotaTime()

    -- Only start injecting counter items after laning phase
    if gameTime < 10 * 60 then return counterItems end

    -- Evasion counter: cores get MKB
    if threats.evasion and position <= 3 then
        if not BotHasOrBuying(bot, "item_monkey_king_bar", buyList) then
            table.insert(counterItems, "item_monkey_king_bar")
        end
    end

    -- Magic heavy: cores ensure BKB, supports get Pipe/Glimmer
    if threats.magic_heavy then
        if position <= 3 then
            if not BotHasOrBuying(bot, "item_black_king_bar", buyList) then
                table.insert(counterItems, "item_black_king_bar")
            end
        end
        if position == 3 or position == 4 then
            if not BotHasOrBuying(bot, "item_pipe", buyList)
            and not BotHasOrBuying(bot, "item_pipe_of_insight", buyList) then
                table.insert(counterItems, "item_pipe")
            end
        end
        if position >= 4 then
            if not BotHasOrBuying(bot, "item_glimmer_cape", buyList) then
                table.insert(counterItems, "item_glimmer_cape")
            end
        end
    end

    -- Illusion heavy: cleave/AoE items
    if threats.illusion_heavy then
        if position <= 2 then
            if not BotHasOrBuying(bot, "item_mjollnir", buyList)
            and not BotHasOrBuying(bot, "item_maelstrom", buyList) then
                table.insert(counterItems, "item_mjollnir")
            end
        end
        if position == 3 then
            if not BotHasOrBuying(bot, "item_crimson_guard", buyList) then
                table.insert(counterItems, "item_crimson_guard")
            end
        end
    end

    -- Heal heavy: Spirit Vessel for pos 3-4
    if threats.heal_heavy then
        if position == 3 or position == 4 then
            if not BotHasOrBuying(bot, "item_spirit_vessel", buyList)
            and not BotHasOrBuying(bot, "item_urn_of_shadows", buyList) then
                table.insert(counterItems, "item_spirit_vessel")
            end
        end
    end

    -- Invis heavy: dust is handled reactively by the active item usage system,
    -- so we don't inject it here to avoid duplicates.

    -- High armor: Desolator for physical cores, Solar Crest for supports
    if threats.high_armor then
        if position <= 2 then
            if not BotHasOrBuying(bot, "item_desolator", buyList)
            and not BotHasOrBuying(bot, "item_assault", buyList) then
                table.insert(counterItems, "item_desolator")
            end
        end
        if position == 4 or position == 5 then
            if not BotHasOrBuying(bot, "item_solar_crest", buyList)
            and not BotHasOrBuying(bot, "item_medallion_of_courage", buyList) then
                table.insert(counterItems, "item_solar_crest")
            end
        end
    end

    return counterItems
end

return X
