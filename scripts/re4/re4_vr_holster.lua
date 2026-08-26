-- Builtin implementation: src/mods/vr/games/re4/RE4VRHolster.cpp
return

-- =====================================================================
-- RE4 VR — Holster (NEU) [ersetzt schrittweise re4_vr_holster_legacy.lua]
-- =====================================================================
-- Generisches "Slot"-System: die jeweils genutzte Waffe schwebt als sichtbarer
-- Klon an einem Body-Joint (Hueft-Hoehe) + eigenem Offset. Am Klon-Root greifen
-- (rechte Hand nah + R-Grip) = equippen/holstern (Toggle). Bewegung gelerpt,
-- in ALLEN 5 Render-Paessen gepinnt. Klon dunkelt bei Nutzung ab (Material).
--
-- Zwei Slots:
-- MESSER -> requestEquipKnife / stow = bare hands (R-Grip in Hand = Wurf)
-- PISTOLE -> letzte 1-Hand-Waffe / stow = bare hands (R-Grip in Hand = AIM)
-- Nur 1-Hand-Waffen (PISTOL_IDS). Aim wird NUR an der Grab-Zone + bei bare hands
-- + Messer-in-Hand unterdrueckt (binding). Kein Code im Motion-Script.
-- Caches (Klon/Material/Handles) bauen sich nach Save-Load + Reset selbst neu auf.
-- =====================================================================

if reframework:get_game_name() ~= "re4" then return end
if not vrmod then return end

-- [KILLSWITCH] is_active = true bei JEDEM aktiven Killswitch (KS1/KS2/KS3, Cutscenes/Zwischensequenzen).
-- Dann: keine Mesh-Clones, keine Grabs, keine Haptik. Fallback = nie aktiv.
local ok_ks, killswitch = pcall(function() return require("re4vr/re4_vr_killswitch") end)
if not ok_ks or not killswitch then killswitch = { is_active = function() return false end,
    get_stage_name = function() return nil end } end
local function ks_active() local ok, v = pcall(killswitch.is_active); return ok and v == true end

-- [KNIFE_ONLY_STAGES 2026-07-15] Reine Messer-Fights (Krauser, Stage 55302): Pistole/Langwaffe/Granate/
-- Magazin komplett dormant, damit im Fight gar nicht erst jemand eine Waffe zieht. NUR der Messer-Slot
-- bleibt normal (sonst kaeme man an die einzige Waffe der Szene nicht ran).
-- ZWEI Bedingungen, Stage allein reicht NICHT: nach dem Kampf laeuft dieselbe Stage weiter, Krauser ist
-- aber weg -> die Holster muessen zurueck. Umgekehrt kommt Krauser spaeter nochmal, dann aber in einer
-- ANDEREN Stage und mit erlaubten Waffen -> die Stage-Bedingung faengt das ab.
-- KRAUSER = chainsaw.Ch1b7z0Context, KindID 200011 (per re4_zz_enemy_log.lua am lebenden Objekt bestimmt:
-- in 55302 der einzige Context; die 5x Ch1d3z0Context/200005 sind die Gegner unten im Aufzugschacht).
-- get_IsDead gibt es an dem Context NICHT (immer nil) -> nicht noetig: ist Krauser weg, faellt sein
-- Context komplett aus der EnemyContextList (live belegt: "Stage=55302 ListCount=0").
local KNIFE_ONLY_STAGES = { [55302] = true }
local KRAUSER_KIND = 200011
-- 0.5s-Throttle wie das bestehende [INV_CHECK]-Muster: die Enemy-Liste jeden Frame durchzugehen waere
-- unnoetige Last. Kosten = das Holster kommt bis zu 0.5s nach Krausers Abgang zurueck.
local knife_only_chk = { t = 0.0, val = false }
local function knife_only_stage()
    local now = os.clock()
    if now - knife_only_chk.t < 0.5 then return knife_only_chk.val end
    knife_only_chk.t = now
    knife_only_chk.val = false
    local ok, v = pcall(killswitch.get_stage_name)
    if not ok or v == nil then return false end
    if not KNIFE_ONLY_STAGES[tonumber(v) or v] then return false end
    -- pcall statt des safe-Helfers: der ist erst weiter unten (Z.~82) definiert und waere hier oben
    -- lexikalisch nicht sichtbar -> globaler Lookup auf nil -> Absturz beim ersten Aufruf.
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
    if not cm then return false end
    local okl, list = pcall(function() return cm:call("get_EnemyContextList") end)
    if not okl or not list then return false end
    local okc, count = pcall(function() return list:call("get_Count") end)
    if not okc or type(count) ~= "number" then return false end
    for i = 0, count - 1 do
        local oki, ctx = pcall(function() return list:call("get_Item", i) end)
        if oki and ctx then   -- null-Slots = Pool
            local okk, kind = pcall(function() return ctx:call("get_KindID") end)
            if okk and kind == KRAUSER_KIND then knife_only_chk.val = true; break end
        end
    end
    return knife_only_chk.val
end

-- [NO_WEAPON_STAGES] no_weapons_yet ist weiter unten definiert (nach has_weapon_in_inventory) -- es braucht
-- den Inventar-Check, und der steht dort. slot_dormant liest hier nur das globale __re4_holster_killswitch.
-- Gate fuer die Waffen-Slots. Killswitch = alles aus (wie bisher); Messer-Stage = alles ausser "knife" aus.
-- An JEDER Stelle noetig, an der ein Slot sichtbar/greifbar wird -- Mesh zerstoeren allein reicht NICHT:
-- nearest_with_clone laesst detached_zone-Slots (Langwaffe) auch OHNE Klon greifen (klonlose Zone hinterm Ruecken).
local function slot_dormant(S)
    if _G.__re4_holster_killswitch == true then return true end
    return _G.__re4_holster_knife_only == true and S.name ~= "knife"
end
-- [AUTO_REDRAW] Nach Engine-Wegnahme der Waffe (Stagger/Kick/Killswitch) den Zustand von VORHER wieder
-- herstellen -- "nach dem Ereignis genau das selbe wie davor, von bare hands bis Langwaffe" (-Regel).
-- snap = Zustand bei sauberem Gameplay: KONKRETE Waffen-ID (number) oder false = leere Haende.
-- nil = noch nie einen eindeutigen Zustand gesehen. Friert im KS/Stagger ein (pg=false).
-- Loeste ar.kind ab (das kannte nur den Typ, nicht WELCHE Waffe, und "bare" gar nicht).
-- suppress = du hast BEWUSST geholstert (Stow) -> kein Auto-Draw, bleibt bare (deckt die deferred Luecke
-- zwischen Grab und echtem Equip-Wechsel ab). stow_until = kurzer Guard ueber den Equip-Delay des Stows.
local auto_redraw = { snap = nil, suppress = false, stow_until = 0.0, next_try = 0.0 }
-- [MERCS-LEVELSTART] Merker fuer die Ladephase (Body nicht lesbar) -- s. Block im Auto-Redraw.
local merc_body_weg = false
local function get_player_body_go()
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager"); if not cm then return nil end
    local ok, ctx = pcall(function() return cm:call("getPlayerContextRef") end)
    if not ok or not ctx then return nil end
    local ok2, bg = pcall(function() return ctx:call("get_BodyGameObject") end)
    if not ok2 then return nil end
    return bg
end

-- [SAFE_GIBT_IMMER_EINEN_WERT 2026-07-31] Ohne das explizite `return nil` liefert diese
-- Funktion im Fehlerfall GAR KEINEN Wert (nicht nil, NICHTS). In tostring(safe(...)) kommt dann
-- kein Argument an -> "bad argument #1 to 'tostring' (value expected)" -> der ganze umgebende
-- Aufruf stirbt. Genau daran ist am 31.07. der Bogen-Reload gestorben. Im Erfolgsfall unveraendert.
local function safe(fn) local ok, r = pcall(fn); if ok then return r end return nil end
local function sc(o, m, ...) if not o then return nil end local a = { ... }
    local ok, r = pcall(function() return o:call(m, table.unpack(a)) end); return ok and r or nil end
local function sf(o, n) if not o then return nil end local ok, r = pcall(function() return o:get_field(n) end); return ok and r or nil end
-- Messer (identisch zu weapons.lua KNIFE_IDS)
local KNIFE_IDS = { [5000]=true,[5001]=true,[5002]=true,[5003]=true,[5006]=true,[6107]=true,[6108]=true,[6305]=true }
-- Einhand-Waffen (Pistolen/Magnums) fuer den zweiten Holster (-Liste)
local PISTOL_IDS = { [4000]=true,[4001]=true,[4002]=true,[4003]=true,[4004]=true,
    [4500]=true,[4501]=true,[4502]=true,[6000]=true,[6103]=true,[6112]=true,[6113]=true,[6300]=true,[6301]=true }
-- Granaten (Wurf laeuft ueber weapons.lua Grip-Release; hier nur der Holster + Equip)
local GRENADE_IDS = { [5400]=true, [5401]=true, [5402]=true }
-- Langwaffen fuer das Schulter-Holster (Rifle/Shotgun/SMG/RL/Bow) — -Liste 2026-07-02.
-- HINWEIS: wp6107 (SW Tactical Knife) NICHT hier -> ist ein Messer, laeuft ueber KNIFE_IDS/Messer-Holster.
local SHOULDER_IDS = {
    [4100]=true, -- W-870
    [4101]=true, -- Riot Gun
    [4102]=true, -- Striker
    [4200]=true, -- TMP
    [4201]=true, -- Chicago Sweeper
    [4202]=true, -- LE 5
    [4400]=true, -- SR M1903
    [4401]=true, -- Stingray
    [4402]=true, -- CQBR Assault Rifle
    [4600]=true, -- Bolt Thrower
    [4701]=true, -- Flamethrower
    [4702]=true, -- Flamethrower 2 / P.R.L. 9412
    [4900]=true, -- Rocket Launcher
    [4901]=true, -- Rocket Launcher (Special)
    [4902]=true, -- Infinite Rocket Launcher
    [6001]=true, -- DLC Skull Shaker
    [6100]=true, -- SW Sawed-off W-870
    [6101]=true, -- SW Chicago Sweeper w/ Drum
    [6102]=true, -- SW Blast Crossbow
    [6104]=true, -- SW TMP / MP-AF
    [6105]=true, -- SW Stingray -> Anti-Materiel Rifle
    [6106]=true, -- SW Rocket Launcher
    [6111]=true, -- SW Infinite Rocket Launcher
    [6114]=true, -- SW SR M1903 -> Hunting Rifle
    [6304]=true, -- MC EJF-338 Compound Bow
    -- [2026-07-22] Nachgetragen: bisher unreleased, schaden aber nicht -- damit ist die Liste
    -- vollstaendig gegen alles, was jemals als Langwaffe im Code gefunden wurde.
    [4800]=true, -- Unreleased Silent Crossbow
    [4801]=true, -- Unreleased XJF-350 Compound Bow
    [6109]=true, -- Unreleased Scorcher XL
}

local CHEST_JOINT_CANDIDATES = { "Spine_1", "Spine1", "Spine_2", "Spine2", "Chest", "Kammer", "Spine", "Hip" }
local _mesh_td = sdk.typeof("via.render.Mesh")

-- ---- Player / Body / Equip ----
-- [FRAME-CACHE 2026-08-17] Siehe re4vr/re4_vr_frame_cache.lua: dieselben Objekte wurden pro Frame
-- dutzendfach neu bei der Engine erfragt (get_equip_wid = vier Managed-Calls, body_tf = drei),
-- und die Waffen-Paesse laufen 4-5 mal pro Frame. Ab jetzt einmal pro Frame, danach aus einer
-- Lua-Tabelle. Semantik unveraendert -- die alten Wege stehen als Fallback darunter.
-- NOT-AUS: `_G.__re4_fc_off = true`. Bewusst OHNE Datei-Local (Lua-200-Local-Limit).
pcall(function() require("re4vr/re4_vr_frame_cache") end)
local character_manager = nil
local function get_ctx()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.ctx() end
    if not character_manager then character_manager = sdk.get_managed_singleton("chainsaw.CharacterManager") end
    return character_manager and sc(character_manager, "getPlayerContextRef")
end
local function body_tf()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.body_tf() end
    local ctx = get_ctx(); if not ctx then return nil end
    local b = sc(ctx, "get_BodyGameObject"); return b and sc(b, "get_Transform")
end
local function get_equip_wid()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.equip_wid() end
    local ctx = get_ctx(); if not ctx then return nil end
    local hu = sc(ctx, "get_HeadUpdater"); if not hu then return nil end
    local wid = sc(hu, "get_EquipWeaponID")
    if type(wid) == "userdata" then local b = sf(wid, "value__"); if type(b) == "number" then return b end end
    if type(wid) == "number" then return wid end
    return nil
end
-- [BARE_HANDS] Ehrliches "ist gerade wirklich eine Waffe GEZOGEN?"-Signal, direkt vom HeadUpdater.
-- get_EquipWeaponID LUEGT: es meldet die zuletzt gewaehlte Waffe auch bei leeren Haenden -> deshalb
-- wurde bare-hands nie erkannt, der Aim-Guard griff nicht, und das Spiel zog bei Right-Grip (=Aim)
-- automatisch die letzte Waffe. get_IsEquipGun/Knife/Grenade/Melee sind die Wahrheit (Live-Abfrage
-- 2026-07-02: mit wp4201 in der Hand -> IsEquipGun=true, Knife/Grenade=false).
local function weapon_actually_in_hand()
    local ctx = get_ctx()
    if not ctx then
        -- [IN-HAND-DIAG 2026-07-20] snap=nil + pure_since seit Spielstart => diese Erkennung sagt bei
        -- Ada offenbar NIE "Waffe in der Hand". Dann kann sich der Auto-Redraw nichts merken und holt
        -- folglich auch nichts zurueck -- unabhaengig vom Kamera-Zustand. Hier die Rohwerte festhalten.
        if (os.clock() - (tonumber(rawget(_G, "__re4_inhand_diag_t")) or 0)) > 2.0 then
            _G.__re4_inhand_diag_t = os.clock()
            local f = rawget(_G, "__re4_rkdiag")
            if type(f) == "function" then f("INHAND", "kein PlayerContext (ctx=nil)") end
        end
        return nil
    end
    local hu = sc(ctx, "get_HeadUpdater")
    if not hu then
        if (os.clock() - (tonumber(rawget(_G, "__re4_inhand_diag_t")) or 0)) > 2.0 then
            _G.__re4_inhand_diag_t = os.clock()
            local f = rawget(_G, "__re4_rkdiag")
            if type(f) == "function" then f("INHAND", "kein HeadUpdater") end
        end
        return nil
    end
    if (os.clock() - (tonumber(rawget(_G, "__re4_inhand_diag_t")) or 0)) > 2.0 then
        _G.__re4_inhand_diag_t = os.clock()
        local f = rawget(_G, "__re4_rkdiag")
        if type(f) == "function" then
            -- [ENTSCHEIDEND] pg/camstate MIT Waffe in der Hand -- nur wenn hier "pg=true" steht, wird der
            -- Merker (ar.snap) ueberhaupt gepflegt. Die RESTORE-Zeile zeigt das nie, sie laeuft nur bei
            -- leeren Haenden. Genau diese Luecke war der blinde Fleck.
            f("INHAND", "gun=" .. tostring(sc(hu, "get_IsEquipGun")) ..
              " knife=" .. tostring(sc(hu, "get_IsEquipKnife")) ..
              " gren=" .. tostring(sc(hu, "get_IsEquipGrenade")) ..
              " melee=" .. tostring(sc(hu, "get_IsEquipMelee")) ..
              " wid=" .. tostring(sc(hu, "get_EquipWeaponID")) ..
              " | pg=" .. tostring(killswitch.is_pure_gameplay and killswitch.is_pure_gameplay()) ..
              " camstate=" .. tostring(killswitch.get_cam_state and killswitch.get_cam_state()) ..
              " snap=" .. tostring(auto_redraw and auto_redraw.snap))
        end
    end
    local gun   = sc(hu, "get_IsEquipGun")
    local knife = sc(hu, "get_IsEquipKnife")
    local gren  = sc(hu, "get_IsEquipGrenade")
    local melee = sc(hu, "get_IsEquipMelee")
    -- [BARE_FIX] Im holstered/bare-Zustand liefern die IsEquip*-Getter ALLE nil (NICHT false), wid=-1
    -- (per Live-Log verifiziert 2026-07-03). Frueher gab "alle nil" -> nil ("unbekannt") zurueck ->
    -- der if-in_hand~=nil-Guard liess __vr_bare_hands beim alten false haengen -> Aim-Guard aus ->
    -- Right-Grip zog die letzte Waffe. FIX: bei lauter nil ist die EquipWeaponID die Wahrheit.
    if gun == nil and knife == nil and gren == nil and melee == nil then
        local wid = tonumber(sc(hu, "get_EquipWeaponID"))
        if wid == nil then return nil end                -- wirklich unbekannt: nicht anfassen
        if wid < 0 then return false, false, false end    -- -1/invalid = wirklich BARE -> Aim-Sperre AN
        -- [AMBIGUOUS] gueltige Waffen-ID, aber Typ UNBEKANNT: get_EquipWeaponID meldet die letzte HAUPT-
        -- Waffe (Gun), auch wenn gerade ein MESSER in der Hand ist (z.B. transient waehrend Messer-Melee).
        -- 4. Rueckgabewert = "mehrdeutig" -> der Auto-Redraw darf ar.kind hierauf NICHT auf "gun" flippen
        -- (sonst wird nach dem Melee die letzte Gun statt des Messers gezogen). in_hand bleibt true.
        return true, false, false, true
    end
    -- Rueckgabe: in_hand (irgendeine Waffe), knife, grenade, mehrdeutig=false (Getter sind zuverlaessig).
    -- IsEquipMelee zaehlt NICHT als "in Hand" (bare-hands Faust-Stance) -> sonst waere man nie bare.
    return (gun == true) or (knife == true) or (gren == true),
           (knife == true), (gren == true), false
end
-- Waffen-GO (geholstert ODER equippt) im Body-Baum: Name "wpXXXX" mit XXXX in ids. Optional want_wid
-- bevorzugen (z.B. die zuletzt genutzte Pistole), sonst die erste passende.
local function find_weapon_go(ids, want_wid)
    local tf = body_tf(); if not tf then return nil, nil end
    local any_go, any_wid, want_go = nil, nil, nil
    local function walk(t, depth)
        if not t or depth > 5 or want_go then return end
        local go = sc(t, "get_GameObject")
        local nm = go and sc(go, "get_Name")
        if type(nm) == "string" then
            local id = tonumber(nm:match("^wp(%d+)") or "")
            -- [VALID] Nur LEBENDE Objekte: nach Save-Load haengen tote wpXXXX-Instanzen (alter Zeiger, letzte
            -- Position) im Baum -> get_Valid==false ueberspringen, sonst klont das Holster ein totes Mesh.
            if id and ids[id] and sc(go, "get_Valid") ~= false then
                if not any_go then any_go, any_wid = go, id end
                if want_wid and id == want_wid then want_go = go end
            end
        end
        local c = sc(t, "get_Child")
        while c and not want_go do walk(c, depth + 1); c = sc(c, "get_Next") end
    end
    walk(tf, 0)
    if want_wid and want_go then return want_go, want_wid end
    return any_go, any_wid
end

-- ---- PlayerEquipment (deferred Equip/Stow) ----
local pe_td = sdk.typeof("chainsaw.PlayerEquipment")
local _pe = nil
local function get_pe()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.pe() end
    if _pe and safe(function() return _pe:call("get_Context") end) then return _pe end
    local ctx = get_ctx(); local head = ctx and sc(ctx, "get_HeadGameObject"); if not head then return nil end
    _pe = sc(head, "getComponent(System.Type)", pe_td); return _pe
end

-- Inventar-Helfer (aus legacy-Holster) fuer das Ziehen einer SPEZIFISCHEN Pistole.
local function enum_value(o)
    if o == nil then return nil end
    if type(o) == "number" then return o end
    local v = sf(o, "value__"); if type(v) == "number" then return v end
    return nil
end
-- [LOG-FLUT 2026-07-20 -- per Framework-Log belegt] sc(g, "ToString") auf einer System.Guid
-- schlaegt fehl ("Invalid number of arguments passed to REMethodDefinition::invoke for
-- System.Guid.ToString") -- und REFramework schreibt JEDE dieser Warnungen auf die Platte. Weil die
-- Funktion pro Frame DREIMAL lief (letzte Pistole/Granate/Langwaffe), waren das ~100 Log-Zeilen pro
-- Sekunde. Das wuergt den Script-Thread ab: Live-Abfrage antwortete nicht mehr, Granaten liessen sich nicht
-- werfen, die native Wurflinie blieb stehen -- und "Reset Scripts" hat es scheinbar "repariert".
-- FIX: die Guid ueber ihre ROHDATEN vergleichbar machen (4 Felder, reine Feldlesungen, kein Invoke).
-- Ergibt einen stabilen Schluessel-String; er muss nicht dem echten Guid-Format entsprechen, er wird
-- ausschliesslich zum VERGLEICHEN benutzt. Fallback auf ToString nur, wenn die Felder fehlen.
local function guid_to_string(g)
    if g == nil then return nil end
    if type(g) == "string" then return g end
    -- Feldnamen der Guid EINMAL ermitteln (RE-Engine nutzt mData*,.NET nutzt _a/_b/...). Der Satz,
    -- der Werte liefert, wird gemerkt -> danach nur noch reine Feldlesungen, kein Invoke, kein Log.
    local sets = _G.__re4_guid_sets or { {"mData1","mData2","mData3","mData4"}, {"_a","_b","_c","_d"} }
    _G.__re4_guid_sets = sets
    local pick = _G.__re4_guid_fields
    if pick == nil then
        for _, f in ipairs(sets) do
            if safe(function() return g:get_field(f[1]) end) ~= nil then pick = f; break end
        end
        _G.__re4_guid_fields = pick or false   -- false = keiner passt, nicht erneut suchen
    end
    if pick and pick ~= false then
        local out = {}
        for i = 1, #pick do out[i] = tostring(safe(function() return g:get_field(pick[i]) end)) end
        return table.concat(out, "-")
    end
    -- [KEIN ToString-FALLBACK] Bewusst KEIN sc(g,"ToString") mehr: genau der Aufruf hat pro Frame
    -- Warnungen auf die Platte geschrieben und den Script-Thread abgewuergt. Lieber kein Guid-Schluessel
    -- (die Aufrufer haben Fallbacks ueber die Waffen-ID) als ein haengendes Spiel.
    return nil
end
local function inventory_weapon_rows(inv)
    local out = {}; local list = inv and sc(inv, "getInventoryItemList"); if not list then return out end
    local n = sc(list, "get_Count") or 0
    for i = 0, n - 1 do
        local row = sc(list, "get_Item", i); local wid = row and enum_value(sc(row, "get_WeaponId"))
        if wid and wid ~= 0 then out[#out + 1] = row end
    end
    return out
end
-- [INV_CHECK] Ist eine Waffe aus 'ids' ueberhaupt im Inventar? -> Klon nur dann anzeigen (kein Phantom-Dummy
-- fuer Granate/Pistole/Langwaffe/Messer, die man gar nicht besitzt; erstes Level ohne Waffen = keine Klone).
local function has_weapon_in_inventory(ids)
    local pe = get_pe(); local inv = pe and sc(pe, "get_InventoryController"); if not inv then return false end
    for _, row in ipairs(inventory_weapon_rows(inv)) do
        local wid = enum_value(sc(row, "get_WeaponId"))
        if wid and ids[wid] then return true end
    end
    return false
end

-- [NO_WEAPON_STAGES 2026-07-16] Spielanfang VOR der Waffen-Cutscene: Leon darf noch KEIN Holster haben (keine
-- Klone, kein Greifen, kein Auto-Redraw) und die Haende bleiben leer. Betrifft die vier Start-Stages (Space 40500).
-- ROCK-SOLIDER TRIGGER ( 2026-07-16, live live verifiziert): waffenlos = Start-Stage UND die Waffen-
-- Schnellwahl (DPAD) ist per Story GESPERRT -> PlayerBaseContext.get_IsRestrictionWeaponShortcut == true.
-- Vor der Cutscene ist die Sperre an (DPAD-Menue nicht verfuegbar), die Waffen-Cutscene in 40510 hebt sie auf.
-- Das ist der ECHTE Spiel-Zustand -> Save-Load-fest: ein Pre-Cutscene-Punkt (auch in DERSELBEN Stage 40510) hat
-- die Sperre wieder an. Kein Latch, kein Reset. Bewusst NICHT das Inventar (man HAT die Waffen schon im
-- Save -> Inventar luegt) und NICHT "Cutscene gesehen" merken (ueberlebt keinen Load). ctx nil -> sicher waffenlos.
local NO_WEAPON_STAGES = { [40500] = true, [40501] = true, [40502] = true, [40510] = true }
local no_weapon_chk = { t = 0.0, val = false }
local function no_weapons_yet()
    local now = os.clock()
    if now - no_weapon_chk.t < 0.3 then return no_weapon_chk.val end
    no_weapon_chk.t = now
    local ok, v = pcall(killswitch.get_stage_name)
    local stage = ok and (tonumber(v) or v) or nil
    if stage == nil or not NO_WEAPON_STAGES[stage] then no_weapon_chk.val = false; return false end
    local ctx = get_ctx()
    if not ctx then no_weapon_chk.val = true; return true end   -- Spieler nicht geladen -> sicher waffenlos
    no_weapon_chk.val = (sc(ctx, "get_IsRestrictionWeaponShortcut") == true)
    return no_weapon_chk.val
end
local function find_row_for_weapon(inv, wid, guid)
    if not (inv and wid and wid ~= 0) then return nil end
    local want = (type(guid) == "string" and guid ~= "") and string.lower(guid) or nil
    local rows = inventory_weapon_rows(inv)
    if want then for _, row in ipairs(rows) do
        local gid = guid_to_string(sc(row, "get_ID")); if gid and string.lower(gid) == want then return row end end end
    for _, row in ipairs(rows) do if enum_value(sc(row, "get_WeaponId")) == wid then return row end end
    return nil
end
local _equip_type_main = nil
local function get_equip_type_main()
    if _equip_type_main ~= nil then return _equip_type_main end
    local td = sdk.find_type_definition("chainsaw.EquipType"); local f = td and td:get_field("Main")
    if f then _equip_type_main = f:get_data(nil) end
    return _equip_type_main
end

-- =====================================================================================================
-- [DER SLOT DARF NIE LEER SEIN 2026-08-01, "das da kein ITEM ist ist FALSCH und DARF NICHT SEIN"]
-- Live gemessen (Live-Abfrage, Skull Shaker in der Hand): `get_EquipWeaponID` = wp6001, aber
-- `getEquippedItemId` = Dummy(0) fuer ALLE VIER EquipTypes. Waffe da, Inventar-Slot leer.
-- Daran haengt ALLES, was ueber den Inventar-Controller laeuft:
-- enableReloadItem -> false ("nichts zu laden") -> kein Nachladen
-- inv:reload -> deref't die null-Row -> das ist DER Crash (RCX=0)
-- addAmmoCount -> trifft nur noch Kopien -> "Item steigt, HUD bleibt"
-- __re4_safe_reduce -> findet die Zeile nicht -> Reserve-Abzug ohne Ladung
-- Nur execReload haengt am Player statt am Slot -- deshalb luden Blacktail/TMP/Punisher weiter,
-- waehrend Schuss-fuer-Schuss-Waffen komplett tot waren. Es war nie der Ladeweg.
-- Entstehung: alle Zieh-Pfade rufen `inv:equip(gid)` nur BEDINGT (`if gid then`), aktivieren die Waffe
-- aber BEDINGUNGSLOS -- fehlt gid oder greift das Equippen nicht, bleibt genau dieser halbe Zustand.
-- Der Wachhund repariert das, statt es zu melden: gefuehrte Waffen-ID vorhanden + kein Item im Slot
-- -> passende Inventar-Zeile suchen und equippen. Kein neuer Call: `inv:equip(Guid)` laeuft seit Wochen
-- bei jedem Holster-Zug (Z. 442/477/523/560) und taucht in KEINEM Crash-Log auf -- gecrasht ist immer
-- `reload`, ein anderer Einstiegspunkt. Gedrosselt auf 4x/s, und pro Waffen-ID hoechstens ein Versuch
-- pro Sekunde, damit ein aussichtsloser Fall nicht jeden Frame neu anlaeuft.
-- =====================================================================================================
local _eqg_t, _eqg_wid, _eqg_n = 0, nil, 0
local function equip_slot_guard()
    local now = os.clock()
    if now - _eqg_t < 0.25 then return end
    _eqg_t = now
    local pe  = get_pe();                            if not pe  then return end
    local inv = sc(pe, "get_InventoryController");   if not inv then return end
    local et  = get_equip_type_main();               if not et  then return end
    local wid = get_equip_wid()
    if not wid or wid <= 0 then _eqg_wid, _eqg_n = nil, 0; return end
    -- Slot belegt? Dann ist alles in Ordnung -- und der Zaehler wird zurueckgesetzt.
    local ok_eq, eq = pcall(function() return inv:call("getEquippedWeapon", et) end)
    if (not ok_eq) or eq ~= nil then _eqg_wid, _eqg_n = nil, 0; return end
    -- Ab hier: Waffe in der Hand, Slot leer. Hoechstens 4 Versuche pro Waffe, dann Ruhe bis zum Wechsel.
    if _eqg_wid ~= wid then _eqg_wid, _eqg_n = wid, 0 end
    if _eqg_n >= 4 then return end
    _eqg_n = _eqg_n + 1
    local row = find_row_for_weapon(inv, wid, nil)
    local gid = row and sc(row, "get_ID")
    if not gid then
        _G.__re4_equip_guard_log = string.format("wid=%d: keine Inventar-Zeile gefunden (Versuch %d)", wid, _eqg_n)
        return
    end
    pcall(function() inv:call("equip", gid) end)
    -- Nachmessen: nur was sich belegen laesst, gilt als repariert.
    local ok2, eq2 = pcall(function() return inv:call("getEquippedWeapon", et) end)
    local fixed = ok2 and eq2 ~= nil
    _G.__re4_equip_guard_log = string.format("wid=%d Versuch %d -> %s", wid, _eqg_n, fixed and "SLOT WIEDER BELEGT" or "weiterhin leer")
    if fixed then _eqg_n = 0 end
end
-- [MINECART] Vom Kart aus (weapons.lua) aufrufbar: aktiv aus dem Messer auf die Main-Waffe wechseln, damit der
-- Kart die Mounted-Gun geben kann. MUSS deferred im updateOnFrameHead-Hook laufen (__re4_knife_defer), sonst greift
-- der Wechsel nicht (wie beim Pistol/Granaten-Draw). requestChangeActiveWeapon(Main) zwingt weg vom Messer.
-- (__re4_force_change_to_main ist weiter unten definiert -- NACH weaponid_enum, weil es den Enum-Helfer braucht.)
-- WeaponID-Enum aus einer Zahl bauen (fuer equipWeapon, das ein echtes chainsaw.WeaponID braucht).
local _wid_td = sdk.find_type_definition("chainsaw.WeaponID")
local function weaponid_enum(wid)
    if not (_wid_td and wid) then return nil end
    local f = _wid_td:get_field("wp" .. tostring(wid))
    return f and f:get_data(nil)
end
-- [MINECART] Vom Kart (minecart.lua) DEFERRED aufrufbar (__re4_knife_defer -> updateOnFrameHead-Hook): die
-- Minecart-Handgun wp4005 ("Don Quixote", Red9-Clone, existiert NUR im Kart) DIREKT in den Main-Slot equippen ->
-- egal ob der Player mit Messer, Langwaffe oder bare reinkam (universell, kein Pistol-Slot-Trick noetig). Bereits
-- 4005 equippt -> No-op (stoert Feuern/Reload nicht). Sequenz: equipWeapon(Main, wp4005) -> requestChangeActiveWeapon(
-- Main) -> execChangeWeapon (Request allein greift nicht). MUSS deferred laufen, sonst greift der Wechsel nicht.
_G.__re4_force_change_to_main = function()
    local pe = get_pe()
    if not pe then
        -- [log entfernt]
        return false
    end
    local cur = nil
    pcall(function() cur = enum_value(pe:call("get_EquipWeaponID")) end)
    if cur == 4005 then return true end   -- schon die Cart-Gun -> nichts tun
    local wid = weaponid_enum(4005)
    local et  = get_equip_type_main()
    pcall(function() pe:call("clearRequest") end)
    local okE = false
    if wid and et then okE = pcall(function() pe:call("equipWeapon", et, wid, false, false) end) end
    if et then pcall(function() pe:call("requestChangeActiveWeapon(chainsaw.EquipType, System.Boolean, System.Boolean)", et, false, false) end) end
    pcall(function() pe:call("execChangeWeapon") end)
    -- [log entfernt]
    return true
end
local function get_equipped_main_guid(inv)
    local et = get_equip_type_main(); if not (inv and et) then return nil end
    return guid_to_string(sc(inv, "getEquippedID", et))
end

-- Zuletzt genutzte 1-Hand-Waffe merken (fuer Klon-Anzeige + Ziehen).
local last_pistol = { wid = 0, guid = "" }
local function track_last_pistol()
    local ew = get_equip_wid()
    if ew and PISTOL_IDS[ew] then
        last_pistol.wid = ew
        local pe = get_pe(); local inv = pe and sc(pe, "get_InventoryController")
        local g = inv and get_equipped_main_guid(inv); if type(g) == "string" then last_pistol.guid = g end
    end
end

-- Zuletzt genutztes Messer merken -> der Holster-Klon zeigt das AKTUELL genutzte Messer (nicht ein
-- festes). Wenn ein Messer gezogen ist (get_IsEquipKnife), meldet get_EquipWeaponID dessen ID.
local last_knife = { wid = 0 }
local function track_last_knife()
    local ctx = get_ctx(); if not ctx then return end
    local hu = sc(ctx, "get_HeadUpdater"); if not hu then return end
    if sc(hu, "get_IsEquipKnife") == true then
        local wid = tonumber(sc(hu, "get_EquipWeaponID"))
        if wid and KNIFE_IDS[wid] then last_knife.wid = wid end
    end
end
-- [EQUIP-VERIFIKATION 2026-08-01, "dann ist der redraw falsch... bitte keine Symptome"] Schreibt
-- NUR im Fehlerfall (also praktisch nie) nach reframework\data\re4_equip_fail.log. Lua steht dort schon
-- im data-Verzeichnis -> nur der Dateiname, sonst legt es data\reframework\data an.
local function hol_warn(msg)
    -- Schreibt nichts mehr (keine Logs ausserhalb der "#"-Werkzeuge). Der letzte
    -- Hinweis bleibt als Global lesbar, die Aufrufstellen koennen so stehen bleiben.
    _G.__re4_holster_warn = tostring(msg)
end

local function draw_last_pistol(pe)
    local inv = pe and sc(pe, "get_InventoryController")
    local et  = get_equip_type_main()
    local row
    if inv then
        row = (last_pistol.wid ~= 0) and find_row_for_weapon(inv, last_pistol.wid, last_pistol.guid) or nil
        if not row then   -- keine gemerkte Pistole -> erste 1-Hand-Waffe aus dem Inventar (wird neuer Default)
            for _, r in ipairs(inventory_weapon_rows(inv)) do
                local wid = enum_value(sc(r, "get_WeaponId"))
                if wid and PISTOL_IDS[wid] then row = r; last_pistol.wid = wid; break end
            end
        end
        local gid = row and sc(row, "get_ID")
        if gid then pcall(function() inv:call("equip", gid) end) end
        -- =====================================================================================
        -- [URSACHE 2026-08-01, live gemessen] Hier entstand der Zustand "Pistole laedt nicht mehr":
        -- `pe:get_EquipWeaponID` meldete wp4001, aber `inv:getEquippedWeapon` gab fuer ALLE VIER
        -- EquipTypes null -- Waffen-ID gesetzt, aber KEIN Item equippt. Jeder Ladeweg braucht das Item,
        -- also lud nichts, waehrend `isEnableReload` weiter true meldete (Geste lief normal durch).
        -- Der Ablauf darunter aktivierte die Waffe BEDINGUNGSLOS -- auch wenn `gid` fehlte (dann lief
        -- inv:equip nie) oder das Equippen wirkungslos blieb. `pcall` beweist dabei GAR NICHTS: es meldet
        -- nur "kein Lua-Fehler", nicht "equippt". Der Zustand war danach stabil, weil der Auto-Redraw nur
        -- bei LEEREN Haenden anspringt -- die gesetzte Waffen-ID tarnte den Schaden als heil.
        -- Jetzt: equippen, NACHMESSEN, und nur bei Erfolg aktivieren. Schlaegt es fehl, bleibt die Hand
        -- leer -> der Auto-Redraw sieht das im naechsten Tick und versucht es erneut (selbstheilend
        -- statt stabil kaputt). Beim Stagger raeumt die Engine das Inventar gerade um; ein Frame
        -- spaeter greift derselbe Weg normal.
        -- =====================================================================================
        -- [SETZEN, PUNKT 2026-08-01, "ICH WILL diese ziehen... wir muessen die Waffe setzen"]
        -- Kein Abbruch, keine leeren Haende: schlaegt der normale Weg fehl, wird HAERTER gesetzt.
        -- Drei Anlaeufe, nach jedem wird nachgemessen (`inv:getEquippedWeapon` -- der Wert, der im
        -- kaputten Zustand null war). Sobald einer sitzt, geht es sofort weiter zum Aktivieren.
        local function equipped_ok()
            if not et then return true end   -- ohne EquipType nicht pruefbar -> wie frueher weitermachen
            local ok_eq, eq = pcall(function() return inv:call("getEquippedWeapon", et) end)
            return (not ok_eq) or (eq ~= nil)
        end
        if not equipped_ok() then
            -- (2) Zeile FRISCH aus dem Inventar holen. Beim Stagger raeumt die Engine gerade um --
            -- die oben benutzte Zeile kann aus dem Moment davor stammen und ins Leere zeigen.
            local row2 = (last_pistol.wid ~= 0) and find_row_for_weapon(inv, last_pistol.wid, last_pistol.guid) or nil
            if not row2 then
                for _, r in ipairs(inventory_weapon_rows(inv)) do
                    local wid2 = enum_value(sc(r, "get_WeaponId"))
                    if wid2 and PISTOL_IDS[wid2] then row2 = r; last_pistol.wid = wid2; break end
                end
            end
            local gid2 = row2 and sc(row2, "get_ID")
            if gid2 then pcall(function() inv:call("equip", gid2) end); gid = gid2 end
        end
        -- [KEIN RATEN 2026-08-01, "hier wird nichts geraten. dann soll die Waffe lieber weg bleiben
        -- wenn wir zu bloed sind was zu redrawen"] Hier stand kurz ein dritter Weg ueber
        -- `pe:equipWeapon(EquipType, WeaponID, Boolean, Boolean)` -- die Signatur ist bekannt, die
        -- Bedeutung der beiden Booleans NICHT. Ersatzlos raus. Wenn wir es nicht sauber setzen koennen,
        -- wird auch nicht aktiviert: lieber sichtbar keine Waffe als eine, die es datenmaessig nicht gibt
        -- (genau daraus entstand "Pistole laedt nicht mehr nach").
        -- Wenn dieser Weg gebraucht wird, gehoeren die Parameter ABGESCHAUT statt geraten: Hook auf
        -- equipWeapon setzen und mitschneiden, was das Spiel bei einem normalen Waffenwechsel uebergibt.
        if not equipped_ok() then
            hol_warn(string.format("draw_last_pistol: equip wirkungslos (gid=%s row=%s wid=%s) -> NICHT aktiviert",
                tostring(gid), tostring(row ~= nil), tostring(last_pistol.wid)))
            return
        end
    end
    -- [PISTOL_DRAW] Wie bei der Granate: inv:equip waehlt die Pistole nur im Main-Slot; requestEquipGun +
    -- execChangeWeapon (in on_grab) ziehen aber die ZULETZT AKTIVE Main-Waffe (z.B. Chicago 4201, wenn die
    -- zuletzt in der Hand war) -> falsche/Zweihand-Waffe kommt aus dem Pistol-Holster. requestChangeActiveWeapon(Main)
    -- zwingt den Wechsel auf die frisch equippte Pistole. requestEquipGun bleibt Fallback (et nil / Call scheitert).
    local ok = false
    if et then ok = pcall(function() pe:call("requestChangeActiveWeapon(chainsaw.EquipType, System.Boolean, System.Boolean)", et, false, false) end) end
    if not ok then pcall(function() pe:call("requestEquipGun") end) end   -- Fallback: in die Hand ziehen
end

-- Zuletzt genutzte Granate merken (Default wp5400 Hand Grenade, falls noch keine).
local last_grenade = { wid = 5400, guid = "" }
local function track_last_grenade()
    local ew = get_equip_wid()
    if ew and GRENADE_IDS[ew] then
        last_grenade.wid = ew
        local pe = get_pe(); local inv = pe and sc(pe, "get_InventoryController")
        local g = inv and get_equipped_main_guid(inv); if type(g) == "string" then last_grenade.guid = g end
    end
end
local function draw_last_grenade(pe)
    local inv = pe and sc(pe, "get_InventoryController"); if not inv then return end
    local gwid = last_grenade.wid
    local row = find_row_for_weapon(inv, last_grenade.wid, last_grenade.guid)   -- Default 5400 (Hand Grenade)
    if not row then   -- 5400/gemerkte nicht im Inventar -> erste Granate im Inventar
        for _, r in ipairs(inventory_weapon_rows(inv)) do
            local wid = enum_value(sc(r, "get_WeaponId"))
            if wid and GRENADE_IDS[wid] then row = r; gwid = wid; break end
        end
    end
    local gid = row and sc(row, "get_ID")
    if gid then pcall(function() inv:call("equip", gid) end) end
    -- [GRENADE_DRAW] Granate ueber das REQUEST-Muster ziehen (wie Pistole: Request -> execChangeWeapon).
    -- requestEquipGun/equipWeapon funktionierten NICHT (live: Messer blieb in Hand). requestChangeWeaponAction
    -- ist das generische "wechsle zu Waffe X" das die Engine selbst nutzt; execChangeWeapon (in on_grab) fuehrt's aus.
    -- [GRENADE_DRAW] Der Schluessel: requestChangeWeaponAction setzt explizit "wechsle zu Granate" und
    -- ueberschreibt den vom Messer geerbten Hand-Typ. Overload von REFramework aufloesen lassen (die strenge
    -- Nullable-Signatur schlug fehl). Rueckgabewert (bool) = ob die Engine den Wechsel AKZEPTIERT hat.
    -- inv:equip hat die Granate in den Main-Slot gewaehlt; execChangeWeapon (in on_grab) zieht aber die
    -- ZULETZT equippte Waffe (nach Messer = Messer). requestChangeActiveWeapon(Main,...) zwingt den Wechsel
    -- auf die AKTIVE Main-Waffe (= jetzt die Granate) und ist sauber aufrufbar (keine Nullable-Args).
    local et = get_equip_type_main()
    local ok = false
    if et then ok = pcall(function() pe:call("requestChangeActiveWeapon(chainsaw.EquipType, System.Boolean, System.Boolean)", et, false, false) end) end
end

-- Zuletzt genutzte Langwaffe merken (fuer Klon-Anzeige + Ziehen). Analog last_pistol.
local last_rifle = { wid = 0, guid = "" }
local function track_last_rifle()
    local ew = get_equip_wid()
    if ew and SHOULDER_IDS[ew] then
        last_rifle.wid = ew
        local pe = get_pe(); local inv = pe and sc(pe, "get_InventoryController")
        local g = inv and get_equipped_main_guid(inv); if type(g) == "string" then last_rifle.guid = g end
    end
end
local function draw_last_rifle(pe)
    local inv = pe and sc(pe, "get_InventoryController")
    local row
    if inv then
        row = (last_rifle.wid ~= 0) and find_row_for_weapon(inv, last_rifle.wid, last_rifle.guid) or nil
        if not row then   -- keine gemerkte Langwaffe -> erste Schulter-Waffe aus dem Inventar (wird neuer Default)
            for _, r in ipairs(inventory_weapon_rows(inv)) do
                local wid = enum_value(sc(r, "get_WeaponId"))
                if wid and SHOULDER_IDS[wid] then row = r; last_rifle.wid = wid; break end
            end
        end
        -- [KEINE_LANGWAFFE 2026-08-05, re4_zzz_holster_probe] Gibt es GAR keine Langwaffe
        -- (Mercs-Wesker: nur zwei Pistolen, Probe: "Langwaffen=0 get_WeaponId_nil=0"), bleibt row nil.
        -- Frueher lief die Funktion trotzdem weiter und zwang unten requestChangeActiveWeapon(Main) --
        -- das zieht die ZULETZT AKTIVE Main-Waffe, also eine Pistole aus dem Ruecken-Holster.
        -- Kein Nachweis einer Langwaffe -> gar nichts tun. Nur wenn das Inventar wirklich lesbar war
        -- (inv vorhanden); bei nicht lesbarem Inventar bleibt der alte Weg samt Fallback bestehen.
        if not row then return end
        local gid = sc(row, "get_ID")
        if gid then pcall(function() inv:call("equip", gid) end) end
    end
    -- [SHOULDER_DRAW] Wie bei Pistole/Granate: inv:equip waehlt nur den Main-Slot; execChangeWeapon zieht
    -- sonst die ZULETZT AKTIVE Main-Waffe. requestChangeActiveWeapon(Main) zwingt den Wechsel auf die
    -- frisch equippte Langwaffe. requestEquipGun bleibt Fallback (et nil / Call scheitert).
    local et = get_equip_type_main()
    local ok = false
    if et then ok = pcall(function() pe:call("requestChangeActiveWeapon(chainsaw.EquipType, System.Boolean, System.Boolean)", et, false, false) end) end
    if not ok then pcall(function() pe:call("requestEquipGun") end) end
end

-- Deferred Aktion (im updateOnFrameHead-Hook; sonst greift der Waffenwechsel nicht).
local pending_action = nil
_G.__re4_knife_holster_exec = function()   -- Name historisch beibehalten (Hook ruft ihn ueber Reloads)
    local pa = pending_action; if not pa then return end
    pending_action = nil
    -- [EIGENER WECHSEL 2026-07-17] Freifahrt fuer den Engine-Block in weapons.lua (KNIFE_KEEP_OUT-Hook auf
    -- requestChangeWeaponAction). WARUM: unser draw_last_pistol/rifle/grenade ruft requestChangeActiveWeapon,
    -- und die Engine ruft daraufhin INTERN requestChangeWeaponAction (im equip_trace 10:49:16 stehen beide
    -- direkt untereinander). Ohne dieses Fenster blockt der Hook also den EIGENEN Holster-Zug, solange noch
    -- ein Messer in der Hand ist -> "keine Waffe mehr aus dem Holster ziehbar". Zeitfenster statt Flag, weil
    -- der Engine-Call erst ein paar Frames nach unserem Request kommt.
    _G.__re4_our_equip_until = os.clock() + 0.5
    pcall(pa)
end
-- [KNIFE_HAND 2026-07-07] Export: re4_vr_knife_lefthand.lua stellt seinen Links-Ziehen/Stauen-Call
-- hier ein -> laeuft im SELBEN updateOnFrameHead-Hook (kein zweiter sdk.hook, kein Game-Neustart noetig).
-- Ein Slot: rechts und links greifen nie im selben Frame (nur eine Hand am Holster).
_G.__re4_knife_defer = function(fn) if type(fn) == "function" then pending_action = fn end end

-- [KNIFE_HAND 2026-07-07] Links-Stow muss den Auto-Redraw GENAUSO unterdruecken wie der rechte Grab
-- (sonst holt die Engine bei "Waffe weg" sofort die letzte Waffe zurueck -> Messer klebt). true = bewusst
-- bare (kein Auto-Draw), false = Ziehen erlaubt. re4_vr_knife_lefthand.lua ruft das beim Links-Grab.
_G.__re4_knife_set_suppress = function(b)
    auto_redraw.suppress = (b == true)
    if b == true then auto_redraw.stow_until = os.clock() + 0.5 end
end
-- [CLONE-FINISHER RESTORE 2026-07-17] weapons2 ruft das, wenn der native Links-Klon-Finisher das Messer RECHTS
-- equippt hat: bewusst holstern -- ueber DENSELBEN deferred Weg wie der Links-Stow (bare-hand im Holster-Hook,
-- KEIN Force jeden Frame -> nicht die teuer bezahlte Falle). suppress legt den Auto-Redraw still, damit er das
-- Messer nicht rechts nachzieht. Danach ist die Engine bare -> weapons2/clone_manage baut den Links-Klon neu.
_G.__re4_knife_holster_bare = function()
    auto_redraw.suppress = true
    auto_redraw.stow_until = os.clock() + 0.5
    _G.__re4_our_equip_until = os.clock() + 0.5   -- Freifahrt fuer den KNIFE_KEEP_OUT-Hook (eigener Wechsel)
    pending_action = function()
        local pe = get_pe(); if not pe then return end
        pcall(function() pe:call("clearRequest") end)
        pcall(function() pe:call("requestEquipBareHand", false, false) end)
        pcall(function() pe:call("execChangeWeapon") end)
    end
end
if not _G.__re4_knife_holster_hook then
    _G.__re4_knife_holster_hook = true
    pcall(function()
        local td = sdk.find_type_definition("share.Startup")
        local m = td and td:get_method("updateOnFrameHead")
        if m then sdk.hook(m, function() end, function(r)
            if _G.__re4_knife_holster_exec then pcall(_G.__re4_knife_holster_exec) end
            return r
        end) end
    end)
end

-- ---- gemeinsame VR-/Math-Helfer ----
local function right_joystick() return safe(function() return vrmod:get_right_joystick() end) end
local function right_grip_pressed()
    local act = safe(function() return vrmod:get_action_grip() end)
    local rj  = safe(function() return vrmod:get_right_joystick() end)
    if not act or not rj then return false end
    local ok, v = pcall(function() return vrmod:is_action_active(act, rj) end)
    return ok and v == true
end
local function rh_world()
    local p = rawget(_G, "__vr_rh_world"); if p then return p end
    local tf = body_tf(); if not tf then return nil end
    local j = sc(tf, "getJointByName", "R_Hand") or sc(tf, "getJointByName", "R_Arm_Hand")
    return j and safe(function() return j:call("get_Position") end)
end
-- ---- LINKE Hand (fuer das Mag-Holster) ----
local function left_joystick() return safe(function() return vrmod:get_left_joystick() end) end
local function left_grip_pressed()
    local act = safe(function() return vrmod:get_action_grip() end)
    local lj  = safe(function() return vrmod:get_left_joystick() end)
    if not act or not lj then return false end
    local ok, v = pcall(function() return vrmod:is_action_active(act, lj) end)
    return ok and v == true
end
local function lh_world()
    local p = rawget(_G, "__vr_lh_joint_pos") or rawget(_G, "__vr_lh_world"); if p then return p end
    local tf = body_tf(); if not tf then return nil end
    local j = sc(tf, "getJointByName", "L_Hand") or sc(tf, "getJointByName", "L_Arm_Hand")
    return j and safe(function() return j:call("get_Position") end)
end
-- [GLEICHER PUNKT FUER BEIDE HAENDE 2026-07-19] Messer-Holster: Kalibrierung UND Messung
-- benutzen ab hier fuer BEIDE Haende denselben Bezug -- den Hand-JOINT am Body (R_Hand / L_Hand).
-- Vorher kalibrierte P ueber rh_world (Controller-basiert, geglaettet/geclamped), waehrend links
-- ueber lh_world den Body-Joint nahm -> systematischer Versatz von einigen Zentimetern, der links
-- ein frueheres Loslassen erzwang. Body-Joints sind symmetrisch und IMMER vorhanden (die
-- Controller-Globals sind es nicht -- __vr_lh_world ist nil, solange motion die linke Hand nicht pinnt).
local _knife_lh_in_zone = false   -- [EINE ZONE] Hysterese-Zustand der LINKEN Messer-Zone
local function hand_joint_pos(side)
    local tf = body_tf(); if not tf then return nil end
    local j = sc(tf, "getJointByName", side .. "_Hand") or sc(tf, "getJointByName", side .. "_Arm_Hand")
    return j and safe(function() return j:call("get_Position") end)
end

local function quat_from_euler(rx, ry, rz)
    local cx, sx = math.cos(rx * 0.5), math.sin(rx * 0.5)
    local cy, sy = math.cos(ry * 0.5), math.sin(ry * 0.5)
    local cz, sz = math.cos(rz * 0.5), math.sin(rz * 0.5)
    return Quaternion.new(cx*cy*cz + sx*sy*sz, sx*cy*cz - cx*sy*sz, cx*sy*cz + sx*cy*sz, cx*cy*sz - sx*sy*cz)
end

-- [HMD_YAW] Legacy-Anker-Basis (aus others/re4_vr_holster.lua.bak get_hmd_pose_yaw): HMD-Weltposition +
-- koerper-yaw-orientierte Basis (right/up/fwd, y=0). Dient dem SCHULTER-Holster: die Greifzone haengt am
-- ECHTEN Kopf (nicht am Leon-Modell-Skelett) -> "hinter die Schulter greifen" trifft dort, wo die Hand real hinkommt.
local function hmd_pose_yaw()
    local cam = sdk.get_primary_camera(); if not cam then return nil end
    local wm = safe(function() return cam:call("get_WorldMatrix") end); if not wm then return nil end
    local pos = Vector3f.new(wm[3].x, wm[3].y, wm[3].z)
    local fx, fz
    local tf = body_tf()
    if tf then local rot = safe(function() return tf:call("get_Rotation") end)
        if rot then local fv = safe(function() return rot * Vector3f.new(0, 0, 1) end)
            if fv then fx, fz = fv.x, fv.z end end end
    if not fx then fx, fz = wm[2].x, wm[2].z end
    local len = math.sqrt(fx*fx + fz*fz)
    if len < 1e-6 then fx, fz = 0.0, 1.0 else fx, fz = fx/len, fz/len end
    return pos, { x = fz, y = 0, z = -fx }, { x = 0, y = 1, z = 0 }, { x = fx, y = 0, z = fz }
end

-- =====================================================================
-- [PERF 2026-08-17] Arbeitsersparnis in den Holster-Slots.
--
-- Warum hier: gemessen (Spielstart ohne diese Datei) kostet re4_vr_holster.lua rund 10 fps.
-- Der Grund ist die Menge, nicht die Logik -- `apply_all` haengt an SECHS Engine-Phasen
-- (LockScene, UpdateMotion, UpdateJointExpression, LateUpdateBehavior, BeginRendering pre/post)
-- und laeuft dort ueber ALLE VIER Slots. Das sind 24 Slot-Durchlaeufe pro Frame, jeder mit
-- ~6 Engine-Calls -> ~150 Calls pro Frame, dazu pro Call eine Closure aus dem safe()-Wrapper.
--
-- Die sechs Paesse selbst bleiben unangetastet -- sie sind der Grund, warum die Holster beim
-- Gehen/Drehen nicht nachlaufen ([NO_LAG]). Eingespart wird nur, was in jedem Pass DASSELBE
-- ERGEBNIS liefert:
--   1. Die Transform des Klon-GOs: ein GameObject behaelt seine Transform, das Objekt wechselt
--      nie. Wurde bisher in jedem Pass neu erfragt (24 Calls/Frame). Wird beim Klon-Neubau und
--      beim destroy() verworfen -- ein neuer Klon holt sie also frisch.
--   2. set_LocalScale: die Klon-Skalierung ist eine Config-Zahl, wurde aber in jedem Pass
--      geschrieben (24 Calls/Frame). Jetzt nur, wenn sich der Wert aendert. EIGENER Schalter,
--      weil hier als einziges ein Schreibvorgang entfaellt.
--   3. Die Joint-Gueltigkeitspruefung in joint_get(): kostet einen echten Engine-Call und lief
--      bei jedem Zugriff. Innerhalb eines Frames kann ein Joint nicht ungueltig werden.
--
-- NOT-AUS:  `_G.__re4_hol_perf_off = true`        -> alle drei aus (Datei wie das Backup)
--           `_G.__re4_hol_scale_perf_off = true`  -> nur Nr. 2 aus
-- Backup:   others/re4_vr_holster.bak_2026-08-17_pre_perf2.lua
-- =====================================================================
local function hol_perf_on()
    return rawget(_G, "__re4_hol_perf_off") ~= true
end
local _hol_frame = 0   -- Frame-Zaehler (wird im on_frame weiter unten erhoeht)

-- =====================================================================
-- Slot-Factory: eigenstaendiger Holster-Slot (Klon + Grab + Dim + eigener Offset/Config).
-- =====================================================================
local function default_cfg()
    return {
        enabled = true, off_x = 0.10, off_y = 0.10, off_z = 0.12,
        rx = 0.0, ry = 0.0, rz = 0.0, scale = 1.0, smooth = 0.8,
        grab_trigger = 0.16, grab_release = 0.24, grab_haptic = true, grab_haptic_delay = 0.0,
        pl_x = 0.0, pl_y = 0.0, pl_z = 0.0,   -- gelernter Greifpunkt-Pivot (modell-relativ, im sm-Rot-Frame)
        md_x = 0.0, md_y = 0.0, md_z = 0.0,   -- [MESH-DISKREPANZ] persistente Korrektur Modell-Pivot vs
                                              -- Kalibrierpunkt; ueberlebt Kalibrierung (die setzt nur off)
        -- [PER-WAFFE X 2026-07-22] Langwaffen sind unterschiedlich lang (LE5 vs Raketenwerfer) --
        -- das Anzeige-Mesh vorne soll aber bei JEDER mittig stehen. Deshalb ZUSAETZLICH zu md_x ein
        -- eigener X-Wert pro Waffen-ID, additiv. Basis fuer alle ist 0.00 (bewusst kein automatischer
        -- AABB-Mittelpunkt -- Entscheidung: "ist mir sicherer").
        -- KEYS SIND STRINGS: json.dump_file/load_file macht aus [4202] den Key "4202" -- beim Lesen und
        -- Schreiben immer tostring(wid) verwenden, sonst findet nach dem Neuladen nichts mehr zusammen.
        md_x_wid = {},
        -- [ENTKOPPELT 2026-07-15] addon_x/y/z (Versatz zum gekoppelten Slot) entfernt -- Slot-Kopplung gibt's
        -- nicht mehr, jeder Slot rechnet aus eigenem off+md. Alte addon_*-Reste in den JSONs werden von
        -- load_slot_cfg ignoriert (uebernimmt nur Keys, die hier existieren) und beim naechsten Save entfernt.
        dim_in_use = true, dim_factor = 0.12, joint = "",
        -- [DETACHED_ZONE] Nur fuer Slots mit entkoppelter Zone (Schulter): Greif-Anker = Joint + dieser
        -- Offset (joint-relativ), UNABHAENGIG vom sichtbaren Mesh (off_x/y/z). Per Kalibrierung gesetzt.
        zx = 0.18, zy = 0.20, zz = -0.20,
    }
end
-- Config laden (mit Migration alter Messer-Keys chest_* -> generisch, damit Tuning bleibt).
local function load_slot_cfg(cfg, path)
    local d = safe(function() return json.load_file(path) end)
    if type(d) ~= "table" then return end
    local map = { chest_enabled="enabled", chest_off_x="off_x", chest_off_y="off_y", chest_off_z="off_z",
        chest_rx="rx", chest_ry="ry", chest_rz="rz", chest_scale="scale", chest_smooth="smooth", chest_joint="joint" }
    for oldk, newk in pairs(map) do if d[oldk] ~= nil and type(d[oldk]) == type(cfg[newk]) then cfg[newk] = d[oldk] end end
    for k, v in pairs(d) do if cfg[k] ~= nil and type(v) == type(cfg[k]) then cfg[k] = v end end
end
-- [KNIFE_ADA HARD-GUARD 2026-07-19, "KEIN MAINGAME wird angefasst"]
-- Zweite, UNABHAENGIGE Sicherung gegen meine eigene Pfad-Buchfuehrung: waehrend Ada gesteuert
-- wird, kann Leons Messer-Datei physisch nicht geschrieben werden -- egal ob irgendwo ein
-- veralteter Pfad durchrutscht (S.path nicht aktualisiert, UI mit altem Wert, neuer Aufrufer).
-- Und umgekehrt. Pfade bewusst als LITERALE verglichen: save_slot_cfg steht vor den
-- Pfad-Konstanten, eine Referenz waere hier ein nil-Global und die Sperre still wirkungslos.
-- Charakter kommt als Global (__re4_knife_char), aus demselben Grund.
local function save_slot_cfg(cfg, path)
    local ch = rawget(_G, "__re4_knife_char")
    if ch == "ada"  and path == "re4_vr/re4_vr_knife.json"     then return end
    if ch == "leon" and path == "re4_vr/re4_vr_knife_ada.json" then return end
    pcall(function() json.dump_file(path, cfg) end)
end

-- o = { name, ids, cfg, path, anchor_g, zone_g, get_source->(mesh,wid,go), on_grab(in_hand) }
local function make_slot(o)
    local S = { name = o.name, ids = o.ids, cfg = o.cfg, path = o.path, anchor_g = o.anchor_g, zone_g = o.zone_g,
        get_source = o.get_source, on_grab = o.on_grab, detached_zone = o.detached_zone == true,
        all_parts = o.all_parts == true,
        clone = {}, sm = { has = false, px=0,py=0,pz=0,rx=0,ry=0,rz=0,rw=1 },
        grab = { in_zone = false, last_dist = 99, was_grip = false }, last_check = 0, joint = nil }

    local function joint_get()
        local tf = body_tf(); if not tf then return nil end
        -- [PERF 3] Die Gueltigkeitspruefung ist ein echter Engine-Call und lief bei JEDEM Zugriff
        -- (in sechs Paessen pro Slot). Ein Joint kann innerhalb eines Frames nicht ungueltig werden:
        -- war er in diesem Frame schon gut, gilt das fuer den ganzen Frame.
        if hol_perf_on() and S.joint and S._joint_ok_frame == _hol_frame then
            return S.joint
        end
        local valid = S.joint and safe(function() return S.joint:get_Valid() end)
        if valid then S._joint_ok_frame = _hol_frame end
        if not valid then
            S.joint = nil
            for _, nm in ipairs(CHEST_JOINT_CANDIDATES) do
                local j = sc(tf, "getJointByName", nm); if j then S.joint = j; S.cfg.joint = nm; break end
            end
        end
        return S.joint
    end
    local function destroy()
        if S.clone.obj then pcall(function()
            local td = sdk.find_type_definition("via.GameObject"); local d = td and td:get_method("destroy(via.GameObject)")
            if d then d:call(nil, S.clone.obj) end
        end) end
        S.clone.obj, S.clone.mesh, S.clone.wid = nil, nil, nil
        S.clone.tf = nil   -- [PERF 1] gemerkte Transform gehoert zum zerstoerten GO
        S.clone.scale_written = nil   -- [PERF 2] neuer Klon -> Skalierung neu schreiben
        S.clone.mat_dim, S.clone.mat_zero, S.clone.dim_applied, S.clone.src_addr = nil, nil, nil, nil
        S.clone.part0_done = nil
        S.sm.has = false
    end
    local function spawn(gmesh)
        local holder = safe(function() return gmesh:call("getMesh") end); if not holder then return false end
        local gmat = safe(function() return gmesh:call("get_Material") end)
        local go_td = sdk.find_type_definition("via.GameObject"); local create = go_td and go_td:get_method("create(System.String)")
        local go = create and safe(function() return create:call(nil, "vr_holster_" .. S.name) end); if not go then return false end
        pcall(function() go:add_ref() end)
        pcall(function() go:call("createComponent(System.Type)", sdk.typeof("via.motion.Motion")) end)  -- KERN: Skelett
        local mesh = safe(function() return go:call("createComponent(System.Type)", sdk.typeof("via.render.Mesh")) end)
        if not mesh then return false end
        pcall(function() mesh:call("setMesh", holder) end)
        if gmat then pcall(function() mesh:call("set_Material", gmat) end) end
        pcall(function() mesh:call("set_DrawDefault", true) end)
        pcall(function() mesh:call("set_Enabled", true) end)
        pcall(function() mesh:call("set_FrustumCulling", false) end)
        pcall(function() mesh:call("set_DrawShadowCast", false) end)   -- [KEIN_SCHATTEN 2026-07-06] Holster-Clone wirft keinen Schatten (sah per Flashlight doof aus)
        -- [NO_LAG] Klon NATIV an den Body-Joint parenten (wie die echte Waffe an der Hand). Dann propagiert
        -- die Engine die Transform VOR dem Skinning -> kein 3-4-Frame-Render-Versatz beim Laufen. Danach
        -- setzen wir nur noch die LOKALE Pose (Offset), die Welt-Position macht die Engine.
        joint_get()   -- S.cfg.joint aufloesen
        local ctf = safe(function() return go:call("get_Transform") end)
        -- [CRASH-FIX] set_Parent auf einen STALE Body-Transform (nach Szenenwechsel/Save-Load) loest eine
        -- native Access Violation aus, die pcall NICHT faengt -> Crash beim Messer-Greifen. Darum Body-GO
        -- frisch holen + get_Valid pruefen, Klon-GO ebenso. Ungueltig -> NICHT parenten (Klon bleibt kurz
        -- frei, wird naechsten Frame gueltig geparentet) statt zu crashen.
        local go_valid  = safe(function() return go:call("get_Valid") end) ~= false
        local bctx = get_ctx()
        local bgo  = bctx and sc(bctx, "get_BodyGameObject")
        local bgo_valid = bgo and safe(function() return bgo:call("get_Valid") end) ~= false
        local btf  = (bgo and bgo_valid) and safe(function() return bgo:call("get_Transform") end) or nil
        S.clone.parented = false
        if ctf and btf and go_valid and bgo_valid then
            local jn = (S.cfg.joint ~= "" and S.cfg.joint) or "Spine_1"
            pcall(function() ctf:call("set_Parent", btf) end)
            if pcall(function() ctf:call("set_ParentJoint", jn) end) then S.clone.parented = true end
        end
        S.clone.obj, S.clone.mesh = go, mesh
        S.clone.tf = ctf   -- [PERF 1] Transform des neuen Klons ist hier schon aufgeloest
        S.clone.mat_dim, S.clone.dim_applied = nil, nil
        return true
    end
    local function build_mat_dim()
        if not S.clone.mesh then return end
        local mnum = safe(function() return S.clone.mesh:call("get_MaterialNum") end) or 0
        if mnum == 0 then return end
        S.clone.mat_dim = {}; S.clone.mat_zero = {}
        for mi = 0, mnum - 1 do
            local vnum = safe(function() return S.clone.mesh:call("getMaterialVariableNum", mi) end) or 0
            for vi = 0, vnum - 1 do
                local vn = safe(function() return S.clone.mesh:call("getMaterialVariableName", mi, vi) end)
                if type(vn) == "string" then
                    local low = vn:lower()
                    if low:find("color") or low:find("albedo") or low:find("diffuse") or low:find("basecol") then
                        local f4 = safe(function() return S.clone.mesh:call("getMaterialFloat4", mi, vi) end)
                        if f4 then S.clone.mat_dim[#S.clone.mat_dim+1] = {mi=mi,vi=vi,x=f4.x,y=f4.y,z=f4.z,w=f4.w} end
                    elseif low == "metallic" or low == "cavity" then
                        local v = safe(function() return S.clone.mesh:call("getMaterialFloat", mi, vi) end)
                        if type(v) == "number" then S.clone.mat_zero[#S.clone.mat_zero+1] = {mi=mi,vi=vi,orig=v} end
                    end
                end
            end
        end
    end
    local function apply_dim(dark)
        if not S.clone.mesh then return false end
        if S.clone.mat_dim == nil then build_mat_dim() end
        if not S.clone.mat_dim then return false end
        local d = dark and (S.cfg.dim_factor or 0.12) or 1.0
        for _, e in ipairs(S.clone.mat_dim) do
            pcall(function() S.clone.mesh:call("setMaterialFloat4", e.mi, e.vi, Vector4f.new(e.x*d, e.y*d, e.z*d, e.w)) end)
        end
        if S.clone.mat_zero then for _, e in ipairs(S.clone.mat_zero) do
            pcall(function() S.clone.mesh:call("setMaterialFloat", e.mi, e.vi, dark and 0.0 or e.orig) end) end end
        return true
    end
    -- [PART_0 2026-07-06] Holster-Klon zeigt NUR Mesh-Part 0 (die reine Waffe/GUN) statt der ganzen
    -- Waffe (sonst Gunstock/Anbauten mit dabei). Methode 1:1 aus re4_zz_hand_part_clone: alle Parts
    -- aus, nur Index 0 an (setPartsEnable). Retry bis Mesh ready (wie apply_dim). true = angewandt.
    -- NUR die Sichtbarkeit der Parts - Offset/Greifpunkt/Schatten/Material bleiben unberuehrt.
    local function isolate_part0()
        if not S.clone.mesh then return false end
        if safe(function() return S.clone.mesh:call("get_MeshReady") end) ~= true then return false end
        -- [ALLE_PARTS 2026-07-22] Slots mit all_parts=true (Langwaffe) zeigen das komplette Mesh
        -- (wie "Alle Parts zeigen" im #Partclone-Tool), sonst wie gehabt nur Part 0.
        -- [KILLER7_PARTS 2026-08-05] EINE Waffe schert aus: die Killer7 (4501) traegt ihren
        -- Laseraufsatz als eigenen Part -- mit Part-0-Isolierung fehlt er am Holster-Klon. Sie zeigt
        -- deshalb IMMER alle Parts, egal ob Kampagne, Separate Ways oder Mercenaries. Alle anderen
        -- Pistolen bleiben unveraendert bei Part 0 (sonst haengt z.B. der Gunstock mit dran).
        for i = 0, 63 do pcall(function()
            S.clone.mesh:call("setPartsEnable", i, S.all_parts or S.clone.wid == 4501 or i == 0)
        end) end
        return true
    end
    -- [CROUCH_OPTIK 2026-07-22] Lokaler Z-Zuschlag, der AUSSCHLIESSLICH das Mesh verschiebt.
    -- Quelle: movement veroeffentlicht als __re4_ub_z_delta, wie weit der Oberkoerper im Crouch
    -- anders steht als beim Gehen (Referenz = Gehen -> dort 0). Gain 0 = aus, negativ = Gegenrichtung.
    -- Wird an GENAU zwei Stellen benutzt: beim Setzen der Mesh-Pose (apply) und beim Kalibrieren
    -- (dort abgezogen, damit der Button weiter exakt auf das sichtbare Mesh setzt).
    local function crouch_opt_z()
        local d = tonumber(rawget(_G, "__re4_ub_z_delta")) or 0.0
        local g = tonumber(rawget(_G, "__re4_holster_crouch_gain")) or 0.0
        -- [ADA-MESH-Z 2026-07-23] Konstanter Z-Zuschlag NUR fuer Ada, auf ALLE Holster-Meshes
        -- gleichzeitig (nur Optik -- crouch_opt_z schiebt das Mesh, nicht den Greifpunkt). Leon
        -- unberuehrt (Wert greift nur bei __re4_knife_char == "ada"). Positiv = naeher zu mir.
        local az = (rawget(_G, "__re4_knife_char") == "ada") and (tonumber(rawget(_G, "__re4_holster_ada_mesh_z")) or 0.0) or 0.0
        return -d * g + az
    end
    local function compute_target()
        local j = joint_get(); if not j then return nil end
        local jp = safe(function() return j:call("get_Position") end); if not jp then return nil end
        local jr = safe(function() return j:call("get_Rotation") end)
        local wx, wy, wz = jp.x, jp.y, jp.z
        -- [ENTKOPPELT 2026-07-17, Entscheidung] md_x/y/z (Mesh-Korrektur) zaehlt hier NICHT: die
        -- Mesh-Position ist vom Holster-/Greifpunkt getrennt. Der md-Slider schiebt NUR das Mesh.
        -- Der Greifpunkt kommt aus der Kalibrierung. md-Kopplung wurde probiert und wieder verworfen --
        -- NICHT erneut einbauen.
        -- [SHIFT_X] shift_x dagegen gilt fuer BEIDE Schreiber (hier + apply/parented) -> schiebt Mesh und
        -- Greifpunkt gemeinsam, ohne ihr Verhaeltnis zu aendern. Joint-relativ wie off (gleicher jr-Frame).
        if jr then local off = safe(function() return jr * Vector3f.new(S.cfg.off_x + (S.cfg.shift_x or 0), S.cfg.off_y, S.cfg.off_z) end)
            if off then wx, wy, wz = jp.x + off.x, jp.y + off.y, jp.z + off.z end end
        local rot = jr and safe(function() return (jr * quat_from_euler(S.cfg.rx, S.cfg.ry, S.cfg.rz)):normalized() end)
        return { x = wx, y = wy, z = wz }, rot
    end
    -- [DETACHED_ZONE / HMD_YAW] Greif-Anker aus HMD-Position + koerper-yaw-Basis + Zonen-Offset (zx/zy/zz),
    -- UNABHAENGIG vom Mesh. Legacy-Prinzip: die Zone haengt am echten Kopf -> "hinter die Schulter greifen"
    -- trifft dort, wo die Hand real hinkommt (nicht am Leon-Modell-Skelett wie die anderen Slots).
    local function compute_zone_anchor()
        local hmd, right, up, fwd = hmd_pose_yaw(); if not hmd then return nil end
        local ox, oy, oz = S.cfg.zx or 0, S.cfg.zy or 0, S.cfg.zz or 0
        return Vector3f.new(
            hmd.x + ox*right.x + oy*up.x + oz*fwd.x,
            hmd.y + ox*right.y + oy*up.y + oz*fwd.y,
            hmd.z + ox*right.z + oy*up.z + oz*fwd.z)
    end
    -- [MESH_ANCHOR] Echte gerenderte Mesh-Mitte (WorldAABB-Center) als Greif-Anker -> der Anker sitzt GENAU
    -- am sichtbaren Mesh, egal wo der GO-Pivot liegt (das war die Wurzel: GO-Origin != sichtbares Messer).
    -- Sanity: muss nah am erwarteten GO liegen; manche Grosswelt-Maps liefern Muell (~944000) -> dann nil,
    -- und der Aufrufer faellt sicher auf GO(+pl) zurueck (kein Regress).
    local function mesh_anchor(fx, fy, fz)
        -- Manuell kalibrierter Greifpunkt (pl != 0) hat VORRANG -> dann NICHT den Auto-AABB nehmen (GO+pl gilt).
        if (S.cfg.pl_x or 0) ~= 0 or (S.cfg.pl_y or 0) ~= 0 or (S.cfg.pl_z or 0) ~= 0 then return nil end
        if not S.clone.mesh then return nil end
        local aabb = safe(function() return S.clone.mesh:call("get_WorldAABB") end); if not aabb then return nil end
        local c = safe(function() return aabb:call("getCenter") end)
        if not (c and type(c.x) == "number") then return nil end
        local dx, dy, dz = c.x - fx, c.y - fy, c.z - fz
        if (dx*dx + dy*dy + dz*dz) > 4.0 then return nil end   -- >2m vom GO entfernt = kaputter AABB -> verwerfen
        return c
    end
    local function update_smooth()
        -- [DETACHED_ZONE] Anker separat aus dem Zonen-Offset; das Mesh-Smoothing laeuft trotzdem (Optik).
        if S.detached_zone then local za = compute_zone_anchor(); if za then _G[S.anchor_g] = za end end
        local tp, tr = compute_target(); if not tp then return end
        local a = 1.0 - math.max(0.0, math.min(0.98, S.cfg.smooth or 0.0))
        local sm = S.sm
        if not sm.has then
            sm.px, sm.py, sm.pz = tp.x, tp.y, tp.z
            if tr then sm.rx, sm.ry, sm.rz, sm.rw = tr.x, tr.y, tr.z, tr.w end
            sm.has = true
        else
            sm.px = sm.px + (tp.x - sm.px) * a; sm.py = sm.py + (tp.y - sm.py) * a; sm.pz = sm.pz + (tp.z - sm.pz) * a
            if tr then
                local dot = sm.rx*tr.x + sm.ry*tr.y + sm.rz*tr.z + sm.rw*tr.w; local s = dot < 0 and -1.0 or 1.0
                sm.rx = sm.rx + (tr.x*s - sm.rx)*a; sm.ry = sm.ry + (tr.y*s - sm.ry)*a
                sm.rz = sm.rz + (tr.z*s - sm.rz)*a; sm.rw = sm.rw + (tr.w*s - sm.rw)*a
                local n = math.sqrt(sm.rx*sm.rx + sm.ry*sm.ry + sm.rz*sm.rz + sm.rw*sm.rw)
                if n > 1e-6 then sm.rx, sm.ry, sm.rz, sm.rw = sm.rx/n, sm.ry/n, sm.rz/n, sm.rw/n end
            end
        end
        -- Anker = sm + gelernter Pivot (modell-relativ, im smoothed-rot-Frame gespeichert). pl wird per
        -- Lang-Griff gelernt (grab_dispatch). Da pl RELATIV zu sm liegt, wandert der Greifpunkt beim
        -- Slider-Verschieben automatisch mit dem Dummy. Default (0,0,0) = Anker am Modell-Ursprung.
        local ax, ay, az = sm.px, sm.py, sm.pz
        local plx, ply, plz = S.cfg.pl_x or 0, S.cfg.pl_y or 0, S.cfg.pl_z or 0
        if plx ~= 0 or ply ~= 0 or plz ~= 0 then
            local q = Quaternion.new(sm.rw, sm.rx, sm.ry, sm.rz)
            local off = safe(function() return q * Vector3f.new(plx, ply, plz) end)
            if off and type(off.x) == "number" then ax, ay, az = sm.px + off.x, sm.py + off.y, sm.pz + off.z end
        end
        -- Anker = GO + gelernter Greifpunkt (pl, per Kalibrierung). get_WorldAABB-Auto-Anker ENTFERNT:
        -- die via.render/physics-AABB-API crasht/spinnt in dieser Grosswelt-Map (siehe castRayAsync-Crash).
        if not S.detached_zone then _G[S.anchor_g] = Vector3f.new(ax, ay, az) end
    end
    -- [PERF 2] Skalierung nur schreiben, wenn sie sich geaendert hat. Die Klon-Skalierung ist eine
    -- Config-Zahl (S.cfg.scale) und aendert sich nur, wenn im Menue geschoben wird -- geschrieben
    -- wurde sie aber in jedem der sechs Paesse, also 24x pro Frame fuer vier Slots. Der gemerkte
    -- Wert haengt am Klon (S.clone.scale_written) und wird mit ihm verworfen; ein neuer Klon
    -- bekommt seine Skalierung also in jedem Fall einmal geschrieben.
    -- Eigener Schalter, weil hier als einziger Punkt ein Schreibvorgang wegfaellt:
    --   `_G.__re4_hol_scale_perf_off = true` -> wieder in jedem Pass schreiben.
    local function write_scale(tf, sc_val)
        if not hol_perf_on() or rawget(_G, "__re4_hol_scale_perf_off") == true then
            pcall(function() tf:call("set_LocalScale", Vector3f.new(sc_val, sc_val, sc_val)) end)
            return
        end
        if S.clone.scale_written ~= sc_val then
            pcall(function() tf:call("set_LocalScale", Vector3f.new(sc_val, sc_val, sc_val)) end)
            S.clone.scale_written = sc_val
        end
    end

    -- [NO_LAG] Position/Rotation FRISCH aus dem Joint in JEDEM Render-Pass berechnen (nicht den in
    -- on_frame gecachten, 1 Frame alten Wert anwenden -> der laggte beim Gehen/Rennen hinterher).
    -- Anker wird gleich rigide mitgezogen, damit auch die Greifzone nicht nachlaeuft.
    local function apply()
        -- [DETACHED_ZONE] Greifzone auch in den Render-Paessen frisch aus dem Joint (No-Lag), unabhaengig
        -- vom Mesh (das evtl. ganz woanders/vorne schwebt oder gar nicht existiert).
        if S.detached_zone then local za = compute_zone_anchor(); if za then _G[S.anchor_g] = za end end
        if not S.clone.obj then return end
        -- [PERF 1] Transform des Klon-GOs gemerkt: dasselbe GameObject liefert immer dieselbe
        -- Transform. Verworfen wird sie in spawn() und destroy(), also bei jedem neuen Klon.
        local tf = nil
        if hol_perf_on() then
            tf = S.clone.tf
            if tf == nil then
                tf = safe(function() return S.clone.obj:call("get_Transform") end)
                S.clone.tf = tf
            end
        else
            tf = safe(function() return S.clone.obj:call("get_Transform") end)
        end
        if not tf then return end
        local s = S.cfg.scale or 1.0
        if S.clone.parented then
            -- [NO_LAG] geparentet: nur LOKALE Pose setzen (Offset relativ zum Joint); die Welt-Position
            -- macht die Engine nativ VOR dem Skinning -> kein Render-Versatz. Anker aus der Welt-Pose lesen.
            -- [MESH-DISKREPANZ] off = Kalibrier-Basis; md = persistente Feinkorrektur (Modell-Pivot).
            -- [ENTKOPPELT 2026-07-15] Die Slot-Kopplung (link_cfg/addon, Langwaffe folgte der Pistole) ist
            -- raus: jeder Slot rechnet wieder aus seinem EIGENEN off+md -> Slots sind unabhaengig bewegbar.
            -- [SHIFT_X] shift_x auf off_x drauf: das Mesh wandert -> der Anker unten (aus wp = echte
            -- Mesh-Weltpose) wandert automatisch identisch mit. compute_target rechnet dasselbe shift_x
            -- -> beide Anker-Schreiber bleiben deckungsgleich, egal welcher pro Frame zuletzt schreibt.
            -- [PER-WAFFE X] Zusatz-Offset der AKTUELL im Slot liegenden Waffe (Tabelle md_x_wid,
            -- String-Keys). Fehlt der Eintrag, ist er 0 -> Verhalten exakt wie vorher.
            local wx = 0.0
            do
                local t = S.cfg.md_x_wid
                local w = S.clone.wid
                if type(t) == "table" and w then wx = tonumber(t[tostring(w)]) or 0.0 end
            end
            local lx = S.cfg.off_x + (S.cfg.md_x or 0) + (S.cfg.shift_x or 0) + wx
            local ly = S.cfg.off_y + (S.cfg.md_y or 0)
            local lz = S.cfg.off_z + (S.cfg.md_z or 0)
            -- [CROUCH_OPTIK 2026-07-22] Im Crouch steht der Oberkoerper anders als beim Gehen
            -- (movement: pin_ub_z_crouch gegen pin_ub_z). Die Klone haengen am Spine -> sie wandern
            -- mit und sitzen relativ zum HMD verschoben. movement veroeffentlicht die Differenz als
            -- __re4_ub_z_delta (Referenz = normales Gehen -> dort 0).
            -- NUR OPTIK: das Delta geht ausschliesslich in die Mesh-Pose. Der Greif-Anker unten wird
            -- bewusst aus der Pose OHNE Delta gebildet, damit die kalibrierten Greifpunkte exakt
            -- dort bleiben, wo sie im Stehen sind (die Zonen selbst arbeiten ohnehin mit den rohen
            -- Controller-Punkten). Gain 0 = aus, negativ = Gegenrichtung; nichts wird persistiert.
            local cz = crouch_opt_z()
            pcall(function() tf:call("set_LocalPosition", Vector3f.new(lx, ly, lz + cz)) end)
            pcall(function() tf:call("set_LocalRotation", quat_from_euler(S.cfg.rx, S.cfg.ry, S.cfg.rz)) end)
            write_scale(tf, s)
            local wp = safe(function() return tf:call("get_Position") end)
            local wr = safe(function() return tf:call("get_Rotation") end)
            if wp then
                local ax, ay, az = wp.x, wp.y, wp.z
                -- [CROUCH_OPTIK] die Optik-Verschiebung wieder herausrechnen: der Anker soll da bleiben,
                -- wo er ohne sie laege. cz ist ein LOKALER Z-Offset am Joint -> in Weltraum ueber die
                -- Joint-Rotation zuruecknehmen (eine Multiplikation, kein zweiter Transform-Write).
                if cz ~= 0.0 then
                    local jr = S.joint and safe(function() return S.joint:call("get_Rotation") end)
                    local d = jr and safe(function() return jr * Vector3f.new(0, 0, cz) end)
                    if d and type(d.x) == "number" then ax, ay, az = ax - d.x, ay - d.y, az - d.z end
                end
                local plx, ply, plz = S.cfg.pl_x or 0, S.cfg.pl_y or 0, S.cfg.pl_z or 0
                if wr and (plx ~= 0 or ply ~= 0 or plz ~= 0) then
                    local off = safe(function() return wr * Vector3f.new(plx, ply, plz) end)
                    if off and type(off.x) == "number" then ax, ay, az = ax+off.x, ay+off.y, az+off.z end
                end
                -- Anker = GO + Greifpunkt-Pivot (pl). AABB-Auto-Anker entfernt (instabile Engine-API).
                if not S.detached_zone then _G[S.anchor_g] = Vector3f.new(ax, ay, az) end
            end
            return
        end
        -- Fallback (nicht geparentet): Welt-Transform frisch aus dem Joint setzen.
        local tp, tr = compute_target(); if not tp then return end
        pcall(function() tf:call("set_Position", Vector3f.new(tp.x, tp.y, tp.z)) end)
        if tr then pcall(function() tf:call("set_Rotation", tr) end) end
        write_scale(tf, s)
        local ax, ay, az = tp.x, tp.y, tp.z
        local plx, ply, plz = S.cfg.pl_x or 0, S.cfg.pl_y or 0, S.cfg.pl_z or 0
        if tr and (plx ~= 0 or ply ~= 0 or plz ~= 0) then
            local off = safe(function() return tr * Vector3f.new(plx, ply, plz) end)
            if off and type(off.x) == "number" then ax, ay, az = tp.x + off.x, tp.y + off.y, tp.z + off.z end
        end
        if not S.detached_zone then _G[S.anchor_g] = Vector3f.new(ax, ay, az) end
    end
    local function manage()
        -- [KILLSWITCH] KS1/2/3 (Cutscenes/Zwischensequenzen): Mesh-Clone weg (baut sich danach neu auf).
        -- [KNIFE_ONLY_STAGES] Messer-Stage: dito fuer alles ausser dem Messer.
        if slot_dormant(S) then if S.clone.obj then destroy() end; return end
        if not S.cfg.enabled then if S.clone.obj then destroy() end; return end
        -- [INV_CHECK] Klon NUR wenn eine Waffe dieses Slots im Inventar liegt (throttled 0.5s). Kein Item
        -- (keine Granate / kein Messer / erstes Level ohne Waffen) -> kein Phantom-Klon. Weg -> Klon zerstoeren.
        local nowi = os.clock()
        if nowi - (S.inv_check_t or 0) > 0.5 then
            S.inv_check_t = nowi
            S.has_inv = has_weapon_in_inventory(S.ids)
        end
        if not S.has_inv then if S.clone.obj then destroy() end; return end
        local ew = get_equip_wid()
        S.clone.in_use = (ew ~= nil and S.ids[ew] == true)
        if S.clone.obj and not safe(function() return S.clone.obj:get_Valid() end) then destroy() end
        if S.clone.obj then
            local now = os.clock()
            if now - S.last_check > 0.5 then
                S.last_check = now
                local _, _, go = S.get_source()
                local addr = go and safe(function() return go:get_address() end)
                if addr and addr ~= S.clone.src_addr then destroy() end
            end
        end
        if not S.clone.obj then
            local mesh, kwid, go = S.get_source()
            if mesh and spawn(mesh) then
                S.clone.wid = kwid
                S.clone.src_addr = go and safe(function() return go:get_address() end)
            end
        end
        if S.clone.obj then
            if not S.clone.part0_done then if isolate_part0() then S.clone.part0_done = true end end
            -- [LH_CLONE 2026-07-08] Messer als Klon in der LINKEN Hand -> Brust-Klon DIMMEN (dunkler Schatten),
            -- exakt wie beim Rechts-Equip (in_use). NICHT verstecken -> sonst ist auch der Schatten weg. Nur Messer.
            local dark = (S.cfg.dim_in_use and S.clone.in_use) == true
            if S.name == "knife" and rawget(_G, "__re4_knife_left_clone") == true then dark = true end
            if dark ~= S.clone.dim_applied then if apply_dim(dark) then S.clone.dim_applied = dark end end
        end
    end
    -- [LH-ZONE UNABHAENGIG 2026-07-20, FIX] Die LINKE Messer-Zone MUSS ausserhalb der Early-Returns von
    -- update_grab laufen. Sobald der Links-Klon draussen ist, steigt update_grab sofort aus (S.name=="knife"
    -- und __re4_knife_left_clone -> return) -- der Links-Block lief dann NIE mehr und __re4_knife_lh_in_zone
    -- fror auf TRUE ein (Stand vom Ziehen, man greift ja IN der Zone). Folgen: weapons.lua sah hz=true und
    -- liess keinen Wurf-Windup mehr zu (kein Wurf), weapons2.lua wertete das Grip-Loslassen als "wegstecken"
    -- -> clone_destroy, Messer sofort weg. Gleiche Formel/Anker/Hysterese/Radien wie rechts, nur der Handpunkt
    -- unterscheidet sich (rohe Controller-Pos, siehe [ROHE CONTROLLER-POS]).
    local function update_knife_lh_zone()
        if S.name ~= "knife" then return end
        -- [EIN RADIUS] Messer-Radien publizieren -> die LINKE Hand (weapons2.lua) nutzt dieselben Werte.
        _G.__re4_knife_grab_trigger = S.cfg.grab_trigger
        _G.__re4_knife_grab_release = S.cfg.grab_release
        local anchor = nil
        if (not slot_dormant(S)) and S.cfg.enabled then anchor = rawget(_G, S.anchor_g) end
        local lhp = anchor and (rawget(_G, "__vr_lh_ctrl_raw") or rawget(_G, "__vr_lh_world") or lh_world()) or nil
        if not (anchor and lhp) then
            _G.__re4_knife_lh_dist = nil
            _knife_lh_in_zone = false
            _G.__re4_knife_lh_in_zone = false
            return
        end
        local lx, ly, lz = lhp.x - anchor.x, lhp.y - anchor.y, lhp.z - anchor.z
        local ld = math.sqrt(lx*lx + ly*ly + lz*lz)
        _G.__re4_knife_lh_dist = ld
        if not _knife_lh_in_zone then
            if ld <= S.cfg.grab_trigger then _knife_lh_in_zone = true end
        else
            if ld > S.cfg.grab_release then _knife_lh_in_zone = false end
        end
        _G.__re4_knife_lh_in_zone = _knife_lh_in_zone
    end
    local function update_grab()
        update_knife_lh_zone()   -- [LH-ZONE UNABHAENGIG] IMMER zuerst, vor jedem Early-Return unten.
        -- [KNIFE_ONLY_STAGES] Messer-Stage: fuer alles ausser dem Messer keine Zone, keine Distanz.
        -- Muss hier zusaetzlich zu manage stehen: die Langwaffe (detached_zone) waere hinterm Ruecken
        -- sonst weiter greifbar, obwohl ihr Mesh laengst zerstoert ist.
        if slot_dormant(S) then
            S.grab.in_zone = false; S.grab.last_dist = 99; _G[S.zone_g] = false; return
        end
        -- [WURF-FENSTER 2026-07-23] Waehrend eines aktiven Granaten-/Ei-Wurf-Windups den SCHULTER-Slot
        -- (Langwaffe) aus der Zone zwingen -> die Aushol-Bewegung ueber die Schulter greift nicht die Waffe.
        -- ZEITBASIERT (__vr_throw_windup_until = os.clock+Grace, gesetzt in re4_vr_weapons) -> laeuft von SELBST
        -- ab, kann NICHT haengen -> Schulter-Holster ist nach dem Fenster garantiert wieder solide da. NUR Schulter.
        if S.name == "shoulder" and (tonumber(rawget(_G, "__vr_throw_windup_until")) or 0) > os.clock() then
            S.grab.in_zone = false; S.grab.last_dist = 99; _G[S.zone_g] = false; return
        end
        -- [LH_CLONE 2026-07-08] Messer ist schon als Klon in der LINKEN Hand -> rechter Messer-Holster AUS
        -- (kein Grab, kein Zug rechts). Symmetrisch zu "Messer rechts equippt -> links ignorieren" (Links-Lua).
        if S.name == "knife" and rawget(_G, "__re4_knife_left_clone") == true then
            S.grab.in_zone = false; S.grab.last_dist = 99; _G[S.zone_g] = false; return
        end
        local anchor = rawget(_G, S.anchor_g)
        -- [ROHE CONTROLLER-POS 2026-07-19] ALLE Holster messen mit der UNVERSCHOBENEN
        -- Controller-Position. rh_world/lh_world tragen per-Hand bzw. per-Waffe Offsets (motion:
        -- apply_hand_offset) plus Smoothing/Arm-Clamp -- damit lagen zwei Haende an derselben
        -- physischen Stelle unterschiedlich weit vom Anker. Das MESH bleibt davon unberuehrt und
        -- wird weiterhin ueber off_x/y/z positioniert.
        local rh = anchor and (rawget(_G, "__vr_rh_ctrl_raw") or rh_world())
        if not (S.cfg.enabled and anchor and rh) then
            S.grab.in_zone = false; S.grab.last_dist = 99; _G[S.zone_g] = false; return
        end
        local dx, dy, dz = rh.x - anchor.x, rh.y - anchor.y, rh.z - anchor.z
        local d = math.sqrt(dx*dx + dy*dy + dz*dz); S.grab.last_dist = d
        if not S.grab.in_zone then if d <= S.cfg.grab_trigger then S.grab.in_zone = true end
        else if d > S.cfg.grab_release then S.grab.in_zone = false end end
        -- Nur Zone/Distanz setzen. Das eigentliche Feuern macht der globale grab_dispatch (naechster Slot).
        _G[S.zone_g] = S.grab.in_zone
        -- [EINE ZONE FUER BEIDE HAENDE 2026-07-19 -> VERSCHOBEN 2026-07-20] Der Links-Block (Distanz,
        -- Hysterese, Radien-Publish) stand hier und lief damit NUR, wenn update_grab nicht vorher
        -- ausgestiegen war -> er lief bei gezogenem Links-Klon nie. Steht jetzt in update_knife_lh_zone,
        -- ganz oben in dieser Funktion aufgerufen. Rechnung/Anker/Radien unveraendert.
    end

    -- [LEARN RAUS 2026-07-20] Die Funktion learn (Greifpunkt modell-relativ aus der Handposition lernen)
    -- ist ersatzlos entfernt: sie war seit dem Slot-Fehlgriff-Problem per LEARN_ENABLED=false tot geschaltet.
    -- pl_x/pl_y/pl_z bleiben als Config-Werte bestehen (Anker = sm + q*pl, von calibrate gesetzt).

    -- [CALIBRATE] RE9-Muster: der gehaltene Controller-Punkt P wird zum Greif-Anker. Wir setzen den
    -- OFFSET so, dass der Anker (= sm + q*pl) exakt bei P liegt; der Griff-Pivot pl bleibt -> das sichtbare
    -- Mesh (dessen Griff pl vom Ursprung entfernt sitzt) rutscht mit an den Controller. Ein Punkt, alles dort.
    local function calibrate(P)
        if not (P and type(P.x) == "number") then return false end
        -- [DETACHED_ZONE / HMD_YAW] Nur die GREIFZONE kalibrieren (Controller hinter die Schulter halten).
        -- Das sichtbare Mesh (off_x/y/z) bleibt unberuehrt vorne. Zonen-Offset in die HMD-yaw-Basis
        -- projizieren (Legacy-Muster: dx/dy/dz vom HMD, auf right/up/fwd projiziert).
        if S.detached_zone then
            local hmd, right, up, fwd = hmd_pose_yaw(); if not hmd then return false end
            local dx, dy, dz = P.x - hmd.x, P.y - hmd.y, P.z - hmd.z
            S.cfg.zx = dx*right.x + dy*right.y + dz*right.z
            S.cfg.zy = dx*up.x    + dy*up.y    + dz*up.z
            S.cfg.zz = dx*fwd.x   + dy*fwd.y   + dz*fwd.z
            save_slot_cfg(S.cfg, S.path)
            return true
        end
        -- [CALIBRATE->MESH 2026-07-03] Kalibrieren setzt jetzt die MESH-POSITION (off_x/y/z), damit das
        -- sichtbare Mesh an den kalibrierten Controller-Punkt P WANDERT (frueher wurde nur der Greifpunkt
        -- pl gesetzt -> Mesh blieb stehen = der Bug). Technik: Rotation setzen, Mesh-WELT auf P setzen,
        -- Engine die lokale Pose zurueckrechnen lassen (get_LocalPosition) -> off. Greif-Anker = Mesh-
        -- Zentrum (pl=0) -> man greift, wo man's sieht. Positions-Slider verfeinern danach dasselbe off;
        -- Rotations-Slider bleiben unveraendert.
        if S.clone.parented and S.clone.obj then
            local tf = safe(function() return S.clone.obj:call("get_Transform") end); if not tf then return false end
            pcall(function() tf:call("set_LocalRotation", quat_from_euler(S.cfg.rx, S.cfg.ry, S.cfg.rz)) end)
            pcall(function() tf:call("set_Position", Vector3f.new(P.x, P.y, P.z)) end)
            local lp = safe(function() return tf:call("get_LocalPosition") end)
            if not (lp and type(lp.x) == "number") then return false end
            -- [CROUCH_OPTIK] Kalibrierst du im Crouch, steckt der Optik-Zuschlag NICHT in lp (die
            -- Weltpose kam vom Controller) -- apply legt ihn aber gleich wieder drauf. Deshalb hier
            -- abziehen: das Mesh sitzt danach exakt auf dem kalibrierten Punkt, im Stehen wie im Crouch.
            -- Ausserhalb des Crouch ist der Wert 0 -> Kalibrieren verhaelt sich unveraendert.
            S.cfg.off_x, S.cfg.off_y, S.cfg.off_z = lp.x, lp.y, lp.z - crouch_opt_z()
            S.cfg.pl_x, S.cfg.pl_y, S.cfg.pl_z = 0, 0, 0
            S.sm.has = false
            save_slot_cfg(S.cfg, S.path)
            return true
        end
        local j = joint_get(); if not j then return false end
        local jp = safe(function() return j:call("get_Position") end)
        local jr = safe(function() return j:call("get_Rotation") end)
        if not (jp and jr) then return false end
        local q = safe(function() return (jr * quat_from_euler(S.cfg.rx, S.cfg.ry, S.cfg.rz)):normalized() end)
        if not q then return false end
        local qpl = safe(function() return q * Vector3f.new(S.cfg.pl_x or 0, S.cfg.pl_y or 0, S.cfg.pl_z or 0) end) or Vector3f.new(0, 0, 0)
        local tgt = Vector3f.new(P.x - jp.x - qpl.x, P.y - jp.y - qpl.y, P.z - jp.z - qpl.z)
        local jrc = Quaternion.new(jr.w, -jr.x, -jr.y, -jr.z)   -- Inverse der Joint-Rotation (Einheitsquat)
        local off = safe(function() return jrc * tgt end)
        if not (off and type(off.x) == "number") then return false end
        S.cfg.off_x, S.cfg.off_y, S.cfg.off_z = off.x, off.y, off.z
        S.sm.has = false   -- Smoothing rigide neu seeden
        save_slot_cfg(S.cfg, S.path)
        return true
    end

    return {
        tick = function() manage(); update_smooth(); update_grab() end,
        apply = apply, destroy = destroy, calibrate = calibrate,   -- [LEARN RAUS 2026-07-20] learn entfernt
        cfg = S.cfg, clone = S.clone, grab = S.grab, hand = "right",
        on_grab = S.on_grab, ids = S.ids, name = S.name,
        anchor_g = S.anchor_g, detached_zone = S.detached_zone,
        -- [KLONLOS GREIFBAR 2026-08-17] Liegt eine Waffe dieses Slots im Inventar? manage() pflegt das
        -- ohnehin (0.5-s-Throttle, has_weapon_in_inventory) -- hier nur herausgereicht, damit
        -- nearest_with_clone den Messer-Slot auch ohne sichtbaren Klon zulassen kann. Begruendung dort.
        has_inv = function() return S.has_inv == true end,
        -- [DIAG] sichtbare Dummy-Weltposition (Klon-Transform) fuer Positions-Log
        dummy_pos = function()
            if not S.clone.obj then return nil end
            local tf = safe(function() return S.clone.obj:call("get_Transform") end); if not tf then return nil end
            return safe(function() return tf:call("get_Position") end)
        end,
        -- [DIAG] ECHTE gerenderte Mesh-Mitte (WorldAABB-Center) -> soll zeigen, wo das Mesh wirklich sichtbar ist
        mesh_center = function()
            if not S.clone.mesh then return nil end
            local aabb = safe(function() return S.clone.mesh:call("get_WorldAABB") end); if not aabb then return nil end
            local c = safe(function() return aabb:call("getCenter") end)
            if c and type(c.x) == "number" then return c end
            return nil
        end,
    }
end

-- =====================================================================
-- Slots instanziieren
-- =====================================================================
local KNIFE_CFG_PATH    = "re4_vr/re4_vr_knife.json"
local PISTOL_CFG_PATH   = "re4_vr/re4_vr_pistol_holster.json"
local GRENADE_CFG_PATH  = "re4_vr/re4_vr_grenade_holster.json"
local SHOULDER_CFG_PATH = "re4_vr/re4_vr_shoulder_holster.json"
local knife_cfg    = default_cfg()
local pistol_cfg   = default_cfg()
-- [SHIFT_X 2026-07-17, -Design] NUR die Pistole: EIN Slider, der Mesh UND Greifpunkt gemeinsam in X
-- schiebt. 0 = die kalibrierte Stellung, in der beide genau zusammen sitzen. shift_x wird in BEIDEN
-- Anker-Schreibern auf off_x addiert (compute_target + apply/parented) -> beide rechnen identisch, das
-- Verhaeltnis Mesh<->Greifpunkt bleibt 1:1. Kein anderer Slot hat den Key -> dort ist shift_x nil -> +0.
pistol_cfg.shift_x = 0.0
local grenade_cfg  = default_cfg()
local shoulder_cfg = default_cfg()
-- [DETACHED_ZONE] off_* = sichtbares Mesh VOR dem Spieler (nur Optik: welche Langwaffe steckt hinten?),
-- klein skaliert. Die GREIFZONE ist entkoppelt (zx/zy/zz = hinter der rechten Schulter, per Kalibrierung).
shoulder_cfg.off_x, shoulder_cfg.off_y, shoulder_cfg.off_z = 0.0, 0.08, 0.40      -- Mesh: mittig vor der Brust
shoulder_cfg.scale = 0.15                                                          -- klein (Anzeige, nicht 1:1)
-- Zone in HMD-yaw-Basis (relativ zum Kopf): rechts, etwas unter dem Kopf, hinter der Schulter. Per Kalibrieren feinjustieren.
shoulder_cfg.zx, shoulder_cfg.zy, shoulder_cfg.zz = 0.20, -0.15, -0.30
shoulder_cfg.grab_trigger, shoulder_cfg.grab_release = 0.22, 0.32                 -- Langwaffe = etwas grosszuegiger
-- =====================================================================
-- [KNIFE_ADA 2026-07-19] Messer-Holster PRO CHARAKTER.
-- =====================================================================
-- Ada hat ein anderes Skelett: derselbe joint-relative Offset traegt bei ihr weiter nach aussen,
-- die Greifzone lag "extrem weit weg vom Koerper". Position UND Greifdistanz muessen also
-- getrennt tunebar sein -- ohne Leons Werte anzufassen.
--
-- UMSETZUNG (bewusst additiv): Leons Datei bleibt exakt wie sie ist. Fuer Ada gibt es eine
-- ZWEITE Datei; beim ersten Mal wird sie aus Leons aktuellen Werten vorbelegt, danach divergieren
-- sie. Fehlt die Ada-Datei, laeuft alles wie bisher.
--
-- WARUM ZUR LAUFZEIT UND NICHT BEIM LADEN: beim Script-Start existiert der Spieler oft noch gar
-- nicht, und der Charakter wechselt mitten in der Session (Maincampaign <-> Separate Ways).
-- Der Umschalter haengt deshalb an einer Charakter-Flanke, nicht am Ladezeitpunkt.
-- load_slot_cfg schreibt IN die bestehende Tabelle -> der Slot behaelt seine cfg-Referenz,
-- es aendert sich nur der Inhalt. Nur beim WECHSEL, nicht jeden Frame.
local KNIFE_CFG_PATH_ADA = "re4_vr/re4_vr_knife_ada.json"
local _knife_char = nil   -- "leon" | "ada"; nil = noch nie gesetzt
-- Liefert "ada" / "leon" ODER nil = UNBEKANNT (Ladebildschirm, Player gerade neu instanziiert).
-- nil ist wichtig: bei "unbekannt" darf NICHT auf Leon zurueckgefallen werden. Sonst wuerde ein
-- kurzer Aussetzer waehrend des Tunens als Ada die Config auf Leon umschalten -- und der naechste
-- Slider-Zug landete in LEONS Datei. Im Zweifel bleibt der zuletzt sichere Charakter stehen.
local function knife_char_now()
    local ctx = get_ctx and get_ctx()
    local b = ctx and sc(ctx, "get_BodyGameObject")
    local n = b and sc(b, "get_Name")
    if n == nil then return nil end
    n = tostring(n)
    if n == "ch3a8z0_body" then return "ada" end
    if n == "ch0a0z0_body" or n == "ch0a1z0_body" then return "leon" end
    return nil   -- fremder Body -> lieber nichts umschalten
end
local function knife_active_path()
    return (_knife_char == "ada") and KNIFE_CFG_PATH_ADA or KNIFE_CFG_PATH
end

load_slot_cfg(knife_cfg, KNIFE_CFG_PATH)
load_slot_cfg(pistol_cfg, PISTOL_CFG_PATH)
load_slot_cfg(grenade_cfg, GRENADE_CFG_PATH)
load_slot_cfg(shoulder_cfg, SHOULDER_CFG_PATH)

-- [KNIFE_ADA] Charakter-Flanke: beim Wechsel die passende Datei IN knife_cfg laden.
-- Existiert Adas Datei noch nicht, wird sie einmalig aus Leons aktuellen Werten geschrieben ->
-- du tunst von Leons Stand aus weiter statt bei 0 anzufangen. Danach sind beide unabhaengig.
-- Getunt wird bei Ada vor allem pl_x/pl_y/pl_z (GREIFPUNKT, modell-relativ) und grab_trigger/
-- grab_release -- off_x/y/z (sichtbares Mesh) bleibt wie geseedet, das passt bei Ada belegt.
-- FORWARD-DECL: knife_char_tick fasst knife_slot an, wird aber VOR dessen Zuweisung definiert.
-- Ohne diese Zeile waere `knife_slot` im Funktionskoerper ein GLOBAL (immer nil) und der
-- Pfad-Wechsel liefe still ins Leere. [[feedback-lua-forward-decl]]
local knife_slot
local function knife_char_tick()
    local want = knife_char_now()
    if want == nil then return end          -- unbekannt -> NICHT umschalten (s. knife_char_now)
    if want == _knife_char then return end
    _knife_char = want
    _G.__re4_knife_char = want   -- [HARD-GUARD] speist die Sperre in save_slot_cfg
    local path = knife_active_path()
    if want == "ada" and type(safe(function() return json.load_file(path) end)) ~= "table" then
        save_slot_cfg(knife_cfg, path)   -- Seed aus Leons aktuellem Stand
    end
    load_slot_cfg(knife_cfg, path)
    if knife_slot then knife_slot.path = path end   -- Speichern (Slider/Kalibrieren) trifft die richtige Datei
end

knife_slot = make_slot({
    name = "knife", ids = KNIFE_IDS, cfg = knife_cfg, path = KNIFE_CFG_PATH,
    anchor_g = "__vr_knife_chest_pos", zone_g = "__vr_knife_holster_zone",
    get_source = function()
        local want = (last_knife.wid ~= 0) and last_knife.wid or nil
        local go, wid = find_weapon_go(KNIFE_IDS, want)
        if not go then return nil end
        return sc(go, "getComponent(System.Type)", _mesh_td), wid, go
    end,
    on_grab = function(in_hand)
        pending_action = function()
            local pe = get_pe()
            if not pe then return end
            pcall(function() pe:call("clearRequest") end)
            -- [STOW-GUARD 2026-08-18 -- gemessen] Steckt der Spieler das Messer bewusst weg, holt die
            -- ENGINE es binnen ~30 ms zurueck: im Log folgt auf unsere Kette (clearRequest ->
            -- requestEquipBareHand -> execChangeWeapon) ein NATIVes requestChangeActiveWeapon +
            -- requestChangeWeaponAction, danach execChangeWeapon/equipWeapon -- und das Messer ist
            -- wieder in der Hand (C! WECHSEL wp5001_MC -> keine -> wp5001_MC).
            -- Deshalb hier ein Zeitfenster + eine Markierung fuer die EIGENEN Aufrufe; der Block in
            -- re4_vr_weapons.lua verwirft in diesem Fenster ausschliesslich die NATIVEN.
            -- [HOLSTER-GUARD 2026-08-18 -- gemessen, BEIDE Richtungen] Nicht nur das Wegstecken wird
            -- von der Engine zurueckgenommen, der ZUG genauso: Log 13:49:44 -- wir ziehen das Messer
            -- (`requestEquipKnife`, C! WECHSEL keine -> wp5000_MC), und 125 ms spaeter ersetzt eine
            -- NATIVE Kette (requestChangeActiveWeapon -> requestChangeWeaponAction -> execChangeWeapon)
            -- es durch die vorherige Hauptwaffe (C! WECHSEL wp5000_MC -> wp4000_MC).
            -- Also gilt fuer beide Richtungen dieselbe Regel: hat der Spieler entschieden, hat die
            -- Engine 0.5 s nichts zu melden. Der Zeitstempel `__re4_stow_ours_until` schuetzt dabei
            -- unsere EIGENEN Aufrufe und laeuft von selbst aus, falls die Kette darunter abbricht.
            _G.__re4_stow_guard_until = os.clock() + 0.5
            _G.__re4_stow_ours_until  = os.clock() + 0.2
            if in_hand then pcall(function() pe:call("requestEquipBareHand", false, false) end); auto_redraw.suppress = true; auto_redraw.stow_until = os.clock() + 0.5   -- bewusst bare -> kein Auto-Draw
            else
                _G.__re4_knife_draw_ours_t = os.clock()   -- [ANTI-GHOST] eigener Zug -> nicht zurueckdrehen
                pcall(function() pe:call("requestEquipKnife") end); auto_redraw.suppress = false; _G.__re4_knife_left_intent = false; _G.__re4_knife_left_clone = false end   -- [KNIFE_HAND] rechts gezogen -> Messer gehoert der rechten Hand (Links-Klon weicht)
            pcall(function() pe:call("execChangeWeapon") end)
            _G.__re4_stow_ours_until = 0   -- [STOW-GUARD] ab hier ist alles Weitere die Engine
        end
    end,
})

local pistol_slot = make_slot({
    name = "pistol", ids = PISTOL_IDS, cfg = pistol_cfg, path = PISTOL_CFG_PATH,
    anchor_g = "__vr_pistol_holster_pos", zone_g = "__vr_pistol_holster_zone",
    get_source = function()
        local want = (last_pistol.wid ~= 0) and last_pistol.wid or nil
        local go, wid = find_weapon_go(PISTOL_IDS, want)
        if not go then return nil end
        return sc(go, "getComponent(System.Type)", _mesh_td), wid, go
    end,
    on_grab = function(in_hand)
        pending_action = function()
            local pe = get_pe()
            if not pe then return end
            pcall(function() pe:call("clearRequest") end)
            if in_hand then pcall(function() pe:call("requestEquipBareHand", false, false) end); auto_redraw.suppress = true; auto_redraw.stow_until = os.clock() + 0.5   -- Pistole weg -> bewusst bare
            else draw_last_pistol(pe); auto_redraw.suppress = false; _G.__re4_clone_no_autogun = false end  -- [BARE_RIGHT] selbst gezogen -> Gate loesen; letzte 1-Hand-Waffe ziehen
            pcall(function() pe:call("execChangeWeapon") end)
        end
    end,
})

local grenade_slot = make_slot({
    name = "grenade", ids = GRENADE_IDS, cfg = grenade_cfg, path = GRENADE_CFG_PATH,
    anchor_g = "__vr_grenade_holster_pos", zone_g = "__vr_grenade_holster_zone",
    get_source = function()
        local go, wid = find_weapon_go(GRENADE_IDS, last_grenade.wid)
        if not go then return nil end
        return sc(go, "getComponent(System.Type)", _mesh_td), wid, go
    end,
    on_grab = function(in_hand)
        pending_action = function()
            local pe = get_pe()
            if not pe then return end
            pcall(function() pe:call("clearRequest") end)
            if in_hand then pcall(function() pe:call("requestEquipBareHand", false, false) end); auto_redraw.suppress = true; auto_redraw.stow_until = os.clock() + 0.5   -- Granate weg -> bewusst bare
            else draw_last_grenade(pe); auto_redraw.suppress = false; _G.__re4_clone_no_autogun = false end  -- [BARE_RIGHT] selbst gezogen -> Gate loesen; letzte Granate ziehen (R-Grip = Wurf)
            pcall(function() pe:call("execChangeWeapon") end)
        end
    end,
})

local shoulder_slot = make_slot({
    name = "shoulder", ids = SHOULDER_IDS, cfg = shoulder_cfg, path = SHOULDER_CFG_PATH,
    anchor_g = "__vr_shoulder_holster_pos", zone_g = "__vr_shoulder_holster_zone",
    detached_zone = true,   -- Greifzone entkoppelt (hinter der Schulter), Mesh schwebt vorne.
    all_parts = true,       -- [ALLE_PARTS 2026-07-22] Langwaffe komplett zeigen (Anbauten inkl.), nicht nur Part 0.
    -- [ENTKOPPELT 2026-07-15] Frueher: link_cfg = pistol_cfg -> Mesh-Position = pistol.off+md + shoulder.addon.
    -- Damit wanderte das Langwaffen-Mesh bei JEDER Pistolen-Kalibrierung mit (die schreibt pistol.off).
    -- Jetzt eigenstaendig: off_x/y/z gelten wieder selbst (in der JSON auf die zuletzt effektive Position
    -- eingefroren, s. re4_vr_shoulder_holster.json) -> Pistole und Langwaffe sind unabhaengig bewegbar.
    -- Feinjustage der Langwaffe: "Mesh-Korrektur X/Y/Z" (md_*) in DIESEM Tree. Die Greifzone (zx/zy/zz,
    -- hinter der Schulter) war schon immer entkoppelt (detached_zone).
    get_source = function()
        local want = (last_rifle.wid ~= 0) and last_rifle.wid or nil
        local go, wid = find_weapon_go(SHOULDER_IDS, want)
        if not go then return nil end
        return sc(go, "getComponent(System.Type)", _mesh_td), wid, go
    end,
    on_grab = function(in_hand)
        pending_action = function()
            local pe = get_pe()
            if not pe then return end
            pcall(function() pe:call("clearRequest") end)
            if in_hand then pcall(function() pe:call("requestEquipBareHand", false, false) end); auto_redraw.suppress = true; auto_redraw.stow_until = os.clock() + 0.5   -- Langwaffe weg -> bewusst bare
            else
                -- [KEINE_LANGWAFFE 2026-08-05, re4_zzz_holster_probe] Hat der Charakter GAR
                -- keine Langwaffe (Mercs-Wesker: zwei Pistolen, Probe: "Langwaffen=0"), darf der
                -- Ruecken-Grab NICHTS tun. Der Riegel muss HIER stehen, nicht in draw_last_rifle:
                -- danach folgen auto_redraw.suppress=false und execChangeWeapon -- allein die beiden
                -- holten die zuletzt aktive Pistole zurueck (im Log: "-1 -> 4501" bzw. "-1 -> 6300").
                -- Inventar nicht lesbar -> alter Weg (kein Regress fuer Leon/Ada).
                local inv_s = sc(pe, "get_InventoryController")
                local has_long = (inv_s == nil)
                if inv_s then
                    for _, r in ipairs(inventory_weapon_rows(inv_s)) do
                        local w = enum_value(sc(r, "get_WeaponId"))
                        if w and SHOULDER_IDS[w] then has_long = true; break end
                    end
                end
                if not has_long then return end
                draw_last_rifle(pe); auto_redraw.suppress = false; _G.__re4_clone_no_autogun = false  -- [BARE_RIGHT] selbst gezogen -> Gate loesen; letzte Langwaffe ziehen
            end
            pcall(function() pe:call("execChangeWeapon") end)
        end
    end,
})

-- =====================================================================
-- Frame + Render-Paesse + Reset
-- =====================================================================
-- Globaler Grab-Dispatch: auf frische Grip-Presse feuert NUR der naechstgelegene Dummy in Reichweite
-- (verhindert Verwechslung bei dicht beieinander liegenden Zonen + geteilter pending_action).
local slots = { knife_slot, pistol_slot, grenade_slot, shoulder_slot }

-- =====================================================================
-- MAG-HOLSTER (linke Huefte, LINKE Hand + LINKER Grip, Grip-HOLD).
-- Kein sichtbares Mesh (nur Zone); signalisiert dem Reload-Script per
-- _G.__re4_reload_set_mag_in_hand(bool), dass das Mag in die linke Hand soll.
-- Frueher in others/re4_vr_holster_legacy.lua (laedt nicht, weil Unterordner) -> hierher.
-- Joint-relativ (wie die Waffen-Slots) + eigene 5s-Kalibrierung (LINKE Hand) + Distanzslider.
-- =====================================================================
local MAG_CFG_PATH = "re4_vr/re4_vr_mag_holster.json"
local mag_cfg = default_cfg()
mag_cfg.off_x, mag_cfg.off_y, mag_cfg.off_z = -0.16, -0.28, 0.06   -- grober Default: linke Huefte
load_slot_cfg(mag_cfg, MAG_CFG_PATH)
local mag_st = { in_zone = false, holding = false, joint = nil, last_dist = 99 }
local mag_empty_latched = false

local function mag_joint()
    local tf = body_tf(); if not tf then return nil end
    local valid = mag_st.joint and safe(function() return mag_st.joint:get_Valid() end)
    if not valid then
        mag_st.joint = nil
        for _, nm in ipairs(CHEST_JOINT_CANDIDATES) do
            local j = sc(tf, "getJointByName", nm); if j then mag_st.joint = j; mag_cfg.joint = nm; break end
        end
    end
    return mag_st.joint
end
local function mag_anchor()
    local j = mag_joint(); if not j then return nil end
    local jp = safe(function() return j:call("get_Position") end); if not jp then return nil end
    local jr = safe(function() return j:call("get_Rotation") end)
    if jr then local off = safe(function() return jr * Vector3f.new(mag_cfg.off_x, mag_cfg.off_y, mag_cfg.off_z) end)
        if off then return Vector3f.new(jp.x+off.x, jp.y+off.y, jp.z+off.z) end end
    return Vector3f.new(jp.x, jp.y, jp.z)
end
local function mag_set_holding(v)
    if v == mag_st.holding then return end
    mag_st.holding = v
    if _G.__re4_reload_set_mag_in_hand then pcall(function() _G.__re4_reload_set_mag_in_hand(v) end) end
end
local function mag_haptic(amp)
    local lj = left_joystick()
    -- [MAG_RUMBLE] kraeftiger: laenger (0.06->0.16s) + tiefere Frequenz (200->80Hz) = wummert statt summt.
    -- Amplitude bleibt wie uebergeben (0.9-1.0 = quasi voll). amp auf mind. 1.0 anheben fuer vollen Punch.
    if lj and mag_cfg.grab_haptic then pcall(function() vrmod:trigger_haptic_vibration(0.0, 0.16, 80.0, math.max(amp, 1.0), lj) end) end
end
local function mag_tick()
    -- [KILLSWITCH] bei aktivem Killswitch (KS1/2/3) NICHTS: kein Grab, kein Halten, keine Haptik.
    -- [KNIFE_ONLY_STAGES] Messer-Stage: dito -- ohne Schusswaffe braucht es auch kein Magazin.
    if _G.__re4_holster_killswitch == true or _G.__re4_holster_knife_only == true then
        mag_set_holding(false); _G.__vr_in_mag_holster_zone = false; return
    end
    if not mag_cfg.enabled then mag_set_holding(false); _G.__vr_in_mag_holster_zone = false; return end
    -- [ROHE CONTROLLER-POS] wie alle Holster -- s. update_grab.
    local anchor = mag_anchor(); local lh = rawget(_G, "__vr_lh_ctrl_raw") or lh_world()
    if not (anchor and lh) then _G.__vr_in_mag_holster_zone = mag_st.holding; return end
    local dx,dy,dz = lh.x-anchor.x, lh.y-anchor.y, lh.z-anchor.z
    local d = math.sqrt(dx*dx+dy*dy+dz*dz); mag_st.last_dist = d
    if not mag_st.in_zone then if d <= mag_cfg.grab_trigger then mag_st.in_zone = true end
    else if d > mag_cfg.grab_release then mag_st.in_zone = false end end
    local lgrip = left_grip_pressed()
    if not mag_st.holding then
        if mag_st.in_zone and lgrip then
            if rawget(_G, "__re4_reload_grab_empty") == true then
                if not mag_empty_latched then mag_empty_latched = true; mag_haptic(1.0) end   -- nichts zu greifen
            else
                mag_set_holding(true); mag_haptic(0.9)
            end
        end
        if not lgrip then mag_empty_latched = false end
    elseif not lgrip then
        mag_set_holding(false)
    end
    _G.__vr_in_mag_holster_zone = mag_st.in_zone or mag_st.holding
end
-- Kalibrierung: LINKER Controller-Punkt P wird zur Zone (Offset dorthin, kein Pivot).
local function mag_calibrate(P)
    if not (P and type(P.x) == "number") then return false end
    local j = mag_joint(); if not j then return false end
    local jp = safe(function() return j:call("get_Position") end)
    local jr = safe(function() return j:call("get_Rotation") end)
    if not (jp and jr) then return false end
    local jrc = Quaternion.new(jr.w, -jr.x, -jr.y, -jr.z)
    local off = safe(function() return jrc * Vector3f.new(P.x-jp.x, P.y-jp.y, P.z-jp.z) end)
    if not (off and type(off.x) == "number") then return false end
    mag_cfg.off_x, mag_cfg.off_y, mag_cfg.off_z = off.x, off.y, off.z
    save_slot_cfg(mag_cfg, MAG_CFG_PATH)
    return true
end
local mag_slot = { name = "mag", cfg = mag_cfg, calibrate = mag_calibrate, grab = mag_st, hand = "left", path = MAG_CFG_PATH }

-- Grip loslassen = greifen (Slot per nearest beim Loslassen).
-- [LEARN RAUS 2026-07-20] Der "Greifpunkt lernen"-Lerngriff (langes Halten am Mesh-Klon, Doppel-Rumble)
-- ist komplett ausgebaut. Er war schon deaktiviert, weil er den zu lernenden Slot per naechstem ANKER
-- waehlte und bei eng liegenden Klonen den FALSCHEN lernte (Messer-Anker wanderte auf die Granate).
-- Anker kommen ausschliesslich aus der Kalibrierung; nichts davon wird noch gebraucht.
local grip_prev     = false
local grip_t0       = 0
local press_armed   = false  -- [PRESS_IN_ZONE] Begann die FRISCHE Grip-Presse in IRGENDEINER Zone? (Hover-Schutz)
                             -- Der KONKRETE Slot wird erst beim Loslassen nach nearest gewaehlt -> das Naehere
                             -- zum Loslass-Zeitpunkt gewinnt (Hand darf sich waehrend des Grips bewegen).
local grab_haptic_at = 0   -- [GRAB-DELAY] geplanter Waffen-Grab-Rumble (0 = keiner), via Tick in grab_dispatch
local knife_snd_at  = 0    -- Zeitpunkt fuer den Messer-Zieh-Sound (verzoegert, bis das Messer wirklich in der Hand ist)

-- [AIM-vs-DRAW] Ist eine Waffe in der Hand, ist Right-Grip = Aim (f.LT). Ein Grip in der Holster-Zone darf
-- dann NICHT ziehen, wenn du eigentlich zielst. Unterscheidung OHNE raeumliche Bewegung: TIPPEN vs HALTEN.
-- Kurzer Tipp (Grip <= AIM_HOLD, dann loslassen) = Holster-Grab (Draw ODER Stow, nearest-wins wie immer).
-- Grip laenger gehalten (= durchgehend zielen) = Aim, KEIN Grab. Bei LEEREN Haenden (kein Aim-Konflikt)
-- bleibt alles beim Alten: jeder Grip-Release in Zone = Grab, egal wie lange gehalten.
local TAP_CFG_PATH = "re4_vr/re4_vr_holster_tap.json"
local AIM_HOLD     = 0.35   -- s: laenger gehalten = Aim (kein Grab); kuerzer = Holster-Tipp
-- [CROUCH_OPTIK 2026-07-22] Gain fuer die Crouch-Optik-Korrektur der Mesh-Klone (0 = aus).
-- Als Global gehalten (die Slot-Closures lesen es; kein weiterer Top-Level-Local), persistiert
-- zusammen mit der Aim-Halteschwelle in derselben kleinen JSON.
_G.__re4_holster_crouch_gain = 0.0
_G.__re4_holster_ada_mesh_z  = 0.0   -- [ADA-MESH-Z] Ada-only Mesh-Z-Offset (alle Slots)
do local d = safe(function() return json.load_file(TAP_CFG_PATH) end)
   if type(d) == "table" then
       if type(d.aim_hold) == "number" then AIM_HOLD = d.aim_hold end
       if type(d.crouch_gain) == "number" then _G.__re4_holster_crouch_gain = d.crouch_gain end
       if type(d.ada_mesh_z) == "number" then _G.__re4_holster_ada_mesh_z = d.ada_mesh_z end
   end end
local function save_tap_cfg()
    pcall(function() json.dump_file(TAP_CFG_PATH,
        { aim_hold = AIM_HOLD, crouch_gain = _G.__re4_holster_crouch_gain or 0.0, ada_mesh_z = _G.__re4_holster_ada_mesh_z or 0.0 }) end)
end
local tap_mode = false  -- FRISCHE Presse begann in Zone MIT Waffe in Hand -> Tipp(=Grab) vs Halten(=Aim)

-- [KNIFE_SND] Sound beim Grabben des Messers aus dem Holster (SoundContainer.trigger, wie #re4_sound_player).
local KNIFE_GRAB_SND = 288425941
-- [HOLSTER_SND] Universeller "aus dem Holster gezogen"-Sound (bei ALLEN Waffen gleich, wie reload mag_holster).
local HOLSTER_GRAB_SND = 1839787494
-- [HOLSTER_SND] Granate hat einen EIGENEN Holster-/Unholster-Sound.
local GRENADE_GRAB_SND = 3388506884
local _snd_container_td = sdk.typeof("soundlib.SoundContainer")
local function play_go_sound(go, id)
    if not (go and id and id > 0 and _snd_container_td) then return end
    local scn = sc(go, "getComponent(System.Type)", _snd_container_td)
    if scn then pcall(function() scn:call("trigger(System.UInt32)", id) end) end
end
-- [KNIFE_HAND 2026-07-07] Export: derselbe Grab-Sound wie beim rechten Messer-Grab (ueber den SoundContainer
-- des Messer-GO, hand-neutral). re4_vr_knife_lefthand.lua ruft das beim Links-Draw/Stow.
_G.__re4_knife_play_grab_sound = function() play_go_sound(find_weapon_go(KNIFE_IDS), HOLSTER_GRAB_SND) end
-- Naechster Slot mit gespawntem Klon (leerer Slot = kein Objekt -> nimmt nicht teil).
local function nearest_with_clone()
    local best, bestd = nil, 1e9
    for _, s in ipairs(slots) do
        -- detached_zone-Slot (Schulter): Zone ist entkoppelt vom Mesh -> darf auch ohne sichtbaren Klon greifen.
        -- [KNIFE_ONLY_STAGES] Genau deshalb hier explizit gaten: sonst bliebe die Langwaffe klonlos greifbar.
        -- [KLONLOS GREIFBAR 2026-08-17] NUR der Messer-Slot darf zusaetzlich ohne Klon mitspielen, solange
        -- ein Messer nachweislich im Inventar liegt. GRUND (aus dem Test, nach einer Cutscene reproduziert):
        -- fehlte der Brust-Klon, fiel der Messer-Slot hier komplett aus der Auswahl -- und der Grab ging an
        -- den naechstliegenden anderen Slot, also an die PISTOLE ("rechts am Messer kommt die Pistole raus").
        -- Der Greif-Anker selbst lief dabei normal weiter (update_smooth rechnet ihn aus dem Joint, ganz ohne
        -- Klon-Bezug; nur apply() steigt bei fehlendem Klon aus) -- deshalb funktionierte die LINKE Messer-Zone
        -- weiterhin, waehrend rechts nichts mehr ging. Genau dieselbe Entkopplung nutzt die Schulter schon
        -- ueber detached_zone. Kein Phantom-Grab: ohne Messer im Inventar (has_inv) bleibt der Slot draussen.
        -- RUECKBAU: `_G.__re4_knife_clonless_grab = false` -> exakt das Verhalten von vorher
        -- (Messer-Slot nur mit sichtbarem Klon greifbar).
        local grabbable = s.clone.obj or s.detached_zone
            or (s.name == "knife" and rawget(_G, "__re4_knife_clonless_grab") ~= false
                and type(s.has_inv) == "function" and s.has_inv())
        if not slot_dormant(s) and s.cfg.enabled and grabbable and s.grab.last_dist < bestd then best, bestd = s, s.grab.last_dist end
    end
    return best
end
local function do_grab(best)
    if not best then return end
    -- [KNIFE_HAND 2026-07-07] Messer in der LINKEN Hand -> die RECHTE Hand macht am Messer-Holster GAR NICHTS
    -- (kein Stow, kein Sound, kein Haptik). Nur die haltende Hand darf stauen; die andere Hand hat mit dem
    -- Messer nichts zu tun. Andere Holster (Pistole/Granate/Langwaffe) bleiben unberuehrt.
    -- [2026-08-17] Zusaetzlich zum abgeleiteten `__re4_knife_hand` wird der ECHTE Zustand gefragt
    -- (`__re4_knife_left_clone` = es liegt wirklich ein Klon in der linken Hand). Reine Ergaenzung,
    -- kein Verhaltenswechsel: `__re4_knife_hand` haengt an `__re4_knife_left_intent`, und das wird
    -- im ganzen Mod nur noch auf FALSE gesetzt (:1390) -- die Datei, die es frueher setzte, gibt es
    -- nicht mehr. Der Klon-Zustand ist damit das einzige belastbare Signal fuer "Messer ist links".
    if best.name == "knife" and (rawget(_G, "__re4_knife_hand") == "left"
                                 or rawget(_G, "__re4_knife_left_clone") == true) then return end
    -- [IN_HAND] Wegstecken vs Ziehen: NUR wegstecken, wenn die Slot-Waffe WIRKLICH in der Hand ist. get_equip_wid
    -- (get_EquipWeaponID) luegt "zuletzt gewaehlt" vor -> bei leeren Haenden waere in_hand faelschlich true und
    -- der Grab wuerde wegstecken statt ziehen. Ehrliches Signal: weapon_actually_in_hand (IsEquipGun/Knife/...).
    local ew = get_equip_wid()
    local really = weapon_actually_in_hand()   -- true = irgendeine Waffe wirklich gezogen; nil/false -> ziehen
    local in_hand = (really == true) and (ew ~= nil) and (best.ids[ew] == true)
    -- [POST_STOW] Beim Wegstecken kurz Aim sperren (binding liest __vr_post_stow_until) -> der Aim-Auto-Draw
    -- zieht die gerade weggesteckte Waffe nicht sofort zurueck (Flackern), bis bare_hands greift.
    if in_hand then _G.__vr_post_stow_until = os.clock() + 0.6 end
    -- [ERST LOSLASSEN 2026-08-12] Greifen und Zielen liegen auf demselben Knopf. Nach JEDEM Holster-
    -- Grab muss der Grip deshalb einmal losgelassen werden, bevor er wieder als Zielen zaehlt -- sonst
    -- zieht man die Waffe und zielt in derselben Bewegung (bei Scope-Waffen sieht man das als kurzen
    -- Zoom durchs Glas). Kein Zeitfenster, sondern ein Latch: das Binding loescht ihn, sobald der
    -- Grip wirklich offen ist. Gilt fuer alle Holster gleich.
    _G.__re4_aim_relatch = true
    best.on_grab(in_hand)
    -- [HOLSTER_SND] Holster-Sound bei JEDEM Grab (Ziehen UND Wegstecken). Granate = eigener Sound.
    -- Ueber den SoundContainer der gegriffenen Waffe (find_weapon_go). Falls unhoerbar -> Body-GO probieren.
    local snd = (best.name == "grenade") and GRENADE_GRAB_SND or HOLSTER_GRAB_SND
    play_go_sound(find_weapon_go(best.ids), snd)
    -- [LH_CLONE 2026-07-10] Der pauschale Klon-Kill bei JEDEM Holster-Zug wurde ENTFERNT: er killte auch bei
    -- reinen Rechte-Hand-Zuegen (Pistole rechts + Messer links soll zusammen bleiben). Die Pose-Kollision, die er
    -- verhindern sollte, wird ohnehin schon durch die gezielten Kills abgedeckt (Support-Dock + Reload/Rack in
    -- re4_vr_knife_lefthand.lua), die nur dann greifen, wenn die LINKE Hand wirklich gebraucht wird.
    if best.cfg.grab_haptic then
        local delay = tonumber(best.cfg.grab_haptic_delay) or 0
        if delay > 0 then
            grab_haptic_at = os.clock() + delay   -- [GRAB-DELAY] zeitgesteuert (Call-Delay-Param feuert unzuverlaessig)
        else
            local rj = right_joystick(); if rj then pcall(function()
                vrmod:trigger_haptic_vibration(0.0, 0.06, 200.0, 0.9, rj) end) end
        end
    end
end
local function grab_dispatch()
    -- [KILLSWITCH] KS1/2/3: keine Grabs, keine Haptik. grip_prev frisch halten (kein Grab beim Austritt).
    if _G.__re4_holster_killswitch == true then grip_prev = right_grip_pressed(); press_armed = false; tap_mode = false; _G.__vr_holster_grab_armed = false; return end
    -- [GRAB-DELAY] verzoegerter Waffen-Grab-Rumble faellig? (aus do_grab geplant)
    if grab_haptic_at > 0 and os.clock() >= grab_haptic_at then
        grab_haptic_at = 0
        local rj = right_joystick()
        if rj then pcall(function() vrmod:trigger_haptic_vibration(0.0, 0.06, 200.0, 0.9, rj) end) end
    end
    local grip = right_grip_pressed()
    if grip and not grip_prev then
        grip_t0 = os.clock()   -- Pressbeginn (fuer die Tipp-/Halte-Unterscheidung beim Loslassen)
        -- [PRESS_IN_ZONE] Nur MERKEN, ob die frische Presse in IRGENDEINER Zone startet (Hover-Schutz). Der
        -- konkrete Slot wird erst beim Loslassen gewaehlt. Verhindert, dass ein bereits gehaltener Grip beim
        -- Hovern ueber ein Holster grabbt (Wurf-Wedeln, Zielen, Reinfahren).
        local s = nearest_with_clone()
        local in_zone = (s and s.grab.last_dist <= s.cfg.grab_trigger) and true or false
        -- [AIM-vs-DRAW] Waffe in Hand? Dann Tipp-Modus: Aim NICHT sperren (Grip zielt sofort), und beim
        -- Loslassen nur greifen, wenn es ein kurzer TIPP war (Halten = Zielen). Nur bei EINDEUTIG (wih==true)
        -- umschalten; unbekannt/bare = alt (Aim-Sperre + Zonen-Grab, egal wie lange gehalten).
        local wih = weapon_actually_in_hand()
        if in_zone and wih == true then
            tap_mode = true; press_armed = false
        else
            tap_mode = false; press_armed = in_zone
        end
    end
    -- LOSLASSEN = GREIFEN. Der Slot wird JETZT (beim Loslassen) nach nearest gewaehlt -> das Naehere zum
    -- Loslass-Zeitpunkt gewinnt (Hand darf sich waehrend des Grips bewegt haben). press_armed = die Presse
    -- begann in einer Zone (Hover-mit-Grip / Wurf-Loslassen -> press_armed=false -> KEIN Grab).
    if grip_prev and not grip then
        -- [AIM-vs-DRAW] Tipp-Modus (Waffe in Hand): nur greifen, wenn es ein kurzer TIPP war (held <= AIM_HOLD);
        -- laenger gehalten = du hast gezielt -> nichts. Der Slot wird wie immer per nearest beim Loslassen
        -- gewaehlt (Draw ODER Stow, nearest-wins). Bare -> wie bisher: press_armed + Loslass-Radius, Dauer egal.
        local held = os.clock() - grip_t0
        local s, fire
        if tap_mode then
            s = (held <= AIM_HOLD) and nearest_with_clone() or nil
            fire = s and (s.grab.last_dist <= s.cfg.grab_release)
        else
            s = press_armed and nearest_with_clone() or nil
            fire = s and (s.grab.last_dist <= s.cfg.grab_release)
        end
        if fire then do_grab(s) end
        press_armed = false; tap_mode = false
    end
    grip_prev = grip
    -- [HOLSTER_GRAB] binding.lua sperrt das Aim NUR wenn dies true ist (= Grip-Presse begann in einer Zone).
    -- Hover mit gedruecktem Aim ueber ein Holster -> press_armed=false -> Aim bleibt an.
    -- [SCOPE_GRAB] Scope-Waffe (z.B. Sniper) im Tipp-Modus: Aim waehrend des Tipp-Fensters (held < AIM_HOLD)
    -- unterdruecken, sonst blitzt beim Antippen kurz das Scope auf, BEVOR der Grab beim Loslassen feuert.
    -- Weil dadurch kein Scope engaged, springt auch der Scope-Killswitch nicht an -> Holster greift ganz
    -- normal. Erst laenger gehalten (>= AIM_HOLD) -> Aim frei (= bewusstes Zielen, dann kein Grab). NUR
    -- Scope-Waffen (__re4_scope_wid); andere Waffen behalten ihr sofortiges Tipp-Aim (unveraendert).
    if tap_mode and rawget(_G, "__re4_scope_wid") ~= nil then
        _G.__vr_holster_grab_armed = (grip and (os.clock() - grip_t0) < AIM_HOLD) and true or false
    else
        _G.__vr_holster_grab_armed = press_armed
    end
end

-- =====================================================================
-- [CALIBRATE] UI-getriggerte 5s-Kalibrierung mit Sekunden-Haptik (RE9-Muster).
-- Knopf im Menue -> 5s Countdown (Puls pro Sekunde) -> Controller-Position wird
-- zum Greif-Anker (calibrate verschiebt den Offset dorthin). Kein Grip noetig,
-- kann nicht versehentlich feuern.
-- =====================================================================
local CAL_DELAY = 5.0
local cal_slot, cal_deadline, cal_last_beep = nil, 0, -1
local function haptic_pulse(dur, freq, amp)
    local rj = right_joystick()
    if rj then pcall(function() vrmod:trigger_haptic_vibration(0.0, dur, freq, amp, rj) end) end
end
local function start_calibration(slot)
    cal_slot = slot; cal_deadline = os.clock() + CAL_DELAY; cal_last_beep = -1
    haptic_pulse(0.10, 200.0, 0.9)   -- Start-Puls (bewaehrte Grab-Rumble-Werte 200Hz/0.9 = sicher fuehlbar)
end
local function calibration_tick()
    if not cal_slot then return end
    local remaining = cal_deadline - os.clock()
    if remaining <= 0 then
        -- [ROHE CONTROLLER-POS] Kalibriert wird mit EXAKT dem Bezug, gegen den auch gemessen wird --
        -- sonst passt der Anker nicht zur Zone. Gilt fuer alle Slots (Mag = LINKE Hand).
        local P
        if cal_slot.hand == "left" then P = rawget(_G, "__vr_lh_ctrl_raw") or lh_world()
        else                              P = rawget(_G, "__vr_rh_ctrl_raw") or rh_world() end
        local ok = P and cal_slot.calibrate(P)
        haptic_pulse(0.30, 200.0, 1.0)   -- langer Bestaetigungspuls
        cal_slot = nil; cal_last_beep = -1
    else
        local int_s = math.ceil(remaining)
        if int_s ~= cal_last_beep then cal_last_beep = int_s; haptic_pulse(0.09, 200.0, 0.9) end   -- Pip pro Sekunde
    end
end

re.on_frame(function()
    -- [PERF 2026-08-17] Frame-Grenze fuer die Joint-Gueltigkeitspruefung (s. joint_get). on_frame
    -- laeuft am ENDE eines Frames, die sechs Phasen-Paesse davor -- alle Paesse eines Frames sehen
    -- also denselben Zaehlerstand, und danach wird wieder frisch geprueft. OHNE dieses Hochzaehlen
    -- wuerde der Joint nach der ersten Pruefung nie mehr geprueft werden.
    _hol_frame = _hol_frame + 1

    -- [KILLSWITCH] KS1/2/3 -> Holster komplett dormant (Clones zerstoert, keine Grabs/Haptik).
    -- [THROWSIGHT] Del-Lago-Stage laeuft mit is_active=false (First-Person als Gameplay), soll das
    -- Holster aber ebenso dormant halten -> Global mit einbeziehen (generelle KS-Regel, nicht extra).
    -- [NO_WEAPON_STAGES] Start-Stages 40500/40501/40502/40510 (vor der Waffen-Cutscene) ebenfalls dormant.
    _G.__re4_holster_killswitch = ks_active() or (rawget(_G, "__re4_throwsight_active") == true)
                                  or no_weapons_yet()
    -- [KNIFE_ONLY_STAGES] Einmal pro Frame, vor allen ticks -> slot_dormant liest es konsistent.
    _G.__re4_holster_knife_only = knife_only_stage()
    -- [KNIFE_ADA] Charakter-Flanke pruefen, BEVOR die Slots ticken -> sie sehen sofort die
    -- richtige Config. Macht nur beim WECHSEL Arbeit (Vergleich zweier Strings pro Frame).
    knife_char_tick()
    -- [SLOT-WACHHUND STILLGELEGT 2026-08-01 -- HAT HART GECRASHT] Der Aufruf stand hier und hat einen
    -- Full-Crash verursacht. Grund, soweit belegbar: `inv:equip(Guid)` ist im Holster ungefaehrlich, WEIL
    -- es dort im Kontext eines Zieh-Vorgangs laeuft. Aus einem freien Frame-Tick trifft es das Inventar
    -- auch waehrend die Engine es gerade umbaut (Waffenwechsel, Stagger, Menue) -- genau die Situation,
    -- in der der Slot leer ist. NICHT wieder scharf schalten ohne Zustands-Gate (kein Menue, kein
    -- Waffenwechsel, kein Stagger) und ohne dass geklaert ist, WER den Slot leert.
    -- equip_slot_guard
    calibration_tick()
    track_last_pistol()
    track_last_grenade()
    track_last_rifle()
    track_last_knife()
    -- [BARE_HANDS] Leere Haende = KEINE Waffe wirklich GEZOGEN -> binding unterdrueckt Aim (sonst zieht
    -- das Spiel bei Right-Grip automatisch die letzte Waffe). Ehrliches Signal (IsEquipGun/Knife/Grenade),
    -- NICHT get_EquipWeaponID (das luegt die letzte Waffe vor). Bei "unbekannt" (nil) Zustand halten.
    local in_hand_now, knife_now, gren_now, in_hand_ambiguous = weapon_actually_in_hand()
    if in_hand_now ~= nil then
        _G.__vr_bare_hands = not in_hand_now
        -- [MELEE_NO_AIM] Messer/Granate wirklich in der Hand -> binding unterdrueckt Aim (Wurf machen wir
        -- selbst ueber den rohen Right-Grip). Sonst zieht die Engine beim Aim die letzte Schusswaffe zurueck.
        -- Pistole/Langwaffe setzen diese Flags NICHT (get_IsEquipGun) -> die behalten Aim.
        _G.__vr_knife_in_hand   = knife_now == true
        _G.__vr_grenade_in_hand = gren_now == true
    end
    -- [STAGGER_DRAW] State.Damage = Spieler in Damage-Reaktion (Feuer/Axt/Treffer -- Live-Abfrage DAS
    -- gemeinsame Flag aller gun-versteckenden Stagger). Solange aktiv + kurz danach Latch setzen, damit
    -- binding ausnahmsweise den Right-Grip-Auto-Draw der letzten Waffe erlaubt (sonst bei bare hands gesperrt).
    do
        local ctx = get_ctx()
        if ctx then
            if _G.__re4_state_damage_mask == nil then
                local m = false
                pcall(function()
                    local ev = sdk.find_type_definition("chainsaw.PlayerDefine.State"):get_field("Damage"):get_data(nil)
                    local bb = ev and ev:get_field("value__")
                    if type(bb) == "number" then m = bb end
                end)
                _G.__re4_state_damage_mask = m
            end
            local mask = _G.__re4_state_damage_mask
            if mask then
                local sv  = sc(ctx, "get_State")
                local svn = sv and sf(sv, "value__")
                if type(svn) == "number" and (svn & mask) == mask then
                    _G.__vr_stagger_recent_until = os.clock() + 0.6   -- kurzes Fenster nach dem Stagger fuer Right-Grip-Draw
                end
            end
        end
    end
    -- [AUTO_REDRAW] Engine hat die Waffe von selbst weggenommen (Stagger/Kick/...) -> letzte Waffe zurueck.
    -- Gate: NUR reines Gameplay (killswitch.is_pure_gameplay -> kein KS/Cutscene/Leiter/Vault/Finisher) UND
    -- NICHT bewusst geholstert (auto_redraw.suppress). "direkt danach" = sobald wieder reines Gameplay.
    do
        local ar = auto_redraw
        -- [HOOKSHOT-AUSNAHME 2026-07-20] Der Enterhaken laesst den CamState im Nicht-Gameplay
        -- haengen -> pg blieb false -> weder Snapshot noch Restore liefen, die Waffe war weg. In einem
        -- kurzen Fenster nach dem Haken (vom Killswitch publiziert) gilt hier bewusst 'Gameplay'.
        local pg = (killswitch.is_pure_gameplay ~= nil) and (killswitch.is_pure_gameplay() == true)
        if not pg and (tonumber(rawget(_G, "__re4_hookshot_recent_until")) or 0) > os.clock()
           and _G.__re4_holster_killswitch ~= true then pg = true end
        -- [REDRAW_STABLE] pure-Gameplay muss kurz STABIL anhalten (0.4s), bevor wir die Waffe zurueckholen.
        -- Sonst feuert der Redraw im kurzen Gameplay-Uebergang (CamState AutoMove beim Leiter-/Vault-Anmarsch),
        -- wo die Engine die Waffe schon weggenommen hat, der Ladder/Vault-KS aber erst 1-2 Frames spaeter angeht.
        if pg then
            if (ar.pure_since or 0) == 0 then ar.pure_since = os.clock() end
        else
            ar.pure_since = 0
            -- [DISARM-GATE 2026-07-17] Letzter Moment in NICHT-reinem Gameplay (KS/Cutscene/Leiter/Vault/
            -- Finisher/Stagger). Der Restore darf NUR feuern, wenn wir gerade DA rauskommen -- also ein
            -- ECHTER Entzug war. -Erkenntnis: "Engine reagiert nicht aufs Leerschiessen, der RT steht
            -- danach zuverlaessig auf dryfire" -> die leere Pistole ist NOCH equippt, pure-gameplay faellt
            -- NIE. Ohne diese Schranke sprang der Restore auf ein 1-2-Frame "bare" (transienter
            -- requestEquipBareHand bei leerer Waffe) an und zog die Waffe/das Messer in die Hand.
            ar.left_pure_t = os.clock()
        end
        -- [FORENSIK 2026-08-06, "die Waffe kam nach dem Stagger erst nach 4 s zurueck"] Die drei
        -- Schranken des Restores sind lokale Felder -> von aussen unsichtbar, kein Log konnte sie zeigen.
        -- Hier jeden Frame spiegeln (reine Zuweisungen, keine Logik): re4_zzz_holster_probe.lua liest sie.
        -- [SNAPSHOT 2026-07-17, -Regel] "Nach einem Killswitch/Stagger genau das selbe wie davor --
        -- von bare hands bis Langwaffe." Also den Ist-Zustand mitschreiben: die KONKRETE wid, oder
        -- false = LEERE HAENDE. Danach wird genau der hergestellt.
        -- ACHTUNG, TEUER BEZAHLT: NICHT auf "pg wird im KS false, also friert der Snapshot ein" verlassen --
        -- das ist FALSCH (s. Kommentar am elseif unten). Was "leer" vom Engine-Entzug trennt, ist ar.suppress.
        -- ERSETZT das alte ar.kind (Typ-String "gun"/"knife"/"grenade"). Warum das nie funktionieren konnte:
        -- 1. ar.kind wurde NUR bei in_hand==true gesetzt -> "bare" war kein speicherbarer Zustand
        -- -> "vorher leere Haende" liess sich nicht wiederherstellen, es wurde immer gezogen.
        -- 2. "gun" sagte nicht WELCHE -> der Restore lief auf requestEquipGun = "zuletzt aktive
        -- Main-Waffe" und holte die Langwaffe (live belegt: REDRAW FIRE -> wid 4902 nach dem KS).
        if pg and in_hand_now ~= nil and not in_hand_ambiguous then
            -- [AMBIGUOUS-GUARD] wie gehabt: im mehrdeutigen Fallback (alle IsEquip*-Getter nil, z.B.
            -- Messer-Melee-Transient meldet die letzte Gun) NICHT mitschreiben -> keine falsche wid einfrieren.
            if in_hand_now == true then
                -- [STOW_VERFAELLT 2026-08-06 -- Log belegt] Waffe wieder in der Hand -> ein frueherer
                -- bewusster Stow ist erledigt, suppress muss weg. Vorher blieb es nach einem Holster-Stow
                -- stehen, bis man das naechste Mal ueber einen Holster-Grab zog (Z.1391/1412/1432/1477) --
                -- ein DPAD-/Inventar-Wechsel loeste es NIE. Folge (Log 12:00:32 -> 12:02:41): suppress=true
                -- ueber zwei Waffenwechsel hinweg, beim Stagger schrieb der Snapshot deshalb snap=false
                -- ("leer ist gewollt") und der Restore feuerte nicht -- die Waffe kam erst zurueck, als der
                -- selbst zog. stow_until (0.5 s, bisher gesetzt aber NIE gelesen) haelt dabei die
                -- Stow-Luecke frei: zwischen Stow-Request und echtem Equip-Wechsel ist in_hand kurz noch
                -- true, dort darf suppress NICHT fallen, sonst dreht der Restore den eigenen Stow zurueck.
                -- Beeinflusst keinen anderen Redraw: suppress wird ausschliesslich in den beiden Zweigen
                -- fuer LEERE Haende gelesen (Snapshot Z.1886, Restore-Bedingung Z.1926).
                if ar.suppress and os.clock() >= (ar.stow_until or 0) then ar.suppress = false end
                local w = get_equip_wid()
                -- wid unlesbar -> alten Snapshot halten statt Muell einfrieren
                if type(w) == "number" and w >= 0 and w ~= ar.snap then
                    ar.snap = w
                end
            elseif ar.suppress then
                -- [LEER NUR BEI EIGENEM STOW 2026-07-17] Haende leer ist NUR dann der gewollte Zustand, wenn
                -- DU bewusst geholstert hast (on_grab setzt suppress). Dann merken -> nach KS/Stagger bleibt bare.
                -- [2026-08-01, "lass das so, das ist realistischer"] Hier stand kurzzeitig eine Ausnahme
                -- fuer den Klon-Finisher (Waffe erzwungen zurueckholen). Wieder raus -- nach einem Finisher darf
                -- das Messer in der Hand bleiben, das ist so gewollt.
                if ar.snap ~= false then
                    -- [GEISTER-WAFFENWECHSEL 2026-07-21] Genau HIER entsteht "Waffe kommt nach dem
                    -- Nahkampf nicht zurueck": snap=false heisst "leere Haende sind gewollt" -> der Restore
                    -- holt bewusst NICHTS. Gesetzt wird das nur, wenn suppress von einem eigenen Stow kommt
                    -- (Holster-Grab/Links-Stow setzen stow_until auf now+0.5).
                    ar.snap = false
                end
            end
            -- [WICHTIG] Haende leer OHNE eigenen Stow = die ENGINE hat sie weggenommen (Killswitch/Stagger/Kick)
            -- -> Snapshot NICHT anfassen, er haelt weiter die Waffe von VORHER, die der Restore zurueckholt.
            -- DAS war der Bug (live belegt 10:28:01: "SNAP 5001 -> false", direkt als der KS das Messer nahm):
            -- die Annahme "im KS ist pg=false, also friert der Snapshot ein" ist FALSCH. Die Engine nimmt die
            -- Waffe 1-2 Frames BEVOR der KS angeht -- in dem Fenster ist pg noch true. Der Snapshot schrieb
            -- deshalb "bare", 5001 war weg, und der Restore hatte nichts mehr zum Wiederherstellen.
            -- Siehe auch den REDRAW_STABLE-Kommentar oben: genau dieses Uebergangsfenster ist dort beschrieben.
        end
        -- [RESTORE] Haende leer, obwohl vor dem Ereignis eine konkrete Waffe drin war -> genau die zurueck.
        -- ar.snap == false (vorher bare) -> NICHTS ziehen, bare bleibt bare. Genau der Fall, der vorher fehlte.
        -- ar.suppress bleibt DRIN: pending_action ist deferred, zwischen "bewusst geholstert" und dem echten
        -- Equip-Wechsel ist in_hand kurz noch true -> ohne suppress feuerte der Restore in diese Luecke und
        -- drehte den eigenen Stow zurueck.
        -- [FINISHER_FAST_REDRAW 2026-08-01] AUSNAHME fuer den RT-Finisher: "nach diesen Momenten muss
        -- die letzte Waffe direkt wieder kommen". Die 0.4 s Stabilitaets-Wartezeit oben schuetzt gegen den
        -- Leiter-/Vault-ANMARSCH (Engine nimmt die Waffe, der KS geht erst 1-2 Frames spaeter an) -- diesen
        -- Uebergang gibt es beim Finisher nicht: die Engine ist fertig, Gameplay ist wieder echt. Also nach
        -- einem Finisher-Prompt praktisch sofort zurueckziehen statt eine knappe halbe Sekunde bare zu stehen.
        -- Erkennung ueber den Prompt (Gui_ui2200, crosshair publiziert den Zeitstempel) und NICHT ueber den
        -- RT-Pfad -- an f.RT wird bewusst nichts angefasst, siehe Notiz.
        -- Deckt damit alle drei Ausloeser ab (durchgereichter RT, Flip-Stich-Geste, Links-Klon).
        -- Alle anderen Schranken bleiben: pure Gameplay, Disarm-Gate, Throttle, no_weapons_yet.
        -- [AR-EXPORT 2026-08-18] NUR Zuweisungen, keine Logik. Die Schranken des Restores sind lokale
        -- Felder und von aussen unsichtbar -- ohne sie laesst sich nicht belegen, WARUM er nicht
        -- feuert (Log 15:14: die Engine tauschte im Stagger Messer -> wp4201, danach kam kein
        -- einziger Restore-Aufruf). Der Wegwerf-Watcher liest diese Werte.
        -- [MERCS-LEVELSTART = BARE HANDS 2026-08-18 -- aus dem Log belegt] Ohne das hier stellt der
        -- Restore nach einem Levelwechsel den Snapshot des VORIGEN Levels wieder her: Log 15:23 --
        -- neues Level (F| body=20D67770), 4 s spaeter `requestEquipKnife VON UNS (holster:2097)`,
        -- und der neue Charakter haelt das Messer aus der alten Runde. `ar.snap` ueberlebt den
        -- Wechsel, denn der Restore kennt nur "stelle her, was ich mir gemerkt habe".
        -- Erkennung wie beim Mercs-Dot: der Spieler-Body ist waehrend des Ladens NICHT lesbar; sobald
        -- er wieder da ist, war ein Levelstart. Dann faellt der Snapshot weg -> nichts wird gezogen,
        -- das neue Level beginnt mit leeren Haenden, so wie das Spiel es vorsieht.
        -- NUR IN MERCS -- die Kampagne bleibt unberuehrt.
        if _G.__re4_in_mercs == true then
            local body_da = (get_player_body_go() ~= nil)
            if not body_da then
                merc_body_weg = true                 -- Ladephase, hier nichts zuruecksetzen
            elseif merc_body_weg then
                merc_body_weg = false
                ar.snap, ar.suppress = nil, false    -- neues Level -> nichts wiederherstellen
                _G.__re4_merc_level_bare = (tonumber(rawget(_G, "__re4_merc_level_bare")) or 0) + 1
            end
        end

        _G.__re4_ar_snap      = ar.snap            -- Zustand vor dem Ereignis: wid, false = bare, nil = unbekannt
        _G.__re4_ar_suppress  = ar.suppress        -- bewusst geholstert?
        _G.__re4_ar_inhand    = in_hand_now        -- true = Waffe in der Hand, false = leer, nil = unklar
        _G.__re4_ar_pg        = pg                 -- reines Gameplay?
        _G.__re4_ar_pure_for  = pg and (os.clock() - (ar.pure_since or 0)) or 0
        _G.__re4_ar_stow_left = math.max(0, (ar.stow_until or 0) - os.clock())

        local stable_need = 0.4
        if (os.clock() - (tonumber(rawget(_G, "__re4_finisher_prompt_seen")) or -999)) < 5.0 then
            stable_need = 0.05
        end
        if in_hand_now == false and not ar.suppress and type(ar.snap) == "number"
           and pg and (os.clock() - (ar.pure_since or 0)) >= stable_need
           and os.clock() >= (ar.next_try or 0)
           -- [DISARM-GATE 2026-07-17] NUR nach einem echten Entzug: entweder kamen wir gerade aus NICHT-reinem
           -- Gameplay (KS/Cutscene/Stagger, s. ar.left_pure_t) ODER es laeuft ein Stagger-Fenster. Ein
           -- Leerschiessen/Dry-Fire faellt durch KEINE der beiden -> Restore feuert NICHT, die leere Waffe
           -- bleibt in der Hand. 2.0s Fenster reicht dem Restore (throttle 0.2s) locker zum Nachziehen.
           and ( (os.clock() - (ar.left_pure_t or -999)) < 2.0
                 or (tonumber(_G.__vr_stagger_recent_until) or 0) > os.clock() )
           and not no_weapons_yet() then   -- [NO_WEAPON_STAGES] Start-Stages: Restore AUS, sonst kaempft er jeden Frame gegen den Bare-Hands-Force (Waffe blitzt auf)
            ar.next_try = os.clock() + 0.20   -- throttle: nicht jeden Frame requesten
            local pe = get_pe()
            if pe then
                -- [EIGENER WECHSEL 2026-07-17] wie in __re4_knife_holster_exec: der Restore laeuft ueber
                -- dieselben draw_last_*-Funktionen (requestChangeActiveWeapon -> intern requestChangeWeaponAction)
                -- -> ohne Freifahrt wuerde der KNIFE_KEEP_OUT-Hook den eigenen Restore blocken.
                _G.__re4_our_equip_until = os.clock() + 0.5
                pcall(function() pe:call("clearRequest") end)
                -- GEZIELT die gemerkte Waffe ziehen, nicht requestEquipGun (= "irgendeine Main-Waffe").
                -- Dieselben Bausteine wie ein echter Holster-Zug (inv:equip + requestChangeActiveWeapon).
                if KNIFE_IDS[ar.snap] then
                    _G.__re4_knife_draw_ours_t = os.clock()   -- [ANTI-GHOST] eigener Zug -> nicht zurueckdrehen
                    pcall(function() pe:call("requestEquipKnife") end)
                elseif GRENADE_IDS[ar.snap] then draw_last_grenade(pe)
                elseif SHOULDER_IDS[ar.snap] then draw_last_rifle(pe)
                elseif PISTOL_IDS[ar.snap] then draw_last_pistol(pe)
                else pcall(function() pe:call("requestEquipGun") end) end   -- unbekannte ID -> alter Weg als Fallback
                pcall(function() pe:call("execChangeWeapon") end)
            end
        end
    end
    -- [ANTI-GHOST-KNIFE DEAKTIVIERT 2026-07-20] Das sofortige Wegstecken kaempft gegen die
    -- Engine (sie zieht das Messer bei Trigger-auf-leer sofort wieder) -> sichtbares Flackern.
    -- Bleibt zum Reaktivieren stehen, ist aber komplett inaktiv.
    knife_slot.tick()
    pistol_slot.tick()
    grenade_slot.tick()
    shoulder_slot.tick()
    mag_tick()
    grab_dispatch()
    -- [NO_WEAPON_STAGES] Bare Hands ERZWINGEN, solange es noch keine Waffe geben darf (Start-Stages bis zur
    -- Waffen-Cutscene, dieselben Stages wie das Holster-Gate). REIN ADDITIV: aendert NICHTS an Holster-/
    -- Auto-Redraw-/Grab-Logik. Laeuft ganz am Ende der on_frame (nach grab_dispatch) und drueckt jede von
    -- IRGENDEINEM Script reingezwungene Waffe wieder auf leere Haende. Greift nur, wenn wirklich eine Waffe in
    -- der Hand ist (in_hand_now, Z.1432) -> kein Spam, kein Blitz, kein throttle noetig.
    if no_weapons_yet() and in_hand_now == true then
        local pe = get_pe()
        if pe then
            pcall(function() pe:call("clearRequest") end)
            pcall(function() pe:call("requestEquipBareHand", false, false) end)
            pcall(function() pe:call("execChangeWeapon") end)
        end
    end
end)
-- Pose in ALLEN Render-Paessen frisch pinnen. WICHTIG: gleiche Paesse wie das Movement-Script
-- (das den Spine pinnt und NICHT laggt) -> inkl. UpdateMotion, der vorher FEHLTE.
local function apply_all() knife_slot.apply(); pistol_slot.apply(); grenade_slot.apply(); shoulder_slot.apply() end
local function apply_all_last()   -- letzter Pass: pinnen
    apply_all()
end
pcall(function() re.on_pre_application_entry("LockScene", apply_all) end)
pcall(function() re.on_application_entry("UpdateMotion", apply_all) end)          -- [NO_LAG] fehlte! (Movement hat ihn)
pcall(function() re.on_application_entry("UpdateJointExpression", apply_all) end)
pcall(function() re.on_application_entry("LateUpdateBehavior", apply_all) end)
pcall(function() re.on_pre_application_entry("BeginRendering", apply_all) end)
pcall(function() re.on_application_entry("BeginRendering", apply_all_last) end)

re.on_script_reset(function()
    knife_slot.destroy(); pistol_slot.destroy(); grenade_slot.destroy(); shoulder_slot.destroy()
    character_manager = nil; _pe = nil; pending_action = nil
    _G.__vr_holster_left_chest_rgrip_as_left_grip = false
    _G.__vr_knife_holster_zone = false
    _G.__vr_pistol_holster_zone = false
    _G.__vr_grenade_holster_zone = false
    _G.__vr_shoulder_holster_zone = false
    _G.__vr_in_mag_holster_zone = false
    _G.__vr_bare_hands = false
    _G.__vr_knife_in_hand = false
    _G.__vr_grenade_in_hand = false
    mag_set_holding(false)
end)

-- =====================================================================
-- UI (ein Block pro Slot, gleiche Slider)
-- =====================================================================
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] Zeichenfunktion local function draw_slot_ui (71 Zeilen) raus -- sie hing am geloeschten Tree und wurde nirgends mehr gerufen. Funktionen/Settings unveraendert.

-- Mag-Holster-UI (kein Mesh -> eigener, schlanker Block: Enable, Kalibrieren (linke Hand), Offset, Radius).
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] Zeichenfunktion local function draw_mag_ui (25 Zeilen) raus -- sie hing am geloeschten Tree und wurde nirgends mehr gerufen. Funktionen/Settings unveraendert.

-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - Holster" raus (43 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.


-- =====================================================================
-- [KNIFE-GATE 2026-07-20 -- per Wechsel-Log belegt]
-- PROBLEM: Beim Leerschiessen zieht die ENGINE selbst das Messer (Quick-Knife). Im Wechsel-Log steht
-- ein echter Waffenwechsel "WECHSEL 6112 -> 6108 GUN -> MESSER", KEIN Melee-Angriff -- deshalb hat ein
-- frueherer Versuch ueber execMelee nichts gebracht. Unser RT-Block greift nicht, weil das VR-Framework
-- den echten Controller-Trigger zusaetzlich direkt an die Engine reicht (gleiche Erkenntnis wie beim
-- Fire-Gate: "SHOT von_uns=false").
--
-- LOESUNG: requestEquipKnife abfangen und verwerfen, wenn der Zug NICHT von uns kommt. Unsere eigenen
-- Zuege (Holster-Griff rechts, Links-Draw, Auto-Redraw) markieren sich vorher ueber
-- __re4_knife_draw_ours_t und laufen unveraendert durch.
--
-- ABSICHERUNG:
-- * nur im Gameplay -- in Killswitch/KS4 (Cutscene, Finisher, Skriptszene) NIE eingreifen
-- * nicht, wenn das Messer ohnehin gewollt ist (equippt / Links-Klon / Links-Absicht / Messer-Stage)
-- * nicht waehrend eines Wurfs
-- * Not-Aus jederzeit: _G.__re4_knife_gate = false
-- ACHTUNG: sdk.hook -> erst nach GAME-NEUSTART aktiv.
-- =====================================================================
if not _G.__re4_knife_gate_hook then
    _G.__re4_knife_gate_hook = true
    _G.__re4_knife_gate = true
    pcall(function()
        local td = sdk.find_type_definition("chainsaw.PlayerEquipment")
        if not td then return end
        -- [ALLE_UEBERLADUNGEN 2026-08-06] wie beim Melee-Gate unten: nicht auf get_method
        -- verlassen, sondern jede Ueberladung dieses Namens hooken.
        local targets = {}
        for _, mm in ipairs(td:get_methods() or {}) do
            if mm:get_name() == "requestEquipKnife" then targets[#targets + 1] = mm end
        end
        if #targets == 0 then return end
        local function install(m)
        sdk.hook(m, function()
            local skip = false
            pcall(function()
                if rawget(_G, "__re4_knife_gate") ~= true then return end
                -- eigener Zug? (Holster/Links-Draw/Auto-Redraw setzen den Stempel unmittelbar davor)
                if (os.clock() - (tonumber(rawget(_G, "__re4_knife_draw_ours_t")) or -999)) < 1.0 then return end
                -- Killswitch/KS4: Engine darf machen was sie will
                if _G.__re4_holster_killswitch == true or rawget(_G, "__re4_ks4_active") == true then return end
                if _G.__re4_holster_knife_only == true then return end
                -- Messer ohnehin gewollt / schon da / unterwegs
                if rawget(_G, "__re4_knife_equipped") == true then return end
                if rawget(_G, "__re4_knife_left_clone") == true then return end
                if rawget(_G, "__re4_knife_left_intent") == true then return end
                if rawget(_G, "__re4_knife_flying") == true then return end
                if rawget(_G, "__re4_clone_finisher_restore") == true then return end
                skip = true
            end)
            if skip then
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end, function(r) return r end)
        end
        for _, m in ipairs(targets) do
            install(m)
        end
    end)
end

-- =====================================================================
-- [MELEE-GATE 2026-07-22] ZWEITER Weg, auf dem das Messer erscheint
-- =====================================================================
-- BEWEIS (re4_zzz_wswitch.log, 22:23:16 -- Volltrace mit Argumenten und Pad-Zustand):
-- requestEquipMelee (0) | von: NATIV | equip=4501 rt_raw=true | PAD RT=1.00
-- execChangeWeapon | von: NATIV | equip=4501 rt_raw=true | PAD RT=1.00
-- equipWeapon (0, 5001,...) <- Messer
-- Das Knife-Gate darueber hookt requestEquipKnife und konnte hier deshalb NIE greifen: der
-- Quick-Knife laeuft ueber requestEquipMelee. Genau der Call wird hier verworfen -- mit
-- demselben Guard-Satz wie oben, plus einer zusaetzlichen Ausnahme:
-- * NAHKAMPF-PROMPT: liegt ein Finisher-/Nahkampf-Prompt an, ist der Melee GEWOLLT -> nie blocken.
-- (Das ist die Falle vom 2026-07-21: eine pauschale RT-Sperre hat den Nahkampf-Prompt lahmgelegt.)
-- * Killswitch/KS4 (Cutscene, Finisher, Skriptszene): Engine darf machen was sie will.
-- * eigener Messerzug (__re4_knife_draw_ours_t), Messer schon da / Links-Klon / Links-Absicht /
-- Wurf unterwegs / Finisher-Restore / Messer-only-Stage -> unberuehrt.
-- Not-Aus jederzeit: _G.__re4_melee_gate = false
-- ACHTUNG: sdk.hook -> erst nach GAME-NEUSTART aktiv.
-- =====================================================================
if not _G.__re4_melee_gate_hook then
    _G.__re4_melee_gate_hook = true
    _G.__re4_melee_gate = true
    pcall(function()
        local td = sdk.find_type_definition("chainsaw.PlayerEquipment")
        if not td then return end
        -- [ALLE_UEBERLADUNGEN 2026-08-06] Frueher: td:get_method("requestEquipMelee") -- ohne
        -- Signatur. Der Call, der das Messer bringt, hat aber einen Parameter (Trace: "requestEquipMelee (0)").
        -- Haengt der Hook an der falschen Ueberladung, feuert das Gate NIE und der Guard ist wertlos.
        -- Deshalb: jede Methode dieses Namens hooken, egal welche Signatur.
        local targets = {}
        for _, mm in ipairs(td:get_methods() or {}) do
            if mm:get_name() == "requestEquipMelee" then targets[#targets + 1] = mm end
        end
        if #targets == 0 then return end
        local function install(m)
        sdk.hook(m, function()
            local skip = false
            pcall(function()
                if rawget(_G, "__re4_melee_gate") ~= true then return end
                -- gewollter Nahkampf: Prompt liegt an -> durchlassen
                if type(rawget(_G, "__re4_is_finisher_prompt")) == "function"
                   and _G.__re4_is_finisher_prompt() == true then return end
                -- eigener Zug (Holster/Links-Draw/Auto-Redraw setzen den Stempel unmittelbar davor)
                if (os.clock() - (tonumber(rawget(_G, "__re4_knife_draw_ours_t")) or -999)) < 1.0 then return end
                -- Killswitch/KS4: nicht eingreifen
                if _G.__re4_holster_killswitch == true or rawget(_G, "__re4_ks4_active") == true then return end
                if rawget(_G, "__re4_ks_active") == true then return end
                if _G.__re4_holster_knife_only == true then return end
                -- Messer ohnehin gewollt / schon da / unterwegs
                if rawget(_G, "__re4_knife_equipped") == true then return end
                if rawget(_G, "__re4_knife_left_clone") == true then return end
                if rawget(_G, "__re4_knife_left_intent") == true then return end
                if rawget(_G, "__re4_knife_flying") == true then return end
                if rawget(_G, "__re4_clone_finisher_restore") == true then return end
                skip = true
            end)
            if skip then
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end, function(r) return r end)
        end
        for _, m in ipairs(targets) do
            install(m)
        end
    end)
end
