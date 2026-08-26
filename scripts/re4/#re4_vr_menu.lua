-- =====================================================================
-- #re4_vr_menu.lua [2026-07-23]
-- ZENTRALE REIHENFOLGE DES REFRAMEWORK-HAUPTMENUES.
--
-- NICHT LOESCHEN -- auch nicht im Public-Release. Das "#" im Dateinamen ist kein Dev-Marker,
-- sondern Absicht: REFramework laedt die autorun-Scripte alphabetisch und ruft die
-- on_draw_ui-Callbacks in genau dieser Reihenfolge auf. "#" sortiert vor jedem Buchstaben,
-- also zeichnet dieses Script VOR allen re4_vr_*.lua -- und damit stehen die schlanken
-- Public-Optionen oben und die Entwickler-Trees der einzelnen Scripte darunter.
--
-- SO WIRD ES BENUTZT (in den einzelnen Scripten, statt eines eigenen re.on_draw_ui):
-- __re4_ui_add(10, "motion_headset", function... imgui-Code... end)
-- order = Sortierung (klein = weiter oben), id = eindeutiger Name (verhindert Doppel-
-- eintraege, falls ein Script seinen Block erneut anmeldet).
--
-- Faellt dieses Script weg, ist nichts kaputt: die Scripte melden ihren Block dann ueber ihr
-- eigenes re.on_draw_ui an (Fallback dort) -- nur die Reihenfolge ist dann nicht mehr garantiert.
--
-- VERGEBENE PLAETZE (damit nichts kollidiert):
-- 10 Headset/Runtime (motion) 20 Firstperson-Events (killswitch) 30 Crosshair (crosshair)
-- 40 Laser-Farbe (crosshair) 50 Recoil (recoil)
-- =====================================================================
-- Builtin implementation: src/mods/vr/games/re4/RE4VRMenu.cpp
return

if reframework:get_game_name() ~= "re4" then return end

-- Beim Laden (auch bei "Reset Scripts") leeren: die Scripte melden sich gleich danach neu an.
_G.__re4_ui_entries = {}

_G.__re4_ui_add = function(order, id, fn)
    if type(fn) ~= "function" then return end
    _G.__re4_ui_entries[tostring(id)] = { order = tonumber(order) or 999, fn = fn }
end

re.on_draw_ui(function()
    local list = {}
    for id, e in pairs(_G.__re4_ui_entries or {}) do
        list[#list + 1] = { id = id, order = e.order, fn = e.fn }
    end
    if #list == 0 then return end
    -- Stabil sortieren: bei gleichem order entscheidet die id, damit die Reihenfolge nicht
    -- zwischen zwei Frames springt (pairs ist ungeordnet).
    table.sort(list, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.id < b.id
    end)
    for _, e in ipairs(list) do pcall(e.fn) end
    imgui.separator()
end)

