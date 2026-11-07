-- Octofury: one-button Berserker Stance DPS for warriors (1.12 client, Octowow/Turtle data).
-- Spam /dps in combat. Priority, built from the server's own Spell.dbc (patch-O.mpq):
--   Bloodthirst  30 rage, 6s cd, 200 + 35% AP          (best single-target button)
--   Whirlwind    25 rage, 10s cd, hits up to 4 enemies  (best button on 2+ mobs)
--   Execute      15 rage + 15 dmg per extra rage (more with Precision Cut), <= 20% hp
--   Heroic Strike / Cleave: off the GCD, queued only with rage left over for BT/WW
--   Berserker Rage: +10 rage with Improved Berserker Rage, but it uses a GCD -> filler only
--   Slam: 15 rage, 2.5s cast. With a two-hander, the top MC Fury warriors on the
--     Chronicle logs (Oct 2026) start it right after a main-hand swing, so it lands just
--     before the next one, and Heroic Strike becomes the overflow. Dual wield never Slams.
-- Spam /dps sunder instead to run the same rotation plus Sunder Armor whenever it's a DPS gain.

local defaults = {
  aoe = "auto",   -- "auto" (Whirlwind/Cleave counts), "on", "off"
  hsRage = 40,    -- never queue Heroic Strike/Cleave below this much rage
  cds = "smart",  -- "smart": on cooldown vs elites, bosses, packs or a healthy mob; "always", "elite", "boss", "off"
  trinkets = true, -- use on-use trinkets with the other cooldowns
  pummel = true,
  shout = true,
  sit = false,    -- sit to take a crit when the Enrage talent's buff is down (sitting = next hit crits)
  slam = true,    -- two-hander only: Slam right after each swing
  debug = false,
}

local SLAM_WINDOW = 0.6 -- start Slam only this soon after a main-hand swing

local ICON_ENRAGE = "Spell_Shadow_UnholyFrenzy" -- the talent's buff (spells 12880, 14201-14204)
local SIT_GAP = 3   -- never sit more often than this, in case the crit never comes
local SIT_WAIT = 2  -- hold the rotation this long after sitting, so a cast doesn't stand us up before the hit
local SIT_MIN_HP = 0.5

local state = {
  autoAttack = false, queueUntil = 0, aoeHits = 0, aoeHitTime = 0, aoeCastTime = 0,
  castUntil = 0, lastCast = nil, lastSit = 0, sitUntil = 0,
  sitPending = false, lastTick = 0, fight = {},
  lastSwing = 0, slamUntil = 0,
  sunder = { stacks = 0, last = 0, prevLast = 0, own = 0, others = 0 },
  sunderImmune = {}, ttd = {}, dealt = 0, dealtStart = 0,
}

local ICON_SHOUT = "Ability_Warrior_BattleShout"
local ICON_HS = "Ability_Rogue_Ambush"
local ICON_CLEAVE = "Ability_Warrior_Cleave"
-- on-use trinkets that shouldn't be burned for damage
local SKIP_TRINKETS = { "Insignia of the", "Medallion of", "Hearthstone", "Carrot on a Stick" }

local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage("|cffff6600Octofury|r: " .. msg) end
local function Debug(msg) if Octofury_DB.debug then Print("|cff888888" .. msg .. "|r") end end

--------------------------------------------------
-- Spellbook / talents

local spells = {}
local talents = {}

local function ScanSpells()
  spells = {}
  local i = 1
  while true do
    local n = GetSpellName(i, BOOKTYPE_SPELL)
    if not n then break end
    spells[n] = i -- last match = highest rank
    i = i + 1
  end
end

local function ScanTalents()
  talents = {}
  for tab = 1, GetNumTalentTabs() do
    for i = 1, GetNumTalents(tab) do
      local name, _, _, _, rank = GetTalentInfo(tab, i)
      if name then talents[name] = rank end
    end
  end
end

local function Talent(name) return talents[name] or 0 end

local function Known(name) return spells[name] ~= nil end

local function CDLeft(name)
  local i = spells[name]
  if not i then return 999 end
  local start, dur = GetSpellCooldown(i, BOOKTYPE_SPELL)
  if start == 0 or dur <= 1.5 then return 0 end -- the global cooldown doesn't count
  return start + dur - GetTime()
end

local function Ready(name) return Known(name) and CDLeft(name) == 0 end

local function OnGCD()
  local i = spells["Battle Shout"] or spells["Hamstring"]
  if not i then return false end
  local start, dur = GetSpellCooldown(i, BOOKTYPE_SPELL)
  return start > 0 and dur <= 1.5
end

local function Cast(name, why)
  Debug(why or name)
  state.lastCast = name
  CastSpellByName(name)
  return true
end

--------------------------------------------------
-- Helpers

local function Stance()
  for i = 1, GetNumShapeshiftForms() do
    local _, name, active = GetShapeshiftFormInfo(i)
    if active then return name end
  end
  return nil
end

local function StanceIndex(stanceName)
  for i = 1, GetNumShapeshiftForms() do
    local _, name = GetShapeshiftFormInfo(i)
    if name == stanceName then return i end
  end
  return nil
end

-- Seconds left on one of our own buffs (by icon), 0 if missing.
local function BuffLeft(icon)
  for i = 0, 31 do
    local idx, untilCancelled = GetPlayerBuff(i, "HELPFUL")
    if idx < 0 then break end
    local tex = GetPlayerBuffTexture(idx)
    if tex and string.find(tex, icon) then
      if untilCancelled == 1 then return 999 end
      return GetPlayerBuffTimeLeft(idx)
    end
  end
  return 0
end

local function Rage() return UnitMana("player") end

local function HealthPct(unit) return UnitHealth(unit) / math.max(UnitHealthMax(unit), 1) end

local function AttackPower()
  local base, pos, neg = UnitAttackPower("player")
  return base + pos + neg
end

local function Enemy(unit)
  return UnitExists(unit) and UnitCanAttack("player", unit) and not UnitIsDead(unit)
end

local function Melee(unit) return CheckInteractDistance(unit, 3) end

local function TwoHander()
  return GetInventoryItemLink("player", 16) ~= nil and not OffhandHasWeapon()
end

local function UseTrinkets()
  for _, slot in ipairs({ 13, 14 }) do
    local link = GetInventoryItemLink("player", slot)
    local start, _, enable = GetInventoryItemCooldown("player", slot)
    if link and enable == 1 and start == 0 then
      local skip = false
      for _, name in ipairs(SKIP_TRINKETS) do
        if string.find(link, name, 1, true) then skip = true end
      end
      if not skip then UseInventoryItem(slot) end
    end
  end
end

local function FuryAoe()
  return Fury_Configuration and MODE_HEADER_AOE and Fury_Configuration[MODE_HEADER_AOE]
end

-- Packs are detected from how many mobs our last Whirlwind/Cleave actually hit.
local function AOE()
  local mode = Octofury_DB.aoe
  if mode == "on" or FuryAoe() then return true end
  if mode == "off" then return false end
  return state.aoeHits >= 2 and GetTime() - state.aoeHitTime < 12
end

-- Is Heroic Strike / Cleave already queued on the next swing?
local function Queued()
  for slot = 1, 120 do
    local tex = GetActionTexture(slot)
    if tex and (string.find(tex, ICON_HS) or string.find(tex, ICON_CLEAVE)) and IsCurrentAction(slot) then
      return true
    end
  end
  return GetTime() < state.queueUntil
end

--------------------------------------------------
-- Sit log: what each sit got us, kept for this fight and for all time (saved)

local function Note(k, n)
  local all = Octofury_DB.sitlog
  all[k] = (all[k] or 0) + (n or 1)
  state.fight[k] = (state.fight[k] or 0) + (n or 1)
end

local function SitReport(t, label)
  local sits = t.sits or 0
  local crits = t.crits or 0
  local msg = label .. ": " .. sits .. " sits -> " .. crits .. " crits taken, " .. (t.hits or 0) .. " plain hits, " ..
    (t.misses or 0) .. " missed/dodged/parried, " .. (t.timeouts or 0) .. " no swing"
  if crits > 0 then msg = msg .. ", avg crit taken " .. math.floor((t.critDmg or 0) / crits) end
  if (t.combatTime or 0) > 0 then
    msg = msg .. ". Enrage uptime " .. math.floor(100 * (t.enrageTime or 0) / t.combatTime) .. "% of " ..
      math.floor(t.combatTime) .. "s in combat"
  end
  Print(msg .. ".")
  if sits >= 5 and crits == 0 and (t.hits or 0) > 0 then
    Print("|cffff3333Sitting never produced a crit: this server doesn't force crits on sitting players. Turn it off: /dps sit off|r")
  end
end

--------------------------------------------------
-- Proc log: every crit we take, and whether Enrage / Blood Craze came from it.
-- Both talents are 100% on being crit in the spell data, so a crit with no proc is a real miss.
-- Buffs are watched for "gained or refreshed" (time left went up), and a crit counts as
-- procced if that happens within PROC_WINDOW of it either side, since the server may send
-- the aura before or after the combat log line.

local PROC_WINDOW = 1
local ICON_CRAZE = "Spell_Shadow_SummonImp"
local PROCS = { { key = "enrage", name = "Enrage", icon = ICON_ENRAGE },
                { key = "craze", name = "Blood Craze", icon = ICON_CRAZE } }
local watch = { left = {}, gained = {}, crits = {} }

local function Count(k)
  local t = Octofury_DB.proclog
  t[k] = (t[k] or 0) + 1
end

local function CritTaken(line, dmg, sat)
  local c = { t = GetTime(), line = line, dmg = dmg, sat = sat, up = {} }
  for _, p in ipairs(PROCS) do c.up[p.key] = (watch.left[p.key] or 0) > 0 end
  table.insert(watch.crits, c)
end

local function Resolve(c)
  local log = Octofury_DB.proclog
  Count("crits")
  if c.sat then Count("satCrits") end
  local parts = {}
  for _, p in ipairs(PROCS) do
    if Talent(p.name) > 0 then
      local g = watch.gained[p.key]
      local how
      if g and math.abs(g - c.t) <= PROC_WINDOW then how = c.up[p.key] and "refresh" or "new"
      else how = "MISS" end
      Count(p.key .. "_" .. how)
      if c.sat then Count("sat_" .. p.key .. "_" .. how) end
      table.insert(parts, p.name .. " " .. how .. (c.up[p.key] and " (was up)" or ""))
    end
  end
  local entry = date("%H:%M:%S") .. (c.sat and " [sat] " or " ") .. c.line .. " -> " .. table.concat(parts, ", ")
  table.insert(log.recent, entry)
  while table.getn(log.recent) > 40 do table.remove(log.recent, 1) end
  Debug(entry)
end

local watcher = CreateFrame("Frame")
local nextPoll = 0
watcher:SetScript("OnUpdate", function()
  local now = GetTime()
  if now < nextPoll then return end
  nextPoll = now + 0.05
  for _, p in ipairs(PROCS) do
    local left = BuffLeft(p.icon)
    if left > (watch.left[p.key] or 0) + 0.3 then watch.gained[p.key] = now end
    watch.left[p.key] = left
  end
  while watch.crits[1] and now - watch.crits[1].t > PROC_WINDOW do
    Resolve(table.remove(watch.crits, 1))
  end
end)

local function ProcReport()
  local t = Octofury_DB.proclog
  local function line(prefix, label)
    local parts = {}
    for _, p in ipairs(PROCS) do
      if Talent(p.name) > 0 then
        local new, ref, miss = t[prefix .. p.key .. "_new"] or 0, t[prefix .. p.key .. "_refresh"] or 0, t[prefix .. p.key .. "_MISS"] or 0
        local n = new + ref + miss
        table.insert(parts, p.name .. " " .. (new + ref) .. "/" .. n ..
          (n > 0 and (" (" .. math.floor(100 * (new + ref) / n) .. "%)") or "") ..
          " [" .. new .. " new, " .. ref .. " refreshed, " .. miss .. " missed]")
      else
        table.insert(parts, p.name .. ": no talent points")
      end
    end
    Print(label .. ": " .. table.concat(parts, "; "))
  end
  Print((t.crits or 0) .. " crits taken, " .. (t.satCrits or 0) .. " of them while sitting.")
  line("", "All crits")
  if (t.satCrits or 0) > 0 then line("sat_", "Sitting crits") end
  Print("Last crits (oldest first):")
  local recent = t.recent
  for i = math.max(1, table.getn(recent) - 9), table.getn(recent) do Print("  " .. recent[i]) end
end

--------------------------------------------------
-- Sunder Armor, for /dps sunder. From patch-O.mpq: 10 rage (-1 per Improved Sunder Armor rank),
-- 90 armor per rank per stack, 5 stacks, 30s, any stance.
-- A Sunder is cast only when the damage it adds to the group's physical attacks over the rest
-- of the fight beats SUNDER_MARGIN times what its rage (and GCD, if something's ready) would do.
-- The client can't see a mob's armor or the debuff's timer, so armor is estimated from level
-- and the timer runs from the last stack change or Sunder of ours that landed.

local ICON_SUNDER = "Ability_Warrior_Sunder"
local ICON_EXPOSE = "Ability_Warrior_Riposte" -- Expose Armor doesn't stack with Sunder
local SUNDER_TIME = 30
local SUNDER_REFRESH = 5  -- refresh with this long left, so a dodge or parry can be retried
local SUNDER_MARGIN = 2
local SUNDER_OTHERS = 4   -- someone else added a stack this recently: leave the stacking to them
local ARMOR_PER_LEVEL = 59.2 -- about 3730 armor on a level 63 boss
local PHYSICAL = { Warrior = true, Rogue = true, Hunter = true, Paladin = true, Shaman = true, Druid = true }

local function Debuff(unit, icon)
  local i = 1
  while UnitDebuff(unit, i) do
    local tex, count = UnitDebuff(unit, i)
    if string.find(tex, icon) then
      if count and count > 0 then return count end
      return 1
    end
    i = i + 1
  end
  return 0
end

local function SunderCost() return 10 - Talent("Improved Sunder Armor") end

local function SunderPerStack()
  local _, rank = GetSpellName(spells["Sunder Armor"], BOOKTYPE_SPELL)
  local _, _, r = string.find(rank or "", "(%d+)")
  return 90 * (tonumber(r) or 1)
end

-- Reads the target's stacks and notices stacks that weren't ours.
local function SunderTrack(now)
  local s = state.sunder
  local stacks = Debuff("target", ICON_SUNDER)
  local name = UnitName("target")
  if name ~= s.name then
    s.name, s.others, s.last = name, 0, now
  elseif stacks ~= s.stacks then
    if stacks > s.stacks and now - s.own > 3 then s.others = now end
    s.last = now
  end
  s.stacks = stacks
  return stacks
end

-- Seconds until the target dies, from how fast its health is really falling.
-- Until that's measurable, a rough guess from what kind of mob it is.
local function TimeToDie(now, hp)
  local t = state.ttd
  local name = UnitName("target")
  if t.name ~= name or hp > t.hp + 0.02 then t.name, t.start, t.startHp = name, now, hp end
  t.hp = hp
  local spent, lost = now - t.start, t.startHp - hp
  if spent >= 3 and lost > 0 then return hp * spent / lost end
  local class = UnitClassification("target")
  if class == "worldboss" then return 300 * hp end
  if class == "elite" or class == "rareelite" then return 60 * hp end
  return 20 * hp
end

local function OwnDps(now)
  local spent = now - state.dealtStart
  if state.dealtStart > 0 and spent >= 5 then return state.dealt / spent end
  return AttackPower() / 4
end

local function Dealt(line)
  local _, _, n = string.find(line, " for (%d+)")
  if not n then return end
  if state.dealtStart == 0 then state.dealtStart = GetTime() end
  state.dealt = state.dealt + tonumber(n)
end

-- Groupmates whose damage Sunder also boosts; each is assumed to hit about as hard as we do.
local function PhysicalAllies()
  local raid = GetNumRaidMembers()
  local prefix, count = "party", GetNumPartyMembers()
  if raid > 0 then prefix, count = "raid", raid end
  local n = 0
  for i = 1, count do
    local u = prefix .. i
    if not UnitIsUnit(u, "player") and UnitIsVisible(u) and not UnitIsDeadOrGhost(u) and PHYSICAL[UnitClass(u)] then
      n = n + 1
    end
  end
  return n
end

-- Returns a description for the debug log if Sunder is worth casting on the target, else false.
local function SunderWanted(now, execute)
  if not Known("Sunder Armor") then return false end
  local s = state.sunder
  local stacks = SunderTrack(now)
  local hp = HealthPct("target")
  local ttd = TimeToDie(now, hp)
  if state.sunderImmune[UnitName("target")] or Debuff("target", ICON_EXPOSE) > 0 then return false end
  -- it's a high threat ability: don't feed a mob that's already on us in a group
  if (GetNumPartyMembers() > 0 or GetNumRaidMembers() > 0) and UnitIsUnit("targettarget", "player") then return false end

  local left = SUNDER_TIME - (now - s.last)
  local refresh = stacks > 0 and left <= SUNDER_REFRESH
  if stacks >= 5 and not refresh then return false end
  if not refresh and now - s.others < SUNDER_OTHERS then return false end

  local level = UnitLevel("target")
  if level <= 0 then level = 63 end -- skull
  local armor = ARMOR_PER_LEVEL * level
  local per = SunderPerStack()
  local k = 400 + 85 * UnitLevel("player")
  local function Taken(n) return k + math.max(armor - per * n, 0) end -- proportional to 1 / damage dealt
  local after = math.min(stacks + 1, 5)

  -- a refresh saves every stack from falling off; a new stack only adds itself
  local gain, time
  if refresh then gain, time = Taken(0) / Taken(after) - 1, ttd - left
  else gain, time = Taken(stacks) / Taken(after) - 1, ttd end

  local own = OwnDps(now)
  local value = gain * own * (1 + PhysicalAllies()) * math.max(time, 0)
  local perRage = (200 + 0.35 * AttackPower()) / 30
  if execute then perRage = 15 * (1 + 0.25 * Talent("Precision Cut")) end
  local cost = SunderCost() * perRage
  if execute or CDLeft("Bloodthirst") <= 1.5 or CDLeft("Whirlwind") <= 1.5 then cost = cost + 1.5 * own end

  if value < SUNDER_MARGIN * cost then return false end
  return "Sunder Armor (" .. stacks .. " stacks" .. (refresh and ", refresh" or "") .. "): worth " ..
    math.floor(value) .. " vs cost " .. math.floor(cost) .. ", " .. math.floor(ttd) .. "s to live"
end

--------------------------------------------------
-- Rotation

function Octofury(useSunder)
  if UnitClass("player") ~= "Warrior" then return end
  local db = Octofury_DB
  local now = GetTime()
  local combat = UnitAffectingCombat("player")

  -- Enrage uptime, sampled between presses (gaps over 1.5s count as 1.5s)
  if combat and state.lastTick > 0 then
    local dt = math.min(now - state.lastTick, 1.5)
    Note("combatTime", dt)
    if BuffLeft(ICON_ENRAGE) > 0 then Note("enrageTime", dt) end
  end
  state.lastTick = now

  if not Enemy("target") then
    if not combat then return end
    TargetNearestEnemy()
    if not Enemy("target") or not UnitAffectingCombat("target") then return end
  end

  -- Sit to eat a crit and proc Enrage (and Blood Craze): only when it's down, the mob is
  -- swinging at us from melee, we can afford a crit, and it isn't a boss
  if state.sitPending and now >= state.sitUntil then
    state.sitPending = false
    Note("timeouts")
    Debug("Sit -> no swing")
  end
  if now < state.sitUntil then return end
  if db.sit and combat and Talent("Enrage") > 0 and BuffLeft(ICON_ENRAGE) < 1
    and UnitIsUnit("targettarget", "player") and Melee("target")
    and HealthPct("player") > SIT_MIN_HP and UnitClassification("target") ~= "worldboss"
    and now - state.lastSit >= SIT_GAP then
    state.lastSit, state.sitUntil, state.sitPending = now, now + SIT_WAIT, true
    Note("sits")
    Debug("Sit")
    DoEmote("SIT")
    return
  end

  if not state.autoAttack then AttackTarget() end

  if combat and Stance() ~= "Berserker Stance" and StanceIndex("Berserker Stance") then
    CastShapeshiftForm(StanceIndex("Berserker Stance"))
    return
  end

  local rage = Rage()
  local aoe = AOE()
  local execute = HealthPct("target") <= 0.2
  local melee = Melee("target")
  local boss = UnitClassification("target") == "worldboss"
  local elite = boss or UnitClassification("target") == "elite" or UnitClassification("target") == "rareelite"

  -- Pummel casters (on the GCD here, but an interrupt beats damage)
  local slamming = now < state.slamUntil -- mid-Slam: only Heroic Strike/Cleave can queue
  if db.pummel and not slamming and now < state.castUntil and Ready("Pummel") and rage >= 10 and melee then
    state.castUntil = 0
    return Cast("Pummel")
  end

  -- Off the GCD
  if combat and not slamming and Ready("Bloodrage") and rage < 50 and HealthPct("player") > 0.4 then
    Cast("Bloodrage")
  end

  local btSoon = Known("Bloodthirst") and CDLeft("Bloodthirst") <= 1.5
  local wwSoon = Known("Whirlwind") and CDLeft("Whirlwind") <= 1.5
  local slams = db.slam and Known("Slam") and TwoHander()
  local sunderWhy = useSunder and combat and melee and not aoe and SunderWanted(now, execute)
  local reserve = (btSoon and 30 or 0) + (wwSoon and 25 or 0) + (slams and 15 or 0) + (sunderWhy and SunderCost() or 0)
  if combat and melee and not Queued() then
    if aoe and Known("Cleave") then
      local cost = 20
      if rage >= db.hsRage and rage - cost >= reserve and (not execute or rage >= 80) then
        Cast("Cleave") state.queueUntil = now + 1.5
      end
    elseif Known("Heroic Strike") then
      local cost = 15 - Talent("Improved Heroic Strike")
      -- in execute range rage is worth more as Execute; only dump near cap
      if rage >= db.hsRage and rage - cost >= reserve and (not execute or rage >= 80) then
        Cast("Heroic Strike") state.queueUntil = now + 1.5
      end
    end
  end

  if OnGCD() or slamming then return end

  -- Cooldowns: pop them the moment they're ready, as long as the fight is worth it
  -- (skip a lone trash mob that's about to die; a boss is always worth it)
  local hp = HealthPct("target")
  local worth = false
  if combat then
    if db.cds == "always" then worth = hp > 0.1
    elseif db.cds == "smart" then worth = boss or ((elite or aoe) and hp > 0.25) or hp > 0.6
    elseif db.cds == "elite" then worth = elite and hp > 0.1
    elseif db.cds == "boss" then worth = boss end
  end
  if worth then
    if db.trinkets then UseTrinkets() end
    if Ready("Blood Fury") then Cast("Blood Fury") end
    if Ready("Berserking") and rage >= 5 then Cast("Berserking") end
    if Ready("Death Wish") and rage >= 10 then return Cast("Death Wish") end
    if Ready("Avatar") then return Cast("Avatar") end
  end

  -- Battle Shout (refresh in the last 3 seconds)
  if db.shout and combat and Known("Battle Shout") and BuffLeft(ICON_SHOUT) < 3 and rage >= 10 then
    return Cast("Battle Shout")
  end

  if sunderWhy and Ready("Sunder Armor") and rage >= SunderCost() then
    local s = state.sunder
    s.prevLast, s.last, s.own = s.last, now, now
    return Cast("Sunder Armor", sunderWhy)
  end

  if execute and Known("Execute") then
    -- Bloodthirst beats Execute only when its damage beats what the same 30 rage adds to Execute
    local btDmg = 200 + 0.35 * AttackPower()
    local rageValue = 15 * (1 + 0.25 * Talent("Precision Cut"))
    if Ready("Bloodthirst") and rage >= 30 and btDmg > 30 * rageValue and not aoe then
      return Cast("Bloodthirst", "Bloodthirst (execute phase)")
    end
    if aoe and Ready("Whirlwind") and rage >= 25 then return Cast("Whirlwind") end
    if rage >= 15 - (Talent("Improved Execute") == 2 and 5 or Talent("Improved Execute") * 2) then
      return Cast("Execute")
    end
    return
  end

  if aoe then
    if Ready("Whirlwind") and rage >= 25 then
      state.aoeCastTime = now
      return Cast("Whirlwind")
    end
    if Ready("Bloodthirst") and rage >= 30 then return Cast("Bloodthirst") end
  else
    if Ready("Bloodthirst") and rage >= 30 then return Cast("Bloodthirst") end
    -- don't spend Whirlwind's 25 rage if it would delay a Bloodthirst coming up
    if Ready("Whirlwind") and melee and (rage >= 55 or not btSoon and rage >= 25) then
      state.aoeCastTime = now
      return Cast("Whirlwind")
    end
  end

  -- Two-hander: Slam right after a swing so the cast fits before the next one. Keep
  -- Bloodthirst's rage if it's back within the cast.
  if slams and melee and not btSoon and not wwSoon and now - state.lastSwing < SLAM_WINDOW
    and rage >= 15 + (CDLeft("Bloodthirst") < 4 and 30 or 0) then
    state.slamUntil = now + 0.5 -- until SPELLCAST_START gives the real cast time
    return Cast("Slam")
  end

  -- Filler GCD: Berserker Rage for rage, only with the talent that makes it give rage
  if combat and Talent("Improved Berserker Rage") > 0 and Ready("Berserker Rage") and rage <= 70
    and CDLeft("Bloodthirst") > 1.5 then
    return Cast("Berserker Rage")
  end
end

--------------------------------------------------
-- Events

local frame = CreateFrame("Frame")
frame:RegisterEvent("VARIABLES_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("SPELLS_CHANGED")
frame:RegisterEvent("CHARACTER_POINTS_CHANGED")
frame:RegisterEvent("PLAYER_ENTER_COMBAT")
frame:RegisterEvent("PLAYER_LEAVE_COMBAT")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
frame:RegisterEvent("CHAT_MSG_COMBAT_SELF_MISSES")
frame:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE")
frame:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_CREATURE_BUFF")
frame:RegisterEvent("CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE")
frame:RegisterEvent("CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF")
frame:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS")
frame:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES")
frame:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE")
frame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS")
frame:RegisterEvent("CHAT_MSG_COMBAT_SELF_HITS")
frame:RegisterEvent("SPELLCAST_START")
frame:RegisterEvent("SPELLCAST_STOP")
frame:RegisterEvent("SPELLCAST_FAILED")
frame:RegisterEvent("SPELLCAST_INTERRUPTED")

frame:SetScript("OnEvent", function()
  if event == "VARIABLES_LOADED" then
    Octofury_DB = Octofury_DB or {}
    for k, v in pairs(defaults) do
      if Octofury_DB[k] == nil then Octofury_DB[k] = v end
    end
    if not Octofury_DB.v2 then Octofury_DB.cds, Octofury_DB.v2 = "smart", true end
    Octofury_DB.sitlog = Octofury_DB.sitlog or {}
    Octofury_DB.proclog = Octofury_DB.proclog or {}
    Octofury_DB.proclog.recent = Octofury_DB.proclog.recent or {}
    ScanSpells()
    ScanTalents()
  elseif event == "PLAYER_ENTERING_WORLD" or event == "SPELLS_CHANGED" or event == "CHARACTER_POINTS_CHANGED" then
    ScanSpells()
    ScanTalents()
  elseif event == "PLAYER_ENTER_COMBAT" then
    state.autoAttack = true
  elseif event == "PLAYER_LEAVE_COMBAT" then
    state.autoAttack = false
  elseif event == "PLAYER_REGEN_ENABLED" then
    state.aoeHits, state.castUntil, state.sitUntil = 0, 0, 0
    if state.sitPending then state.sitPending = false Note("timeouts") end
    state.fight, state.lastTick = {}, 0
    state.sunder = { stacks = 0, last = 0, prevLast = 0, own = 0, others = 0 }
    state.sunderImmune, state.ttd, state.dealt, state.dealtStart = {}, {}, 0, 0
  elseif event == "CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS" or event == "CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES"
    or event == "CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE" or event == "CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS" then
    local _, _, dmg = string.find(arg1, " crits you for (%d+)")
    local melee = event == "CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS" or event == "CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES"
    local sat = state.sitPending and melee
    if dmg then CritTaken(arg1, tonumber(dmg), sat) end
    local _, _, mob = string.find(arg1, "^(.+) begins to cast ") -- casts at us can land here too, for Pummel
    if mob and mob == UnitName("target") and UnitCanAttack("player", "target") then state.castUntil = GetTime() + 2 end
    if sat then
      state.sitUntil, state.sitPending = 0, false -- the swing came (a hit stands us up): back to the rotation
      if dmg then
        Note("crits") Note("critDmg", tonumber(dmg))
        Debug("Sit -> crit for " .. dmg)
      elseif event == "CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS" then
        Note("hits") Debug("Sit -> plain hit: " .. arg1)
      else
        Note("misses") Debug("Sit -> " .. arg1)
      end
    end
  elseif event == "CHAT_MSG_COMBAT_SELF_HITS" then
    state.lastSwing = GetTime() -- a white swing landed (timing for Slam)
    Dealt(arg1)
  elseif event == "SPELLCAST_START" then
    if arg1 == "Slam" then state.slamUntil = GetTime() + (arg2 or 2500) / 1000 end
  elseif event == "SPELLCAST_STOP" or event == "SPELLCAST_FAILED" or event == "SPELLCAST_INTERRUPTED" then
    if event ~= "SPELLCAST_STOP" or GetTime() >= state.slamUntil - 0.3 then state.slamUntil = 0 end
  elseif event == "CHAT_MSG_SPELL_SELF_DAMAGE" or event == "CHAT_MSG_COMBAT_SELF_MISSES" then
    local now = GetTime()
    if event == "CHAT_MSG_SPELL_SELF_DAMAGE" then Dealt(arg1) end
    -- white misses, and Heroic Strike/Cleave (they replace a swing), restart the swing too
    if event == "CHAT_MSG_COMBAT_SELF_MISSES" and not string.find(arg1, "^Your ") then state.lastSwing = now end
    if string.find(arg1, "^Your Heroic Strike") or string.find(arg1, "^Your Cleave") then state.lastSwing = now end
    if string.find(arg1, "Your Whirlwind") or string.find(arg1, "Your Cleave") then
      -- count every mob one Whirlwind/Cleave touched
      if now - state.aoeHitTime > 1 then state.aoeHits = 0 end
      state.aoeHits = state.aoeHits + 1
      state.aoeHitTime = now
    elseif string.find(arg1, "Your Heroic Strike") then
      state.queueUntil = 0
    elseif string.find(arg1, "Your Pummel") then
      state.castUntil = 0
    elseif string.find(arg1, "^Your Sunder Armor") then
      -- Sunder does no damage, so a line about it means it didn't land: the timer wasn't refreshed
      state.sunder.last = state.sunder.prevLast
      if string.find(arg1, "immune") then state.sunderImmune[UnitName("target") or ""] = true end
    end
  else
    -- enemy cast starts, for Pummel
    local _, _, mob = string.find(arg1, "^(.+) begins to cast ")
    if mob and mob == UnitName("target") and UnitCanAttack("player", "target") then
      state.castUntil = GetTime() + 2
    end
  end
end)

--------------------------------------------------
-- Slash command

local function OnOff(v) if v then return "|cff00ff00on|r" end return "|cffff0000off|r" end

local function Status()
  local db = Octofury_DB
  Print("aoe " .. db.aoe .. (FuryAoe() and " (forced on by /fury aoe)" or "") .. ", HS/Cleave at " .. db.hsRage ..
    "+ rage, cooldowns " .. db.cds .. ", trinkets " .. OnOff(db.trinkets) .. ", pummel " .. OnOff(db.pummel) ..
    ", shout " .. OnOff(db.shout) .. ", sit " .. OnOff(db.sit) .. ", slam " .. OnOff(db.slam) ..
    (TwoHander() and " (two-hander)" or " (dual wield: never slams)") .. ".")
  Print("Talents seen: Enrage " .. Talent("Enrage") .. (db.sit and Talent("Enrage") == 0 and " (sit does nothing without it)" or "") ..
    ", Improved Berserker Rage " .. Talent("Improved Berserker Rage") .. ", Precision Cut " ..
    Talent("Precision Cut") .. ", Improved Heroic Strike " .. Talent("Improved Heroic Strike") ..
    ". Bloodthirst beats Execute above " ..
    math.floor((30 * 15 * (1 + 0.25 * Talent("Precision Cut")) - 200) / 0.35) .. " AP (you have " .. AttackPower() .. ").")
end

local function Slash(msg)
  local db = Octofury_DB
  local _, _, cmd, rest = string.find(string.lower(msg or ""), "^(%S*)%s*(.*)$")
  if cmd == "" then
    Octofury()
  elseif cmd == "sunder" then
    Octofury(true)
  elseif cmd == "aoe" then
    if rest == "on" or rest == "off" or rest == "auto" then db.aoe = rest
    else db.aoe = (db.aoe == "auto") and "on" or ((db.aoe == "on") and "off" or "auto") end
    Print("aoe " .. db.aoe)
  elseif cmd == "hs" and tonumber(rest) then
    db.hsRage = tonumber(rest)
    Print("Heroic Strike/Cleave at " .. db.hsRage .. "+ rage")
  elseif cmd == "cds" and (rest == "smart" or rest == "always" or rest == "elite" or rest == "boss" or rest == "off") then
    db.cds = rest
    Print("cooldowns " .. rest)
  elseif cmd == "trinkets" or cmd == "pummel" or cmd == "shout" or cmd == "sit" or cmd == "slam" or cmd == "debug" then
    if rest == "on" then db[cmd] = true elseif rest == "off" then db[cmd] = false else db[cmd] = not db[cmd] end
    Print(cmd .. " " .. OnOff(db[cmd]))
  elseif cmd == "sitlog" then
    if rest == "reset" then db.sitlog = {} Print("sit log cleared")
    else SitReport(db.sitlog, "Sit, all time") end
  elseif cmd == "procs" then
    if rest == "reset" then db.proclog = { recent = {} } Print("proc log cleared")
    else ProcReport() end
  elseif cmd == "status" then
    Status()
  else
    Print("/dps - run the rotation (bind it to a key and spam it)")
    Print("/dps sunder - the same rotation, plus Sunder Armor whenever it's a DPS gain")
    Print("/dps aoe [on|off|auto]  /dps hs <rage>  /dps cds smart|always|elite|boss|off  /dps trinkets|pummel|shout|sit|slam|debug [on|off]  /dps sitlog [reset]  /dps procs [reset]  /dps status")
  end
end

SLASH_OCTOFURY1 = "/dps"
SLASH_OCTOFURY2 = "/octofury"
SlashCmdList["OCTOFURY"] = Slash
