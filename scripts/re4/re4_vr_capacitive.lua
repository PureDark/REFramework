-- =====================================================================
-- re4_vr_capacitive.lua  --  GRIP-EMPFINDLICHKEIT (NUR OpenXR)
-- =====================================================================
-- WARUM ES DIESE DATEI GIBT
-- Unter OpenVR liest unser mitgeliefertes Index-Profil den Griff als "force_sensor"
-- (force_input = force) und schaltet bei 0.30 an / 0.25 aus -- das ist dort schon
-- richtig und darf NICHT angefasst werden. Unter OpenXR war der Griff dagegen an
-- "/user/hand/*/input/squeeze/value" gebunden -- und das ist bei den Index-
-- Controllern der KAPAZITIVE Griffwert, also "wie geschlossen ist die Hand". Der steht
-- schon beim blossen Halten des Controllers deutlich ueber 0.30: der Griff hat deshalb
-- bei der kleinsten Bewegung ausgeloest.
-- Der Fork bindet jetzt zusaetzlich "/user/hand/*/input/squeeze/force" (denselben
-- Kraftsensor wie OpenVR) und legt die Schwelle darauf. Eingestellt wird das NICHT im
-- Framework, sondern hier -- Werte in re4_vr/re4_vr_capacitive.json.
--
-- RUNTIME-SPERRE (19.08.2026)
-- `set_grip_settings` wird AUSSCHLIESSLICH gerufen, wenn die Runtime OpenXR ist
-- (`vrmod:is_openxr_loaded()`). Unter OpenVR laeuft dieses Script komplett leer --
-- kein Aufruf, kein Nachschieben, kein UI. Vorher hat der 2-Sekunden-Takt die
-- Grip-Einstellung auch unter OpenVR ueberschrieben; genau das war der Fehler.
-- Die Runtime wird bei JEDEM Takt neu geprueft, damit ein VR-Neustart mit
-- gewechselter Runtime sofort richtig liegt.
--
-- KEIN UI MEHR: die Werte in der JSON stimmen, es gibt nichts einzustellen.
-- Aendern nur noch von Hand in reframework\data\re4_vr\re4_vr_capacitive.json
-- (bei beendetem Spiel).
--
-- BRAUCHT den Fork-Build mit `set_grip_settings` (sonst passiert schlicht nichts).
-- =====================================================================
-- Builtin implementation: src/mods/vr/games/re4/RE4VRCapacitive.cpp
return

if reframework:get_game_name() ~= "re4" then return end
if not vrmod then return end

local JSON_PATH = "re4_vr/re4_vr_capacitive.json"

-- Defaults = die Werte, die das OpenVR-Index-Profil seit jeher benutzt.
local CFG = {
    use_analog   = true,   -- eigene Schwelle statt der Runtime-Entscheidung
    prefer_force = true,   -- Kraftsensor vor kapazitivem Wert (Index)
    press        = 0.30,   -- ab hier gilt der Griff als zu
    release      = 0.25,   -- darunter wieder als offen (Hysterese)
}

do
    local ok, loaded = pcall(json.load_file, JSON_PATH)
    if ok and type(loaded) == "table" then
        if loaded.use_analog   ~= nil then CFG.use_analog   = loaded.use_analog   and true or false end
        if loaded.prefer_force ~= nil then CFG.prefer_force = loaded.prefer_force and true or false end
        if type(loaded.press)   == "number" then CFG.press   = loaded.press end
        if type(loaded.release) == "number" then CFG.release = loaded.release end
    end
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Ein Loslassen-Punkt OBERHALB des Greif-Punktes wuerde den Griff fuer immer festhalten.
local function sane()
    CFG.press   = clamp(tonumber(CFG.press)   or 0.30, 0.05, 0.95)
    CFG.release = clamp(tonumber(CFG.release) or 0.25, 0.05, 0.95)
    if CFG.release > CFG.press then CFG.release = CFG.press end
end
sane()

-- Nur OpenXR. Solange die Runtime noch nicht steht (VR nicht initialisiert), ist das
-- Ergebnis false -- dann wird schlicht nichts gesetzt und beim naechsten Takt neu gefragt.
local function is_openxr()
    local ok, v = pcall(function()
        return vrmod.is_openxr_loaded and vrmod:is_openxr_loaded() or false
    end)
    return ok and v == true
end

local function apply()
    if not is_openxr() then return end     -- OpenVR / unbekannt: Finger weg
    pcall(function()
        vrmod:set_grip_settings(CFG.use_analog, CFG.prefer_force, CFG.press, CFG.release)
    end)
end

apply()

-- Das Framework laedt seine eigene Config auch nach einem VR-Neustart (Runtime-Wechsel,
-- Save-Load der Session) -- dann stuenden dort wieder die Fork-Defaults. Deshalb wird der
-- Satz regelmaessig nachgeschoben; ein Aufruf alle zwei Sekunden kostet nichts.
local next_push = 0.0

re.on_frame(function()
    local t = os.clock()
    if t < next_push then return end
    next_push = t + 2.0
    apply()
end)
