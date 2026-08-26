#if defined(RE4)
#define NOMINMAX
#include <algorithm>
#include <cctype>
#include <cmath>
#include <fstream>
#include <type_traits>

#include <glm/gtc/constants.hpp>
#include <glm/gtc/quaternion.hpp>
#include <glm/gtx/quaternion.hpp>

#include <spdlog/spdlog.h>

#include <sdk/SceneManager.hpp>
#include <sdk/RETransform.hpp>
#include <sdk/REComponent.hpp>
#include <sdk/REArray.hpp>
#include <sdk/REString.hpp>
#include <sdk/Math.hpp>
#include <sdk/MotionFsm2Layer.hpp>
#include <sdk/REManagedObject.hpp>
#include <sdk/SystemArray.hpp>
#include <sdk/MurmurHash.hpp>
#include <sdk/Application.hpp>
#include <utility/String.hpp>

#include "HookManager.hpp"
#include "../../../ScriptRunner.hpp"
#include "RE4VRKillswitch.hpp"
#include "RE4VRMovement.hpp"
#include "RE4VRShared.hpp"

using re4vr::obj_ok;
using re4vr::pcall;
using re4vr::safe;

namespace {

float pin_lookup(const std::unordered_map<std::string, float>& m, std::string_view name, float fallback = 0.0f) {
    auto it = m.find(std::string{name});
    return it != m.end() ? it->second : fallback;
}

nlohmann::json pose_to_json(const RE4VRMovement::StoredPose& pose) {
    nlohmann::json j;
    j["joints"] = nlohmann::json::object();
    for (const auto& [nm, sj] : pose.joints) {
        nlohmann::json e;
        e["px"] = sj.p.x;
        e["py"] = sj.p.y;
        e["pz"] = sj.p.z;
        e["rw"] = sj.r.w;
        e["rx"] = sj.r.x;
        e["ry"] = sj.r.y;
        e["rz"] = sj.r.z;
        if (sj.par_inv) {
            e["iw"] = sj.par_inv->w;
            e["ix"] = sj.par_inv->x;
            e["iy"] = sj.par_inv->y;
            e["iz"] = sj.par_inv->z;
        }
        j["joints"][nm] = e;
    }
    if (pose.null_off) {
        nlohmann::json n;
        n["px"] = pose.null_off->p.x;
        n["py"] = pose.null_off->p.y;
        n["pz"] = pose.null_off->p.z;
        n["rw"] = pose.null_off->r.w;
        n["rx"] = pose.null_off->r.x;
        n["ry"] = pose.null_off->r.y;
        n["rz"] = pose.null_off->r.z;
        j["null"] = n;
    }
    return j;
}

std::optional<RE4VRMovement::StoredPose> pose_from_json(const nlohmann::json& j) {
    if (!j.is_object() || !j.contains("joints") || !j["joints"].is_object()) {
        return std::nullopt;
    }
    RE4VRMovement::StoredPose pose{};
    for (auto it = j["joints"].begin(); it != j["joints"].end(); ++it) {
        const auto& s = it.value();
        if (!s.is_object() || !s.contains("px") || !s["px"].is_number() || !s.contains("rw") || !s["rw"].is_number()) {
            return std::nullopt;
        }
        RE4VRMovement::StoredJoint sj{};
        sj.p = Vector3f{s.value("px", 0.0f), s.value("py", 0.0f), s.value("pz", 0.0f)};
        sj.r = glm::quat{s.value("rw", 1.0f), s.value("rx", 0.0f), s.value("ry", 0.0f), s.value("rz", 0.0f)};
        if (s.contains("iw") && s["iw"].is_number()) {
            sj.par_inv = glm::quat{s.value("iw", 1.0f), s.value("ix", 0.0f), s.value("iy", 0.0f), s.value("iz", 0.0f)};
        }
        pose.joints[it.key()] = sj;
    }
    if (j.contains("null") && j["null"].is_object() && j["null"].contains("px") && j["null"]["px"].is_number()) {
        const auto& n = j["null"];
        RE4VRMovement::StoredJoint nj{};
        nj.p = Vector3f{n.value("px", 0.0f), n.value("py", 0.0f), n.value("pz", 0.0f)};
        nj.r = glm::quat{n.value("rw", 1.0f), n.value("rx", 0.0f), n.value("ry", 0.0f), n.value("rz", 0.0f)};
        pose.null_off = nj;
    }
    return pose;
}
}

const std::array<const char*, 6> RE4VRMovement::SCOPE_WIDS{"4202", "4400", "4401", "4402", "6105", "6114"};
const std::array<const char*, 4> RE4VRMovement::SCOPE_STATES{"ironsight", "normal", "thermal", "hipower"};
const std::array<const char*, 7> RE4VRMovement::PIN_JOINTS{"Hip", "Spine_0", "Spine_1", "Spine_2", "Neck_0", "Neck_1", "Head"};
const std::array<const char*, 4> RE4VRMovement::SPINE_YAW_JOINTS{"Spine_1", "Spine_2", "Neck_0", "Neck_1"};
const std::unordered_set<std::string> RE4VRMovement::UB_JOINTS{"Spine_0", "Spine_1", "Spine_2", "Neck_0", "Neck_1"};
const std::vector<const char*> RE4VRMovement::STOP_NODES{
    "ch0_540_JOG_END", "ch0_550_JOG_END_LIGHT", "general_0381_stop_jog",
    "ch0_740_DASH_END", "ch0_749_DASH_CANCEL",
    "ch0_406_WALK_END_FRONT", "ch0_446_WALK_END_BACK", "general_0380_stop_walk",
    "ch0_1406_CROUCH_WALK_END_FRONT", "ch0_1446_CROUCH_WALK_END_BACK",
};
const std::vector<const char*> RE4VRMovement::START_NODES{
    "ch0_400_WALK_START_FRONT", "ch0_440_WALK_START_BACK", "ch0_490_WALK_START_TURN",
    "ch0_1400_CROUCH_WALK_START_FRONT", "ch0_1440_CROUCH_WALK_START_BACK",
    "ch0_1490_CROUCH_WALK_START_TURN",
};
const std::vector<const char*> RE4VRMovement::RUN_START_NODES{
    "ch0_500_JOG_START", "ch0_700_DASH_START", "ch0_1500_CROUCH_TO_JOG_START",
};

std::shared_ptr<RE4VRMovement>& RE4VRMovement::get() {
    static auto inst = std::make_shared<RE4VRMovement>();
    return inst;
}

std::filesystem::path RE4VRMovement::cfg_path() {
    return re4vr::data_path("re4_vr/re4_vr_movement.json");
}

void RE4VRMovement::init_default_scope_sets() {
    m_cfg.scope_sets.clear();
    for (auto w : SCOPE_WIDS) {
        for (auto s : SCOPE_STATES) {
            m_cfg.scope_sets[w][s] = ScopeSlot{};
        }
    }
}

std::optional<std::string> RE4VRMovement::on_initialize() {
    init_default_scope_sets();
    load_json();
    m_cfg.cam_body_rotate = false;

    m_player_cam_td = sdk::find_type_definition("chainsaw.PlayerCameraController");
    m_gimmick_cam_td = sdk::find_type_definition("chainsaw.GimmickMotionCameraController");

    if (m_player_cam_td != nullptr) {
        if (auto* m = m_player_cam_td->get_method("updateCameraPosition")) {
            g_hookman.add(m, &RE4VRMovement::pre_update_camera_position, &RE4VRMovement::post_update_camera_position);
            spdlog::info("[RE4VRMovement] Hooked PlayerCameraController.updateCameraPosition");
        }
    }

    if (auto* jh = sdk::find_type_definition("chainsaw.MotionJackSuppliedHolder")) {
        if (auto* m = jh->get_method("setupJackLayer")) {
            g_hookman.add(m, &RE4VRMovement::pre_setup_jack_layer, &RE4VRMovement::post_setup_jack_layer);
            spdlog::info("[RE4VRMovement] Hooked MotionJackSuppliedHolder.setupJackLayer");
        }
    }
    for (auto* tn : {"chainsaw.GmInterstice1Motion", "chainsaw.GmIntersticeWithEm"}) {
        if (auto* td = sdk::find_type_definition(tn)) {
            if (auto* m = td->get_method("startJackPl")) {
                g_hookman.add(m, &RE4VRMovement::pre_start_jack_pl, &RE4VRMovement::post_start_jack_pl);
                spdlog::info("[RE4VRMovement] Hooked {}.startJackPl", tn);
            }
        }
    }

    return std::nullopt;
}

void RE4VRMovement::on_config_load(const utility::Config&) {
    // Nested movement settings live in re4_vr/re4_vr_movement.json, not re2_tweaks.ini.
    load_json();
    m_cfg.cam_body_rotate = false;
}

void RE4VRMovement::on_config_save(utility::Config&) {
    save_json();
}

void RE4VRMovement::on_lua_state_created(sol::state& lua) {
    install_compat_globals(lua);
}

void RE4VRMovement::on_lua_state_destroyed(sol::state&) {
    reset_runtime();
}

void RE4VRMovement::install_compat_globals(sol::state& lua) {
    lua["__vr_zbob_tau"] = sol::nil;
    lua["__re4_jackblock_hooked"] = true;
}

void RE4VRMovement::set_roomscale_enabled(bool v) {
    m_cfg.roomscale = v;
    save_json();
}

void RE4VRMovement::on_frame() {
    ScriptProfileGuard guard("re4_vr_movement.lua", "on_frame", re4vr::profile_frame());
    apply_grav_fix();
}

void RE4VRMovement::on_pre_application_entry(void*, const char* name, size_t hash) {
    const auto call = std::string("on_pre_application_entry:") + (name ? name : "");
    const auto frame = re4vr::profile_frame();
    switch (hash) {
    case "LockScene"_fnv: {
        ScriptProfileGuard guard("re4_vr_movement.lua", call, frame);
        apply_auto_center();
        roomscale_recenter_events();
        roomscale_crouch();
        apply_hmd_body_follow();
        apply_hard_yaw(true);
        apply_ub_lock(true);
        update_stop_skip();
        update_anim_export();
        apply_spine_pin(true);
        apply_crouch_pin();
        break;
    }
    case "BeginRendering"_fnv: {
        ScriptProfileGuard guard("re4_vr_movement.lua", call, frame);
        enforce_hard_yaw();
        apply_ub_lock();
        apply_spine_pin();
        apply_crouch_pin();
        apply_crouch_ub_z(false);
        break;
    }
    default:
        break;
    }
}

void RE4VRMovement::on_application_entry(void*, const char* name, size_t hash) {
    const auto call = std::string("on_application_entry:") + (name ? name : "");
    const auto frame = re4vr::profile_frame();
    switch (hash) {
    case "LateUpdateBehavior"_fnv: {
        ScriptProfileGuard guard("re4_vr_movement.lua", call, frame);
        roomscale_flush_body();
        enforce_hard_yaw();
        if (!is_ks_active()) {
            apply_ub_lock();
            if (auto* tf = get_body_transform()) {
                apply_spine_yaw(tf);
            }
        }
        apply_spine_pin();
        apply_crouch_pin(true);
        apply_crouch_ub_z(true);
        break;
    }
    case "BeginRendering"_fnv: {
        ScriptProfileGuard guard("re4_vr_movement.lua", call, frame);
        enforce_hard_yaw();
        apply_ub_lock();
        apply_spine_pin();
        apply_crouch_pin();
        apply_crouch_ub_z(false);
        apply_scope_freeze_late();
        sqab_tick();
        break;
    }
    case "UpdateMotion"_fnv: {
        ScriptProfileGuard guard("re4_vr_movement.lua", call, frame);
        enforce_hard_yaw();
        apply_ub_lock();
        apply_spine_pin();
        apply_crouch_pin();
        apply_lag_fix();
        break;
    }
    case "UpdateJointExpression"_fnv: {
        ScriptProfileGuard guard("re4_vr_movement.lua", call, frame);
        apply_ub_lock();
        apply_spine_pin();
        apply_crouch_pin();
        apply_crouch_ub_z(false);
        break;
    }
    default:
        break;
    }
}

// ---- JSON ----

void RE4VRMovement::load_json() {
    init_default_scope_sets();
    const auto path = cfg_path();
    std::ifstream f{path};
    if (!f) {
        return;
    }
    try {
        nlohmann::json d;
        f >> d;
        if (d.is_object()) {
            apply_json(d);
        }
    } catch (const std::exception& e) {
        spdlog::error("[RE4VRMovement] Failed to load {}: {}", path.string(), e.what());
    }
}

void RE4VRMovement::save_json() {
    try {
        const auto path = cfg_path();
        std::filesystem::create_directories(path.parent_path());
        std::ofstream f{path};
        f << dump_json().dump(4);
    } catch (const std::exception& e) {
        spdlog::error("[RE4VRMovement] Failed to save movement json: {}", e.what());
    }
}

void RE4VRMovement::apply_json(const nlohmann::json& d) {
    auto b = [&](const char* k, bool& dst) {
        if (d.contains(k) && !d[k].is_null()) {
            dst = d[k].is_boolean() ? d[k].get<bool>() : (d[k].is_number() && d[k].get<double>() != 0.0);
        }
    };
    auto n = [&](const char* k, float& dst) {
        if (d.contains(k) && d[k].is_number()) {
            dst = d[k].get<float>();
        }
    };
    auto ni = [&](const char* k, int32_t& dst) {
        if (d.contains(k) && d[k].is_number()) {
            dst = d[k].get<int32_t>();
        }
    };

    b("enabled", m_cfg.enabled);
    b("hmd_yaw_drive", m_cfg.hmd_yaw_drive);
    n("yaw_offset_deg", m_cfg.yaw_offset_deg);
    n("scope_yaw_xr", m_cfg.scope_yaw_xr);
    ni("scope_submit_mode", m_cfg.scope_submit_mode);
    b("roomscale", m_cfg.roomscale);
    b("rs_lean", m_cfg.rs_lean);
    n("rs_lean_radius", m_cfg.rs_lean_radius);
    b("rs_recenter", m_cfg.rs_recenter);
    b("rs_crouch", m_cfg.rs_crouch);
    n("rs_crouch_pct", m_cfg.rs_crouch_pct);
    n("rs_stand_height", m_cfg.rs_stand_height);
    b("hmd_follow", m_cfg.hmd_follow);
    n("hmd_follow_deadzone", m_cfg.hmd_follow_deadzone);
    n("hmd_follow_alpha", m_cfg.hmd_follow_alpha);
    b("hip_follow", m_cfg.hip_follow);
    n("spine_yaw_deg", m_cfg.spine_yaw_deg);
    b("ub_lock", m_cfg.ub_lock);
    n("ub_trim_deg", m_cfg.ub_trim_deg);
    b("ub_lock_world", m_cfg.ub_lock_world);
    b("spine_pin", m_cfg.spine_pin);
    b("grav_fix", m_cfg.grav_fix);
    n("grav_value", m_cfg.grav_value);
    b("grav_in_elevator", m_cfg.grav_in_elevator);
    b("lag_boost_on", m_cfg.lag_boost_on);
    n("lag_boost_target", m_cfg.lag_boost_target);
    n("lag_boost_max", m_cfg.lag_boost_max);
    n("lag_boost_window", m_cfg.lag_boost_window);
    b("lag_brake_on", m_cfg.lag_brake_on);
    n("lag_brake_gain", m_cfg.lag_brake_gain);
    n("lag_brake_window", m_cfg.lag_brake_window);
    n("pin_z_hip_walk", m_cfg.pin_z_hip_walk);
    n("pin_x_hip", m_cfg.pin_x_hip);
    n("pin_ub_z", m_cfg.pin_ub_z);
    n("pin_ub_z_crouch", m_cfg.pin_ub_z_crouch);
    n("pin_ub_x", m_cfg.pin_ub_x);
    n("pin_ub_x_crouch", m_cfg.pin_ub_x_crouch);
    n("pin_ub_yaw", m_cfg.pin_ub_yaw);
    n("pin_hip_yaw", m_cfg.pin_hip_yaw);
    n("pin_spine1_roll", m_cfg.pin_spine1_roll);
    n("body_yaw_speed", m_cfg.body_yaw_speed);
    b("yaw_hmd_target", m_cfg.yaw_hmd_target);
    b("cam_body_rotate", m_cfg.cam_body_rotate);
    b("stop_skip", m_cfg.stop_skip);
    n("stop_skip_frames", m_cfg.stop_skip_frames);
    b("start_skip", m_cfg.start_skip);
    n("start_skip_frames", m_cfg.start_skip_frames);
    b("no_pivot", m_cfg.no_pivot);
    n("scope_pitch_gain", m_cfg.scope_pitch_gain);

    if (d.contains("pin_z") && d["pin_z"].is_object()) {
        for (auto& [k, v] : m_cfg.pin_z) {
            if (d["pin_z"].contains(k) && d["pin_z"][k].is_number()) {
                v = d["pin_z"][k].get<float>();
            }
        }
    }
    if (d.contains("pin_x") && d["pin_x"].is_object()) {
        for (auto& [k, v] : m_cfg.pin_x) {
            if (d["pin_x"].contains(k) && d["pin_x"][k].is_number()) {
                v = d["pin_x"][k].get<float>();
            }
        }
    }
    if (d.contains("pin_z_hip_crouch") && d["pin_z_hip_crouch"].is_number()) {
        m_cfg.pin_z_hip_crouch = d["pin_z_hip_crouch"].get<float>();
    }
    if (d.contains("pin_pose") && d["pin_pose"].is_object()) {
        m_cfg.pin_pose = pose_from_json(d["pin_pose"]);
    }
    if (d.contains("crouch_pose") && d["crouch_pose"].is_object()) {
        m_cfg.crouch_pose = pose_from_json(d["crouch_pose"]);
    }
    if (d.contains("scope_sets") && d["scope_sets"].is_object()) {
        const auto& ss = d["scope_sets"];
        bool is_new = false;
        for (auto w : SCOPE_WIDS) {
            if (ss.contains(w) && ss[w].is_object()) {
                is_new = true;
                break;
            }
        }
        if (is_new) {
            for (auto w : SCOPE_WIDS) {
                if (!ss.contains(w) || !ss[w].is_object()) {
                    continue;
                }
                for (auto st : SCOPE_STATES) {
                    if (!ss[w].contains(st) || !ss[w][st].is_object()) {
                        continue;
                    }
                    const auto& s = ss[w][st];
                    auto& dst = m_cfg.scope_sets[w][st];
                    if (s.contains("x_r") && s["x_r"].is_number()) dst.x_r = s["x_r"].get<float>();
                    if (s.contains("z_r") && s["z_r"].is_number()) dst.z_r = s["z_r"].get<float>();
                    if (s.contains("yaw") && s["yaw"].is_number()) dst.yaw = s["yaw"].get<float>();
                }
            }
        } else {
            for (auto st : {"normal", "thermal", "hipower"}) {
                if (!ss.contains(st) || !ss[st].is_object()) {
                    continue;
                }
                const auto& s = ss[st];
                auto& dst = m_cfg.scope_sets["4401"][st];
                if (s.contains("x_r") && s["x_r"].is_number()) dst.x_r = s["x_r"].get<float>();
                if (s.contains("z_r") && s["z_r"].is_number()) dst.z_r = s["z_r"].get<float>();
                if (s.contains("yaw") && s["yaw"].is_number()) dst.yaw = s["yaw"].get<float>();
            }
        }
    }
}

nlohmann::json RE4VRMovement::dump_json() const {
    nlohmann::json j;
    j["enabled"] = m_cfg.enabled;
    j["scope_submit_mode"] = m_cfg.scope_submit_mode;
    j["hmd_yaw_drive"] = m_cfg.hmd_yaw_drive;
    j["yaw_offset_deg"] = m_cfg.yaw_offset_deg;
    j["roomscale"] = m_cfg.roomscale;
    j["rs_lean"] = m_cfg.rs_lean;
    j["rs_lean_radius"] = m_cfg.rs_lean_radius;
    j["rs_recenter"] = m_cfg.rs_recenter;
    j["rs_crouch"] = m_cfg.rs_crouch;
    j["rs_crouch_pct"] = m_cfg.rs_crouch_pct;
    j["rs_stand_height"] = m_cfg.rs_stand_height;
    j["hmd_follow"] = m_cfg.hmd_follow;
    j["hmd_follow_deadzone"] = m_cfg.hmd_follow_deadzone;
    j["hmd_follow_alpha"] = m_cfg.hmd_follow_alpha;
    j["hip_follow"] = m_cfg.hip_follow;
    j["spine_yaw_deg"] = m_cfg.spine_yaw_deg;
    j["ub_lock"] = m_cfg.ub_lock;
    j["ub_trim_deg"] = m_cfg.ub_trim_deg;
    j["ub_lock_world"] = m_cfg.ub_lock_world;
    j["spine_pin"] = m_cfg.spine_pin;
    j["pin_z"] = m_cfg.pin_z;
    j["pin_z_hip_walk"] = m_cfg.pin_z_hip_walk;
    if (m_cfg.pin_z_hip_crouch) {
        j["pin_z_hip_crouch"] = *m_cfg.pin_z_hip_crouch;
    }
    j["pin_x_hip"] = m_cfg.pin_x_hip;
    j["pin_x"] = m_cfg.pin_x;
    j["pin_ub_z"] = m_cfg.pin_ub_z;
    j["pin_ub_x"] = m_cfg.pin_ub_x;
    j["pin_ub_x_crouch"] = m_cfg.pin_ub_x_crouch;
    j["pin_ub_yaw"] = m_cfg.pin_ub_yaw;
    j["pin_ub_z_crouch"] = m_cfg.pin_ub_z_crouch;
    j["pin_hip_yaw"] = m_cfg.pin_hip_yaw;
    j["pin_spine1_roll"] = m_cfg.pin_spine1_roll;
    j["body_yaw_speed"] = m_cfg.body_yaw_speed;
    j["yaw_hmd_target"] = m_cfg.yaw_hmd_target;
    j["cam_body_rotate"] = m_cfg.cam_body_rotate;
    j["stop_skip"] = m_cfg.stop_skip;
    j["stop_skip_frames"] = m_cfg.stop_skip_frames;
    j["start_skip"] = m_cfg.start_skip;
    j["start_skip_frames"] = m_cfg.start_skip_frames;
    j["no_pivot"] = m_cfg.no_pivot;
    j["scope_pitch_gain"] = m_cfg.scope_pitch_gain;
    j["scope_yaw_xr"] = m_cfg.scope_yaw_xr;
    j["grav_fix"] = m_cfg.grav_fix;
    j["grav_value"] = m_cfg.grav_value;
    j["grav_in_elevator"] = m_cfg.grav_in_elevator;
    j["lag_boost_on"] = m_cfg.lag_boost_on;
    j["lag_boost_target"] = m_cfg.lag_boost_target;
    j["lag_boost_max"] = m_cfg.lag_boost_max;
    j["lag_boost_window"] = m_cfg.lag_boost_window;
    j["lag_brake_on"] = m_cfg.lag_brake_on;
    j["lag_brake_gain"] = m_cfg.lag_brake_gain;
    j["lag_brake_window"] = m_cfg.lag_brake_window;
    j["scope_sets"] = nlohmann::json::object();
    for (auto w : SCOPE_WIDS) {
        j["scope_sets"][w] = nlohmann::json::object();
        auto wit = m_cfg.scope_sets.find(w);
        if (wit == m_cfg.scope_sets.end()) {
            continue;
        }
        for (auto st : SCOPE_STATES) {
            auto sit = wit->second.find(st);
            if (sit == wit->second.end()) {
                continue;
            }
            const auto& s = sit->second;
            j["scope_sets"][w][st] = {{"x_r", s.x_r}, {"z_r", s.z_r}, {"yaw", s.yaw}};
        }
    }
    if (m_cfg.pin_pose) {
        j["pin_pose"] = pose_to_json(*m_cfg.pin_pose);
    }
    if (m_cfg.crouch_pose) {
        j["crouch_pose"] = pose_to_json(*m_cfg.crouch_pose);
    }
    return j;
}

void RE4VRMovement::reset_runtime() {
    if (m_grav_orig) {
        if (auto* ga = ground_adsorber()) {
            if (auto* f = sdk::get_object_field<float>(ga, "_GravitationalAcceleration")) {
                *f = *m_grav_orig;
            }
        }
    }
    if (m_stop_skip.applied) {
        pcall([&] { apply_stop_skip(false); });
    }
    if (m_start_skip.applied) {
        pcall([&] { apply_start_skip(false); });
    }
    if (m_no_pivot.applied) {
        pcall([&] { apply_no_pivot(false); });
    }

    m_pause_manager = nullptr;
    m_gui_manager = nullptr;
    m_last_yaw_quat.reset();
    m_body_yaw_last_t.reset();
    m_owned_yaw.reset();
    m_hmd_yaw_pcc = nullptr;
    m_hmd_yaw_prev.reset();
    m_hip_joint = nullptr;
    m_hip_ref_offset.reset();
    m_spine_joint_cache.clear();
    m_spine_last_written.clear();
    m_ub_lock_pose.clear();
    m_ub_lock_rel.clear();
    m_ub_lock_has_pose = false;
    m_ub_lock_has_rel = false;
    m_ub_lock_base.valid = false;
    m_spinepin_tf = nullptr;
    m_spinepin_joints.clear();
    m_spinepin_names.clear();
    m_spinepin_rel.reset();
    m_spinepin_par_inv.clear();
    m_spinepin_null_off = nullptr;
    m_spinepin_null_rel.reset();
    m_crouch_ubz_has_base = false;
    m_crouch_ubz_base.clear();
    m_crouchpin_capture_req = false;
    RE4VRShared::get()->vr_surge_bridged = false;
    m_auto_center_ctx = nullptr;
    m_bw_motion = nullptr;
    m_pose_freeze_now = false;
    apply_pose_freeze(false);
}

double RE4VRMovement::now_clock() const {
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - m_clock_origin).count();
}

// ---- Killswitch / gameplay gates (C++ mods, not Lua package.loaded) ----

bool RE4VRMovement::is_ks_active() {
    if (RE4VRShared::get()->re4_throwsight_active) {
        return true;
    }
    if (RE4VRShared::get()->re4_ks_keep_movement) {
        return false;
    }
    return RE4VRKillswitch::get()->is_active();
}

bool RE4VRMovement::is_pin_release() {
    return RE4VRKillswitch::get()->is_pin_release();
}

bool RE4VRMovement::is_crouch_active() {
    return RE4VRKillswitch::get()->is_crouch_active();
}

bool RE4VRMovement::is_aim() {
    return RE4VRShared::get()->is_aim;
}

bool RE4VRMovement::pure_gameplay_only() {
    if (is_ks_active()) {
        return false;
    }
    if (RE4VRShared::get()->re4_ks_active) {
        return false;
    }
    if (!RE4VRKillswitch::get()->is_pure_gameplay()) {
        return false;
    }
    if (!obj_ok(m_pause_manager)) {
        m_pause_manager = sdk::get_managed_singleton<::REManagedObject>("share.PauseManager");
    }
    if (obj_ok(m_pause_manager)) {
        auto paused = safe([&] { return sdk::call_object_func_easy<bool>(m_pause_manager, "isPaused()"); });
        if (!paused) {
            paused = safe([&] { return sdk::call_object_func_easy<bool>(m_pause_manager, "isPaused"); });
        }
        if (paused && *paused) {
            return false;
        }
    }
    if (!obj_ok(m_gui_manager)) {
        m_gui_manager = sdk::get_managed_singleton<::REManagedObject>("chainsaw.GuiManager");
    }
    if (obj_ok(m_gui_manager)) {
        auto lock = safe([&] { return sdk::call_object_func_easy<bool>(m_gui_manager, "get_hasOccupiedPauseMenuSystemLock"); });
        if (lock && *lock) {
            return false;
        }
    }
    return true;
}

// ---- Pointers ----

::RETransform* RE4VRMovement::get_body_transform() {
    return re4vr::body_transform();
}

::REManagedObject* RE4VRMovement::get_player_cam_controller() {
    auto* sys = re4vr::camera_system();
    if (!obj_ok(sys)) {
        return nullptr;
    }
    auto* main = safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(sys, "get_MainCameraController"); }).value_or(nullptr);
    auto* busy = main ? safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(main, "get_BusyCameraController"); }).value_or(nullptr) : nullptr;
    if (!obj_ok(busy) || m_player_cam_td == nullptr) {
        return nullptr;
    }
    if (!utility::re_managed_object::is_a(busy, "chainsaw.PlayerCameraController")) {
        return nullptr;
    }
    return busy;
}

::REManagedObject* RE4VRMovement::ground_adsorber(::REManagedObject** out_ctx) {
    auto* c = re4vr::player_context();
    if (out_ctx) {
        *out_ctx = c;
    }
    if (!obj_ok(c)) {
        return nullptr;
    }
    auto* bu = safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(c, "get_BodyUpdater"); }).value_or(nullptr);
    if (!obj_ok(bu)) {
        return nullptr;
    }
    return safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(bu, "get_GroundAdsorber"); }).value_or(nullptr);
}

::REManagedObject* RE4VRMovement::get_motion_fsm(::REManagedObject** out_ctx) {
    auto* ctx = re4vr::player_context();
    if (out_ctx) {
        *out_ctx = ctx;
    }
    if (!obj_ok(ctx)) {
        return nullptr;
    }
    auto* updater = sdk::get_object_field<::REManagedObject*>(ctx, "_BodyUpdater");
    if (!updater || !obj_ok(*updater)) {
        return nullptr;
    }
    auto* mfsm = sdk::get_object_field<::REManagedObject*>(*updater, "<MotionFsm>k__BackingField");
    if (!mfsm || !obj_ok(*mfsm)) {
        return nullptr;
    }
    return *mfsm;
}

bool RE4VRMovement::joint_alive(::REJoint* j) {
    if (j == nullptr || !utility::re_managed_object::is_managed_object(j)) {
        return false;
    }
    return pcall([&] { (void)sdk::get_joint_position(j); });
}

::REJoint* RE4VRMovement::get_hip_joint(::RETransform* tf) {
    if (m_hip_joint) {
        if ((now_clock() - m_hipjv_bad) < 0.5) {
            return nullptr;
        }
        if (joint_alive(m_hip_joint)) {
            return m_hip_joint;
        }
        m_hipjv_bad = now_clock();
        m_hip_joint = nullptr;
    }
    if (!tf) {
        return nullptr;
    }
    m_hip_joint = sdk::get_transform_joint_by_name(tf, L"Hip");
    return m_hip_joint;
}

::REJoint* RE4VRMovement::get_spine_joint(::RETransform* tf, const char* name) {
    auto it = m_spine_joint_cache.find(name);
    if (it != m_spine_joint_cache.end()) {
        if (joint_alive(it->second)) {
            return it->second;
        }
        m_spine_joint_cache.erase(it);
    }
    if (!tf) {
        return nullptr;
    }
    auto* j = sdk::get_transform_joint_by_name(tf, utility::widen(name));
    if (j) {
        m_spine_joint_cache[name] = j;
    }
    return j;
}

std::optional<float> RE4VRMovement::flat_yaw_of(const glm::quat& rot) {
    const auto f = rot * Vector3f{0.0f, 0.0f, 1.0f};
    const auto len = std::sqrt(f.x * f.x + f.z * f.z);
    if (len < 0.0001f) {
        return std::nullopt;
    }
    return std::atan2(f.x / len, f.z / len);
}

glm::quat RE4VRMovement::yaw_to_quat(float yaw) {
    const auto half = yaw * 0.5f;
    return glm::quat{std::cos(half), 0.0f, std::sin(half), 0.0f};
}

glm::quat RE4VRMovement::spin_axis_quat(float ax, float ay, float az, float rad) {
    const auto h = rad * 0.5f;
    const auto s = std::sin(h);
    return glm::quat{std::cos(h), ax * s, ay * s, az * s};
}

std::optional<float> RE4VRMovement::spin_yaw_of(const glm::quat& rot) {
    const auto f = rot * Vector3f{0.0f, 0.0f, 1.0f};
    const auto len = std::sqrt(f.x * f.x + f.z * f.z);
    if (len < 0.0001f) {
        return std::nullopt;
    }
    return std::atan2(f.x / len, f.z / len);
}

glm::quat RE4VRMovement::spin_yaw_quat(float yaw) {
    const auto h = yaw * 0.5f;
    return glm::quat{std::cos(h), 0.0f, std::sin(h), 0.0f};
}

Vector3f RE4VRMovement::quat_rotate_vec3(const glm::quat& q, const Vector3f& v) {
    return q * v;
}

glm::quat RE4VRMovement::hmd_quat() {
    auto& vr = VR::get();
    return glm::quat{vr->get_transform(0)};
}

float RE4VRMovement::hmd_wrap(float a) {
    if (a > glm::pi<float>()) {
        return a - 2.0f * glm::pi<float>();
    }
    if (a < -glm::pi<float>()) {
        return a + 2.0f * glm::pi<float>();
    }
    return a;
}

bool RE4VRMovement::quat_approx_equal(const glm::quat& a, const glm::quat& b) {
    auto dot = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    if (dot < 0.0f) {
        dot = -dot;
    }
    return dot > 0.9999995f;
}

bool RE4VRMovement::is_ub_joint(std::string_view name) {
    return UB_JOINTS.contains(std::string{name});
}

bool RE4VRMovement::is_user_turning() {
    auto& vr = VR::get();
    const auto ax = vr->get_right_stick_axis();
    return std::abs(ax.x) > 0.1f;
}

void RE4VRMovement::apply_hip_follow(::RETransform* tf, const glm::quat& root_yaw_quat) {
    if (!m_cfg.hip_follow || !tf) {
        return;
    }
    auto* hip = get_hip_joint(tf);
    if (!hip) {
        return;
    }
    auto hr = safe([&] { return sdk::get_joint_rotation(hip); });
    if (!hr) {
        return;
    }
    auto hip_yaw = flat_yaw_of(*hr);
    if (!hip_yaw) {
        return;
    }
    const auto hip_yaw_q = yaw_to_quat(*hip_yaw);

    if (!is_user_turning()) {
        auto off = glm::normalize(glm::conjugate(root_yaw_quat) * hip_yaw_q);
        if (m_hip_ref_offset) {
            m_hip_ref_offset = glm::slerp(*m_hip_ref_offset, off, 0.1f);
        } else {
            m_hip_ref_offset = off;
        }
        return;
    }
    if (!m_hip_ref_offset) {
        return;
    }
    const auto desired_yaw = glm::normalize(root_yaw_quat * *m_hip_ref_offset);
    const auto correction = glm::normalize(desired_yaw * glm::conjugate(hip_yaw_q));
    const auto new_rot = glm::normalize(correction * *hr);
    pcall([&] { sdk::set_joint_rotation(hip, new_rot); });
}

// ---- Spine pin ----

bool RE4VRMovement::spinepin_resolve(::RETransform* tf) {
    if (m_spinepin_tf == tf && !m_spinepin_joints.empty()) {
        return true;
    }
    m_spinepin_tf = tf;
    m_spinepin_joints.clear();
    m_spinepin_names.clear();
    m_spinepin_null_off = nullptr;

    if (auto* js = sdk::get_transform_joints(tf); js != nullptr && js->get_size() > 0) {
        if (auto* root = (::REJoint*)js->get_element(0)) {
            m_spinepin_joints.push_back(root);
            m_spinepin_names.emplace_back("root");
        }
    }
    for (auto name : PIN_JOINTS) {
        if (auto* j = sdk::get_transform_joint_by_name(tf, utility::widen(name))) {
            m_spinepin_joints.push_back(j);
            m_spinepin_names.emplace_back(name);
        }
    }
    if (m_spinepin_joints.empty()) {
        return false;
    }
    m_spinepin_null_off = sdk::get_transform_joint_by_name(tf, L"Null_Offset");
    return true;
}

bool RE4VRMovement::spinepin_capture(::RETransform* tf, std::vector<PinRel>& rel, std::vector<std::optional<glm::quat>>& par_inv, std::optional<PinRel>& null_rel) {
    auto tr = safe([&] { return sdk::get_transform_rotation(tf); });
    if (!tr) {
        return false;
    }
    const auto tri = glm::conjugate(*tr);

    std::vector<glm::quat> fixed_rel;
    fixed_rel.reserve(m_spinepin_joints.size());
    for (auto* j : m_spinepin_joints) {
        auto wr = safe([&] { return sdk::get_joint_rotation(j); });
        if (!wr) {
            return false;
        }
        auto rel_r = glm::normalize(tri * *wr);
        if (auto y = spin_yaw_of(rel_r); y && *y != 0.0f) {
            rel_r = glm::normalize(spin_yaw_quat(-*y) * rel_r);
        }
        fixed_rel.push_back(rel_r);
    }

    rel.clear();
    par_inv.clear();
    rel.resize(m_spinepin_joints.size());
    par_inv.resize(m_spinepin_joints.size());
    for (size_t i = 0; i < m_spinepin_joints.size(); ++i) {
        auto lp = safe([&] { return sdk::get_joint_local_position(m_spinepin_joints[i]); });
        if (!lp) {
            return false;
        }
        glm::quat lr{};
        if (i == 0) {
            lr = fixed_rel[0];
            par_inv[i].reset();
        } else {
            lr = glm::normalize(glm::conjugate(fixed_rel[i - 1]) * fixed_rel[i]);
            par_inv[i] = glm::conjugate(fixed_rel[i - 1]);
        }
        rel[i] = PinRel{Vector3f{lp->x, lp->y, lp->z}, lr};
    }

    null_rel.reset();
    if (m_spinepin_null_off) {
        auto lp = safe([&] { return sdk::get_joint_local_position(m_spinepin_null_off); });
        auto lr = safe([&] { return sdk::get_joint_local_rotation(m_spinepin_null_off); });
        if (lp && lr) {
            null_rel = PinRel{Vector3f{lp->x, lp->y, lp->z}, *lr};
        }
    }
    return true;
}

void RE4VRMovement::spinepin_store(const std::vector<PinRel>& rel, const std::vector<std::optional<glm::quat>>& par_inv, const std::optional<PinRel>& null_rel, bool crouch) {
    StoredPose store{};
    for (size_t i = 0; i < m_spinepin_names.size() && i < rel.size(); ++i) {
        StoredJoint sj{};
        sj.p = rel[i].p;
        sj.r = rel[i].r;
        if (i < par_inv.size() && par_inv[i]) {
            sj.par_inv = par_inv[i];
        }
        store.joints[m_spinepin_names[i]] = sj;
    }
    if (null_rel) {
        store.null_off = StoredJoint{null_rel->p, null_rel->r, std::nullopt};
    }
    if (crouch) {
        m_cfg.crouch_pose = store;
    } else {
        m_cfg.pin_pose = store;
    }
    save_json();
}

bool RE4VRMovement::spinepin_restore(bool crouch, std::vector<PinRel>& rel, std::vector<std::optional<glm::quat>>& par_inv, std::optional<PinRel>& null_rel) {
    const auto& opt = crouch ? m_cfg.crouch_pose : m_cfg.pin_pose;
    if (!opt || m_spinepin_names.empty()) {
        return false;
    }
    rel.clear();
    par_inv.clear();
    rel.resize(m_spinepin_names.size());
    par_inv.resize(m_spinepin_names.size());
    for (size_t i = 0; i < m_spinepin_names.size(); ++i) {
        auto it = opt->joints.find(m_spinepin_names[i]);
        if (it == opt->joints.end()) {
            return false;
        }
        rel[i] = PinRel{it->second.p, it->second.r};
        par_inv[i] = it->second.par_inv;
    }
    null_rel.reset();
    if (opt->null_off) {
        null_rel = PinRel{opt->null_off->p, opt->null_off->r};
    }
    return true;
}

void RE4VRMovement::apply_spine_pin(bool can_capture) {
    if (!m_cfg.spine_pin) {
        m_spinepin_rel.reset();
        RE4VRShared::get()->vr_surge_bridged = false;
        return;
    }
    if (is_ks_active()) {
        return;
    }
    if (is_pin_release()) {
        RE4VRShared::get()->vr_surge_bridged = false;
        return;
    }
    if (is_crouch_active()) {
        return;
    }

    auto* tf = get_body_transform();
    if (!tf) {
        return;
    }

    if (!m_spinepin_joints.empty() && !joint_alive(m_spinepin_joints[0])) {
        m_spinepin_tf = nullptr;
        m_spinepin_joints.clear();
        m_spinepin_null_off = nullptr;
    }
    if (!spinepin_resolve(tf)) {
        return;
    }

    if (!m_spinepin_rel) {
        RE4VRShared::get()->vr_surge_bridged = false;
        if (!m_spinepin_cfg_tried) {
            m_spinepin_cfg_tried = true;
            std::vector<PinRel> r;
            std::vector<std::optional<glm::quat>> pi;
            std::optional<PinRel> nr;
            if (spinepin_restore(false, r, pi, nr)) {
                m_spinepin_rel = std::move(r);
                m_spinepin_par_inv = std::move(pi);
                m_spinepin_null_rel = nr;
                return;
            }
        }
        if (can_capture) {
            auto a = RE4VRShared::get()->vr_anim_l0;
            std::vector<PinRel> r;
            std::vector<std::optional<glm::quat>> pi;
            std::optional<PinRel> nr;
            if (spinepin_capture(tf, r, pi, nr)) {
                m_spinepin_rel = r;
                m_spinepin_par_inv = pi;
                m_spinepin_null_rel = nr;
                std::string al = a ? *a : "";
                std::transform(al.begin(), al.end(), al.begin(), [](unsigned char c) { return (char)std::tolower(c); });
                if (al.find("stand") != std::string::npos) {
                    m_spinepin_provisional = false;
                    spinepin_store(r, pi, nr, false);
                } else {
                    m_spinepin_provisional = true;
                }
            }
        }
        return;
    }

    if (m_spinepin_provisional && can_capture) {
        auto a = RE4VRShared::get()->vr_anim_l0;
        std::string al = a ? *a : "";
        std::transform(al.begin(), al.end(), al.begin(), [](unsigned char c) { return (char)std::tolower(c); });
        if (al.find("stand") != std::string::npos) {
            std::vector<PinRel> r;
            std::vector<std::optional<glm::quat>> pi;
            std::optional<PinRel> nr;
            if (spinepin_capture(tf, r, pi, nr)) {
                m_spinepin_rel = r;
                m_spinepin_par_inv = pi;
                m_spinepin_null_rel = nr;
                m_spinepin_provisional = false;
                spinepin_store(r, pi, nr, false);
            }
        }
    }

    auto& cur_rel = *m_spinepin_rel;
    RE4VRShared::get()->vr_surge_bridged = true;

    if (can_capture) {
        auto a = RE4VRShared::get()->vr_anim_l0;
        bool running = false, walking = false;
        if (a) {
            std::string al = *a;
            std::transform(al.begin(), al.end(), al.begin(), [](unsigned char c) { return (char)std::tolower(c); });
            running = al.find("jog") != std::string::npos || al.find("dash") != std::string::npos || al.find("run") != std::string::npos;
            walking = !running && al.find("walk") != std::string::npos;
        }
        m_spinepin_run_blend += ((running ? 1.0f : 0.0f) - m_spinepin_run_blend) * 0.15f;
        m_spinepin_walk_blend += ((walking ? 1.0f : 0.0f) - m_spinepin_walk_blend) * 0.15f;
    }

    Vector3f anchor_p = (!cur_rel.empty()) ? cur_rel[0].p : Vector3f{};
    const auto sdx = (float)RE4VRShared::get()->vr_surge_dx.value_or(0.0);
    const auto sdz = (float)RE4VRShared::get()->vr_surge_dz.value_or(0.0);
    if (!cur_rel.empty() && (sdx != 0.0f || sdz != 0.0f)) {
        auto tr = safe([&] { return sdk::get_transform_rotation(tf); });
        if (tr) {
            const auto off = glm::conjugate(*tr) * Vector3f{sdx, 0.0f, sdz};
            anchor_p += off;
        }
    }

    RE4VRShared::get()->re4_ub_z_delta = 0.0;

    for (size_t i = 0; i < m_spinepin_joints.size() && i < cur_rel.size(); ++i) {
        auto* j = m_spinepin_joints[i];
        auto p = (i == 0) ? anchor_p : cur_rel[i].p;
        const auto& name = m_spinepin_names[i];
        float zo = pin_lookup(m_cfg.pin_z, name);
        float xo = pin_lookup(m_cfg.pin_x, name, 0.0f);
        const bool is_ub = is_ub_joint(name);
        if (is_ub) {
            zo += m_cfg.pin_ub_z;
            xo += m_cfg.pin_ub_x;
        }
        if (name == "Hip") {
            zo = pin_lookup(m_cfg.pin_z, "Hip") * m_spinepin_run_blend + m_cfg.pin_z_hip_walk * m_spinepin_walk_blend;
            xo += m_cfg.pin_x_hip;
        } else if (name == "Spine_0") {
            zo -= pin_lookup(m_cfg.pin_z, "Hip") * m_spinepin_run_blend + m_cfg.pin_z_hip_walk * m_spinepin_walk_blend;
            xo -= m_cfg.pin_x_hip;
        }
        if (zo != 0.0f || xo != 0.0f) {
            Vector3f v{xo, 0.0f, -zo};
            if (i < m_spinepin_par_inv.size() && m_spinepin_par_inv[i]) {
                v = *m_spinepin_par_inv[i] * v;
            }
            p += v;
        }
        auto r = cur_rel[i].r;
        const auto hy = m_cfg.pin_hip_yaw;
        if (hy != 0.0f && (name == "Hip" || name == "Spine_0")) {
            Vector3f axis{0.0f, 1.0f, 0.0f};
            if (i < m_spinepin_par_inv.size() && m_spinepin_par_inv[i]) {
                axis = *m_spinepin_par_inv[i] * axis;
            }
            const auto ang = (name == "Hip") ? hy : -hy;
            r = glm::normalize(spin_axis_quat(axis.x, axis.y, axis.z, glm::radians(ang)) * r);
        }
        if (is_ub && m_cfg.pin_ub_yaw != 0.0f) {
            Vector3f axis{0.0f, 1.0f, 0.0f};
            if (i < m_spinepin_par_inv.size() && m_spinepin_par_inv[i]) {
                axis = *m_spinepin_par_inv[i] * axis;
            }
            r = glm::normalize(spin_axis_quat(axis.x, axis.y, axis.z, glm::radians(m_cfg.pin_ub_yaw)) * r);
        }
        if (name == "Spine_1" && m_cfg.pin_spine1_roll != 0.0f) {
            Vector3f axis{0.0f, 0.0f, 1.0f};
            if (i < m_spinepin_par_inv.size() && m_spinepin_par_inv[i]) {
                axis = *m_spinepin_par_inv[i] * axis;
            }
            r = glm::normalize(spin_axis_quat(axis.x, axis.y, axis.z, glm::radians(m_cfg.pin_spine1_roll)) * r);
        }
        pcall([&] {
            sdk::set_joint_local_position(j, Vector4f{p.x, p.y, p.z, 1.0f});
            sdk::set_joint_local_rotation(j, r);
        });
    }

    if (m_spinepin_null_off && m_spinepin_null_rel) {
        pcall([&] {
            sdk::set_joint_local_position(m_spinepin_null_off, Vector4f{m_spinepin_null_rel->p.x, m_spinepin_null_rel->p.y, m_spinepin_null_rel->p.z, 1.0f});
            sdk::set_joint_local_rotation(m_spinepin_null_off, m_spinepin_null_rel->r);
        });
    }
}

void RE4VRMovement::apply_ub_lock(bool can_capture) {
    if (!m_cfg.ub_lock) {
        m_ub_lock_has_pose = false;
        m_ub_lock_has_rel = false;
        m_ub_lock_base.valid = false;
        return;
    }
    if (is_ks_active()) {
        return;
    }
    auto* tf = get_body_transform();
    if (!tf) {
        return;
    }

    if (m_cfg.ub_lock_world) {
        auto brot = safe([&] { return sdk::get_transform_rotation(tf); });
        auto byaw = brot ? flat_yaw_of(*brot) : std::nullopt;
        if (!byaw) {
            return;
        }
        const auto bq = yaw_to_quat(*byaw);
        if (!m_ub_lock_has_rel) {
            if (!can_capture) {
                return;
            }
            const auto inv = glm::conjugate(bq);
            m_ub_lock_rel.clear();
            for (auto name : SPINE_YAW_JOINTS) {
                auto* j = get_spine_joint(tf, name);
                auto w = j ? safe([&] { return sdk::get_joint_rotation(j); }) : std::nullopt;
                if (!w) {
                    return;
                }
                m_ub_lock_rel[name] = glm::normalize(inv * *w);
            }
            m_ub_lock_has_rel = true;
        }
        glm::quat tq{1.0f, 0.0f, 0.0f, 0.0f};
        const bool has_trim = m_cfg.ub_trim_deg != 0.0f;
        if (has_trim) {
            const auto half = glm::radians(m_cfg.ub_trim_deg) * 0.5f;
            tq = glm::quat{std::cos(half), 0.0f, std::sin(half), 0.0f};
        }
        for (auto name : SPINE_YAW_JOINTS) {
            auto* j = get_spine_joint(tf, name);
            auto it = m_ub_lock_rel.find(name);
            if (!j || it == m_ub_lock_rel.end()) {
                continue;
            }
            const auto tgt = glm::normalize(has_trim ? (bq * tq * it->second) : (bq * it->second));
            pcall([&] { sdk::set_joint_rotation(j, tgt); });
        }
        return;
    }

    if (!m_ub_lock_has_pose) {
        if (!can_capture) {
            return;
        }
        std::unordered_map<std::string, glm::quat> pose;
        for (auto name : SPINE_YAW_JOINTS) {
            auto* j = get_spine_joint(tf, name);
            auto lr = j ? safe([&] { return sdk::get_joint_local_rotation(j); }) : std::nullopt;
            if (!lr) {
                return;
            }
            pose[name] = *lr;
        }
        auto* j1 = get_spine_joint(tf, SPINE_YAW_JOINTS[0]);
        auto w1 = j1 ? safe([&] { return sdk::get_joint_rotation(j1); }) : std::nullopt;
        auto* p1j = j1 ? sdk::get_joint_parent(j1) : nullptr;
        auto p1 = p1j ? safe([&] { return sdk::get_joint_rotation(p1j); }) : std::nullopt;
        if (!w1 || !p1) {
            return;
        }
        m_ub_lock_pose = std::move(pose);
        m_ub_lock_has_pose = true;
        m_ub_lock_base = {m_ub_lock_pose[SPINE_YAW_JOINTS[0]], *p1, *w1, true};
        m_ub_trim_applied.reset();
    }

    if (m_ub_lock_base.valid && (!m_ub_trim_applied || *m_ub_trim_applied != m_cfg.ub_trim_deg)) {
        const char* first = SPINE_YAW_JOINTS[0];
        if (m_cfg.ub_trim_deg == 0.0f) {
            m_ub_lock_pose[first] = m_ub_lock_base.raw;
            m_ub_trim_applied = m_cfg.ub_trim_deg;
        } else {
            const auto half = glm::radians(m_cfg.ub_trim_deg) * 0.5f;
            const auto y = glm::quat{std::cos(half), 0.0f, std::sin(half), 0.0f};
            m_ub_lock_pose[first] = glm::normalize(glm::conjugate(m_ub_lock_base.parent) * y * m_ub_lock_base.world);
            m_ub_trim_applied = m_cfg.ub_trim_deg;
        }
    }

    for (auto name : SPINE_YAW_JOINTS) {
        auto* j = get_spine_joint(tf, name);
        auto it = m_ub_lock_pose.find(name);
        if (j && it != m_ub_lock_pose.end()) {
            pcall([&] { sdk::set_joint_local_rotation(j, it->second); });
        }
    }
}

void RE4VRMovement::apply_spine_yaw(::RETransform* tf) {
    if (m_cfg.spine_yaw_deg == 0.0f || !tf) {
        return;
    }
    const auto half = glm::radians(m_cfg.spine_yaw_deg) * 0.5f;
    const auto yaw_off = glm::quat{std::cos(half), 0.0f, std::sin(half), 0.0f};
    for (auto name : SPINE_YAW_JOINTS) {
        auto* j = get_spine_joint(tf, name);
        if (!j) {
            continue;
        }
        auto r = safe([&] { return sdk::get_joint_rotation(j); });
        if (!r) {
            continue;
        }
        auto last = m_spine_last_written.find(name);
        if (last != m_spine_last_written.end() && quat_approx_equal(*r, last->second)) {
            continue;
        }
        const auto nr = glm::normalize(yaw_off * *r);
        if (pcall([&] { sdk::set_joint_rotation(j, nr); })) {
            m_spine_last_written[name] = nr;
        }
    }
}

void RE4VRMovement::apply_crouch_ub_z(bool capture_base) {
    if (!m_cfg.spine_pin) {
        return;
    }
    if (m_crouchpin_rel) {
        return;
    }
    const auto z = m_cfg.pin_ub_z_crouch;
    if (z == 0.0f) {
        m_crouch_ubz_has_base = false;
        return;
    }
    if (is_ks_active()) {
        return;
    }
    if (!is_crouch_active()) {
        m_crouch_ubz_has_base = false;
        return;
    }
    auto* tf = get_body_transform();
    if (!tf || !spinepin_resolve(tf) || m_spinepin_joints.empty()) {
        return;
    }
    auto tr = safe([&] { return sdk::get_transform_rotation(tf); });
    if (!tr) {
        return;
    }
    const auto tri = glm::conjugate(*tr);

    if (capture_base) {
        m_crouch_ubz_base.clear();
        for (size_t i = 0; i < m_spinepin_names.size(); ++i) {
            if (is_ub_joint(m_spinepin_names[i])) {
                auto lp = safe([&] { return sdk::get_joint_local_position(m_spinepin_joints[i]); });
                if (lp) {
                    m_crouch_ubz_base[(int)i] = Vector3f{lp->x, lp->y, lp->z};
                }
            }
        }
        m_crouch_ubz_has_base = true;
    }
    if (!m_crouch_ubz_has_base) {
        return;
    }

    for (size_t i = 0; i < m_spinepin_names.size(); ++i) {
        auto bit = m_crouch_ubz_base.find((int)i);
        if (!is_ub_joint(m_spinepin_names[i]) || bit == m_crouch_ubz_base.end()) {
            continue;
        }
        Vector3f v{0.0f, 0.0f, -z};
        if (i > 0) {
            auto* parent = m_spinepin_joints[i - 1];
            auto pw = parent ? safe([&] { return sdk::get_joint_rotation(parent); }) : std::nullopt;
            if (pw) {
                const auto relp = glm::normalize(tri * *pw);
                v = glm::conjugate(relp) * v;
            }
        }
        const auto p = bit->second + v;
        pcall([&] { sdk::set_joint_local_position(m_spinepin_joints[i], Vector4f{p.x, p.y, p.z, 1.0f}); });
    }
}

void RE4VRMovement::apply_crouch_pin(bool can_capture) {
    if (!m_cfg.spine_pin) {
        return;
    }
    if (is_ks_active() || is_pin_release()) {
        return;
    }
    if (!is_crouch_active()) {
        m_crouchpin_capture_req = false;
        return;
    }

    auto* tf = get_body_transform();
    if (!tf) {
        return;
    }
    if (!m_spinepin_joints.empty() && !joint_alive(m_spinepin_joints[0])) {
        m_spinepin_tf = nullptr;
        m_spinepin_joints.clear();
        m_spinepin_null_off = nullptr;
    }
    if (!spinepin_resolve(tf)) {
        return;
    }

    if (m_crouchpin_capture_req) {
        if (can_capture) {
            std::vector<PinRel> r;
            std::vector<std::optional<glm::quat>> pi;
            std::optional<PinRel> nr;
            if (spinepin_capture(tf, r, pi, nr)) {
                m_crouchpin_rel = std::move(r);
                m_crouchpin_par_inv = std::move(pi);
                m_crouchpin_null_rel = nr;
                m_crouchpin_capture_req = false;
                spinepin_store(*m_crouchpin_rel, m_crouchpin_par_inv, m_crouchpin_null_rel, true);
            }
        }
        return;
    }

    if (!m_crouchpin_rel) {
        if (!m_crouchpin_cfg_tried) {
            m_crouchpin_cfg_tried = true;
            std::vector<PinRel> r;
            std::vector<std::optional<glm::quat>> pi;
            std::optional<PinRel> nr;
            if (spinepin_restore(true, r, pi, nr)) {
                m_crouchpin_rel = std::move(r);
                m_crouchpin_par_inv = std::move(pi);
                m_crouchpin_null_rel = nr;
            }
        }
        if (!m_crouchpin_rel) {
            RE4VRShared::get()->vr_surge_bridged = false;
            return;
        }
    }

    auto& cur_rel = *m_crouchpin_rel;
    const auto ubz = m_cfg.pin_ub_z_crouch;
    RE4VRShared::get()->re4_ub_z_delta = (double)(ubz - m_cfg.pin_ub_z);
    const auto hipz = m_cfg.pin_z_hip_crouch.value_or(pin_lookup(m_cfg.pin_z, "Hip"));

    RE4VRShared::get()->vr_surge_bridged = true;
    Vector3f anchor_p = (!cur_rel.empty()) ? cur_rel[0].p : Vector3f{};
    const auto sdx = (float)RE4VRShared::get()->vr_surge_dx.value_or(0.0);
    const auto sdz = (float)RE4VRShared::get()->vr_surge_dz.value_or(0.0);
    if (!cur_rel.empty() && (sdx != 0.0f || sdz != 0.0f)) {
        auto tr = safe([&] { return sdk::get_transform_rotation(tf); });
        if (tr) {
            anchor_p += glm::conjugate(*tr) * Vector3f{sdx, 0.0f, sdz};
        }
    }

    for (size_t i = 0; i < m_spinepin_joints.size() && i < cur_rel.size(); ++i) {
        auto p = (i == 0) ? anchor_p : cur_rel[i].p;
        const auto& name = m_spinepin_names[i];
        float zo = 0.0f;
        float xo = 0.0f;
        if (is_ub_joint(name)) {
            zo += ubz;
            xo += m_cfg.pin_ub_x_crouch;
        }
        if (name == "Hip") {
            zo += hipz;
        } else if (name == "Spine_0") {
            zo -= hipz;
        }
        if (zo != 0.0f || xo != 0.0f) {
            Vector3f v{xo, 0.0f, -zo};
            if (i < m_crouchpin_par_inv.size() && m_crouchpin_par_inv[i]) {
                v = *m_crouchpin_par_inv[i] * v;
            }
            p += v;
        }
        pcall([&] {
            sdk::set_joint_local_position(m_spinepin_joints[i], Vector4f{p.x, p.y, p.z, 1.0f});
            sdk::set_joint_local_rotation(m_spinepin_joints[i], cur_rel[i].r);
        });
    }
    if (m_spinepin_null_off && m_crouchpin_null_rel) {
        pcall([&] {
            sdk::set_joint_local_position(m_spinepin_null_off, Vector4f{m_crouchpin_null_rel->p.x, m_crouchpin_null_rel->p.y, m_crouchpin_null_rel->p.z, 1.0f});
            sdk::set_joint_local_rotation(m_spinepin_null_off, m_crouchpin_null_rel->r);
        });
    }
}

// ---- Hard yaw / roomscale / HMD ----

void RE4VRMovement::apply_hard_yaw(bool sample) {
    if (!m_cfg.enabled) {
        m_owned_yaw.reset();
        return;
    }
    if (is_ks_active()) {
        m_last_yaw_quat.reset();
        m_body_yaw_last_t.reset();
        m_owned_yaw.reset();
        return;
    }
    auto& vr = VR::get();
    if (!vr->is_hmd_active()) {
        m_owned_yaw.reset();
        return;
    }
    if (!sample) {
        return;
    }
    if (is_aim()) {
        m_body_yaw_last_t.reset();
        m_owned_yaw.reset();
        return;
    }

    auto* pcc = get_player_cam_controller();
    if (!pcc) {
        m_last_yaw_quat.reset();
        m_body_yaw_last_t.reset();
        m_owned_yaw.reset();
        return;
    }

    if (m_cfg.cam_body_rotate) {
        auto* tf = get_body_transform();
        if (!tf) {
            return;
        }
        auto body_rot = safe([&] { return sdk::get_transform_rotation(tf); });
        auto body_yaw = body_rot ? flat_yaw_of(*body_rot) : std::nullopt;
        if (!body_yaw) {
            return;
        }
        if (!m_owned_yaw) {
            m_owned_yaw = *body_yaw;
        }
        auto* cam = sdk::get_primary_camera();
        auto wm = cam ? safe([&] { return sdk::call_object_func_easy<Matrix4x4f>(cam, "get_WorldMatrix"); }) : std::nullopt;
        if (!wm) {
            return;
        }
        float tfx = -(*wm)[2].x;
        float tfz = -(*wm)[2].z;
        auto tlen = std::sqrt(tfx * tfx + tfz * tfz);
        if (tlen < 0.0001f) {
            return;
        }
        tfx /= tlen;
        tfz /= tlen;
        auto target_yaw = std::atan2(tfx, tfz);
        if (auto hy = flat_yaw_of(hmd_quat())) {
            target_yaw += *hy;
        }
        if (m_cfg.yaw_offset_deg != 0.0f) {
            target_yaw += glm::radians(m_cfg.yaw_offset_deg);
        }
        tfx = std::sin(target_yaw);
        tfz = std::cos(target_yaw);

        double dt = 0.011;
        const auto now = now_clock();
        if (m_body_yaw_last_t) {
            dt = now - *m_body_yaw_last_t;
            if (dt <= 0.0) dt = 0.011;
            else if (dt > 0.1) dt = 0.1;
        }
        m_body_yaw_last_t = now;

        float pfx = std::sin(*m_owned_yaw);
        float pfz = std::cos(*m_owned_yaw);
        const auto dot = pfx * tfx + pfz * tfz;
        const auto crossY = pfz * tfx - pfx * tfz;
        const auto angle = std::atan2(crossY, dot);
        const auto deg = glm::degrees(angle);
        if (std::abs(deg) >= 0.001f) {
            const float perpx = pfz, perpz = -pfx;
            const float s = (angle > 0.0f) ? 1.0f : -1.0f;
            const float prx = -s * perpx, prz = -s * perpz;
            const float k = (std::abs(deg) / 720.0f) * (float)dt * m_cfg.body_yaw_speed;
            float nfx = pfx + (pfx - prx) * k;
            float nfz = pfz + (pfz - prz) * k;
            const auto nlen = std::sqrt(nfx * nfx + nfz * nfz);
            if (nlen >= 0.00001f) {
                m_owned_yaw = std::atan2(nfx / nlen, nfz / nlen);
                m_owned_yaw = hmd_wrap(*m_owned_yaw);
            }
        }
        m_last_yaw_quat = yaw_to_quat(*m_owned_yaw);
        auto diff = *m_owned_yaw - *body_yaw;
        diff = hmd_wrap(diff);
        glm::quat q = yaw_to_quat(*m_owned_yaw);
        if (std::abs(diff) >= glm::radians(BODY_YAW_EPS_DEG)) {
            pcall([&] { sdk::set_transform_rotation(tf, q); });
        }
        apply_hip_follow(tf, q);
        return;
    }

    const bool pin_hard = m_cfg.spine_pin && m_spinepin_rel.has_value();
    Vector3f fwd{};
    if (m_cfg.yaw_hmd_target || pin_hard) {
        auto* cam = sdk::get_primary_camera();
        auto wm = cam ? safe([&] { return sdk::call_object_func_easy<Matrix4x4f>(cam, "get_WorldMatrix"); }) : std::nullopt;
        if (!wm) {
            return;
        }
        fwd = Vector3f{(*wm)[2].x, 0.0f, (*wm)[2].z};
    } else {
        auto* cam_rot = sdk::get_object_field<glm::quat>(pcc, "_CameraRotation");
        if (!cam_rot) {
            return;
        }
        fwd = *cam_rot * Vector3f{0.0f, 0.0f, 1.0f};
        fwd.y = 0.0f;
    }
    const auto len = std::sqrt(fwd.x * fwd.x + fwd.z * fwd.z);
    if (len < 0.0001f) {
        return;
    }
    fwd = Vector3f{-fwd.x / len, 0.0f, -fwd.z / len};
    auto yaw_quat = utility::math::to_quat(fwd);
    if (m_cfg.yaw_offset_deg != 0.0f) {
        const auto half = glm::radians(m_cfg.yaw_offset_deg) * 0.5f;
        yaw_quat = glm::normalize(glm::quat{std::cos(half), 0.0f, std::sin(half), 0.0f} * yaw_quat);
    }
    m_last_yaw_quat = yaw_quat;

    double dt = 0.011;
    const auto now = now_clock();
    if (m_body_yaw_last_t) {
        dt = now - *m_body_yaw_last_t;
        if (dt <= 0.0) dt = 0.011;
        else if (dt > 0.1) dt = 0.1;
    }
    m_body_yaw_last_t = now;

    auto* tf = get_body_transform();
    if (!tf) {
        return;
    }
    auto body_rot = safe([&] { return sdk::get_transform_rotation(tf); });
    auto body_yaw = body_rot ? flat_yaw_of(*body_rot) : std::nullopt;
    if (!body_yaw) {
        return;
    }
    if (!m_owned_yaw) {
        m_owned_yaw = *body_yaw;
    }
    const auto tfwd = yaw_quat * Vector3f{0.0f, 0.0f, 1.0f};
    const auto target_yaw = std::atan2(tfwd.x, tfwd.z);
    auto d = hmd_wrap(target_yaw - *m_owned_yaw);
    if (std::abs(d) >= glm::radians(BODY_YAW_EPS_DEG)) {
        float k = (float)dt * m_cfg.body_yaw_speed;
        if (k > 1.0f) k = 1.0f;
        if (pin_hard) k = 1.0f;
        m_owned_yaw = hmd_wrap(*m_owned_yaw + d * k);
    }
    auto diff = hmd_wrap(*m_owned_yaw - *body_yaw);
    glm::quat q = yaw_to_quat(*m_owned_yaw);
    if (std::abs(diff) >= glm::radians(BODY_YAW_EPS_DEG)) {
        pcall([&] { sdk::set_transform_rotation(tf, q); });
    }
    apply_hip_follow(tf, q);
}

void RE4VRMovement::enforce_hard_yaw() {
    if (!m_owned_yaw || !m_cfg.enabled || is_ks_active() || is_aim()) {
        return;
    }
    auto* tf = get_body_transform();
    if (!tf) {
        return;
    }
    auto body_rot = safe([&] { return sdk::get_transform_rotation(tf); });
    auto body_yaw = body_rot ? flat_yaw_of(*body_rot) : std::nullopt;
    if (!body_yaw) {
        return;
    }
    const auto diff = hmd_wrap(*m_owned_yaw - *body_yaw);
    if (std::abs(diff) < glm::radians(BODY_YAW_EPS_DEG)) {
        return;
    }
    pcall([&] { sdk::set_transform_rotation(tf, yaw_to_quat(*m_owned_yaw)); });
}

void RE4VRMovement::apply_auto_center() {
    auto& vr = VR::get();
    if (!vr->is_hmd_active()) {
        return;
    }
    auto* ctx = re4vr::player_context();
    if (!ctx || ctx == m_auto_center_ctx) {
        return;
    }
    auto hmd = vr->get_position(0);
    auto so = vr->get_standing_origin();
    m_auto_center_ctx = ctx;
    so.x = hmd.x;
    so.z = hmd.z;
    vr->set_standing_origin(so);
}

void RE4VRMovement::roomscale_recenter() {
    auto& vr = VR::get();
    auto hmd = vr->get_position(0);
    auto so = vr->get_standing_origin();
    so.x = hmd.x;
    so.z = hmd.z;
    vr->set_standing_origin(so);
}

void RE4VRMovement::roomscale_recenter_events() {
    if (!(m_cfg.roomscale && m_cfg.rs_recenter)) {
        m_rs_prev_ks = false;
        m_rs_prev_pos.reset();
        return;
    }
    const auto ks = is_ks_active();
    if (m_rs_prev_ks && !ks) {
        roomscale_recenter();
    }
    m_rs_prev_ks = ks;
    if (ks) {
        m_rs_prev_pos.reset();
        return;
    }
    auto* tf = get_body_transform();
    auto pos = tf ? safe([&] { return sdk::get_transform_position(tf); }) : std::nullopt;
    if (!pos) {
        m_rs_prev_pos.reset();
        return;
    }
    if (m_rs_prev_pos) {
        const auto dx = pos->x - m_rs_prev_pos->x;
        const auto dz = pos->z - m_rs_prev_pos->z;
        if (dx * dx + dz * dz > 9.0f) {
            roomscale_recenter();
        }
    }
    m_rs_prev_pos = Vector3f{pos->x, 0.0f, pos->z};
}

void RE4VRMovement::roomscale_crouch() {
    if (!(m_cfg.roomscale && m_cfg.rs_crouch) || is_ks_active() || !pure_gameplay_only()) {
        return;
    }
    if (m_cfg.rs_stand_height < 0.5f) {
        return;
    }
    auto& vr = VR::get();
    const auto hmd = vr->get_position(0);
    const auto down_at = m_cfg.rs_stand_height * (1.0f - m_cfg.rs_crouch_pct);
    const auto up_at = m_cfg.rs_stand_height * (1.0f - m_cfg.rs_crouch_pct * 0.6f);
    std::optional<bool> want;
    if (hmd.y < down_at) want = true;
    else if (hmd.y > up_at) want = false;
    else return;
    if (*want == is_crouch_active()) {
        return;
    }
    const auto now = now_clock();
    if (now < m_rs_crouch_next_t) {
        return;
    }
    m_rs_crouch_next_t = now + 0.6;
    RE4VRShared::get()->re4_want_crouch_press = true;
}

void RE4VRMovement::apply_hmd_body_follow() {
    if (!m_cfg.enabled || !m_cfg.hmd_follow || is_ks_active()) {
        return;
    }
    auto& vr = VR::get();
    if (!vr->is_hmd_active() || !get_player_cam_controller()) {
        return;
    }
    auto hmd = vr->get_position(0);
    auto so = vr->get_standing_origin();
    float dx = hmd.x - so.x;
    float dz = hmd.z - so.z;
    float dist2 = dx * dx + dz * dz;

    bool rs_delta = false;
    if (m_cfg.roomscale && !m_cfg.rs_lean && m_rs_prev_hmd) {
        dx = hmd.x - m_rs_prev_hmd->x;
        dz = hmd.z - m_rs_prev_hmd->z;
        dist2 = dx * dx + dz * dz;
        rs_delta = true;
        if (dist2 > 0.04f) {
            m_rs_prev_hmd = Vector3f{hmd.x, 0.0f, hmd.z};
            return;
        }
    }
    float dead = m_cfg.hmd_follow_deadzone;
    if (m_cfg.roomscale && m_cfg.rs_lean) {
        dead = std::max(dead, m_cfg.rs_lean_radius);
    }
    if (rs_delta) {
        dead = 0.0002f;
    }
    if (dist2 < dead * dead) {
        return;
    }

    auto dist = std::sqrt(dist2);
    float knee = (dist - dead) / dist;
    if (m_cfg.roomscale && !m_cfg.rs_lean) knee = 1.0f;
    if (rs_delta) knee = 1.0f;
    dx *= knee;
    dz *= knee;

    float alpha = m_cfg.roomscale ? 1.0f : m_cfg.hmd_follow_alpha;
    if (alpha > 0.99f) alpha = 0.99f;
    else if (alpha < 0.01f) alpha = 0.01f;
    const auto now = now_clock();
    double dt = m_hmd_follow_last_t ? std::min(now - *m_hmd_follow_last_t, 0.1) : 0.016;
    m_hmd_follow_last_t = now;
    float a = 1.0f - std::exp(std::log(1.0f - alpha) * (float)dt * 60.0f);
    if (rs_delta) a = 1.0f;
    dx *= a;
    dz *= a;

    Vector3f delta{dx, 0.0f, dz};
    delta = quat_rotate_vec3(vr->get_rotation_offset(), delta);

    auto* cam = sdk::get_primary_camera();
    auto* cam_go = cam ? safe([&] { return sdk::call_object_func_easy<::REGameObject*>(cam, "get_GameObject"); }).value_or(nullptr) : nullptr;
    auto* cam_tf = cam_go ? safe([&] { return sdk::call_object_func_easy<::RETransform*>(cam_go, "get_Transform"); }).value_or(nullptr) : nullptr;
    auto cam_rot = cam_tf ? safe([&] { return sdk::get_transform_rotation(cam_tf); }) : std::nullopt;
    if (!cam_rot) {
        return;
    }
    if (m_cfg.roomscale) {
        if (auto cyaw = flat_yaw_of(*cam_rot)) {
            *cam_rot = yaw_to_quat(*cyaw);
        }
    }
    delta = quat_rotate_vec3(*cam_rot, delta);
    delta.y = 0.0f;

    auto* tf = get_body_transform();
    if (!tf) {
        return;
    }
    auto pos = safe([&] { return sdk::get_transform_position(tf); });
    if (!pos) {
        return;
    }
    if (m_cfg.roomscale) {
        m_rs_pending.x += delta.x;
        m_rs_pending.z += delta.z;
    } else {
        pcall([&] { sdk::set_transform_position(tf, Vector4f{pos->x + delta.x, pos->y, pos->z + delta.z, 1.0f}); });
    }
    so.x += dx;
    so.z += dz;
    vr->set_standing_origin(so);
    m_rs_prev_hmd = Vector3f{hmd.x, 0.0f, hmd.z};
}

void RE4VRMovement::roomscale_flush_body() {
    if (!m_cfg.roomscale) {
        m_rs_pending.x = m_rs_pending.z = 0.0f;
        return;
    }
    if (m_rs_pending.x == 0.0f && m_rs_pending.z == 0.0f) {
        return;
    }
    auto* tf = get_body_transform();
    if (!tf) {
        m_rs_pending.x = m_rs_pending.z = 0.0f;
        return;
    }
    auto pos = safe([&] { return sdk::get_transform_position(tf); });
    if (!pos) {
        m_rs_pending.x = m_rs_pending.z = 0.0f;
        return;
    }
    pcall([&] { sdk::set_transform_position(tf, Vector4f{pos->x + m_rs_pending.x, pos->y, pos->z + m_rs_pending.z, 1.0f}); });
    m_rs_pending.x = m_rs_pending.z = 0.0f;
}

RE4VRMovement::ScopeSlot* RE4VRMovement::active_scope_slot() {
    auto wnum = RE4VRShared::get()->re4_scope_wid;
    if (!wnum) {
        return nullptr;
    }
    int w = (int)*wnum;
    if (RE4VRShared::get()->re4_ada_uses_leon_scope) {
        if (w == 6105) w = 4401;
        else if (w == 6114) w = 4400;
    }
    const auto ws = std::to_string(w);
    auto wit = m_cfg.scope_sets.find(ws);
    if (wit == m_cfg.scope_sets.end()) {
        return nullptr;
    }
    auto state = RE4VRShared::get()->re4_scope_id.value_or("ironsight");
    auto sit = wit->second.find(state);
    if (sit == wit->second.end()) {
        sit = wit->second.find("ironsight");
    }
    if (sit == wit->second.end()) {
        return nullptr;
    }
    return &sit->second;
}

void RE4VRMovement::drive_hmd_yaw() {
    auto& vr = VR::get();
    if (!RE4VRShared::get()->re4_force_killswitch_scope) {
        m_scope_pitch_base.reset();
    }
    if (RE4VRShared::get()->re4_force_killswitch_scope) {
        const auto hq = hmd_quat();
        auto off = glm::conjugate(hq);
        if (auto ap = RE4VRShared::get()->re4_scope_aim_pitch) {
            const auto delta = (float)*ap * SCOPE_PITCH_SIGN * m_cfg.scope_pitch_gain;
            const auto h = glm::radians(delta) * 0.5f;
            const auto pq = glm::quat{std::cos(h), std::sin(h), 0.0f, 0.0f};
            off = glm::normalize(pq * off);
        }
        vr->set_rotation_offset(off);
        auto hmd = vr->get_position(0);
        auto so = vr->get_standing_origin();
        auto* sset = active_scope_slot();
        RE4VRShared::get()->re4_scope_eye = 0.0;
        const float eye_x = sset ? sset->x_r : 0.0f;
        const float eye_z = sset ? sset->z_r : 0.0f;
        const auto pre = glm::conjugate(off) * Vector3f{eye_x, 0.0f, eye_z};
        so.x = hmd.x - pre.x;
        so.y = hmd.y - pre.y;
        so.z = hmd.z - pre.z;
        vr->set_standing_origin(so);
        const bool mp = vr->is_using_multipass();
        const bool xr = vr->is_openxr_loaded();
        float gain = 0.0f;
        if (mp) gain = 0.0f;
        else if (xr) gain = m_cfg.scope_yaw_xr;
        else gain = sset ? sset->yaw : 0.0f;
        RE4VRShared::get()->re4_scope_bullet_yaw = (double)(eye_x * gain);
        RE4VRShared::get()->re4_scope_bullet_src = std::string{mp ? "multipass" : (xr ? "openxr" : "openvr")};
        m_hmd_yaw_prev.reset();
        return;
    }

    const bool active = m_cfg.hmd_yaw_drive && vr->is_hmd_active() && !is_ks_active();
    if (!active) {
        m_hmd_yaw_prev.reset();
        if (!RE4VRShared::get()->vr_recenter_hold) {
            vr->set_rotation_offset(yaw_to_quat(0.0f));
        }
        return;
    }
    if (!m_hmd_yaw_pcc) {
        return;
    }
    auto hmd = flat_yaw_of(hmd_quat());
    if (!hmd) {
        return;
    }
    if (!m_hmd_yaw_prev) {
        m_hmd_yaw_prev = *hmd;
    }
    const auto d = hmd_wrap(*hmd - *m_hmd_yaw_prev);
    m_hmd_yaw_prev = *hmd;
    auto* yawf = sdk::get_object_field<float>(m_hmd_yaw_pcc, "_Yaw");
    std::optional<float> yaw_new;
    if (yawf) {
        yaw_new = hmd_wrap(*yawf + d);
        *yawf = *yaw_new;
    }
    if (yaw_new) {
        auto* cam_rot = sdk::get_object_field<glm::quat>(m_hmd_yaw_pcc, "_CameraRotation");
        auto cur = cam_rot ? flat_yaw_of(*cam_rot) : std::nullopt;
        if (cur) {
            const auto dyaw = hmd_wrap((*yaw_new + glm::pi<float>()) - *cur);
            *cam_rot = yaw_to_quat(dyaw) * *cam_rot;
            if (auto* main = sdk::get_object_field<::REManagedObject*>(m_hmd_yaw_pcc, "_MainCameraController")) {
                if (obj_ok(*main)) {
                    if (auto* mcr = sdk::get_object_field<glm::quat>(*main, "_CameraRotation")) {
                        *mcr = *cam_rot;
                    }
                }
            }
        }
    }
    vr->set_rotation_offset(yaw_to_quat(-*hmd));
}

void RE4VRMovement::apply_pose_freeze(bool on) {
    auto& vr = VR::get();
    const auto want_mode = m_cfg.scope_submit_mode;
    if (!m_pose_submit_now || *m_pose_submit_now != want_mode) {
        vr->set_pose_freeze_submit(want_mode);
        m_pose_submit_now = want_mode;
    }
    if (on == m_pose_freeze_now) {
        return;
    }
    vr->set_pose_freeze(on);
    m_pose_freeze_now = on;
}

void RE4VRMovement::apply_scope_freeze_late() {
    if (!RE4VRShared::get()->re4_force_killswitch_scope) {
        apply_pose_freeze(false);
        return;
    }
    apply_pose_freeze(true);
    auto& vr = VR::get();
    auto off = glm::conjugate(hmd_quat());
    if (auto ap = RE4VRShared::get()->re4_scope_aim_pitch) {
        const auto h = glm::radians((float)*ap * SCOPE_PITCH_SIGN * m_cfg.scope_pitch_gain) * 0.5f;
        off = glm::normalize(glm::quat{std::cos(h), std::sin(h), 0.0f, 0.0f} * off);
    }
    vr->set_rotation_offset(off);
    auto hmd = vr->get_position(0);
    auto so = vr->get_standing_origin();
    auto* sset = active_scope_slot();
    const float eye_x = sset ? sset->x_r : 0.0f;
    const float eye_z = sset ? sset->z_r : 0.0f;
    const auto pre = glm::conjugate(off) * Vector3f{eye_x, 0.0f, eye_z};
    so.x = hmd.x - pre.x;
    so.y = hmd.y - pre.y;
    so.z = hmd.z - pre.z;
    vr->set_standing_origin(so);
}

HookManager::PreHookResult RE4VRMovement::pre_update_camera_position(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    if (args.size() > 1) {
        get()->m_hmd_yaw_pcc = (::REManagedObject*)args[1];
    }
    return HookManager::PreHookResult::CALL_ORIGINAL;
}

void RE4VRMovement::post_update_camera_position(uintptr_t&, sdk::RETypeDefinition*, uintptr_t) {
    pcall([] { get()->drive_hmd_yaw(); });
}

// ---- Anim skip / grav / lag / squeeze ----

bool RE4VRMovement::apply_skip_nodes(const std::vector<const char*>& nodes, float frames, bool enable, bool overwrite_interp, ::REManagedObject** out_ctx) {
    ::REManagedObject* ctx = nullptr;
    auto* mfsm = get_motion_fsm(&ctx);
    if (out_ctx) {
        *out_ctx = ctx;
    }
    if (!obj_ok(mfsm)) {
        return false;
    }
    auto* layer = safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(mfsm, "getLayer", 0); }).value_or(nullptr);
    if (!layer) {
        return false;
    }
    auto* tree = ((sdk::behaviortree::CoreHandle*)layer)->get_tree_object();
    if (!tree) {
        return false;
    }
    bool touched = false;
    for (auto name : nodes) {
        auto* node = tree->get_node_by_name(name);
        if (!node) {
            continue;
        }
        auto acts = node->get_actions();
        if (acts.empty()) {
            acts = node->get_unloaded_actions();
        }
        for (auto* act : acts) {
            if (!obj_ok(act)) {
                continue;
            }
            auto* sf = sdk::get_object_field<float>(act, "_StartFrame");
            if (!sf) {
                continue;
            }
            if (enable) {
                auto* ef = sdk::get_object_field<float>(act, "_EndFrame");
                *sf = (ef && *ef > 0.0f) ? *ef : frames;
            } else {
                *sf = 0.0f;
            }
            if (auto* oi = sdk::get_object_field<bool>(act, "_OverwriteInterpolation")) {
                *oi = enable && overwrite_interp;
            }
            touched = true;
        }
    }
    return touched;
}

bool RE4VRMovement::apply_stop_skip(bool enable) {
    ::REManagedObject* ctx = nullptr;
    const auto touched = apply_skip_nodes(STOP_NODES, m_cfg.stop_skip_frames, enable, true, &ctx);
    if (touched) {
        m_stop_skip.applied = enable;
        m_stop_skip.last_ctx = ctx;
    }
    return touched;
}

bool RE4VRMovement::apply_start_skip(bool enable) {
    const auto t_walk = apply_skip_nodes(START_NODES, m_cfg.start_skip_frames, enable, true);
    ::REManagedObject* ctx = nullptr;
    const auto t_run = apply_skip_nodes(RUN_START_NODES, m_cfg.start_skip_frames, enable, false, &ctx);
    const auto touched = t_walk || t_run;
    if (touched) {
        m_start_skip.applied = enable;
        m_start_skip.last_ctx = ctx;
    }
    return touched;
}

bool RE4VRMovement::apply_no_pivot(bool disable) {
    ::REManagedObject* ctx = nullptr;
    auto* mfsm = get_motion_fsm(&ctx);
    if (!obj_ok(mfsm)) {
        return false;
    }
    auto* layer = safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(mfsm, "getLayer", 0); }).value_or(nullptr);
    if (!layer) {
        return false;
    }
    auto* tree = ((sdk::behaviortree::CoreHandle*)layer)->get_tree_object();
    if (!tree) {
        return false;
    }
    bool ok = pcall([&] {
        auto* node = tree->get_node_by_name("JogLoop");
        if (!node || !node->get_data()) {
            return;
        }
        auto& states = node->get_data()->get_states();
        while (disable && states.size() > 1) {
            states.erase(1);
        }
        while (!disable && states.size() <= 1) {
            states.emplace(false);
        }
        if (states.size() > 1) {
            states[1] = 109;
        }
    });
    pcall([&] {
        auto* node = tree->get_node_by_name("JogLoop");
        if (!node) {
            return;
        }
        auto children = node->get_children();
        if (children.size() < 2) {
            return;
        }
        auto* jloop = children[1];
        auto acts = jloop->get_actions();
        if (acts.empty()) {
            acts = jloop->get_unloaded_actions();
        }
        if (acts.empty() || !obj_ok(acts[0])) {
            return;
        }
        auto* damping = sdk::get_object_field<::REManagedObject*>(acts[0], "<DampingAngle>k__BackingField");
        if (damping && obj_ok(*damping)) {
            if (auto* t = sdk::get_object_field<float>(*damping, "_DampingTime")) {
                *t = disable ? 99.0f : 0.5f;
            }
        }
    });
    if (ok) {
        m_no_pivot.applied = disable;
        m_no_pivot.last_ctx = ctx;
    }
    return ok;
}

void RE4VRMovement::update_stop_skip() {
    ::REManagedObject* ctx = nullptr;
    get_motion_fsm(&ctx);
    if (!ctx) {
        return;
    }
    if (m_cfg.stop_skip && ctx != m_stop_skip.last_ctx) {
        apply_stop_skip(true);
    }
    if (m_cfg.start_skip && ctx != m_start_skip.last_ctx) {
        apply_start_skip(true);
    }
    if (m_cfg.no_pivot && ctx != m_no_pivot.last_ctx) {
        apply_no_pivot(true);
    }
}

void RE4VRMovement::update_anim_export() {
    auto* tf = get_body_transform();
    if (!tf) {
        RE4VRShared::get()->vr_anim_l0.reset();
        m_bw_motion = nullptr;
        return;
    }
    if (!obj_ok(m_bw_motion)) {
        auto* go = safe([&] { return sdk::call_object_func_easy<::REGameObject*>(tf, "get_GameObject"); }).value_or(nullptr);
        static auto* motion_td = sdk::find_type_definition("via.motion.Motion");
        if (go && motion_td) {
            m_bw_motion = safe([&] {
                return sdk::call_object_func_easy<::REManagedObject*>(go, "getComponent(System.Type)", motion_td->get_runtime_type());
            }).value_or(nullptr);
        }
    }
    if (!obj_ok(m_bw_motion)) {
        RE4VRShared::get()->vr_anim_l0.reset();
        return;
    }
    auto* layer = safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(m_bw_motion, "getLayer", 0); }).value_or(nullptr);
    auto* node = layer ? safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(layer, "get_HighestWeightMotionNode"); }).value_or(nullptr) : nullptr;
    auto* name = node ? safe([&] { return sdk::call_object_func_easy<::SystemString*>(node, "get_MotionName"); }).value_or(nullptr) : nullptr;
    if (name) {
        const auto s = utility::re_string::get_string(name);
        if (!s.empty()) {
            RE4VRShared::get()->vr_anim_l0 = std::string{s};
            return;
        }
    }
    RE4VRShared::get()->vr_anim_l0.reset();
    m_bw_motion = nullptr;
}

void RE4VRMovement::apply_grav_fix() {
    ::REManagedObject* c = nullptr;
    auto* ga = ground_adsorber(&c);
    if (!obj_ok(ga) || !obj_ok(c)) {
        return;
    }
    auto* curp = sdk::get_object_field<float>(ga, "_GravitationalAcceleration");
    if (!curp) {
        return;
    }
    const auto cur = *curp;
    if (!m_grav_orig && cur > 0.0f && cur < 100.0f) {
        m_grav_orig = cur;
    }
    if (!m_grav_orig) {
        return;
    }
    m_grav_active = false;
    if (m_cfg.grav_fix && pure_gameplay_only()) {
        const auto is_run = safe([&] { return sdk::call_object_func_easy<bool>(c, "get_IsRun"); }).value_or(false);
        const auto is_walk = safe([&] { return sdk::call_object_func_easy<bool>(c, "get_IsWalk"); }).value_or(false);
        const auto intensity = safe([&] { return sdk::call_object_func_easy<float>(c, "get_MoveIntensity"); }).value_or(0.0f);
        const auto moving = is_run || is_walk || intensity > 0.1f;
        const auto ladder = safe([&] { return sdk::call_object_func_easy<bool>(c, "get_IsLadder"); }).value_or(false);
        const auto jumping = safe([&] { return sdk::call_object_func_easy<bool>(c, "get_IsJumping"); }).value_or(false);
        if (moving && !ladder && !jumping) {
            m_grav_active = true;
            *curp = m_cfg.grav_value;
            return;
        }
    }
    if (std::abs(cur - *m_grav_orig) > 0.01f) {
        *curp = *m_grav_orig;
    }
}

float RE4VRMovement::lag_pad_axis() {
    auto* gp = sdk::get_native_singleton("via.hid.GamePad");
    auto* pad_td = sdk::find_type_definition("via.hid.GamePad");
    if (!gp || !pad_td) {
        return 0.0f;
    }
    auto* pad = safe([&] { return sdk::call_native_func_easy<::REManagedObject*>(gp, pad_td, "get_LastInputDevice"); }).value_or(nullptr);
    if (!obj_ok(pad)) {
        return 0.0f;
    }
    if (auto a = safe([&] { return sdk::call_object_func_easy<Vector2f>(pad, "get_AxisL"); })) {
        return std::sqrt(a->x * a->x + a->y * a->y);
    }
    if (auto a = safe([&] { return sdk::call_object_func_easy<Vector3f>(pad, "get_AxisL"); })) {
        return std::sqrt(a->x * a->x + a->y * a->y);
    }
    if (auto a = safe([&] { return sdk::call_object_func_easy<Vector4f>(pad, "get_AxisL"); })) {
        return std::sqrt(a->x * a->x + a->y * a->y);
    }
    return 0.0f;
}

void RE4VRMovement::apply_lag_fix() {
    if (!(m_cfg.lag_boost_on || m_cfg.lag_brake_on)) {
        return;
    }
    if (!pure_gameplay_only()) {
        m_lagm.last_pos.reset();
        m_lagm.last_t.reset();
        m_lagm.edge_t.reset();
        m_lagm.edge_kind = nullptr;
        m_lagm.pad_was = 0.0f;
        m_lagm.boost_now = 0.0f;
        m_lagm.brake_now = false;
        return;
    }
    ::REManagedObject* c = nullptr;
    auto* ga = ground_adsorber(&c);
    if (!obj_ok(c)) {
        return;
    }
    auto* go = safe([&] { return sdk::call_object_func_easy<::REGameObject*>(c, "get_BodyGameObject"); }).value_or(nullptr);
    auto* btf = go ? safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr) : nullptr;
    if (!btf) {
        return;
    }
    auto cur = safe([&] { return sdk::get_transform_position(btf); });
    if (!cur) {
        return;
    }
    const auto now = now_clock();
    double dt = m_lagm.last_t ? std::clamp(now - *m_lagm.last_t, 0.001, 0.1) : 0.016;
    m_lagm.last_t = now;
    float dx = 0.0f, dz = 0.0f;
    if (m_lagm.last_pos) {
        dx = cur->x - m_lagm.last_pos->x;
        dz = cur->z - m_lagm.last_pos->z;
    }
    const auto step = std::sqrt(dx * dx + dz * dz);
    m_lagm.spd = step / (float)dt;

    const auto pad = lag_pad_axis();
    if (pad >= 0.5f && m_lagm.pad_was < 0.5f) {
        m_lagm.edge_t = now;
        m_lagm.edge_kind = "START";
    } else if (pad < 0.15f && m_lagm.pad_was >= 0.15f) {
        m_lagm.edge_t = now;
        m_lagm.edge_kind = "STOP";
    }
    m_lagm.pad_was = pad;

    bool blocked = safe([&] { return sdk::call_object_func_easy<bool>(c, "get_IsLadder"); }).value_or(false)
        || safe([&] { return sdk::call_object_func_easy<bool>(c, "get_IsJumping"); }).value_or(false);
    if (obj_ok(ga)) {
        const auto ground = safe([&] { return sdk::call_object_func_easy<bool>(ga, "get_Ground"); }).value_or(true);
        if (!ground) {
            blocked = true;
        }
    }

    m_lagm.boost_now = 0.0f;
    m_lagm.brake_now = false;
    if (!blocked && m_lagm.edge_t) {
        const auto since = now - *m_lagm.edge_t;
        if (m_cfg.lag_boost_on && m_lagm.edge_kind && std::string_view{m_lagm.edge_kind} == "START" && pad >= 0.5f && since <= m_cfg.lag_boost_window) {
            const auto add = std::min(std::max(m_cfg.lag_boost_target - m_lagm.spd, 0.0f), m_cfg.lag_boost_max);
            if (add > 0.001f) {
                auto md4 = safe([&] { return sdk::call_object_func_easy<Vector4f>(c, "get_MoveDirection"); });
                Vector3f md{0.0f, 0.0f, 0.0f};
                if (md4) {
                    md = Vector3f{md4->x, md4->y, md4->z};
                } else if (auto md3 = safe([&] { return sdk::call_object_func_easy<Vector3f>(c, "get_MoveDirection"); })) {
                    md = *md3;
                }
                const auto ml = std::sqrt(md.x * md.x + md.z * md.z);
                if (ml > 1e-4f) {
                    const auto k = (add * (float)dt) / ml;
                    pcall([&] { sdk::set_transform_position(btf, Vector4f{cur->x + md.x * k, cur->y, cur->z + md.z * k, 1.0f}); });
                    m_lagm.boost_now = add;
                }
            }
        } else if (m_cfg.lag_brake_on && m_lagm.edge_kind && std::string_view{m_lagm.edge_kind} == "STOP" && pad < 0.15f
                   && since <= m_cfg.lag_brake_window && m_lagm.last_pos && step > 0.0001f) {
            const auto g = std::clamp(m_cfg.lag_brake_gain, 0.0f, 1.0f);
            pcall([&] { sdk::set_transform_position(btf, Vector4f{m_lagm.last_pos->x + dx * g, cur->y, m_lagm.last_pos->z + dz * g, 1.0f}); });
            m_lagm.brake_now = true;
        }
    }
    m_lagm.last_pos = safe([&] { return sdk::get_transform_position(btf); }).value_or(*cur);
}

bool RE4VRMovement::sqab_in_gimmick() {
    auto* sys = re4vr::camera_system();
    auto* main = sys ? safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(sys, "get_MainCameraController"); }).value_or(nullptr) : nullptr;
    auto* busy = main ? safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(main, "get_BusyCameraController"); }).value_or(nullptr) : nullptr;
    if (!obj_ok(busy) || !m_gimmick_cam_td) {
        return false;
    }
    return utility::re_managed_object::is_a(busy, "chainsaw.GimmickMotionCameraController");
}

Vector3f RE4VRMovement::sqab_body_pos() {
    auto* tf = get_body_transform();
    auto p = tf ? safe([&] { return sdk::get_transform_position(tf); }) : std::nullopt;
    return p ? Vector3f{p->x, p->y, p->z} : Vector3f{0, 0, 0};
}

void RE4VRMovement::sqab_tick() {
    const auto now = now_clock();
    const auto a = sqab_in_gimmick();
    auto* tf = get_body_transform();
    if (!tf) {
        return;
    }
    auto p = safe([&] { return sdk::get_transform_position(tf); });
    if (!p) {
        return;
    }
    const Vector3f pp{p->x, p->y, p->z};

    auto sq_end = RE4VRShared::get()->re4_sq_end_t.value_or(-999.0);
    auto sq_exit = RE4VRShared::get()->re4_sq_exit;

    auto dist = [](const Vector3f& A, const Vector3f& B) {
        const auto d = A - B;
        return std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
    };

    if (a && !m_sqab_active) {
        m_sqab_active = true;
        m_sqab_pin = false;
        const auto d_ex = sq_exit ? dist(pp, *sq_exit) : 1e9f;
        if ((now - sq_end) < SQAB_RETRIG_WINDOW && sq_exit && d_ex < SQAB_SAME_SPOT) {
            m_sqab_pin = true;
            m_sqab_pin_pos = sq_exit;
        }
        m_sqab_last = pp;
    }
    if (a) {
        if (m_sqab_pin && m_sqab_pin_pos) {
            pcall([&] { sdk::set_transform_position(tf, Vector4f{m_sqab_pin_pos->x, m_sqab_pin_pos->y, m_sqab_pin_pos->z, 1.0f}); });
        } else {
            m_sqab_last = pp;
        }
        return;
    }
    if (m_sqab_active && !a) {
        m_sqab_active = false;
        const auto exitp = (m_sqab_pin && m_sqab_pin_pos) ? *m_sqab_pin_pos : m_sqab_last.value_or(pp);
        RE4VRShared::get()->re4_sq_exit = exitp;
        RE4VRShared::get()->re4_sq_end_t = now;
        m_sqab_pin = false;
    }
}

bool RE4VRMovement::sqab_is_retrigger() {
    const auto dt = now_clock() - RE4VRShared::get()->re4_sq_end_t.value_or(-999.0);
    if (dt >= SQAB_RETRIG_WINDOW) {
        return false;
    }
    auto ex = RE4VRShared::get()->re4_sq_exit;
    const auto p = sqab_body_pos();
    if (!ex) {
        return false;
    }
    const auto d = p - *ex;
    const auto dist = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
    return dist < SQAB_SAME_SPOT;
}

HookManager::PreHookResult RE4VRMovement::pre_setup_jack_layer(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    auto& self = *get();
    self.m_sqab_skip_ret.reset();
    if (!self.sqab_is_retrigger()) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    auto* holder = args.size() > 1 ? (::REManagedObject*)args[1] : nullptr;
    if (!obj_ok(holder)) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    auto idx = safe([&] { return sdk::call_object_func_easy<int32_t>(holder, "get_JackLayerIndex"); });
    if (!idx) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    self.m_sqab_skip_ret = *idx;
    return HookManager::PreHookResult::SKIP_ORIGINAL;
}

void RE4VRMovement::post_setup_jack_layer(uintptr_t& ret_val, sdk::RETypeDefinition*, uintptr_t) {
    auto& self = *get();
    if (self.m_sqab_skip_ret) {
        ret_val = (uintptr_t)(int32_t)*self.m_sqab_skip_ret;
        self.m_sqab_skip_ret.reset();
    }
}

HookManager::PreHookResult RE4VRMovement::pre_start_jack_pl(std::vector<uintptr_t>&, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    if (get()->sqab_is_retrigger()) {
        return HookManager::PreHookResult::SKIP_ORIGINAL;
    }
    return HookManager::PreHookResult::CALL_ORIGINAL;
}

void RE4VRMovement::post_start_jack_pl(uintptr_t&, sdk::RETypeDefinition*, uintptr_t) {}

#endif
