-- Builtin implementation: src/mods/vr/games/re4/RE4VRMaterials.cpp
return

-- ============================================================
-- RE4 VR Materials
-- Versteckt nur Leons Head- und Hair-Materialien.
-- Scene-Walk auf ch0a0z0_body, setMaterialsEnable(false) auf Treffer.
-- Killswitch-aware: in Cutscenes Materialien WIEDER AN (Kopf sichtbar).
-- ============================================================

if reframework:get_game_name() ~= "re4" then return end

-- Leon = ch0a0z0_body, Ashley = ch0a1z0_body. Beide Player-Bodies zulassen; der AKTUELL gesteuerte
-- wird per CharacterManager gewaehlt (unten). Diskriminator = Body-Name.
local PLAYER_BODY_NAMES = {
    ["ch0a0z0_body"] = true,   -- Leon
    ["ch0a1z0_body"] = true,   -- Ashley
    ["ch3a8z0_body"] = true,   -- Ada (Separate Ways) [2026-07-19]
}

-- [ADA_NPC_SCHUTZ 2026-07-19] Ada kommt AUCH in Leons Kampagne vor -- dort ist sie NPC und
-- muss Kopf/Haare ANBEHALTEN. Der Primaerpfad oben ist dagegen sicher: er fragt den CharacterManager
-- nach dem GESTEUERTEN Body, NPC-Ada kann da nie rauskommen.
-- Der Fallback dagegen sucht die Szene stumpf nach Namen ab -- und der GO heisst bei NPC-Ada GENAUSO
-- (ch3a8z0_body). Waere sie hier gelistet, wuerde ein Aussetzer des Primaerpfads (Uebergaenge,
-- Reparenting) mitten in Leons Kampagne NPC-Ada den Kopf wegblenden.
-- Darum: Ada NUR im Primaerpfad, NIE im Fallback. Leon/Ashley bleiben unkritisch -- von denen gibt
-- es keine zweite Instanz, die faelschlich getroffen werden koennte.
local FALLBACK_BODY_NAMES = {
    ["ch0a0z0_body"] = true,   -- Leon
    ["ch0a1z0_body"] = true,   -- Ashley
}

-- Leon Head/Hair-Materialien (ch0a0z0_body).
local HIDE_MATERIALS_LEON = {
    -- Head
    EyeAO_mat          = true,
    EyeOut_mat         = true,
    Face_mat           = true,
    EyeWet_mat         = true,
    BrowsEyeLashes_mat = true,
    Eye_inside_mat     = true,
    Mouth_mat          = true,
    -- Hair
    Hair00_Mat = true,
    Hair01_Mat = true,
    -- [PINSTRIPE-HUT 2026-08-04] Leons Hut aus dem Nadelstreifen-Kostuem. Er liegt NICHT in einem
    -- eigenen GO, sondern als Submaterial im grossen 'body'-Mesh -> geht nur per-Material weg (der
    -- gemischte Pfad unten macht genau das). Materialnamen live am Mercs-Body gedumpt (2026-08-02) und
    -- dort identisch; andere Kostueme haben diese Materialien gar nicht, der Eintrag stoert also nie.
    Hat00_Mat = true,
    Hat01_Mat = true,
    -- [PINSTRIPE-HAAR 2026-08-05] Das Kostuem bringt eigene Haar-Materialien mit
    -- (Hinterkopf), die NICHT Hair00/01 heissen -- ohne die blieb das Haar in der Kampagne stehen.
    pl0074_Hair_Mat  = true,
    pl0074_Hair2_Mat = true,
}

-- Ashley Head/Hair-Materialien (ch0a1z0_body, Live-Dump 2026-07-11). Eigene Liste -> generische Namen
-- (z.B. Ao_mat) treffen NICHT versehentlich Leon. Ashley hat eigene "head"- und "hair"-Mesh-GOs.
local HIDE_MATERIALS_ASHLEY = {
    -- Head (GO "head")
    Eye_out_mat = true,
    Face_mat    = true,
    Mouth_mat   = true,
    Ao_mat      = true,
    EyeLash_mat = true,
    Eye_in_mat  = true,
    Eyebrows_mat = true,
    Eyewet_mat  = true,
    -- Hair (GO "hair")
    Hair_A_Mat = true,
    Hair_B_Mat = true,
    Hair_C_Mat = true,
}

-- Ada Head/Hair-Materialien (ch3a8z0_body). Namen aus der alten Mod uebernommen
-- (developer RE4/reframework/autorun/re4_vr_materials.lua, ada.mat_hidden) -- dort war die Liste
-- allerdings die VOLLE Koerper-Liste (Boots/Holster/Leg/...); hier stehen bewusst NUR Head+Hair,
-- weil das die Gameplay-Regel ist. Achtung: `Ao_mat`/`Face_mat`/`Mouth_mat` heissen bei Ashley
-- genauso -- deshalb hat jeder Charakter seine EIGENE Liste und wir schalten sie um, statt eine
-- gemeinsame zu benutzen (sonst wuerde ein generischer Name den Falschen treffen).
local HIDE_MATERIALS_ADA = {
    -- Head
    Ao_mat          = true,
    Blow_mat        = true,
    EyeLash_mat     = true,
    Eye_in_mat      = true,
    Eye_out_mat     = true,
    Eyewet_mat      = true,
    Face_mat        = true,
    Mouth_mat       = true,
    Lens_Inside_mat = true,
    -- Hair
    Hair00_mat = true,   -- ACHTUNG kleines "mat": Leon hat Hair00_Mat (gross), Ada Hair00_mat
    Hair01_mat = true,
    Hair02_mat = true,
}

-- Aktive Head/Hair-Liste. Wird pro Frame nach dem gesteuerten Body umgeschaltet (Leon/Ashley/Ada).
local HIDE_MATERIALS_BY_BODY = {
    ["ch0a0z0_body"] = HIDE_MATERIALS_LEON,
    ["ch0a1z0_body"] = HIDE_MATERIALS_ASHLEY,
    ["ch3a8z0_body"] = HIDE_MATERIALS_ADA,
}
local HIDE_MATERIALS = HIDE_MATERIALS_LEON

-- [FP_ONLY] In Killswitch 2 (First-Person bleibt) den GANZEN sichtbaren Koerper ausblenden
-- (sonst klippt die native 3rd-Person-Animation in die Ego-Kamera). Diese GOs unter Leon
-- (ch0a0z0_body/children) komplett aus = ALLE Materialien disabled, solange fp_only aktiv.
-- Ausserhalb fp_only wieder an (bzw. Kopf/Haar folgen weiter der normalen Regel).
-- =====================================================================
-- [EXTRA_MATS 2026-08-05] Materialien, die im Voll-Aus NICHT auf DrawDefault hoeren
-- =====================================================================
-- Die Jacke (GO 'jacket', Jacket_Mat/JacketFur_Mat) blieb im KS3 stehen, obwohl DrawDefault am
-- Mesh false war. Im EMV verschwindet sie ueber das Material-Haekchen -- und EMV findet seine
-- Meshes ueber die SZENE, nicht ueber den Transform-Baum:
-- scene:call("findComponents(System.Type)", sdk.typeof("via.render.Mesh")) (init.lua ~10949)
-- mesh:call("setMaterialsEnable", id, on) (init.lua ~7335)
-- In Mercenaries hat exakt dieser Weg funktioniert (re4_vr_merc.lua), hier derselbe Nachbau fuer
-- Kampagne + Separate Ways ("Jacken-Leon" gibt es auch dort).
-- Neues Kostuemteil, das im Stagger stehen bleibt -> Materialnamen hier eintragen.
local FULLHIDE_EXTRA_MATS = {
    ["JacketFur_Mat"] = true,   -- Leon, Jacken-Kostuem (Fell am Kragen)
    ["Jacket_Mat"]    = true,   -- Leon, Jacke
    ["Boa_Mat"]       = true,   -- Krauser, Fellkragen -- dieselbe Liste gilt in beiden Scripten
}
local extra_mats, extra_mats_off, extra_scan_t = nil, false, 0

-- =====================================================================
-- [FUR 2026-08-15] Das Fell am Kragen ist KEIN Material auf einem Mesh
-- =====================================================================
-- Live in der TDB nachgesehen: das Fell haengt an einer eigenen Renderkomponente,
-- `via.render.Fur` bzw. `via.render.ShellFurMesh` -- beide erben von `via.render.RenderEntity`,
-- NICHT von `via.render.Mesh`. Damit greift keiner unserer beiden bisherigen Wege:
-- `findComponents(via.render.Mesh)` liefert sie nicht, `getComponent(via.render.Mesh)` im
-- Walk auch nicht, und `setMaterialsEnable` gibt es auf ihr gar nicht. Genau deshalb gingen
-- alle anderen Meshes brav aus und nur das Fell blieb stehen.
-- Anfassbar ist sie ueber RenderEntity: set_DrawDefault / set_DrawShadowCast -- dieselben
-- Setter wie bei den Meshes, also auch dieselbe Regel: unsichtbar, Schatten bleibt.
-- BEWUSST NICHT szenenweit gesammelt: `via.render.Fur` haengt auch an Gegnern (Fell/Haare) --
-- ein Scene-Scan wuerde im Damage-Moment fremde Felle mit ausblenden. Wir nehmen ausschliesslich
-- die Komponenten AM GEFUNDENEN JACKEN-MESH (dessen GO, dessen Eltern-GO, dessen direkte Kinder);
-- gefunden wird das Mesh weiterhin ueber die Materialnamen in FULLHIDE_EXTRA_MATS.
-- [NIL-TYPE-GUARD] Fehlt einer der Typen, bleibt er nil und wird unten uebersprungen -- ein
-- getComponent(nil) wirft eine Game-Exception und flutet das Log (bekannte Falle).
local T_FUR      = sdk.typeof("via.render.Fur")
local T_SHELLFUR = sdk.typeof("via.render.ShellFurMesh")
local extra_furs = nil

-- [2026-08-09] Sind die gemerkten Meshes ueberhaupt noch am Leben? Nach Save-Load,
-- Stage- oder Kostuemwechsel zeigt der Cache auf Leichen -- und `setMaterialsEnable` WIRFT
-- dabei nicht, es verpufft nur. Genau daran blieb das Fell am Kragen stehen: einmal
-- gefunden, nie wieder gesucht (bekannte Falle).
-- Der Test ist billig (ein Getter je Eintrag) und braucht keinen Szenen-Scan: liefert das
-- Mesh an derselben Stelle nicht mehr denselben Materialnamen, ist der Cache Muell.
local function extra_mats_alive()
    if not extra_mats then return false end
    for _, e in ipairs(extra_mats) do
        local ok, mn = pcall(function() return e.mesh:call("getMaterialName", e.idx) end)
        if not ok or mn ~= e.name then return false end
        -- [LEICHENTEST 2026-08-18 -- gemessen im Watcher-Log] Der Materialname allein reicht NICHT:
        -- nach einem Neuaufbau des Charakters (neue Mercs-Runde, Respawn, Kostuem/Stage) lieferte
        -- das tote Mesh weiter denselben Namen und `get_DrawDefault()` weiter true/false -- der
        -- Cache galt als gesund, waehrend sein GameObject schon weg war (Log 12:28:27.974:
        -- `fur1[? draw=true]`, 0,2 s nach `fur1[jacket<ch6i0z0_body draw=true]`). Beim naechsten
        -- Voll-Aus schalteten wir dann Geister ab, und das Fell des NEUEN Koerpers blieb sichtbar.
        -- Das GameObject ist der einzige der drei Werte, der den Tod nicht ueberlebt.
        local go_ok = false
        pcall(function() go_ok = e.mesh:call("get_GameObject") ~= nil end)
        if not go_ok then return false end
    end
    -- [FUR] Die Fur-Komponenten haben keinen Materialnamen zum Vergleichen -- ein Getter
    -- reicht als Lebendtest, er schlaegt an einer Leiche fehl.
    if extra_furs then
        for _, f in ipairs(extra_furs) do
            local ok = pcall(function() return f:call("get_DrawDefault") end)
            if not ok then return false end
            -- s. oben: `get_DrawDefault` antwortet auch an einer Leiche, das GameObject nicht.
            local fgo_ok = false
            pcall(function() fgo_ok = f:call("get_GameObject") ~= nil end)
            if not fgo_ok then return false end
        end
    end
    return true
end

local function scan_extra_mats()
    -- Cache verwerfen, sobald er nicht mehr traegt -- danach faellt der Block unten
    -- automatisch in den normalen Suchlauf.
    if extra_mats and not extra_mats_alive() then
        -- Zeitsperre mit zuruecksetzen: sonst stuende das Fell bis zu 5 s sichtbar da,
        -- weil der Szenen-Scan unten noch in der Drosselung des letzten Laufs haengt.
        extra_mats, extra_mats_off, extra_scan_t = nil, false, 0
        extra_furs = nil
    end
    if extra_mats then return end
    if (os.clock() - extra_scan_t) < 5.0 then return end   -- Szenen-Scan ist teuer -> gedrosselt
    extra_scan_t = os.clock()
    -- eigener pcall-Helfer: das globale `safe` dieser Datei entsteht erst weiter UNTEN (Zeile ~186),
    -- hier oben waere es nil -> "global 'safe' is not callable" (Fehler vom 2026-08-06).
    local function s(fn) local ok, r = pcall(fn); if ok then return r end return nil end
    local sm = sdk.get_native_singleton("via.SceneManager")
    local td = sdk.find_type_definition("via.SceneManager")
    local scene = (sm and td) and s(function() return sdk.call_native_func(sm, td, "get_CurrentScene") end) or nil
    if not scene then return end
    local arr = s(function()
        return scene:call("findComponents(System.Type)", sdk.typeof("via.render.Mesh"))
    end)
    local list = arr and s(function() return arr:get_elements() end) or nil
    if not list then return end
    local found = {}
    for _, mesh in ipairs(list) do
        local n = s(function() return mesh:call("get_MaterialNum") end) or 0
        for i = 0, n - 1 do
            local mn = s(function() return mesh:call("getMaterialName", i) end)
            if type(mn) == "string" and FULLHIDE_EXTRA_MATS[mn] then
                found[#found + 1] = { mesh = mesh, idx = i, name = mn }
            end
        end
    end
    if #found > 0 then extra_mats = found end

    -- [FUR 2026-08-15] Zu jedem gefundenen Jacken-Mesh die Fur-Komponenten einsammeln.
    -- Gesucht wird nur lokal: am GO des Meshes, an dessen Eltern-GO und an dessen direkten
    -- Kindern -- damit kann kein fremdes Fell (Gegner) hineinrutschen, egal wie die Szene aussieht.
    -- Doppelte Eintraege sind unkritisch: set_DrawDefault zweimal zu setzen kostet nichts.
    if extra_mats and not extra_furs then
        local furs = {}
        local function take(go)
            if not go then return end
            for _, t in ipairs({ T_FUR, T_SHELLFUR }) do
                if t then
                    local c = s(function() return go:call("getComponent(System.Type)", t) end)
                    if c then furs[#furs + 1] = c end
                end
            end
        end
        for _, e in ipairs(extra_mats) do
            local go = s(function() return e.mesh:call("get_GameObject") end)
            if go then
                take(go)
                local tf = s(function() return go:call("get_Transform") end)
                if tf then
                    local par = s(function() return tf:call("get_Parent") end)
                    take(par and s(function() return par:call("get_GameObject") end))
                    local ch = s(function() return tf:call("get_Child") end)
                    while ch do
                        take(s(function() return ch:call("get_GameObject") end))
                        ch = s(function() return ch:call("get_Next") end)
                    end
                end
            end
        end
        if #furs > 0 then extra_furs = furs end
    end
end

-- [2026-08-09] Im AUS-Zustand wird jeden Tick nachgedrueckt, nicht nur auf der
-- Flanke: baut die Engine das Mesh neu auf (neue Runde, Kostuemwechsel), waehrend unser
-- Flag noch "aus" sagt, wuerde nie wieder geschrieben -- das Fell waere sichtbar und wir
-- haetten uns fuer fertig gehalten. Beim Wiedereinschalten reicht die Flanke.
local function apply_extra_mats(off)
    if not extra_mats and not extra_furs then return end
    if not off and off == extra_mats_off then return end
    -- [FUR 2026-08-15] Gleiche Regel wie bei den Meshes ([SHADOW BODY]): nur den Farb-Pass
    -- abschalten, Schattenwurf anlassen. Steht VOR der Material-Schleife, weil die bei einem
    -- toten Mesh mit return aussteigt -- sonst bliebe das Fell in genau dem Fall stehen.
    if extra_furs then
        for _, f in ipairs(extra_furs) do
            pcall(function() f:call("set_DrawDefault", not off) end)
            pcall(function() f:call("set_DrawShadowCast", true) end)
        end
    end
    if not extra_mats then extra_mats_off = off; return end
    for _, e in ipairs(extra_mats) do
        -- [2026-08-10] BEIDE Aufrufformen, genau wie die alte Mod (developer RE4,
        -- re4_vr_materials.lua:377): die kurze Form kann bei ueberladenen Methoden die
        -- falsche Ueberladung treffen und dann lautlos nichts tun. Die signierte Variante
        -- ist die verbindliche; sie steht bewusst DANACH, damit sie das letzte Wort hat.
        local ok = pcall(function() e.mesh:call("setMaterialsEnable", e.idx, not off) end)
        pcall(function() e.mesh:call("setMaterialsEnable(System.Int32,System.Boolean)", e.idx, not off) end)
        if not ok then extra_mats, extra_mats_off, extra_furs = nil, false, nil; return end   -- Mesh tot -> neu suchen
    end
    extra_mats_off = off
    -- [FUR-DIAG 2026-08-18] NUR Export, kein Verhalten: der Wegwerf-Logger braucht genau die
    -- Objekte, die WIR gefunden haben -- sonst muesste er die Szene selbst scannen und wuerde
    -- moeglicherweise andere erwischen. Damit laesst sich pro Engine-Pass nachsehen, wer das
    -- Fell wieder anschaltet.
    _G.__re4_fur_dbg = { mats = extra_mats, furs = extra_furs, off = extra_mats_off, quelle = "kampagne" }
end

local FULLHIDE_GO_NAMES = {
    ["body"]       = true,   -- Leon + Ashley (beide haben ein "body"-Mesh)
    ["body_armor"] = true,   -- Leon
    ["headhair"]   = true,   -- Leon (kombiniertes Head/Hair-Mesh)
    ["cloth"]      = true,   -- Ashley (Jacke/Pants_Front) -- lief in KS3 sonst sichtbar weiter
    -- [ADA 2026-07-20] Ada (ch3a8z0_body) heisst voellig anders -> in KS2/KS3 blieb ihr Koerper
    -- sichtbar (z.B. im Damage-KS3, per Monitordump belegt). Namen aus dem Live-Mesh-Dump ihres Bodys.
    -- EINE gemeinsame Liste ist unkritisch (Entscheidung): Leon und Ada sind nie gleichzeitig der
    -- gesteuerte Charakter, und die Liste wird ausschliesslich auf den GESTEUERTEN Body angewendet.
    ["cha200_00"]     = true,   -- Ada Koerper (Boots/Glove/Holster/Leg/Skin...)
    ["cha200_10"]     = true,   -- Ada Kopf
    ["cha200_20"]     = true,   -- Ada Haare
    ["sm61_342_00"]   = true,   -- Ada Ausruestungsteil am Koerper
    ["HookShot_Rope"] = true,   -- Ada Greifhaken: Seil
    ["HookShot_Gun"]  = true,   -- Ada Greifhaken: Geraet
}


local scene_td = sdk.find_type_definition("via.SceneManager")
local T_MESH   = sdk.typeof("via.render.Mesh")
local T_SKIN   = sdk.typeof("via.render.SkinnedMesh")
local T_OILLAMP = sdk.typeof("chainsaw.OilLampController")   -- [ASHLEY_LAMP] Hand-Lampe (ac0300_00)


local function safe(fn)
    local ok, val = pcall(fn)
    if ok then return val end
    return nil
end


local function call0(o, m)
    if not o then return nil end
    return safe(function() return o:call(m) end)
end

local function call1(o, m, a)
    if not o then return nil end
    return safe(function() return o:call(m, a) end)
end

local function call2(o, m, a, b)
    if not o then return nil end
    return safe(function() return o:call(m, a, b) end)
end


-- Zentraler VR-Killswitch (re4vr). Faellt auf No-op zurueck, falls Modul fehlt.
local ok_ks, killswitch = pcall(function() return require("re4vr/re4_vr_killswitch") end)
if not ok_ks or not killswitch then killswitch = { is_active = function() return false end } end

-- Zielzustand fuer die Head/Hair-Materialien: false = verstecken (First-Person-Gameplay),
-- true = zeigen. In Cutscenes (killswitch aktiv) zeigen, sonst verstecken.
local mat_set_enable = false
-- [FP_ONLY] true = Killswitch 2 aktiv -> ganze FULLHIDE-GOs ausblenden.
local fp_only_now = false
-- [SCOPE_BODY_HIDE] true = Zielen durch montiertes Scope. Body/Head-Hair AUS wie fp_only,
-- ABER Waffen bleiben sichtbar (Scope-Glas/RTT haengt am Waffen-Mesh, darf nicht weg).
local scope_body_hide = false
-- [KS4_HOLSTER 2026-08-06] true = KS4 -> NUR die Holster-Klone ausblenden. In KS4 bleibt der
-- Body bewusst sichtbar (nur Kopf/Haare aus), aber die geholsterten Waffen stoeren dort aus der Naehe.
-- Bewusst getrennt von fp_only_now: KS3/KS5 blenden ohnehin den ganzen Baum aus, inkl. der Klone.
local holster_hide_now = false


local function get_scene()
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm or not scene_td then return nil end
    return safe(function()
        return sdk.call_native_func(sm, scene_td, "get_CurrentScene")
    end)
end


local function get_body_go()
    -- Primaer: CharacterManager -> der AKTUELL gesteuerte Body (Leon ODER Ashley), auch wenn reparented.
    -- Wichtig falls beide gleichzeitig in der Szene sind (Escort): so treffen wir den PLAYER, nicht den NPC.
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
    if cm then
        local ctx = call0(cm, "getPlayerContextRef")
        local body = ctx and call0(ctx, "get_BodyGameObject")
        local name = body and call0(body, "get_Name")
        if type(name) == "string" and PLAYER_BODY_NAMES[name] then return body end
    end

    -- Fallback: Szene nach bekannten Player-Body-Namen absuchen.
    local scene = get_scene()
    if scene then
        for nm in pairs(FALLBACK_BODY_NAMES) do   -- [ADA_NPC_SCHUTZ] bewusst OHNE Ada, s. oben
            local go = call1(scene, "findGameObject(System.String)", nm)
            if go then
                local valid = false
                pcall(function() valid = go:get_Valid() end)
                if valid then return go end
            end
        end
    end
    return nil
end


local function set_mat(renderer, mi, enable)
    call2(renderer, "setMaterialsEnable", mi, enable)
    pcall(function()
        renderer:call("setMaterialsEnable(System.Int32,System.Boolean)", mi, enable)
    end)
end

-- [SHADOW] Mesh-weiter Farb-/Schatten-Pass. draw_color=false -> unsichtbar im Bild,
-- shadow=true -> wirft trotzdem Schatten. shadow=nil -> nicht anfassen.
local function set_mesh_draw(renderer, draw_color, shadow)
    pcall(function() renderer:call("set_DrawDefault", draw_color) end)
    if shadow ~= nil then pcall(function() renderer:call("set_DrawShadowCast", shadow) end) end
end

-- [SHADOW] true = dieses Mesh besteht AUSSCHLIESSLICH aus head/hair-Materialien
-- (z.B. das separate headhair-Mesh). Dann koennen wir es mesh-weit unsichtbar machen
-- und trotzdem Schatten werfen lassen. Gemischte Meshes (Body MIT Gesicht-Submesh)
-- liefern false -> dort geht nur per-Material (Schatten dann unvermeidbar weg).
local function renderer_is_hh_only(renderer, mcount)
    if type(mcount) ~= "number" or mcount < 1 then return false end
    for mi = 0, mcount - 1 do
        local name = call1(renderer, "getMaterialName", mi)
        if not (type(name) == "string" and HIDE_MATERIALS[name]) then return false end
    end
    return true
end

-- fullhide_go = dieser GO gehoert zu FULLHIDE_GO_NAMES (body/body_armor/headhair).
local function hide_mats_on(renderer, fullhide_go)
    if not renderer then return end
    local mcount = call0(renderer, "get_MaterialNum")
    if type(mcount) ~= "number" then return end

    -- [SHADOW] Reines head/hair-Mesh -> Materialien AN lassen, statt dessen mesh-weit
    -- den Farb-Pass schalten + Schatten anlassen. Unsichtbar im Bild, wirft Schatten.
    if renderer_is_hh_only(renderer, mcount) then
        for mi = 0, mcount - 1 do set_mat(renderer, mi, true) end   -- Geometrie fuer Schatten
        if fp_only_now or scope_body_hide then
            set_mesh_draw(renderer, false, true)        -- fp_only/scope: aus, Schatten darf bleiben
        else
            -- Gameplay (mat_set_enable=false): unsichtbar + Schatten an
            -- Cutscene (mat_set_enable=true): normal sichtbar
            set_mesh_draw(renderer, mat_set_enable, true)
        end
        return
    end

    -- [SHADOW BODY 2026-07-11] Gemischtes Body-Mesh, aber der GANZE GO soll weg (KS3/fp_only/Scope):
    -- mesh-weit unsichtbar ABER Schatten AN -- statt per-Material (setMaterialsEnable(false) nahm den
    -- Schatten mit -> "unvermeidbar" war es NICHT). Materialien AN lassen (Geometrie fuer den Schatten) +
    -- set_DrawDefault(false) + set_DrawShadowCast(true) -> Body verschwindet im Bild, wirft weiter Schatten
    -- (genau wie das Kopf/Haar-Mesh oben). Nur wenn der ganze GO weg soll -> KS2/KS4-Teilhide unberuehrt.
    if fullhide_go and (fp_only_now or scope_body_hide) then
        -- [EXTRA_MATS IM WALK 2026-08-06, "sorge dafuer dass im KS3 die Materials ausgehen"]
        -- Materialien aus FULLHIDE_EXTRA_MATS hoeren NICHT auf DrawDefault (Befund 05.08.: das GO
        -- 'jacket' blieb im KS3 stehen, obwohl DrawDefault=false stand -- per Dump 06.08. bestaetigt:
        -- MESH jacket / Jacket_Mat#0 / JacketFur_Mat#1, DrawDefault=true Enabled=true).
        -- Die Zeile darunter setzte sie zusaetzlich JEDEN Frame wieder auf true (Geometrie fuer den
        -- Schatten) -- damit hat sie den Szenen-Weg (apply_extra_mats, der nur auf der FLANKE schaltet)
        -- in jedem Frame ueberstimmt. Deshalb hier: genau diese Materialien AUS, der Rest bleibt an.
        -- Kosten: ein getMaterialName pro Material, nur im Voll-Ausblenden (KS3/KS5/Scope).
        for mi = 0, mcount - 1 do
            local nm_x = call1(renderer, "getMaterialName", mi)
            local extra = (type(nm_x) == "string" and FULLHIDE_EXTRA_MATS[nm_x]) == true
            set_mat(renderer, mi, not extra)
        end
        set_mesh_draw(renderer, false, true)                        -- unsichtbar, Schatten AN
        return
    end

    -- Gemischtes Mesh: Farb-Pass normal an lassen, head/hair per-Material schalten (wie bisher).
    set_mesh_draw(renderer, true, nil)
    for mi = 0, mcount - 1 do
        local name = call1(renderer, "getMaterialName", mi)
        local is_hh = (type(name) == "string" and HIDE_MATERIALS[name]) == true
        -- [EXTRA_MATS IM WALK 2026-08-06] Gegenstueck zum Block oben: ausserhalb des Voll-Ausblendens
        -- gehoeren diese Materialien IMMER sichtbar. Ohne das bliebe die Jacke nach dem KS3-Austritt weg,
        -- weil der Zweig oben sie ausgeschaltet hat und dieser Pfad sie sonst nie wieder anfasst
        -- ('jacket' steht nicht in FULLHIDE_GO_NAMES). Macht uns unabhaengig davon, ob der Szenen-Weg
        -- (apply_extra_mats) gerade einen gueltigen Cache hat.
        if (type(name) == "string" and FULLHIDE_EXTRA_MATS[name]) == true then
            set_mat(renderer, mi, true)
        elseif fullhide_go then
            -- Ganzen GO managen: fp_only -> ALLES aus; sonst Kopf/Haar-Regel, Rest sichtbar.
            local enable
            if fp_only_now or scope_body_hide then enable = false
            elseif is_hh then enable = mat_set_enable
            else enable = true end
            set_mat(renderer, mi, enable)
        elseif is_hh then
            -- Nicht-FULLHIDE-GO: nur Kopf/Haar-Materialien nach normaler Regel.
            set_mat(renderer, mi, mat_set_enable)
        end
    end
end


-- [WEAPON_HIDE] Jede getragene Waffe haengt als Child unter ch0a0z0_body mit Namen
-- "wp####" (per chartree-Dump verifiziert: wp4201 equippt + wp6000/6001/5001/... geholstert).
-- Kein hardcoded ID-Liste noetig -> Namensmuster erwischt dynamisch genau das aktuelle
-- Inventar. In KS3 (fp_only) sollen ALLE Waffen + ihre Sub-Meshes (LaserSight/ShellGenerator/
-- ThrowSight...) weg, sonst klippt die equippte Waffe in die Ego-Kamera.
local function is_weapon_name(nm)
    return type(nm) == "string" and nm:match("^wp%d") ~= nil
end

-- in_weapon = dieser GO ist ein Waffen-Root ODER liegt im Subtree einer Waffe.
local function process_go(go, in_weapon)
    if not go then return end
    local nm = call0(go, "get_Name")
    -- [NIL-TYPE-GUARD] getComponent NIE mit nil-Type aufrufen: das wirft eine interne
    -- Game-ArgumentNullException, die REFramework JEDES Mal auf Disk loggt (ScriptRunner_LogToDisk).
    -- Dieser walk laeuft jeden Frame ueber den ganzen Body-Baum -> bei nil-Type = massiver Log-Flood
    -- (hunderte/Frame), der den Script-Thread + die managed Web-API (Live-Abfrage) abwuergt. T_SKIN
    -- (via.render.SkinnedMesh) existiert in RE4 nicht -> war nil -> Flood. via.render.Mesh deckt
    -- geskinnte Meshes ohnehin ab.
    local mesh = T_MESH and call1(go, "getComponent(System.Type)", T_MESH)
    local skin = T_SKIN and call1(go, "getComponent(System.Type)", T_SKIN)

    -- [KS4_HOLSTER 2026-08-06] Die Holster-Klone (eigene GOs "vr_holster_*", per set_Parent im
    -- Body-Baum -- live verifiziert) in KS4 aus dem Farb-Pass nehmen. Schatten ist bei ihnen ohnehin aus
    -- (holster.lua spawnt sie mit DrawShadowCast=false). Ausserhalb von KS4 fasst dieser Zweig nichts an;
    -- sichtbar macht sie wie bisher der normale Pfad weiter unten (set_mesh_draw(renderer, true, nil)).
    if holster_hide_now and type(nm) == "string" and nm:sub(1, 11) == "vr_holster_" then
        if mesh then pcall(function() mesh:call("set_DrawDefault", false) end) end
        if skin then pcall(function() skin:call("set_DrawDefault", false) end) end
        return
    end

    if in_weapon then
        -- [WEAPON_HIDE] NUR den Renderer-DrawDefault toggeln (nicht GO-DrawSelf), damit die
        -- Holster/Equip-Logik der Engine unberuehrt bleibt. KS3 -> aus; sonst -> an (dann
        -- entscheidet weiter das GO-DrawSelf: equippt sichtbar, geholstert unsichtbar).
        -- [SCHATTEN BLEIBT 2026-07-20] Auch Waffen verschwinden im Voll-Ausblenden nur aus dem
        -- Farb-Pass; ihr Schattenwurf bleibt an (DrawShadowCast=true ist ohnehin ihr Normalzustand).
        local want = not fp_only_now
        if mesh then pcall(function() mesh:call("set_DrawDefault", want) end); pcall(function() mesh:call("set_DrawShadowCast", true) end) end
        if skin then pcall(function() skin:call("set_DrawDefault", want) end); pcall(function() skin:call("set_DrawShadowCast", true) end) end
        return   -- Waffen NICHT durch die Head/Hair-Material-Logik schicken
    end

    -- [KOSTUEMFEST 2026-07-20] Im Voll-Ausblenden (fp_only/Scope) gilt JEDES Mesh unter dem
    -- gesteuerten Body als fullhide -- unabhaengig vom GO-Namen. Die Namensliste war kostuemabhaengig
    -- (anderes Outfit = andere Mesh-GOs) und kannte nur Leon/Ashley/Ada-Standard. Ausgeblendet wird
    -- weiterhin ueber DrawDefault=false + DrawShadowCast=true -> unsichtbar, SCHATTEN BLEIBT.
    -- Ausserhalb des Voll-Ausblendens bleibt alles wie gehabt (nur Kopf/Haar nach Materialliste),
    -- damit im normalen Gameplay nichts anders aussieht als bisher.
    local fullhide_go = fp_only_now or scope_body_hide
        or ((type(nm) == "string" and FULLHIDE_GO_NAMES[nm:lower()]) == true)
    if mesh then hide_mats_on(mesh, fullhide_go) end
    if skin then hide_mats_on(skin, fullhide_go) end
end


local function walk(tf, in_weapon)
    if not tf then return end

    local go = call0(tf, "get_GameObject")
    local here_weapon = in_weapon
    if not here_weapon then
        here_weapon = is_weapon_name(go and call0(go, "get_Name"))
    end
    if go then process_go(go, here_weapon) end

    local child = call0(tf, "get_Child")
    while child do
        walk(child, here_weapon)
        child = call0(child, "get_Next")
    end
end

-- ========== 分片遍历状态（持久跨帧） ==========
local walk_state = {
    active = false,         -- 是否正在分片遍历
    stack = {},             -- 迭代栈，保存待处理节点 {tf, weapon}
    max_per_frame = 12,     -- 每帧最多处理节点，调小=更平滑，调大=完成更快
    need_restart = false    -- 需要强制重新完整扫描标记
}

--- 启动一次全新的树遍历，重置状态
local function start_walk(root_tf)
    if not root_tf then
        walk_state.active = false
        walk_state.stack = {}
        return
    end
    walk_state.stack = {{tf = root_tf, weapon = false}}
    walk_state.active = true
    walk_state.need_restart = false
end

--- 每帧执行分片工作：消费栈中有限数量节点
local function walk_chunk()
    if not walk_state.active or #walk_state.stack == 0 then
        walk_state.active = false
        return
    end

    local processed = 0
    while #walk_state.stack > 0 and processed < walk_state.max_per_frame do
        processed = processed + 1

        local item = table.remove(walk_state.stack)
        local tf = item.tf
        local here_weapon = item.weapon

        local go = call0(tf, "get_GameObject")
        if not here_weapon then
            here_weapon = is_weapon_name(go and call0(go, "get_Name"))
        end
        if go then
            process_go(go, here_weapon)
        end

        -- 收集子节点，逆序压栈，保持原遍历顺序
        local temp = {}
        local child = call0(tf, "get_Child")
        while child do
            table.insert(temp, {tf = child, weapon = here_weapon})
            child = call0(child, "get_Next")
        end
        for i = #temp, 1, -1 do
            table.insert(walk_state.stack, temp[i])
        end
    end

    -- 栈空代表整棵树遍历完成
    if #walk_state.stack == 0 then
        walk_state.active = false
    end
end


-- Body-GO ueber Frames cachen (sonst Szenen-Suche pro Frame). Neu holen wenn ungueltig.
local cached_body = nil
local function get_body_go_cached()
    -- Jeden Frame den AKTUELL gesteuerten Body neu bestimmen (CharacterManager-primaer, guenstig) ->
    -- bei Charakterwechsel Leon<->Ashley folgt der Hide SOFORT dem gespielten Character, auch wenn BEIDE
    -- Bodies gueltig in der Szene sind (Escort). Sonst blieb der Cache am alten (NPC-)Body haengen und
    -- dessen Kopf/Haare fehlten statt der des Players.
    local fresh = get_body_go()
    if fresh then cached_body = fresh; return fresh end
    -- CharacterManager momentan nicht verfuegbar -> letzten gueltigen Body weiterverwenden.
    if cached_body then
        local valid = false
        pcall(function() valid = cached_body:get_Valid() end)
        if valid then return cached_body end
        cached_body = nil
    end
    return nil
end

-- [ASHLEY_LAMP] Ashleys Hand-Lampe = chainsaw.OilLampController (GO ac0300_00). In KS3 nur das ROOT-MESH
-- (Lampenkoerper) ausblenden -- die Licht-Kinder (light / light_shaft / Lensflare) NICHT anfassen, damit
-- Lichtkegel/Glow bleiben. GO ueber Frames cachen (findComponents nur wenn ungueltig).
local lamp_go_cache = nil
local lamp_hidden = false
local function get_lamp_go()
    if lamp_go_cache then
        local valid = false; pcall(function() valid = lamp_go_cache:get_Valid() end)
        if valid then return lamp_go_cache end
        lamp_go_cache = nil
    end
    local scene = get_scene()
    if not (scene and T_OILLAMP) then return nil end
    local comps = safe(function() return scene:call("findComponents(System.Type)", T_OILLAMP) end)
    local n = comps and (tonumber(safe(function() return comps:get_Length() end)) or 0) or 0
    if n > 0 then
        local c = comps[0]
        lamp_go_cache = c and safe(function() return c:call("get_GameObject") end)
    end
    return lamp_go_cache
end

-- [KS3_FLASHLIGHT ROBUST] Fallback wenn motions __re4_fl_mesh nicht gecacht ist (Event-Eintritt: motion war
-- nicht aktiv, hat die FL nie erfasst). Die Flashlight selbst finden = GO "ac0000_00" unter "ch0a0z0_body"
-- (1:1 wie motions fl_find). Nur das Root-Mesh (Lampenkoerper) wird spaeter ausgeblendet; das Kind "light"
-- (Kegel) bleibt unangetastet. GO ueber Frames cachen (get_Valid) -> kein Scene-Walk pro Frame.
local fl_go_cache = nil
local fl_mesh_hidden = false
local function get_flashlight_go()
    if fl_go_cache then
        local valid = false; pcall(function() valid = fl_go_cache:get_Valid() end)
        if valid then return fl_go_cache end
        fl_go_cache = nil
    end
    local scene = get_scene()
    if not scene then return nil end
    local body = safe(function() return scene:call("findGameObject(System.String)", "ch0a0z0_body") end)
    if not body then return nil end
    local btf = safe(function() return body:call("get_Transform") end)
    if not btf then return nil end
    local fltf = safe(function() return btf:find("ac0000_00") end)
    if not fltf or tostring(fltf) == "nil" then return nil end
    fl_go_cache = safe(function() return fltf:call("get_GameObject") end)
    return fl_go_cache
end

-- FRAME-BASIERT: laeuft jeden Frame (keine Zeit-Drossel mehr) -> Body-Hide reagiert sofort.
-- =====================================================================
-- [GONDELN AUSBLENDEN 2026-07-22] Stage 60850: die Kabinen glitchen sichtbar
-- hin und her. Das ist NICHT unsere Schuld -- der Killswitch steht dort auf KS4, alle
-- Scripte sind aus, es glitcht identisch weiter (vrmod-Kern-Kamera auf bewegter
-- Plattform). Da nicht behebbar: Meshes ausblenden.
-- Namen aus dem Live-Dump: gm81_303_00_0_PLGondola (die, auf der man steht) und
-- gm81_303_00_0_Gondola01..11 -> gemeinsames Praefix genuegt.
-- Quelle: chainsaw.GimmickManager._MoveArray (bewegliche Gimmicks; ueber dasselbe
-- Array findet der Killswitch den Aufzug in 59100) -> kein Scene-Walk ueber die Map.
-- NUR Stage 60850. Beim Verlassen/Abschalten wird exakt das zurueckgesetzt, was WIR
-- versteckt haben -> es kann nichts unsichtbar kleben bleiben.
-- =====================================================================
local GONDOLA_STAGE  = 60850
local GONDOLA_PREFIX = "gm81_303_00_0_"
-- [EIGENE GONDEL BLEIBT 2026-07-22] Die Kabine, auf der man STEHT, darf NICHT verschwinden --
-- sonst steht man sichtbar in der Luft (live bestaetigt). Sie heisst "PLGondola" (PL = Player) und ist
-- zugleich der Parent des Spielers. Ausgeschlossen wird sie ueber den Namen -- Praefix-Treffer ja,
-- aber dieser eine Name nicht.
local GONDOLA_KEEP   = "PLGondola"
local GONDOLA_CFG    = "re4_vr/re4_vr_materials.json"
local gondola_cfg    = { gondola_hide = true }
pcall(function()
    local d = json.load_file(GONDOLA_CFG)
    if type(d) == "table" and type(d.gondola_hide) == "boolean" then
        gondola_cfg.gondola_hide = d.gondola_hide
    end
end)
local function gondola_save() pcall(function() json.dump_file(GONDOLA_CFG, gondola_cfg) end) end

local gondola_hidden = {}     -- [mesh] = true: NUR von uns versteckte Meshes
local gondola_next_t = 0      -- Throttle (1x/s -- Kabinen koennen nachladen)

local function gondola_stage()
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager"); if not cm then return nil end
    local ctx = call0(cm, "getPlayerContextRef"); if not ctx then return nil end
    return tonumber(call0(ctx, "get_CurrentStageID"))
end

local function gondola_set_tree(tf, enable)
    if not tf then return end
    local go = call0(tf, "get_GameObject")
    local mesh = go and safe(function() return go:call("getComponent(System.Type)", T_MESH) end)
    if mesh then
        pcall(function() mesh:call("set_Enabled", enable) end)
        if enable then gondola_hidden[mesh] = nil else gondola_hidden[mesh] = true end
    end
    local child = call0(tf, "get_Child")
    while child do
        gondola_set_tree(child, enable)
        child = call0(child, "get_Next")
    end
end

local function gondola_unhide()
    for mesh in pairs(gondola_hidden) do pcall(function() mesh:call("set_Enabled", true) end) end
    gondola_hidden = {}
end

local function gondola_tick()
    local now = os.clock()
    if now < gondola_next_t then return end
    gondola_next_t = now + 1.0
    if gondola_stage() == GONDOLA_STAGE and gondola_cfg.gondola_hide then
        local gm  = sdk.get_managed_singleton("chainsaw.GimmickManager"); if not gm then return end
        local arr = safe(function() return gm:get_field("_MoveArray") end); if not arr then return end
        local n   = safe(function() return arr:get_size() end) or 0
        for i = 0, n - 1 do
            local core = safe(function() return arr:get_element(i) end)
            local go   = core and call0(core, "get_GameObject")
            local nm   = go and call0(go, "get_Name")
            if type(nm) == "string" and nm:find(GONDOLA_PREFIX, 1, true)
               and not nm:find(GONDOLA_KEEP, 1, true) then   -- eigene Kabine bleibt sichtbar
                gondola_set_tree(call0(go, "get_Transform"), false)
            end
        end
    elseif next(gondola_hidden) ~= nil then
        gondola_unhide()   -- Stage verlassen oder Schalter aus
    end
end

-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - Materials" raus (10 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

re.on_script_reset(function() pcall(gondola_unhide) end)

local refresh_timer = 0.0
local last_time = os.clock()
local FULL_REFRESH_INTERVAL = 2.5 -- 每2.5s强制一轮完整扫描兜底
re.on_frame(function()
    gondola_tick()   -- [GONDELN] Stage-gated, throttled (1x/s)
    local ks2, ks3, ks4, ks5 = false, false, false, false
    if type(killswitch.is_ks2) == "function" then local o, v = pcall(killswitch.is_ks2); if o then ks2 = (v == true) end end
    if type(killswitch.is_ks3) == "function" then local o, v = pcall(killswitch.is_ks3); if o then ks3 = (v == true) end end
    if type(killswitch.is_ks4) == "function" then local o, v = pcall(killswitch.is_ks4); if o then ks4 = (v == true) end end
    if type(killswitch.is_ks5) == "function" then local o, v = pcall(killswitch.is_ks5); if o then ks5 = (v == true) end end

    -- Body + Character FRUEH bestimmen: fuer die Ashley-spezifische KS2-Regel (unten) und die Material-Liste.
    local body = get_body_go_cached()
    local is_ashley = false
    if body then
        local bname = call0(body, "get_Name")
        is_ashley = (bname == "ch0a1z0_body")
        -- [ADA 2026-07-19] 3-Wege statt Ashley-Ternaer. Unbekannter Body -> Leon-Liste wie bisher.
        HIDE_MATERIALS = HIDE_MATERIALS_BY_BODY[bname] or HIDE_MATERIALS_LEON
    end

    -- [KS3]+[KS5] gesamtes Mesh aus (FULLHIDE-GOs). [KS2]+[KS4] nur Head/Hair aus = exakt die Gameplay-
    -- Regel (hh-only-Mesh unsichtbar ABER Schatten an -> Kopf-Schatten bleibt erhalten).
    fp_only_now = ks3 or ks5
    holster_hide_now = ks4   -- [KS4_HOLSTER 2026-08-06] nur die Holster-Klone, Body bleibt
    -- [THROWSIGHT] Del-Lago-Harpunen-Stage: gesamtes Leon-Mesh aus (wie KS3), obwohl der
    -- Killswitch fuer die Kamera bewusst inaktiv bleibt (First-Person laeuft als Gameplay).
    if rawget(_G, "__re4_throwsight_active") == true then fp_only_now = true end
    -- [STAGE_FULLHIDE 55300] Loren-FAHRT in Stage 55300: gesamtes Leon-Mesh + Waffe aus (wie KS3/fp_only),
    -- OHNE Killswitch/Scripte anzufassen -> Zielen/Cart-Gun laufen normal weiter (analog throwsight-Override).
    -- NUR waehrend KS4 (die Fahrt): die Cutscene in derselben Stage 55300 ist KS1 (voll) -> ks4=false ->
    -- Override feuert NICHT -> KS1 zeigt Leon komplett (genau so gewollt). Danach neue Stage -> ohnehin normal.
    -- [2026-07-14 railcar-Gate] ZUSAETZLICH auf railcar_mode gegatet: eine LEITER in Stage 55300 ist AUCH
    -- KS4 -> ohne diese Bedingung blendete der Override den Body die ganze Leiter hoch aus (Bug "kein mesh
    -- beim Leiter-Hochgehen"). railcar_mode ist NUR waehrend der echten Loren-Fahrt true -> Leiter bleibt sichtbar.
    if ks4 and rawget(_G, "__re4_railcar_mode") == true and type(killswitch.get_stage_name) == "function" then
        local o, st = pcall(killswitch.get_stage_name)
        if o and tonumber(st) == 55300 then fp_only_now = true end
    end
    -- [STAGE_FULLHIDE 60880 -- DURCHQUETSCHEN 2026-07-22] Quetschstelle bei Ada (Monitordump
    -- 14:54:34: GimmickMotionCameraController + Occupied CH_JACKED_GMK_HIGH, KS4 via "ks3_gimmick").
    -- Gesamtes Mesh aus, exakt wie bei 55300 -- ohne Killswitch/Scripte anzufassen.
    -- Gates, alle drei noetig: ks4 (nur waehrend des Events) + __re4_in_squeeze (setzt der killswitch
    -- NUR im Durchquetschen -> eine Leiter oder ein anderes KS4 derselben Stage blendet nichts aus,
    -- dieselbe Falle wie beim railcar-Gate oben) + Stage 60880 (Leons Quetschstellen bleiben unberuehrt).
    -- Zum Generalisieren: die Stage-Bedingung entfernen, dann gilt es fuer JEDE Quetschstelle.
    -- [3RD-PERSON-TOGGLE] Steht der First-Person-Toggle auf AUS (__re4_ks_fp_enabled == false), laufen
    -- alle Events bewusst in 3rd-Person -- dann MUSS der Koerper sichtbar bleiben, sonst schaut man auf
    -- eine leere Szene. Deshalb hier explizit mitgepruefte Bedingung.
    -- [EVT60874 FULLHIDE 2026-07-22] Mid-Event-Umschalter in Stage 60874: die ersten 1.0 s
    -- laufen bewusst in 3rd-Person (Mesh sichtbar), danach KS4 + ganzes Mesh aus. Das Flag setzt der
    -- killswitch genau im Umschalt-Zweig -> hier reicht die Abfrage, kein eigenes Stage-/Positions-Gate.
    -- Toggle-Regel wie ueberall: First-Person-Toggle AUS -> alles 3rd-Person -> Koerper sichtbar lassen.
    if rawget(_G, "__re4_evt60874_fullhide") == true
       and rawget(_G, "__re4_ks_fp_enabled") ~= false then
        fp_only_now = true
    end
    -- [STAGE_FULLHIDE 60880 -- NUR DIESES EVENT 2026-07-22] Monitordump 14:54:34:
    -- Stage 60880, KS4, Reason "ks3_gimmick", Position 64.33 / -3.66 / 237.35.
    -- Eng gegatet, damit NUR dieses eine Event den Koerper ausblendet:
    -- ks4 + Reason "ks3_gimmick" + Stage 60880 + Position im 6-m-Radius um die Dump-Stelle.
    -- Eine Leiter oder ein anderes KS4 derselben Stage bleibt damit unberuehrt, ebenso die zweite
    -- Quetschstelle weiter vorne (43.77 / 252.55, ~28 m entfernt).
    -- Bei ausgeschaltetem First-Person-Toggle laeuft alles in 3rd-Person -> Koerper muss sichtbar bleiben.
    if ks4 and rawget(_G, "__re4_ks_fp_enabled") ~= false
       and type(killswitch.get_stage_name) == "function"
       and type(killswitch.get_activating_controller) == "function" then
        local o, st = pcall(killswitch.get_stage_name)
        local o2, rs = pcall(killswitch.get_activating_controller)
        if o and o2 and tonumber(st) == 60880 and tostring(rs) == "ks3_gimmick" then
            local btf = body and call0(body, "get_Transform")
            local p = btf and call0(btf, "get_Position")
            if p then
                local dx, dy, dz = p.x - 64.33, p.y - (-3.66), p.z - 237.35
                if (dx * dx + dy * dy + dz * dz) <= 36.0 then fp_only_now = true end
            end
        end
    end
    -- [SCOPE_BODY_HIDE] Zielen durch montiertes Scope -> Body/Head-Hair aus (Waffe/Scope-Glas bleibt).
    scope_body_hide = rawget(_G, "__re4_force_killswitch_scope") == true

    -- [EXTRA_MATS] NUR die Materialien aus FULLHIDE_EXTRA_MATS (Jacke), ueber die Szene gefunden --
    -- alles andere bleibt unveraendert beim bisherigen DrawDefault-Weg samt Schattenwurf.
    -- Suchen (inkl. Lebendtest des Caches) laeuft NUR, wenn wir gerade verstecken wollen --
    -- ausserhalb kostet es nichts.
    if fp_only_now or scope_body_hide then scan_extra_mats() end
    apply_extra_mats((fp_only_now or scope_body_hide) == true)
    -- Head/Hair SICHTBAR nur in KS1 (voll/3rd-Person). Gameplay + KS2 + KS3 + KS4 -> Head/Hair versteckt.
    mat_set_enable = killswitch.is_active() and not ks2 and not ks3 and not ks4 and not ks5

    -- [KS3_FLASHLIGHT 2026-07-06] In KS3 ist der GANZE Body aus (fp_only) -> die separat in der Hand
    -- gehaltene Flashlight wuerde sonst schweben. motion ist in KS3 dormant (is_active), managed die FL
    -- also nicht mehr -> hier ausblenden. Kein Toggle-War (motion forced sie in KS3 nicht sichtbar).
    -- Beim KS3-Austritt uebernimmt motion wieder und schaltet sie per fl_set_mesh_visible zurueck an.
    -- motions gecachten Mesh-Handle bevorzugen; ist der beim Event-Eintritt nil (motion war dormant),
    -- die FL selbst finden (get_flashlight_go) und deren Root-Mesh holen. Kegel-Kind "light" bleibt an.
    local function fl_mesh_now()
        local flm = rawget(_G, "__re4_fl_mesh")
        if flm then return flm end
        local go = get_flashlight_go()
        return go and safe(function() return go:call("getComponent(System.Type)", T_MESH) end) or nil
    end
    if ks3 or ks5 then
        local flm = fl_mesh_now()
        if flm then pcall(function() flm:call("set_Enabled", false) end); fl_mesh_hidden = true end
    elseif fl_mesh_hidden then
        -- KS3-Austritt: unsere selbst-gefundene FL-Mesh EINMAL zurueck an (motion uebernimmt danach wieder).
        local flm = fl_mesh_now()
        if flm then pcall(function() flm:call("set_Enabled", true) end) end
        fl_mesh_hidden = false
    end

    -- [ASHLEY_LAMP] Hand-Lampe: in KS3 nur das ROOT-Mesh (ac0300_00) verstecken (Licht/Kegel bleiben).
    -- Waehrend KS3 jeden Frame erzwingen (gegen Spiel-Re-Enable), beim KS3-Austritt EINMAL zuruecksetzen.
    if ks3 or ks5 then
        local go = get_lamp_go()
        local mesh = go and safe(function() return go:call("getComponent(System.Type)", T_MESH) end)
        -- set_Enabled (nicht set_DrawDefault): das GO hat ParamCurveAnimator/GameObjectStateController, die den
        -- DrawDefault ueberschreiben -> set_Enable(false) auf die Mesh-Comp hidet zuverlaessig (wie die Flashlight).
        if mesh then pcall(function() mesh:call("set_Enabled", false) end); lamp_hidden = true end
    elseif lamp_hidden then
        local go = get_lamp_go()
        local mesh = go and safe(function() return go:call("getComponent(System.Type)", T_MESH) end)
        if mesh then pcall(function() mesh:call("set_Enabled", true) end) end
        lamp_hidden = false
    end

    if not body then return end
    local tf = call0(body, "get_Transform")
    if not tf then return end
	local now = os.clock()
	local delta = now - last_time
	last_time = now
	refresh_timer = refresh_timer + delta
    if not walk_state.active or refresh_timer >= FULL_REFRESH_INTERVAL then
        refresh_timer = 0
        start_walk(tf)
    end
    walk_chunk()
end)


