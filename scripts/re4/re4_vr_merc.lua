-- Builtin implementation: src/mods/vr/games/re4/RE4VRMerc.cpp
return

-- =====================================================================
-- re4_vr_merc.lua — VR-Anpassungen fuer den DLC "The Mercenaries"
--
-- SCHRITT 1 (2026-08-02): NUR die Moduserkennung. Dieses Script aendert
-- am Spiel NICHTS und fasst KEINE Datei der Hauptkampagne an.
--
-- Erkennung (live live im laufenden Mercs-Spiel gemessen):
-- POSITIV: chainsaw.MercenariesManager.get_GuiManager liefert einen
-- lebenden chainsaw.Cp1021GuiManager (ToString bestaetigt, das
-- Objekt liegt im Manager selbst bei +0xA0, also kein Puffer-
-- muell, s. [Notiz]).
-- In der Kampagne registriert die Mercs-Scene diesen GUI-
-- Manager nie -> dort nil.
-- STUETZE: chainsaw.CampaignManager.get_CurrentCampaign ist im Mercs
-- 'Invalid' (-1); in Haupt- UND Ada-Kampagne 'Main' (0).
-- Das Enum kennt NUR diese zwei Werte -- Separate Ways ist
-- also NICHT ueber die CampaignID von Leon zu trennen (dafuer
-- bleibt es beim Charakter, so wie bisher im Projekt).
--
-- SCHRITT 2 (2026-08-02): Charaktererkennung + einmaliger Material-Dump.
-- Mercs gibt JEDEM waehlbaren Charakter einen eigenen Body/KindID-Slot --
-- Leon heisst hier NICHT ch0a0z0_body, sondern **ch6i0z0_body** (KindID
-- ch6_i0z0 / 600000). Genau deshalb greift das Head/Hair-Verstecken aus
-- re4_vr_materials.lua im Mercs nicht: dessen Whitelist (Zeile 12) kennt
-- nur ch0a0z0 (Leon), ch0a1z0 (Ashley), ch3a8z0 (Ada).
-- ALLES Mercs-Spezifische gehoert hier rein (Wunsch) -- die
-- Kampagnen-Scripte bleiben unberuehrt, wir schreiben nur von ihnen ab.
--
-- Export fuer andere Scripte:
-- _G.__re4_in_mercs = true/false (Modus)
-- _G.__re4_merc_cid = -1 / 0 (rohe CampaignID, nur Diagnose)
-- _G.__re4_merc_kind = KindID des gespielten Mercs-Charakters
-- _G.__re4_merc_body = Body-GO-Name (z.B. "ch6i0z0_body")
-- =====================================================================

local PREFIX = "[MERC] "

-- Alle wieviel Frames neu geprueft wird (Modus wechselt nur beim Laden)
local CHECK_EVERY = 30

-- Kopf/Haar-Materialien von Leon -- LIVE GEDUMPT am Mercs-Body 2026-08-02 und
-- Zeichen fuer Zeichen identisch mit HIDE_MATERIALS_LEON aus re4_vr_materials.lua.
-- Es scheiterte also NUR am Body-Namen, nie an der Logik.
local HIDE_LEON = {
    -- GO 'head'
    EyeAO_mat          = true,
    EyeOut_mat         = true,
    Face_mat           = true,
    EyeWet_mat         = true,
    BrowsEyeLashes_mat = true,
    Eye_inside_mat     = true,
    Mouth_mat          = true,
    -- GO 'hair'
    Hair00_Mat = true,
    Hair01_Mat = true,
    -- [PINSTRIPE-HAAR 2026-08-05] eigene Haar-Materialien des Nadelstreifen-Kostuems
    pl0074_Hair_Mat  = true,
    pl0074_Hair2_Mat = true,
}

-- Kopfbedeckungen u.ae., die NICHT in einem eigenen GO liegen, sondern als
-- Submaterial im grossen 'body'-Mesh haengen (Leons Pinstripe-Hut, Live-Dump
-- 2026-08-02). Die gehen nur per-Material weg -- mesh-weit wuerde der ganze
-- Koerper verschwinden. Der Schatten geht dabei mit, beim Hut ist das richtig.
-- Beim Durchspielen der uebrigen Charaktere hier ergaenzen.
local HIDE_MATS_EXTRA = {
    Hat00_Mat = true,   -- Leon, Pinstripe-Kostuem
    Hat01_Mat = true,   -- Leon, Pinstripe-Kostuem
    Beret_Mat = true,   -- Krauser, Baskenmuetze (sitzt im 47er Body-Mesh chi200_00)
    -- [PINSTRIPE-HAAR 2026-08-05] auch hier, falls das Kostuem-Haar in einem gemischten
    -- Mesh haengt (dann greift der GO-Name-Weg nicht) -- so geht es in JEDEM Fall weg.
    pl0074_Hair_Mat  = true,
    pl0074_Hair2_Mat = true,
}

-- Bekannte Mercs-Charaktere. Wird beim Durchspielen aus dem Log gefuellt --
-- jeder neue Body loggt sich selbst mit KindID (s. Dump unten).
-- `hide` = Kopf/Haar-Materialien dieses Charakters; fehlt sie, passiert nichts.
-- Luis, Live-Dump 2026-08-02: eigenes 'head' (MIT Beard_Mat) und 'hair'
-- (nur Hair_A_Mat). Beide werden schon ueber den GO-Namen erfasst -- die
-- Liste steht nur als Rueckfallebene hier.
local HIDE_LUIS = {
    Beard_Mat         = true,
    BrowsEyelashes_mat = true,
    EyeAO_mat         = true,
    EyeInside_mat     = true,
    EyeOut_mat        = true,
    EyeWet_mat        = true,
    Face_mat          = true,
    Mouth_mat         = true,
    Hair_A_Mat        = true,
}

-- Krauser, Live-Dump 2026-08-02: DER ERSTE, bei dem die GO-Namen NICHT
-- 'head'/'hair' heissen -- sein Kopf ist 'chi200_10', die Haare 'chb700_21'.
-- Fuer ihn traegt also die Materialliste die Erkennung (genau dafuer ist sie
-- als zweiter Weg drin). Sein Barett steckt im Body-Mesh -> HIDE_MATS_EXTRA.
local HIDE_KRAUSER = {
    -- Kopf (GO 'chi200_10')
    EyeAO_mat     = true,
    Eye_out_mat   = true,
    Face_mat      = true,
    Mouth_mat     = true,
    Blow_mat      = true,
    Eye_in_mat    = true,
    Eyewet_mat    = true,
    Eye_Lashes_mat = true,
    -- Haare (GO 'chb700_21')
    Hair1_Mat = true,
    Hair2_Mat = true,
    Hair3_Mat = true,
    Hair4_Mat = true,
}

-- HUNK, Live-Dump 2026-08-02: hat weder 'head' noch 'hair' -- sein Kopf ist
-- die GASMASKE im GO 'chi300_10' (Maskenkoerper + beide Glasflaechen). Das
-- ganze GO fliegt raus, sonst haengt einem das Maskenglas im Bild.
-- Vorsicht bei den Namen: Face_Mat/Body_Mat sind generisch, deshalb greift
-- die Liste nur ueber Hunks KindID.
local HIDE_HUNK = {
    Face_Mat      = true,
    Body_Mat      = true,
    Glass_out_Mat = true,
    Glass_in_Mat  = true,
}

-- Ada, Live-Dump 2026-08-02: FAELLT AUS DER REIHE. Sie hat KEINE 6000xx-ID,
-- sondern ihre Separate-Ways-KindID 380000, und ihr Body heisst
-- 'ch3a8z0_MC_body' -- der SW-Body mit _MC-Suffix (s. [Notiz],
-- gleiche Suffix-Kette). Deshalb greift auch hier der exakte Namensvergleich
-- in re4_vr_materials.lua nicht, der nur 'ch3a8z0_body' kennt.
-- Kopf = 'cha200_10' (inkl. Lens_Inside_mat), Haare = 'cha200_20'.
local HIDE_ADA = {
    -- Kopf
    Ao_mat          = true,
    Blow_mat        = true,
    EyeLash_mat     = true,
    Eye_in_mat      = true,
    Eye_out_mat     = true,
    Eyewet_mat      = true,
    Face_mat        = true,
    Mouth_mat       = true,
    Lens_Inside_mat = true,
    -- Haare (Achtung: kleines "mat" am Ende, anders als bei Leon)
    Hair00_mat = true,
    Hair01_mat = true,
    Hair02_mat = true,
}

-- Wesker, Live-Dump 2026-08-02: Kopf = 'cha600_10' -- die Sonnenbrille steckt
-- MIT drin (GlassLens_mat, Glass_mat, NosePad_Mat, Emi_Glass_mat), geht also
-- ohne Extrawurst mit weg. Haare = 'cha600_20'.
-- KindID 600004 fehlt in der Reihe -- Ada belegt den Platz mit ihrer 380000.
local HIDE_WESKER = {
    -- Kopf inkl. Brille
    Ao_mat        = true,
    Blow_mat      = true,
    Eye_in_mat    = true,
    Eye_out_mat   = true,
    Eyewet_mat    = true,
    Face_mat      = true,
    Mouth_mat     = true,
    GlassLens_mat = true,
    Glass_mat     = true,
    NosePad_Mat   = true,
    Emi_Glass_mat = true,
    -- Haare
    Hair_A_Mat = true,
    Hair_B_Mat = true,
    Hair_C_Mat = true,
    Hair_D_Mat = true,
    Hair_E_Mat = true,
}

-- [ARM_KEY 2026-08-06] Schluessel fuer die Arm-IK-Presets (re4_vr_arm_chain.json).
-- Pro Mercs-Charakter ein eigener Block -- Krauser hat voellig andere Proportionen als Leon.
local MERC_ARM_KEYS = {
    [600000] = "merc_leon",
    [600001] = "merc_luis",
    [600002] = "merc_krauser",
    [600003] = "merc_hunk",
    [380000] = "merc_ada",
    [600005] = "merc_wesker",
}

local MERC_CHARS = {
    [600000] = { body = "ch6i0z0_body",   name = "Leon (Mercs)",    hide = HIDE_LEON },
    [600001] = { body = "ch6i1z0_body",   name = "Luis (Mercs)",    hide = HIDE_LUIS },
    [600002] = { body = "ch6i2z0_body",   name = "Krauser (Mercs)", hide = HIDE_KRAUSER },
    [600003] = { body = "ch6i3z0_body",   name = "HUNK (Mercs)",    hide = HIDE_HUNK },
    [380000] = { body = "ch3a8z0_MC_body", name = "Ada (Mercs)",    hide = HIDE_ADA },
    [600005] = { body = "ch6i5z0_body",   name = "Wesker (Mercs)",  hide = HIDE_WESKER },
}

-- [SW_VS_MERCS 2026-08-04] Body-Namen der Mercs-Charaktere als Nachschlagetabelle.
-- Grund: get_GuiManager allein erkennt Mercenaries NICHT zuverlaessig -- live gemessen, waehrend
-- Ada im Separate-Ways-DLC lief: get_GuiManager lieferte einen Cp1021GuiManager und
-- CampaignManager.get_CurrentCampaign stand auf Invalid (-1), also exakt das Mercs-Muster.
-- Folge war, dass Adas SW-DLC im Mercs-Binding-Zweig landete (Links-A = RS+LS usw.).
-- Der Body-Name trennt beide sauber: SW-Ada ist "ch3a8z0_body", Mercs-Ada "ch3a8z0_MC_body",
-- und Mercs-Leon heisst ch6i0z0_body statt ch0a0z0_body.
local MERC_BODIES = {}
for _, c in pairs(MERC_CHARS) do MERC_BODIES[c.body] = true end

-- via.render.SkinnedMesh existiert in RE4 NICHT -> sdk.typeof waere nil und
-- jeder getComponent-Aufruf damit wirft eine Engine-Exception, die REFramework
-- SYNCHRON auf Platte loggt (Logflut, siehe Notiz).
-- via.render.Mesh deckt geskinnte Meshes ohnehin ab.
local T_MESH = sdk.typeof("via.render.Mesh")

local merc_mgr      = nil
local campaign_mgr  = nil
local char_mgr      = nil
local frames        = 0
local last_state    = nil   -- nil = noch nie geloggt
local last_kind     = nil
local merc_body_ok  = false -- [SW_VS_MERCS] letzter Body-Befund; haelt den Zustand, wenn der Body
                            -- gerade nicht lesbar ist (Ladephase) -> kein Branch-Flackern in Mercs

-- Kopf/Haar verstecken
local hide_enabled  = true  -- Toggle im Desktop-Tree
local round_gap     = false -- laeuft gerade die Ladeluecke zwischen zwei Runden?
local hh_meshes     = nil   -- gecachte Renderer der reinen head/hair-Meshes
local hh_body       = nil   -- fuer welchen Body der Cache gilt
-- [MERC_FULLHIDE 2026-08-05] ALLE Renderer unter dem Mercs-Body -- fuer das
-- Komplett-Aus in KS3/KS5 (Stagger/Treffer). Eigener Cache, eigene Lebensdauer.
local all_meshes    = nil
local full_hidden   = false
local hh_logged     = nil


local function safe(fn)
    local ok, r = pcall(fn)
    if ok then return r end
    return nil
end

-- Zentraler VR-Killswitch (wie in re4_vr_materials.lua). Faellt auf No-op
-- zurueck, falls das Modul fehlt -> dann bleibt der Kopf schlicht immer aus.
local ok_ks, killswitch = pcall(function() return require("re4vr/re4_vr_killswitch") end)
if not ok_ks or not killswitch or type(killswitch.is_active) ~= "function" then
    killswitch = { is_active = function() return false end }
end

-- Singleton-Getter MIT Cache-Verwurf: ein Cache, der einen Szenen-/
-- Savewechsel ueberlebt, liefert still nil und friert den Zustand ein
-- (genau der Bug, der den Anim-Export 2026-08-02 getoetet hat).
local function get_merc_mgr()
    if not merc_mgr then
        merc_mgr = sdk.get_managed_singleton("chainsaw.MercenariesManager")
    end
    return merc_mgr
end

local function get_campaign_mgr()
    if not campaign_mgr then
        campaign_mgr = sdk.get_managed_singleton("chainsaw.CampaignManager")
    end
    return campaign_mgr
end

local function detect()
    local mm  = get_merc_mgr()
    local gui = mm and safe(function() return mm:call("get_GuiManager") end)
    if mm and gui == nil then
        -- Manager da, aber kein GUI: entweder Kampagne (richtig) oder der
        -- Singleton ist tot -> einmal verwerfen, naechster Tick holt frisch
        merc_mgr = nil
    end

    local cm  = get_campaign_mgr()
    local cid = cm and safe(function() return cm:call("get_CurrentCampaign") end)
    if cm and cid == nil then campaign_mgr = nil end

    return (gui ~= nil), cid
end

-- ---- Gespielter Charakter (nur im Mercs interessant) ----
local function get_char_mgr()
    if not char_mgr then
        char_mgr = sdk.get_managed_singleton("chainsaw.CharacterManager")
    end
    return char_mgr
end

-- Liefert KindID (Zahl), Body-GO-Name und den Body-Transform
local function get_player_body()
    local cmgr = get_char_mgr()
    local ctx  = cmgr and safe(function() return cmgr:call("getPlayerContextRef") end)
    -- [KEIN-WERT-FALLE 2026-08-06] IMMER drei Werte zurueckgeben. Ein blankes `return nil` liefert
    -- nur EINEN Wert -> `select(2, get_player_body)` liefert GAR KEINEN -> tostring reisst mit
    -- "bad argument #1 (value expected)" ab (live passiert, merc.lua:1082, Ladephase ohne Context).
    if not ctx then char_mgr = nil; return nil, nil, nil end
    local kind = safe(function() return ctx:call("get_KindID") end)
    local go   = safe(function() return ctx:call("get_BodyGameObject") end)
    if not go then return kind, nil, nil end
    local name = safe(function() return go:call("get_Name") end)
    local tf   = safe(function() return go:call("get_Transform") end)
    return kind, name, tf
end

-- ---- Kopf/Haare verstecken (abgeschrieben von re4_vr_materials.lua) ----
-- Vorgehen wie dort im [SHADOW]-Zweig: ein Mesh, das AUSSCHLIESSLICH aus
-- Kopf/Haar-Materialien besteht (bei Leon sind 'head' und 'hair' eigene GOs),
-- wird mesh-weit aus dem Farb-Pass genommen und wirft trotzdem Schatten --
-- besser als setMaterialsEnable(false), das den Schatten mitnimmt.
-- ZWEI Wege, ein Mesh als Kopf/Haar zu erkennen:
-- (1) GO-NAME ist 'head' oder 'hair' -> Hauptweg, kostuemfest.
-- [KOSTUEM 2026-08-02] Noetig geworden durch Leons Pinstripe-Kostuem:
-- Body-Name und KindID bleiben gleich, aber das Haar-Mesh traegt dann
-- pl0074_Hair_Mat/pl0074_Hair2_Mat statt Hair00_Mat/Hair01_Mat -- die
-- reine Materialliste liess die Haare stehen. GO-Namen aendern sich nicht.
-- (2) ALLE Materialien stehen in der Hide-Liste -> Zusatzsicherung fuer
-- Charaktere, deren Kopf-GO anders heisst.
-- In beiden Faellen gilt: nur REINE Kopf/Haar-Meshes. Ein gemischtes Mesh
-- (z.B. 'body', das bei Pinstripe den Hut traegt) wird nie mesh-weit versteckt.
local HH_GO_NAMES = { head = true, hair = true }

local function collect_hh(tf, hide_list)
    if not tf or not T_MESH then return nil end
    local found = {}
    local function walk(t, depth)
        if not t or depth > 14 then return end
        local go = safe(function() return t:call("get_GameObject") end)
        local mesh = go and safe(function()
            return go:call("getComponent(System.Type)", T_MESH)
        end)
        if mesh then
            local n = safe(function() return mesh:call("get_MaterialNum") end)
            if type(n) == "number" and n > 0 then
                local gname = safe(function() return go:call("get_Name") end)
                local hit = (type(gname) == "string") and HH_GO_NAMES[gname:lower()] == true
                if not hit and hide_list then
                    hit = true
                    for i = 0, n - 1 do
                        local mn = safe(function() return mesh:call("getMaterialName", i) end)
                        if not (type(mn) == "string" and hide_list[mn]) then
                            hit = false
                            break
                        end
                    end
                end
                if hit then
                    found[#found + 1] = { mesh = mesh, name = tostring(gname) }
                else
                    -- Gemischtes Mesh: einzelne Materialien (Hut) einsammeln
                    for i = 0, n - 1 do
                        local mn = safe(function() return mesh:call("getMaterialName", i) end)
                        if type(mn) == "string" and HIDE_MATS_EXTRA[mn] then
                            found[#found + 1] = {
                                mesh = mesh, idx = i,
                                name = tostring(gname) .. "/" .. mn,
                            }
                        end
                    end
                end
            end
        end
        local c = safe(function() return t:call("get_Child") end)
        while c do
            walk(c, depth + 1)
            c = safe(function() return c:call("get_Next") end)
        end
    end
    walk(tf, 0)
    if #found == 0 then return nil end
    return found
end

-- Kopf/Haare gehoeren NUR in KS1 ins Bild (volle Drittperson). Gameplay und
-- KS2/KS3/KS4/KS5 sind alle Erstperson -- exakt die Regel aus
-- re4_vr_materials.lua:575, hier 1:1 nachgebaut.
local function show_head_now()
    if not killswitch.is_active() then return false end
    for _, fn in ipairs({ "is_ks2", "is_ks3", "is_ks4", "is_ks5" }) do
        if type(killswitch[fn]) == "function" then
            local ok, v = pcall(killswitch[fn])
            if ok and v == true then return false end
        end
    end
    return true
end

-- =====================================================================
-- [MERC_FULLHIDE 2026-08-05] "bei den Merc-Charakteren muss das Mesh bei genau
-- demselben Trigger komplett aus"
-- =====================================================================
-- Trigger ist derselbe wie in re4_vr_materials.lua (fp_only_now = ks3 or ks5) -- und KS3 ist
-- genau der Damage-/Stagger-Zustand: der Killswitch zieht bei jedem Damage-CamState den
-- Latch auf Level 3 (re4_vr_killswitch.lua, "fp_latch_level = 3"). Bei Leon/Ada blendet
-- materials.lua dort den ganzen Koerper aus -- dessen Body-Whitelist kennt aber KEINEN
-- Mercs-Body, darum sah man in Mercs bei jedem Treffer den eigenen Koerper.
-- Bewusst HIER statt in materials.lua (Mercs-Material bleibt im Mercs-Script).
--
-- Verfahren wie im [SHADOW BODY]-Zweig dort: Materialien ANLASSEN (Geometrie fuer den
-- Schatten) und nur den Farb-Pass abschalten -- set_DrawDefault(false) + ShadowCast an.
-- =====================================================================
-- [EXTRA_MATS 2026-08-05] Materialien, die im Voll-Aus NICHT auf DrawDefault hoeren
-- =====================================================================
-- Die Jacke blieb im KS3 stehen, obwohl DrawDefault am GO 'jacket' nachweislich false war.
-- Im EMV verschwindet sie ueber das MATERIAL-Haekchen -- und EMV findet seine Meshes NICHT
-- ueber den Transform-Baum, sondern ueber die SZENE:
-- scene:call("findComponents(System.Type)", sdk.typeof("via.render.Mesh"))
-- (init.lua ~10949) und nimmt die Komponente aus der Komponentenliste, nicht per getComponent
-- (das liefert nur die ERSTE Mesh-Komponente eines GOs). Genau dieser Weg wird hier nachgebaut --
-- ausschliesslich fuer die Materialien in dieser Liste.
-- Neues Kostuemteil, das im Stagger stehen bleibt -> Materialnamen hier eintragen.
local FULLHIDE_EXTRA_MATS = {
    ["JacketFur_Mat"] = true,   -- Leon, Jacken-Kostuem (Fell am Kragen)
    ["Jacket_Mat"]    = true,   -- Leon, Jacke
    ["Boa_Mat"]       = true,   -- Krauser, Fellkragen (chi200_00) -- gleiches Muster wie JacketFur
}

local extra_mats = nil          -- { {mesh=, idx=} } -- ueber die Szene gefunden
local extra_mats_off = false
local extra_scan_t = 0

-- =====================================================================
-- [FUR 2026-08-15] Das Fell am Kragen ist KEIN Material auf einem Mesh
-- =====================================================================
-- Live in der TDB nachgesehen: es haengt an `via.render.Fur` bzw. `via.render.ShellFurMesh` --
-- beide erben von `via.render.RenderEntity`, NICHT von `via.render.Mesh`. Deshalb sieht sie
-- weder `findComponents(via.render.Mesh)` noch `getComponent(via.render.Mesh)`, und
-- `setMaterialsEnable` gibt es auf ihr gar nicht: alles andere ging aus, nur das Fell blieb.
-- Geschaltet wird ueber RenderEntity (set_DrawDefault / set_DrawShadowCast) -- unsichtbar,
-- Schatten bleibt, genau wie bei den Meshes.
-- BEWUSST NICHT szenenweit: Gegner (und Krauser als Gegner-Modell) haben eigene Fur-Komponenten.
-- Genommen wird nur, was am gefundenen Jacken-/Boa-Mesh haengt: dessen GO, dessen Eltern-GO,
-- dessen direkte Kinder.
-- [NIL-TYPE-GUARD] Fehlender Typ bleibt nil und wird uebersprungen -- getComponent(nil) flutet das Log.
local T_FUR      = sdk.typeof("via.render.Fur")
local T_SHELLFUR = sdk.typeof("via.render.ShellFurMesh")
local extra_furs = nil

local function scene_now()
    local sm = sdk.get_native_singleton("via.SceneManager")
    local td = sdk.find_type_definition("via.SceneManager")
    if not (sm and td) then return nil end
    return safe(function() return sdk.call_native_func(sm, td, "get_CurrentScene") end)
end

-- Szene nach genau diesen Materialien absuchen. Teuer -> hoechstens alle 5 s, und nur solange
-- nichts gefunden wurde (danach haelt der Cache, bis ein Call fehlschlaegt).
-- [LEICHENTEST 2026-08-18 -- gemessen im Watcher-Log] In Mercs gab es bisher GAR KEINEN
-- Gueltigkeitstest: einmal gefunden, hielt der Cache bis ans Ende (der `if not ok`-Abbruch in
-- apply_extra_mats greift nicht, weil `setMaterialsEnable` an einer Leiche nicht wirft, sondern
-- verpufft). Nach einem Neuaufbau des Charakters -- neue Runde, Respawn, Kostuem/Stage -- zeigten
-- Mesh und Fur-Komponente auf tote Objekte und wurden trotzdem weiter geschaltet.
-- Belegt im Log: 12:28:27.761 `fur1[jacket<ch6i0z0_body draw=true]`, 0,2 s spaeter
-- `fur1[? draw=true]` -- das GameObject war weg, `get_DrawDefault()` antwortete aber weiter.
-- Beim naechsten Voll-Aus stand dann `fur1[? draw=false]`: wir schalteten Geister ab, waehrend
-- das Fell des NEUEN Koerpers sichtbar blieb. Genau deshalb half ein "Reset Scripts" sofort --
-- es baut den Cache neu auf.
-- Das GameObject ist der einzige Wert, der den Tod nicht ueberlebt -> danach wird geprueft.
local function extra_cache_alive()
    if not extra_mats then return false end
    for _, e in ipairs(extra_mats) do
        local ok = false
        pcall(function() ok = (e.mesh:call("get_GameObject") ~= nil)
            and (e.mesh:call("getMaterialName", e.idx) == e.name) end)
        if not ok then return false end
    end
    if extra_furs then
        for _, f in ipairs(extra_furs) do
            local ok = false
            pcall(function() ok = (f:call("get_GameObject") ~= nil) end)
            if not ok then return false end
        end
    end
    return true
end

local function scan_extra_mats()
    -- Toten Cache verwerfen und sofort neu suchen duerfen (Drosselung mit zuruecksetzen,
    -- sonst stuende das Fell bis zu 5 s sichtbar da).
    if extra_mats and not extra_cache_alive() then
        extra_mats, extra_mats_off, extra_furs, extra_scan_t = nil, false, nil, 0
    end
    if extra_mats then return end
    if (os.clock() - extra_scan_t) < 5.0 then return end
    extra_scan_t = os.clock()
    local scene = scene_now(); if not scene then return end
    local arr = safe(function()
        return scene:call("findComponents(System.Type)", sdk.typeof("via.render.Mesh"))
    end)
    local list = arr and safe(function() return arr:get_elements() end) or nil
    if not list then return end
    local found = {}
    for _, mesh in ipairs(list) do
        local n = safe(function() return mesh:call("get_MaterialNum") end) or 0
        for i = 0, n - 1 do
            local mn = safe(function() return mesh:call("getMaterialName", i) end)
            if type(mn) == "string" and FULLHIDE_EXTRA_MATS[mn] then
                found[#found + 1] = { mesh = mesh, idx = i, name = mn }
            end
        end
    end
    if #found > 0 then
        extra_mats = found
        local names = {}
        for _, e in ipairs(found) do names[#names + 1] = e.name .. "#" .. e.idx end
    end

    -- [FUR 2026-08-15] Fur-Komponenten am gefundenen Mesh einsammeln (GO, Eltern-GO, direkte Kinder).
    -- Doppelte Eintraege sind unkritisch -- set_DrawDefault zweimal zu setzen kostet nichts.
    if extra_mats and not extra_furs then
        local furs = {}
        local function take(go)
            if not go then return end
            for _, t in ipairs({ T_FUR, T_SHELLFUR }) do
                if t then
                    local c = safe(function() return go:call("getComponent(System.Type)", t) end)
                    if c then furs[#furs + 1] = c end
                end
            end
        end
        for _, e in ipairs(extra_mats) do
            local go = safe(function() return e.mesh:call("get_GameObject") end)
            if go then
                take(go)
                local tf = safe(function() return go:call("get_Transform") end)
                if tf then
                    local par = safe(function() return tf:call("get_Parent") end)
                    take(par and safe(function() return par:call("get_GameObject") end))
                    local ch = safe(function() return tf:call("get_Child") end)
                    while ch do
                        take(safe(function() return ch:call("get_GameObject") end))
                        ch = safe(function() return ch:call("get_Next") end)
                    end
                end
            end
        end
        if #furs > 0 then extra_furs = furs end
    end
end

-- Aufrufform wie im EMV (init.lua ~7335: mesh:call("setMaterialsEnable", id, on)).
local function apply_extra_mats(off)
    if not extra_mats and not extra_furs then return end
    -- [GLEICHZUG 2026-08-18] Vorher `if off == extra_mats_off then return end` -- also nur auf der
    -- Flanke. Baut die Engine Mesh/Fur waehrend eines laufenden Voll-Aus neu auf (neue Runde,
    -- Respawn, Kostuem), wurde nie wieder geschrieben und das Fell stand sichtbar da.
    -- materials.lua macht es seit dem 09.08. richtig: im AUS-Zustand jeden Tick nachdruecken,
    -- beim Wiedereinschalten genuegt die Flanke. Jetzt identisch in beiden Dateien.
    if not off and off == extra_mats_off then return end
    -- [FUR 2026-08-15] Zuerst das Fell: die Material-Schleife darunter steigt bei einem toten
    -- Mesh mit return aus -- stuende das Fell danach, bliebe es in genau dem Fall sichtbar.
    if extra_furs then
        for _, f in ipairs(extra_furs) do
            pcall(function() f:call("set_DrawDefault", not off) end)
            pcall(function() f:call("set_DrawShadowCast", true) end)
        end
    end
    if not extra_mats then extra_mats_off = off; return end
    for _, e in ipairs(extra_mats) do
        local ok = pcall(function() e.mesh:call("setMaterialsEnable", e.idx, not off) end)
        if not ok then extra_mats, extra_mats_off, extra_furs = nil, false, nil; return end   -- Mesh tot -> neu suchen
    end
    extra_mats_off = off
    -- [FUR-DIAG 2026-08-18] NUR Export, kein Verhalten -- derselbe Satz wie in materials.lua, damit
    -- der Wegwerf-Logger in Mercs GENAU die Objekte misst, die dieser Zweig auch schaltet.
    -- (In Mercs heisst Leons Body ch6i0z0_body, deshalb laeuft der Voll-Aus hier und nicht dort.)
    _G.__re4_fur_dbg = { mats = extra_mats, furs = extra_furs, off = extra_mats_off, quelle = "mercs" }
end

local function collect_all_meshes(tf)
    if not tf or not T_MESH then return nil end
    local found = {}
    local function walk(t, depth)
        if not t or depth > 14 then return end
        local go = safe(function() return t:call("get_GameObject") end)
        local mesh = go and safe(function()
            return go:call("getComponent(System.Type)", T_MESH)
        end)
        if mesh then found[#found + 1] = mesh end
        local c = safe(function() return t:call("get_Child") end)
        while c do
            walk(c, depth + 1)
            c = safe(function() return c:call("get_Next") end)
        end
    end
    walk(tf, 0)
    if #found == 0 then return nil end
    return found
end

local function full_hide_now()
    for _, fn in ipairs({ "is_ks3", "is_ks5" }) do
        if type(killswitch[fn]) == "function" then
            local ok, v = pcall(killswitch[fn])
            if ok and v == true then return true end
        end
    end
    return false
end

-- Waehrend KS3/KS5 jeden Frame erzwingen (die Engine setzt DrawDefault selbst zurueck),
-- beim Austritt EINMAL zurueckschalten -- sonst bliebe der Koerper unsichtbar.
local function apply_full_hide()
    -- [EXTRA_MATS] laeuft unabhaengig vom Mesh-Cache (eigener Weg ueber die Szene, s. oben)
    local want_extra = hide_enabled and full_hide_now()
    if want_extra then scan_extra_mats() end
    apply_extra_mats(want_extra)

    if not all_meshes then return end
    local want = hide_enabled and full_hide_now()
    if not want and not full_hidden then return end   -- Normalfall: nichts anfassen
    for _, m in ipairs(all_meshes) do
        local ok = pcall(function()
            m:call("set_DrawDefault", not want)
            m:call("set_DrawShadowCast", true)
        end)
        if not ok then
            -- toter Renderer (Save-Load/Rundenende) -> Cache verwerfen, s.
            -- Notiz
            all_meshes, full_hidden = nil, false
            return
        end
    end
    full_hidden = want
end

-- Jeden Frame erzwingen: die Engine setzt DrawDefault beim Nachladen/
-- Reparenten zurueck. Schlaegt ein Call fehl, ist der gecachte Renderer tot
-- -> Cache wegwerfen statt still nichts mehr zu tun (die Save-Load-Falle
-- vom 2026-08-02, siehe Notiz).
local function apply_hide()
    if not hh_meshes then return end
    -- Kopf/Haare NUR in KS1 sichtbar -- alles andere ist Erstperson.
    -- [KS1-ONLY 2026-08-02] Vorher hing das nur an is_active, und die
    -- ist in BEIDEN Mercs-Grapples an: dem von hinten (Drittperson, KS1) und
    -- dem von vorne (bleibt Erstperson). Die Stufe trennt sie sauber.
    local want_hidden = hide_enabled and not show_head_now()
    for _, e in ipairs(hh_meshes) do
        local ok
        if e.idx then
            -- Einzelmaterial (Hut im gemischten body-Mesh): nur dieser Slot.
            -- Beide Aufrufformen wie in re4_vr_materials.lua -- die kurze
            -- Variante trifft je nach Overload-Aufloesung nicht immer.
            ok = pcall(function()
                e.mesh:call("setMaterialsEnable", e.idx, not want_hidden)
            end)
            pcall(function()
                e.mesh:call("setMaterialsEnable(System.Int32,System.Boolean)",
                    e.idx, not want_hidden)
            end)
        else
            ok = pcall(function()
                e.mesh:call("set_DrawDefault", not want_hidden)
                e.mesh:call("set_DrawShadowCast", true)
            end)
        end
        if not ok then
            hh_meshes, hh_body = nil, nil
            return
        end
    end
end

-- =====================================================================
-- [MERC_WEP_OFFSET 2026-08-03] WAFFE-only Versatz fuer Mercenaries-Waffen.
--
-- Die Waffe haengt (wie in der Kampagne) an der RECHTEN Hand. Hier wird NUR die Waffe
-- gegen die Hand verschoben/gedreht -- die Hand selbst bleibt 1:1, weil dieser Hook erst
-- ganz am Ende von attach_weapon greift (Handjoints sind da laengst geschrieben).
-- Genau das, was in der Kampagne "6102_bowwep"/"4004_stockwep" machen, nur eben hier,
-- damit am Maingame nichts geaendert wird: motion ruft lediglich den nil-gepruefte Hook
-- __re4_merc_wep_apply auf -- ohne dieses Script passiert dort exakt nichts.
--
-- Gilt fuer JEDE Mercs-Waffe: die Slider im Tree bearbeiten immer die gerade equippte,
-- Werte je Waffen-ID in re4_vr_merc.json ("wep_off"). Alles startet auf 0 = kein Effekt.
-- =====================================================================
local LH_CFG_PATH = "re4_vr/re4_vr_merc.json"

local wep_off_on = true
local wep_off    = {}       -- ["6304"] = {px,py,pz,rx,ry,rz}

local function wep_off_for(wid)
    local k = tostring(wid)
    local o = wep_off[k]
    if not o then
        o = { px = 0.0, py = 0.0, pz = 0.0, rx = 0.0, ry = 0.0, rz = 0.0 }
        wep_off[k] = o
    end
    return o
end

-- =====================================================================
-- [BOW_POSE 2026-08-03] Handposen fuer den Compound Bow. Die Werte sind KOPIEN aus dem
-- Capture-Tool und liegen in unserer eigenen re4_vr_merc.json ("poses") -- KEIN Verweis auf
-- re4_vr_guestures.lua/-json, das ist nur zum Aufnehmen da.
-- compoundBOW -- LINKS gecaptured -> gespiegelt auf die RECHTE Hand (Bogen in der Hand)
-- compoundBOWLEFT -- RECHTS gecaptured -> gespiegelt auf die LINKE Hand (Lazypose, immer)
-- Beide gelten, solange wp6304 draussen ist.
--
-- Gespiegelt wird zur Laufzeit (Bone L_x <-> R_x + Quaternion), damit die Rohdaten in der JSON
-- unveraendert bleiben. Welche der drei Spiegel-Varianten die richtige ist, haengt an der
-- Achsenkonvention der Fingerjoints -- deshalb im Tree umschaltbar statt geraten (Default 1).
-- =====================================================================
local BOW_WID          = 6304
local bow_poses        = {}     -- ["compoundBOW"] = { src_hand=, bones={ [bone]={w,x,y,z} } }
local bow_pose_on      = true
-- [2026-08-09] Gui_ui2770 in Mercenaries per Haken ausblenden. Startwert: AUSGEBLENDET.
-- Muss hier oben stehen, weil lh_save_cfg/lh_load_cfg weiter unten darauf zugreifen.
local hide_2770        = true
-- [2026-08-09] Der Kasten HINTER dem Countdown (Gui_ui2700). Es sind zwei Panels:
-- `main/c_bg_new` (der grosse) und `main/c_timer/c_bg` (der kleine direkt an den Ziffern).
-- Beide zusammen an einem Haken; die Ziffern, das Symbol und die Effektzahlen bleiben.
-- Startwert: ausgeblendet.
local hide_timer_bg    = true
local bow_mirror_mode  = 1      -- 1 = (w, x,-y,-z) | 2 = (w,-x, y,-z) | 3 = (w,-x,-y, z)
local bow_pose_blend   = 1.0
local bow_mirror_cache = {}     -- [name] = gespiegelte bones (pro Modus verworfen)
local bow_dbg          = "noch nichts geschrieben"

local function bow_count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function bow_mirror_bones(bones)
    local out = {}
    for name, q in pairs(bones) do
        if type(q) == "table" and q[1] then
            local n2 = name
            local side = name:sub(1, 2)
            if side == "L_" then n2 = "R_" .. name:sub(3)
            elseif side == "R_" then n2 = "L_" .. name:sub(3) end
            local w, x, y, z = q[1], q[2], q[3], q[4]
            if bow_mirror_mode == 2 then
                out[n2] = { w, -x, y, -z }
            elseif bow_mirror_mode == 3 then
                out[n2] = { w, -x, -y, z }
            else
                out[n2] = { w, x, -y, -z }
            end
        end
    end
    return out
end

local function bow_mirrored(name)
    local c = bow_mirror_cache[name]
    if c then return c end
    local p = bow_poses[name]
    if not (p and type(p.bones) == "table") then return nil end
    c = bow_mirror_bones(p.bones)
    bow_mirror_cache[name] = c
    return c
end

-- Aufgerufen von re4_vr_motion.lua im BeginRendering-POST-Pass (dort werden alle Handposen
-- geschrieben -- im Pre-Pass wuerde die Engine-Anim sie jeden Frame ueberschreiben).
_G.__re4_merc_apply_bow_pose = function()
    if not bow_pose_on then return end
    if _G.__re4_in_mercs ~= true then return end
    if rawget(_G, "__vr_dbg_wep_id") ~= BOW_WID then return end
    local ap = rawget(_G, "__re4_reload_apply_pose_bones")
    if type(ap) ~= "function" then return end
    local rp = bow_mirrored("compoundBOW")       -- -> rechte Hand (haelt den Bogen)
    local lp = bow_mirrored("compoundBOWLEFT")   -- -> linke Hand (Lazypose)
    -- [BOW_KNIFE_LEFT 2026-08-05] Liegt das Messer in der LINKEN Hand, gehoert die linke
    -- Pose dem Messer. Wir laufen im POST-Pass NACH __re4_apply_left_knife_pose (motion.lua) --
    -- ohne diesen Ausstieg wuerde die Bogen-Lazypose die Messerpose jeden Frame ueberschreiben.
    -- Die rechte Bogenhand bleibt unberuehrt.
    if rawget(_G, "__re4_knife_hand") == "left" then lp = nil end
    local okr, okl = false, false
    if rp then pcall(function() okr = ap(rp, bow_pose_blend) == true end) end
    if lp then pcall(function() okl = ap(lp, bow_pose_blend) == true end) end
    -- Sichtbar machen, ob wirklich geschrieben wurde -- "Pose sieht falsch aus" und "Pose kommt
    -- gar nicht an" fuehlen sich im Headset identisch an (BOM in der JSON = poses leer, kein Fehler).
    bow_dbg = string.format("rechts=%s (%d Bones)  links=%s (%d Bones)",
        okr and "geschrieben" or "NEIN", rp and bow_count(rp) or 0,
        okl and "geschrieben" or "NEIN", lp and bow_count(lp) or 0)
end

local function lh_load_cfg()
    local d = nil
    pcall(function() d = json.load_file(LH_CFG_PATH) end)
    if type(d) ~= "table" then return end
    if d.wep_off_on ~= nil then wep_off_on = d.wep_off_on == true end
    if d.bow_pose_on ~= nil then bow_pose_on = d.bow_pose_on == true end
    if d.hide_2770 ~= nil then hide_2770 = d.hide_2770 == true end
    if d.hide_timer_bg ~= nil then hide_timer_bg = d.hide_timer_bg == true end
    if tonumber(d.bow_mirror_mode) then bow_mirror_mode = tonumber(d.bow_mirror_mode) end
    if tonumber(d.bow_pose_blend) then bow_pose_blend = tonumber(d.bow_pose_blend) end
    if type(d.poses) == "table" then
        bow_poses = d.poses
        bow_mirror_cache = {}
    end
    -- [MERCS_HUD 2026-08-05] Groesse/Offset von Countdown + Balken. Der HUD-Block liegt weiter
    -- unten im File -> hier ueber das Global lesen (ist beim ersten Laden ggf. noch nil, dann
    -- merkt sich lh_load_cfg die Werte in __re4_merc_hud_pending und der Block zieht sie).
    if type(d.hud) == "table" then _G.__re4_merc_hud_pending = d.hud end
    if type(d.wep_off) == "table" then
        for k, v in pairs(d.wep_off) do
            if type(v) == "table" then
                local o = wep_off_for(k)
                o.px = tonumber(v.px) or 0.0; o.py = tonumber(v.py) or 0.0; o.pz = tonumber(v.pz) or 0.0
                o.rx = tonumber(v.rx) or 0.0; o.ry = tonumber(v.ry) or 0.0; o.rz = tonumber(v.rz) or 0.0
            end
        end
    end
end

local function lh_save_cfg()
    pcall(function()
        -- poses MUSS mitgeschrieben werden, sonst radiert der erste Slider-Klick die
        -- kopierten Capture-Werte aus der JSON.
        local h = rawget(_G, "__re4_merc_hud")
        json.dump_file(LH_CFG_PATH, {
            wep_off_on      = wep_off_on,
            wep_off         = wep_off,
            poses           = bow_poses,
            bow_pose_on     = bow_pose_on,
            hide_2770       = hide_2770,
            hide_timer_bg   = hide_timer_bg,
            bow_mirror_mode = bow_mirror_mode,
            bow_pose_blend  = bow_pose_blend,
            -- [MERCS_HUD] Groesse/Offset aller HUD-Teile -- generisch ueber die Tabelle, damit
            -- ein neuer Eintrag im HUD-Block nicht auch noch hier nachgetragen werden muss.
            hud = h and (function()
                local out = {}
                for k, v in pairs(h) do
                    out[k] = { on = v.on, scale = v.scale, x = v.x, y = v.y, bx = v.bx, by = v.by }
                end
                return out
            end)() or nil,
        })
    end)
end

-- Der HUD-Block weiter unten liegt in einem eigenen do-Block und kommt an die lokale
-- Funktion nicht heran: er muss die EINMAL gelesene Nulllage von Gui_ui2710 sofort
-- sichern, sonst wird sie beim naechsten Start neu gemessen -- und dann vom eigenen
-- Offset verfaelscht.
_G.__re4_merc_save_cfg = lh_save_cfg

lh_load_cfg()

-- Achsenreihenfolge identisch zu re4_vr_motion.lua (Y * X * Z), damit sich die Slider
-- genauso anfuehlen wie die uebrigen Rot-Slider im Projekt.
local function wep_quat_from_euler_deg(px, py, pz)
    local function ax(a, x, y, z)
        local h = math.rad(a) * 0.5
        local s = math.sin(h)
        return Quaternion.new(math.cos(h), x * s, y * s, z * s)
    end
    local q = ax(py, 0, 1, 0) * ax(px, 1, 0, 0) * ax(pz, 0, 0, 1)
    local ok, n = pcall(function() return q:normalized() end)
    return ok and n or q
end

-- Vektor mit Quaternion drehen -- gleiche Absicherung wie motion (q*v kann je nach
-- REFramework-Build fehlen, dann von Hand rechnen), sonst faellt der Hook still aus.
local function wep_rot_vec3(q, v)
    local ok, r = pcall(function() return q * v end)
    if ok and r then return r end
    local qv  = Vector3f.new(q.x, q.y, q.z)
    local uv  = Vector3f.new(qv.y * v.z - qv.z * v.y, qv.z * v.x - qv.x * v.z, qv.x * v.y - qv.y * v.x)
    local uuv = Vector3f.new(qv.y * uv.z - qv.z * uv.y, qv.z * uv.x - qv.x * uv.z, qv.x * uv.y - qv.y * uv.x)
    return Vector3f.new(
        v.x + ((uv.x * q.w) + uuv.x) * 2.0,
        v.y + ((uv.y * q.w) + uuv.y) * 2.0,
        v.z + ((uv.z * q.w) + uuv.z) * 2.0)
end

-- Hook fuer re4_vr_motion.lua (attach_weapon, letzte Station vor set_Position/set_Rotation).
-- WAFFE-only: Pos additiv im Frame der RECHTEN Hand, Rot lokal an die Waffe -- die Hand selbst
-- ist zu diesem Zeitpunkt schon geschrieben und bleibt unberuehrt.
-- Rueckgabe nil,nil = "nicht zustaendig" -> motion behaelt seine eigenen Werte.
-- =====================================================================
-- [BOW_PIN 2026-08-06] Compound Bow NATIV an die Hand haengen
-- =====================================================================
-- Bisher wurde der Bogen wie jede Waffe pro Frame in WELT-Koordinaten nachgezogen -> er lief der
-- Hand sichtbar hinterher. Dieselbe Lektion gab es bei den Magazin-/Shell-Klonen aus dem
-- Mag-Holster: erst das NATIVE Parenten hat sie festgeklebt (re4_vr_reload.lua, [NO_LAG]):
-- tf:call("set_Parent", body_transform) + tf:call("set_ParentJoint", "L_Hand")
-- und danach NUR noch set_LocalPosition/-Rotation. Die Engine propagiert die Transform dann VOR
-- dem Skinning -> kein Render-Versatz mehr.
--
-- Hier dasselbe fuer wp6304: einmal an R_Hand parenten, danach nur lokale Pose. Solange der Pin
-- steht, meldet __re4_merc_bow_pinned = true und motion.lua laesst die Waffe in Ruhe (sonst
-- pruegeln sich Welt-Schreiber und Parent um dieselbe Transform).
--
-- CRASH-FALLE (teuer bezahlt, s. re4_vr_holster.lua): set_Parent auf einen STALEN Transform loest
-- eine native Access Violation aus, die pcall NICHT faengt -> vor jedem Parenten get_Valid pruefen.
--
-- Die Slider "Wpn Pos/Rot" im Mercenaries-Tree wirken jetzt als LOKALE Pose am Handgelenk --
-- die alten Werte fuer 6304 passen nicht mehr 1:1 und muessen einmal neu eingestellt werden.
local BOW_PIN_JOINT = "R_Hand"
local bow_pin_on = true
local bowp = { go = nil, tf = nil, pinned = false }

local function bow_find_go(btf)
    if not btf then return nil end
    for _, suffix in ipairs({ "", "_MC", "_AO" }) do
        local nm = "wp" .. BOW_WID .. suffix
        local c = safe(function() return btf:call("get_Child") end)
        while c do
            local g = safe(function() return c:call("get_GameObject") end)
            local n = g and safe(function() return g:call("get_Name") end)
            if n == nm then return g, c end
            c = safe(function() return c:call("get_Next") end)
        end
    end
    return nil
end

local function bow_unpin()
    -- Zurueck an den Body-Root: die Engine setzt die Waffe beim naechsten Equip/Holster ohnehin
    -- selbst, wichtig ist nur, dass sie nicht am Handgelenk kleben bleibt.
    if bowp.tf then
        local cmgr = get_char_mgr()
        local ctx  = cmgr and safe(function() return cmgr:call("getPlayerContextRef") end)
        local bgo  = ctx and safe(function() return ctx:call("get_BodyGameObject") end)
        local ok   = bgo and safe(function() return bgo:call("get_Valid") end) ~= false
        local btf  = ok and safe(function() return bgo:call("get_Transform") end) or nil
        if btf then pcall(function() bowp.tf:call("set_ParentJoint", "") end) end
    end
    bowp.go, bowp.tf, bowp.pinned = nil, nil, false
end

local function update_bow_pin()
    local want = bow_pin_on
        and _G.__re4_in_mercs == true
        and rawget(_G, "__vr_dbg_wep_id") == BOW_WID
        and rawget(_G, "__re4_ks4_active") ~= true
        and rawget(_G, "__re4_ks_active") ~= true
    if not want then
        if bowp.pinned then bow_unpin() end
        _G.__re4_merc_bow_pinned = false
        return
    end

    if not bowp.pinned then
        local cmgr = get_char_mgr()
        local ctx  = cmgr and safe(function() return cmgr:call("getPlayerContextRef") end)
        local bgo  = ctx and safe(function() return ctx:call("get_BodyGameObject") end)
        -- [CRASH-FALLE] beide Seiten auf Gueltigkeit pruefen, sonst native AV beim set_Parent
        if not bgo or safe(function() return bgo:call("get_Valid") end) == false then return end
        local btf = safe(function() return bgo:call("get_Transform") end); if not btf then return end
        local go, tf = bow_find_go(btf)
        if not (go and tf) then return end
        if safe(function() return go:call("get_Valid") end) == false then return end
        pcall(function() tf:call("set_Parent", btf) end)
        local ok = pcall(function() tf:call("set_ParentJoint", BOW_PIN_JOINT) end)
        if not ok then return end
        bowp.go, bowp.tf, bowp.pinned = go, tf, true
    end

    -- nur noch LOKALE Pose -- die Welt macht die Engine
    local o = wep_off_for(BOW_WID)
    pcall(function()
        bowp.tf:call("set_LocalPosition", Vector3f.new(o.px or 0, o.py or 0, o.pz or 0))
        bowp.tf:call("set_LocalRotation", wep_quat_from_euler_deg(o.rx or 0, o.ry or 0, o.rz or 0))
    end)
    _G.__re4_merc_bow_pinned = true
end

_G.__re4_merc_wep_apply = function(wpos, wrot, wid, hand_rot)
    if not wep_off_on then return nil, nil end
    if _G.__re4_in_mercs ~= true then return nil, nil end
    if not wid then return nil, nil end

    local o = wep_off[tostring(wid)]
    if not o then return nil, nil end
    if o.px == 0 and o.py == 0 and o.pz == 0 and o.rx == 0 and o.ry == 0 and o.rz == 0 then
        return nil, nil
    end

    -- Die Rotation aus DIESEM Pass (von motion durchgereicht). __vr_rh_rot ist nur der Fallback --
    -- es wird erst am Tick-Ende publiziert und ist beim Aufruf einen Pass alt; damit gerechnet
    -- zappelt die Waffe bei schnellen Bewegungen um genau diese Differenz.
    local rr = hand_rot or rawget(_G, "__vr_rh_rot")
    if not rr then return nil, nil end

    local np, nr
    local ok = pcall(function()
        local ov = wep_rot_vec3(rr, Vector3f.new(o.px, o.py, o.pz))   -- Offset im Hand-Frame
        np = Vector3f.new(wpos.x + ov.x, wpos.y + ov.y, wpos.z + ov.z)
        if o.rx ~= 0 or o.ry ~= 0 or o.rz ~= 0 then
            nr = (wrot * wep_quat_from_euler_deg(o.rx, o.ry, o.rz)):normalized()
        else
            nr = wrot
        end
    end)
    if not ok or not (np and nr) then return nil, nil end
    return np, nr
end

-- =====================================================================
-- [MERCS_HUD 2026-08-05] Groesse + Position der beiden Mercs-Anzeigen:
-- * der fette Countdown oben -> chainsaw.TimerGuiBehavior (Ziffern liegen in _NumberPanel)
-- * der Balken unten -> chainsaw.BulletRushGaugeGuiBehavior (Wurzel-Panel _Main)
-- Das sind KEINE eigenen GUI-GameObjects, sondern GuiBehaviors -- deshalb ueber deren Panels.
-- Angefasst wird jeweils EIN Control: beim Timer das Eltern-Control der Ziffern (sonst muesste
-- man jede Ziffer einzeln schieben), beim Balken _Main. Die Ausgangswerte (Position/Scale)
-- werden beim ersten Fund gemerkt -> die Slider sind reine Offsets, 0/1.0 = Original.
-- Cache wird verworfen, sobald das Objekt weg ist (Save-Load/Runden-Ende), s.
-- Notiz.
-- Alles lebt HIER im Mercs-Script, nirgends sonst.
-- =====================================================================
local hud_apply, hud_ui
do
    local HUD = {
        -- [MERCS-HUD 2026-08-09, live gefunden] Mercenaries hat EIGENE HUD-Behaviors mit
        -- dem Praefix `Cp1021` -- `chainsaw.TimerGuiBehavior` (ohne Praefix) ist der Timer der
        -- KAMPAGNE und existiert hier nur nutzlos in der Szene. Deshalb bewegten die Slider
        -- nichts, egal ueber welches Panel oder in welchem Render-Pass.
        -- Alle vier tragen ihre Anzeige in `_Main` (via.gui.Panel) -- dieselbe Struktur, mit
        -- der der Balken von Anfang an funktioniert hat.
        -- [BASIS FEST 2026-08-09, gemessen] bx/by = Ausgangsposition des jeweiligen `_Main`.
        -- NICHT live nachmessen: nach einem Rundenwechsel liefert die Szene ein anderes Panel,
        -- und was man dann abliest, ist nicht zwingend die Nulllage -- die Offsets sassen
        -- danach woanders (bekannte Falle). Ueber 12
        -- Messungen mit ausgeschalteten Haken waren diese Werte bitgenau konstant, Scale 1.0.
        timer = { on = true, scale = 1.0, x = 0.0, y = 0.0, bx =  960.0, by =   0.0,
                  type = "chainsaw.Cp1021TimerGuiBehavior", field = "_Main", to_parent = false },
        score = { on = true, scale = 1.0, x = 0.0, y = 0.0, bx = 1444.0, by =   0.0,
                  type = "chainsaw.Cp1021HudScoreDispGuiBehavior", field = "_Main", to_parent = false },
        combo = { on = true, scale = 1.0, x = 0.0, y = 0.0, bx = 1920.0, by =   0.0,
                  type = "chainsaw.Cp1021HudComboGuiBehavior", field = "_Main", to_parent = false },
        total = { on = true, scale = 1.0, x = 0.0, y = 0.0, bx = 1520.0, by =  66.0,
                  type = "chainsaw.Cp1021HudTotalScoreGuiBehavior", field = "_Main", to_parent = false },
        gauge = { on = true, scale = 1.0, x = 0.0, y = 0.0, bx =    0.0, by = -20.0,
                  type = "chainsaw.BulletRushGaugeGuiBehavior", field = "_Main", to_parent = false },
        -- [2026-08-09] Gui_ui2710 -- gleiche Bedienung wie die anderen (Groesse, X, Y),
        -- nur der Weg dahin ist ein anderer: fuer diese Anzeige gibt es kein Behavior, ueber
        -- das der Szene-Scan sie finden koennte. Sie wird deshalb ueber den GameObject-NAMEN
        -- im Draw-Hook gegriffen (`go`).
        -- bx/by = Nulllage. Sie wird EINMAL gelesen (beim ersten Zeichnen) und danach
        -- gespeichert -- nie wieder nachgemessen. Wuerde man sie neu einlesen, waehrend wir
        -- schon schreiben, laese man den eigenen Wert (Basis+Offset) und der Offset kaeme ein
        -- zweites Mal drauf: genau das Aufschaukeln aus Notiz.
        ui2710 = { on = true, scale = 1.0, x = 0.0, y = 0.0, bx = nil, by = nil, go = "Gui_ui2710" },
        -- [2026-08-18] Gui_ui2764 -- gleicher Weg wie ui2710: kein Behavior vorhanden, also ueber den
        -- GameObject-NAMEN im Draw-Hook. bx/by bleiben nil und werden beim ERSTEN Zeichnen einmalig
        -- als Nulllage gelesen (nie nachmessen -- sonst liest man den eigenen Wert und der Offset
        -- kommt ein zweites Mal drauf).
        ui2764 = { on = true, scale = 1.0, x = 0.0, y = 0.0, bx = nil, by = nil, go = "Gui_ui2764" },
    }
    _G.__re4_merc_hud = HUD          -- damit lh_save/lh_load drankommen
    -- gespeicherte Werte uebernehmen (lh_load_cfg lief weiter oben, bevor es HUD gab)
    do
        local p = rawget(_G, "__re4_merc_hud_pending")
        if type(p) == "table" then
            for key, dst in pairs(HUD) do
                local src = p[key]
                if type(src) == "table" then
                    if src.on ~= nil then dst.on = src.on == true end
                    if tonumber(src.scale) then dst.scale = tonumber(src.scale) end
                    if tonumber(src.x) then dst.x = tonumber(src.x) end
                    if tonumber(src.y) then dst.y = tonumber(src.y) end
                    -- Nulllage nur fuer Namens-Eintraege (die anderen haben sie fest im Code)
                    if dst.go and tonumber(src.bx) and tonumber(src.by) then
                        dst.bx, dst.by = tonumber(src.bx), tonumber(src.by)
                    end
                end
            end
            _G.__re4_merc_hud_pending = nil
        end
    end
    local cache = {}                 -- key -> { ctrl, base_pos, base_scale }
    local scan_t = 0

    local function s(fn) local ok, r = pcall(fn); if ok then return r end end

    local function cur_scene()
        return s(function() return sdk.call_native_func(
            sdk.get_native_singleton("via.SceneManager"),
            sdk.find_type_definition("via.SceneManager"), "get_CurrentScene") end)
    end

    -- [SCOPE_HIDE] GameObject-Namen der HUD-GUIs, die beim Suchen anfallen. Damit blendet der
    -- Draw-Hook weiter unten genau diese Anzeigen im Scope aus -- ohne die Namen irgendwo
    -- hartkodieren zu muessen (sie ergeben sich aus denselben Behaviors, die wir eh finden).
    local hud_names = {}

    -- Ziel-Control eines Behaviors suchen (Szene-Scan, gedrosselt).
    local function find_ctrl(cfg)
        local t = s(function() return sdk.typeof(cfg.type) end); if not t then return nil end
        local scene = cur_scene()
        if not scene then return nil end
        local comps = s(function() return scene:call("findComponents(System.Type)", t) end)
        local n = comps and s(function() return comps:get_size() end) or 0
        for i = 0, n - 1 do
            local beh = s(function() return comps:get_element(i) end)
            local f   = beh and s(function() return beh:get_field(cfg.field) end)
            local ctrl = f
            -- Array-Feld (_NumberPanel) -> erstes Element
            if f and s(function() return f:get_size() end) then
                ctrl = s(function() return f:get_element(0) end)
            end
            if ctrl and cfg.to_parent then
                local p = s(function() return ctrl:call("get_Parent") end)
                if p then ctrl = p end
            end
            if ctrl then
                -- Namen des tragenden GameObjects merken (fuer das Ausblenden im Scope)
                local go = beh and s(function() return beh:call("get_GameObject") end)
                local nm = go and s(function() return go:call("get_Name") end)
                if type(nm) == "string" then hud_names[nm] = true end
                return ctrl
            end
        end
        return nil
    end

    -- [NEUE RUNDE 2026-08-09] Zwischen zwei Mercs-Runden baut die Engine die HUD-GUIs
    -- neu auf. Das alte Control bleibt als LEICHE im Speicher liegen und liefert weiterhin
    -- brav eine Position -- ein Check "kommt noch ein Wert?" schlaegt also NICHT an (genau
    -- Notiz). Deshalb wird im Scan-Takt immer neu
    -- gesucht; gecacht ist nur noch das Control selbst.
    -- Die Ausgangsposition wird BEWUSST NICHT mitgelesen, sie steht fest in HUD (bx/by).
    local function entry(key, cfg, may_scan)
        local e = cache[key]
        if e and not s(function() return e.ctrl:call("get_Position") end) then e = nil; cache[key] = nil end
        if not may_scan then return e end

        local fresh = find_ctrl(cfg)
        if not fresh then cache[key] = nil; return nil end
        e = { ctrl = fresh }
        cache[key] = e
        return e
    end

    hud_apply = function()
        if _G.__re4_in_mercs ~= true then return end
        local now = os.clock()
        local may_scan = (now - scan_t) > 1.0
        for key, cfg in pairs(HUD) do
            -- Eintraege mit `go` haben kein Behavior -- die holt sich der Draw-Hook selbst.
            if cfg.go then goto next_entry end
            -- [SCOPE_HIDE] Gesucht wird IMMER (auch ohne Haken) -- nur so kennt der Draw-Hook
            -- unten die GameObject-Namen. Veraendert wird nach wie vor nur mit Haken.
            if cache[key] or may_scan then
                local e = entry(key, cfg, may_scan)
                if e and cfg.on then
                    -- absolut gegen die feste Basis, nie gegen einen gelesenen Ist-Wert
                    s(function() e.ctrl:call("set_Position",
                        Vector3f.new(cfg.bx + cfg.x, cfg.by + cfg.y, 0.0)) end)
                    s(function() e.ctrl:call("set_Scale",
                        Vector3f.new(cfg.scale, cfg.scale, cfg.scale)) end)
                end
            end
            ::next_entry::
        end
        if may_scan then scan_t = now end
    end

    -- [SCOPE_HIDE 2026-08-09] Analog zur Hand-HUD-Gruppe in re4_vr_crosshair.lua (~755):
    -- beim Zielen durch ein montiertes Scope liegen die Mercs-Anzeigen mitten im gezoomten
    -- Bild -> gar nicht erst zeichnen. Beide Signale, damit es mit UND ohne unseren Fork
    -- greift: `__re4_scope_native` (Fork) bzw. `__re4_force_killswitch_scope` (sonst).
    -- Betrifft AUSSCHLIESSLICH die GameObjects, an denen die oben gesuchten Mercs-HUD-
    -- Behaviors haengen, und nur waehrend Mercenaries laeuft -- die Kampagne sieht davon nichts.
    -- Root-Control einer GUI ueber ihr GameObject. Bewusst OHNE Cache: zwischen zwei
    -- Runden baut die Engine die HUD-GUIs neu auf, ein gehaltenes Control waere danach
    -- eine Leiche (bekannte Falle).
    -- Kind mit diesem Namen (Geschwisterkette). Ueber NAMEN, nicht ueber Index --
    -- auf die Reihenfolge der Kinder sollte man sich nicht verlassen.
    local function child_by_name(ctrl, want)
        local c = s(function() return ctrl:call("get_Child") end)
        while c do
            if s(function() return c:call("get_Name") end) == want then return c end
            c = s(function() return c:call("get_Next") end)
        end
        return nil
    end

    local function root_ctrl(go)
        local td = s(function() return sdk.typeof("via.gui.GUI") end); if not td then return nil end
        local comp = s(function() return go:call("getComponent(System.Type)", td) end)
        local view = comp and s(function() return comp:call("get_View") end)
        return view and s(function() return view:call("get_Child") end)
    end

    re.on_pre_gui_draw_element(function(element, context)
        if _G.__re4_in_mercs ~= true then return true end

        local go = s(function() return element:call("get_GameObject") end)
        local nm = go and s(function() return go:call("get_Name") end)
        if type(nm) ~= "string" then return true end

        -- [2026-08-09] Namens-Eintraege (Gui_ui2710): hier gesetzt, weil es fuer sie
        -- kein Behavior gibt, ueber das der Szene-Scan sie finden koennte. Sonst genau wie
        -- die anderen: Position ABSOLUT als Basis + Offset, Groesse absolut auf den Regler.
        for _, cfg in pairs(HUD) do
            if cfg.go == nm and cfg.on then
                local ctrl = root_ctrl(go)
                if ctrl then
                    -- Nulllage genau EINMAL lesen, danach nie wieder (sonst Aufschaukeln).
                    if cfg.bx == nil or cfg.by == nil then
                        local p = s(function() return ctrl:call("get_Position") end)
                        local px = p and s(function() return p.x end)
                        local py = p and s(function() return p.y end)
                        if type(px) == "number" and type(py) == "number" then
                            cfg.bx, cfg.by = px, py
                            if type(rawget(_G, "__re4_merc_save_cfg")) == "function" then
                                _G.__re4_merc_save_cfg()
                            end
                        end
                    end

                    if cfg.bx and cfg.by then
                        s(function() ctrl:call("set_Position",
                            Vector3f.new(cfg.bx + (cfg.x or 0.0), cfg.by + (cfg.y or 0.0), 0.0)) end)
                    end
                    s(function() ctrl:call("set_Scale",
                        Vector3f.new(cfg.scale or 1.0, cfg.scale or 1.0, cfg.scale or 1.0)) end)
                end
            end
        end

        -- [2026-08-09] Gui_ui2770: mit Haken gar nicht erst zeichnen. Nur in
        -- Mercenaries (der Hook steigt oben aus, wenn __re4_in_mercs nicht steht).
        if nm == "Gui_ui2770" and hide_2770 then return false end

        -- [2026-08-09] Timer-Hintergrund. Jeden Frame durchgedrueckt, weil die
        -- Engine die Sichtbarkeit sonst zurueckstellt. Die Knoten werden ueber NAMEN
        -- gesucht (Baum aus dem UILogger), nicht ueber Kind-Indizes.
        if nm == "Gui_ui2700" and hide_timer_bg then
            local root = root_ctrl(go)
            if root then
                local a = child_by_name(root, "c_bg_new")
                if a then s(function() a:call("set_Visible", false) end) end
                local t = child_by_name(root, "c_timer")
                local b = t and child_by_name(t, "c_bg")
                if b then s(function() b:call("set_Visible", false) end) end
            end
        end

        if rawget(_G, "__re4_scope_native") ~= true
           and rawget(_G, "__re4_force_killswitch_scope") ~= true then return true end
        if hud_names[nm] then return false end
        return true
    end)

    hud_ui = function(save)
        imgui.separator()
        imgui.text_colored("HUD (nur Mercenaries): Groesse + Position", 0xFF66CCFF)
        do
            local c2, v2 = imgui.checkbox("Gui_ui2770 ausblenden", hide_2770)
            if c2 then hide_2770 = v2; save() end
            local c3, v3 = imgui.checkbox("Hintergrund hinter dem Countdown aus", hide_timer_bg)
            if c3 then hide_timer_bg = v3; save() end
        end
        local ORDER = {
            { "timer", "Countdown oben" },
            { "score", "Punkte-Anzeige" },
            { "combo", "Combo-Anzeige" },
            { "total", "Gesamtpunktzahl" },
            { "gauge", "Balken unten" },
            { "ui2710", "Gui_ui2710" },
            { "ui2764", "Gui_ui2764" },
        }
        for _, ent in ipairs(ORDER) do
            local key, name = ent[1], ent[2]
            local cfg  = HUD[key]
            local c, v = imgui.checkbox(name .. " anpassen##hud" .. key, cfg.on)
            if c then cfg.on = v; save() end

            -- [2026-08-09] Ohne Haken wird gar nicht gesucht (hud_apply ueberspringt den
            -- Eintrag) -- dann steht hier zwangslaeufig "nein" und die Slider koennen nichts
            -- bewirken. Das war die eigentliche Ursache fuer "die Slider machen nichts".
            if cfg.go then
                imgui.text_colored("   ueber den GameObject-Namen (" .. cfg.go .. "), Nulllage: "
                    .. (cfg.bx and string.format("%.0f / %.0f", cfg.bx, cfg.by) or "noch nicht gelesen"),
                    cfg.bx and 0xFF00FF00 or 0xFF66CCFF)
            elseif not cfg.on then
                imgui.text_colored("   gefunden: nein -- Haken ist aus, es wird nicht gesucht",
                    0xFF66CCFF)
            elseif rawget(_G, "__re4_in_mercs") ~= true then
                imgui.text_colored("   gefunden: nein -- wir sind nicht in Mercenaries", 0xFF66CCFF)
            else
                imgui.text_colored("   gefunden: " .. (cache[key] and "ja" or "nein (noch nicht in der Szene)"),
                    cache[key] and 0xFF00FF00 or 0xFF5555FF)
            end
            local b
            b, cfg.scale = imgui.drag_float("Groesse##hs" .. key, cfg.scale or 1.0, 0.01, 0.10, 3.00, "%.2f")
            if b then save() end
            b, cfg.x = imgui.drag_float("X (rechts +)##hx" .. key, cfg.x or 0.0, 1.0, -1500, 1500, "%.0f")
            if b then save() end
            b, cfg.y = imgui.drag_float("Y (runter +)##hy" .. key, cfg.y or 0.0, 1.0, -1500, 1500, "%.0f")
            if b then save() end
        end
    end
end

-- =====================================================================
-- [BULLETRUSH_KS4 2026-08-05] Mercenaries-Ragemodus ("BulletRush")
-- =====================================================================
-- Gemessen mit re4_zzz_rage_probe (Log 23:22): waehrend der Rage-Phase steht am HeadUpdater
-- (chainsaw.Ch6CommonHeadUpdater -- gilt fuer ALLE Mercs-Charaktere) `get_PlayingBulletRush`
-- auf true, `_BulletRushState` springt dabei 3 -> 4. Der Killswitch ist in dieser Zeit komplett
-- AUS (Log: active=false, CamState pendelt BattleNormal(1) <-> Combat(20)) -- fuer die Engine ist
-- das normales Gameplay, deshalb bleiben die VR-Haende stehen, waehrend der Body nativ pruegelt.
--
-- Wir publizieren das Flag; den KS4 macht daraus der Killswitch (Force-Zweig "ks4_bulletrush",
-- Muster wie boltcycle). Das deckt die GANZE Phase ab -- auch das Beamen von Gegner zu Gegner --
-- und endet von selbst, ganz ohne Trigger-Hook.
--
-- Jeden Frame aktualisiert (NICHT im CHECK_EVERY-Takt): das Flag muss sofort wieder fallen,
-- sonst haengt der KS4 nach. Zwei Sicherungen, weil ein haengendes true den Spieler in Dauer-KS4
-- sperren wuerde: ausserhalb Mercs immer false, und eine harte Zeitgrenze.
--
-- [NUR_WESKER 2026-08-05] Vorerst ausschliesslich Wesker (KindID 600005). Leons Mercs-
-- Superpower ist eine andere -- dort muss alles normales Gameplay bleiben; die uebrigen vier
-- Charaktere prueft man noch. Erweitern = weitere KindID in BR_CHARS eintragen.
local BR_CHARS = { [600005] = true }   -- Wesker
local br_hu, br_since = nil, 0
local BR_MAX_SEC = 60.0
local function update_bulletrush()
    if _G.__re4_in_mercs ~= true or BR_CHARS[rawget(_G, "__re4_merc_kind")] ~= true then
        br_hu, br_since = nil, 0
        _G.__re4_force_ks4_bulletrush = false
        return
    end
    if not br_hu then
        local cmgr = get_char_mgr()
        local ctx  = cmgr and safe(function() return cmgr:call("getPlayerContextRef") end)
        br_hu = ctx and safe(function() return ctx:call("get_HeadUpdater") end) or nil
    end
    local on = false
    if br_hu then
        local v = safe(function() return br_hu:call("get_PlayingBulletRush") end)
        -- Kein Wert = toter/gewechselter HeadUpdater -> Cache verwerfen (Save-Load-Falle),
        -- siehe Notiz
        if v == nil then br_hu = nil else on = (v == true) end
    end
    if on then
        if br_since == 0 then
            br_since = os.clock()
        elseif (os.clock() - br_since) > BR_MAX_SEC then
            on = false   -- Notbremse: laenger als eine Rage-Phase dauert das nie
        end
    else
        br_since = 0
    end
    _G.__re4_force_ks4_bulletrush = on
end

re.on_frame(function()
    update_bulletrush()
    update_bow_pin()   -- [BOW_PIN] Compound Bow haengt nativ am Handgelenk
    -- [REIHENFOLGE 2026-08-05] Voll-Aus ZUERST, Kopf/Haar danach: beim Verlassen von KS3/KS5 setzt
    -- das Voll-Aus alle Materialien wieder an -- apply_hide muss im SELBEN Frame das letzte Wort
    -- ueber Kopf/Haare haben, sonst blitzen sie einen Frame lang auf.
    apply_full_hide()   -- [MERC_FULLHIDE] KS3/KS5 (Stagger/Treffer): ganzer Koerper aus
    apply_hide()
    hud_apply()   -- sucht + setzt; der zweite, spaete Pass haengt unten an BeginRendering

    frames = frames + 1
    if frames % CHECK_EVERY ~= 0 then return end

    local in_mercs, cid = detect()

    -- [SW_VS_MERCS 2026-08-04] ZWEITES Kriterium: der Body-GO des Spielers muss einer der
    -- Mercs-Bodys sein. Ohne das meldet detect auch im Separate-Ways-DLC "Mercenaries" (live
    -- gemessen: get_GuiManager ~= nil UND CampaignID -1, waehrend Ada in SW lief) -- und dann
    -- greift im Binding der Mercs-Zweig samt seiner Mercs-Bindings fuer Adas Kampagne.
    -- Ist der Body gerade nicht lesbar (Ladephase), bleibt der letzte Befund stehen.
    if in_mercs then
        local _, body_now = get_player_body()
        if type(body_now) == "string" and body_now ~= "" then
            merc_body_ok = (MERC_BODIES[body_now] == true)
        end
        in_mercs = merc_body_ok
    else
        merc_body_ok = false
    end

    _G.__re4_in_mercs = in_mercs
    _G.__re4_merc_cid = cid

    if in_mercs ~= last_state then
        last_state = in_mercs
        -- [KEIN-WERT-FALLE 2026-08-06] Body ueber eine Zwischenvariable holen, NICHT per select(2,...)
        -- direkt in tostring: fehlt der zweite Rueckgabewert, bekommt tostring gar kein Argument.
        local _, _body_log = get_player_body()
    end

    if not in_mercs then
        _G.__re4_merc_kind, _G.__re4_merc_body = nil, nil
        hh_meshes, hh_body = nil, nil   -- ausserhalb Mercs fassen wir NICHTS an
        all_meshes, full_hidden = nil, false   -- [MERC_FULLHIDE] dito
        _G.__vr_active_char = nil              -- [ARM_KEY] ausserhalb Mercs wieder Leons Preset
        return
    end

    local kind, body, tf = get_player_body()
    _G.__re4_merc_kind, _G.__re4_merc_body = kind, body

    -- [CACHE-LEICHEN 2026-08-09, Log-belegt] Beim Rundenwechsel meldet der Body kurz
    -- NICHTS (Log 17:04:14 "Body='nil'", eine Sekunde spaeter wieder 'ch6i0z0_body'). Der
    -- Neuaufbau unten haengt aber an `hh_body ~= body` -- und weil in der Luecke gar nichts
    -- passiert, ist der Name danach WIEDER derselbe: die Bedingung ist falsch, die gecachten
    -- Renderer der alten Runde bleiben stehen. Auf so eine Leiche zu schreiben wirft KEINEN
    -- Fehler (die Engine haelt das Objekt noch), also greift auch die pcall-Selbstheilung
    -- nicht -- man sah Kopf/Haare im KS3 weiterhin, waehrend nur die ueber die SZENE gesuchten
    -- EXTRA_MATS verschwanden. Deshalb hier die Luecke selbst als Trigger nehmen:
    -- kein lesbarer Body -> Caches wegwerfen, der naechste gueltige Body baut sie neu auf.
    if type(body) ~= "string" or body == "" then
        hh_meshes, hh_body = nil, nil
        all_meshes, full_hidden = nil, false

        -- [RUNDEN-TOKEN 2026-08-09] Dieselbe Luecke ist der einzige verlaessliche
        -- Hinweis auf "neue Runde" (das Spiel laedt die Map neu, ein eigenes Flag dafuer
        -- kennen wir nicht). Andere Scripte haengen ihren Zustands-Reset daran: wer sich
        -- den Token merkt und ihn bei Aenderung vergleicht, wirft genau einmal pro Runde
        -- seine Waffen-/Ladezustaende weg. Nur EINMAL pro Luecke hochzaehlen, nicht pro
        -- Frame -- sonst wuerde waehrend der ganzen Ladephase dauernd zurueckgesetzt.
        if not round_gap then
            round_gap = true
            _G.__re4_merc_round = (tonumber(rawget(_G, "__re4_merc_round")) or 0) + 1
        end
        return
    end
    round_gap = false

    -- [ARM_KEY 2026-08-06] Arm-IK pro Mercs-Charakter. re4_vr_arm_chain.lua kann das laengst:
    -- resolve_config_key liest __vr_active_char, apply_key_config laedt den passenden Block und
    -- save_config schreibt unter genau diesem Schluessel -- nur hat den Wert NIE jemand gesetzt,
    -- also lief alles (auch Krauser) mit Leons Werten. Fehlt ein Block in der JSON, faellt arm_chain
    -- weiter auf "leon" zurueck -> bis zum ersten Speichern aendert sich fuer niemanden etwas.
    -- Kampagne und Adas DLC bleiben unberuehrt: dort setzt niemand das Global (= "leon", belegt gut).
    _G.__vr_active_char = MERC_ARM_KEYS[kind] or "leon"

    if kind ~= last_kind then
        last_kind = kind
        local known = (type(kind) == "number") and MERC_CHARS[kind]
    end

    -- Kopf/Haar-Meshes suchen, sobald sich der Body geaendert hat oder der
    -- Cache verworfen wurde. Laeuft fuer JEDEN Mercs-Charakter -- der GO-Name
    -- reicht; eine hinterlegte Hide-Liste ist nur noch die Zusatzsicherung.
    if type(body) == "string" and body ~= "" and (hh_meshes == nil or hh_body ~= body) then
        local entry = (type(kind) == "number") and MERC_CHARS[kind]
        hh_meshes = collect_hh(tf, entry and entry.hide)
        hh_body   = hh_meshes and body or nil
        -- [MERC_FULLHIDE] am selben Punkt einsammeln: gleicher Body, gleiche Lebensdauer
        all_meshes, full_hidden = collect_all_meshes(tf), false
        if hh_meshes and hh_logged ~= body then
            hh_logged = body
            local names = {}
            for _, e in ipairs(hh_meshes) do names[#names + 1] = e.name end
        end
    end
end)

-- Statusanzeige am DESKTOP (im Headset nicht lesbar -> alles Wichtige
-- steht zusaetzlich im Log). Kein Button, nichts zum Bedienen.
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - Mercenaries (DLC)" raus (56 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

-- =====================================================================
-- [BOW_KEEP 2026-08-05] Die Engine steckt den Compound Bow im Lauf von selbst weg
-- =====================================================================
-- Im Volltrace (re4_zzz_wswitch.log, 22:22:54) steht die Kette OHNE jeden Tastendruck und
-- ohne Lua im Stack:
-- requestEquipBareHand(0,0) -> requestChangeWeaponAction -> execChangeWeapon
-- -> equipWeapon(0,-1,..) -> castoffWeapon(-255) -> storageWeapon(6304,0) -> equip=-1
-- Also derselbe Fall wie beim Messer (re4_vr_weapons2.lua): ein NATIVER Zug, den wir nicht
-- wollen. Geblockt wird der AUSLOESER (requestEquipBareHand), damit die Kette gar nicht erst
-- anlaeuft -- mit denselben Gates wie dort:
-- * nur in Mercenaries und nur mit dem Bogen (6304) in der Hand,
-- * nur NATIVE Aufrufe -- steht eins unserer Scripte im Stack (Holster/Binding), geht es durch,
-- * nie im Killswitch/KS4 (Cutscene/Sonderfall: die Engine darf machen, was sie will).
-- ACHTUNG beim Test: verhaelt sich der Bogen an Leitern/bei Interaktionen komisch, ist genau
-- dieser Block schuld -- dann melden, dann gaten wir zusaetzlich auf den Spielerzustand.
-- Signatur-Falle: SKIP_ORIGINAL braucht bei nicht-void einen Rueckgabewert, darum der Post-Hook.
_G.__re4_merc_bow_keep_blocked = 0
if not _G.__re4_merc_bow_keep_hooked then
    _G.__re4_merc_bow_keep_hooked = true
    local bk_td = sdk.find_type_definition("chainsaw.PlayerEquipment")
    local bk_m  = bk_td and bk_td:get_method("requestEquipBareHand(System.Boolean, System.Boolean)")
    if not bk_m then
    else
        local bk_rt = safe(function() return bk_m:get_return_type():get_full_name() end)
        local bk_void = (bk_rt == nil) or (bk_rt == "System.Void")
        local bk_skipped = false
        sdk.hook(bk_m,
            function(args)
                local skip = false
                pcall(function()
                    if _G.__re4_in_mercs ~= true then return end
                    if rawget(_G, "__vr_dbg_wep_id") ~= BOW_WID then return end
                    if rawget(_G, "__re4_holster_killswitch") == true then return end
                    if rawget(_G, "__re4_ks4_active") == true then return end
                    local native = true
                    local tb = (debug and debug.traceback) and debug.traceback("", 2) or ""
                    for line in tb:gmatch("[^\n]+") do
                        if line:find("autorun", 1, true) and not line:find("re4_vr_merc", 1, true) then
                            native = false; break
                        end
                    end
                    skip = native
                end)
                bk_skipped = skip
                if skip then
                    _G.__re4_merc_bow_keep_blocked = (_G.__re4_merc_bow_keep_blocked or 0) + 1
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
            end,
            function(ret)
                if bk_skipped then
                    bk_skipped = false
                    if not bk_void then return sdk.to_ptr(0) end
                end
                return ret
            end)
    end
end

-- =====================================================================
-- [LASER-DOT MERCS 2026-08-18] Der rote Punkt am Ende des Lasers
-- =====================================================================
-- SYMPTOM: In der Kampagne haben alle Pistolen mit Laser-Aufsatz (und die Killer7, die ihn immer
-- hat) einen Punkt am Strahlende. In Mercs -- Leons SG-09 R mit Aufsatz, Weskers Killer7 -- wird
-- der STRAHL gezeichnet, der PUNKT fehlt.
--
-- GEMESSEN (live in Mercs, 18.08.):
--   Gun.<WeaponPartsCustom> = null, Gun.<CustomLevelInWeapon> = null
--     -> die Mercs-Waffe kennt keine angebauten Teile, der Aufsatz ist nur Modell.
--   PlayerEquipment.IsEnableLaserSight = false, Gun.get_EnableLaserSight() = false
--     -> ein set_IsEnableLaserSight(true) wird noch im selben Frame zurueckgerechnet.
--   LaserSightController: vorhanden, Line-GO ('ver5') und Anker-GO ('Light') werden gezeichnet,
--     aber _IsDraw = false, und der DOT ist der `PointerEffect` des Controllers -- dessen
--     Container stand auf isFinished=true / isDisposing=true / Creator=nil, also fertig und in
--     Entsorgung. Am 'Light'-GO selbst haengt weder Lichtquelle noch Mesh, es ist nur der Anker.
--   `castLaserSightTip()` rechnet uebrigens sauber (die Tip-Position wandert mit dem Zielen) --
--     der Punkt haengt also NICHT an ihr, sondern am Effekt.
--
-- FIX (live bestaetigt: "dot ist da"): zwei Handgriffe, beide nur in Mercs und nur, solange die
-- Engine selbst KEINEN Lasersight meldet -- die Kampagne laeuft damit unveraendert weiter:
--   1. `set_IsEnableLaserSight(true)` + `castLaserSightTip()`/`updateLaserSightTip()`
--      -> die Ziel-Position des Punktes. FEHLT DAS, klebt der Punkt an der Waffe (so passiert,
--         als der Schritt beim ersten Einbau nicht mitkam).
--   2. `setDraw(true)` + `_IsDraw` halten  -> der Controller zeichnet ueberhaupt.
--   3. `start()` bei totem Effekt          -> baut den PointerEffect neu auf. `setDraw` allein
--      genuegt NICHT, es schaltet nur Sichtbarkeit; erzeugt wird der Effekt in start().
--
-- Kosten: die Controller-Suche laeuft nur alle 0.5 s und wird pro Waffen-GO gecacht; pro Frame
-- bleibt ein Feld-Lesen. `start()` hoechstens dreimal pro Waffe -- bringt es das nicht, ist der
-- Weg falsch und nicht die Zahl der Versuche.
-- RUECKBAU: _G.__re4_merc_dot = false
-- =====================================================================
-- [WAFFENLISTE 2026-08-18 -- vom Tester vorgegeben] In Mercs haben GENAU DIESE DREI Waffen einen
-- Laser, alle anderen nicht. Die vorherige Heuristik (gibt es ein gezeichnetes Strahl-Objekt?) hat
-- nicht getragen: bei Adas Pistole ohne Aufsatz meldete der Controller trotzdem eine Linie, und der
-- Fix setzte einen nackten roten Punkt an die Waffe. Liste schlaegt Heuristik.
local MERC_LASER_WIDS = {
    [6304] = true,   -- EJF-338 Compound Bow (MC)
    [4000] = true,   -- SG-09 R
    [4501] = true,   -- Killer7
}

local DOT = { lsc = nil, key = nil, tries = 0, next_scan = 0.0, body_weg = false, aimed = false, draw_frames = 0,
              T = safe(function() return sdk.typeof("chainsaw.LaserSightController") end) }

function DOT.gun()
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager"); if not cm then return nil end
    local ctx = safe(function() return cm:call("getPlayerContextRef") end); if not ctx then return nil end
    local hu = safe(function() return ctx:call("get_HeadUpdater") end); if not hu then return nil end
    local g = safe(function() return hu:call("get_EquipWeapon") end)
    if g and safe(function() return g:get_type_definition():is_a("chainsaw.Gun") end) then return g end
    return nil
end

-- Der Controller haengt am Aufsatz, also evtl. ein paar Ebenen unter dem Waffen-GO.
function DOT.find(go, depth)
    if not (go and DOT.T) or (depth or 0) > 6 then return nil end
    local c = safe(function() return go:call("getComponent(System.Type)", DOT.T) end)
    if c then return c end
    local tf = safe(function() return go:call("get_Transform") end); if not tf then return nil end
    local child = safe(function() return tf:call("get_Child") end)
    local guard = 0
    while child and guard < 128 do
        guard = guard + 1
        local cgo = safe(function() return child:call("get_GameObject") end)
        local r = cgo and DOT.find(cgo, (depth or 0) + 1)
        if r then return r end
        child = safe(function() return child:call("get_Next") end)
    end
    return nil
end

-- [LEVELSTART 2026-08-18 -- gemessen] Zwei Mercs-Neustarts, alle Kandidaten nebeneinander
-- protokolliert: Szene (`MainScene`), MercenariesManager und dessen GuiManager blieben bitgleich,
-- NUR die Player-Body-Adresse wechselte jedes Mal (204CED80 -> ? -> 2229A5E0 -> ? -> 24EC0170;
-- das "?" ist die Ladephase, in der der Body nicht lesbar ist). Die Waffen-GO-Adresse allein taugt
-- nicht -- sie griff einmal nach "Reset Scripts" und danach nicht mehr.
-- Waehrend der Ladephase (Body nicht lesbar) wird NICHTS zurueckgesetzt, sonst wuerde jedes
-- kurzzeitige Aussetzen als Neustart zaehlen.
local function player_body_addr()
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager"); if not cm then return nil end
    local ctx = safe(function() return cm:call("getPlayerContextRef") end); if not ctx then return nil end
    local bg = safe(function() return ctx:call("get_BodyGameObject") end); if not bg then return nil end
    return safe(function() return bg:get_address() end)
end

function DOT.tick()
    if rawget(_G, "__re4_merc_dot") == false then return end

    -- [LEVELSTART 2026-08-18 -- gemessen] Eine neue Runde erkennt man daran, dass der Spieler-Body
    -- kurz NICHT lesbar ist (Ladephase, im Watcher-Log als `body=?`). Das trat bei beiden getesteten
    -- Neustarts auf, unabhaengig von Charakter und Speicheradresse. Szene, MercenariesManager und
    -- GuiManager blieben dabei bitgleich, taugen also nicht; die Waffen-GO-Adresse griff nur einmal
    -- nach "Reset Scripts". Ein Adressvergleich waere ueberfluessig -- er sagt nichts, was die
    -- Ladephase nicht schon sagt, und ginge daneben, sobald die Engine eine Adresse wiederverwendet.
    if not player_body_addr() then
        DOT.body_weg = true              -- Ladephase laeuft -- hier NICHTS zuruecksetzen
    elseif DOT.body_weg then
        DOT.body_weg = false             -- Body wieder da -> neue Runde -> Punkt neu scharf stellen
        DOT.aimed, DOT.lsc, DOT.key, DOT.tries = false, nil, nil, 0
    end
    if _G.__re4_in_mercs ~= true then DOT.lsc, DOT.key, DOT.aimed = nil, nil, false; return end

    local g = DOT.gun(); if not g then return end

    -- Nur die drei Mercs-Laserwaffen -- alles andere bleibt unberuehrt (Kampagne laeuft ohnehin
    -- nicht hier durch, das Gate `__re4_in_mercs` steht oben).
    local wid = safe(function() return g:call("get_WeaponID") end)
    wid = tonumber(wid)
    if not (wid and MERC_LASER_WIDS[wid]) then return end

    -- Meldet die Engine selbst einen Lasersight, fassen wir nichts an.
    if safe(function() return g:call("get_EnableLaserSight") end) == true then return end

    -- [WAFFENWECHSEL ZUERST 2026-08-18] Der Reihenfolge-Fehler: der Aim-Check stand VOR dem
    -- Waffenvergleich, und `DOT.aimed` wurde beim Wechsel gar nicht zurueckgesetzt. Wer am
    -- Rundenanfang mit irgendetwas anderem gezielt hatte, brachte den Punkt beim spaeteren Ziehen
    -- der Laserwaffe sofort mit -- ohne dass je MIT DIESER Waffe gezielt wurde.
    -- Jetzt: erst Waffe feststellen (und beim Wechsel alles inklusive `aimed` verwerfen), danach
    -- das Aimen pruefen. Damit gilt die Bedingung "erstes Zielen mit GENAU DIESER Waffe".
    local wgo = safe(function() return g:call("get_GameObject") end); if not wgo then return end
    local key = safe(function() return wgo:get_address() end)
    if key ~= DOT.key then
        DOT.key, DOT.lsc, DOT.tries, DOT.draw_frames, DOT.aimed = key, nil, 0, 0, false
    end

    -- [ERST BEIM AIMEN 2026-08-18] Bis zum ersten Zielen wird NICHTS gemacht. Grund: direkt nach
    -- dem Levelstart gibt es noch keine gueltige Tip-Position, der Punkt entsteht dann am Anker-GO
    -- und klebt an der Muendung, bis einmal gezielt wurde. Beim Aimen ist die Position gueltig.
    -- Betrifft AUSSCHLIESSLICH den Punkt -- am Laserstrahl aendert das nichts, der wird hier gar
    -- nicht angefasst (der laeuft ueber den updateLaser-Hook in re4_vr_crosshair.lua).
    if not DOT.aimed then
        if rawget(_G, "__vr_aim_input") ~= true then return end
        DOT.aimed = true
    end

    if not DOT.lsc then
        local t = os.clock()
        if t < DOT.next_scan then return end
        DOT.next_scan = t + 0.5
        DOT.lsc = DOT.find(wgo, 0)
        if not DOT.lsc then return end
    end

    -- 1. Die TIP-POSITION rechnen lassen -- ohne sie hat der Punkt kein Ziel und klebt an der
    -- Waffe (genau das passierte, als dieser Schritt beim Einbau zuerst fehlte). Die Engine ruft
    -- das in Mercs nie, weil sie keinen Lasersight kennt; die Rechnung selbst funktioniert
    -- einwandfrei (die Position wandert live mit dem Zielen).
    local pe_eq = safe(function() return g:call("get_OwnerEquipment") end)
    if pe_eq then safe(function() pe_eq:call("set_IsEnableLaserSight", true) end) end
    safe(function() g:call("castLaserSightTip") end)
    safe(function() g:call("updateLaserSightTip") end)

    -- 2. Der Controller muss zeichnen duerfen.
    if safe(function() return DOT.lsc:get_field("_IsDraw") end) ~= true then
        safe(function() DOT.lsc:call("setDraw", true) end)
        safe(function() DOT.lsc:set_field("_IsDraw", true) end)
    end

    -- 3. Toten Punkt-Effekt neu aufbauen lassen. Genau so lief der abgenommene Test:
    -- sofort, sobald ein toter Container gesehen wird, hoechstens dreimal pro Waffe.
    -- (Zwei Nachbesserungen sind hier gescheitert und bleiben deshalb draussen: den Anker selbst
    -- setzen -- das macht der Laser-Hook in re4_vr_crosshair.lua, zwei Schreiber = Punkt schwebt;
    -- und start() um ein paar Frames verzoegern -- dann kam gar kein Punkt mehr.)
    -- [AIM-GATE 2026-08-18] NUR der Punkt haengt am Zielen, der STRAHL laeuft unveraendert weiter
    -- (Schritt 1 und 2 oben bleiben deshalb ungegatet). Grund: vor dem ersten Zielen hat
    -- `castLaserSightTip()` noch kein Ziel -- wird der Effekt vorher gebaut, klebt der Punkt an
    -- der Waffe. Also erst beim Zielen aufbauen lassen, dann sitzt er von Anfang an richtig.
    -- Zielzustand = __vr_aim_input (LT >= 0.5, binding.lua:1217), der ECHTE VR-Zielzustand.
    if rawget(_G, "__vr_aim_input") == true and DOT.tries < 3 then
        local eff = safe(function() return DOT.lsc:get_field("<PointerEffect>k__BackingField") end)
        local dead = (eff == nil)
            or (safe(function() return eff:call("get_isFinished") end) == true)
            or (safe(function() return eff:call("get_isDisposing") end) == true)
        if dead then
            DOT.tries = DOT.tries + 1
            safe(function() DOT.lsc:call("start") end)
        end
    end
end

-- Im LateUpdateBehavior, also NACH dem Engine-Update: frueher gesetzt, dreht die Engine _IsDraw
-- im selben Frame wieder zurueck (genau das zeigte der Test).
re.on_application_entry("LateUpdateBehavior", function() pcall(DOT.tick) end)
