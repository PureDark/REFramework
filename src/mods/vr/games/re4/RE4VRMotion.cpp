#define NOMINMAX
#include "RE4VRMotion.hpp"

#if defined(RE4)
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>

#include <glm/gtc/quaternion.hpp>
#include <glm/gtx/norm.hpp>
#include <glm/gtx/quaternion.hpp>
#include <imgui.h>
#include <sdk/MurmurHash.hpp>
#include <sdk/RETypeDB.hpp>
#include <sdk/RETransform.hpp>
#include <sdk/SceneManager.hpp>
#include <spdlog/spdlog.h>

#include "RE4VRCrosshair.hpp"
#include "RE4VRFrameCache.hpp"
#include "RE4VRMenu.hpp"
#include "RE4VRMerc.hpp"
#include "RE4VRShared.hpp"
#include "RE4VRWeapons2.hpp"

namespace {
constexpr float TWO_HAND_SNAP_COS = 0.966f;
constexpr float TWO_HAND_SNAP_EASE = 0.25f;
constexpr uint32_t KNIFE_FLIP_SND = 1007228839u;

glm::quat slerp_q(const glm::quat& a, const glm::quat& b, float t) {
    return glm::normalize(glm::slerp(a, b, t));
}
Vector3f lerp3(const Vector3f& a, const Vector3f& b, float t) {
    return a + (b - a) * t;
}
bool knife_id(int32_t id) {
    return id == 5000 || id == 5001 || id == 5002 || id == 5003 || id == 5006 || id == 6107 || id == 6108 || id == 6305;
}
}

std::shared_ptr<RE4VRMotion>& RE4VRMotion::get() {
    static auto inst = std::make_shared<RE4VRMotion>();
    return inst;
}

std::optional<std::string> RE4VRMotion::on_initialize() {
    load_config();
    return std::nullopt;
}

void RE4VRMotion::load_config() {
    m_cfg_raw = re4vr::load_json_file("re4_vr/re4_vr_motion.json");
    auto& d = m_cfg_raw;
    if (d.contains("knife_relfix_ada") && d["knife_relfix_ada"].is_boolean() && d["knife_relfix_ada"].get<bool>()) {
        RE4VRShared::get()->re4_ada_relfix = true;
    }
    if (d.contains("knife_relfix_ada2") && d["knife_relfix_ada2"].is_boolean() && d["knife_relfix_ada2"].get<bool>()) {
        RE4VRShared::get()->re4_ada_relfix2 = true;
    }
    if (d.contains("knife_relfix_ada3") && d["knife_relfix_ada3"].is_boolean() && d["knife_relfix_ada3"].get<bool>()) {
        RE4VRShared::get()->re4_ada_relfix3 = true;
    }
    auto numg = [&](const char* k, const char* g, double def) {
        if (d.contains(k) && d[k].is_number()) {
            re4vr::lua_set_number(g, d[k].get<double>());
        } else if (!re4vr::lua_number(g)) {
            re4vr::lua_set_number(g, def);
        }
    };
    numg("knife_swing_threshold", "__re4_knife_swing_threshold", 3.5);
    numg("pose_fade_dur", "__re4_pose_fade_dur", 0.10);
    numg("knife_touch", "__re4_knife_touch", 0.90);
    numg("knife_reach", "__re4_knife_reach", 0.90);
    numg("knife_throw_threshold", "__re4_knife_throw_threshold", 4.0);
    numg("knife_flip_speed", "__re4_knife_flip_speed", 0.18);
    numg("knife_flip_finger_deg", "__re4_knife_flip_finger_deg", -35.0);
    numg("knife_flip_pos_x", "__re4_knife_flip_pos_x", 0.0);
    numg("knife_flip_pos_y", "__re4_knife_flip_pos_y", 0.0);
    numg("knife_flip_pos_z", "__re4_knife_flip_pos_z", 0.0);
    auto load_flip_map = [](const nlohmann::json& src, std::unordered_map<int32_t, FlipPos>& dest) {
        dest.clear();
        if (!src.is_object()) {
            return;
        }
        for (auto it = src.begin(); it != src.end(); ++it) {
            if (!it.value().is_object()) {
                continue;
            }
            FlipPos p;
            p.x = re4vr::j_num(it.value(), "x", 0);
            p.y = re4vr::j_num(it.value(), "y", 0);
            p.z = re4vr::j_num(it.value(), "z", 0);
            try {
                dest[std::stoi(it.key())] = p;
            } catch (...) {
                continue;
            }
        }
    };
    if (d.contains("knife_flip_pos")) {
        load_flip_map(d["knife_flip_pos"], m_flip_pos);
    }
    if (d.contains("knife_flip_pos_ada")) {
        load_flip_map(d["knife_flip_pos_ada"], m_flip_pos_ada);
    }
    if (d.contains("controller_type") && d["controller_type"].is_string()) {
        const auto c = d["controller_type"].get<std::string>();
        if (c == "steamvr" || c == "metavr") {
            m_controller = c;
            m_metavr = (c == "metavr");
        }
    }
    auto load_corr = [](const nlohmann::json& src, Corr& dst) {
        if (!src.is_object()) {
            return;
        }
        dst.pos_x = re4vr::j_num(src, "pos_x", dst.pos_x);
        dst.pos_y = re4vr::j_num(src, "pos_y", dst.pos_y);
        dst.pos_z = re4vr::j_num(src, "pos_z", dst.pos_z);
        dst.rot_pitch = re4vr::j_num(src, "rot_pitch", dst.rot_pitch);
        dst.rot_yaw = re4vr::j_num(src, "rot_yaw", dst.rot_yaw);
        dst.rot_roll = re4vr::j_num(src, "rot_roll", dst.rot_roll);
    };
    if (d.contains("openxr_correction")) {
        load_corr(d["openxr_correction"], m_oxr);
    }
    if (d.contains("ctrl_correction")) {
        load_corr(d["ctrl_correction"], m_ctrl);
    }
    if (d.contains("left_hand_offset") && d["left_hand_offset"].is_object()) {
        auto& o = d["left_hand_offset"];
        m_hand_l.px = re4vr::j_num(o, "px", 0);
        m_hand_l.py = re4vr::j_num(o, "py", 0);
        m_hand_l.pz = re4vr::j_num(o, "pz", 0);
        m_hand_l.rx = re4vr::j_num(o, "rx", 0);
        m_hand_l.ry = re4vr::j_num(o, "ry", 0);
        m_hand_l.rz = re4vr::j_num(o, "rz", 0);
    }
    if (d.contains("weapon_offset") && d["weapon_offset"].is_object()) {
        for (auto it = d["weapon_offset"].begin(); it != d["weapon_offset"].end(); ++it) {
            if (!it.value().is_object()) {
                continue;
            }
            HandOff o;
            o.px = re4vr::j_num(it.value(), "px", 0);
            o.py = re4vr::j_num(it.value(), "py", 0);
            o.pz = re4vr::j_num(it.value(), "pz", 0);
            o.rx = re4vr::j_num(it.value(), "rx", 0);
            o.ry = re4vr::j_num(it.value(), "ry", 0);
            o.rz = re4vr::j_num(it.value(), "rz", 0);
            m_weapon_offset[it.key()] = o;
        }
        m_weapon_offset.erase("4004_stock");
    }
    if (d.contains("weapon_rel") && d["weapon_rel"].is_object()) {
        for (auto it = d["weapon_rel"].begin(); it != d["weapon_rel"].end(); ++it) {
            if (!it.value().is_object() || !it.value().contains("px") || !it.value().contains("qw")) {
                continue;
            }
            WepRel r;
            r.px = re4vr::j_num(it.value(), "px", 0);
            r.py = re4vr::j_num(it.value(), "py", 0);
            r.pz = re4vr::j_num(it.value(), "pz", 0);
            r.qx = re4vr::j_num(it.value(), "qx", 0);
            r.qy = re4vr::j_num(it.value(), "qy", 0);
            r.qz = re4vr::j_num(it.value(), "qz", 0);
            r.qw = re4vr::j_num(it.value(), "qw", 1);
            m_weapon_rel[it.key()] = r;
        }
    }
    auto load_soff = [&](const nlohmann::json& s, SupportOff& o) {
        o.px = re4vr::j_num(s, "pos_x", o.px);
        o.py = re4vr::j_num(s, "pos_y", o.py);
        o.pz = re4vr::j_num(s, "pos_z", o.pz);
        o.rx = re4vr::j_num(s, "rot_pitch", o.rx);
        o.ry = re4vr::j_num(s, "rot_yaw", o.ry);
        o.rz = re4vr::j_num(s, "rot_roll", o.rz);
        o.dock_threshold = re4vr::j_num(s, "dock_threshold", o.dock_threshold);
        o.undock_threshold = re4vr::j_num(s, "undock_threshold", o.undock_threshold);
        o.grip_x = re4vr::j_num(s, "grip_x", o.grip_x);
        o.grip_y = re4vr::j_num(s, "grip_y", o.grip_y);
        o.grip_z = re4vr::j_num(s, "grip_z", o.grip_z);
        o.grip_back = re4vr::j_num(s, "grip_back", o.grip_back);
        o.grip_fwd = re4vr::j_num(s, "grip_fwd", o.grip_fwd);
        o.blend_in = re4vr::j_num(s, "blend_in", o.blend_in);
        o.blend_out = re4vr::j_num(s, "blend_out", o.blend_out);
        o.dock_dist = re4vr::j_num(s, "dock_dist", o.dock_dist);
        o.blend_speed = re4vr::j_num(s, "blend_speed", o.blend_speed);
        o.burst_rot = re4vr::j_num(s, "burst_rot", o.burst_rot);
        o.burst_count = re4vr::j_num(s, "burst_count", o.burst_count);
        o.single_rot = re4vr::j_num(s, "single_rot", o.single_rot);
        o.lerp = re4vr::j_num(s, "lever_lerp", re4vr::j_num(s, "lerp", o.lerp));
        o.idx_rx = re4vr::j_num(s, "idx_rx", o.idx_rx);
        o.idx_ry = re4vr::j_num(s, "idx_ry", o.idx_ry);
        o.idx_rz = re4vr::j_num(s, "idx_rz", o.idx_rz);
        if (s.contains("grip_on") && s["grip_on"].is_boolean()) {
            o.grip_on = s["grip_on"].get<bool>();
        }
        if (s.contains("grip_anchor") && s["grip_anchor"].is_boolean()) {
            o.grip_anchor = s["grip_anchor"].get<bool>();
        }
        if (s.contains("grip_noroll") && s["grip_noroll"].is_boolean()) {
            o.grip_noroll = s["grip_noroll"].get<bool>();
        }
    };
    auto load_soff_map = [&](const char* key, std::unordered_map<std::string, SupportOff>& dest) {
        if (!d.contains(key) || !d[key].is_object()) {
            return;
        }
        for (auto it = d[key].begin(); it != d[key].end(); ++it) {
            if (!it.value().is_object()) {
                continue;
            }
            SupportOff o{};
            if (auto have = dest.find(it.key()); have != dest.end()) {
                o = have->second;
            }
            load_soff(it.value(), o);
            dest[it.key()] = o;
        }
    };
    load_soff_map("support_offset", m_support_off);
    load_soff_map("support_offset_aim", m_support_off_aim);
    load_soff_map("support_offset_switch", m_support_off_switch);
    load_soff_map("support_offset_switch_aim", m_support_off_switch_aim);
    load_soff_map("support_offset_switch2", m_support_off_switch2);
    load_soff_map("support_offset_switch2_aim", m_support_off_switch2_aim);
    if (d.contains("support_cfg") && d["support_cfg"].is_object()) {
        m_sup.enabled = re4vr::j_bool(d["support_cfg"], "enabled", true);
        m_sup.blend_speed = re4vr::j_num(d["support_cfg"], "blend_speed", m_sup.blend_speed);
        m_sup.grip_latch_reach = re4vr::j_num(d["support_cfg"], "grip_latch_reach", m_sup.grip_latch_reach);
    }
    m_cfg.smooth_rot = re4vr::j_num(d, "hand_smooth_rot", 0);
    m_cfg.smooth_pos = re4vr::j_num(d, "hand_smooth_pos", 0);
    if (d.contains("two_hand_cfg") && d["two_hand_cfg"].is_object()) {
        auto& th = d["two_hand_cfg"];
        m_th.enabled = re4vr::j_bool(th, "enabled", true);
        m_th.min_dist = re4vr::j_num(th, "min_dist", m_th.min_dist);
        m_th.max_dist = re4vr::j_num(th, "max_dist", m_th.max_dist);
        m_th.blend_speed = re4vr::j_num(th, "blend_speed", m_th.blend_speed);
        if (m_th.blend_speed == 0.10f) {
            m_th.blend_speed = 0.05f;
        }
    }
    if (d.contains("knife_fly") && d["knife_fly"].is_object()) {
        re4vr::LuaGuard g;
        if (auto* L = g.lua()) {
        sol::object existing = (*L)["__re4_knife_fly_cfg"];
        sol::table fc;
        if (existing.is<sol::table>()) {
            fc = existing.as<sol::table>();
        } else {
            fc = L->create_table();
            fc["speed"] = 12.0;
            fc["gravity"] = 7.0;
            fc["spin"] = 18.0;
            fc["max_time"] = 1.5;
            fc["return_delay"] = 0.4;
        }
            auto& kf = d["knife_fly"];
            for (auto it = kf.begin(); it != kf.end(); ++it) {
                if (it.value().is_number()) {
                    fc[it.key()] = it.value().get<double>();
                } else if (it.value().is_boolean()) {
                    fc[it.key()] = it.value().get<bool>();
                }
            }
            (*L)["__re4_knife_fly_cfg"] = fc;
        }
    }
    auto fl = re4vr::load_json_file("re4_vr/re4_vr_flashlight.json");
    m_fl_enabled = re4vr::j_bool(fl, "enabled", true);
    m_fl_keep_knife = re4vr::j_bool(fl, "keep_on_knife", true);
    auto load_flo = [](const nlohmann::json& src, FlOff& dst) {
        if (!src.is_object()) {
            return;
        }
        dst.pos_x = re4vr::j_num(src, "pos_x", dst.pos_x);
        dst.pos_y = re4vr::j_num(src, "pos_y", dst.pos_y);
        dst.pos_z = re4vr::j_num(src, "pos_z", dst.pos_z);
        dst.rot_pitch = re4vr::j_num(src, "rot_pitch", dst.rot_pitch);
        dst.rot_yaw = re4vr::j_num(src, "rot_yaw", dst.rot_yaw);
        dst.rot_roll = re4vr::j_num(src, "rot_roll", dst.rot_roll);
    };
    if (fl.contains("flashlight")) {
        load_flo(fl["flashlight"], m_fl_off);
    }
    if (fl.contains("light")) {
        load_flo(fl["light"], m_fl_light);
    }
    if (fl.contains("docked")) {
        load_flo(fl["docked"], m_fl_dock);
    }
    if (fl.contains("docked_light")) {
        load_flo(fl["docked_light"], m_fl_dock_light);
    }
}

void RE4VRMotion::save_config() {
    auto d = re4vr::load_json_file("re4_vr/re4_vr_motion.json");
    d["controller_type"] = m_controller;
    d["hand_smooth_rot"] = m_cfg.smooth_rot;
    d["hand_smooth_pos"] = m_cfg.smooth_pos;
    d["left_hand_offset"] = {{"px", m_hand_l.px}, {"py", m_hand_l.py}, {"pz", m_hand_l.pz}, {"rx", m_hand_l.rx}, {"ry", m_hand_l.ry}, {"rz", m_hand_l.rz}};
    nlohmann::json wo = nlohmann::json::object();
    for (auto& [k, o] : m_weapon_offset) {
        wo[k] = {{"px", o.px}, {"py", o.py}, {"pz", o.pz}, {"rx", o.rx}, {"ry", o.ry}, {"rz", o.rz}};
    }
    d["weapon_offset"] = wo;
    nlohmann::json wr = nlohmann::json::object();
    for (auto& [k, r] : m_weapon_rel) {
        wr[k] = {{"px", r.px}, {"py", r.py}, {"pz", r.pz}, {"qx", r.qx}, {"qy", r.qy}, {"qz", r.qz}, {"qw", r.qw}};
    }
    d["weapon_rel"] = wr;
    d["openxr_correction"] = {{"pos_x", m_oxr.pos_x}, {"pos_y", m_oxr.pos_y}, {"pos_z", m_oxr.pos_z}, {"rot_pitch", m_oxr.rot_pitch}, {"rot_yaw", m_oxr.rot_yaw}, {"rot_roll", m_oxr.rot_roll}};
    d["ctrl_correction"] = {{"pos_x", m_ctrl.pos_x}, {"pos_y", m_ctrl.pos_y}, {"pos_z", m_ctrl.pos_z}, {"rot_pitch", m_ctrl.rot_pitch}, {"rot_yaw", m_ctrl.rot_yaw}, {"rot_roll", m_ctrl.rot_roll}};
    d["two_hand_cfg"] = {{"enabled", m_th.enabled}, {"min_dist", m_th.min_dist}, {"max_dist", m_th.max_dist}, {"blend_speed", m_th.blend_speed}};
    d["support_cfg"] = {{"enabled", m_sup.enabled}, {"blend_speed", m_sup.blend_speed}, {"grip_latch_reach", m_sup.grip_latch_reach}};
    if (auto v = RE4VRShared::get()->re4_knife_swing_threshold) {
        d["knife_swing_threshold"] = *v;
    }
    re4vr::save_json_file("re4_vr/re4_vr_motion.json", d);
}

void RE4VRMotion::register_ui() {
    if (m_ui_registered) {
        return;
    }
    m_ui_registered = true;
    RE4VRMenu::get()->add(10, "motion_headset", [this]() {
        ImGui::Text("Runtime: %s   Controller: %s", m_runtime.c_str(), m_controller.c_str());
        ImGui::TextColored(ImVec4(1.0f, 0.65f, 0.0f, 1.0f), "Select Headset:");
        const bool steam = m_controller == "steamvr";
        if (steam) {
            ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.25f, 0.88f, 0.82f, 1.0f));
        }
        if (ImGui::Button("SteamVR##public")) {
            if (m_controller != "steamvr") {
                m_controller = "steamvr";
                m_metavr = false;
                save_config();
            }
        }
        if (steam) {
            ImGui::PopStyleColor();
        }
        ImGui::SameLine();
        const bool meta = m_controller == "metavr";
        if (meta) {
            ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.25f, 0.88f, 0.82f, 1.0f));
        }
        if (ImGui::Button("MetaVR##public")) {
            if (m_controller != "metavr") {
                m_controller = "metavr";
                m_metavr = true;
                save_config();
            }
        }
        if (meta) {
            ImGui::PopStyleColor();
        }
    });
}

void RE4VRMotion::export_globals(sol::state& lua) {
    lua["__re4_motion_public_draw"] = [this]() { register_ui(); };
    lua["__re4_knife_ks_restore_native"] = [this]() { knife_ks_restore_native(); };
    lua["__re4_fl_dispatch"] = [this](sol::object p, sol::object r) {
        auto pos = re4vr::as_vec3(p);
        auto rot = re4vr::as_quat(r);
        if (pos && rot) {
            apply_flashlight(*pos, *rot);
        }
    };
    lua["__re4_pump_grip_weapons"] = lua.create_table();
    lua["__re4_pump_grip_weapons"][4100] = true;
    lua["__re4_pump_grip_weapons"][4101] = true;
    if (lua["__re4_ks4fade"].get_type() != sol::type::table) {
        auto t = lua.create_table();
        t["dur"] = 0.35;
        t["from"] = lua.create_table();
        lua["__re4_ks4fade"] = t;
    }
    lua["vr_knife_swing"] = m_knife_swing;
}

void RE4VRMotion::on_lua_state_created(sol::state& lua) {
    load_config();
    export_globals(lua);
    register_ui();
}
void RE4VRMotion::on_lua_state_destroyed(sol::state&) {
    m_rh = m_lh = nullptr;
    m_body_tf = nullptr;
    m_wep = {};
    m_init = false;
}

RE4VRMotion::HandOff& RE4VRMotion::get_weapon_offset(const std::string& key) {
    auto it = m_weapon_offset.find(key);
    if (it == m_weapon_offset.end()) {
        m_weapon_offset[key] = HandOff{};
        return m_weapon_offset[key];
    }
    return it->second;
}

std::optional<int32_t> RE4VRMotion::get_equip_weapon_id() {
    auto& fc = RE4VRFrameCache::get();
    if (fc->on()) {
        return fc->equip_wid();
    }
    auto* ctx = re4vr::player_context();
    auto* hu = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_HeadUpdater"); }).value_or(nullptr) : nullptr;
    if (!hu) {
        return std::nullopt;
    }
    auto n = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(hu, "get_EquipWeaponID"); });
    if (n) {
        return *n;
    }
    auto* o = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(hu, "get_EquipWeaponID"); }).value_or(nullptr);
    if (o) {
        return re4vr::safe([&] { return utility::re_managed_object::get_field<int32_t>(o, "value__"); }).value_or(0);
    }
    return std::nullopt;
}

std::string RE4VRMotion::rel_key(int32_t wid) {
    auto ch = RE4VRShared::get()->re4_char_now.value_or("leon");
    if (knife_id(wid) && ch == "ada") {
        return std::to_string(wid) + "@ada";
    }
    return std::to_string(wid);
}

std::string RE4VRMotion::current_weapon_key() {
    auto w = m_wep.id;
    if (!w || *w <= 0) {
        return "-1";
    }
    return std::to_string(*w);
}

bool RE4VRMotion::is_two_hand_aim_weapon() {
    return m_wep.id && m_two_hand_ids.contains(*m_wep.id);
}
bool RE4VRMotion::is_support_hand_weapon() {
    return m_wep.id && m_support_ids.contains(*m_wep.id);
}
bool RE4VRMotion::is_killswitch_active() {
    if (RE4VRShared::get()->vr_motion_paused) {
        return true;
    }
    if (RE4VRShared::get()->re4_railcar_mode) {
        if (!RE4VRShared::get()->re4_railcar_reloading) {
            return false;
        }
    }
    if (RE4VRShared::get()->re4_throwsight_active) {
        return true;
    }
    return re4vr::call_killswitch_bool("is_active", RE4VRShared::get()->re4_ks_active);
}

void RE4VRMotion::find_joints() {
    auto* tf = re4vr::body_transform();
    m_body_tf = tf;
    if (!tf) {
        m_rh = m_lh = nullptr;
        return;
    }
    if (!m_rh) {
        m_rh = sdk::get_transform_joint_by_name(tf, L"R_Hand");
    }
    if (!m_lh) {
        m_lh = sdk::get_transform_joint_by_name(tf, L"L_Hand");
    }
}

void RE4VRMotion::write_joint_pose(::REJoint* j, const Vector3f& pos, const glm::quat& rot) {
    if (!j) {
        return;
    }
    sdk::set_joint_position(j, re4vr::v4(pos));
    sdk::set_joint_rotation(j, rot);
}

void RE4VRMotion::restore_hands_native() {
    find_joints();
    auto restore = [](::REJoint* h) {
        if (!h) {
            return;
        }
        auto bp = re4vr::safe([&] { return sdk::call_object_func_easy<Vector4f>(h, "get_BaseLocalPosition"); });
        if (bp) {
            sdk::set_joint_local_position(h, *bp);
        }
    };
    restore(m_rh);
    restore(m_lh);
}

void RE4VRMotion::release_motion_targets() {
    RE4VRShared::get()->vr_lh_world.reset();
    RE4VRShared::get()->vr_lh_rot.reset();
    RE4VRShared::get()->vr_lh_joint_pos.reset();
    RE4VRShared::get()->vr_lh_joint_rot.reset();
    RE4VRShared::get()->vr_unified_lh_pos.reset();
    RE4VRShared::get()->vr_rh_world.reset();
    RE4VRShared::get()->vr_rh_rot.reset();
    RE4VRShared::get()->vr_rh_joint_pos.reset();
    RE4VRShared::get()->vr_rh_joint_rot.reset();
    RE4VRShared::get()->vr_unified_rh_pos.reset();
    m_rh_ok = m_lh_ok = false;
}

Vector3f RE4VRMotion::apply_hand_offset(const Vector3f& pos, const glm::quat& rot, const HandOff& off, glm::quat& out_rot) {
    Vector3f p = pos;
    out_rot = rot;
    if (off.px != 0 || off.py != 0 || off.pz != 0) {
        p = pos + re4vr::quat_rotate(rot, Vector3f{off.px, off.py, off.pz});
    }
    if (off.rx != 0 || off.ry != 0 || off.rz != 0) {
        out_rot = glm::normalize(rot * re4vr::quat_euler_yxz_deg(off.rx, off.ry, off.rz));
    }
    return p;
}

Vector3f RE4VRMotion::clamp_hand_to_arm_reach(const Vector3f& hand_pos, bool left) {
    if (RE4VRShared::get()->re4_railcar_mode) {
        return hand_pos;
    }
    const char* side = left ? "L" : "R";
    auto root = re4vr::lua_vec3(std::string("__vr_arm_chain_") + side + "_root");
    auto maxr = re4vr::lua_number(std::string("__vr_arm_chain_") + side + "_maxreach");
    if (!root || !maxr || *maxr <= 0.05) {
        return hand_pos;
    }
    const auto dlt = hand_pos - *root;
    const float d = glm::length(dlt);
    if (d <= (float)*maxr || d < 1e-6f) {
        return hand_pos;
    }
    return *root + dlt * ((float)*maxr / d);
}

std::optional<RE4VRMotion::CamData> RE4VRMotion::get_camera_data() {
    auto* cam = sdk::get_primary_camera();
    if (!cam) {
        return std::nullopt;
    }
    auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(cam, "get_GameObject"); }).value_or(nullptr);
    auto* tf = go ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr) : nullptr;
    if (!tf) {
        return std::nullopt;
    }
    CamData c;
    auto rot = re4vr::safe([&] { return sdk::call_object_func_easy<glm::quat>(tf, "get_Rotation"); });
    if (!rot) {
        return std::nullopt;
    }
    c.rot = *rot;
    auto wm = re4vr::safe([&] { return sdk::call_object_func_easy<Matrix4x4f>(cam, "get_WorldMatrix"); });
    if (wm) {
        c.pos = Vector3f{(*wm)[3].x, (*wm)[3].y, (*wm)[3].z};
    } else {
        c.pos = re4vr::v3(sdk::get_transform_position(tf));
    }
    if (RE4VRShared::get()->vr_camera_fix_active) {
        if (auto p = RE4VRShared::get()->vr_camera_fix_pos) {
            c.pos = *p;
        }
        if (auto r = RE4VRShared::get()->vr_camera_fix_rot) {
            c.rot = *r;
        }
    }
    return c;
}

std::optional<RE4VRMotion::VrData> RE4VRMotion::get_vr_data() {
    auto& vr = VR::get();
    if (!vr->is_hmd_active()) {
        return std::nullopt;
    }
    auto& ctrls = vr->get_controllers();
    if (ctrls.size() < 2) {
        return std::nullopt;
    }
    VrData d;
    d.rh_pos = re4vr::v3(vr->get_position(ctrls[1]));
    d.lh_pos = re4vr::v3(vr->get_position(ctrls[0]));
    d.rh_rot = glm::normalize(glm::quat{vr->get_rotation(ctrls[1])});
    d.lh_rot = glm::normalize(glm::quat{vr->get_rotation(ctrls[0])});
    d.rh_ok = d.lh_ok = true;
    return d;
}

std::pair<Vector3f, glm::quat> RE4VRMotion::controller_to_world(const Vector3f& pos, const glm::quat& rot, const CamData& cam) {
    auto& vr = VR::get();
    if (!m_standing_set) {
        m_standing = re4vr::v3(vr->get_standing_origin());
        m_standing_set = true;
    }
    auto rel = pos - m_standing;
    const auto rot_off = vr->get_rotation_offset();
    rel = re4vr::quat_rotate(rot_off, rel);
    auto world_pos = cam.pos + re4vr::quat_rotate(cam.rot, rel);
    auto ctrl_q = glm::normalize(rot_off * rot);
    auto world_rot = glm::normalize(cam.rot * ctrl_q);
    if (m_runtime == "openxr") {
        const auto fix = re4vr::quat_euler_yxz_deg(m_oxr.rot_pitch, m_oxr.rot_yaw, m_oxr.rot_roll);
        world_rot = glm::normalize(world_rot * fix);
        world_pos += re4vr::quat_rotate(world_rot, Vector3f{m_oxr.pos_x, m_oxr.pos_y, m_oxr.pos_z});
    }
    if (m_controller == "metavr") {
        const auto fix = re4vr::quat_euler_yxz_deg(m_ctrl.rot_pitch, m_ctrl.rot_yaw, m_ctrl.rot_roll);
        world_rot = glm::normalize(world_rot * fix);
        world_pos += re4vr::quat_rotate(world_rot, Vector3f{m_ctrl.pos_x, m_ctrl.pos_y, m_ctrl.pos_z});
    }
    return {world_pos, world_rot};
}

void RE4VRMotion::find_weapon() {
    auto wid = get_equip_weapon_id();
    if (wid && *wid > 0 && !knife_id(*wid)) {
        m_wep.parry_last_gun = *wid;
    } else {
        auto ut = RE4VRShared::get()->re4_parry_keep_gun_until;
        if (ut && re4vr::now() < *ut && m_wep.parry_last_gun) {
            wid = m_wep.parry_last_gun;
        }
    }
    if (!wid || *wid == 0) {
        m_wep.id.reset();
        m_wep.go = nullptr;
        m_wep.tf = nullptr;
        m_wep.rel_pos.reset();
        m_wep.rel_rot.reset();
        return;
    }
    if (m_wep.id == wid && m_wep.tf) {
        auto valid = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_wep.tf, "get_Valid"); });
        if (valid != false) {
            return;
        }
    }
    m_wep.id = *wid;
    m_wep.go = nullptr;
    m_wep.tf = nullptr;
    const auto rk = rel_key(*wid);
    if (auto it = m_weapon_rel.find(rk); it != m_weapon_rel.end()) {
        m_wep.rel_pos = Vector3f{it->second.px, it->second.py, it->second.pz};
        m_wep.rel_rot = glm::quat{it->second.qw, it->second.qx, it->second.qy, it->second.qz};
        m_wep.frozen = true;
        m_wep.calib_wait = 0;
    } else {
        m_wep.rel_pos.reset();
        m_wep.rel_rot.reset();
        m_wep.frozen = false;
        m_wep.calib_wait = 25;
        m_wep.calib_sample = 5;
    }
    auto* btf = re4vr::body_transform();
    if (!btf) {
        return;
    }
    char base[16];
    std::snprintf(base, sizeof(base), "wp%04d", *wid);
    ::REGameObject* found = nullptr;
    ::REGameObject* suffix = nullptr;
    auto* c = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(btf, "get_Child"); }).value_or(nullptr);
    int n = 0;
    while (c && n++ < 64) {
        auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(c, "get_GameObject"); }).value_or(nullptr);
        auto nm = go ? re4vr::go_name((::REManagedObject*)go) : std::string{};
        if (nm == base) {
            found = go;
            break;
        }
        if (!suffix && (nm == std::string(base) + "_AO" || nm == std::string(base) + "_MC")) {
            suffix = go;
        }
        c = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(c, "get_Next"); }).value_or(nullptr);
    }
    if (!found) {
        found = suffix;
    }
    m_wep.go = found;
    m_wep.tf = found ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(found, "get_Transform"); }).value_or(nullptr) : nullptr;
}

void RE4VRMotion::apply_two_hand_aim(const VrData& vr, const CamData& cam) {
    if (m_th.blend <= 0) {
        m_th.engage0.reset();
    }
    if (!m_th.enabled || !is_two_hand_aim_weapon()) {
        m_th.blend = 0;
        m_th.active = false;
        return;
    }
    if (m_sup.switch_docked || RE4VRShared::get()->vr_mag_in_hand || RE4VRShared::get()->vr_block_two_hand
        || RE4VRShared::get()->vr_pump_anim_active || !m_rh_ok) {
        m_th.blend = 0;
        m_th.active = false;
        return;
    }
    auto [lh_raw, lh_rr] = controller_to_world(vr.lh_pos, vr.lh_rot, cam);
    (void)lh_rr;
    const float dist = glm::length(lh_raw - m_rh_world);
    const bool lg = re4vr::grip_held(true);
    const bool rg = re4vr::grip_held(false);
    float target = 0;
    if (lg && rg && m_sup.free_near && dist >= m_th.min_dist && dist <= m_th.max_dist) {
        target = 1;
    }
    const bool rack = RE4VRShared::get()->vr_slide_rack_active;
    if (rack) {
        target = m_th.blend;
    }
    m_th.active = (target == 1.0f) && !rack;
    if (m_th.blend < target) {
        m_th.blend = std::min(m_th.blend + m_th.blend_speed, target);
    } else if (m_th.blend > target) {
        m_th.blend = std::max(m_th.blend - m_th.blend_speed, target);
    }
    if (m_th.blend <= 0 || !m_wep.rel_rot) {
        return;
    }
    const auto wrot = glm::normalize(m_rh_rot * *m_wep.rel_rot);
    auto cur_fwd = re4vr::quat_rotate(wrot, Vector3f{0, 0, 1});
    if (glm::length2(cur_fwd) < 1e-12f) {
        return;
    }
    cur_fwd = glm::normalize(cur_fwd);
    auto des = lh_raw - m_rh_world;
    if (glm::length2(des) < 1e-10f) {
        return;
    }
    des = glm::normalize(des);
    const auto swing_full = glm::normalize(glm::rotation(cur_fwd, des));
    if (!m_th.engage0) {
        m_th.engage0 = swing_full;
    }
    const auto swing_rel = glm::normalize(swing_full * glm::conjugate(*m_th.engage0));
    const auto swing = slerp_q(glm::quat{1, 0, 0, 0}, swing_rel, m_th.blend);
    m_rh_rot = glm::normalize(swing * m_rh_rot);
}

void RE4VRMotion::attach_right_hand(const CamData& cam, const VrData& vr) {
    if (!m_rh) {
        return;
    }
    auto [ctrl_pos, ctrl_rot] = controller_to_world(vr.rh_pos, vr.rh_rot, cam);
    m_rh_aim = ctrl_rot;
    RE4VRShared::get()->vr_rh_ctrl_raw = ctrl_pos;
    glm::quat hand_rot = ctrl_rot;
    auto hand_pos = apply_hand_offset(ctrl_pos, ctrl_rot, get_weapon_offset("-1"), hand_rot);
    const auto& wo = get_weapon_offset(m_weapon_key);
    if (m_weapon_key != "-1" && m_weapon_key != "none" && m_weapon_key != "5403" && m_weapon_key != "5405") {
        hand_pos = apply_hand_offset(hand_pos, hand_rot, wo, hand_rot);
    }
    if (m_cfg.smooth_rot > 0 && m_smooth_rh_r) {
        hand_rot = slerp_q(*m_smooth_rh_r, hand_rot, 1.0f - m_cfg.smooth_rot);
    }
    if (m_cfg.smooth_pos > 0 && m_smooth_rh_p) {
        hand_pos = lerp3(*m_smooth_rh_p, hand_pos, 1.0f - m_cfg.smooth_pos);
    }
    m_smooth_rh_p = hand_pos;
    m_smooth_rh_r = hand_rot;
    hand_pos = clamp_hand_to_arm_reach(hand_pos, false);
    m_rh_world = hand_pos;
    m_rh_rot = hand_rot;
    m_rh_ok = true;
    apply_two_hand_aim(vr, cam);
    apply_pump_locks(cam);
    if (m_th.smooth_rot && is_two_hand_aim_weapon()) {
        float dot = glm::abs(glm::dot(*m_th.smooth_rot, m_rh_rot));
        if (dot < TWO_HAND_SNAP_COS) {
            m_rh_rot = slerp_q(*m_th.smooth_rot, m_rh_rot, TWO_HAND_SNAP_EASE);
        }
    }
    m_th.smooth_rot = m_rh_rot;
    if (auto rc = RE4VRShared::get()->vr_recoil_pos) {
        auto wq = m_rh_rot;
        if (m_wep.rel_rot) {
            wq = glm::normalize(m_rh_rot * *m_wep.rel_rot);
        }
        m_rh_world += re4vr::quat_rotate(wq, *rc);
        hand_pos = m_rh_world;
    }
    write_joint_pose(m_rh, m_rh_world, m_rh_rot);
    m_rh_jpos = m_rh_world;
    m_rh_jrot = m_rh_rot;
}

glm::quat RE4VRMotion::knife_flip_spin(const glm::quat& wrot) {
    if (!RE4VRShared::get()->re4_knife_equipped) {
        m_flip_lerp = 0;
        m_flip_prev = 0;
        return wrot;
    }
    const float target = RE4VRShared::get()->vr_knife_flip ? 1.0f : 0.0f;
    if (m_flip_prev != target) {
        m_flip_prev = target;
        if (m_wep.go) {
            auto* scn = re4vr::get_component((::REManagedObject*)m_wep.go, "soundlib.SoundContainer");
            if (scn) {
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(scn, "trigger(System.UInt32)", KNIFE_FLIP_SND); });
            }
        }
    }
    const float spd = (float)RE4VRShared::get()->re4_knife_flip_speed.value_or(0.18);
    if (m_flip_lerp < target) {
        m_flip_lerp = std::min(target, m_flip_lerp + spd);
    } else if (m_flip_lerp > target) {
        m_flip_lerp = std::max(target, m_flip_lerp - spd);
    }
    if (m_flip_lerp <= 0.0001f) {
        return wrot;
    }
    return glm::normalize(wrot * re4vr::quat_euler_yxz_deg(180.0f * m_flip_lerp, 0, 0));
}

void RE4VRMotion::attach_weapon() {
    if (RE4VRShared::get()->re4_merc_bow_pinned || RE4VRShared::get()->re4_knife_flying) {
        return;
    }
    if (!m_wep.tf || !m_wep.rel_pos || !m_wep.rel_rot) {
        return;
    }
    Vector3f hand_world;
    glm::quat hand_rot;
    Vector3f rel_pos = *m_wep.rel_pos;
    glm::quat rel_rot = *m_wep.rel_rot;
    const bool left_knife = RE4VRShared::get()->re4_knife_hand.value_or("") == "left";
    Vector3f lh_fb = m_lh_world;
    glm::quat lh_fr = m_lh_rot;
    bool lh_use = m_lh_ok;
    if (left_knife && !lh_use) {
        if (auto p = RE4VRShared::get()->vr_lh_world) {
            lh_fb = *p;
            lh_use = true;
        }
        if (auto r = RE4VRShared::get()->vr_lh_rot) {
            lh_fr = *r;
        }
    }
    if (left_knife && lh_use) {
        hand_world = lh_fb;
        hand_rot = lh_fr;
        rel_pos.x = -rel_pos.x;
        rel_rot = glm::quat{rel_rot.w, -rel_rot.x, rel_rot.y, rel_rot.z};
        if (m_wep.id) {
            Vector3f pos{}, euler{};
            if (RE4VRWeapons2::get()->knife_lh_off(*m_wep.id, pos, euler)) {
                rel_pos += pos;
                if (euler.x != 0 || euler.y != 0 || euler.z != 0) {
                    rel_rot = glm::normalize(rel_rot * re4vr::quat_euler_yxz_deg(euler.x, euler.y, euler.z));
                }
            }
        }
    } else {
        if (!m_rh_ok) {
            return;
        }
        hand_world = m_rh_world;
        hand_rot = m_rh_rot;
        auto add_wep = [&](const std::string& key) {
            auto& o = get_weapon_offset(key);
            rel_pos += Vector3f{o.px, o.py, o.pz};
            if (o.rx != 0 || o.ry != 0 || o.rz != 0) {
                rel_rot = glm::normalize(rel_rot * re4vr::quat_euler_yxz_deg(o.rx, o.ry, o.rz));
            }
        };
        if (m_wep.matilda_stock) {
            add_wep("4004_stockwep");
        }
        if (m_wep.id == 5403) {
            add_wep("5403");
        }
        if (m_wep.id == 5405) {
            add_wep("5405");
        }
        if (m_wep.id == 6102) {
            add_wep("6102_bowwep");
        }
        if (m_wep.id && knife_id(*m_wep.id)) {
            add_wep(std::to_string(*m_wep.id) + (RE4VRShared::get()->re4_char_now.value_or("") == "ada" ? "_knifewep@ada" : "_knifewep"));
        }
    }
    auto wpos = hand_world + re4vr::quat_rotate(hand_rot, rel_pos);
    auto wrot = glm::normalize(hand_rot * rel_rot);
    if (RE4VRShared::get()->vr_pump_anim_active) {
        float frac = 0.f;
        if (auto p = RE4VRShared::get()->vr_pump_anim_progress) {
            frac = std::max(0.f, (float)*p);
        } else {
            const double now = re4vr::now();
            if (!m_skull_spin_t0) {
                m_skull_spin_t0 = now;
            }
            frac = (float)((now - *m_skull_spin_t0) / 0.40);
        }
        constexpr float SKULL_SPIN_DIR = -1.f;
        const float h = (SKULL_SPIN_DIR * frac * 2.0f * 3.14159265f) * 0.5f;
        wrot = glm::normalize(wrot * glm::quat{std::cos(h), std::sin(h), 0, 0});
    } else {
        m_skull_spin_t0.reset();
    }
    wrot = knife_flip_spin(wrot);
    RE4VRWeapons2::get()->apply_wildwest(wpos, wrot);
    if (RE4VRShared::get()->re4_knife_equipped && m_flip_lerp > 0.0001f && m_wep.id) {
        const bool is_left = left_knife;
        float px = 0, py = 0, pz = 0;
        if (is_left) {
            Vector3f fp{};
            if (RE4VRWeapons2::get()->knife_lh_flip_pos(*m_wep.id, fp)) {
                px = fp.x;
                py = fp.y;
                pz = fp.z;
            }
        } else {
            const bool ada = RE4VRShared::get()->re4_char_now.value_or("") == "ada";
            auto& mp = ada ? m_flip_pos_ada : m_flip_pos;
            if (auto it = mp.find(*m_wep.id); it != mp.end()) {
                px = it->second.x;
                py = it->second.y;
                pz = it->second.z;
            } else {
                px = (float)RE4VRShared::get()->re4_knife_flip_pos_x.value_or(0);
                py = (float)RE4VRShared::get()->re4_knife_flip_pos_y.value_or(0);
                pz = (float)RE4VRShared::get()->re4_knife_flip_pos_z.value_or(0);
            }
        }
        float ox = px * m_flip_lerp;
        float oy = py * m_flip_lerp;
        float oz = pz * m_flip_lerp;
        if (!is_left && knife_id(*m_wep.id)) {
            const std::string kkey = std::to_string(*m_wep.id) + (RE4VRShared::get()->re4_char_now.value_or("") == "ada" ? "_knifewep@ada" : "_knifewep");
            auto& ko = get_weapon_offset(kkey);
            ox -= ko.px * m_flip_lerp;
            oy -= ko.py * m_flip_lerp;
            oz -= ko.pz * m_flip_lerp;
        }
        const glm::quat* fr = is_left ? &hand_rot : &m_rh_rot;
        if (ox != 0 || oy != 0 || oz != 0) {
            wpos += re4vr::quat_rotate(*fr, Vector3f{ox, oy, oz});
        }
    }
    if (m_wep.id) {
        Vector3f np{};
        glm::quat nr{};
        if (RE4VRMerc::get()->wep_apply(wpos, wrot, *m_wep.id, &hand_rot, np, nr)) {
            wpos = np;
            wrot = nr;
        }
    }
    sdk::set_transform_position(m_wep.tf, re4vr::v4(wpos));
    sdk::set_transform_rotation(m_wep.tf, wrot);
}

bool RE4VRMotion::pump_grip_weapon() const {
    return m_wep.id && (*m_wep.id == 4100 || *m_wep.id == 4101);
}
bool RE4VRMotion::switch_dock_weapon() const {
    return m_wep.id && (*m_wep.id == 4201 || *m_wep.id == 4202);
}
int RE4VRMotion::fire_mode_next(int32_t wid, int cur) const {
    if (wid == 4201) {
        return cur == 0 ? 1 : 0;
    }
    if (cur == 0) {
        return 1;
    }
    if (cur == 1) {
        return 2;
    }
    return 0;
}
RE4VRMotion::SupportOff* RE4VRMotion::soff(std::unordered_map<std::string, SupportOff>& m, const std::string& key) {
    auto it = m.find(key);
    return it == m.end() ? nullptr : &it->second;
}
::REJoint* RE4VRMotion::get_pump_joint() {
    if (!pump_grip_weapon() || !m_wep.tf || !m_wep.id) {
        return nullptr;
    }
    auto nm = RE4VRShared::get()->re4_rack_joint_name;
    auto wid = RE4VRShared::get()->re4_rack_joint_wid;
    if (!nm || nm->empty() || !wid || (int32_t)*wid != *m_wep.id) {
        return nullptr;
    }
    return re4vr::joint_by_name(m_wep.tf, *nm);
}
::REJoint* RE4VRMotion::get_switch_joint() {
    if (!m_wep.tf || !m_wep.id) {
        return nullptr;
    }
    const char* cands[2]{};
    int n = 0;
    if (*m_wep.id == 4202) {
        cands[0] = "_05";
        cands[1] = "joint_05";
        n = 2;
    } else if (*m_wep.id == 4201) {
        cands[0] = "_06";
        cands[1] = "joint_06";
        n = 2;
    } else {
        return nullptr;
    }
    if (!m_switch_jn.empty() && m_switch_jn_wid == m_wep.id) {
        if (auto* j = re4vr::joint_by_name(m_wep.tf, m_switch_jn)) {
            return j;
        }
    }
    m_switch_jn.clear();
    for (int i = 0; i < n; ++i) {
        if (auto* j = re4vr::joint_by_name(m_wep.tf, cands[i])) {
            m_switch_jn = cands[i];
            m_switch_jn_wid = *m_wep.id;
            return j;
        }
    }
    return nullptr;
}

void RE4VRMotion::compute_grip_pull(const Vector3f& gp) {
    m_sup.grip_pull.reset();
    if (!m_wep.id || *m_wep.id != 4100 || !m_th.active || !m_rh_ok) {
        return;
    }
    auto lr = RE4VRShared::get()->vr_arm_chain_L_root;
    auto lm_o = RE4VRShared::get()->vr_arm_chain_L_maxreach;
    if (!lr || !lm_o) {
        return;
    }
    float lm = (float)*lm_o - 0.015f;
    if (lm <= 0.05f) {
        return;
    }
    auto wq = m_rh_rot;
    if (m_wep.rel_rot) {
        wq = glm::normalize(m_rh_rot * *m_wep.rel_rot);
    }
    auto ax = re4vr::quat_rotate(wq, Vector3f{0, 0, 1});
    const float al = glm::length(ax);
    if (al < 1e-6f) {
        return;
    }
    ax /= al;
    const auto mx = gp - m_th.give;
    const auto e = mx - *lr;
    const float ee = glm::dot(e, e);
    if (ee <= lm * lm) {
        return;
    }
    const float ea = glm::dot(e, ax);
    const float disc = ea * ea - ee + lm * lm;
    if (disc < 0) {
        return;
    }
    float t = ea - std::sqrt(disc);
    if (t <= 0) {
        return;
    }
    t = std::min(t, 0.5f);
    m_sup.grip_pull = -ax * t;
}

void RE4VRMotion::apply_pump_locks(const CamData& cam) {
    const bool pumping = RE4VRShared::get()->vr_shotgun_pump_active || RE4VRShared::get()->vr_slide_rack_active;
    Vector3f want{0, 0, 0};
    if (m_sup.grip_pull && m_wep.id == 4100 && !pumping) {
        want = *m_sup.grip_pull;
    }
    const float k = 0.25f;
    m_th.give += (want - m_th.give) * k;
    if (glm::length2(m_th.give) > 1e-10f) {
        m_rh_world += m_th.give;
    }
    const bool rack_no_z = RE4VRShared::get()->vr_shotgun_pump_active
        || (RE4VRShared::get()->vr_slide_rack_active && is_two_hand_aim_weapon());
    if (rack_no_z && m_rh_ok) {
        auto wq = m_rh_rot;
        if (m_wep.rel_rot) {
            wq = glm::normalize(m_rh_rot * *m_wep.rel_rot);
        }
        auto ax = re4vr::quat_rotate(wq, Vector3f{0, 0, 1});
        if (!m_th.pump_ref) {
            m_th.pump_ref = m_rh_world;
            m_th.pump_cam = cam.pos;
        } else {
            Vector3f ox{0, 0, 0};
            if (m_th.pump_cam) {
                ox = cam.pos - *m_th.pump_cam;
            }
            const auto dlt = m_rh_world - (*m_th.pump_ref + ox);
            const float d = glm::dot(dlt, ax);
            float exd = 0;
            Vector3f sx{0, 0, 0};
            if (m_wep.id == 4100 && RE4VRShared::get()->vr_shotgun_pump_active) {
                sx = re4vr::quat_rotate(wq, Vector3f{1, 0, 0});
                exd = glm::dot(dlt, sx);
            }
            if (d != 0 || exd != 0) {
                m_rh_world -= ax * d;
                if (exd != 0) {
                    m_rh_world -= sx * exd;
                }
            }
        }
    } else {
        m_th.pump_ref.reset();
        m_th.pump_cam.reset();
    }
}

void RE4VRMotion::elevator_unparent() {
    RE4VRShared::get()->re4_on_elevator2 = false;
    auto* btf = re4vr::body_transform();
    if (!btf) {
        return;
    }
    auto* t = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(btf, "get_Parent"); }).value_or(nullptr);
    bool on = false;
    for (int i = 0; i < 5 && t; ++i) {
        auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(t, "get_GameObject"); }).value_or(nullptr);
        if (go) {
            if (re4vr::get_component((::REManagedObject*)go, "chainsaw.GmElevator")) {
                on = true;
                break;
            }
            const auto nm = re4vr::go_name((::REManagedObject*)go);
            static const std::string k_elev = "\xE3\x82\xA8\xE3\x83\xAC\xE3\x83\x99\xE3\x83\xBC\xE3\x82\xBF";
            static const std::string k_lift = "\xE3\x83\xAA\xE3\x83\x95\xE3\x83\x88";
            if (nm.find(k_elev) != std::string::npos || nm.find(k_lift) != std::string::npos) {
                on = true;
                break;
            }
        }
        t = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(t, "get_Parent"); }).value_or(nullptr);
    }
    if (!on) {
        return;
    }
    RE4VRShared::get()->re4_on_elevator2 = true;
    if (re4vr::safe([&] { return sdk::call_object_func_easy<bool>(btf, "get_Valid"); }).value_or(false)) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(btf, "set_Parent", (::RETransform*)nullptr); });
    }
}

void RE4VRMotion::repin_left() {
    if (!m_lh || !m_lh_ok) {
        return;
    }
    if (!pump_grip_weapon()) {
        return;
    }
    if (m_sup.blend_factor < 0.999f) {
        return;
    }
    if (RE4VRShared::get()->vr_slide_dock_blend_factor.value_or(0) > 0.001) {
        return;
    }
    if (RE4VRShared::get()->re4_knife_hand.value_or("") == "left") {
        return;
    }
    auto sp = get_support_pose();
    if (!sp) {
        return;
    }
    write_joint_pose(m_lh, sp->first, sp->second);
    m_lh_jpos = sp->first;
    m_lh_jrot = sp->second;
    m_lh_world = sp->first;
    m_lh_rot = sp->second;
    RE4VRShared::get()->vr_lh_joint_pos = sp->first;
    RE4VRShared::get()->vr_lh_joint_rot = sp->second;
}

std::optional<std::pair<Vector3f, glm::quat>> RE4VRMotion::get_support_pose() {
    if (!m_rh_ok) {
        return std::nullopt;
    }
    const auto& key = m_weapon_key;
    auto blend_off = [&](const SupportOff& idle, const SupportOff* aim) {
        SupportOff r = idle;
        if (aim && m_sup.aim_blend > 0.001f) {
            const float b = m_sup.aim_blend;
            r.px += (aim->px - r.px) * b;
            r.py += (aim->py - r.py) * b;
            r.pz += (aim->pz - r.pz) * b;
            r.rx += (aim->rx - r.rx) * b;
            r.ry += (aim->ry - r.ry) * b;
            r.rz += (aim->rz - r.rz) * b;
        }
        return r;
    };
    if (m_sup.switch_docked || (m_sup.switch_blend_lock && m_sup.blend_factor > 0)) {
        if (auto* sw = soff(m_support_off_switch, key)) {
            auto a = blend_off(*sw, soff(m_support_off_switch_aim, key));
            bool use_endpoints = false;
            if (auto* sw2 = soff(m_support_off_switch2, key)) {
                use_endpoints = true;
                auto b = blend_off(*sw2, soff(m_support_off_switch2_aim, key));
                const float t = std::clamp(m_sup.switch2_blend, 0.0f, 1.0f);
                a.px += (b.px - a.px) * t;
                a.py += (b.py - a.py) * t;
                a.pz += (b.pz - a.pz) * t;
                a.rx += (b.rx - a.rx) * t;
                a.ry += (b.ry - a.ry) * t;
                a.rz += (b.rz - a.rz) * t;
            }
            auto pos = m_rh_world + re4vr::quat_rotate(m_rh_rot, Vector3f{a.px, a.py, a.pz});
            auto rot = m_rh_rot;
            if (a.rx != 0 || a.ry != 0 || a.rz != 0) {
                rot = glm::normalize(m_rh_rot * re4vr::quat_euler_yxz_deg(a.rx, a.ry, a.rz));
            }
            const float ba = m_sup.burst_anim;
            if (!use_endpoints && std::abs(ba) > 0.05f) {
                if (auto* j = get_switch_joint()) {
                    const auto pivot = re4vr::v3(sdk::get_joint_position(j));
                    const auto jr = sdk::get_joint_rotation(j);
                    const auto jm = glm::mat3_cast(jr);
                    Vector3f axis{jm[0].x, jm[0].y, jm[0].z};
                    const float al = glm::length(axis);
                    if (al > 1e-5f) {
                        axis /= al;
                        const float h = glm::radians(ba) * 0.5f;
                        const float s = std::sin(h);
                        glm::quat rq{std::cos(h), axis.x * s, axis.y * s, axis.z * s};
                        pos = pivot + re4vr::quat_rotate(rq, pos - pivot);
                        rot = glm::normalize(rq * rot);
                    }
                }
            }
            return std::pair{pos, rot};
        }
    }
    SupportOff a{};
    if (auto* so = soff(m_support_off, key)) {
        a = *so;
    }
    a = blend_off(a, soff(m_support_off_aim, key));
    if (pump_grip_weapon() && a.grip_on) {
        if (auto* pj = get_pump_joint()) {
            auto jp = re4vr::v3(sdk::get_joint_position(pj));
            auto jr = sdk::get_joint_rotation(pj);
            if (!m_sup.grip_off_wid || *m_sup.grip_off_wid != *m_wep.id) {
                m_sup.grip_off.reset();
                m_sup.grip_rhprev.reset();
                m_sup.grip_off_wid = *m_wep.id;
            }
            float gz = a.grip_z;
            if (a.grip_back > 0 || a.grip_fwd > 0) {
                if (auto lc = RE4VRShared::get()->vr_lh_ctrl_world) {
                    const auto rl = glm::conjugate(jr) * (*lc - jp);
                    gz = std::clamp(rl.z, gz - a.grip_back, gz + a.grip_fwd);
                }
            }
            Vector3f gv{a.grip_x, a.grip_y, gz};
            auto jps = jp;
            if (a.grip_anchor) {
                float mv = 999.0f;
                if (m_sup.grip_rhprev) {
                    mv = glm::length(m_rh_world - *m_sup.grip_rhprev);
                }
                m_sup.grip_rhprev = m_rh_world;
                if (!m_sup.grip_off || mv < 0.006f) {
                    m_sup.grip_off = glm::conjugate(m_rh_rot) * (jp - m_rh_world);
                }
                if (m_sup.grip_off) {
                    jps = m_rh_world + re4vr::quat_rotate(m_rh_rot, *m_sup.grip_off);
                }
            }
            auto jrg = jr;
            if (a.grip_noroll) {
                const float n = std::sqrt(jr.w * jr.w + jr.z * jr.z);
                if (n >= 1e-6f) {
                    glm::quat tw{jr.w / n, 0, 0, jr.z / n};
                    jrg = glm::normalize(jr * glm::conjugate(tw));
                }
            }
            auto gp = jps + re4vr::quat_rotate(jrg, gv);
            compute_grip_pull(gp);
            auto grot = m_rh_rot;
            if (a.rx != 0 || a.ry != 0 || a.rz != 0) {
                grot = glm::normalize(m_rh_rot * re4vr::quat_euler_yxz_deg(a.rx, a.ry, a.rz));
            }
            return std::pair{gp, grot};
        }
    }
    auto pos = m_rh_world + re4vr::quat_rotate(m_rh_rot, Vector3f{a.px, a.py, a.pz});
    auto rot = m_rh_rot;
    if (a.rx != 0 || a.ry != 0 || a.rz != 0) {
        rot = glm::normalize(m_rh_rot * re4vr::quat_euler_yxz_deg(a.rx, a.ry, a.rz));
    }
    return std::pair{pos, rot};
}

void RE4VRMotion::update_support_dock(const Vector3f& free_pos, const std::optional<Vector3f>& support_pos) {
    const bool aiming = RE4VRShared::get()->vr_aim_input;
    const float at = aiming ? 1.0f : 0.0f;
    float sp_in = 0.18f, sp_out = 0.18f;
    if (m_sup.switch_docked) {
        if (auto* swa = soff(m_support_off_switch_aim, m_weapon_key)) {
            sp_in = swa->blend_in;
            sp_out = swa->blend_out;
        }
    } else if (auto* aimcfg = soff(m_support_off_aim, m_weapon_key)) {
        sp_in = aimcfg->blend_in;
        sp_out = aimcfg->blend_out;
    }
    if (m_sup.aim_blend < at) {
        m_sup.aim_blend = std::min(at, m_sup.aim_blend + sp_in);
    } else if (m_sup.aim_blend > at) {
        m_sup.aim_blend = std::max(at, m_sup.aim_blend - sp_out);
    }
    const float b_tgt = m_sup.burst_active ? 1.0f : 0.0f;
    float lsp = 0.15f;
    if (auto* sw2 = soff(m_support_off_switch2, m_weapon_key)) {
        lsp = sw2->lerp > 0 ? sw2->lerp : 0.15f;
    }
    if (m_sup.switch2_blend < b_tgt) {
        m_sup.switch2_blend = std::min(b_tgt, m_sup.switch2_blend + lsp);
    } else if (m_sup.switch2_blend > b_tgt) {
        m_sup.switch2_blend = std::max(b_tgt, m_sup.switch2_blend - lsp);
    }
    if (m_sup.blend_factor <= 0) {
        m_sup.switch_blend_lock = false;
    }
    const bool needs_rack = RE4VRShared::get()->vr_needs_rack;
    const bool blk_2h = RE4VRShared::get()->vr_block_two_hand;
    const bool pump_anim = RE4VRShared::get()->vr_pump_anim_active;
    const bool slide_dock = RE4VRShared::get()->vr_slide_dock_blend_factor.value_or(0) > 0.001;
    auto ramp_out = [&]() {
        m_sup.docked = false;
        m_sup.target_blend = 0;
        m_sup.blend_factor = std::max(0.0f, m_sup.blend_factor - m_sup.blend_speed);
    };
    if (needs_rack || blk_2h || pump_anim || slide_dock) {
        m_sup.switch_docked = false;
        m_sup.switch_latched = false;
        m_sup.prev_left_grip = false;
        m_sup.free_near = false;
        if (slide_dock && !(needs_rack || blk_2h || pump_anim)) {
            m_sup.docked = false;
        } else if (m_sup.docked || m_sup.blend_factor > 0) {
            ramp_out();
        }
        return;
    }
    if (!m_sup.enabled || !is_support_hand_weapon() || !support_pos) {
        m_sup.switch_docked = false;
        m_sup.switch_latched = false;
        m_sup.prev_left_grip = false;
        m_sup.free_near = false;
        if (m_sup.docked || m_sup.blend_factor > 0) {
            ramp_out();
        }
        return;
    }
    SupportOff off0{};
    if (auto* so = soff(m_support_off, m_weapon_key)) {
        off0 = *so;
    }
    const float dmin = std::min(glm::length(free_pos - *support_pos), glm::length(free_pos - m_rh_world));
    m_sup.free_near = dmin < (m_sup.free_near ? off0.undock_threshold : off0.dock_threshold);
    if (RE4VRShared::get()->vr_mag_in_hand) {
        m_sup.switch_docked = false;
        m_sup.switch_latched = false;
        m_sup.prev_left_grip = false;
        if (m_sup.docked || m_sup.blend_factor > 0) {
            ramp_out();
        }
        return;
    }
    SupportOff* sw = switch_dock_weapon() ? soff(m_support_off_switch, m_weapon_key) : nullptr;
    if (sw) {
        const bool grip = re4vr::grip_held(true);
        const auto switch_pos = m_rh_world + re4vr::quat_rotate(m_rh_rot, Vector3f{sw->px, sw->py, sw->pz});
        const float d_switch = glm::length(free_pos - switch_pos);
        if (grip && !m_sup.prev_left_grip) {
            m_sup.switch_latched = d_switch < sw->dock_dist;
            if (!m_sup.switch_latched) {
                m_sup.switch_blend_lock = false;
            }
        }
        if (!grip) {
            m_sup.switch_latched = false;
            m_sup.sw_consumed = false;
        }
        m_sup.prev_left_grip = grip;
        m_sup.switch_docked = grip && m_sup.switch_latched;
        if (m_sup.switch_docked && grip) {
            const bool trig = []() {
                auto& vr = VR::get();
                const auto act = vr->get_action_trigger();
                const auto joy = vr->get_left_joystick();
                return act && joy && vr->is_action_active(act, joy);
            }();
            if (trig && !m_sup.prev_switch_trigger && m_wep.id) {
                m_sup.fire_mode = fire_mode_next(*m_wep.id, m_sup.fire_mode);
                if (*m_wep.id == 4201) {
                    m_sup.switch_latched = false;
                    m_sup.sw_consumed = true;
                }
            }
            m_sup.prev_switch_trigger = trig;
        } else {
            m_sup.prev_switch_trigger = false;
        }
    } else {
        m_sup.switch_docked = false;
        m_sup.switch_latched = false;
        m_sup.prev_left_grip = false;
        m_sup.sw_consumed = false;
    }
    if (m_wep.id == 4201 && (m_sup.fire_mode < 0 || m_sup.fire_mode > 1)) {
        m_sup.fire_mode = 0;
    }
    if (m_wep.id == 4202 && (m_sup.fire_mode < 0 || m_sup.fire_mode > 2)) {
        m_sup.fire_mode = 0;
    }
    m_sup.burst_active = m_sup.fire_mode != 0;
    if (m_sup.fire_mode != m_sup.prev_fire_mode) {
        if (m_wep.go) {
            auto* scn = re4vr::get_component((::REManagedObject*)m_wep.go, "soundlib.SoundContainer");
            if (scn) {
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(scn, "trigger(System.UInt32)", 812850326u); });
            }
        }
        m_sup.prev_fire_mode = m_sup.fire_mode;
    }
    if (auto* sws = soff(m_support_off_switch, m_weapon_key)) {
        const float tgt_deg = m_sup.fire_mode == 2 ? sws->single_rot : (m_sup.fire_mode == 1 ? sws->burst_rot : 0.0f);
        const float ll = sws->lerp > 0 ? sws->lerp : 0.18f;
        m_sup.burst_anim += (tgt_deg - m_sup.burst_anim) * ll;
        if (std::abs(m_sup.burst_anim - tgt_deg) < 0.05f) {
            m_sup.burst_anim = tgt_deg;
        }
    }
    if (m_sup.switch_docked) {
        m_sup.switch_blend_lock = true;
        m_sup.docked = true;
        m_sup.target_blend = 1.0f;
        const float sbs = sw ? sw->blend_speed : 0.150f;
        if (m_sup.blend_factor < m_sup.target_blend) {
            m_sup.blend_factor = std::min(m_sup.target_blend, m_sup.blend_factor + sbs);
        } else if (m_sup.blend_factor > m_sup.target_blend) {
            m_sup.blend_factor = std::max(m_sup.target_blend, m_sup.blend_factor - sbs);
        }
        return;
    }
    if (m_th.active) {
        m_sup.docked = true;
        m_sup.target_blend = 1.0f;
        if (m_sup.blend_factor < m_sup.target_blend) {
            m_sup.blend_factor = std::min(m_sup.target_blend, m_sup.blend_factor + m_sup.blend_speed);
        }
        return;
    }
    const bool need_grip = m_wep.id && m_grip_dock.contains(*m_wep.id);
    if (need_grip && (!re4vr::grip_held(true) || m_sup.sw_consumed)) {
        if (m_sup.docked || m_sup.blend_factor > 0) {
            ramp_out();
        }
        return;
    }
    const float dt = off0.dock_threshold;
    const float ut = off0.undock_threshold;
    const float ds = glm::length(free_pos - *support_pos);
    const float dw = glm::length(free_pos - m_rh_world);
    const float eff = std::min(ds, dw);
    if (!m_sup.docked) {
        if (eff < dt) {
            m_sup.docked = true;
            m_sup.target_blend = 1.0f;
        }
    } else {
        bool grip_latched = need_grip && re4vr::grip_held(true);
        if (grip_latched) {
            auto l_root = RE4VRShared::get()->vr_arm_chain_L_root;
            auto l_max = RE4VRShared::get()->vr_arm_chain_L_maxreach;
            if (l_root && l_max && support_pos) {
                if (glm::length(*l_root - *support_pos) > (float)*l_max * m_sup.grip_latch_reach) {
                    grip_latched = false;
                }
            }
        }
        if (!grip_latched && ds > ut && dw > ut) {
            m_sup.docked = false;
            m_sup.target_blend = 0;
        }
    }
    if (m_sup.blend_factor < m_sup.target_blend) {
        m_sup.blend_factor = std::min(m_sup.target_blend, m_sup.blend_factor + m_sup.blend_speed);
    } else if (m_sup.blend_factor > m_sup.target_blend) {
        m_sup.blend_factor = std::max(m_sup.target_blend, m_sup.blend_factor - m_sup.blend_speed);
    }
}

void RE4VRMotion::attach_left_hand(const CamData& cam, const VrData& vr, bool update_dock) {
    if (!m_lh) {
        return;
    }
    auto [ctrl_pos, ctrl_rot] = controller_to_world(vr.lh_pos, vr.lh_rot, cam);
    RE4VRShared::get()->vr_lh_ctrl_raw = ctrl_pos;
    glm::quat hand_rot = ctrl_rot;
    auto hand_pos = apply_hand_offset(ctrl_pos, ctrl_rot, m_hand_l, hand_rot);
    if (m_cfg.smooth_rot > 0 && m_smooth_lh_r) {
        hand_rot = slerp_q(*m_smooth_lh_r, hand_rot, 1.0f - m_cfg.smooth_rot);
    }
    if (m_cfg.smooth_pos > 0 && m_smooth_lh_p) {
        hand_pos = lerp3(*m_smooth_lh_p, hand_pos, 1.0f - m_cfg.smooth_pos);
    }
    m_smooth_lh_p = hand_pos;
    m_smooth_lh_r = hand_rot;
    RE4VRShared::get()->vr_lh_ctrl_world = hand_pos;
    auto sp = get_support_pose();
    if (sp) {
        RE4VRShared::get()->vr_support_hand_world_pos = sp->first;
        RE4VRShared::get()->vr_support_hand_world_rot = sp->second;
    }
    if (update_dock) {
        update_support_dock(hand_pos, sp ? std::optional{sp->first} : std::nullopt);
    }
    if (m_sup.blend_factor > 0 && sp) {
        if (m_sup.blend_factor >= 1.0f) {
            hand_pos = sp->first;
            hand_rot = sp->second;
        } else {
            hand_pos = lerp3(hand_pos, sp->first, m_sup.blend_factor);
            hand_rot = slerp_q(hand_rot, sp->second, m_sup.blend_factor);
        }
    }
    const float slide_b = (float)RE4VRShared::get()->vr_slide_dock_blend_factor.value_or(0);
    if (!m_sup.docked && slide_b <= 0.001f) {
        hand_pos = clamp_hand_to_arm_reach(hand_pos, true);
    } else if (m_th.active && !(m_wep.id && *m_wep.id == 4100)) {
        hand_pos = clamp_hand_to_arm_reach(hand_pos, true);
    }
    m_lh_world = hand_pos;
    m_lh_rot = hand_rot;
    m_lh_ok = true;
    write_joint_pose(m_lh, hand_pos, hand_rot);
    m_lh_jpos = hand_pos;
    m_lh_jrot = hand_rot;
}

void RE4VRMotion::knife_ks_restore_native() {
    if (!RE4VRShared::get()->re4_knife_equipped) {
        return;
    }
    if (RE4VRShared::get()->vr_knife_flip) {
        RE4VRShared::get()->re4_knife_flip_pre_ks = true;
    }
    m_flip_lerp = 0;
    m_flip_prev = 0;
    RE4VRShared::get()->vr_knife_flip = false;
    if (m_rh && m_wep.tf && m_wep.rel_pos && m_wep.rel_rot) {
        auto hw = sdk::get_joint_position(m_rh);
        auto hr = sdk::get_joint_rotation(m_rh);
        auto wpos = re4vr::v3(hw) + re4vr::quat_rotate(hr, *m_wep.rel_pos);
        auto wrot = glm::normalize(hr * *m_wep.rel_rot);
        sdk::set_transform_position(m_wep.tf, re4vr::v4(wpos));
        sdk::set_transform_rotation(m_wep.tf, wrot);
    }
}

bool RE4VRMotion::native_reload_active() {
    bool r = false;
    auto wid = get_equip_weapon_id();
    if (wid && *wid == 4002) {
        auto* go = re4vr::body_game_object();
        auto* m = go ? re4vr::get_component((::REManagedObject*)go, "via.motion.MotionFsm2") : nullptr;
        if (m) {
            for (int layer = 0; layer <= 6; ++layer) {
                auto* n = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(m, "getCurrentNodeName", layer); }).value_or(nullptr);
                if (n && re4vr::obj_name(n).find("RELOAD") != std::string::npos) {
                    r = true;
                    break;
                }
            }
        }
    }
    RE4VRShared::get()->vr_red9_reloading = r;
    return r;
}

void RE4VRMotion::update_knife_swing() {
    const double now = re4vr::now();
    if (RE4VRShared::get()->vr_knife_flip && RE4VRCrosshair::get()->is_finisher_prompt()) {
        m_knife_swing = false;
        m_swing_last.reset();
        RE4VRShared::get()->vr_knife_swing = false;
        return;
    }
    if (m_knife_swing && now >= m_swing_end) {
        m_knife_swing = false;
    }
    auto& vr = VR::get();
    if (!vr->is_hmd_active()) {
        m_swing_last.reset();
        RE4VRShared::get()->vr_knife_swing = m_knife_swing;
        return;
    }
    auto& ctrls = vr->get_controllers();
    const bool left = RE4VRShared::get()->re4_knife_hand.value_or("") == "left";
    const int cidx = left ? 0 : 1;
    if ((int)ctrls.size() <= cidx) {
        RE4VRShared::get()->vr_knife_swing = m_knife_swing;
        return;
    }
    if (m_swing_cidx != cidx) {
        m_swing_cidx = cidx;
        m_swing_last.reset();
    }
    const auto wp = re4vr::v3(vr->get_position(ctrls[cidx]));
    const float dt = (float)(now - m_swing_t);
    if (m_swing_last && dt > 0.001f && dt < 0.2f) {
        const auto d = wp - *m_swing_last;
        const float horiz = std::sqrt(d.x * d.x + d.z * d.z);
        float vel = glm::length(d) / dt;
        if (d.y > 0 && d.y > horiz) {
            vel = 0;
        }
        const float thr = (float)RE4VRShared::get()->re4_knife_swing_threshold.value_or(3.5);
        if (vel >= thr && now > m_swing_end) {
            m_knife_swing = true;
            m_swing_end = now + 0.18;
        }
    }
    m_swing_last = wp;
    m_swing_t = now;
    RE4VRShared::get()->vr_knife_swing = m_knife_swing;
}

void RE4VRMotion::apply_flashlight(const Vector3f& hp, const glm::quat& hr) {
    flashlight_tick(hp, hr);
}

void RE4VRMotion::apply_ada_lazy_pose() {
    const double now = re4vr::now();
    if ((now - m_ada_body_t) >= 0.5) {
        m_ada_body_t = now;
        m_ada_body = false;
        auto* body = re4vr::body_game_object();
        if (body) {
            m_ada_body = re4vr::go_name((::REManagedObject*)body) == "ch3a8z0_body";
        }
    }
    if (!m_ada_body) {
        return;
    }
    if (!is_two_hand_aim_weapon()) {
        return;
    }
    auto* s = RE4VRShared::get().get();
    if (s->vr_slide_rack_active || s->vr_mag_in_hand) {
        return;
    }
    if (s->re4_knife_hand == std::optional<std::string>{"left"} || s->re4_knife_left_clone) {
        return;
    }
    const float blend = 1.0f - m_sup.blend_factor;
    if (blend <= 0.001f) {
        return;
    }
    s->apply_reload_pose("ADAlazypose", blend);
}

void RE4VRMotion::apply_ada_flashlight() {
    if (!m_fl_enabled) {
        return;
    }
    const double now = re4vr::now();
    if (!m_ada_fl_tf || now - m_ada_fl_check > 1.0) {
        m_ada_fl_check = now;
        m_ada_fl_tf = nullptr;
        m_ada_fl_light_tf = nullptr;
        auto* btf = re4vr::body_transform();
        if (btf) {
            m_ada_fl_tf = re4vr::safe([&] {
                return sdk::call_object_func_easy<::RETransform*>(btf, "find", sdk::VM::create_managed_string(L"ac0000_00"));
            }).value_or(nullptr);
            if (m_ada_fl_tf) {
                m_ada_fl_light_tf = re4vr::safe([&] {
                    return sdk::call_object_func_easy<::RETransform*>(m_ada_fl_tf, "find", sdk::VM::create_managed_string(L"light"));
                }).value_or(nullptr);
            }
        }
    }
    if (!m_ada_fl_tf) {
        return;
    }
    auto cam = get_camera_data();
    if (!cam) {
        return;
    }
    const auto& o = m_fl_dock;
    auto fl_pos = cam->pos + re4vr::quat_rotate(cam->rot, Vector3f{o.pos_x, o.pos_y, o.pos_z});
    auto fl_rot = cam->rot;
    if (o.rot_pitch != 0 || o.rot_yaw != 0 || o.rot_roll != 0) {
        fl_rot = glm::normalize(cam->rot * re4vr::quat_euler_yxz_deg(o.rot_pitch, o.rot_yaw, o.rot_roll));
    }
    sdk::set_transform_position(m_ada_fl_tf, re4vr::v4(fl_pos));
    sdk::set_transform_rotation(m_ada_fl_tf, fl_rot);
    if (m_ada_fl_light_tf) {
        const auto& lo = m_fl_dock_light;
        auto lp = fl_pos + re4vr::quat_rotate(fl_rot, Vector3f{lo.pos_x, lo.pos_y, lo.pos_z});
        auto lr = fl_rot;
        if (lo.rot_pitch != 0 || lo.rot_yaw != 0 || lo.rot_roll != 0) {
            lr = glm::normalize(fl_rot * re4vr::quat_euler_yxz_deg(lo.rot_pitch, lo.rot_yaw, lo.rot_roll));
        }
        sdk::set_transform_position(m_ada_fl_light_tf, re4vr::v4(lp));
        sdk::set_transform_rotation(m_ada_fl_light_tf, lr);
    }
}

void RE4VRMotion::flashlight_tick(const Vector3f& hp, const glm::quat& hr) {
    if (!m_fl_enabled) {
        return;
    }
    if (RE4VRShared::get()->re4_char_now.value_or("") == "ada") {
        apply_ada_flashlight();
        return;
    }
    const double now = re4vr::now();
    if (!m_fl_tf || now - m_fl_check > 1.0) {
        m_fl_check = now;
        m_fl_tf = nullptr;
        m_fl_light_tf = nullptr;
        auto* btf = re4vr::body_transform();
        if (btf) {
            auto* found = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(btf, "find", sdk::VM::create_managed_string(L"ac0000_00")); }).value_or(nullptr);
            m_fl_tf = found;
            if (found) {
                m_fl_light_tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(found, "find", sdk::VM::create_managed_string(L"light")); }).value_or(nullptr);
            }
        }
    }
    if (!m_fl_tf) {
        return;
    }
    if (RE4VRShared::get()->re4_force_killswitch_scope || RE4VRShared::get()->re4_scope_wid) {
        if (RE4VRShared::get()->re4_scope_native || RE4VRShared::get()->re4_force_killswitch_scope) {
            auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(m_fl_tf, "get_GameObject"); }).value_or(nullptr);
            if (go) {
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(go, "set_DrawSelf", false); });
            }
            return;
        }
    }
    const bool busy = fl_left_hand_busy();
    FlOff off = busy ? m_fl_dock : m_fl_off;
    FlOff loff = busy ? m_fl_dock_light : m_fl_light;
    Vector3f base_pos = hp;
    glm::quat base_rot = hr;
    if (busy) {
        if (auto cam = get_camera_data()) {
            base_pos = cam->pos;
            auto& vr = VR::get();
            const auto hmd = glm::normalize(glm::quat{vr->get_rotation(0)});
            base_rot = glm::normalize(cam->rot * (vr->get_rotation_offset() * hmd));
        }
        auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(m_fl_tf, "get_GameObject"); }).value_or(nullptr);
        auto* mesh = go ? re4vr::get_component((::REManagedObject*)go, "via.render.Mesh") : nullptr;
        if (mesh) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "set_Enabled", false); });
        }
    } else {
        auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(m_fl_tf, "get_GameObject"); }).value_or(nullptr);
        if (go) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(go, "set_DrawSelf", true); });
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(go, "set_UpdateSelf", true); });
        }
    }
    auto fl_pos = base_pos + re4vr::quat_rotate(base_rot, Vector3f{off.pos_x, off.pos_y, off.pos_z});
    auto fl_rot = base_rot;
    if (off.rot_pitch != 0 || off.rot_yaw != 0 || off.rot_roll != 0) {
        fl_rot = glm::normalize(base_rot * re4vr::quat_euler_yxz_deg(off.rot_pitch, off.rot_yaw, off.rot_roll));
    }
    sdk::set_transform_position(m_fl_tf, re4vr::v4(fl_pos));
    sdk::set_transform_rotation(m_fl_tf, fl_rot);
    if (m_fl_light_tf) {
        auto lp = fl_pos + re4vr::quat_rotate(fl_rot, Vector3f{loff.pos_x, loff.pos_y, loff.pos_z});
        auto lr = fl_rot;
        if (loff.rot_pitch != 0 || loff.rot_yaw != 0 || loff.rot_roll != 0) {
            lr = glm::normalize(fl_rot * re4vr::quat_euler_yxz_deg(loff.rot_pitch, loff.rot_yaw, loff.rot_roll));
        }
        sdk::set_transform_position(m_fl_light_tf, re4vr::v4(lp));
        sdk::set_transform_rotation(m_fl_light_tf, lr);
    }
}

void RE4VRMotion::post_poses(bool lock_pass) {
    if (lock_pass) {
        return;
    }
    apply_ada_lazy_pose();
    apply_fl_hold_pose();
    apply_pistol_support_pose();
    if (auto name = RE4VRShared::get()->vr_rack_hand_pose) {
        RE4VRShared::get()->apply_reload_pose(*name, 1.0f);
    }
    apply_mag_hand_pose();
    apply_switch_hand_pose();
    apply_switch_rotation();
    apply_skullshaker_open_pose();
    knife_flip_finger_open();
    RE4VRWeapons2::get()->apply_wildwest_fingers();
    RE4VRWeapons2::get()->apply_left_knife_pose(nullptr);
    RE4VRMerc::get()->apply_bow_pose();
}

bool RE4VRMotion::fl_left_hand_busy() const {
    if (m_sup.blend_factor > 0.0f) {
        return true;
    }
    if (RE4VRShared::get()->vr_slide_rack_active || RE4VRShared::get()->vr_mag_in_hand) {
        return true;
    }
    if (RE4VRShared::get()->re4_knife_hand.value_or("") == "left" || RE4VRShared::get()->re4_knife_left_clone) {
        return true;
    }
    return false;
}

void RE4VRMotion::add_joint_local_euler(::REJoint* j, float rx, float ry, float rz) {
    if (!j || (rx == 0 && ry == 0 && rz == 0)) {
        return;
    }
    re4vr::pcall([&] {
        auto cur = sdk::get_joint_local_rotation(j);
        const auto ax = [](float a, float x, float y, float z) {
            const float h = glm::radians(a) * 0.5f;
            const float s = std::sin(h);
            return glm::quat{std::cos(h), x * s, y * s, z * s};
        };
        const auto add = ax(rz, 0, 0, 1) * ax(ry, 0, 1, 0) * ax(rx, 1, 0, 0);
        sdk::set_joint_local_rotation(j, glm::normalize(cur * add));
    });
}

void RE4VRMotion::apply_fl_hold_pose() {
    if (!m_fl_tf || !m_fl_enabled) {
        return;
    }
    if (get_equip_weapon_id() && knife_id(*get_equip_weapon_id()) && !m_fl_keep_knife) {
        return;
    }
    if (fl_left_hand_busy()) {
        return;
    }
    RE4VRShared::get()->apply_reload_pose("fl", 1.0f);
}

void RE4VRMotion::apply_pistol_support_pose() {
    if (!m_wep.id || !is_support_hand_weapon()) {
        return;
    }
    if (m_sup.blend_factor <= 0.0f) {
        return;
    }
    std::string pose;
    if (*m_wep.id == 4200) {
        pose = "TMPSUpport";
    } else if (*m_wep.id == 6106 || *m_wep.id == 6111) {
        pose = "ADArocket";
    } else if (m_grip_dock.contains(*m_wep.id)) {
        return;
    } else {
        pose = "pose1";
    }
    RE4VRShared::get()->apply_reload_pose(pose, m_sup.blend_factor);
}

void RE4VRMotion::apply_switch_hand_pose() {
    if (!m_sup.switch_docked) {
        return;
    }
    RE4VRShared::get()->apply_reload_pose("LE5SWITCH", m_sup.blend_factor > 0 ? m_sup.blend_factor : 1.0f);
    auto* sw = soff(m_support_off_switch, m_weapon_key);
    if (!sw || (sw->idx_rx == 0 && sw->idx_ry == 0 && sw->idx_rz == 0)) {
        return;
    }
    auto* tf = re4vr::body_transform();
    if (!tf) {
        return;
    }
    static const char* k_idx[] = {"L_IndexF1", "L_IndexF2", "L_IndexF3"};
    for (auto* n : k_idx) {
        add_joint_local_euler(re4vr::joint_by_name(tf, n), sw->idx_rx, sw->idx_ry, sw->idx_rz);
    }
}

void RE4VRMotion::apply_switch_rotation() {
    if (!m_wep.tf || !switch_dock_weapon()) {
        return;
    }
    auto* sw = soff(m_support_off_switch, m_weapon_key);
    if (!sw) {
        return;
    }
    const int fm = m_sup.fire_mode;
    float target = 0;
    if (fm == 2) {
        target = sw->single_rot;
    } else if (fm == 1) {
        target = sw->burst_rot;
    }
    const float ll = sw->lerp > 0 ? sw->lerp : 0.18f;
    m_sup.burst_anim += (target - m_sup.burst_anim) * ll;
    if (std::abs(m_sup.burst_anim - target) < 0.05f) {
        m_sup.burst_anim = target;
    }
    const float deg = m_sup.burst_anim;
    if (std::abs(deg) < 0.05f) {
        return;
    }
    if (auto* j = get_switch_joint()) {
        add_joint_local_euler(j, deg, 0, 0);
    }
}

void RE4VRMotion::apply_skullshaker_open_pose() {
    const bool open = RE4VRShared::get()->vr_break_open;
    const double now = re4vr::now();
    if (open != m_skull_open_prev) {
        m_skull_open_t = now;
    }
    m_skull_open_prev = open;
    if (m_skull_open_t < 0) {
        return;
    }
    const double dt = now - m_skull_open_t;
    constexpr double DUR = 0.2;
    constexpr double REL = 0.15;
    if (dt >= DUR + REL) {
        m_skull_open_t = -1;
        return;
    }
    float blend = 1.0f;
    if (dt > DUR) {
        blend = 1.0f - (float)((dt - DUR) / REL);
    }
    RE4VRShared::get()->apply_reload_pose("skullbreak", blend);
}

void RE4VRMotion::knife_flip_finger_open() {
    if (!RE4VRShared::get()->re4_knife_equipped) {
        return;
    }
    const bool is_left = RE4VRShared::get()->re4_knife_hand.value_or("") == "left";
    auto* hand = is_left ? m_lh : m_rh;
    if (!hand) {
        return;
    }
    const float lp = m_flip_lerp;
    const float bump = 4.0f * lp * (1.0f - lp);
    if (bump <= 0.001f) {
        return;
    }
    float deg = (float)RE4VRShared::get()->re4_knife_flip_finger_deg.value_or(-35.0);
    if (is_left) {
        deg = -deg;
    }
    auto* tf = re4vr::body_transform();
    if (!tf) {
        return;
    }
    static const char* k_r[] = {
        "R_Thumb1", "R_Thumb2", "R_Thumb3",
        "R_IndexF1", "R_IndexF2", "R_IndexF3",
        "R_MiddleF1", "R_MiddleF2", "R_MiddleF3",
        "R_RingF1", "R_RingF2", "R_RingF3",
        "R_PinkyF1", "R_PinkyF2", "R_PinkyF3",
    };
    for (auto* n : k_r) {
        std::string bn = n;
        if (is_left && bn.size() >= 2 && bn[0] == 'R' && bn[1] == '_') {
            bn[0] = 'L';
        }
        add_joint_local_euler(re4vr::joint_by_name(tf, bn), deg * bump, 0, 0);
    }
}

void RE4VRMotion::apply_mag_hand_pose() {
    auto name = RE4VRShared::get()->vr_mag_hand_pose;
    float blend = 1.0f;
    if (name && !name->empty()) {
        m_mag_fade.name = *name;
        m_mag_fade.trx = (float)RE4VRShared::get()->vr_mag_hand_trx.value_or(0);
        m_mag_fade.try_ = (float)RE4VRShared::get()->vr_mag_hand_try.value_or(0);
        m_mag_fade.trz = (float)RE4VRShared::get()->vr_mag_hand_trz.value_or(0);
        m_mag_fade.release_t.reset();
        blend = 1.0f;
    } else {
        if (!m_mag_fade.name) {
            return;
        }
        auto pb = RE4VRShared::get()->re4_push_blend;
        if (pb && *pb > 0.0) {
            m_mag_fade.release_t.reset();
            blend = 1.0f - (float)*pb;
            if (blend <= 0.001f) {
                m_mag_fade.name.reset();
                return;
            }
        } else {
            if (!m_mag_fade.release_t) {
                m_mag_fade.release_t = re4vr::now();
            }
            const double el = re4vr::now() - *m_mag_fade.release_t;
            const float fd = (float)RE4VRShared::get()->re4_pose_fade_dur.value_or(0.10);
            if (fd <= 0.001f || el >= fd) {
                m_mag_fade.name.reset();
                return;
            }
            blend = 1.0f - (float)(el / fd);
        }
    }
    RE4VRShared::get()->apply_reload_pose(*m_mag_fade.name, blend);
    const float trx = m_mag_fade.trx * blend;
    const float try_ = m_mag_fade.try_ * blend;
    const float trz = m_mag_fade.trz * blend;
    if (trx != 0 || try_ != 0 || trz != 0) {
        auto* tf = re4vr::body_transform();
        if (tf) {
            add_joint_local_euler(re4vr::joint_by_name(tf, "L_Thumb1"), trx, try_, trz);
        }
    }
}

void RE4VRMotion::publish_globals() {
    if (m_rh_ok) {
        RE4VRShared::get()->vr_rh_world = m_rh_world;
        RE4VRShared::get()->vr_rh_rot = m_rh_rot;
        RE4VRShared::get()->vr_rh_aim_rot = m_rh_aim;
    }
    if (m_lh_ok) {
        RE4VRShared::get()->vr_lh_world = m_lh_world;
        RE4VRShared::get()->vr_lh_rot = m_lh_rot;
    }
    RE4VRShared::get()->vr_support_hand_docked = m_sup.docked;
    RE4VRShared::get()->vr_support_blend_factor = m_sup.blend_factor;
    RE4VRShared::get()->vr_dbg_fire_mode = m_sup.fire_mode;
    RE4VRShared::get()->vr_dbg_switch_docked = m_sup.switch_docked;
    if (m_wep.id) {
        RE4VRShared::get()->vr_dbg_wep_id = *m_wep.id;
    } else {
        RE4VRShared::get()->vr_dbg_wep_id.reset();
    }
    if (m_rh_jpos) {
        RE4VRShared::get()->vr_rh_joint_pos = *m_rh_jpos;
    }
    if (m_rh_jrot) {
        RE4VRShared::get()->vr_rh_joint_rot = *m_rh_jrot;
    }
    if (m_lh_jpos) {
        RE4VRShared::get()->vr_lh_joint_pos = *m_lh_jpos;
    }
    if (m_lh_jrot) {
        RE4VRShared::get()->vr_lh_joint_rot = *m_lh_jrot;
    }
}

void RE4VRMotion::tick(bool late) {
    elevator_unparent();
    if (native_reload_active()) {
        release_motion_targets();
        m_smooth_rh_p.reset();
        m_smooth_rh_r.reset();
        m_smooth_lh_p.reset();
        m_smooth_lh_r.reset();
        return;
    }
    if (is_killswitch_active()) {
        knife_ks_restore_native();
        release_motion_targets();
        m_smooth_rh_p.reset();
        m_smooth_rh_r.reset();
        m_smooth_lh_p.reset();
        m_smooth_lh_r.reset();
        restore_hands_native();
        return;
    }
    if (RE4VRShared::get()->re4_knife_flip_pre_ks) {
        RE4VRShared::get()->re4_knife_flip_pre_ks = false;
        if (RE4VRShared::get()->re4_knife_equipped) {
            RE4VRShared::get()->vr_knife_flip = true;
            m_flip_lerp = 1.0f;
            m_flip_prev = 1.0f;
        }
    }
    auto& vr = VR::get();
    if (!m_init) {
        if (vr->get_controllers().size() >= 2) {
            m_init = true;
            m_rh = m_lh = nullptr;
            m_standing_set = false;
            if (vr->is_openxr_loaded()) {
                m_runtime = "openxr";
                m_openxr = true;
            } else if (vr->is_openvr_loaded()) {
                m_runtime = "openvr";
                m_openxr = false;
            }
            load_config();
        }
        return;
    }
    auto cam = get_camera_data();
    auto vrd = get_vr_data();
    if (!cam || !vrd) {
        return;
    }
    m_standing = re4vr::v3(vr->get_standing_origin());
    m_standing_set = true;
    find_joints();
    find_weapon();
    if (late && m_wep.tf && !m_wep.frozen && m_rh && m_wep.calib_wait <= 0 && m_wep.calib_sample > 0) {
        auto hp = sdk::get_joint_position(m_rh);
        auto hr = sdk::get_joint_rotation(m_rh);
        auto wp = sdk::get_transform_position(m_wep.tf);
        auto wr = sdk::get_transform_rotation(m_wep.tf);
        const auto inv = glm::conjugate(hr);
        m_wep.rel_pos = re4vr::quat_rotate(inv, re4vr::v3(wp) - re4vr::v3(hp));
        m_wep.rel_rot = glm::normalize(inv * wr);
        --m_wep.calib_sample;
        if (m_wep.calib_sample <= 0 && m_wep.id) {
            WepRel r;
            r.px = m_wep.rel_pos->x;
            r.py = m_wep.rel_pos->y;
            r.pz = m_wep.rel_pos->z;
            r.qx = m_wep.rel_rot->x;
            r.qy = m_wep.rel_rot->y;
            r.qz = m_wep.rel_rot->z;
            r.qw = m_wep.rel_rot->w;
            m_weapon_rel[rel_key(*m_wep.id)] = r;
            m_wep.frozen = true;
            save_config();
        }
    } else if (late && m_wep.calib_wait > 0) {
        --m_wep.calib_wait;
    }
    m_weapon_key = current_weapon_key();
    m_wep.matilda_stock = false;
    if (m_weapon_key == "4004" && m_wep.go) {
        auto* mesh = re4vr::get_component((::REManagedObject*)m_wep.go, "via.render.Mesh");
        if (mesh) {
            m_wep.matilda_stock = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(mesh, "getPartsEnable", 11); }).value_or(false);
        }
    }
    const bool lock_pass = !late;
    m_rh_ok = m_lh_ok = false;
    bool changing = m_was_changing;
    if (late) {
        changing = false;
        if (auto* go = re4vr::body_game_object()) {
            auto* fsm = re4vr::get_component((::REManagedObject*)go, "via.motion.MotionFsm2");
            auto* node = fsm ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(fsm, "getCurrentNodeName", 4); }).value_or(nullptr) : nullptr;
            if (node && re4vr::obj_name(node).find("ChangeWeapon") != std::string::npos) {
                changing = true;
            }
        }
        m_was_changing = changing;
        m_wep.changing = changing;
    }
    const bool pin = RE4VRShared::get()->vr_wsw_pin;
    const bool calib_suspend = !m_wep.frozen && m_wep.calib_wait <= 0 && m_wep.calib_sample > 0;
    bool did_left = false;
    if ((!changing && !calib_suspend) || (pin && changing)) {
        attach_right_hand(*cam, *vrd);
        if (RE4VRShared::get()->re4_knife_hand.value_or("") == "left") {
            attach_left_hand(*cam, *vrd, lock_pass);
            did_left = true;
        }
        attach_weapon();
    }
    if (!did_left) {
        attach_left_hand(*cam, *vrd, lock_pass);
    }
    if (m_lh_ok) {
        apply_flashlight(m_lh_world, m_lh_rot);
    }
    post_poses(lock_pass);
    if (lock_pass) {
        update_knife_swing();
    }
    publish_globals();
}

void RE4VRMotion::on_frame() {}

void RE4VRMotion::on_pre_application_entry(void*, const char* name, size_t hash) {
    if (hash == "LockScene"_fnv) {
        const auto call = std::string("on_pre_application_entry:") + (name ? name : "");
        ScriptProfileGuard guard("re4_vr_motion.lua", call, re4vr::profile_frame());
        tick(false);
    }
}

void RE4VRMotion::on_application_entry(void*, const char* name, size_t hash) {
    const auto call = std::string("on_application_entry:") + (name ? name : "");
    if (hash == "LateUpdateBehavior"_fnv) {
        ScriptProfileGuard guard("re4_vr_motion.lua", call, re4vr::profile_frame());
        tick(true);
    } else if (hash == "BeginRendering"_fnv) {
        ScriptProfileGuard guard("re4_vr_motion.lua", call, re4vr::profile_frame());
        if (!m_init || native_reload_active()) {
            if (native_reload_active()) {
                release_motion_targets();
            }
            return;
        }
        if (is_killswitch_active()) {
            knife_ks_restore_native();
            restore_hands_native();
            return;
        }
        auto cam = get_camera_data();
        auto vrd = get_vr_data();
        if (!cam || !vrd) {
            return;
        }
        const bool pin = RE4VRShared::get()->vr_wsw_pin;
        const bool calib_suspend = !m_wep.frozen && m_wep.calib_wait <= 0 && m_wep.calib_sample > 0;
        bool did_left = false;
        if ((!m_was_changing && !calib_suspend) || (pin && m_was_changing)) {
            attach_right_hand(*cam, *vrd);
            if (RE4VRShared::get()->re4_knife_hand.value_or("") == "left") {
                attach_left_hand(*cam, *vrd, false);
                did_left = true;
            }
            attach_weapon();
        }
        if (!did_left) {
            attach_left_hand(*cam, *vrd, false);
        }
        if (m_lh_ok) {
            apply_flashlight(m_lh_world, m_lh_rot);
        }
        post_poses(false);
        publish_globals();
    } else if (hash == "UpdateJointExpression"_fnv) {
        ScriptProfileGuard guard("re4_vr_motion.lua", call, re4vr::profile_frame());
        if (!m_init || native_reload_active() || is_killswitch_active()) {
            return;
        }
        if (RE4VRShared::get()->re4_in_mercs && RE4VRShared::get()->vr_dbg_wep_id.value_or(0) == 6304) {
            if (!(m_was_changing && !RE4VRShared::get()->vr_wsw_pin)) {
                auto cam = get_camera_data();
                auto vrd = get_vr_data();
                if (cam && vrd) {
                    attach_right_hand(*cam, *vrd);
                    attach_weapon();
                }
            }
        }
        repin_left();
    }
}
#endif
