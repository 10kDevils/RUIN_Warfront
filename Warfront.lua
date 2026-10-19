-- RUIN Warfront
-- Officers drop objectives on the map. RUIN members who stand in an
-- objective's circle capture it (needs a quorum, so one player cannot fake
-- it). A small HUD points to the nearest objective or call for help, and a
-- Call to Arms button alerts everyone in the org with your position.
-- Objectives and calls for help are pinned on the world map and minimap;
-- RUIN Intel sightings near an objective mark it contested. Officers post
-- bounties on rival guilds or players, claimed kills need a second RUIN
-- witness, and captures and bounties add up to a weekly war record.
local ADDON, ns = ...
local R = RUIN_API
if not R or (R.apiLevel or 1) < 3 then
    print("|cff54b7d9[RUIN]|r Warfront needs a newer RUIN Core (0.3.0 or later).")
    return
end
local W = R.Widgets
local C = W.COLORS

local M = R:RegisterModule("Warfront", { version = "0.3.2" })

-- Retired: RUIN's world PvP runs on Overlord Forever, and Warfront's bounties
-- and rally points moved to RUIN Muster. Say so once per session.
C_Timer.After(12, function()
    print("|cff54b7d9[RUIN]|r Warfront is retired. RUIN uses Overlord Forever for world PvP; bounties and rally points are in RUIN Muster. You can disable or remove RUIN Warfront.")
end)

local RADIUS = 0.02            -- fraction of the zone map (roughly 60-100 yards)
local CAPTURE_SECONDS = 60
local REPORT_EVERY = 5
local PRESENCE_TTL = 12
local OBJECTIVE_HOURS = 2
local HELP_SECONDS = 120
local CTA_COOLDOWN = 30
local CONTEST_YARDS = 300            -- an Intel sighting this close contests an objective
local CONTEST_SECONDS = 10 * 60
local BOUNTY_DAYS = 7
local CLAIM_SECONDS = 5 * 60         -- witnesses have this long to confirm a kill
local WITNESS_YARDS = 200
local WEEK = 7 * 86400
local WEEK_OFFSET = 5 * 86400 + 15 * 3600   -- weeks start Tuesday 15:00 UTC
local POINTS = { cap = 3, bounty = 2 }

local RADAR_SIZE, RING_DOTS          -- set in the navigation section
local navTick                        -- defined in the navigation section

local DEFAULTS = { objectives = {}, hud = true, quorum = 2, hudPos = nil, practice = false,
                   pins = true, bounties = {}, claims = {}, record = {} }

local db
local presence = {}            -- objective id -> { [guid] = time }
local captureStart = {}        -- objective id -> time the quorum was first met
local help                     -- latest Call to Arms
local lastCTA = -999
local ui = {}
local hud

---------------------------------------------------------------------------
-- Position helpers
---------------------------------------------------------------------------
local function myPos()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return nil end
    local map = C_Map.GetBestMapForUnit("player")
    if not map then return nil end
    local pos = C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return nil end
    local x, y = pos:GetXY()
    if not x or (x == 0 and y == 0) then return nil end
    return map, x, y
end

local DIRS = { "E", "NE", "N", "NW", "W", "SW", "S", "SE" }
local function describe(map, tx, ty)
    local myMap, x, y = myPos()
    if not myMap or myMap ~= map then return nil end
    local dx, dy = tx - x, ty - y
    local angle = math.atan2(-dy, dx)              -- map y grows downward
    local dir = DIRS[math.floor(angle / (2 * math.pi) * 8 + 0.5) % 8 + 1]
    local dist
    if C_Map.GetMapWorldSize then
        local w, hgt = C_Map.GetMapWorldSize(map)
        if w and w > 0 then dist = math.sqrt((dx * w) ^ 2 + (dy * hgt) ^ 2) end
    end
    local inside = math.sqrt(dx * dx + dy * dy)
    return dir, dist, inside
end

local function distanceText(map, x, y)
    local dir, yards, frac = describe(map, x, y)
    if not dir then return C.dim .. "other zone|r" end
    if yards then return ("%d yd %s"):format(yards, dir) end
    return ("%d%% %s"):format(frac * 100, dir)
end

local function newId()
    return tostring(R:GetPlayerGUID() or "x"):sub(-5) .. math.random(1000, 9999)
end

---------------------------------------------------------------------------
-- Objectives
---------------------------------------------------------------------------
local function refresh() end   -- replaced once the page exists
local function updateHUD() end
local updatePins                -- map pins, defined below

local function validObjective(o)
    return type(o) == "table" and type(o.id) == "string" and type(o.name) == "string"
        and type(o.map) == "number" and type(o.x) == "number" and type(o.y) == "number"
end

-- Officers command the org. Without an org connection anyone can practice:
-- objectives stay on your own screen and a capture needs only you.
-- Practice mode is on when you switch it on (page checkbox or /wf practice),
-- and automatically while you're not connected to RUIN.
local function practicing() return (db and db.practice) or not R:IsConnected() end
local function canCommand() return R:IsOfficer() or practicing() end
local function quorumFor(o) return (o.practice or practicing()) and 1 or (db.quorum or 2) end

function M:Mark(name)
    if not canCommand() then return self:Print("Only officers can set objectives.") end
    name = (name or ""):sub(1, 30)
    if name == "" then return self:Print("Give the objective a name.") end
    local map, x, y = myPos()
    if not map then return self:Print("Your map position can't be read here.") end
    local now = GetServerTime()
    local o = { id = newId(), name = name, map = map, x = x, y = y, r = RADIUS,
                zone = GetZoneText and GetZoneText() or "?", by = UnitName("player"),
                t = now, exp = now + OBJECTIVE_HOURS * 3600 }
    if practicing() then o.practice = true end
    db.objectives[o.id] = o
    if o.practice then
        self:Toast("Practice objective set: " .. name .. " (only you can see it)")
    else
        self:Send("OBJ", o, "ORG")
        self:Toast("Objective set: " .. name)
    end
    updatePins()
    refresh()
end

-- Practice objectives are yours alone: they are never sent, and a capture
-- needs only you. Switching practice off clears them.
function M:SetPractice(on)
    db.practice = on and true or false
    if not db.practice then
        for id, o in pairs(db.objectives) do if o.practice then db.objectives[id] = nil end end
        for id, b in pairs(db.bounties or {}) do if b.practice then db.bounties[id] = nil end end
        for id, c in pairs(db.claims or {}) do if c.practice then db.claims[id] = nil end end
    end
    if ui.practiceCheck then ui.practiceCheck:Refresh() end
    self:Print(db.practice
        and "Practice mode on: mark objectives with /wf mark <name> or the page, and capture them alone. Only you see them."
        or "Practice mode off. Practice objectives cleared.")
    refresh()
    updateHUD()
end

function M:Remove(id)
    if not canCommand() then return end
    db.objectives[id] = nil
    self:Send("DEL", { id = id }, "ORG")
    updatePins()
    refresh()
end

function M:OnObjective(o, sender)
    if not validObjective(o) then return end
    local known = db.objectives[o.id]
    if known and (known.holder or not o.holder) then return end
    db.objectives[o.id] = o
    if not known then
        self:Toast(("New objective: %s in %s (%s)"):format(o.name, o.zone or "?", W.ClassName(sender)), { sound = true })
    end
    updatePins()
    refresh()
end

function M:OnDelete(d)
    if type(d.id) == "string" and db.objectives[d.id] then
        db.objectives[d.id] = nil
        refresh()
    end
end

function M:OnHere(d)
    if type(d.id) ~= "string" or type(d.g) ~= "string" or not db.objectives[d.id] then return end
    presence[d.id] = presence[d.id] or {}
    presence[d.id][d.g] = { t = GetTime(), gu = type(d.gu) == "string" and d.gu or "RUIN",
                            n = type(d.n) == "string" and d.n:sub(1, 40) or nil }
end

local recordCapture   -- war record, defined below

function M:OnCapture(d, sender)
    local o = type(d.id) == "string" and db.objectives[d.id]
    if not o or o.holder then return end
    o.holder, o.heldAt, o.heldBy = d.gu or "RUIN", tonumber(d.at) or GetServerTime(), sender
    self:Toast(("%s captured by %s!"):format(o.name, o.holder), { sound = true })
    if not o.practice then recordCapture(o, d) end
    refresh()
end

-- Officers answer a newcomer with the objectives they know.
function M:OnAsk()
    if not R:IsOfficer() then return end
    C_Timer.After(2 + math.random() * 6, function()
        for _, o in pairs(db.objectives) do
            if not o.practice then self:Send("OBJ", o, "ORG", nil, R.PRIORITY.BULK) end
        end
    end)
end

---------------------------------------------------------------------------
-- Call to Arms
---------------------------------------------------------------------------
function M:CallToArms()
    if GetTime() - lastCTA < CTA_COOLDOWN then return self:Print("Call to Arms is on cooldown.") end
    local map, x, y = myPos()
    lastCTA = GetTime()
    self:Send("CTA", { map = map, x = x, y = y, zone = GetZoneText and GetZoneText() or "?",
                       sz = GetSubZoneText and GetSubZoneText() or "" }, "ORG", nil, R.PRIORITY.ALERT)
    self:Print("Call to Arms sent to RUIN.")
end

function M:OnCallToArms(d, sender)
    help = { name = sender, map = d.map, x = d.x, y = d.y, zone = d.zone, sz = d.sz, t = GetTime() }
    local where = (d.sz and d.sz ~= "") and (d.sz .. ", " .. tostring(d.zone)) or tostring(d.zone)
    self:Toast(("CALL TO ARMS: %s needs help at %s"):format(W.ClassName(sender), where), { sound = true })
    updateHUD()
end

---------------------------------------------------------------------------
-- Presence and capture loop
---------------------------------------------------------------------------
local function tick()
    local me, now, serverNow = R:GetPlayerGUID(), GetTime(), GetServerTime()
    for id, o in pairs(db.objectives) do
        if (o.exp or 0) < serverNow then db.objectives[id] = nil end
    end

    local map, x, y = myPos()
    for id, o in pairs(db.objectives) do
        if map and o.map == map then
            local dx, dy = o.x - x, o.y - y
            if math.sqrt(dx * dx + dy * dy) <= (o.r or RADIUS) then
                local myGuild = R:GetPlayer().guild or "RUIN"
                presence[id] = presence[id] or {}
                presence[id][me] = { t = now, gu = myGuild, n = UnitName("player") }
                if not o.practice then M:Send("HERE", { id = id, g = me, gu = myGuild, n = UnitName("player") }, "ORG") end
            end
        end
        -- Count who is in the circle. The guild with the most members present
        -- gets the credit; the lowest GUID present announces it (one sender).
        local count, lowest, perGuild = 0, nil, {}
        for g, p in pairs(presence[id] or {}) do
            if now - p.t <= PRESENCE_TTL then
                count = count + 1
                perGuild[p.gu] = (perGuild[p.gu] or 0) + 1
                if not lowest or g < lowest then lowest = g end
            else
                presence[id][g] = nil
            end
        end
        o.here = count
        if not o.holder and count >= quorumFor(o) then
            captureStart[id] = captureStart[id] or now
            o.progress = math.min(1, (now - captureStart[id]) / CAPTURE_SECONDS)
            if o.progress >= 1 and lowest == me then
                local guild, best = "RUIN", 0
                for gu, n in pairs(perGuild) do
                    if n > best or (n == best and gu < guild) then guild, best = gu, n end
                end
                local who = {}
                for _, pr in pairs(presence[id] or {}) do
                    if pr.n and #who < 10 then who[#who + 1] = pr.n end
                end
                local cap = { id = id, at = serverNow, gu = guild, p = who }
                if not o.practice then
                    M:Send("CAP", cap, "ORG", nil, R.PRIORITY.ALERT)
                end
                M:OnCapture(cap, UnitName("player"))
            end
        else
            captureStart[id], o.progress = nil, nil
        end
    end
    if help and now - help.t > HELP_SECONDS then help = nil end
    for _, o in pairs(db.objectives) do
        if o.contested and serverNow - (o.contested.t or 0) > CONTEST_SECONDS then o.contested = nil end
    end
    updatePins()
    updateHUD()
    refresh()
end

---------------------------------------------------------------------------
-- Map pins: objectives and the latest call for help
---------------------------------------------------------------------------
local OBJ_ICON = "Interface\\Icons\\INV_BannerPVP_01"
local CTA_ICON = "Interface\\Icons\\Ability_Warrior_BattleShout"

local function objectiveState(o)
    if o.contested then
        return "Contested" .. ((o.contested.text or "") ~= "" and (": " .. o.contested.text) or "")
    elseif o.holder then
        return "Held by " .. o.holder
    elseif o.progress then
        return ("Capturing: %d%%"):format(o.progress * 100)
    end
    return "Open"
end

updatePins = function()
    if not db then return end
    if not db.pins then R.Map:ClearPins("Warfront"); return end
    local keep = {}
    for id, o in pairs(db.objectives) do
        local color = o.contested and { 1, 0.55, 0.1 } or (o.holder and { 0.3, 1, 0.3 } or { 0.77, 0.12, 0.23 })
        R.Map:SetPin("Warfront", "o" .. id, { map = o.map, x = o.x, y = o.y, icon = OBJ_ICON, color = color,
            title = o.name, text = objectiveState(o) .. "  ·  set by " .. tostring(o.by) })
        keep["o" .. id] = true
    end
    if help and help.map then
        R.Map:SetPin("Warfront", "help", { map = help.map, x = help.x, y = help.y, icon = CTA_ICON,
            color = { 1, 0.15, 0.15 }, title = "Call to Arms: " .. R.Util.ShortName(help.name or "?"),
            text = tostring(help.zone or "") })
        keep.help = true
    end
    for id in pairs(R.Map:GetPins("Warfront")) do
        if not keep[id] then R.Map:RemovePin("Warfront", id) end
    end
end

---------------------------------------------------------------------------
-- Contested objectives: RUIN Intel enemy sightings near an objective.
-- An Intel "under attack" call also points your HUD at that member.
---------------------------------------------------------------------------
local function yardsBetween(map, x1, y1, x2, y2)
    if not (C_Map and C_Map.GetMapWorldSize) then return nil end
    local w, h = C_Map.GetMapWorldSize(map)
    if not w or w <= 0 then return nil end
    local dx, dy = (x2 - x1) * w, (y2 - y1) * h
    return math.sqrt(dx * dx + dy * dy)
end

local function onIntelSpot(sp)
    if type(sp) ~= "table" or type(sp.map) ~= "number" then return end
    if sp.kind == "attack" and not sp.mine then
        help = { name = sp.by, map = sp.map, x = sp.x, y = sp.y, zone = sp.where, sz = "", t = GetTime() }
    end
    if sp.kind == "enemy" then
        local now = GetServerTime()
        for _, o in pairs(db.objectives) do
            local tx, ty = R.Map:Translate(sp.map, sp.x, sp.y, o.map)
            local yards = tx and yardsBetween(o.map, o.x, o.y, tx, ty)
            if yards and yards <= CONTEST_YARDS then
                local fresh = not o.contested
                o.contested = { t = now, text = sp.text or "", by = sp.by }
                if fresh then
                    M:Toast(("%s is contested%s (%s)"):format(o.name,
                        (sp.text or "") ~= "" and (": " .. sp.text) or "", W.ClassName(sp.by)), { sound = true })
                end
            end
        end
    end
    updatePins()
    updateHUD()
    refresh()
end

---------------------------------------------------------------------------
-- War record: captures and confirmed bounties, per week, by guild and player
---------------------------------------------------------------------------
local function weekKey(t) return math.floor(((t or GetServerTime()) - WEEK_OFFSET) / WEEK) end

local function recordFor(key)
    local rec = db.record[key]
    if not rec then
        rec = { guilds = {}, players = {}, seen = {} }
        db.record[key] = rec
        -- keep the last four weeks
        for k in pairs(db.record) do if k < key - 3 then db.record[k] = nil end end
    end
    return rec
end

local function bump(tbl, name, field)
    if type(name) ~= "string" or name == "" then return end
    local e = tbl[name] or { c = 0, b = 0 }
    e[field] = (e[field] or 0) + 1
    tbl[name] = e
end

recordCapture = function(o, d)
    local rec = recordFor(weekKey(tonumber(d.at)))
    if rec.seen["c" .. o.id] then return end
    rec.seen["c" .. o.id] = true
    bump(rec.guilds, d.gu or "RUIN", "c")
    for _, n in ipairs(type(d.p) == "table" and d.p or {}) do bump(rec.players, R.Util.ShortName(n), "c") end
end

local function recordBounty(claim)
    local rec = recordFor(weekKey(claim.t))
    if rec.seen["b" .. claim.id] then return end
    rec.seen["b" .. claim.id] = true
    bump(rec.guilds, claim.gu or "RUIN", "b")
    bump(rec.players, R.Util.ShortName(claim.by), "b")
end

-- Officers share this week's record with members who just connected; the
-- larger count wins for each guild and player.
function M:OnRecord(d)
    if type(d.k) ~= "number" or type(d.g) ~= "table" or type(d.p) ~= "table" then return end
    local rec = recordFor(d.k)
    for _, pair in ipairs({ { rec.guilds, d.g }, { rec.players, d.p } }) do
        local mine, theirs = pair[1], pair[2]
        for name, e in pairs(theirs) do
            if type(name) == "string" and type(e) == "table" then
                local cur = mine[name] or { c = 0, b = 0 }
                cur.c = math.max(cur.c or 0, tonumber(e.c) or 0)
                cur.b = math.max(cur.b or 0, tonumber(e.b) or 0)
                mine[name] = cur
            end
        end
    end
    refresh()
end

local function leaderboard(key)
    local rec = db.record[key]
    local guilds, players = {}, {}
    if rec then
        for name, e in pairs(rec.guilds) do
            guilds[#guilds + 1] = { name = name, c = e.c or 0, b = e.b or 0, pts = (e.c or 0) * POINTS.cap + (e.b or 0) * POINTS.bounty }
        end
        for name, e in pairs(rec.players) do
            players[#players + 1] = { name = name, c = e.c or 0, b = e.b or 0, pts = (e.c or 0) * POINTS.cap + (e.b or 0) * POINTS.bounty }
        end
    end
    local function byPoints(a, b) if a.pts ~= b.pts then return a.pts > b.pts end return a.name < b.name end
    table.sort(guilds, byPoints)
    table.sort(players, byPoints)
    return guilds, players
end

---------------------------------------------------------------------------
-- Bounties: officers name a rival guild or player; a claimed kill counts
-- once another RUIN member confirms it.
---------------------------------------------------------------------------
local function activeBounties()
    local list, now = {}, GetServerTime()
    for id, b in pairs(db.bounties) do
        if (b.exp or 0) < now then db.bounties[id] = nil else list[#list + 1] = b end
    end
    table.sort(list, function(a, b) return (a.t or 0) > (b.t or 0) end)
    return list
end

function M:PostBounty(target, kind, reward)
    if not canCommand() then return self:Print("Only officers can post bounties.") end
    target = R.Util.Trim(target or ""):sub(1, 40)
    if target == "" then return self:Print("Name the guild or player for the bounty.") end
    local now = GetServerTime()
    local b = { id = newId(), target = target, kind = kind == "Player" and "Player" or "Guild",
                reward = R.Util.Trim(reward or ""):sub(1, 40), by = UnitName("player"), t = now,
                exp = now + BOUNTY_DAYS * 86400 }
    if practicing() then b.practice = true end
    db.bounties[b.id] = b
    if not b.practice then self:Send("BOUNTY", b, "ORG") end
    self:Toast(("Bounty posted on %s %s%s"):format(b.kind == "Guild" and "guild" or "player", b.target,
        b.reward ~= "" and (" (" .. b.reward .. ")") or ""))
    refresh()
end

function M:RemoveBounty(id)
    local b = db.bounties[id]
    if not b or not canCommand() then return end
    db.bounties[id] = nil
    if not b.practice then self:Send("BDEL", { id = id }, "ORG") end
    refresh()
end

function M:OnBounty(b, sender)
    if type(b) ~= "table" or type(b.id) ~= "string" or type(b.target) ~= "string" or type(b.exp) ~= "number" then return end
    local known = db.bounties[b.id]
    db.bounties[b.id] = b
    if not known and b.exp > GetServerTime() then
        self:Toast(("Bounty on %s %s%s, posted by %s"):format(b.kind == "Player" and "player" or "guild", b.target,
            (b.reward or "") ~= "" and (" (" .. b.reward .. ")") or "", W.ClassName(sender)))
    end
    refresh()
end

function M:OnBountyDelete(d)
    if type(d.id) == "string" and db.bounties[d.id] then db.bounties[d.id] = nil; refresh() end
end

local function secret(v) return issecretvalue and issecretvalue(v) end

local function matchBounty(name, guild)
    for _, b in ipairs(activeBounties()) do
        if b.kind == "Player" and name and b.target:lower() == R.Util.ShortName(name):lower() then return b end
        if b.kind == "Guild" and guild and b.target:lower() == guild:lower() then return b end
    end
end

-- Target the corpse of an enemy player you killed, then claim.
function M:ClaimKill()
    if not (UnitExists and UnitExists("target") and UnitIsPlayer and UnitIsPlayer("target")) then
        return self:Print("Target the enemy player you killed (their body), then claim the bounty.")
    end
    if UnitIsFriend and UnitIsFriend("player", "target") then return self:Print("That's not an enemy player.") end
    if UnitIsDeadOrGhost and not UnitIsDeadOrGhost("target") then return self:Print("They're still alive!") end
    local name = UnitName("target")
    local guild = GetGuildInfo and GetGuildInfo("target")
    if secret(name) or secret(guild) then return self:Print("The game is hiding that player's details right now; try again out of combat.") end
    local b = matchBounty(name, guild)
    if not b then
        return self:Print(("No bounty on %s%s."):format(tostring(name), guild and (" <" .. guild .. ">") or ""))
    end
    local map, x, y = myPos()
    local p = R:GetPlayer()
    local c = { id = newId(), b = b.id, v = R.Util.ShortName(name), vg = guild, by = p.name, gu = p.guild,
                t = GetServerTime(), map = map, x = x, y = y }
    if b.practice then
        c.practice, c.confirmed = true, "practice"
        db.claims[c.id] = c
        self:Toast(("Practice bounty: you killed %s. Confirmed (practice needs no witness)."):format(c.v))
        refresh()
        return
    end
    db.claims[c.id] = c
    self:Send("CLAIM", c, "ORG", nil, R.PRIORITY.ALERT)
    self:Toast(("Bounty claim sent: %s%s. A RUIN member who saw it must confirm."):format(c.v, guild and (" <" .. guild .. ">") or ""))
    refresh()
end

function M:OnClaim(c, sender)
    if type(c) ~= "table" or type(c.id) ~= "string" or type(c.b) ~= "string" or type(c.v) ~= "string" then return end
    if db.claims[c.id] then return end
    c.by = sender
    db.claims[c.id] = c
    local near = c.map and select(3, R.Map:Offset(c.map, c.x, c.y))
    if near and near <= WITNESS_YARDS then
        self:Toast(("Did you see %s kill %s? Confirm on the Warfront Bounties page or /wf confirm."):format(
            W.ClassName(sender), c.v), { sound = true })
    end
    refresh()
end

-- Confirm the newest open claim (or a given one) as a witness.
function M:Confirm(id)
    local now, best = GetServerTime(), nil
    for cid, c in pairs(db.claims) do
        local open = not c.confirmed and now - (c.t or 0) <= CLAIM_SECONDS and c.by ~= UnitName("player")
        if open and (cid == id or (not id and (not best or c.t > best.t))) then best = c end
    end
    if not best then return self:Print("No bounty claim waiting for a witness.") end
    self:Send("CONFIRM", { c = best.id }, "ORG", nil, R.PRIORITY.ALERT)
    self:OnConfirm({ c = best.id }, UnitName("player"))
end

function M:OnConfirm(d, sender)
    local c = type(d.c) == "string" and db.claims[d.c]
    if not c or c.confirmed or R.Util.ShortName(sender) == R.Util.ShortName(c.by or "") then return end
    c.confirmed = sender
    recordBounty(c)
    self:Toast(("Bounty confirmed: %s killed %s%s, witnessed by %s."):format(W.ClassName(c.by), c.v,
        c.vg and (" <" .. c.vg .. ">") or "", W.ClassName(sender)), { sound = true })
    refresh()
end

local function openClaims()
    local list, now = {}, GetServerTime()
    for id, c in pairs(db.claims) do
        if now - (c.t or 0) > 86400 then
            db.claims[id] = nil
        elseif now - (c.t or 0) <= CLAIM_SECONDS or c.confirmed then
            list[#list + 1] = c
        end
    end
    table.sort(list, function(a, b) return (a.t or 0) > (b.t or 0) end)
    return list
end

---------------------------------------------------------------------------
-- HUD
---------------------------------------------------------------------------
local function nearestObjective()
    local myMap = myPos()
    local best, bestScore
    for _, o in pairs(db.objectives) do
        local score = (o.map == myMap) and 0 or 1
        if not best or score < bestScore or (score == bestScore and (o.t or 0) > (best.t or 0)) then
            best, bestScore = o, score
        end
    end
    return best
end

---------------------------------------------------------------------------
-- Navigation: on-screen arrow and radar. Addons can't draw in the 3D world,
-- so the circle is shown top-down on screen instead.
---------------------------------------------------------------------------
RADAR_SIZE, RING_DOTS = 150, 36
local navAcc = 0

local function navTarget()
    if help and help.map then return help, false end
    local o = nearestObjective()
    return o, o ~= nil
end

local function worldSize(map)
    if C_Map.GetMapWorldSize then
        local w, h = C_Map.GetMapWorldSize(map)
        if w and w > 0 and h and h > 0 then return w, h, true end
    end
    return 1000, 1000, false        -- unknown scale: still right for direction
end

navTick = function(self, elapsed)
    navAcc = navAcc + (elapsed or 0)
    if navAcc < 0.03 then return end
    navAcc = 0
    local radar = self.radar
    local t, isObjective = navTarget()
    local map, px, py = myPos()
    local facing = GetPlayerFacing and GetPlayerFacing()
    if not t or not map or t.map ~= map or not facing then
        self.arrow:Hide()
        radar:Hide()
        return
    end
    local w, h, known = worldSize(map)
    local east, north = (t.x - px) * w, -(t.y - py) * h          -- yards (map y grows south)
    local dist = math.sqrt(east * east + north * north)
    local radius = isObjective and (t.r or RADIUS) * w or 0
    local inside = isObjective and dist <= radius

    -- Arrow: bearing from north, counter-clockwise, minus where you face.
    self.arrow:SetRotation(math.atan2(-east, north) - facing)
    if inside then self.arrow:SetVertexColor(0.3, 1, 0.3) else self.arrow:SetVertexColor(1, 0.82, 0.2) end
    self.arrow:Show()

    if not isObjective or dist > radius * 3 + 40 then
        radar:Hide()
        return
    end
    radar:Show()
    local half = RADAR_SIZE / 2 - 8
    local scale = half / math.max(radius * 2.2, 30)
    local cf, sf = math.cos(facing), math.sin(facing)
    local cx = (east * cf + north * sf) * scale                    -- right of you
    local cy = (-east * sf + north * cf) * scale                   -- ahead of you
    local R = radius * scale
    local spin = GetTime() * 0.5
    local r, g, b = 1, 0.8, 0.2
    if inside then r, g, b = 0.3, 1, 0.3 end
    local n = #radar.dots
    for i, d in ipairs(radar.dots) do
        local a = (i / n) * 2 * math.pi + spin
        local x, y = cx + R * math.cos(a), cy + R * math.sin(a)
        if x * x + y * y > half * half then
            d:Hide()
        else
            d:ClearAllPoints()
            d:SetPoint("CENTER", radar, "CENTER", x, y)
            d:SetVertexColor(r, g, b, 0.9)
            d:Show()
        end
    end
    if cx * cx + cy * cy <= half * half then
        radar.center:ClearAllPoints()
        radar.center:SetPoint("CENTER", radar, "CENTER", cx, cy)
        radar.center:SetVertexColor(r, g, b, 1)
        radar.center:Show()
    else
        radar.center:Hide()
    end
    if inside then
        radar.label:SetText(C.good .. "In the circle|r")
    elseif known then
        radar.label:SetText(("%d yd to the edge"):format(math.max(0, dist - radius)))
    else
        radar.label:SetText("Head for the ring")
    end
end

local function createHUD()
    hud = W.HudFrame("RUIN_WarfrontHUD", "Warfront", db, "hudPos", { "TOP", UIParent, "TOP", 0, -70 })
    hud:SetSize(320, 58)
    -- Direction arrow: points at the target and turns as you turn.
    hud.arrow = hud:CreateTexture(nil, "ARTWORK")
    hud.arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
    hud.arrow:SetSize(34, 34)
    hud.arrow:SetPoint("LEFT", 6, 0)
    hud.arrow:Hide()
    hud.line1 = W.Label(hud, "", "GameFontNormal")
    hud.line1:SetPoint("TOPLEFT", 46, -9)
    hud.line1:SetPoint("RIGHT", hud, "RIGHT", -70, 0)
    hud.line2 = W.Label(hud, "", "GameFontHighlightSmall")
    hud.line2:SetPoint("TOPLEFT", 46, -30)
    hud.line2:SetPoint("RIGHT", hud, "RIGHT", -70, 0)
    hud.cta = W.Button(hud, "Help!", 56, function() M:CallToArms() end)
    hud.cta:SetPoint("RIGHT", hud, "RIGHT", -8, 0)

    -- Radar: a top-down view of the objective's circle around you, forward
    -- at the top. The ring spins slowly and turns green when you're inside.
    local radar = CreateFrame("Frame", "RUIN_WarfrontRadar", hud, (not W.Skin and BackdropTemplateMixin) and "BackdropTemplate" or nil)
    radar:SetSize(RADAR_SIZE, RADAR_SIZE)
    radar:SetPoint("TOP", hud, "BOTTOM", 0, -6)
    if W.Skin then
        W.Skin(radar, "bg", 0.8, "border")           -- RUIN navy (Core 0.3.1+)
    elseif radar.SetBackdrop then
        radar:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16,
                            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        radar:SetBackdropColor(0.02, 0.02, 0.03, 0.75)
        radar:SetBackdropBorderColor(0.7, 0.1, 0.1, 1)
    end
    radar.dots = {}
    for i = 1, RING_DOTS do
        local d = radar:CreateTexture(nil, "OVERLAY")
        d:SetColorTexture(1, 1, 1, 1)
        d:SetSize(5, 5)
        d:Hide()
        radar.dots[i] = d
    end
    radar.center = radar:CreateTexture(nil, "OVERLAY")
    radar.center:SetColorTexture(1, 1, 1, 1)
    radar.center:SetSize(7, 7)
    radar.center:SetRotation(math.pi / 4)
    radar.me = radar:CreateTexture(nil, "OVERLAY")
    radar.me:SetTexture("Interface\\Minimap\\MinimapArrow")
    radar.me:SetSize(22, 22)
    radar.me:SetPoint("CENTER")
    radar.label = W.Label(radar, "", "GameFontHighlightSmall")
    radar.label:SetPoint("BOTTOM", 0, 6)
    radar:Hide()
    hud.radar = radar

    hud:SetScript("OnUpdate", function(self, elapsed) navTick(self, elapsed) end)
    hud:Hide()
end

updateHUD = function()
    if not db then return end
    if not hud then createHUD() end
    local o = nearestObjective()
    if not db.hud or (not o and not help) then hud:Hide(); return end
    hud:Show()
    if help then
        hud.line1:SetText(C.bad .. "Help: |r" .. W.ClassName(help.name) .. "  " .. (help.map and distanceText(help.map, help.x, help.y) or tostring(help.zone)))
        hud.line2:SetText(o and (C.dim .. "Objective: " .. o.name .. "|r") or "")
        return
    end
    hud.line1:SetText(C.gold .. o.name .. "|r  " .. distanceText(o.map, o.x, o.y))
    local status
    if o.contested then
        status = "|cffff8c1aCONTESTED|r " .. C.dim .. W.Ago(GetServerTime() - o.contested.t) .. "|r"
            .. ((o.contested.text or "") ~= "" and ("  " .. o.contested.text) or "")
    elseif o.holder then
        status = C.good .. "Held by " .. o.holder .. "|r " .. C.dim .. W.Ago(GetServerTime() - (o.heldAt or 0)) .. "|r"
    elseif o.progress then
        status = ("Capturing: %d%%  (%d here)"):format(o.progress * 100, o.here or 0)
    else
        status = ("Open  ·  %d of %d needed here"):format(o.here or 0, quorumFor(o))
    end
    hud.line2:SetText(status)
end

---------------------------------------------------------------------------
-- Page
---------------------------------------------------------------------------
local function buildObjectives(page)
    local cta = W.Button(page, "|T" .. CTA_ICON .. ":16:16|t Call to Arms", 140, function() M:CallToArms() end)
    cta:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 2)
    local hudCheck = W.Check(page, "Show HUD", function() return db.hud end, function(v) db.hud = v; updateHUD() end)
    hudCheck:SetPoint("TOPLEFT", 0, 2)
    local pinCheck = W.Check(page, "Map pins", function() return db.pins end, function(v) db.pins = v; updatePins() end)
    pinCheck:SetPoint("TOPLEFT", 110, 2)
    ui.practiceCheck = W.Check(page, "Practice mode", function() return db.practice end,
        function(v) M:SetPractice(v) end)
    ui.practiceCheck:SetPoint("TOPLEFT", 220, 2)

    ui.officer = W.Card(page)
    ui.officer:SetPoint("TOPLEFT", 0, -28)
    ui.officer:SetPoint("RIGHT", page, "RIGHT", -4, 0)
    ui.officer:SetHeight(34)
    local nameBox = W.EditBox(ui.officer, 200)
    nameBox:SetPoint("LEFT", 10, 0)
    local mark = W.Button(ui.officer, "|T" .. OBJ_ICON .. ":16:16|t Mark objective here", 180, function()
        M:Mark(nameBox:GetText()); nameBox:SetText("")
    end)
    mark:SetPoint("LEFT", nameBox, "RIGHT", 8, 0)
    local hint = W.Label(ui.officer, C.dim .. "officers, or practice solo|r", "GameFontHighlightSmall")
    hint:SetPoint("LEFT", mark, "RIGHT", 8, 0)

    ui.list = W.List(page, 26, function(row)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(18, 18)
        row.icon:SetPoint("LEFT", 4, 0)
        row.text = W.Label(row, "")
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -70, 0)
        row.text:SetWordWrap(false)
        row.del = W.Button(row, "Remove", 66)
        row.del:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    end, function(row, o)
        row.icon:SetTexture(OBJ_ICON)
        local state = o.contested and ("|cffff8c1acontested|r")
            or (o.holder and (C.good .. "held by " .. o.holder .. "|r"))
            or (o.progress and ("capturing " .. math.floor(o.progress * 100) .. "%")) or (C.dim .. "open|r")
        row.text:SetText(("%s%s|r  %s  ·  %s  ·  %s  ·  %d here  %s· %s|r"):format(C.gold, o.name, o.zone or "?",
            distanceText(o.map, o.x, o.y), state, o.here or 0, C.dim, o.by or "?"))
        row.del:SetShown(canCommand())
        row.del:SetScript("OnClick", function() M:Remove(o.id) end)
        row.tip = function(tip)
            tip:AddLine(o.name, 0.77, 0.12, 0.23)
            tip:AddLine(objectiveState(o), 1, 1, 1, true)
            tip:AddLine(("%s  ·  set by %s, %s"):format(o.zone or "?", tostring(o.by), W.Ago(GetServerTime() - (o.t or 0))), 0.7, 0.7, 0.7)
            if o.exp then tip:AddLine("Expires in " .. W.Duration(o.exp - GetServerTime()), 0.6, 0.6, 0.6) end
        end
    end)
    ui.list:SetEmptyText("No objectives tonight. Officers mark ground worth holding; it appears here, on the HUD and on your map.")
    ui.list.frame:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -24, 22)

    ui.foot = W.Label(page, "", "GameFontHighlightSmall")
    ui.foot:SetPoint("BOTTOMLEFT", 0, 2)
    ui.foot:SetPoint("RIGHT", page, "RIGHT", -10, 0)
end

local function buildBounties(page)
    ui.bountyCard = W.Card(page)
    ui.bountyCard:SetPoint("TOPLEFT", 0, 0)
    ui.bountyCard:SetPoint("RIGHT", page, "RIGHT", -4, 0)
    ui.bountyCard:SetHeight(58)
    local f = ui.bountyCard
    local h = W.Header(f, "Post a bounty")
    h:SetPoint("TOPLEFT", 8, -6)
    ui.bKind = "Guild"
    local kind = W.Cycle(f, 80, { "Guild", "Player" }, function() return ui.bKind end, function(v) ui.bKind = v end)
    kind:SetPoint("TOPLEFT", 8, -26)
    local target = W.EditBox(f, 190)
    target:SetPoint("LEFT", kind, "RIGHT", 10, 0)
    local rl = W.Label(f, C.dim .. "reward|r", "GameFontHighlightSmall")
    rl:SetPoint("LEFT", target, "RIGHT", 8, 0)
    local reward = W.EditBox(f, 110)
    reward:SetPoint("LEFT", rl, "RIGHT", 6, 0)
    local post = W.Button(f, "Post", 64, function()
        M:PostBounty(target:GetText(), ui.bKind, reward:GetText())
        target:SetText(""); reward:SetText("")
    end)
    post:SetPoint("LEFT", reward, "RIGHT", 8, 0)

    ui.bountyHeader = W.Header(page, "Open bounties")
    ui.bountyList = W.List(page, 24, function(row)
        row.text = W.Label(row, "")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -70, 0)
        row.text:SetWordWrap(false)
        row.del = W.Button(row, "Remove", 66)
        row.del:SetPoint("RIGHT", 0, 0)
    end, function(row, b)
        local kills = 0
        for _, c in pairs(db.claims) do if c.b == b.id and c.confirmed then kills = kills + 1 end end
        row.text:SetText(("%s%s|r %s%s|r%s  %s· by %s · %s left|r%s"):format(C.dim, b.kind == "Player" and "player" or "guild",
            C.gold, b.target, (b.reward or "") ~= "" and ("  " .. C.good .. b.reward .. "|r") or "", C.dim, tostring(b.by),
            W.Duration((b.exp or 0) - GetServerTime()), kills > 0 and ("  ·  " .. kills .. " confirmed kill" .. (kills == 1 and "" or "s")) or ""))
        row.del:SetShown(canCommand())
        row.del:SetScript("OnClick", function() M:RemoveBounty(b.id) end)
    end)
    ui.bountyList:SetEmptyText("No bounties posted. Officers can put a price on a rival guild or player.")

    ui.claimBtn = W.Button(page, "|TInterface\\Icons\\Ability_Rogue_Ambush:16:16|t Claim kill on target", 200, function() M:ClaimKill() end)
    ui.claimHeader = W.Header(page, "Claims")
    ui.claimList = W.List(page, 24, function(row)
        row.text = W.Label(row, "")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -84, 0)
        row.text:SetWordWrap(false)
        row.ok = W.Button(row, "Confirm", 80)
        row.ok:SetPoint("RIGHT", 0, 0)
    end, function(row, c)
        local state = c.confirmed and (C.good .. "confirmed by " .. R.Util.ShortName(c.confirmed) .. "|r")
            or (C.gold .. "needs a witness · " .. W.Duration(CLAIM_SECONDS - (GetServerTime() - (c.t or 0))) .. " left|r")
        row.text:SetText(("%s killed %s%s|r%s  %s"):format(W.ClassName(c.by), C.white, c.v,
            c.vg and (C.dim .. " <" .. c.vg .. ">|r") or "", state))
        local mine = R.Util.ShortName(c.by or "") == R.Util.ShortName(UnitName("player") or "")
        row.ok:SetShown(not c.confirmed and not mine)
        row.ok:SetScript("OnClick", function() M:Confirm(c.id) end)
    end)
    ui.claimList:SetEmptyText("Kill a bountied enemy, target the body and press Claim. Another RUIN member who saw it confirms.")
end

local function layoutBounties()
    local officer = canCommand()
    ui.bountyCard:SetShown(officer)
    local top = officer and -66 or 0
    ui.bountyHeader:ClearAllPoints()
    ui.bountyHeader:SetPoint("TOPLEFT", 0, top - 2)
    ui.bountyList.frame:ClearAllPoints()
    ui.bountyList.frame:SetPoint("TOPLEFT", 0, top - 20)
    ui.bountyList.frame:SetPoint("RIGHT", ui.bountyPage, "RIGHT", -24, 0)
    ui.bountyList.frame:SetHeight(officer and 120 or 170)
    ui.claimBtn:ClearAllPoints()
    ui.claimBtn:SetPoint("TOPRIGHT", ui.bountyList.frame, "BOTTOMRIGHT", 24, -8)
    ui.claimHeader:ClearAllPoints()
    ui.claimHeader:SetPoint("TOPLEFT", ui.bountyList.frame, "BOTTOMLEFT", 0, -12)
    ui.claimList.frame:ClearAllPoints()
    ui.claimList.frame:SetPoint("TOPLEFT", ui.claimHeader, "BOTTOMLEFT", 0, -10)
    ui.claimList.frame:SetPoint("BOTTOMRIGHT", ui.bountyPage, "BOTTOMRIGHT", -24, 0)
end

local function buildRecord(page)
    ui.week = "This week"
    local h = W.Header(page, "War record")
    h:SetPoint("TOPLEFT", 0, -2)
    local wk = W.Cycle(page, 110, { "This week", "Last week" }, function() return ui.week end,
        function(v) ui.week = v; refresh() end)
    wk:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 2)
    local sub = W.Label(page, C.dim .. ("Captures score %d, confirmed bounties %d. Weeks start Tuesday."):format(POINTS.cap, POINTS.bounty) .. "|r", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", 0, -20)

    local function rankRow(row)
        row.rank = W.Label(row, "", "GameFontNormalLarge")
        row.rank:SetPoint("LEFT", 6, 0)
        row.rank:SetWidth(26)
        row.text = W.Label(row, "")
        row.text:SetPoint("LEFT", 36, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.text:SetWordWrap(false)
    end
    local medals = { "|cffffd100", "|cffc0c0c0", "|cffcd7f32" }
    local gh = W.Header(page, "Guilds")
    gh:SetPoint("TOPLEFT", 0, -42)
    ui.guildBoard = W.List(page, 26, rankRow, function(row, e, i)
        row.rank:SetText((medals[i] or C.white) .. i .. "|r")
        row.text:SetText(("%s%s|r   %s%d pts|r   %s%d captures · %d bounties|r"):format(C.white, e.name, C.gold, e.pts, C.dim, e.c, e.b))
    end)
    ui.guildBoard:SetEmptyText("No captures or bounties yet this week.")
    ui.guildBoard.frame:SetPoint("TOPLEFT", 0, -60)
    ui.guildBoard.frame:SetPoint("RIGHT", page, "RIGHT", -24, 0)
    ui.guildBoard.frame:SetHeight(110)
    local ph = W.Header(page, "Top fighters")
    ph:SetPoint("TOPLEFT", 0, -184)
    ui.playerBoard = W.List(page, 22, rankRow, function(row, e, i)
        row.rank:SetText((medals[i] or C.white) .. i .. "|r")
        row.text:SetText(("%s   %s%d pts|r   %s%d captures · %d bounties|r"):format(W.ClassName(e.name), C.gold, e.pts, C.dim, e.c, e.b))
    end)
    ui.playerBoard:SetEmptyText("Take an objective or confirm a bounty to get on the board.")
    ui.playerBoard.frame:SetPoint("TOPLEFT", 0, -202)
    ui.playerBoard.frame:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -24, 0)
end

local function buildPage(panel)
    ui.panel = panel
    ui.tabs = W.SubTabs(panel, { "Objectives", "Bounties", "War record" }, function() refresh() end)
    buildObjectives(ui.tabs.pages[1])
    ui.bountyPage = ui.tabs.pages[2]
    buildBounties(ui.tabs.pages[2])
    buildRecord(ui.tabs.pages[3])

    refresh = function()
        if not ui.panel:IsVisible() then return end
        local tab = ui.tabs.selected
        local items = {}
        for _, o in pairs(db.objectives) do items[#items + 1] = o end
        ui.tabs:SetLabel(1, #items > 0 and ("Objectives (" .. #items .. ")") or "Objectives")
        local waiting = 0
        for _, c in ipairs(openClaims()) do if not c.confirmed then waiting = waiting + 1 end end
        ui.tabs:SetLabel(2, waiting > 0 and ("Bounties " .. C.good .. "(" .. waiting .. ")|r") or "Bounties")
        if tab == 1 then
            local officer = canCommand()
            ui.officer:SetShown(officer)
            ui.list.frame:ClearAllPoints()
            ui.list.frame:SetPoint("TOPLEFT", 0, officer and -70 or -30)
            ui.list.frame:SetPoint("BOTTOMRIGHT", ui.tabs.pages[1], "BOTTOMRIGHT", -24, 22)
            table.sort(items, function(a, b) return (a.t or 0) > (b.t or 0) end)
            ui.list:SetItems(items)
            ui.foot:SetText(C.dim .. ("A capture needs %d RUIN members inside the circle for %ds. Objectives expire after %d hours."):format(
                db.quorum, CAPTURE_SECONDS, OBJECTIVE_HOURS) .. "|r")
        elseif tab == 2 then
            layoutBounties()
            ui.bountyList:SetItems(activeBounties())
            ui.claimList:SetItems(openClaims())
        elseif tab == 3 then
            local key = weekKey() - (ui.week == "Last week" and 1 or 0)
            local guilds, players = leaderboard(key)
            ui.guildBoard:SetItems(guilds)
            local top = {}
            for i = 1, math.min(25, #players) do top[i] = players[i] end
            ui.playerBoard:SetItems(top)
        end
    end
    panel:SetScript("OnShow", function() refresh() end)
    ui.tabs:Select(1)
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
-- Officers answer a newcomer with bounties and this week's record too.
local function shareWithNewcomer()
    if not R:IsOfficer() then return end
    C_Timer.After(3 + math.random() * 8, function()
        for _, b in ipairs(activeBounties()) do
            if not b.practice then M:Send("BOUNTY", b, "ORG", nil, R.PRIORITY.BULK) end
        end
        local key = weekKey()
        local rec = db.record[key]
        if rec and next(rec.guilds) then
            M:Send("RECORD", { k = key, g = rec.guilds, p = rec.players }, "ORG", nil, R.PRIORITY.BULK)
        end
    end)
end

function M:OnEnable()
    if type(RUIN_WarfrontDB) ~= "table" then RUIN_WarfrontDB = {} end
    db = RUIN_WarfrontDB
    for k, v in pairs(DEFAULTS) do if db[k] == nil then db[k] = v end end

    self:Listen("OBJ", "OnObjective")
    self:Listen("DEL", "OnDelete")
    self:Listen("HERE", "OnHere")
    self:Listen("CAP", "OnCapture")
    self:Listen("CTA", "OnCallToArms")
    self:Listen("ASK", function(mod, d, sender) mod:OnAsk(d, sender); shareWithNewcomer() end)
    self:Listen("BOUNTY", "OnBounty")
    self:Listen("BDEL", "OnBountyDelete")
    self:Listen("CLAIM", "OnClaim")
    self:Listen("CONFIRM", "OnConfirm")
    self:Listen("RECORD", "OnRecord")
    self:AddTab("Warfront", buildPage)
    R:Subscribe("Intel:SPOT", onIntelSpot)

    R:Subscribe("CHANNELS_CHANGED", function()
        C_Timer.After(4, function() if R:IsConnected() then self:Send("ASK", {}, "ORG") end end)
    end)
    C_Timer.NewTicker(REPORT_EVERY, tick)
    updateHUD()
    updatePins()
end

function RUIN_Warfront_CallToArms() M:CallToArms() end
function RUIN_Warfront_Open() M:OpenTab() end
BINDING_HEADER_RUIN_WARFRONT = "RUIN Warfront"
BINDING_NAME_RUIN_WARFRONT_CTA = "Warfront: Call to Arms"
BINDING_NAME_RUIN_WARFRONT_OPEN = "Open Warfront"

SLASH_RUINWARFRONT1 = "/wf"
SLASH_RUINWARFRONT2 = "/warfront"
-- /wf mark <name> | help | hud | pins | practice | quorum <n>
-- /wf bounty guild|player <name> [reward] | claim | confirm
SlashCmdList.RUINWARFRONT = function(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.*)$")
    cmd = cmd:lower()
    if cmd == "mark" then
        M:Mark(rest)
    elseif cmd == "help" or cmd == "cta" then
        M:CallToArms()
    elseif cmd == "hud" then
        db.hud = not db.hud
        updateHUD()
    elseif cmd == "pins" then
        db.pins = not db.pins
        updatePins()
        M:Print("Map pins " .. (db.pins and "on." or "off."))
    elseif cmd == "practice" then
        M:SetPractice(not db.practice)
    elseif cmd == "quorum" and tonumber(rest) then
        db.quorum = math.max(1, math.floor(tonumber(rest)))
        M:Print("Capture quorum set to " .. db.quorum .. " (use 1 to test alone).")
    elseif cmd == "bounty" then
        local kind, name = rest:match("^(%S+)%s+(.+)$")
        kind = kind and kind:lower()
        if kind ~= "guild" and kind ~= "player" then
            return M:Print("Usage: /wf bounty guild <name> or /wf bounty player <name>")
        end
        local target, reward = name:match("^(.-)%s+%((.+)%)%s*$")
        M:PostBounty(target or name, kind == "player" and "Player" or "Guild", reward)
    elseif cmd == "claim" then
        M:ClaimKill()
    elseif cmd == "confirm" then
        M:Confirm()
    else
        M:OpenTab()
    end
end
