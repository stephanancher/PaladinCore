PCA_Config = PCA_Config or {}

local PCA_VERSION = "1.4.1"

local defaultOpener        = "Holy Strike"
local defaultOpenerPrebuff = "Seal of Righteousness"
local defaultRot1          = "Seal of Righteousness"
local defaultRot2          = "None"
local defaultRot3          = "None"

-- Special alternating combo option (shares cooldown, handled in script)
local COMBO_HS_CS = "Holy Strike / Crusader Strike"

local menuBuilt        = false
local debugBtnRef      = nil
local dragBtnTex       = nil
local iconUpdateTick   = 0
local cdScanTimer      = 0      -- counts up; re-scans for the macro action button every 5 s
local palCoreCdFrame   = nil    -- action bar button frame for PalCore macro
local autoAttackTick   = 0      -- counts icon ticks; fires auto-attack check every ~1 s
local pca_autoAttacking = false  -- true once we have called AttackTarget(); reset by events

-- Texture short-names for icon/buff detection.
-- DevNote: Seal of the Crusader buff texture is "Spell_Holy_HolySmite"
local spellTextures = {
    ["Seal of Righteousness"]        = "Ability_ThunderBolt",
    ["Seal of Command"]              = "Ability_Thunderbolt",
    ["Seal of Wisdom"]               = "Spell_Holy_RighteousnessAura",
    ["Seal of Light"]                = "Spell_Holy_SealOfLight",
    ["Seal of Justice"]              = "Spell_Holy_SealOfWrath",
    ["Seal of the Crusader"]         = "Spell_Holy_HolySmite",
    ["Holy Strike"]                  = "Ability_Paladin_HolyStrike",
    ["Crusader Strike"]              = "Spell_Holy_CrusaderStrike",
    ["Holy Strike / Crusader Strike"] = "Ability_Paladin_HolyStrike",  -- default icon; alternates dynamically
    ["Consecration"]                 = "Spell_Holy_Consecration",
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
    "Holy Strike",
    "Crusader Strike",
    COMBO_HS_CS,
    "Seal of Righteousness",
    "Seal of Command",
    "Seal of the Crusader",
    "Seal of Wisdom",
    "Seal of Light",
    "Seal of Justice",
}

-- Pre-buff seal options (shown under opener; used when running in)
local openerPrebuffOptions = {
    "None",
    "Seal of Righteousness",
    "Seal of Command",
    "Seal of the Crusader",
    "Seal of Wisdom",
    "Seal of Light",
    "Seal of Justice",
}

-- Rotation slot dropdown options (None = skip this slot)
local rotationOptions = {
    "None",
    "Seal of Righteousness",
    "Seal of Command",
    "Seal of the Crusader",
    "Seal of Wisdom",
    "Seal of Light",
    "Seal of Justice",
    "Holy Strike",
    "Crusader Strike",
    COMBO_HS_CS,
    "Consecration",
}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function IsSeal(name)
    return sealNames[name] == true
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

-- ── Auto-attack guardian ──────────────────────────────────────────────────────
-- Tracks whether we have already started auto-attack via a flag.
-- AttackTarget() is a toggle in vanilla WoW, so we only call it once per
-- engagement. The flag is reset when the target changes or combat ends.
local function PCA_EnsureAutoAttack()
    if not UnitExists("target") or UnitIsDead("target") then
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
    return ct == "Undead"
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

    -- If Stop Judging is ON, we don't swap to SoR (we keep our utility seal up)
    if PCA_Config.StopJudging then return spellName end

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
                if not PlayerHasSeal(spell) then return 0, 0 end  -- applying seal

                -- If Stop Judging is ON, the next critical action might be Judgement (to apply debuff)
                if PCA_Config.StopJudging and spell ~= "Seal of Righteousness" and spell ~= "Seal of Command" then
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
                return spellTextures[prebuff] or fallbackTex, true
            end
            -- Fighting Undead: Exorcism after pre-buff
            if PCA_Config.FightingUndead and UnitExists("target") and IsTargetUndead() then
                local sealToCheck = (prebuff ~= "None") and prebuff or (PCA_Config.RotationSpell1 or defaultRot1)
                if PlayerHasSeal(sealToCheck) then
                    local exIcon = PCA_GetSpellIconShortName("Exorcism") or fallbackTex
                    return exIcon, IsSpellReady("Exorcism")
                end
            end
            return PCA_GetSpellIconShortName(castSpell) or fallbackTex, IsSpellReady(castSpell)
        else
            if not PlayerHasSeal(openerSpell) then
                return spellTextures[openerSpell] or fallbackTex, true
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
                    return spellTextures[spell] or fallbackTex, true
                end

                -- If Stop Judging is ON, we allow ONE judgement to apply the utility debuff
                if PCA_Config.StopJudging and spell ~= "Seal of Righteousness" and spell ~= "Seal of Command" then
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
    if not PCA_Config.StopJudging and IsSpellReady("Judgement") then
        return judgeIcon, true
    end

    -- Everything is on cooldown; show the first busy slot dimmed
    return firstOnCdIcon or judgeIcon, false
end

-- ── Addon load ────────────────────────────────────────────────────────────────

function PCA_OnLoad()
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
    if PCA_Config.Debug          == nil then PCA_Config.Debug          = false end
    if PCA_Config.FightingUndead == nil then PCA_Config.FightingUndead = false end
    if PCA_Config.StopJudging    == nil then PCA_Config.StopJudging    = false end
    if PCA_Config.AssistEnabled  == nil then PCA_Config.AssistEnabled  = false end
    if PCA_Config.AssistTankName == nil then PCA_Config.AssistTankName = ""    end
    if PCA_Config.MinimapPos     == nil then PCA_Config.MinimapPos     = 45   end
    if PCA_Config.UIScale        == nil then PCA_Config.UIScale        = 0.85 end

    -- Set title to full name + version
    if PCATitle then
        PCATitle:SetText("PaladinCore  V" .. PCA_VERSION)
    end
    if PCASubTitle then
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
    iconFrame:RegisterEvent("PLAYER_REGEN_ENABLED")   -- left combat
    iconFrame:RegisterEvent("PLAYER_TARGET_CHANGED")  -- new target needs attacking
    iconFrame:SetScript("OnEvent", function()
        if event == "VARIABLES_LOADED" then
            if PCA_MinimapButton_UpdatePosition then
                PCA_MinimapButton_UpdatePosition()
            end
        elseif event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_TARGET_CHANGED" then
            -- Reset auto-attack flag so PCA_EnsureAutoAttack() will re-engage on next check
            pca_autoAttacking = false
        end
    end)

    iconFrame:SetScript("OnUpdate", function()
        iconUpdateTick = iconUpdateTick + arg1
        if iconUpdateTick < 0.33 then return end
        iconUpdateTick = 0

        local shortName, isReady = PCA_GetNextActionInfo()

        -- Dim the settings-panel drag button when next spell is on cooldown
        if dragBtnTex then
            dragBtnTex:SetTexture("Interface\\Icons\\" .. shortName)
            if isReady then
                dragBtnTex:SetVertexColor(1, 1, 1)
            else
                dragBtnTex:SetVertexColor(0.35, 0.35, 0.35)
            end
        end

        local macroIdx = PCA_GetMacroIndex("PalCore")
        if macroIdx and macroIdx > 0 then
            -- Keep the macro icon synced to next action
            EditMacro(macroIdx, "PalCore", shortName, "/script paladincore()", nil, nil)

            -- Re-scan for the action bar button every 5 seconds
            cdScanTimer = cdScanTimer + 0.33
            if cdScanTimer >= 5 or palCoreCdFrame == nil then
                cdScanTimer = 0
                palCoreCdFrame = nil

                -- GetActionText is vanilla-1.12 compatible; returns macro name for macro slots.
                if GetActionText then
                    local page    = (GetActionBarPage and GetActionBarPage()) or 1
                    local pageOff = (page - 1) * 12
                    for i = 1, 12 do
                        if GetActionText(pageOff + i) == "PalCore" then
                            palCoreCdFrame = _G["ActionButton" .. i]  -- the button frame itself
                            break
                        end
                    end

                    if not palCoreCdFrame then
                        local extraBars = {
                            { 24, "MultiBarBottomRightButton" },
                            { 36, "MultiBarBottomLeftButton"  },
                            { 48, "MultiBarRightButton"       },
                            { 60, "MultiBarLeftButton"        },
                        }
                        for _, bc in ipairs(extraBars) do
                            for i = 1, 12 do
                                if GetActionText(bc[1] + i) == "PalCore" then
                                    palCoreCdFrame = _G[bc[2] .. i]
                                    break
                                end
                            end
                            if palCoreCdFrame then break end
                        end
                    end
                end
            end

            -- Dim the action bar button when the next spell is on cooldown
            if palCoreCdFrame then
                palCoreCdFrame:SetAlpha(isReady and 1.0 or 0.45)
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
    -- ── 0) ASSIST LOGIC ──────────────────────────────────────────────────────
    if PCA_Config.AssistEnabled and PCA_Config.AssistTankName and PCA_Config.AssistTankName ~= "" then
        TargetByName(PCA_Config.AssistTankName, true)
        AssistUnit("target")
    end

    local openerSpell = PCA_Config.OpenerSpell or defaultOpener

    ----------------------------------------------------------------
    -- 1) ACQUIRE TARGET
    ----------------------------------------------------------------
    if not UnitExists("target") or UnitIsDead("target") then
        dbg("|cffff0000[PCA] No/dead target → TargetNearestEnemy|r")
        TargetNearestEnemy()
        if not UnitExists("target") or UnitIsDead("target") then
            -- No target found — apply pre-buff if configured
            local inCombat = UnitAffectingCombat("player")
            if not inCombat then
                if not IsSeal(openerSpell) then
                    -- Opener is an attack spell — nothing to pre-buff here
                else
                    -- Opener is a seal — apply it
                    if not PlayerHasSeal(openerSpell) then
                        dbg("|cff00ff00[PCA] No Target: Applying opener " .. openerSpell .. "|r")
                        CastSpellByName(openerSpell)
                    end
                end
            else
                -- In combat with no target — maintain first rotation seal
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
    end

    if UnitHealth("target") <= 0 then
        dbg("|cffff0000[PCA] Target HP <= 0 → abort|r")
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
            elseif PCA_Config.FightingUndead and PlayerHasSeal(prebuff ~= "None" and prebuff or (PCA_Config.RotationSpell1 or defaultRot1)) and IsTargetUndead() and IsSpellReady("Exorcism") then
                -- Pre-buff seal is up and target is undead — cast Exorcism before engaging
                dbg("|cffff9900[PCA] Fighting Undead: Exorcism|r")
                CastSpellByName("Exorcism")
                AttackTarget()  -- start auto-attack (Exorcism is a spell, doesn't do this automatically)
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

                -- If Stop Judging is ON, we allow ONE judgement to apply the utility debuff
                if PCA_Config.StopJudging and spell ~= "Seal of Righteousness" and spell ~= "Seal of Command" then
                    local tex = spellTextures[spell]
                    if tex and not HasDebuffTexture("target", tex) then
                        if IsSpellReady("Judgement") then
                            dbg("|cff00ff00[PCA] StopJudging: Applying initial " .. spell .. " debuff|r")
                            CastSpellByName("Judgement")
                            return
                        end
                        -- If Judgement is on CD, wait for it (high priority to get debuff up)
                        return
                    end
                end

                -- seal already active → fall through to next slot
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
    if not PCA_Config.StopJudging and IsSpellReady("Judgement") then
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

local function PCA_GetStopJudgingText()
    if PCA_Config.StopJudging then return "Stop Judging: ON"
    else return "Stop Judging: OFF" end
end

local function PCA_GetAssistText()
    if PCA_Config.AssistEnabled then return "Assist: YES"
    else return "Assist: NO" end
end

local fightingUndeadBtnRef = nil
local stopJudgingBtnRef    = nil
local assistBtnRef         = nil

-- ── Dropdown initializers ─────────────────────────────────────────────────────

local function PCA_OpenerDropdown_Init()
    local current = PCA_Config.OpenerSpell or defaultOpener
    for _, spell in ipairs(openerOptions) do
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

local function PCA_RotationDropdown2_Init()
    local current = PCA_Config.RotationSpell2 or defaultRot2
    for _, spell in ipairs(rotationOptions) do
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

local function PCA_RotationDropdown3_Init()
    local current = PCA_Config.RotationSpell3 or defaultRot3
    for _, spell in ipairs(rotationOptions) do
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

-- ── Build the menu ─────────────────────────────────────────────────────────────

local function PCA_BuildMenu()
    local frame   = PCAFrame
    local yOffset = -50

    local function MakeLabel(text, yOff)
        local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("TOP", frame, "TOP", 0, yOff)
        lbl:SetText(text)
    end

    local function MakeDropdown(globalName, initFunc, configKey, defaultVal, yOff)
        local dd = CreateFrame("Frame", globalName, frame, "UIDropDownMenuTemplate")
        dd:SetPoint("TOP", frame, "TOP", 0, yOff)
        UIDropDownMenu_SetWidth(160, dd)
        UIDropDownMenu_Initialize(dd, initFunc)
        UIDropDownMenu_SetText(PCA_Config[configKey] or defaultVal, dd)
        return dd
    end

    -- ── Opener ──────────────────────────────────────────────────────────────
    MakeLabel("|cffffcc00Opener Spell:|r", yOffset)
    yOffset = yOffset - 20
    MakeDropdown("PCAOpenerDropdown", PCA_OpenerDropdown_Init, "OpenerSpell", defaultOpener, yOffset)
    yOffset = yOffset - 42

    MakeLabel("|cffaaaaaa  └ Pre-buff (out of range):|r", yOffset)
    yOffset = yOffset - 20
    MakeDropdown("PCAOpenerPrebuffDropdown", PCA_OpenerPrebuffDropdown_Init, "OpenerPrebuff", defaultOpenerPrebuff, yOffset)
    yOffset = yOffset - 42

    -- ── Rotation Slot 1 ─────────────────────────────────────────────────────
    MakeLabel("|cff88ccff1. Rotation Spell  (highest priority)|r", yOffset)
    yOffset = yOffset - 20
    MakeDropdown("PCARotationDropdown1", PCA_RotationDropdown1_Init, "RotationSpell1", defaultRot1, yOffset)
    yOffset = yOffset - 42

    -- ── Rotation Slot 2 ─────────────────────────────────────────────────────
    MakeLabel("|cff88ccff2. Rotation Spell|r", yOffset)
    yOffset = yOffset - 20
    MakeDropdown("PCARotationDropdown2", PCA_RotationDropdown2_Init, "RotationSpell2", defaultRot2, yOffset)
    yOffset = yOffset - 42

    -- ── Rotation Slot 3 ─────────────────────────────────────────────────────
    MakeLabel("|cff88ccff3. Rotation Spell  (lowest priority)|r", yOffset)
    yOffset = yOffset - 20
    MakeDropdown("PCARotationDropdown3", PCA_RotationDropdown3_Init, "RotationSpell3", defaultRot3, yOffset)
    yOffset = yOffset - 46

    -- ── Divider ──────────────────────────────────────────────────────────────
    local sep = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sep:SetPoint("TOP", frame, "TOP", 0, yOffset)
    sep:SetText("|cff555555──────────────────────────|r")
    yOffset = yOffset - 16

    -- ── Stop Judging toggle ──────────────────────────────────────────────────
    local stopJudgingBtn = CreateFrame("Button", "PCAStopJudgingBtn", frame, "UIPanelButtonTemplate")
    stopJudgingBtn:SetWidth(210)
    stopJudgingBtn:SetHeight(22)
    stopJudgingBtn:SetPoint("TOP", frame, "TOP", 0, yOffset)
    stopJudgingBtn:SetText(PCA_GetStopJudgingText())
    stopJudgingBtn:SetScript("OnClick", function()
        PCA_Config.StopJudging = not PCA_Config.StopJudging
        stopJudgingBtn:SetText(PCA_GetStopJudgingText())
    end)
    stopJudgingBtnRef = stopJudgingBtn
    yOffset = yOffset - 26

    -- ── Assist Tank ──────────────────────────────────────────────────────────
    MakeLabel("|cffffcc00Tank Name (for Assist):|r", yOffset)
    yOffset = yOffset - 18
    local editBox = CreateFrame("EditBox", "PCATankNameEdit", frame, "InputBoxTemplate")
    editBox:SetWidth(180)
    editBox:SetHeight(20)
    editBox:SetPoint("TOP", frame, "TOP", 0, yOffset)
    editBox:SetAutoFocus(false)
    editBox:SetText(PCA_Config.AssistTankName or "")
    editBox:SetScript("OnEnterPressed", function()
        PCA_Config.AssistTankName = this:GetText()
        this:ClearFocus()
    end)
    editBox:SetScript("OnEditFocusLost", function()
        PCA_Config.AssistTankName = this:GetText()
    end)
    yOffset = yOffset - 26

    local assistBtn = CreateFrame("Button", "PCAAssistBtn", frame, "UIPanelButtonTemplate")
    assistBtn:SetWidth(210)
    assistBtn:SetHeight(22)
    assistBtn:SetPoint("TOP", frame, "TOP", 0, yOffset)
    assistBtn:SetText(PCA_GetAssistText())
    assistBtn:SetScript("OnClick", function()
        PCA_Config.AssistEnabled = not PCA_Config.AssistEnabled
        assistBtn:SetText(PCA_GetAssistText())
    end)
    assistBtnRef = assistBtn
    yOffset = yOffset - 30

    -- ── Fighting Undead toggle ────────────────────────────────────────────────
    local fightingUndeadBtn = CreateFrame("Button", "PCAFightingUndeadBtn", frame, "UIPanelButtonTemplate")
    fightingUndeadBtn:SetWidth(210)
    fightingUndeadBtn:SetHeight(22)
    fightingUndeadBtn:SetPoint("TOP", frame, "TOP", 0, yOffset)
    fightingUndeadBtn:SetText(PCA_GetFightingUndeadText())
    fightingUndeadBtn:SetScript("OnClick", function()
        PCA_Config.FightingUndead = not PCA_Config.FightingUndead
        fightingUndeadBtn:SetText(PCA_GetFightingUndeadText())
    end)
    fightingUndeadBtnRef = fightingUndeadBtn
    yOffset = yOffset - 26

    -- ── Debug toggle ─────────────────────────────────────────────────────────
    local debugBtn = CreateFrame("Button", "PCADebugBtn", frame, "UIPanelButtonTemplate")
    debugBtn:SetWidth(210)
    debugBtn:SetHeight(22)
    debugBtn:SetPoint("TOP", frame, "TOP", 0, yOffset)
    debugBtn:SetText(PCA_GetDebugText())
    debugBtn:SetScript("OnClick", function()
        PCA_Config.Debug = not PCA_Config.Debug
        debugBtn:SetText(PCA_GetDebugText())
    end)
    debugBtnRef = debugBtn
    yOffset = yOffset - 26

    -- ── Drag-to-action-bar ────────────────────────────────────────────────────
    local divider = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    divider:SetPoint("TOP", frame, "TOP", 0, yOffset)
    divider:SetText("|cffffcc00─────  Drag to Action Bar  ─────|r")
    yOffset = yOffset - 22

    local dragBtn = CreateFrame("Frame", "PCADragBtn", frame)
    dragBtn:SetWidth(36)
    dragBtn:SetHeight(36)
    dragBtn:SetPoint("TOP", frame, "TOP", -55, yOffset - 2)
    dragBtn:EnableMouse(true)
    dragBtn:RegisterForDrag("LeftButton")
    dragBtn:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    dragBtn:SetBackdropColor(0.05, 0.05, 0.4, 0.95)
    dragBtn:SetBackdropBorderColor(0.8, 0.7, 0.2, 1)

    local initTex = spellTextures[PCA_Config.RotationSpell1 or defaultRot1] or "Ability_ThunderBolt"
    local dragTex = dragBtn:CreateTexture(nil, "ARTWORK")
    dragTex:SetTexture("Interface\\Icons\\" .. initTex)
    dragTex:SetPoint("TOPLEFT",     dragBtn, "TOPLEFT",     3, -3)
    dragTex:SetPoint("BOTTOMRIGHT", dragBtn, "BOTTOMRIGHT", -3,  3)
    dragBtnTex = dragTex

    local dragHint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dragHint:SetPoint("LEFT", dragBtn, "RIGHT", 6, 0)
    dragHint:SetJustifyH("LEFT")
    dragHint:SetText("|cffaaaaaa← Drag onto\nan action bar slot|r")

    dragBtn:SetScript("OnDragStart", function()
        local idx = PCA_EnsureMacro()
        if idx and idx > 0 then
            PickupMacro(idx)
        else
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cffff4444PaladinCore:|r Could not create macro — macro list may be full.")
        end
    end)
    dragBtn:SetScript("OnEnter", function()
        dragBtn:SetBackdropColor(0.1, 0.1, 0.6, 1)
        dragBtn:SetBackdropBorderColor(1, 0.9, 0.3, 1)
        GameTooltip:SetOwner(dragBtn, "ANCHOR_RIGHT")
        GameTooltip:AddLine("PaladinCore Rotation", 1, 1, 0)
        GameTooltip:AddLine("Drag to an action bar slot.", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Runs your full seal rotation.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    dragBtn:SetScript("OnLeave", function()
        dragBtn:SetBackdropColor(0.05, 0.05, 0.4, 0.95)
        dragBtn:SetBackdropBorderColor(0.8, 0.7, 0.2, 1)
        GameTooltip:Hide()
    end)

    -- ── Scale controls ────────────────────────────────────────────────────────
    local scaleLbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    scaleLbl:SetPoint("TOP", frame, "TOP", -28, yOffset)
    scaleLbl:SetText("|cffaaaaaaScale:|r")

    local scaleDownBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    scaleDownBtn:SetWidth(26)
    scaleDownBtn:SetHeight(18)
    scaleDownBtn:SetPoint("TOP", frame, "TOP", 14, yOffset)
    scaleDownBtn:SetText("-")
    scaleDownBtn:SetScript("OnClick", function()
        local s = math.max(0.5, (PCA_Config.UIScale or 0.85) - 0.05)
        PCA_Config.UIScale = s
        PCAFrame:SetScale(s)
    end)

    local scaleUpBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    scaleUpBtn:SetWidth(26)
    scaleUpBtn:SetHeight(18)
    scaleUpBtn:SetPoint("TOP", frame, "TOP", 44, yOffset)
    scaleUpBtn:SetText("+")
    scaleUpBtn:SetScript("OnClick", function()
        local s = math.min(1.5, (PCA_Config.UIScale or 0.85) + 0.05)
        PCA_Config.UIScale = s
        PCAFrame:SetScale(s)
    end)
    yOffset = yOffset - 28

    menuBuilt = true
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
end

function PCA_OpenMenu()
    if not menuBuilt then PCA_BuildMenu() end
    PCA_UpdateButtons()
    if debugBtnRef then debugBtnRef:SetText(PCA_GetDebugText()) end
    if fightingUndeadBtnRef then fightingUndeadBtnRef:SetText(PCA_GetFightingUndeadText()) end
    if stopJudgingBtnRef then stopJudgingBtnRef:SetText(PCA_GetStopJudgingText()) end
    if assistBtnRef then assistBtnRef:SetText(PCA_GetAssistText()) end
    if PCATankNameEdit then PCATankNameEdit:SetText(PCA_Config.AssistTankName or "") end
    PCAFrame:SetScale(PCA_Config.UIScale or 0.85)
    PCAFrame:Show()
end
