-- Builtin implementation: src/mods/vr/games/re4/RE4VRLib.cpp
return

if _RE4Lib ~= nil then
    return _RE4Lib
end

local RE4 = {}
local known_typeofs = {}

if reframework:get_game_name() ~= "re4" then
    return RE4
end

local function get_component(game_object, type_name)
    if game_object == nil then return nil end
    local t = known_typeofs[type_name] or sdk.typeof(type_name)

    if t == nil then 
        return nil
    end

    known_typeofs[type_name] = t
    return game_object:call("getComponent(System.Type)", t)
end

RE4.get_component = get_component

function RE4.get_localplayer_ctx()
    local character_manager = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    if character_manager == nil then
        return nil
    end

    return character_manager:call("getPlayerContextRef")
end

function RE4.get_body(context)
    context = context or RE4.get_localplayer_ctx()
    if context == nil then
        return nil
    end

    return context:call("get_BodyGameObject")
end

function RE4.get_head(context)
    context = context or RE4.get_localplayer_ctx()
    if context == nil then
        return nil
    end

    return context:call("get_HeadGameObject")
end

function RE4.get_body_updater()
    if RE4.body == nil then
        return nil
    end

    return get_component(RE4.body, sdk.game_namespace("PlayerBodyUpdater"))
end

function RE4.get_hair_mesh()
    local updater = RE4.get_body_updater()
    if updater == nil then
        return nil
    end

    return updater:get_field("<HairMesh>k__BackingField")
end

function RE4.get_equipment(player)
    return get_component(player, sdk.game_namespace("PlayerEquipment"))
end

function RE4.get_inventory_gui_gameobject()
    return nil
end

function RE4.get_inventory_gui_behavior()
    local inventory_gui = RE4.get_inventory_gui_gameobject()

    if not inventory_gui then
        return nil
    end

    return get_component(inventory_gui, sdk.game_namespace("gui.NewInventoryBehavior"))
end

function RE4.get_weapon_object(player)
    local equipment = RE4.equipment or RE4.get_equipment(player)
    if equipment == nil then
        return nil
    end

    return equipment:call("getEquipWeapon")
end

function RE4.update_singletons()
    RE4.singletons = {
        camera_system = sdk.get_managed_singleton(sdk.game_namespace("CameraSystem"))
    }
end

RE4.fp_enabled = false

function RE4.init_globals()
    RE4.player = nil
    RE4.body = nil
    RE4.head = nil
    RE4.ik_leg = nil

    RE4.equipment = nil
    RE4.weapon = nil
    RE4.weapon_gameobject = nil
    RE4.weapon_mesh = nil
    RE4.weapon_has_scope = false
    RE4.last_inventory_shown_time = 0.0

    RE4.camera_data = {
        controller = nil,
        busy_controller = nil,
        is_player_controlled = false,
        is_crouching = false
    }
end

RE4.init_globals()
RE4.update_singletons()

local player_camera_controller_t = sdk.find_type_definition(sdk.game_namespace("PlayerCameraController"))

function RE4.is_in_inventory_menu()
    return os.clock() - RE4.last_inventory_shown_time <= 0.1
end

re.on_pre_application_entry("UpdateBehavior", function()
    RE4.update_singletons()

    RE4.player = RE4.get_localplayer_ctx()
    RE4.body = RE4.get_body(RE4.player)
    RE4.head = RE4.get_head(RE4.player)

    if RE4.player == nil then
        RE4.init_globals()
        return
    end

    RE4.ik_leg = get_component(RE4.body, "via.motion.IkLeg2")

    if RE4.singletons.camera_system ~= nil then
        local camera_data = RE4.camera_data

        -- 0 == main camera controller
        camera_data.controller = RE4.singletons.camera_system:call("getCameraController(chainsaw.CameraDefine.Role)", 0)

        if camera_data.controller ~= nil then
            camera_data.busy_controller = camera_data.controller:call("get_BusyCameraController")

            local was_player_controlled = camera_data.is_player_controlled

            if camera_data.busy_controller ~= nil then
                local is_a_player_controller = camera_data.busy_controller:get_type_definition():is_a(player_camera_controller_t)
                local is_scoped = camera_data.controller:get_field("_IsScopeCamera") and not vrmod:is_hmd_active()
                camera_data.is_player_controlled = is_a_player_controller and is_scoped == false
                camera_data.is_crouching = RE4.player:get_field("<RequestCrouch>k__BackingField")
            else
                camera_data.is_player_controlled = false
                camera_data.is_crouching = RE4.player:get_field("<RequestCrouch>k__BackingField")
            end

            if was_player_controlled and not camera_data.is_player_controlled then
                local standing_origin = vrmod:get_standing_origin()
                local hmd_pos = vrmod:get_position(0)
                hmd_pos.y = standing_origin.y
                vrmod:set_standing_origin(hmd_pos)
            end
        end
    end

    RE4.equipment = RE4.get_equipment(RE4.head)

    if RE4.equipment == nil then
        RE4.equipment = nil
        RE4.weapon = nil
        RE4.weapon_gameobject = nil
        RE4.weapon_has_scope = false
        return
    end
    
    local weapon = RE4.get_weapon_object(RE4.head)

    if weapon == nil then
        RE4.equipment = nil
        RE4.weapon = nil
        RE4.weapon_gameobject = nil
        RE4.weapon_has_scope = false
        return
    end

    if weapon ~= RE4.weapon then
        RE4.weapon = weapon
        RE4.weapon_gameobject = weapon:call("get_GameObject")
        RE4.weapon_mesh = get_component(RE4.weapon_gameobject, "via.render.Mesh")
    end
    
    RE4.weapon_has_scope = RE4.weapon:call("get_HasScope")
end)

local inventory_names = {
    "Gui_ui3030",
    "Gui_ui3040", -- just picked up an item
}

for i, v in ipairs(inventory_names) do
    inventory_names[v] = true
end

re.on_pre_gui_draw_element(function(element, context)
    local game_object = element:call("get_GameObject")
    if game_object == nil then return true end

    local name = game_object:call("get_Name")

    -- 0x10 = updating
    if inventory_names[name] ~= nil and game_object:read_byte(0x10) == 1 then
        RE4.last_inventory_shown_time = os.clock()
    end
end)

-- [UI ENTFERNT 2026-07-14] Der "RE4Debug"-object_explorer-Tree wurde entfernt (reines Dev-Werkzeug).
-- Die Bibliothek selbst (RE4 / _RE4Lib) bleibt unveraendert nutzbar.

_RE4Lib = RE4

return RE4