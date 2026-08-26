#define NOMINMAX
#include "RE4VRCrosshair.hpp"

#if defined(RE4)
#include <algorithm>
#include <cmath>
#include <cstring>

#include <glm/gtc/constants.hpp>
#include <glm/gtc/quaternion.hpp>
#include <glm/gtx/quaternion.hpp>
#include <imgui.h>
#include <spdlog/spdlog.h>

#include <sdk/SceneManager.hpp>
#include <sdk/RETypeDB.hpp>
#include <sdk/REString.hpp>
#include <sdk/REGameObject.hpp>
#include <sdk/SystemArray.hpp>
#include <sdk/MurmurHash.hpp>
#include <sdk/Application.hpp>
#include <utility/String.hpp>

#include "RE4VRMenu.hpp"
#include "RE4VRShared.hpp"
#include "../../../ScriptRunner.hpp"

namespace {
const std::vector<const char*> CHARACTER_IDS{
    "ch3a8z0_head", "ch6i0z0_head", "ch6i1z0_head", "ch6i2z0_head",
    "ch6i3z0_head", "ch3a8z0_MC_head", "ch6i5z0_head",
};
const std::unordered_set<std::string> PLAYER_CH_PREFIX{
    "ch0a0", "ch3a8", "ch6i0", "ch6i1", "ch6i2", "ch6i3", "ch6i5",
};
const std::unordered_set<int32_t> NPC_SHARED_WEAPONS{4002};
const std::vector<const char*> PLAYER_BODY_NAMES{
    "ch0a0z0_body", "ch3a8z0_body", "ch3a8z0_MC_body",
    "ch6i0z0_body", "ch6i1z0_body", "ch6i2z0_body", "ch6i3z0_body", "ch6i5z0_body",
};
const std::unordered_set<int32_t> RETICLE_SHAPE_WEAPONS{4005, 4400, 4401, 4402, 6105, 6114, 6304, 6102, 4501};
const char* RETICLE_DOT = "Gui_ui2040";
constexpr float MIN_SCALE = 0.3f;
constexpr float MAX_SCALE = 0.94f;
constexpr int32_t RETICLE_VALUE = 4;

bool json_bool(const nlohmann::json& d, const char* k, bool cur) {
    if (!d.contains(k) || d[k].is_null()) {
        return cur;
    }
    if (d[k].is_boolean()) {
        return d[k].get<bool>();
    }
    return cur;
}
float json_num(const nlohmann::json& d, const char* k, float cur) {
    if (d.contains(k) && d[k].is_number()) {
        return d[k].get<float>();
    }
    return cur;
}
Vector3f v3(const Vector4f& v) {
    return Vector3f{v.x, v.y, v.z};
}
bool joint_valid_like(::REJoint* j) {
    if (!j || !utility::re_managed_object::is_managed_object(j)) {
        return false;
    }
    return re4vr::pcall([&] { (void)sdk::get_joint_position(j); });
}
glm::quat dir_to_quat(const Vector3f& v) {
    const auto mat = glm::rowMajor4(glm::lookAtLH(Vector3f{0, 0, 0}, v, Vector3f{0, 1, 0}));
    return glm::quat{mat};
}
uint32_t laser_rgba(float r, float g, float b, float a) {
    const auto R = (uint32_t)std::floor(r * 255.0f + 0.5f);
    const auto G = (uint32_t)std::floor(g * 255.0f + 0.5f);
    const auto B = (uint32_t)std::floor(b * 255.0f + 0.5f);
    const auto A = (uint32_t)std::floor(a * 255.0f + 0.5f);
    return R + G * 256 + B * 65536 + A * 16777216;
}

sol::table re4_table(sol::state& lua) {
    sol::object loaded = lua["package"]["loaded"]["utility/RE4"];
    if (loaded.is<sol::table>()) {
        return loaded.as<sol::table>();
    }
    sol::object g = lua["re4"];
    if (g.is<sol::table>()) {
        return g.as<sol::table>();
    }
    auto t = lua.create_table();
    lua["re4"] = t;
    return t;
}
}

std::shared_ptr<RE4VRCrosshair>& RE4VRCrosshair::get() {
    static auto inst = std::make_shared<RE4VRCrosshair>();
    return inst;
}

double RE4VRCrosshair::now_clock() const {
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - m_clock_origin).count();
}

bool RE4VRCrosshair::is_finisher_prompt() const {
    return (now_clock() - m_finisher_prompt_seen) < 0.15;
}

bool RE4VRCrosshair::is_dodge_prompt() const {
    return (now_clock() - m_dodge_prompt_seen) < 0.15;
}

void RE4VRCrosshair::load_json() {
    const auto d = re4vr::load_json_file("re4_vr/re4_vr_crosshair.json");
    m_cfg.bullet_hook = json_bool(d, "bullet_hook", m_cfg.bullet_hook);
    m_cfg.crosshair_off = json_bool(d, "crosshair_off", m_cfg.crosshair_off);
    m_cfg.reticle_color = json_bool(d, "reticle_color", m_cfg.reticle_color);
    m_cfg.reticle_r = json_num(d, "reticle_r", m_cfg.reticle_r);
    m_cfg.reticle_g = json_num(d, "reticle_g", m_cfg.reticle_g);
    m_cfg.reticle_b = json_num(d, "reticle_b", m_cfg.reticle_b);
    m_cfg.force_reticle_concentrate = json_bool(d, "force_reticle_concentrate", m_cfg.force_reticle_concentrate);
    m_cfg.concentrate_ratio = json_num(d, "concentrate_ratio", m_cfg.concentrate_ratio);
    if (d.contains("reticle_scale") && d["reticle_scale"].is_object()) {
        for (auto it = d["reticle_scale"].begin(); it != d["reticle_scale"].end(); ++it) {
            if (it.value().is_number()) {
                m_cfg.reticle_scale[it.key()] = it.value().get<float>();
            }
        }
    }
}

void RE4VRCrosshair::save_json() {
    nlohmann::json out;
    out["bullet_hook"] = m_cfg.bullet_hook;
    out["crosshair_off"] = m_cfg.crosshair_off;
    out["reticle_scale"] = m_cfg.reticle_scale;
    out["reticle_color"] = m_cfg.reticle_color;
    out["reticle_r"] = m_cfg.reticle_r;
    out["reticle_g"] = m_cfg.reticle_g;
    out["reticle_b"] = m_cfg.reticle_b;
    out["force_reticle_concentrate"] = m_cfg.force_reticle_concentrate;
    out["concentrate_ratio"] = m_cfg.concentrate_ratio;
    re4vr::save_json_file("re4_vr/re4_vr_crosshair.json", out);
}

void RE4VRCrosshair::load_hud_json() {
    m_hud.guis["Gui_ui2030"] = true;
    m_hud.guis["Gui_ui2032_default"] = true;
    m_hud.guis["Gui_ui2032"] = true;
    m_hud.guis["Gui_ui2180"] = true;
    m_hud.guis["Gui_ui2190"] = true;
    m_hud.guis["Gui_ui2083"] = true;
    const auto d = re4vr::load_json_file("re4_vr/re4_vr_hand_huds.json");
    m_hud.enabled = json_bool(d, "enabled", m_hud.enabled);
    m_hud.hide_hud = json_bool(d, "hide_hud", m_hud.hide_hud);
    m_hud.ada_rot = json_bool(d, "ada_rot", m_hud.ada_rot);
    m_hud.dx = json_num(d, "dx", m_hud.dx);
    m_hud.dy = json_num(d, "dy", m_hud.dy);
    m_hud.dz = json_num(d, "dz", m_hud.dz);
    m_hud.scale = json_num(d, "scale", m_hud.scale);
    m_hud.rx = json_num(d, "rx", m_hud.rx);
    m_hud.ry = json_num(d, "ry", m_hud.ry);
    m_hud.rz = json_num(d, "rz", m_hud.rz);
    m_hud.ada_rx = json_num(d, "ada_rx", m_hud.ada_rx);
    m_hud.ada_ry = json_num(d, "ada_ry", m_hud.ada_ry);
    m_hud.ada_rz = json_num(d, "ada_rz", m_hud.ada_rz);
    m_hud.ada_dx = json_num(d, "ada_dx", m_hud.ada_dx);
    m_hud.ada_dy = json_num(d, "ada_dy", m_hud.ada_dy);
    m_hud.ada_dz = json_num(d, "ada_dz", m_hud.ada_dz);
    if (d.contains("guis") && d["guis"].is_object()) {
        for (auto it = d["guis"].begin(); it != d["guis"].end(); ++it) {
            if (it.value().is_object() && it.value().contains("enabled") && it.value()["enabled"].is_boolean()) {
                if (m_hud.guis.count(it.key())) {
                    m_hud.guis[it.key()] = it.value()["enabled"].get<bool>();
                }
            }
        }
    }
}

void RE4VRCrosshair::save_hud_json() {
    nlohmann::json out;
    out["enabled"] = m_hud.enabled;
    out["hide_hud"] = m_hud.hide_hud;
    out["ada_rot"] = m_hud.ada_rot;
    out["dx"] = m_hud.dx; out["dy"] = m_hud.dy; out["dz"] = m_hud.dz; out["scale"] = m_hud.scale;
    out["rx"] = m_hud.rx; out["ry"] = m_hud.ry; out["rz"] = m_hud.rz;
    out["ada_rx"] = m_hud.ada_rx; out["ada_ry"] = m_hud.ada_ry; out["ada_rz"] = m_hud.ada_rz;
    out["ada_dx"] = m_hud.ada_dx; out["ada_dy"] = m_hud.ada_dy; out["ada_dz"] = m_hud.ada_dz;
    nlohmann::json guis = nlohmann::json::object();
    for (auto& [n, e] : m_hud.guis) {
        guis[n] = nlohmann::json{{"enabled", e}};
    }
    out["guis"] = guis;
    re4vr::save_json_file("re4_vr/re4_vr_hand_huds.json", out);
}

void RE4VRCrosshair::load_laser_json() {
    const auto d = re4vr::load_json_file("re4_vr/re4_vr_laser.json");
    m_laser.enabled = json_bool(d, "enabled", m_laser.enabled);
    m_laser.width = json_num(d, "width", m_laser.width);
    m_laser.length = json_num(d, "length", m_laser.length);
    m_laser.force_color = json_bool(d, "force_color", m_laser.force_color);
    m_laser.r = json_num(d, "r", m_laser.r);
    m_laser.g = json_num(d, "g", m_laser.g);
    m_laser.b = json_num(d, "b", m_laser.b);
    m_laser.tune_glow = json_bool(d, "tune_glow", m_laser.tune_glow);
    m_laser.glow = json_num(d, "glow", m_laser.glow);
    m_laser.alpha = json_num(d, "alpha", m_laser.alpha);
    m_laser.smoke = json_bool(d, "smoke", m_laser.smoke);
    m_laser.smoke_amt = json_num(d, "smoke_amt", m_laser.smoke_amt);
    m_laser.smoke_speed = json_num(d, "smoke_speed", m_laser.smoke_speed);
    m_laser.dot_raycast = json_bool(d, "dot_raycast", m_laser.dot_raycast);
    m_laser.dot_dist = json_num(d, "dot_dist", m_laser.dot_dist);
    m_laser.dot_size = json_num(d, "dot_size", m_laser.dot_size);
}

void RE4VRCrosshair::save_laser_json() {
    nlohmann::json out;
    out["enabled"] = m_laser.enabled;
    out["width"] = m_laser.width;
    out["length"] = m_laser.length;
    out["force_color"] = m_laser.force_color;
    out["r"] = m_laser.r; out["g"] = m_laser.g; out["b"] = m_laser.b;
    out["tune_glow"] = m_laser.tune_glow;
    out["glow"] = m_laser.glow;
    out["alpha"] = m_laser.alpha;
    out["smoke"] = m_laser.smoke;
    out["smoke_amt"] = m_laser.smoke_amt;
    out["smoke_speed"] = m_laser.smoke_speed;
    out["dot_raycast"] = m_laser.dot_raycast;
    out["dot_dist"] = m_laser.dot_dist;
    out["dot_size"] = m_laser.dot_size;
    re4vr::save_json_file("re4_vr/re4_vr_laser.json", out);
}

void RE4VRCrosshair::register_ui() {
    if (m_ui_registered) {
        return;
    }
    m_ui_registered = true;
    RE4VRMenu::get()->add(30, "crosshair_off", [this]() {
        bool v = m_cfg.crosshair_off;
        if (ImGui::Checkbox("Disable Crosshair", &v)) {
            m_cfg.crosshair_off = v;
            save_json();
        }
    });
    RE4VRMenu::get()->add(40, "laser_color", [this]() {
        auto preset_button = [&](const char* label, float r, float g, float b, ImU32 tint) {
            const bool active = m_laser.force_color
                && std::abs(m_laser.r - r) < 0.01f
                && std::abs(m_laser.g - g) < 0.01f
                && std::abs(m_laser.b - b) < 0.01f;
            if (active) {
                ImGui::PushStyleColor(ImGuiCol_Text, tint);
            }
            if (ImGui::Button(label)) {
                m_laser.force_color = true;
                m_laser.r = r; m_laser.g = g; m_laser.b = b;
                save_laser_json();
            }
            if (active) {
                ImGui::PopStyleColor(1);
            }
        };
        ImGui::TextColored(ImVec4(1.0f, 0.647f, 0.0f, 1.0f), "Select Laser Color:");
        preset_button("Red", 1, 0, 0, IM_COL32(255, 0, 0, 255));
        ImGui::SameLine();
        preset_button("Green", 0, 1, 0, IM_COL32(0, 255, 0, 255));
        ImGui::SameLine();
        preset_button("Blue", 0, 0, 1, IM_COL32(0, 0, 255, 255));
        ImGui::SameLine();
        preset_button("Yellow", 1, 1, 0, IM_COL32(255, 255, 0, 255));
    });
    RE4VRMenu::get()->add(45, "reticle_color", [this]() {
        ImGui::TextColored(ImVec4(1.0f, 0.647f, 0.0f, 1.0f), "Select Crosshair Color:");
        const bool white_active = !m_cfg.reticle_color;
        if (white_active) {
            ImGui::PushStyleColor(ImGuiCol_Text, IM_COL32(255, 255, 255, 255));
        }
        if (ImGui::Button("White##ret")) {
            m_cfg.reticle_color = false;
            save_json();
        }
        if (white_active) {
            ImGui::PopStyleColor(1);
        }
        ImGui::SameLine();
        auto preset_button = [&](const char* label, float r, float g, float b, ImU32 tint) {
            const bool active = m_cfg.reticle_color
                && std::abs(m_cfg.reticle_r - r) < 0.01f
                && std::abs(m_cfg.reticle_g - g) < 0.01f
                && std::abs(m_cfg.reticle_b - b) < 0.01f;
            if (active) {
                ImGui::PushStyleColor(ImGuiCol_Text, tint);
            }
            if (ImGui::Button(label)) {
                m_cfg.reticle_color = true;
                m_cfg.reticle_r = r; m_cfg.reticle_g = g; m_cfg.reticle_b = b;
                save_json();
            }
            if (active) {
                ImGui::PopStyleColor(1);
            }
        };
        preset_button("Red##ret", 1, 0, 0, IM_COL32(255, 0, 0, 255));
        ImGui::SameLine();
        preset_button("Green##ret", 0, 1, 0, IM_COL32(0, 255, 0, 255));
        ImGui::SameLine();
        preset_button("Blue##ret", 0, 0, 1, IM_COL32(0, 0, 255, 255));
        ImGui::SameLine();
        preset_button("Yellow##ret", 1, 1, 0, IM_COL32(255, 255, 0, 255));
    });
    RE4VRMenu::get()->add(46, "reticle_size", [this]() {
        if (!m_current_weapon_id) {
            return;
        }
        const auto key = std::to_string(*m_current_weapon_id);
        float cur = m_cfg.reticle_scale.count(key) ? m_cfg.reticle_scale[key] : 1.0f;
        if (ImGui::SliderFloat("Crosshair Size", &cur, 0.25f, 4.0f, "%.2f")) {
            m_cfg.reticle_scale[key] = cur;
            save_json();
        }
    });
}

void RE4VRCrosshair::publish_re4() {
    re4vr::LuaGuard g;
    auto* L = g.lua();
    if (!L) {
        return;
    }
    auto t = re4_table(*L);
    t["crosshair_pos"] = m_crosshair_pos;
    t["crosshair_dir"] = m_crosshair_dir;
    t["crosshair_normal"] = m_crosshair_normal;
    if (m_crosshair_distance) {
        t["crosshair_distance"] = *m_crosshair_distance;
    }
    if (m_has_muzzle) {
        t["last_muzzle_pos"] = m_last_muzzle_pos;
        t["last_muzzle_forward"] = m_last_muzzle_forward;
        t["last_shoot_dir"] = m_last_shoot_dir;
        t["last_shoot_pos"] = m_last_shoot_pos;
        t["last_muzzle_joint"] = (::REManagedObject*)m_current_muzzle_joint;
    }
}

bool RE4VRCrosshair::ks_active() {
    return re4vr::call_killswitch_bool("is_active", RE4VRShared::get()->re4_ks_active);
}

void* RE4VRCrosshair::resolve_type(const char* name) {
    auto* td = sdk::find_type_definition(name);
    return td ? td->get_runtime_type() : nullptr;
}

int32_t RE4VRCrosshair::resolve_enum(const char* type_name, const char* field, int32_t fallback) {
    auto* t = sdk::find_type_definition(type_name);
    if (!t) {
        return fallback;
    }
    for (auto* fld : t->get_fields()) {
        if (fld && fld->is_static() && std::string{fld->get_name()} == field) {
            return fld->get_data<int32_t>(nullptr);
        }
    }
    return fallback;
}

::REManagedObject* RE4VRCrosshair::create_instance(const char* name) {
    auto* td = sdk::find_type_definition(name);
    if (!td) {
        return nullptr;
    }
    auto* obj = td->create_instance_full();
    if (obj) {
        utility::re_managed_object::add_ref(obj);
    }
    return obj;
}

::REManagedObject* RE4VRCrosshair::current_scene() {
    if (re4vr::obj_ok(m_scene)) {
        return m_scene;
    }
    auto* sm = sdk::get_native_singleton("via.SceneManager");
    auto* td = sdk::find_type_definition("via.SceneManager");
    if (!sm || !td) {
        return nullptr;
    }
    m_scene = re4vr::safe([&] { return sdk::call_native_func_easy<::REManagedObject*>(sm, td, "get_CurrentScene"); }).value_or(nullptr);
    return re4vr::obj_ok(m_scene) ? m_scene : nullptr;
}

void RE4VRCrosshair::cast_ray_async(::REManagedObject* ray_result, const Vector3f& start_pos, const Vector3f& end_pos, int32_t layer, ::REManagedObject* filter_info) {
    if (!m_cast_ray_async) {
        return;
    }
    auto* sys = sdk::get_native_singleton("via.physics.System");
    if (!sys) {
        return;
    }
    auto* ray_query = create_instance("via.physics.CastRayQuery");
    if (!ray_query || !ray_result) {
        return;
    }
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(ray_query, "setRay(via.vec3, via.vec3)", start_pos, end_pos); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(ray_query, "clearOptions"); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(ray_query, "enableAllHits"); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(ray_query, "enableNearSort"); });
    if (!filter_info) {
        filter_info = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ray_query, "get_FilterInfo"); }).value_or(nullptr);
        if (re4vr::obj_ok(filter_info)) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(filter_info, "set_Group", 0); });
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(filter_info, "set_MaskBits", (int32_t)(0xFFFFFFFF & ~1)); });
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(filter_info, "set_Layer", layer); });
        }
    }
    if (re4vr::obj_ok(filter_info)) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(ray_query, "set_FilterInfo", filter_info); });
    }
    re4vr::pcall([&] { m_cast_ray_async->call<void*>(sdk::get_thread_context(), sys, ray_query, ray_result); });
}

void RE4VRCrosshair::update_crosshair_world_pos(const Vector3f& start_pos, const Vector3f& end_pos) {
    if (!m_attack_ray || !m_bullet_ray) {
        m_attack_ray = create_instance("via.physics.CastRayResult");
        m_bullet_ray = create_instance("via.physics.CastRayResult");
        cast_ray_async(m_attack_ray, start_pos, end_pos, 5);
        cast_ray_async(m_bullet_ray, start_pos, end_pos, 10);
    }
    const bool finished = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_attack_ray, "get_Finished"); }).value_or(false)
        && re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_bullet_ray, "get_Finished"); }).value_or(false);
    const int attack_n = finished ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(m_attack_ray, "get_NumContactPoints"); }).value_or(0) : 0;
    const int bullet_n = finished ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(m_bullet_ray, "get_NumContactPoints"); }).value_or(0) : 0;
    const bool attack_hit = finished && attack_n > 0;
    const bool any_hit = finished && (attack_hit || bullet_n > 0);
    const bool both_hit = finished && attack_n > 0 && bullet_n > 0;

    if (finished && any_hit) {
        ::REManagedObject* best = nullptr;
        if (both_hit) {
            auto* acp = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(m_attack_ray, "getContactPoint(System.UInt32)", 0u); }).value_or(nullptr);
            auto* bcp = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(m_bullet_ray, "getContactPoint(System.UInt32)", 0u); }).value_or(nullptr);
            float ad = 1e9f, bd = 1e9f;
            if (acp) {
                if (auto* f = sdk::get_object_field<float>(acp, "Distance")) {
                    ad = *f;
                }
            }
            if (bcp) {
                if (auto* f = sdk::get_object_field<float>(bcp, "Distance")) {
                    bd = *f;
                }
            }
            best = (ad < bd) ? m_attack_ray : m_bullet_ray;
        } else {
            best = attack_hit ? m_attack_ray : m_bullet_ray;
        }
        auto* contact = best ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(best, "getContactPoint(System.UInt32)", 0u); }).value_or(nullptr) : nullptr;
        if (contact) {
            float contact_distance = 10.0f;
            if (auto* f = sdk::get_object_field<float>(contact, "Distance")) {
                contact_distance = *f;
            }
            if (contact_distance > 100.0f) {
                contact_distance = 100.0f;
            }
            auto dir = end_pos - start_pos;
            const float len = glm::length(dir);
            if (len > 0.0001f) {
                dir /= len;
            }
            m_crosshair_dir = dir;
            if (auto* n = sdk::get_object_field<Vector3f>(contact, "Normal")) {
                m_crosshair_normal = *n;
            } else if (auto* n4 = sdk::get_object_field<Vector4f>(contact, "Normal")) {
                m_crosshair_normal = v3(*n4);
            }
            m_crosshair_distance = contact_distance;
            m_crosshair_pos = start_pos + (m_crosshair_dir * contact_distance);
        }
    } else if (finished && !any_hit) {
        auto dir = end_pos - start_pos;
        const float len = glm::length(dir);
        if (len > 0.0001f) {
            dir /= len;
        }
        m_crosshair_dir = dir;
        m_crosshair_distance = 100.0f;
        m_crosshair_pos = start_pos + (m_crosshair_dir * 100.0f);
    } else {
        auto dir = end_pos - start_pos;
        const float len = glm::length(dir);
        if (len > 0.0001f) {
            dir /= len;
        }
        m_crosshair_dir = dir;
        if (m_crosshair_distance) {
            m_crosshair_pos = start_pos + (m_crosshair_dir * *m_crosshair_distance);
        } else {
            m_crosshair_pos = start_pos + (m_crosshair_dir * 10.0f);
            m_crosshair_distance = 10.0f;
        }
    }
    if (finished) {
        ::REManagedObject* dmg_filter = nullptr;
        if (m_filter_damage_other >= 0) {
            if (auto* q = create_instance("via.physics.CastRayQuery")) {
                dmg_filter = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(q, "get_FilterInfo"); }).value_or(nullptr);
                if (re4vr::obj_ok(dmg_filter)) {
                    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(dmg_filter, "set_Group", 0); });
                    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(dmg_filter, "set_MaskBits", (int32_t)(0xFFFFFFFF & ~1)); });
                    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(dmg_filter, "set_Layer", 5); });
                    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(dmg_filter, "set_Filter", m_filter_damage_other); });
                }
            }
        }
        cast_ray_async(m_attack_ray, start_pos, end_pos, 5, dmg_filter);
        cast_ray_async(m_bullet_ray, start_pos, end_pos, 10);
    }
    publish_re4();
}

::REGameObject* RE4VRCrosshair::find_weapon_on_player_body(const std::string& weapon_name) {
    auto* scene = current_scene();
    if (!scene) {
        return nullptr;
    }
    for (auto* body_name : PLAYER_BODY_NAMES) {
        auto* pb = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(scene, "findGameObject(System.String)", body_name); }).value_or(nullptr);
        auto* btf = pb ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(pb, "get_Transform"); }).value_or(nullptr) : nullptr;
        if (!btf) {
            continue;
        }
        auto* child = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(btf, "get_Child"); }).value_or(nullptr);
        int guard = 0;
        while (child && guard < 60) {
            ++guard;
            auto* cgo = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(child, "get_GameObject"); }).value_or(nullptr);
            if (re4vr::obj_ok((::REManagedObject*)cgo)) {
                auto* nm = re4vr::safe([&] { return sdk::call_object_func_easy<::SystemString*>(cgo, "get_Name"); }).value_or(nullptr);
                if (nm && utility::re_string::get_string(nm) == weapon_name) {
                    return cgo;
                }
            }
            child = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(child, "get_Next"); }).value_or(nullptr);
        }
    }
    return nullptr;
}

void RE4VRCrosshair::update_muzzle_data() {
    auto* scene = current_scene();
    if (!scene) {
        return;
    }
    const double current_time = now_clock();
    if (!re4vr::obj_ok((::REManagedObject*)m_cached_pl_head) || (current_time - m_cache_refresh_time) > 1.0) {
        m_cached_pl_head = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(scene, "findGameObject(System.String)", "ch0a0z0_head"); }).value_or(nullptr);
        if (!re4vr::obj_ok((::REManagedObject*)m_cached_pl_head)) {
            for (auto* id : CHARACTER_IDS) {
                m_cached_pl_head = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(scene, "findGameObject(System.String)", id); }).value_or(nullptr);
                if (re4vr::obj_ok((::REManagedObject*)m_cached_pl_head)) {
                    break;
                }
            }
        }
        m_cache_refresh_time = current_time;
    }
    if (!re4vr::obj_ok((::REManagedObject*)m_cached_pl_head)) {
        return;
    }
    auto valid = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_cached_pl_head, "get_Valid"); });
    if (valid && !*valid) {
        m_cached_pl_head = nullptr;
        return;
    }
    auto* pe_t = resolve_type("chainsaw.PlayerEquipment");
    auto* player_equip = pe_t ? re4vr::get_component((::REManagedObject*)m_cached_pl_head, "chainsaw.PlayerEquipment") : nullptr;
    auto equip_weapon = player_equip ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(player_equip, "get_EquipWeaponID()"); }) : std::nullopt;
    if (!equip_weapon) {
        equip_weapon = player_equip ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(player_equip, "get_EquipWeaponID"); }) : std::nullopt;
    }
    if (!equip_weapon) {
        return;
    }
    m_current_weapon_id = equip_weapon;
    if (!re4vr::obj_ok((::REManagedObject*)m_cached_gun_obj) || m_cached_weapon_id != equip_weapon || (current_time - m_cache_refresh_time) > 1.0) {
        const auto wp = std::string("wp") + std::to_string(*equip_weapon);
        if (NPC_SHARED_WEAPONS.count(*equip_weapon)) {
            m_cached_gun_obj = find_weapon_on_player_body(wp);
            if (!m_cached_gun_obj) {
                m_cached_gun_obj = find_weapon_on_player_body(wp + "_AO");
            }
            if (!m_cached_gun_obj) {
                m_cached_gun_obj = find_weapon_on_player_body(wp + "_MC");
            }
        } else {
            m_cached_gun_obj = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(scene, "findGameObject(System.String)", wp.c_str()); }).value_or(nullptr);
            if (!m_cached_gun_obj) {
                m_cached_gun_obj = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(scene, "findGameObject(System.String)", (wp + "_AO").c_str()); }).value_or(nullptr);
            }
            if (!m_cached_gun_obj) {
                m_cached_gun_obj = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(scene, "findGameObject(System.String)", (wp + "_MC").c_str()); }).value_or(nullptr);
            }
        }
        m_cached_weapon_id = equip_weapon;
        m_cache_refresh_time = current_time;
    }
    if (!re4vr::obj_ok((::REManagedObject*)m_cached_gun_obj)) {
        return;
    }
    auto* bt_arms = re4vr::get_component((::REManagedObject*)m_cached_gun_obj, "chainsaw.Arms");
    m_current_laser_active = false;
    if (re4vr::obj_ok(bt_arms)) {
        auto en = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(bt_arms, "get_EnableLaserSight"); });
        m_current_laser_active = en.value_or(false);
    }
    ::REJoint* muzzle_joint = nullptr;
    if (re4vr::obj_ok(bt_arms)) {
        muzzle_joint = re4vr::safe([&] { return sdk::call_object_func_easy<::REJoint*>(bt_arms, "getMuzzleJoint"); }).value_or(nullptr);
    }
    if (!muzzle_joint) {
        auto* gun_tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(m_cached_gun_obj, "get_Transform"); }).value_or(nullptr);
        if (gun_tf) {
            muzzle_joint = sdk::get_transform_joint_by_name(gun_tf, L"vfx_muzzle");
            if (!muzzle_joint) {
                muzzle_joint = sdk::get_transform_joint_by_name(gun_tf, L"vfx_muzzle1");
            }
        }
    }
    if (muzzle_joint) {
        m_current_muzzle_joint = muzzle_joint;
        m_last_muzzle_pos = v3(sdk::get_joint_position(muzzle_joint));
        auto ax = re4vr::safe([&] { return sdk::call_object_func_easy<Vector3f>((::REManagedObject*)muzzle_joint, "get_AxisZ"); });
        if (!ax) {
            ax = re4vr::safe([&] { return v3(sdk::call_object_func_easy<Vector4f>((::REManagedObject*)muzzle_joint, "get_AxisZ")); });
        }
        if (ax) {
            m_last_muzzle_forward = *ax;
        }
        m_last_shoot_dir = m_last_muzzle_forward;
        m_last_shoot_pos = m_last_muzzle_pos;
        m_has_muzzle = true;
    } else {
        m_current_muzzle_joint = nullptr;
        m_has_muzzle = false;
    }
    publish_re4();
}

void RE4VRCrosshair::apply_reticle_params() {
    if (m_reticle_params_applied) {
        return;
    }
    auto* scene = current_scene();
    if (!scene) {
        return;
    }
    const bool ok = re4vr::pcall([&] {
        auto find_go = [&](const char* n) {
            return re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(scene, "findGameObject(System.String)", n); }).value_or(nullptr);
        };
        auto* weaponCatalog = find_go("WeaponCatalog");
        ::REManagedObject* weaponDataTables2 = nullptr;
        if (!weaponCatalog) {
            weaponCatalog = find_go("WeaponCatalog_AO");
        }
        if (!weaponCatalog) {
            weaponCatalog = find_go("WeaponCatalog_MC");
            auto* cat2 = find_go("WeaponCatalog_MC_2nd");
            if (cat2) {
                auto* reg2 = re4vr::get_component((::REManagedObject*)cat2, "chainsaw.WeaponCatalogRegister");
                auto* ud2 = reg2 ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(reg2, "get_WeaponEquipParamCatalogUserData"); }).value_or(nullptr) : nullptr;
                weaponDataTables2 = ud2 ? *sdk::get_object_field<::REManagedObject*>(ud2, "_DataTable") : nullptr;
            }
        }
        if (!weaponCatalog) {
            throw std::runtime_error("no catalog");
        }
        auto* register_ = re4vr::get_component((::REManagedObject*)weaponCatalog, "chainsaw.WeaponCatalogRegister");
        auto* ud = register_ ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(register_, "get_WeaponEquipParamCatalogUserData"); }).value_or(nullptr) : nullptr;
        auto* weaponDataTables = ud && sdk::get_object_field<::REManagedObject*>(ud, "_DataTable")
            ? *sdk::get_object_field<::REManagedObject*>(ud, "_DataTable") : nullptr;
        if (!weaponDataTables) {
            throw std::runtime_error("no datatable");
        }
        auto applyPointRange = [](::REManagedObject* param) {
            if (!param) {
                return;
            }
            if (auto* s = sdk::get_object_field<float>(param, "_PointRange")) {
                // fallback raw write at 0x10 like lua write_valuetype
            }
            auto* bytes = (uint8_t*)param;
            // s and r as first two floats of the valuetype at 0x10
            *(float*)(bytes + 0x10) = 100.0f;
            *(float*)(bytes + 0x14) = 100.0f;
        };
        auto processWeaponData = [&](::REManagedObject* weaponData) {
            if (!weaponData) {
                return;
            }
            int32_t weaponID = 0;
            if (auto* f = sdk::get_object_field<int32_t>(weaponData, "_WeaponID")) {
                weaponID = *f;
            }
            auto* tblp = sdk::get_object_field<::REManagedObject*>(weaponData, "_ReticleFitParamTable");
            auto* tbl = tblp ? *tblp : nullptr;
            if (!tbl) {
                return;
            }
            if (RETICLE_SHAPE_WEAPONS.count(weaponID)) {
                if (auto* f = sdk::get_object_field<int32_t>(tbl, "_ReticleShape")) {
                    *f = RETICLE_VALUE;
                }
            }
            auto* defp = sdk::get_object_field<::REManagedObject*>(tbl, "_DefaultParam");
            applyPointRange(defp ? *defp : nullptr);
            auto* customp = sdk::get_object_field<::REManagedObject*>(tbl, "_CustomParams");
            auto* customParams = customp ? *customp : nullptr;
            if (customParams) {
                const int n = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(customParams, "get_Count"); }).value_or(0);
                for (int i = 0; i < n; ++i) {
                    auto* cp = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(customParams, "get_Item", i); }).value_or(nullptr);
                    auto* pp = cp ? sdk::get_object_field<::REManagedObject*>(cp, "_Param") : nullptr;
                    applyPointRange(pp ? *pp : nullptr);
                }
            }
        };
        for (auto* weaponTable : {weaponDataTables, weaponDataTables2}) {
            if (!weaponTable) {
                continue;
            }
            const int n = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(weaponTable, "get_Count"); }).value_or(0);
            for (int i = 0; i < n; ++i) {
                processWeaponData(re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(weaponTable, "get_Item", i); }).value_or(nullptr));
            }
        }
        auto* customCatalog = find_go("WeaponCustomCatalog");
        if (!customCatalog) {
            customCatalog = find_go("WeaponCustomCatalog_AO");
        }
        if (!customCatalog) {
            customCatalog = find_go("WeaponCustomCatalog_MC");
        }
        auto* customRegister = customCatalog ? re4vr::get_component((::REManagedObject*)customCatalog, "chainsaw.WeaponCustomCatalogRegister") : nullptr;
        auto* detailUd = customRegister ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(customRegister, "get_WeaponDetailCustomUserdata"); }).value_or(nullptr) : nullptr;
        auto* stagesp = detailUd ? sdk::get_object_field<::REManagedObject*>(detailUd, "_WeaponDetailStages") : nullptr;
        auto* stages = stagesp ? *stagesp : nullptr;
        if (stages) {
            const int n = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(stages, "get_Count"); }).value_or(0);
            for (int i = 0; i < n; ++i) {
                auto* weaponData = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(stages, "get_Item", i); }).value_or(nullptr);
                auto* detailp = weaponData ? sdk::get_object_field<::REManagedObject*>(weaponData, "_WeaponDetailCustom") : nullptr;
                auto* detail = detailp ? *detailp : nullptr;
                auto* attp = detail ? sdk::get_object_field<::REManagedObject*>(detail, "_AttachmentCustoms") : nullptr;
                auto* attachments = attp ? *attp : nullptr;
                if (!attachments) {
                    continue;
                }
                const int an = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(attachments, "get_Count"); }).value_or(0);
                for (int j = 0; j < an; ++j) {
                    auto* itemData = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(attachments, "get_Item", j); }).value_or(nullptr);
                    int32_t itemID = 0;
                    if (itemData) {
                        if (auto* f = sdk::get_object_field<int32_t>(itemData, "_ItemID")) {
                            itemID = *f;
                        }
                    }
                    auto* paramsp = itemData ? sdk::get_object_field<::REManagedObject*>(itemData, "_AttachmentParams") : nullptr;
                    auto* params = paramsp ? *paramsp : nullptr;
                    if (!params) {
                        continue;
                    }
                    const int pn = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(params, "get_Count"); }).value_or(0);
                    for (int k = 0; k < pn; ++k) {
                        auto* ad = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(params, "get_Item", k); }).value_or(nullptr);
                        if (!ad) {
                            continue;
                        }
                        if (itemID == 116008000) {
                            int32_t pnme = 0;
                            if (auto* f = sdk::get_object_field<int32_t>(ad, "_AttachmentParamName")) {
                                pnme = *f;
                            }
                            if (pnme == 501) {
                                if (auto* f = sdk::get_object_field<int32_t>(ad, "_ReticleGuiType")) {
                                    *f = RETICLE_VALUE;
                                }
                            }
                        } else if (itemID == 116006400 || itemID == 116001600 || itemID == 116009600) {
                            auto* fitp = sdk::get_object_field<::REManagedObject*>(ad, "_ReticleFitParam");
                            applyPointRange(fitp ? *fitp : nullptr);
                        }
                    }
                }
            }
        }
    });
    if (ok) {
        m_reticle_params_applied = true;
    }
}

void RE4VRCrosshair::write_vec4(::REManagedObject* obj, const Vector4f& v, int offset) {
    auto* p = (float*)((uintptr_t)obj + offset);
    p[0] = v.x; p[1] = v.y; p[2] = v.z; p[3] = v.w;
}

glm::quat RE4VRCrosshair::hud_quat_from_euler_deg(float dxg, float dyg, float dzg) {
    auto axis_q = [](float ax, float ay, float az, float ang) {
        const float h = glm::radians(ang) * 0.5f;
        const float s = std::sin(h);
        return glm::quat{std::cos(h), ax * s, ay * s, az * s};
    };
    return glm::normalize(axis_q(0, 1, 0, dyg) * axis_q(1, 0, 0, dxg) * axis_q(0, 0, 1, dzg));
}

void RE4VRCrosshair::apply_hand_hud(::REGameObject* game_object) {
    auto hand_o = RE4VRShared::get()->vr_rh_world;
    auto hrot_o = RE4VRShared::get()->vr_rh_rot;
    if (!hand_o || !hrot_o) {
        return;
    }
    const auto hand = *hand_o;
    const auto hrot = *hrot_o;
    auto* tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(game_object, "get_Transform"); }).value_or(nullptr);
    if (!tf) {
        return;
    }
    auto* gui = re4vr::get_component((::REManagedObject*)game_object, "via.gui.GUI");
    auto* view = gui ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(gui, "get_View"); }).value_or(nullptr) : nullptr;
    if (re4vr::obj_ok(view)) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(view, "set_ViewType", 1); });
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(view, "set_Overlay", true); });
    }
    float Llen = 0.0833f;
    const auto b0x = *(float*)((uintptr_t)tf + 0x80);
    const auto b0y = *(float*)((uintptr_t)tf + 0x84);
    const auto b0z = *(float*)((uintptr_t)tf + 0x88);
    const float n = std::sqrt(b0x * b0x + b0y * b0y + b0z * b0z);
    if (n > 1e-5f) {
        Llen = n;
    }
    float _rx = m_hud.rx, _ry = m_hud.ry, _rz = m_hud.rz;
    float _dx = m_hud.dx, _dy = m_hud.dy, _dz = m_hud.dz;
    if (m_hud.ada_rot && RE4VRShared::get()->re4_char_now.value_or("") == "ada") {
        _rx = m_hud.ada_rx; _ry = m_hud.ada_ry; _rz = m_hud.ada_rz;
        _dx = m_hud.ada_dx; _dy = m_hud.ada_dy; _dz = m_hud.ada_dz;
    }
    const auto off = hrot * Vector3f{_dx, _dy, _dz};
    const auto q = glm::normalize(hrot * hud_quat_from_euler_deg(_rx, _ry, _rz));
    const Matrix4x4f m{q};
    const float s = Llen * m_hud.scale;
    write_vec4((::REManagedObject*)tf, Vector4f{m[0].x * s, m[0].y * s, m[0].z * s, m[0].w * s}, 0x80);
    write_vec4((::REManagedObject*)tf, Vector4f{m[1].x * s, m[1].y * s, m[1].z * s, m[1].w * s}, 0x90);
    write_vec4((::REManagedObject*)tf, Vector4f{m[2].x * s, m[2].y * s, m[2].z * s, m[2].w * s}, 0xA0);
    write_vec4((::REManagedObject*)tf, Vector4f{hand.x + off.x, hand.y + off.y, hand.z + off.z, 1.0f}, 0xB0);
}

void RE4VRCrosshair::on_pre_request_fire(std::vector<uintptr_t>& args) {
    if (args.size() > 1 && args[1]) {
        auto* gen = (::REManagedObject*)args[1];
        if (re4vr::obj_ok(gen)) {
            auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(gen, "get_GameObject"); }).value_or(nullptr);
            auto* tf = go ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr) : nullptr;
            bool is_npc = false;
            int guard = 0;
            while (tf && guard < 16) {
                ++guard;
                auto* ngo = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(tf, "get_GameObject"); }).value_or(nullptr);
                auto* nm = ngo ? re4vr::safe([&] { return sdk::call_object_func_easy<::SystemString*>(ngo, "get_Name"); }).value_or(nullptr) : nullptr;
                if (nm) {
                    const auto s = utility::re_string::get_string(nm);
                    if (s.size() >= 2 && s.substr(0, 2) == "ch") {
                        const auto pref = s.substr(0, std::min<size_t>(5, s.size()));
                        is_npc = PLAYER_CH_PREFIX.count(pref) == 0;
                        break;
                    }
                }
                tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(tf, "get_Parent"); }).value_or(nullptr);
            }
            if (is_npc) {
                return;
            }
        }
    }
    const int seq = (int)RE4VRShared::get()->vr_shot_seq.value_or(0.0) + 1;
    RE4VRShared::get()->vr_shot_seq = seq;
    if (!m_cfg.bullet_hook) {
        return;
    }
    if (RE4VRShared::get()->vr_scope_active) {
        auto pos_o = RE4VRShared::get()->vr_scope_aim_pos;
        auto dir_o = RE4VRShared::get()->vr_scope_aim_dir;
        if (pos_o && dir_o && args.size() > 3 && args[2] && args[3]) {
            const auto p = *pos_o;
            auto d = *dir_o;
            const float len = glm::length(d);
            if (len > 0.0001f) {
                d /= len;
            }
            *(Vector3f*)args[2] = p;
            *(glm::quat*)args[3] = dir_to_quat(d);
            return;
        }
    }
    if (ks_active() && !RE4VRShared::get()->re4_railcar_mode) {
        return;
    }
    Vector3f muzzle_pos = m_last_muzzle_pos;
    Vector3f muzzle_fwd = m_last_muzzle_forward;
    if (m_current_muzzle_joint && joint_valid_like(m_current_muzzle_joint)) {
        muzzle_pos = v3(sdk::get_joint_position(m_current_muzzle_joint));
        auto ax = re4vr::safe([&] { return sdk::call_object_func_easy<Vector3f>((::REManagedObject*)m_current_muzzle_joint, "get_AxisZ"); });
        if (ax) {
            muzzle_fwd = *ax;
        }
    }
    if (!m_has_muzzle && glm::length(muzzle_fwd) < 0.0001f) {
        return;
    }
    if (args.size() > 3 && args[2] && args[3]) {
        *(Vector3f*)args[2] = muzzle_pos;
        auto n = muzzle_fwd;
        const float len = glm::length(n);
        if (len > 0.0001f) {
            n /= len;
        }
        *(glm::quat*)args[3] = dir_to_quat(n);
    }
}

void RE4VRCrosshair::on_pre_rocket_generate(std::vector<uintptr_t>& args) {
    if (!m_cfg.bullet_hook) {
        return;
    }
    if (ks_active() && !RE4VRShared::get()->re4_railcar_mode) {
        return;
    }
    if (!m_has_muzzle) {
        return;
    }
    if (args.size() > 5 && args[5]) {
        auto* owner = (::REManagedObject*)args[5];
        if (!re4vr::obj_ok(owner)) {
            return;
        }
        auto* td = utility::re_managed_object::get_type_definition(owner);
        if (!td || std::string{td->get_full_name()} != "chainsaw.Gun") {
            return;
        }
    }
    if (args.size() > 3 && args[2] && args[3]) {
        *(Vector3f*)args[2] = m_last_muzzle_pos;
        auto n = m_last_muzzle_forward;
        const float len = glm::length(n);
        if (len > 0.0001f) {
            n /= len;
        }
        *(glm::quat*)args[3] = dir_to_quat(n);
    }
}

void RE4VRCrosshair::laser_post(::REManagedObject* self) {
    if (!re4vr::obj_ok(self) || !m_laser.enabled) {
        return;
    }
    re4vr::pcall([&] {
        bool is_draw = false;
        if (auto* f = sdk::get_object_field<bool>(self, "_IsDraw")) {
            is_draw = *f;
        }
        if (!is_draw) {
            return;
        }
        auto* emitp = sdk::get_object_field<::REJoint*>(self, "SightEmitJoint");
        auto* emit = emitp ? *emitp : nullptr;
        if (!emit) {
            return;
        }
        const auto ep = v3(sdk::get_joint_position(emit));
        const auto er = sdk::get_joint_rotation(emit);
        auto ez = re4vr::safe([&] { return sdk::call_object_func_easy<Vector3f>((::REManagedObject*)emit, "get_AxisZ"); }).value_or(Vector3f{0, 0, 1});
        float sm_w = 1, sm_l = 1, sm_alpha = 1;
        if (m_laser.smoke) {
            const float t = (float)now_clock() * m_laser.smoke_speed;
            const float n = std::sin(t) * 0.5f + std::sin(t * 2.3f + 1.7f) * 0.3f + std::sin(t * 5.1f + 3.0f) * 0.2f;
            sm_w = 1.0f + m_laser.smoke_amt * n;
            sm_l = 1.0f + m_laser.smoke_amt * 0.5f * std::sin(t * 2.3f + 1.7f);
            sm_alpha = 1.0f - m_laser.smoke_amt * 0.5f * (0.5f + 0.5f * n);
        }
        auto* line = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(self, "get_Line"); }).value_or(nullptr);
        if (line) {
            auto* tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(line, "get_Transform"); }).value_or(nullptr);
            if (tf) {
                sdk::set_transform_position(tf, Vector4f{ep.x, ep.y, ep.z, 1.0f});
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(tf, "set_Rotation", er); });
                const float w = m_laser.width * sm_w;
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(tf, "set_LocalScale", Vector3f{w, w, m_laser.length * sm_l}); });
            }
        }
        if (m_laser.force_color) {
            *(uint32_t*)((uintptr_t)self + 0xD0) = laser_rgba(m_laser.r, m_laser.g, m_laser.b, 1.0f);
            *(uint8_t*)((uintptr_t)self + 0xD4) = 1;
        }
        if (m_laser.tune_glow || m_laser.smoke) {
            const float a = (m_laser.tune_glow ? m_laser.alpha : 1.0f) * sm_alpha;
            auto* mp = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(self, "get_PlayerLineAlphaMaterialParam"); }).value_or(nullptr);
            if (mp) {
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mp, "set_ValueF", a); });
            }
            if (m_laser.tune_glow) {
                auto* mp2 = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(self, "get_PlayerLineEmissiveMaterialParam"); }).value_or(nullptr);
                if (mp2) {
                    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mp2, "set_ValueF", m_laser.glow); });
                }
            }
        }
        float dist = m_laser.dot_dist;
        if (m_laser.dot_raycast && m_crosshair_distance) {
            dist = *m_crosshair_distance;
        }
        const auto endp = ep + (ez * dist);
        auto* light = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(self, "get_Light"); }).value_or(nullptr);
        if (light) {
            auto* ltf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(light, "get_Transform"); }).value_or(nullptr);
            if (ltf) {
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(ltf, "set_Position", Vector4f{endp.x, endp.y, endp.z, 1}); });
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(ltf, "set_LocalScale", Vector3f{m_laser.dot_size, m_laser.dot_size, m_laser.dot_size}); });
            }
        }
    });
}

HookManager::PreHookResult RE4VRCrosshair::pre_concentrate(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    auto& self = *get();
    if (self.m_cfg.force_reticle_concentrate && args.size() > 2) {
        float f = self.m_cfg.concentrate_ratio;
        uint32_t bits = 0;
        std::memcpy(&bits, &f, 4);
        args[2] = (uintptr_t)bits;
    }
    return HookManager::PreHookResult::CALL_ORIGINAL;
}

HookManager::PreHookResult RE4VRCrosshair::pre_apply_concentrate(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    auto& self = *get();
    if (self.m_cfg.force_reticle_concentrate && args.size() > 2) {
        args[2] = 1;
    }
    return HookManager::PreHookResult::CALL_ORIGINAL;
}

void RE4VRCrosshair::post_nop(uintptr_t&, sdk::RETypeDefinition*, uintptr_t) {}

HookManager::PreHookResult RE4VRCrosshair::pre_request_fire(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    get()->on_pre_request_fire(args);
    return HookManager::PreHookResult::CALL_ORIGINAL;
}

void RE4VRCrosshair::post_request_fire(uintptr_t&, sdk::RETypeDefinition*, uintptr_t) {}

HookManager::PreHookResult RE4VRCrosshair::pre_rocket(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    get()->on_pre_rocket_generate(args);
    return HookManager::PreHookResult::CALL_ORIGINAL;
}

HookManager::PreHookResult RE4VRCrosshair::pre_laser(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    auto& self = *get();
    self.m_laser_this = nullptr;
    if (args.size() > 1) {
        self.m_laser_this = (::REManagedObject*)args[1];
    }
    return HookManager::PreHookResult::CALL_ORIGINAL;
}

void RE4VRCrosshair::post_laser(uintptr_t&, sdk::RETypeDefinition*, uintptr_t) {
    auto& self = *get();
    self.laser_post(self.m_laser_this);
}

std::optional<std::string> RE4VRCrosshair::on_initialize() {
    load_json();
    load_hud_json();
    load_laser_json();
    if (auto* td = sdk::find_type_definition("via.physics.System")) {
        m_cast_ray_async = td->get_method("castRayAsync(via.physics.CastRayQuery, via.physics.CastRayResult)");
        if (!m_cast_ray_async) {
            m_cast_ray_async = td->get_method("castRayAsync");
        }
    }
    if (auto* td = sdk::find_type_definition("chainsaw.ReticleGuiBehavior")) {
        if (auto* m = td->get_method("set_CurrConcentrateRatio(System.Single)")) {
            g_hookman.add(m, &RE4VRCrosshair::pre_concentrate, &RE4VRCrosshair::post_nop);
        }
        if (auto* m = td->get_method("applyConcentrate(System.Boolean)")) {
            g_hookman.add(m, &RE4VRCrosshair::pre_apply_concentrate, &RE4VRCrosshair::post_nop);
        } else if (auto* m2 = td->get_method("applyConcentrate")) {
            g_hookman.add(m2, &RE4VRCrosshair::pre_apply_concentrate, &RE4VRCrosshair::post_nop);
        }
    }
    auto hook_type = [](const char* tn, const char* mn, auto pre, auto post) {
        auto* td = sdk::find_type_definition(tn);
        auto* m = td ? td->get_method(mn) : nullptr;
        if (m) {
            g_hookman.add(m, pre, post);
        }
    };
    hook_type("chainsaw.BulletShellGenerator", "requestFire", &RE4VRCrosshair::pre_request_fire, &RE4VRCrosshair::post_request_fire);
    hook_type("chainsaw.ShotgunShellGenerator", "requestFire", &RE4VRCrosshair::pre_request_fire, &RE4VRCrosshair::post_request_fire);
    hook_type("chainsaw.RocketLauncherShellGenerator", "requestGenerate", &RE4VRCrosshair::pre_rocket, &RE4VRCrosshair::post_request_fire);
    if (auto* ltd = sdk::find_type_definition("chainsaw.LaserSightController")) {
        auto* lm = ltd->get_method("updateLaser()") ? ltd->get_method("updateLaser()") : ltd->get_method("updateLaser");
        if (lm) {
            g_hookman.add(lm, &RE4VRCrosshair::pre_laser, &RE4VRCrosshair::post_laser);
        }
    }
    m_filter_damage_other = resolve_enum("chainsaw.CollisionUtil.Filter", "DamageCheckOtherThanPlayer", -1);
    if (m_filter_damage_other < 0) {
        m_filter_damage_other = resolve_enum("via.physics.FilterInfo", "DamageCheckOtherThanPlayer", -1);
    }
    register_ui();
    spdlog::info("[RE4VRCrosshair] Hooks installed");
    return std::nullopt;
}

void RE4VRCrosshair::on_config_load(const utility::Config&) {
    load_json();
    load_hud_json();
    load_laser_json();
}

void RE4VRCrosshair::on_lua_state_created(sol::state& lua) {
    lua["__re4_force_concentrate"] = m_cfg.force_reticle_concentrate;
    float f = m_cfg.concentrate_ratio;
    uint32_t bits = 0;
    std::memcpy(&bits, &f, 4);
    lua["__re4_concentrate_bits"] = bits;
    lua["__re4_vr_crosshair_hooks_installed"] = true;
    lua["__re4_laser_track_installed"] = true;
    lua["__re4_concentrate_hook_installed"] = true;
    lua["__re4_apply_concentrate_installed"] = true;
    lua["__re4_laser_pre"] = [](sol::object) {};
    lua["__re4_laser_post"] = [](sol::object retval) { return retval; };
    lua["__re4_vr_laser_pre"] = [](sol::object) {};
    lua["__re4_vr_laser_post"] = [](sol::object retval) { return retval; };
    lua["__re4_is_finisher_prompt"] = [this]() { return is_finisher_prompt(); };
    lua["__re4_is_dodge_prompt"] = [this]() { return is_dodge_prompt(); };
    if (!lua["__re4_finisher_prompt_seen"].valid() || lua["__re4_finisher_prompt_seen"] == sol::nil) {
        lua["__re4_finisher_prompt_seen"] = 0.0;
    }
    if (!lua["__re4_dodge_prompt_seen"].valid() || lua["__re4_dodge_prompt_seen"] == sol::nil) {
        lua["__re4_dodge_prompt_seen"] = 0.0;
    }
    register_ui();
    publish_re4();
}

void RE4VRCrosshair::on_lua_state_destroyed(sol::state&) {
    m_attack_ray = nullptr;
    m_bullet_ray = nullptr;
    m_cached_pl_head = nullptr;
    m_cached_gun_obj = nullptr;
    m_cached_weapon_id.reset();
    m_reticle_params_applied = false;
    m_scene = nullptr;
    m_current_muzzle_joint = nullptr;
    RE4VRShared::get()->is_aim = false;
    RE4VRShared::get()->is_reticle_displayed = false;
}

void RE4VRCrosshair::on_pre_application_entry(void*, const char*, size_t hash) {
    if (hash != "LockScene"_fnv) {
        return;
    }
    ScriptProfileGuard guard("re4_vr_crosshair.lua", "on_pre_application_entry:LockScene", re4vr::profile_frame());
    auto* ctx = re4vr::player_context();
    if (re4vr::obj_ok(ctx)) {
        RE4VRShared::get()->is_aim = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(ctx, "get_IsShootEnable"); }).value_or(false);
        RE4VRShared::get()->is_reticle_displayed = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(ctx, "get_IsReticleDisp"); }).value_or(false);
        RE4VRShared::get()->_IsWeaponChanging = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(ctx, "get_IsWeaponChanging"); }).value_or(false);
    } else {
        RE4VRShared::get()->is_aim = false;
        RE4VRShared::get()->is_reticle_displayed = false;
        RE4VRShared::get()->_IsWeaponChanging = false;
    }
    if (ks_active() && !RE4VRShared::get()->re4_railcar_mode) {
        RE4VRShared::get()->is_aim = false;
        RE4VRShared::get()->is_reticle_displayed = false;
        RE4VRShared::get()->_IsWeaponChanging = false;
    }
    update_muzzle_data();
    apply_reticle_params();
    if (m_has_muzzle) {
        const auto pos = m_last_shoot_pos + (m_last_shoot_dir * 0.05f);
        update_crosshair_world_pos(pos, pos + (m_last_shoot_dir * 1000.0f));
    }
}

bool RE4VRCrosshair::on_pre_gui_draw_element(REComponent* gui_element, void*) {
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
    const auto name = utility::re_string::get_string(nm);
    if (name == "Gui_ui2200") {
        m_finisher_prompt_seen = now_clock();
        RE4VRShared::get()->re4_finisher_prompt_seen = m_finisher_prompt_seen;
    }
    if (name == "Gui_ui2191_3" || name == "Gui_ui2150") {
        m_dodge_prompt_seen = now_clock();
        RE4VRShared::get()->re4_dodge_prompt_seen = m_dodge_prompt_seen;
    }
    if (name == "Gui_ui2042") {
        return false;
    }
    auto git = m_hud.guis.find(name);
    if (git != m_hud.guis.end() && git->second) {
        if (m_hud.hide_hud) {
            return false;
        }
        if (RE4VRShared::get()->re4_force_killswitch_scope || RE4VRShared::get()->re4_scope_native) {
            return false;
        }
        if (m_hud.enabled) {
            apply_hand_hud(go);
        }
        return true;
    }
    if (name != RETICLE_DOT) {
        return true;
    }
    if (m_cfg.crosshair_off) {
        return false;
    }
    if (m_current_laser_active) {
        return false;
    }
    if (!RE4VRShared::get()->is_aim || !m_current_muzzle_joint || !m_crosshair_distance) {
        return false;
    }
    auto* transform = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr);
    if (!transform) {
        return true;
    }
    auto* gui_comp = re4vr::get_component((::REManagedObject*)go, "via.gui.GUI");
    auto* view = gui_comp ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(gui_comp, "get_View"); }).value_or(nullptr) : nullptr;
    if (!re4vr::obj_ok(view)) {
        return true;
    }
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(view, "set_ViewType", 1); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(view, "set_Overlay", true); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(view, "set_Detonemap", true); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(view, "set_DepthTest", false); });
    auto* root = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(view, "get_Child"); }).value_or(nullptr);
    if (re4vr::obj_ok(root)) {
        const float r = m_cfg.reticle_color ? m_cfg.reticle_r : 1.0f;
        const float g = m_cfg.reticle_color ? m_cfg.reticle_g : 1.0f;
        const float b = m_cfg.reticle_color ? m_cfg.reticle_b : 1.0f;
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(root, "set_ColorScale", Vector4f{r, g, b, 1.0f}); });
    }
    re4vr::pcall([&] { VR::get()->unhide_crosshair(); });
    const float distance = *m_crosshair_distance;
    Vector3f dir = m_crosshair_dir;
    Vector3f base = m_crosshair_pos - (dir * distance);
    if (m_current_muzzle_joint) {
        const bool okp = re4vr::pcall([&] { (void)sdk::get_joint_position(m_current_muzzle_joint); });
        if (okp) {
            const auto mp = v3(sdk::get_joint_position(m_current_muzzle_joint));
            auto fwd = re4vr::safe([&] { return sdk::call_object_func_easy<Vector3f>((::REManagedObject*)m_current_muzzle_joint, "get_AxisZ"); });
            if (fwd) {
                const float len = glm::length(*fwd);
                dir = len > 0.0001f ? (*fwd / len) : dir;
                base = mp;
            }
        }
    }
    float scale_distance = distance * 0.075f;
    if (scale_distance < MIN_SCALE) {
        scale_distance = MIN_SCALE;
    } else if (scale_distance > MAX_SCALE) {
        scale_distance = MAX_SCALE;
    }
    if (m_current_weapon_id) {
        const auto key = std::to_string(*m_current_weapon_id);
        auto it = m_cfg.reticle_scale.find(key);
        if (it != m_cfg.reticle_scale.end()) {
            scale_distance *= it->second;
        }
    }
    const Matrix4x4f new_mat{dir_to_quat(dir)};
    const auto adjusted = base + (dir * (distance - 0.05f));
    write_vec4((::REManagedObject*)transform, Vector4f{new_mat[0].x * scale_distance, new_mat[0].y * scale_distance, new_mat[0].z * scale_distance, new_mat[0].w * scale_distance}, 0x80);
    write_vec4((::REManagedObject*)transform, Vector4f{new_mat[1].x * scale_distance, new_mat[1].y * scale_distance, new_mat[1].z * scale_distance, new_mat[1].w * scale_distance}, 0x90);
    write_vec4((::REManagedObject*)transform, Vector4f{new_mat[2].x * scale_distance, new_mat[2].y * scale_distance, new_mat[2].z * scale_distance, new_mat[2].w * scale_distance}, 0xA0);
    write_vec4((::REManagedObject*)transform, Vector4f{adjusted.x, adjusted.y, adjusted.z, 1.0f}, 0xB0);
    return true;
}
#endif
