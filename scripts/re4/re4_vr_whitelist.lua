-- Builtin implementation: src/mods/vr/games/re4/RE4VRWhitelist.cpp
return

-- re4_vr_whitelist.lua
-- ============================================================================
-- DIE BIBEL: gemeinsame Breakable-Whitelist fuers Messer. Was hier drin ist, darf das Messer
-- (a) per Melee/Wurf ZERSTOEREN (break_nearby) UND
-- (b) per Wurf-HOMING ANPEILEN.
-- Alles AUSSERHALB wird von BEIDEN ignoriert (weder zerstoert noch anvisiert) -> Leitern & sonstige
-- HitController-Props fallen raus. Gegner laufen SEPARAT (EnemyContextList) -- nicht hier, unberuehrt.
--
-- ZWEI Wege, ein Objekt aufzunehmen:
-- 1) per TYP (Komponente) -> BREAKABLE_TYPES (z.B. "chainsaw.GmOilDrum")
-- 2) per NAME-PRAEFIX -> BREAKABLE_NAME_PREFIXES (aus dem Object Explorer, z.B. "gm84_505")
-- Ein Objekt zaehlt, wenn ES SELBST oder ein Parent (bis 4 Ebenen) matcht (der HitController sitzt oft auf
-- einem Kind wie "Before"/"After" unter dem eigentlichen gm..-Objekt).
--
-- Aendern -> Reset Scripts. Alles GLOBAL (weapons.lua sitzt am 200-Local-Limit).
-- HINWEIS: Kern-Breakables WoodBox / Durability / lebende Tiere (GmAnimal) sind in weapons.lua fest verdrahtet
-- (eigene Zerstoer-/Homing-Logik) und IMMER Ziel -- die musst du NICHT eintragen.
-- ============================================================================

-- [UND-MATCHING 2026-08-12] Diese Typen sind ab jetzt eine ZUSAETZLICHE BEDINGUNG, kein zweiter
-- Freifahrtschein: ein Objekt zaehlt nur, wenn es einen dieser Typen traegt UND sein Name in
-- BREAKABLE_NAME_PREFIXES steht. Vorher galt Typ ODER Name -- ein Typ-Eintrag hier haette also
-- SOFORT alles dieser Klasse angezogen (auch brechbare Paletten & Deko, die intern Kisten sind).
-- chainsaw.GmWoodBoxBase ist LIVE gemessen die Basis von genau vier Klassen: GmWoodBox,
-- GmWoodBoxMotion, GmPhasedWoodBox und GmSmoothWoodBox (Vasen UND Faesser tragen letztere --
-- die Klasse allein unterscheidet die Sorten also NICHT, deshalb das UND).
-- Fenster (GmWindow) und Tueren/Barrikaden haengen NICHT darunter (die erben von GmOMUnitBase).
local BREAKABLE_TYPES = {
    "chainsaw.GmWoodBoxBase",
    -- [FENSTER 2026-08-12] Fenster erben von GmOMUnitBase, NICHT von GmWoodBoxBase -- sie fielen deshalb
    -- durch das UND, egal wie gut der Name passte. Live gemessen: gm84_527_00_農村窓1FB_向きOK,
    -- Klasse chainsaw.GmWindow, woodbox=false, durability=true. Die Liste wird als ODER geprueft,
    -- das UND mit dem Namen (Sortenwort 窓) bleibt also erhalten.
    "chainsaw.GmWindow",
}

-- Rueckbau in einer Zeile: false -> altes Verhalten (Typ ODER Name).
if _G.__re4_wl_require_type == nil then _G.__re4_wl_require_type = true end

-- [GELEERT 2026-08-12] Hartkodiert steht hier NICHTS mehr -- die Liste kommt
-- ausschliesslich aus dem Capture (data/re4_vr/re4_vr_breakables.json). Die alten Eintraege bleiben
-- nur als Kommentar stehen, falls sie je wieder gebraucht werden:
--   "gm84_500_00_0_"   Fass (アイテム樽)
--   "gm84_505_00_0_"   Holzkiste gross (アイテム木箱大)
--   "gm84_575_00_0_"   weitere Kisten-Sorte
local BREAKABLE_NAME_PREFIXES = {
    -- << kommt aus dem Capture -- hier nichts eintragen >>
}

-- ============================================================================
-- [SONDERFAELLE 2026-08-12] Namen, die OHNE Typbedingung gelten (reines ODER, wie frueher).
-- Muenze/Medaille und Explosionsfass sind KEINE GmWoodBox -- sie wuerden vom UND oben
-- ausgeschlossen und waeren damit lautlos aus Homing UND Melee verschwunden.
-- Wer hier etwas eintraegt, umgeht die Typpruefung bewusst.
-- ============================================================================
-- [GELEERT 2026-08-12] Auch hier steht nichts mehr aktiv drin -- Muenze und Explosionsfass sind
-- auskommentiert, damit die Liste wirklich leer ist. Wieder scharf: die vier Zeilen einkommentieren.
local BREAKABLE_NAME_ONLY = {
    -- "gm84_508_00_0_",   -- Blaue Muenze / Sammler-Medaillon (青コイン, haengt am Pendel; HitController auf Kind "BreakObj", Prefix am Parent)
    -- [INSTANZ-NAMEN 2026-07-15] NICHT jede Muenze heisst "gm84_508_00_0_..."! Belegt per Auto-Dump
    -- (re4_breakable_dump.txt, 23:51): die Kette war "BreakObj <- 青コイン_03" -- gar kein gm-Praefix.
    -- Deshalb griff der Eintrag oben nicht -> WL=nein -> kein Homing. Der japanische Name ist der
    -- gemeinsame Nenner ALLER Instanzen (_01/_02/_03...), darum als Sorten-Praefix. Gilt fuer beide
    -- Wege: Whitelist (hier) UND Y-Offset (__re4_breakable_yoff unten) -- die haengen am SELBEN String,
    -- ein Eintrag allein reicht nicht (sonst Default +0.5 statt Muenzen--1.2 -> Wurf geht drueber).
    -- 青コイン steht nicht mehr hier, sondern in BREAKABLE_CONTAINS_ONLY (unten) -- als Praefix
    -- griff es nur bei "青コイン_03", nicht bei "gm84_508_00_教団の青コイン_(4)", wo es MITTEN im
    -- Namen steht.
    -- [DRITTE SCHREIBWEISE 2026-07-23, Dump re4_zzz_props] Live gemessen hiess die Medaille
    -- "gm84_508_00_教団の青コイン_(4)" -- dazwischen fehlt das "_0_", und der japanische Teil steht
    -- NICHT am Zeilenanfang. Der Abgleich unten ist reines Praefix-Matching (nm:sub(1,#pre)), also
    -- griffen weder "gm84_508_00_0_" noch "青コイン" -> WL=false -> Melee ignorierte sie.
    -- Kurzer gemeinsamer Stamm deckt jetzt alle Varianten dieser Sorte ab.
    "gm84_508_00_",     -- Blaue Muenze / Medaille, Schreibweise ohne _0_ (教団の青コイン_(1..n))
                        -- deckt als Praefix auch die alte Form gm84_508_00_0_ mit ab
    -- [2026-08-12] Explosionsfass kommt nicht mehr rein.
    -- "爆発ドラム缶",      -- Explosionsfass (HitController auf Kindern "BombObj"/"EmberObj", Name am Parent)
    -- << weitere hier: Stamm-Prefix = ganze Sorte | voller Name mit [..] = nur die eine Instanz >>
}

-- ============================================================================
-- [SORTENWORT 2026-08-12] Der einzige Nenner, der ueber das GANZE Spiel haelt.
-- LIVE gemessen an fuenf Faessern:
--   gm84_500_00_0_たる(2) | gm84_500_00_村長への道樽 | gm84_566_00_0_[樽] | gm84_566_00_樽_01 | gm84_566_00_樽
-- Die Asset-Nummer ist NICHT gemeinsam (500 und 566 sind verschiedene Assets), der Rest des Namens
-- ist jedes Mal anders -- gemeinsam ist NUR das Wort "Fass", und es steht MITTEN im Namen.
-- Deshalb wird hier NICHT auf den Zeilenanfang geprueft (nm:sub) sondern auf ENTHALTEN
-- (nm:find(w, 1, true) -- plain, also reine Byte-Suche; japanische Zeichen sind 3 Bytes, als
-- Lua-Pattern waere das Glueckssache). Datei MUSS UTF-8 OHNE BOM bleiben, sonst passen die Bytes
-- nicht zu denen aus get_Name.
-- Gilt wie die Praefixe NUR zusammen mit chainsaw.GmWoodBoxBase (UND) -- eine Palette, die zufaellig
-- so heisst, aber keine Kiste/Vase/Fass ist, faellt raus.
-- ============================================================================
local BREAKABLE_NAME_CONTAINS = {
    "樽",     -- Fass, Kanji   -- BELEGT (566er und 500er Faesser)
    "たる",   -- Fass, Hiragana -- BELEGT (gm84_500_00_0_たる(2))
    "タル",   -- Fass, Katakana -- BELEGT am selben Tag: gm84_565_00_0_タル (drittes Fass-Asset neben
              -- 500 und 566). Ohne diesen Eintrag waere genau dieses Fass durchgefallen, weil weder
              -- 樽 noch たる darin vorkommen -- der Beweis, dass alle drei Schriften vorkommen.
    -- [KISTE 2026-08-12] LIVE gemessen: gm84_505_00_0_木箱大 (grosse Holzkiste, GmSmoothWoodBox).
    -- Der alte Whitelist-Kommentar sprach von "アイテム木箱大" -- live steht dort KEIN アイテム davor,
    -- ein Praefix-Eintrag haette also erneut danebengegriffen. Als Sortenwort (ohne 大/小) deckt
    -- 木箱 die grosse UND die kleine Kiste ab.
    "木箱",   -- Holzkiste (grosse: 木箱大, kleine: 木箱小村) -- BELEGT ueber BEIDE:
              -- gm84_505_00_0_木箱大 und gm84_506_00_0_木箱小村 (verschiedene Assets, ein Wort)
    -- [VASE 2026-08-12] LIVE gemessen: gm84_520_00_0_壺(大)(2), Klasse GmSmoothWoodBox.
    -- Ohne (大)/(小) eingetragen -> deckt grosse und kleine Vase ab.
    -- [FENSTER 2026-08-12] BELEGT: gm84_527_00_農村窓1FB_向きOK (chainsaw.GmWindow, Durability).
    -- Als Sortenwort deckt es alle Fenster ab, nicht nur das Dorf-Asset; der Rest des Namens ist
    -- pro Instanz verschieden (Stockwerk, Ausrichtungs-Vermerk der Leveldesigner).
    "窓",     -- Fenster -- greift zusammen mit dem neuen Typ chainsaw.GmWindow oben
    "壺",     -- Vase / Krug -- BELEGT ueber BEIDE Groessen: gross gm84_520_00_0_壺(大) bzw. 壺（大）
              -- (ASCII- UND vollbreite Klammern kommen vor!), klein gm84_519_00_0_壺小.
              -- Ein eigener Eintrag fuer die kleine waere eine Doublette -- 壺 faengt sie mit.
}
_G.__re4_breakable_name_contains = BREAKABLE_NAME_CONTAINS

-- ============================================================================
-- [SORTENWORT OHNE TYP 2026-08-12] Wie oben, aber OHNE die GmWoodBoxBase-Bedingung -- fuer Sorten,
-- die keine WoodBox sind. Die Muenze haengt am Pendel und traegt nur IGimmickDurability.
-- Belegt sind zwei Namensformen, beide enthalten 青コイン:
--   "青コイン_03"  und  "gm84_508_00_教団の青コイン_(4)"  (dort steht es MITTEN im Namen)
-- Der zugehoerige Zielversatz (__re4_coin_off_y) unten prueft dasselbe Wort -- beide Wege muessen
-- zusammen passen, sonst wird die Muenze zwar angepeilt, aber 0.5 m ueber ihrem Pendel-Pivot.
-- ============================================================================
local BREAKABLE_CONTAINS_ONLY = {
    "青コイン",   -- Blaue Muenze / Medaille, alle bekannten Instanzformen
}
_G.__re4_breakable_contains_only = BREAKABLE_CONTAINS_ONLY

-- Typedefs bei JEDEM Load frisch (Aenderungen greifen per Reset Scripts).
_G.__re4_breakable_tds = (function()
    local out = {}
    for _, n in ipairs(BREAKABLE_TYPES) do
        local t = sdk.typeof(n); if t then out[#out + 1] = t end
    end
    return out
end)()
-- [CAPTURE-PERSISTENZ 2026-07-09] Vom In-Game-Capture-Tool (re4_vr_breakable_capture.lua) per Knopfdruck
-- gesammelte Staemme liegen in reframework/data/re4_breakable_whitelist.txt (eine Zeile = ein Stamm).
-- Hier beim Laden dazumergen -> ueberlebt Reload/Neustart. Duplikate raus.
do
    local seen = {}
    for _, p in ipairs(BREAKABLE_NAME_PREFIXES) do seen[p] = true end
    -- [ABLAGE 2026-08-12] Die Sammlung liegt jetzt als JSON bei den anderen Configs:
    --   reframework/data/re4_vr/re4_vr_breakables.json   { stems = { "gm..", ... } }
    -- Frueher war es eine lose TXT direkt in data/ -- zwischen den Logs, die aufgeraeumt werden;
    -- so ist schon einmal eine komplette Sammlung verlorengegangen. Die beiden alten TXT-Pfade
    -- werden weiterhin MITGELESEN, damit nichts haengenbleibt, das dort noch liegt.
    local _wl_add = function(str)
        local v = tostring(str or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if v ~= "" and v:sub(1, 1) ~= "#" and not seen[v] then
            seen[v] = true
            BREAKABLE_NAME_PREFIXES[#BREAKABLE_NAME_PREFIXES + 1] = v
        end
    end
    local _wl_json = json.load_file("re4_vr/re4_vr_breakables.json")
    if type(_wl_json) == "table" and type(_wl_json.stems) == "table" then
        for _, v in ipairs(_wl_json.stems) do _wl_add(v) end
    end
    for _, _wl_path in ipairs({ "re4_vr/re4_breakable_whitelist.txt", "re4_breakable_whitelist.txt" }) do
        local f = io.open(_wl_path, "r")
        if f then
            for line in f:lines() do _wl_add(line) end
            f:close()
        end
    end
end
_G.__re4_breakable_name_prefixes = BREAKABLE_NAME_PREFIXES
_G.__re4_breakable_name_only     = BREAKABLE_NAME_ONLY

-- Ist `go` (self ODER Parent bis 4 Ebenen) ein whitelisteter Breakable? Typ- ODER Namens-Match.
_G.__re4_is_real_breakable_prop = function(go)
    if not go then return false end
    local tds  = rawget(_G, "__re4_breakable_tds") or {}
    local pres = rawget(_G, "__re4_breakable_name_prefixes") or {}
    -- [UND-MATCHING 2026-08-12] Typ und Name werden ueber die GANZE Kette (self + 4 Parents)
    -- GESAMMELT und erst am Ende verknuepft -- sie sitzen naemlich oft auf VERSCHIEDENEN Ebenen
    -- (HitController auf dem Kind "Before"/"After", WoodBox-Komponente + gm-Name am Parent).
    -- Ergebnis: Sonderfall-Name allein ODER (Name UND Typ).
    local only = rawget(_G, "__re4_breakable_name_only") or {}
    local cont = rawget(_G, "__re4_breakable_name_contains") or {}
    local conly = rawget(_G, "__re4_breakable_contains_only") or {}
    local ok, r = pcall(function()
        local tf = go:call("get_Transform")
        local has_type, has_name = false, false
        for _ = 0, 4 do
            if not tf then break end
            local g = tf:call("get_GameObject")
            if g then
                if not has_type then
                    for _, td in ipairs(tds) do
                        if g:call("getComponent(System.Type)", td) then has_type = true; break end
                    end
                end
                local nm = g:call("get_Name")
                if type(nm) == "string" then
                    -- Sonderfaelle: gelten SOFORT, ohne Typbedingung -- als Praefix ...
                    for _, pre in ipairs(only) do
                        if nm:sub(1, #pre) == pre then return true end
                    end
                    -- ... und als Wort irgendwo im Namen (青コイン steht mal vorne, mal mittendrin).
                    for _, w in ipairs(conly) do
                        if #w > 0 and nm:find(w, 1, true) then return true end
                    end
                    if not has_name then
                        for _, pre in ipairs(pres) do
                            if nm:sub(1, #pre) == pre then has_name = true; break end
                        end
                    end
                    -- Sortenwort IRGENDWO im Namen (樽 / たる / タル ...) -- plain, kein Pattern.
                    if not has_name then
                        for _, w in ipairs(cont) do
                            if #w > 0 and nm:find(w, 1, true) then has_name = true; break end
                        end
                    end
                end
            end
            tf = tf:call("get_Parent")
        end
        -- SICHERUNG: Liefert sdk.typeof nichts (leere Typliste), waere sonst ALLES tot -> Typbedingung
        -- gilt dann als erfuellt (Verhalten wie vor dem UND).
        local need_type = (rawget(_G, "__re4_wl_require_type") ~= false) and (#tds > 0)
        if not has_name then return false end
        return (not need_type) or has_type
    end)
    return ok and r == true
end

-- [MUENZE-ZIELPUNKT 2026-07-10] Y-Versatz des Homing-Zielpunkts. Die blaue Muenze (gm84_508_00_0_) haengt am
-- Pendel -> ihr Transform-Ursprung ist der Pivot OBEN -> das Homing ginge DRUEBER. Darum NUR fuer die Muenze
-- nach UNTEN (negativ). Alles andere: +0.5 (Kisten-Mitte, Ursprung am Boden). weapons.lua ruft das INLINE auf
-- (kein Local dort -> 200-Limit). TUNEN: __re4_coin_off_y anpassen (negativer = tiefer).
_G.__re4_coin_off_y = -1.2
-- [VASE-ZIELPUNKT 2026-07-11] Die kleine Vase (gm84_519_00_0_ = GmSmoothWoodBox, "壺小") steht auf
-- HUEFTHOHEN Gelaendern und ist selbst nur ~20-30cm gross. Ihr Collider-Origin (posY) sitzt schon AUF
-- Vasenhoehe (Log: 14.73, Fuesse 13.94) -> der Origin IST praktisch der Vasenkoerper. Default +0.5 zielt
-- 0.5m drueber; zu negativ (-0.7) zeigt UNTER die Vase ins Gelaender -> los_clear failt -> Homing waehlt
-- die Vase gar nicht mehr (pick=nil, kein Homing). Also ~0: direkt auf den Origin. TUNEN in 0.05-Schritten
-- (Fenster ist klein, Vase winzig). EIGENER Eintrag -- NICHT mit Muenze/Schlange zusammengezogen.
_G.__re4_vase_off_y = -0.4
_G.__re4_breakable_yoff = function(go)
    if not go then return 0.5 end
    local ok, r = pcall(function()
        local tf = go:call("get_Transform")
        for _ = 0, 3 do
            if not tf then break end
            local g = tf:call("get_GameObject")
            local nm = g and g:call("get_Name")
            if type(nm) == "string" then
                -- [INSTANZ-NAMEN 2026-07-15] "青コイン" MUSS hier mit stehen, nicht nur in der Whitelist:
                -- beide Wege fragen denselben Namen. Ohne diesen Zweig bekaeme die Muenze den Default +0.5
                -- -> Zielpunkt 0.5m UEBER dem Pendel-Pivot (der sitzt eh schon oben) -> Wurf geht drueber.
                -- #"..." statt fester Zahl: UTF-8, 青コイン = 12 Bytes -- von Hand zaehlen geht schief.
                -- [2026-07-23] Dritte Schreibweise "gm84_508_00_教団の青コイン_(4)" mit abdecken --
                -- der kurze Stamm "gm84_508_00_" schliesst die alte Variante mit _0_ mit ein.
                -- [MUENZE PER SORTENWORT 2026-08-12] 青コイン wird jetzt per find (irgendwo im Namen)
                -- gesucht statt nur am Zeilenanfang -- bei "gm84_508_00_教団の青コイン_(4)" steht es
                -- mittendrin. Der Stamm bleibt zusaetzlich stehen, falls eine Instanz das Wort gar
                -- nicht im Namen traegt.
                if nm:find("青コイン", 1, true) or nm:sub(1, #"gm84_508_00_") == "gm84_508_00_" then
                    return tonumber(rawget(_G, "__re4_coin_off_y")) or -0.8
                -- [VASE PER SORTENWORT 2026-08-12] Vorher haftete der Versatz am Praefix
                -- "gm84_519_00_0_" -- also an EINEM Asset. Jede kleine Vase aus einem anderen Asset
                -- bekam den Default +0.5 und der Wurf ging drueber, obwohl die Whitelist sie erfasst.
                -- Jetzt am Wort: 壺 = Vase, zusaetzlich 小 = klein. Beide Zeichen werden EINZELN
                -- gesucht (find plain), damit alle Klammer-Schreibweisen mitgehen -- live belegt sind
                -- 壺小 (gm84_519), 壺(大) mit ASCII- und 壺（大） mit vollbreiten Klammern.
                -- NUR die KLEINE Vase bekommt -0.4: der Wert wurde an ihr gemessen (steht auf
                -- huefthohem Gelaender, Origin liegt schon auf Vasenhoehe). Die GROSSE Vase steht am
                -- Boden und ist ~1 m hoch -- fuer sie waere -0.4 unter dem Objekt, sie bleibt beim
                -- Default. Wenn die Grosse spaeter einen eigenen Wert braucht: hier ein Zweig mit
                -- 大 analog.
                elseif nm:find("壺", 1, true) and nm:find("小", 1, true) then
                    return tonumber(rawget(_G, "__re4_vase_off_y")) or 0.15
                end
                -- Explosionsfass bleibt bewusst beim Default +0.5: Origin sitzt am Fassboden
                -- (Dump 23:51: Fass + BombObj + EmberObj alle auf derselben Pos) -> +0.5 = Fassmitte.
            end
            tf = tf:call("get_Parent")
        end
        return 0.5
    end)
    return (ok and type(r) == "number") and r or 0.5
end

-- [SCHLANGE-ZIELPUNKT 2026-07-10] Die Schlange ist ein GEGNER (ch8g2z0 / ctx chainsaw.Ch8g2z0Context), liegt aber
-- flach am Boden -> der Gegner-Zielpunkt (Fallback pos.y+0.9) zielt DRUEBER, Messer fliegt drueber. NUR fuer die
-- Schlange nach UNTEN; alle anderen Gegner: 0 (unveraendert). weapons.lua __re4_enemy_aim_point ruft das INLINE
-- auf (kein Local dort -> 200-Limit). TUNEN: __re4_snake_off_y (negativer = tiefer). Muenze bleibt separat (-1.2).
_G.__re4_snake_off_y = -0.8
_G.__re4_enemy_off_y = function(ctx)
    if not ctx then return 0.0 end
    local ok, r = pcall(function()
        local tn = ctx:get_type_definition():get_full_name()
        if type(tn) == "string" and tn:find("Ch8g2z0") then
            return tonumber(rawget(_G, "__re4_snake_off_y")) or -0.8
        end
        return 0.0
    end)
    return (ok and type(r) == "number") and r or 0.0
end

-- [ANIMAL-ZIELPUNKT 2026-07-11] Tiere (chainsaw.GmAnimal: Kraehe/Crow, Huhn) laufen im Breakable-Homing-
-- Pfad (is_animal) und kriegen sonst den Default +0.5 -> das zielt bei der kleinen, tief sitzenden Kraehe
-- DRUEBER. Eigener Offset nach UNTEN (wie Muenze -1.2 / Vase -0.4). weapons.lua liest __re4_animal_off_y INLINE.
-- TUNEN: negativer = tiefer. Gilt aktuell fuer ALLE Tiere; falls Crow vs Huhn getrennt werden soll -> hier
-- splitten (Component-Typ chainsaw.GmCrow vs GmChicken pruefen). Getrennt von Muenze/Vase/Schlange.
_G.__re4_animal_off_y = -0.3
-- [MAUS-ZIELPUNKT 2026-07-11] Ratte (chainsaw.GmMouse, erbt GmAnimal) sitzt noch flacher am Boden als
-- Kraehe/Huhn -> eigener, tieferer Offset. weapons.lua prueft im is_animal-Zweig type_name==GmMouse INLINE
-- und nimmt DANN diesen Wert statt __re4_animal_off_y. Etwas hoeher als die Schlange (-0.8). TUNEN: negativer = tiefer.
_G.__re4_mouse_off_y = -0.9

-- [ANIMAL-CENTER 2026-07-16] ECHTER Mesh-Mittelpunkt statt Konstante -- macht __re4_animal_off_y /
-- __re4_mouse_off_y ueberfluessig, sobald er greift (sie bleiben als Fallback).
--
-- WARUM: Eine feste Abwaerts-Konstante faehrt den Zielpunkt in DAS hinein, worauf das Tier sitzt.
-- Rabe am Boden + (-0.3) = Luft drunter -> egal. Rabe auf dem Gelaender + (-0.3) = Zielpunkt IM Gelaender
-- -> los_clear failt -> das Tier wird gar nicht erst gepickt -> "das Messer hat kein Interesse".
-- Exakt dieselbe Falle wie bei der Vase (s. __re4_vase_off_y oben: "zu negativ zeigt UNTER die Vase ins
-- Gelaender -> Homing waehlt sie nicht mehr"). Nachtunen hilft da grundsaetzlich nicht.
--
-- KETTE (live am lebenden Raben verifiziert 2026-07-16 per re4_breakable_dump):
-- chainsaw.GmAnimal:get_Mesh -> via.render.Mesh:get_WorldAABB -> minpos/maxpos mitteln
-- get_WorldAABB ist bereits WELT-Raum (kein Transformieren noetig).
--
-- !! via.AABB:getCenter NICHT BENUTZEN !! Die Methode existiert im TDB, liefert ueber REFrameworks
-- ValueType-Bruecke aber MUELL: gemessen 944337.50/5.83/-51.44, waehrend minpos/maxpos derselben AABB
-- sauber 58.95..60.05 / 11.66..12.94 / -102.89..-101.77 lieferten (Rabe stand real auf 59.40/12.14/-102.27).
-- Fies daran: getCenter gibt PLAUSIBLE Zahlen zurueck, nur falsche -> ein "ist es eine Zahl?"-Check
-- faellt darauf rein. Genau das hat hier eine Runde gekostet. Darum: min/max selbst mitteln, fertig.
--
-- LEERE AABB: Die Engine initialisiert leere Boxen mit min=+FLT_MAX, max=-FLT_MAX (im Dump als
-- 3.4e38 / -3.4e38 aufgetaucht -- eine zweite Kraehe hatte das, vermutlich Mesh nicht geladen/gecullt).
-- Mitteln ergaebe 0/0/0 -> mitten in der Welt. Deshalb explizit min>max pruefen und verwerfen.
--
-- SIGNATUR: (anim, fx, fy, fz) -> x, y, z. Bekommt den Fallback-Punkt REIN und gibt ihn unveraendert
-- zurueck, wenn kein Mesh/AABB da ist. Grund: weapons.lua ist am 200-Local-Limit -> der Aufruf dort ist
-- eine reine Zuweisung auf die schon existierenden cx/cy/cz, ohne EINEN neuen Local.
-- `anim` = die GmAnimal-KOMPONENTE (weapons.lua haelt sie eh schon in is_animal), nicht das GameObject.
--
-- SANITY: Center weiter als ANIMAL_CENTER_MAX_D vom Fallback -> verwerfen. Gleiche Lektion wie der
-- [KOPF-SANITY]-Check in __re4_enemy_aim_point (dort lieferte get_HeadGameObject einen FERNEN, fremden
-- Kopf -> Ziel galt als 33m weg). Ein Kraehen-Mesh-Center liegt real < 0.5m vom Origin.
_G.__re4_animal_center_max_d = 3.0
_G.__re4_animal_center = function(anim, fx, fy, fz)
    if not anim then return fx, fy, fz end
    local ok, x, y, z = pcall(function()
        local mesh = anim:call("get_Mesh")
        if not mesh then return nil end
        local aabb = mesh:call("get_WorldAABB")
        if not aabb then return nil end
        local mn, mx = aabb:get_field("minpos"), aabb:get_field("maxpos")
        if not (mn and mx and type(mn.x) == "number" and type(mx.x) == "number") then return nil end
        -- Leere AABB (min=+FLT_MAX / max=-FLT_MAX) -> min liegt ueber max. Mitteln gaebe 0/0/0.
        if mn.x > mx.x or mn.y > mx.y or mn.z > mx.z then return nil end
        return (mn.x + mx.x) * 0.5, (mn.y + mx.y) * 0.5, (mn.z + mx.z) * 0.5
    end)
    if not (ok and type(x) == "number" and type(y) == "number" and type(z) == "number") then
        return fx, fy, fz
    end
    -- Sanity gegen den Fallback-Punkt
    local m = tonumber(rawget(_G, "__re4_animal_center_max_d")) or 3.0
    local dx, dy, dz = x - fx, y - fy, z - fz
    if (dx*dx + dy*dy + dz*dz) > (m * m) then return fx, fy, fz end
    return x, y, z
end
