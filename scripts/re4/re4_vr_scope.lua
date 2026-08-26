-- Builtin implementation: src/mods/vr/games/re4/RE4VRScope.cpp
return

-- =====================================================================
-- re4_vr_scope.lua [2026-08-07]
--
-- Zwei Aufgaben, beide nur auf UNSEREN eigenen REFramework-Forks wirksam:
--
-- 1) FORK-ERKENNUNG. Stellt fest, ob das laufende REFramework unsere Version ist,
-- und legt das Ergebnis in Globals ab. Andere Scripte (weapons.lua, re4_vr_ui.lua)
-- fragen die ab und bleiben auf ihrem bisherigen Weg, wenn sie false sind.
--
-- 2) MONO-BROKER + NATIVES SCOPE. Beim Zielen mit MONTIERTEM Scope laeuft auf
-- unserem Fork alles nativ -- kein Killswitch, kein Freeze/Headpin, kein
-- Augen-Versatz, kein Body-Hide (dafuer sorgt re4_vr_weapons.lua, indem es dort
-- scope_aim fallen laesst und uns `__re4_scope_native` publisht). Das Einzige,
-- was wir stattdessen tun: Mono-Rendering an, beide Augen bekommen dasselbe
-- Bild. Iron-Sight ist unberuehrt und bleibt normales Gameplay.
--
-- WARUM ERKENNUNG UEBER DIE FAEHIGKEIT: unsere Forks exportieren zusaetzliche
-- VR-Schalter nach Lua (VR.cpp, am globalen `vrmod`):
-- vrmod:is_mono_rendering / set_mono_rendering(bool)
-- vrmod:get_mono_rendering_eye / set_mono_rendering_eye(0=links,1=rechts)
-- vrmod:is_gui_projection_matrix_override_disabled / set_..._disabled(bool)
-- Im oeffentlichen REFramework gibt es die nicht. Eine Versionsnummer waere identisch,
-- also wird die Faehigkeit selbst geprueft: existiert der Getter und liefert er einen
-- Wert -> unser Fork.
--
-- MONO GEHOERT GENAU HIER HIN: mehr als eine Stelle darf `set_mono_rendering` NICHT
-- rufen, sonst schalten zwei Regler dieselbe Groesse und der eine nimmt dem anderen
-- den Zustand weg (bekannte Falle). Wer Mono will, meldet das an:
-- __re4_mono_request("<id>", true/false)
-- Solange IRGENDEIN Anforderer true hat, ist Mono an -- sonst aus.
--
-- UI: REFramework-Menue -> "Mod Options" -> Tree "RE4VR - Scope" (reine Anzeige).
-- =====================================================================
if reframework:get_game_name() ~= "re4" then return end

-- ---------------------------------------------------------------------
-- 1) Fork-Erkennung
-- Startwert bewusst false, nicht nil: wer die Globals abfragt, bevor die Erkennung
-- durch ist, bekommt den SICHEREN Fall = bisheriger Weg.
-- ---------------------------------------------------------------------
_G.__re4_fork_ok         = false   -- true = eine unserer REFramework-Versionen
_G.__re4_fork_mono       = false   -- true = Mono-Rendering per Lua schaltbar
_G.__re4_fork_gui_matrix = false   -- true = GUI-Projection-Override per Lua schaltbar
-- Getrennt gefuehrt: die Flatscreen-Leinwand kam spaeter dazu, ein aelterer eigener Build
-- kann Mono koennen und die Leinwand noch nicht. Nicht an __re4_fork_ok haengen.
_G.__re4_fork_canvas     = false   -- true = Flatscreen-Leinwand per Lua schaltbar

local probe_done  = false          -- Erkennung abgeschlossen (Ergebnis steht fest)
local probe_tries = 0              -- Versuche, solange `vrmod` noch nicht existiert
local PROBE_MAX   = 600            -- ~10s bei 60fps, dann endgueltig aufgeben
local probe_note  = "noch nicht geprueft"

-- Einen Getter gefahrlos antesten. Nur parameterlose const-Getter hier reinreichen --
-- die Setter werden NIE zum Testen gerufen, sonst wuerden wir den Zustand veraendern.
local function has_getter(name)
    local ok, v = pcall(function() return vrmod[name](vrmod) end)
    if not ok then return false end
    return type(v) == "boolean" or type(v) == "number"
end

local function run_probe()
    if probe_done then return end

    -- `vrmod` wird von der VR-Mod beim Erzeugen des Lua-States gesetzt. Ist es noch
    -- nicht da, spaeter nochmal versuchen (kein Ergebnis festschreiben).
    if type(vrmod) ~= "userdata" and type(vrmod) ~= "table" then
        probe_tries = probe_tries + 1
        if probe_tries >= PROBE_MAX then
            probe_done = true
            probe_note = "kein vrmod -- VR-Mod nicht geladen"
        end
        return
    end

    _G.__re4_fork_mono       = has_getter("is_mono_rendering")
    _G.__re4_fork_gui_matrix = has_getter("is_gui_projection_matrix_override_disabled")
    _G.__re4_fork_canvas     = has_getter("is_flatscreen_overlay")
    _G.__re4_fork_ok         = _G.__re4_fork_mono and _G.__re4_fork_gui_matrix
    probe_done = true

    if _G.__re4_fork_ok then
        probe_note = "eigener Fork (Mono + GUI-Matrix)"
    elseif _G.__re4_fork_mono or _G.__re4_fork_gui_matrix then
        -- Teiltreffer: einer der beiden Schalter fehlt. Dann NICHT als Fork fuehren --
        -- der neue Weg braucht beides, halber Umbau waere schlimmer als der alte Weg.
        probe_note = "Teiltreffer (mono=" .. tostring(_G.__re4_fork_mono)
                  .. " gui=" .. tostring(_G.__re4_fork_gui_matrix) .. ") -- gilt als Standard"
    else
        probe_note = "Standard-REFramework"
    end

end

-- Sofort einmal versuchen (meistens steht `vrmod` beim Laden schon).
run_probe()

-- Fuer andere Scripte / Diagnose: liefert das Ergebnis und stoesst die Erkennung an,
-- falls sie noch nicht durch ist.
_G.__re4_fork_check = function()
    run_probe()
    return _G.__re4_fork_ok, _G.__re4_fork_mono, _G.__re4_fork_gui_matrix
end

-- ---------------------------------------------------------------------
-- 2) Mono-Broker -- die EINZIGE Stelle, die set_mono_rendering ruft
-- ---------------------------------------------------------------------
local mono_reqs  = {}      -- ["scope"]=true, ["map"]=true,...
local mono_state = false   -- was wirklich am vrmod steht
local mono_fail  = false   -- Setter hat geworfen -> nicht jeden Frame nachbohren

_G.__re4_mono_request = function(id, on)
    if type(id) ~= "string" then return end
    mono_reqs[id] = (on == true) or nil
end

local function mono_wanted()
    for _ in pairs(mono_reqs) do return true end
    return false
end

local function mono_apply()
    if not _G.__re4_fork_mono or mono_fail then return end

    local want = mono_wanted()
    if want == mono_state then return end

    local ok = pcall(function() vrmod:set_mono_rendering(want) end)
    if not ok then
        mono_fail = true
        return
    end

    mono_state = want
end

-- ---------------------------------------------------------------------
-- 3) Scope-Tick -- `__re4_scope_native` kommt aus re4_vr_weapons.lua und ist NUR
-- dann true, wenn dort mit montiertem Scope gezielt wird UND unser Fork laeuft.
-- Iron-Sight setzt es nie.
-- ---------------------------------------------------------------------
local scope_native = false
local native_off_t = nil   -- seit wann ist die Erkennung weg? (Entprellen, s. on_frame)

-- Schalter zum Vergleichen im Headset, alle im Tree "RE4VR - Scope".
local opt = {
    mono     = true,   -- Mono-Rendering waehrend des Scope-Aims (beide Augen dasselbe Bild)
    -- [MONO_MANUAL 2026-08-14] Freier Dauerschalter fuer GENAU denselben Mono-Effekt, nur
    -- ohne Scope und ohne Karte. Laeuft ueber den Broker (`manual`-Slot), damit sich die drei
    -- Anforderer nicht gegenseitig den Zustand wegnehmen -- direkt `set_mono_rendering` zu
    -- rufen waere die bekannte Doppelregler-Falle. Solange EINER true hat, ist Mono an.
    mono_manual = false,
    -- [ZOOM] DAS ist der Zoom-Schalter. Der native Scope-Zoom ist eine enge FOV an der
    -- Spielkamera -- die VR-Mod ersetzt die Projektion aber jeden Frame durch ihre eigene,
    -- und damit ist der Zoom weg (man schaut ins Scope, es holt aber nichts heran).
    -- Hier setzen wir den Projektions-Override waehrend des Scope-Aims aus: dann rechnet
    -- das Spiel mit seiner EIGENEN, gezoomten Projektion -- wie flat.
    proj_off = true,
    -- [VIEW] Dasselbe fuer die KAMERA-POSITION/-RICHTUNG. Ist der View-Override auch aus,
    -- steht die Kamera im Scope genau dort, wo das Spiel sie flat hat -- sie kippt also mit
    -- der Waffe mit, wenn man mit dem rechten Stick zielt. Damit braucht es weder den Freeze
    -- noch den Pitch-Follow (der nie sauber lief).
    view_off = true,
    -- [ZOOM-FAKTOR] Skaliert die fertige Projektion. Das ist der Faktor, den der linke Stick
    -- unten regelt -- der Versatz X/Y dazu ist ersatzlos raus, der bewirkte nichts.
    zoom     = 1.0,
    fov      = 0.0,
    -- [STICK_ZOOM] Linker Stick hoch/runter regelt waehrend des Scope-Zooms den Zoom-Faktor.
    -- NUR auf unserem Fork und NUR waehrend des Scope-Aims. Der Stick wird ausschliesslich
    -- GELESEN -- kein Eingriff in den Eingabepfad, die Bewegung bleibt unberuehrt
    -- (bekannte Falle).
    -- [BLANK_EYE] Ein Auge im Scope komplett schwarz. Grund: die VR-Mod rendert ABWECHSELND
    -- (AFR) -- linkes und rechtes Auge sehen also verschiedene Zeitpunkte, und weil die Waffe
    -- im ADS schwankt, sitzt das Fadenkreuz in beiden Augen minimal anders und ein Auge zittert
    -- staerker. Mono macht die Position gleich, nicht den Zeitpunkt. Das nicht-zielende Auge
    -- zu schwaerzen nimmt den Konflikt ganz raus (wie ein Auge zukneifen).
    -- -1 = aus, 0 = linkes Auge schwarz, 1 = rechtes Auge schwarz.
    blank_eye   = -1,
    -- [XR 2026-08-11] Derselbe Schalter, aber NUR fuer OpenXR. Zwei Werte, damit das
    -- Umstellen der Runtime die jeweils andere Einstellung nicht kaputtmacht.
    -- [2026-08-14] Default jetzt AUS, wie unter OpenVR: mit beiden Augen sieht man besser,
    -- und das Auseinanderdriften beim Zoomen kam nicht vom fehlenden Schwaerzen, sondern
    -- aus der Projektion (Fork: ZoomScalesEyeOffset / ZoomShrinksIPD). Wer es doch will,
    -- stellt es im Tree um -- der Wert wird gespeichert (cfg_touch).
    blank_eye_xr = -1,
    -- [XR_DELTA 2026-08-11] EIN pauschaler Versatz fuer die ganze Runtime, kein zweiter
    -- Wertesatz pro Waffe x Optik: unter OpenXR sitzt das Okular gegenueber OpenVR
    -- ueberall um denselben Betrag daneben (andere Augen-/Kopfmitte der Runtime -- genau
    -- wie bei den Controller-Offsets, wo `openxr_correction` in re4_vr_motion.lua seit
    -- jeher pauschal gilt). Wird bei erkanntem OpenXR auf den Kurvenwert ADDIERT; die
    -- Punkte in der JSON bleiben dabei unangetastet, unter OpenVR wirkt gar nichts.
    -- Z bleibt bewusst draussen: die Tiefe stimmt in beiden Runtimes.
    xr_dx       = 0.0,
    xr_dy       = 0.0,
    -- [ZOOM_X 2026-08-14] Seitlicher Versatz, LINEAR ueber den Zoom: bei `zoom_min` wirkt
    -- gar nichts, bei `zoom_max` genau dieser Wert (negativ = nach links). Dazwischen wird
    -- geblendet. 0.0 = aus, dann ist alles exakt wie vorher.
    -- WARUM NUR X: die alte Zoom-Kompensation (08.08. wieder RAUS) zog X *und* Y mit und
    -- das Crosshair sass bei Vollzoom nicht mehr mittig. Y/Z bleiben deshalb Geometrie.
    -- Addiert wird NACH der Punktkurve, genau wie das XR-Delta -- niemals in `opt.cam_x`
    -- zurueck, sonst backt der SET-Knopf den Zoom-Anteil in die Punkte ein.
    zoom_x      = 0.0,
    -- [ZOOM_X_BOW 2026-08-14] Der eigentliche Fehler ist KEINE Gerade: ganz ausgezoomt
    -- stimmt das Bild, ganz reingezoomt auch -- dazwischen wandert es aus und kommt wieder
    -- zurueck (live beobachtet: nach rechts, Ausgleich also mit einem PLUS-Wert).
    -- Genau diese Form hat `sin(pi * t)`: null an beiden Enden, Maximum in der Mitte, ohne
    -- Knick. Der Regler ist damit reiner Faktor -- er kann die beiden Enden gar nicht
    -- verstellen, egal wie weit man ihn zieht. Wirkt additiv NEBEN `zoom_x` (der bleibt die
    -- Gerade fuer Faelle, in denen der Vollzoom selbst danebensitzt). 0.0 = aus.
    zoom_x_bow  = 0.0,
    -- [PITCH_Y 2026-08-15] Hoehenausgleich ueber den WAFFENWINKEL (nicht ueber den Zoom):
    -- in der Mitte stimmt es, ganz hoch gezielt sitzt das Crosshair drueber, ganz unten
    -- drunter. Das ist ein GEGENLAEUFIGER Fehler -- die Korrektur muss also ihr Vorzeichen
    -- mit dem Winkel wechseln (ungerade Funktion), ein Bogen wie `zoom_x_bow` waere hier
    -- falsch: der schoebe oben und unten in dieselbe Richtung.
    --   t = deg / pitch_y_deg   (-1 unten … 0 Mitte … +1 oben, geklemmt)
    --   y += pitch_y * sign(t) * |t| ^ pitch_y_pow
    -- `pitch_y_pow` = 1 ist die Gerade; groesser laesst den Ausgleich erst nahe den
    -- Anschlaegen anziehen und die Mitte in Ruhe. 0.0 = aus, dann bleibt alles wie vorher.
    -- Kommt oben auf die Punktkurve drauf, wandert also nie in die Punkte.
    pitch_y     = 0.0,
    pitch_y_deg = 75.0,
    pitch_y_pow = 1.0,
    -- [ADA_Y 2026-08-15] EIGENER Satz fuer Adas beide Scope-Waffen (6105 Anti-Materiel /
    -- "Adas Stingray" und 6114 Hunting Rifle). Grund: ihr Waffen-Pitch laeuft anders als
    -- bei Leons Vorlagen, und EIN gemeinsamer Regler kann immer nur eine von beiden Seiten
    -- treffen -- stellt man ihn fuer Ada richtig, ist Leon hinueber und umgekehrt.
    -- Startwerte bewusst = Leons Zahlen: bis jemand hier dreht, aendert sich GAR NICHTS.
    -- Alles andere (Punktkurve, Augen-Versatz) teilen sich die Klone weiter mit der Vorlage.
    pitch_y_ada     = 0.0,
    pitch_y_deg_ada = 75.0,
    pitch_y_pow_ada = 1.0,
    -- [ADA_Y_PRO_OPTIK 2026-08-15] Bei Leon reicht EIN Y-Ausgleich fuer alle Waffen und
    -- Optiken -- bei Ada nicht: dort braucht das Thermal einen anderen Wert als Hi-Power
    -- und normal (live berichtet, das Wegkippen tritt am staerksten mit Thermal auf).
    -- Darum pro Optik ein eigener Satz, Schluessel wie bei den Punktlisten:
    -- "normal" / "thermal" / "hipower" / "ironsight" -> { y, deg, pow }.
    -- Leer angelegte Optiken erben einmalig die alten Ada-Werte (s. cfg_load).
    pitch_y_ada_sets = {},
    -- Einmalige Uebernahme von Leons Werten (s. cfg_load) -- sonst startete Ada auf 0.0,
    -- waehrend Leon laengst getunt ist, und der "eigene Satz" waere beim ersten Mal AUS.
    pitch_y_ada_migrated = false,
    -- [ZOOM_Y 2026-08-15] Dasselbe fuer die Hoehe: 0 ausgezoomt, voller Wert bei Vollzoom.
    -- Y war bis hierher bewusst draussen (die alte Auto-Kompensation zog Y mit und das
    -- Crosshair sass bei Vollzoom nicht mehr mittig, 08.08. raus) -- als HANDregler ist es
    -- etwas anderes: er wirkt nur, wenn jemand ihn zieht, und ausgezoomt garantiert nie.
    zoom_y      = 0.0,
    -- [MONO_PROJ 2026-08-11] Mono setzt normalerweise nur die AUGENPOSITION auf ein Auge;
    -- die Projektion behaelt jede Anzeige selbst (per-Auge asymmetrisches Frustum). Damit
    -- passen Blickpunkt und Frustum nicht zusammen -- unter OpenVR faellt das kaum auf,
    -- unter OpenXR sind die Frusta staerker asymmetrisch: der Treffer sitzt dann konstant
    -- neben der Fadenkreuzmitte und es fuehlt sich an wie Schielen. Mit diesem Schalter
    -- kommt auch die Projektion vom Mono-Auge (vrmod:set_mono_projection).
    mono_proj   = false,
    -- [IMAGE_SHIFT] Verschiebt das FERTIGE Bild im Panel (beim Submit an den Compositor).
    -- Das ist der einzige Versatz, der noch wirkt, wenn Projektion UND Kamera dem Spiel
    -- gehoeren -- alles davor rechnet die VR-Mod dann gar nicht mehr.
    -- Einheit = Anteil des Bildes: 0.01 = ein Prozent der Breite/Hoehe.
    img_x       = 0.0,
    img_y       = 0.0,
    -- [CAM_OFF] Eigener Kamera-Offset NUR fuer "Rifle MIT Scope im Zoom" -- Vorbild ist
    -- apply_turret_hmd_offset in re4_vr_firstperson.lua: die PRIMARY CAMERA wird direkt
    -- verschoben. Das ist der einzige Weg, der auch dann noch wirkt, wenn die View-Matrix
    -- dem Spiel gehoert -- wir schieben ja die Spielkamera selbst, nicht unsere Matrix.
    -- BLICKRELATIV: x = seitlich, y = hoch, z = vor/zurueck (+ = nach vorne).
    -- [ 2026-08-08] Bedienung: die drei Regler wirken IMMER live. Passt es bei einem
    -- Winkel, druckst du SET -- dann merkt sich das Script diesen Winkel samt X/Y/Z als
    -- Punkt. Zwischen den Punkten wird linear geblendet, ausserhalb gilt der Randpunkt.
    -- Beliebig viele Punkte an beliebigen Graden; kein Modus, nichts zu verstehen.
    cam_x       = 0.0,
    cam_y       = 0.0,
    cam_z       = 0.0,
    -- Die Punkte: Liste von { deg = Waffen-Pitch in Grad, x, y, z }, nach deg sortiert.
    -- [ 2026-08-09] PRO WAFFE **UND** PRO OPTIK eine eigene Liste -- nicht nur die drei
    -- Optiken sitzen unterschiedlich tief, auch dieselbe Optik sitzt auf jeder Waffe anders.
    -- Schluessel = "<wid>_<optik>", z.B. "4401_normal" (Stingray), "4400_thermal"
    -- (SR M1903), "4202_ironsight" (LE 5 ohne Aufsatz). Die Waffe kommt aus
    -- `__re4_scope_wid`, die Optik aus `__re4_scope_id` (beides weapons.lua).
    -- Neue Kombinationen legt cur_kfs bei Bedarf leer an -- nichts wird vorbelegt.
    kfs_sets    = {},
    kfs         = {},   -- alt: eine gemeinsame Liste; wird einmalig nach "normal" gehoben
    kfs_migrated = false,   -- alte Stuetzstellen schon uebernommen? (nur einmal, sonst
                            -- kaemen sie nach "Alle Punkte loeschen" wieder zurueck)
    -- [2026-08-08] Zoom-Kompensation und Z-Rueckzug waren hier und sind wieder RAUS:
    -- der Rueckzug wirkte zwar, aber zusammen mit der Skalierung wanderten bei Vollzoom
    -- auch X/Y, und das Crosshair sass nicht mehr mittig. Der Offset ist jetzt wieder
    -- reine Geometrie: was am Punkt steht, gilt -- unabhaengig vom Zoom.
    -- Alt (3 bzw. 5 feste Stuetzstellen). Bleiben im Table, damit bestehende JSONs sauber
    -- laden -- sie werden einmalig nach `kfs` uebernommen und danach nicht mehr benutzt.
    live        = false,
    mid_y = 0.0, mid_z = 0.0,
    up_y  = 0.0, up_z  = 0.0,
    dn_y  = 0.0, dn_z  = 0.0,
    um_y  = 0.0, um_z  = 0.0, um_on = false,
    dm_y  = 0.0, dm_z  = 0.0, dm_on = false,
    mid_t       = 0.5,
    pitch_ref   = 45.0,  -- nur noch fuer die einmalige Uebernahme der alten Werte
    -- [HOLD] Halte-Zeit gegen das Blitzen: so lange darf die Scope-Erkennung aussetzen,
    -- ohne dass Mono/Projektion/Kamera umschalten. Hoch = ruhiger, aber traeger beim Verlassen.
    hold        = 0.35,
    -- [BOLT_EYE 2026-08-12] Repetierer (SR M1903 4400, Hunting Rifle 6114): das schwarze Auge
    -- soll UEBER den Schuss hinaus bleiben -- man bleibt ja am Zielfernrohr, waehrend man
    -- durchlaedt. Sekunden ab dem Schuss. 0 = altes Verhalten (Auge geht sofort weg).
    -- WARUM ES BISHER NICHT GING: das `bolt_win`-Fenster unten hat das Auge fuer wid 4400
    -- 1,10 s lang HART auf -1 gezwungen -- die "Halte-Zeit gegen Blitzen" konnte dagegen
    -- prinzipiell nichts ausrichten, egal wie hoch sie stand.
    bolt_eye_hold = 1.50,
    -- [BOLT_PITCH_FREEZE 2026-08-15] So lange ab dem Schuss wird der Waffen-Pitch nicht neu
    -- gelesen, sondern der letzte gute Wert gehalten. Wirkt in re4_vr_weapons.lua.
    -- STARTET AUS (0.0): gebaut wurde er gegen scheinbare Winkelspruenge von +17 auf +83 Grad
    -- -- die waren aber ein ARTEFAKT des damaligen Flanken-Logs (zwischen zwei Zeilen lagen
    -- Sekunden). Die spaetere kontinuierliche Messung zeigt den Winkel sauber durchlaufen;
    -- die echte Ursache war der fehlende Parent (s. SCOPE_PARENT in re4_vr_weapons.lua).
    -- Bleibt als Werkzeug stehen, falls nach dem Durchladen doch noch etwas kippt.
    bolt_pitch_hold = 0.0,
    -- [BOLT_REAIM] Nach dem Schuss der Bolt Rifle den gehaltenen Griff abbrechen. Es wird
    -- KEIN neues Zielen erzwungen -- zum Weiterzoomen ist ein neuer Grip-Druck noetig
    -- (deshalb gibt es auch keine Dauer mehr; die Sperre endet beim Loslassen).
    bolt_reaim  = true,
    -- [BOLT_MUTE] Repetier-Sound nach dem Schuss schlucken (nur wp4400, nur im
    -- 1,2-s-Fenster nach dem Schuss -- s. Block weiter unten).
    bolt_mute   = true,
    -- [SCOPE_SENS] Faktor auf den rechten Stick beim Zielen durch ein montiertes Scope,
    -- linear ueber den Zoom gemischt: `sens_out` gilt bei zoom_min (rausgezoomt),
    -- `sens_in` bei zoom_max (voll drin). Beide auf 1.00 = aus. Wirkt in
    -- re4_vr_binding.lua vor dem vigem-Export, also unabhaengig von der Sensitivity
    -- im Spielmenue -- das Verhaeltnis bleibt immer dasselbe.
    sens_out    = 0.85,
    sens_in     = 0.35,
    stick_zoom  = true,
    zoom_speed  = 0.04,   -- pro Frame bei vollem Ausschlag
    zoom_min    = 1.0,   -- [ 2026-08-08] Stick darf NUR zwischen 1.000 und 3.000 regeln
    zoom_max    = 3.0,

    -- ---------------------------------------------------------------------
    -- [FERNGLAS 2026-08-10] Vom Fernglas bleibt hier NUR diese eine Sache:
    -- Zoom und Mono ueber unseren Fork wurden gebaut und wieder ZURUECKGEBAUT -- das
    -- Ergebnis war schlechter als der bestehende Kamera-Offset-Workaround in
    -- re4_vr_binding.lua. NICHT nochmal anfangen: der Projektions-Zoom skaliert auch die
    -- per Auge verschiedenen Off-Center-Terme (VR.cpp:2534), dadurch laufen die beiden
    -- Bilder beim Zoomen seitlich auseinander; beim Scope faellt das nur deshalb nicht
    -- auf, weil dort ein Auge geschwaerzt ist.
    --
    -- Der schwarze Rand im Fernglas ist `bg_outside` in Gui_ui2110 (NICHT 3110 -- die
    -- gibt es nicht, per #UILogger belegt). Die GUI selbst bleibt sichtbar, skaliert wird
    -- nur diese eine Ebene. 1.0 = unveraendert, dann wird gar nicht erst gesucht.
    bino_bg_scale = 1.0,
}

-- ---------------------------------------------------------------------
-- Persistenz -- data/re4_vr/re4_vr_scope.json (gleicher Ort wie die anderen Scripte).
-- Ohne das waeren alle Offsets nach jedem "Reset Scripts" wieder weg.
-- ---------------------------------------------------------------------
local CFG_PATH  = "re4_vr/re4_vr_scope.json"
local save_dirty, save_t = false, 0.0

local function cfg_load()
    local ok, d = pcall(function() return json.load_file(CFG_PATH) end)
    if not ok or type(d) ~= "table" then return end

    for k, v in pairs(opt) do
        local nv = d[k]
        if type(nv) == type(v) then opt[k] = nv end
    end

    -- Punkte sauber machen: nur Eintraege mit Zahlen, nach Winkel sortiert. Was aus der
    -- JSON kommt, kann alles sein -- hier wird es einmal geradegezogen.
    local function clean_list(src)
        local clean = {}
        for _, e in ipairs(src or {}) do
            if type(e) == "table" and tonumber(e.deg) then
                clean[#clean + 1] = { deg = tonumber(e.deg),
                                      x = tonumber(e.x) or 0.0,
                                      y = tonumber(e.y) or 0.0,
                                      z = tonumber(e.z) or 0.0,
                                      zoom = tonumber(e.zoom) or 1.0 }
            end
        end
        table.sort(clean, function(a, b) return a.deg < b.deg end)
        return clean
    end

    -- [ADA_Y 2026-08-15] Adas eigener Winkel-Ausgleich startet auf Leons Werten, damit sich
    -- beim ersten Laden nichts aendert. Laeuft genau EINMAL -- danach ist er unabhaengig und
    -- ein spaeteres Nachstellen an Leon zieht ihn nicht mehr mit.
    if opt.pitch_y_ada_migrated ~= true then
        opt.pitch_y_ada_migrated = true
        opt.pitch_y_ada     = opt.pitch_y
        opt.pitch_y_deg_ada = opt.pitch_y_deg
        opt.pitch_y_pow_ada = opt.pitch_y_pow
    end

    opt.kfs = clean_list(opt.kfs)
    if type(opt.kfs_sets) ~= "table" then opt.kfs_sets = {} end
    for k, v in pairs(opt.kfs_sets) do
        opt.kfs_sets[k] = clean_list(v)
    end

    -- [PRO WAFFE 2026-08-09] Frueher galt eine Liste pro OPTIK fuer ALLE Waffen. Getunt
    -- wurden sie an der Stingray -- also gehen sie an 4401_<optik>. Alle anderen Waffen fangen
    -- bewusst LEER an (man setzt sie von Hand neu). Laeuft nur einmal: die alten
    -- Schluessel werden danach entfernt.
    for _, id in ipairs({ "normal", "thermal", "hipower", "ironsight" }) do
        local old = opt.kfs_sets[id]
        if type(old) == "table" then
            local dst = "4401_" .. id
            if #old > 0 and #(opt.kfs_sets[dst] or {}) == 0 then
                opt.kfs_sets[dst] = old
            end
            opt.kfs_sets[id] = nil
        end
    end

    local sting_normal = opt.kfs_sets["4401_normal"]
    if type(sting_normal) ~= "table" then
        sting_normal = {}
        opt.kfs_sets["4401_normal"] = sting_normal
    end

    -- Die alte gemeinsame Liste gehoert dem normalen Scope der Stingray -- dafuer wurde sie getunt.
    if #opt.kfs > 0 and #sting_normal == 0 then
        opt.kfs_sets["4401_normal"] = opt.kfs
        sting_normal = opt.kfs_sets["4401_normal"]
        opt.kfs = {}
    end

    -- Einmalige Uebernahme der alten festen Stuetzstellen (nur wenn noch keine Punkte da
    -- sind und dort ueberhaupt etwas getunt wurde) -- sonst waere die Arbeit weg.
    if #sting_normal == 0 and not opt.kfs_migrated then
        opt.kfs_migrated = true
        local pr = opt.pitch_ref; if pr < 1.0 then pr = 1.0 end
        local old = { { 0.0, opt.mid_y, opt.mid_z, true },
                      {  pr, opt.up_y,  opt.up_z,  true },
                      { -pr, opt.dn_y,  opt.dn_z,  true },
                      {  pr * opt.mid_t, opt.um_y, opt.um_z, opt.um_on },
                      { -pr * opt.mid_t, opt.dm_y, opt.dm_z, opt.dm_on } }
        local any = false
        for _, o in ipairs(old) do
            if o[4] and (o[2] ~= 0.0 or o[3] ~= 0.0) then any = true end
        end
        if any or opt.cam_x ~= 0.0 then
            local dst = sting_normal
            for _, o in ipairs(old) do
                if o[4] then
                    dst[#dst + 1] = { deg = o[1], x = opt.cam_x, y = o[2], z = o[3] }
                end
            end
            table.sort(dst, function(a, b) return a.deg < b.deg end)
        end
    end
end

local function cfg_save()
    pcall(function() json.dump_file(CFG_PATH, opt) end)
    save_dirty = false
end

-- Von der UI gerufen: nicht bei jedem Pixel schreiben, sondern eine Sekunde nachdem
-- das Menue zuletzt offen war.
local function cfg_touch()
    save_dirty = true
    save_t = os.clock()
end

cfg_load()

-- Muss SOFORT gelten, nicht erst wenn der Tree einmal offen war (die Zuweisung in der UI
-- laeuft nur waehrend des Zeichnens -- siehe Notiz).
_G.__re4_bolt_reaim        = opt.bolt_reaim
-- Startwert, bis der Tick den zoomabhaengigen Faktor das erste Mal gerechnet hat.
_G.__re4_scope_sens_factor = opt.sens_out

-- Zoom/Shift NUR waehrend des nativen Scope-Aims -- sonst waere die ganze Welt gezoomt.
local proj_on = false
local proj_supported = nil
-- [BOLT_BLANK] zuletzt an vrmod geschriebener Wert fuers schwarze Auge (-1 = aus). Muss HIER
-- oben stehen, sonst laeuft der Block im Tick gegen ein nil-Local (bekannte Falle).
-- [AUGE-SCHWAERZEN RAUS 2026-08-17] `blank_eye_now` ist entfallen (samt des Startwerts -99,
-- der beim ersten Frame bewusst einmal die -1 in den Fork schrieb).

-- [XR 2026-08-11] Welche Runtime laeuft? Einmal ermitteln und merken -- sie wechselt nur
-- mit einem Neustart des Spiels. Danach entscheidet sie, WELCHER der beiden Augen-Werte
-- gilt: OpenVR nimmt opt.blank_eye (dort ist -1 richtig), OpenXR opt.blank_eye_xr.
-- Muss HIER oben stehen, sonst laeuft proj_apply gegen ein nil-Local (bekannte Falle).
local is_xr = nil
-- Erkennung wie in re4_vr_motion.lua (Z. 4394): erst pruefen, OB es die Methode gibt --
-- ein blosses pcall auf vrmod:is_openxr_loaded() sagt nicht, ob sie fehlt oder nur
-- false liefert. Wird von UI UND Tick gerufen, sonst steht im UI ewig "unbekannt".
local function detect_runtime()
    if is_xr ~= nil then return is_xr end
    if type(vrmod) ~= "userdata" and type(vrmod) ~= "table" then return nil end
    pcall(function()
        if vrmod.is_openxr_loaded and vrmod:is_openxr_loaded() then
            is_xr = true
        elseif vrmod.is_openvr_loaded and vrmod:is_openvr_loaded() then
            is_xr = false
        end
    end)
    return is_xr
end

-- [AUGE-SCHWAERZEN RAUS 2026-08-17] `want_blank_eye()` (welcher der beiden Augen-Werte gilt,
-- je nach Runtime) ist mit dem Feature entfallen. `detect_runtime` bleibt -- daran haengt noch
-- das XR-Delta der Scope-Kamera und die Anzeige im Menue.
-- [ZOOM_X 2026-08-14] Die 0..1-Rampe ueber den Zoom: 0 bei `zoom_min`, 1 bei `zoom_max`.
-- Eine Stelle fuer beide Verbraucher (Stick-Empfindlichkeit im Tick, Zoom-X in der Kamera) --
-- sonst haetten wir zwei Rechnungen fuer dieselbe Groesse und die driften irgendwann
-- auseinander (bekannte Falle).
local function zoom_ramp()
    local zmin, zmax = opt.zoom_min, opt.zoom_max
    if not (zmax > zmin) then return 0.0 end
    local t = (opt.zoom - zmin) / (zmax - zmin)
    if t < 0.0 then return 0.0 elseif t > 1.0 then return 1.0 end
    return t
end

-- [ZOOM_X_BOW 2026-08-14] Der seitliche Versatz zum aktuellen Zoom -- EINE Stelle fuer
-- Kamera und Regleranzeige, aus demselben Grund wie bei `zoom_ramp()`: zwei Rechnungen
-- fuer dieselbe Groesse driften irgendwann auseinander.
-- Zwei Anteile, die sich nicht ins Gehege kommen:
--   `zoom_x`     Gerade  -- 0 ausgezoomt, voller Wert bei Vollzoom.
--   `zoom_x_bow` Bogen   -- 0 an BEIDEN Enden, Maximum in der Mitte (sin-Halbwelle).
-- Der Bogen ist der Ausgleich fuer die beobachtete Auswanderung zwischen den Enden: er
-- kann die eingestellten Endpunkte gar nicht verschieben, deshalb bleibt beim Feinstellen
-- alles stehen, was schon passt.
local function zoom_x_at(t)
    local full = tonumber(opt.zoom_x) or 0.0
    local bow  = tonumber(opt.zoom_x_bow) or 0.0
    return (full * t) + (bow * math.sin(math.pi * t))
end

local function zoom_x_now()
    return zoom_x_at(zoom_ramp())
end

-- [ZOOM_Y 2026-08-15] Hoehe: nur die Gerade, kein Bogen -- der wurde fuer X gebaut, weil
-- dort die Auswanderung zwischen den Enden gemessen wurde. Kommt derselbe Effekt in Y,
-- gehoert hier ein `zoom_y_bow` daneben, nicht ein zweiter Rechenweg.
local function zoom_y_now()
    return (tonumber(opt.zoom_y) or 0.0) * zoom_ramp()
end

-- [PITCH_Y 2026-08-15] Hoehenausgleich ueber den Waffenwinkel, punktsymmetrisch um die
-- Mitte: in der Mitte exakt null, an den Anschlaegen der volle Wert mit ENTGEGENGESETZTEM
-- Vorzeichen. Damit bleibt die eingestellte Mittelstellung unangetastet, egal wie weit man
-- den Regler zieht -- dieselbe Eigenschaft, die den Zoom-Bogen ungefaehrlich macht.
-- [ADA_Y 2026-08-15] Der ROHE `__re4_scope_wid` (also 6105/6114 statt der Vorlage), gehalten
-- wie alle Scope-Globals: am Desktop im Menue steht sie sonst auf nil und die Anzeige
-- zeigte den falschen Satz. MUSS hier oben stehen -- `pitch_y_at` weiter unten sieht ein
-- `local` sonst nicht (bekannte Falle Local-Reihenfolge).
local last_raw_wid = 4401
local function scope_raw_wid()
    local w = tonumber(rawget(_G, "__re4_scope_wid"))
    if w then last_raw_wid = w end
    return last_raw_wid
end
-- Adas beide Scope-Waffen. Sie teilen sich Punktkurve und Augen-Versatz mit ihren Leon-
-- Vorlagen (s. scope_wid_now), bekommen fuer den WINKEL-Ausgleich aber einen eigenen Satz:
-- ihr Waffen-Pitch laeuft anders, und ein gemeinsamer Regler kann nur einen von beiden
-- treffen. Alle drei Werte starten auf Leons Zahlen -- bis jemand dreht, aendert sich nichts.
local function scope_is_ada()
    local w = scope_raw_wid()
    return w == 6105 or w == 6114
end

-- [ADA_Y_PRO_OPTIK 2026-08-15] Die montierte Optik, ebenfalls gehalten -- am Desktop steht
-- die Globale sonst auf nil und man justierte den falschen Satz. Muss wie scope_raw_wid
-- HIER OBEN stehen, damit pitch_y_at es sieht (Local-Reihenfolge).
local last_raw_id = "normal"
local function scope_raw_id()
    local s = rawget(_G, "__re4_scope_id")
    if type(s) == "string" then last_raw_id = s
    elseif rawget(_G, "__re4_scope_wid") ~= nil then last_raw_id = "ironsight" end
    return last_raw_id
end

-- Der Y-Satz der AKTUELL montierten Optik. Fehlt er, wird er aus den alten Ada-Einzelwerten
-- angelegt -- so aendert sich beim ersten Aufruf einer neuen Optik nichts.
local function ada_y_set()
    local id = scope_raw_id()
    local s  = opt.pitch_y_ada_sets[id]
    if type(s) ~= "table" then
        s = { y = tonumber(opt.pitch_y_ada) or 0.0,
              deg = tonumber(opt.pitch_y_deg_ada) or 75.0,
              pow = tonumber(opt.pitch_y_pow_ada) or 1.0 }
        opt.pitch_y_ada_sets[id] = s
    end
    return s
end

local function pitch_y_at(deg)
    local ada = scope_is_ada()
    local set = ada and ada_y_set() or nil
    local k = tonumber(ada and set.y or opt.pitch_y) or 0.0
    if k == 0.0 or type(deg) ~= "number" then return 0.0 end

    local ref = tonumber(ada and set.deg or opt.pitch_y_deg) or 75.0
    if ref < 1.0 then ref = 1.0 end          -- sonst Division durch ~0 und ein Sprung

    local t = deg / ref
    if t > 1.0 then t = 1.0 elseif t < -1.0 then t = -1.0 end

    local p = tonumber(ada and set.pow or opt.pitch_y_pow) or 1.0
    if p < 0.2 then p = 0.2 elseif p > 5.0 then p = 5.0 end

    -- Betrag hoch p, Vorzeichen getrennt -- `(-0.5)^1.5` waere in Lua NaN.
    local a = (t < 0.0) and -t or t
    local s = (a ^ p) * ((t < 0.0) and -1.0 or 1.0)
    return k * s
end

-- [2026-08-10] Die Faehigkeitspruefung lag frueher NUR in proj_apply -- die laeuft
-- aber erst beim ersten Scope-Einstieg. Wer nie durch ein Scope schaut, hatte
-- proj_supported dauerhaft auf nil, und der Fernglas-Zweig unten sprang nie an
-- ("Fork erkannt, aber der alte Workaround laeuft weiter"). Jetzt eigenstaendig.
local function ensure_proj_supported()
    if proj_supported ~= nil then return proj_supported end
    if type(vrmod) ~= "userdata" and type(vrmod) ~= "table" then return nil end
    proj_supported = pcall(function() return vrmod:get_projection_zoom() end)
    if not proj_supported then
    end
    return proj_supported
end

local function proj_apply(on)
    ensure_proj_supported()
    if not proj_supported then return end

    on = on and true or false
    if on == proj_on then return end
    proj_on = on

    pcall(function()
        -- Der eigentliche Zoom: im Scope die Projektion dem SPIEL ueberlassen.
        vrmod:set_projection_matrix_override_disabled(on and opt.proj_off)
        vrmod:set_view_matrix_override_disabled(on and opt.view_off)
        -- [AUGE-SCHWAERZEN RAUS 2026-08-17 -- AFW] Hier stand `set_blank_eye(...)`. Wir fahren
        -- nur noch mit BEIDEN Augen an, der Fork-Default ist ohnehin "aus" (m_blank_eye = -1),
        -- also wird der Wert gar nicht mehr angefasst -- kein Eingriff in den Kopier-/Submit-Pfad,
        -- in dem AFW arbeitet. Config-Keys (blank_eye / blank_eye_xr) bleiben nur fuers Laden stehen.
        -- [MONO_PROJ] Nur waehrend des Scope-Aims und nur wenn angehakt; beim Verlassen
        -- zwingend zurueck auf false, sonst bleibt die Projektion einaeugig stehen.
        if vrmod.set_mono_projection then
            vrmod:set_mono_projection(on and opt.mono_proj or false)
        end
        -- Zoom-Faktor (Stick regelt ihn); beim Verlassen neutral.
        vrmod:set_projection_zoom(on and opt.zoom or 1.0)
        vrmod:set_projection_fov(on and opt.fov or 0.0)
        -- Bild-Versatz -- beim Verlassen ZWINGEND auf 0, sonst haengt das ganze Spielbild schief.
        vrmod:set_image_shift_x(on and opt.img_x or 0.0)
        vrmod:set_image_shift_y(on and opt.img_y or 0.0)
    end)
end

-- Eigener pcall-Helfer: dieses Script hat kein `safe`.
local function bs(fn) local ok, r = pcall(fn); if ok then return r end end

-- =====================================================================
-- [FERNGLAS-RAND ENTFERNT 2026-08-17 -- AFW]
-- Hier lag ein `re.on_pre_gui_draw_element`-Callback, der den Rand im Fernglas
-- (Gui_ui2110 / bg_outside) skalierte, plus der Baum-Sucher `find_by_name` dafuer.
--
-- WARUM RAUS: Der Callback lief in JEDEM Frame fuer JEDES GUI-Element (zwei Engine-Calls
-- pro Element), und bei passendem Namen zusaetzlich ein rekursiver Baum-Lauf mit einem
-- SCHREIBZUGRIFF (`set_Scale`) mitten im GUI-Zeichnen. Er war der einzige GUI-Callback in
-- allen unseren Scripten, der in diesem Pfad schreibt statt nur zu lesen.
-- Sein Early-Out griff nur bei `bino_bg_scale == 1.0`; in der ausgelieferten
-- data/re4_vr/re4_vr_scope.json stand 0.99, er war also dauerhaft scharf -- auch im
-- Ladebildschirm, wo AFW seine Framebuffer aufbaut und bei fehlender Textur jeden Frame
-- `force_reset()` fahrt (D3D12Component.cpp:172). Der AFW-Absturz sitzt genau dort im
-- Present-Thread (PDAFWPlugin: Map liefert fuer das zweite Auge NULL, memcpy ungeprueft
-- dorthin), passt also zu einem Timing-Eingriff in genau diesem Pfad.
-- Der Fernglas-Weg laeuft ohnehin nicht ueber dieses Script (Versuch vom 10.08., wieder
-- verworfen -- der alte Weg ist zurueck), das Feature war also toter, aber aktiver Code.
-- Der Config-Key `bino_bg_scale` bleibt in den Defaults stehen, damit vorhandene JSONs
-- unveraendert laden; er wirkt nirgends mehr.
-- =====================================================================

-- (Der Fernglas-Rand-Block stand hier -- s. Notiz oben. Der pcall-Helfer `bs` weiter oben hat
--  damit keinen Aufrufer mehr; er bleibt als Helfer stehen, falls hier wieder etwas hinkommt.)

re.on_frame(function()
    if not probe_done then run_probe() end

    _G.__re4_scope_mono_enable = opt.mono
    -- [BOLT_PITCH_FREEZE] Hier und nicht nur im Tree: sonst stuende der Wert auf nil, solange
    -- das Menue nie geoeffnet wurde -- der Freeze waere dann schlicht aus.
    _G.__re4_bolt_pitch_hold = opt.bolt_pitch_hold

    -- [ENTPRELLEN] `__re4_scope_native` faellt zwischendurch kurz aus (Bolt-Fenster, ein Frame
    -- ohne ViaScope, Waffenwechsel-Zucker). Ohne Halte-Zeit schalten Mono, Projektion, Kamera
    -- und das schwarze Auge bei JEDEM dieser Aussetzer um -- genau das sieht man als Blitzen
    -- zwischen 3rd Person und Scope. Einschalten sofort, Ausschalten erst nach HOLD Sekunden.
    local raw_native = rawget(_G, "__re4_scope_native") == true
    if raw_native then
        scope_native = true
        native_off_t = nil
    elseif scope_native then
        native_off_t = native_off_t or os.clock()
        if (os.clock() - native_off_t) >= opt.hold then
            scope_native = false
            native_off_t = nil
        end
    end

    -- [BOLT_WIN 2026-08-09] Gemeinsames Fenster fuer alles, was beim Bolt-Schuss SOFORT
    -- aufhoeren muss: schwarzes Auge und Mono-Rendering. Die Halte-Zeit oben bleibt davon
    -- unberuehrt (sie haelt Projektion/Kamera ruhig) -- hier geht es nur um die zwei Sachen,
    -- die man im normalen Bild sofort als falsch sieht. Gleiche 1,10 s wie das Body-Einblenden
    -- in re4_vr_weapons.lua, damit beides zusammen passiert.
    local bolt_win = false
    do
        local st  = tonumber(rawget(_G, "__re4_bolt_shoot_t"))
        local wid = rawget(_G, "__re4_scope_wid")
        -- [ADA 2026-08-15] 6114 (Hunting Rifle, Separate Ways) ist derselbe Repetierer wie 4400.
        bolt_win = st ~= nil and (wid == 4400 or wid == 6114) and (os.clock() - st) < 1.10
        -- [AUGE-SCHWAERZEN RAUS 2026-08-17] Hier lag zusaetzlich `eye_keep` (Auge nach dem
        -- Bolt-Schuss stehen lassen, Regler `bolt_eye_hold`). Es hatte nur das schwarze Auge
        -- gesteuert und faellt mit ihm weg. `bolt_win` bleibt -- es haelt weiterhin das Mono.
    end

    _G.__re4_mono_request("scope", scope_native and opt.mono and not bolt_win)
    -- [MONO_MANUAL] Eigener Slot: der Handschalter haelt Mono unabhaengig von Scope und Karte.
    -- Bewusst jeden Frame gemeldet -- so kommt er nach "Reset Scripts" (leert `mono_reqs`)
    -- von selbst wieder, ohne dass man die Checkbox anfassen muss.
    _G.__re4_mono_request("manual", opt.mono_manual)

    mono_apply()
    proj_apply(scope_native)

    -- [AUGE-SCHWAERZEN RAUS 2026-08-17 -- AFW] Hier lag der Block, der `set_blank_eye` nachfuehrte
    -- (Ein-/Ausschalten am Scope-Eintritt, Sofort-Freigabe nach dem Bolt-Schuss). Er war die
    -- EINZIGE Stelle, die im Normalbetrieb -- also auch ohne Scope, direkt beim ersten Frame nach
    -- dem Laden -- einen Fork-Setter angefasst hat (Startwert war bewusst unmoeglich, damit einmal
    -- die -1 geschrieben wird). Wir fahren nur noch mit beiden Augen an, und der Fork steht
    -- ohnehin so (m_blank_eye = -1), also fasst das Script den Wert gar nicht mehr an.

    -- [SCOPE_SENS] Stick-Daempfung ABHAENGIG VOM ZOOM: rausgezoomt fast normal, voll
    -- reingezoomt langsam. Gerechnet wird hier, weil hier der Zoomfaktor lebt; angewandt
    -- wird er in re4_vr_binding.lua direkt vor dem vigem-Export.
    -- ACHTUNG: gilt fuer UNSEREN Projektions-Zoom (Stick). Laeuft die Projektion nativ
    -- ueber das Spiel (opt.proj_off), bleibt opt.zoom konstant -> dann wirkt ein fester
    -- Faktor statt einer Rampe.
    do
        local t = zoom_ramp()
        _G.__re4_scope_sens_factor = opt.sens_out + (opt.sens_in - opt.sens_out) * t
    end

    -- Gesammelt speichern: eine Sekunde nach der letzten Aenderung.
    if save_dirty and (os.clock() - save_t) > 1.0 then cfg_save() end

    -- Versatz live nachziehen, damit das Schieben im Headset sofort sichtbar ist
    -- (proj_apply setzt nur beim Ein-/Aussteigen).
    if scope_native and proj_supported then
        pcall(function()
            vrmod:set_image_shift_x(opt.img_x)
            vrmod:set_image_shift_y(opt.img_y)
        end)
    end

    -- [STICK_ZOOM] Nur waehrend des Scope-Aims und nur lesend.
    if scope_native and opt.stick_zoom and proj_supported then
        local y = 0.0
        pcall(function() y = vrmod:get_left_stick_axis().y or 0.0 end)

        if y > 0.3 or y < -0.3 then
            local z = opt.zoom + (y * opt.zoom_speed)
            if z < opt.zoom_min then z = opt.zoom_min end
            if z > opt.zoom_max then z = opt.zoom_max end

            if z ~= opt.zoom then
                opt.zoom = z
                pcall(function() vrmod:set_projection_zoom(z) end)
            end
        end
    end
end)

-- Nach "Reset Scripts" nicht im Mono stehenbleiben -- das Headset waere sonst bis zum
-- naechsten Zielen einaeugig.
re.on_script_reset(function()
    mono_reqs = {}
    if _G.__re4_fork_mono and not mono_fail and mono_state then
        pcall(function() vrmod:set_mono_rendering(false) end)
    end
    mono_state = false
    proj_apply(false)   -- sonst bliebe die ganze Welt gezoomt
    if save_dirty then cfg_save() end   -- nichts verlieren, was noch nicht auf Platte ist
end)

-- ---------------------------------------------------------------------
-- [BOLT_MUTE 2026-08-09] Der Repetier-Sound der Bolt Rifle (wp4400).
-- Die native Bolt-ANIM liess sich nicht unterdruecken (alle Wege gemessen und tot),
-- ihr SOUND aber schon: er laeuft als sieben Wwise-Events durch
-- soundlib.SoundManager.postEvent, und die Event-IDs sind ueber alle Schuesse
-- konstant (ueber drei Schuesse gemessen; die Zeit dahinter ist der Abstand zum
-- Schuss -- der spaeteste liegt bei +0.87 s, daher das 1,2-s-Fenster).
--
-- ENG GEGATET, die IDs sind NICHT dauerhaft stumm: geschluckt wird ausschliesslich
-- im Fenster nach einem echten Bolt-Schuss. `__re4_bolt_shoot_t` setzt allein
-- re4_vr_weapons.lua und nur bei wp4400 + echter Shoot-Node; ausserhalb laeuft der
-- Hook unveraendert durch. Der Schussknall selbst (2095290572) steht bewusst NICHT
-- in der Liste.
-- SKIP_ORIGINAL ohne Rueckgabewert waere Registermuell -> im Post-Hook sdk.to_ptr(0)
-- (bekannte Falle).
-- ---------------------------------------------------------------------
do
    local WINDOW = 1.20
    local IDS = {
        [ 748483445] = true,   -- +0.49s
        [1477056167] = true,   -- +0.52s
        [1441789338] = true,   -- +0.59s
        [2498172228] = true,   -- +0.74s
        [1357901439] = true,   -- +0.79s
        [2086827955] = true,   -- +0.85s
        [1545855344] = true,   -- +0.87s
    }

    local function muted(eid)
        if not eid or not IDS[eid] then return false end
        if opt.bolt_mute == false then return false end
        -- [ADA 2026-08-15] 6114 mitgenommen. Die Event-IDs oben sind an der 4400 gemessen --
        -- sind Adas Repetier-Sounds andere Events, passiert bei ihr schlicht nichts (die IDs
        -- kommen dann nie vor). Dauerhaft stumm wird nichts: das Fenster haengt weiter am
        -- Schuss-Stempel, den weapons.lua nur bei einem echten Bolt-Schuss setzt.
        local _mw = rawget(_G, "__re4_scope_wid")
        if _mw ~= 4400 and _mw ~= 6114 then return false end
        local t = tonumber(rawget(_G, "__re4_bolt_shoot_t")); if not t then return false end
        local dt = os.clock() - t
        return dt >= 0.0 and dt <= WINDOW
    end

    local td = sdk.find_type_definition("soundlib.SoundManager")
    local ms = td and (function() local ok, r = pcall(function() return td:get_methods() end)
                       if ok then return r end end)() or {}
    for _, m in ipairs(ms) do
        local nm = (function() local ok, r = pcall(function() return m:get_name() end)
                    if ok then return r end end)()
        local np = tonumber((function() local ok, r = pcall(function() return m:get_num_params() end)
                             if ok then return r end end)()) or 0
        if nm == "postEvent" and np == 7 then
            -- postEvent ist static -> args[2] = erster Parameter (RequestId),
            -- args[3] = EventId. (Bei Instanzmethoden waere args[2] das "this".)
            local skipped = false
            pcall(sdk.hook, m,
                function(args)
                    local v = (function() local ok, r = pcall(function() return tonumber(sdk.to_int64(args[3])) end)
                               if ok then return r end end)()
                    if v and muted(v % 4294967296) then
                        skipped = true
                        return sdk.PreHookResult.SKIP_ORIGINAL
                    end
                end,
                function(retval)
                    if skipped then skipped = false; return sdk.to_ptr(0) end
                    return retval
                end)
        end
    end
end

-- ---------------------------------------------------------------------
-- [CAM_OFF] Kamera-Versatz im Scope-Zoom. Baugleich zu apply_turret_hmd_offset
-- (re4_vr_firstperson.lua): Primary Camera holen, Position verschieben, fertig.
-- Laeuft bewusst OHNE Killswitch-Gate -- firstperson selbst ist im Scope aus (KS1).
-- Der Offset wird mit der Kamera-Rotation gedreht, ist also blickrelativ.
-- ---------------------------------------------------------------------
-- Waffen-Pitch in Grad -- die Achse, auf der die Punkte liegen.
-- WICHTIG: `__re4_scope_aim_pitch` wird NUR im Scope fortgeschrieben. Das Menue bedient
-- man aber ausserhalb (im Headset ist ImGui unlesbar), dort stuende sonst immer 0
-- und jeder SET landete bei 0 Grad. Darum halten wir den letzten Winkel AUS dem Scope
-- fest -- der bleibt stehen, bis wieder gezielt wird.
-- ZWEI Winkel, streng getrennt:
-- scope_pitch_deg = der ECHTE, sofortige Pitch. Nur der steuert die Kurve -- alles
-- Verzoegerte hier drin laesst die Kamera nachlaufen und die Waffe
-- wippen (2026-08-08 genau so passiert).
-- scope_set_deg = derselbe Wert, aber HOLD_BACK Sekunden alt und ausserhalb des
-- Scopes eingefroren. Nur fuer SET und die Anzeige: beim Verlassen
-- des Scopes senkt man die Waffe und der Pitch liefe sonst bis ~0.
--
-- [KAMERA-PITCH 2026-08-09 -- VERWORFEN] Nach dem Bolt-Zyklus springt der Waffen-Pitch um
-- +16..28 Grad (Waffe real verkippt); der Kamera-Pitch macht das nicht mit und sah darum
-- nach der besseren Quelle aus. Im Spiel war es nur ANDERS schief: der Blick-Freeze in
-- movement.lua muss der Waffe folgen (Scope sitzt an ihr), und zwei Quellen fuer dieselbe
-- Groesse schaukeln sich auf. Ursache ist die verkippte Waffe -- dort ansetzen, nicht hier.

local last_scope_deg, deg_hist = 0.0, {}
local HOLD_BACK = 0.5
local function scope_pitch_deg()
    -- [2026-08-09] Hier stand testweise der KAMERA-Pitch fuer wp4400. Wieder raus: der
    -- Blick-Freeze in movement.lua muss der WAFFE folgen (das Scope sitzt an ihr), und
    -- zwei verschiedene Quellen fuer dieselbe Groesse schaukeln sich auf
    -- (bekannte Falle). Beide laufen wieder auf dem Waffen-Pitch.
    --
    -- [WICHTIG 2026-08-09] Fehlt der Pitch, ist der Ersatz **0** (= Mitte) -- genau wie im
    -- alten Code (`... or 0.0`). NICHT `last_scope_deg`: das ist der 0.5 s alte Wert aus
    -- dem LETZTEN Zielvorgang, und beim Verlassen senkt man die Waffe, der steht also gern
    -- bei -40 Grad. Beim Neu-Ansetzen zog die Kurve dann kurz diesen Winkel und das Bild
    -- rutschte sichtbar an seinen Platz. `last_scope_deg` ist ausschliesslich der Winkel
    -- fuer den SET-Knopf und hat in der Steuerung nichts verloren.
    local p = tonumber(rawget(_G, "__re4_scope_aim_pitch"))

    if not scope_native then
        deg_hist = {}
        return p or 0.0
    end

    if not p then return 0.0 end

    local now = os.clock()
    deg_hist[#deg_hist + 1] = { now, p }
    while #deg_hist > 0 and (now - deg_hist[1][1]) > HOLD_BACK do
        last_scope_deg = deg_hist[1][2]
        table.remove(deg_hist, 1)
    end
    return p                    -- LIVE, ohne Verzoegerung
end

local function scope_set_deg()
    return last_scope_deg
end

-- Ziehen am Regler friert den Winkel ein (live_deg) und haelt den Wert, bis SET kommt.
-- KEIN automatisches Ende: man justiert am Desktop, waehrend die Controller
-- irgendwo liegen -- ein winkelabhaengiger Abbruch wirft die Einstellung dann weg.
local live_on, live_deg = false, 0.0
local set_note = ""   -- kurze Rueckmeldung unter dem SET-Knopf
local SET_MERGE = 3.0
-- [ 2026-08-08] Jeder Punkt gilt in einem Fenster von +-PLATEAU Grad voll. Ohne das
-- muesste man den Winkel exakt treffen, um seine Einstellung wiederzusehen -- mit der
-- Hand in VR unmoeglich. Geblendet wird erst zwischen den Fenstern.
local PLATEAU = 3.0

-- [SCOPE_ID] Welcher Optik gehoeren die Punkte gerade? `__re4_scope_id` setzt weapons.lua
-- aus der montierten Attachment-ItemID (normal / thermal / hipower), "ironsight" wenn
-- nichts montiert ist. Der zuletzt gesehene Wert wird gehalten -- beim Bedienen des
-- Menues ausserhalb des Zielens steht die Globale sonst evtl. auf nil.
local last_scope_id  = "normal"
-- (der Halter fuer die Waffen-ID sitzt jetzt weiter oben als `last_raw_wid`/`scope_raw_wid`,
--  damit ihn auch `pitch_y_at` sehen kann -- Local-Reihenfolge)
local function scope_id_now()
    local s = rawget(_G, "__re4_scope_id")
    if type(s) == "string" then
        last_scope_id = s
    elseif rawget(_G, "__re4_scope_wid") ~= nil then
        -- Scope-Waffe in der Hand, aber nichts montiert -> eigene Liste "ironsight".
        last_scope_id = "ironsight"
    end
    return last_scope_id
end

-- [PRO WAFFE] Welche Scope-Waffe liegt in der Hand? Wie oben wird der letzte Wert gehalten:
-- beim Bedienen des Menues am Desktop steht die Globale sonst evtl. auf nil und alle
-- Aenderungen landeten in der falschen Liste.
local function scope_wid_now()
    -- Ein einziger Halter fuer den rohen Wert (scope_raw_wid, ganz oben) -- zwei Halter
    -- fuer dieselbe Groesse laufen frueher oder spaeter auseinander.
    local last_scope_wid = scope_raw_wid()
    -- [ADA 1:1 2026-08-15] Adas Nachbauten benutzen die Punktliste ihrer Vorlage DIREKT,
    -- statt eine eigene Kopie zu fuehren -- genau wie beim Augen-Versatz in
    -- re4_vr_movement.lua. Damit fuehlt sich Ada exakt wie Leon an, und jedes Nachstellen
    -- an Leon wirkt sofort mit. ACHTUNG, die Kehrseite: der SET-Knopf schreibt bei Ada dann
    -- ebenfalls in Leons Liste -- getunt wird also immer BEIDES zugleich.
    -- RUECKBAU: `_G.__re4_ada_uses_leon_scope = false` (dann wieder eigene Listen).
    if rawget(_G, "__re4_ada_uses_leon_scope") ~= false then
        if     last_scope_wid == 6105 then return 4401
        elseif last_scope_wid == 6114 then return 4400 end
    end
    return last_scope_wid
end

-- Schluessel der Punktliste: PRO WAFFE und PRO OPTIK, z.B. "4401_normal".
local function scope_key_now()
    return string.format("%d_%s", scope_wid_now(), scope_id_now())
end


-- [ADA-KLONE 2026-08-09] Separate Ways hat zwei 1:1-Nachbauten der Kampagnen-Waffen:
-- 6105 (Anti-Materiel) = Stingray 4401, 6114 (Hunting Rifle) = SR M1903 4400. Deren Punkte
-- lassen sich per Knopf im Tree uebernehmen, statt sie zweimal von Hand zu setzen.
-- Kopiert wird TIEF (eigene Tabellen) -- sonst haetten Original und Klon dieselbe Liste und
-- ein spaeteres Nachjustieren am Klon wuerde das Original mitziehen.
local CLONE_MAP = { [6105] = 4401, [6114] = 4400 }   -- Klon -> Vorlage

local function copy_to_clones()
    -- Erst sammeln, dann schreiben: neue Schluessel waehrend eines pairs-Laufs einzufuegen
    -- ist in Lua nicht erlaubt.
    local todo = {}
    for k, list in pairs(opt.kfs_sets) do
        local w, id = k:match("^(%d+)_(.+)$")
        local src = w and tonumber(w)
        if src and id and type(list) == "table" and #list > 0 then
            for clone, from in pairs(CLONE_MAP) do
                if from == src then
                    todo[#todo + 1] = { key = string.format("%d_%s", clone, id), src = list }
                end
            end
        end
    end
    for _, t in ipairs(todo) do
        local dst = {}
        for _, e in ipairs(t.src) do
            dst[#dst + 1] = { deg = e.deg, x = e.x, y = e.y, z = e.z, zoom = e.zoom }
        end
        opt.kfs_sets[t.key] = dst
    end
    return #todo
end

-- Nur fuer die Anzeige im Tree -- wid allein sagt einem am Desktop wenig.
local WEAPON_NAMES = {
    [4202] = "LE 5",
    [4400] = "SR M1903",
    [4401] = "Stingray",
    [4402] = "CQBR Assault Rifle",
    [6105] = "Anti-Materiel (SW)",
    [6114] = "Hunting Rifle (SW)",
}

-- Die Punktliste dieser Waffe mit dieser Optik (wird bei Bedarf leer angelegt).
local function cur_kfs()
    local k = scope_key_now()
    if type(opt.kfs_sets[k]) ~= "table" then opt.kfs_sets[k] = {} end
    return opt.kfs_sets[k]
end

-- [WICHTIG] Der Live-Regler ist ein PUNKT AN live_deg, kein globaler Wert. Frueher galt
-- er waehrend des Ziehens ueberall -- man stellte oben ein und die Mitte war hinueber.
-- Jetzt wird er als temporaerer Punkt in die Kurve gehaengt (und verdeckt dabei einen
-- echten Punkt, der ohnehin ueberschrieben wuerde). Alle anderen Punkte bleiben stehen.
local function curve_points()
    if not live_on then return cur_kfs() end

    local list = {}
    for _, e in ipairs(cur_kfs()) do
        local d = e.deg - live_deg; if d < 0.0 then d = -d end
        if d > SET_MERGE then list[#list + 1] = e end
    end
    list[#list + 1] = { deg = live_deg, x = opt.cam_x, y = opt.cam_y, z = opt.cam_z }
    table.sort(list, function(a, b) return a.deg < b.deg end)
    return list
end

-- Kurvenwert bei diesem Winkel: zwischen den zwei umschliessenden Punkten linear,
-- ausserhalb der Randpunkte deren Wert (kein Extrapolieren -- das kippt nur weg).
local function scope_curve(pts, deg)
    local n = #pts
    if n == 0 then return 0.0, 0.0, 0.0 end

    local a = pts[1]
    if n == 1 or deg <= a.deg then return a.x, a.y, a.z end

    local b = pts[n]
    if deg >= b.deg then return b.x, b.y, b.z end

    for i = 1, n - 1 do
        local p, q = pts[i], pts[i + 1]
        if deg >= p.deg and deg <= q.deg then
            -- Plateau um beide Punkte; die Blende laeuft nur vom Ende des einen bis zum
            -- Anfang des anderen Fensters. Liegen die Punkte enger als zwei Plateaus,
            -- wird stattdessen ueber die volle Strecke geblendet.
            local pa, qb = p.deg + PLATEAU, q.deg - PLATEAU
            if qb <= pa then pa, qb = p.deg, q.deg end
            if deg <= pa then return p.x, p.y, p.z end
            if deg >= qb then return q.x, q.y, q.z end

            local span = qb - pa
            local u = (span > 0.0001) and ((deg - pa) / span) or 0.0
            return p.x + (q.x - p.x) * u,
                   p.y + (q.y - p.y) * u,
                   p.z + (q.z - p.z) * u
        end
    end
    return b.x, b.y, b.z
end

-- Was gerade wirken soll -- und zugleich das, was die Regler anzeigen.
-- Kein Zoom im Spiel: der Offset ist reine Geometrie, sonst wandern bei Vollzoom auch
-- X/Y und das Crosshair sitzt nicht mehr mittig (2026-08-08 im Spiel geprueft).
local function scope_cam_xyz()
    local deg = scope_pitch_deg()
    local pts = curve_points()
    if #pts == 0 then return opt.cam_x, opt.cam_y, opt.cam_z, deg, true end

    local x, y, z = scope_curve(pts, deg)
    -- Waehrend des Ziehens NICHT zurueckschreiben, sonst frisst die Kurve die Eingabe.
    if not live_on then opt.cam_x, opt.cam_y, opt.cam_z = x, y, z end
    return x, y, z, deg, live_on
end

-- Punkt beim aktuellen Winkel setzen. Liegt schon einer dichter als SET_MERGE Grad daneben,
-- wird der ueberschrieben statt ein zweiter danebengelegt.
local function scope_set_point(deg)
    local list = cur_kfs()

    -- [SET_GILT_SOFORT 2026-08-14] Steht schon eine Kurve, wird sie um GENAU die Differenz
    -- verschoben, die man am Regler gezogen hat -- alle Punkte mit. Vorher wurde nur der
    -- Punkt am SET-Winkel geschrieben; zeigte die Waffe beim Klicken woandershin, rechnete
    -- der naechste Tick wieder den alten Nachbarpunkt und die Einstellung war scheinbar
    -- weg. So gilt der eingestellte Wert sofort, egal wo der Pitch gerade steht -- die
    -- Form der Kurve (oben/unten) bleibt dabei erhalten, die alten Absolutwerte nicht.
    -- Einzelne Punkte gezielt aendern geht weiterhin im Zweig "Punkte bearbeiten".
    if #list > 0 then
        local bx, by, bz = scope_curve(list, deg)
        local dx, dy, dz = opt.cam_x - bx, opt.cam_y - by, opt.cam_z - bz

        -- [SET_KENNT_DEN_ZOOM 2026-08-15] Die Punktkurve haengt am PITCH und gilt in jedem
        -- Zoom -- wer bei Vollzoom mit ihr korrigiert, verstellt das ausgezoomte Bild gleich
        -- mit. Darum entscheidet SET nach dem aktuellen Zoom, wohin X/Y wandern:
        --   rausgezoomt (Rampe < 0.5) -> in die Kurve, die Basis fuer alle Zoomstufen.
        --   reingezoomt (Rampe >= 0.5) -> in `zoom_x`/`zoom_y`, die ausgezoomt null sind
        --   und die Basis deshalb nicht anfassen koennen.
        -- Hochgerechnet wird auf VOLLZOOM (`/ t`), weil die Regler dort ihren vollen Wert
        -- haben; bei t = 1 ist das genau das gezogene Delta. Z bleibt immer die Kurve --
        -- die Tiefe ist Geometrie und hat keinen Zoom-Anteil.
        local t = zoom_ramp()
        if t >= 0.5 then
            opt.zoom_x = (tonumber(opt.zoom_x) or 0.0) + (dx / t)
            opt.zoom_y = (tonumber(opt.zoom_y) or 0.0) + (dy / t)
            if dz ~= 0.0 then
                for _, e in ipairs(list) do e.z = (e.z or 0.0) + dz end
            end
            live_on = false
            return string.format("in den Zoom-Versatz uebernommen (Zoom %.2f)", opt.zoom)
        end

        for _, e in ipairs(list) do
            e.x, e.y, e.z = (e.x or 0.0) + dx, (e.y or 0.0) + dy, (e.z or 0.0) + dz
        end
        live_on = false
        return "uebernommen (" .. #list .. " Punkte mitgezogen)"
    end
    list[#list + 1] = { deg = deg, x = opt.cam_x, y = opt.cam_y, z = opt.cam_z,
                        zoom = opt.zoom }
    table.sort(list, function(a, b) return a.deg < b.deg end)
    live_on = false
    return "neu"
end

-- [BOLT_FREEZE 2026-08-09 -- VERWORFEN] Versuch, die Kamera-Position waehrend des
-- Bolt-Zyklus festzuhalten, damit die Engine einen nicht aus dem Zoom holt. Im Spiel
-- passierte GENAU DASSELBE wie vorher, und nach der Anim hing das Scope zusaetzlich
-- schief. Die Position ist also nicht der Hebel -- nicht nochmal probieren.
local function apply_scope_cam_offset()
    if not scope_native then return end

    -- [KEIN ERSATZWINKEL 2026-08-09] Liegt der Waffen-Pitch noch nicht an, wird GAR
    -- NICHTS geschrieben. Jeder Ersatzwert erzeugt einen sichtbaren Zwischenzustand:
    -- mit `last_scope_deg` (letzter Winkel, oft vom Absenken) rutschte das Bild zurecht,
    -- mit 0.0 (Mitte) sprang es. Beides falsch -- lieber einen Frame keinen Offset als
    -- einen Frame den falschen.
    if tonumber(rawget(_G, "__re4_scope_aim_pitch")) == nil then return end

    local ox, oy, oz, cur_deg = scope_cam_xyz()

    -- [PITCH_Y 2026-08-15] Hoehenausgleich ueber den Winkel -- wie die Zoom-Anteile NACH der
    -- Kurve und NACH dem Ruecklesen in opt.cam_*, sonst steht er in der Regleranzeige und
    -- der SET-Knopf backt ihn in die Punkte ein.
    local py = pitch_y_at(cur_deg)

    -- [ZOOM_X 2026-08-14] Linearer Seitversatz ueber den Zoom, NACH der Kurve und NACH dem
    -- Ruecklesen in opt.cam_* -- exakt aus demselben Grund wie beim XR-Delta unten: sonst
    -- steht er in der Regleranzeige und der SET-Knopf backt ihn in die Punkte ein.
    -- [ZOOM_X_MID 2026-08-14] Kurve statt Gerade: `zoom_x_now()` liefert je nach Schalter
    -- die alte lineare Rampe oder den Verlauf ueber den mittleren Stuetzpunkt.
    local zx = zoom_x_now()
    local zy = zoom_y_now()

    -- Erst der Kurvenwert: hat diese Waffe+Optik noch gar keine Punkte, bleibt es beim
    -- nativen Bild -- dann darf auch das XR-Delta nichts verschieben. Stehen die Zoom-Regler
    -- aber auf einem Wert, gelten sie trotzdem: die haengen am Zoom, nicht an den Punkten.
    if ox == 0.0 and oy == 0.0 and oz == 0.0 and zx == 0.0 and zy == 0.0 and py == 0.0 then
        _G.__re4_scope_off_x, _G.__re4_scope_off_y, _G.__re4_scope_off_z = 0.0, 0.0, 0.0
        return
    end

    ox = ox + zx
    oy = oy + zy + py

    -- [XR_DELTA 2026-08-11] Pauschaler Runtime-Versatz, NACH der Kurve und NACH dem
    -- Ruecklesen in opt.cam_* (Z.~911). Genau in dieser Reihenfolge, sonst wandert das
    -- Delta in die Regleranzeige und der SET-Knopf backt es in die Punkte ein -- ab dann
    -- zaehlte es doppelt und OpenVR waere gleich mit verstellt.
    if detect_runtime() == true then
        ox, oy = ox + opt.xr_dx, oy + opt.xr_dy
    end

    -- [OFF_NOW] Der Offset, der in diesem Pass wirklich geschrieben wird -- reine Information
    -- fuer Diagnose/Anzeige (die Kurve ist von aussen sonst nicht nachvollziehbar).
    _G.__re4_scope_off_x, _G.__re4_scope_off_y, _G.__re4_scope_off_z = ox, oy, oz

    local cam = sdk.get_primary_camera(); if not cam then return end

    pcall(function()
        local cgo = cam:call("get_GameObject"); if not cgo then return end
        local ctf = cgo:call("get_Transform"); if not ctf then return end

        local p = ctf:get_position(); if not p then return end
        local r = ctf:call("get_Rotation")

        local dx, dy, dz = ox, oy, oz
        if r then
            local d = r * Vector3f.new(ox, oy, oz)
            dx, dy, dz = d.x, d.y, d.z
        end

        ctf:set_position(Vector4f.new(p.x + dx, p.y + dy, p.z + dz, p.w), true)
    end)
end

-- Multi-Hook wie in firstperson: die Engine schreibt das Kamera-Joint zwischen den
-- Phasen zurueck, mit nur einem Hook bliebe die Kamera "unveraendert".
re.on_pre_application_entry("UnlockScene", apply_scope_cam_offset)
re.on_application_entry("LateUpdateBehavior", apply_scope_cam_offset)
re.on_application_entry("BeginRendering", apply_scope_cam_offset)

-- ---------------------------------------------------------------------
-- UI -- reine Anzeige. Platz 60 (10..50 sind laut ##re4_vr_menu.lua vergeben).
-- ---------------------------------------------------------------------
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - Scope" raus (306 Zeilen: Zeichenfunktion + Registrierung). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.


