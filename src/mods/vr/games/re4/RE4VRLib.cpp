#define NOMINMAX
#include "RE4VRLib.hpp"

#if defined(RE4)
#include <chrono>
#include <sdk/RETypeDB.hpp>
#include <sdk/REString.hpp>
#include <sdk/MurmurHash.hpp>
#include <sdk/Application.hpp>
#include "RE4VRShared.hpp"
#include "../../../ScriptRunner.hpp"

std::shared_ptr<RE4VRLib>& RE4VRLib::get() {
    static auto inst = std::make_shared<RE4VRLib>();
    return inst;
}

void RE4VRLib::init_globals() {
    m_player = nullptr;
    m_body = nullptr;
    m_head = nullptr;
    m_equipment = nullptr;
    m_weapon = nullptr;
    m_weapon_go = nullptr;
    m_is_player_controlled = false;
    m_is_crouching = false;
}

bool RE4VRLib::is_in_inventory_menu() const {
    const auto now = std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
    return (now - m_last_inventory_shown) <= 0.1;
}

void RE4VRLib::update() {
    m_player = re4vr::player_context();
    m_body = re4vr::body_game_object();
    m_head = re4vr::head_game_object();
    if (!re4vr::obj_ok(m_player)) {
        init_globals();
        return;
    }

    auto* sys = re4vr::camera_system();
    if (re4vr::obj_ok(sys)) {
        auto* controller = re4vr::safe([&] {
            return sdk::call_object_func_easy<::REManagedObject*>(sys, "getCameraController(chainsaw.CameraDefine.Role)", 0);
        }).value_or(nullptr);
        const bool was = m_is_player_controlled;
        if (re4vr::obj_ok(controller)) {
            auto* busy = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(controller, "get_BusyCameraController"); }).value_or(nullptr);
            if (re4vr::obj_ok(busy) && m_player_cam_td) {
                const bool is_pc = utility::re_managed_object::is_a(busy, "chainsaw.PlayerCameraController");
                bool scoped = false;
                if (auto* f = sdk::get_object_field<bool>(controller, "_IsScopeCamera")) {
                    scoped = *f && !VR::get()->is_hmd_active();
                }
                m_is_player_controlled = is_pc && !scoped;
            } else {
                m_is_player_controlled = false;
            }
            if (auto* f = sdk::get_object_field<bool>(m_player, "<RequestCrouch>k__BackingField")) {
                m_is_crouching = *f;
            }
        } else {
            m_is_player_controlled = false;
        }
        if (was && !m_is_player_controlled) {
            auto& vr = VR::get();
            auto so = vr->get_standing_origin();
            auto hmd = vr->get_position(0);
            hmd.y = so.y;
            vr->set_standing_origin(hmd);
        }
    }

    m_equipment = re4vr::get_component((::REManagedObject*)m_head, "chainsaw.PlayerEquipment");
    if (!re4vr::obj_ok(m_equipment)) {
        m_weapon = nullptr;
        m_weapon_go = nullptr;
        return;
    }
    auto* weapon = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(m_equipment, "getEquipWeapon"); }).value_or(nullptr);
    if (!re4vr::obj_ok(weapon)) {
        m_equipment = nullptr;
        m_weapon = nullptr;
        m_weapon_go = nullptr;
        return;
    }
    if (weapon != m_weapon) {
        m_weapon = weapon;
        m_weapon_go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(weapon, "get_GameObject"); }).value_or(nullptr);
    }
}

void RE4VRLib::on_lua_state_created(sol::state& lua) {
    m_player_cam_td = sdk::find_type_definition("chainsaw.PlayerCameraController");
    auto t = lua.create_table();
    t["get_component"] = [](::REManagedObject* go, const std::string& tn) {
        return re4vr::get_component(go, tn.c_str());
    };
    t["get_localplayer_ctx"] = []() { return re4vr::player_context(); };
    t["get_body"] = [this](sol::object) { return m_body; };
    t["get_head"] = [this](sol::object) { return m_head; };
    t["get_equipment"] = [this](sol::object) { return m_equipment; };
    t["get_weapon_object"] = [this](sol::object) { return m_weapon; };
    t["is_in_inventory_menu"] = [this]() { return is_in_inventory_menu(); };
    t["fp_enabled"] = false;
    t["init_globals"] = [this]() { init_globals(); };
    t["update_singletons"] = []() {};
    lua["_RE4Lib"] = t;
    lua["re4"] = t;
    lua["package"]["loaded"]["utility/RE4"] = t;
}

void RE4VRLib::on_pre_application_entry(void*, const char*, size_t hash) {
    if (hash != "UpdateBehavior"_fnv) {
        return;
    }
    ScriptProfileGuard guard("utility/RE4.lua", "on_pre_application_entry:UpdateBehavior", re4vr::profile_frame());
    update();
}

bool RE4VRLib::on_pre_gui_draw_element(REComponent* gui_element, void*) {
    if (!gui_element) {
        return true;
    }
    auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(gui_element, "get_GameObject"); }).value_or(nullptr);
    if (!re4vr::obj_ok((::REManagedObject*)go)) {
        return true;
    }
    auto* nm = re4vr::safe([&] { return sdk::call_object_func_easy<::SystemString*>(go, "get_Name"); }).value_or(nullptr);
    if (!nm) {
        return true;
    }
    const auto s = utility::re_string::get_string(nm);
    if (s == "Gui_ui3030" || s == "Gui_ui3040") {
        if (*((uint8_t*)go + 0x10) == 1) {
            m_last_inventory_shown = std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
        }
    }
    return true;
}
#endif
