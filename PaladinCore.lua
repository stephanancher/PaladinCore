PCA_Config = PCA_Config or {}

local PCA_VERSION = "2.0.2"

-- Use tables to avoid "too many upvalues" limit (limit=32 in Lua 5.0/Vanilla)
local PCA_Refs  = {}
local PCA_State = { alerted = false, menuBuilt = false }

local defaultOpener        = "Holy Strike"
local defaultOpenerPrebuff = "Seal of Righteousness"
local defaultRot1          = "Seal of Righteousness"
local defaultRot2          = "None"
local defaultRot3          = "None"
local defaultRot4          = "None"

local COMBO_HS_CS = "Holy Strike / Crusader Strike"

local iconUpdateTick   = 0
local cdScanTimer      = 0      -- counts up; re-scans for the macro action button every 5 s
local autoAttackTick   = 0      -- counts icon ticks; fires auto-attack check every ~1 s
local pca_autoAttacking = false  -- true once we have called AttackTarget(); reset by events
local lastPartyCount   = 0      -- track group size to prevent sync spam

local pcaMessages = {
    "I am powered by the mighty PaladinCore!",
    "My bubble is on a cooldown, but PaladinCore is forever!",
    "Warning: This Paladin is overclocked by PaladinCore. Mana not included.",
    "I don't always judge, but when I do, PaladinCore does it better.",
    "The Light provides, but PaladinCore automates!",
    "You handle the mechanics, PaladinCore handles the rotation.",
    "Blessing of Wisdom? No, I have Blessing of PaladinCore!",
    "If you see me Hammer of Justice perfectly, thank PaladinCore.",
    "PaladinCore: Making Retribution great again, one seal at a time.",
    "Keep your seals sharp and your PaladinCore updated!"
}

-- Texture short-names for icon/buff detection.
-- DevNote: Seal of the Crusader buff texture is "Spell_Holy_HolySmite"
local spellTextures = {
    ["Seal of Righteousness"]        = "Ability_ThunderBolt",
    ["Seal of Command"]              = "Ability_Thunderbolt",
    ["Seal of Wisdom"]               = "Spell_Holy_RighteousnessAura",
    ["Seal of Light"]                = "Spell_holy_HealingAura",
    ["Seal of Justice"]              = "Spell_Holy_SealOfWrath",
    ["Seal of the Crusader"]         = "Spell_Holy_HolySmite",
    ["Holy Strike"]                  = "Ability_Paladin_HolyStrike",
    ["Crusader Strike"]              = "Spell_Holy_CrusaderStrike",
    ["Holy Strike / Crusader Strike"] = "Ability_Paladin_HolyStrike",  -- default icon; alternates dynamically
    ["Consecration"]                 = "Spell_Holy_Consecration",
    ["Devotion Aura"]                = "Spell_Holy_DevotionAura",
    ["Retribution Aura"]             = "Spell_Holy_AuraOfLight",
    ["Concentration Aura"]           = "Spell_Holy_MindSooth",
    ["Shadow Resistance Aura"]       = "Spell_Holy_ShadowResistanceAura",
    ["Righteous Fury"]               = "Spell_Holy_SealOfFury",
    ["Blessing of Sanctuary"]        = "Spell_Nature_LightningShield",
    ["Blessing of Kings"]            = "Spell_Magic_MageArmor",
    ["Blessing of Salvation"]        = "Spell_Holy_SealOfSalvation",
    ["Blessing of Wisdom"]           = "Spell_Holy_SealOfWisdom",
    ["Blessing of Might"]            = "Spell_Holy_FistOfJustice",
    ["Blessing of Light"]            = "Spell_Holy_PrayerOfHealing02",
    ["Blessing of Freedom"]          = "Spell_Holy_SealOfValor",
    ["Blessing of Protection"]       = "Spell_Holy_SealOfProtection",
    ["Holy Shield"]                  = "Ability_Paladin_HolyShield",
}

-- Fast lookup: is this spell a seal?
local sealNames = {
    ["Seal of Righteousness"] = true,
    ["Seal of Command"]       = true,
    ["Seal of Wisdom"]        = true,
    ["Seal of Light"]         = true,
    ["Seal of Justice"]       = true,
    ["Seal of the Crusader"]  = true,
}

-- Opener dropdown options
local openerOptions = {
    "Blessing of Sanctuary",
    "Crusader Strike",
    "Holy Shield",
    "Holy Strike",
    COMBO_HS_CS,
    "Seal of Command",
    "Seal of Justice",
    "Seal of Light",
    "Seal of Righteousness",
    "Seal of Wisdom",
    "Seal of the Crusader",
}

-- Pre-buff seal options (shown under opener; used when running in)
local openerPrebuffOptions = {
    "None",
    "Seal of Command",
    "Seal of Justice",
    "Seal of Light",
    "Seal of Righteousness",
    "Seal of Wisdom",
    "Seal of the Crusader",
}

-- Rotation slot dropdown options (None = skip this slot)
local rotationOptions = {
    "None",
    "Blessing of Sanctuary",
    "Consecration",
    "Crusader Strike",
    "Holy Shield",
    "Holy Strike",
    COMBO_HS_CS,
    "Seal of Command",
    "Seal of Justice",
    "Seal of Light",
    "Seal of Righteousness",
    "Seal of Wisdom",
    "Seal of the Crusader",
}

-- Aura dropdown options
local auraOptions = {
    "None",
    "Concentration Aura",
    "Devotion Aura",
    "Retribution Aura",
    "Shadow Resistance Aura",
}

-- Blessing dropdown options
local blessingOptions = {
    "None",
    "Blessing of Freedom",
    "Blessing of Kings",
    "Blessing of Light",
    "Blessing of Might",
    "Blessing of Protection",
    "Blessing of Salvation",
    "Blessing of Sanctuary",
    "Blessing of Wisdom",
}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function IsSeal(name)
    return sealNames[name] == true
end

local function PCA_IsNewer(remote, current)
    local v1, v2 = {}, {}
    for v in string.gfind(remote, "(%d+)") do table.insert(v1, tonumber(v)) end
    for v in string.gfind(current, "(%d+)") do table.insert(v2, tonumber(v)) end
    for i = 1, math.max(table.getn(v1), table.getn(v2)) do
        local n1, n2 = v1[i] or 0, v2[i] or 0
        if n1 > n2 then return true end
        if n1 < n2 then return false end
    end
    return false
end

local function PCA_GetRestedString()
    local xp = GetXPExhaustion() or 0
    local pct = math.floor(100 * xp / UnitXPMax("player"))
    if pct >= 112 then return "MAX" else return pct .. "%" end
end

local function PCA_SendSync(msg)
    if GetNumRaidMembers() > 0 then
        SendAddonMessage("PalCore", msg, "RAID")
    elseif GetNumPartyMembers() > 0 then
        SendAddonMessage("PalCore", msg, "PARTY")
    end
    if IsInGuild() and IsInGuild() ~= 0 then
        SendAddonMessage("PalCore", msg, "GUILD")
    end
end

local function PCA_DebugBuffs()
    DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00PaladinCore — Player buffs:|r")
    local i = 1
    while true do
        local texture = UnitBuff("player", i)
        if not texture then break end
        DEFAULT_CHAT_FRAME:AddMessage("  [" .. i .. "] " .. texture)
        i = i + 1
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00PaladinCore — Target debuffs:|r")
    i = 1
    while true do
        local texture = UnitDebuff("target", i)
        if not texture then break end
        DEFAULT_CHAT_FRAME:AddMessage("  [" .. i .. "] " .. texture)
        i = i + 1
    end
end

-- ── Debug ─────────────────────────────────────────────────────────────────────

local function dbg(msg)
    if PCA_Config.Debug then
        DEFAULT_CHAT_FRAME:AddMessage(msg)
    end
end

-- ── Spell / buff helpers ──────────────────────────────────────────────────────

local function FindSpell(name)
    for i = 1, 200 do
        local n = GetSpellName(i, BOOKTYPE_SPELL)
        if not n then break end
        if string.find(n, name) then return i end
    end
    return nil
end

local function IsSpellReady(name)
    local slot = FindSpell(name)
    if not slot then return false end
    local start, dur = GetSpellCooldown(slot, BOOKTYPE_SPELL)
    if start == 0 then return true end
    return (GetTime() - start) >= dur
end

local function PlayerKnowsBlessing(blessingName)
    return FindSpell(blessingName) ~= nil
end

-- ── Auto-attack guardian ──────────────────────────────────────────────────────
-- Tracks whether we have already started auto-attack via a flag.
-- AttackTarget() is a toggle in vanilla WoW, so we only call it once per
-- engagement. The flag is reset when the target changes or combat ends.
local function PCA_EnsureAutoAttack()
    if not UnitExists("target") or UnitIsDead("target") or not UnitCanAttack("player", "target") then
        pca_autoAttacking = false   -- lost target; reset so we re-engage next target
        return
    end
    if not pca_autoAttacking then
        dbg("|cffff9900[PCA] Starting auto-attack|r")
        AttackTarget()
        pca_autoAttacking = true
    end
end


local function HasBuffTexture(unit, pattern)
    local lp = string.lower(pattern)
    local i = 1
    while true do
        local texture = UnitBuff(unit, i)
        if not texture then return false end
        if string.find(string.lower(texture), lp) then return true end
        i = i + 1
    end
end

local function HasDebuffTexture(unit, pattern)
    local lp = string.lower(pattern)
    local i = 1
    while true do
        local texture = UnitDebuff(unit, i)
        if not texture then return false end
        if string.find(string.lower(texture), lp) then return true end
        i = i + 1
    end
end

local function IsTargetUndead()
    if not UnitExists("target") then return false end
    local ct = UnitCreatureType("target")
    -- In Turtle WoW / Vanilla, Exorcism works on Undead and Demons
    return (ct == "Undead") or (ct == "Demon")
end

local function PCA_IsExorcismPriority()
    return PCA_Config.FightingUndead and IsTargetUndead()
end

local function UnitIsCasting(unit)
    if unit ~= "target" then return false end
    if not UnitExists("target") then return false end
    
    local name = UnitName("target")
    if name == PCA_State.castingTargetName then
        local elapsed = GetTime() - (PCA_State.castStartTime or 0)
        -- Standard cast window; reset if too much time has passed
        if elapsed < 3.5 then return true else PCA_State.castingTargetName = nil end
    end
    return false
end

local function PlayerHasSeal(sealName)
    local pattern = spellTextures[sealName]
    if not pattern then return false end
    return HasBuffTexture("player", pattern)
end

local function PlayerHasSoR()
    return HasBuffTexture("player", "Ability_ThunderBolt")
end

-- Returns the effective version of a spell name.
-- For utility seals (SotC / SoW / SoL / SoJ): if that seal's judgement debuff
-- is already on the target, switch to Seal of Righteousness so we can judge
-- again for holy damage without wasting the utility debuff slot.
-- SoR and SoC are always returned as-is (always want them maintained).
local function GetEffectiveSpell(spellName)
    if not spellName or spellName == "None" then return nil end

    -- If Judging is DISABLED, we don't swap to SoR (we keep our utility seal up)
    if PCA_Config.JudgingEnabled == false then return spellName end

    if IsSeal(spellName)
       and spellName ~= "Seal of Righteousness"
       and spellName ~= "Seal of Command"
       and UnitExists("target") then
        local tex = spellTextures[spellName]
        if tex and HasDebuffTexture("target", tex) then
            return "Seal of Righteousness"  -- debuff up, switch to SoR for judging
        end
    end
    return spellName
end

-- Build the effective priority list from the 3 config slots.
local function GetRotationSpells()
    return {
        GetEffectiveSpell(PCA_Config.RotationSpell1 or defaultRot1),
        GetEffectiveSpell(PCA_Config.RotationSpell2 or defaultRot2),
        GetEffectiveSpell(PCA_Config.RotationSpell3 or defaultRot3),
        GetEffectiveSpell(PCA_Config.RotationSpell4 or defaultRot4),
    }
end

-- Returns (start, duration) from GetSpellCooldown for the *next* spell in the
-- rotation so we can drive the action bar button's cooldown swipe animation.
-- Returns (0, 0) when the next step needs no cooldown check (e.g. applying a seal).
local function PCA_GetNextSpellCooldownInfo()
    local function spellCD(name)
        local slot = FindSpell(name)
        if not slot then return 0, 0 end
        return GetSpellCooldown(slot, BOOKTYPE_SPELL)
    end

    local inCombat    = UnitAffectingCombat("player")
    local rotSpells   = GetRotationSpells()
    local openerSpell = PCA_Config.OpenerSpell or defaultOpener

    -- Absolute priority on Exorcism when Fighting Undead is ON
    if PCA_IsExorcismPriority() then
        local start, dur = spellCD("Exorcism")
        if start > 0 and dur > 0 then
            return start, dur
        end
    end

    if not inCombat then
        if not IsSeal(openerSpell) then
            local prebuff = PCA_Config.OpenerPrebuff or defaultOpenerPrebuff
            if prebuff ~= "None" and not PlayerHasSeal(prebuff) then
                return 0, 0  -- about to apply a seal; no cooldown to display
            end
            if PCA_Config.FightingUndead and UnitExists("target") and IsTargetUndead() then
                local sealCheck = (prebuff ~= "None") and prebuff or (PCA_Config.RotationSpell1 or defaultRot1)
                if PlayerHasSeal(sealCheck) then
                    return spellCD("Exorcism")
                end
            end
            local castSpell = (openerSpell == COMBO_HS_CS)
                              and (PCA_Config.HSCSToggle or "Holy Strike")
                              or openerSpell
            return spellCD(castSpell)
        end
        return 0, 0  -- opener is a seal, no cooldown to display
    end

    -- In-combat: follow the same priority order as the rotation
    for _, spell in ipairs(rotSpells) do
        if spell then
            if IsSeal(spell) then
                if not PlayerHasSeal(spell) then return spellCD(spell) end  -- applying seal

                -- If Judging is LIMITED, the next critical action might be Judgement (to apply debuff)
                if PCA_Config.JudgingEnabled == false and spell ~= "Seal of Righteousness" and spell ~= "Seal of Command" then
                    local tex = spellTextures[spell]
                    if tex and not HasDebuffTexture("target", tex) then
                        return spellCD("Judgement")
                    end
                end
            elseif spell == COMBO_HS_CS then
                return spellCD(PCA_Config.HSCSToggle or "Holy Strike")
            else
                return spellCD(spell)
            end
        end
    end
    return spellCD("Judgement")  -- fallback filler
end

-- Checks if the configured aura is active; casts it if missing.
local function PCA_EnsureAura()
    local aura = PCA_Config.SelectedAura
    if not aura or aura == "None" then return false end

    local tex = spellTextures[aura]
    if tex and not HasBuffTexture("player", tex) then
        local slot = FindSpell(aura)
        if slot then
            local start, dur = GetSpellCooldown(slot, BOOKTYPE_SPELL)
            if start > 0 and dur > 0 then return true end
        end
        dbg("|cff00ff00[PCA] Missing aura: Casting " .. aura .. "|r")
        CastSpellByName(aura, 1)
        return true
    end
    return false
end

local function PCA_GetRFText()
    if PCA_Config.MaintainRF then return "Righteous Fury: ON"
    else return "Righteous Fury: OFF" end
end

local lastRFAttempt = 0
-- Checks if Righteous Fury is active when enabled; casts it if missing.
local function PCA_EnsureRF()
    if not PCA_Config.MaintainRF then return false end

    -- Use a broader pattern 'sealoffury' to catch variations in icon paths
    if not HasBuffTexture("player", "sealoffury") then
        local slot = FindSpell("Righteous Fury")
        if not slot then
            dbg("|cffff4444[PCA] Error: 'Righteous Fury' spell not found in spellbook!|r")
            return false
        end

        local start, dur = GetSpellCooldown(slot, BOOKTYPE_SPELL)
        if start > 0 and dur > 0 then return true end

        -- Rate limit the debug message to avoid chat spam if the cast fails
        if GetTime() - lastRFAttempt > 5 then
            dbg("|cff00ff00[PCA] Missing Righteous Fury: Casting|r")
            lastRFAttempt = GetTime()
        end

        local spellName = GetSpellName(slot, BOOKTYPE_SPELL)
        CastSpellByName(spellName, 1)
        return true
    end
    return false
end

local function PCA_GetBlessingText()
    local blessing = PCA_Config.SelectedBlessing or "None"
    return "Blessing: " .. blessing
end

local lastBlessingAttempt = 0
-- Checks if the selected blessing is active; casts it if missing.
local function PCA_EnsureBlessing()
    local blessing = PCA_Config.SelectedBlessing
    if not blessing or blessing == "None" then return false end

    local tex = spellTextures[blessing]
    if tex and not HasBuffTexture("player", tex) then
        local slot = FindSpell(blessing)
        if not slot then
            dbg("|cffff4444[PCA] Error: '" .. blessing .. "' spell not found in spellbook!|r")
            return false
        end

        local start, dur = GetSpellCooldown(slot, BOOKTYPE_SPELL)
        if start > 0 and dur > 0 then return true end

        -- Rate limit the debug message to avoid chat spam if the cast fails
        if GetTime() - lastBlessingAttempt > 5 then
            dbg("|cff00ff00[PCA] Missing " .. blessing .. ": Casting|r")
            lastBlessingAttempt = GetTime()
        end

        CastSpellByName(blessing, 1)
        return true
    end
    return false
end

-- Find the first seal in the rotation slots (used for pre-buffing).
local function GetFirstRotationSeal()
    local slots = {
        PCA_Config.RotationSpell1 or defaultRot1,
        PCA_Config.RotationSpell2 or defaultRot2,
        PCA_Config.RotationSpell3 or defaultRot3,
    }
    for _, spell in ipairs(slots) do
        if spell and spell ~= "None" and IsSeal(spell) then
            return spell
        end
    end
    return nil
end

-- ── Macro helpers ─────────────────────────────────────────────────────────────

local function PCA_GetMacroIndex(name)
    local numGeneral, numChar = GetNumMacros()
    for i = 1, numGeneral + numChar do
        local macroName = GetMacroInfo(i)
        if macroName == name then return i end
    end
    return 0
end

local function PCA_EnsureMacro()
    local macroName = "PalCore"
    local macroBody = "/script paladincore()"
    local rot1      = PCA_Config.RotationSpell1 or defaultRot1
    local macroIcon = spellTextures[rot1] or "Ability_ThunderBolt"
    local idx = PCA_GetMacroIndex(macroName)
    if idx == 0 then
        CreateMacro(macroName, macroIcon, macroBody, nil, nil)
        idx = PCA_GetMacroIndex(macroName)
    else
        EditMacro(idx, macroName, macroIcon, macroBody, nil, nil)
    end
    return idx
end

-- ── Next-action icon prediction ───────────────────────────────────────────────
-- Mirrors paladincore() logic but returns a texture name instead of casting.

local function PCA_GetSpellIconShortName(spellName)
    local idx = FindSpell(spellName)
    if not idx then return nil end
    local fullPath = GetSpellTexture(idx, BOOKTYPE_SPELL)
    if not fullPath then return nil end
    local _, _, shortName = string.find(fullPath, "([^\\/]+)$")
    return shortName
end

local function PCA_GetNextActionInfo()
    local rotSpells   = GetRotationSpells()
    local openerSpell = PCA_Config.OpenerSpell or defaultOpener
    local fallbackTex = spellTextures[PCA_Config.RotationSpell1 or defaultRot1] or "Ability_ThunderBolt"
    local inCombat    = UnitAffectingCombat("player")

    -- Absolute priority on Exorcism when Fighting Undead is ON
    if PCA_IsExorcismPriority() and IsSpellReady("Exorcism") then
        return PCA_GetSpellIconShortName("Exorcism") or "Spell_Holy_Exorcism", true
    end

    if not inCombat then
        local nextHS = PCA_Config.HSCSToggle or "Holy Strike"
        if not IsSeal(openerSpell) then
            local castSpell = (openerSpell == COMBO_HS_CS) and nextHS or openerSpell
            if UnitExists("target") and IsSpellReady(castSpell) then
                return PCA_GetSpellIconShortName(castSpell) or fallbackTex, true
            end
            local prebuff = PCA_Config.OpenerPrebuff or defaultOpenerPrebuff
            if prebuff ~= "None" and not PlayerHasSeal(prebuff) then
                -- Seal application has no cooldown gate — always ready
                return spellTextures[prebuff] or fallbackTex, IsSpellReady(prebuff)
            end
            return PCA_GetSpellIconShortName(castSpell) or fallbackTex, IsSpellReady(castSpell)
        else
            if not PlayerHasSeal(openerSpell) then
                return spellTextures[openerSpell] or fallbackTex, IsSpellReady(openerSpell)
            end
        end
        return fallbackTex, false
    end

    -- ── In combat: strict slot priority 1 → 2 → 3, then Judgement filler ──────
    local nextHS     = PCA_Config.HSCSToggle or "Holy Strike"
    local judgeIcon  = PCA_GetSpellIconShortName("Judgement") or fallbackTex
    local firstOnCdIcon = nil  -- icon of the first slot that is on cooldown (dimmed fallback)

    for _, spell in ipairs(rotSpells) do
        if spell then
            if IsSeal(spell) then
                if not PlayerHasSeal(spell) then
                    -- Missing seal — applying it is the next action
                    return spellTextures[spell] or fallbackTex, IsSpellReady(spell)
                end

                -- If Judging is LIMITED, we allow ONE judgement to apply the utility debuff
                if PCA_Config.JudgingEnabled == false and spell ~= "Seal of Righteousness" and spell ~= "Seal of Command" then
                    local tex = spellTextures[spell]
                    if tex and not HasDebuffTexture("target", tex) then
                        local jIcon = PCA_GetSpellIconShortName("Judgement") or fallbackTex
                        return jIcon, IsSpellReady("Judgement")
                    end
                end

                -- Seal active → fall through to next slot
            else
                local castSpell = (spell == COMBO_HS_CS) and nextHS or spell
                local icon      = PCA_GetSpellIconShortName(castSpell) or fallbackTex
                if not firstOnCdIcon then firstOnCdIcon = icon end
                if IsSpellReady(castSpell) then
                    return icon, true
                end
                -- On cooldown → fall through to next slot
            end
        end
    end

    -- Judgement filler
    if PCA_Config.JudgingEnabled ~= false and IsSpellReady("Judgement") then
        return judgeIcon, true
    end

    -- Everything is on cooldown; show the first busy slot dimmed
    return firstOnCdIcon or judgeIcon, false
end

-- ── Addon load ────────────────────────────────────────────────────────────────

function PCA_OnLoad()
    math.randomseed(GetTime())
    local _, class = UnitClass("player")
    if class ~= "PALADIN" then
        if PCAMinimapButton then PCAMinimapButton:Hide() end
        this:UnregisterAllEvents()
        return
    end

    -- If we reached here, we are a Paladin
    if PCAMinimapButton then 
        PCAMinimapButton:Show()
        PCA_MinimapButton_UpdatePosition()

        PCAMinimapButton:SetScript("OnEnter", function()
            GameTooltip:SetOwner(this, "ANCHOR_LEFT")
            GameTooltip:AddLine("|cffffcc00PaladinCore v" .. PCA_VERSION .. "|r")
            GameTooltip:AddLine("Currently |cff00ff00" .. PCA_GetRestedString() .. "|r Rested", 1, 1, 1)
            GameTooltip:AddLine("Left-Click: Open settings", 0.7, 0.7, 0.7)
            GameTooltip:AddLine("Drag to move", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
    end

    -- Migrate old config keys
    if PCA_Config.Seal and not PCA_Config.RotationSpell1 then
        PCA_Config.RotationSpell1 = PCA_Config.Seal
    end
    if PCA_Config.RotationSpell and not PCA_Config.RotationSpell1 then
        PCA_Config.RotationSpell1 = PCA_Config.RotationSpell
    end
    PCA_Config.Seal          = nil
    PCA_Config.RotationSpell = nil
    PCA_Config.Consecration  = nil  -- removed; now a rotation slot option

    if not PCA_Config.OpenerSpell    then PCA_Config.OpenerSpell    = defaultOpener       end
    if not PCA_Config.OpenerPrebuff  then PCA_Config.OpenerPrebuff  = defaultOpenerPrebuff end
    if not PCA_Config.HSCSToggle     then PCA_Config.HSCSToggle     = "Holy Strike"        end
    if not PCA_Config.RotationSpell1 then PCA_Config.RotationSpell1 = defaultRot1          end
    if not PCA_Config.RotationSpell2 then PCA_Config.RotationSpell2 = defaultRot2          end
    if not PCA_Config.RotationSpell3 then PCA_Config.RotationSpell3 = defaultRot3          end
    if not PCA_Config.RotationSpell4 then PCA_Config.RotationSpell4 = defaultRot4          end
    if not PCA_Config.SelectedAura   then PCA_Config.SelectedAura   = "None"               end
    if not PCA_Config.SelectedBlessing then PCA_Config.SelectedBlessing = "None"            end
    if PCA_Config.MaintainRF     == nil then PCA_Config.MaintainRF     = false             end
    if PCA_Config.MaintainBS     == nil then PCA_Config.MaintainBS     = false             end  -- legacy, can remove later
    if PCA_Config.Debug          == nil then PCA_Config.Debug          = false end
    if PCA_Config.FightingUndead == nil then PCA_Config.FightingUndead = false end

    -- Migrate MaintainBS to SelectedBlessing
    if PCA_Config.MaintainBS and PCA_Config.SelectedBlessing == "None" then
        PCA_Config.SelectedBlessing = "Blessing of Sanctuary"
    end

    -- Migrate StopJudging -> JudgingEnabled
    if PCA_Config.StopJudging ~= nil then
        PCA_Config.JudgingEnabled = not PCA_Config.StopJudging
        PCA_Config.StopJudging = nil
    end
    if PCA_Config.JudgingEnabled == nil then PCA_Config.JudgingEnabled = true end

    if PCA_Config.AssistEnabled  == nil then PCA_Config.AssistEnabled  = false end
    if PCA_Config.AssistTankName == nil then PCA_Config.AssistTankName = ""    end
    if PCA_Config.MinimapPos     == nil then PCA_Config.MinimapPos     = 45   end
    if PCA_Config.SmartTargeting == nil then PCA_Config.SmartTargeting = true end
    if PCA_Config.SmartTargeting == nil then PCA_Config.SmartTargeting = true end
    if PCA_Config.AutoStun      == nil then PCA_Config.AutoStun      = false end
    if PCA_Config.UIScale        == nil then PCA_Config.UIScale        = 0.85 end

    -- Set title to full name + version
    if PCATitle then
        PCATitle:SetFont("Fonts\\FRIZQT__.TTF", 16)
        PCATitle:SetText("PaladinCore  V" .. PCA_VERSION)
    end
    if PCASubTitle then
        PCASubTitle:SetFont("Fonts\\FRIZQT__.TTF", 12)
        PCASubTitle:SetText("")
    end

    SLASH_PCA1 = "/pca"
    SlashCmdList["PCA"] = PCA_OpenMenu

    SLASH_PCABUFFS1 = "/pcabuffs"
    SlashCmdList["PCABUFFS"] = function()
        DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00PaladinCore — Player buffs:|r")
        local i = 1
        while true do
            local texture = UnitBuff("player", i)
            if not texture then break end
            DEFAULT_CHAT_FRAME:AddMessage("  [" .. i .. "] " .. texture)
            i = i + 1
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00PaladinCore — Target debuffs:|r")
        i = 1
        while true do
            local texture = UnitDebuff("target", i)
            if not texture then break end
            DEFAULT_CHAT_FRAME:AddMessage("  [" .. i .. "] " .. texture)
            i = i + 1
        end
    end

    tinsert(UISpecialFrames, "PCAFrame")

    local iconFrame = CreateFrame("Frame")
    iconFrame:RegisterEvent("VARIABLES_LOADED")
    iconFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    iconFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
    iconFrame:RegisterEvent("RAID_ROSTER_UPDATE")
    iconFrame:RegisterEvent("CHAT_MSG_ADDON")
    iconFrame:RegisterEvent("PLAYER_REGEN_ENABLED")   -- left combat
    iconFrame:RegisterEvent("PLAYER_REGEN_DISABLED")  -- entered combat
    iconFrame:RegisterEvent("PLAYER_TARGET_CHANGED")  -- new target
    iconFrame:RegisterEvent("PLAYER_ENTER_COMBAT")    -- started auto-attack
    iconFrame:RegisterEvent("PLAYER_LEAVE_COMBAT")    -- stopped auto-attack
    
    -- Casting Detection (Combat Log)
    iconFrame:RegisterEvent("CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE")
    iconFrame:RegisterEvent("CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF")
    iconFrame:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE")
    iconFrame:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_CREATURE_BUFF")

    iconFrame:SetScript("OnEvent", function()
        if event == "VARIABLES_LOADED" then
            if PCA_MinimapButton_UpdatePosition then
                PCA_MinimapButton_UpdatePosition()
            end
        elseif event == "PLAYER_ENTERING_WORLD" then
            lastPartyCount = GetNumPartyMembers()
            PCA_SendSync("VER:" .. PCA_VERSION)
            DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00PaladinCore v" .. PCA_VERSION .. "|r Loaded. Currently |cff00ff00" .. PCA_GetRestedString() .. "|r Rested.")
        elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
            local count = GetNumPartyMembers() + GetNumRaidMembers()
            if count ~= lastPartyCount then
                PCA_SendSync("VER:" .. PCA_VERSION)
                -- Send advertisement when joining a group for the first time
                if lastPartyCount == 0 and count > 0 then
                    local chatChannel = GetNumRaidMembers() > 0 and "RAID" or "PARTY"
                    local msg = pcaMessages[math.random(1, table.getn(pcaMessages))]
                    SendChatMessage(msg .. " (v" .. PCA_VERSION .. ") https://github.com/stephanancher/PaladinCore", chatChannel)
                end
                lastPartyCount = count
            end
        elseif event == "CHAT_MSG_ADDON" then
            -- arg1: prefix, arg2: msg, arg3: channel, arg4: sender
            if arg1 == "PalCore" and arg4 ~= UnitName("player") then
                if string.find(arg2, "VER:") then
                    local remoteVer = string.sub(arg2, 5)
                    dbg("|cff88ccff[PCA Sync] Received v" .. remoteVer .. " from " .. arg4 .. "|r")
                    if PCA_IsNewer(remoteVer, PCA_VERSION) and not PCA_State.alerted then
                        DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[PaladinCore]|r A newer version (|cffffffffv" .. remoteVer .. "|r) is available! Check your GitHub for updates.")
                        PCA_State.alerted = true
                    end
                elseif arg2 == "REQ" then
                    PCA_SendSync("VER:" .. PCA_VERSION)
                end
            end
        elseif event == "PLAYER_TARGET_CHANGED" then
            pca_autoAttacking = false
            PCA_State.castingTargetName = nil
        elseif event == "PLAYER_ENTER_COMBAT" then
            pca_autoAttacking = true
        elseif event == "PLAYER_LEAVE_COMBAT" then
            pca_autoAttacking = false
        elseif event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED" then
            pca_autoAttacking = false
        elseif event == "CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE" or 
               event == "CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF" or
               event == "CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE" or
               event == "CHAT_MSG_SPELL_CREATURE_VS_CREATURE_BUFF" then
            if arg1 then
                local _, _, caster, spell = string.find(arg1, "(.+) begins to cast (.+)%.")
                if caster and caster == UnitName("target") then
                    PCA_State.castingTargetName = caster
                    PCA_State.castStartTime = GetTime()
                    dbg("|cffff0000[PCA] Target is casting: " .. spell .. "|r")
                end
            end
        end
    end)

    iconFrame:SetScript("OnUpdate", function()
        iconUpdateTick = iconUpdateTick + arg1
        if iconUpdateTick < 0.33 then return end
        iconUpdateTick = 0

        -- Periodically ensure aura is active (automatic maintenance)
        if not auraAutoTick then auraAutoTick = 0 end
        auraAutoTick = auraAutoTick + 0.33
        if auraAutoTick >= 2.0 then
            auraAutoTick = 0
            if not UnitIsDeadOrGhost("player") then
                -- Try to maintain all independently
                local auraTargeted = PCA_EnsureAura()
                local rfTargeted   = PCA_EnsureRF()
                local blessingTargeted = PCA_EnsureBlessing()
                
                if (auraTargeted or rfTargeted or blessingTargeted) and UnitAffectingCombat("player") then
                    -- In standard 1.12, CastSpellByName might fail in combat via OnUpdate
                    -- We'll rely on the player's next macro click to catch it if so.
                end
            end
        end

        local shortName, isReady = PCA_GetNextActionInfo()

        -- Dim the settings-panel drag button when next spell is on cooldown
        if PCA_Refs.dragBtnTex then
            PCA_Refs.dragBtnTex:SetTexture("Interface\\Icons\\" .. shortName)
            if isReady then
                PCA_Refs.dragBtnTex:SetVertexColor(1, 1, 1)
            else
                PCA_Refs.dragBtnTex:SetVertexColor(0.35, 0.35, 0.35)
            end
        end

        local macroIdx = PCA_GetMacroIndex("PalCore")
        if macroIdx and macroIdx > 0 then
            -- Keep the macro icon synced to next action
            EditMacro(macroIdx, "PalCore", shortName, "/script paladincore()", nil, nil)

            -- Re-scan for the action bar button every 5 seconds
            cdScanTimer = cdScanTimer + 0.33
            if cdScanTimer >= 5 or PCA_Refs.palCoreCdFrame == nil then
                cdScanTimer = 0
                PCA_Refs.palCoreCdFrame = nil

                -- GetActionText is vanilla-1.12 compatible; returns macro name for macro slots.
                if GetActionText then
                    local page    = (GetActionBarPage and GetActionBarPage()) or 1
                    local pageOff = (page - 1) * 12
                    for i = 1, 12 do
                        if GetActionText(pageOff + i) == "PalCore" then
                            PCA_Refs.palCoreCdFrame = _G["ActionButton" .. i]  -- the button frame itself
                            break
                        end
                    end

                    if not PCA_Refs.palCoreCdFrame then
                        local extraBars = {
                            { 24, "MultiBarBottomRightButton" },
                            { 36, "MultiBarBottomLeftButton"  },
                            { 48, "MultiBarRightButton"       },
                            { 60, "MultiBarLeftButton"        },
                        }
                        for _, bc in ipairs(extraBars) do
                            for i = 1, 12 do
                                if GetActionText(bc[1] + i) == "PalCore" then
                                    PCA_Refs.palCoreCdFrame = _G[bc[2] .. i]
                                    break
                                end
                            end
                            if PCA_Refs.palCoreCdFrame then break end
                        end
                    end
                end
            end

            -- Dim the action bar button when the next spell is on cooldown
            if PCA_Refs.palCoreCdFrame then
                PCA_Refs.palCoreCdFrame:SetAlpha(isReady and 1.0 or 0.45)
            end

            -- Periodic auto-attack guardian (~every 1 s = 3 icon ticks)
            autoAttackTick = autoAttackTick + 1
            if autoAttackTick >= 3 then
                autoAttackTick = 0
                if UnitAffectingCombat("player") then
                    PCA_EnsureAutoAttack()
                end
            end
        end
    end)
end

-- ── Minimap Button ────────────────────────────────────────────────────────────

function PCA_MinimapButton_UpdatePosition()
    if not PCA_Config.MinimapPos then PCA_Config.MinimapPos = 45 end
    local angle = math.rad(PCA_Config.MinimapPos)
    local radius = 80
    local x = math.cos(angle) * radius
    local y = math.sin(angle) * radius
    PCAMinimapButton:ClearAllPoints()
    PCAMinimapButton:SetPoint("CENTER", "Minimap", "CENTER", x, y)
end

function PCA_MinimapButton_OnUpdate()
    local xpos, ypos = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    local xmin, ymin = Minimap:GetLeft(), Minimap:GetBottom()
    xpos = xpos / scale
    ypos = ypos / scale
    local mx = xmin + Minimap:GetWidth() / 2
    local my = ymin + Minimap:GetHeight() / 2
    local dx = xpos - mx
    local dy = ypos - my
    local ang = math.deg(math.atan2(dy, dx))
    PCA_Config.MinimapPos = ang
    PCA_MinimapButton_UpdatePosition()
end

-- ── Rotation ──────────────────────────────────────────────────────────────────
-- Opener:   cast OpenerSpell (HS attack OR seal pre-buff)
-- Combat:   check slots 1→2→3 in priority order each press, then Judgement

function paladincore()
    -- ── 0) TARGETING & AUTO-ATTACK ───────────────────────────────────────────
    -- We acquire target and start attacking BEFORE buff checks.
    -- This ensures auto-attack starts even if we return early for a GCD buff.
    if PCA_Config.AssistEnabled and PCA_Config.AssistTankName and PCA_Config.AssistTankName ~= "" then
        TargetByName(PCA_Config.AssistTankName, true)
        AssistUnit("target")
    end

    if not UnitExists("target") or UnitIsDead("target") then
        TargetNearestEnemy()
    elseif PCA_Config.SmartTargeting and not CheckInteractDistance("target", 2) then
        -- Current target is far (> 11yd). Try to find someone closer.
        TargetNearestEnemy()
    end

    if UnitExists("target") and not UnitIsDead("target") and UnitCanAttack("player", "target") then
        PCA_EnsureAutoAttack()
    end

    -- ── 0.1) AUTO STUN (Highest Priority) ───────────────────────────────────
    if PCA_Config.AutoStun and UnitExists("target") and not UnitIsDead("target") then
        if UnitIsCasting("target") and CheckInteractDistance("target", 3) then
            if IsSpellReady("Hammer of Justice") then
                dbg("|cffff0000[PCA] Auto-Stun: Casting Hammer of Justice|r")
                CastSpellByName("Hammer of Justice")
                return
            end
        end
    end

    -- ── 1) BUFF LOGIC ────────────────────────────────────────────────────────
    -- We check these first and return early if a cast is triggered.
    if PCA_EnsureRF()        then return end
    if PCA_EnsureBlessing()  then return end
    if PCA_EnsureAura()      then return end

    local openerSpell = PCA_Config.OpenerSpell or defaultOpener

    ----------------------------------------------------------------
    -- 2) PRE-BUFF / OPENER
    ----------------------------------------------------------------
    if not UnitExists("target") or UnitIsDead("target") then
            -- No target found (or out of combat) — apply pre-buff if configured
            local inCombat = UnitAffectingCombat("player")
            if not inCombat then
                if IsSeal(openerSpell) then
                    -- Opener is a seal — apply it
                    if not PlayerHasSeal(openerSpell) then
                        dbg("|cff00ff00[PCA] No Target: Applying opener " .. openerSpell .. "|r")
                        CastSpellByName(openerSpell)
                    end
                end
            else
                -- In combat with no target (and TargetNearestEnemy failed) — maintain first rotation seal
                local rotSpells = GetRotationSpells()
                for _, spell in ipairs(rotSpells) do
                    if spell and IsSeal(spell) and not PlayerHasSeal(spell) then
                        dbg("|cff00ff00[PCA] In Combat (No Target): Applying " .. spell .. "|r")
                        CastSpellByName(spell)
                        return
                    end
                end
            end
            return
    end

    if UnitHealth("target") <= 0 or not UnitCanAttack("player", "target") then
        return
    end

    -- ── Priority Exorcism (Undead/Demon) ─────────────────────────────────────
    if PCA_IsExorcismPriority() and IsSpellReady("Exorcism") then
        dbg("|cffff9900[PCA] Priority Exorcism|r")
        CastSpellByName("Exorcism")
        return
    end

    local inCombat = UnitAffectingCombat("player")

    ----------------------------------------------------------------
    -- 2) OPENER LOGIC (Out of Combat)
    ----------------------------------------------------------------
    if not inCombat then
        if not IsSeal(openerSpell) then
            -- Opener is an attack spell (Holy Strike, Crusader Strike, or combo)
            local castSpell = openerSpell
            if openerSpell == COMBO_HS_CS then
                castSpell = PCA_Config.HSCSToggle or "Holy Strike"
            end
            if IsSpellReady(castSpell) then
                dbg("|cff00ff00[PCA] Opener: " .. castSpell .. "|r")
                CastSpellByName(castSpell)
                if openerSpell == COMBO_HS_CS then
                    PCA_Config.HSCSToggle = (castSpell == "Holy Strike") and "Crusader Strike" or "Holy Strike"
                end
            end
            -- Pre-buff the chosen seal while running in / on GCD
            local prebuff = PCA_Config.OpenerPrebuff or defaultOpenerPrebuff
            if prebuff ~= "None" and not PlayerHasSeal(prebuff) then
                dbg("|cff00ff00[PCA] Opener: Pre-buffing " .. prebuff .. "|r")
                CastSpellByName(prebuff)
            end
        else
            -- Opener is a seal — apply silently as pre-buff
            if not PlayerHasSeal(openerSpell) then
                dbg("|cff00ff00[PCA] Opener: Applying seal " .. openerSpell .. "|r")
                CastSpellByName(openerSpell)
            end
        end
        return
    end

    ----------------------------------------------------------------
    -- 3) COMBAT ROTATION — Strict slot priority: 1 → 2 → 3, then Judgement
    ----------------------------------------------------------------

    -- Always ensure auto-attack is running when we have a target in combat
    PCA_EnsureAutoAttack()

    local rotSpells = GetRotationSpells()

    -- Single loop: each slot evaluated in order; seals applied if missing,
    -- attack spells cast if ready, otherwise skip to the next slot.
    for _, spell in ipairs(rotSpells) do
        if spell then
            if IsSeal(spell) then
                if not PlayerHasSeal(spell) then
                    dbg("|cff00ff00[PCA] Applying " .. spell .. "|r")
                    CastSpellByName(spell)
                    return
                end

                -- If Judging is LIMITED, we allow ONE judgement to apply the utility debuff
                if PCA_Config.JudgingEnabled == false and spell ~= "Seal of Righteousness" and spell ~= "Seal of Command" then
                    local tex = spellTextures[spell]
                    if tex and not HasDebuffTexture("target", tex) then
                        if IsSpellReady("Judgement") then
                            dbg("|cff00ff00[PCA] Judging: Applying initial " .. spell .. " debuff|r")
                            CastSpellByName("Judgement")
                            return
                        end
                        -- If Judgement is on CD, wait for it (high priority to get debuff up)
                        return
                    end
                end

                -- seal already active → fall through to next slot
            elseif string.find(spell, "Blessing of") then
                -- Blessings are handled by PCA_EnsureBlessing() in buff logic
                -- but can also be manually triggered in rotation if desired
                local tex = spellTextures[spell]
                if tex and not HasBuffTexture("player", tex) then
                    if IsSpellReady(spell) then
                        dbg("|cff00ff00[PCA] Casting " .. spell .. "|r")
                        CastSpellByName(spell)
                        return
                    end
                end
            elseif spell == COMBO_HS_CS then
                local nextSpell = PCA_Config.HSCSToggle or "Holy Strike"
                if IsSpellReady(nextSpell) then
                    dbg("|cff00ff00[PCA] Combo: Casting " .. nextSpell .. "|r")
                    CastSpellByName(nextSpell)
                    PCA_Config.HSCSToggle = (nextSpell == "Holy Strike") and "Crusader Strike" or "Holy Strike"
                    return
                end
                -- not ready → fall through to next slot
            else
                if IsSpellReady(spell) then
                    dbg("|cff00ff00[PCA] Casting " .. spell .. "|r")
                    CastSpellByName(spell)
                    return
                end
                -- not ready → fall through to next slot
            end
        end
    end

    -- Judgement filler — cast whenever off cooldown and all higher slots are busy
    if PCA_Config.JudgingEnabled ~= false and IsSpellReady("Judgement") then
        dbg("|cff00ff00[PCA] Judgement|r")
        CastSpellByName("Judgement")
        return
    end

    dbg("|cffff8800[PCA] Waiting for cooldowns|r")
end


-- ── Settings menu ─────────────────────────────────────────────────────────────

local function PCA_GetDebugText()
    if PCA_Config.Debug then return "Debug: ON"
    else return "Debug: OFF" end
end

local function PCA_GetFightingUndeadText()
    if PCA_Config.FightingUndead then return "Fighting Undead: ON"
    else return "Fighting Undead: OFF" end
end

local function PCA_GetJudgingText()
    if PCA_Config.JudgingEnabled ~= false then return "Judging: YES"
    else return "Judging: NO" end
end

local function PCA_GetSmartTargetingText()
    if PCA_Config.SmartTargeting then return "Smart Targeting: ON"
    else return "Smart Targeting: OFF" end
end

local function PCA_GetAutoStunText()
    if PCA_Config.AutoStun then return "Auto Stun: ON"
    else return "Auto Stun: OFF" end
end

local function PCA_GetAssistText()
    if PCA_Config.AssistEnabled then return "Assist: YES"
    else return "Assist: NO" end
end

-- ── Dropdown initializers ─────────────────────────────────────────────────────

local function PCA_OpenerDropdown_Init()
    local current = PCA_Config.OpenerSpell or defaultOpener
    for _, spell in ipairs(openerOptions) do
        if spell ~= "Holy Shield" or FindSpell("Holy Shield") then
            local capture = spell
            local info = {}
            info.text    = spell
            info.checked = (spell == current)
            info.func    = function()
                PCA_Config.OpenerSpell = capture
                UIDropDownMenu_SetText(capture, PCAOpenerDropdown)
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info)
        end
    end
end

local function PCA_OpenerPrebuffDropdown_Init()
    local current = PCA_Config.OpenerPrebuff or defaultOpenerPrebuff
    for _, spell in ipairs(openerPrebuffOptions) do
        local capture = spell
        local info = {}
        info.text    = spell
        info.checked = (spell == current)
        info.func    = function()
            PCA_Config.OpenerPrebuff = capture
            UIDropDownMenu_SetText(capture, PCAOpenerPrebuffDropdown)
            CloseDropDownMenus()
        end
        UIDropDownMenu_AddButton(info)
    end
end

local function PCA_RotationDropdown1_Init()
    local current = PCA_Config.RotationSpell1 or defaultRot1
    for _, spell in ipairs(rotationOptions) do
        if spell ~= "Holy Shield" or FindSpell("Holy Shield") then
            local capture = spell
            local info = {}
            info.text    = spell
            info.checked = (spell == current)
            info.func    = function()
                PCA_Config.RotationSpell1 = capture
                UIDropDownMenu_SetText(capture, PCARotationDropdown1)
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info)
        end
    end
end

local function PCA_RotationDropdown2_Init()
    local current = PCA_Config.RotationSpell2 or defaultRot2
    for _, spell in ipairs(rotationOptions) do
        if spell ~= "Holy Shield" or FindSpell("Holy Shield") then
            local capture = spell
            local info = {}
            info.text    = spell
            info.checked = (spell == current)
            info.func    = function()
                PCA_Config.RotationSpell2 = capture
                UIDropDownMenu_SetText(capture, PCARotationDropdown2)
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info)
        end
    end
end

local function PCA_RotationDropdown3_Init()
    local current = PCA_Config.RotationSpell3 or defaultRot3
    for _, spell in ipairs(rotationOptions) do
        if spell ~= "Holy Shield" or FindSpell("Holy Shield") then
            local capture = spell
            local info = {}
            info.text    = spell
            info.checked = (spell == current)
            info.func    = function()
                PCA_Config.RotationSpell3 = capture
                UIDropDownMenu_SetText(capture, PCARotationDropdown3)
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info)
        end
    end
end

local function PCA_RotationDropdown4_Init()
    local current = PCA_Config.RotationSpell4 or defaultRot4
    for _, spell in ipairs(rotationOptions) do
        if spell ~= "Holy Shield" or FindSpell("Holy Shield") then
            local capture = spell
            local info = {}
            info.text    = spell
            info.checked = (spell == current)
            info.func    = function()
                PCA_Config.RotationSpell4 = capture
                UIDropDownMenu_SetText(capture, PCARotationDropdown4)
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info)
        end
    end
end

local function PCA_AuraDropdown_Init()
    local current = PCA_Config.SelectedAura or "None"
    for _, spell in ipairs(auraOptions) do
        local capture = spell
        local info = {}
        info.text    = spell
        info.checked = (spell == current)
        info.func    = function()
            PCA_Config.SelectedAura = capture
            UIDropDownMenu_SetText(capture, PCA_AuraDropdown)
            CloseDropDownMenus()
        end
        UIDropDownMenu_AddButton(info)
    end
end

local function PCA_BlessingDropdown_Init()
    local current = PCA_Config.SelectedBlessing or "None"
    for _, blessing in ipairs(blessingOptions) do
        if blessing == "None" or PlayerKnowsBlessing(blessing) then
            local capture = blessing
            local info = {}
            info.text    = blessing
            info.checked = (blessing == current)
            info.func    = function()
                PCA_Config.SelectedBlessing = capture
                UIDropDownMenu_SetText(capture, PCA_BlessingDropdown)
                CloseDropDownMenus()
                if capture ~= "None" then
                    PCA_EnsureBlessing()
                end
            end
            UIDropDownMenu_AddButton(info)
        end
    end
end

-- ── Build the menu ─────────────────────────────────────────────────────────────

-- ── Build the menu ─────────────────────────────────────────────────────────────

function PCA_SetTab(id)
    PCA_Refs.pageRotation:Hide()
    PCA_Refs.pageSettings:Hide()
    PCA_Refs.pageBuffs:Hide()
    PCA_Refs.pageInfo:Hide()
    
    PCA_Refs.tabBtnRot:SetBackdropColor(0, 0, 0, 0.4)
    PCA_Refs.tabBtnSet:SetBackdropColor(0, 0, 0, 0.4)
    PCA_Refs.tabBtnBuf:SetBackdropColor(0, 0, 0, 0.4)
    PCA_Refs.tabBtnInf:SetBackdropColor(0, 0, 0, 0.4)

    if id == 1 then
        PCA_Refs.pageRotation:Show()
        PCA_Refs.tabBtnRot:SetBackdropColor(0.5, 0.1, 0.1, 0.8)
    elseif id == 2 then
        PCA_Refs.pageSettings:Show()
        PCA_Refs.tabBtnSet:SetBackdropColor(0.5, 0.1, 0.1, 0.8)
    elseif id == 3 then
        PCA_Refs.pageBuffs:Show()
        PCA_Refs.tabBtnBuf:SetBackdropColor(0.5, 0.1, 0.1, 0.8)
    else
        PCA_Refs.pageInfo:Show()
        PCA_Refs.tabBtnInf:SetBackdropColor(0.5, 0.1, 0.1, 0.8)
    end
end

local function PCA_BuildMenu()
    local frame = PCAFrame
    
    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -5)
    closeBtn:SetScript("OnClick", function() frame:Hide() end)

    -- ── Tab Buttons ──────────────────────────────────────────────────────────
    local function MakeTab(text, id, x)
        local btn = CreateFrame("Button", nil, frame)
        btn:SetWidth(78)
        btn:SetHeight(18)
        btn:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -63)
        btn:SetBackdrop({
            bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 8, edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        btn:SetBackdropColor(0, 0, 0, 0.4)
        btn:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)

        local t = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        t:SetPoint("CENTER", btn, "CENTER")
        t:SetText(text)
        btn:SetFontString(t)

        btn:SetScript("OnEnter", function() btn:SetBackdropBorderColor(1, 0.82, 0, 1) end)
        btn:SetScript("OnLeave", function() btn:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8) end)
        btn:SetScript("OnClick", function() PCA_SetTab(id) end)
        return btn
    end

    PCA_Refs.tabBtnRot = MakeTab("Rotation", 1, 10)
    PCA_Refs.tabBtnSet = MakeTab("Config",   2, 88)
    PCA_Refs.tabBtnBuf = MakeTab("Buffs",    3, 166)
    PCA_Refs.tabBtnInf = MakeTab("Info",     4, 244)

    -- ── Content Border ───────────────────────────────────────────────────────
    local contentArea = CreateFrame("Frame", nil, frame)
    contentArea:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -55)
    contentArea:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 8)
    contentArea:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
    })
    contentArea:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    -- ── Layout Helpers ──────────────────────────────────────────────────────
    local function MakeLabel(p, text, yOff, xOff)
        local lbl = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("TOP", p, "TOP", xOff or 0, yOff)
        lbl:SetText(text)
        lbl:SetTextColor(1, 0.9, 0)
        return lbl
    end

    local function MakeLabelSmall(p, text, yOff, xOff)
        local lbl = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOP", p, "TOP", xOff or 0, yOff)
        lbl:SetText(text)
        lbl:SetTextColor(0.7, 0.7, 0.7)
        return lbl
    end

    local function MakeDropdown(p, globalName, initFunc, configKey, defaultVal, yOff, xOff)
        local dd = CreateFrame("Frame", globalName, p, "UIDropDownMenuTemplate")
        dd:SetPoint("TOP", p, "TOP", xOff or 0, yOff)
        UIDropDownMenu_SetWidth(120, dd)
        UIDropDownMenu_Initialize(dd, initFunc)
        UIDropDownMenu_SetText(PCA_Config[configKey] or defaultVal, dd)
        return dd
    end

    local function SetTip(f, t)
        f:SetScript("OnEnter", function()
            GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
            GameTooltip:SetText(t, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    -- ── Rotation Page ────────────────────────────────────────────────────────
    PCA_Refs.pageRotation = CreateFrame("Frame", nil, contentArea)
    PCA_Refs.pageRotation:SetAllPoints()

    local yRot = -45
    MakeLabel(PCA_Refs.pageRotation, "Opener Spell", yRot)
    yRot = yRot - 18
    MakeDropdown(PCA_Refs.pageRotation, "PCAOpenerDropdown", PCA_OpenerDropdown_Init, "OpenerSpell", defaultOpener, yRot)
    yRot = yRot - 38

    MakeLabelSmall(PCA_Refs.pageRotation, "  └ Pre-buff (out of range)", yRot)
    yRot = yRot - 16
    MakeDropdown(PCA_Refs.pageRotation, "PCAOpenerPrebuffDropdown", PCA_OpenerPrebuffDropdown_Init, "OpenerPrebuff", defaultOpenerPrebuff, yRot)
    yRot = yRot - 45

    -- Row 1: Slots 1 & 2
    MakeLabel(PCA_Refs.pageRotation, "1.", yRot, -75)
    local drop1 = MakeDropdown(PCA_Refs.pageRotation, "PCARotationDropdown1", PCA_RotationDropdown1_Init, "RotationSpell1", defaultRot1, yRot - 16, -75)
    
    MakeLabel(PCA_Refs.pageRotation, "2.", yRot, 75)
    local drop2 = MakeDropdown(PCA_Refs.pageRotation, "PCARotationDropdown2", PCA_RotationDropdown2_Init, "RotationSpell2", defaultRot2, yRot - 16, 75)
    
    yRot = yRot - 65

    -- Row 2: Slots 3 & 4
    MakeLabel(PCA_Refs.pageRotation, "3.", yRot, -75)
    local drop3 = MakeDropdown(PCA_Refs.pageRotation, "PCARotationDropdown3", PCA_RotationDropdown3_Init, "RotationSpell3", defaultRot3, yRot - 16, -75)
    
    MakeLabel(PCA_Refs.pageRotation, "4.", yRot, 75)
    local drop4 = MakeDropdown(PCA_Refs.pageRotation, "PCARotationDropdown4", PCA_RotationDropdown4_Init, "RotationSpell4", defaultRot4, yRot - 16, 75)
    
    yRot = yRot - 55

    local judgingBtn = CreateFrame("Button", "PCAJudgingBtn", PCA_Refs.pageRotation, "UIPanelButtonTemplate")
    judgingBtn:SetWidth(210)
    judgingBtn:SetHeight(22)
    judgingBtn:SetPoint("TOP", PCA_Refs.pageRotation, "TOP", 0, yRot)
    judgingBtn:SetText(PCA_GetJudgingText())
    judgingBtn:SetScript("OnClick", function()
        PCA_Config.JudgingEnabled = not (PCA_Config.JudgingEnabled ~= false)
        judgingBtn:SetText(PCA_GetJudgingText())
    end)
    PCA_Refs.judgingBtnRef = judgingBtn
    SetTip(judgingBtn, "Toggles whether to use Judgement automatically or wait for manual control.")
    yRot = yRot - 35


    -- ── Settings Page ────────────────────────────────────────────────────────
    PCA_Refs.pageSettings = CreateFrame("Frame", nil, contentArea)
    PCA_Refs.pageSettings:SetAllPoints()
    PCA_Refs.pageSettings:Hide()

    local ySet = -45
    MakeLabel(PCA_Refs.pageSettings, "Tank Name (for Assist)", ySet)
    ySet = ySet - 18
    local editBox = CreateFrame("EditBox", "PCATankNameEdit", PCA_Refs.pageSettings, "InputBoxTemplate")
    editBox:SetWidth(180)
    editBox:SetHeight(20)
    editBox:SetPoint("TOP", PCA_Refs.pageSettings, "TOP", 0, ySet)
    editBox:SetAutoFocus(false)
    editBox:SetText(PCA_Config.AssistTankName or "")
    editBox:SetScript("OnEnterPressed", function()
        PCA_Config.AssistTankName = this:GetText()
        this:ClearFocus()
    end)
    editBox:SetScript("OnEditFocusLost", function()
        PCA_Config.AssistTankName = this:GetText()
    end)
    ySet = ySet - 26

    local assistBtn = CreateFrame("Button", "PCAAssistBtn", PCA_Refs.pageSettings, "UIPanelButtonTemplate")
    assistBtn:SetWidth(210)
    assistBtn:SetHeight(22)
    assistBtn:SetPoint("TOP", PCA_Refs.pageSettings, "TOP", 0, ySet)
    assistBtn:SetText(PCA_GetAssistText())
    assistBtn:SetScript("OnClick", function()
        PCA_Config.AssistEnabled = not PCA_Config.AssistEnabled
        assistBtn:SetText(PCA_GetAssistText())
    end)
    PCA_Refs.assistBtnRef = assistBtn
    SetTip(assistBtn, "Automatically target and assist the player named in the box above.")
    ySet = ySet - 30

    local fightingUndeadBtn = CreateFrame("Button", "PCAFightingUndeadBtn", PCA_Refs.pageSettings, "UIPanelButtonTemplate")
    fightingUndeadBtn:SetWidth(210)
    fightingUndeadBtn:SetHeight(22)
    fightingUndeadBtn:SetPoint("TOP", PCA_Refs.pageSettings, "TOP", 0, ySet)
    fightingUndeadBtn:SetText(PCA_GetFightingUndeadText())
    fightingUndeadBtn:SetScript("OnClick", function()
        PCA_Config.FightingUndead = not PCA_Config.FightingUndead
        fightingUndeadBtn:SetText(PCA_GetFightingUndeadText())
    end)
    PCA_Refs.fightingUndeadBtnRef = fightingUndeadBtn
    SetTip(fightingUndeadBtn, "Gives Exorcism absolute priority if the target is Undead or a Demon.")
    ySet = ySet - 30

    local smartTargetingBtn = CreateFrame("Button", "PCASmartTargetingBtn", PCA_Refs.pageSettings, "UIPanelButtonTemplate")
    smartTargetingBtn:SetWidth(210)
    smartTargetingBtn:SetHeight(22)
    smartTargetingBtn:SetPoint("TOP", PCA_Refs.pageSettings, "TOP", 0, ySet)
    smartTargetingBtn:SetText(PCA_GetSmartTargetingText())
    smartTargetingBtn:SetScript("OnClick", function()
        PCA_Config.SmartTargeting = not PCA_Config.SmartTargeting
        smartTargetingBtn:SetText(PCA_GetSmartTargetingText())
    end)
    PCA_Refs.smartTargetingBtnRef = smartTargetingBtn
    SetTip(smartTargetingBtn, "Automatically targets the nearest enemy if you press the macro without a target.")
    ySet = ySet - 26

    local autoStunBtn = CreateFrame("Button", "PCAAutoStunBtn", PCA_Refs.pageSettings, "UIPanelButtonTemplate")
    autoStunBtn:SetWidth(210)
    autoStunBtn:SetHeight(22)
    autoStunBtn:SetPoint("TOP", PCA_Refs.pageSettings, "TOP", 0, ySet)
    autoStunBtn:SetText(PCA_GetAutoStunText())
    autoStunBtn:SetScript("OnClick", function()
        PCA_Config.AutoStun = not PCA_Config.AutoStun
        autoStunBtn:SetText(PCA_GetAutoStunText())
    end)
    PCA_Refs.autoStunBtnRef = autoStunBtn
    SetTip(autoStunBtn, "Automatically uses Hammer of Justice if the target begins casting within range.")
    ySet = ySet - 26

    local debugBtn = CreateFrame("Button", "PCADebugBtn", PCA_Refs.pageSettings, "UIPanelButtonTemplate")
    debugBtn:SetWidth(210)
    debugBtn:SetHeight(22)
    debugBtn:SetPoint("TOP", PCA_Refs.pageSettings, "TOP", 0, ySet)
    debugBtn:SetText(PCA_GetDebugText())
    debugBtn:SetScript("OnClick", function()
        PCA_Config.Debug = not PCA_Config.Debug
        debugBtn:SetText(PCA_GetDebugText())
    end)
    PCA_Refs.debugBtnRef = debugBtn
    SetTip(debugBtn, "Prints detailed combat logs to your chat window (Very spammy!).")
    ySet = ySet - 40

    local scaleLbl = PCA_Refs.pageSettings:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    scaleLbl:SetPoint("TOP", PCA_Refs.pageSettings, "TOP", -28, ySet)
    scaleLbl:SetText("|cffaaaaaaScale:|r")

    local scaleDownBtn = CreateFrame("Button", nil, PCA_Refs.pageSettings, "UIPanelButtonTemplate")
    scaleDownBtn:SetWidth(26)
    scaleDownBtn:SetHeight(18)
    scaleDownBtn:SetPoint("TOP", PCA_Refs.pageSettings, "TOP", 14, ySet)
    scaleDownBtn:SetText("-")
    scaleDownBtn:SetScript("OnClick", function()
        local s = math.max(0.5, (PCA_Config.UIScale or 0.85) - 0.05)
        PCA_Config.UIScale = s
        PCAFrame:SetScale(s)
    end)
    SetTip(scaleDownBtn, "Decrease the scale of the settings window.")

    local scaleUpBtn = CreateFrame("Button", nil, PCA_Refs.pageSettings, "UIPanelButtonTemplate")
    scaleUpBtn:SetWidth(26)
    scaleUpBtn:SetHeight(18)
    scaleUpBtn:SetPoint("TOP", PCA_Refs.pageSettings, "TOP", 44, ySet)
    scaleUpBtn:SetText("+")
    scaleUpBtn:SetScript("OnClick", function()
        local s = math.min(1.5, (PCA_Config.UIScale or 0.85) + 0.05)
        PCA_Config.UIScale = s
        PCAFrame:SetScale(s)
    end)
    SetTip(scaleUpBtn, "Increase the scale of the settings window.")

    -- ── Buffs Page ───────────────────────────────────────────────────────────
    PCA_Refs.pageBuffs = CreateFrame("Frame", nil, contentArea)
    PCA_Refs.pageBuffs:SetAllPoints()
    PCA_Refs.pageBuffs:Hide()

    local yBuf = -45
    MakeLabel(PCA_Refs.pageBuffs, "Desired Aura", yBuf)
    yBuf = yBuf - 18
    local ddAura = MakeDropdown(PCA_Refs.pageBuffs, "PCA_AuraDropdown", PCA_AuraDropdown_Init, "SelectedAura", "None", yBuf)
    yBuf = yBuf - 40

    local rfBtn = CreateFrame("Button", "PCARighteousFuryBtn", PCA_Refs.pageBuffs, "UIPanelButtonTemplate")
    rfBtn:SetWidth(210)
    rfBtn:SetHeight(22)
    rfBtn:SetPoint("TOP", PCA_Refs.pageBuffs, "TOP", 0, yBuf)
    rfBtn:SetText(PCA_GetRFText())
    rfBtn:SetScript("OnClick", function()
        PCA_Config.MaintainRF = not PCA_Config.MaintainRF
        rfBtn:SetText(PCA_GetRFText())
        if PCA_Config.MaintainRF then PCA_EnsureRF() end
    end)
    PCA_Refs.rfBtnRef = rfBtn
    SetTip(rfBtn, "Automatically maintains Righteous Fury buff if enabled.")
    yBuf = yBuf - 35

    MakeLabel(PCA_Refs.pageBuffs, "Desired Blessing", yBuf)
    yBuf = yBuf - 18
    local ddBlessing = MakeDropdown(PCA_Refs.pageBuffs, "PCA_BlessingDropdown", PCA_BlessingDropdown_Init, "SelectedBlessing", "None", yBuf)
    yBuf = yBuf - 40
    
    local auraHint = PCA_Refs.pageBuffs:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    auraHint:SetPoint("TOP", PCA_Refs.pageBuffs, "TOP", 0, yBuf)
    auraHint:SetWidth(200)
    auraHint:SetText("|cffaaaaaaThe addon will automatically ensure\nthis aura is active whenever you\npress the rotation macro.|r")

    -- ── Info Page ────────────────────────────────────────────────────────────
    PCA_Refs.pageInfo = CreateFrame("Frame", nil, contentArea)
    PCA_Refs.pageInfo:SetAllPoints()
    PCA_Refs.pageInfo:Hide()

    local yInf = -40
    local infoText = PCA_Refs.pageInfo:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    infoText:SetPoint("TOP", PCA_Refs.pageInfo, "TOP", 0, yInf)
    infoText:SetWidth(220)
    infoText:SetJustifyH("CENTER")
    infoText:SetText("|cffffcc00For updates check:|r\nhttps://github.com/stephanancher/PaladinCore\n\n\n|cffffffffThis addon is made for my friend|r\n|cff00ff00Hyneron|r\n|cffffffffon Turtle WoW...|r\n\n|cffff99ffhugs|r")
    
    yInf = yInf - 140
    local divider = PCA_Refs.pageInfo:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    divider:SetPoint("TOP", PCA_Refs.pageInfo, "TOP", 0, yInf)
    divider:SetTextColor(1, 0.82, 0)
    divider:SetText("─────  Drag to Action Bar  ─────")
    yInf = yInf - 22

    local dragBtn = CreateFrame("Frame", "PCADragBtn", PCA_Refs.pageInfo)
    dragBtn:SetWidth(36)
    dragBtn:SetHeight(36)
    dragBtn:SetPoint("TOP", PCA_Refs.pageInfo, "TOP", -55, yInf - 2)
    dragBtn:EnableMouse(true)
    dragBtn:RegisterForDrag("LeftButton")
    dragBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-EmptySlot-White",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    dragBtn:SetBackdropColor(0.05, 0.05, 0.4, 0.95)
    dragBtn:SetBackdropBorderColor(0.8, 0.7, 0.2, 1)

    local initTex = spellTextures[PCA_Config.RotationSpell1 or defaultRot1] or "Ability_ThunderBolt"
    local dragTex = dragBtn:CreateTexture(nil, "ARTWORK")
    dragTex:SetTexture("Interface\\Icons\\" .. initTex)
    dragTex:SetPoint("TOPLEFT",     dragBtn, "TOPLEFT",     3, -3)
    dragTex:SetPoint("BOTTOMRIGHT", dragBtn, "BOTTOMRIGHT", -3,  3)
    PCA_Refs.dragBtnTex = dragTex

    local dragHint = PCA_Refs.pageInfo:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dragHint:SetPoint("LEFT", dragBtn, "RIGHT", 6, 0)
    dragHint:SetJustifyH("LEFT")
    dragHint:SetText("|cffaaaaaa← Drag onto\nan action bar slot|r")

    dragBtn:SetScript("OnDragStart", function()
        local idx = PCA_GetMacroIndex("PalCore")
        if idx and idx > 0 then
            PickupMacro(idx)
        end
    end)
    dragBtn:SetScript("OnEnter", function()
        dragBtn:SetBackdropColor(0.1, 0.1, 0.7, 1)
        dragBtn:SetBackdropBorderColor(1, 1, 1, 1)
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("|cffffcc00PalCore Macro|r")
        GameTooltip:AddLine("Drag this button to any action bar slot.", 1, 1, 1)
        GameTooltip:AddLine("That slot will then show the next predicted", 0.7, 0.7, 0.7, 1)
        GameTooltip:AddLine("spell and its cooldown.", 0.7, 0.7, 0.7, 1)
        GameTooltip:Show()
    end)
    dragBtn:SetScript("OnLeave", function()
        dragBtn:SetBackdropColor(0.05, 0.05, 0.4, 0.95)
        dragBtn:SetBackdropBorderColor(0.8, 0.7, 0.2, 1)
        GameTooltip:Hide()
    end)

    local reloadBtn = CreateFrame("Button", nil, PCA_Refs.pageInfo, "UIPanelButtonTemplate")
    reloadBtn:SetWidth(120)
    reloadBtn:SetHeight(26)
    reloadBtn:SetPoint("BOTTOM", PCA_Refs.pageInfo, "BOTTOM", 0, 30)
    reloadBtn:SetText("Reload UI")
    reloadBtn:SetScript("OnClick", function() ReloadUI() end)

    PCA_SetTab(1)
    PCA_State.menuBuilt = true
end

function PCA_UpdateButtons()
    if PCAOpenerDropdown then
        UIDropDownMenu_SetText(PCA_Config.OpenerSpell or defaultOpener, PCAOpenerDropdown)
    end
    if PCAOpenerPrebuffDropdown then
        UIDropDownMenu_SetText(PCA_Config.OpenerPrebuff or defaultOpenerPrebuff, PCAOpenerPrebuffDropdown)
    end
    if PCARotationDropdown1 then
        UIDropDownMenu_SetText(PCA_Config.RotationSpell1 or defaultRot1, PCARotationDropdown1)
    end
    if PCARotationDropdown2 then
        UIDropDownMenu_SetText(PCA_Config.RotationSpell2 or defaultRot2, PCARotationDropdown2)
    end
    if PCARotationDropdown3 then
        UIDropDownMenu_SetText(PCA_Config.RotationSpell3 or defaultRot3, PCARotationDropdown3)
    end
    if PCARotationDropdown4 then
        UIDropDownMenu_SetText(PCA_Config.RotationSpell4 or defaultRot4, PCARotationDropdown4)
    end
    if PCA_AuraDropdown then
        UIDropDownMenu_SetText(PCA_Config.SelectedAura or "None", PCA_AuraDropdown)
    end
    if PCA_Refs.rfBtnRef then
        PCA_Refs.rfBtnRef:SetText(PCA_GetRFText())
    end
end

function PCA_OpenMenu()
    if not PCA_State.menuBuilt then PCA_BuildMenu() end
    PCA_UpdateButtons()
    if PCA_Refs.debugBtnRef then PCA_Refs.debugBtnRef:SetText(PCA_GetDebugText()) end
    if PCA_Refs.fightingUndeadBtnRef then PCA_Refs.fightingUndeadBtnRef:SetText(PCA_GetFightingUndeadText()) end
    if PCA_Refs.smartTargetingBtnRef then PCA_Refs.smartTargetingBtnRef:SetText(PCA_GetSmartTargetingText()) end
    if PCA_Refs.autoStunBtnRef then PCA_Refs.autoStunBtnRef:SetText(PCA_GetAutoStunText()) end
    if PCA_Refs.judgingBtnRef then PCA_Refs.judgingBtnRef:SetText(PCA_GetJudgingText()) end
    if PCA_Refs.assistBtnRef then PCA_Refs.assistBtnRef:SetText(PCA_GetAssistText()) end
    if PCA_Refs.rfBtnRef then PCA_Refs.rfBtnRef:SetText(PCA_GetRFText()) end
    if PCATankNameEdit then PCATankNameEdit:SetText(PCA_Config.AssistTankName or "") end
    PCAFrame:SetScale(PCA_Config.UIScale or 0.85)
    PCAFrame:Show()
end

-- ── Slash Commands ────────────────────────────────────────────────────────────

SLASH_PCA1 = "/pca"
SlashCmdList["PCA"] = function(msg)
    local cmd = string.lower(msg or "")
    if string.find(cmd, "sync") then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[PaladinCore]|r Requesting version from group...")
        PCA_SendSync("REQ")
    elseif string.find(cmd, "buffs") then
        PCA_DebugBuffs()
    else
        PCA_OpenMenu()
    end
end

SLASH_PCABUFFS1 = "/pcabuffs"
SlashCmdList["PCABUFFS"] = PCA_DebugBuffs
