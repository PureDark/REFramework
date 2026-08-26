-- Builtin implementation: src/mods/vr/games/re4/RE4VRReload.cpp
return
-- =====================================================================
-- [RACK-DIAG 2026-07-21 ENTFERNT] Das globale __re4_rkdiag (re4_rack_diag.log) ist raus -- es schrieb
-- ueber KSQUELLE/INHAND/RESTORE dauerhaft 1-2 io.open pro Sekunde und kostete FPS. Wer es zur Analyse
-- zurueckholt: others/re4_vr_reload.bak_2026-07-21_pre_diagclean.
-- RE4 VR MANUAL RELOAD — Portierung von re9_vr_reload.lua
-- =====================================================================
-- Struktur 1:1 nach RE9: Master-Toggle + per-Waffengattung-Toggle
-- (Pistolen / SMG / Shotguns / Magnum / Rifles), an dem ALLES fuer die
-- jeweilige Gattung haengt. RE9-Logik je Gattung wird stufenweise
-- nachgezogen; aktuell implementiert: PISTOLEN — Mag-Drop.
--
-- Mag-Drop (RE9-Mechanik 1:1):
-- * Rechter B-Knopf wird im BINDING abgefangen (re4_vr_binding.lua setzt
-- r_bbutton=false, solange _G.__vr_manual_reload_consume_b gesetzt ist)
-- -> Gamepad-X (= Reload) kommt nie beim Spiel an -> kein nativer Reload.
-- Genau wie RE9 (dort konsumiert das Binding den B-Knopf).
-- * Wir lesen B direkt (vrmod) fuer die Trigger-Flanke und droppen das
-- Magazin im Welt-Raum: t = elapsed/drop_duration (clamp 1),
-- fall = drop_distance * t*t, joint:set_Position(sx, sy - fall, sz)
-- (Schreiben in LateUpdateBehavior, sonst clobbert die Engine-Pose).
--
-- Joints pro Pistole (visuell identifiziert): wp4004 Mag=_14, Slide=_01.
-- Andere Pistolen per UI eintragen (Cycler-Probe).
--
-- NAECHSTE STUFEN (RE9 abschauen): Slide-Rack, Grip-Distanz-Zonen,
-- Mag-Holster + Mag-in-Hand-Spawn, Knife-Block, Reload-Mathematik
-- (Ammo via chainsaw.WeaponItem.addAmmoCount), Haptik, Sounds; dann SMG/
-- Shotgun/Magnum/Rifle als eigene Gattungs-Zweige.
-- =====================================================================

local CFG_PATH = "re4_vr/re4_vr_reload.json"

-- [SAFE_GIBT_IMMER_EINEN_WERT 2026-07-31, -Screenshot reload.png] Vorher endete diese Funktion im
-- Fehlerfall OHNE return -> sie lieferte gar keinen Wert (nicht nil, NICHTS). In einem Aufruf wie
-- tostring(safe(...)) kommt dann kein Argument an: "bad argument #1 to 'tostring' (value expected)",
-- und der ganze umgebende Aufruf bricht ab. Genau daran ist der Bogen gestorben (reload.lua:424 aus
-- reload2.lua:3699 'xadd_one' -> seine get_WeaponId ist nicht lesbar, pcall schlaegt fehl, safe liefert
-- nichts, __re4_safe_inv_reload stirbt VOR dem Laden). Das explizite `return nil` macht den Rueckgabewert
-- eindeutig; im Erfolgsfall aendert sich nichts.
local function safe(fn) local ok, r = pcall(fn); if ok then return r end return nil end

-- =============================================================================================
-- [ACCESSOR 2026-08-12] DIE EINZIGE PERSISTENTE WeaponItem-INSTANZ -- zentral, fuer ALLE Dateien.
-- =============================================================================================
-- Live gemessen: `getEquipWeaponItem`, `getEquippedWeapon` und die Zeilen aus
-- `getInventoryItemList` liefern bei JEDEM Aufruf eine frische KOPIE (Adresse springt pro Tick,
-- @pe als Kontrolle steht still). Schreiben darauf wirkt im selben Tick und ist danach WEG --
-- das ist der Grund, warum jahrelang jede Buchung "verpuffte" und nur der native
-- CsInventoryController.reload lud (der beim Bogen zuverlaessig crasht).
-- Einzig `pe:getEquipWeaponAccessor()` (chainsaw.CsInventoryItem) ist stabil und haelt in
-- `<Item>k__BackingField` das ECHTE chainsaw.WeaponItem -> dort wirkt setAmmoCount/addAmmoCount
-- sofort, das HUD folgt im selben Tick. Details: [[reference_re4_echte_weaponitem_instanz]]
--
-- BEWUSST GLOBAL und selbstversorgend (holt sich PlayerEquipment selbst, statt auf ein lokales
-- get_pe zu bauen): reload2/3/5 haben je eigene Beschaffungsfunktionen, und in weapons2 war ein
-- lokales `get_pe` an der Aufrufstelle nicht sichtbar -> "global 'get_pe' is not callable".
-- Eine Implementierung statt neun Kopien.
--
-- want_wid (optional): nur zurueckgeben, wenn der Accessor DIESE Waffe traegt. Beim Waffenwechsel
-- kann er kurz noch die alte halten.
-- RUECKBAU: _G.__re4_use_accessor_item = false  -> jede Beschaffung faellt auf ihren alten Weg.
-- =============================================================================================
_G.__re4_real_wi = function(want_wid)
    if rawget(_G, "__re4_use_accessor_item") == false then return nil end

    local pe, pe_ok = rawget(_G, "__re4_rw_pe"), false
    if pe ~= nil then
        local o, v = pcall(function() return pe:call("get_Context") end)
        pe_ok = (o == true and v ~= nil)
    end
    if not pe_ok then
        pe = nil
        local td = rawget(_G, "__re4_rw_td")
        if td == nil then
            local o, v = pcall(function() return sdk.typeof("chainsaw.PlayerEquipment") end)
            if o then td = v; _G.__re4_rw_td = v end
        end
        local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
        if cm and td then
            local o1, ctx = pcall(function() return cm:call("getPlayerContextRef") end)
            if o1 and ctx then
                local o2, head = pcall(function() return ctx:call("get_HeadGameObject") end)
                if o2 and head then
                    local o3, v = pcall(function() return head:call("getComponent(System.Type)", td) end)
                    if o3 then pe = v end
                end
            end
        end
        _G.__re4_rw_pe = pe
    end
    if pe == nil then return nil end

    local o4, acc = pcall(function() return pe:call("getEquipWeaponAccessor") end)
    if not o4 or acc == nil then return nil end
    local o5, real = pcall(function() return acc:call("get_Item") end)
    if not o5 or real == nil then return nil end
    local o6, amm = pcall(function() return real:call("get_CurrentAmmoCount") end)
    if not o6 or amm == nil then return nil end

    if want_wid ~= nil then
        local o7, w = pcall(function() return real:call("get_WeaponId"):get_field("value__") end)
        if o7 and type(w) == "number" and w ~= want_wid then return nil end
    end
    _G.__re4_acc_hit = (tonumber(rawget(_G, "__re4_acc_hit")) or 0) + 1
    return real
end
local function sc(o, m, ...) if not o then return nil end local a = {...}
    local ok, r = pcall(function() return o:call(m, table.unpack(a)) end); return ok and r or nil end
local function sf(o, n) if not o then return nil end local ok, r = pcall(function() return o:get_field(n) end); return ok and r or nil end
-- Produktiv-Logging ENTFERNT. Die gesamte Diagnose lebt in re4_vr_reload_diag.lua,
-- ENTFERNT 2026-08-15: auch der State-Export (publish_dbg / _G.__re4_reload_dbg) ist raus,
-- das zugehoerige Diag-Script existiert nicht mehr. rlog bleibt als No-Op stehen.
local function rlog(_) end

local function ease(t) return t * t * (3.0 - 2.0 * t) end   -- smoothstep

-- Quaternion aus Euler-Grad (Quaternion.new ist W,X,Y,Z)
local function quat_from_euler(rx, ry, rz)
    local hx, hy, hz = math.rad(rx) * 0.5, math.rad(ry) * 0.5, math.rad(rz) * 0.5
    local qx = Quaternion.new(math.cos(hx), math.sin(hx), 0, 0)
    local qy = Quaternion.new(math.cos(hy), 0, math.sin(hy), 0)
    local qz = Quaternion.new(math.cos(hz), 0, 0, math.sin(hz))
    return qz * qy * qx
end

-- =====================================================================
-- Konfiguration
-- =====================================================================
local CFG = {
    enabled         = true,   -- Master
    pistols_enabled = true,
    smgs_enabled    = true,
    shotguns_enabled= true,
    magnum_enabled  = true,
    rifles_enabled  = true,
    -- Mag-Drop: freier Fall mit Gravitation (Welt-Einheiten/s^2)
    gravity         = 9.8,
    -- Hand-Pose (gestures.lua) waehrend das Mag in der linken Hand ist
    mag_hold_pose   = "MAG",
    -- (Daumen-Abspreizung ist jetzt PRO WAFFE in MAGHAND[wid].t_rx/t_ry/t_rz)
    -- Mag-Insert (Slide-in von der Hand in die Kammer)
    insert_dur      = 0.18,
    insert_distance = 0.15,   -- ab dieser Hand->Waffe-Distanz (m) snappt das Mag in die Kammer
    -- [INSERT-PUNCH 2026-07-21, "Mag soll reingehaemmert wirken, nicht locker fluffig reinfliegen"]
    -- REIN OPTISCH/HAPTISCH -- Ammo-Reload, Rack-Logik und Slide-Lock feuern unveraendert im selben Frame
    -- wie vorher (Ende der Einschub-Phase). Danach laeuft nur noch eine kurze Nachfeder-Bewegung.
    insert_punch    = true,   -- Ease-in (beschleunigt bis zum Anschlag) statt Smoothstep (weiches Auslaufen)
    insert_overshoot= 0.005,  -- m, wie weit das Mag UEBER die Ruhelage hinaus in den Schacht faehrt
    insert_settle   = 0.07,   -- s, Rueckfedern aus dem Overshoot in die Ruhelage
    insert_haptic   = 0.85,   -- Amplitude des Einrast-Pulses (0 = aus)
    -- [SND-TIMING 2026-07-21, "der Klack kommt ein kleines bisschen zu spaet"] Ab welchem Fortschritt
    -- der Einschub-Phase (0..1) der Einrast-Sound startet. War hart auf 0.90 -- weil der Sound selbst eine
    -- Anlaufzeit hat, hoerte man ihn erst NACH dem Aufschlag. Kleiner = frueher. Slider statt Konstante,
    -- damit du es am Desktop nachziehen kannst (in VR ist ImGui nicht lesbar).
    insert_snd_at   = 0.80,
    -- [MANUAL_INSERT 2026-08-15] Mag NICHT auf einer Zeitbahn einfahren lassen, sondern selbst
    -- mit dem Controller bis zum Anschlag hochschieben. Der Weg ist derselbe wie bisher (Andock-
    -- punkt -> Ruhelage), nur der Fahrparameter kommt aus der HAND statt aus der Uhr -- deshalb
    -- laesst er sich auch wieder zurueckziehen. Faehrt er hinter den Andockpunkt, liegt das Mag
    -- wieder in der Hand wie vorher.
    -- Gemessen wird am HANDABSTAND (linke Hand <-> rechte Hand), nie gegen Waffe oder Weltanker:
    -- laeuft/dreht man sich, wandern beide Haende mit und der Fortschritt bleibt stehen.
    insert_manual   = true,   -- Master fuer den Handschub (aus = alles exakt wie vorher, Zeitbahn)
    -- Eigene Sound-Schwelle fuer den Handschub. insert_snd_at (0.80) gilt weiter fuer die Zeitbahn --
    -- dort ist die Bahn ease-in, 0.80 der ZEIT liegt also schon dicht am Anschlag. Beim Handschub ist
    -- t die reine STRECKE, da waeren 0.80 woertlich 80 Prozent des Wegs: der Klack kaeme auf halber Hoehe.
    -- Im Handschub gibt es KEINE Sound-Schwelle mehr: der Klack haengt am tatsaechlichen Einrasten
    -- (t >= 1 im Abschluss). Jede Schwelle davor laesst sich wieder zurueckziehen -- dann klingt es,
    -- obwohl nichts eingerastet ist. insert_snd_at oben gilt unveraendert fuer die Zeitbahn.
    -- [WEG RELATIV 2026-08-15] Der Handweg ist KEIN absoluter Meterwert mehr. Gemessen wird der
    -- Abstand Hand -> Ladepunkt, und angedockt wird schon bei insert_distance (z.B. 0.237 m). Ein
    -- fester Weg von 0.09 m hiess: nach 9 cm Annaeherung ist der Schub fertig, obwohl die Hand noch
    -- 15 cm vom Schacht weg ist -- das Mag sprang hinein. Jetzt ist es ein ANTEIL der Strecke, die
    -- beim Andocken tatsaechlich noch vor dir liegt: 0.85 = eingerastet, wenn 85 Prozent davon
    -- zurueckgelegt sind. Passt damit automatisch zu jeder Waffe und jeder Andock-Distanz.
    insert_travel   = 0.09,
    -- [SELBST-EINRASTEN 2026-08-16] Ab diesem Anteil des Weges rastet das Magazin von SELBST
    -- ein -- die letzten Prozent macht die Bahn allein. 1.00 = aus (wie bisher, ganz bis zum
    -- Anschlag schieben). 0.90 = die letzten 10 %% laufen automatisch.
    -- Warum das hilft: die Hand faehrt zum Schluss einen Bogen, die Restbewegung liegt also
    -- immer schraeger zur Schachtachse und traegt kaum noch zum Fortschritt bei -- genau
    -- dort fuehlt es sich zaeh an.
    -- Wirkt NUR im Handschub; die Zeitbahn laeuft ohnehin bis 1.0 durch.
    insert_snap_at  = 0.80,   -- m Handweg vom Andocken bis zum Einrasten
    insert_back_out = 0.02,   -- m Rueckweg HINTER den Andockpunkt -> Mag wieder in die Hand
    insert_redock   = 0.01,   -- m, die man danach wieder vorschieben muss, damit es neu andockt
    reload_ammo     = true,   -- beim Insert echten Ammo-Reload ausfuehren (Mag fuellen + Reserve abziehen)
    -- [NO_NATIVE_RELOAD 2026-07-31] AUS = der native chainsaw.CsInventoryController.reload wird NIE
    -- gerufen (die Quelle aller Reload-Vollcrashes). Geladen wird direkt am Laufzeit-Gun-Item, die Reserve
    -- per reduceCount. NUR einschalten, wenn eine Waffe nachweislich nicht mehr laedt -- dann kann sie
    -- wieder crashen. Zaehler dazu stehen im Reload-Tree ganz oben.
    -- [BEIDE SCHALTER AUSGEBAUT 2026-08-01, "du machst den bloeden Toggle auch raus"]
    -- `native_reload_fallback` und `exec_reload_all` gibt es nicht mehr. Der Ladeweg ist jetzt fest:
    -- volles Magazin -> pe:execReload (Engine laedt + zieht Reserve)
    -- Teilmenge -> Weg C, der Nachbau (addAmmoCount auf __re4_live_wi + reduceCount)
    -- Kein nativer chainsaw.CsInventoryController.reload mehr, an keiner Stelle, unter keiner Bedingung.
    -- Slide-Rack (RE9-Muster): leer -> RT blockiert bis nachgeladen UND Slide gerackt
    rack_enabled    = true,   -- Empty-Block + Slide-Rack-Pflicht an
    rack_grab_dist  = 0.18,   -- linke Hand muss so nah an den Slide-Joint zum Grabben (hardcoded)
    rack_pull_dist  = 0.09,   -- (unbenutzt seit 1:1-Zug; Zug-Weg = Slide-Travel)
    -- [PUMP_START_PULL 2026-07-31, "Shotgun ist steif obwohl ich nur halte"] Ab wie viel
    -- Rueckweichung (m, gun-relativ) der Pump-Grab startet. War hart 0.04 -> beim blossen Halten mit
    -- ausstehendem Pump reichten 4 cm Handwandern, um grab_active (= __vr_slide_rack_active) zu setzen
    -- -> motion friert die Waffe ein, obwohl gar nicht gepumpt wurde. Jetzt Slider (Reload-Tree ->
    -- Shotgun-Pump): hochdrehen, bis nur noch ein echter Zug ausloest.
    pump_start_pull = 0.04,
    -- [RE9_PUMP 2026-08-12] Wieviel vom gezogenen Weg muss zurueckgeschoben werden, damit der Pump
    -- als fertig gilt (Anteil des Slide-Travels, mind. 3 cm). RE9 hat dafuer eine eigene
    -- Push-Distanz; bei uns relativ, damit es zum Travel der Waffe passt.
    pump_push_frac = 0.5,
    rack_haptic     = true,   -- Haptik-Puls beim Rack
    rack_pose       = "rack-slide",  -- LINKE-Hand-Pose beim Slide-Grab (gestures.lua)
    -- [RACK_POSE_ANGLE 2026-07-31] NUR PISTOLEN: zwei Rack-Posen, je nachdem aus welcher Richtung
    -- die linke Hand beim Greifen an die Waffe kommt. Gemessen wird SLIDE-LOKAL in der XZ-Ebene
    -- (Y/hoch-runter egal, Waffenlage im Raum egal): 0 Grad = genau von HINTEN, 90 Grad = genau von der
    -- SEITE. Unter der Schwelle -> rack_pose (die bisherige globale), darueber -> rack_pose_side.
    -- Der Winkel ist seitenneutral (|x|), es zaehlt also "seitlich", nicht "links oder rechts".
    rack_pose_side     = "MAGRack",  -- Pose bei seitlicher Annaeherung
    rack_pose_side_deg = 45,         -- ab wie viel Grad gilt die Annaeherung als "von der Seite"
    -- [SND] Eigene Waffen-Sounds (SoundContainer-Trigger)
    sound_enabled   = true,   -- Mag/Slide/DryFire-Sounds abspielen
    mag_floor_delay = 0.45,   -- Verzoegerung (s) bis der Mag-Boden-Aufprall-Sound kommt
    -- [SHOTGUN] Shell-Reload-Verhaeltnis: 1 Einfuehrbewegung laedt so viele Shells (1=1:1, 2=1:2). Default 1:2.
    shotgun_ratio   = 2,
    pump_haptic_delay = 0.0,  -- [SHOTGUN PUMP] Delay (s) der Pump-Haptik (hin/zurueck) -> aufs Audio legbar
}

-- Mag-in-Hand Pose pro Waffe (Offset im Hand-Frame + Rotation in Grad + Daumen-Abspreizung t_*)
local MAGHAND = {}
local function maghand(wid)
    local m = MAGHAND[wid]
    if not m then
        m = { x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = 0, t_rx = 0, t_ry = 0, t_rz = 0 }
        MAGHAND[wid] = m
    end
    return m
end

-- Slide-Rack-Zustand (RE9-Muster): needs=true sperrt das Feuern bis gerackt.
-- Wird gesetzt sobald das Magazin leer ist, NUR durch die Rack-Geste geloescht.
local rack = { needs = false, grab_active = false, armed = false, gx = 0, gy = 0, gz = 0, frac = 0, pulled = false,
               pushed = false,                    -- [SHOTGUN PUMP] nach vollem Zug wieder nach vorn geschoben (RE9-Modell: HER-Sound)
               has_mag = false,                  -- Mag drin? (Slide -0.015) vs leer (Slide -0.060)
               empty = false,                     -- [EMPTY_SLIDE] Waffe LEER (loaded<=0, frisch) -> Slide hinten, schon VOR dem Mag-Drop
               empty_when_dropped = false,        -- war die Waffe beim Drop LEER? -> Rack noetig nach Reload
               tuning = false, tune_frac = 0,    -- tuning = UI-Vorschau der Slide-Pose
               dock_tune = false,                -- Hand-Pose-Einstellmodus: Hand ans Slide-Dock zwingen (ohne Reload-Zyklus)
               dock_blend = 0,                   -- [DOCK_LERP] 0..1 Blend der Hand zum Slide-Dock (sanft hin/weg)
               _last_grip = false, _last_dist = -1 }   -- fuer Diag-Export

-- [SHELL_EJECT] W-870-Spass: Shell aus dem geoeffneten Chamber werfen. Start = Chamber-Position
-- (per-Waffe Offset von der _04-Shell-Ruhepose), danach Flug (spaeter). SCHRITT 1: nur die
-- Startposition tunen (Preview-Toggle haelt die Shell an der Offset-Stelle).
-- sx/sy/sz/srx/sry/srz = Chamber-Startposition (Offset von _04-Ruhepose, lokal).
-- vx/vy/vz = Abschuss-Geschwindigkeit (lokal, m/s; vx=rechts), grav = Fallbeschleunigung (lokal -Y),
-- dur = Flugdauer (s), spin = Taumel-Rotation (Grad/s um lokales X).
local SHELL_EJECT = {}   -- [wid] = { sx,sy,sz, srx,sry,srz, vx,vy,vz, grav,dur,spin }
local SHELL_EJECT_DEF = { sx=0.0, sy=0.0, sz=0.0, srx=0.0, sry=0.0, srz=0.0,
                          vx=0.8, vy=0.5, vz=0.0, grav=4.0, dur=0.7, spin=540.0 }
local function shell_eject_cfg(wid)
    local s = SHELL_EJECT[wid]
    if not s then s = {}; for k,v in pairs(SHELL_EJECT_DEF) do s[k]=v end; SHELL_EJECT[wid] = s end
    return s
end
local shell_eject = { preview = false, flying = false, t = 0.0, last_clock = 0.0, _prev_pulled = false }
-- [SHOTGUN] Z-Offset von der _04-Shell-Ruhepose zum CHAMBER-Port (lokal, Waffen-Frame). Wird sowohl
-- fuer die Insert-Distanz (Hand->Chamber) ALS AUCH das Insert-ZIEL (Shell gleitet in den Port) genutzt.
local SHOTGUN_CHAMBER_Z = { [4100] = -0.093, [4101] = 0.0, [4102] = -0.093, [6001] = -0.093 }   -- W-870/Striker/Skull Shaker = -0.093 unter _04. Riot Gun = exakt _04-Position. (alle tunen)
-- [DOCK-PORT PRO WAFFE] Exakter Andock-Spot fuers Mag/Shell-Einlegen = LIVE-Weltpos eines FESTEN
-- Gun-Joints (bewegt sich NICHT mit der Hand) + Offset in dessen lokalem Z. Der Insert-Proximity misst
-- Hand->diesen Punkt (statt Hand->Griff). { joint = Name, z = Offset }.
local DOCK_PORT = {
    [4202] = { joint = "_03", z = 0.087 },    -- LE 5: Mag-Andock-Spot = joint_03 + Z +0.087
    [4102] = { joint = "_03", x = -0.020, y = 0.026, z = 0.016 },   -- Striker: Shell-Einlegepunkt = joint_03 + Offset (-gemessen 2026-07-24, genau wo die Shell reinkommt)
    [6001] = { joint = "_03", x = 0.021, z = 0.055 },   -- Skull Shaker: Shell-Einlegepunkt = joint_03 + X 0.021 / Z 0.055 (etwas weiter vorn)
}
-- [LEVER_PORT] Exakter GREIF-Punkt fuer den Break-Action-Hebel (linke Hand). Gun-Joint + Offset in
-- dessen lokalem Z. Sonst misst der Greif-Gate Hand->joint_02-Ursprung (zu weit). { joint, z }.
local LEVER_PORT = {
    [6001] = { joint = "_01", z = 0.0 },   -- Skull Shaker: Hebel-Greifpunkt = joint_01 (Live-Weltpos)
}

-- [CHAMBER] Top-Loader-Zustand (Red9): die Waffe hat kein Magazin, sondern einen Chamber,
-- den der rechte B-Knopf auf-/zuschiebt (Joint in Z verschieben). open=true -> offen.
-- base = einmal (im geschlossenen Zustand) erfasste Ruhe-LocalPosition des Chamber-Joints.
local chamber = { open = false, blend = 0.0, base = nil, base_joint = nil }

-- [DOCK_LERP] Ramp-Schritt pro Frame fuer das Hand->Slide-Andocken (linear, dann
-- smoothstep-geglaettet). 1:1 aus RE9 (re9_vr_reload_advanced DOCK_BLEND_SPEED).
local DOCK_BLEND_SPEED = 0.10
-- Slide-Rack-Posen HARDCODED pro Pistole als ABSOLUTE lokale Z (wie RE9 SLIDE_BIND_POSE).
-- KEINE Laufzeit-Erfassung -> keine kumulative Drift bei Reset Scripts.
-- rest_z = gechambered/Ruhe (Slide vorne)
-- park_z = Mag drin, noch nicht gerackt (leicht hinten)
-- back_z = leer / Rack-Endpunkt (voll hinten)
-- dock_x/y/z = Versatz der LINKEN Hand relativ zum Slide-Joint (lokales Slide-Frame),
-- damit die Hand am Slide GREIFT statt daneben zu haengen. Per Feedback justiert.
-- rack_rx/ry/rz = Rotations-Offset (Grad) der LINKEN Hand relativ zur Slide-Rotation
-- waehrend des Grabs -> feste, tunebare Hand-Pose (steif, folgt nicht dem Controller).
local SLIDE_POSE = {
    [4004] = { rest_z = 0.06174, park_z = 0.04674, back_z = 0.03174, dock_x = 0.0, dock_y = 0.0, dock_z = 0.0, rack_rx = 0.0, rack_ry = 0.0, rack_rz = 0.0 },   -- Matilda (_01)
    [4001] = { rest_z = 0.10042, park_z = 0.08542, back_z = 0.06042, dock_x = 0.045, dock_y = 0.032, dock_z = -0.192, rack_rx = 53.7, rack_ry = 285.7, rack_rz = -86.1 },   -- Punisher: ZU/rest_z=0.10042 LIVE ausgelesen. Slide-Greif-Handpose (dock/rack) wiederhergestellt. park/back grobe Startwerte
    -- [PORT 2026-06-15] 1:1 von Punisher (4001) uebernommen -> per Waffe noch visuell nachtunen
    [4000] = { rest_z = 0.10042, park_z = 0.08542, back_z = 0.06042, dock_x = 0.045, dock_y = 0.032, dock_z = -0.192, rack_rx = 53.7, rack_ry = 285.7, rack_rz = -86.1 },   -- SG-09 R (Punisher-Startwerte)
    [4003] = { rest_z = 0.10042, park_z = 0.08542, back_z = 0.06042, dock_x = 0.045, dock_y = 0.032, dock_z = -0.192, rack_rx = 53.7, rack_ry = 285.7, rack_rz = -86.1 },   -- Blacktail (Punisher-Startwerte)
    [6000] = { rest_z = 0.10042, park_z = 0.08542, back_z = 0.06042, dock_x = 0.045, dock_y = 0.032, dock_z = -0.192, rack_rx = 53.7, rack_ry = 285.7, rack_rz = -86.1 },   -- Sentinel Nine DLC (Punisher-Startwerte)
    [4501] = { rest_z = 0.10042, park_z = 0.08542, back_z = 0.06042, dock_x = 0.045, dock_y = 0.032, dock_z = -0.192, rack_rx = 53.7, rack_ry = 285.7, rack_rz = -86.1 },   -- Killer7 (Punisher-Startwerte -> per Slider nachtunen)
    -- [MC_6300 2026-08-04] XM96E1 (Mercenaries). rest_z NICHT von der Punisher geerbt:
    -- die geerbten 0.10042 hielten den Slide sichtbar 3.5 cm zu weit vorne (Log re4_slide_z_diag.log,
    -- d_rest konstant 0.00000 auf 0.10042). Gemessen wurde 0.06542 -- der Wert, den der Joint in dem
    -- einen Frame nach dem Script-Reset zeigte, bevor unser Halt griff (dmg/reload/shoot alle 0).
    -- park/back mit denselben Abstaenden wie bei der Punisher (rest-0.015 / rest-0.04).
    -- Dock/rack-Werte bleiben Punisher-Startwerte (Handpose, nicht Slide-Geometrie).
    [6300] = { rest_z = 0.06542, park_z = 0.05042, back_z = 0.02542, dock_x = 0.045, dock_y = 0.032, dock_z = -0.192, rack_rx = 53.7, rack_ry = 285.7, rack_rz = -86.1 },   -- XM96E1 (MC)
    -- [MC_6301 2026-08-15] Blacktail AC (Mercenaries) -- baugleich zu Leons Blacktail (4003),
    -- deshalb 1:1 deren Werte als Start. Bei Bedarf ueber den Slide-Tree nachziehen.
    [6301] = { rest_z = 0.10042, park_z = 0.08542, back_z = 0.06042, dock_x = 0.045, dock_y = 0.032, dock_z = -0.192, rack_rx = 53.7, rack_ry = 285.7, rack_rz = -86.1 },   -- Blacktail AC (MC) <- 4003
    [4002] = { rest_z = 0.10042, park_z = 0.08542, back_z = 0.06042, dock_x = 0.045, dock_y = 0.032, dock_z = -0.192, rack_rx = 53.7, rack_ry = 285.7, rack_rz = -86.1 },   -- Red9 (Punisher-Startwerte; EXOTISCH: Top-Fill, kein _14-Mag -> alles nachtunen)
    -- [SMG PORT 2026-06-15] 1:1 von Punisher (4001) -> anpassen
    [4200] = { rest_z = -0.07458, park_z = -0.07458, back_z = -0.10500, dock_x = 0.045, dock_y = 0.032, dock_z = -0.192, rack_rx = 53.7, rack_ry = 285.7, rack_rz = -86.1 },   -- [TMP _09 2026-07-20 -- gemessen] Ruhe (Slide ZU) = -0.07458. Die TMP hat KEIN Hold-Open: der Slide steht auch bei leerer Waffe vorne, deshalb park_z = rest_z. Rack = kurzer Zug nach hinten (back_z) und wieder vor. rest_z war vorher 0.10042 -- falsch vom Punisher geerbt.
    [4201] = { rest_z = 0.10042, park_z = 0.08542, back_z = 0.06042, dock_x = 0.045, dock_y = 0.032, dock_z = -0.192, rack_rx = 53.7, rack_ry = 285.7, rack_rz = -86.1 },   -- Chicago Sweeper
    [4202] = { rest_z = 0.10042, park_z = 0.08542, back_z = 0.06042, dock_x = 0.045, dock_y = 0.032, dock_z = -0.192, rack_rx = 53.7, rack_ry = 285.7, rack_rz = -86.1 },   -- LE 5
    -- [SHOTGUN 2026-06-17] W-870 (4100): "slide" = PUMP-Joint _01. rest_z=vorn/gechambert=0.425 (LIVE
    -- aus re4_shotgun_pump.log: Idle-_01-Z), back_z/park_z = Pump-Zugweg fuer das MANUELLE Pumpen
    -- (Startwerte, per Shotgun-UI live nachtunen). Native AfterShoot dippte auf ~0.34.
    [4100] = { rest_z = 0.42500, park_z = 0.42500, back_z = 0.30000, dock_x = 0.0, dock_y = 0.0, dock_z = 0.0, rack_rx = 0.0, rack_ry = 0.0, rack_rz = 0.0 },   -- W-870 Pump (_01)
    [4101] = { rest_z = 0.42500, park_z = 0.42500, back_z = 0.30000, dock_x = 0.0, dock_y = 0.0, dock_z = 0.0, rack_rx = 0.0, rack_ry = 0.0, rack_rz = 0.0 },   -- Riot Gun Pump (_01) — Kopie W-870, rest/travel spaeter tunen
    [4102] = { rest_z = 0.42500, park_z = 0.42500, back_z = 0.30000, dock_x = 0.0, dock_y = 0.0, dock_z = 0.0, rack_rx = 0.0, rack_ry = 0.0, rack_rz = 0.0 },   -- Striker Pump — Kopie W-870, rest/travel + Joints spaeter tunen
    [6001] = { rest_z = 0.42500, park_z = 0.42500, back_z = 0.30000, dock_x = 0.0, dock_y = 0.0, dock_z = 0.0, rack_rx = 0.0, rack_ry = 0.0, rack_rz = 0.0 },   -- Skull Shaker — slide=_02 ist LEVER (Pitch, kein Z); Z-Werte Platzhalter bis Break-Action-Logik
}
-- [POSE2_OFFSETS 2026-07-31] ZWEITER Offset-Satz (sdock_*/srack_*) = die SEITEN-Pose beim
-- Slide-Rack (MAGRack). Bisher gab es nur EINEN Satz pro Waffe, den sich beide Posen teilen mussten --
-- deshalb klebte die Default-Pose mit dem Versatz der MAG-Pose an der Waffe. Nur Pistolen werten den
-- zweiten Satz aus (s. apply_slide_dock); rest_z/park_z/back_z bleiben bewusst EINFACH: das ist der
-- Slide-WEG der Waffe, keine Eigenschaft der Handpose.
-- Startwerte belegt: Pose 1 (von hinten) = Punisher-Werte, Pose 2 (seitlich) = Blacktail-Werte.
local SLIDE_POSE_DEFAULT = { rest_z = 0.06174, park_z = 0.04674, back_z = 0.03174,
    dock_x  = 0.0,   dock_y  = 0.0,   dock_z  = 0.0,   rack_rx  = 0.0, rack_ry  = 0.0,   rack_rz  = 0.0,
    sdock_x = 0.077, sdock_y = -0.008, sdock_z = -0.056, srack_rx = 4.7, srack_ry = 153.7, srack_rz = -37.6 }
-- (Keine eigenen Konstanten fuer die Startwerte -- reload.lua ist am 200-Local-Limit. Der Reset-Knopf
-- in der UI setzt sie literal: Pose 1 = 0.045/0.032/-0.192 + 53.7/285.7/-86.1 (Punisher),
-- Pose 2 = 0.077/-0.008/-0.056 + 4.7/153.7/-37.6 (Blacktail).)

-- [CRASH-HARDEN 2026-07-17] EINZIGER sicherer Weg, den nativen Inventar-Reload aufzurufen. Warum noetig:
-- chainsaw.CsInventoryController.reload dereferenziert das equippte Gun-/Ammo-Item OHNE Null-Check. Beim
-- frame-genauen Uebergang (Um-Equippen mitten im Reload, 0-Ammo-Wechsel) ist dieses Item kurz null -> die
-- native reduce-Kette liest null -> Access Violation c0000005 -> FULL GAME CRASH (belegt re2_framework_log
-- 19:37:30, "Exception... CsInventoryController.reload"). Die pcall um den Call faengt eine AV NICHT.
-- Der bisherige Guard (equip_wid == wep.wid) hatte noch ein Fenster. Der Crash ist konkret das NULL GUN-ITEM
-- im Equip-Uebergang (Kommentar 2026-07-14: equip_wid zeigt schon die neue Waffe, das Gun-Item ist aber noch
-- null). Genau DAS abfragen: getEquippedWeapon(EquipType) liefert das equippte WeaponItem, null = kein Item =
-- Crash-Fall -> dann NICHT reload'en. Wichtig: KEIN enableReloadItem-Gate (2026-07-17 verworfen) -- der prueft
-- die VOLLE Reload-Gueltigkeit nach Engine-Semantik und lehnt unseren eigenen VR-Reload-Flow ab (Sentinel Nine:
-- auf 0, nachgeladen -> blieb 0). getEquippedWeapon blockt NUR den echten null-Fall, keine legitimen Reloads.
-- Global (kein neuer Top-Level-Local; reload.lua ist am 200-Local-Limit) -> reload2/reload3 nutzen denselben Helfer.
-- [RELOAD-WATCHDOG 2026-07-21 ENTFERNT] Der PRE/POST-Watchdog um den nativen reduce/reload
-- (re4_reload_watch.log) ist raus. Die Crash-Guards selbst (getEquippedWeapon-null-Check, Ammo-Guard,
-- Drain-Split, __re4_safe_reduce) sind UNVERAENDERT drin -- nur das Protokoll faellt weg.
-- Zum Wiederholen einer Crash-Analyse: others/re4_vr_reload.bak_2026-07-21_pre_diagclean.
-- [CRASH-HARDEN 2026-07-18 v2] Reserve-Abzug OHNE den nativen chainsaw.CsInventoryController.reduce.
-- WARUM v1 (count-Guard) versagte: getItemCountSum liefert eine PLAUSIBLE Zahl, aber der native reduce laeuft
-- intern ueber die Item-Rows und deref't eine "stale/Spiegel"-Row mit null-Innenobjekt -> c0000005 (RCX=0) ->
-- FULL CRASH (belegt 12:51:04 UND erneut 13:14:45, trotz count>=n). getItemCountSum ist laut eigenem Kommentar
-- Z.1648 ohnehin unzuverlaessig (ItemID:ToString-Marshalling). Zaehler != Deref-Sicherheit.
-- EFFEKTIV: den nativen reduce NIE rufen. Die AV kann nur IM nativen reduce passieren -> rufen wir ihn nie,
-- kann er nie crashen. Stattdessen die Reserve an den echten getItems-Rows runterzaehlen (dieselbe Enumeration,
-- die __re4_item_count_sum als ZUVERLAESSIG nutzt). set_CurrentItemCount ist ein managed Setter auf einem per
-- safe bestaetigten Nicht-null-Row-Objekt -> deref't nichts selbst -> keine AV moeglich. Schlimmster Fall
-- (Setter greift nicht): Reserve bleibt 1 zu hoch -- rein kosmetisch, NIE ein Crash. reduce laedt keine Waffe,
-- der Ladepfad (reload/addAmmoCount/write_dword) ist getrennt und lief schon davor -> KEINE Funktionsbeschneidung.
-- Global, damit reload2/reload3 denselben Helfer nutzen.
_G.__re4_safe_reduce = function(inv, ammo_id, n)
    n = tonumber(n); if not inv or ammo_id == nil or not n or n <= 0 then return false end
    local want  = tostring(ammo_id)
    -- [ECHTE_ROW 2026-07-31, "Reserve bleibt gleich"] DER Fehler: `inv:getItems` liefert KOPIEN.
    -- Log-Beweis (SHELL-Zeilen, Riot Gun/Skull Shaker/Red9): geladen wurde sauber (hud 8->10), reduceCount
    -- lief durch OHNE die "wirkungslos"-Meldung -- die Kopie ist also brav gesunken -- und die
    -- Inventarsumme stand trotzdem unveraendert bei 10. Wir haben an einer Attrappe gezaehlt.
    -- Die ECHTE Zeile haengt an `inv:getInventoryItemList` -> chainsaw.CsInventoryItem, und deren
    -- geerbtes `get_Item` (chainsaw.InventoryItemBase) liefert das reale chainsaw.Item. Darauf wirkt
    -- reduceCount. Kein Inventar-weiter nativer Call (kein `inv:reduce`) -> die alte Crash-Ecke bleibt
    -- unberuehrt; es sind nur Getter plus ein Mutator auf einem per safe bestaetigten Objekt.
    -- Am Ende wird die Summe NACHGEMESSEN: sinkt sie nicht, sagt es das Log, statt still falsch zu buchen.
    local before_sum = tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or 0
    -- [INV_REDUCE 2026-07-31, "auch nach 50 Versuchen nicht hin"] Messung, die das entschieden hat:
    -- "Zeilen=32 passende=1 bewegt=1" bei "Summe blieb 3" -- die Zeile WURDE gefunden und ist gesunken,
    -- das Inventar blieb trotzdem stehen. Also ist auch `getInventoryItemList` eine KOPIENliste. Jeder
    -- Weg ueber Item-Objekte ist damit erschoepft; der zweckgenaue Call ist `inv:reduce(ItemID, n)`.
    -- Zur Crash-Frage, weil die berechtigt ist: gecrasht ist ausschliesslich
    -- `chainsaw.CsInventoryController.reload(EquipType, Int32, Boolean)` (RIP re4+0x233ef9b, RCX=0).
    -- =========================================================================================
    -- [GELOESCHT 2026-08-12 14:45] Hier lief ZUERST `inv:reduce(chainsaw.ItemID, System.Int32)`.
    -- Er hat einen Full-Crash beim Pistolen-Reload ausgeloest:
    --   "Exception thrown in REMethodDefinition::invoke for chainsaw.CsInventoryController.reduce"
    -- Der alte Kommentar hier ("reduce taucht in KEINEM Crash-Log auf") ist damit widerlegt --
    -- es ist dieselbe Sorte Inventar-weiter Call wie `reload` und laeuft in dieselbe Wand.
    -- Aufgefallen ist es erst jetzt, weil der Ladeweg vorher verpuffte und die Engine die Reserve
    -- selbst zog; scharf lief dieser Abzug also praktisch nie.
    --
    -- ERSATZLOS RAUS statt hinter ein Flag: ein Call, der das Spiel killt, gehoert nicht ins
    -- Script. Der RE2-Mod ruft ebenfalls NIE einen inventarweiten reduce, sondern schreibt die
    -- Slot-/Item-Werte direkt -- genau das macht der Block unten
    -- (getInventoryItemList -> row:get_Item() -> reduceCount/setItemCount) und ist ab jetzt der
    -- einzige Weg. Wirkt er nicht, bleibt die Reserve stehen: ein Buchungsfehler, KEIN Crash.
    -- Alte Fassung: others/re4_vr_reload.bak_2026-08-12_pre_accessor.lua
    -- =========================================================================================
    do
        local list = safe(function() return inv:call("getInventoryItemList()") end)
        local lcnt = list and (tonumber(safe(function() return list:call("get_Count") end)) or 0) or 0
        local rem2, hits, moved = n, 0, 0
        local hit_row = nil   -- [KANONISCH] erste passende Zeile merken -> unten der echte Abzugsweg
        for i = 0, lcnt - 1 do
            if rem2 <= 0 then break end
            local row = safe(function() return list:call("get_Item(System.Int32)", i) end)
            local rid = row and safe(function() return row:call("get_ItemId") end)
            if rid and tostring(rid) == want then
                hits = hits + 1
                hit_row = hit_row or row
                local real = safe(function() return row:call("get_Item") end)
                local have = real and (tonumber(safe(function() return real:call("get_CurrentItemCount") end)) or 0) or 0
                if have > 0 then
                    local take = math.min(have, rem2)
                    pcall(function() real:call("reduceCount", take) end)
                    local now = tonumber(safe(function() return real:call("get_CurrentItemCount") end)) or have
                    if now >= have then pcall(function() real:call("setItemCount", have - take) end)
                        now = tonumber(safe(function() return real:call("get_CurrentItemCount") end)) or have end
                    moved = moved + math.max(0, have - now)
                    rem2 = rem2 - take
                end
            end
        end
        local after_sum = tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or before_sum
        if after_sum < before_sum then
            return true
        end
        -- [TRENNSCHAERFE 2026-07-31] hits=0 -> die ItemId der Munition passt zu KEINER Inventar-Zeile
        -- (Vergleichsproblem). hits>0 aber moved=0 -> Zeile gefunden, aber auch das echte Item laesst
        -- sich nicht veraendern. Zwei voellig verschiedene Ursachen, deshalb getrennt protokolliert.
        -- [AUFGERAEUMT 2026-08-12] Hier standen drei Sackgassen, alle im Log widerlegt und deshalb
        -- geloescht: (K) getItem(SlotIndex), (F) Roh-Schreiben auf Zeilen-/Getter-Instanz und die
        -- (S)-Diagnose dazu -- alle drei fassen KLONE an (jeder Aufruf liefert eine andere Adresse),
        -- die Summe blieb jedes Mal stehen. Dazu (R2) reduceItem, das die Engine mit ret=false
        -- verweigert hat. Gebucht wird ausschliesslich ueber (G) unten -- die echte Liste.
        -- (G) DIE ECHTE LISTE -- ueber FELDER statt Getter. Belegt im Log: jeder Getter (getItems,
        -- get_Item, getItem(SlotIndex)) liefert bei jedem Aufruf eine ANDERE Adresse, also Klone; deshalb
        -- verpufft dort jeder Schreibvorgang. Der Dump zeigt, wo die Originale liegen:
        --   CsInventoryController.<_CsInventory>k__BackingField (0xa0) -> chainsaw.gui.inventory.CsInventory
        --   CsInventory._InventoryItems (0x38) -> List<CsInventoryItem>
        --   CsInventoryItem.<Item>k__BackingField (0x10) -> chainsaw.Item
        --   Item._CurrentItemCount (0x34)
        -- Kein nativer Call, nur Feldzugriffe und eine Zahl. Adressen kommen mit ins Log, damit sofort
        -- sichtbar ist, ob DIESE Instanzen stabil sind (dann sind es die Originale).
        do
            local csinv = safe(function() return inv:get_field("<_CsInventory>k__BackingField") end)
            local lst   = csinv and safe(function() return csinv:get_field("_InventoryItems") end)
            local lcnt2 = lst and (tonumber(safe(function() return lst:call("get_Count") end)) or 0) or 0
            local rem3 = n
            for i = 0, lcnt2 - 1 do
                if rem3 <= 0 then break end
                local row2 = safe(function() return lst:call("get_Item(System.Int32)", i) end)
                local it2  = row2 and safe(function() return row2:get_field("<Item>k__BackingField") end)
                local iid2 = it2 and safe(function() return it2:get_field("_ItemId") end)
                if it2 and iid2 and tostring(iid2) == want then
                    local have2 = tonumber(safe(function() return it2:get_field("_CurrentItemCount") end)) or 0
                    local take2 = math.min(have2, rem3)
                    if take2 > 0 then
                        pcall(function() it2:set_field("_CurrentItemCount", have2 - take2) end)
                        local back = tonumber(safe(function() return it2:get_field("_CurrentItemCount") end)) or -1
                        if back ~= (have2 - take2) then pcall(function() it2:write_dword(0x34, have2 - take2) end) end
                        rem3 = rem3 - take2
                    end
                end
            end
            -- [LEERZEILE RAUS 2026-08-12] Munition mit 0 gibt es im Inventar nicht -- ist eine Zeile
            -- leergebucht, muss sie verschwinden. Dafuer der Weg der Inventarverwaltung selbst:
            -- CsInventory.remove(System.Guid), Guid steht im Item (_ID, 0x18). Das ist NICHT die
            -- reduce/reload-Familie, die die Abstuerze gebracht hat, und er laeuft ausschliesslich auf
            -- Zeilen, die bereits auf 0 stehen. Rueckbau: _G.__re4_inv_remove_empty = false
            if rawget(_G, "__re4_inv_remove_empty") ~= false then
                for i = lcnt2 - 1, 0, -1 do
                    local row3 = safe(function() return lst:call("get_Item(System.Int32)", i) end)
                    local it3  = row3 and safe(function() return row3:get_field("<Item>k__BackingField") end)
                    local iid3 = it3 and safe(function() return it3:get_field("_ItemId") end)
                    if it3 and iid3 and tostring(iid3) == want
                       and (tonumber(safe(function() return it3:get_field("_CurrentItemCount") end)) or 1) <= 0 then
                        local gid = safe(function() return it3:get_field("_ID") end)
                        if gid ~= nil then
                            local okr3 = pcall(function() csinv:call("remove(System.Guid)", gid) end)
                            local nach = tonumber(safe(function() return lst:call("get_Count") end)) or lcnt2
                        end
                    end
                end
            end
            local sg = tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or before_sum
            if sg < before_sum then return true end
        end
        -- [WER FUEHRT DIE BUCHHALTUNG? 2026-08-12] Messen statt raten: unsere Summe laeuft ueber
        -- inv:getItems(). Wenn ein Schreiben auf die Zeilen-Instanz die Summe nicht bewegt, ist das Objekt
        -- in getItems ein ANDERES. Deshalb hier einmalig jede passende Zeile aus getItems mit ADRESSE und
        -- Zaehlerstand ins Log -- danach wissen wir, welche Instanz beschrieben werden muss, statt es zu
        -- [CRASH 2026-08-12 22:11 -- WIEDER RAUS] Hier stand fuer eine knappe Stunde ein Aufruf von
        -- `inv:reduce(chainsaw.ItemID, System.Int32)`, dem nativen Verbrauchsweg des Controllers.
        -- Er hat abgezogen -- und dann das Spiel getoetet: Killer7 ok=true (Summe 4->0), Stingray
        -- ok=false (Summe 8->0), danach kam kein Reload mehr ins Log. Damit gehoert er in dieselbe
        -- Familie wie der ausgebaute `inv:reload`/`execReload`: laeuft nur sauber, wenn die ENGINE ihn
        -- aus ihrem eigenen Zyklus faehrt. Ersatzlos raus statt hinter ein Flag -- ein Call, der das
        -- Spiel killt, gehoert nicht ins Script, auch nicht ausgeschaltet.
        -- Damit ist der Abzug wieder OFFEN: die Reserve bleibt stehen, das ist ein Buchungsfehler
        -- statt eines Absturzes. Naechste Spur: den Abzug NICHT im Reload-Weg fahren, sondern der
        -- Engine ueberlassen bzw. einen Frame spaeter -- ungetestet.
    end
    -- Fallback: der bisherige Weg ueber die getItems-Kopien (siehe oben -- wirkungslos, aber harmlos).
    local items = safe(function() return inv:call("getItems") end); if not items then return false end
    local cnt   = tonumber(safe(function() return items:call("get_Count") end)) or 0
    local rem   = n
    for i = 0, cnt - 1 do
        if rem <= 0 then break end
        local it = safe(function() return items:call("get_Item(System.Int32)", i) end)
        if it then
            local iid = safe(function() return it:call("get_ItemId") end)
            if iid and tostring(iid) == want then
                local have = tonumber(safe(function() return it:call("get_CurrentItemCount") end)) or 0
                if have > 0 then
                    local take = math.min(have, rem)
                    -- [FIX 2026-07-18] chainsaw.Item hat KEIN set_CurrentItemCount (mein alter Call verpuffte,
                    -- Row blieb stehen -> Reserve nie abgezogen). Echter Mutator = reduceCount(n), direkt am
                    -- non-null Row-Objekt -> zuverlaessig UND kein Controller-null-Deref (kein Crash).
                    -- [ABZUG_NACHMESSEN 2026-07-31, "zieht nix von der Reserve ab"] Log-Beweis
                    -- (SHELL-Zeilen, Riot Gun): geladen wurde sauber (hud 8->10), aber die Reserve stand
                    -- vor UND nach dem Abzug auf 10 -- reduceCount ist also durchgelaufen und hat nichts
                    -- bewegt. Deshalb an der Row NACHMESSEN und, wenn sie stehenblieb, den direkten
                    -- Setter setItemCount(rest) nehmen (existiert laut Typdump, chainsaw.Item). Beide
                    -- Aufrufe gehen auf ein per safe bestaetigtes Row-Objekt -> kein Deref-Risiko.
                    pcall(function() it:call("reduceCount", take) end)
                    local now = tonumber(safe(function() return it:call("get_CurrentItemCount") end)) or have
                    if now >= have then
                        pcall(function() it:call("setItemCount", have - take) end)
                        now = tonumber(safe(function() return it:call("get_CurrentItemCount") end)) or have
                    end
                    -- Nur das als abgezogen verbuchen, was die Row wirklich verloren hat.
                    local drop = math.max(0, have - now)
                    if drop <= 0 then
                        break   -- weitere Rows bringen nichts, wenn der Mutator generell nicht greift
                    end
                    rem = rem - drop
                end
            end
        end
    end
    return rem < n   -- true = es wurde etwas abgezogen
end
-- [LOG RAUS 2026-08-13] Die komplette Reload-Diagnose (__re4_rlog samt Stub und allen
-- Aufrufstellen) ist entfernt. Rueckfallebene: others/_backup_2026-08-13_pre_logclean.
-- =====================================================================
-- [TOTER (E)-ZWEIG ENTFERNT 2026-08-12]
-- =====================================================================
-- Hier stand ein Zweig (E), der zuerst `PlayerEquipment:execReload()` versucht hat, gesteuert
-- ueber `_G.__re4_reload_native_path`. Er hat am 12.08. beim ersten Pistolen-Reload einen
-- VOLLCRASH ausgeloest und stand seither auf `false` -- also toter Code mit einer scharfen
-- Zuendschnur (ein versehentliches `true` haette gereicht).
--
-- Der Befund dahinter bleibt wichtig: `execReload` crasht von uns aus GENAUSO wie der
-- Direkteinstieg in `INV:reload`. Die aufgezeichnete native Kette
--   Gun:onReloadStart -> INV:enableReloadItem -> PlayerEquipment:execReload
--   -> Gun:get_ReloadNum -> INV:reload(...) -> WeaponItem:addAmmoCount
--   -> INV:onItemCountChanged/onRemoveItem/onReloadWeapon -> PlayerEquipment:updateGunAmmo
-- laeuft NUR sauber, wenn die ENGINE sie aus ihrem eigenen Zyklus heraus faehrt. Aus einem
-- freien Frame-Tick trifft jeder Einstieg dieselbe Wand.
--
-- Gebraucht wird das alles nicht mehr: seit dem Accessor-Umbau
-- (`pe:getEquipWeaponAccessor():get_Item()`, siehe get_live_weapon_item) schreiben wir direkt
-- auf die echte WeaponItem-Instanz, das HUD folgt sofort und kein nativer Ladecall ist noetig.
-- Wer die alte Fassung braucht: others/re4_vr_reload.bak_2026-08-12_pre_deadcode.lua
-- =====================================================================

-- [LADEN + BUCHEN 2026-08-12] `__re4_safe_inv_reload` hat frueher nativ geladen UND dabei die Reserve
-- gezogen. Seit der native Call raus ist, laedt der Weg zwar noch (die Wege dahinter schreiben selbst),
-- aber NIEMAND bucht mehr ab -- sichtbar beim Red9: Einzelpatronen gehen rein, die Reserve bleibt stehen.
-- Dieser Helfer kapselt beides: Stand vorher merken, laden lassen, und wenn die Waffe voller wurde,
-- ohne dass die Reserve gefallen ist, genau diese Menge ueber __re4_safe_reduce buchen (der Weg ueber
-- die echte Inventarliste). Doppelt kann es nicht buchen -- gefallene Reserve heisst: schon gebucht.
_G.__re4_load_and_book = function(inv, et, n, refill)
    local pe = _G.__re4_pe and _G.__re4_pe()
    local w  = nil
    pcall(function() w = inv and inv:call("getEquippedWeapon(chainsaw.EquipType)", et) end)
    local aid = w and safe(function() return w:call("get_CurrentAmmo") end)
    local function rsv() return (inv and aid) and (tonumber(safe(function() return _G.__re4_item_count_sum(inv, aid) end)) or 0) or 0 end
    local function gun() return pe and tonumber(safe(function() return pe:call("getCurrentGunAmmo") end)) or nil end
    local r0, g0 = rsv(), gun()
    local ok = _G.__re4_safe_inv_reload(inv, et, n, refill)
    local g1 = gun()
    if g0 and g1 and g1 > g0 and rsv() >= r0 and aid then
        local gained = g1 - g0
        _G.__re4_safe_reduce(inv, aid, gained)
    end
    return ok
end

_G.__re4_safe_inv_reload = function(inv, et, n, refill)
    if not inv or et == nil then return false end
    n = tonumber(n); if not n or n <= 0 then return false end

    -- (1) Gun-Item da? (Uebergangsframe: getEquippedWeapon == null -> reload deref't null)
    local w = nil
    pcall(function() w = inv:call("getEquippedWeapon(chainsaw.EquipType)", et) end)
    if w == nil then return false end
    -- (2) [AMMO-GUARD 2026-07-17] DER eigentliche Crash: reload ruft intern reduce auf das RESERVE-
    -- Ammo-Item. Ist das null/leer (z.B. Aufruf mit fixem n=1 ohne Reserve-Check), deref't reduce null ->
    -- Access Violation c0000005 (RCX=0), Full-Crash (belegt 19:37 UND 20:14, gleicher RIP). getEquippedWeapon
    -- allein reichte NICHT (prueft die Waffe, nicht die Munition). Also: Reserve des zur Waffe passenden
    -- Ammo-Items lesen und n NICHT ueberschreiten. refill==true = "gibt Munition" (kein Reserve-Abzug) ->
    -- kein Reserve-Check. Unlesbar -> sicherheitshalber NICHT rufen (verpasster Reload < Crash).
    local drain, ammo_id = false, nil
    if refill ~= true then
        pcall(function() ammo_id = w:call("get_CurrentAmmo") end)
        if ammo_id == nil then return false end
        local cnt = nil
        pcall(function() cnt = tonumber(inv:call("getItemCountSum(chainsaw.ItemID)", ammo_id)) end)
        if not cnt or cnt < n then
            return false
        end
        -- [DRAIN-FIX 2026-07-17] Crash NUR wenn dieser Zug die Reserve auf EXAKT 0 zieht (live belegt: n=7 bei
        -- 7 Reserve -> null-Deref im nativen reload). Loesung: die Reserve NIE per nativem reload auf 0 ziehen.
        -- rel = ZUVERLAESSIGE Reserve (getItems). rel <= n (oder unlesbar) -> Split-Weg. Auch wenn rel mal zu
        -- niedrig liest, ist der Split korrekt UND crashfrei (native reload zieht dann nur n-1).
        -- [ZURUECKGENOMMEN 2026-07-23] Der Always-Drain (jeder Reload ueber refill=true) hat den
        -- nativen Reload-Aufruf von "selten" auf "immer" gestellt -- und genau dort kam der Absturz bei
        -- der LE5 (Log 17:34:46, gleiche Signatur wie am Vormittag). Wieder die urspruengliche Regel:
        -- der Sonderweg gilt nur, wenn dieser Zug die Reserve auf 0 zieht.
        local rel = tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end))
        if rel == nil or rel <= n then drain = true end
    end
    -- [GATE ZURUECKGENOMMEN 2026-07-23] Der enableReloadItem-Vorabcheck war KONTRAPRODUKTIV:
    -- enableReloadItem dereferenziert DIESELBE null Item-Row wie reload und stuerzt selbst mit
    -- c0000005 ab (Log 20:58/21:00) -- pcall faengt die native AV nicht. Der Check war also ein
    -- ZWEITER Crash-Punkt plus ein Retry-Loop, der mehrfach crasht. Wieder direkt der native Weg.
    -- [REENTRANCY-GUARD 2026-07-24] Live-belegt (re4_zzz_reload_probe v4, #22 ok -> #23 KEIN ok):
    -- zwei native reloads im ~1s-Abstand auf DERSELBEN Waffe -> der zweite deref't das noch nicht
    -- fertig abgeraeumte Reload-Unterobjekt des ersten -> c0000005. Waffen-UNABHAENGIG (geloggt bei
    -- wid=4101, sah es auch bei Shotguns) -> universeller Fix: nach einem nativen reload eine
    -- kurze Sperre, in der kein zweiter nativer reload durchgeht. Blockt keine echten Reloads
    -- (die Reload-Animation dauert deutlich laenger als das Fenster). Reload-Mechanik bleibt unangetastet.
    -- =================================================================================================
    -- [NO_NATIVE_RELOAD 2026-07-31, "kannst du den Scheiss endlich abfangen"] DER EIGENTLICHE FIX.
    -- Fakt nach einem Monat Logs: die AV liegt IMMER im nativen chainsaw.CsInventoryController.reload
    -- (zuletzt 2026-07-31 16:23:09, RIP re4+0x233ef9b, RCX=0, LE5). Kein Vorab-Check kann sie verhindern,
    -- weil enableReloadItem/reload DIESELBE null-Row deref'en und pcall keine c0000005 faengt. Der einzige
    -- Weg, der garantiert nicht crashen kann, ist: DEN CALL NICHT MACHEN.
    -- Ersatz (crashfrei, weil nur managed Getter + eine rohe Speicherschreibung auf ein per safe
    -- bestaetigtes Objekt): den Ladestand direkt am ECHTEN Laufzeit-Gun-Item setzen -- genau der Pfad,
    -- der als Retained-Zweig (Z. ~1780, write_dword 0x44) schon laeuft. Danach GEGENGEPRUEFT an
    -- pe:getCurrentGunAmmo (die HUD-Quelle, kein Cache): zieht der Wert mit, war es echtes Laden.
    -- Reserve wird per __re4_safe_reduce abgezogen (reduceCount auf der Item-Row, ebenfalls crashfrei).
    -- Nur wenn der Direktweg NACHWEISLICH nicht greift, faellt es auf den nativen Call zurueck -- und
    -- das auch nur, wenn CFG.native_reload_fallback ausdruecklich an ist (Default AUS = nie crashen).
    -- =================================================================================================
    local wi_live  = _G.__re4_live_gun and _G.__re4_live_gun()
    -- Ladestand-Quelle: bevorzugt die HUD-Wahrheit (pe:getCurrentGunAmmo). Ist die mal nicht lesbar,
    -- ersatzweise der Item-Getter -- dann ist die Gegenprobe schwaecher, aber immer noch eine Messung
    -- (und nie ein Grund, in den crashenden nativen Call zu laufen).
    local gun_ammo = function()
        local v = _G.__re4_gun_ammo and _G.__re4_gun_ammo()
        if v then return v end
        return wi_live and tonumber(safe(function() return wi_live:call("get_CurrentAmmoCount") end)) or nil
    end
    local before   = gun_ammo()
    -- [ADR-DIAG 2026-07-31] Sind die drei beschriebenen Instanzen ueberhaupt VERSCHIEDEN? (a)/(d)/(e)
    -- zeigten alle denselben item-Wert -- das beweist noch nicht, dass es drei Objekte waren. Adressen
    -- einmal mitloggen: sind sie gleich, haben wir dreimal dasselbe Objekt beschrieben und die HUD-Quelle
    -- ist definitiv ein anderes Objekt (nicht das WeaponItem).
    local _adr = function(o) return o and string.format("%X", tonumber(safe(function() return o:get_address() end)) or 0) or "-" end
    -- [WID_IM_LOG 2026-07-31] Ohne Waffen-ID ist im Log nicht zu unterscheiden, welche Waffe gerade
    -- klemmt (Armbrust/Bogen/Bolt-Action sehen in den Zahlen gleich aus).
    -- [WID_WAR_BLIND 2026-08-01, "das nicht pruefen bricht uns das Genick"] `wid=nil` stand seit Tagen
    -- in JEDER Logzeile -- nicht weil die Waffe keine ID hat, sondern weil get_WeaponId ein Enum-ValueType
    -- liefert und `:get_field("value__")` daran scheitert; safe schluckt es und macht daraus ein stilles nil.
    -- Damit war die wichtigste Frage des ganzen Ladewegs unbeantwortet: SCHREIBEN WIR UEBERHAUPT AUF DIE
    -- WAFFE IN DER HAND? `__re4_live_wi` kommt aus dem addAmmoCount-Hook und kann auf die ZULETZT benutzte
    -- Waffe zeigen -- dann steigt deren Item (Reserve wird gezogen), und die HUD der gefuehrten Waffe bleibt 0.
    -- Genau dieses Bild zeigt der Skull Shaker. Ab jetzt stehen drei IDs nebeneinander im Log:
    -- wid = WeaponId der Instanz, auf der gemessen wird (wi_live)
    -- add_wid = WeaponId der Instanz, auf die Weg C SCHREIBT (__re4_live_wi)
    -- soll_wid = die Waffe, die der Reload-Pfad gerade fuehrt (__re4_reload_ui_wid)
    -- Laufen die auseinander, ist die Ursache bewiesen statt vermutet.
    local _wid = function(o)
        if not o then return "-" end
        local ok, v = pcall(function() return o:call("get_WeaponId") end)
        if not ok or v == nil then return "?" end
        if type(v) == "number" then return tostring(v) end
        local ok2, n = pcall(function() return v:get_field("value__") end)
        if ok2 and type(n) == "number" then return tostring(n) end
        return "?"
    end
    -- [ITEM_IST_DIE_MESSGROESSE 2026-07-31, "die Shotgun laedt brav nach Ratio, zieht nur nix ab"]
    -- Der Ladeerfolg wird am ITEM gemessen, nicht an pe:getCurrentGunAmmo. Belegt: die Shotgun laedt
    -- sichtbar und korrekt (Ratio stimmt, auch beim Verstellen), waehrend der HUD-Getter stehenbleibt.
    -- Wer am HUD misst, sieht "nichts passiert", zieht keine Reserve ab und laedt womoeglich doppelt.
    -- [ADD_INSTANZ 2026-07-31, "Shotgun und Red9 laden gar nichts"] DIE Instanz-Frage. Log-Beweis:
    -- addAmmoCount auf wi_live erhoeht das Item (8->10), aber pe:getCurrentGunAmmo bleibt stehen (8->8)
    -- = die Waffe laedt nicht. Der Shotgun-Pfad (rotary.do_load, Z. ~2459) laedt mit demselben Aufruf
    -- SICHTBAR -- und nimmt dafuer `rawget(_G,"__re4_live_wi")`, den Cache aus dem addAmmoCount/
    -- reduceAmmoCount-Hook. Das ist die Instanz, auf der die ENGINE selbst arbeitet; get_live_weapon_item
    -- liefert dagegen oft eine andere (die Adressen im Log wechseln bei jedem Reload komplett).
    -- Also denselben Vorrang wie der funktionierende Pfad, aber mit WeaponId-Abgleich gegen einen
    -- stale Cache (toter Cache -> schon der Getter darauf waere ein Call ins Leere, s. CACHE-TTL).
    -- [ABGLEICH RAUS 2026-07-31] Mein WeaponId-Abgleich schlug still fehl -> es landete wieder auf
    -- wi_live (Log: "auf wi_live") und lud nicht. rotary.do_load nimmt seit Wochen schlicht
    -- `__re4_live_wi or wi` -- ohne Abgleich, ohne Crash, und laedt nachweislich (Shotgun: HUD geht mit).
    -- Genau dieselbe Wahl hier.
    -- [ACCESSOR 2026-08-12] ZUERST die echte, persistente Instanz -- __re4_live_wi ist der alte
    -- Hook-Cache (kann nach Save-Load eine Leiche sein), wi_live/w sind KOPIEN (Schreiben verpufft).
    local add_wi = (_G.__re4_real_wi and _G.__re4_real_wi()) or rawget(_G, "__re4_live_wi") or wi_live
    local item_ammo = function()
        return add_wi and tonumber(safe(function() return add_wi:call("get_CurrentAmmoCount") end)) or nil
    end
    if wi_live and before then
        -- [CAP-KANDIDATEN 2026-08-01, "meine pistole laedt nicht nach"] `cap` kam bisher NUR aus
        -- wi_live. Log-Beweis (13:17): "START wid=nil... item=0" -> "(C) Nachbau ohne Wirkung" -- auf
        -- dieser Instanz lieferten get_WeaponId UND get_CurrentAmmoMax nichts, also cap=0. Damit fiel
        -- `is_full` durch und Weg A (execReload) wurde NIE VERSUCHT, obwohl er genau der richtige war
        -- (Waffe leer, volles Magazin gewollt). Uebrig blieb Weg C -- der auf einer Kopie schrieb.
        -- Live live gegengeprueft: `pe:getEquipWeaponItem` liefert eine WeaponItem-Referenz, die
        -- beim naechsten Zugriff schon nicht mehr aufloesbar ist. Eine EINZELNE Instanz zu fragen ist
        -- also zu wenig -> der Reihe nach alle vier, die erste mit cap>0 gewinnt.
        local cap, cap_src, cap_dbg = 0, "-", {}
        for _, c in ipairs({
            { "add_wi",  add_wi },
            { "wi_live", wi_live },
            { "equip",   _G.__re4_equip_gun and _G.__re4_equip_gun() },
            { "inv",     w },
        }) do
            local v = c[2] and tonumber(safe(function() return c[2]:call("get_CurrentAmmoMax") end)) or nil
            cap_dbg[#cap_dbg + 1] = string.format("%s=%s", c[1], c[2] and tostring(v) or "nil")
            if cap <= 0 and (v or 0) > 0 then cap, cap_src = v, c[1] end
            -- [ADD_WI_TOT 2026-08-06 -- Crash beim Revolver-Nachladen] Ergebnis dieser Messung
            -- MERKEN: liefert add_wi hier nil, ist die Instanz tot -- und genau darauf schreibt Weg R/C
            -- weiter unten mit addAmmoCount. Ein:call auf eine tote Instanz ist ein virtueller Call
            -- ins Leere -> c0000005, und pcall faengt das NICHT. Genau so ist es 18:57:49 passiert:
            -- Log "cap-Quellen: add_wi=nil", letzte Engine-Exception "WeaponItem.get_CurrentAmmoMax"
            -- (= dieser Getter hier), danach bricht unser Reload-Log mitten in (R)/(C) ab.
            -- Wir nutzen bewusst DIESE Messung und rufen nichts Neues auf der Leiche auf.
            if c[1] == "add_wi" then _G.__re4_addwi_alive = (v ~= nil) end
        end
        -- Zeigt beim naechsten Fehlschlag sofort, OB ueberhaupt eine Instanz noch lebt (Frage:
        -- "wie kam es dazu?"). Alle vier auf nil/0 = keine gueltige WeaponItem-Referenz mehr in der Hand.
        local it_b   = item_ammo() or before
        local target = (cap > 0) and math.min(cap, it_b + n) or (it_b + n)
        local got    = target - it_b
        if got <= 0 then
            return false   -- schon voll
        end
        -- =========================================================================================
        -- [KEINE_WAFFEN_SONDERFAELLE 2026-07-31, "wo soll der Unterschied von Red9, Shotgun
        -- oder Bogen sein, das sind nur Zahlen"] Der hat recht -- es GIBT keinen. Alle
        -- Sonderpfade nach Waffe (isLoopReload, Add-Kette ueber 5 Item-Instanzen, GUID-Weg) sind
        -- RAUS. Was die Messungen uebrig gelassen haben, sind genau zwei Wege:
        --
        -- A) JEDER RELOAD -> pe:execReload [seit 2026-08-01 auch Teilmengen, s. Block weiter unten]
        -- Laedt echt, HUD zieht sofort mit, Engine zieht die Reserve selbst UND rechnet die Menge
        -- selbst aus. Crashfrei -- laeuft durch die normale State-Maschine wie ohne Mod.
        --
        -- B) NUR NOCH FALLBACK, wenn A nicht durchlaeuft -> nativer inv:reload(EquipType, menge, refill)
        -- Der EINZIGE Call, der Menge UND Wirkung hat. Alles andere verpufft, weil jede
        -- Item-Instanz, die wir zu fassen bekommen, eine Kopie ist -- gemessen an Red9,
        -- Shotgun und Bogen gleichermassen (item steigt, hud bleibt). Er zieht auch die
        -- Reserve selbst; genau deshalb ging sie nie ab, seit wir ihn nicht mehr rufen.
        --
        -- Zum Restrisiko, ohne es schoenzureden: dieser Call ist der, der ~1/10000 abstuerzt
        -- (RIP re4+0x233ef9b, RCX=0, use-after-free -- kein Mengen- oder Ammo-Problem). Er trifft
        -- jetzt aber nur noch TEILMENGEN; volle Magazine, also die grosse Mehrheit aller Reloads,
        -- laufen ueber den crashfreien Weg A. Abschaltbar bleibt er ueber die Checkbox im
        -- Reload-Tree ("Nativen Inventar-Reload erlauben") -- dann laden Teilmengen eben nicht.
        -- =========================================================================================
        -- =========================================================================================
        -- [WEG A FUER ALLES 2026-08-01, Log-Beweis] Weg A gilt ab jetzt fuer JEDE Menge, nicht
        -- mehr nur fuer volle Magazine. Beweis aus re4_reload_direct.log (Absturz 00:33): ALLE Reloads
        -- dieser Sitzung standen auf ok=true -- der EINE mit ok=false war die letzte Zeile vor dem Aus:
        -- "(B/late) inv:reload(20) ok=false isEnableReload=true -> hud 0->20"
        -- Das pcall hat also eine Ausnahme IM nativen Call gefangen (die Munition ging trotzdem rein),
        -- und kurz danach war das Spiel weg -- ohne Dump, weil REFramework die AV abfaengt und das Spiel
        -- erst an der zerlegten Engine-Struktur stirbt. Der Absturz, den wir jagen, ist die Nachwirkung.
        --
        -- Der Grund, warum Teilmengen ueberhaupt ueber B liefen, war der RESERVE-ABZUG (eigene Versuche
        -- verpufften alle an Item-Kopien). Der faellt hier nicht weg: **execReload zieht die Reserve
        -- selbst** -- exakt so, wie es bei jedem vollen Magazin schon den ganzen Tag laeuft. Und die
        -- Menge rechnet die Engine ebenfalls selbst (freie Kapazitaet gegen Reserve) -- das ist genau
        -- die Teilmenge, die wir vorher von Hand ausgerechnet und uebergeben haben.
        -- B bleibt nur noch stehen, falls execReload gar nicht erst durchlaeuft (pcall false).
        -- =========================================================================================
        -- [RESERVE_IST_AUCH_VOLL 2026-08-01, "die BLACKTAIL konnte nun laden"] DER Fehler, warum
        -- Waffen mal luden und mal nicht -- belegt in re4_reload_direct.log, drei Zeilen derselben Sitzung:
        -- n=13 cap=13 -> (A) execReload=true hud 0->13 (Blacktail: Reserve reicht fuers volle Mag)
        -- n=20 cap=24 -> (C) Nachbau ohne Wirkung (Punisher: 20 Reserve, 24 Kapazitaet)
        -- n=2 cap=6 -> (C) Nachbau ohne Wirkung (Revolver: 2 Reserve, 6 Kapazitaet)
        -- `target >= cap` fragt "wird das Magazin voll?" -- das ist die falsche Frage. Sobald die Reserve
        -- kleiner ist als die freie Kapazitaet (bei aufgeruesteten Waffen der Normalfall), kann target
        -- cap NIE erreichen, Weg A wird nie versucht, und uebrig bleibt Weg C, der ohne Wirkung verpufft.
        -- Richtig ist: Weg A passt auch dann, wenn wir ALLES laden wollen, was die Reserve hergibt --
        -- execReload laedt genau min(freie Kapazitaet, Reserve), also exakt dieselbe Menge wie gewollt.
        -- Die Reserve wird mit denselben zwei Bausteinen gemessen, die Weg C unten schon fuer den Abzug
        -- benutzt (get_CurrentAmmo -> __re4_item_count_sum) -- keine neue Mechanik, kein Raten.
        -- Ist sie nicht lesbar (rsv=0), bleibt es beim alten Verhalten: dann greift nur target>=cap.
        -- [RESERVE AN TOTER INSTANZ 2026-08-01] Die Ammo-ID kam nur aus `add_wi` -- genau der Instanz, die
        -- tot sein kann (Log 58.60: "add_wi=nil" bei lebendem wi_live/equip/inv). Dann war aid nil und die
        -- Reserve las sich als 0, obwohl Munition da war. Jetzt der Reihe nach ueber alle Instanzen, die
        -- eine Ammo-ID liefern koennen -- dieselbe Kandidatenkette wie bei cap, erste brauchbare gewinnt.
        -- [PHANTOM-RESERVE 2026-08-06, "es wurden 2 Reserve angezeigt, die gar nicht da waren"]
        -- Die Reihenfolge war `add_wi` ZUERST -- das ist `__re4_live_wi`, der Cache aus dem
        -- addAmmoCount-Hook, und der zeigt laut Re-Acquire-Kommentar (Z.~1751) auf die ZULETZT BENUTZTE
        -- Waffe, nicht zwingend auf die in der Hand. Damit wurde die Munition einer FREMDEN Waffe
        -- gezaehlt: Log 1702.15 meldete `reserve=2` fuer den Revolver, obwohl dort nichts war ( hat
        -- es am selben Save doppelt gegengeprueft). Auf diese Phantom-Menge lief dann der Ladeversuch.
        -- Jetzt zuerst die Waffe im SLOT (`w` = inv:getEquippedWeapon(et)) und die equippte Instanz --
        -- beide gehoeren per Definition zur Waffe in der Hand -- und `add_wi` erst ganz zuletzt.
        -- Die gewinnende ID kommt ins Log, damit ein falscher Abzug nicht wieder unbemerkt bleibt.
        -- [FREMDE MUNITION 2026-08-12, "Killer7 laedt Riflepatronen"] Log 21:53:37: rsv_src=slot lieferte
        -- ammo_id=112801600 fuer wid 4501 (Killer7) -- geladen wurden Gewehrpatronen, und cap meldete 15
        -- statt 7. Ein Kandidat wurde bisher NUR daran gemessen, ob seine Munition im Inventar liegt, nie
        -- daran, ob er ueberhaupt die Waffe in der Hand IST. Deshalb hier der WeaponId-Abgleich gegen
        -- soll_wid: ist die Id lesbar und passt sie nicht, faellt der Kandidat raus. Ist sie nicht lesbar,
        -- bleibt es beim alten Verhalten (kein neuer stiller Ausfall). Jede Entscheidung geht ins Log.
        local rsv, rsv_src, rsv_aid = 0, "-", nil
        local soll = tonumber(rawget(_G, "__re4_reload_ui_wid"))
        for _, c in ipairs({ { "slot", w }, { "equip", _G.__re4_equip_gun and _G.__re4_equip_gun() },
                             { "wi_live", wi_live }, { "add_wi", add_wi } }) do
            if rsv > 0 then break end
            -- WeaponId der Kandidaten-Instanz, ohne Abhaengigkeit von Helfern weiter oben (die liegen in
            -- einem anderen Block): Enum kommt als ValueType -> value__ lesen, sonst direkt die Zahl.
            local cwid = nil
            pcall(function()
                local v = c[2] and c[2]:call("get_WeaponId")
                if type(v) == "number" then cwid = v
                elseif v ~= nil then cwid = tonumber(v:get_field("value__")) end
            end)
            if soll and cwid and cwid ~= soll then
            else
                -- [USABLE-LISTE 2026-08-12] `get_CurrentAmmo` ist ein beschreibbares Feld (_CurrentAmmo,
                -- 0x40) und damit genau das, was sich verstellen laesst -- steht dort eine fremde Sorte,
                -- meldet die Waffe 0 Reserve, obwohl der Koffer voll ist. Die Waffe weiss aber selbst,
                -- welche Sorten sie ueberhaupt nimmt: get_UsableAmmoList() -> ItemID[]. Also erst die
                -- aktuelle Sorte pruefen, dann alle erlaubten -- die erste mit Bestand gewinnt.
                local cand = {}
                local aid_r = safe(function() return c[2] and c[2]:call("get_CurrentAmmo") end)
                if aid_r ~= nil then cand[#cand + 1] = aid_r end
                local arr = safe(function() return c[2] and c[2]:call("get_UsableAmmoList") end)
                if arr then
                    local asz = tonumber(safe(function() return arr:get_size() end)) or 0
                    for k = 0, asz - 1 do
                        local e = safe(function() return arr:get_element(k) end)
                        if e ~= nil then cand[#cand + 1] = e end
                    end
                end
                local zeile = {}
                for _, aid in ipairs(cand) do
                    if inv and _G.__re4_item_count_sum_num then
                        -- ueber die ZAHL vergleichen: Eintraege aus der Usable-Liste sind eingepackte
                        -- Enum-Werte, deren tostring die Adresse ist (Log: sol.REManagedObject*: ...).
                        local anum = _G.__re4_id_num(aid)
                        local s = anum and (tonumber(safe(function() return _G.__re4_item_count_sum_num(inv, anum) end)) or 0) or 0
                        zeile[#zeile + 1] = string.format("%s=%d", tostring(anum or aid), s)
                        if s > 0 and rsv <= 0 then
                            rsv, rsv_src, rsv_aid = s, c[1], aid
                            _G.__re4_reserve_aid_wid = cwid
                            -- Die Sorte stammt aus der Kandidatenliste DIESER Waffe (aktuelle Sorte oder
                            -- ihre Usable-Liste) -- also belegt zulaessig und damit auch schreibbar.
                            _G.__re4_reserve_aid_ok = true
                        end
                    end
                end
                if #zeile > 0 then
                end
            end
        end
        if rsv <= 0 then _G.__re4_reserve_aid_wid = nil; _G.__re4_reserve_aid_ok = nil end
        _G.__re4_reserve_aid = rsv_aid   -- [PHANTOM-RESERVE] exakt DIESE ID zieht der Abzug spaeter ab
        -- [HUD-RESERVE 2026-08-12] Zeigt die Waffe "0 Reserve", obwohl der Koffer voll ist, dann steht in
        -- ihrem Feld _CurrentAmmo (0x40) die falsche Sorte -- das Spiel zeichnet die Anzeige aus genau
        -- diesem Feld. Sobald die Messung eine Sorte MIT Bestand aus der Usable-Liste DIESER Waffe
        -- gefunden hat, wird sie dorthin zurueckgeschrieben. Quelle ist damit die Waffe selbst, nicht
        -- irgendeine fremde Instanz -- das war der Unterschied zum Fremdschreiben von vorhin.
        if rsv_aid ~= nil and rawget(_G, "__re4_reserve_aid_ok") == true then
            local wi_now = safe(function() return w and w:call("get_CurrentAmmo") end)
            if tostring(wi_now) ~= tostring(rsv_aid) then
                local ok_sid = pcall(function() w:call("setAmmoId(chainsaw.ItemID)", rsv_aid) end)
            end
        end
        local is_full = (cap > 0) and (target >= cap or (rsv > 0 and got >= rsv))
        -- [NOTLOESUNG WIEDER RAUS 2026-08-01, "ich habe das Gefuehl du willst das Problem
        -- umschiffen"] Hier stand kurz ein Zweig, der bei cap<=0 und n>1 trotzdem execReload rief.
        -- Zu Recht kassiert: cap<=0 heisst nach der Messung unten, dass das WeaponItem GAR NICHT MEHR
        -- EXISTIERT (Speicher an der Adresse aus pe:getEquipWeaponItem komplett genullt, inkl.
        -- Typ-Pointer bei Offset 0). execReload ausgerechnet dann zu feuern, waere ein Crash-Kandidat
        -- auf eine tote Referenz -- und wuerde die eigentliche Ursache zudecken statt sie zu zeigen.
        -- Volles Magazin -> Weg A. Teilmenge -> Weg C weiter unten. (Kein Schalter mehr: execReload
        -- kann keine Menge, es fuellt IMMER bis cap -- deshalb ist es nur fuer den vollen Fall richtig.)
        -- [WEG A RAUS 2026-08-06 -- Crashdump belegt] execReload wird NICHT mehr gerufen. Grund:
        -- Am 06.08. 14:17:18 ist es mit einer Access Violation gestorben -- RIP 14233ef9b, also EXAKT
        -- die Instruktion, die oben (Z.676-682) fuer den nativen Reload disassembliert wurde:
        -- mov rcx,[rax+0x10] (Zeile.Item = NULL) -> mov r8d,[rcx+0x28] -> c0000005, RCX=0
        -- Beide Wege landen in derselben Engine-Routine ueber die Inventar-Zeilen. Weg N ist nur deshalb
        -- sicher, weil der Zeilen-Check (P, unten) VORHER prueft -- fuer Weg A gab es diesen Schutz nie,
        -- und er ist hier auch nicht nachruestbar: der Zeilen-Check lief am 06.08. unmittelbar NACH dem
        -- Absturz und meldete OHNE_ITEM=0, die leere Zeile existiert also nur WAEHREND des Calls
        -- (die Engine leert sie beim Abbuchen der Reserve selbst). Eine Pruefung davor kann das nie sehen.
        -- Der volle Fall geht damit ebenfalls ueber (P)+(N): inv:reload laedt die Menge n UND zieht die
        -- Reserve selbst (s. Kommentar an Z.717) -- kein Funktionsverlust beim Nachladen, nur der
        -- ungeschuetzte Eingang faellt weg. (__re4_exec_reload ist am 12.08. ganz entfernt worden --
        -- es rief es niemand mehr, und der Call selbst ist ein Vollcrash.)
        -- Nach dem fehlgeschlagenen Weg A lief frueher noch der ganze Rest (N/R/C) auf einem Zustand
        -- weiter, den die Engine gerade mit einer AV verlassen hatte -- das duerfte der Grund sein,
        -- warum das Spiel danach hart gestorben ist (kein zweiter Dump, Log endet 40 s spaeter).
        if refill ~= true and is_full then
        end
        -- =========================================================================================
        -- [WEG C -- NACHBAU 2026-08-01, "wir lesen doch nur das Inventar nach Ammo und hauen es
        -- in die Waffe rein"] Genau das. Und zwar ABGESCHAUT statt geraten: re4_ammo_watch.log hat
        -- mitgeschnitten, was die Engine INNERHALB ihres eigenen inv:reload(menge=1) tut -- es sind
        -- exakt zwei Calls, mehr nicht:
        -- CALL WeaponItem.add obj=22742330 arg=1 8 -> 9 | HUD=9
        -- CALL Item.reduceCount obj=27901C70 45 -> 44
        -- Beide bauen wir hier nach:
        -- 1. addAmmoCount(menge,false) auf DER Instanz, auf der die Engine arbeitet -- das ist
        -- __re4_live_wi aus dem Hook-Cache (add_wi oben). Im Log zieht die HUD SOFORT mit; genau
        -- daran ist der Direktweg frueher gescheitert, weil er auf einer Kopie schrieb.
        -- 2. reduceCount(menge) auf der ECHTEN Item-Zeile der passenden Munition. Welche das ist,
        -- sagt die Waffe selbst: get_CurrentAmmo liefert die ItemID -- keine eigene Zuordnung,
        -- keine Tabelle, kein Raten. __re4_safe_reduce kennt den Weg ueber getInventoryItemList.
        -- Gemessen wird an der HUD (pe:getCurrentGunAmmo): steigt sie, war es echtes Laden -- und NUR
        -- dann wird die Reserve gezogen, und zwar um exakt die Menge, die wirklich angekommen ist.
        -- Kein nativer inv:reload -> der Call, der im Log die Zeile vor dem Absturz war, faellt weg.
        -- =========================================================================================
        -- [LOOP-RELOAD GEHOERT DER ENGINE 2026-08-01] Vor Weg C. Bei Schuss-fuer-Schuss-Waffen hat unser
        -- Nachbau im Log AUSNAHMSLOS nichts bewirkt (4 von 4), waehrend die Reserve trotzdem gebucht wurde
        -- -- also genau der Munitionsverlust, den man sieht. Statt weiter auf eine Item-Instanz zu
        -- schreiben, die die Engine ohnehin verwirft, wird hier ihr eigener Nachladevorgang angestossen.
        -- Sie laedt dann Schuss fuer Schuss UND bucht die Reserve selbst -> danach ist hier Schluss:
        -- KEIN Weg C, KEIN eigener Reserve-Abzug (sonst doppelt).
        -- [LOOP-RELOAD-ZWEIG KOMPLETT ENTFERNT 2026-08-01, "der crash call kommt wieder raus, sofort"]
        -- Hier lagen vier Versuche fuer Schuss-fuer-Schuss-Waffen, alle an diesem Abend gemessen und alle
        -- gescheitert -- damit sie nicht noch einmal gebaut werden:
        -- execReloadStart -> laeuft durch (ok=true), laedt nichts.
        -- inv:equip vor dem Laden -> ueberfluessig, der Slot IST belegt (Slot-Waffe=6001 im Log).
        -- enableReloadItem-Probe -> liefert false bzw. ERR fuer JEDE Menge und beide refill-Werte.
        -- nativer inv:reload -> der Call, der abstuerzt. Raus auf Ansage, und zu Recht: er hat
        -- das Problem nie geloest, sondern nur verschoben.
        -- Ebenfalls widerlegt: __re4_sync_gun_ammo (updateGunAmmo) nach addAmmoCount -- der Sync lief,
        -- das Item stieg 0->4, die HUD blieb 0. Die Instanz mit der richtigen WeaponId ist nachweislich
        -- NICHT die, aus der die Waffe ihren Ladestand nimmt.
        -- Stand: fuer loopReload-Waffen gibt es derzeit KEINEN funktionierenden Ladeweg. Alter Code:
        -- others/re4_vr_reload.bak_2026-08-01_pre_loopblock_removal.lua
        -- =========================================================================================
        -- [NATIVER RELOAD ZURUECK + CRASH-SCHUTZ 2026-08-01, "bau es zurueck und schuetze alles"]
        -- Der native inv:reload ist der EINZIGE Call, der eine bestimmte Menge laedt und dabei wirkt --
        -- deshalb kommt er zurueck. Neu ist, dass wir jetzt WISSEN, woran er stirbt.
        --
        -- Am laufenden Spiel disassembliert (Modulbasis 0x140000000, RIP re4+0x233ef9b):
        -- mov rax, [rbx+0x18]; rax = eine Inventar-Zeile (InventoryItemBase)
        -- mov rcx, [rax+0x10]; rcx = Zeile.Item <-- NULL
        -- mov r8d, [rcx+0x28]; will Item._ItemId lesen -> c0000005, RCX=0
        -- Belegt ueber die Feld-Offsets: InventoryItemBase.<Item> liegt auf +0x10, Item._ItemId auf +0x28.
        -- Der Reload laeuft also ueber die Inventar-Zeilen und liest von jeder die ItemID. Trifft er eine
        -- Zeile OHNE Item, greift er auf Adresse 0x28 zu und das Spiel ist weg.
        -- Das ist kein Mengen-, Munitions- oder Timing-Problem -- deshalb hat es kein Log je gezeigt.
        --
        -- SCHUTZ: vorher genau diese Bedingung pruefen. Reine Getter, kein Schreiben, kein Deref auf
        -- etwas Ungepruefte. Findet sich eine leere Zeile, wird der Call NICHT gefeuert.
        -- FORENSIK: die Pruefzeile geht VOR dem Call synchron auf die Platte (io.open/close pro Zeile).
        -- Crasht es trotzdem, ist die letzte Zeile im Log der exakte Zustand, der es ausgeloest hat --
        -- dann war der Absturz wenigstens nicht umsonst.
        -- =========================================================================================
        local rows_n, rows_bad, rows_ok = 0, 0, false
        do
            rows_ok = pcall(function()
                local list = inv and inv:call("getInventoryItemList()")
                rows_n = list and (tonumber(list:call("get_Count")) or 0) or 0
                for i = 0, rows_n - 1 do
                    local row = list:call("get_Item", i)
                    if row then
                        local it = row:call("get_Item")
                        if it == nil then rows_bad = rows_bad + 1 end
                    end
                end
            end)
        end
        -- [WEG N RAUS 2026-08-06 -- zweiter Crash desselben Tages] Der native inv:reload wird NICHT
        -- mehr gefeuert. Beweis, warum der Zeilen-Check (P) ihn NIE schuetzen konnte:
        -- Reload-Log 18:15:58 -> (P) lesbar=true zeilen=35 OHNE_ITEM=0 [sauber!]
        -- (N) inv:reload(10,false) ok=false [= die AV]
        -- Framework-Log -> RIP 14233ef9b, RCX=0, "Exception... CsInventoryController.reload"
        -- Also exakt die Instruktion aus Z.676-682 -- OBWOHL unmittelbar davor jede der 35 Zeilen ein
        -- Item hatte. Die leere Zeile entsteht damit WAEHREND des Calls (die Engine leert sie beim
        -- Abbuchen der Reserve selbst); eine Pruefung davor kann das prinzipiell nicht sehen.
        -- Damit sind BEIDE nativen Ladewege erledigt: execReload (14:17 Uhr) und inv:reload (18:15 Uhr)
        -- sterben an derselben Stelle. Uebrig bleibt Weg C weiter unten -- der laeuft NICHT ueber die
        -- Inventar-Zeilenschleife der Engine, sondern setzt den Reload-State und schreibt Ammo direkt.
        -- Der Zeilen-Check (P) bleibt als reine Messung stehen: er sagt uns weiterhin, wie das Inventar
        -- VOR dem Laden aussah -- nur eben ohne daran eine Ladeentscheidung zu haengen.
        if rows_ok and rows_bad == 0 and et and inv then
        elseif rows_bad > 0 then
            -- Genau der Zustand, der abstuerzt. Nicht laden -- und sagen, dass es passiert ist.
        end
        if add_wi then
            local hud_b = gun_ammo() or before
            -- Beide Varianten des zweiten Parameters, in DERSELBEN Reihenfolge wie rotary.do_load
            -- (der Shotgun-Pfad, der seit Wochen nachweislich laedt): erst true, dann false.
            -- Zweiter Versuch nur, wenn der erste die HUD nicht bewegt hat -> nie doppelt geladen.
            -- [SYNC WAR NIE VERDRAHTET 2026-08-01, -Log: "Item stieg 0->2, HUD blieb bei 0"]
            -- addAmmoCount schreibt NUR ins Item. Die Runtime-Gun -- das, was HUD, Feuern und unsere
            -- eigene Dry-Fire-Erkennung lesen -- wird davon nicht angefasst. Genau deshalb galt der
            -- Item-Write immer als "verpufft" und nur der native reload als der einzige Weg, der wirkt.
            -- Die Sync-Funktion dafuer steht seit 2026-07-31 im Code (__re4_sync_gun_ammo ->
            -- PlayerEquipment.updateGunAmmo) und wurde NIE aufgerufen -- an keiner einzigen Stelle.
            -- Das ist der fehlende Schritt zwischen "Item voll" und "Waffe geladen".
            -- [ALLE INSTANZEN, NICHT NUR DER CACHE 2026-08-01, "es gibt einen Weg"]
            -- Bisher ging JEDER Schreibversuch auf `add_wi` -- den Hook-Cache. Die anderen drei
            -- Instanzen, die in jeder Logzeile als cap-Quelle mit 6 auftauchen und damit nachweislich
            -- leben, waren nie Schreibziel, sondern nur Messgroesse. Live live geprueft, warum das
            -- ueberhaupt mehrere sind: `pe:getEquipWeaponItem` reicht eine FLUECHTIGE Huelle heraus
            -- (beim zweiten Zugriff nicht mehr aufloesbar), und `chainsaw.Gun` -- die Runtime-Waffe --
            -- hat ueberhaupt kein Ammo-Feld. Die Munition liegt also in genau einer dieser WeaponItem-
            -- Instanzen, und wir haben bisher auf die falsche geschrieben.
            -- Deshalb: der Reihe nach ueber alle vier, nach JEDEM Schreiben synchronisieren und an der
            -- HUD messen. Sobald sie steigt, ist Schluss -- also nie doppelt geladen. Welche Instanz
            -- gewonnen hat, steht danach im Log; damit ist die Frage ein fuer alle Mal beantwortet.
            -- [INSTANZ-DURCHLAUF WIEDER RAUS 2026-08-01 -- HAT HART GECRASHT] Hier stand ein Durchlauf
            -- ueber alle vier WeaponItem-Instanzen. Er hat einen Full-Crash ausgeloest, und zwar aus
            -- einem Grund, der vorher schon gemessen war: `pe:getEquipWeaponItem` reicht eine
            -- FLUECHTIGE Huelle heraus, die beim naechsten Zugriff nicht mehr aufloesbar ist (live
            -- bestaetigt: "Could not resolve object"). Ein `:call` darauf ist ein virtueller Call ins
            -- Leere -> c0000005, und pcall faengt eine AV NICHT.
            -- REGEL DARAUS: Auf eine WeaponItem-Instanz wird NUR geschrieben, wenn sie aus dem
            -- addAmmoCount/reduceAmmoCount-Hook stammt (`__re4_live_wi`). Alle anderen sind Messgroesse,
            -- niemals Schreibziel -- auch nicht "nur zum Ausprobieren".
            -- [RELOAD-STATE ZUERST 2026-08-01 -- live live am Skull Shaker gemessen]
            -- DER fehlende Schritt. Am laufenden Spiel nachgewiesen:
            -- State None + execReload -> nichts passiert (wochenlang genau dieses Bild)
            -- Gun.onReloadStart -> State Reload
            -- dann laden -> Munition landet in der Waffe (hud 0 -> 6)
            -- Unser addAmmoCount hat also nie verpufft, weil die Instanz falsch war -- sondern weil die
            -- Waffe gar nicht im Ladevorgang war. Die Engine bucht Munition nur im Reload-State.
            -- Wichtig: `pe:getEquipWeapon` liefert eine STABILE Gun-Instanz (live mehrfach
            -- angesprochen), im Gegensatz zu `getEquipWeaponItem`, das eine fluechtige Huelle ist --
            -- die bleibt weiterhin tabu als Ziel.
            -- [ADD_WI_TOT 2026-08-06] NICHT auf eine Leiche schreiben. Die Antwort steht schon in der
            -- cap-Messung oben (add_wi=nil = tot). Lieber ein verpasster Reload als ein Full-Crash --
            -- der Aufrufer bekommt false und kann es im naechsten Frame erneut versuchen, bis der
            -- addAmmoCount-Hook wieder eine lebende Instanz gecacht hat.
            -- [AUSWEICHEN STATT AUFGEBEN 2026-08-06, "Blacktail laedt nicht, ich stecke ein Mag
            -- rein aber kein Ammo"] Log 4840.86: `add_wi=nil` (Leiche), waehrend wi_live/equip/inv alle
            -- 13 melden -- es LEBEN also Instanzen, wir haben sie nur nicht benutzt. Statt abzubrechen,
            -- auf die Slot-Waffe `w` (inv:getEquippedWeapon(et)) ausweichen und wie gehabt an der HUD
            -- messen. Bewusst NUR diese eine: der Instanz-Durchlauf vom 01.08. hat hart gecrasht, aber
            -- an `pe:getEquipWeaponItem` -- der fluechtigen Huelle, die tabu bleibt. `w` stammt aus
            -- dem InventoryController und ist eine andere Quelle. Verpufft der Schreibvorgang, sieht man
            -- das an der HUD (dann greift die forceSet-Kette darunter) -- schlimmstenfalls passiert
            -- nichts, statt dass die Waffe gar nicht erst laedt.
            if rawget(_G, "__re4_addwi_alive") == false and w ~= nil
               and safe(function() return w:call("get_CurrentAmmoMax") end) ~= nil then
                _G.__re4_live_wi = nil   -- Leiche loswerden, damit der Hook sie neu fuellen kann
                add_wi = (_G.__re4_real_wi and _G.__re4_real_wi()) or w   -- [ACCESSOR] echte Instanz vor der Kopie
                _G.__re4_addwi_alive = true
            end
            if rawget(_G, "__re4_addwi_alive") == false then
                -- [SELBSTHEILUNG 2026-08-06, "eine Waffe kann nicht NICHT laden"] Nicht nur
                -- abbrechen: die Leiche AUS DEM CACHE werfen. add_wi = `__re4_live_wi or wi_live` --
                -- solange der tote Cache belegt ist, wird die lebende Alternative gar nicht erst
                -- genommen (Log: add_wi=nil, waehrend wi_live/equip/inv alle 10 melden). Cache leer ->
                -- naechster Versuch nimmt wi_live und laedt. Die Leiche selbst wird NICHT angefasst.
                -- Aufgefuellt wird der Cache sonst vom sdk.hook auf get_CurrentAmmoCount -- und der ist
                -- nach mehrfachem "Reset Scripts" erfahrungsgemaess tot (sdk.hook braucht GAME-Neustart),
                -- deshalb darf sich der Ladeweg nicht darauf verlassen.
                _G.__re4_live_wi = nil
                _G.__re4_live_wi_t = nil
                _G.__re4_reload_direct_fail = (tonumber(rawget(_G, "__re4_reload_direct_fail")) or 0) + 1
                return false
            end
            local gun_obj = safe(function() local p = _G.__re4_pe and _G.__re4_pe(); return p and p:call("getEquipWeapon") end)
            -- [ALTERNIEREND 2026-08-06, "bei jedem ZWEITEN Mal laedt die LE5 nicht"] Log-Muster
            -- belegt (294.24 fail / 299.45 ok / 306.81 fail): bei den Fehlschlaegen bewegt sich die HUD
            -- durch KEINEN der beiden addAmmoCount-Versuche. Verdacht: der Reload-State der Waffe bleibt
            -- nach unserem Laden stehen, dann ist onReloadStart beim naechsten Mal wirkungslos.
            -- NICHT raten -- messen: den State-Getter der Gun VOR und NACH onReloadStart mitschreiben.
            -- Der Name ist nicht sicher bekannt, deshalb mehrere Kandidaten per pcall; der erste, der
            -- antwortet, kommt ins Log. Reine Getter, kein Schreiben, kein Verhaltenswechsel.
            local function gun_state_str()
                if not gun_obj then return "keine Gun" end
                for _, m in ipairs({ "get_ReloadState", "get_State", "get_GunState", "get_ActionState", "get_ReloadType" }) do
                    local ok, v = pcall(function() return gun_obj:call(m) end)
                    if ok and v ~= nil then
                        local n = nil
                        if type(v) == "number" then n = v else pcall(function() n = v:get_field("value__") end) end
                        return string.format("%s=%s", m, tostring(n ~= nil and n or v))
                    end
                end
                return "kein State-Getter gefunden"
            end
            -- [LEERES MAG 2026-08-06, "Blacktail, nichts geht rein"] Log 4971.65: hud=0 item=0, und
            -- ALLE VIER Schreibwege (add true/false, forceSet, setAmmoCount) verpuffen. Gestern liefen
            -- alle erfolgreichen Reloads mit TEILGEFUELLTEM Magazin (51/46/40) -- der Unterschied ist also
            -- der Leer-Zustand. Passt zum [LAST-ROUND-FIX 2026-07-18]: bei leerer Waffe schreibt
            -- addAmmoCount nur eine Kopie, die Runtime-Gun bleibt 0.
            -- Neue Spur aus dem API-Dump: `setAmmoId(chainsaw.ItemID)`. Bei leerem Magazin hat die Waffe
            -- moeglicherweise gar keine gueltige Munitionssorte gesetzt -- dann weiss addAmmoCount nicht,
            -- WAS es addieren soll. Also vorher die ID setzen, die die Reserve-Messung ermittelt hat
            -- (dieselbe, die danach auch abgebucht wird). Nur im Leer-Fall, damit ein laufender
            -- Teil-Reload unveraendert bleibt.
            if (tonumber(hud_b) or 0) <= 0 then
                local _aid0 = rawget(_G, "__re4_reserve_aid")
                -- [KEIN FREMDSCHREIBEN 2026-08-12] Dieser Aufruf ist der gefaehrlichste im ganzen Weg: er
                -- schreibt eine Munitionssorte FEST auf das Waffen-Item. Landet dort einmal eine fremde ID,
                -- meldet die Waffe sie danach selbst zurueck ("Killer7 laedt Riflepatronen") und der Fehler
                -- haelt sich von allein am Leben. Geschrieben wird deshalb nur, wenn die ID nachweislich von
                -- einer Instanz DIESER Waffe stammt (WeaponId-Abgleich in der Reserve-Messung).
                local _aw = tonumber(rawget(_G, "__re4_reserve_aid_wid"))
                local _sw = tonumber(rawget(_G, "__re4_reload_ui_wid"))
                -- [UNBEWEISBAR = NICHT SCHREIBEN 2026-08-12] soll_wid ist im Log oft `nil` -- dann konnte
                -- die Herkunft der ID NIE geprueft werden und der Schutz lief leer. Ab jetzt gilt: ohne
                -- Beweis (beide WeaponIds lesbar UND gleich) wird nichts auf das Waffen-Item geschrieben.
                if _aid0 ~= nil and (not _sw or not _aw or _aw ~= _sw) then
                elseif _aid0 ~= nil then
                    local _ok_sid = pcall(function() add_wi:call("setAmmoId(chainsaw.ItemID)", _aid0) end)
                end
            end
            local _st_before = gun_state_str()
            if gun_obj then pcall(function() gun_obj:call("onReloadStart") end) end
            local carry_add = 0   -- [MAG-CARRY] gutgeschriebene, bereits bezahlte Patronen (nie in `got`)
            -- [MAG-CARRY 2026-08-12] Der beim Auswurf gemerkte Magazinrest kommt hier wieder drauf --
            -- er kostet KEINE Reserve (die wurde damals schon beim Laden dieser Patronen abgebucht),
            -- deshalb nur die Menge fuer die Waffe erhoehen, nicht `n`. Auf die Kapazitaet gedeckelt,
            -- und nur fuer dieselbe Waffe. Danach ist der Merker verbraucht.
            -- [ABBRUCH-SICHER 2026-08-12] Dieser Block hat den ganzen Ladeweg gerissen: er rief
            -- `get_equip_wid()`, das hier gar nicht existiert -> Fehler mitten im Reload, und im Log
            -- endete alles nach der [STATE]-Zeile. Sichtbar war es als "der erste Reload nach dem
            -- Magazinwechsel laedt nichts, der zweite schon" (beim zweiten war der Merker leer, also
            -- lief der Block nicht). Jetzt komplett in pcall, und die Waffen-ID kommt aus der Instanz,
            -- die hier ohnehin beschrieben wird.
            pcall(function()
                local carry = tonumber(rawget(_G, "__re4_mag_carry")) or 0
                if carry > 0 then
                    local cwid2 = tonumber(rawget(_G, "__re4_mag_carry_wid"))
                    local nowid = nil
                    pcall(function()
                        local v = add_wi:call("get_WeaponId")
                        nowid = (type(v) == "number") and v or tonumber(v:get_field("value__"))
                    end)
                    if cwid2 == nil or nowid == nil or cwid2 == nowid then
                        local room = (tonumber(cap) or 0) - got
                        if room < 0 then room = 0 end
                        local give = (carry < room) and carry or room
                        -- [NICHT AUF got 2026-08-13] Der Merker darf NUR die Lademenge erhoehen, nicht `got`:
                        -- mit `got` wird weiter unten die RESERVE abgebucht. Aufaddiert hat die Waffe zwar
                        -- richtig geladen (18 + 12 = 30), aber es wurden auch 30 statt 12 abgezogen -- die
                        -- schon bezahlten Patronen ein zweites Mal (Log 00:54:27: "Summe 30 -> 0").
                        carry_add = give
                    end
                end
                _G.__re4_mag_carry, _G.__re4_mag_carry_wid = nil, nil
            end)
            pcall(function() add_wi:call("addAmmoCount(System.Int32, System.Boolean)", got + carry_add, true) end)
            if _G.__re4_sync_gun_ammo then _G.__re4_sync_gun_ammo() end
            local hud_a = gun_ammo() or hud_b
            local _how = "add(true)"
            if (tonumber(hud_a) or 0) <= (tonumber(hud_b) or 0) then
                pcall(function() add_wi:call("addAmmoCount(System.Int32, System.Boolean)", got + carry_add, false) end)
                if _G.__re4_sync_gun_ammo then _G.__re4_sync_gun_ammo() end
                hud_a = gun_ammo() or hud_b
                _how = "add(false)"
            end
            -- [FORCE_SET 2026-08-06, "bei jedem ZWEITEN Mal laedt die LE5 nicht"] Dritter Anlauf,
            -- erst wenn BEIDE addAmmoCount-Varianten die HUD nicht bewegt haben (Log-Muster 294.24 fail /
            -- 299.45 ok / 306.81 fail -- exakt jedes zweite Mal). addAmmoCount ist additiv und haengt
            -- offenbar am Reload-Zustand der Waffe; `forceSetAmmoCount` setzt den Ladestand ABSOLUT.
            -- Beide Setter stehen erst seit dem API-Dump vom 06.08. ueberhaupt zur Verfuegung
            -- (chainsaw.WeaponItem: setAmmoCount / forceSetAmmoCount / getReloadableCount) -- vorher war
            -- addAmmoCount der einzige bekannte Weg. Ziel = alter Stand + gewollte Menge, gedeckelt auf
            -- die Kapazitaet, damit hier nie mehr landet als reinpasst. Rein additiv zum bisherigen
            -- Ablauf: laeuft der erste oder zweite Versuch, wird das hier nie erreicht.
            if (tonumber(hud_a) or 0) <= (tonumber(hud_b) or 0) then
                -- [MAG-CARRY] gutgeschriebene Patronen gehoeren in die LADEMENGE (wie bei addAmmoCount).
                local want_abs = math.min((tonumber(hud_b) or 0) + got + carry_add, (cap > 0) and cap or ((tonumber(hud_b) or 0) + got + carry_add))
                pcall(function() add_wi:call("forceSetAmmoCount(System.Int32)", want_abs) end)
                if _G.__re4_sync_gun_ammo then _G.__re4_sync_gun_ammo() end
                hud_a = gun_ammo() or hud_b
                _how = string.format("forceSet(%d)", want_abs)
                -- Greift auch das nicht, den weicheren Setter probieren (ohne "force").
                if (tonumber(hud_a) or 0) <= (tonumber(hud_b) or 0) then
                    pcall(function() add_wi:call("setAmmoCount(System.Int32)", want_abs) end)
                    if _G.__re4_sync_gun_ammo then _G.__re4_sync_gun_ammo() end
                    hud_a = gun_ammo() or hud_b
                    _how = string.format("setAmmoCount(%d)", want_abs)
                end
            end
            local loaded = math.max(0, (tonumber(hud_a) or 0) - (tonumber(hud_b) or 0))
            if loaded > 0 then
                -- [AMMO-ID AUS DER KETTE 2026-08-06, "reserve abzug lief NIE"] Die ID kam bisher NUR
                -- aus add_wi -- genau der Instanz, die tot sein kann (Log: "add_wi=nil" bei lebendem
                -- wi_live/equip/inv). Dann war aid nil oder eine ID, die zu KEINER Inventarzeile passt
                -- -> "Zeilen=36 passende=0 bewegt=0 | Summe blieb 0", waehrend die MESSUNG oben im selben
                -- Vorgang reserve=20 sah. Fuer die Messung wurde das am 01.08. laengst behoben (Z.602-613),
                -- beim Abzug nie -- deshalb hier dieselbe Kandidatenkette, erste brauchbare gewinnt.
                -- Brauchbar heisst: die ID findet im Inventar tatsaechlich Munition (count_sum > 0);
                -- eine ID, die auf 0 zeigt, waere genau der stille Fehlschlag von bisher.
                -- [PHANTOM-RESERVE 2026-08-06] KEINE eigene Suche mehr. Abgezogen wird GENAU die ID, aus
                -- der die Messung oben ihre Reserve gelesen hat (`__re4_reserve_aid`, Slot-Waffe zuerst).
                -- Eine zweite, unabhaengige Kette koennte sonst eine andere Munitionssorte treffen als
                -- die, die gerade als "reserve=N" angezeigt und geladen wurde -- genau so verschwand die
                -- Magnum-Munition, waehrend eine andere Waffe geladen wurde.
                local aid = rawget(_G, "__re4_reserve_aid")
                local red = false
                -- [NICHT DOPPELT ZAHLEN 2026-08-13] `loaded` ist die HUD-Zunahme und enthaelt auch die
                -- gutgeschriebenen Patronen aus dem gedroppten Magazin -- die sind laengst bezahlt.
                -- Abgebucht wird deshalb nur der Teil, der WIRKLICH aus der Reserve kam. Genau das war
                -- der TMP-Fehler: 18 gemerkt + 12 aus der Reserve = 30 geladen, aber 30 abgebucht.
                local pay = math.max(0, loaded - (carry_add or 0))
                if aid ~= nil and inv and pay > 0 then
                    red = (safe(function() return _G.__re4_safe_reduce(inv, aid, pay) end) == true)
                end
                _G.__re4_reload_direct_ok = (tonumber(rawget(_G, "__re4_reload_direct_ok")) or 0) + 1
                return true
            end
        end
        -- [RETTUNG 2026-08-06, "nichts geht mehr rein"] Der Nachbau haengt an EINER Referenz
        -- (__re4_live_wi, gefuellt vom addAmmoCount-Hook). Geht die verloren -- z.B. nach einem
        -- Save-Load -- schreiben wir nur noch auf Kopien und die Waffe laedt GAR NICHT mehr. Belegt:
        -- Log 5116.00, SG-09 mit hud=7 (nicht leer), add_wi=nil bei wi_live/equip/inv=18, alle fuenf
        -- Schreibwege wirkungslos. Als alleiniger Ladeweg ist der Nachbau damit untauglich.
        -- Deshalb hier der native Reload als LETZTE Instanz -- aber nur, wenn der Nachbau nachweislich
        -- nichts bewirkt hat (HUD unveraendert). Im Normalfall wird diese Zeile nie erreicht, das
        -- Crash-Risiko der Engine-Suchschleife trifft also nur noch die Ausnahme statt jeden Reload.
        -- Der Zeilen-Check (P) bleibt als Minimalabsicherung davor: bei einer bereits leeren Zeile
        -- wird gar nicht erst gefeuert.
        -- =====================================================================================
        -- [GELOESCHT 2026-08-12 14:26] Hier lag der (RETTUNG)-Zweig: der native
        -- `inv:reload(EquipType, Int32, Boolean)` als "letzte Instanz", falls der Nachbau nichts
        -- bewirkt hat. Der Bogen lief AUSSCHLIESSLICH hierueber (Log: "[RE4-RETTUNG] nativer
        -- inv:reload(1) BENUTZT" #1..#5) und ist beim 5. Mal mit einer Access Violation
        -- abgestuerzt -- Muster A, exakt der Crash, den wir seit Wochen jagen.
        -- ERSATZLOS RAUS, nicht hinter ein Flag: der Call ist toedlich und mit dem Accessor-Weg
        -- (get_live_weapon_item -> __re4_real_wi) auch nicht mehr noetig.
        -- Laedt eine Waffe nicht, steht "(C) Nachbau ohne Wirkung" im Log -- ein verpasster
        -- Reload, kein Crash. Alte Fassung: others/re4_vr_reload.bak_2026-08-12_pre_accessor.lua
        -- =====================================================================================
        -- [NATIVER RELOAD AUSGEBAUT 2026-08-01] Hier lag Weg B: der native
        -- chainsaw.CsInventoryController.reload, vorgemerkt fuer LateUpdateBehavior. ERSATZLOS RAUS --
        -- samt Checkbox, Reentranz-Sperre und Warteschlange. Belegt im Log als die Zeile vor dem Absturz
        -- ("(B/late) inv:reload(20) ok=false" -- die einzige ok=false der ganzen Sitzung), und seit Weg C
        -- nicht mehr noetig: der laedt exakte Mengen (Red9 +1) und zieht die Reserve.
        -- Laedt etwas nicht, steht "(C) Nachbau ohne Wirkung" im Log -- ein verpasster Reload, kein Crash.
        _G.__re4_reload_direct_fail = (tonumber(rawget(_G, "__re4_reload_direct_fail")) or 0) + 1
        return false
    end
    _G.__re4_reload_direct_fail = (tonumber(rawget(_G, "__re4_reload_direct_fail")) or 0) + 1
    return false
end
-- [GELOESCHT 2026-08-12] Hier lag der auskommentierte alte native Reload-Weg
-- (inv:reload samt Reentranz-Sperre und drain/refill-Zweig). Toter Code mit scharfem
-- Call -- raus statt aufbewahrt. Alte Fassung: others/*_pre_accessor.lua

local function slide_pose(wid)
    local sp = SLIDE_POSE[wid]
    if not sp then
        sp = {}
        for k, v in pairs(SLIDE_POSE_DEFAULT) do sp[k] = v end
        SLIDE_POSE[wid] = sp
    end
    -- fehlende Felder (aus alter JSON) mit Default auffuellen
    for k, v in pairs(SLIDE_POSE_DEFAULT) do if sp[k] == nil then sp[k] = v end end
    return sp
end
-- [EMPTY-RELOAD SLIDE] Riot Gun: nach Leerschuss (auf 0) + Reload wird NICHT gepumpt, sondern an einem
-- EIGENEN Lade-Slide-Joint (_08) nach hinten gezogen (pistolen-artig: ziehen -> loslassen -> schnappt
-- vor -> chambert). Eigene Travel-Pose (rest/park/back/dock) + eigene Hand-Pose. NUR dieser Sonderfall;
-- zwischen den Schuessen bleibt alles Pump (_01).
local SLIDE_POSE2 = {}
local function slide_pose2(wid)
    local sp = SLIDE_POSE2[wid]
    if not sp then sp = {}; for k, v in pairs(SLIDE_POSE_DEFAULT) do sp[k] = v end; SLIDE_POSE2[wid] = sp end
    for k, v in pairs(SLIDE_POSE_DEFAULT) do if sp[k] == nil then sp[k] = v end end
    return sp
end
local EMPTY_RELOAD_JOINT = { [4101] = "_08" }   -- [wid] = Lade-Slide-Joint fuers Chambern nach Leerschuss+Reload
-- [SHELL_PART_FIX] Waffen die den Shell-Sub-Mesh-Part-Trick (Lern-Diff) nutzen, ohne _08-Lade-Slide.
local SHELL_PART_LEARN = {}   -- (Lern-Diff-Pfad; aktuell keine Waffe -> Riot Gun laeuft ueber EMPTY_RELOAD_JOINT)
-- HINWEIS: Skull Shaker (6001) rendert seine Huelse NICHT als statischen Sub-Mesh-Part, sondern ueber
-- die Engine-Komponente chainsaw.ShotgunShellGenerator (prozedural). Part-Toggle/Force ist daher
-- WIRKUNGSLOS -> getragene Shell muss ueber den Generator/eigene Instanz geloest werden (offen).
-- [SHELL_PART_PERSIST] Gelernter Shell-Part-Index pro WeaponID (nur Lern-Diff-Pfad) -> auf Disk gesichert.
local SHELL_PARTS = {}
-- [SHELL_PART_FIXED 2026-07-18] FEST bestaetigter Shell-Sub-Mesh-Part fuer Static-Mesh-Shotguns, die NICHT
-- ueber den Lern-Diff laufen (kein EMPTY_RELOAD_JOINT/SHELL_PART_LEARN). Striker (4102): Part 1 LIVE
-- verifiziert (A/B-Test: Force Part 1 -> Huelse in der Hand sichtbar). Deckungsgleich mit dem Skull-Shaker-
-- Clone (isoliert Part 1) -> Part 1 = Huelse ueber die Shotgun-Modelle. Fallback in sg_mesh, wenn nichts gelernt.
local SHELL_PART_FIXED = { [4102] = { 1 } }
-- [SHELL_SPAWN] Waffen deren getragene Huelse NICHT als statischer Mesh-Part existiert (die Engine
-- generiert die Kammer-Huelse prozedural via chainsaw.ShotgunShellGenerator -> bei 0 Ammo ist NICHTS
-- da zum Forcen). Loesung: wir instanziieren das Shell-Prefab der Waffe (_UserData._Prefab) EINMAL
-- und docken die Instanz jeden Frame an die _04-Joint-Weltpose (die folgt via mag_to_hand der Hand).
-- Skull Shaker (6001) nutzt JETZT den Part-1-Mesh-Clone (s. [SHELL_CLONE] weiter unten) statt der
-- gespawnten Prefab -> daher hier NICHT mehr gelistet (Tabelle leer, kein Prefab-Spawn mehr).
local SHELL_SPAWN = {}
-- [SHELL_CLONE] Skull Shaker (6001): die getragene Shell (Mag-Holster -> Hand) ist ein MESH-CLONE
-- von Part 1 der Waffe (Technik wie reload2-Revolver: Motion+Mesh+setMesh+Material+Part isolieren),
-- KEIN Joint/Prefab mehr. Eigene Hand-Offsets, weil der Clone anders liegt als der alte _04-Joint.
-- preview = UI-Vorschau zum Tunen. Als Global -> kein Main-Chunk-Local (reload.lua ist voll).
_G.__re4_ss_clone = _G.__re4_ss_clone or { part = 1, x = 0.0, y = 0.0, z = 0.0, rx = 0.0, ry = 0.0, rz = 0.0, scale = 1.0, preview = false }
-- [NO_CYCLE_AFTER_SHOT] Waffen die NACH dem Schuss KEIN Cyceln brauchen (frei ballern bis 0). Der Cycle
-- ist NUR Teil des Ladens (nach jeder Einfuehrbewegung). Striker = Drehschalter nur beim Nachladen.
local NO_CYCLE_AFTER_SHOT = { [4101] = true, [4102] = true, [6001] = true }   -- Riot Gun (2026-07-16: ist AUTO/semi-auto, kein Pump), Striker + Skull Shaker: frei ballern bis 0 (kein Cock/Pump zwischen Schuessen; Block nur bei leer -> Leer-Rack ueber _08/EMPTY_RELOAD_JOINT bleibt).
-- [NO_RELOAD_CYCLE 2026-07-17] Waffen die nach einem TAKTISCHEN Shell-Insert (noch geladen) KEINEN
-- Cycle/Pump brauchen -> frei weiterballern; nur der 0-Reload chambert (bei der Riot Gun per Slide-Rack _08).
-- NUR die Riot Gun (4101)! NICHT NO_CYCLE_AFTER_SHOT nehmen -- da stehen auch Striker (4102, braucht den
-- Drehschalter-Cycle nach JEDER Shell) und Skull Shaker (6001, Break-Action-Cock) drin, die ihren Reload-
-- Cycle behalten MUESSEN. W-870 (4100, echte Pump-Gun) ist ohnehin nicht hier -> Pump bleibt.
-- [PARENT-RAUM-DOCK 2026-07-23] NUR diese Waffen: Mag-Joint _04 an einem anderen Parent als
-- die Pistolen -> Einleit-Punkt muss ueber die Joint-Lage in den Parent-Raum. Alle anderen nicht.
local PARENT_SPACE_DOCK = { [4200] = true, [6104] = true }
local NO_RELOAD_CYCLE = { [4101] = true }
-- [DRYFIRE_ONLY_WHEN_EMPTY] Feuer-Block/Dry-Fire NUR bei wirklich leerer Waffe (nicht nach Schuss/Drum).
-- Striker (semi-auto Drum) ballert frei bis 0. Andere Shotguns: normales Verhalten.
local DRYFIRE_ONLY_WHEN_EMPTY = { [4102] = true }
-- [ROTARY_CYCLE] Waffen deren "slide"-Joint KEIN Z-Slide, sondern ein DREHSCHALTER ist (Striker joint_01).
-- Cycle-Input = Left Grip + Left Trigger (wie LE5-Schalter): joint_01 dreht ~rz Grad, Hand folgt, dann
-- clear_rack (eine Drehung pro geladener Shell). NUR diese Waffen; Pump-/Pistolen-Pfade unberuehrt.
local ROTARY_CYCLE = { [4102] = true }
-- [BREAK_ACTION] Lever/Klappe-Shotguns: slide-Joint ist ein Pitch-Hebel (joint_02), kein Z-Slide.
-- Skull Shaker: Hebel runterklappen (oeffnen) -> Shells oben rein -> hochklappen (schliessen/cocken).
-- BASIS: nur als Flag + aus der Z-Slide-Logik ausgegatet; die eigentliche Mechanik kommt noch.
local BREAK_ACTION = { [6001] = true }
-- Dreh-Euler (Grad) bei voller Drehung; eine Achse setzen. Default 15 Grad um lokales Z -> per UI tunen.
-- grab_dist = Abstand Hand->Schalter (m), ab dem gegriffen wird (eigener Wert, NICHT der Pump-Wert).
-- rx/ry/rz=Joint-Rotation bei voll (Rotary: gedreht; Break: aufgeklappt). pitch_range=Controller-Pitch-Grad
-- fuer voll auf<->zu (nur Break). grab_dist=Greif-Distanz. lerp=Dreh-Geschw. (nur Rotary).
local ROTARY_DEFAULT = { rx = 0.0, ry = 0.0, rz = 15.0, grab_dist = 0.15, lerp = 0.06, pitch_range = 55.0 }
-- Per-Waffe-Defaults (JSON ueberschreibt nach Tunen). Striker: RotZ -80. Skull Shaker: Pitch-Klappe (RotX -60 Startwert).
local ROTARY = {
    [4102] = { rx = 0.0, ry = 0.0, rz = -80.0, grab_dist = 0.15, lerp = 0.035 },
    [6001] = { rx = -60.0, ry = 0.0, rz = 0.0, grab_dist = 0.15, lerp = 0.06, pitch_range = 55.0 },
}
local function rotary_cfg(wid)
    local r = ROTARY[wid]
    if not r then r = {}; for k, v in pairs(ROTARY_DEFAULT) do r[k] = v end; ROTARY[wid] = r end
    for k, v in pairs(ROTARY_DEFAULT) do if r[k] == nil then r[k] = v end end
    return r
end
-- Laufzeit: prog 0..1 Dreh-Fortschritt, dir +1=hin/-1=zurueck/0=ruht, preview = UI-Tuning haelt die Drehung
-- _grip_latched = die aktuelle Grip-Haltung gehoert dem Schalter (blockt Two-Hand bis Loslassen+Neugriff)
local rotary = { prog = 0.0, dir = 0, _prev_trig = false, _prev_grip = false, _grip_latched = false, preview = false, _last_dist = -1 }
-- [BREAK_ACTION] Klapphebel-State (Skull Shaker joint_02). RIGHT-B togglet open; prog 0=zu..1=auf (gelerped).
local break_st = { prog = 0.0, open = false, _prev_b = false, _was_open = false, preview = false }
-- Joint-Finder: beliebigen Waffen-Joint live verschieben, um den echten Slide zu finden
local finder = { active = false, name = "_01", idx = 1, x = 0.0, y = 0.0, z = 0.0, base = nil, base_name = nil }

-- Waffen-Namen (WeaponID -> Klarname). Fuer UI-Anzeige aller Pro-Waffe-Settings.
local WEAPON_NAMES = {
    [4000]="SG-09 R", [4001]="Punisher", [4002]="Red9", [4003]="Blacktail", [4004]="Matilda",
    [4005]="Don Quixote", [4100]="W-870", [4101]="Riot Gun", [4102]="Striker", [4200]="TMP",
    [4201]="Chicago Sweeper", [4202]="LE 5", [4400]="SR M1903", [4401]="Stingray",
    [4402]="CQBR Assault Rifle", [4500]="Broken Butterfly", [4501]="Killer7", [4502]="Handcannon",
    [4600]="Bolt Thrower", [4701]="Flamethrower", [4702]="P.R.L. 9412", [4800]="Silent Crossbow",
    [4801]="XJF-350 Compound Bow", [4900]="Rocket Launcher", [4901]="Rocket Launcher (Special)",
    [4902]="Infinite Rocket Launcher", [5000]="Combat Knife", [5001]="Fighting Knife",
    [5002]="Kitchen Knife", [5003]="Boot Knife", [5004]="Water Pipe", [5005]="Giant Rock",
    [5006]="Primal Knife", [5400]="Hand Grenade", [5401]="Heavy Grenade", [5402]="Flash Grenade",
    [5403]="Chicken Egg", [5404]="Brown Chicken Egg", [5405]="Gold Chicken Egg",
    [5500]="Unlimited Bottomless Ammo", [6000]="Sentinel Nine", [6001]="Skull Shaker",
    [6100]="Sawed-off W-870", [6101]="Chicago Sweeper w/ Drum", [6102]="Blast Crossbow",
    [6103]="Blacktail AC", [6104]="MP-AF", [6105]="Anti-Materiel Rifle", [6106]="Rocket Launcher (SW)",
    [6107]="Tactical Knife", [6108]="Elite Knife", [6109]="Scorcher XL", [6110]="XM96E1",
    [6111]="Infinite Rocket Launcher (SW)", [6112]="Punisher MC", [6113]="Samurai Edge",
    [6114]="Hunting Rifle", [6300]="XM96E1 (MC)", [6301]="Blacktail AC (MC)", [6302]="Quickdraw Army",
    [6304]="EJF-338 Compound Bow", [6305]="Hot Dogger",
}
local function weapon_name(wid) return wid and WEAPON_NAMES[wid] or nil end
local function wp_label(wid)
    local n = weapon_name(wid)
    return n and string.format("wp%s (%s)", tostring(wid), n) or ("wp" .. tostring(wid or "-"))
end

-- Waffen-Kategorien (per WeaponID). Pistolen bestaetigt; Rest folgt.
local CATEGORIES = {
    pistols = { [4000]=true, [4001]=true, [4003]=true, [4004]=true, [6000]=true, [4501]=true, [6300]=true, [6301]=true },   -- 4501 = Killer7 (Magnum, mag-fed -> Punisher-Pfad). 6300 = XM96E1 (Mercenaries), 1:1 Punisher-Pfad. 6301 = Blacktail AC (Mercenaries), 1:1 Blacktail-Pfad. 4002 Red9 ausgezogen -> reload2.lua
    -- (4002 Red9 raus: wird komplett eigenstaendig in reload2.lua aufgebaut, reload.lua fasst ihn nicht mehr an)
    smgs    = { [4200]=true, [4202]=true },   -- TMP / LE 5 (Punisher-Klon zum Anpassen). 4201 Chicago Sweeper ausgezogen -> reload3.lua
    shotguns= { [4100]=true, [4101]=true, [4102]=true, [6001]=true },   -- W-870, Riot Gun, Striker, Skull Shaker. CQBR (4402, Rifle) kommt spaeter als eigene Gattung.
    magnum  = {},
    rifles  = {},
}

-- Per-Waffe Joints: mag = Magazin-Joint, slide = Slide-Joint
local JOINTS = {
    [4004] = { mag = "_14", slide = "_01" },   -- Matilda (bestaetigt)
    [4001] = { mag = "_14", slide = "_01" },   -- Punisher: STARTANNAHME (Matilda-Mapping) -> per Cycler/Finder visuell bestaetigen!
    -- [PORT 2026-06-15] 1:1 von Punisher -> per Waffe via Cycler bestaetigen (Joints koennen abweichen!)
    [4000] = { mag = "_14", slide = "_01" },   -- SG-09 R (Punisher-Startannahme)
    [4003] = { mag = "_14", slide = "_01" },   -- Blacktail (Punisher-Startannahme)
    [6000] = { mag = "_14", slide = "_01" },   -- Sentinel Nine DLC (Punisher-Startannahme)
    [4501] = { mag = "_14", slide = "_01" },   -- Killer7 (Punisher-Startannahme -> per Cycler bestaetigen!)
    [6300] = { mag = "_14", slide = "_01" },   -- [MC_6300] XM96E1 (Mercenaries) -- gleicher Mag-/Slide-Joint wie alle Magazinpistolen
    [6301] = { mag = "_14", slide = "_01" },   -- [MC_6301] Blacktail AC (Mercenaries) -- baugleich zu 4003
    [4002] = { mag = "_14", slide = "_01" },   -- Red9: PLATZHALTER (Punisher) -> wp4002 hat KEIN _14 (Top-Fill)! Mag-Joint via Cycler finden, sonst greift der Mag-Drop nicht.
    -- [SMG PORT] Platzhalter (Punisher) -> via SMG-Cycler bestaetigen
    [4200] = { mag = "_04", slide = "_09" },   -- TMP (Mag=_04, Slide=_09)
    -- 4201 Chicago Sweeper ausgezogen -> reload3.lua (reload.lua managed sie nicht mehr; Switch/Burst bleiben in motion.lua)
    [4202] = { mag = "_04", slide = "_02" },   -- LE 5: Mag=_04, Slide=_02 (Slide bei leerem Mag in -Z ziehen)
    -- [SHOTGUN] W-870: mag = SHELL-Joint _04 (folgt der Hand wie ein Mag), slide = PUMP-Joint _01
    -- (linke Hand racked ihn wie einen Slide). Vom visuell bestaetigt.
    [4100] = { mag = "_04", slide = "_01" },   -- W-870 (Pump-Action): Shell=_04, Pump=_01
    [4101] = { mag = "_04", slide = "_01" },   -- Riot Gun (Pump-Action): Shell=_04, Pump=_01 (joint_08-Slide spaeter)
    [4102] = { mag = "_06", slide = "_01" },   -- Striker: Shell-in-Hand=_06, Cycle=_01 (DREHSCHALTER -> Rotation, nicht Z-Slide!)
    [6001] = { mag = "_04", slide = "_02" },   -- Skull Shaker: Shell=_04, slide=_02 = LEVER/Klappe (Pitch auf/zu -> Break-Action, kein Z-Slide)
}

-- [POSE PER WAFFE] Eigene Hand-Posen pro wid (Mag-Halten + Slide-Rack). Fallback = globale
-- CFG.mag_hold_pose / CFG.rack_pose -> Waffen OHNE Eintrag (alle Pistolen) bleiben EXAKT gleich.
-- Nur Waffen mit eigenem Eintrag (z.B. SMGs) nutzen ihre eigene gecapturete Pose.
local MAG_POSE  = { [4202] = "LE5MAG", [4200] = "TMPMAG", [4100] = "Shotgunshell", [4101] = "Shotgunshell", [4102] = "Shotgunshell", [6001] = "Shotgunshell" }   -- [wid] = Pose-Name fuers Mag/Shell-Halten in der linken Hand. SGSHELL = W-870 Shell-in-Hand; noch leer -> bis Capture (via gestures) keine Pose erzwungen (Finger frei).
-- [SKULLRELOAD 2026-07-31] 6001 bewusst OHNE Eintrag: RACK_POSE greift nur bei einem echten Slide-Grab
-- (rack.needs UND rack.grab_active). Der Skull Shaker ist Break-Action und hat keinen -- die Pose waere
-- hier nie angefordert worden. Seine "Skullreload" haengt an der Drehung nach dem Schuss
-- (SKULLSHAKER_COCK_POSE in re4_vr_motion.lua). Die Pose-DATEN wurden aus re4_vr_gestures_capture.json
-- nach re4_vr_reload.json KOPIERT (gestures bleibt reines Capture-Tool).
local RACK_POSE = { [4202] = "LE5MAGSLIDE", [4100] = "SGPUMP", [4101] = "SGPUMP", [4102] = "StrikerReload", [4000] = "MAGRack", [4003] = "MAGRack", [6301] = "MAGRack", [4200] = "rack-slide" }   -- [MC_6301] Blacktail AC = dieselbe Rack-Pose wie 4003   -- [TMP 2026-07-20] TMP-Slide = dieselbe Pose wie der RED9-Slide. Die Red9 nutzt intern "Red9Slide", das ist laut Code eine 1:1-Kopie von "rack-slide" aus re4_vr_reload.json -> Leons Haende. (Vorher stand hier faelschlich "re9shaft" -- das ist die Schaftpose aus dem RE9-Mod, nicht die Red9-Slide-Pose.) -- [4000 SG-09 R / 4003 Blacktail 2026-07-19] eigene Slide-Rack-Pose. MAGRack = 1:1-Kopie der MAG-Pose (in re4_vr_reload.json), aber EIGENER Name -> ENTKOPPELT von der globalen Mag-Halte-Pose "MAG". Damit nicht alle Pistolen dieselbe Rack-Pose haben; unabhaengig von gestures.
local RACK_POSE_EMPTY = { [4101] = "RiotSLide" }  -- [wid] = Hand-Pose fuer den _08-Lade-Slide-Grab (Empty-Reload). Capture existiert in gestures. -- [wid] = Pose-Name fuer Slide/Pump-Rack-Grab. SGPUMP = W-870 Pump-Griff (linke Hand); noch leer -> bis Capture global.
-- [INSERT-DIST PRO GATTUNG] Abstand Hand->Waffe (m), ab dem das Mag reingleitet. KEIN globaler
-- Wert: jede Gattung hat ihren eigenen. Pistolen-Wert wird beim Laden aus dem alten
-- CFG.insert_distance uebernommen; SMGs/etc. starten als Kopie des Pistolen-Werts.
local INSERT_DIST = { pistols = 0.15, smgs = 0.15, shotguns = 0.15, magnum = 0.15, rifles = 0.15 }
-- [INSERT-DIST PRO WAFFE] Optionaler Override pro WeaponID. Gesetzt = gilt VOR dem Gattungs-Wert,
-- nil = Gattungs-Wert (INSERT_DIST[cat]). So kann z.B. die TMP einen eigenen Wert haben, ohne die
-- LE5 (gleiche Gattung smgs) zu aendern. Nur Waffen mit Eintrag weichen ab.
local INSERT_DIST_WID = {}
-- [SHOTGUN-RATIO PRO WAFFE] Optionaler Override pro WeaponID (Shells pro Einfuehrbewegung). Gesetzt =
-- gilt VOR dem globalen CFG.shotgun_ratio, nil = globaler Wert. So hat z.B. die Striker ein anderes
-- Ratio als die W-870, ohne die andere zu aendern.
local SHOTGUN_RATIO_WID = {}

-- [SHELL-RATIO-SYNC 2026-07-24] EIN Schalter fuer alles: reload4_dlc (DLC-Shotguns) liest kuenftig
-- DIESEN Wert statt einer eigenen Tabelle -> der Shotgun-Ratio-Schalter hier (Dev-Tree UND die nackte
-- UI-Kopie) gilt direkt fuer Leon UND Ada. Als Global (kein neuer Top-Level-Local, reload.lua ist am 200-Limit).
-- Liefert immer eine Zahl (per-Waffe-Override ODER globaler Default) -> reload4s Fallback-Tabelle wird umgangen.
_G.__re4_shotgun_ratio_get = function(wid)
    return tonumber(SHOTGUN_RATIO_WID[wid] or CFG.shotgun_ratio) or 2
end

-- [POSE-STORE] Die gecaptureten Hand-Pose-DATEN (Finger-Quaternionen) gehoeren zu unseren
-- Reloads -> hier in reload.lua besitzen + anwenden, persistiert in re4_vr_reload.json ("poses").
-- gestures.lua ist NUR Capture-Tool: beim Laden importieren wir neue Captures aus gestures.json.
-- POSES[name] = { hand = "left"/"right", bones = { [bone] = {w,x,y,z} } }
local POSES = {}

-- [CHAMBER_HOLD_PERSIST] Per-Waffe (DATEN, nicht Logik): bei diesen Waffen den Nach-Rack-
-- Halt (rest_z) NICHT beim 1. Schuss loesen, sondern bis die Waffe wirklich LEER ist.
-- Grund: deren Engine-Slide-Anim schliesst nach dem Schuss nicht sauber -> Slide schnappt
-- sichtbar zurueck. Matilda/Punisher (nil) behalten das Original-Verhalten 1:1.
-- Diag (re4_reload_diag.log, SLIDE_OFF_REST) belegt: auch Punisher (4001) bleibt nach dem 1. Schuss
-- voll hinten haengen (lz hinter back_z) -> die Engine schliesst den Slide nach manuellem Reload bei
-- KEINER Standard-Pistole. Daher ALLE Standard-Pistolen persistieren (rest_z halten bis leer).
local CHAMBER_HOLD_PERSIST = { [6000] = true, [4000] = true, [4003] = true, [4001] = true, [4004] = true, [4501] = true, [6300] = true, [6301] = true }   -- Sentinel Nine, SG-09 R, Blacktail, Punisher, Matilda, Killer7, XM96E1 (MC), Blacktail AC (MC)

-- [ENGINE_CLOSES_SLIDE] Per-Waffe (DATEN, nicht Logik): das Slide-SCHLIESSEN (zurueck auf
-- gechambert/vorne) macht die ENGINE selbst (ihre Reload/Chamber-Anim faehrt den Slide vor).
-- Bei diesen Waffen forcen WIR KEINEN rest_z-Halt -> kein falscher rest_z-Sprung. Es werden
-- NUR park_z (MITTEL: 0 Ammo / Mag-Drop) und back_z (Rack-Zugweg) genutzt; die geschlossene
-- Position ist Sache der Engine (Gate in apply_slide_park gibt im Ruhezustand eh schon zurueck).
-- Matilda/Punisher (nil) behalten _chambered_hold (deren Engine schliesst nach manuellem
-- Reload NICHT -> Slide wuerde sonst offen klemmen, s. Slide-Rack-Saga). Schrittweise ausweiten.
-- [TMP SLIDE-RACK 2026-07-20] 4200 (TMP) ist hier RAUS: die TMP bekommt ein echtes Slide-Rack
-- ueber Joint _09 (wie die Pistolen ueber _01). Vorher lief sie als "Engine schliesst selbst" -> es gab
-- gar keine Rack-Bedingung. LE 5 (4202) bleibt unveraendert.
local ENGINE_CLOSES_SLIDE = { [4202] = true }   -- LE 5, TMP (W-870 RAUS: wir HALTEN das Pump-Joint _01 selbst auf rest_z, um den nativen AfterShoot-Pump zu unterdruecken -> kein Engine-Close)

-- [SHOTGUN] Per-Waffe-Set: Pump-Action-Shotguns laufen den shell-by-shell Lade-Pfad (Shell in die
-- Hand greifen statt Mag-Drop; Insert addiert SHOTGUN_SHELL_RATIO statt vollem Mag; kein B-Eject;
-- Release legt die Shell zurueck statt sie fallen zu lassen). Sonst 1:1 die bestehende Pipeline
-- (Shell-Joint folgt der Hand via update_mag_in_hand, Pump = Slide-Rack auf slide=_01).
local SHOTGUNS = { [4100] = true, [4101] = true, [4102] = true, [6001] = true }   -- W-870, Riot Gun, Striker, Skull Shaker
local function is_shotgun(wid) return wid ~= nil and SHOTGUNS[wid] == true end
-- [SHOTGUN] Reload-Verhaeltnis: 1 Einfuehrbewegung laedt so viele Shells (gedeckelt auf cap-loaded
-- und Reserve). UI schaltet 1:1 (=1) / 1:2 (=2). Default 1:2 wie RE9. Persistiert in CFG.
-- (Wert lebt in CFG.shotgun_ratio.)

-- [TOP_LOADER] Per-Waffe (DATEN): Waffen OHNE herausfallendes Magazin, die von oben mit
-- einem Schnelllader / Einzelpatronen geladen werden (Red9). Bei diesen ist das Modell
-- grundsaetzlich anders: KEIN Mag-Auswurf -> der Mag-Holster darf NICHT auf mag_out warten,
-- sondern ist IMMER greifbar solange Reserve-Ammo da ist (sonst Leer-Puls). Alles hier ist
-- gekapselt: nur Waffen in dieser Tabelle laufen den Sonderpfad, alle anderen 1:1 wie bisher.
local TOP_LOADER = {}   -- (Red9/4002 ausgezogen -> jetzt eigener Aufbau in reload2.lua)

-- [CHAMBER] Per-Waffe: welcher Joint ist der Chamber + wie weit faehrt er beim Oeffnen (Z).
-- Rechter B togglet diesen Joint zwischen Ruhe (zu) und Ruhe+z (offen). Red9: Joint _01, +0.115.
-- (Visuell ermittelt mit dem Joint-Cycler.) Gekapselt: nur Waffen hier haben das Chamber-Modell.
local CHAMBER = {}   -- (Red9/4002 ausgezogen -> eigener Aufbau in reload2.lua)
-- [CHAMBER] Ramp-Schritt pro Frame fuer das weiche Auf-/Zufahren (0..1), smoothstep im Apply.
local CHAMBER_BLEND_SPEED = 0.10

local function category_of(wid)
    for cat, set in pairs(CATEGORIES) do if set[wid] then return cat end end
    return nil
end
local function category_enabled(cat)
    return cat and CFG[cat .. "_enabled"] == true
end

local function load_cfg()
    local data = safe(function() return json.load_file(CFG_PATH) end)
    if type(data) ~= "table" then return end
    local c = data.cfg or data
    -- "enabled" (Master) NICHT mehr laden -> bleibt immer true. Jede Gattung haengt an ihrem
    -- eigenen Toggle (pistols_enabled/smgs_enabled/...). Master-Toggle entfernt.
    for _, k in ipairs({ "pistols_enabled","smgs_enabled","shotguns_enabled","magnum_enabled","rifles_enabled","reload_ammo","rack_enabled","rack_haptic","sound_enabled" }) do
        if type(c[k]) == "boolean" then CFG[k] = c[k] end
    end
    CFG.enabled = true   -- Master gibt's nicht mehr (immer an)
    for _, k in ipairs({ "gravity","insert_dur","insert_distance","rack_grab_dist","mag_floor_delay","shotgun_ratio","pump_haptic_delay",
                         "insert_overshoot","insert_settle","insert_haptic","insert_snd_at",
                         "insert_travel","insert_back_out","insert_redock","insert_snap_at",   -- [MANUAL_INSERT]
                         "rack_pose_side_deg","pump_start_pull","pump_push_frac" }) do   -- [INSERT-PUNCH] / [RACK_POSE_ANGLE] / [PUMP_START_PULL]
        if type(c[k]) == "number" then CFG[k] = c[k] end
    end
    if type(c.insert_punch) == "boolean" then CFG.insert_punch = c.insert_punch end   -- [INSERT-PUNCH]
    if type(c.insert_manual) == "boolean" then CFG.insert_manual = c.insert_manual end   -- [MANUAL_INSERT]
    if type(c.mag_hold_pose) == "string" and c.mag_hold_pose ~= "" then CFG.mag_hold_pose = c.mag_hold_pose end
    if type(c.rack_pose) == "string" then CFG.rack_pose = c.rack_pose end
    if type(c.rack_pose_side) == "string" and c.rack_pose_side ~= "" then CFG.rack_pose_side = c.rack_pose_side end   -- [RACK_POSE_ANGLE]
    -- Legacy: altes GLOBALES Daumen-Offset (vor der Per-Waffe-Umstellung) fuer Migration merken
    local legacy_thumb = nil
    if type(c.thumb_rx) == "number" or type(c.thumb_ry) == "number" or type(c.thumb_rz) == "number" then
        legacy_thumb = { rx = c.thumb_rx or 0, ry = c.thumb_ry or 0, rz = c.thumb_rz or 0 }
    end
    local thumb_present = {}
    if type(data.maghand) == "table" then
        for k, v in pairs(data.maghand) do
            local wid = tonumber(k)
            if wid and type(v) == "table" then
                MAGHAND[wid] = { x = v.x or 0, y = v.y or 0, z = v.z or 0,
                                 rx = v.rx or 0, ry = v.ry or 0, rz = v.rz or 0,
                                 t_rx = v.t_rx or 0, t_ry = v.t_ry or 0, t_rz = v.t_rz or 0 }
                if v.t_rx ~= nil or v.t_ry ~= nil or v.t_rz ~= nil then thumb_present[wid] = true end
            end
        end
    end
    -- [SHELL_CLONE] Skull Shaker Part-1-Clone-Offsets (Global) laden
    if type(data.shell_clone) == "table" then
        local scl = _G.__re4_ss_clone
        for _, kk in ipairs({ "part", "x", "y", "z", "rx", "ry", "rz", "scale" }) do
            if type(data.shell_clone[kk]) == "number" then scl[kk] = data.shell_clone[kk] end
        end
    end
    -- [SHELL_EJECT] Chamber-Startposition pro Waffe laden
    if type(data.shell_eject) == "table" then
        for k, v in pairs(data.shell_eject) do
            local wid = tonumber(k)
            if wid and type(v) == "table" then
                local e = shell_eject_cfg(wid)
                for _, kk in ipairs({ "sx","sy","sz","srx","sry","srz","vx","vy","vz","grav","dur","spin" }) do
                    if type(v[kk]) == "number" then e[kk] = v[kk] end
                end
            end
        end
    end
    -- Migration: globaler Daumen -> Matilda (wp4004), falls dort noch kein per-Waffe-Daumen gespeichert ist
    if legacy_thumb and not thumb_present[4004] then
        local m = maghand(4004)
        m.t_rx, m.t_ry, m.t_rz = legacy_thumb.rx, legacy_thumb.ry, legacy_thumb.rz
    end
    -- [PORT] Punisher (wp4001) erbt Matildas (wp4004) Mag-Hand-Pose als Startwert, falls
    -- noch nichts Eigenes gespeichert -> kein 0-Offset (Mag haengt sonst falsch in der Hand).
    -- Sobald man die Punisher tunt + speichert, gewinnt deren eigener JSON-Eintrag.
    if not MAGHAND[4001] and MAGHAND[4004] then
        local s = MAGHAND[4004]
        MAGHAND[4001] = { x=s.x, y=s.y, z=s.z, rx=s.rx, ry=s.ry, rz=s.rz, t_rx=s.t_rx, t_ry=s.t_ry, t_rz=s.t_rz }
    end
    -- [PORT 2026-06-15] SG-09 R (4000) / Blacktail (4003) / Sentinel Nine (6000) erben
    -- 1:1 die Punisher-Mag-Hand-Pose (4001), falls noch nichts Eigenes gespeichert.
    -- Sobald man pro Waffe tunt + speichert, gewinnt deren eigener JSON-Eintrag.
    if MAGHAND[4001] then
        local s = MAGHAND[4001]
        for _, w in ipairs({ 4000, 4002, 4003, 6000, 4200, 4201, 4202, 6300 }) do   -- 6300 = XM96E1 (MC), erbt die Punisher-Mag-Hand-Pose
            if not MAGHAND[w] then
                MAGHAND[w] = { x=s.x, y=s.y, z=s.z, rx=s.rx, ry=s.ry, rz=s.rz, t_rx=s.t_rx, t_ry=s.t_ry, t_rz=s.t_rz }
            end
        end
    end
    -- [JOINTS CODE-ONLY] Joints werden BEWUSST NICHT mehr aus der JSON geladen. Sie sind Code-
    -- Konstanten (einmal visuell bestimmt, in der JOINTS-Tabelle oben). Frueher hat ein verklickter
    -- Cycler-Wert (z.B. LE5 mag=_03 statt _04) die JSON ueberschrieben und still den Code-Default
    -- ueberstimmt -> falscher Drop-Joint. Nie wieder: die Code-Tabelle ist die einzige Wahrheit.
    -- (Der Cycler unten setzt nur IN-MEMORY zum Probieren; Fund wird im Code hardcodiert.)
    -- Slide-Hand-Dock (Position + Rotations-Offset) pro Waffe; rest/park/back bleiben hardcoded
    if type(data.slide_dock) == "table" then
        for k, v in pairs(data.slide_dock) do
            local wid = tonumber(k)
            if wid and type(v) == "table" then
                local sp = slide_pose(wid)
                -- [POSE2_OFFSETS] sdock_*/srack_* = zweiter Satz (Seiten-/MAG-Rack-Pose). Fehlen sie in
                -- einer alten JSON, bleibt der Blacktail-Startwert aus SLIDE_POSE_DEFAULT stehen.
                for _, f in ipairs({ "dock_x","dock_y","dock_z","rack_rx","rack_ry","rack_rz","rest_z","park_z","back_z",
                                     "sdock_x","sdock_y","sdock_z","srack_rx","srack_ry","srack_rz" }) do
                    if type(v[f]) == "number" then sp[f] = v[f] end
                end
            end
        end
    end
    -- [EMPTY-RELOAD SLIDE] _08-Travel/Dock laden (Riot Gun)
    if type(data.slide_dock2) == "table" then
        for k, v in pairs(data.slide_dock2) do
            local wid = tonumber(k)
            if wid and type(v) == "table" then
                local sp = slide_pose2(wid)
                for _, f in ipairs({ "dock_x","dock_y","dock_z","rack_rx","rack_ry","rack_rz","rest_z","park_z","back_z" }) do
                    if type(v[f]) == "number" then sp[f] = v[f] end
                end
            end
        end
    end
    -- [POSE PER WAFFE] gecapturete Hand-Posen pro Waffe laden (Pistolen ohne Eintrag = global)
    if type(data.mag_pose) == "table" then
        for k, v in pairs(data.mag_pose) do local wid = tonumber(k); if wid and type(v) == "string" then MAG_POSE[wid] = v end end
    end
    if type(data.rack_pose_w) == "table" then
        for k, v in pairs(data.rack_pose_w) do local wid = tonumber(k); if wid and type(v) == "string" then RACK_POSE[wid] = v end end
    end
    -- [INSERT-DIST PRO GATTUNG] kein globaler Wert: Pistolen erben den alten CFG.insert_distance,
    -- andere Gattungen ihren gespeicherten Wert ODER (ungetunt) eine Kopie des Pistolen-Werts.
    INSERT_DIST.pistols = CFG.insert_distance or INSERT_DIST.pistols
    local _sd = (type(data.insert_dist) == "table") and data.insert_dist or {}
    for _, cat in ipairs({ "pistols", "smgs", "shotguns", "magnum", "rifles" }) do
        if type(_sd[cat]) == "number" then INSERT_DIST[cat] = _sd[cat]
        elseif cat ~= "pistols" then INSERT_DIST[cat] = INSERT_DIST.pistols end
    end
    -- [INSERT-DIST PRO WAFFE] Per-WeaponID-Override laden (wid-keys als String).
    if type(data.insert_dist_wid) == "table" then
        for k, v in pairs(data.insert_dist_wid) do
            local wid = tonumber(k); if wid and type(v) == "number" then INSERT_DIST_WID[wid] = v end
        end
    end
    if type(data.shotgun_ratio_wid) == "table" then
        for k, v in pairs(data.shotgun_ratio_wid) do
            local wid = tonumber(k); if wid and type(v) == "number" then SHOTGUN_RATIO_WID[wid] = v end
        end
    end
    -- [SHELL-DOCK PERSIST 2026-07-24] NUR die Striker (4102) laden -- andere Waffen bleiben auf ihren
    -- Code-Werten, egal was in der JSON steht (kein Ueberschreiben der "okayen" Waffen).
    if type(data.dock_port) == "table" and type(data.dock_port["4102"]) == "table" and DOCK_PORT[4102] then
        local v = data.dock_port["4102"]
        if type(v.x) == "number" then DOCK_PORT[4102].x = v.x end
        if type(v.y) == "number" then DOCK_PORT[4102].y = v.y end
        if type(v.z) == "number" then DOCK_PORT[4102].z = v.z end
    end
    -- [SHELL_PART_PERSIST] gelernte Shell-Sub-Mesh-Part-Indizes pro Waffe laden (Liste von Indizes).
    -- Mutieren (nicht neu zuweisen) -> der Alias _sg_shell_by_wid = SHELL_PARTS bleibt gueltig.
    if type(data.shell_parts) == "table" then
        for k, v in pairs(data.shell_parts) do
            local wid = tonumber(k)
            if wid and type(v) == "table" and #v > 0 then SHELL_PARTS[wid] = v end
        end
    end
    -- [ROTARY_CYCLE] Drehschalter-Werte pro Waffe laden (ueberschreibt die Code-Defaults nach dem Tunen).
    if type(data.rotary) == "table" then
        for k, v in pairs(data.rotary) do
            local wid = tonumber(k)
            if wid and type(v) == "table" then
                local rr = rotary_cfg(wid)
                for _, f in ipairs({ "rx", "ry", "rz", "grab_dist", "lerp", "pitch_range" }) do
                    if type(v[f]) == "number" then rr[f] = v[f] end
                end
            end
        end
    end
    -- [POSE-STORE] 1) Pose-DATEN aus reload.json laden
    if type(data.poses) == "table" then
        for name, v in pairs(data.poses) do
            if type(v) == "table" and type(v.bones) == "table" then POSES[name] = { hand = v.hand, bones = v.bones } end
        end
    end
    -- [POSE-STORE] 2) neue Captures aus gestures.json importieren (gestures = nur Capture-Tool).
    -- gestures-Version gewinnt (frischester Capture). Faellt weg wenn gestures.json geloescht.
    local gj = safe(function() return json.load_file("re4_vr/re4_vr_gestures_capture.json") end)
    local gp = gj and (gj.poses or gj)
    if type(gp) == "table" then
        for name, v in pairs(gp) do
            if type(v) == "table" and type(v.bones) == "table" then POSES[name] = { hand = v.hand, bones = v.bones } end
        end
    end
    -- KEIN Uebernehmen von Matilda-Werten mehr: die Punisher (und jede andere Pistole) wird
    -- eigenstaendig getunt. Slide-Dock/Rack/Slide-Z starten auf Code-Default (0 bzw. neutral).
end
local function save_cfg()
    local jt = {}
    for wid, v in pairs(JOINTS) do jt[tostring(wid)] = { mag = v.mag, slide = v.slide } end
    local c = {}
    for k, v in pairs(CFG) do c[k] = v end
    local mh = {}
    for wid, v in pairs(MAGHAND) do mh[tostring(wid)] = v end
    local se = {}
    for wid, v in pairs(SHELL_EJECT) do se[tostring(wid)] = v end
    local sdk_dock = {}
    for wid, v in pairs(SLIDE_POSE) do
        sdk_dock[tostring(wid)] = { dock_x = v.dock_x, dock_y = v.dock_y, dock_z = v.dock_z,
                                    rack_rx = v.rack_rx, rack_ry = v.rack_ry, rack_rz = v.rack_rz,
                                    -- [POSE2_OFFSETS] zweiter Satz (Seiten-/MAG-Rack-Pose)
                                    sdock_x = v.sdock_x, sdock_y = v.sdock_y, sdock_z = v.sdock_z,
                                    srack_rx = v.srack_rx, srack_ry = v.srack_ry, srack_rz = v.srack_rz,
                                    rest_z = v.rest_z, park_z = v.park_z, back_z = v.back_z }
    end
    -- [EMPTY-RELOAD SLIDE] _08-Travel/Dock pro Waffe (Riot Gun) separat
    local sdk_dock2 = {}
    for wid, v in pairs(SLIDE_POSE2) do
        sdk_dock2[tostring(wid)] = { dock_x = v.dock_x, dock_y = v.dock_y, dock_z = v.dock_z,
                                     rack_rx = v.rack_rx, rack_ry = v.rack_ry, rack_rz = v.rack_rz,
                                     rest_z = v.rest_z, park_z = v.park_z, back_z = v.back_z }
    end
    local mpose, rpose = {}, {}
    for wid, v in pairs(MAG_POSE)  do mpose[tostring(wid)] = v end
    for wid, v in pairs(RACK_POSE) do rpose[tostring(wid)] = v end
    -- INSERT_DIST ist pro GATTUNG (string-keys pistols/smgs/...) -> direkt speichern
    local idist = {}; for cat, v in pairs(INSERT_DIST) do idist[cat] = v end
    -- [INSERT-DIST PRO WAFFE] Per-WeaponID-Override separat speichern (wid-keys als String).
    local idist_w = {}; for wid, v in pairs(INSERT_DIST_WID) do idist_w[tostring(wid)] = v end
    -- [SHOTGUN-RATIO PRO WAFFE] Per-WeaponID-Override (Shells pro Einfuehrbewegung).
    local sratio_w = {}; for wid, v in pairs(SHOTGUN_RATIO_WID) do sratio_w[tostring(wid)] = v end
    -- [ROTARY_CYCLE] Drehschalter-Werte pro Waffe persistieren (rx/ry/rz/grab_dist/lerp).
    local rotcfg = {}
    for wid, v in pairs(ROTARY) do
        rotcfg[tostring(wid)] = { rx = v.rx, ry = v.ry, rz = v.rz, grab_dist = v.grab_dist, lerp = v.lerp, pitch_range = v.pitch_range }
    end
    -- [SHELL_PART_PERSIST] gelernte Shell-Sub-Mesh-Part-Indizes pro Waffe (Liste von Part-Indizes).
    local sparts = {}
    for wid, v in pairs(SHELL_PARTS) do sparts[tostring(wid)] = v end
    -- [SHELL_CLONE] Skull Shaker Part-1-Clone-Offsets (Global) persistieren
    local sscl = _G.__re4_ss_clone or {}
    local sclone = { part = sscl.part, x = sscl.x, y = sscl.y, z = sscl.z, rx = sscl.rx, ry = sscl.ry, rz = sscl.rz, scale = sscl.scale }
    -- [SHELL-DOCK PERSIST 2026-07-24] NUR die Striker (4102) persistieren -- andere DOCK_PORT-Waffen
    -- bleiben rein code-getrieben (unangetastet). Joint bleibt im Code, nur der Offset wird gespeichert.
    local dpout = {}; if DOCK_PORT[4102] then dpout["4102"] = { x = DOCK_PORT[4102].x, y = DOCK_PORT[4102].y, z = DOCK_PORT[4102].z } end
    pcall(function() json.dump_file(CFG_PATH, { cfg = c, joints = jt, maghand = mh, shell_eject = se, slide_dock = sdk_dock, slide_dock2 = sdk_dock2, mag_pose = mpose, rack_pose_w = rpose, insert_dist = idist, insert_dist_wid = idist_w, shotgun_ratio_wid = sratio_w, poses = POSES, rotary = rotcfg, shell_parts = sparts, shell_clone = sclone, dock_port = dpout }) end)
end

-- =====================================================================
-- Player / Waffe
-- =====================================================================
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
local function get_body()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.body_go() end
    local ctx = get_ctx(); return ctx and sc(ctx, "get_BodyGameObject")
end
local function body_tf()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.body_tf() end
    local b = get_body(); return b and sc(b, "get_Transform")
end

-- =====================================================================
-- [POSE-STORE] Hand-Pose anwenden (eigene Engine -> KEINE gestures.lua-Abhaengigkeit).
-- Finger-Joint-LocalRotation aus POSES[name].bones schreiben (nlerp bei blend<1).
-- Exponiert als _G.__re4_reload_apply_pose; motion.lua ruft das an (statt gestures).
-- =====================================================================
local _pmap_tf, _pmap = nil, {}
local function pose_build_map()
    local tf = body_tf(); if not tf then return {} end
    if tf == _pmap_tf and next(_pmap) ~= nil then return _pmap end
    local map = {}
    local joints = safe(function() return tf:call("get_Joints") end)
    if joints then
        local count = safe(function() return joints:call("get_Count") end)
        if type(count) == "number" then
            for i = 0, count - 1 do
                local j = safe(function() return joints[i] end)
                local nm = j and safe(function() return j:call("get_Name") end)
                if nm then map[tostring(nm)] = j end
            end
        end
    end
    _pmap_tf, _pmap = tf, map
    return map
end
local function pose_apply(name, blend)
    local pose = name and POSES[name]
    if not pose or not pose.bones then return false end
    local map = pose_build_map(); if next(map) == nil then return false end
    blend = blend or 1.0
    if blend <= 0.0 then return true end
    for bone, v in pairs(pose.bones) do
        local j = map[bone]
        if j and v and v[1] then
            if blend >= 0.9999 then
                pcall(function() j:call("set_LocalRotation", Quaternion.new(v[1], v[2], v[3], v[4])) end)
            else
                local c = safe(function() return j:call("get_LocalRotation") end)
                if c then
                    local tw, tx, ty, tz = v[1], v[2], v[3], v[4]
                    if (c.w*tw + c.x*tx + c.y*ty + c.z*tz) < 0.0 then tw, tx, ty, tz = -tw, -tx, -ty, -tz end
                    local w, x, y, z = c.w+(tw-c.w)*blend, c.x+(tx-c.x)*blend, c.y+(ty-c.y)*blend, c.z+(tz-c.z)*blend
                    local len = math.sqrt(w*w + x*x + y*y + z*z)
                    if len > 1e-6 then pcall(function() j:call("set_LocalRotation", Quaternion.new(w/len, x/len, y/len, z/len)) end) end
                end
            end
        end
    end
    return true
end
_G.__re4_reload_apply_pose = pose_apply
-- [KNIFE_HAND 2026-07-07] Externe Pose (bones-Dict DIREKT, ohne POSES/Namen) anwenden. re4_vr_knife_
-- lefthand.lua liefert die selbst-gespiegelte Links-Messer-Pose -> unabhaengig von gestures/POSES.
-- Gleicher Joint-Writer wie pose_apply (nlerp bei blend<1).
_G.__re4_reload_apply_pose_bones = function(bones, blend)
    if type(bones) ~= "table" then return false end
    local map = pose_build_map(); if next(map) == nil then return false end
    blend = blend or 1.0
    if blend <= 0.0 then return true end
    for bone, v in pairs(bones) do
        local j = map[bone]
        if j and v and v[1] then
            if blend >= 0.9999 then
                pcall(function() j:call("set_LocalRotation", Quaternion.new(v[1], v[2], v[3], v[4])) end)
            else
                local c = safe(function() return j:call("get_LocalRotation") end)
                if c then
                    local tw, tx, ty, tz = v[1], v[2], v[3], v[4]
                    if (c.w*tw + c.x*tx + c.y*ty + c.z*tz) < 0.0 then tw, tx, ty, tz = -tw, -tx, -ty, -tz end
                    local w, x, y, z = c.w+(tw-c.w)*blend, c.x+(tx-c.x)*blend, c.y+(ty-c.y)*blend, c.z+(tz-c.z)*blend
                    local len = math.sqrt(w*w + x*x + y*y + z*z)
                    if len > 1e-6 then pcall(function() j:call("set_LocalRotation", Quaternion.new(w/len, x/len, y/len, z/len)) end) end
                end
            end
        end
    end
    return true
end
-- Pose-Namen (sortiert) fuer die UI-Picker -> unabhaengig von gestures
_G.__re4_reload_pose_names = function()
    local t = {}; for n in pairs(POSES) do t[#t+1] = n end; table.sort(t); return t
end
local function search_tree(tf, target, depth)
    if not tf or depth < 0 then return nil end
    local child = sc(tf, "get_Child"); local n = 0
    while child and n < 128 do
        n = n + 1
        local go = sc(child, "get_GameObject")
        local gn = go and sc(go, "get_Name")
        if gn and tostring(gn) == target and sc(go, "get_DrawSelf") ~= false then return go, child end
        local fgo, ftf = search_tree(child, target, depth - 1)
        if fgo then return fgo, ftf end
        child = sc(child, "get_Next")
    end
end
-- [GO_SUFFIX 2026-07-19] Waffen-GOs heissen nicht immer exakt "wp####": bei Ada (Separate
-- Ways) haengen Punisher MC / Rocket Launcher als "wp6112_AO" / "wp6111_AO" im Baum (verifiziert
-- mit re4_zzz_weaponhide_probe). Exakter Vergleich fand sie nie -> Waffe galt als nicht vorhanden.
-- Reihenfolge "" -> "_AO" -> "_MC" ist WICHTIG: wo es ein plain-GO gibt, ist "_AO" ein
-- Schatten-Proxy und darf NICHT gewinnen.
local function find_weapon(wid)
    local bt = body_tf(); if not bt then return nil, nil end
    local base = string.format("wp%04d", wid)
    for _, suffix in ipairs({ "", "_AO", "_MC" }) do
        local go, tf = search_tree(bt, base .. suffix, 5)
        if go then return go, tf end
    end
    return nil, nil
end

-- [TYPE_DEFS] Alle via/chainsaw-Typ-Handles in EINER Tabelle (statt je 1 Top-Level-Local) ->
-- spart Slots gegen das Lua-200-Local-Limit im Haupt-Chunk. Neue Typen hier ergaenzen, NICHT
-- als neues `local` anlegen.
local TD = {
    pe     = sdk.typeof("chainsaw.PlayerEquipment"),
    snd_sc = sdk.typeof("soundlib.SoundContainer"),
    mfsm2  = sdk.typeof("via.motion.MotionFsm2"),
    motion = sdk.typeof("via.motion.Motion"),
}

-- PlayerEquipment + equippte WeaponItem (fuer den echten Ammo-Reload)
local _pe_cache = nil
local function get_pe()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.pe() end
    if _pe_cache and safe(function() return _pe_cache:call("get_Context") end) then return _pe_cache end
    local ctx = get_ctx(); local head = ctx and sc(ctx, "get_HeadGameObject")
    _pe_cache = head and sc(head, "getComponent(System.Type)", TD.pe)
    return _pe_cache
end
local function get_weapon_item()
    -- [ACCESSOR 2026-08-12] zuerst die ECHTE, persistente Instanz (s. reload.lua,
    -- __re4_real_wi). Alles darunter sind KOPIEN -> Schreiben verpufft.
    local _rw = _G.__re4_real_wi and _G.__re4_real_wi()
    if _rw then return _rw end
    local pe = get_pe(); return pe and sc(pe, "getEquipWeaponItem")
end

-- LIVE equippte WeaponItem aus dem Inventory (wie der Holster) — NICHT die Kopie von getEquipWeaponItem
local function enum_value(o)
    if type(o) == "number" then return o end
    local v = sf(o, "value__"); return type(v) == "number" and v or nil
end
-- [LOG-FLUT 2026-08-01 -- im Framework-Log direkt vor dem Absturz belegt] Hier stand
-- `sc(g, "ToString")` auf einer System.Guid. Der Aufruf SCHLAEGT FEHL ("Invalid number of arguments
-- passed to REMethodDefinition::invoke for System.Guid.ToString") -- und REFramework schreibt JEDE
-- dieser Warnungen SYNCHRON auf die Platte. Die Funktion laeuft in einer Schleife ueber die
-- Inventar-Zeilen; im Log stehen dadurch ~18 Warnungen in EINER Millisekunde (01:24:50.662),
-- unmittelbar vor dem Absturz. Genau dieses Muster hat am 2026-07-20 schon in holster.lua den
-- Script-Thread abgewuergt -- dort wurde es deshalb auf reine Feldlesungen umgebaut, hier nicht.
-- FIX = dieselbe Loesung wie in holster.lua: die Guid ueber ihre ROHFELDER vergleichbar machen.
-- Der String muss nicht dem Guid-Format entsprechen, er wird nur zum VERGLEICHEN benutzt.
-- Kein ToString-Fallback: lieber kein Schluessel (die Aufrufer haben Fallbacks) als ein haengendes Spiel.
local function guid_to_string(g)
    if g == nil then return nil end
    if type(g) == "string" then return g end
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
    return nil
end
local equip_type_main_cache = nil
local function get_equip_type_main()
    if equip_type_main_cache ~= nil then return equip_type_main_cache end
    local td = sdk.find_type_definition("chainsaw.EquipType")
    local f = td and td:get_field("Main")
    if f then equip_type_main_cache = f:get_data(nil) end
    return equip_type_main_cache
end
-- Inventory-Row-Item (autoritativ, mit Reserve-Anbindung) — KEIN Cache.
-- Guid-Match bevorzugt, sonst WeaponId-Match.
local function get_inv_row_weapon_item()
    local pe = get_pe(); if not pe then return nil end
    local inv = sc(pe, "get_InventoryController"); if not inv then return nil end
    local list = sc(inv, "getInventoryItemList"); if not list then return nil end
    local cnt = sc(list, "get_Count") or 0
    local et = get_equip_type_main()
    local want = et and guid_to_string(sc(inv, "getEquippedID", et))
    want = want and string.lower(want)
    local wid = get_equip_wid()
    local by_wid = nil
    for i = 0, cnt - 1 do
        local row = sc(list, "get_Item", i)
        if row then
            local rid = guid_to_string(sc(row, "get_ID"))
            if want and rid and string.lower(rid) == want then return row end
            if wid and enum_value(sc(row, "get_WeaponId")) == wid then by_wid = by_wid or row end
        end
    end
    return by_wid
end


-- [LIVE_WI_SAVELOAD 2026-08-06] Der Cache `__re4_live_wi` wird bei jedem Waffenwechsel verworfen
-- (Z.4114 u.a.), aber NICHT beim Save-Load mit derselben Waffe -- genau dort wird das Item neu
-- instanziiert und der Cache zur Leiche. Bisher fiel das erst beim Benutzen auf: der Guard
-- `cached:call("get_IsValid")` in get_live_weapon_item war selbst schon der Zugriff auf das tote
-- Objekt -> Engine-Exception, die REFramework SYNCHRON auf Platte schreibt (117 Zeilen im Log vom
-- 06.08., Vierer-Buendel im Sekundentakt). safe faengt sie zu spaet ab
-- [[Notiz]].
-- Deshalb: Save-Load an der Adresse des Player-Body-GO erkennen (wechselt beim Laden und beim
-- Charakterwechsel) und den Cache VORHER wegwerfen, statt ihn hinterher zu befragen. Gleiches Muster
-- wie die Guards in re4_vr_weapons.lua (Granaten-Generator) und re4_vr_weapons2.lua (Messer-DamageInfo).
-- [200-LOCAL-LIMIT] Bewusst GLOBALS statt neuer Top-Level-Locals: diese Datei steht exakt am Lua-Limit
-- von 200 Locals im Hauptchunk -- zwei weitere kippen sie beim Laden ([[Notiz]]).
-- [SORTE HEILEN 2026-08-12] Zeigt eine Waffe "0 Reserve", obwohl die passende Munition im Koffer liegt,
-- dann steht in ihrem Feld _CurrentAmmo (0x40) eine Sorte ohne Bestand -- das Spiel zeichnet die Anzeige
-- aus genau diesem Feld, und mit 0 Reserve laesst sich gar nicht erst nachladen. Der Ladeweg kann das
-- also nicht reparieren, er wird nie erreicht. Deshalb hier getickt, unabhaengig vom Nachladen:
-- Bestand der aktuellen Sorte pruefen, und wenn 0, die erste Sorte MIT Bestand aus der Usable-Liste
-- DIESER Waffe eintragen (get_UsableAmmoList = was die Waffe laut Spieldaten akzeptiert, kein Raten).
-- Nur dann -- hat die aktuelle Sorte Bestand, wird nichts angefasst.
re.on_frame(function()
    if os.clock() < (tonumber(rawget(_G, "__re4_sortefix_next")) or 0) then return end
    _G.__re4_sortefix_next = os.clock() + 1.0
    pcall(function()
        local wi = _G.__re4_real_wi and _G.__re4_real_wi(); if not wi then return end
        local pe = _G.__re4_pe and _G.__re4_pe(); if not pe then return end
        local inv = pe:call("get_InventoryController"); if not inv then return end
        local sum = _G.__re4_item_count_sum_num; if not sum then return end
        local cur = wi:call("get_CurrentAmmo"); if cur == nil then return end
        local curn = _G.__re4_id_num(cur)
        local arr  = wi:call("get_UsableAmmoList")
        local n2   = arr and (tonumber(arr:get_size()) or 0) or 0
        -- [AUSKUNFT 2026-08-12] Einmal pro Waffen-/Sortenwechsel die volle Lage ins Log, auch wenn nichts
        -- zu heilen ist: sonst ist nicht unterscheidbar, ob der Tick nichts findet oder gar nicht laeuft.
        do
            local wnum; pcall(function() wnum = _G.__re4_id_num(wi:call("get_WeaponId")) end)
            local key = tostring(wnum) .. "/" .. tostring(curn)
            if rawget(_G, "__re4_sortefix_last") ~= key then
                _G.__re4_sortefix_last = key
                local liste = {}
                for i = 0, n2 - 1 do
                    local a = arr:get_element(i); local an = _G.__re4_id_num(a)
                    liste[#liste + 1] = string.format("%s=%d", tostring(an), an and (tonumber(sum(inv, an)) or 0) or -1)
                end
            end
        end
        if curn and (tonumber(sum(inv, curn)) or 0) > 0 then return end   -- Bestand da -> nichts zu heilen
        if not arr then return end
        for i = 0, n2 - 1 do
            local aid  = arr:get_element(i)
            local anum = _G.__re4_id_num(aid)
            if anum and anum ~= curn then
                local s = tonumber(sum(inv, anum)) or 0
                if s > 0 then
                    wi:call("setAmmoId(chainsaw.ItemID)", aid)
                    return
                end
            end
        end
    end)
end)

re.on_frame(function()
    if os.clock() < (tonumber(rawget(_G, "__re4_lw_next")) or 0) then return end
    _G.__re4_lw_next = os.clock() + 0.25
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager"); if not cm then return end
    local ok, body = pcall(function()
        local c = cm:call("getPlayerContextRef"); if not c then return nil end
        return c:call("get_BodyGameObject")
    end)
    if not (ok and body) then return end
    local ok2, a = pcall(function() return body:get_address() end)
    if not (ok2 and a) then return end
    local prev_a = rawget(_G, "__re4_lw_body_addr")
    if prev_a == nil then _G.__re4_lw_body_addr = a; return end
    if a == prev_a then return end
    _G.__re4_lw_body_addr = a
    _G.__re4_live_wi = nil
    _G.__re4_live_wi_dropped_t = os.clock()   -- [FORENSIK] wann zuletzt verworfen
end)

local function get_live_weapon_item()
    local ewid = get_equip_wid()
    -- =========================================================================================
    -- 0) [ACCESSOR 2026-08-12] DIE EINZIGE PERSISTENTE INSTANZ.
    -- Live gemessen (#wi_write_probe, Laeufe 3+4, Script danach geloescht):
    --   * `pe:getEquipWeaponItem`, `inv:getEquippedWeapon` und die Zeilen aus
    --     `getInventoryItemList` liefern bei JEDEM Aufruf eine FRISCHE KOPIE -- ihre Adresse
    --     springt in jedem Tick, waehrend @pe als Kontrolle stehenbleibt (GC ausgeschlossen).
    --     Schreiben darauf wirkt sauber ("vor=18 soll=19 NACH=19") und ist danach WEG -- das
    --     erklaert rueckwirkend jedes "verpufft" der letzten Monate.
    --   * `pe:getEquipWeaponAccessor()` (chainsaw.CsInventoryItem) hat als EINZIGES eine stabile
    --     Adresse und haelt in `<Item>k__BackingField` das ECHTE chainsaw.WeaponItem
    --     (`get_Item()`). Dort wirkt `setAmmoCount` SOFORT, das HUD folgt noch im selben Tick
    --     (18 -> 19 -> 20 belegt) und der Wert steht auch Ticks spaeter noch.
    -- Damit wird der crashende native `CsInventoryController.reload` UEBERFLUESSIG statt
    -- abgesichert -- er ist die einzige reload-Ueberladung in RE4 und bekommt nur den EquipType,
    -- muss also Waffe/Ammo-ID/Inventarzeile selbst suchen (genau die Suchkette, die null
    -- dereferenziert). RE9 gibt Zeile+ItemID mit, RE2 bucht selbst -- beide crashen nie.
    -- Nebeneffekt: der Leichen-Cache __re4_live_wi wird hier nicht mehr gebraucht.
    -- RUECKBAU:  _G.__re4_use_accessor_item = false   -> exakt das alte Verhalten.
    -- Zaehler:   __re4_acc_hit / __re4_acc_miss
    -- Details: [[reference_re4_echte_weaponitem_instanz]]
    -- =========================================================================================
    if rawget(_G, "__re4_use_accessor_item") ~= false then
        local pe_a = get_pe()
        local acc  = pe_a and safe(function() return pe_a:call("getEquipWeaponAccessor") end)
        local real = acc and safe(function() return acc:call("get_Item") end)
        if real and safe(function() return real:call("get_CurrentAmmoCount") end) ~= nil then
            -- Beim Waffenwechsel kann der Accessor kurz noch die ALTE Waffe halten -> nur nehmen,
            -- wenn er dieselbe Waffe traegt, die das Equipment meldet. Ist eine der beiden IDs
            -- nicht lesbar, wird er trotzdem genommen (er ist per Definition der equippte Slot).
            local rwid = safe(function() return real:call("get_WeaponId"):get_field("value__") end)
            if ewid == nil or rwid == nil or rwid == ewid then
                _G.__re4_acc_hit = (tonumber(rawget(_G, "__re4_acc_hit")) or 0) + 1
                return real
            end
        end
        _G.__re4_acc_miss = (tonumber(rawget(_G, "__re4_acc_miss")) or 0) + 1
    end
    -- 1) Gecachtes Gun-Item (Schuss/Reload schreiben darauf) NUR nutzen wenn es (a) noch VALID ist
    -- (get_IsValid -> tote Instanz nach Waffenwechsel/Save-Load ausschliessen) UND (b) EINDEUTIG die
    -- AKTUELL equippte Waffe traegt (cwid == ewid, beide gueltig). Frueher gab `not cwid`/`not ewid` das
    -- stale Item zurueck (totes Item -> cwid=nil -> falsche Waffe: cap/Ammo-ID der ALTEN Waffe -> Reload
    -- rechnet Mist). [[Notiz]]
    local cached = rawget(_G, "__re4_live_wi")
    -- [LIVE_WI_SAVELOAD 2026-08-06] `get_IsValid` ist hier RAUS: auf einem toten Item ist genau dieser
    -- Aufruf schon die Exception, die er verhindern soll (117 Logzeilen am 06.08.). Frisch gehalten wird
    -- der Cache jetzt vom Guard oben (Save-Load) plus den bestehenden Waffenwechsel-Resets.
    -- Der Enum-Vergleich unten bleibt UNANGETASTET (Entscheidung 06.08.): er kostet zwei Calls und
    -- keine Logzeile -- ihn zu reparieren wuerde diesen Cache-Zweig erstmals scharf schalten und damit
    -- das Reload-Verhalten aendern, das gerade endlich stabil laeuft.
    if cached
       and safe(function() return cached:call("get_CurrentAmmoCount") end) ~= nil then
        local cwid = safe(function() return cached:call("get_WeaponId"):get_field("value__") end)
        if ewid and cwid and cwid == ewid then return cached end
    end
    -- 2) Das ECHTE equippte Item (getEquipWeaponItem) — immer die aktuelle Waffe, korrekte cap/Ammo-ID.
    local pe0 = get_pe()
    local eqwi = pe0 and safe(function() return pe0:call("getEquipWeaponItem") end)
    if eqwi and safe(function() return eqwi:call("get_CurrentAmmoCount") end) ~= nil then return eqwi end
    -- 3) Fallback: Inventory-Row (Guid bevorzugt, sonst WeaponId)
    return get_inv_row_weapon_item()
end

-- [NO_NATIVE_RELOAD 2026-07-31] Zwei Globals fuer __re4_safe_inv_reload (steht WEITER OBEN im
-- File und sieht diese lokalen Funktionen sonst nicht). Kein neuer Top-Level-Local (200-Limit).
-- __re4_live_gun = das ECHTE Laufzeit-Gun-Item (dieselbe Aufloesung wie ueberall sonst)
-- __re4_gun_ammo = der HUD-/Runtime-Ladestand (pe:getCurrentGunAmmo, kein Cache) = die WAHRHEIT
_G.__re4_live_gun = function() return get_live_weapon_item() end
_G.__re4_gun_ammo = function()
    local pe = get_pe()
    return pe and tonumber(safe(function() return pe:call("getCurrentGunAmmo") end)) or nil
end
-- [GUN_AMMO_SYNC 2026-07-31, "er laedt gar nichts rein"] DAS fehlende Puzzleteil. Ein Schreiben
-- auf das WeaponItem (write_dword 0x44 / addAmmoCount) landet nur im ITEM -- die Runtime-Gun (das, was
-- HUD und Feuern lesen) wird davon NICHT angefasst. Deshalb galt der Item-Write ein Jahr lang als
-- "verpufft" und nur der native reload als "der einzige Pfad der wirklich greift".
-- chainsaw.PlayerEquipment.updateGunAmmo ist genau die Sync-Funktion Item -> Runtime-Gun, die die
-- Engine selbst benutzt. Parameterlos, kein Inventar-Deref -> kann die reload-AV nicht ausloesen.
_G.__re4_sync_gun_ammo = function()
    local pe = get_pe(); if not pe then return end
    pcall(function() pe:call("updateGunAmmo") end)
end
-- Das Item, das die ENGINE selbst als equippt fuehrt (getEquipWeaponItem). Zweite Chance, falls
-- get_live_weapon_item gerade eine andere Instanz (Cache/Inventory-Row) liefert.
_G.__re4_equip_gun = function()
    local pe = get_pe()
    return pe and safe(function() return pe:call("getEquipWeaponItem") end) or nil
end
-- =====================================================================
-- [ENTFERNT 2026-08-12] __re4_exec_reload / __re4_exec_reload_start
-- =====================================================================
-- Hier lagen zwei parameterlose Wrapper um `PlayerEquipment:execReload` bzw. `execReloadStart`.
-- Sie wurden von NIRGENDS gerufen (ueber alle Scripte geprueft) und standen nur noch als
-- "Doku/Notfall" herum -- eine scharfe Zuendschnur: `execReload` hat am 12.08. beim ersten
-- Pistolen-Reload einen VOLLCRASH ausgeloest.
--
-- Die alte Begruendung ("execReload laeuft durch die normale State-Maschine, der Pfad crasht im
-- Vanilla nicht") war der Trugschluss: sie gilt nur, wenn die ENGINE den Call aus ihrem eigenen
-- Zyklus heraus macht. Aus einem freien Frame-Tick trifft er dieselbe Wand wie INV:reload.
--
-- Der damals gesuchte "MASTER, aus dem die Engine das Item zurueckschreibt" ist inzwischen
-- gefunden und gelost: es gab nie einen Master, wir haben nur immer auf KOPIEN geschrieben.
-- `pe:getEquipWeaponAccessor():get_Item()` ist die einzige persistente Instanz -- siehe
-- get_live_weapon_item(), Zweig 0. Damit braucht es keinen nativen Ladecall mehr.
-- Alte Fassung: others/re4_vr_reload.bak_2026-08-12_pre_deadcode.lua
-- =====================================================================
-- Laedt die Waffe Schuss fuer Schuss (Skull Shaker, Riot Gun, Revolver, Bogen)? Dann fuehrt die Engine
-- den Ladestand selbst und verwirft unsere addAmmoCount-Schreibvorgaenge -- im Log ausnahmslos so:
-- loopReload=true -> "(C) Nachbau ohne Wirkung" (4 von 4), loopReload=false -> Weg C wirkt.
_G.__re4_is_loop_reload = function()
    local pe = get_pe(); if not pe then return false end
    local ok, v = pcall(function() return pe:call("isLoopReload") end)
    return (ok and v == true)
end
-- Roher PlayerEquipment-Zugriff fuer die Diagnosezeilen weiter oben (get_pe ist dort nicht sichtbar).
_G.__re4_pe = function() return get_pe() end

-- [WER NULLT DAS MAGAZIN? 2026-08-12] Der Magazinrest kam nicht zurueck, weil KEINER der beiden bekannten
-- Merkpunkte lief (`MAG-DROP` stand 0-mal im Log) -- das Nullen kommt also von einer dritten Stelle.
-- Statt weiter zu suchen: jede Stelle, die auf 0 schreibt, meldet sich hier an und legt dabei den Rest
-- als Merker ab. Damit steht im Log, WER es war, und der Rest ist gleichzeitig gerettet.
-- Nur die erste Meldung pro Auswurf zaehlt (danach steht die Waffe ja auf 0).
_G.__re4_carry_capture = function(wi, where, wid)
    if not wi then return end
    local cur = nil
    pcall(function() cur = tonumber(wi:call("get_CurrentAmmoCount")) end)
    if not cur or cur <= 0 then return end
    if (tonumber(rawget(_G, "__re4_mag_carry")) or 0) > 0 then return end   -- schon gemerkt
    _G.__re4_mag_carry     = cur
    _G.__re4_mag_carry_wid = wid
end

-- [WARTESCHLANGE AUSGEBAUT 2026-08-01] Hier lag __re4_run_pending_reload: die Ausfuehrung des
-- vorgemerkten nativen Reloads im LateUpdateBehavior. Mit Weg B ist sie gegenstandslos -- es gibt nichts
-- mehr vorzumerken. Der LateUpdateBehavior-Hook ist damit ebenfalls weg (eine Registrierung weniger).
-- Alte Fassung: others/re4_vr_reload.bak_2026-08-01_pre_native_removal.lua
-- Stub bleibt, falls ein anderes Script den Namen noch ruft -> tut dann nichts, statt einen nil-Call zu werfen.
_G.__re4_run_pending_reload = function() end
_G.__re4_pending_reload = nil

-- Das ECHTE Gun-WeaponItem cachen: reduceAmmoCount (Schuss) + addAmmoCount (Reload)
-- laufen beide auf dem Live-Item -> wir merken es uns in _G.__re4_live_wi.
if not _G.__re4_ammo_hooks then
    _G.__re4_ammo_hooks = true
    pcall(function()
        local td = sdk.find_type_definition("chainsaw.WeaponItem")
        -- [CACHE-TTL 2026-07-20] Zeitstempel mitschreiben: das gecachte WeaponItem darf nur
        -- kurz nach dem Hook benutzt werden. Danach kann es eine tote Instanz sein, und schon der
        -- Guard-Aufruf get_IsValid darauf ist ein virtueller Call ins Leere -> c0000005, FULL CRASH
        -- (pcall/safe faengt eine AV NICHT). Genau dieses Muster steht im Dump vom 2026-07-20 10:42.
        local function cache(args)
            local wi = safe(function() return sdk.to_managed_object(args[2]) end)
            if wi then _G.__re4_live_wi = wi; _G.__re4_live_wi_t = os.clock() end
        end
        for _, name in ipairs({ "reduceAmmoCount", "addAmmoCount" }) do
            local m = td and td:get_method(name)
            if m then sdk.hook(m, function(args) cache(args) end, function(r) return r end) end
        end
        -- RE-ACQUIRE OHNE SCHUSS: die HUD liest get_CurrentAmmoCount jeden Frame auf dem
        -- ECHTEN Laufzeit-Item. Nur cachen wenn der Cache leer ist (nach Reset/Waffenwechsel)
        -- UND die WeaponId der equippten Waffe entspricht -> billig (early-return wenn gecacht),
        -- kein "erst schiessen" mehr noetig. (sdk.hook -> braucht GAME-NEUSTART, nicht nur Reset.)
        local gca = td and td:get_method("get_CurrentAmmoCount")
        if gca then
            sdk.hook(gca, function(args)
                -- [CACHE WAR TOT, NICHT LEER 2026-08-01, -Log 61.48] Hier stand ein Early-Return auf
                -- `~= nil`. Der Cache wird aber nicht leer, sondern LEICHE: das Log zeigt add_wid=? und
                -- "cap-Quellen: add_wi=nil" bei gleichzeitig lebendem wi_live/equip/inv=6. Eine tote
                -- Instanz ist nicht nil -> der Early-Return griff, die Auffrischung lief nie, und Weg C
                -- schrieb dauerhaft in ein totes Objekt. Die Leiche selbst wird NICHT angefasst (ein
                -- Getter darauf ist eine AV, siehe CACHE-TTL oben) -- stattdessen wird der Cache
                -- zeitgesteuert erneuert: hoechstens 10x pro Sekunde, also nie teuer, und beim Reload
                -- nie aelter als 0.1 s. Damit ist er ohne Schuss und ohne Engine-Reload immer frisch.
                local now = os.clock()
                if (tonumber(rawget(_G, "__re4_live_wi_t")) or -1) > now - 0.1 then return end
                local wi = safe(function() return sdk.to_managed_object(args[2]) end)
                if not wi then return end
                -- [RE-ACQUIRE WAR TOT 2026-08-01, "es GING doch auch schon"] Hier stand
                -- `wi:call("get_WeaponId"):get_field("value__")` -- get_WeaponId liefert einen Enum-
                -- ValueType, an dem get_field scheitert; safe schluckte den Fehler, cwid war IMMER
                -- nil, die Bedingung IMMER false. Damit hat sich dieser Cache NIE ohne Schuss gefuellt.
                -- Solange der native inv:reload noch lief, hat DER intern addAmmoCount gerufen und den
                -- Cache ueber den Hook oben befuellt -- deshalb luden Teilmengen (Red9 8->9, 31.07.).
                -- Seit dem Ausbau des nativen Calls gibt es bei leerem Magazin keinen Fuellweg mehr:
                -- schiessen geht nicht, die Engine laedt nicht -> add_wid=- im Log -> Weg C schreibt
                -- auf eine Spiegel-Instanz -> Reserve weg, Waffe leer. Gleiche Auslesung wie in der
                -- START-Zeile: erst Zahl, sonst value__, beides ueber pcall statt safe.
                local cwid
                do
                    local ok, v = pcall(function() return wi:call("get_WeaponId") end)
                    if ok and v ~= nil then
                        if type(v) == "number" then cwid = v
                        else
                            local ok2, n2 = pcall(function() return v:get_field("value__") end)
                            if ok2 and type(n2) == "number" then cwid = n2 end
                        end
                    end
                end
                local ewid = get_equip_wid()
                if cwid and ewid and cwid == ewid then
                    _G.__re4_live_wi   = wi
                    _G.__re4_live_wi_t = now
                end
            end, function(r) return r end)
        end
    end)
end

-- geladene Munition der Waffe setzen.
-- WICHTIG: forceSetAmmoCount/setAmmoCount sind nur der SAVE-Pfad (greifen zur Laufzeit NICHT,
-- darum heilt Save/Load). Der LAUFZEIT-Pfad (HUD) ist reduceAmmoCount (das nutzt auch das
-- Schiessen). Zum Leeren auf 0 ziehen wir die Munition per reduceAmmoCount auf 0 runter.
local function drain_to_zero(wi)
    if not wi then return false end
    local function cur() return sc(wi, "get_CurrentAmmoCount") or 0 end
    local function still() return cur() > 0 end
    if not still() then return true end
    -- ROHE SPEICHER-SCHREIBUNG: _CurrentAmmoCount @0x44 (Int32). Das ist das Feld, das
    -- get_CurrentAmmoCount + HUD lesen und das Feuern beschreibt. write_dword umgeht
    -- set_field/Methoden-Eigenheiten komplett.
    _G.__re4_carry_capture(wi, "re4_vr_reload.lua:2229", nil)   -- [MAG-REST] merken, bevor genullt wird
    pcall(function() wi:write_dword(0x44, 0) end)
    -- (set_field("_CurrentAmmoCount") ENTFERNT: das Feld ist nur per Offset 0x44 schreibbar,
    -- nicht per Namen -> warf jedes Mal "Attempted to set invalid field" ins REFwk-Overlay.)
    -- Fallbacks (falls beides nicht greift): die Methoden der Reihe nach.
    if still() then pcall(function() wi:call("reduceAmmoCount", cur()) end) end
    if still() then pcall(function() wi:call("addAmmoCount", -cur(), false) end) end
    if still() then pcall(function() wi:call("forceSetAmmoCount", 0) end) end
    if still() then pcall(function() wi:call("setAmmoCount", 0) end) end
    return true
end
local function set_gun_loaded(n)
    local wi  = get_live_weapon_item()
    local row = get_inv_row_weapon_item()
    if n == 0 then
        -- [KEIN VERWERFEN 2026-08-12] Was noch im Magazin steckt, ist NICHT weg -- im Spiel geht dabei
        -- nie eine Patrone verloren. Der Auswurf setzt die Waffe zwar sichtbar auf 0 (VR-Fiktion:
        -- Magazin raus = Waffe leer), aber der Rest wird gemerkt und beim Einsetzen wieder
        -- draufgerechnet. Merker gilt nur fuer DIESE Waffe und wird beim Laden verbraucht.
        -- (Der Magazinrest wird NICHT hier gemerkt, sondern an der einen vorhandenen Stelle bei
        --  `mag_retained = cur` -- zwei Merker fuer dieselbe Zahl waeren genau der Doppelregler-Fehler.)
        -- Mag-Drop -> Munition LEEREN (Laufzeit, HUD geht auf 0)
        drain_to_zero(wi)
        if row and row ~= wi then drain_to_zero(row) end
        return true
    end
    -- andere Werte: Save-Pfad (selten genutzt)
    local ok = pcall(function() wi:call("forceSetAmmoCount", n) end)
    if not ok then ok = pcall(function() wi:call("setAmmoCount", n) end) end
    return ok
end

-- =====================================================================
-- Waffen-Cache (Mag-Joint)
-- =====================================================================
local wep = { wid = nil, tf = nil, mag_joint = nil, slide_joint = nil, slide_rest_lp = nil }
local _weapon_reacquired = false   -- [SAVE_LOAD] Flag: gleiche Waffe neu instanziiert
local function refresh_weapon()
    local wid = get_equip_wid()
    if not wid or wid == 0 then wep.wid, wep.tf, wep.mag_joint, wep.slide_joint, wep.slide_rest_lp = nil, nil, nil, nil, nil; return end
    -- [TOP_LOADER] Bei Chamber-Waffen reicht die Transform (kein Mag-Joint) -> Gate auf wep.tf.
    if wep.wid == wid and (wep.mag_joint or TOP_LOADER[wid]) and wep.tf and safe(function() return wep.tf:call("get_Position") end) then return end
    -- [SAVE_LOAD] Gleiche WeaponId, aber Re-Resolve noetig (alte tf ungueltig) = neue
    -- Instanz durch Save-Load/Respawn. Der Waffenwechsel-Reset greift hier NICHT (wid
    -- unveraendert) -> separat signalisieren, sonst bleibt stale Lua-State haengen.
    local same_wid = (wep.wid == wid)
    wep.wid, wep.tf, wep.mag_joint, wep.slide_joint, wep.slide_rest_lp = nil, nil, nil, nil, nil
    wep.slide_joint2 = nil   -- [EMPTY-RELOAD SLIDE] _08 (Riot Gun)
    wep.cycle_rest_rot = nil -- [ROTARY_CYCLE] Ruhe-Rotation des Drehschalters (Striker)
    local cfg = JOINTS[wid] or { mag = "", slide = "" }
    -- [TOP_LOADER] Red9 & Co: KEIN Mag/Slide noetig. Transform aufloesen, Joints optional.
    if TOP_LOADER[wid] then
        local go, tf = find_weapon(wid); if not tf then return end
        wep.wid, wep.tf = wid, tf
        wep.mag_joint   = (cfg.mag   and cfg.mag   ~= "") and sc(tf, "getJointByName", cfg.mag)   or nil
        wep.slide_joint = (cfg.slide and cfg.slide ~= "") and sc(tf, "getJointByName", cfg.slide) or nil
        if same_wid then _weapon_reacquired = true end
        return
    end
    if not (cfg.mag and cfg.mag ~= "") then return end
    local go, tf = find_weapon(wid); if not tf then return end
    local j = sc(tf, "getJointByName", cfg.mag); if not j then return end
    wep.wid, wep.tf, wep.mag_joint = wid, tf, j
    -- Slide-Joint (fuer Slide-Rack), gleicher Waffen-Transform
    wep.slide_joint = (cfg.slide and cfg.slide ~= "") and sc(tf, "getJointByName", cfg.slide) or nil
    -- [PUMP_GRIP 2026-08-07, "der Joint ist doch der, den wir bewegen"] Den NAMEN nach
    -- aussen geben, damit motion.lua den Vordergriff an EXAKT dasselbe Joint haengen kann, das
    -- hier auch gepumpt wird. Nur der Name, kein Objekt -- das ueberlebt keinen Savegame-Load.
    _G.__re4_rack_joint_name = (cfg.slide and cfg.slide ~= "") and cfg.slide or nil
    _G.__re4_rack_joint_wid  = wid
    -- [ROTARY/BREAK] Ruhe-Rotation des Dreh-/Klapp-Joints merken. BIND-Pose (get_BaseLocalRotation),
    -- NICHT live: nach Reset Scripts ist die Klappe evtl. noch offen (Engine-Zustand ueberlebt den
    -- Lua-Reset). Live wuerde dann die OFFENE Lage als "Ruhe" merken -> naechstes RIGHT-B legt den
    -- Oeffnungs-Delta obendrauf. Bind-Pose = stabile Zu-Ruhe (Klappe schnappt nach Reset zu, State
    -- wieder konsistent). Fallback auf live, falls die Methode fehlt.
    if (ROTARY_CYCLE[wid] or BREAK_ACTION[wid]) and wep.slide_joint then
        wep.cycle_rest_rot = sc(wep.slide_joint, "get_BaseLocalRotation") or sc(wep.slide_joint, "get_LocalRotation")
        -- [BREAK_ACTION] Klappe beim Erwerb einmalig auf die Zu-Ruhe setzen -> nach Reset Scripts (Engine
        -- haelt _02 evtl. noch offen) schnappt sie sofort zu, passend zum frischen break_st (open=false).
        -- Kein Snap/Delta beim ersten RIGHT-B. Nur Break-Action (Striker unangetastet).
        if BREAK_ACTION[wid] and wep.cycle_rest_rot then
            pcall(function() wep.slide_joint:call("set_LocalRotation", wep.cycle_rest_rot) end)
        end
    end
    -- [EMPTY-RELOAD SLIDE] separater Lade-Slide-Joint (_08) fuer den Empty-Reload-Chamber (Riot Gun)
    local erj = EMPTY_RELOAD_JOINT[wid]
    wep.slide_joint2 = (erj and erj ~= "") and sc(tf, "getJointByName", erj) or nil
    if same_wid then _weapon_reacquired = true end
end

-- [EMPTY-RELOAD SLIDE] aktiver Rack-Joint + Pose: im Empty-Reload-Modus der Lade-Slide (_08) mit
-- eigener Travel-Pose, sonst der normale Slide/Pump (_01). Eine Stelle -> alle Rack-Funktionen folgen.
local function rack_joint()
    if rack.empty_reload and wep.slide_joint2 then return wep.slide_joint2 end
    return wep.slide_joint
end
local function rack_slide_pose()
    if rack.empty_reload then return slide_pose2(wep.wid or 0) end
    return slide_pose(wep.wid or 0)
end

-- =====================================================================
-- [SND] Waffen-Sounds: Trigger-IDs auf dem SoundContainer der equippten Waffe.
-- PER-WAFFE (jede Pistole hat eigene Trigger-IDs in ihrem SoundContainer).
-- IDs holen mit #re4_sound_player.lua -> Treenode "Equipped Weapon (live)" -> id=-Spalte.
-- Fehlende ID = nil -> play_weapon_sound returnt still (kein falscher Sound).
-- =====================================================================
local SND_BY_WID = {
    [4004] = {                    -- Matilda (bestaetigt 2026-06-13)
        dry_fire    = 1757452382, -- Klick bei leerer Waffe (Trigger gezogen, gesperrt)
        mag_eject   = 1466005368, -- Mag verlaesst die Waffe (Auswurf, sofort)
        mag_insert  = 3805002294, -- Mag rastet voll in der Waffe ein (Insert-Ende)
        mag_floor   = 3140689763, -- Mag schlaegt auf dem Boden auf (verzoegert)
        slide_back  = 943565871,  -- Slide zurueck UND nach vorn (1 Sound, 2x gespielt; 2026-06-15 von 2254736732 umgestellt)
        mag_holster = 1839787494, -- Mag aus dem Holster gezogen
    },
    [4001] = {                    -- Punisher (per Audition bestaetigt 2026-06-14)
        dry_fire    = 812850326,  -- Klick bei leerer Waffe
        mag_eject   = 1466005368, -- Mag verlaesst die Waffe (= Matilda)
        mag_insert  = 1757452382, -- Mag rastet ein
        mag_floor   = 3140689763, -- Mag faellt auf den Boden (= Matilda)
        slide_back  = 943565871,  -- Slide zurueck UND nach vorn (1 Sound, 2x gespielt)
        mag_holster = 1839787494, -- Mag aus dem Holster (= Matilda)
    },
    -- [PORT 2026-06-15] 1:1 von Punisher (4001). Andere Waffen haben evtl. EIGENE
    -- Trigger-IDs im Weapon-SoundContainer -> bei falschem/stummem Sound via
    -- #re4_sound_player.lua "Equipped Weapon (live)" die echten id= ziehen.
    [4000] = {                    -- SG-09 R (Punisher-IDs)
        dry_fire    = 812850326, mag_eject = 1466005368, mag_insert = 1757452382,
        mag_floor   = 3140689763, slide_back = 943565871, mag_holster = 1839787494,
    },
    [4003] = {                    -- Blacktail (Punisher-IDs)
        dry_fire    = 812850326, mag_eject = 1466005368, mag_insert = 1757452382,
        mag_floor   = 3140689763, slide_back = 943565871, mag_holster = 1839787494,
    },
    [6000] = {                    -- Sentinel Nine DLC (Punisher-IDs)
        dry_fire    = 812850326, mag_eject = 1466005368, mag_insert = 1757452382,
        mag_floor   = 3140689763, slide_back = 943565871, mag_holster = 1839787494,
    },
    [6300] = {                    -- [MC_6300 2026-08-04] XM96E1 (Mercenaries), Punisher-IDs als Start
        dry_fire    = 812850326, mag_eject = 1466005368, mag_insert = 1757452382,
        mag_floor   = 3140689763, slide_back = 943565871, mag_holster = 1839787494,
    },
    [6301] = {                    -- [MC_6301 2026-08-15] Blacktail AC (Mercenaries) <- 4003, gleiche IDs
        dry_fire    = 812850326, mag_eject = 1466005368, mag_insert = 1757452382,
        mag_floor   = 3140689763, slide_back = 943565871, mag_holster = 1839787494,
    },
    [4002] = {                    -- Red9 (Punisher-IDs als Start; per #re4_sound_player.lua nachziehen)
        dry_fire    = 812850326, mag_eject = 1466005368, mag_insert = 1757452382,
        mag_floor   = 3140689763, slide_back = 943565871, mag_holster = 1839787494,
        chamber     = 1113312480, -- Chamber auf UND zu (1 Sound, beide Richtungen)
    },
    -- [SMG PORT] Punisher-IDs als Start -> per #re4_sound_player.lua je SMG nachziehen
    [4200] = { dry_fire=812850326, mag_eject=1466005368, mag_insert=1757452382, mag_floor=3140689763, slide_back=943565871, mag_holster=1839787494 },  -- TMP
    [4201] = { dry_fire=812850326, mag_eject=1466005368, mag_insert=1757452382, mag_floor=3140689763, slide_back=943565871, mag_holster=1839787494 },  -- Chicago Sweeper
    [4202] = { dry_fire=812850326, mag_eject=1466005368, mag_insert=1757452382, mag_floor=3140689763, slide_back=943565871, mag_holster=1839787494 },  -- LE 5
    -- [SHOTGUN] W-870: mag_holster=Shell aus dem Holster gezogen, mag_insert=Shell rastet im Ladeport ein,
    -- slide_back=Pump (zurueck+vor). Punisher-IDs als Start -> per #re4_sound_player.lua die echten W-870-IDs ziehen.
    [4100] = { dry_fire=812850326, mag_eject=1466005368, mag_insert=942865223, mag_floor=1351699582, slide_back=741230436, mag_holster=1839787494 },  -- W-870 (slide_back=Pump-Cock 741230436 2x; mag_insert=942865223 Shell-Einleg; Shell-Boden=1351699582)
    [4101] = { dry_fire=812850326, mag_eject=1466005368, mag_insert=942865223, mag_floor=1351699582, slide_back=1001178976, mag_holster=1839787494 },  -- Riot Gun: Shell-Insert=942865223; Pump (hin UND her)=1001178976; Shell-Boden=1351699582
    [4102] = { dry_fire=812850326, mag_eject=1466005368, mag_insert=942865223, mag_floor=1351699582, slide_back=741230436, mag_holster=1839787494, cycle=942865223 },  -- Striker: cycle=942865223 (Drehschalter-Dreh-Sound)
    [6001] = { dry_fire=812850326, mag_eject=1466005368, mag_insert=942865223, mag_floor=1351699582, slide_back=741230436, mag_holster=1839787494, break_open=1938228639 },  -- Skull Shaker: break_open=Klapp-Sound (auf/zu)
    [4501] = { dry_fire=812850326, mag_eject=1466005368, mag_insert=1757452382, mag_floor=3140689763, slide_back=943565871, mag_holster=1839787494 },  -- Killer7 (Punisher-IDs als Start)
}
-- aktuelle Waffen-Sounds (nach equippter wid). nil-tolerant.
local function snd(key)
    local t = wep.wid and SND_BY_WID[wep.wid]
    return t and t[key] or nil
end
-- 1:1 wie der Sound-Player (#re4_sound_player.lua): simple trigger(uint32) ist
-- hoerbar fuer alle Matilda-IDs. (Full-Sig gelang lautlos -> stumm, verworfen.)
local _sg_our_sound = false   -- [SG PUMP DIAG temp] true waehrend unserer eigenen Trigger-Calls
local function play_weapon_sound(id)
    if not CFG.sound_enabled or not id or id <= 0 then return end
    local tf = wep.tf; if not tf then return end
    local go = safe(function() return tf:call("get_GameObject") end)
    if not go or not TD.snd_sc then return end
    local scn = safe(function() return go:call("getComponent(System.Type)", TD.snd_sc) end)
    if not scn then return end
    _sg_our_sound = true
    pcall(function() scn:call("trigger(System.UInt32)", id) end)
    _sg_our_sound = false
end

-- [SG PUMP MUTE] Die Shotgun-Engine spielt nach JEDEM Schuss automatisch den Pump-Cock-Sound,
-- obwohl wir die Pump-Bewegung (_01) unterdruecken -> klingt falsch. Diese Engine-Auto-Pump-ID
-- pro Waffe am SoundContainer-Trigger blocken. NUR die Engine-Variante (ours=false): unser eigener
-- manueller Pump-Sound (play_weapon_sound -> ours=true) bleibt durch, falls wir die ID dort nutzen.
-- sdk.hook -> braucht GAME-NEUSTART. Guard ueberlebt Reset Scripts.
local AUTO_PUMP_MUTE = { [4100] = 1964290782, [4101] = 1964290782, [4102] = 1964290782, [6001] = 1964290782 }   -- [wid] = Engine-Auto-Pump-Sound-ID (W-870-Kopie fuer Riot/Striker/Skull Shaker, ggf. eigene ID spaeter)
if not _G.__sg_pump_mute_v4 then
    _G.__sg_pump_mute_v4 = true
    -- [log entfernt]
    -- soundlib.SoundManager.postRequestInfo(RequestInfo) = globaler Sound-Funnel: ALLE Sounds laufen
    -- hier durch (auch Motion-SE, die am Weapon-SoundContainer vorbeigehen -> deshalb sah der
    -- Container-Hook den Pump nie). RequestInfo erbt von SoundTriggerInfo -> _TriggerId@0x10, _EventId@0x14.
    local td = sdk.find_type_definition("soundlib.SoundManager")
    local m  = td and td:get_method("postRequestInfo(soundlib.SoundManager.RequestInfo)")
    if m then
        sdk.hook(m,
            function(args)
                if not is_shotgun(wep.wid) then return end
                local tid, eid
                pcall(function()
                    local info = sdk.to_managed_object(args[3])
                    if info then tid = info:read_dword(0x10); eid = info:read_dword(0x14) end
                end)
                -- [log entfernt]
                local mute_id = AUTO_PUMP_MUTE[wep.wid]
                if mute_id and (not _sg_our_sound) and (tid == mute_id or eid == mute_id) then
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
            end,
            function(r) return r end)
    end
end

-- [LET-GO] true nur wenn handled~=nil (in on_frame gesetzt). Gate fuer Render-Paesse +
-- Holster-Grab: Toggle aus -> wir schreiben/greifen NICHTS, alles nativ.
local _managed = false

-- ist die aktuell equippte Waffe von uns verwaltet (Master + Gattung + Joints)?
local function handled()
    -- KEIN Master mehr -> jede Gattung haengt allein an ihrem eigenen Toggle (category_enabled).
    local wid = get_equip_wid(); if not wid then return nil end
    local cat = category_of(wid); if not category_enabled(cat) then return nil end
    if TOP_LOADER[wid] then return wid end   -- [TOP_LOADER] Chamber-Modell, kein Mag-Joint noetig
    local jc = JOINTS[wid]; if not (jc and jc.mag and jc.mag ~= "") then return nil end
    return wid
end

-- =====================================================================
-- Mag-Drop (RE9-Mathe, Welt-Raum)
-- =====================================================================
local drop = { active = false, use_module = false, joint = nil, sx = 0, sy = 0, sz = 0, t0 = 0 }
local mag_hand = { active = false, joint = nil }   -- Mag in der linken Hand (nach Mag-Holster-Grab)
local mag_insert = { active = false, joint = nil, t0 = 0, dur = 0.18 }  -- Slide-in Hand->Kammer
-- "Mag drin?" wird ABGELEITET (kein getracktes Flag -> kann nicht desyncen/haengen):
-- drin = kein manueller Flow aktiv (kein Drop gehalten, nicht in Hand, kein Insert).
local function mag_is_present() return not (drop.active or mag_hand.active or mag_insert.active) end
local mag_tune = { active = false }   -- reiner Einstell-Modus (positionieren), getrennt vom Reload-Flow

-- [MAG_OUT] Anti-Doppeldrop: sobald das Mag ausgeworfen ist, kommt KEIN zweites mehr
-- (force_eject droppt sonst bei jedem B ein neues Mag aus der Kammer). Das Flag wird
-- frisch aus der Engine GEHEILT: sobald live_loaded_count > 0 (Mag wieder geladen),
-- faellt es automatisch auf false -> kann nicht haengen bleiben (das war der alte
-- Bug, der B nach Reset/Save-Load totmachte). Kein gecachter kritischer Gate-State.
local mag_out = false
local mag_out_store = {}   -- [MAG_OUT] per WeaponId gemerkter Draussen-Zustand (ueberlebt Waffenwechsel)
local mag_retained = 0     -- [MAG_RETAIN] geladene Patronen beim Drop gemerkt (UI zeigt 0, intern bleiben sie)

local function start_mag_drop()
    if not wep.mag_joint then return false end
    mag_hand.active = false   -- neuer Drop -> Mag nicht mehr in der Hand
    mag_insert.active = false -- evtl. laufenden Insert abbrechen
    mag_insert.settle = false   -- [INSERT-PUNCH] Nachfedern mit abbrechen
    mag_tune.active = false   -- Einstell-Modus weicht dem echten Reload
    -- [MAG_RETAIN] Geladenen Stand MERKEN, bevor die UI auf 0 geht. Die Patronen gehen
    -- NICHT verloren: beim Insert kommt der Stand zurueck (+ Reserve oben drauf bis Cap).
    -- UI zeigt 0, solange das Mag draussen ist (Anforderung).
    if CFG.reload_ammo then
        local pe0 = get_pe()
        local cur = pe0 and tonumber(sc(pe0, "getCurrentGunAmmo"))   -- echter HUD-Stand
        if not cur then
            local wi0 = get_live_weapon_item()
            cur = wi0 and (sc(wi0, "get_CurrentAmmoCount") or 0) or 0
        end
        mag_retained = cur or 0
        -- [EINE QUELLE 2026-08-12] Genau hier wird der Magazinrest gemerkt -- aber `mag_retained` ist ein
        -- local, das erst ~1300 Zeilen SPAETER steht: der (R)/(C)-Ladeweg weiter oben kann es gar nicht
        -- sehen und lud deshalb nur die Reserve (4 in der Waffe + 5 Reserve ergaben 5 statt 9).
        -- Deshalb dieselbe Zahl zusaetzlich als Global spiegeln -- kein zweiter Merker, nur sichtbar
        -- gemacht. Verbraucht und geloescht wird sie dort beim Laden.
        _G.__re4_mag_carry     = mag_retained
        _G.__re4_mag_carry_wid = get_equip_wid()
        set_gun_loaded(0)   -- UI auf 0
        -- [ACCESSOR-FOLGE 2026-08-12] Die 0 oben ist UNSER Werk (HUD-Anzeige "Magazin raus").
        -- Seit der Ladeweg auf der ECHTEN Instanz arbeitet, wirkt dieses Leeren auch wirklich --
        -- vorher verpuffte es auf einer Kopie. Die Kammer-Pruefung beim Einsetzen darf diesen
        -- selbstgesetzten 0-Stand deshalb NICHT als "Kammer leer" werten, sonst verlangt jede
        -- Magazinwaffe nach JEDEM Reload ein Slide-Rack. Der echte Leer-Fall steckt in
        -- `rack.empty_when_dropped`, das direkt VOR diesem Leeren gelatcht wird.
        rack._zeroed_by_us = true
    end
    -- bevorzugt das Advanced-Modul (Slide-aus-der-Kammer + Fall)
    local ms = _G.__re4_reload_mag_slide
    if ms then
        ms.current_mag_joint = wep.mag_joint
        -- [EINLEIT-PUNKT ALS DROP-ZIEL 2026-07-23] Das Mag gleitet zum SELBEN Punkt raus, an dem
        -- es beim Reinsliden ansetzt -- rueckwaerts die Kammerachse entlang. Inline berechnet (reload.lua
        -- ist am 200-Local-Limit, keine eigene Funktion moeglich). Fehlt der Punkt -> alter Exit-Vektor.
        local drop_target = nil
        do
            local mj = wep.mag_joint
            if PARENT_SPACE_DOCK[wep.wid] and type(ms.dock_world) == "function" and mj and wep.tf then
                local W = ms.dock_world(wep.tf, wep.wid or 0)
                local jw = W and sc(mj, "get_Position"); local jr = W and sc(mj, "get_Rotation")
                local jlp = W and sc(mj, "get_LocalPosition"); local jlr = W and sc(mj, "get_LocalRotation")
                if W and jw and jr and jlp and jlr then
                    drop_target = safe(function()
                        local dd = jlr * (jr:conjugate() * (W - jw))
                        return { x = jlp.x + dd.x, y = jlp.y + dd.y, z = jlp.z + dd.z }
                    end)
                end
            elseif type(ms.dock_local) == "function" and wep.tf then
                drop_target = ms.dock_local(wep.tf, wep.wid or 0)
            end
        end
        local bd_ok = ms.begin_drop(wep.mag_joint, wep.wid, CFG.insert_dur, drop_target)   -- Slide-Out = Insert-Speed
        if bd_ok then
            drop.active, drop.use_module, drop.joint = true, true, wep.mag_joint
            rlog(string.format("mag-drop START (slide) wp%s", tostring(wep.wid)))
            return true
        end
    end
    -- Fallback: einfacher Gravity-Drop im Welt-Raum
    local p = sc(wep.mag_joint, "get_Position")
    if not p then return false end
    drop.joint, drop.use_module = wep.mag_joint, false
    drop.sx, drop.sy, drop.sz = p.x, p.y, p.z
    -- [ENTKOPPEL_ROT] Weltrotation beim Drop-Start einfrieren -> Mag folgt am Boden NICHT der
    -- Waffenrotation (wie der Modul-Pfad in reload_adv). Feste Weltpose bis stop_mag_drop.
    do local r = sc(wep.mag_joint, "get_Rotation")
       if r then drop.srw, drop.srx, drop.sry, drop.srz = r.w, r.x, r.y, r.z else drop.srw = nil end end
    drop.t0 = os.clock()
    drop.active = true
    rlog(string.format("mag-drop START (fall) wp%s @(%.3f,%.3f,%.3f)", tostring(wep.wid), p.x, p.y, p.z))
    return true
end
local function stop_mag_drop()
    if drop.use_module then local ms = _G.__re4_reload_mag_slide; if ms then ms.cancel() end end
    drop.active, drop.use_module, drop.joint = false, false, nil
end
local DROP_FALL_DUR = 1.0   -- [DROP-AUTOCLEAR] Sek bis der kosmetische Fall ausgelaufen ist
local function update_mag_drop()
    if not drop.active then return end
    if drop.use_module then
        local ms = _G.__re4_reload_mag_slide
        if ms then ms.tick() end
        return
    end
    if not drop.joint then return end
    local t = os.clock() - drop.t0
    -- [DROP-AUTOCLEAR] Der freie Fall ist rein kosmetisch. Nach DROP_FALL_DUR die Drop-Phase BEENDEN,
    -- sonst haengt drop.active=true -> flow_active=true -> Feuer FUER IMMER gesperrt (Soft-Lock; bei der
    -- Shotgun mit noch geladenem Ammo = "habe Munition, kann nicht schiessen"). Darf nie passieren.
    if t > DROP_FALL_DUR then
        -- Shotgun: die losgelassene Shell ist nur Deko (Ammo unveraendert) -> _04 zurueck in die Ruhepose,
        -- damit die gechamberte Shell wieder sichtbar ist. Pistole: Mag ist echt ausgeworfen (mag_out
        -- blockt weiter) -> liegen lassen.
        if is_shotgun(wep.wid) and wep.mag_joint and wep.rest_lp then
            pcall(function() wep.mag_joint:call("set_LocalPosition", Vector3f.new(wep.rest_lp.x, wep.rest_lp.y, wep.rest_lp.z)) end)
            if wep.rest_lr then
                pcall(function() wep.mag_joint:call("set_LocalRotation",
                    Quaternion.new(wep.rest_lr.w, wep.rest_lr.x, wep.rest_lr.y, wep.rest_lr.z)) end)
            end
        end
        drop.active, drop.joint = false, nil
        return
    end
    local fall = 0.5 * CFG.gravity * t * t              -- s = 1/2 g t^2 (freier Fall)
    pcall(function() drop.joint:call("set_Position", Vector3f.new(drop.sx, drop.sy - fall, drop.sz)) end)
    -- [ENTKOPPEL_ROT] Weltrotation jeden Frame festhalten -> Mag bleibt starr, folgt nicht der Waffe.
    if drop.srw then pcall(function() drop.joint:call("set_Rotation", Quaternion.new(drop.srw, drop.srx, drop.sry, drop.srz)) end) end
end

-- ---- Mag in der LINKEN Hand halten (nach Mag-Holster-Grab) ----
local lhand_joint = nil
local function get_left_hand()
    local bt = body_tf(); if not bt then return nil end
    local valid = lhand_joint and safe(function() return lhand_joint:get_Valid() end)
    if not valid then lhand_joint = sc(bt, "getJointByName", "L_Hand") or sc(bt, "getJointByName", "L_Arm_Hand") end
    return lhand_joint
end
-- [MANUAL_INSERT 2026-08-15] Welche Waffen schiebt man von Hand ein?
-- Quelle ist bewusst `M.PUSH_WIDS` aus reload_adv (die Waffen MIT Druecken-Geste) statt einer
-- zweiten Liste: der Handschub braucht diese Geste zwingend (sie haelt die Hand am Magazin), und
-- so kann keine Waffe in der einen Liste stehen und in der anderen fehlen. Waffen ohne Push-Geste
-- (Shotgun-Shells, Bogen, Break-Action, Red9) fahren unveraendert die Zeitbahn.
-- Diese Tabelle bleibt als AUSNAHME-Liste: ein Eintrag `[wid] = false` nimmt eine Waffe wieder raus.
-- BEWUSST als Global und nicht als weiterer Top-Level-Local: diese Datei sitzt am 200-Local-Limit
-- (siehe Notiz bei __re4_shotgun_ratio_get).
-- [6104 RAUS 2026-08-15] Adas MP-AF (SW-TMP) bekommt den Handschub NICHT -- Ansage: nur ihre beiden
-- Pistolen (6103 Blacktail AC, 6112 Punisher MC). Sie steht zwar in PUSH_WIDS, wird hier aber
-- ausgenommen und faehrt damit unveraendert die alte Zeitbahn.
_G.__re4_insert_manual_wid = { [6104] = false }   -- leer = alle Waffen mit Push-Geste; [wid]=false schliesst eine aus

-- [MANUAL_INSERT] Der Messwert fuer den Handschub: Abstand LINKE HAND <-> RECHTE HAND.
-- Ausdruecklich NICHT gegen die Waffe oder einen Weltanker (bekannte Falle, siehe Gesten-Notiz):
-- die Waffe wandert mit der rechten Hand, ein Weltanker wandert beim Laufen/Drehen weg -- beides
-- wuerde als Schub gelesen. Der Handabstand steht still, solange man die Haende nicht zueinander bewegt.
-- Rueckgabe in Metern oder nil (dann faellt der Aufrufer auf die Zeitbahn zurueck).
-- ZWINGEND die ROHEN Controller-Positionen (__vr_*_ctrl_raw), NICHT die Handjoints: waehrend des
-- Einschiebens zieht der Push-Dock die linke Hand per IK ans Magazin -- und das Magazin faehrt auf
-- unserem Weg. Am Handjoint gemessen bewegte der Schub also die Hand, die Hand den Messwert und der
-- Messwert wieder den Schub: eine Rueckkopplung. Der Controller in der echten Hand ist davon unberuehrt.
-- [HOEHE STATT ABSTAND 2026-08-15] Gemessen wird die HOEHE des linken Controllers, nicht mehr der
-- Abstand zur rechten Hand. Grund steht im Messlog (re4_mag_push.log, 18:41:52-54): beim Einschieben
-- liegt die linke Hand bereits ~7 cm HOEHER als die rechte, jede weitere Aufwaertsbewegung entfernt
-- sie also von ihr -- der Abstand WUCHS um 6,7 cm, waehrend die Hand 10 cm hochfuhr, und das Mag fuhr
-- prompt wieder heraus. Fuer Magazine ist der Abstand damit prinzipiell falsch herum (bei der Pumpgun
-- passt er, weil man dort ZUR anderen Hand zieht; beim Magazin schiebt man an ihr VORBEI nach oben).
-- Die Hoehe kann das Vorzeichen nicht drehen: Controller hoch = Mag rein, runter = Mag raus.
-- Aendern betrifft IMMER alle Waffen mit Handschub (Leon 4000/4001/4003/4004/4200/4501/6000/6300/6301,
-- Ada 6103/6112) -- nie an einer Waffe "mal eben" drehen.
-- [WAFFENACHSE 2026-08-15 -- GEMESSEN, data/re4_mag_axis.log] Die Hoehe allein reicht nicht:
-- kippt man die Waffe im Roll und schiebt das Magazin SEITLICH ein, gewinnt die Hand kaum
-- Hoehe. Im Log bei roll +86 Grad schwankte `-lp.y` nur noch (-0.059 / -0.073 / -0.118) und
-- `prog` taumelte zwischen 0.03 und 0.90 -- das Mag ging nie hinein.
-- Darum wird jetzt entlang der WAFFEN-Y-ACHSE gemessen, also der Richtung, in der das
-- Magazin wirklich in den Schacht faehrt. Weil Hand UND Achse im selben Raum liegen, dreht
-- die Messung mit der Waffe mit: aufrecht verhaelt sie sich wie bisher, gekippt zaehlt der
-- seitliche Schub genauso.
-- WARUM DAS NICHT DIE ZWEI VERWORFENEN WEGE VON HEUTE FRUEH IST:
--   * NICHT die Achse "Hand -> Ladepunkt" -- die war beim Andocken winzig und ihre Richtung
--     reines Rauschen. Hier ist die Achse fest an der Waffe, unabhaengig vom Handabstand.
--   * NICHT die dynamisch nachgefuehrte Magazinbahn -- die koppelte zurueck (Mag faehrt,
--     Bahn wandert mit, Mag snappte). Hier bewegt sich die Achse nur mit der WAFFE, nie mit
--     dem Magazin.
-- Vorzeichen wie gehabt: der Rueckgabewert muss beim Einschieben KLEINER werden, damit die
-- bestehende Rechnung (d0 - d) waechst. Die Hand naehert sich dem Schacht von unten, ihre
-- Y-Komponente im Waffenraum steigt also -> mit Minus davor wird der Wert kleiner.
-- FALLBACK: fehlt die Waffe oder ihre Transform, wird wieder die reine Hoehe geliefert --
-- dann verhaelt sich alles exakt wie vorher, nie haengen.
-- RUECKBAU auf den alten Weg: `_G.__re4_mag_push_world_y = true`.
-- Aendern betrifft IMMER alle Waffen mit Handschub (Leon 4000/4001/4003/4004/4200/4501/6000/
-- 6300/6301, Ada 6103/6104/6112) -- nie an einer Waffe "mal eben" drehen.
-- [BREMSE WIEDER RAUS 2026-08-15] Hier stand kurzzeitig ein Filter gegen Ausreisser im
-- Messwert (gemessen: bei Adas Waffen sprang er bis 0.407 m zwischen zwei Abtastungen,
-- Median 0.0002 m -- bei 0.09 m Einschubweg rastet EIN solcher Ausschlag das Magazin ein).
-- BEIDE Varianten sind im Spiel durchgefallen und wurden ersatzlos entfernt:
--   1) Wert auf eine Maximalrate bremsen -> Nachlauf: das Mag hinkt der Hand hinterher, die
--      Hand klebt per IK am Mag, es zieht nach -> die haltende Hand ZITTERTE bei beiden
--      Charakteren, auch bei Leon, der vorher einwandfrei lief.
--   2) Sprung in einen Offset buchen statt zu bremsen (kein Nachlauf in der Theorie) --
--      im Spiel ebenfalls schlechter als ganz ohne.
-- NICHT NOCHMAL FILTERN. Wer die Spruenge angehen will, muss an ihre Quelle: sie kommen aus
-- der WAFFEN-Transform (der Wert misst Hand relativ zur Waffe), nicht aus der Hand.

-- [ZURUECK AUF LEONS WEG 2026-08-15] Gemessen wird wieder ausschliesslich die HOEHE des
-- linken Controllers -- fuer BEIDE Charaktere, ohne Gate, ohne Sonderfall.
-- Dazwischen lagen mehrere Umbauten (Waffen-Y-Achse, Handweg-Integration, Ausreisser-Bremse,
-- Ada-Gate). Alle sind wieder raus: keiner davon war durch eine Messung gedeckt, und der
-- Ada-Unterschied liess sich mit KEINER Messung am Messwert nachweisen --
--   * ratio-Messung Ada 6112: Hand 3.054 m -> Push 2.334 m (0.76), also eher LANGSAMER
--   * Waffen-Transform sauber: 3-7 cm/Frame, par=ja, GO konstant
--   * die vermeintlichen 0.4-m-Spruenge waren ein Abtastraster-Artefakt (0.25 s)
-- Wenn Adas Magazin bei ~10 % Weg einrastet, liegt es also NICHT an dieser Zahl, sondern an
-- ihrer Verarbeitung in re4_vr_reload4_dlc.lua (d0 / prog / insert_travel) -- DORT messen,
-- bevor hier wieder etwas umgebaut wird.
-- Vorzeichen: hoehere Hand = kleinerer Wert -> (d0 - d) waechst -> Schub nach vorn.
-- [WELTKOORDINATE -- MESSBEFUND 2026-08-18, KEIN UMBAU]
-- Gemessen, bleibt als Wissen stehen: `__vr_lh_ctrl_raw` ist eine WELTPOSITION
-- (re4_vr_motion.lua:3304, `controller_to_world`). `-lp.y` misst also die Hoehe der Hand IM
-- LEVEL, nicht den Schub. Im Watcher-Log stand waehrend eines einzigen Einschubs `move=5.051`
-- und `hand dx=-4.882` -- fuenf Meter "Handbewegung", also reine Fortbewegung des Spielers.
-- Daher: bergab/ducken -> `prog` wird negativ (gemessen -0.271 bei 21 cm Schub) und
-- unterschreitet die Rueckzieher-Schwelle; bergauf/laufen -> das Mag rastet von selbst ein.
--
-- Der naheliegende Umbau (Hand im WAFFENRAUM messen) wurde am 18.08. gebaut und SOFORT wieder
-- entfernt: das Magazin rastete augenblicklich ein und die linke Hand klebte nicht mehr sauber
-- unten am Mag. Das ist EXAKT das Ergebnis vom 15.08. ("Projektion auf die Magazinbahn -- das
-- Mag snappte hinein statt zu folgen"). Damit ist der Waffenraum als Messgroesse zum zweiten Mal
-- durchgefallen: NICHT nochmal versuchen.
-- Was noch offen ist: eine Groesse, die weder an der Weltposition haengt (Fortbewegung faelscht
-- sie) noch am Waffenraum (snappt). Naechster ungetesteter Kandidat waere die Hand relativ zum
-- KOPF/Koerper -- vor einem weiteren Umbau aber erst messen.
-- Vorzeichen: hoehere Hand = kleinerer Wert -> (d0 - d) waechst -> Schub nach vorn.
_G.__re4_mag_push_dist = function()
    local lp = rawget(_G, "__vr_lh_ctrl_raw")
    if not lp then return nil end
    return -lp.y
end

-- [MESSWEG STEHT FEST 2026-08-15] Am 15.08. wurden zwei Alternativen probiert und BEIDE wieder
-- ausgebaut, weil das Einschieben damit schlechter lief als mit dem Handabstand:
--   1) Projektion auf die Achse "Hand -> Ladepunkt" (Waffenraum) -- ging gar nicht mehr: steht die
--      Hand beim Andocken schon fast am Punkt, ist der Vektor winzig und seine Richtung Rauschen.
--   2) Projektion auf die Magazinbahn (Andockpunkt -> Ruhelage), Hand im Waffenraum gemessen --
--      das Mag snappte hinein statt zu folgen.
-- [UEBERHOLT 2026-08-15 abends] Der Handabstand wurde noch am selben Tag durch die HOEHE
-- ersetzt und diese dann durch die WAFFEN-Y-ACHSE (s. Block bei `__re4_mag_push_dist`).
-- Der Grund fuer den letzten Schritt ist gemessen (data/re4_mag_axis.log): bei gekippter
-- Waffe traegt die Hoehe nicht. Die beiden oben genannten Sackgassen bleiben Sackgassen --
-- die Waffenachse ist keine von ihnen, weil sie weder am Handabstand haengt (1) noch dem
-- fahrenden Magazin nachgefuehrt wird (2).
-- Wer das wieder anfasst: es betrifft IMMER alle Waffen mit Handschub
-- (Leon 4000/4001/4003/4004/4200/4501/6000/6300/6301, Ada 6103/6104/6112) -- also nie an
-- einer Waffe "mal eben" umstellen.

local thumb_joint = nil
local function get_thumb_joint()
    local bt = body_tf(); if not bt then return nil end
    local valid = thumb_joint and safe(function() return thumb_joint:get_Valid() end)
    if not valid then thumb_joint = sc(bt, "getJointByName", "L_Thumb1") end
    return thumb_joint
end


local function update_mag_in_hand()
    _G.__re4_reload_ui_wid = wep.wid   -- aktuell gefuehrte Waffe (Einleit-Punkt-UI in reload_adv)
    -- aktiv durch echten Reload-Grab ODER reinen Einstell-Modus
    local joint = (mag_hand.active and mag_hand.joint) or (mag_tune.active and wep.mag_joint) or nil
    if not joint then
        -- Mag nicht (mehr) in der Hand -> Hand-Pose dem Spiel zurueckgeben
        _G.__vr_mag_hand_pose = nil
        _G.__vr_mag_hand_trx, _G.__vr_mag_hand_try, _G.__vr_mag_hand_trz = nil, nil, nil
        return
    end
    local wid_for = (mag_hand.active and mag_hand.wid) or wep.wid or 0
    local m = maghand(wid_for)
    -- Greif-Pose (Finger) + Daumen-Spreizung NICHT hier direkt anwenden (Pre-Anim -> Engine
    -- ueberschreibt). Stattdessen Pose-NAME + Daumen-Offset publizieren; motion.lua wendet
    -- es im POST-ANIM-Pass an (eigener Global, voellig getrennt von der Rack-Slide-Pose).
    -- leere mag_hold_pose = KEINE Pose erzwungen (Finger frei -> zum Aufnehmen einer neuen Pose).
    -- [POSE PER WAFFE] eigene Pose dieser Waffe bevorzugen, sonst globale (Pistolen unveraendert).
    local _mp = (wep.wid and MAG_POSE[wep.wid]) or CFG.mag_hold_pose
    _G.__vr_mag_hand_pose = (_mp and _mp ~= "" and _mp) or nil
    _G.__vr_mag_hand_trx, _G.__vr_mag_hand_try, _G.__vr_mag_hand_trz = m.t_rx, m.t_ry, m.t_rz
    -- [SHELL_CLONE] Skull Shaker (6001): den Mag-Joint (_04, Part 1 ist daran geskinnt) NICHT in die
    -- Hand ziehen -> sonst haengt Part 1 doppelt zum Mesh-Clone in der Hand. Finger-Pose (oben schon
    -- publiziert) bleibt; die sichtbare Shell ist der Clone. _04 bleibt in Ruhe (Engine-kontrolliert).
    if wep.wid == 6001 then return end
    local lh = get_left_hand(); if not lh then return end
    local hp = sc(lh, "get_Position"); if not hp then return end
    local hr = sc(lh, "get_Rotation")
    local wx, wy, wz = hp.x, hp.y, hp.z
    if hr then
        local off = safe(function() return hr * Vector3f.new(m.x, m.y, m.z) end)
        if off then wx, wy, wz = hp.x + off.x, hp.y + off.y, hp.z + off.z end
    end
    pcall(function() joint:call("set_Position", Vector3f.new(wx, wy, wz)) end)
    if hr then
        local rot = safe(function() return (hr * quat_from_euler(m.rx, m.ry, m.rz)):normalized() end)
        if rot then pcall(function() joint:call("set_Rotation", rot) end) end
    end
end

-- Chamber-Ruhepose (lokal) des Mag-Joints erfassen, solange unmanipuliert
local function capture_mag_rest()
    if not wep.mag_joint then return end
    if drop.active or mag_hand.active or mag_insert.active then return end
    -- [RUHELAGE HAERTEN 2026-08-17] Diese live gemessene Nulllage ist der Endpunkt der Einschubachse
    -- (mag_insert.rlp) -- faengt sie einen Engine-/Eigen-Zustand ein, zeigt die Achse danach falsch und
    -- der Handschub bringt keinen Fortschritt mehr (s. NOTBREMSE in update_mag_insert). Zwei Luecken:
    -- 1. `mag_insert.settle`: die Nachfeder-Phase schreibt die Mag-Position selbst (set_LocalPosition im
    --    Overshoot-Block) und laeuft NACH `active` -- in diesen ~0.07 s wurde bisher gemessen.
    -- 2. Kein reines Gameplay (Killswitch/Cutscene/Menue/Boot): dort posiert die Engine Waffe und Mag
    --    selbst. Bewusst nur bei ausdruecklichem `false` blocken -- ist das Binding nicht aktiv (Global
    --    nil), wird wie bisher gemessen, damit die Ruhelage nie ganz ausfaellt (ohne sie kein Insert).
    if mag_insert.settle then return end
    if rawget(_G, "__re4_frame_is_gameplay") == false then return end
    if shell_eject.preview or shell_eject.flying then return end   -- [SHELL_EJECT] _04 verschoben -> NICHT als Ruhepose erfassen (Drift)
    if rawget(_G, "__re4_mag_eject_kf_preview") then return end   -- [MAG-EJECT-KEYFRAMES] Mag haengt am Tuning-Punkt -> nicht als Ruhepose erfassen (Drift)
    if mag_out then return end   -- [MAG_OUT] Mag-Mesh ist versteckt -> NICHT als Ruhepose erfassen
    local lp = sc(wep.mag_joint, "get_LocalPosition")
    local lr = sc(wep.mag_joint, "get_LocalRotation")
    if lp then wep.rest_lp = { x = lp.x, y = lp.y, z = lp.z } end
    if lr then wep.rest_lr = { w = lr.w, x = lr.x, y = lr.y, z = lr.z } end
    -- (Slide-Ruhepose wird NICHT mehr erfasst -> Slide-Z ist hartcodiert absolut, s. SLIDE_POSE)
    -- [SHOTGUN CHAMBER] Chamber-Port (waffen-lokaler Offset) jetzt erfassen, solange _04 in Ruhe ist:
    -- echte _04-Weltpos + (-0.093 in _04-lokalem Z) = Port-Welt; dann relativ zur Waffen-Transform
    -- speichern -> shotgun_chamber_world rechnet ihn spaeter mit der Live-Waffen-Transform zurueck.
    local zoff = is_shotgun(wep.wid) and SHOTGUN_CHAMBER_Z[wep.wid]
    if zoff and wep.tf then
        local jw = sc(wep.mag_joint, "get_Position")
        local jr = sc(wep.mag_joint, "get_Rotation")
        local gp = sc(wep.tf, "get_Position")
        local gr = sc(wep.tf, "get_Rotation")
        if jw and jr and gp and gr then
            local cw  = safe(function() return jw + jr * Vector3f.new(0, 0, zoff) end)            -- Port-Welt
            local rel = cw and safe(function() return gr:conjugate() * (cw - gp) end)             -- waffen-lokal
            if rel then wep.chamber_off = { x = rel.x, y = rel.y, z = rel.z } end
        end
    end
end

-- Slide-in: Mag von der aktuellen (Hand-)Lokalpose in die Chamber-Ruhepose
local function start_mag_insert()
    if not (wep.mag_joint and wep.rest_lp) then return false end
    local lp = sc(wep.mag_joint, "get_LocalPosition"); if not lp then return false end
    local lr = sc(wep.mag_joint, "get_LocalRotation")
    mag_insert.joint = wep.mag_joint
    mag_insert.slp = { x = lp.x, y = lp.y, z = lp.z }
    mag_insert.slr = lr and { w = lr.w, x = lr.x, y = lr.y, z = lr.z } or nil
    mag_insert.rlp = wep.rest_lp
    mag_insert.rlr = wep.rest_lr
    -- [SHOTGUN] Insert-ZIEL = Chamber-Port (rest + -0.093 Z), nicht die vordere _04-Ruhe -> die Shell
    -- gleitet IN den Ladeport statt nach vorne zu fliegen.
    local zoff = SHOTGUN_CHAMBER_Z[wep.wid]
    if zoff then mag_insert.rlp = { x = wep.rest_lp.x, y = wep.rest_lp.y, z = wep.rest_lp.z + zoff } end
    -- [SHELL-KEYFRAMES 2026-07-24] Nutzt diese Waffe die Keyframe-Bahn (reload_adv, KEYFRAME_INSERT)?
    -- Dann faehrt update_mag_insert die geordnete Bahn ab und der lineare Slide + Overshoot unten gilt
    -- NICHT mehr -- die Shell klebt an der Waffe, Start = 1. Keyframe (Andockpunkt), Hand-Pos ignoriert.
    do
        local ms = rawget(_G, "__re4_reload_mag_slide")
        mag_insert.keyframe = (ms and type(ms.has_shell_keys) == "function" and ms.has_shell_keys(wep.wid)) == true
    end
    mag_insert.t0  = os.clock()
    mag_insert.dur = CFG.insert_dur
    -- [MASTER-TEMPO 2026-07-23] Insert-Dauer mit demselben Faktor strecken wie die Push-Geste
    -- (reload_speed in reload_adv) -> das gesamte Reinladen wird gleichmaessig langsamer/schneller.
    do
        local ms = rawget(_G, "__re4_reload_mag_slide")
        if mag_insert.keyframe and ms and tonumber(ms.shell_dur) then
            -- [INSERT = EJECT RUECKWAERTS 2026-07-25] Waffen, die den Einschub als rueckwaerts
            -- gefahrene Auswurf-Bahn machen, haben eine EIGENE Dauer -- sonst zoegen sie shell_dur, den
            -- gemeinsamen Wert der Schrotflinten-Shells, und ein Tunen dort wuerde sie mitverstellen.
            mag_insert.dur = ((type(ms.kf_insert_dur) == "function") and tonumber(ms.kf_insert_dur(wep.wid)))
                or tonumber(ms.shell_dur)   -- [SHELL-KEYFRAMES] eigene Bahn-Dauer, unabhaengig von insert_dur/reload_speed
        elseif ms and type(ms.time_mult) == "function" then
            mag_insert.dur = CFG.insert_dur * ms.time_mult()
        end
    end
    mag_insert.active = true
    mag_insert.snd_played = false   -- [SND] Einrast-Sound einmal pro Insert
    -- [MANUAL_INSERT 2026-08-15] Handschub scharf machen: Nullpunkt ist der Handabstand GENAU JETZT,
    -- also im Moment des Andockens. Alles weitere misst sich gegen diesen einen Wert.
    -- Liefert die Messung nichts (Hand/Joint nicht da), bleibt es still bei der Zeitbahn -- nie haengen.
    mag_insert.manual = false
    mag_insert.prog = 0.0
    -- [NOTBREMSE 2026-08-17] Startwerte fuer den Handschub-Watchdog (Begruendung in update_mag_insert).
    -- Bei JEDEM Andocken frisch -- auch wenn der Handschub gar nicht scharf wird (dann bleiben sie ungenutzt).
    mag_insert.wd_t0  = os.clock()
    mag_insert.wd_max = 0.0
    do
        -- [WELTWEG WAR DER FEHLER 2026-08-18 -- gemessen] Der Watchdog merkte sich hier die
        -- WELTPOSITION der linken Hand und verglich sie spaeter mit der aktuellen. Beides ist
        -- `__vr_lh_ctrl_raw`, also durch `controller_to_world` gelaufen -- beim Laufen wandert das
        -- mit dem Spieler. Im Log standen so 12 METER "Handweg" waehrend eines Einschubs, die
        -- 6-cm-Schwelle war also sofort ueberschritten: die Notbremse schaltete `manual` ab und
        -- startete die Zeitbahn -> das Magazin fuhr von allein hinein, waehrend der Controller am
        -- Knie hing, und die Kopplung rechnete nicht mehr mit (prog eingefroren).
        -- Jetzt wird DIESELBE Groesse benutzt wie in der Kopplung: linke Hand GEGEN rechte Hand.
        -- Laeuft man, wandern beide gemeinsam und es faellt heraus -- der Watchdog zuendet nur noch,
        -- wenn wirklich geschoben wurde.
        local _l0 = rawget(_G, "__vr_lh_ctrl_raw")
        local _r0 = rawget(_G, "__vr_rh_ctrl_raw")
        if _l0 and _r0 then
            mag_insert.wd_lp0 = { x = _l0.x - _r0.x, y = _l0.y - _r0.y, z = _l0.z - _r0.z }
        else
            mag_insert.wd_lp0 = nil
        end
    end
    do
        local ms = rawget(_G, "__re4_reload_mag_slide")
        -- Waffe mit Druecken-Geste? -> Handschub. Ausnahme-Eintrag `false` schlaegt das ab.
        local ok_wid = (ms and type(ms.PUSH_WIDS) == "table" and ms.PUSH_WIDS[wep.wid] == true)
                       and (_G.__re4_insert_manual_wid[wep.wid] ~= false)
        if CFG.insert_manual ~= false and ok_wid then
            -- Nullpunkt = der Handabstand GENAU JETZT, also im Moment des Andockens.
            mag_insert.d0 = _G.__re4_mag_push_dist()
            mag_insert.manual = (mag_insert.d0 ~= nil)
            mag_insert.p0 = nil   -- [1:1] Nullpunkt der Achsen-Kopplung neu setzen
            -- [WEGWERF-DIAG 2026-08-15] nach der Messung ersatzlos loeschen
            _G.__re4_dg_src, _G.__re4_dg_d0, _G.__re4_dg_start = "leon", mag_insert.d0, os.clock()
            _G.__re4_dg_travel = tonumber(CFG.insert_travel)
            _G.__re4_dg_dur    = tonumber(mag_insert.dur)
            _G.__re4_dg_manual = mag_insert.manual
        end
    end
    -- [PUSH_POSE 2026-07-21] Das Mag verlaesst jetzt die linke Hand -> kurz in die universelle
    -- Druecken-Pose lerpen und danach zurueck (liegt in reload_adv, waffenunabhaengig). Rein optisch.
    -- [MANUAL_INSERT] Im Handschub dieselbe Geste, aber als HALTEN: die Hand geht in die Druecken-Pose
    -- und dockt per IK ans Magazin -- und weil das Magazin auf unserem Weg faehrt, bleibt sie unten am
    -- Mag kleben, solange geschoben wird. Zurueckgefahren wird die Pose erst beim Einrasten oder beim
    -- Rueckzieher (end_push_hold), nicht nach einer festen Zeit.
    do
        local ms = rawget(_G, "__re4_reload_mag_slide")
        if mag_insert.manual and ms and type(ms.begin_push_hold) == "function" then
            pcall(ms.begin_push_hold, wep.wid)
        elseif ms and type(ms.start_push) == "function" then
            pcall(ms.start_push, wep.wid)
        end
    end
    -- [INSERT-PUNCH] Ziel der Einschub-Phase liegt um insert_overshoot WEITER in Einschubrichtung
    -- (Richtung Start->Ruhelage, normiert). Danach federt es in insert_settle zurueck. Rein optisch.
    mag_insert.olp = nil
    mag_insert.settle = false
    local ov = tonumber(CFG.insert_overshoot) or 0.0
    -- [MANUAL_INSERT] Kein Overshoot beim Handschub: dort IST die Hand die Position -- ein Ziel hinter
    -- der Ruhelage wuerde bedeuten, dass man am Anschlag noch weiterschieben muss.
    if ov > 0.0 and not mag_insert.keyframe and not mag_insert.manual then   -- [SHELL-KEYFRAMES] Keyframe-Bahn hat keinen linearen Overshoot
        local a, b = mag_insert.slp, mag_insert.rlp
        local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
        local len = math.sqrt(dx*dx + dy*dy + dz*dz)
        if len > 1e-5 then
            mag_insert.olp = { x = b.x + dx/len*ov, y = b.y + dy/len*ov, z = b.z + dz/len*ov }
        end
    end
    rlog("mag-insert START")
    return true
end
-- [SS-FLASH 2026-08-01] SICHT-PASS. Gemessen (re4_zzz_ss_shell_diag.log): die Engine-Reihenfolge
-- ist LockScene -> BeginRendering(pre) -> BeginRendering(post) -> [in VR beides 2x, beide Augen] ->
-- LateUpdateBehavior -> UpdateJointExpression. Alles, was erst in LateUpdateBehavior geschrieben wird,
-- ist eine Renderrunde zu spaet -- deshalb blitzt die Skull-Shaker-Shell einen Frame auf der Ruhelage
-- des _04 auf (Sprung zum 1. Keyframe: Y +1.3 cm, Z -5.3 cm), bevor sie die Bahn abfaehrt.
-- Behoben ueber einen ZUSAETZLICHEN Aufruf im BeginRendering-PRE -- aber NUR als reiner Sicht-Pass:
-- ist mag_insert.visual gesetzt, wird ausschliesslich die Position geschrieben. KEIN Sound, KEIN
-- Abschluss des Inserts. Das ist der Punkt: am Insert-Ende haengt die Ammo-Buchung
-- (__re4_safe_inv_reload -> ggf. pe:execReload), und die darf NIE aus einer anderen Engine-Phase
-- feuern als bisher -- genau daran haengt der Reload-Crash. Siehe Notiz.
local function update_mag_insert()
    -- [INSERT-PUNCH] Nachfedern aus dem Overshoot zurueck in die Ruhelage. Laeuft NACH dem eigentlichen
    -- Insert (der ist da schon abgeschlossen, inkl. Ammo/Rack) und schreibt NUR die Position.
    if mag_insert.settle and mag_insert.joint then
        local st = (os.clock() - mag_insert.settle_t0) / math.max(tonumber(CFG.insert_settle) or 0.07, 0.01)
        if st >= 1.0 then
            st = 1.0
            if not mag_insert.visual then mag_insert.settle = false end   -- [SS-FLASH] Sicht-Pass beendet nichts
        end
        local o, r = mag_insert.olp, mag_insert.rlp
        if o and r then
            local u2 = ease(st)
            pcall(function() mag_insert.joint:call("set_LocalPosition",
                Vector3f.new(o.x + (r.x - o.x) * u2, o.y + (r.y - o.y) * u2, o.z + (r.z - o.z) * u2)) end)
        end
    end
    if not mag_insert.active or not mag_insert.joint then return end
    local t = (os.clock() - mag_insert.t0) / math.max(mag_insert.dur, 0.01)
    -- [MANUAL_INSERT 2026-08-15] Handschub: t kommt aus dem zurueckgelegten Handweg statt aus der Uhr.
    -- 0 = Andockpunkt, 1 = eingerastet. Dazwischen kann man beliebig vor und zurueck -- die Bahn selbst
    -- (linearer Slide wie Keyframe-Bahn) wertet t jedes Mal frisch aus und merkt sich nichts.
    if mag_insert.manual then
        -- Fortschritt = wie weit sich die Haende seit dem Andocken genaehert haben.
        local d = _G.__re4_mag_push_dist()
        if d and mag_insert.d0 then
                        -- [1:1-KOPPLUNG 2026-08-15] Das Magazin klebt am CONTROLLER, statt einen
            -- Fortschritt aus einer Distanz-Differenz zu rechnen. Gemessen war der alte Weg
            -- (Hoehe des Controllers) nachweislich unbrauchbar: prog lief rueckwaerts,
            -- waehrend eingeschoben wurde, und brauchte fuer die letzten 10 %% eine ganze
            -- Sekunde -- weil die virtuelle Hand ab dem Andocken per IK am Magazin haengt und
            -- mit der Controller-Hoehe nichts mehr zu tun hat.
            -- Jetzt: die Controller-Position wird auf die ECHTE Einschubachse projiziert
            -- (Andockpunkt -> Ruhelage, mit der Waffe gedreht). Damit dreht die Messung mit
            -- der Waffe mit -> gekippt einschieben geht, und die Bewegung ist die der Hand.
            -- Der Nullpunkt `p0` faengt den Griff-Versatz ab (die Hand haelt das Mag ja mit
            -- Abstand), sodass 0 = Andockpunkt und 1 = eingerastet gilt.
            -- ZURUECK auf den alten Weg: `_G.__re4_mag_11 = false`.
            local _p11 = nil
            if rawget(_G, "__re4_mag_11") ~= false then
                local _ms = rawget(_G, "__re4_reload_mag_slide")
                local _lp = rawget(_G, "__vr_lh_ctrl_raw")
                local _b  = mag_insert.olp or mag_insert.rlp
                -- [WEGWERF-DIAG 2026-08-18] Im Log stand `axlen=-` und `p0=-`: die 1:1-Kopplung lief
                -- ueberhaupt nicht, es griff still der Hoehen-Fallback. Welche der Voraussetzungen
                -- fehlt, war von aussen nicht zu sehen -- deshalb hier EINMAL pro Frame als String.
                -- Nach der Messung ersatzlos loeschen.
                _G.__re4_dg_11 = string.format("ms=%s dock=%s tf=%s lp=%s slp=%s b=%s rh=%s",
                    _ms and "1" or "0",
                    (_ms and type(_ms.dock_world) == "function") and "1" or "0",
                    wep.tf and "1" or "0", _lp and "1" or "0",
                    mag_insert.slp and "1" or "0", _b and "1" or "0",
                    rawget(_G, "__vr_rh_ctrl_raw") and "1" or "0")
                if _ms and type(_ms.dock_world) == "function" and wep.tf and _lp
                   and mag_insert.slp and _b then
                    -- [KEIN WELTANKER 2026-08-15] Gemessen wird NICHT mehr gegen `dock_world`
                    -- (ein Punkt an der Waffe): beim LAUFEN wandert der mit, und die
                    -- Fortbewegung zaehlt als Einschub -> das Magazin flackerte.
                    -- Das ist derselbe Fehler wie damals beim W-870-Pump; der Merksatz dazu:
                    -- Zuggesten IMMER zwei Koerperteile gegeneinander messen, nie gegen etwas,
                    -- das Spiel oder Script bewegen. Also LINKE gegen RECHTE Hand -- laeuft man,
                    -- wandern beide gemeinsam und es faellt heraus.
                    -- Anders als beim Pump aber RICHTUNGSBEHAFTET: nicht der Abstand (der ist
                    -- beim Magazin falsch herum -- man schiebt an der anderen Hand VORBEI nach
                    -- oben), sondern die Komponente entlang der Einschubachse. Damit dreht die
                    -- Messung mit der Waffe mit und gekipptes Einschieben funktioniert weiter.
                    -- ZWINGEND die ROHEN Controller-Positionen: die Handjoints haengen im
                    -- Einschub per IK am Magazin -> Rueckkopplung.
                    local _rp = rawget(_G, "__vr_rh_ctrl_raw")
                    local _A  = _rp and Vector3f.new(_rp.x, _rp.y, _rp.z) or nil
                    local _wr = sc(wep.tf, "get_Rotation")
                    if _A and _wr then
                        local _a = mag_insert.slp
                        -- [ACHSE 2026-08-18] Versuch, die Achse beim Andocken einzufrieren, ist
                        -- wieder RAUS: er brachte nichts, weil in den Problemfaellen dieser ganze
                        -- Block gar nicht laeuft (die Notbremse schaltet `manual` ab, s. unten).
                        local _ax = _wr * Vector3f.new(_b.x - _a.x, _b.y - _a.y, _b.z - _a.z)
                        local _L2 = _ax.x * _ax.x + _ax.y * _ax.y + _ax.z * _ax.z
                        if _L2 > 1e-8 then
                            _p11 = ((_lp.x - _A.x) * _ax.x + (_lp.y - _A.y) * _ax.y
                                  + (_lp.z - _A.z) * _ax.z) / _L2
                            if mag_insert.p0 == nil then
                                mag_insert.p0 = _p11
                                -- [WEGWERF-DIAG 2026-08-15] Achsen-Kenndaten EINMAL beim
                                -- Andocken veroeffentlichen -- nach der Messung loeschen.
                                _G.__re4_dg_axlen = math.sqrt(_L2)
                                _G.__re4_dg_alp   = string.format("%.4f/%.4f/%.4f", _a.x, _a.y, _a.z)
                                _G.__re4_dg_blp   = string.format("%.4f/%.4f/%.4f", _b.x, _b.y, _b.z)
                                _G.__re4_dg_p0    = _p11
                            end
                            _p11 = _p11 - mag_insert.p0
                        end
                    end
                end
            end
            if _p11 then
                mag_insert.prog = _p11
            else
            mag_insert.prog = (mag_insert.d0 - d) / math.max(tonumber(CFG.insert_travel) or 0.09, 0.01)
            end
            -- [WEGWERF-DIAG 2026-08-15]
            _G.__re4_dg_d, _G.__re4_dg_prog = d, mag_insert.prog
        end
        -- [DIAG 2026-08-15] Nur lesen/veroeffentlichen, keine Logik: drei Skalare fuer das
        -- Wegwerf-Messscript (kein Table -> kein Muell pro Frame). Kann ersatzlos raus.
        t = mag_insert.prog or 0.0
        -- Hinter den Andockpunkt zurueckgezogen -> das Mag liegt wieder in der linken Hand, genau wie
        -- vor dem Andocken. KEIN Abbruch der Reload-Logik noetig: gebucht wird erst am Anschlag (t>=1).
        -- [SS-FLASH] Nur im echten Pass -- der Sicht-Pass darf ausschliesslich Position schreiben.
        if not mag_insert.visual
           and t <= -((tonumber(CFG.insert_back_out) or 0.02) / math.max(tonumber(CFG.insert_travel) or 0.09, 0.01)) then
            mag_insert.active = false
            mag_insert.settle = false
            mag_insert.manual = false
            -- Druecken-Pose sauber ausfahren lassen (Zurueck-Lerp + Links-Ausfade wie am normalen
            -- Push-Ende) -- sonst bliebe die Hand am Magazin-Dock haengen, obwohl das Mag wieder
            -- der Hand gehoert.
            do
                local ms = rawget(_G, "__re4_reload_mag_slide")
                if ms and type(ms.end_push_hold) == "function" then pcall(ms.end_push_hold) end
            end
            mag_hand.joint  = mag_insert.joint
            mag_hand.wid    = wep.wid
            -- Sentinel fuer check_mag_insert_proximity: erst wieder andocken, wenn man ein Stueck
            -- VORgeschoben hat. Ohne das saesse die Hand noch in der Andock-Distanz und es klebte im
            -- naechsten Frame sofort wieder an -- der Rueckzieher waere nie zu sehen.
            mag_hand.redock_d = true
            -- [MANUAL_INSERT] In der Hand bleibt es NUR bei gehaltenem Grip -- sonst haelt es niemand
            -- und es faellt sofort zu Boden, wie ein losgelassenes Mag. Der Grip kann waehrend des
            -- Schiebens losgelassen worden sein; das Loslassen selbst lief damals ins Leere, weil
            -- mag_hand.active im Insert false ist.
            mag_hand.active = (mag_hand.grip_held == true)
            -- Das Fallen selbst erst im Frame-Tick: drop_mag_simple steht weiter unten in der Datei
            -- und ist hier oben noch nicht sichtbar (Lua-Local-Reihenfolge, bekannte Falle).
            mag_hand.want_drop = (not mag_hand.active) or nil
            rlog(mag_hand.active and "mag-insert ZURUECK in die Hand (Handschub)"
                or "mag-insert ZURUECK, aber kein Grip -> faellt")
            return
        end
        -- [NOTBREMSE 2026-08-17] "Ich schiebe, und das Magazin geht nicht rein": das Magazin klebt am
        -- Andockpunkt, die Hand haengt per IK daran, prog bleibt bei ~0. Beobachtet aus dem Test (Bild),
        -- sporadisch, NICHT an Bewegung/Laufen gekoppelt (auch im Stehen, spaeter mit derselben Waffe
        -- problemlos). Alle drei Groessen der 1:1-Kopplung sind pro Versuch anders: die Achsen-RICHTUNG
        -- und -LAENGE haengen an `slp` (Mag-Lage im Moment des Andockens) und an `rest_lp` (LIVE gemessene
        -- Ruhelage, s. capture_mag_rest), der Nullpunkt `p0` am ersten Frame mit rechter Controller-Pos.
        -- Zeigt die Achse in eine Richtung, in die man physisch nicht schiebt, waechst die Projektion nie
        -- -- und es gibt bisher KEINEN Ausweg: die Zeitbahn ist im Handschub komplett verlassen.
        --
        -- Diese Notbremse aendert an der Kopplung NICHTS. Sie greift nur in dem einen Fall, der sonst
        -- haengt: der Controller hat sich seit dem Andocken nachweislich bewegt (Maximalabstand > 6 cm),
        -- aber nach 1.5 s ist der Schub unter 5 Prozent. Dann faellt DIESER EINE Insert auf die Zeitbahn
        -- zurueck -- der Weg, der vor dem 15.08. fuer alle Waffen lief.
        -- Haelt man die Hand nur still, zuendet sie NICHT (moved bleibt klein) -> kein Automatik-Einschub.
        -- `end_push_hold` muss hier selbst gerufen werden: der Abschluss unten faehrt die Druecken-Pose
        -- nur im `mag_insert.manual`-Zweig zurueck, und den schalten wir gerade ab -> sonst klebte die
        -- Hand am Magazin, obwohl es von allein reinfaehrt.
        -- Diagnose: `_G.__re4_mag_wd_hits` (bleibt 0 = hat nie gegriffen).
        if not mag_insert.visual and mag_insert.wd_t0 and (os.clock() - mag_insert.wd_t0) > 1.5
           and (tonumber(mag_insert.prog) or 0) < 0.05 then
            -- Gegenstueck zum Andocken: ebenfalls linke GEGEN rechte Hand (s. wd_lp0).
            local _l0 = mag_insert.wd_lp0
            local _lr = rawget(_G, "__vr_lh_ctrl_raw")
            local _rr = rawget(_G, "__vr_rh_ctrl_raw")
            local _ln = (_lr and _rr) and { x = _lr.x - _rr.x, y = _lr.y - _rr.y, z = _lr.z - _rr.z } or nil
            if _l0 and _ln then
                local _dx, _dy, _dz = _ln.x - _l0.x, _ln.y - _l0.y, _ln.z - _l0.z
                local _md = math.sqrt(_dx*_dx + _dy*_dy + _dz*_dz)
                if _md > (tonumber(mag_insert.wd_max) or 0) then mag_insert.wd_max = _md end
            end
            if (tonumber(mag_insert.wd_max) or 0) > 0.06 then
                mag_insert.manual = false
                mag_insert.t0     = os.clock()   -- Zeitbahn beginnt JETZT (stetig, das Mag steht am Andockpunkt)
                mag_insert.wd_t0  = nil
                local ms = rawget(_G, "__re4_reload_mag_slide")
                if ms and type(ms.end_push_hold) == "function" then pcall(ms.end_push_hold) end
                _G.__re4_mag_wd_hits = (tonumber(rawget(_G, "__re4_mag_wd_hits")) or 0) + 1
                rlog(string.format("mag-insert NOTBREMSE: Handschub ohne Fortschritt (prog=%.3f, Handweg=%.3f m) -> Zeitbahn",
                    tonumber(mag_insert.prog) or 0, tonumber(mag_insert.wd_max) or 0))
                t = 0.0
            end
        end
        if t < 0.0 then t = 0.0 end
    end
    if t > 1.0 then t = 1.0 end
    -- [SND] Einrast-Sound kurz VOR dem Anschlag, einmalig. Mit Punch sitzt er spaeter (0.90), damit
    -- Klack und Aufschlag zusammenfallen; ohne Punch bleibt es beim alten Timing (0.75).
    -- [SND-TIMING 2026-07-21] Schwelle jetzt aus CFG.insert_snd_at (Default 0.80 statt hart 0.90).
    -- [MANUAL_INSERT 2026-08-15] Im Handschub spielt hier NICHTS: jede Wegschwelle liegt vor dem Anschlag und
    -- laesst sich wieder zurueckziehen. Der Klack kommt unten im Abschluss, beim echten Einrasten.
    if not mag_insert.visual   -- [SS-FLASH] Sicht-Pass spielt keine Sounds
       and not mag_insert.manual
       and not mag_insert.snd_played
       and t >= ((CFG.insert_punch ~= false) and (tonumber(CFG.insert_snd_at) or 0.80) or 0.75) then
        mag_insert.snd_played = true
        play_weapon_sound(snd("mag_insert"))
    end
    -- [SHELL-KEYFRAMES 2026-07-24] Waffen mit Keyframe-Bahn: Shell-Joint entlang der geordneten
    -- Keyframes (Position + Rotation, relativ zur Waffe) setzen -- der lineare Slide unten gilt fuer sie
    -- NICHT mehr. Start = 1. Keyframe (Andockpunkt), Ende = letzter Keyframe (Kammer).
    if mag_insert.keyframe then
        local ms = rawget(_G, "__re4_reload_mag_slide")
        if ms and type(ms.apply_shell_keys) == "function" and wep.tf then
            ms.apply_shell_keys(wep.tf, mag_insert.joint, wep.wid or 0, t)
        end
    else
    -- [INSERT-PUNCH] Ease-IN (beschleunigt bis zum Anschlag) statt Smoothstep (laeuft weich aus).
    -- [MANUAL_INSERT] Im Handschub LINEAR: die Hand ist die Position. Jede Kurve wuerde bedeuten, dass
    -- das Mag anders laeuft als die Hand -- und beim Zurueckziehen faende man den Anschlag nicht wieder.
    local u = mag_insert.manual and t
        or ((CFG.insert_punch ~= false) and (t * t * t) or ease(t))
    local a, b = mag_insert.slp, (mag_insert.olp or mag_insert.rlp)
    -- [EINLEIT-PUNKT 2026-07-23] Startpunkt ist NICHT die Hand, sondern ein fester Punkt am
    -- Waffen-Skelett: Joint + Versatz, pro Waffe in re4_vr_reload_adv.lua gepflegt (Sentinel Nine =
    -- _03 mit Y -0.092 / Z -0.061). Dadurch ist der Weg immer derselbe -- unabhaengig davon, wie die
    -- Hand steht und wie schnell man dabei laeuft. Fehlt der Joint an einer Waffe, liefert dock_local
    -- nil und es bleibt beim bisherigen Verhalten.
    do
        local ms = rawget(_G, "__re4_reload_mag_slide")
        _G.__re4_reload_ui_wid = wep.wid   -- fuer die Einleit-Punkt-UI in reload_adv
        -- [PARENT-RAUM 2026-07-23] set_LocalPosition ist relativ zum PARENT des Mag-Joints,
        -- NICHT zur Waffen-Transform. Bei Pistolen (_14) ist der Parent ~ die Waffe, deshalb passte
        -- der im Waffenraum gerechnete Punkt. Die TMP (_04) haengt an einem anderen Parent -> der
        -- Punkt sass seitlich (X aus der Waffe). Also den WELT-Punkt in den Parent-Raum DES Joints
        -- bringen: aktuelle Welt-/Local-Lage des Joints liefert die Umrechnung ohne den Parent zu
        -- kennen -- localTarget = localPos + (localRot * worldRot^-1) * (W - worldPos).
        -- Standard: Punkt im WAFFENRAUM -- bewiesen rock solid fuer alle Pistolen inkl. Matilda.
        if ms and type(ms.dock_local) == "function" and wep.tf then
            local dl = ms.dock_local(wep.tf, wep.wid or 0)
            if dl then a = dl end
        end
        -- [NUR TMP/MP-AF 2026-07-23] Diese beiden haben den Mag-Joint _04 an einem ANDEREN
        -- Parent als die Pistolen (_14) -> der Waffenraum-Punkt sass seitlich (X aus der Waffe).
        -- NUR fuer sie den Welt-Punkt ueber die aktuelle Joint-Lage in den Parent-Raum bringen.
        -- Alle anderen Waffen bleiben unangetastet beim Waffenraum-Punkt oben.
        if PARENT_SPACE_DOCK[wep.wid] and ms and type(ms.dock_world) == "function" and wep.tf and mag_insert.joint then
            local W = ms.dock_world(wep.tf, wep.wid or 0)
            local jw = W and sc(mag_insert.joint, "get_Position")
            local jr = W and sc(mag_insert.joint, "get_Rotation")
            local jlp = W and sc(mag_insert.joint, "get_LocalPosition")
            local jlr = W and sc(mag_insert.joint, "get_LocalRotation")
            if W and jw and jr and jlp and jlr then
                local dl = safe(function()
                    local d = jlr * (jr:conjugate() * (W - jw))
                    return { x = jlp.x + d.x, y = jlp.y + d.y, z = jlp.z + d.z }
                end)
                if dl then a = dl end
            end
        end
    end
    pcall(function() mag_insert.joint:call("set_LocalPosition",
        Vector3f.new(a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u, a.z + (b.z - a.z) * u)) end)
    if mag_insert.slr and mag_insert.rlr then
        local s, r = mag_insert.slr, mag_insert.rlr
        local rw, rx, ry, rz = r.w, r.x, r.y, r.z
        if (s.w*rw + s.x*rx + s.y*ry + s.z*rz) < 0 then rw, rx, ry, rz = -rw, -rx, -ry, -rz end
        local w, x, y, z = s.w+(rw-s.w)*u, s.x+(rx-s.x)*u, s.y+(ry-s.y)*u, s.z+(rz-s.z)*u
        local len = math.sqrt(w*w + x*x + y*y + z*z)
        if len > 1e-6 then pcall(function() mag_insert.joint:call("set_LocalRotation", Quaternion.new(w/len, x/len, y/len, z/len)) end) end
    end
    end   -- [SHELL-KEYFRAMES] Ende else-Zweig (linearer Slide)
    -- [SS-FLASH] Ab hier haengt die RELOAD-LOGIK (Ammo-Buchung, Rack-Entscheidung, Haptik, mag_out).
    -- Der Sicht-Pass steigt hier IMMER aus -- er hat oben nur die Position geschrieben. Abgeschlossen
    -- wird der Insert weiterhin ausschliesslich in den bisherigen Paessen, in unveraenderter Phase.
    if mag_insert.visual then return end
    -- [SELBST-EINRASTEN] Im Handschub genuegt `insert_snap_at` des Weges; die Bahn oben hat
    -- das Magazin dann fast am Ziel, den Rest macht der Abschluss. Ausserhalb des Handschubs
    -- bleibt es bei 1.0, damit die Zeitbahn unveraendert laeuft.
    local _snap = 1.0
    if mag_insert.manual then
        _snap = tonumber(CFG.insert_snap_at) or 1.0
        if _snap < 0.5 then _snap = 0.5 elseif _snap > 1.0 then _snap = 1.0 end
    end
    if t >= _snap then
        mag_insert.active = false
        -- [MANUAL_INSERT] Eingerastet -> das Halten der Druecken-Pose aufloesen, ab hier laeuft die
        -- normale Zurueck-Phase samt Links-Ausfade. Steht ganz vorn, damit es auch dann greift, wenn
        -- unten irgendein Zweig frueh aussteigt.
        -- [MANUAL_INSERT] Der Einrast-Klack gehoert an DIESEN Moment: hier ist das Magazin
        -- tatsaechlich eingerastet (t >= 1). Eine Wegschwelle davor kann immer noch zurueckgezogen
        -- werden, also klang sie zwangslaeufig vor dem Einrasten.
        if mag_insert.manual and not mag_insert.snd_played then
            mag_insert.snd_played = true
            play_weapon_sound(snd("mag_insert"))
        end
        if mag_insert.manual then
            mag_insert.manual = false
            local ms = rawget(_G, "__re4_reload_mag_slide")
            if ms and type(ms.end_push_hold) == "function" then pcall(ms.end_push_hold) end
        end
        -- [INSERT-PUNCH] Anschlag erreicht: Nachfedern starten + kurzer, harter Haptik-Puls auf der
        -- rechten Hand (die haelt die Waffe). Beides rein sensorisch, keine Reload-Logik.
        if mag_insert.olp then
            mag_insert.settle = true
            mag_insert.settle_t0 = os.clock()
        end
        local hamp = tonumber(CFG.insert_haptic) or 0.0
        if hamp > 0.0 then
            pcall(function()
                local rj = vrmod and vrmod:get_right_joystick()
                if rj then vrmod:trigger_haptic_vibration(0.0, 0.06, 90.0, hamp, rj) end
            end)
        end
        rack._ammo_input_t = os.clock()   -- [RACK-LOCK] Ammo gerade eingelegt -> Shaft/Slide-Grab 2s sperren
        -- [MAG_OUT] PHYSISCH ein frisches Mag in der Kammer -> Anti-Doppeldrop-Flag loesen.
        -- An den INSERT gekoppelt, NICHT an loaded>0 (Ammo kann 0 bleiben: leeres Mag, keine
        -- Reserve, addAmmoCount-Problem) -> sonst bleibt mag_out haengen und B ist tot.
        mag_out = false
        -- Rack NUR noetig wenn die Waffe beim Drop LEER war (komplett auf 0 geschossen).
        -- Taktischer Reload (noch Patronen drin) -> KEIN Rack, Slide direkt vor (gechambert).
        -- [LEERE KAMMER 2026-07-23] `empty_when_dropped` wird beim Waffenwechsel mit geloescht
        -- (Regel "nach dem Wechsel immer schussbereit"). Wer leergeschossen hat, das Mag auswirft,
        -- wegwechselt und spaeter mit gefundener Munition zurueckkommt, bekam deshalb KEIN Rack --
        -- obwohl die Kammer leer ist. Der Ladestand unmittelbar vor dem Einsetzen (`_ld`) sagt das
        -- unabhaengig vom Wechsel. Bewusst NUR fuer Waffen mit echtem Slide-Rack: Shotguns laufen im
        -- Zweig darunter (Pump/Drehschalter/Klappe), Bolt-Action, Bogen und Armbrust haben hier keinen
        -- Eintrag. Ohne diese Einschraenkung koennte rack.needs eine Waffe dauerhaft feuersperren.
        -- Ladestand UNMITTELBAR vor dem Einsetzen -- selbe Quelle wie der EMPTY_RELOAD_JOINT-Block
        -- weiter unten (pe:getCurrentGunAmmo, kein Cache; Fallback Live-Item). Muss HIER schon
        -- feststehen, sonst ist die Variable an dieser Stelle nil und die Bedingung wirkungslos --
        -- genau das war der Fehler beim ersten Anlauf (Blacktail verlangte kein Rack).
        local _pe0 = get_pe()
        local _loaded0 = _pe0 and tonumber(safe(function() return _pe0:call("getCurrentGunAmmo") end))
        if _loaded0 == nil then
            local _wi0 = get_live_weapon_item()
            _loaded0 = _wi0 and tonumber(safe(function() return _wi0:call("get_CurrentAmmoCount") end)) or nil
        end
        -- [ACCESSOR-FOLGE 2026-08-12] `_empty_chamber` bleibt fuer den Fall, fuer den es gebaut wurde
        -- (Waffenwechsel: `empty_when_dropped` ist geloescht, die Kammer aber echt leer). Es zaehlt aber
        -- NICHT mehr, wenn die 0 von unserem eigenen Mag-Drop-Leeren stammt -- das wirkt seit dem
        -- Accessor-Umbau wirklich und liess sonst jede Magazinwaffe nach JEDEM Reload racken.
        local _empty_chamber = (_loaded0 == 0) and (not is_shotgun(wep.wid))
                               and (rack._zeroed_by_us ~= true)
        if rack.empty_when_dropped or _empty_chamber then
            rack.needs = true   -- sticky, nur durch Rack-Geste/Wechsel/Reset geclear't
        else
            rack.needs = false
            -- [SLIDE_STUCK_BACK FIX 2026-07-03] Taktischer Reload nach einer VORHER leeren Kammer
            -- (2. Mag-Zyklus: leer geschossen -> Drop -> Insert): die Engine hatte den Slide bei 0
            -- Ammo zurueckgelockt (~0.0574). Ein EINMALIGER rest_z-Snap reicht NICHT -> die Engine
            -- spielt nach manuellem Reload keine Schliess-Anim, und apply_slide_park returnt danach
            -- early (nichts aktiv) -> der Slide blieb auf 0.0574 haengen (rein optisch; ld=20, Waffe
            -- schiesst). FIX wie nach einem Rack: _chambered_hold setzen -> apply_slide_park HAELT den
            -- Slide jeden Frame auf rest_z bis zum 1. Schuss (dann uebernimmt die Engine-Anim).
            -- _prev_gun_ammo nil = frischer Schuss-Vergleich (sonst loest der Halt sofort). Fuer
            -- ENGINE_CLOSES_SLIDE-Waffen NICHT (deren Engine faehrt den Slide selbst vor).
            if not ENGINE_CLOSES_SLIDE[wep.wid] then
                rack._chambered_hold = true
                rack._prev_gun_ammo  = nil
            end
            -- Sofort-Snap (Erst-Effekt; der Halt oben zieht danach jeden Frame nach).
            if wep.slide_joint and not ENGINE_CLOSES_SLIDE[wep.wid] then
                local cur = sc(wep.slide_joint, "get_LocalPosition")
                if cur then
                    local sp2 = slide_pose(wep.wid or 0)
                    pcall(function() wep.slide_joint:call("set_LocalPosition", Vector3f.new(cur.x, cur.y, sp2.rest_z)) end)
                end
            end
        end
        -- [EMPTY-RELOAD SLIDE] Riot Gun: war die Waffe VOR diesem Insert komplett leer (0 geladen)?
        -- -> dieser Reload chambert per _08-Lade-Slide (Slide-Rack, ziehen). VOR dem Ammo-Add lesen
        -- (= Vor-Reload-Stand). ZUERST bestimmt -- das Chamber-Fenster unten braucht empty_reload.
        if EMPTY_RELOAD_JOINT[wep.wid] then
            -- [EMPTY-DETECT FIX 2026-07-17] Loaded-Stand FRISCH per pe:getCurrentGunAmmo (kein Cache, laut Code
            -- zuverlaessig, gleiche Quelle wie force_eject). Frueher ueber get_live_weapon_item (Cache) ->
            -- liest im Insert-Frame oft nil -> _ld==0 verfehlt -> empty_reload NIE gesetzt -> Rack faellt nach
            -- Leerschuss weg. Fallback auf das Live-Item nur, wenn der Engine-Read fehlt. False-Positive-Guard
            -- bleibt: NUR bei ECHTEM 0 (nil -> NICHT setzen).
            local _pe = get_pe()
            local _ld = _pe and tonumber(safe(function() return _pe:call("getCurrentGunAmmo") end))
            if _ld == nil then
                local _wi = get_live_weapon_item()
                _ld = _wi and tonumber(safe(function() return _wi:call("get_CurrentAmmoCount") end)) or nil
            end
            -- STICKY: einmal leer-nachgeladen -> Slide-Modus bleibt bis zum Rack (clear_rack) / Wechsel.
            if _ld == 0 then rack.empty_reload = true end
        end
        -- [SHOTGUN] Shell eingelegt -> Chamber-Fenster (rack.needs) oeffnen.
        -- [RIOT GUN 2026-07-17] NUR die Riot Gun (NO_RELOAD_CYCLE) braucht bei taktischem Reload KEINEN
        -- Pump -- frei weiterballern; nur der 0-Reload chambert (Slide-Rack _08, empty_reload). Der alte
        -- `if is_shotgun then rack.needs=true` erzwang bei JEDEM Shell-Insert ein Pump-Fenster (+ IK-Freeze via
        -- __vr_slide_rack_active) -- Ueberbleibsel aus der Pump-Gun-Zeit. ALLE anderen Shotguns unveraendert:
        -- W-870 = Pump nach jedem Shell; Striker = Drehschalter-Cycle; Skull Shaker = Cock.
        if is_shotgun(wep.wid) then
            if not NO_RELOAD_CYCLE[wep.wid] or rack.empty_reload then rack.needs = true end
        end
        rack.empty_when_dropped = false
        rack._zeroed_by_us      = false   -- [ACCESSOR-FOLGE] Merker verbraucht, Zyklus zu Ende
        -- echter Ammo-Reload (wie das Game): Mag fuellen + Reserve abziehen
        if CFG.reload_ammo then
            local wi  = get_live_weapon_item()
            local pe  = get_pe()
            local inv = pe and sc(pe, "get_InventoryController")
            -- ECHTE Reserve = Inventar-Anzahl des Ammo-Items.
            local reserve, ammo_id = 0, wi and safe(function() return wi:call("get_CurrentAmmo") end)
            if inv and ammo_id then
                reserve = tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or 0
            end
            if is_shotgun(wep.wid) then
                -- [ROTARY_DEFER 2026-07-18] Striker (ROTARY_CYCLE): Ammo NICHT beim Insert zaehlen ->
                -- erst am Drehschalter (update_rotary_cycle ruft rotary.do_load am Dreh-Peak). Hier nur
                -- pending markieren. Alle anderen Shotguns (W-870/Riot/Skull): sofort laden wie bisher --
                -- rotary.do_load ist der alte Insert-Shotgun-Zweig 1:1, nur ausgelagert als rotary-Tabellen-
                -- feld (KEIN neuer Main-Chunk-Local wegen 200-Limit). Ratio = SHOTGUN_RATIO_WID/CFG unveraendert.
                if ROTARY_CYCLE[wep.wid] then rotary.pending = true
                else rotary.do_load() end
            else
                -- [RUNTIME-FIX 0/0] FRUEHER: write_dword(0x44) auf `wi`. Waehrend des Reloads ist
                -- `wi` aber oft NICHT das Laufzeit-Item (__re4_live_wi stale -> Spiegel/Inv-Row) ->
                -- der Write greift nicht, ABER die Reserve wird abgezogen = 0/0 (per re4_reload_diag.log
                -- RELOAD_ZERO @wp4001 bestaetigt). JETZT: Engine-Reload-Pfad wie der Shotgun-Zweig
                -- (inv:reload ueber EquipType greift auf das ECHTE equippte Gun-Item, item-unabhaengig).
                -- Ziel = min(cap, retained+reserve). ZWEI Quellen getrennt behandeln:
                -- (1) Reserve-Anteil `used` via Engine-Reload (greift aufs echte Gun-Item, zieht Reserve).
                -- (2) Retained-Anteil (Rounds aus dem gedroppten Mag, schon bezahlt) -> frei auf target
                -- auffuellen OHNE Reserve-Abzug. (Frueherer Fix gatete ALLES auf used>0 -> bei reserve=0
                -- + retained>0 wurde nichts geladen = 0; per re4_reload_diag.log @wp6000 bestaetigt.)
                local cap    = wi and (sc(wi, "get_CurrentAmmoMax") or 0) or 0
                local target = math.min(cap, (mag_retained or 0) + reserve)
                local used   = math.max(0, target - (mag_retained or 0))   -- Reserve-Anteil
                local pe_h = get_pe()
                local function gun_ammo() return pe_h and tonumber(safe(function() return pe_h:call("getCurrentGunAmmo") end)) or nil end
                local function read_rsv() return (inv and ammo_id) and (tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or reserve) or reserve end
                local r_b4 = reserve
                local b4   = gun_ammo() or 0
                local et   = get_equip_type_main()
                -- (1) Reserve-Anteil laden. WICHTIG: nur wenn wirklich eine Waffe live equippt ist
                -- (EquipWeaponID >= 0). Bei wid=-1 (mitten im Waffen-/Mag-Wechsel) ist das Main-Gun-Item
                -- null -> der native reload dereferenziert null -> c0000005 (pcall faengt die AV NICHT).
                -- [CRASH-HARDEN 2026-07-14] Der >=0-Guard reichte nicht: beim Um-Equippen mitten im Reload
                -- (auch bei manuellem Nachladen) zeigt get_equip_wid schon die NEUE Waffe (>=0=ok), aber das
                -- Gun-Item ist im Uebergangsframe noch null -> Crash. Zusaetzlich verlangen, dass die live
                -- equippte Waffe == der Reload-Waffe (wep.wid) ist. Stimmt sie nicht -> Invoke ueberspringen.
                if et and inv and used > 0 and (get_equip_wid() or -1) >= 0 and get_equip_wid() == wep.wid then
                    _G.__re4_load_and_book(inv, et, used, false)
                end
                -- [log entfernt]
                local af  = gun_ammo() or b4
                local got = math.max(0, af - b4)
                if got > 0 and inv and ammo_id and read_rsv() >= r_b4 then   -- Reserve nur ziehen wenn Engine es nicht tat
                    _G.__re4_safe_reduce(inv, ammo_id, got)
                end
                -- (2) Retained-Anteil: auf target auffuellen (frei, KEIN Reserve-Abzug)
                if (gun_ammo() or af) < target then
                    pcall(function() wi:write_dword(0x44, target) end)
                    local now = gun_ammo() or (b4 + got)
                    if now < target and wi then pcall(function() wi:call("addAmmoCount", target - now, false) end) end
                end
                mag_retained = 0
            end
        else
            rlog("mag-insert FERTIG")
        end
    end
end

-- Chamber-Weltpunkt = Waffen-Transform (zuverlaessig) * gecachter Chamber-Offset (waffen-lokal).
-- Der Offset wird in capture_mag_rest aus der ECHTEN _04-Weltposition im Ruhezustand + dem
-- -0.093-Z-Port (in _04-lokalem Z) abgeleitet. So bleibt der Port fix an der Waffe, auch waehrend
-- _04 beim Reload der Hand folgt. (Parent-Joint-Ansatz war kaputt -> d war 0.3-0.8m daneben.)
local function shotgun_chamber_world()
    if not (wep.tf and wep.chamber_off) then return nil end
    local gp = sc(wep.tf, "get_Position"); local gr = sc(wep.tf, "get_Rotation")
    if not (gp and gr) then return nil end
    local co  = wep.chamber_off
    local off = safe(function() return gr * Vector3f.new(co.x, co.y, co.z) end); if not off then return nil end
    return Vector3f.new(gp.x + off.x, gp.y + off.y, gp.z + off.z)
end

-- [DOCK-PORT] Andock-Spot = LIVE-Weltpos eines FESTEN Gun-Joints + Offset in dessen lokalem Z.
-- Der Joint bewegt sich (anders als der Mag-Joint) NICHT mit der Hand -> Live-Transform direkt nutzbar.
local function dock_port_world()
    local cfg = wep.wid and DOCK_PORT[wep.wid]; if not cfg then return nil end
    if not wep.tf then return nil end
    local j = sc(wep.tf, "getJointByName", cfg.joint); if not j then return nil end
    local jp = sc(j, "get_Position"); local jr = sc(j, "get_Rotation")
    if not (jp and jr) then return nil end
    local off = safe(function() return jr * Vector3f.new(cfg.x or 0, cfg.y or 0, cfg.z or 0) end); if not off then return nil end
    return Vector3f.new(jp.x + off.x, jp.y + off.y, jp.z + off.z)
end
-- [LEVER_PORT] Greif-Punkt des Break-Hebels (wie dock_port_world, eigene Tabelle).
local function lever_port_world()
    local cfg = wep.wid and LEVER_PORT[wep.wid]; if not cfg or not wep.tf then return nil end
    local j = sc(wep.tf, "getJointByName", cfg.joint); if not j then return nil end
    local jp = sc(j, "get_Position"); local jr = sc(j, "get_Rotation")
    if not (jp and jr) then return nil end
    local off = safe(function() return jr * Vector3f.new(0, 0, cfg.z) end); if not off then return nil end
    return Vector3f.new(jp.x + off.x, jp.y + off.y, jp.z + off.z)
end

-- Proximity: Mag in Hand nah genug an die Waffe -> automatisch in die Kammer sliden
local function check_mag_insert_proximity()
    if not mag_hand.active then return end
    local lh = get_left_hand(); if not lh then return end
    local hp = sc(lh, "get_Position"); if not hp then return end
    -- Bezugspunkt: exakter DOCK-PORT (festes Joint + Z-Offset) wenn fuer die Waffe definiert,
    -- sonst rechte Hand (Griff) / Waffen-Root.
    -- [EINLEIT-PUNKT 2026-07-23] Zusaetzlich der in re4_vr_reload_adv.lua gepflegte Punkt
    -- (Joint + Versatz pro Waffe). Damit misst die Einlege-Distanz gegen den ECHTEN Ladepunkt statt
    -- gegen Waffenwurzel oder rechte Hand -- auch bei Waffen, die gar nichts "hineingleiten" lassen.
    -- Reihenfolge: alter DOCK_PORT (falls fuer die Waffe gesetzt) -> Adv-Punkt -> bisheriger Ersatz.
    local _advp = nil
    do
        local ms = rawget(_G, "__re4_reload_mag_slide")
        if ms and type(ms.dock_world) == "function" and wep.tf then
            _advp = ms.dock_world(wep.tf, wep.wid or 0)
        end
    end
    local gp = dock_port_world() or _advp or rawget(_G, "__vr_rh_world") or (wep.tf and sc(wep.tf, "get_Position"))
    if not gp then return end
    local dx, dy, dz = hp.x - gp.x, hp.y - gp.y, hp.z - gp.z
    local d = math.sqrt(dx*dx + dy*dy + dz*dz)
    mag_hand.dist = d   -- fuer UI-Anzeige
    local cat = wep.wid and category_of(wep.wid)
    -- [INSERT-DIST PRO WAFFE] Per-Waffe-Override vor dem Gattungs-Wert.
    local idist = (wep.wid and INSERT_DIST_WID[wep.wid]) or (cat and INSERT_DIST[cat]) or INSERT_DIST.pistols
    -- [MANUAL_INSERT 2026-08-15] Nach einem Rueckzieher (Mag wieder in der Hand) steht die Hand noch
    -- mitten in der Andock-Distanz -- ohne Sperre klebte das Mag im naechsten Frame sofort wieder an.
    -- Deshalb: Abstand beim Rueckzieher merken und erst wieder andocken, wenn man ihn um insert_redock
    -- VORgeschoben hat (oder normal weit weggegangen ist). Damit laesst es sich beliebig rein/raus schieben.
    -- Der Sentinel `true` heisst "Abstand beim naechsten Durchlauf einmalig merken" -- update_mag_insert
    -- kann ihn selbst nicht ausrechnen, dock_port_world steht erst weiter unten in der Datei.
    if mag_hand.redock_d ~= nil then
        if mag_hand.redock_d == true then
            mag_hand.redock_d = d
            return
        elseif d > idist then
            mag_hand.redock_d = nil            -- normal weit weg -> alles wieder wie immer
        elseif d <= (mag_hand.redock_d - (tonumber(CFG.insert_redock) or 0.01)) then
            mag_hand.redock_d = nil            -- wieder Richtung Waffe geschoben -> andocken erlauben
        else
            return                             -- im Totband: NICHT andocken
        end
    end
    if d <= idist then
        mag_hand.active = false
        start_mag_insert()
    end
end

-- Mag-in-Hand aktivieren (Holster-Grab ODER UI-Tuning-Toggle)
local function mag_to_hand()
    if not wep.mag_joint then return false end
    stop_mag_drop()
    mag_insert.active = false   -- evtl. laufenden Insert abbrechen
    mag_insert.settle = false   -- [INSERT-PUNCH] Nachfedern mit abbrechen
    mag_tune.active = false     -- echter Grab beendet den Einstell-Modus
    mag_hand.active = true
    mag_hand.joint = wep.mag_joint
    mag_hand.wid = wep.wid
    mag_hand.redock_d = nil     -- [MANUAL_INSERT] frischer Grab -> keine Andock-Sperre aus einem alten Rueckzieher
    return true
end

-- Mag faellt von der aktuellen (Hand-)Position auf den Boden (Gravity, wie der B-Drop-Fall)
local function drop_mag_simple()
    if not wep.mag_joint then return false end
    local p = sc(wep.mag_joint, "get_Position"); if not p then return false end
    drop.joint, drop.use_module = wep.mag_joint, false
    drop.sx, drop.sy, drop.sz = p.x, p.y, p.z
    -- [ENTKOPPEL_ROT] Weltrotation einfrieren -> Mag dreht sich am Boden nicht mit der Waffe.
    do local r = sc(wep.mag_joint, "get_Rotation")
       if r then drop.srw, drop.srx, drop.sry, drop.srz = r.w, r.x, r.y, r.z else drop.srw = nil end end
    drop.t0 = os.clock()
    drop.active = true
    return true
end
-- vom Holster-Script gerufen: Mag in der Hand AN (Grip gedrueckt) / AUS (Grip los)
-- [RESERVE-FIX 2026-07-08] getItemCountSum(ItemID) liefert 0, OBWOHL das Ammo-Item mit Count im selben
-- Inventar liegt (per getItems live verifiziert; Ursache: ItemID:ToString gibt keinen String -> das
-- Enum-Marshalling in getItemCountSum scheitert). ZUVERLAESSIG: getItems durchgehen, per tostring(ItemId)
-- matchen und CurrentItemCount summieren (deckt gestackte Ammo). Global -> reload2/reload3 nutzen dasselbe.
-- Gilt fuer ALLE Waffen/Items. [[Notiz]]
-- [ID ALS ZAHL 2026-08-12] Im Log stand `sol.REManagedObject*: 0000002460779BE8=0`: die Eintraege aus
-- get_UsableAmmoList() sind eingepackte Enum-Werte, deren tostring die ADRESSE ist. Der Mengenvergleich
-- unten arbeitet aber mit tostring der Zeilen-ItemID (eine Zahl) -- so kann nie etwas passen, und jede
-- Sorte aus der Usable-Liste zaehlte faelschlich 0. Deshalb beide Seiten auf die nackte Zahl bringen.
_G.__re4_id_num = function(x)
    if x == nil then return nil end
    local n = tonumber(tostring(x)); if n then return n end
    local ok, v = pcall(function() return x:get_field("value__") end)
    return ok and tonumber(v) or nil
end
-- Wie __re4_item_count_sum, nur ueber die Zahl statt ueber den String -- fuer Sorten aus der Usable-Liste.
_G.__re4_item_count_sum_num = function(inv, num)
    if not (inv and num) then return 0 end
    local items = safe(function() return inv:call("getItems") end); if not items then return 0 end
    local n = tonumber(safe(function() return items:call("get_Count") end)) or 0
    local sum = 0
    for i = 0, n - 1 do
        local it = safe(function() return items:call("get_Item(System.Int32)", i) end)
        local iid = it and safe(function() return it:call("get_ItemId") end)
        if iid and _G.__re4_id_num(iid) == num then
            sum = sum + (tonumber(safe(function() return it:call("get_CurrentItemCount") end)) or 0)
        end
    end
    return sum
end

_G.__re4_item_count_sum = function(inv, id)
    if not (inv and id) then return 0 end
    local want = tostring(id)
    local items = safe(function() return inv:call("getItems") end); if not items then return 0 end
    local n = tonumber(safe(function() return items:call("get_Count") end)) or 0
    local sum = 0
    for i = 0, n - 1 do
        local it = safe(function() return items:call("get_Item(System.Int32)", i) end)
        if it then
            local iid = safe(function() return it:call("get_ItemId") end)
            if iid and tostring(iid) == want then
                sum = sum + (tonumber(safe(function() return it:call("get_CurrentItemCount") end)) or 0)
            end
        end
    end
    return sum
end

-- [TOP_LOADER] aktuelle Reserve-Ammo der equippten Waffe (ohne dass vorher geschossen
-- werden musste). Nutzt das Live-Item, faellt auf getEquipWeaponItem zurueck (nur fuer die
-- Ammo-ItemID), dann die korrekte getItems-Zaehlung. 0 wenn nichts ermittelbar.
local function current_reserve()
    local wi = get_live_weapon_item()
    if not wi then local pe0 = get_pe(); wi = pe0 and safe(function() return pe0:call("getEquipWeaponItem") end) end
    if not wi then return 0 end
    local ammo_id = safe(function() return wi:call("get_CurrentAmmo") end); if not ammo_id then return 0 end
    local pe2 = get_pe(); local inv2 = pe2 and sc(pe2, "get_InventoryController"); if not inv2 then return 0 end
    return tonumber(safe(function() return _G.__re4_item_count_sum(inv2, ammo_id) end)) or 0
end

-- [SHOTGUN GIMMICK] 1 Patrone RAUSPUMPEN: loaded -1 -> shell_bank +1 (kein Verlust, kein Inventar-
-- Gefummel). Gibt true zurueck wenn was rausging (loaded>0) -> dann fliegt die Shell. Funktioniert
-- bei JEDER Reserve (auch 0). Beim Reload kommen die Bank-Patronen zuerst gratis zurueck.
-- [SHOTGUN GIMMICK] Rein kosmetisch: Shell fliegt beim unnoetigen Pump solange Munition geladen ist.
-- KEINE Ammo-Aenderung (Shotgun-Chamber laesst sich per WeaponItem nicht dekrementieren -> wuerde eh
-- nicht greifen). Kostet so per Definition nichts. Gibt true zurueck wenn die Shell fliegen soll.
local function pump_one_out()
    local wi = get_live_weapon_item(); if not wi then return false end
    local loaded = tonumber(safe(function() return wi:call("get_CurrentAmmoCount") end)) or 0
    return loaded > 0
end

_G.__re4_reload_set_mag_in_hand = function(active)
    -- [MAGGRAB_DIAG] TEMP: jeden Aufruf + Gate-Entscheidung protokollieren.
    -- [log entfernt]
    -- [MANUAL_INSERT 2026-08-15] Haelt die linke Hand den Grip GERADE? Diese Funktion ist die einzige
    -- verlaessliche Quelle dafuer: das Holster ruft sie flankenweise beim Druecken und beim Loslassen
    -- (mag_set_holding). Waehrend eines laufenden Inserts ist mag_hand.active false -- der Loslass-Zweig
    -- unten macht dann nichts, und ohne diesen Merker wuesste der Rueckzieher nicht, dass der Finger
    -- laengst offen ist. (`__vr_raw_l_grip` taugt dafuer nicht: das setzt binding.lua nur im Throwsight.)
    mag_hand.grip_held = (active == true)
    if active then
        if not _managed then return false end      -- [LET-GO] Toggle aus -> kein Grab, alles nativ
        if is_shotgun(wep.wid) then
            -- [SHOTGUN] Shell aus dem Holster in die linke Hand (Joint _04 folgt der Hand wie ein Mag).
            -- KEIN mag_out noetig (man wirft kein Mag aus) -> nur greifbar wenn Reserve da ist und die
            -- Roehre nicht schon voll. Insert per Naehe addiert dann SHOTGUN_RATIO Shells.
            -- [STRIKER] Nach einer eingelegten Shell MUSS erst der Drehschalter gedreht werden (rack.needs)
            -- bevor die naechste Shell geholt werden darf. Nur ROTARY_CYCLE-Waffen (W-870/Riot Gun: frei laden).
            if ROTARY_CYCLE[wep.wid] and rack.needs then return false end
            if BREAK_ACTION[wep.wid] and not (rawget(_G, "__vr_break_open") == true) then return false end   -- [SKULL SHAKER] Shell nur bei OFFENEM Hebel holbar
            if mag_hand.active or mag_insert.active then return false end
            local wi0    = get_live_weapon_item()
            local loaded = wi0 and (sc(wi0, "get_CurrentAmmoCount") or 0) or 0
            local cap0   = wi0 and (sc(wi0, "get_CurrentAmmoMax") or 0) or 0
            -- greifbar wenn Reserve da UND Roehre nicht voll
            if current_reserve() <= 0 or (cap0 > 0 and loaded >= cap0) then return false end
            local ok = mag_to_hand()
            if ok then rlog("shotgun shell-in-hand AN"); play_weapon_sound(snd("mag_holster")) end
            return ok
        end
        -- Nur erlauben wenn die Kammer LEER ist (Mag schon draussen, mag_out=true).
        -- Es gibt nur EINEN Mag-Joint: bei vollem Mag wuerde der Holster-Grab das
        -- Kammer-Mag herausziehen (Mag verschwindet aus der Waffe). Schon ein Mag in
        -- der Hand? -> auch blocken (kein zweites).
        if TOP_LOADER[wep.wid] then
            -- [CLIP zurueckgestellt] Red9: kein Mag-Joint, Clip-Visual noch ungeloest -> Holster-
            -- Grab macht (noch) nichts. Funktionaler Reload = Chamber via B + Ammo per Insert.
            return false
        end
        if mag_hand.active then return false end   -- kein zweites Mag in die Hand
        if not mag_out then return false end
        local ok = mag_to_hand()
        if ok then rlog("mag-in-hand AN"); play_weapon_sound(snd("mag_holster")) end
        return ok
    end
    -- Grip losgelassen
    if is_shotgun(wep.wid) then
        -- [SHOTGUN] Shell nicht eingefuehrt -> faellt auf den Boden (wie ein Pistolen-Mag), NICHT
        -- zurueck in die Ruhepose. _04 wird von der aktuellen (Hand-)Position mit Gravity gedroppt.
        if mag_hand.active then
            mag_hand.active = false
            drop_mag_simple()
            rlog("shotgun shell losgelassen -> faellt auf den Boden")
        end
        return true
    end
    if TOP_LOADER[wep.wid] then return true end
    -- war das Mag noch in der Hand (nicht per Naehe inserted) -> faellt auf den Boden.
    if mag_hand.active then
        mag_hand.active = false
        drop_mag_simple()
        rlog("mag losgelassen -> faellt auf den Boden")
    end
    return true
end

-- FORWARD-DECL: live_loaded_count ist erst weiter unten (SLIDE-RACK-Sektion)
-- definiert. force_eject ruft es aber HIER schon -> ohne Forward-Decl zeigt der
-- Name auf eine nil-Globale -> Crash bei jedem B-Druck (bricht on_frame ab, bevor
-- der Mag-Drop startet). Forward-decl macht beide zum selben Upvalue. [[feedback-lua-forward-decl]]
local live_loaded_count

-- ROBUSTER Mag-Auswurf: raeumt JEDEN Zwischenzustand ab (laufender Insert,
-- Mag-in-Hand, Tuning, haengender/alter Drop, ungueltiger Joint nach Save-Load)
-- und startet immer einen frischen Drop aus der Kammer. Nie blockiert.
local function force_eject()
    -- [UNLIMITED] Waffe mit Unlimited-Ammo (Spezial-Upgrade/Infinite-Script) muss NIE
    -- nachladen -> B-Drop stilllegen (sonst haengt der Reload-Flow). Frisch gelesen.
    if _G.__re4_is_unlimited and _G.__re4_is_unlimited() then return false end
    refresh_weapon()                 -- Joint nach Save-Load/Wechsel neu aufloesen
    if not wep.mag_joint then return false end
    -- [MAG_OUT] Mag ist schon draussen -> NICHT noch eins droppen (Anti-Doppeldrop).
    -- mag_out wird per live_loaded_count>0 geheilt (siehe on_frame), kann nicht haengen.

    if mag_out then return false end
    -- [KEIN DROP OHNE RESERVE 2026-08-12] Ohne Nachschub wird das Magazin gar nicht erst
    -- ausgeworfen -- gilt fuer JEDE Waffe, nicht nur fuer die, bei der es auffiel.
    if (tonumber(current_reserve()) or 0) <= 0 then
        return false
    end
    -- [0-RESERVE-KEIN-EJECT 2026-07-23] Ohne Reserve gar nicht auswerfen: es gaebe keinen Mag zum
    -- Nachladen -> mag_out clemmt ewig -> Dauer-Dry-Fire TROTZ geladener Schuss (der Brick). Erst wenn
    -- Reserve da ist, ist ein Eject sinnvoll. INLINE + FAIL-OPEN (kein neuer Top-Level-Local -- reload.lua
    -- steht am 200-Local-Limit): nur sperren, wenn die Reserve-Kette SAUBER liest UND 0 ergibt; jeder
    -- unlesbare Zwischenzustand (Save-Load/Wechsel) laesst B durch -> kein neuer Brick. loaded>0 bleibt drin + feuert.
    do
        local ewi = get_live_weapon_item()
        if not ewi then local pe0 = get_pe(); ewi = pe0 and safe(function() return pe0:call("getEquipWeaponItem") end) end
        local eam = ewi and safe(function() return ewi:call("get_CurrentAmmo") end)
        local pe3 = get_pe(); local inv3 = pe3 and sc(pe3, "get_InventoryController")
        local ers = (ewi and eam and inv3) and tonumber(safe(function() return _G.__re4_item_count_sum(inv3, eam) end)) or nil
        if ers ~= nil and ers <= 0 then return false end   -- nur bei SAUBER gelesener 0 -> kein Eject (sonst B frei)
    end
    -- RE9-Latch: war die Waffe JETZT (vor dem Drop) leer? -> nach dem Reload Rack noetig.
    -- Taktischer Wechsel mit Patronen drin (loaded>0) -> KEIN Rack noetig.
    -- [STALE-FIX 2026-07-08] FRISCHER Engine-Read (pe:getCurrentGunAmmo = kein Cache, laut Code zuverlaessig)
    -- statt live_loaded_count -> das geht ueber das gecachte __re4_live_wi und liest nach Save-Load stale 0
    -- -> empty_when_dropped faelschlich true -> rack.needs latcht -> Dauer-Dry-Fire TROTZ Munition (gamebreaking).
    -- Regel bleibt exakt: Rack nur wenn die Gun beim Drop WIRKLICH 0 hatte. Fallback wenn pe/Read fehlt.
    do
        local pe_ee = get_pe()
        local fresh_ga = pe_ee and tonumber(safe(function() return pe_ee:call("getCurrentGunAmmo") end))
        if fresh_ga ~= nil then rack.empty_when_dropped = (fresh_ga == 0)
        else rack.empty_when_dropped = (live_loaded_count() == 0) end
        -- [KAMMER 2026-08-12] Der Read oben kann bereits UNSERE 0 sehen: mehrere Stellen schreiben die
        -- Waffe beim Auswurf auf 0, und laeuft der Latch danach, gilt ein volles Magazin faelschlich als
        -- leer -> Rack wird verlangt, obwohl nie leergeschossen wurde. Der beim Nullen gemerkte
        -- Magazinrest ist die verlaessliche Auskunft: war etwas drin, war die Kammer nicht leer.
        if (tonumber(rawget(_G, "__re4_mag_carry")) or 0) > 0 then
            rack.empty_when_dropped = false
        end
    end
    rack._chambered_hold = false   -- [CHAMBER_HOLD] neuer Reload-Zyklus -> Halt aus
    -- NIE blockiert: jeden laufenden Zwischenzustand abraeumen, Mag in Ruhepose, frisch
    -- droppen. KEIN Gate (das hatte B nach Reset/Save-Load tot gemacht).
    stop_mag_drop()
    mag_hand.active   = false
    mag_insert.active = false
    mag_insert.settle = false   -- [INSERT-PUNCH] Nachfedern mit abbrechen
    mag_tune.active   = false
    if wep.rest_lp then
        pcall(function() wep.mag_joint:call("set_LocalPosition",
            Vector3f.new(wep.rest_lp.x, wep.rest_lp.y, wep.rest_lp.z)) end)
    end
    if wep.rest_lr then
        pcall(function() wep.mag_joint:call("set_LocalRotation",
            Quaternion.new(wep.rest_lr.w, wep.rest_lr.x, wep.rest_lr.y, wep.rest_lr.z)) end)
    end
    local started = start_mag_drop()
    if started then mag_out = true end   -- [MAG_OUT] erst bei erfolgreichem Drop setzen
    if started then play_weapon_sound(snd("mag_eject")) end  -- [SND] Mag verlaesst die Waffe (Boden folgt verzoegert)
    return started
end

-- =====================================================================
-- Rechter B-Knopf -> Mag-Drop (RE9-Prinzip: Binding faengt B ab)
-- =====================================================================
-- Das Binding (re4_vr_binding.lua) unterdrueckt den rechten B -> Gamepad-X
-- (= nativer Reload), solange _G.__vr_manual_reload_consume_b gesetzt ist.
-- Wir lesen den B-Knopf direkt (nicht-konsumierend) fuer die Trigger-Flanke.
-- WICHTIG: NUR das Action-Handle cachen, den right_joystick JEDEN Call FRISCH holen.
-- Ein gecachtes Joystick-Handle wird stale (frueh gegriffen vor Controller-Init /
-- nach SteamVR-Szenenwechsel) -> is_action_active liefert lautlos false OHNE Fehler
-- -> setzt sich nie zurueck -> B reagiert dauerhaft nicht. 1:1 wie left_grip_down.
-- B kommt aus dem Binding (re4_vr_binding.lua): es liest den rechten B-Knopf ohnehin jeden
-- Frame und publiziert ihn VOR dem Consume als _G.__vr_raw_r_bbutton. Das ist die EINE
-- autoritative Quelle (Binding re-initialisiert die VR-Actions bei Reset). KEIN eigener
-- vrmod-Read mehr hier -> kein stale Action-Handle, das B wiederholt totlegt.
local function right_b_down()
    return rawget(_G, "__vr_raw_r_bbutton") == true
end
local _b_prev = false
-- [SND] Timer/Flanken fuer die Waffen-Sounds
local _mag_floor_at  = 0       -- os.clock-Ziel fuer den verzoegerten Mag-Boden-Sound
local _drop_prev     = false   -- Drop-Aktiv-Flanke (Auswurf ODER Holster-Release-Fall)
local _empty_trig_prev = false -- leere-Waffe-Trigger-Flanke (Dry-Fire)

-- =====================================================================
-- Frame-Loops
-- =====================================================================
-- Killswitch-fuer-Haende: wenn der manuelle Reload fuer die equippte Pistole AUS
-- ist und die NATIVE Reload-Anim (L4) laeuft, motion.lua pausieren -> die Engine
-- animiert die Haende selbst (statt Controller-Pin). Kein Kamera-Killswitch.
local native_pause_active = false
local function update_native_reload_pause()
    local wid = get_equip_wid()
    local manual_off = wid and category_of(wid) == "pistols" and not handled()
    local in_reload = false
    if manual_off then
        local body = get_body()
        local mfsm2 = body and sc(body, "getComponent(System.Type)", TD.mfsm2)
        local node = mfsm2 and sc(mfsm2, "getCurrentNodeName", 4)
        node = node and tostring(node) or ""
        in_reload = node:find("Reload", 1, true) ~= nil
    end
    if in_reload and not native_pause_active then
        native_pause_active = true
        _G.__vr_motion_paused = true
    elseif not in_reload and native_pause_active then
        native_pause_active = false
        _G.__vr_motion_paused = false
    end
end

-- =====================================================================
-- SLIDE-RACK (RE9-Muster): leer -> RT blockiert bis nachgeladen UND gerackt
-- =====================================================================
-- Geladene Patronen ROBUST lesen — jeden Frame frisch, KEIN event-gecachtes Item
-- (Cache veraltet nach Reset/Save/ohne-Schuss). Quellen-Kaskade, erste gueltige zaehlt.
local function read_loaded_of(wi, want_wid)
    if not wi then return nil end
    if want_wid then
        local cwid = safe(function() return wi:call("get_WeaponId"):get_field("value__") end)
        if cwid and cwid ~= want_wid then return nil end   -- falsches Item -> ignorieren
    end
    local n = safe(function() return wi:call("get_CurrentAmmoCount") end)
    return (type(n) == "number") and n or nil
end
-- (Zuweisung an die Forward-Decl oben, NICHT 'local function' -> selber Upvalue)
live_loaded_count = function()
    -- KONSISTENZ ist alles: lesen vom GLEICHEN Item auf das set_gun_loaded/addAmmoCount
    -- schreiben (get_live_weapon_item). Sonst sieht der Block-Check nach dem Drop noch
    -- Munition -> Schiessen ohne Mag. getCurrentGunAmmo war eine andere Quelle -> raus.
    local ewid = get_equip_wid()
    local n = read_loaded_of(get_live_weapon_item(), ewid)
    if n then return n end
    -- Fallback nur falls das Live-Item mal fehlt
    return read_loaded_of(get_weapon_item(), nil)
end

-- [GUN_STATE] chainsaw.Gun = Waffen-Runtime auf dem Waffen-GO. Traegt CurrentState; bei 0 Ammo
-- = AmmoEmpty -> Engine lockt den Slide hinten. set_CurrentState/setState entriegelt.
-- ([CLEANUP] toter `local _gun_type` entfernt -- war nie benutzt.)
-- Live-Gun der EQUIPPTEN Waffe DIREKT aus PlayerEquipment.WeaponList holen
-- (Dictionary<WeaponID, Arms>; fuer Pistolen ist Arms = chainsaw.Gun). Kein Hook, keine
-- Baum-Suche, kein Neustart. PlayerEquipment kriegen wir zuverlaessig (get_pe).
local function get_gun()
    local pe = get_pe(); if not pe then _G.__re4_gun_dbg = "no_pe"; return nil end
    local wl = safe(function() return pe:get_field("WeaponList") end)
    if not wl then _G.__re4_gun_dbg = "no_WeaponList"; return nil end
    local ewid = get_equip_wid(); if not ewid then _G.__re4_gun_dbg = "no_ewid"; return nil end
    -- 1) Versuch get_Item (Enum-Key direkt + als Zahl)
    for _, key in ipairs({ safe(function() return pe:call("get_EquipWeaponID") end), ewid }) do
        if key ~= nil then
            local a = safe(function() return wl:call("get_Item", key) end)
            if a and safe(function() return a:call("get_CurrentState") end) ~= nil then _G.__re4_gun_dbg = "OK(get_Item)"; return a end
        end
    end
    -- 2) Fallback: ueber die internen _entries iterieren und die Arms mit passender WeaponID nehmen
    local entries = safe(function() return wl:get_field("_entries") end)
    local cnt = tonumber(safe(function() return wl:get_field("_count") end)) or 0
    if not entries then _G.__re4_gun_dbg = "no_entries"; return nil end
    for i = 0, cnt - 1 do
        local v = safe(function() local e = entries[i]; return e and e:get_field("value") end)
        if v then
            local vwid = safe(function() return v:call("get_WeaponID"):get_field("value__") end)
            if vwid == ewid and safe(function() return v:call("get_CurrentState") end) ~= nil then
                _G.__re4_gun_dbg = "OK(iter)"; return v
            end
        end
    end
    _G.__re4_gun_dbg = "not_found(cnt=" .. cnt .. ")"
    return nil
end
local function gun_state_val()
    local g = get_gun(); if not g then return nil end
    local s = safe(function() return g:call("get_CurrentState") end)
    if type(s) == "number" then return s end                                  -- Enum kommt als Zahl
    if type(s) == "userdata" then return safe(function() return s:get_field("value__") end) end
    return nil
end
-- Enum-Werte holen (AmmoEmpty fuer die Leer-Erkennung, Holding zum Entriegeln nach dem Rack).
local _state_td = sdk.find_type_definition("chainsaw.Gun.State")
local function _enum_num(name)
    local v = _state_td and safe(function() return _state_td:get_field(name):get_data(nil) end)
    if type(v) == "number" then return v end
    return v and safe(function() return v:get_field("value__") end)
end
local _ammoempty_num    = _enum_num("AmmoEmpty")
local _gun_state_holding = _state_td and safe(function() return _state_td:get_field("Holding"):get_data(nil) end)
-- Wert -> Name Map fuer lesbare Logs (AmmoEmpty/Holding/Fire/Reload/...)
local _state_names = {}
pcall(function()
    if not _state_td then return end
    for _, f in ipairs(_state_td:get_fields()) do
        if f:is_static() then
            local v = f:get_data(nil)
            local num = (type(v) == "number") and v or (type(v) == "userdata" and safe(function() return v:get_field("value__") end))
            if num then _state_names[num] = f:get_name() end
        end
    end
end)
local function gun_state_name()
    local v = gun_state_val()
    if v == nil then return "NIL(keine Gun)" end
    return string.format("%s(%s)", _state_names[v] or "?", tostring(v))
end
-- [EMPTY] Sieht die ENGINE die Waffe als leer? (Gun.CurrentState==AmmoEmpty) -> zuverlaessig,
-- unabhaengig vom kaputten Ammo-Zaehler. Das treibt "0 Ammo -> Slide MITTEL".
local function gun_is_empty()
    local v = gun_state_val()
    return (v ~= nil and _ammoempty_num ~= nil and v == _ammoempty_num) or false
end
-- Gun aus AmmoEmpty holen (= "Patrone gechambert") -> Engine lockt den Slide nicht mehr.
local function gun_chamber()
    local g = get_gun(); if not (g and _gun_state_holding ~= nil) then return end
    pcall(function() g:call("set_CurrentState(chainsaw.Gun.State)", _gun_state_holding) end)
end

local _rack_lj = nil
local function rack_haptic(amp, dur)
    if not CFG.rack_haptic or not vrmod then return end
    if not _rack_lj then pcall(function() _rack_lj = vrmod:get_left_joystick() end) end   -- linke Hand rackt
    if _rack_lj then pcall(function() vrmod:trigger_haptic_vibration(0.0, dur or 0.06, 169.385, amp or 0.9, _rack_lj) end) end
end

-- [SHOTGUN PUMP] Haptik mit optionalem Delay (CFG.pump_haptic_delay) -> aufs Audio legbar.
-- Delay<=0 -> sofort. Sonst in die Queue, service_haptics feuert wenn die Zeit erreicht ist.
local _haptic_queue = {}
local function queue_haptic(amp, dur)
    local d = tonumber(CFG.pump_haptic_delay) or 0
    if d <= 0 then rack_haptic(amp, dur); return end
    _haptic_queue[#_haptic_queue + 1] = { at = os.clock() + d, amp = amp, dur = dur }
end
local function service_haptics()
    local n = #_haptic_queue
    if n == 0 then return end
    local now = os.clock()
    local i = 1
    while i <= #_haptic_queue do
        local h = _haptic_queue[i]
        if now >= h.at then rack_haptic(h.amp, h.dur); table.remove(_haptic_queue, i)
        else i = i + 1 end
    end
end

-- [ROTARY_DEFER 2026-07-18] Der Shotgun-Ammo-Add (Reserve->Mag in Ratio) als Feld auf der
-- bestehenden rotary-Tabelle = KEIN neuer Main-Chunk-Local (200-Limit). Logik 1:1 aus dem alten Insert-
-- Shotgun-Zweig, nur wi/reserve/loaded frisch recomputet (zum Aufruf-Zeitpunkt). Aufrufer: nicht-Rotary
-- Shotguns beim Insert (sofort), Striker am Drehschalter-Peak (update_rotary_cycle).
rotary.do_load = function()
    if not CFG.reload_ammo then return end
    local wi  = get_live_weapon_item()
    local pe  = get_pe()
    local inv = pe and sc(pe, "get_InventoryController")
    local ammo_id = wi and safe(function() return wi:call("get_CurrentAmmo") end)
    local reserve = 0
    if inv and ammo_id then reserve = tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or 0 end
    local loaded = wi and (sc(wi, "get_CurrentAmmoCount") or 0) or 0
    local cap    = wi and (sc(wi, "get_CurrentAmmoMax") or 0) or 0
    local ratio  = math.max(1, math.floor(tonumber(SHOTGUN_RATIO_WID[wep.wid] or CFG.shotgun_ratio) or 2))
    local add    = math.min(ratio, math.max(0, cap - loaded), reserve)
    if add <= 0 then return end
    -- loaded erhoehen: ENGINE-Reload inv:reload (einziger Pfad der wirklich greift; write_dword/addAmmoCount
    -- werden re-synct), Fallback addAmmoCount. VERLUSTSICHER: Reserve nur abziehen wenn der Pfad sie nicht selbst zog.
    -- [ACCESSOR 2026-08-12] echte Instanz zuerst; __re4_live_wi kann eine Leiche sein, wi eine Kopie.
    local awi   = (_G.__re4_real_wi and _G.__re4_real_wi()) or rawget(_G, "__re4_live_wi") or wi
    local b4    = awi and (sc(awi, "get_CurrentAmmoCount") or loaded) or loaded
    -- [KEIN ABZUG OHNE LADUNG 2026-08-01, "die Reserve geht weg aber nichts in die Waffe"]
    -- Der Ladestand des Item-Objekts (`b4`/`af`) ist KEIN Beweis, dass die Waffe geladen hat -- beim
    -- Skull Shaker steigt er, waehrend die HUD auf 0 stehenbleibt (Log 1778.51: "hud blieb bei 0",
    -- direkt danach "Reserve 4 -> 2"). Deshalb wird der Erfolg zusaetzlich an der HUD gemessen, und
    -- die Reserve NUR gezogen, wenn dort wirklich Munition angekommen ist.
    local hud_b4 = tonumber(_G.__re4_gun_ammo and _G.__re4_gun_ammo()) or 0
    local r_b4  = reserve
    local et    = get_equip_type_main()
    -- [CRASH-HARDEN] nativer reload nur bei live equippter, passender Waffe (sonst null-Gun-Item -> c0000005).
    -- [NO_NATIVE_RELOAD 2026-07-31] Rueckgabe auswerten: hat der Helfer bereits geladen (Direktweg,
    -- Reserve dort schon gezogen), duerfen die addAmmoCount-Nachschlaege unten NICHT mehr laufen -- sonst
    -- laedt es doppelt, waehrend die Reserve nur einmal abgezogen wurde. `awi` kann eine andere Item-
    -- Instanz sein als die, auf die der Direktweg geschrieben hat -> af <= b4 waere hier kein Beweis.
    local did = false
    if et and inv and (get_equip_wid() or -1) >= 0 and get_equip_wid() == wep.wid then
        -- [NUR WER EINEN EIGENEN PFAD HAT 2026-07-31] Dem Helfer sagen, dass HIER noch ein eigener
        -- Nachschlag kommt, wenn er false meldet -> er haelt sich dann raus. Ohne dieses Flag laedt er
        -- Teilmengen selbst (was Bogen/Bolt Thrower brauchen, die keinen eigenen Pfad haben).
        _G.__re4_caller_has_fallback = true
        did = _G.__re4_load_and_book(inv, et, add, false) == true
        _G.__re4_caller_has_fallback = nil
    end
    local af    = awi and (sc(awi, "get_CurrentAmmoCount") or b4) or b4
    -- [SHELL-DIAG 2026-07-31 ENTFERNT] Die Messzeilen (Instanz-Adressen, hud/Reserve vorher-nachher)
    -- haben ihren Zweck erfuellt: sie haben belegt, dass getItems/getInventoryItemList Kopien
    -- liefern und der Reserve-Abzug deshalb nie ankam. Der Ladeweg laeuft jetzt ueber den nativen
    -- Call, der die Reserve selbst zieht. Zum Wiederholen: others/re4_vr_reload.bak_2026-07-31_pre_diagclean.
    -- Die beiden addAmmoCount-Nachschlaege bleiben als Sicherheitsnetz: sie laufen NUR, wenn der
    -- Helfer nicht geladen hat (did=false) UND das Item sich nicht bewegt hat.
    -- [SYNC 2026-08-01] Wie in Weg C: addAmmoCount landet nur im Item, die Runtime-Gun (HUD, Feuern,
    -- Dry-Fire-Erkennung) muss per updateGunAmmo nachgezogen werden -- sonst steht das Item auf 2 und
    -- die Waffe bleibt leer.
    if not did and af <= b4 then
        pcall(function() awi:call("addAmmoCount", add, true) end)
        if _G.__re4_sync_gun_ammo then _G.__re4_sync_gun_ammo() end
        af = awi and (sc(awi, "get_CurrentAmmoCount") or b4) or b4
    end
    if not did and af <= b4 then
        pcall(function() awi:call("addAmmoCount", add, false) end)
        if _G.__re4_sync_gun_ammo then _G.__re4_sync_gun_ammo() end
        af = awi and (sc(awi, "get_CurrentAmmoCount") or b4) or b4
    end
    -- Erfolg = was in der WAFFE angekommen ist (HUD), nicht was am Item-Objekt steht. Steigt nur das
    -- Item, war es eine Buchung ins Leere -> kein Abzug.
    local hud_af = tonumber(_G.__re4_gun_ammo and _G.__re4_gun_ammo()) or hud_b4
    local gained = math.max(0, hud_af - hud_b4)
    if gained <= 0 then
        -- nichts in der Waffe angekommen -> nichts abbuchen
    elseif inv and ammo_id then
        -- Reserve nur manuell ziehen, wenn der genutzte Pfad sie NICHT selbst gezogen hat.
        local r_now = tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or r_b4
        if r_now >= r_b4 then _G.__re4_safe_reduce(inv, ammo_id, gained) end
    end
end

local function clear_rack()
    -- [EMPTY-RELOAD SLIDE] War's der _08-Lade-Slide? -> _08 nach vorn (rest) schnappen + Modus beenden
    -- (danach wieder normaler Pump). Vor dem _01-Handling, damit es unabhaengig von ENGINE_CLOSES_SLIDE laeuft.
    local was_er = rack.empty_reload
    rack.empty_reload = false
    if was_er and wep.slide_joint2 then
        local cur = sc(wep.slide_joint2, "get_LocalPosition")
        if cur then
            local sp2 = slide_pose2(wep.wid or 0)
            pcall(function() wep.slide_joint2:call("set_LocalPosition", Vector3f.new(cur.x, cur.y, sp2.rest_z)) end)
        end
    end
    rack.needs = false
    rack.grab_active = false
    rack.pulled = false
    rack.pushed = false
    rack.frac = 0
    _G.__vr_needs_rack = false
    _G.__vr_block_fire_when_empty = false
    _G.__re4_bf_who = "re4_vr_reload.lua:2057"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
    _G.__vr_rack_block_left_knife = false
    -- [GUN_STATE] Engine aus AmmoEmpty holen (Patrone gechambert) -> rack.empty wird false.
    gun_chamber()
    -- [ENGINE_CLOSES_SLIDE] Bei diesen Waffen schliesst die Engine den Slide selbst -> wir forcen
    -- NICHTS (kein _chambered_hold, kein rest_z-Snap). Das Gate in apply_slide_park gibt dann im
    -- Ruhezustand zurueck -> Engine kontrolliert den Slide.
    if ENGINE_CLOSES_SLIDE[wep.wid] then
        rack._chambered_hold = false
        rack._prev_gun_ammo = nil
        return
    end
    if ROTARY_CYCLE[wep.wid] then   -- [ROTARY_CYCLE] kein Position-Snap/Chamber-Hold (joint_01 dreht, kein Z)
        rack._chambered_hold = false
        rack._prev_gun_ammo = nil
        return
    end
    -- [CHAMBER_HOLD] Slide ab jetzt auf ZU halten (Engine spielt die Schliess-Anim nach unserem
    -- manuellen Reload nicht). Wird beim ersten Schuss geloescht (dann uebernimmt die Engine).
    rack._chambered_hold = true
    rack._prev_gun_ammo = nil   -- frischer Schuss-Vergleich
    -- Slide nach dem Rack auf rest_z (vorne/gechambert) schnappen (Sofort-Effekt; Engine zieht nach).
    if wep.slide_joint then
        local cur = sc(wep.slide_joint, "get_LocalPosition")
        if cur then
            local sp = slide_pose(wep.wid or 0)
            pcall(function() wep.slide_joint:call("set_LocalPosition", Vector3f.new(cur.x, cur.y, sp.rest_z)) end)
        end
    end
end

-- Empty-Detect + Block-Globals pflegen
local function update_rack_state()
    if rack.tuning then return end   -- UI-Vorschau: Live-Logik aussetzen
    if TOP_LOADER[wep.wid] then
        -- [TOP_LOADER] kein Slide-Rack. Chamber-Blend einmal pro Frame Richtung Ziel rampen
        -- (open=1, zu=0) -> apply_chamber zeichnet die smoothstep-Kurve. Feuern sperren solange offen.
        local target = chamber.open and 1.0 or 0.0
        if chamber.blend < target then chamber.blend = math.min(target, chamber.blend + CHAMBER_BLEND_SPEED)
        elseif chamber.blend > target then chamber.blend = math.max(target, chamber.blend - CHAMBER_BLEND_SPEED) end
        _G.__vr_block_fire_when_empty = chamber.open and true or false
        _G.__re4_bf_who = "re4_vr_reload.lua:2097"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
        return
    end
    if handled() == nil then         -- nur an "Manual Pistol Reload" gekoppelt, kein Extra-Toggle
        rack.empty = false
        if rack.needs or _G.__vr_block_fire_when_empty then clear_rack() end
        return
    end
    local loaded   = live_loaded_count()
    local flow_active = not mag_is_present()   -- Drop/in-Hand/Insert laeuft gerade
    local is_empty = (type(loaded) == "number") and loaded <= 0   -- frischer Engine-Read
    rack.has_mag   = (type(loaded) == "number" and loaded > 0)
    -- [EMPTY_SLIDE] Slide-Trigger = Waffe LEER. Quelle = ENGINE Gun.CurrentState==AmmoEmpty
    -- (zuverlaessig!), NICHT der kaputte Ammo-Zaehler (las nach dem Reload falsch 0 -> Slide
    -- blieb auf MITTEL statt zu). Nach dem Rack setzt gun_chamber Holding -> nicht mehr leer.
    -- [EMPTY_SLIDE] Slide auf MITTEL (halb hinten) SOFORT bei 0 Ammo -> game-eigenes
    -- isGunAmmoEmpty (greift auch im IgnoreClerMask-Zwischenstate, anders als State==AmmoEmpty).
    -- Nach dem Reload wieder false -> kein Konflikt mit dem Nach-Rack-Schliess-Halt.
    local pe_e = get_pe()
    rack.empty = (pe_e and safe(function() return pe_e:call("isGunAmmoEmpty") end)) == true
    -- [RIOT GUN SELF-HEAL 2026-07-17 "was passiert wenn wir beim Nachladen staggered werden"] Bei
    -- NO_RELOAD_CYCLE (Riot Gun) ist der Rack NUR noetig, solange die Gun nach dem 0-Reload UN-gechambert
    -- bleibt (isGunAmmoEmpty=true). Ist sie feuerbereit (rack.empty=false) -- weil ein Stagger/Engine-Event
    -- zwischendrin gechambert hat ODER empty_reload faelschlich gelatcht war -- dann ist KEIN Rack noetig:
    -- den sticky Latch loesen, sonst bleibt "kann schiessen UND Hand will ans Rack" haengen. Feuert genau
    -- einmal (danach empty_reload=false). Der ECHTE 0-Reload haelt rack.empty=true bis zur Rack-Geste -> hier
    -- NICHT vorzeitig geloescht. NUR die Riot Gun (NO_RELOAD_CYCLE); alle anderen Shotguns unberuehrt.
    -- [RACK IST PFLICHT nach 0-Reload 2026-07-17 "auf 0 + nachladen = Slide-Rack Pflicht"] Der fruehere
    -- Self-Heal (loeschte rack.needs, sobald die Engine die Riot Gun beim Reload chamberte -> rack.empty=false)
    -- ist RAUS. Er nahm faelschlich auch den gewollten Leer-Reload-Rack weg. Jetzt bleibt der Rack Pflicht,
    -- bis die Rack-Geste (clear_rack) ihn loest. (Damit ist die alte Stagger-beim-Nachladen-Heilung entfernt.)
    -- [CHAMBER_HOLD] Schuss erkennen (echte Gun-Ammo SINKT) -> Nach-Rack-Halt loesen, ab dann
    -- spielt die Engine die Slide-Anim selbst. getCurrentGunAmmo ist zuverlaessig (kein Cache).
    if rack._chambered_hold then
        local ga = pe_e and tonumber(safe(function() return pe_e:call("getCurrentGunAmmo") end))
        if CHAMBER_HOLD_PERSIST[wep.wid] then
            -- [CHAMBER_HOLD_PERSIST] NICHT beim Schuss loesen -> Slide bleibt zu, bis die Waffe
            -- leer ist (rack.empty oben aus isGunAmmoEmpty). Dann normaler Leer-Slide (park_z).
            if rack.empty then rack._chambered_hold = false end
        else
            if ga and rack._prev_gun_ammo and ga < rack._prev_gun_ammo then rack._chambered_hold = false end
        end
        rack._prev_gun_ammo = ga
    end
    -- needs_rack wird hier NICHT abgeleitet (das war der Fehler). Es wird beim Insert
    -- gelatcht (nur wenn vorher leer) und NUR durch die Rack-Geste geclear't -> sticky,
    -- ueberlebt das Nachladen. Genau RE9. Geclear't ausserdem bei Waffenwechsel/Reset.
    -- [SHOTGUN] Nach JEDEM Schuss ist ein Pump noetig. Schuss = __vr_shot_seq steigt (crosshair-Hook).
    -- Nur Shotgun; Pistolen unberuehrt. Setzt needs_pump -> naechster Pump = noetig (kein Gimmick).
    if is_shotgun(wep.wid) then
        local seq = tonumber(rawget(_G, "__vr_shot_seq")) or 0
        -- [SHOTGUN] Pump nach Schuss NUR wenn danach noch Munition in der Kammer ist (rack.has_mag).
        -- Hat der Schuss auf 0 geleert -> KEIN Pump (man chambert keine leere Kammer; jetzt wird
        -- nachgeladen). Sonst haengt ein unmoeglicher Pump bei 0 -> wirkt wie ein Soft-Lock.
        -- [NO_CYCLE_AFTER_SHOT] Striker: kein Cycle nach dem Schuss (frei ballern bis 0); nur beim Laden.
        if rack._prev_shot_seq and seq > rack._prev_shot_seq and rack.has_mag and not NO_CYCLE_AFTER_SHOT[wep.wid] then rack.needs = true end
        rack._prev_shot_seq = seq
    end
    -- [SHOTGUN] needs_rack pre-empted in motion die Support-Hand (undockt sie sofort). Bei der Shotgun
    -- soll die Hand im Pump-Fenster (nach Schuss) AUF dem Vordergriff bleiben (Two-Hand-IK) -> daher
    -- needs_rack hier NICHT melden. Der echte Pump undockt ohnehin via slide_dock_blend (grab_active).
    -- Andere Waffen: needs_rack lenkt die linke Hand wie gehabt an den Slide.
    _G.__vr_needs_rack             = rack.needs and not is_shotgun(wep.wid)
    -- [IK-GATE] Slide-Rack-Grab aktiv -> motion sperrt die Two-Hand-IK (sonst dreht ein bereits
    -- gehaltener rechter Grip die Waffe waehrend des Rackens). Erst nach Rack-Ende wieder IK.
    _G.__vr_slide_rack_active      = rack.grab_active == true
    _G.__vr_shotgun_pump_active    = (rack.grab_active and wep.wid and is_shotgun(wep.wid)) == true   -- [PUMP_NO_Z] Laengsachse sperren (motion)
    -- Feuern gesperrt wenn: Rack noetig ODER Mag physisch draussen (mag_out, bis nachgeladen)
    -- ODER gerade ein Flow laeuft ODER die Waffe LEER ist (loaded<=0, frisch aus der Engine).
    -- mag_out + is_empty heilen ueber loaded>0 -> kein Dauer-Block nach echtem Reload.
    if BREAK_ACTION[wep.wid] then
        -- [SKULL SHAKER] Block/Dry-Fire wenn leer ODER Cock aussteht (rack.needs nach Schuss) ODER Hebel OFFEN
        -- (solange aufgeklappt = nicht schiessbar, bis wieder zu). Cock/Close (clear_rack) hebt rack.needs auf.
        -- [LIVE-EMPTY] rack.empty = pe:isGunAmmoEmpty (jeden Frame frisch, KEIN Cache), statt is_empty
        -- (live_loaded_count -> gecachtes __re4_live_wi, nach Save-Load stale 0 -> Fehl-Dry-Fire).
        _G.__vr_block_fire_when_empty = rack.empty or rack.needs or (rawget(_G, "__vr_break_open") == true)
        _G.__re4_bf_who = "re4_vr_reload.lua:2171"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
    elseif DRYFIRE_ONLY_WHEN_EMPTY[wep.wid] then
        -- [STRIKER] Block/Dry-Fire wenn leer ODER ein Cycle aussteht (rack.needs nach JEDER nachgelegten
        -- Shell) -> RT gesperrt BIS am Schalter gedreht wurde (clear_rack loescht needs).
        -- KEIN flow_active/mag_out-Block (Drum = Fehl-Block) und kein after-shot-Block (NO_CYCLE_AFTER_SHOT).
        -- [LIVE-EMPTY] rack.empty statt is_empty (kein Cache).
        _G.__vr_block_fire_when_empty = rack.empty or rack.needs
        _G.__re4_bf_who = "re4_vr_reload.lua:2177"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
    else
        -- [LIVE-EMPTY 2026-07-08] Grundregel: die Engine entscheidet ueber "kann nicht feuern" via rack.empty
        -- (pe:isGunAmmoEmpty, frisch). Bei den meisten Waffen bleibt die Gun bis zur Rack-Geste in AmmoEmpty.
        -- [RIOT GUN RACK-PFLICHT 2026-07-17 "auf 0 + nachladen = Slide-Rack Pflicht"] AUSNAHME: die Riot
        -- Gun (NO_RELOAD_CYCLE) ist semi-auto -> die Engine CHAMBERT beim 0-Reload sofort (isGunAmmoEmpty=false)
        -- -> rack.empty allein blockt NICHT -> man konnte ohne Rack weiterballern. Darum zusaetzlich den sticky
        -- Empty-Reload-Latch: nach 0 + Nachladen bleibt Feuern gesperrt, bis der _08-Slide-Rack (clear_rack ->
        -- empty_reload=false) gezogen wurde. Genau wie bei den anderen Waffen.
        -- [RACK-ZWANG 2026-07-20 -- per Log BEWIESEN] rack.needs FEHLTE hier. Ablauf laut
        -- re4_rack_diag.log: leergeschossen -> DROP fresh_ga=0 -> empty_when_dropped=true -> INSERT setzt
        -- rack.needs=true (Z.~1506) -- aber diese Zeile fragt needs gar nicht ab. Der native Reload
        -- chambert die Waffe (isGunAmmoEmpty=false) -> rack.empty=false -> Block faellt weg -> man konnte
        -- nach dem Nachladen OHNE Slide-Rack weiterfeuern. needs ist der sticky Latch, der erst durch die
        -- Rack-Geste (clear_rack) faellt -- genau das gewuenschte Verhalten.
        -- UNGEFAEHRLICH fuer Pistolen: needs wird nach einem SCHUSS nur im is_shotgun-Zweig gesetzt
        -- (Z.~2223), bei Pistolen also ausschliesslich beim 0-Reload.
        _G.__vr_block_fire_when_empty  = rack.empty or rack.needs or mag_out or flow_active
            or (NO_RELOAD_CYCLE[wep.wid] and rack.empty_reload)
        _G.__re4_bf_who = "re4_vr_reload.lua:2186"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
    end
    _G.__vr_rack_block_left_knife  = rack.needs   -- linker Grip frei fuer Slide-Grab (Messer aus)
end

-- Linker Grip (vrmod, wie der Holster). Liefert (gedrueckt, left_joystick).
-- 1:1 aus re9_vr_reload.lua get_left_grip_pressed: left_joystick JEDEN Aufruf frisch
-- holen (nicht cachen -> wird sonst stale -> is_action_active schlaegt fehl).
local function left_grip_down()
    if not vrmod then return false end
    -- [STALE_HANDLE_FIX] Action-Handle UND Joystick JEDEN Frame frisch holen (nicht cachen): nach
    -- Save-Load/Szenenwechsel geht das gecachte Grip-Handle stale -> is_action_active lautlos false
    -- -> Pump-Grab tot bis Reset. Frisch holen heilt sich in-place. [[project-re4-vr-mag-holster-stale-grip]]
    local act, lj
    pcall(function() act = vrmod:get_action_grip() end)
    pcall(function() lj  = vrmod:get_left_joystick() end)
    if not act or not lj then return false end
    local ok, v = pcall(function() return vrmod:is_action_active(act, lj) end)
    return ok and v == true
end

-- [ROTARY_CYCLE] Linker Trigger (vrmod weapon_dial-Action, wie motion is_left_trigger_held). Nur LESEN,
-- normale Funktion bleibt. Handle jeden Frame frisch (Stale-Handle-Fix wie beim Grip).
local function left_trigger_down()
    if not vrmod then return false end
    local ok, v = pcall(function()
        local act = vrmod:get_action_weapon_dial()
        local lj  = vrmod:get_left_joystick()
        if not (act and lj) then return false end
        return vrmod:is_action_active(act, lj)
    end)
    return ok and v == true
end

-- [BREAK_ACTION] Pitch des LINKEN Controllers in Grad (forward.y-Winkel). Runterkippen -> sinkt.
-- Treibt den Klapphebel (joint_02). Handle jeden Frame frisch.
local function left_ctrl_pitch_deg()
    if not vrmod then return nil end
    local ok, p = pcall(function()
        local cs = vrmod:get_controllers(); if not cs or #cs < 1 then return nil end
        local q = vrmod:get_rotation(cs[1]); q = q and q:to_quat()
        if not q then return nil end
        local f = q * Vector3f.new(0, 0, 1)
        local y = f.y; if y > 1 then y = 1 elseif y < -1 then y = -1 end
        return math.deg(math.asin(y))
    end)
    return ok and p or nil
end

-- Linke CONTROLLER-Welt-Position (1:1 aus RE9 SD.get_left_controller_pos). WICHTIG:
-- fuer Grab-Distanz UND Zug den Controller nehmen, NICHT den L_Hand-Bone — der wird
-- beim Dock an den Slide gepinnt, sonst waere die Zug-Bewegung immer null.
local function get_left_controller_pos()
    if not vrmod then return nil end
    local ok, pos = pcall(function()
        local controllers = vrmod:get_controllers()
        if not controllers or #controllers < 1 then return nil end
        return vrmod:get_position(controllers[1])
    end)
    return ok and pos or nil
end

-- Rack-Geste (RE9-Verfahren): linke Hand am Slide + LINKER GRIP greift -> Grip
-- HALTEN und ganz nach hinten ziehen (Slide folgt via frac) -> Grip LOSLASSEN = fertig.
-- "armed": Grip muss einmal losgelassen worden sein, bevor neu gegriffen werden kann.
local function update_rack_gesture()
    if rack.tuning then return end   -- UI-Vorschau: Geste aussetzen

    -- [STAGGER-FIX 2026-08-10, Log-belegt] Riot Gun: nach einem Stagger mit
    -- ausstehendem Rack ging weder Rack noch Schuss -- aber ein "Pumpen" vorne am
    -- Vorderschaft loeste es. Genau das ist der Rest aus der Pump-Gun-Zeit:
    -- der Stagger raeumt `empty_reload` weg (`needs` bleibt sticky stehen), und damit
    -- greift ab Z.~3518 der Shotgun-Pull-to-Pump-Zweig am _01-Schaft statt des
    -- Release-arm-Pfads am _08-Ladeslide. Der Pump-Zweig kennt `armed` gar nicht --
    -- deshalb blieb armed im Log ueber den ganzen Vorgang false, obwohl Hand und
    -- Joint nachweislich in Ordnung waren (22 Frames Grip + dist 0.258 bei max 0.297).
    --
    -- Der Modus laesst sich zwingend rekonstruieren, ohne den Loescher zu kennen:
    -- bei der Riot Gun (NO_RELOAD_CYCLE) wird `needs` AUSSCHLIESSLICH ueber
    -- `empty_reload` gesetzt (Z.~2636). Steht needs, war es also ein Empty-Reload.
    if NO_RELOAD_CYCLE[wep.wid] and rack.needs and not rack.empty_reload then
        rack.empty_reload = true
        _G.__vr_empty_reload_active = true
    end
    if ROTARY_CYCLE[wep.wid] or BREAK_ACTION[wep.wid] then return end   -- [ROTARY/BREAK] eigener Pfad, kein Pull-Rack
    -- [SHOTGUN PUMP-FENSTER] Pump (= Slide-Grab am Schaft) NUR wenn rack.needs -> d.h. einmal nach
    -- jedem Schuss (shot_seq, s.u.) oder nach einer Shell-Reload. AUSSERHALB des Fensters racket die
    -- Shotgun NICHT -> der linke Grip am Schaft ist frei fuer Two-Hand-IK (motion). Gilt jetzt fuer
    -- ALLE Waffen gleich (kein is_shotgun-Sonderfall mehr = "immer pumpbar" war der Two-Hand-Killer).
    if not rack.needs then
        rack.grab_active = false; rack.pulled = false; rack.pushed = false; rack.frac = 0; rack.armed = false
        rack._pump_ref_z = nil   -- [PUMP_AXIS] Achse+Kamera-Anker verfallen   -- [SHOTGUN] Pull-to-Pump-Referenz frisch fuers naechste Fenster
        _G.__re4_rack_dbg = "kein Rack noetig (needs=false)"
        rack._last_grip = false; rack._last_dist = -1; return
    end
    if not wep.slide_joint or (rack.empty_reload and not wep.slide_joint2) then refresh_weapon() end
    local sj  = rack_joint()   -- [EMPTY-RELOAD SLIDE] _08 im Empty-Reload-Modus, sonst _01 (Pump/Slide)
    -- Linke Hand-WELT-Ziel (motion, Controller-getrieben, GAME-WORLD) fuer Grab-Distanz + Zug.
    -- NICHT der L_Hand-Bone (wird beim Dock an den Slide gepinnt -> Zug=0) und NICHT
    -- der vrmod-Controller (anderer Koordinatenraum -> dist=129!). Dieses Global setzt
    -- motion VOR dem IK -> vom Dock unberuehrt -> bewegt sich frei mit dem Controller.
    -- [SHOTGUN] rohe un-gedockte Hand (__vr_lh_ctrl_world): noetig fuer den nahtlosen Pull-to-Pump
    -- aus der Two-Hand-Haltung (sonst gepinnt = Zug 0). Andere Waffen wie gehabt.
    local hp
    if is_shotgun(wep.wid) then
        hp = rawget(_G, "__vr_lh_ctrl_world") or rawget(_G, "__vr_lh_world") or rawget(_G, "__vr_unified_lh_pos") or rawget(_G, "__vr_lh_joint_pos")
    else
        hp = rawget(_G, "__vr_lh_world") or rawget(_G, "__vr_unified_lh_pos") or rawget(_G, "__vr_lh_joint_pos")
    end
    if not hp then local lh = get_left_hand(); hp = lh and sc(lh, "get_Position") end
    local sp  = sj and sc(sj, "get_Position")
    local grip = left_grip_down()
    rack._last_grip = grip
    rack._last_dist = (hp and sp) and math.sqrt((hp.x-sp.x)^2 + (hp.y-sp.y)^2 + (hp.z-sp.z)^2) or -1
    -- [RACK-DIAG IM MONITOR-DUMP 2026-07-21, "Sliderack steht an, alles geht, aber er registriert
    -- meine Controllerbewegung nicht"] Reine VEROEFFENTLICHUNG der ohnehin gefuehrten Werte -- kein Log,
    -- keine Verhaltensaenderung. #Monitor.lua schreibt sie in den Dump, damit im Fall der Faelle
    -- ablesbar ist, WORAN der Grab scheitert: armed=false -> der linke Grip wurde nie losgelassen
    -- (Scharfmachen fehlt); dist > grab_dist -> Hand zu weit vom Slide-Joint.
    _G.__re4_rack_dbg = string.format("needs=%s armed=%s grab=%s grip=%s dist=%.3f (max %.3f) wid=%s",
        tostring(rack.needs), tostring(rack.armed), tostring(rack.grab_active), tostring(grip),
        tonumber(rack._last_dist) or -1, tonumber(CFG.rack_grab_dist) or 0, tostring(wep.wid))
    if not (sj and hp and sp) then return end

    if not rack.grab_active then
        -- [RACK-LOCK] Kein Grab solange eine Patrone in der Hand ist (mag_hand.active) ODER gerade in die
        -- Kammer gleitet (mag_insert.active). Bei NICHT-Shotgun zusaetzlich 2s nach Ammo-Input sperren.
        -- Shotgun NICHT nach-sperren -> direkt nach Shell-Einlegen soll man pumpen koennen.
        -- [FIX] mag_insert.active war frueher NICHT mitgesperrt: beim leeren Nachladen (rack.needs=true)
        -- greift die linke Hand direkt am Slide waehrend der Insert-Animation -> die Rack-Geste startete
        -- MITTEN im Insert und zog den Slide auf back_z ("viel zu weit hinten"). Der _ammo_input_t-Lock
        -- greift erst NACH Insert-Ende (zu spaet). Waehrend eine Patrone in die Kammer gleitet, darf nie
        -- gerackt werden -> beide Phasen sperren.
        if mag_hand.active or mag_insert.active then
            rack.armed = false; rack._pump_ref_z = nil; return
        end
        if not is_shotgun(wep.wid) and rack._ammo_input_t and (os.clock() - rack._ammo_input_t) < 0.2 then
            rack.armed = false; return
        end

        -- [RIOT GUN KEIN PUMP 2026-08-10] Die Riot Gun ist semi-auto: ihr Rack sitzt
        -- SEITLICH (_08), gepumpt wird bei ihr gar nicht mehr. Der Pull-to-Pump am
        -- Vorderschaft war der letzte Rest aus der Pump-Gun-Zeit und die eigentliche
        -- Ursache des Stagger-Deadlocks -- er greift jetzt nur noch bei der W-870 (4100).
        -- Striker (4102) und Skull Shaker (6001) sind ohnehin ueber ROTARY_CYCLE /
        -- BREAK_ACTION schon weiter oben ausgestiegen.
        if is_shotgun(wep.wid) and not rack.empty_reload and not NO_RELOAD_CYCLE[wep.wid] then
            -- [SHOTGUN PULL-TO-PUMP] Nahtlos aus der Two-Hand-Haltung: KEIN Grip-Release noetig. Bedingung:
            -- Grip gehalten + Hand am Schaft (Naehe) + echter RUECKWAERTS-Zug. Erst der Zug startet den Pump
            -- (vorher bleibt Two-Hand-IK aktiv). Zug GUN-RELATIV gemessen (Hand-Z im Slide-Frame) -> immun
            -- gegen Waffen-Bewegung/-Drehung. Referenz = vorderster Punkt; Pull = Rueckweichung davon.
            if grip and rack._last_dist >= 0 and rack._last_dist <= CFG.rack_grab_dist then
                local srot = sc(sj, "get_Rotation")
                local rel  = srot and safe(function() return srot:conjugate() * Vector3f.new(hp.x - sp.x, hp.y - sp.y, hp.z - sp.z) end)
                local cz   = rel and rel.z or 0
                -- [RE9_PUMP 2026-08-12] Referenz = ABSTAND DER BEIDEN HAENDE (1:1 aus dem
                -- RE9-Mod, re9_vr_weapons.lua: `along = initial_hand_dist - dist_now`).
                -- Warum das alles loest, woran die bisherigen Ansaetze gescheitert sind:
                --   * kein Waffenbezug -> keine Rueckkopplung mit PUMP_NO_Z/X in motion.lua
                --     (dort wird cache.rh_world jeden Frame korrigiert -> frac alternierte)
                --   * kein Weltanker -> Laufen zaehlt nicht mit, beide Haende wandern gemeinsam
                --     (fester Anker liess `pull` auf -2.066 laufen, der Pump war tot)
                --   * richtungslos von Haus aus -> die Controller-Richtung ist egal
                -- Selbstnachziehend: solange nicht gezogen wurde und der Abstand WAECHST, wird die
                -- Referenz nachgefuehrt -- man kann also in Ruhe an den Schaft greifen.
                local rhp = rawget(_G, "__vr_rh_world") or rawget(_G, "__vr_unified_rh_pos")
                local dist_now = rhp and math.sqrt((hp.x-rhp.x)^2 + (hp.y-rhp.y)^2 + (hp.z-rhp.z)^2) or nil
                if dist_now and not rack._pump_init_dist then rack._pump_init_dist = dist_now end
                local pull = 0
                if dist_now and rack._pump_init_dist then
                    pull = rack._pump_init_dist - dist_now
                    if pull < 0 then rack._pump_init_dist = dist_now; pull = 0 end
                end
                if pull > (CFG.pump_start_pull or 0.04) then
                    rack.grab_active = true; rack.armed = false; rack.pulled = false; rack.pushed = false; rack.frac = 0
                    rack.gx, rack.gy, rack.gz = hp.x, hp.y, hp.z   -- (nur noch fuer Nicht-Shotgun-Pfade)
                    rack.g_relz = cz   -- [PUMP] gun-relativer Z-Anker (nur noch Fallback, s. unten)
                    -- [RE9_PUMP] Handabstand JETZT als Nullpunkt einfrieren + Maximum zuruecksetzen.
                    rack._pump_init_dist = dist_now
                    rack._pump_max = 0
                    -- [PUMP_AXIS 2026-08-12] Zugachse EINMAL in WELTkoordinaten einfrieren.
                    -- Messung (#pump_probe): die Hand laeuft sauber (dHand 0.4-2 cm/Frame, Position
                    -- monoton), aber `frac` alterniert im Frame-Takt (0.39/0.20/0.59/0.37/0.78/0.53...)
                    -- -> es springt NICHT die Hand, sondern das Bezugssystem. Grund: der Zug wurde
                    -- gegen den LIVE gelesenen Slide-Joint gerechnet, und PUMP_NO_Z in motion.lua
                    -- korrigiert waehrenddessen jeden Frame die Waffenposition (cache.rh_world).
                    -- Zwei Stellen regeln dieselbe Groesse gegeneinander -- dasselbe Muster wie beim
                    -- Doppelregler am Z-Clamp und beim alternierenden Scope-FOV.
                    -- Mit fester Weltachse ist die Messung immun gegen alles, was Engine/motion mit
                    -- der Waffe machen: gemessen wird nur noch der Weg der HAND entlang dieser Achse.
                    -- (Die Waffe selbst wird dadurch NICHT eingefroren -- nur die Bezugsrichtung.)
                    rack._pump_ref_z = nil
                    rack_haptic(0.25, 0.03)
                    rack.pump_off = nil
                    local shp = rawget(_G, "__vr_support_hand_world_pos")
                    if shp then
                        local d = Vector3f.new(shp.x - sp.x, shp.y - sp.y, shp.z - sp.z)
                        local inv = srot and safe(function() return srot:conjugate() end)
                        rack.pump_off = (inv and safe(function() return inv * d end)) or d
                    end
                end
            else
                rack._pump_ref_z = nil   -- Hand weg vom Schaft / Grip los -> Referenz reset
            end
            return
        end

        -- Nicht-Shotgun ODER Shotgun-Empty-Reload (_08-Lade-Slide): Release-arm + Proximity-Grab,
        -- pistolen-artig (ziehen -> loslassen -> schnappt vor -> chambert). Grip einmal loslassen = scharf.
        if not grip then rack.armed = true; return end   -- Grip erst loslassen -> scharf
        if not rack.armed then return end
        if (rack._last_dist >= 0) and (rack._last_dist <= CFG.rack_grab_dist) then
            rack.grab_active = true
            rack.armed = false
            rack.pulled = false
            rack.pushed = false
            rack.frac = 0
            -- [ROHER CONTROLLER 2026-07-20] Anker aus der UNGEDOCKTEN Hand (__vr_lh_ctrl_world,
            -- von motion VOR dem IK publiziert). hp ist die GEDOCKTE Hand -- sobald der Rack-Dock
            -- greift, ist sie unsere eigene Vorgabe und der Zug wuerde sich selbst messen (Zug 0 /
            -- snappy). NUR Anker und Zug -- Naehe-Pruefung, _last_dist und Pose-Distanz bleiben auf hp.
            local hpr = rawget(_G, "__vr_lh_ctrl_world") or hp
            rack.gx, rack.gy, rack.gz = hpr.x, hpr.y, hpr.z
            -- [LAUFEN 2026-08-12] Zweiter Anker: die WAFFENHAND. Der Zug wurde bisher gegen einen festen
            -- WELTpunkt gemessen -- beim Gehen/Drehen wandern beide Haende mit dem Koerper, und diese
            -- Fortbewegung landete komplett im Zug. Deshalb wird unten die Verschiebung der rechten Hand
            -- abgezogen: gemessen wird nur noch die Bewegung der Ziehhand GEGEN die Waffenhand. Genau das
            -- hat den Pump geloest (RE9-Modell, Handabstand) -- hier mit erhaltener Zugrichtung, damit die
            -- eingestellten travel-Werte unveraendert gelten. Rueckbau: _G.__re4_rack_relative = false
            local rhr = rawget(_G, "__vr_rh_ctrl_raw") or rawget(_G, "__vr_rh_world") or rawget(_G, "__vr_unified_rh_pos")
            rack.rgx, rack.rgy, rack.rgz = rhr and rhr.x or nil, rhr and rhr.y or nil, rhr and rhr.z or nil
            -- [PUMP] gun-relativer Z-Anker (fuer Shotgun/_08 frac-Zug; Pistolen ignorieren ihn)
            local _srot = sc(sj, "get_Rotation")
            local _rel = _srot and safe(function() return _srot:conjugate() * Vector3f.new(hp.x - sp.x, hp.y - sp.y, hp.z - sp.z) end)
            rack.g_relz = _rel and _rel.z or nil
            -- [RACK_POSE_ANGLE 2026-07-31] Aus welcher Richtung ist die Hand gekommen? Dieselbe
            -- slide-lokale Umrechnung wie oben (_rel), nur der Winkel in der XZ-Ebene:
            -- 0 Grad = genau von HINTEN (hinter dem Slide, -Z) -> globale Rack-Pose
            -- 90 Grad = genau von der SEITE (reines X) -> Seiten-Pose (MAGRack)
            -- Seitenneutral ueber |x| (links wie rechts), Hoehe (Y) bewusst ignoriert. EINMAL beim
            -- Greifen bestimmt und bis zum Loslassen gehalten -- sonst springt die Pose waehrend des Zugs.
            -- Nur Pistolen werten das aus (s. apply_rack_hand_pose), alle anderen Gattungen unveraendert.
            -- [POSE2_OFFSETS] Im Einstellmodus (dock_tune) NICHT neu bestimmen -- sonst reisst der
            -- naechste Greifvorgang die Vorschau-Auswahl aus der UI wieder weg.
            rack.pose_side = rack.dock_tune and rack.pose_side or false
            -- [RACK_BACK_ONLY 2026-08-05] Die Killer7 (4501) hat nur EINE Art zu racken:
            -- Winkel gar nicht erst auswerten -> pose_side bleibt false -> immer Pose 1
            -- (von hinten) samt erstem Offset-Satz. Weitere Waffen einfach mit
            -- "and wep.wid ~= <id>" anhaengen (kein neues local moeglich: die Datei steht am
            -- 200-Local-Limit von Lua, s. [[Notiz]]).
            -- Alle anderen Magazinpistolen behalten die Zwei-Posen-Weiche unveraendert.
            if _rel and not rack.dock_tune and wep.wid ~= 4501 then
                local _at2 = math.atan2 or math.atan
                local _ang = math.deg(_at2(math.abs(_rel.x or 0), -(_rel.z or 0)))
                rack.pose_side = _ang >= (tonumber(CFG.rack_pose_side_deg) or 45)
                rack._pose_ang = _ang   -- nur Anzeige im UI
            end
            rack_haptic(0.25, 0.03)
            rack.pump_off = nil
        end
        return
    end

    -- gegriffen + Grip gehalten -> Slide folgt dem RUECKWAERTS-Zug entlang der Gun-Achse.
    if grip then
        local sp_pose = rack_slide_pose()   -- [EMPTY-RELOAD SLIDE] _08-Travel im Empty-Reload, sonst _01
        local travel = math.max(math.abs(sp_pose.back_z - sp_pose.park_z), 0.005)   -- Slide-Travel = Zieh-Weg (1:1)
        local pull
        if is_shotgun(wep.wid) and rack._pump_init_dist then
            -- [RE9_PUMP 2026-08-12] Zug = Annaeherung der beiden HAENDE (RE9-Modell).
            -- Kein Waffen-, Welt- oder Achsenbezug -> immun gegen PUMP_NO_Z/X, gegen Laufen und
            -- gegen die Controller-Richtung. Siehe ausfuehrliche Begruendung am Grab-Start.
            local rhp = rawget(_G, "__vr_rh_world") or rawget(_G, "__vr_unified_rh_pos")
            local hpr = rawget(_G, "__vr_lh_ctrl_world") or hp
            if rhp then
                local dist_now = math.sqrt((hpr.x-rhp.x)^2 + (hpr.y-rhp.y)^2 + (hpr.z-rhp.z)^2)
                pull = rack._pump_init_dist - dist_now
                -- Solange nicht durchgezogen: waechst der Abstand, zieht die Referenz nach
                -- (verhindert, dass ein Nachgreifen den Zyklus blockiert).
                if not rack.pulled and pull < 0 then
                    rack._pump_init_dist = dist_now; pull = 0; rack._pump_max = 0
                end
                if pull < 0 then pull = 0 end
                if (rack._pump_max or 0) < pull then rack._pump_max = pull end
            else
                pull = 0
            end
        elseif is_shotgun(wep.wid) then
            -- FALLBACK (kein Handabstand messbar): wie frueher gun-relativ.
            -- gun-relativ gegen den Slide-Frame.
            local srot = sc(sj, "get_Rotation")
            local spos = sc(sj, "get_Position")
            local cz
            if srot and spos then
                local rel = safe(function() return srot:conjugate() * Vector3f.new(hp.x-spos.x, hp.y-spos.y, hp.z-spos.z) end)
                cz = rel and rel.z
            end
            if cz and rack.g_relz then
                pull = rack.g_relz - cz   -- nach hinten gezogen -> cz sinkt -> pull steigt
                if pull < 0 then pull = 0 end
            else
                pull = 0
            end
        else
            -- Nicht-Shotgun: Welt-Projektion der Controller-Verschiebung auf die Slide-Rueckwaerts-Achse.
            -- [ROHER CONTROLLER] gegen denselben ungedockten Bezug wie der Anker (s. oben).
            local hpr = rawget(_G, "__vr_lh_ctrl_world") or hp
            local px, py, pz = hpr.x - rack.gx, hpr.y - rack.gy, hpr.z - rack.gz
            -- [LAUFEN 2026-08-12] Bis hierher ist das eine WELT-Verschiebung: beim Gehen oder Drehen
            -- wandert die Ziehhand mit dem Koerper, und diese Fortbewegung landete komplett im Zug --
            -- deshalb ging der Slide nur im Stand. Also die Bewegung der WAFFENHAND abziehen; uebrig
            -- bleibt die Bewegung der Ziehhand GEGEN die Waffe, genau wie beim Pump (RE9-Handabstand),
            -- nur mit erhaltener Richtung, damit die eingestellten travel-Werte weiter gelten.
            -- Rueckbau: _G.__re4_rack_relative = false
            if rack.rgx and rawget(_G, "__re4_rack_relative") ~= false then
                local rhn = rawget(_G, "__vr_rh_ctrl_raw") or rawget(_G, "__vr_rh_world") or rawget(_G, "__vr_unified_rh_pos")
                if rhn then
                    px = px - (rhn.x - rack.rgx)
                    py = py - (rhn.y - rack.rgy)
                    pz = pz - (rhn.z - rack.rgz)
                end
            end
            local srot = sc(sj, "get_Rotation")
            local bd = srot and safe(function() return srot * Vector3f.new(0, 0, -1) end)
            if bd then
                local bl = math.sqrt(bd.x*bd.x + bd.y*bd.y + bd.z*bd.z)
                if bl > 1e-6 then bd = Vector3f.new(bd.x/bl, bd.y/bl, bd.z/bl) end
                pull = px*bd.x + py*bd.y + pz*bd.z
                if pull < 0 then pull = 0 end
            else
                pull = math.sqrt(px*px + py*py + pz*pz)
            end
        end
        local f = pull / travel
        rack.frac = (f > 1.0) and 1.0 or f
        if rack.frac >= 1.0 and not rack.pulled then
            rack.pulled = true
            -- [SND] Slide-Sound beim Zurueckziehen (voll hinten). Pistolen: 2. Sound (vor) beim
            -- Loslassen/Snap. Shotgun: 2. Sound beim Nach-vorn-Schieben (siehe unten, RE9-Modell).
            play_weapon_sound(snd("slide_back"))
            if is_shotgun(wep.wid) then queue_haptic(0.95, 0.07) end   -- [SHOTGUN PUMP] Haptik HIN (delaybar, 2. Puls beim Vorschieben)
        end
        -- [SHOTGUN PUMP] RE9-Pump-Modell (re9_vr_weapons.lua): nach vollem Zug wieder nach VORN
        -- geschoben (frac faellt zurueck) -> HER-Sound + Zyklus fertig, OHNE Loslassen. Nur Shotgun;
        -- Pistolen behalten Snap-on-Release (unten). frac<=0.15 = praktisch wieder vorn/gechambert.
        -- [RE9_PUMP 2026-08-12] Vorschieben RELATIV zum weitesten Punkt (RE9: return_dist =
        -- pull_max - along), nicht mehr gegen einen Fixpunkt. Vorher galt `frac <= 0.15`, was bei
        -- 8,7 cm Travel nur ~1,3 cm Toleranz bedeutete -- richtungslos gemessen praktisch nicht
        -- treffbar: im Log blieb frac auf 1.000 stehen und `pushed` kam nie.
        local _back = (rack._pump_max or 0) - (pull or 0)
        local _back_need = math.max(0.03, travel * (tonumber(CFG.pump_push_frac) or 0.5))
        if is_shotgun(wep.wid) and not rack.empty_reload and rack.pulled and not rack.pushed
           and (_back >= _back_need or rack.frac <= 0.15) then
            rack.pushed = true
            play_weapon_sound(snd("slide_back"))    -- HER: nach vorne gepumpt
            queue_haptic(0.95, 0.07)                 -- [SHOTGUN PUMP] Haptik ZURUECK (delaybar)
            if rack.needs then clear_rack() end   -- noetiger Pump: chambern + Empty-Block weg
            -- [SHOTGUN PUMP] Grab BEHALTEN (clear_rack setzt es false) + Zyklus zuruecksetzen ->
            -- ohne Loslassen direkt weiterpumpen (auch nahtlos vom noetigen in den Spass-Pump).
            rack.grab_active = true
            rack.pulled = false
            rack.pushed = false
            rack._pump_max = 0           -- [RE9_PUMP] naechster Zug misst frisch
            rack._pump_init_dist = nil
        end
        return
    end

    -- Grip losgelassen
    -- [RACKEV] Entscheidender Moment: war voll gezogen? wo steht der Slide? wird rest_z gesnappt?
    -- [log entfernt]
    if rack.pulled and not rack.pushed then
        -- voll gezogen, aber NICHT nach vorn gepumpt (Shotgun) bzw. Pistole losgelassen -> Snap nach
        -- vorn = HER-Sound. (Shotgun: hat er schon nach vorn gepumpt, lief der Sound oben + grab endete.)
        clear_rack()
        rack_haptic(0.95, 0.07)
        play_weapon_sound(snd("slide_back"))   -- [SND] Slide schnellt nach vorn
    else
        rack.grab_active = false; rack.frac = 0; rack.pulled = false; rack.pushed = false; rack.armed = true
    end
end

-- [ROTARY_CYCLE] Striker-Drehschalter: nach jeder geladenen Shell (rack.needs) am Schalter (Left Grip)
-- den Left Trigger druecken -> joint_01 dreht ~rz Grad (Animation hin+zurueck), Hand folgt (Dock+Pose),
-- am Peak clear_rack (chambert + rack.needs weg). Eine Drehung pro Shell. Nur ROTARY_CYCLE-Waffen.
local function update_rotary_cycle()
    if not ROTARY_CYCLE[wep.wid] then
        _G.__vr_block_two_hand = false; rotary._grip_latched = false; rotary._prev_grip = false; return
    end
    if rotary.preview then rack.grab_active = true; _G.__vr_block_two_hand = true; return end   -- UI-Tuning: Hand am Schalter, Two-Hand blocken
    local grip = left_grip_down()
    local trig = left_trigger_down()
    -- [SWITCH-GRIP-LATCH] Eine Grip-FLANKE waehrend ein Cycle noetig ist (rack.needs) gehoert dem
    -- Schalter -> diese Grip-Haltung blockt Two-Hand-IK (Schalter+Vordergriff liegen zu nah). Erst
    -- Loslassen + erneut Greifen erlaubt Two-Hand. Nur diese Waffe (Flag wird sonst nie true gesetzt).
    if grip and not rotary._prev_grip and rack.needs then rotary._grip_latched = true end
    if not grip then rotary._grip_latched = false end
    rotary._prev_grip = grip
    _G.__vr_block_two_hand = rotary._grip_latched == true
    -- Distanz Hand -> Drehschalter (joint_01) fuer den Greif-Gate (rohe un-gedockte Hand)
    local r = rotary_cfg(wep.wid)
    local hp = rawget(_G, "__vr_lh_world") or rawget(_G, "__vr_unified_lh_pos") or rawget(_G, "__vr_lh_joint_pos")
    local sp = wep.slide_joint and sc(wep.slide_joint, "get_Position")
    rotary._last_dist = (hp and sp) and math.sqrt((hp.x-sp.x)^2 + (hp.y-sp.y)^2 + (hp.z-sp.z)^2) or -1
    local near = (rotary._last_dist >= 0) and (rotary._last_dist <= (r.grab_dist or 0.15))
    local at_switch = (rack.needs == true) and grip and near   -- am Schalter = Cycle noetig + Grip + nah genug
    if rotary.dir == 0 then rotary.prog = 0.0 end   -- [IDLE] keine Drehung aktiv -> prog auf 0 (sonst haengt es vom UI-Preview auf 1.0 fest)
    -- Trigger-FLANKE am Schalter -> eine Drehung starten (nur wenn gerade keine laeuft)
    if at_switch and trig and not rotary._prev_trig and rotary.dir == 0 and rotary.prog <= 0.0001 then
        rotary.dir = 1
        rack_haptic(0.30, 0.04)
        play_weapon_sound(snd("cycle"))   -- [STRIKER] Drehschalter-Dreh-Sound beim Start der Drehung
    end
    rotary._prev_trig = trig
    local SPD = r.lerp or 0.06   -- [STRIKER] Dreh-Lerp (per UI tunebar)
    if rotary.dir == 1 then
        rotary.prog = math.min(1.0, rotary.prog + SPD)
        if rotary.prog >= 1.0 then
            if rotary.pending then rotary.do_load(); rotary.pending = false end   -- [ROTARY_DEFER] Ammo (Ratio) kommt ERST hier, am Dreh-Peak -- nicht beim Insert
            clear_rack()                       -- Cycle fertig: chambert + rack.needs weg (Position-Snaps fuer ROTARY gegated)
            rotary.dir = -1                    -- zurueckdrehen (Dreh-Sound lief schon beim Start)
        end
    elseif rotary.dir == -1 then
        rotary.prog = math.max(0.0, rotary.prog - SPD)
        if rotary.prog <= 0.0 then rotary.dir = 0 end
    end
    -- Hand am Schalter halten (Dock + StrikerReload-Pose) solange am Schalter ODER waehrend der Drehung
    rack.grab_active = (at_switch or rotary.dir ~= 0) == true
    -- [ROTARY_LEXIT 2026-07-24] Fallende Flanke des Schalter-Docks -> denselben weichen Links-Ausfade
    -- zum Controller triggern wie beim Mag-Push (motion __re4_reload_lexit_apply, Slider "Snap-Ausfaden s").
    if rotary._was_grab and not rack.grab_active then _G.__re4_reload_lexit_t = os.clock() end
    rotary._was_grab = rack.grab_active
end

-- [BREAK_ACTION] Skull Shaker Klapphebel (joint_02): RIGHT-B togglet auf/zu (gelerped). KEINE linke Hand.
-- Auf -> Reload (Shells holbar) + Fire blockiert. Voll zu -> Cock/Chamber (clear_rack). prog 0=zu..1=auf
-- treibt die Rotation in apply_slide_pass. Lerp = rotary_cfg.lerp.
local function update_break_action()
    if not BREAK_ACTION[wep.wid] then
        _G.__vr_break_open = false; break_st.open = false; break_st._was_open = false; return
    end
    if break_st.preview then _G.__vr_break_open = (break_st.prog > 0.15); return end   -- UI-Tuning: Slider treibt prog
    -- [SKULL_SPIN_ENTFERNT 2026-07-31] Hier hielt die Spin-Vorschau die Klappe optisch offen.
    -- Spin und Vorschau sind ausgebaut -> die Klappe geht wieder ausschliesslich per RIGHT-B auf.
    local r = rotary_cfg(wep.wid)
    -- RIGHT-B-FLANKE togglet auf/zu
    local b = right_b_down()
    if b and not break_st._prev_b then
        break_st.open = not break_st.open
        play_weapon_sound(snd("break_open"))   -- Klapp-Sound (auf/zu)
    end
    break_st._prev_b = b
    -- prog Richtung Ziel lerpen (auf=1, zu=0)
    local target = break_st.open and 1.0 or 0.0
    local SPD = r.lerp or 0.06
    if break_st.prog < target then
        break_st.prog = math.min(target, break_st.prog + SPD)
    elseif break_st.prog > target then
        break_st.prog = math.max(target, break_st.prog - SPD)
        if break_st.prog <= 0.0 and break_st._was_open then
            break_st._was_open = false
            if rack.needs then clear_rack() end                  -- voll zu = cocken/chambern
        end
    end
    if break_st.open then break_st._was_open = true end
    _G.__vr_break_open = (break_st.open or break_st.prog > 0.15) == true   -- offen -> Fire-Block + Shell-Insert
end

-- [BREAK_PUMP_SND] Nach JEDEM Schuss der Break-Action (wp6001) ein FESTES Cock-Fenster forcen:
-- __vr_pump_anim_active = true fuer SKULLSHAKER_PUMP_FORCE_DUR s, __vr_pump_anim_progress linear 0..1
-- darueber. Treibt Dreh-Loop (motion skullshaker_cock_spin), Cock-Pose (shakerloop) + die 2x Rack-Sounds.
-- WARUM geforct statt nativen "PumpAction"-Node lesen: die Engine spielt den Node nach einmal-leer-
-- geschossen + Reload NICHT mehr -> der Loop fiel aus. Geforct ueber die Schuss-Flanke (__vr_shot_seq,
-- crosshair-Hook) kommt er IMMER und in exakt gleicher Laenge.
local BREAK_PUMP_SND_ID = 3370013164
local SKULLSHAKER_PUMP_FORCE_DUR = 0.55   -- Cock-Fenster-Laenge (s): Dreh-Dauer (1 Umdrehung) + Sound-Sequenz
local _pumpsnd = { t0 = nil, prev_seq = nil, first_at = nil, second_at = nil }
local function update_break_pump_sound()
    if not BREAK_ACTION[wep.wid] then
        _pumpsnd.t0 = nil; _pumpsnd.prev_seq = nil; _pumpsnd.first_at = nil; _pumpsnd.second_at = nil
        _G.__vr_pump_anim_active = false; _G.__vr_pump_anim_progress = nil; return
    end
    local now = os.clock()
    -- Schuss-Flanke (globaler crosshair-Hook). Init ohne Trigger (prev_seq nil -> nur merken, nicht
    -- feuern -> kein Geister-Cock beim Equip, wenn der globale seq schon hochgezaehlt war).
    local seq = tonumber(rawget(_G, "__vr_shot_seq")) or 0
    if _pumpsnd.prev_seq == nil then
        _pumpsnd.prev_seq = seq
    elseif seq > _pumpsnd.prev_seq then
        _pumpsnd.prev_seq  = seq
        _pumpsnd.t0        = now          -- neues Cock-Fenster (Dreh + Pose); retriggert auch ein laufendes
        _pumpsnd.first_at  = now + 0.1    -- Sound-Sequenz pro Schuss neu planen (auch bei Ueberlappung)
        _pumpsnd.second_at = nil
    end
    -- Fenster-Status -> Dreh-Loop + Cock-Pose (motion liest beide Globals)
    if _pumpsnd.t0 and (now - _pumpsnd.t0) < SKULLSHAKER_PUMP_FORCE_DUR then
        _G.__vr_pump_anim_active   = true
        _G.__vr_pump_anim_progress = (now - _pumpsnd.t0) / SKULLSHAKER_PUMP_FORCE_DUR
    else
        _pumpsnd.t0 = nil
        _G.__vr_pump_anim_active   = false
        _G.__vr_pump_anim_progress = nil
    end
    -- 2x Rack-Sound: 1. = 0.1s nach Schuss, 2. = 0.42s nach dem 1.
    if _pumpsnd.first_at and now >= _pumpsnd.first_at then
        play_weapon_sound(BREAK_PUMP_SND_ID)
        _pumpsnd.first_at  = nil
        _pumpsnd.second_at = now + 0.42
    end
    if _pumpsnd.second_at and now >= _pumpsnd.second_at then
        play_weapon_sound(BREAK_PUMP_SND_ID)
        _pumpsnd.second_at = nil
    end
end

-- IK-Dock: solange gegriffen, die linke Hand ans Slide-Welt-Ziel ziehen.
-- re4_vr_arm_chain.lua liest __vr_slide_hand_world_pos und loest die Arm-Kette darauf
-- (nur aktiv wenn gesetzt -> kein Einfluss aufs normale Arm-IK). Konzept aus RE9 SD.
-- [DOCK_LERP] Blend EINMAL pro Frame rampen (NICHT in publish_dock -> das laeuft
-- 5x/Frame: on_frame + 4 Slide-Override-Paesse, wuerde 5x hochzaehlen). Ziel = 1 wenn
-- gegriffen/Tuning, sonst 0. Publiziert eine smoothstep-Kurve fuer weiches In/Out.
local function update_dock_blend()
    local want = ((rack.grab_active or rack.dock_tune) and wep.slide_joint) and 1.0 or 0.0
    local b = rack.dock_blend or 0
    if b < want then b = math.min(b + DOCK_BLEND_SPEED, want)
    elseif b > want then
        -- [PUMP-REDOCK] Shotguns: Slide-Dock beim LOESEN schneller runterrampen. Der SLIDE_RACK-
        -- PRIORITY-Block (motion) haelt die Support-Hand undocked solange slide_dock_blend > 0.001 ->
        -- je schneller der nach dem Pump faellt, desto frueher re-dockt die Hand an den Vordergriff
        -- = kein kurzes Abheben beim Dauerfeuer+Pumpen. NUR Shotguns; Pistolen-Slide unberuehrt.
        local down = is_shotgun(wep.wid) and 0.30 or DOCK_BLEND_SPEED
        -- [ROTARY_LEXIT 2026-07-24] Drehschalter-Waffen (Striker) NICHT schnell wegrampen -> hart
        -- loesen; den weichen Weg zum Controller macht der Lexit-Fade in motion (wie beim Mag-Push).
        if ROTARY_CYCLE[wep.wid] then down = 1.0 end
        b = math.max(b - down, want)
    end
    rack.dock_blend = b
    _G.__vr_slide_dock_blend_factor = b * b * (3.0 - 2.0 * b)   -- smoothstep
end

local function publish_dock()
    -- [DOCK_LERP] Gate auf dock_blend (nicht grab_active): solange der Blend > 0 ist
    -- (auch beim Weg-Lerp nach dem Loslassen) bleibt das Slide-Ziel gesetzt, damit die
    -- Konsumenten (arm_chain Position, motion Rotation) sauber zurueck-interpolieren.
    local rj = rack_joint()   -- [EMPTY-RELOAD SLIDE] _08 im Empty-Reload-Modus, sonst _01
    if (rack.dock_blend or 0) > 0.001 and rj then
        local p = sc(rj, "get_Position")
        local r = sc(rj, "get_Rotation")
        local sd = rack_slide_pose()
        if is_shotgun(wep.wid) and rack.pump_off and not ROTARY_CYCLE[wep.wid] then   -- [ROTARY] Drehschalter-Waffen nie den Pump-Zweig -> immer Dock-/Rot-Offsets unten
            -- [SHOTGUN PUMP] Hand = Slide-Pos + (Slide-Rot * gemerkter lokaler Offset) -> wandert mit
            -- dem Pump, Position behaelt den Support-Offset. Rotation = live Support-Hand-Rotation.
            if p and r then
                local off = safe(function() return r * rack.pump_off end)
                if off then p = Vector3f.new(p.x + off.x, p.y + off.y, p.z + off.z) end
            end
            local srot = rawget(_G, "__vr_support_hand_world_rot")
            if srot then r = srot end
        else
            -- [POSE2_OFFSETS 2026-07-31] Welcher der beiden Offset-Saetze gilt? Bei Pistolen
            -- entscheidet das dieselbe Weiche wie bei der Finger-Pose (rack.pose_side, EINMAL beim
            -- Greifen bestimmt): seitliche Annaeherung -> MAG-Rack-Pose mit IHREN Offsets (sdock_*/
            -- srack_*), sonst die Default-Pose mit ihren (dock_*/rack_*). Alle anderen Gattungen und
            -- der _08-Empty-Reload-Slide nehmen unveraendert nur den ersten Satz.
            local dX, dY, dZ = sd.dock_x, sd.dock_y, sd.dock_z
            local rX, rY, rZ = sd.rack_rx, sd.rack_ry, sd.rack_rz
            if rack.pose_side and not rack.empty_reload and wep.wid and category_of(wep.wid) == "pistols" then
                dX, dY, dZ = sd.sdock_x or dX, sd.sdock_y or dY, sd.sdock_z or dZ
                rX, rY, rZ = sd.srack_rx or rX, sd.srack_ry or rY, sd.srack_rz or rZ
            end
            if p and r and (dX ~= 0 or dY ~= 0 or dZ ~= 0) then
                local off = safe(function() return r * Vector3f.new(dX, dY, dZ) end)
                if off then p = Vector3f.new(p.x + off.x, p.y + off.y, p.z + off.z) end
            end
            -- Rotations-Offset auf die Slide-Rotation -> feste, tunebare Hand-Pose (Grad).
            if r and (rX ~= 0 or rY ~= 0 or rZ ~= 0) then
                r = safe(function() return (r * quat_from_euler(rX, rY, rZ)):normalized() end) or r
            end
        end
        _G.__vr_slide_hand_world_pos = p
        _G.__vr_slide_hand_world_rot = r
    else
        -- [PUSH_DOCK 2026-07-21] BEVOR geleert wird: laeuft gerade das Mag-Nachdruecken, gehoert das
        -- Dock dem Magazin. Wichtig, weil publish_dock 5x pro Frame laeuft (on_frame + 4 Slide-Passes)
        -- -- ein blindes Leeren hier hat das Push-Dock jedes Mal wieder abgeraeumt.
        if not rack.publish_push_dock() then
            -- [DOCK-RELEASE 2026-07-24] Fallende Flanke des Push-Docks -> EINMAL einen Zeitstempel
            -- setzen; die linke Hand fadet dann in motion.lua (__re4_reload_lexit_apply) weich von der
            -- Magazin-Pose zum Controller, exakt wie der KS4-Austritt. Nur links. Globals hier weiter HART
            -- leeren (Original) -- das Ausfaden macht allein motion.
            if rack.pushdock_was_active then
                _G.__re4_reload_lexit_t = os.clock()
                rack.pushdock_was_active = false
            end
            _G.__vr_slide_hand_world_pos = nil
            _G.__vr_slide_hand_world_rot = nil
            _G.__vr_slide_dock_blend_factor = 0
        end
    end
end

-- [PUSH_DOCK 2026-07-21, "die Hand soll wie beim Sliderack feststehen und der Waffe folgen"]
-- Waehrend die Hand das Mag nachdrueckt, exakt derselbe Weg wie beim Slide-Grab: ein IK-Dock-Ziel
-- veroeffentlichen (arm_chain zieht die linke Hand dorthin, motion nimmt die Rotation). Bezug ist der
-- MAGAZIN-Joint, also klebt die Hand am Mag und folgt der Waffe -- unabhaengig vom linken Controller.
-- Offsets (Lage relativ zum Mag) und Blend kommen aus reload_adv (M.push / M.push_blend).
-- Laeuft NUR, wenn das Slide-Dock nicht selbst aktiv ist -> die beiden koennen sich nie streiten.
-- [200-LOCAL-LIMIT] bewusst als Feld der bestehenden rack-Tabelle, NICHT als neues Top-Level-Local.
function rack.publish_push_dock()
    local ms = rawget(_G, "__re4_reload_mag_slide")
    if not (ms and type(ms.push_blend) == "function" and wep.mag_joint) then return false end
    if (rack.dock_blend or 0) > 0.001 then return false end   -- Slide-Dock hat Vorrang
    local b = tonumber(ms.push_blend()) or 0.0
    if b <= 0.001 then return false end
    local p = sc(wep.mag_joint, "get_Position")
    local r = sc(wep.mag_joint, "get_Rotation")
    if not (p and r) then return false end
    local o = ms.push or {}
    -- [ADA] Positions-Offset ueber den Getter holen: bei Ada steckt ihr Zusatz-Offset (kleinere Haende)
    -- schon drin, bei Leon sind es exakt seine px/py/pz. Rotation bleibt fuer beide dieselbe.
    local ox, oy, oz = 0, 0, 0
    if type(ms.push_pos) == "function" then
        -- [PUSH-Y PRO WAFFE 2026-07-25] wep.wid MITGEBEN: der Y-Zusatz pro Waffe darf nicht am globalen
        -- __re4_reload_ui_wid haengen -- publish_dock laeuft mehrfach pro Frame, auch in Passes, in denen
        -- ein anderes Reload-Script das Global schon umgeschrieben hat.
        local ok2, a, b2, c2 = pcall(ms.push_pos, wep.wid)
        if ok2 then ox, oy, oz = a or 0, b2 or 0, c2 or 0 end
    else
        ox, oy, oz = o.px or 0, o.py or 0, o.pz or 0
    end
    if ox ~= 0 or oy ~= 0 or oz ~= 0 then
        local off = safe(function() return r * Vector3f.new(ox, oy, oz) end)
        if off then p = Vector3f.new(p.x + off.x, p.y + off.y, p.z + off.z) end
    end
    if (o.rx or 0) ~= 0 or (o.ry or 0) ~= 0 or (o.rz or 0) ~= 0 then
        r = safe(function() return (r * quat_from_euler(o.rx or 0, o.ry or 0, o.rz or 0)):normalized() end) or r
    end
    _G.__vr_slide_hand_world_pos    = p
    _G.__vr_slide_hand_world_rot    = r
    _G.__vr_slide_dock_blend_factor = b
    -- [DOCK-RELEASE 2026-07-24] Push-Dock AKTIV -> fuer die Exit-Flanke (unten) markieren und einen
    -- evtl. laufenden Links-Ausfade abbrechen (Dock hat Vorrang, wie beim KS4-Wiedereintritt).
    rack.pushdock_was_active = true
    _G.__re4_reload_lexit_t = nil
    return true
end

-- Slide-Pose treiben solange gerackt werden muss:
-- ungegriffen -> Park (leer, leicht hinten); gegriffen -> Park..Voll-Hinten per frac
local function apply_slide_park()
    if not CFG.enabled then return end
    if TOP_LOADER[wep.wid] then return end   -- [TOP_LOADER] kein Slide-Modell (Chamber via apply_chamber)
    if ROTARY_CYCLE[wep.wid] or BREAK_ACTION[wep.wid] then return end   -- [ROTARY/BREAK] slide-Joint ist Rotation/Hebel, kein Z-Slide
    -- [SHOTGUN_PUMP_SUPPRESS] Die Shotgun-Engine racked das Pump-Joint _01 nach JEDEM Schuss selbst
    -- (AfterShoot-Node: _01 faehrt rest->back->rest). Das wollen wir MANUELL machen -> den nativen
    -- Pump unterdruecken, indem wir _01 jeden Post-Anim-Pass hart auf rest_z (vorn/gechambert) halten.
    -- AUSNAHME: waehrend unseres eigenen manuellen Racks (grab_active) ODER UI-Vorschau (tuning) ->
    -- dann faellt es durch zur normalen Logik unten (frac-getriebener Zug).
    if is_shotgun(wep.wid) then
        if rack.empty_reload then
            -- [EMPTY-RELOAD SLIDE] Pump-Joint _01 IMMER vorn (rest) halten (wird in diesem Modus nicht
            -- benutzt); der _08-Lade-Slide wird unten generisch via rack_joint/rack_slide_pose getrieben.
            local j1 = wep.slide_joint
            if j1 then
                local cur = sc(j1, "get_LocalPosition")
                if cur then
                    local sp1 = slide_pose(wep.wid or 0)
                    pcall(function() j1:call("set_LocalPosition", Vector3f.new(cur.x, cur.y, sp1.rest_z)) end)
                end
            end
            -- fall through -> generischer Block treibt _08
        elseif not (rack.grab_active or rack.tuning) then
            local sj = wep.slide_joint
            if sj then
                local cur = sc(sj, "get_LocalPosition")
                if cur then
                    local sp = slide_pose(wep.wid or 0)
                    pcall(function() sj:call("set_LocalPosition", Vector3f.new(cur.x, cur.y, sp.rest_z)) end)
                end
            end
            return
        end
        -- manuelles Rack laeuft -> weiter unten der grab_active-Zweig (frac-Zug)
    end
    -- [SLIDE-IDLE-HOLD 2026-07-24] GENERELLER FIX (alle Standard-Pistolen): wird ein Rack durch
    -- Stagger/Event unterbrochen, bleibt _chambered_hold AUS -> apply_slide_park returnt hier und die
    -- ENGINE haelt den Slide in Hold-Open HINTER back_z, obwohl die Waffe geladen+feuerbereit ist
    -- (Slide-Z-Diag 00:55:17: slz=0.056 < back_z=0.060, loaded=7, needs_rack=0, grab=0). Fix: den
    -- rest_z-Halt am ECHTEN Ammo-Stand festmachen statt am fragilen _chambered_hold-Flag. NICHT bei
    -- ENGINE_CLOSES_SLIDE (LE5/TMP schliessen selbst). getCurrentGunAmmo = frisch, kein Cache.
    local chambered_idle = false
    if not ENGINE_CLOSES_SLIDE[wep.wid]
       and not (rack.needs or rack.grab_active or rack.tuning or mag_out or rack.empty
                or rack.empty_when_dropped or rack.empty_reload) then
        local _pe = get_pe()
        local _ld = _pe and tonumber(safe(function() return _pe:call("getCurrentGunAmmo") end))
        if _ld and _ld > 0 then chambered_idle = true end
    end
    -- Slide treiben solange: 0 Ammo / Mag draussen / Rack noetig / gerackt / Vorschau / Nach-Rack-Halt / feuerbereit-idle.
    if not (rack.empty or mag_out or rack.needs or rack.grab_active or rack.tuning or rack._chambered_hold or chambered_idle) then return end
    local sj = rack_joint(); if not sj then return end   -- [EMPTY-RELOAD SLIDE] _08 im Empty-Reload, sonst _01
    local cur = sc(sj, "get_LocalPosition"); if not cur then return end   -- x/y bleiben, nur Z setzen
    local sp = rack_slide_pose()
    local z
    if rack.tuning then
        z = sp.park_z + (sp.back_z - sp.park_z) * rack.tune_frac
    elseif rack.grab_active then
        z = sp.park_z + (sp.back_z - sp.park_z) * rack.frac   -- 1:1 gezogen: Park -> Voll-Hinten
    elseif rack._chambered_hold then
        if ENGINE_CLOSES_SLIDE[wep.wid] then return end   -- [ENGINE_CLOSES_SLIDE] Schliessen macht die Engine
        z = sp.rest_z   -- NACH dem Rack zu halten (Engine spielt die Kammer-Schliess-Anim nicht;
                        -- bis zum naechsten Schuss forcen, dann uebernimmt die Engine-Anim)
    elseif chambered_idle then
        z = sp.rest_z   -- [SLIDE-IDLE-HOLD] geladen+feuerbereit -> Slide vorne/gechambert halten
                        -- (robuster Nach-Rack-Halt am echten Ammo-Stand; deckt unterbrochenen Rack ab)
    elseif rack.needs or rack.empty_when_dropped or rack.empty then
        z = sp.park_z   -- 0 Ammo ODER leer nach Drop -> Slide auf MITTEL bis gerackt
    else
        if ENGINE_CLOSES_SLIDE[wep.wid] then return end   -- [ENGINE_CLOSES_SLIDE] taktischer Mag-Out: Engine schliesst
        z = sp.rest_z   -- taktischer Mag-Out (noch Patronen) -> Slide vorne/gechambert
    end
    pcall(function() sj:call("set_LocalPosition", Vector3f.new(cur.x, cur.y, z)) end)
end

-- Rack-Handpose (Finger) der LINKEN Hand. Greift bei echtem Rack (Hand am Slide angedockt)
-- UND im Einstell-Toggle (dock_tune), damit man beim Posen die ganze Hand sieht.
-- NICHT waehrend das Mag getragen/eingesetzt wird (Konflikt mit der Mag-Halte-Pose).
-- Wir wenden die Pose NICHT selbst an (unsere Passes sind PRE-Anim -> Engine ueberschreibt).
-- Stattdessen den Pose-NAMEN publizieren; motion.lua wendet ihn im POST-ANIM-Pass an
-- (exakt wie die Flashlight-Knife-Pose) -> ueberschreibt die Engine-Finger-Animation.
local function apply_rack_hand_pose()
    -- [POSE PER WAFFE] eigene Rack-Pose dieser Waffe bevorzugen, sonst globale (Pistolen unveraendert).
    -- [EMPTY-RELOAD SLIDE] Im _08-Modus eigene Hand-Pose (RiotSLide) statt der Pump-Pose (SGPUMP).
    -- [RACK_POSE_ANGLE 2026-07-31] Pistolen haben ZWEI Posen (Annaeherung von hinten vs. seitlich,
    -- beim Greifen bestimmt: rack.pose_side). Fuer Pistolen wird RACK_POSE[wid] deshalb NICHT mehr
    -- gelesen -- die Alt-Eintraege 4000/4003 = "MAGRack" sind hier wirkungslos, MAGRack kommt jetzt
    -- ueber den Seiten-Zweig und gilt fuer ALLE Pistolen. Andere Gattungen unveraendert.
    local _rp
    if rack.empty_reload and wep.wid and RACK_POSE_EMPTY[wep.wid] then
        _rp = RACK_POSE_EMPTY[wep.wid]
    elseif wep.wid and category_of(wep.wid) == "pistols" then
        _rp = rack.pose_side and CFG.rack_pose_side or CFG.rack_pose
    else
        _rp = (wep.wid and RACK_POSE[wep.wid]) or CFG.rack_pose
    end
    if not CFG.enabled or not _rp or _rp == "" or mag_hand.active or mag_insert.active then
        _G.__vr_rack_hand_pose = nil; return
    end
    local want = false
    if rack.dock_tune then
        want = true
    elseif rack.needs then
        -- [POSE ERST AM RACK 2026-07-19] Frueher genuegte NAEHE (rack._last_dist <= rack_grab_dist)
        -- -> die Hand nahm die Rack-Pose schon ein, sobald sie in die Naehe der Waffe kam. Jetzt nur
        -- noch, wenn wirklich gegriffen wird (grab_active). dock_tune (UI-Vorschau) bleibt unberuehrt.
        want = rack.grab_active
    end
    _G.__vr_rack_hand_pose = want and _rp or nil
end

-- [FINDER] Waffen-Transform fuer den Finder, UNABHAENGIG von wep.tf: bei einer noch nicht
-- konfigurierten Waffe (z.B. Red9, deren Platzhalter-Mag-Joint nicht aufloest) bleibt wep.tf
-- nil -> sonst koennte man die Joints gar nicht durchsuchen. Hier direkt per find_weapon holen.
local function finder_tf()
    if wep.tf then return wep.tf end
    local wid = get_equip_wid(); if not wid or wid == 0 then return nil end
    local _, tf = find_weapon(wid)
    return tf
end

-- [FINDER] alle Joint-Namen der aktuell equippten Waffe (fuer den Index-Slider).
-- 1) echte Joint-Liste der Transform (get_Joints). 2) Fallback: generische Pistolen-Joint-
-- Namen abklopfen (getJointByName ist erprobt). Per wid gecacht.
local _jn_cache = { wid = nil, names = nil }
local function weapon_joint_names()
    local wid = wep.wid or get_equip_wid()
    if _jn_cache.wid == wid and _jn_cache.names and #_jn_cache.names > 0 then return _jn_cache.names end
    local tf = finder_tf(); if not tf then return {} end
    local names, seen = {}, {}
    local arr = safe(function() return tf:call("get_Joints") end)
    if arr then
        local n = safe(function() return arr:get_size() end)
        if n and n > 0 then
            for i = 0, n - 1 do
                local jt = safe(function() return arr:get_element(i) end)
                local nm = jt and safe(function() return jt:call("get_Name") end)
                if nm and nm ~= "" and not seen[nm] then seen[nm] = true; names[#names+1] = nm end
            end
        end
    end
    if #names == 0 then
        local cand = { "root" }
        for i = 0, 30 do cand[#cand+1] = string.format("_%02d", i) end
        for _, nm in ipairs({ "_100","_101","_102","_103","_104","_105" }) do cand[#cand+1] = nm end
        for _, nm in ipairs(cand) do
            if not seen[nm] and sc(tf, "getJointByName", nm) then seen[nm] = true; names[#names+1] = nm end
        end
    end
    if #names > 0 then _jn_cache = { wid = wid, names = names } end
    return names
end

-- Joint-Finder: verschiebt den gewaehlten Joint um einen festen Offset von seiner
-- (einmal erfassten) Ruhepose -> man sieht welcher Joint der Slide ist.
local function apply_finder()
    if not finder.active then return end
    local tf = finder_tf(); if not tf then return end
    local j = sc(tf, "getJointByName", finder.name); if not j then return end
    if finder.base_name ~= finder.name or not finder.base then
        local lp = sc(j, "get_LocalPosition"); if not lp then return end
        finder.base = { x = lp.x, y = lp.y, z = lp.z }
        finder.base_name = finder.name
    end
    pcall(function() j:call("set_LocalPosition",
        Vector3f.new(finder.base.x + finder.x, finder.base.y + finder.y, finder.base.z + finder.z)) end)
end

-- [CHAMBER] Top-Loader (Red9): rechter B togglet den Chamber auf/zu.
local function toggle_chamber()
    chamber.open = not chamber.open
    rlog("chamber " .. (chamber.open and "AUF" or "ZU"))
    play_weapon_sound(snd("chamber"))   -- [SND] Chamber auf UND zu = derselbe Sound
end

-- [SHELL_EJECT] Shell-Joint _04 in die Chamber-Startposition setzen (Offset von der Ruhepose).
-- SCHRITT 1: nur Preview (Flug kommt spaeter). Im Override-Pass halten gegen die Engine.
local function apply_shell_eject()
    if not is_shotgun(wep.wid) then return end
    if not (wep.mag_joint and wep.rest_lp) then return end
    if not (shell_eject.preview or shell_eject.flying) then return end   -- sonst Engine kontrolliert _04
    local s = shell_eject_cfg(wep.wid)
    local rl = wep.rest_lp
    local px, py, pz = rl.x + s.sx, rl.y + s.sy, rl.z + s.sz
    local spin_deg = 0.0
    if shell_eject.flying then
        local t = shell_eject.t or 0
        px = px + (s.vx or 0) * t
        py = py + (s.vy or 0) * t - 0.5 * (s.grav or 4.0) * t * t   -- Bogen: hoch dann fallen
        pz = pz + (s.vz or 0) * t
        spin_deg = (s.spin or 0) * t                                -- Taumeln
    end
    pcall(function() wep.mag_joint:call("set_LocalPosition", Vector3f.new(px, py, pz)) end)
    if wep.rest_lr then
        local base = Quaternion.new(wep.rest_lr.w, wep.rest_lr.x, wep.rest_lr.y, wep.rest_lr.z)
        local rot = safe(function() return (base * quat_from_euler(s.srx + spin_deg, s.sry, s.srz)):normalized() end)
        if rot then pcall(function() wep.mag_joint:call("set_LocalRotation", rot) end) end
    end
end

-- [SHELL_EJECT] Flug-State 1x/Frame fortschreiben (NICHT in apply_shell_eject -> das laeuft 4x/Frame).
-- Trigger: Pump voll zurueckgezogen (rack.pulled-Flanke = Chamber offen) -> Shell fliegt aus dem Chamber.
local function update_shell_eject()
    if not is_shotgun(wep.wid) then shell_eject.flying = false; shell_eject._prev_pulled = false; return end
    local now = os.clock()
    local dt = now - (shell_eject.last_clock or now)
    shell_eject.last_clock = now
    if dt < 0 or dt > 0.1 then dt = 0.016 end   -- Sprung-Schutz (Pause/Ladebildschirm)
    -- Trigger: rack.pulled steigende Flanke (Chamber offen), nicht im Tuning-Preview.
    -- [DIAG temp] Zustand beim Pump-Grab mitloggen (throttled) -> warum kein Gimmick?
    -- [log entfernt]
    -- [GIMMICK] Pump passiert jetzt NUR noch im rack.needs-Fenster (nach Schuss/Reload). Auf der
    -- rack.pulled-Flanke (Chamber offen) fliegt die Shell kosmetisch raus, solange geladen (pump_one_out).
    if rack.pulled and not shell_eject._prev_pulled and not shell_eject.preview then
        if pump_one_out() then
            shell_eject.flying = true
            shell_eject.t = 0.0
        end
    end
    shell_eject._prev_pulled = rack.pulled
    if shell_eject.flying then
        shell_eject.t = (shell_eject.t or 0) + dt
        local s = shell_eject_cfg(wep.wid)
        if shell_eject.t >= (s.dur or 0.7) then shell_eject.flying = false end   -- Flug vorbei -> Engine chambert frisch
    end
end

-- [CHAMBER] Chamber-Joint in den Override-Paessen halten: offen -> Ruhe+z, zu -> nicht forcen
-- (Engine-Pose stellt zu). Ruhepose wird einmal im geschlossenen Zustand erfasst.
local function apply_chamber()
    local cc = CHAMBER[wep.wid]; if not cc then return end
    local tf = wep.tf; if not tf then return end
    local j = sc(tf, "getJointByName", cc.joint); if not j then return end
    -- Ruhepose (zu) NUR im voll geschlossenen Zustand erfassen (blend == 0).
    if chamber.blend <= 0.0001 and (chamber.base_joint ~= cc.joint or not chamber.base) then
        local lp = sc(j, "get_LocalPosition")
        if lp then chamber.base = { x = lp.x, y = lp.y, z = lp.z }; chamber.base_joint = cc.joint end
    end
    -- Solange irgendwie offen (auch beim Zufahren) den interpolierten Z-Offset schreiben.
    if chamber.base and chamber.blend > 0.0001 then
        local t = chamber.blend
        local s = t * t * (3 - 2 * t)   -- smoothstep
        pcall(function() j:call("set_LocalPosition",
            Vector3f.new(chamber.base.x, chamber.base.y, chamber.base.z + cc.z * s)) end)
    end
end

-- Kompakter State-Export fuer das EXTERNE Diag-Script (re4_vr_reload_diag.lua).
-- Ein Tabellen-Write pro Frame, KEIN Logging im Produktiv-Pfad.

-- Zentraler Reset des KOMPLETTEN Reload-States. Bei JEDEM Waffenwechsel / Unequip /
-- Enemy-Grab (Spiel holstert die Waffe zwangsweise) aufgerufen -> kein haengender
-- Zwischenstand (halber Drop/Insert, Mag-in-Hand, stale Block/needs_rack). Macht den
-- Ablauf grab- und save-load-fest: nach jedem Wechsel wird der State frisch hergeleitet.
local function reset_reload_state()
    stop_mag_drop()
    drop.active       = false
    mag_hand.active   = false
    mag_insert.active = false
    mag_insert.settle = false   -- [INSERT-PUNCH] Nachfedern mit abbrechen
    mag_tune.active   = false
    rack.grab_active  = false
    rack.armed        = false
    rack.frac         = 0
    rack.pulled       = false
    rack.needs        = false
    rack.has_mag      = false
    rack.empty_when_dropped = false
    rack._zeroed_by_us = false  -- [ACCESSOR-FOLGE] Merker darf einen Wechsel nicht ueberleben
    rack.empty_reload = false   -- [EMPTY-RELOAD SLIDE] Modus bei Wechsel/Reset aus
    rotary.prog = 0.0; rotary.dir = 0; rotary._prev_trig = false; rotary.pending = false   -- [ROTARY_CYCLE] Dreh-State (+ deferred Ammo) bei Wechsel/Reset aus
    rotary._grip_latched = false; rotary._prev_grip = false; _G.__vr_block_two_hand = false   -- [SWITCH-GRIP-LATCH] aus
    break_st.prog = 0.0; break_st.open = false; break_st._was_open = false; break_st._prev_b = false; _G.__vr_break_open = false   -- [BREAK_ACTION] Hebel zu + ready nach Wechsel
    rack._pump_ref_z = nil
    rack.pump_off    = nil   -- [PUMP_OFF STALE] sonst behaelt eine vorher gepumpte Shotgun (W-870/Riot) ihren
                             -- lokalen Pump-Offset; bei der naechsten Shotgun (Striker = is_shotgun!) nimmt
                             -- publish_dock faelschlich den Pump-Zweig und ignoriert deren Dock-/Rot-Offsets.
    -- [GOLDEN RULE] Schuss-Sequenz-Baseline beim Wechsel NEU syncen, sonst triggert die Shotgun-
    -- Schuss-Erkennung (seq > _prev_shot_seq) faelschlich rack.needs=true auf der frisch gezogenen
    -- Waffe (globaler __vr_shot_seq ist von anderen Waffen schon hochgezaehlt) -> Waffe waere NICHT
    -- ready (erst nach Pump feuerbar). nil -> naechster Frame setzt _prev_shot_seq = aktueller seq.
    rack._prev_shot_seq = nil
    rack._chambered_hold = false   -- [CHAMBER_HOLD] bei Wechsel/Reset aus
    chamber.open = false; chamber.blend = 0.0; chamber.base = nil; chamber.base_joint = nil   -- [TOP_LOADER] Chamber zu + Ruhepose neu erfassen
    -- mag_out NICHT hier nullen -> per-Waffe persistent (Wiederherstellung im on_frame-Branch)
    _G.__vr_block_fire_when_empty   = false
    _G.__re4_bf_who = "re4_vr_reload.lua:2939"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
    _G.__vr_needs_rack              = false
    _G.__vr_shotgun_pump_active     = false   -- [PUMP_NO_Z] nie ueber einen Waffenwechsel haengen lassen
    _G.__vr_rack_block_left_knife   = false
    _G.__vr_manual_reload_consume_b = false
    _G.__vr_slide_hand_world_pos    = nil
    _G.__vr_slide_hand_world_rot    = nil
    _G.__vr_slide_dock_blend_factor = 0      -- [DOCK_LERP] harter Reset: kein Weg-Lerp
    rack.dock_blend                 = 0
    _G.__vr_rack_hand_pose          = nil
    -- [WI_CACHE] gecachtes Live-Item ist nach Waffenwechsel stale (alte Instanz gleicher
    -- WeaponId -> getReloadableCount=0). Invalidieren -> get_live_weapon_item resolved frisch
    -- (Inventory-Row mit Reserve), bis der naechste Schuss/Reload es neu cached.
    _G.__re4_live_wi = nil
end
local _last_handled_wid = nil
local _red9_prev_reloading = false   -- [RED9_NATIVE_AMMO] Flanke der nativen Reload-Anim (motion publiziert __vr_red9_reloading)

-- [SHELL_PART] Forward-Decl: on_frame (unten) ruft sg_update_parts, definiert wird es weiter unten
-- (zusammen mit sg_force_shell_parts, das apply_slide_pass nutzt). [[feedback-lua-forward-decl]]
local sg_update_parts, sg_force_shell_parts
local update_shell_spawn   -- [SHELL_SPAWN] forward-decl (im on_frame aufgerufen, weiter unten definiert)

re.on_frame(function()
    -- [LET-GO] update_native_reload_pause (Motion-Pause bei nativem Reload) ENTFERNT aus reload:
    -- die Hand-Trennung waehrend der Reload-Anim gehoert in den Killswitch, nicht hierher.
    if not CFG.enabled then
        _managed = false
        _G.__vr_manual_reload_consume_b = false
        _G.__vr_block_fire_when_empty   = false
        _G.__re4_bf_who = "re4_vr_reload.lua:2967"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
        _G.__vr_rack_block_left_knife   = false
        _G.__vr_rack_hand_pose          = nil
        _G.__re4_reload_grab_empty      = false
        _G.__vr_motion_paused           = false
        return
    end
    refresh_weapon()
    -- Waffenwechsel / Unequip / Enemy-Grab -> kompletten Reload-State sauber resetten
    local hwid = handled()
    if hwid ~= _last_handled_wid then
        -- [MAG_OUT] Draussen-Zustand pro Waffe merken/wiederherstellen -> Drop ueberlebt
        -- den Waffenwechsel. Der Mesh-Hold (apply_mag_out_hidden) haelt das Mag dann
        -- jeden Frame aus der Kammer -> B bleibt korrekt blockiert (Mag ist ja draussen).
        -- [STAGGER_MAGOUT 2026-07-24 "staggered mit der Blacktail, Ammo drin, trotzdem Dry-Fire"]
        -- Waehrend eines Staggers/Enemy-Grabs meldet die Engine KEINE Waffe -> hwid wird nil -> unten
        -- Wechsel-Zweig + Return. reset_reload_state raeumt Drop/Mag-in-Hand/Insert UND rack.needs ab,
        -- aber mag_out kam aus dem Store zurueck -> "Mag draussen" ohne jeden laufenden Flow. Da das
        -- Heilen ueber loaded>0 bewusst entfernt ist (s.u. Z.~3390), blieb der Feuer-Block aus Z.~2405
        -- fuer immer stehen = Dry-Fire mit voller Waffe (gamebreaking).
        -- REGEL: A -> B (echter Waffenwechsel) stellt den Store wie bisher wieder her.
        -- A -> nil -> A (Waffe war nur kurz weg) NICHT: die Engine hat in der Abwesenheit selbst
        -- gechambert/nachgeladen, also gilt das Mag als drin. rack._gone_wid statt neuem Local
        -- (reload.lua steht am Lua-200-Local-Limit; reset_reload_state fasst das Feld nicht an).
        -- [RACK-ZWANG UEBERLEBT DEN WECHSEL 2026-07-24 "bei Leon muss das auch so rein"]
        -- Nachgezogen aus re4_vr_reload4_dlc.lua (dort seit 2026-07-20 bewaehrt): reset_reload_state
        -- loescht rack.needs, und das feuert bei JEDEM kurzen Waffenwechsel -- Granate, Messer,
        -- Enterhaken, Stagger. Danach war der Rack-Zwang weg und man konnte ohne Slide-Rack
        -- weiterfeuern. Gleiches Muster wie mag_out: pro Waffe merken, beim Zurueckwechseln
        -- wiederherstellen. Geloescht wird der Zwang weiterhin NUR durch ein echtes Rack (clear_rack).
        -- [MAG_RETAIN PRO WAFFE 2026-07-25] mag_retained war als EINZIGER dieser Notiz global:
        -- Punisher mit 10 Rest droppen -> auf eine andere Pistole wechseln -> die kassiert beim naechsten
        -- Nachladen ueber target=min(cap,mag_retained+reserve) die 10 Runden gratis und nullt den Zaehler
        -- -> zurueck auf der Punisher ist der Notiz leer und die 10 sind weg (Dry-Fire). Deshalb
        -- jetzt genau wie mag_out/rack.needs pro Waffe sichern und wiederherstellen.
        if _last_handled_wid then
            mag_out_store[_last_handled_wid] = mag_out
            rack._needs_store = rack._needs_store or {}   -- [200-LIMIT] Feld statt neuem Local
            rack._needs_store[_last_handled_wid] = rack.needs
            rack._retained_store = rack._retained_store or {}   -- [MAG_RETAIN PRO WAFFE] ebenfalls Feld (200-Limit)
            rack._retained_store[_last_handled_wid] = mag_retained
            if hwid == nil then rack._gone_wid = _last_handled_wid end   -- Waffe nur WEG, kein Wechsel
        end
        reset_reload_state()
        if hwid and rack._gone_wid == hwid then
            mag_out = false                  -- dieselbe Waffe kommt nach der Abwesenheit zurueck
            mag_out_store[hwid] = false      -- Store mitloeschen -> spaeterer Wechsel holt ihn nicht zurueck
            -- Mag gilt als drin (Engine hat selbst gechambert) -> der Notiz ist damit abgegolten,
            -- sonst wuerde derselbe Rest beim naechsten Nachladen ein zweites Mal gutgeschrieben.
            mag_retained = 0
            if rack._retained_store then rack._retained_store[hwid] = nil end
            rack._gone_wid = nil
        else
            mag_out = (hwid and mag_out_store[hwid]) or false
            mag_retained = (hwid and rack._retained_store and rack._retained_store[hwid]) or 0
            if hwid then rack._gone_wid = nil end
        end
        rack.needs = (hwid and rack._needs_store and rack._needs_store[hwid]) or false
        _last_handled_wid = hwid
    end
    -- [SAVE_LOAD] Gleiche Waffe, aber neu instanziiert (Save-Load/Respawn) -> stale
    -- Lua-State (mag_out/mag_hand/rack/...) wie bei Reset Scripts neu initialisieren,
    -- sonst klemmt z.B. der Holster-Grab. Engine haelt nach dem Laden das Mag in der
    -- Kammer -> mag_out = false. Nur wenn verwaltete Waffe.
    if _weapon_reacquired then
        _weapon_reacquired = false
        if hwid then
            reset_reload_state()
            mag_out = false
            -- [REGAL LEEREN 2026-07-24] Nach Save-Load/Respawn gilt NICHTS von vorher: die Engine
            -- haelt alle Mags in der Kammer und chambert selbst. Darum BEIDE Notiz-Regale komplett
            -- leeren (nicht nur die aktuelle Waffe) -- sonst holt ein spaeterer Waffenwechsel einen alten
            -- mag_out oder rack.needs zurueck und die Waffe verlangt ein Rack, das laengst erledigt war.
            -- Bei "Reset Scripts" passiert das ohnehin von selbst: beide Regale sind Datei-Locals und
            -- werden beim Neuladen frisch angelegt.
            mag_out_store = {}
            rack._needs_store = nil
            rack._gone_wid    = nil
            -- [MAG_RETAIN PRO WAFFE] drittes Regal mitleeren: nach Save-Load/Respawn haelt die Engine
            -- alle Mags in der Kammer, ein alter Rest-Notiz wuerde sonst Gratis-Munition schenken.
            rack._retained_store = nil
            mag_retained = 0
        end
    end
    -- [LET-GO] Waffe NICHT verwaltet ("Manual Pistol Reload" AUS, keine Pistole, kein Joint):
    -- reload laesst KOMPLETT los -> alle Globals frei, KEINE Writes, KEINE Pausen. Nativer
    -- Reload + Ammo-Zaehlung liegen voll bei der Engine. Hand-Trennung waehrend der Reload-Anim
    -- macht der Killswitch (separat), NICHT dieses Script.
    if not hwid then
        _managed = false
        _G.__vr_manual_reload_consume_b = false
        _G.__vr_block_fire_when_empty   = false
        _G.__re4_bf_who = "re4_vr_reload.lua:3006"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
        _G.__vr_needs_rack              = false
        _G.__vr_rack_block_left_knife   = false
        _G.__vr_rack_hand_pose          = nil
        _G.__re4_reload_grab_empty      = false
        _G.__vr_motion_paused           = false
        return
    end
    _managed = true

    -- [RED9_NATIVE_AMMO] Der native Reload spielt nur die Anim, verteilt aber KEINE Ammo. Daher beim
    -- Ende der Anim (__vr_red9_reloading true->false, von motion.lua) einmal VERLUSTSICHER auffuellen:
    -- nur die Luecke bis Cap, Reserve entsprechend abziehen. Hat die Engine doch transferiert (loaded
    -- schon == target), ist used=0 -> kein Doppel.
    do
        local reloading = rawget(_G, "__vr_red9_reloading") == true
        if (hwid == 4002) and _red9_prev_reloading and (not reloading) and CFG.reload_ammo then
            local wi = get_live_weapon_item()
            if wi then
                local cap     = tonumber(safe(function() return wi:call("get_CurrentAmmoMax") end)) or 0
                local ammo_id = safe(function() return wi:call("get_CurrentAmmo") end)
                local pe2     = get_pe(); local inv2 = pe2 and sc(pe2, "get_InventoryController")
                local function gun_ammo() return pe2 and tonumber(safe(function() return pe2:call("getCurrentGunAmmo") end)) or nil end
                local function read_rsv() return (inv2 and ammo_id) and (tonumber(safe(function() return _G.__re4_item_count_sum(inv2, ammo_id) end)) or 0) or 0 end
                local r_b4    = read_rsv()
                local b4      = gun_ammo() or (tonumber(safe(function() return wi:call("get_CurrentAmmoCount") end)) or 0)
                local target  = math.min(cap, b4 + r_b4)
                local used    = math.max(0, target - b4)
                if used > 0 then
                    -- [RUNTIME-FIX 0/0] Engine-Reload primaer (greift aufs ECHTE Gun-Item), write_dword nur Fallback.
                    local et = get_equip_type_main()
                    -- [CRASH-HARDEN 2026-07-14] nur wenn der Red9 (4002) noch live equippt ist (sonst null-Gun-Item -> AV).
                    if et and inv2 and (get_equip_wid() or -1) == 4002 then _G.__re4_load_and_book(inv2, et, used, false) end
                    local af = gun_ammo() or b4
                    if af <= b4 then pcall(function() wi:write_dword(0x44, target) end); af = gun_ammo() or target end
                    local gained = math.max(0, af - b4)
                    if gained > 0 and inv2 and ammo_id and read_rsv() >= r_b4 then
                        _G.__re4_safe_reduce(inv2, ammo_id, gained)
                    end
                end
            end
        end
        _red9_prev_reloading = reloading
    end

    capture_mag_rest()   -- Chamber-Ruhepose laufend erfassen (fuer den Insert)
    check_mag_insert_proximity()   -- Mag nah an der Waffe -> auto-insert
    update_shell_spawn()   -- [SHELL_SPAWN] getragene Huelse als eigene Instanz (Waffen ohne statischen Shell-Part)
    -- Mag-Joint ans Advanced-Modul reichen (fuer Live-Preview im UI)
    if _G.__re4_reload_mag_slide then _G.__re4_reload_mag_slide.current_mag_joint = wep.mag_joint end
    -- Self-Heal: haengender/alter Drop bei Equip-Wechsel ODER ungueltigem Joint
    -- (z.B. nach Save-Load wird der Mag-Joint neu erzeugt) sauber abraeumen
    if drop.active and not drop.use_module then
        local bad = (drop.joint ~= wep.mag_joint)
            or not safe(function() return drop.joint:get_Valid() end)
        if bad then stop_mag_drop() end
    end

    -- verwaltete Pistole? -> Binding soll den rechten B abfangen (kein nativer Reload)
    -- [RED9_NATIVE] Top-Loader (Red9): KEIN B-Intercept -> der native Reload feuert (Engine spielt die
    -- Top-Fill-Anim inkl. Clip). Waehrend dieser Anim schaltet motion.lua sich selbst aus (native_reload_active).
    local on = (hwid ~= nil) and not TOP_LOADER[hwid]
    _G.__vr_manual_reload_consume_b = on

    -- [MAG_OUT] KEIN Heilen ueber loaded>0! "Mag physisch draussen" darf NICHT an den
    -- Ammo-Zaehler gekoppelt sein: mit Infinite Ammo / Engine-Refill ist loaded nach dem
    -- Drop sofort wieder >0 -> das hat mag_out faelschlich geloest und den Holster-Grab
    -- blockiert. mag_out wird NUR durch physisches Wieder-Einsetzen (Insert-Complete) ODER
    -- Waffenwechsel/Reset geloescht. [[feedback-no-cached-state-for-critical-gates]]

    -- [MAG_OUT] UI auf 0 HALTEN solange das Mag draussen ist (Anzeige, gegen Engine-Re-Sync).
    -- Der echte Stand ist in mag_retained gemerkt -> beim Insert kommt er zurueck. NICHT
    -- waehrend des Inserts (mag_insert.active), sonst wuerde der Fuell-Wert sofort genullt.
    if mag_out and not mag_insert.active then
        local wi = get_live_weapon_item()
        if wi and (sc(wi, "get_CurrentAmmoCount") or 0) > 0 then
            _G.__re4_carry_capture(wi, "re4_vr_reload.lua:4905", nil)   -- [MAG-REST] merken, bevor genullt wird
            pcall(function() wi:write_dword(0x44, 0) end)
        end
    end

    -- [MAG_AVAIL] Fuer den Holster: gibt es ueberhaupt etwas zu greifen? (gemerkter Mag-Stand
    -- ODER Reserve > 0). Mag draussen + NICHTS da -> Holster sperren + Leer-Haptik.
    do
        if is_shotgun(wep.wid) then
            -- [SHOTGUN] Shell-Holster Sperr-Puls wenn Reserve leer ODER Roehre voll (loaded>=cap).
            -- Sonst offen (greifbar). Wie der Grab selbst (set_mag_in_hand) es auch blockt.
            local wifull = get_live_weapon_item()
            local lo = wifull and (sc(wifull, "get_CurrentAmmoCount") or 0) or 0
            local cp = wifull and (sc(wifull, "get_CurrentAmmoMax") or 0) or 0
            local full = (cp > 0 and lo >= cp)
            -- [STRIKER] Cycle ausstehend (rack.needs) -> Holster gesperrt (erst drehen). grab_empty=true
            -- -> der Holster-Modul feuert den gewohnten Sperr-Haptic-Puls. Nur ROTARY_CYCLE-Waffen.
            local rotary_block = (ROTARY_CYCLE[wep.wid] == true) and (rack.needs == true)
            -- [SKULL SHAKER] Holster gesperrt (Sperr-Puls) solange der Hebel ZU ist (erst aufklappen).
            local break_block = (BREAK_ACTION[wep.wid] == true) and not (rawget(_G, "__vr_break_open") == true)
            _G.__re4_reload_grab_empty = (not mag_hand.active and not mag_insert.active and (current_reserve() <= 0 or full or rotary_block or break_block))
        elseif TOP_LOADER[wep.wid] then
            -- [TOP_LOADER] Red9: kein mag_out-Konzept -> Verfuegbarkeit haengt NUR an der Reserve.
            -- Holster immer greifbar wenn Reserve>0, sonst Leer-Puls (grab_empty=true).
            _G.__re4_reload_grab_empty = (not mag_hand.active and not mag_insert.active and current_reserve() <= 0)
        else
            local avail = false
            if mag_out and not mag_hand.active and not mag_insert.active then
                local reserve = 0
                local wi = get_live_weapon_item()
                local ammo_id = wi and safe(function() return wi:call("get_CurrentAmmo") end)
                local pe2 = get_pe(); local inv2 = pe2 and sc(pe2, "get_InventoryController")
                if inv2 and ammo_id then
                    reserve = tonumber(safe(function() return _G.__re4_item_count_sum(inv2, ammo_id) end)) or 0
                end
                avail = ((mag_retained or 0) + reserve) > 0
            end
            _G.__re4_reload_grab_empty = (mag_out and not mag_hand.active and not mag_insert.active and not avail)
        end
    end

    -- Slide-Rack: Empty-Block pflegen + Rack-Geste auswerten
    update_rack_state()
    -- [STAGGER_HEAL 2026-07-19] Stagger-Ende (fallende Flanke von __re4_damage_active, vom killswitch) ->
    -- Slide zu + fire-ready wie ein Waffenwechsel. Behebt "Slide steckt hinten, wenn man mitten im Slide-Rack
    -- staggered wird". clear_rack snappt slide_joint auf rest_z + setzt _chambered_hold (haelt bis 1. Schuss).
    -- Nur bei Slide-Waffe (wep.slide_joint). Kein neuer Local (rack._prev_damage = Feld) -- reload.lua am 200-Limit.
    -- [SLIDE-STAGGER-GUARD 2026-07-20] Wie bei der Red9: wird man mitten im Slide-Rack getroffen,
    -- bleibt der Slide irgendwo hinten stehen (Engine zieht ihn auf ihren eigenen Wert). Der Killswitch
    -- stempelt das Damage-ENDE (__re4_damage_end_t) -- diese Funktion laeuft waehrend des Staggers gar
    -- nicht (Engine meldet keine Waffe), kann die Flanke also nicht selbst sehen.
    -- WICHTIG (Lehre vom 2026-07-20): NICHT clear_rack rufen! Das chambert intern die Waffe und nimmt
    -- den Rack-Zwang mit -> man koennte nach dem Nachladen ohne Rack weiterfeuern. Hier NUR die
    -- Slide-Position korrigieren, und auch das nur, wenn KEIN Rack aussteht (steht eins an, gehoert der
    -- Slide korrekt nach hinten). Genau einmal pro Stempel.
    do
        local det = tonumber(rawget(_G, "__re4_damage_end_t"))
        if det and rack._heal_done_t ~= det and (os.clock() - det) < 3.0
           and not rack.needs and not rack.empty and not mag_out and wep.slide_joint then
            rack._heal_done_t = det
            local sp  = slide_pose(wep.wid or 0)
            local cur = sc(wep.slide_joint, "get_LocalPosition")
            if sp and cur then
                pcall(function() wep.slide_joint:call("set_LocalPosition", Vector3f.new(cur.x, cur.y, sp.rest_z)) end)
            end
            rack.grab_active = false; rack.pulled = false; rack.pushed = false; rack.frac = 0
            -- [HALTEN 2026-07-20] Ein einmaliger Snap reicht NICHT: apply_slide_park laesst den
            -- Slide danach wieder los ("AUS (Engine haelt den Slide)") und die Engine zieht ihn erneut
            -- nach hinten (gemessen 0.0579, noch hinter back_z). _chambered_hold haelt ihn auf rest_z,
            -- bis der erste Schuss faellt -- genau wie nach einem normalen Rack. Chambert NICHTS an der
            -- Engine (das macht nur gun_chamber in clear_rack), nimmt also keinen Rack-Zwang mit.
            rack._chambered_hold = true
        end
    end
    service_haptics()    -- [SHOTGUN PUMP] verzoegerte Pump-Haptik faellig? -> feuern
    update_rack_gesture()
    update_rotary_cycle()   -- [ROTARY_CYCLE] Striker-Drehschalter (early-return fuer Nicht-Rotary-Waffen)
    update_break_action()   -- [BREAK_ACTION] Skull Shaker Klapphebel (early-return fuer Nicht-Break-Waffen)
    update_break_pump_sound()   -- [BREAK_PUMP_SND] 2x Klapp-Sound waehrend der nativen PumpAction-Anim
    -- [IK-GATE] AUTORITATIV jeden Frame publizieren (update_rack_state hat fruehe returns -> dort
    -- konnte das Global auf true haengen bleiben = IK fuer die Waffe tot bis Wechsel). Hier nie stuck.
    -- [PUMP_NO_Z 2026-07-31] Nur fuer die Pump-Shotgun: motion sperrt waehrend des Pumps die
    -- Waffen-Laengsachse (Waffe wandert nicht zum Koerper). Bewusst hier neben dem autoritativen
    -- slide_rack_active-Write -> kann nicht auf true haengen bleiben.
    _G.__vr_shotgun_pump_active = (rack.grab_active and wep.wid and is_shotgun(wep.wid)) == true
    _G.__vr_slide_rack_active = (rack.grab_active) == true   -- [SLIDE_RACK] Rack-Freeze nur fuer Z-Slide-Waffen. [SKULL SHAKER] break_open friert NICHT mehr ein (Klappe auf = Gun bleibt frei beweglich) -- __vr_break_open ist nur bei 6001 je true, daher gekapselt
    _G.__vr_empty_reload_active = rack.empty_reload == true   -- [EMPTY-RELOAD RACK] Riot Gun _08-Zug: Gun NICHT einfrieren (motion liest das) -> folgt der Hand statt starr zu stehen
    -- [MAG-DOCK-LOCK] AUTORITATIV jeden Frame: linke Hand haelt gerade Mag/Shell (oder Insert laeuft,
    -- oder <0.2s nach dem letzten Ammo-Input) -> die Support-Hand darf NICHT an den Schaft docken
    -- (sonst springt die "volle" Hand vorne auf den Vordergriff). motion.lua liest dieses Global.
    _G.__vr_mag_in_hand = (mag_hand.active or mag_insert.active
        or (rack._ammo_input_t and (os.clock() - rack._ammo_input_t) < 0.2)) and true or false
    -- [SHELL-KEYFRAMES 2026-07-24] Shell-Joint + Waffen-Transform + wid fuer die Keyframe-UI/Preview
    -- in reload_adv exponieren (jeden Frame, damit die Vorschau auch ohne laufenden Insert greift).
    _G.__re4_reload_shell_joint = wep.mag_joint
    _G.__re4_reload_weapon_tf   = wep.tf
    _G.__re4_reload_ui_wid      = wep.wid
    update_shell_eject() -- [SHELL_EJECT] Flug-State fortschreiben (nach rack.pulled gesetzt ist)
    -- [MANUAL_INSERT 2026-08-15] SICHERUNG: das Halten der Druecken-Pose darf NIE einen laufenden
    -- Handschub ueberleben. Den Insert brechen mehrere fremde Wege ab (Mag fallen lassen, neuer Grab,
    -- Waffenwechsel, Save-Load) -- die kennen den Push nicht. Ein Frame ohne aktiven Handschub reicht
    -- also, um das Halten aufzuloesen; die Pose faehrt dann normal zurueck statt am Magazin zu kleben.
    do
        local ms = rawget(_G, "__re4_reload_mag_slide")
        if ms and ms.push_hold == true and not (mag_insert.active and mag_insert.manual) then
            if type(ms.end_push_hold) == "function" then pcall(ms.end_push_hold) end
        end
    end
    -- [MANUAL_INSERT 2026-08-15] Rueckzieher OHNE gehaltenen Grip -> das Mag faellt. Hier statt direkt
    -- im Rueckzieher, weil drop_mag_simple erst weiter unten in der Datei steht.
    if mag_hand.want_drop then
        mag_hand.want_drop = nil
        mag_hand.redock_d  = nil
        if not mag_hand.active and not drop.active then
            drop_mag_simple()
            rlog("mag nach Rueckzieher losgelassen -> faellt auf den Boden")
        end
    end
    update_dock_blend()  -- [DOCK_LERP] Blend 1x/Frame rampen (vor publish_dock)
    publish_dock()  -- IK-Dock-Ziel fuer arm_chain (Hand an den Slide) waehrend gegriffen

    -- [SHELL_PART] enabled-Part-Set bei loaded>0 merken + bei 0 den Shell-Part-Diff bilden
    -- (1x/Frame; das eigentliche Einschalten passiert im vollen Override-Stack via sg_force_shell_parts).
    -- Riot Gun ueber EMPTY_RELOAD_JOINT, Break-Action (Skull Shaker) ueber SHELL_PART_LEARN -> sonst
    -- wird sg_update_parts fuer 6001 NIE aufgerufen und der Shell-Part nie gelernt (Shell unsichtbar).
    if EMPTY_RELOAD_JOINT[wep.wid] or SHELL_PART_LEARN[wep.wid] then
        local wi = get_live_weapon_item()
        local loaded = wi and tonumber(safe(function() return wi:call("get_CurrentAmmoCount") end))
        sg_update_parts(loaded)
    end

    -- [SND] Mag-Boden-Sound verzoegert: bei Drop-START (Auswurf ODER Holster-Release-
    -- Fall) Timer setzen, nach mag_floor_delay einmalig abspielen (Mag knallt auf Boden).
    if drop.active and not _drop_prev then
        _mag_floor_at = os.clock() + (CFG.mag_floor_delay or 0.45)
    end
    _drop_prev = drop.active
    if _mag_floor_at > 0 and os.clock() >= _mag_floor_at then
        _mag_floor_at = 0
        play_weapon_sound(snd("mag_floor"))
    end
    -- [SND] Dry-Fire: leere/gesperrte Waffe + Schuss-Trigger gezogen (Flanke vom Binding).
    local et = rawget(_G, "__re4_empty_trigger_held") == true
    if et and not _empty_trig_prev then play_weapon_sound(snd("dry_fire")) end
    _empty_trig_prev = et

    -- B-Flanke -> ROBUSTER Mag-Auswurf. Niemals blockiert: force_eject raeumt
    -- jeden Zwischenzustand ab und startet immer einen frischen Drop.
    local bd = right_b_down()
    if on and bd and not _b_prev then
        -- [SHOTGUN] Kein B-Eject: die Shotgun wirft kein Mag aus, das Pumpen macht die linke Hand
        -- (Pump = slide=_01 ueber das Slide-Rack-System). B bleibt fuer Shotguns wirkungslos.
        if is_shotgun(wep.wid) then
            -- nichts
        elseif CHAMBER[wep.wid] then toggle_chamber() else force_eject() end
    end
    _b_prev = bd
end)

-- Joint-Write NACH der Engine-Pose (sonst clobbert die Engine den Drop)
-- [MAG_OUT] Mag-Mesh aus der Kammer halten solange das Mag "draussen" ist (persistenter
-- Drop ueber Waffenwechsel). Engine setzt das Mag beim Equip neu in die Kammer -> wir
-- skalieren den Mag-Joint jeden Frame auf 0 (unsichtbar). NUR wenn kein Flow laeuft:
-- Drop-Animation/Mag-in-Hand/Insert duerfen das Mag normal zeigen.
local mag_hidden_applied = false
local function apply_mag_out_hidden()
    local should_hide = mag_out and wep.mag_joint
        and not drop.active and not mag_hand.active and not mag_insert.active
    if should_hide then
        pcall(function() wep.mag_joint:call("set_LocalScale", Vector3f.new(0, 0, 0)) end)
        mag_hidden_applied = true
    elseif mag_hidden_applied then
        -- wieder einblenden sobald draussen-Zustand endet ODER ein Flow das Mag zeigt
        if wep.mag_joint then
            pcall(function() wep.mag_joint:call("set_LocalScale", Vector3f.new(1, 1, 1)) end)
        end
        mag_hidden_applied = false
    end
end

-- [SHELL_PART] (Riot Gun) Die gechamberte Shell ist ein Sub-Mesh-PART des Gun-Meshes. Die Engine
-- disabled diesen Part bei leerer Kammer (0) -> bei 0 ist nichts zum Anzeigen da (Bone-Scale-Force
-- reicht nicht). RE9-Mechanismus: setPartsEnable(part, true) am via.render.Mesh. Part-Index AUTOMATISCH
-- (Diff: enabled bei loaded>0 minus enabled bei 0 = der Shell-Part), kein Hardcode.
local _sg = { tf = nil, mesh = nil, e1 = nil, shell = nil, empty = false }
local _sg_shell_by_wid = SHELL_PARTS   -- [PERSIST] ermittelter Shell-Part-Index pro WeaponID (Modell-fix) -> ueberlebt Waffenwechsel UND (via Disk) Script-Reset
local function sg_mesh()
    if wep.tf ~= _sg.tf or not _sg.mesh then
        _sg.tf = wep.tf; _sg.mesh = nil; _sg.e1 = nil; _sg.empty = false
        -- [PERSIST] Part-Index aus dem Per-Waffe-Cache wiederherstellen: nach Wechsel-zurueck-bei-leer
        -- wuerde der Diff sonst nie laufen (Waffe war nie loaded>0 seit dem Wechsel) -> keine Shell.
        _sg.shell = _sg_shell_by_wid[wep.wid] or SHELL_PART_FIXED[wep.wid]
        local go = wep.tf and safe(function() return wep.tf:call("get_GameObject") end)
        if go then _sg.mesh = safe(function() return go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh")) end) end
    end
    return _sg.mesh
end
local function sg_part_on(m, i)
    local v; pcall(function() v = m:call("getPartsEnable", i) end); return v == true
end
-- on_frame: e1 (enabled-Set bei loaded>0) EINMAL merken; den Shell-Part EINMAL per Diff ermitteln und
-- dann STABIL behalten (NICHT bei jedem Reload neu diffen -> nach dem 1. Chambern wuerde der Diff leer).
-- Der Part-Index ist fix (gleiches Gun-Modell). _sg.empty = Kammer leer (steuert das Force unten). (forward-declared)
sg_update_parts = function(loaded)
    if not (EMPTY_RELOAD_JOINT[wep.wid] or SHELL_PART_LEARN[wep.wid]) then return end   -- [SHELL_PART_FIX] auch Break-Action (Skull Shaker) lernt den Shell-Part
    local m = sg_mesh(); if not m then return end
    -- Gate auf KAMMER leer (rack.empty=isGunAmmoEmpty), NICHT loaded==0: nach der 1. Shell ist loaded=1
    -- (Roehre), aber die Kammer ist bis zum _08-Rack leer -> sonst zeigt die 2. Shell nicht.
    _sg.empty = (rack.empty == true)
    if loaded and loaded > 0 and not _sg.empty then
        -- e1 nur bei voller Kammer erfassen (Kammer-Shell-Part ist dann AN -> im Set enthalten).
        if not _sg.e1 then
            local set = {}
            for i = 0, 255 do if sg_part_on(m, i) then set[#set+1] = i end end
            _sg.e1 = set
        end
    elseif _sg.empty and _sg.e1 and (not _sg.shell or #_sg.shell == 0) then
        -- Shell-Part EINMAL bestimmen (nachlaufen bis nicht leer; Engine disabled evtl. 1-2 Frames spaeter).
        -- Danach bleibt _sg.shell stehen -> jede weitere Shell bei 0 nutzt denselben Part.
        local sh = {}
        for _, p in ipairs(_sg.e1) do if not sg_part_on(m, p) then sh[#sh+1] = p end end
        if #sh > 0 then
            _sg.shell = sh; _sg_shell_by_wid[wep.wid] = sh   -- [PERSIST] Index merken -> ueberlebt Waffenwechsel
            pcall(save_cfg)   -- [SHELL_PART_PERSIST] frisch gelernten Index auf Disk -> reset-fest (einmalig pro Waffe)
        end
    end
end
-- apply_slide_pass: Shell-Part-Sichtbarkeit steuern (forward-declared, voller Override-Stack).
-- on=true (Shell in der Hand): IMMER sichtbar erzwingen, egal ob Kammer leer ODER voll -> sonst ist
-- die getragene Huelse beim Nachladen mit voller Kammer weg (z.B. 2. Shell NACH dem Chamber-Rack).
-- on=false (nicht getragen): nur bei LEERER Kammer (_sg.empty) ausschalten (Phantom-Huelse weg);
-- bei voller Kammer NICHTS anfassen -> die Engine zeigt die gechamberte Huelse selbst.
sg_force_shell_parts = function(on)
    local m = sg_mesh(); if not m then return end   -- ZUERST: sg_mesh kann _sg (inkl. _sg.shell) bei Waffenwechsel reset/restore
    if not _sg.shell or #_sg.shell == 0 then return end   -- NACH sg_mesh pruefen -> nie nil in der Schleife
    if not on and not _sg.empty then return end   -- volle Kammer + nicht getragen -> Engine machen lassen
    for _, p in ipairs(_sg.shell) do
        pcall(function() m:call("setPartsEnable(System.UInt64, System.Boolean)", p, on and true or false) end)
    end
end

-- ---------------------------------------------------------------------
-- [SHELL_SPAWN] Getragene Huelse als EIGENE Instanz (Waffen ohne statischen Shell-Part, z.B.
-- Break-Action: Engine generiert die Huelse via ShotgunShellGenerator prozedural -> bei 0 Ammo
-- nichts da). Wir instanziieren das Shell-Prefab der Waffe (Generator._UserData._Prefab) einmal
-- und docken die Instanz an die _04-Joint-Weltpose (folgt via mag_to_hand bereits der Hand).
-- ---------------------------------------------------------------------
local _spawn = { go = nil, tf = nil, wid = nil }
local _go_destroy = nil
do
    local t = sdk.find_type_definition("via.GameObject")
    _go_destroy = t and t:get_method("destroy(via.GameObject)")
end
local function destroy_spawn_go()
    if _spawn.go and _go_destroy then pcall(function() _go_destroy:call(nil, _spawn.go) end) end
    _spawn.go, _spawn.tf = nil, nil
end
-- Generator-Komponente der equippten Waffe (child-GO "ShotgunShellGeneratorBase").
-- ROBUST per Typ-Name: die Komponente kann chainsaw.ShotgunShellGenerator ODER die GmActor-
-- Subklasse sein -> getComponent(exakter Typ) wuerde die andere verfehlen. Wir matchen "ShellGenerator".
local function find_shell_generator()
    if not wep.tf then return nil end
    local child = sc(wep.tf, "get_Child"); local n = 0
    while child and n < 64 do
        n = n + 1
        local go = sc(child, "get_GameObject")
        local nm = go and sc(go, "get_Name")
        if nm and tostring(nm):find("ShellGenerator", 1, true) then
            local comps = safe(function() return go:call("get_Components") end)
            if comps then
                for _, c in ipairs(comps) do
                    local td = safe(function() return c:get_type_definition() end)
                    local tn = td and safe(function() return td:get_full_name() end)
                    if tn and tn:find("ShellGenerator", 1, true) then return c end
                end
            end
        end
        child = sc(child, "get_Next")
    end
    return nil
end
-- Shell-Instanz sicherstellen (einmal pro Waffe aus dem Prefab des Generators erzeugen).
local function ensure_shell_spawn()
    if _spawn.go and _spawn.wid == wep.wid and safe(function() return _spawn.go:call("get_Valid") end) then
        return _spawn.go
    end
    if _spawn.go and _spawn.wid ~= wep.wid then destroy_spawn_go() end
    local gen = find_shell_generator(); if not gen then _G.__re4_shellspawn_dbg = "no_generator"; return nil end
    local ud = safe(function() return gen:call("get_UserData") end); if not ud then _G.__re4_shellspawn_dbg = "no_userdata"; return nil end
    local prefab = safe(function() return ud:get_field("_Prefab") end); if not prefab then _G.__re4_shellspawn_dbg = "no_prefab"; return nil end
    if safe(function() return prefab:call("get_Ready") end) == false then _G.__re4_shellspawn_dbg = "prefab_not_ready"; return nil end
    local pos = sc(wep.mag_joint, "get_Position") or rawget(_G, "__vr_lh_world") or sc(wep.tf, "get_Position")
    if not pos then _G.__re4_shellspawn_dbg = "no_pos"; return nil end
    local rot = rawget(_G, "__vr_lh_rot") or Quaternion.new(1, 0, 0, 0)
    local go = safe(function() return prefab:call("instantiate(via.vec3, via.Quaternion)", pos, rot) end)
    if not go then _G.__re4_shellspawn_dbg = "instantiate_nil"; return nil end
    pcall(function() go:call("set_UpdateSelf", false) end)   -- Shell-Script/Physik aus -> reine Optik, Transform steuern WIR
    _spawn.go = go; _spawn.tf = sc(go, "get_Transform"); _spawn.wid = wep.wid
    _G.__re4_shellspawn_dbg = "SPAWNED ok"
    return go
end
-- Per-Frame: beim Tragen die Shell-Instanz an die _04-Joint-Weltpose docken, sonst verstecken.
update_shell_spawn = function()
    if not (wep.wid and SHELL_SPAWN[wep.wid]) then
        if _spawn.go then destroy_spawn_go() end
        return
    end
    local carrying = (mag_hand.active or mag_insert.active) and wep.mag_joint
    if not carrying then
        if _spawn.go then pcall(function() _spawn.go:call("set_DrawSelf", false) end) end
        return
    end
    local go = ensure_shell_spawn(); if not go or not _spawn.tf then return end
    local jp = sc(wep.mag_joint, "get_Position")
    local jr = sc(wep.mag_joint, "get_Rotation")
    if jp then pcall(function() _spawn.tf:call("set_Position", jp) end) end
    if jr then pcall(function() _spawn.tf:call("set_Rotation", jr) end) end
    pcall(function() go:call("set_DrawSelf", true) end)
end

-- [SHELL_CLONE] Skull Shaker (6001): getragene Shell = MESH-CLONE von Part 1 an der linken Hand.
-- Ersetzt die gespawnte Prefab. Technik wie reload2-Revolver (via.motion.Motion baut Skelett +
-- via.render.Mesh + setMesh(lebender Gun-Holder) + Gun-Material + Part isolieren). Offsets aus dem
-- Global _G.__re4_ss_clone. Ganzer Block als IIFE (sofort aufgerufene Funktion) -> EIGENER Scope,
-- KEIN Main-Chunk-Local (reload.lua ist am 200-Local-Limit; ein do-Block wuerde die 7 Locals zum
-- Main-Chunk zaehlen und ihn ueberlaufen lassen). Die Hook-Closures (ss_apply) ueberleben.
-- Siehe Notiz.
;(function()
    local SS_WID = 6001
    local ssc = { obj = nil, mesh = nil, parts_sig = nil }
    local function ss_gun_mesh()
        if not wep.tf then return nil end
        local go = sc(wep.tf, "get_GameObject")
        return go and sc(go, "getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
    end
    local function ss_destroy()
        if ssc.obj then pcall(function()
            local td = sdk.find_type_definition("via.GameObject"); local d = td and td:get_method("destroy(via.GameObject)")
            if d then d:call(nil, ssc.obj) end
        end) end
        ssc.obj, ssc.mesh, ssc.parts_sig = nil, nil, nil
    end
    local function ss_spawn()
        if ssc.obj then return true end
        local gmesh = ss_gun_mesh(); if not gmesh then return false end
        local holder = safe(function() return gmesh:call("getMesh") end); if not holder then return false end
        local gmat = safe(function() return gmesh:call("get_Material") end)
        local go_td = sdk.find_type_definition("via.GameObject")
        local create = go_td and go_td:get_method("create(System.String)")
        local go = create and safe(function() return create:call(nil, "vr_ss_shell") end); if not go then return false end
        pcall(function() go:add_ref() end)
        pcall(function() go:call("createComponent(System.Type)", sdk.typeof("via.motion.Motion")) end)   -- KERN: baut Skelett
        local mesh = safe(function() return go:call("createComponent(System.Type)", sdk.typeof("via.render.Mesh")) end)
        if not mesh then return false end
        pcall(function() mesh:call("setMesh", holder) end)
        if gmat then pcall(function() mesh:call("set_Material", gmat) end) end
        pcall(function() mesh:call("set_DrawDefault", true) end)
        pcall(function() mesh:call("set_Enabled", true) end)
        pcall(function() mesh:call("set_FrustumCulling", false) end)
        ssc.obj, ssc.mesh = go, mesh
        -- [NO_LAG] nativ ans L_Hand-Joint parenten (wie Holster-Fix): Engine propagiert die Transform VOR
        -- dem Skinning -> kein 3-4-Frame-Render-Versatz beim Laufen. Danach nur noch LOKALE Pose setzen.
        ssc.parented = false
        local ctf = safe(function() return go:call("get_Transform") end)
        local bt2 = body_tf()
        if ctf and bt2 then
            pcall(function() ctf:call("set_Parent", bt2) end)
            if pcall(function() ctf:call("set_ParentJoint", "L_Hand") end) then ssc.parented = true end
        end
        return true
    end
    local function ss_isolate()
        if not ssc.mesh then return end
        local part = math.floor((_G.__re4_ss_clone.part or 1) + 0.5)
        local sig = "part:" .. tostring(part)
        if ssc.parts_sig == sig then return end
        local applied = true
        for i = 0, 48 do
            if not pcall(function() ssc.mesh:call("setPartsEnable", i, i == part) end) then applied = false end
        end
        if applied then ssc.parts_sig = sig end
    end
    -- NUR Position/Rotation/Scale auf die aktuelle L_Hand ziehen (kein Spawn/Isolate). Von beiden
    -- Paessen genutzt -> im POST schlank wie reload2s reposition_cart_late.
    local function ss_place()
        if not ssc.obj then return end
        local cfg = _G.__re4_ss_clone
        local tf = safe(function() return ssc.obj:call("get_Transform") end); if not tf then return end
        local scl = cfg.scale or 1.0
        -- [NO_LAG] geparentet ans L_Hand: nur LOKALE Pose setzen (Offset = wie vorher hand-relativ),
        -- die Engine macht die Welt-Position -> kein Render-Versatz beim Laufen.
        if ssc.parented then
            pcall(function() tf:call("set_LocalPosition", Vector3f.new(cfg.x or 0, cfg.y or 0, cfg.z or 0)) end)
            pcall(function() tf:call("set_LocalRotation", quat_from_euler(cfg.rx or 0, cfg.ry or 0, cfg.rz or 0)) end)
            pcall(function() tf:call("set_LocalScale", Vector3f.new(scl, scl, scl)) end)
            return
        end
        -- Fallback (nicht geparentet): alter Welt-Weg.
        local bt = body_tf(); local lhj = bt and sc(bt, "getJointByName", "L_Hand")
        local hp = lhj and sc(lhj, "get_Position"); if not hp then return end
        local hr = lhj and sc(lhj, "get_Rotation")
        local wx, wy, wz = hp.x, hp.y, hp.z
        if hr then
            local off = safe(function() return hr * Vector3f.new(cfg.x or 0, cfg.y or 0, cfg.z or 0) end)
            if off then wx, wy, wz = hp.x + off.x, hp.y + off.y, hp.z + off.z end
        end
        local rot = hr and safe(function() return (hr * quat_from_euler(cfg.rx or 0, cfg.ry or 0, cfg.rz or 0)):normalized() end)
        local okp = pcall(function() tf:set_position(Vector3f.new(wx, wy, wz), true) end)   -- no_dirty gegen Jitter
        if not okp then pcall(function() tf:call("set_Position", Vector3f.new(wx, wy, wz)) end) end
        if rot then local okr = pcall(function() tf:set_rotation(rot) end); if not okr then pcall(function() tf:call("set_Rotation", rot) end) end end
        pcall(function() tf:call("set_LocalScale", Vector3f.new(scl, scl, scl)) end)
    end
    -- Voller Pass (4 Nicht-POST-Paesse): Spawn/Isolate/Destroy + Positionieren.
    local function ss_apply()
        if not CFG.enabled or wep.wid ~= SS_WID then if ssc.obj then ss_destroy() end return end
        local cfg = _G.__re4_ss_clone
        -- [SS-HANDOVER 2026-08-01, "die Patrone verschwindet nicht aus der Hand, wenn die Anim
        -- anfaengt"] Der Clone ist die Shell IN DER HAND -- nur solange sie getragen wird. Sobald der
        -- Insert laeuft, uebernimmt die waffeneigene _04-Shell die Keyframe-Bahn in die Kammer; der Clone
        -- muss in DEMSELBEN Moment weg, sonst haengt eine zweite Huelse an der Hand und es sieht aus, als
        -- laedt man mit voller Hand nach. Frueher stand hier `or mag_insert.active` -> er blieb stehen.
        local show = mag_hand.active or cfg.preview
        if not show then if ssc.obj then ss_destroy() end return end
        if not ssc.obj then if not ss_spawn() then return end end
        ss_isolate()
        ss_place()
    end
    -- [WOBBLE-FIX] BeginRendering-POST: NUR nachziehen, NACH motion.lua's finalem L_Hand-Write
    -- (attach_left_hand im POST). Schlank wie reload2s reposition_cart_late -> kein Spawn/Isolate im POST.
    local function ss_repos_late()
        if not ssc.obj or wep.wid ~= SS_WID then return end
        local cfg = _G.__re4_ss_clone
        if not (mag_hand.active or cfg.preview) then return end   -- [SS-HANDOVER] ab dem Insert nicht mehr
        ss_place()
    end
    -- voller Override-Stack; POST = schlanke Reposition NACH motion (gegen Wabbeln)
    pcall(function() re.on_pre_application_entry("LockScene", ss_apply) end)
    pcall(function() re.on_application_entry("LateUpdateBehavior", ss_apply) end)
    pcall(function() re.on_application_entry("UpdateJointExpression", ss_apply) end)
    pcall(function() re.on_pre_application_entry("BeginRendering", ss_apply) end)
    pcall(function() re.on_application_entry("BeginRendering", ss_repos_late) end)
end)()

local function apply_drop_pass()
    if not CFG.enabled then return end
    -- [X-LINKS-BLITZ 2026-07-23] Der Proximity-Check (startet den Insert) lief in einem anderen
    -- Hook (on_frame) als diese Anwendung -- lief die Anwendung im Frame VORHER, blieb das Mag noch
    -- ein Frame an der Handposition (seitlich = X links), bevor der Insert es auf die Achse zog.
    -- Frueher unsichtbar (Insert startete auch an der Hand), seit dem festen dock-Start ein Sprung.
    -- Deshalb den Check hier im SELBEN Pass zuerst laufen lassen -- er ist idempotent (mag_hand.active
    -- schon false -> sofortiger Return), der on_frame-Aufruf bleibt als Fallback bestehen.
    check_mag_insert_proximity()
    update_mag_drop()
    update_mag_in_hand()
    update_mag_insert()
    apply_mag_out_hidden()
end
pcall(function() re.on_pre_application_entry("LockScene", apply_drop_pass) end)
pcall(function() re.on_application_entry("LateUpdateBehavior", apply_drop_pass) end)
pcall(function() re.on_application_entry("BeginRendering", apply_drop_pass) end)
-- [SS-FLASH 2026-08-01] Letzter Schreibpunkt VOR dem Rendern -- hier fehlte einer, deshalb der
-- Ein-Frame-Blitz der Skull-Shaker-Shell (Messung: siehe Kommentar an update_mag_insert).
-- BEWUSST eng gehalten:
-- * NUR wp6001 -- fuer jede andere Waffe ist der Ablauf bitgleich wie bisher,
-- * NUR update_mag_insert (nicht der ganze apply_drop_pass -> kein Drop, kein Proximity-Check,
-- der einen Insert starten koennte),
-- * und das im Sicht-Modus: schreibt ausschliesslich die Position, schliesst nichts ab.
-- Damit kann aus dieser neuen Phase KEIN Reload-Call, kein Ammo-Write und kein Sound entstehen.
pcall(function() re.on_pre_application_entry("BeginRendering", function()
    if not CFG.enabled or wep.wid ~= 6001 or not mag_insert.active then return end
    mag_insert.visual = true
    pcall(update_mag_insert)
    mag_insert.visual = false
end) end)

-- [ENTKOPPEL_ROT/HMD] Der gedroppte Mag ist ein ANIMIERTER Waffen-Joint -> braucht den VOLLEN
-- Joint-Override-Stack (wie apply_slide_pass). Der Drop-Pass oben deckt nur LockScene-pre +
-- LateUpdateBehavior + BeginRendering-POST ab; es fehlten UpdateJointExpression + BeginRendering-PRE.
-- In UpdateJointExpression schreibt die Engine den Joint aus der HMD-gefuehrten Waffenpose zurueck ->
-- ohne unseren Write in diesem Pass wackelte das gefallene Mag mit dem Kopf. Nur der reine Drop-Write
-- (kein mag_in_hand/insert -> die haben eigenes POST-Timing gegen motion.lua).
local function apply_drop_joint_pass()
    if not CFG.enabled then return end
    if drop.active then update_mag_drop() end
end
pcall(function() re.on_application_entry("UpdateJointExpression", apply_drop_joint_pass) end)
pcall(function() re.on_pre_application_entry("BeginRendering", apply_drop_joint_pass) end)

-- Slide-Park + Joint-Finder schreiben ANIMIERTE Joints -> brauchen den VOLLEN
-- Joint-Override-Stack wie re4_vr_arm_chain.lua (LockScene-pre + LateUpdateBehavior
-- + UpdateJointExpression + BeginRendering-pre), sonst ueberschreibt die Engine den Write.
local function apply_slide_pass()
    if not CFG.enabled then return end
    -- [LET-GO] Joint-Writes (Chamber/Slide/Dock/Rack-Pose) NUR wenn die Waffe verwaltet ist.
    -- Toggle aus -> _managed=false -> wir schreiben NICHTS, die Engine kontrolliert die Waffe.
    if _managed then
        if CHAMBER[wep.wid] then apply_chamber() end   -- [TOP_LOADER] Chamber statt Slide
        apply_slide_park()
        -- [ROTARY/BREAK] slide-Joint ist eine Rotation (Striker Drehschalter _01 / Skull Shaker Klappe _02).
        -- Ruhe-Rotation um (rx,ry,rz)*prog drehen. prog 0 = Ruhe (Engine ueberlassen). prog-Quelle je Typ.
        if (ROTARY_CYCLE[wep.wid] or BREAK_ACTION[wep.wid]) and wep.slide_joint and wep.cycle_rest_rot then
            local p = ROTARY_CYCLE[wep.wid] and (rotary.prog or 0) or (break_st.prog or 0)
            if p > 0.0001 then
                local r = rotary_cfg(wep.wid)
                local q = quat_from_euler(r.rx * p, r.ry * p, r.rz * p)
                local newrot = safe(function() return (wep.cycle_rest_rot * q):normalized() end)
                if newrot then pcall(function() wep.slide_joint:call("set_LocalRotation", newrot) end) end
            end
        end
        -- [EMPTY-RELOAD SLIDE] _08-Lade-Slide ZU halten (rest_z = gechambert) WANN IMMER kein aktiver
        -- Empty-Reload-Zug laeuft. Die Engine schliesst den _08 nach dem manuellen Zug NICHT (wie der
        -- Pistolen-Slide) -> clear_rack snappt ihn nur 1x, danach zieht die Engine ihn wieder hinten.
        -- Hier im VOLLEN Override-Stack jeden Pass forcen. Waehrend des Zugs (rack.empty_reload) NICHT
        -- anfassen -> da treibt ihn apply_slide_park via frac. Per-Waffe (EMPTY_RELOAD_JOINT), kein _01.
        if EMPTY_RELOAD_JOINT[wep.wid] and wep.slide_joint2 and not rack.empty_reload then
            local cur = sc(wep.slide_joint2, "get_LocalPosition")
            if cur then
                local sp2 = slide_pose2(wep.wid or 0)
                pcall(function() wep.slide_joint2:call("set_LocalPosition", Vector3f.new(cur.x, cur.y, sp2.rest_z)) end)
            end
        end
        -- [SHELL_VISIBLE] Shell beim Tragen (Grab/Tuning/Insert) sichtbar erzwingen, im VOLLEN
        -- Override-Stack (dieser Pass laeuft auch in UpdateJointExpression + BeginRendering-pre):
        -- (1) _04-Bone-Scale auf 1 (Engine skaliert ihn bei leerer Kammer auf 0),
        -- (2) Shell-Sub-Mesh-PART einschalten (Engine disabled ihn bei 0 -> ohne das ist nichts da).
        -- [SS-HANDOVER 2026-08-01] Skull Shaker: die andere Haelfte der Uebergabe. Beim TRAGEN ist die
        -- Shell der Hand-Clone und die gun-eigene _04 bleibt versteckt (sonst doppelte Huelse) -- das war
        -- der Grund fuer den 6001-Ausschluss hier. Ab dem INSERT ist es genau umgekehrt: der Clone ist weg
        -- (ss_apply) und die _04 muss SICHTBAR die Keyframe-Bahn in die Kammer fahren. Explizit einschalten
        -- statt der Engine zu ueberlassen -- die blendet die Huelse bei leerer Kammer selbst aus.
        local ss_insert = (wep.wid == 6001) and mag_insert.active
        if wep.mag_joint and (ss_insert
            or (is_shotgun(wep.wid) and wep.wid ~= 6001 and (mag_hand.active or mag_tune.active or mag_insert.active))) then
            pcall(function() wep.mag_joint:call("set_LocalScale", Vector3f.new(1, 1, 1)) end)
            sg_force_shell_parts(true)    -- Shell-Sub-Mesh-Part sichtbar (bei 0 sonst weg)
        else
            sg_force_shell_parts(false)   -- nicht getragen -> Shell-Part aus (leere Kammer zeigt keine Huelse)
        end
        apply_shell_eject()   -- [SHELL_EJECT] Shell in Chamber-Startposition (Preview/Flug)
        -- Dock-Ziel der Hand JEDEN Pass NACH dem Slide-Setzen frisch publizieren -> arm_chain
        -- liest in jedem der 4 Override-Paesse die aktuelle Slide-Position -> kein Nachhinken.
        publish_dock()
        apply_rack_hand_pose()   -- Finger-Pose bei Rack-Dock + im Einstell-Toggle
    end
    -- Finder ist ein UI-Tuning-Tool (nur aktiv wenn finder.active) -> unabhaengig von _managed.
    if not (rack.needs or rack.tuning) then apply_finder() end
end
pcall(function() re.on_pre_application_entry("LockScene", apply_slide_pass) end)
pcall(function() re.on_application_entry("LateUpdateBehavior", apply_slide_pass) end)
pcall(function() re.on_application_entry("UpdateJointExpression", apply_slide_pass) end)
pcall(function() re.on_pre_application_entry("BeginRendering", apply_slide_pass) end)

-- =====================================================================
-- UI (RE9-Struktur: per-Gattung Toggle, alles haengt daran)
-- =====================================================================
local function category_row(label, key)
    local c, v = imgui.checkbox("##mr_" .. key, CFG[key])
    imgui.same_line(); imgui.text_colored("Enable", 0xFF00FF00)
    imgui.same_line(); imgui.text(label)
    if c then CFG[key] = v; save_cfg() end
    return v
end

-- [NAKED-RATIO 2026-07-24] KOPIE der 3 Shotgun-Ladeverhaeltnis-Toggles (1:1/1:2/1:3) im schlanken
-- Public-Menue (ohne Tree, oben bei den anderen Optionen -- via __re4_ui_add-Dispatcher). Das Original
-- bleibt unveraendert im Shotgun-Dev-Tree. Gleiche Wirkung: setzt SHOTGUN_RATIO_WID[equippte Waffe].
-- Eigene ##-IDs (nak_) -> keine Kollision mit den Original-Buttons.
if _G.__re4_ui_add then
    _G.__re4_ui_add(60, "reload_shotgun_ratio_naked", function()
        local awid = wep.wid or get_equip_wid()
        imgui.text_colored("Shotgun Shell Ratio", 0xFF00A5FF)   -- [KNALLIG 2026-07-24] Orange (2026-07-24)
        local eff = SHOTGUN_RATIO_WID[awid] or CFG.shotgun_ratio or 2
        local r1 = (eff == 1) and "[1:1]" or " 1:1 "
        if imgui.button(r1 .. "##nak_shratio1") and awid then SHOTGUN_RATIO_WID[awid] = 1; save_cfg() end
        imgui.same_line()
        local r2 = (eff == 2) and "[1:2]" or " 1:2 "
        if imgui.button(r2 .. "##nak_shratio2") and awid then SHOTGUN_RATIO_WID[awid] = 2; save_cfg() end
        imgui.same_line()
        local r3 = (eff == 3) and "[1:3]" or " 1:3 "
        if imgui.button(r3 .. "##nak_shratio3") and awid then SHOTGUN_RATIO_WID[awid] = 3; save_cfg() end
    end)
end

-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - Reload" raus (645 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

-- [GUN_DIAG] TEMP Gun-Diagnose-Log ENTFERNT (2026-07-03) -> war die 201. Top-Level-Local
-- (Limit 200 gesprengt, Script lud nicht mehr). Fokus liegt aufs [SLIDEBUG]-Log (Slide-Park-Bug).

load_cfg()
-- [POSE-STORE] importierte Posen (aus gestures.json) sofort in reload.json backen ->
-- damit die Daten in reload.json liegen und gestures.lua spaeter geloescht werden kann.
save_cfg()
-- Beim Script-Reload keinen stale Feuer-Block hinterlassen
_G.__vr_block_fire_when_empty = false
_G.__re4_bf_who = "re4_vr_reload.lua:4093"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
_G.__vr_needs_rack = false
_G.__vr_shotgun_pump_active = false   -- [PUMP_NO_Z] sauber starten
_G.__vr_rack_block_left_knife = false
-- Fire-gecachtes Live-Item beim Reload leeren -> der get_CurrentAmmoCount-Hook akquiriert
-- das ECHTE Laufzeit-Item frisch neu (kein stale Item nach Reset Scripts).
_G.__re4_live_wi = nil


-- =====================================================================
-- [RUNDEN-RESET 2026-08-09] Neue Mercenaries-Runde -> Waffenzustand wegwerfen
-- =====================================================================
-- SYMPTOM: die letzte Runde mit leerem Magazin verlassen -> in der neuen Runde ist die
-- Waffe voll, das Script will aber trotzdem nachladen/durchladen.
-- URSACHE: `rack` und `_pe_cache` leben auf Script-Ebene und werden nur bei Waffenwechsel
-- bzw. bei einem GEWORFENEN Aufruf verworfen. Ein Rundenwechsel ist beides nicht: das
-- Spiel laedt die Map neu, die alten Objekte bleiben ansprechbar (Schreiben verpufft
-- lautlos, siehe Notiz).
-- TRIGGER: `__re4_merc_round` -- re4_vr_merc.lua zaehlt es in der Ladeluecke hoch, in der
-- der Body kurz gar nichts meldet. Das ist der einzige verlaessliche Hinweis auf eine neue
-- Runde; ein eigenes Flag dafuer gibt es nicht.
-- Ausserhalb Mercenaries aendert sich der Token nie -> Kampagne und Adas DLC sind unberuehrt.
-- Zaehler bewusst als Global, NICHT als local: diese Datei liegt nah am 200-Local-Limit.
re.on_frame(function()
    local t = tonumber(rawget(_G, "__re4_merc_round"))
    if t == rawget(_G, "__re4_round_seen_reload1") then return end
    _G["__re4_round_seen_reload1"] = t

    _pe_cache = nil

    -- Ladezustand der letzten Runde: in der neuen ist die Waffe frisch.
    if type(rack) == "table" then
        rack.needs              = false
        rack.empty              = false
        rack.empty_when_dropped = false
        rack._zeroed_by_us      = false
        rack.empty_reload       = false
        rack.armed              = false
        rack.grab_active        = false
        rack.pulled             = false
        rack.pushed             = false
    end

    -- Die eine Referenz, an der der ganze Ladeweg haengt -- nach dem Neuladen der Map ist
    -- sie eine Leiche (bekannte Falle). Nur HIER genullt, damit
    -- nicht vier Scripte dasselbe Global anfassen.
    _G.__re4_live_wi = nil
end)

-- =====================================================================
-- [DRYFIRE_WATCH 2026-08-12]  Munition steht im Item, aber die Waffe klickt leer
-- =====================================================================
-- Die Munition liegt an ZWEI Stellen: im Inventar-Item und in der Runtime-Gun. Geschossen
-- wird aus der Runtime-Gun. Unsere Ladewege schreiben teils nur das Item (mehrere Pfade in
-- reload2/3/5 buchen per addAmmoCount OHNE anschliessenden Sync) -- dann zeigt alles "geladen",
-- die Waffe feuert aber nicht. Genau dafuer gibt es updateGunAmmo (= __re4_sync_gun_ammo):
-- es traegt den Item-Stand in die Runtime-Gun. Parameterlos, fasst das Inventar nicht an,
-- kann die Reload-AV also nicht ausloesen.
--
-- WARUM NICHT EINFACH JEDEN FRAME: die Uebertragung geht nur Item -> Waffe. Beim Schuss zieht
-- die Engine erst die Waffe runter und danach das Item; genau in diesem Zwischenfenster wuerde
-- ein Sync den alten, hoeheren Item-Wert zurueckschreiben (Schuss geschenkt). Waehrend der
-- Ladeanimation gilt dasselbe fuer halbfertige Zwischenstaende.
--
-- DESHALB ALS WAECHTER: nur alle 0.5 s messen, und nur eingreifen, wenn beide Werte seit der
-- letzten Messung UNVERAENDERT sind. Stabilitaet ist hier der Ruhe-Nachweis: waehrend Schuss
-- oder Reload aendert sich mindestens einer der beiden Werte staendig.
-- ZUSTAND BEWUSST IN GLOBALS: diese Datei steht am 200-Local-Limit des Lua-Chunks
-- (drei zusaetzliche Top-Level-Locals brechen sie mit "too many local variables").
_G.__re4_dfw_t, _G.__re4_dfw_run, _G.__re4_dfw_item = 0.0, nil, nil

re.on_frame(function()
    local now = os.clock()
    if (now - (rawget(_G, "__re4_dfw_t") or 0.0)) < 0.5 then return end
    _G.__re4_dfw_t = now

    local pe = get_pe()
    if not pe then _G.__re4_dfw_run, _G.__re4_dfw_item = nil, nil; return end

    local run = tonumber(safe(function() return pe:call("getCurrentGunAmmo") end))
    local wi  = get_live_weapon_item()
    local item = wi and tonumber(safe(function() return wi:call("get_CurrentAmmoCount") end)) or nil
    if not run or not item then _G.__re4_dfw_run, _G.__re4_dfw_item = run, item; return end

    -- Nur bei RUHE (zwei gleiche Messungen) und nur wenn das Item wirklich mehr fuehrt.
    if item > run and run == rawget(_G, "__re4_dfw_run") and item == rawget(_G, "__re4_dfw_item") then
        if _G.__re4_sync_gun_ammo then _G.__re4_sync_gun_ammo() end
        _G.__re4_dryfire_sync = (tonumber(rawget(_G, "__re4_dryfire_sync")) or 0) + 1
    end

    _G.__re4_dfw_run, _G.__re4_dfw_item = run, item
end)
