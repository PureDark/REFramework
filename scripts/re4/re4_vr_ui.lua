-- Builtin implementation: src/mods/vr/games/re4/RE4VRUI.cpp
return

-- ============================================================
-- re4_vr_ui.lua -- Karte in VR korrekt rendern
-- ============================================================
-- Die Karte wird in VR falsch gerendert, solange REFramework die GUI-Projektionsmatrix
-- ueberschreibt. Unser Fork kann diesen Override aus Lua schalten:
-- vrmod:set_gui_projection_matrix_override_disabled(true/false)
--
-- Getriggert wird ueber die MAP SELBST (chainsaw.MapManager:isMapGuiOpen), NICHT ueber
-- das Binding -- egal ob die Karte per Links-A (Leon lang / Ada kurz), per Gamepad-BACK,
-- ueber ein Menue oder sonstwie aufgeht, der Fix greift.
--
-- Auf einem normalen/vanilla REFramework existiert die Methode nicht. Das wird EINMAL
-- erkannt (ohne sie aufzurufen), danach macht dieses Script schlicht nichts -- kein Fehler,
-- kein Log-Spam, die Karte geht dort halt wie gehabt auf.
--
-- Kein sdk.hook -> "Reset Scripts" reicht, kein Spielneustart noetig.
-- ============================================================

-- ZWEI GETRENNTE SCHALTER (2026-08-07). Beide wirken nur solange die Karte offen ist und
-- sind EINZELN umlegbar, weil sie an verschiedenen Ebenen der Karte ziehen:
-- * gui_matrix: REFrameworks GUI-Projektions-Override AUS. Betrifft den GUI-Renderpfad,
-- also die Icons/Marker, die AUF der Karte liegen.
-- * mono: beide Augen rendern aus derselben Augenposition. Betrifft die 3D-Szene
-- der Karte selbst (Grundriss-Mesh) -- nimmt die Disparitaet zwischen den
-- Augen weg, aber NICHT die Perspektive: die Ebenen der Karte stehen
-- weiterhin raeumlich auseinander, weil unser Frustum nicht das der
-- Original-Kamera ist.
-- Live umschaltbar im REFramework-Menue -> Tree "RE4VR - UI" (wirkt sofort, auch bei
-- offener Karte, kein "Reset Scripts" noetig).
-- * canvas: Flatscreen-Leinwand. Das Spiel rendert waehrenddessen sein NATIVES
-- Monitor-Bild (alle Kamera-Overrides ausgesetzt) und dieses fertige
-- Bild haengt als flaches Quad vor dem Kopf -- das ist der einzige Weg,
-- bei dem die Karten-Ebenen zueinander sitzen wie am TV.
-- * gui_elem: verhindert, dass die VR-Mod die EINZELNEN GUI-Elemente im Raum
-- platziert (der Pfad hinter "2D UI Distance"/"World-Space UI Scale").
-- Gehoert sachlich zu gui_matrix: die Karten-Kamera ist ORTHOGRAFISCH
-- (live gemessen 2026-08-07: get_ProjectionType = OrthographicRH), dort
-- gibt es gar keine Parallaxe -- alle Ebenen liegen exakt uebereinander.
-- Bleibt diese Matrix stehen, waehrend die Elemente trotzdem einzeln im
-- Raum sitzen, driften Icons/Marker gegen den Umriss. Genau das ist der
-- Rest-Fehler, den gui_matrix allein nicht wegbekommt.
-- * suspend:  [2026-08-10] VR komplett aussetzen -- der Fork parkt ALLE Engine-Eingriffe
--             auf einmal (Kamera, Projektion, GUI-Projektion, GUI-Elemente, HMD-Groesse
--             fuer den Backbuffer, Engine-Overlays, PostEffect-Fix). Das Spiel rendert
--             dann exakt wie flach -- inklusive der orthografischen GUI-Kamera, an der
--             die Karte sonst scheitert -- und beide Augen bekommen dasselbe Bild.
--             Anders als `canvas` ist das kein zweiter Layer VOR dem VR-Bild, sondern
--             das VR-Bild selbst faellt weg; Frames werden weiter abgeliefert, das
--             Headset friert also nicht ein.
local opt = {
    gui_matrix = true,   -- bisheriges Verhalten
    -- [2026-08-09] Startwert AUS. Der Schalter gehoert sachlich zu gui_matrix, hat die
    -- driftenden Icons aber nicht repariert -- er soll nach "Reset Scripts" nicht von selbst
    -- wieder anstehen, sondern nur wenn man ihn im Tree "RE4VR - UI" bewusst setzt.
    gui_elem   = false,
    mono       = false,  -- brachte bei der Karte nichts
    canvas     = false,  -- brachte bei der Karte nichts
    -- [2026-08-10] getestet: kein flaches Bild, die Ebenen driften weiter -> bringt nichts
    suspend    = false,
    -- * binoglue: [2026-08-11] derselbe Pin wie mapglue, aber fuer das Fernglas-UI (2110).
    binoglue   = false,
    -- * mapglue: [2026-08-10] Fork-Neubau. Der Fork heftet sonst JEDE Karten-Ebene einzeln
    --   vor die SPIELKAMERA und dreht sie aus ihrem eigenen Abstand zum Auge -- der Kopf
    --   bewegt sich unabhaengig davon, und genau das schiebt Umriss, Navkreuz und Funde
    --   gegeneinander. Mit dem Haken bekommen alle sechs Karten-GUIs denselben Anker
    --   (den Kopf), dieselbe Distanz und dieselbe Rotation.
    mapglue    = false,
}

-- Abstand der gepinnten Karte vor dem Kopf, in Metern. Nur wirksam solange mapglue laeuft.
local glue_distance = 1.5
-- Staffelung der Karten-Ebenen in METERN. Bei exakt 0 liegen alle in derselben Ebene, dann
-- entscheidet die Zeichenreihenfolge -- und eine deckende Ebene schluckt den Kartenumriss
-- (genau das passierte beim ersten Test). 0.002 = 2 mm, bei 1,5 m Abstand unsichtbar.
local glue_gap = 0.002

-- Groesse/Abstand der Leinwand in Metern. Nur wirksam solange canvas laeuft.
local canvas_width    = 2.5
local canvas_distance = 2.0

-- ---------------------------------------------------------------------
-- EINZELNE KARTEN-GUIs (2026-08-09 -- per Wegwerf-Logger gefunden)
-- Gui_ui3121: stoert in VR -> wird gar nicht erst gezeichnet (Startwert AN,
-- d.h. ausgeblendet). Alle anderen Karten-GUIs bleiben unangetastet.
-- Gui_ui3101: Groesse frei regelbar. Gesetzt wird ABSOLUT auf den Reglerwert
-- (Basis ist 1.0) -- nie gegen den gelesenen Ist-Wert, sonst
-- schaukelt sich der Wert pro Frame auf.
-- Beides wirkt nur, solange die Karte offen ist.
-- ---------------------------------------------------------------------
local HIDE_NAME    = "Gui_ui3121"
local SCALE_NAME   = "Gui_ui3101"
local BG_NAME      = "AcBackGround"   -- Hintergrund: in Karte UND Koffer weg
-- NUR im Hauptmenue weg. Liste, damit ein weiterer Name eine Zeile ist und sonst nichts.
local MENU_NAMES   = { ["Gui_ui0502"] = true, ["Gui_ui0501"] = true }
-- GUIs, die im GANZEN Spiel gelten (nicht nur Karte/Koffer/Hauptmenue). Jeder Eintrag
-- hat seinen eigenen Haken; der Schluessel ist der Name des Schalters in der JSON.
local GLOBAL_GUIS = {
    { name = "Gui_ui2041", key = "hide_dot",      label = "Mittel-Dot ausblenden (ganzes Spiel)" },
    { name = "Gui_ui2152", key = "hide_vignette", label = "Damage-Vignette ausblenden (ganzes Spiel)" },
    { name = "Gui_ui2151", key = "hide_vignette2", label = "Damage-Vignette2 ausblenden (ganzes Spiel)" },
}
local hide_3121    = true
-- Startwerte der GLOBAL_GUIS -- in EINER Tabelle, damit Persistenz und Draw-Hook
-- generisch bleiben und ein neuer Eintrag oben genuegt.
local global_hide = { hide_dot = true, hide_vignette = true, hide_vignette2 = true }
local hide_bg      = true
local ui3101_scale = 1.0

-- ---------------------------------------------------------------------
-- VIEWTYPE-VERSUCH (2026-08-10) -- gegen die Parallaxe der Karten-Ebenen
-- ---------------------------------------------------------------------
-- Befund: die Ebenen der Karte liegen in VR auf UNTERSCHIEDLICHER TIEFE. Am Desktop
-- faellt das nicht auf, im HMD schiebt jede Kopfbewegung sie per Parallaxe gegeneinander
-- (Umriss, Navigationskreis, Marker/Funde). Kein 2D-Eingriff (gui_matrix, gui_elem,
-- mono, canvas, suspend) erreicht das -- alle fuenf sind daran gescheitert.
--
-- Das Spiel kennt `via.gui.ViewType { Screen = 0, World = 1 }`. Eine View auf Screen
-- gestellt landet im 2D-UI-Pfad und damit auf EINER festen Distanz statt auf ihrer
-- eigenen Tiefe -- wenn die Engine das zur Laufzeit mitmacht, sitzen alle Ebenen
-- danach in derselben Ebene und die Parallaxe ist konstruktiv weg.
--
-- KEIN Parenting: die Hierarchie wird nicht angefasst (das war schon einmal der Weg,
-- bei dem der umgehaengte Layer unsichtbar wurde). Hier wird nur eine Eigenschaft der
-- View gesetzt, jeder Layer bleibt wo er ist.
--
-- Die vier Namen sind der Messbefund von 2026-08-09 weiter unten -- explizite Liste,
-- kein Praefix-Raten. Der Ist-Wert wird pro Name EINMAL gemerkt und beim Ausschalten
-- wieder zurueckgeschrieben (die View holen wir uns jeden Frame frisch, es haengt also
-- keine Referenz herum, die ein Save-Load toeten koennte).
--
-- [2026-08-10 ERSTER TEST, alle vier auf Screen] Umriss und Navigationskreuz kleben
-- danach aneinander, die Funde wandern weiter. Gewuenscht ist genau andersherum:
-- Umriss + Funde fest, Navikreuz weiter beweglich. Deshalb ist der Schalter jetzt
-- PRO LAYER -- welche Ebene auf Screen gehoert, entscheidet der Versuch, nicht wir.
--
-- [ROLLEN 2026-08-10, vom User im HMD identifiziert -- nicht nochmal raten]
--   Gui_ui3100 = Navigationskreuz -> muss NORMAL bleiben, steht deshalb bewusst NICHT
--                in dieser Liste und wird von diesem Schalter nie angefasst.
--   Gui_ui3101 = die Funde        -> sollen mit der Karte zusammenkleben
--   Gui_ui3104 = die Karte        -> Partner der Funde
-- Ziel ist also: 3104 + 3101 auf Screen, 3100 in Ruhe lassen.
-- Nur 3120 steht hier: die Haken fuer 3104/3101/3121 sind am 2026-08-10 wieder raus,
-- weil diese Ebenen schon Screen SIND und der Haken dort nachweislich nichts tun kann.
local MAP_VIEWS = {
    { name = "Gui_ui3120", key = "vt_3120", label = "Karte-Ebene (3120) auf Screen" },
}
-- [name] -> key, damit der Draw-Hook in einer Zeile nachschlagen kann.
local MAP_VIEW_KEY = {}
for i = 1, #MAP_VIEWS do MAP_VIEW_KEY[MAP_VIEWS[i].name] = MAP_VIEWS[i].key end
local vt_on = { vt_3120 = false }
local VIEWTYPE_SCREEN = 0
local VIEWTYPE_WORLD  = 1
local vt_orig  = {}   -- [name] = urspruenglicher ViewType, nur solange umgestellt
-- NOTAUS. "Reset Scripts" kann den gemerkten Ist-Wert nicht zurueckschreiben (die Views
-- sind dann weg), die Ebene bleibt also auf Screen stehen und der naechste Durchlauf
-- merkt sich Screen als "Original" -- ab da bringt kein Haken sie mehr zurueck.
-- Dieser Knopf schreibt allen vier Ebenen ABSOLUT World (1), egal was gemerkt ist.
-- Wirkt beim naechsten Zeichnen, also einmal die Karte aufmachen.
local vt_force = nil   -- Set der noch zu erzwingenden Namen, nil = nichts zu tun
local vt_seen  = {}    -- [name] = zuletzt GELESENER ViewType (Diagnose fuer die Statuszeile)
-- ---------------------------------------------------------------------
-- MESSBEFUND 2026-08-10 (Log-Diagnose, Karte offen) -- nicht nochmal messen
-- ---------------------------------------------------------------------
-- Bei offener Karte gezeichnet und ihr ViewType:
--   Gui_ui3120 = 1 (World)   <-- die EINZIGE Ebene, die nicht schon Screen ist
--   Gui_ui3100 (Navkreuz), Gui_ui3101 (Funde), Gui_ui3103, Gui_ui3104 (Karte),
--   Gui_ui3121, Gui_ui3030, Gui_ui3006, Gui_ui2170, Gui_ui2031, WhiteFade,
--   BlackFade, Gui_ui0300, Gui_ui0200 = alle 0 (Screen); AcBackGround = 1 (World).
-- Daraus folgt: die drei anderen Haken KOENNEN nichts bewirken, sie schreiben Screen auf
-- etwas, das schon Screen ist. Nur 3120 ist ein echter Hebel -- und der klebt Navkreuz
-- und Karte zusammen. Der Restfehler der Funde ist also KEIN ViewType-Thema mehr.

-- ICON-MITWANDERN -- Erklaerung und Messbefund stehen weiter unten beim Code.
-- Die Variablen MUESSEN hier oben stehen: der Persistenz-Block direkt darunter
-- liest und schreibt sie, und eine erst spaeter definierte local waere fuer ihn
-- eine ganz andere (globale) Variable -- der Block liefe dann lautlos ins Leere.

local function safe(fn) local ok, r = pcall(fn); if ok then return r end end

-- ---------------------------------------------------------------------
-- PERSISTENZ (2026-08-09) -- alle Schalter dieses Trees liegen in
-- reframework\data\re4_vr\re4_vr_ui.json
-- Geschrieben wird VERZOEGERT (0,5 s nach der letzten Aenderung), damit das Ziehen
-- eines Sliders nicht pro Frame eine Datei schreibt.
-- ---------------------------------------------------------------------
-- [ZEIGESTRAHL-PITCH 2026-08-15] Neigung des Overlay-Zeigestrahls in Grad (negativ = nach
-- unten). Sitzt eigentlich als ImGui-Slider im Fork -- im Headset ist ImGui aber nicht
-- lesbar, darum hier: eingestellt wird am Desktop, gespeichert wird in der JSON, und beim
-- Start schreiben wir den Wert in den Fork. Beide Wege schreiben dieselbe Variable, der
-- Slider im Fork bleibt also funktionsfaehig.
-- Auf einem Build ohne diesen Export passiert gar nichts (Faehigkeit wird geprueft).
local ptr_pitch      = -45.0     -- unser Default (Fork-Default waere -35.0)
local ptr_pitch_ok   = nil       -- kann dieser Build das? (nil = noch nicht geprueft)
local ptr_pitch_sent = nil       -- zuletzt geschriebener Wert -> nur bei Aenderung schreiben

local CFG_PATH    = "re4_vr/re4_vr_ui.json"
local cfg_dirty_t = nil

local function save_cfg()
    pcall(function()
        json.dump_file(CFG_PATH, {
            gui_matrix      = opt.gui_matrix,
            gui_elem        = opt.gui_elem,
            mono            = opt.mono,
            canvas          = opt.canvas,
            suspend         = opt.suspend,
            mapglue         = opt.mapglue,
            glue_distance   = glue_distance,
            glue_gap        = glue_gap,
            glue_on         = glue_on,
            map_hide        = map_hide,
            binoglue        = opt.binoglue,
            bino_distance   = bino_distance,
            vt_on           = vt_on,
            canvas_width    = canvas_width,
            canvas_distance = canvas_distance,
            hide_3121       = hide_3121,
            hide_bg         = hide_bg,
            global_hide     = global_hide,
            ui3101_scale    = ui3101_scale,
            ptr_pitch       = ptr_pitch,
        })
    end)
end

do
    local d = safe(function() return json.load_file(CFG_PATH) end)
    if type(d) == "table" then
        if type(d.ptr_pitch)       == "number"  then ptr_pitch        = d.ptr_pitch end
        if type(d.gui_matrix)      == "boolean" then opt.gui_matrix   = d.gui_matrix end
        if type(d.gui_elem)        == "boolean" then opt.gui_elem     = d.gui_elem end
        if type(d.mono)            == "boolean" then opt.mono         = d.mono end
        if type(d.canvas)          == "boolean" then opt.canvas       = d.canvas end
        if type(d.suspend)         == "boolean" then opt.suspend      = d.suspend end
        if type(d.mapglue)         == "boolean" then opt.mapglue      = d.mapglue end
        if type(d.glue_distance)   == "number"  then glue_distance    = d.glue_distance end
        if type(d.glue_gap)        == "number"  then glue_gap         = d.glue_gap end
        if type(d.binoglue)        == "boolean" then opt.binoglue     = d.binoglue end
        if type(d.bino_distance)   == "number"  then bino_distance    = d.bino_distance end
        if type(d.map_hide) == "table" then
            for k, v in pairs(d.map_hide) do
                if type(v) == "boolean" and map_hide[k] ~= nil then map_hide[k] = v end
            end
        end
        if type(d.glue_on) == "table" then
            for k, v in pairs(d.glue_on) do
                if type(v) == "boolean" and glue_on[k] ~= nil then glue_on[k] = v end
            end
        end
        -- [VIEWTYPE] Erst der alte Sammel-Haken (einmalige Migration: er stand fuer
        -- "alle vier"), danach die neuen Einzelhaken -- die gewinnen, wenn es sie gibt.
        if d.viewtype == true then
            for k in pairs(vt_on) do vt_on[k] = true end
        end
        if type(d.vt_on) == "table" then
            for k, v in pairs(d.vt_on) do
                if type(v) == "boolean" and vt_on[k] ~= nil then vt_on[k] = v end
            end
        end
        if type(d.canvas_width)    == "number"  then canvas_width     = d.canvas_width end
        if type(d.canvas_distance) == "number"  then canvas_distance  = d.canvas_distance end
        if type(d.hide_3121)       == "boolean" then hide_3121        = d.hide_3121 end
        if type(d.hide_bg)         == "boolean" then hide_bg          = d.hide_bg end
        if type(d.global_hide) == "table" then
            for k, v in pairs(d.global_hide) do
                if type(v) == "boolean" and global_hide[k] ~= nil then global_hide[k] = v end
            end
        end
        if type(d.ui3101_scale)    == "number"  then ui3101_scale     = d.ui3101_scale end
    end
end

-- Root-Control einer GUI: GameObject -> via.gui.GUI -> View -> erstes Kind.
-- Bewusst OHNE Cache: die Karte baut ihre GUIs bei jedem Oeffnen neu auf, ein
-- gehaltenes Control waere danach eine Leiche (s. component_cache_ueberlebt_saveload).
local function gui_view(go)
    local td = sdk.typeof("via.gui.GUI"); if not td then return nil end
    local comp = safe(function() return go:call("getComponent(System.Type)", td) end)
    if not comp then return nil end
    return safe(function() return comp:call("get_View") end)
end

local function gui_root_control(go)
    local view = gui_view(go)
    if not view then return nil end
    return safe(function() return view:call("get_Child") end)
end

-- Ein Layer pro Frame: Soll-ViewType setzen bzw. den gemerkten Ist-Wert zurueckgeben.
-- Absolut geschrieben, nie gegen den gelesenen Wert gerechnet.
-- [REPARATUR 2026-08-11] Schreibt EINEN bestimmten ViewType absolut auf eine Ebene und
-- vergisst alles Gemerkte. Getrennt von apply_viewtype, weil es fuer JEDEN Namen gilt --
-- auch fuer die, die keinen eigenen Haken (mehr) haben.
--
-- Warum es das braucht: der Notaus schrieb pauschal World. Fuer 3104 war das FALSCH (er
-- ist original Screen), und weil der Fork beim Zeichnen genau den vorgefundenen Zustand
-- als "Original" merkt und danach zurueckschreibt, blieb der falsche Wert kleben -- der
-- Umriss war auch mit ausgeschaltetem Pin weg. Die Zielwerte unten sind die Messwerte
-- vom 2026-08-10, vor unserem ersten Eingriff.
local function force_viewtype(go, name)
    local target = vt_force and vt_force[name]
    if target == nil then return false end

    local view = gui_view(go)
    if view then safe(function() view:call("set_ViewType", target) end) end
    vt_orig[name]  = nil
    vt_force[name] = nil
    if next(vt_force) == nil then vt_force = nil end
    return true
end

local function apply_viewtype(go, name, want)
    local view = gui_view(go)
    if not view then vt_seen[name] = "keine View"; return end

    -- Ist-Wert JEDEN Frame lesen und merken: nur so sieht man in der Statuszeile, ob ein
    -- Schreibversuch ueberhaupt haften bleibt (Symptom "Haken tut gar nichts").
    local cur = safe(function() return view:call("get_ViewType") end)
    vt_seen[name] = (cur == nil) and "kein ViewType" or tostring(cur)
    if cur == nil then return end                  -- Build/Typ kennt es nicht -> Finger weg

    if want then
        if vt_orig[name] == nil then vt_orig[name] = cur end
        if cur ~= VIEWTYPE_SCREEN then
            safe(function() view:call("set_ViewType", VIEWTYPE_SCREEN) end)
        end
    elseif vt_orig[name] ~= nil then
        safe(function() view:call("set_ViewType", vt_orig[name]) end)
        vt_orig[name] = nil
    end
end

-- ---------------------------------------------------------------------
-- MESSBEFUND 2026-08-09 (nicht nochmal messen, nicht nochmal probieren)
-- ---------------------------------------------------------------------
-- Beim Scrollen der Karte bewegen sich VIER Ebenen, und zwar exakt gleich (44 Samples,
-- groesste Abweichung 0.00):
-- Gui_ui3120 /main/c_map/c_map_move
-- Gui_ui3121 /main/c_map/c_map_move und /main/c_map_decoration/c_map_move_decoration
-- Gui_ui3101 /main/c_icon_move/c_icon_all (die Funde)
-- Gui_ui3104 (Kartenumriss) bewegt sich GAR NICHT. Ein wanderndes Fadenkreuz gibt es
-- nicht -- der Marker steht in der Mitte und die Welt zieht darunter durch.
--
-- Im GUI-System kleben die Funde also bereits perfekt auf der Karte. Dass sie im Headset
-- trotzdem wegdriften, entsteht erst beim VR-Rendering: die GUIs haengen als getrennte
-- Flaechen in unterschiedlicher Tiefe im Raum.
--
-- ZWEI WEGE SIND DAMIT TOT, BITTE NICHT WIEDER BAUEN:
-- * Position der Funde selbst rechnen (Faktor/Offset auf c_icon_all) -- aendert am
-- Auseinanderlaufen im Headset nichts, weil die Ursache nicht im GUI-Raum liegt.
-- * c_icon_all in den Kartenbaum umhaengen -- technisch moeglich, aber dann sind die
-- Funde KOMPLETT WEG: ein Control gehoert zu SEINER View und wird in einer fremden
-- nicht mehr gerendert.
-- Der einzige verbliebene Hebel ist die Tiefe/Platzierung der GUI-Flaechen selbst,
-- und die liegt im Fork (re_vr.cpp), nicht in Lua.
-- ---------------------------------------------------------------------



local state = {
    supported = nil,    -- nil = noch nicht geprueft, true/false = Ergebnis
    applied   = false,  -- haben WIR den Override gerade abgeschaltet?
    elem      = false,  -- haben WIR den Element-Override gerade abgeschaltet?
    mono      = false,  -- haben WIR gerade Mono eingeschaltet?
    canvas    = false,  -- laeuft gerade die Flatscreen-Leinwand?
    suspend   = false,  -- ist die VR gerade komplett ausgesetzt?
    map_open  = false,
    inv_open  = false,
    menu_open = false,
}

-- Singleton NICHT dauerhaft festhalten ohne Nachfassen: nach einem Savegame-Load kann die
-- gecachte Instanz tot sein -> bei nil einfach neu holen.
local map_manager = nil
local function get_map_manager()
    if not map_manager then
        local ok, mm = pcall(function() return sdk.get_managed_singleton("chainsaw.MapManager") end)
        map_manager = ok and mm or nil
    end
    return map_manager
end

-- Fork-Erkennung: die Methode wird nur NACHGESCHLAGEN, nicht aufgerufen. Auf vanilla ist
-- sie nil -> supported = false, und wir fassen vrmod nie wieder an.
local function is_supported()
    if state.supported ~= nil then return state.supported end
    if not vrmod then return false end   -- VR-Mod noch nicht da -> naechsten Frame nochmal

    local ok, fn = pcall(function() return vrmod.set_gui_projection_matrix_override_disabled end)
    state.supported = (ok and fn ~= nil)

    if not state.supported then
    end

    return state.supported
end

-- Beide Setter sind idempotent: sie rufen vrmod nur, wenn sich der Zustand wirklich
-- aendert. Damit darf der on_frame unten jeden Frame den SOLL-Zustand reinreichen.
local function apply_override(want)
    if want == state.applied then return end
    pcall(function() vrmod:set_gui_projection_matrix_override_disabled(want) end)
    state.applied = want
end

-- Mono wird NICHT selbst geschaltet, sondern beim Broker in re4_vr_scope.lua angemeldet.
-- Grund: das Scope meldet dort ebenfalls an; wuerden beide direkt `set_mono_rendering`
-- rufen, nimmt der eine dem anderen den Zustand weg (bekannte Falle).
-- Fehlt der Broker (fremdes REFramework, Script nicht geladen), passiert gar nichts.
-- Eigene Erkennung: aeltere eigene Builds kennen den Element-Schalter noch nicht.
local elem_supported = nil
local function apply_elem(want)
    if elem_supported == nil then
        local ok = pcall(function() return vrmod:is_gui_element_override_disabled() end)
        elem_supported = ok
        if not ok then
        end
    end
    if not elem_supported then return end

    want = want and true or false
    if want == state.elem then return end

    pcall(function() vrmod:set_gui_element_override_disabled(want) end)
    state.elem = want
end

local function apply_mono(want)
    state.mono = want and true or false
    if type(_G.__re4_mono_request) == "function" then
        _G.__re4_mono_request("map", state.mono)
    end
end

-- Flatscreen-Leinwand. Haengt an ihrer EIGENEN Erkennung (`__re4_fork_canvas`), nicht an
-- __re4_fork_ok: ein aelterer eigener Build kennt Mono, aber die Leinwand noch nicht.
local function apply_canvas(want)
    if not _G.__re4_fork_canvas then return end

    want = want and true or false
    if want == state.canvas then return end

    pcall(function() vrmod:set_flatscreen_overlay(want) end)
    state.canvas = want

    -- Groesse nur beim Einschalten setzen; die Slider schieben sie unten live nach.
    if want then
        pcall(function()
            vrmod:set_flatscreen_overlay_width(canvas_width)
            vrmod:set_flatscreen_overlay_distance(canvas_distance)
        end)
    end
end

-- VR komplett aussetzen. Eigene Erkennung wie bei apply_elem: aeltere eigene Builds
-- kennen den Schalter noch nicht, und ein fremdes REFramework kennt ihn nie -- einmal
-- nachschauen, danach nie wieder anfassen.
local suspend_supported = nil
local function apply_suspend(want)
    if suspend_supported == nil then
        local ok = pcall(function() return vrmod:is_vr_suspended() end)
        suspend_supported = ok
        if not ok then
        end
    end
    if not suspend_supported then return end

    want = want and true or false
    if want == state.suspend then return end

    pcall(function() vrmod:set_vr_suspended(want) end)
    state.suspend = want
end

-- Karte am Kopf festpinnen (Fork-Feature). Eigene Erkennung wie bei apply_suspend:
-- aeltere eigene Builds kennen den Schalter nicht, ein fremdes REFramework nie.
-- Welche Ebenen der Pin erfasst und in welcher Reihenfolge sie liegen (0 = am weitesten
-- hinten). Der Fork hat dieselbe Liste als Vorbelegung -- wir tragen sie beim Einschalten
-- trotzdem selbst ein: sobald ein zweiter Anwendungsfall dazukommt und die Liste fuer sich
-- umbaut, bringt die Karte ihre eigenen Eintraege dann wieder mit.
-- Aendern kostet KEIN Compile mehr, nur Reset Scripts.
-- [2026-08-11] Messbefund: 3104 wird gezeichnet und ist `visible=true`, mit exakt
-- demselben Zustand wie die anderen Ebenen (vt=1, overlay=true, scale=1.00). Er wird also
-- nicht verworfen -- er ist nur nicht zu sehen. Bleibt: eine naeher stehende Ebene deckt
-- ihn zu. Deshalb steht er testweise GANZ VORN (hoechste Zahl = am dichtesten am Auge).
-- Kommt er so zurueck, war es die Verdeckung, und wir legen die Reihenfolge endgueltig fest.
-- [2026-08-11] 3140/3141 kamen per Selbstlernen aus einem anderen Level dazu -- sie
-- gehoeren zum Kartenkoerper und stehen deshalb hinten bei 3120/3121. Der Umriss steht
-- wieder auf seinem urspruenglichen Platz (ueber dem Koerper, unter Funden und Navkreuz):
-- der Versuch, ihn nach ganz vorn zu legen, hat ihn nicht zurueckgebracht.
local GLUE_LAYERS = {
    { "Gui_ui3120", 0, "Karten-Ebene (3120)" },
    { "Gui_ui3121", 1, "Karte + Dekoration (3121)" },
    { "Gui_ui3140", 2, "Karten-Ebene (3140)" },
    { "Gui_ui3141", 3, "Karten-Ebene (3141)" },
    { "Gui_ui3104", 4, "Kartenumriss (3104)" },
    { "Gui_ui3103", 5, "Gui_ui3103" },
    { "Gui_ui3101", 6, "Funde (3101)" },
    { "Gui_ui3100", 7, "Navigationskreuz (3100)" },
}

-- [2026-08-10 Nacht] Der Umriss bleibt auch mit Staffelung weg -- es ist also NICHT die
-- Zeichenreihenfolge. Damit man das trennen kann, ist jede Ebene einzeln aus dem Pin
-- nehmbar: eine ausgehakte Ebene laeuft wieder ueber den normalen Weg (driftet dann, ist
-- aber sichtbar). Kommt der Umriss so zurueck, killt ihn der Pin; bleibt er weg, liegt es
-- woanders. Wird jeden Frame durchgeschrieben, wirkt also sofort bei offener Karte.
-- [2026-08-11] Alle Ebenen starten AN, auch 3140/3141. Dass der Umriss mit ihnen zugedeckt
-- wird, ist bekannt und wird getrennt geklaert -- abgeschaltet wird hier nichts von selbst,
-- jede Ebene hat ihren eigenen Haken.
local GLUE_DEFAULT_OFF = {}

-- [2026-08-11] Dritter Weg fuer 3140/3141: gar nicht erst zeichnen. Gepinnt decken sie den
-- Umriss zu, ungepinnt driften sie -- ist die Karte ohne sie vollstaendig, ist beides weg.
-- Eigene Haken, Startwert aus; wirkt nur bei offener Karte.
-- [ADA 2026-08-15] Separate Ways bringt eine EIGENE Karten-Ebene mit: `Gui_ui3131_AO`. Sie stoert
-- in VR und soll weg -- deshalb steht sie hier als dritter Eintrag, Startwert AN (also ausgeblendet),
-- waehrend die beiden Leon-Ebenen wie bisher aus starten.
-- Der `_AO`-Suffix ist Absicht und muss exakt so stehen: Adas GUIs heissen so (dieselbe Kette wie bei
-- ihren Waffen-GOs). Er faellt damit auch NICHT unter das Selbstlernen der Pin-Liste, das ausschliesslich
-- auf `^Gui_ui31%d%d$` matcht -- die Ebene wird also nur ausgeblendet und nicht zusaetzlich gepinnt.
local MAP_HIDE = {
    { "Gui_ui3140", "Karten-Ebene 3140 ausblenden" },
    { "Gui_ui3141", "Karten-Ebene 3141 ausblenden" },
    { "Gui_ui3131_AO", "Adas Karten-Ebene 3131_AO ausblenden (Separate Ways)" },
}
local map_hide = { ["Gui_ui3140"] = false, ["Gui_ui3141"] = false, ["Gui_ui3131_AO"] = true }
local glue_on = {}
for i = 1, #GLUE_LAYERS do
    glue_on[GLUE_LAYERS[i][1]] = not GLUE_DEFAULT_OFF[GLUE_LAYERS[i][1]]
end

-- [2026-08-11] In einem anderen Level driftete wieder alles: unsere sechs Namen stammen
-- aus EINEM Level, ein anderes zeichnet zusaetzliche Karten-Ebenen -- und was nicht in der
-- Liste steht, wird nicht gepinnt und wandert weiter. Deshalb lernt die Liste jetzt selbst:
-- jede bei offener Karte gezeichnete `Gui_ui31xx`, die wir noch nicht kennen, wird sofort
-- mit aufgenommen (Reihenfolge 0 = hinten beim Kartenkoerper) und EINMAL ins Log geschrieben,
-- damit ihr Platz danach fest vergeben werden kann.
local glue_auto = {}

-- ---------------------------------------------------------------------
-- ZWEITER PIN-FALL: FERNGLAS (2026-08-11)
-- ---------------------------------------------------------------------
-- Gui_ui2110 ist das Fernglas-UI und braucht dieselbe Behandlung wie die Karte.
-- Erkannt wird es an sich selbst: taucht es im Zeichen-Hook auf, ist das Fernglas
-- oben -- kein Singleton, keine Zustandsabfrage, und es kann nicht danebenliegen.
-- Der Pin-Schalter im Fork gilt fuer die ganze Liste, deshalb wird pro Fall die
-- passende Distanz gesetzt; gleichzeitig aktiv sind Karte und Fernglas ohnehin nie.
local BINO_GUI      = "Gui_ui2110"
local BINO_SEEN_SEC = 0.25    -- so lange nach dem letzten Zeichnen gilt es als offen
local bino_distance = 1.0
local bino_seen_t   = nil

local glue_supported = nil
local function apply_mapglue(want)
    if glue_supported == nil then
        local ok = pcall(function() return vrmod:is_map_face_glue() end)
        glue_supported = ok
        if not ok then
        end
    end
    if not glue_supported then return end

    want = want and true or false
    if want == state.mapglue then return end

    pcall(function() vrmod:set_map_face_glue(want) end)
    state.mapglue = want

    -- Distanz nur beim Einschalten setzen; der Slider schiebt sie unten live nach.
    -- Dazu die eigenen Ebenen eintragen (aeltere Builds kennen add_glue_gui nicht --
    -- dort greift stillschweigend die eingebaute Vorbelegung, das ist genau richtig).
    if want then
        pcall(function() vrmod:set_map_glue_distance(glue_distance) end)
    end
end

-- Liste jeden Frame durchschreiben, solange gepinnt wird: ein Haken im Tree wirkt damit
-- sofort, ohne Sonderbehandlung fuer "waehrend die Karte offen ist".
local function push_glue_layers()
    for i = 1, #GLUE_LAYERS do
        local g = GLUE_LAYERS[i]
        if glue_on[g[1]] then
            pcall(function() vrmod:add_glue_gui(g[1], g[2]) end)
        else
            pcall(function() vrmod:remove_glue_gui(g[1]) end)
        end
    end
end

-- [INVENTAR 2026-08-09] AcBackGround stoert auch im Koffer. Erkennung wie in
-- re4_vr_binding.lua (~321): chainsaw.AttacheCaseManager:get_IsAttacheCaseBusy.
-- Singleton nicht dauerhaft festhalten -- nach einem Save-Load kann die Instanz tot sein.
local case_manager = nil
local function is_inventory_open()
    if not case_manager then
        case_manager = safe(function() return sdk.get_managed_singleton("chainsaw.AttacheCaseManager") end)
    end
    if not case_manager then return false end

    local ok, busy = pcall(function() return case_manager:call("get_IsAttacheCaseBusy") end)
    if not ok then case_manager = nil; return false end

    return busy == true
end

-- [MAINMENUE 2026-08-09] Gui_ui0502 soll NUR im Hauptmenue weg. Erkennung ueber
-- denselben Lock, den auch re4_vr_binding.lua benutzt (~433):
-- chainsaw.GuiManager:get_hasOccupiedPauseMenuSystemLock
-- Der Lock steht aber auch, wenn Karte oder Koffer offen sind -- die sind ja ebenfalls
-- Menues. Deshalb zaehlt als Hauptmenue: Lock steht UND weder Karte noch Koffer offen.
local gui_manager = nil
local function is_main_menu_open()
    if state.map_open or state.inv_open then return false end

    if not gui_manager then
        gui_manager = safe(function() return sdk.get_managed_singleton("chainsaw.GuiManager") end)
    end
    if not gui_manager then return false end

    local ok, locked = pcall(function()
        return gui_manager:call("get_hasOccupiedPauseMenuSystemLock")
    end)
    if not ok then gui_manager = nil; return false end

    return locked == true
end

local function is_map_gui_open()
    local mm = get_map_manager()
    if not mm then return false end

    -- Methodenname EXAKT so: klein anfangend, KEIN "get_" davor. "get_IsMapGuiOpen"
    -- existiert nicht (live geprueft 2026-08-07: "Method not found") -- der Call warf
    -- dann jeden Frame in den pcall unten und die Karte galt immer als zu.
    local ok, open = pcall(function() return mm:call("isMapGuiOpen") end)
    if not ok then
        map_manager = nil   -- Instanz war eine Leiche -> naechsten Frame neu holen
        return false
    end

    return open == true
end

-- [ZEIGESTRAHL-PITCH] Wert in den Fork schreiben -- nur wenn er sich geaendert hat, damit
-- der ImGui-Slider im Fork nicht bei jedem Frame ueberschrieben wird (sonst koennte man ihn
-- dort gar nicht mehr ziehen). Die Faehigkeit wird EINMAL geprueft; fehlt sie, passiert nie
-- wieder etwas.
local function apply_ptr_pitch()
    if ptr_pitch_ok == false then return end
    if ptr_pitch_ok == nil then
        if type(vrmod) ~= "userdata" and type(vrmod) ~= "table" then return end
        ptr_pitch_ok = (pcall(function() return vrmod:get_overlay_pointer_pitch() end)) and true or false
        if not ptr_pitch_ok then return end
    end
    if ptr_pitch_sent == ptr_pitch then return end
    if pcall(function() vrmod:set_overlay_pointer_pitch(ptr_pitch) end) then
        ptr_pitch_sent = ptr_pitch
    end
end

re.on_frame(function()
    apply_ptr_pitch()
    -- Speichern VOR der Fork-Pruefung: die Haken sollen auch dann erhalten bleiben,
    -- wenn dieses REFramework den Projektions-Schalter gar nicht kennt.
    if cfg_dirty_t and (os.clock() - cfg_dirty_t) > 0.5 then
        cfg_dirty_t = nil
        save_cfg()
    end

    if not is_supported() then return end

    state.map_open = is_map_gui_open()
    state.inv_open = is_inventory_open()
    state.menu_open = is_main_menu_open()

    -- Soll-Zustand JEDEN Frame ableiten statt nur auf der Flanke zu schalten: so wirkt ein
    -- Haken im UI sofort, auch waehrend die Karte schon offen ist.
    apply_override(state.map_open and opt.gui_matrix)
    apply_elem(state.map_open and opt.gui_elem)
    apply_mono(state.map_open and opt.mono)
    apply_canvas(state.map_open and opt.canvas)
    apply_suspend(state.map_open and opt.suspend)
    -- [FERNGLAS 2026-08-11] Zweiter Pin-Fall. Beide teilen sich den Fork-Schalter, aber
    -- jeder bringt seine eigene Distanz und seine eigene Liste mit; gleichzeitig offen
    -- sind sie nie. Karte hat Vorrang, falls doch mal beides zutrifft.
    local bino_up  = opt.binoglue and bino_seen_t ~= nil
                     and (os.clock() - bino_seen_t) < BINO_SEEN_SEC
    local map_pin  = state.map_open and opt.mapglue

    apply_mapglue(map_pin or bino_up)

    if state.mapglue then
        if map_pin then
            pcall(function() vrmod:set_map_glue_distance(glue_distance) end)
            pcall(function() vrmod:set_map_glue_layer_gap(glue_gap) end)
            push_glue_layers()
            pcall(function() vrmod:remove_glue_gui(BINO_GUI) end)
        else
            pcall(function() vrmod:set_map_glue_distance(bino_distance) end)
            pcall(function() vrmod:add_glue_gui(BINO_GUI, 0) end)
        end
    end

    -- Slider live nachziehen, solange die Leinwand laeuft.
    if state.canvas then
        pcall(function()
            vrmod:set_flatscreen_overlay_width(canvas_width)
            vrmod:set_flatscreen_overlay_distance(canvas_distance)
        end)
    end
end)

-- Nur die benannten GUIs anfassen -- jedes andere Element geht unveraendert durch.
re.on_pre_gui_draw_element(function(element, context)
    local go = safe(function() return element:call("get_GameObject") end)
    if not go then return true end
    local name = safe(function() return go:call("get_Name") end)
    if not name then return true end

    -- [MITTEL-DOT 2026-08-10] Als EINZIGES gilt dieser Name im GANZEN Spiel --
    -- deshalb steht er VOR dem Zustands-Gate. Alles Weitere unten betrifft nur Karte,
    -- Koffer und Hauptmenue.
    for i = 1, #GLOBAL_GUIS do
        local gg = GLOBAL_GUIS[i]
        if name == gg.name then
            return not global_hide[gg.key]
        end
    end

    -- [VIEWTYPE 2026-08-10] VOR dem Zustands-Gate: so wird auch dann zurueckgestellt,
    -- wenn die Karte gerade zugeht und der Layer noch einen Frame gezeichnet wird.
    -- [FERNGLAS 2026-08-11] Vor jedem Zustands-Gate: das Fernglas hat mit Karte, Koffer
    -- und Hauptmenue nichts zu tun, es meldet sich einfach dadurch, dass es gezeichnet wird.
    if name == BINO_GUI then
        bino_seen_t = os.clock()
    end

    -- [SELBSTLERNEND 2026-08-11] siehe glue_auto oben. Nur bei offener Karte und nur mit
    -- gesetztem Haken -- ohne Pin wird nichts angefasst.
    if state.map_open and opt.mapglue and glue_auto[name] == nil
       and name:match("^Gui_ui31%d%d$") then
        glue_auto[name] = true
        if glue_on[name] == nil then
            -- NUR melden, NICHT mehr selbst pinnen: das Selbstlernen hat in diesem Level
            -- 3140/3141 stillschweigend dazugenommen und damit den Umriss gekillt.
            -- Was gepinnt wird, entscheidest du im Tree -- nicht das Script.
        end
    end

    -- Reparatur zuerst und fuer JEDEN Namen -- sie muss auch Ebenen erreichen,
    -- die keinen eigenen Haken haben.
    if not force_viewtype(go, name) then
        local vt_key = MAP_VIEW_KEY[name]
        if vt_key then
            apply_viewtype(go, name, state.map_open and vt_on[vt_key])
        end
    end

    -- Karte, Koffer oder Hauptmenue -- sonst gar nicht erst weitersehen.
    if not (state.map_open or state.inv_open or state.menu_open) then return true end

    -- [ACBACKGROUND 2026-08-09] Der Hintergrund stoert in der Karte UND im Koffer.
    -- Der Hook laeuft nur in diesen beiden Zustaenden -> danach ist er automatisch
    -- wieder da, es muss nichts zurueckgesetzt werden.
    if name == BG_NAME then
        -- nur Karte und Koffer -- im Hauptmenue bleibt der Hintergrund stehen
        if state.map_open or state.inv_open then return not hide_bg end
        return true
    end

    if MENU_NAMES[name] then
        return not state.menu_open        -- im Hauptmenue gar nicht zeichnen
    end

    -- Alles Weitere betrifft ausschliesslich die Karte.
    if not state.map_open then return true end

    -- [2026-08-11] Karten-Ebenen, die man ganz weglassen kann (s. MAP_HIDE oben).
    if map_hide[name] then return false end

    if name == HIDE_NAME then
        return not hide_3121          -- Haken gesetzt -> gar nicht zeichnen
    end

    if name == SCALE_NAME then
        local ctrl = gui_root_control(go)
        if ctrl then
            safe(function() ctrl:call("set_Scale",
                Vector3f.new(ui3101_scale, ui3101_scale, ui3101_scale)) end)
        end
    end

    return true
end)

-- Beim Reload der Scripte nicht mit abgeschaltetem Override, im Mono oder auf der
-- Leinwand stehenbleiben.
re.on_script_reset(function()
    apply_override(false)
    apply_elem(false)
    apply_mono(false)
    apply_canvas(false)
    apply_suspend(false)
    apply_mapglue(false)
    state.map_open = false
    state.inv_open = false
    state.menu_open = false
    map_manager, case_manager, gui_manager = nil, nil, nil
end)

-- ---------------------------------------------------------------------
-- UI -- REFramework-Menue, Tree "RE4VR - UI". Zum Vergleichen der Ebenen:
-- einzeln an/aus, waehrend die Karte offen ist.
-- ---------------------------------------------------------------------
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - UI" raus (155 Zeilen: Zeichenfunktion + Registrierung). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

