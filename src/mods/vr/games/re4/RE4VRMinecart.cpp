#define NOMINMAX
#include "RE4VRMinecart.hpp"

#if defined(RE4)
#include <algorithm>
#include <cctype>
#include <cmath>

#include <glm/gtc/constants.hpp>
#include <glm/gtx/quaternion.hpp>
#include <sdk/RETypeDB.hpp>
#include <sdk/RETransform.hpp>
#include <sdk/REString.hpp>
#include <sdk/MurmurHash.hpp>
#include <sdk/Application.hpp>

#include "RE4VRFrameCache.hpp"
#include "RE4VRHolster.hpp"
#include "RE4VRShared.hpp"
#include "../../../ScriptRunner.hpp"

namespace {
const char* PIN_JOINTS[] = {"Hip", "Spine_0", "Spine_1", "Spine_2", "Neck_0", "Neck_1", "Head"};

::RETransform* body_tf() {
    if (RE4VRFrameCache::get()->on()) {
        return RE4VRFrameCache::get()->body_tf();
    }
    return re4vr::body_transform();
}

std::string motion_name(::REManagedObject* motion) {
    if (!motion) {
        return {};
    }
    auto* layer = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(motion, "getLayer", 0); }).value_or(nullptr);
    auto* node = layer ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(layer, "get_HighestWeightMotionNode"); }).value_or(nullptr) : nullptr;
    auto* nm = node ? re4vr::safe([&] { return sdk::call_object_func_easy<::SystemString*>(node, "get_MotionName"); }).value_or(nullptr) : nullptr;
    return nm ? utility::re_string::get_string(nm) : std::string{};
}
}

std::shared_ptr<RE4VRMinecart>& RE4VRMinecart::get() {
    static auto inst = std::make_shared<RE4VRMinecart>();
    return inst;
}

void RE4VRMinecart::load_json() {
    const auto d = re4vr::load_json_file("re4_vr/re4_vr_minecart.json");
    if (d.empty()) {
        return;
    }
    m_cfg.body_down = re4vr::j_num(d, "body_down", m_cfg.body_down);
    m_cfg.body_back = re4vr::j_num(d, "body_back", m_cfg.body_back);
    m_cfg.yaw_sign = re4vr::j_num(d, "yaw_sign", m_cfg.yaw_sign);
    m_cfg.lean_enabled = re4vr::j_bool(d, "lean_enabled", m_cfg.lean_enabled);
    m_cfg.lean_threshold = re4vr::j_num(d, "lean_threshold", m_cfg.lean_threshold);
    m_cfg.lean_full = re4vr::j_num(d, "lean_full", m_cfg.lean_full);
    m_cfg.lean_sign = re4vr::j_num(d, "lean_sign", m_cfg.lean_sign);
    m_cfg.lean_tilt_min = re4vr::j_num(d, "lean_tilt_min", m_cfg.lean_tilt_min);
    m_cfg.recenter_enabled = re4vr::j_bool(d, "recenter_enabled", m_cfg.recenter_enabled);
    m_cfg.recenter_dead = re4vr::j_num(d, "recenter_dead", m_cfg.recenter_dead);
    m_cfg.recenter_rate = re4vr::j_num(d, "recenter_rate", m_cfg.recenter_rate);
    m_cfg.rumble_enabled = re4vr::j_bool(d, "rumble_enabled", m_cfg.rumble_enabled);
    m_cfg.rumble_amp = re4vr::j_num(d, "rumble_amp", m_cfg.rumble_amp);
    m_cfg.rumble_rate = re4vr::j_num(d, "rumble_rate", m_cfg.rumble_rate);
    m_cfg.rumble_dur = re4vr::j_num(d, "rumble_dur", m_cfg.rumble_dur);
    m_cfg.rumble_freq = re4vr::j_num(d, "rumble_freq", m_cfg.rumble_freq);
    m_cfg.rumble_clack = re4vr::j_bool(d, "rumble_clack", m_cfg.rumble_clack);
    m_cfg.rumble_clack_every = re4vr::j_num(d, "rumble_clack_every", m_cfg.rumble_clack_every);
    m_cfg.rumble_clack_amp = re4vr::j_num(d, "rumble_clack_amp", m_cfg.rumble_clack_amp);
    m_cfg.rumble_intro = re4vr::j_bool(d, "rumble_intro", m_cfg.rumble_intro);
    m_cfg.rumble_speed_min = re4vr::j_num(d, "rumble_speed_min", m_cfg.rumble_speed_min);
    m_cfg.rumble_speed_full = re4vr::j_num(d, "rumble_speed_full", m_cfg.rumble_speed_full);
    m_cfg.rumble_speed_scale = re4vr::j_bool(d, "rumble_speed_scale", m_cfg.rumble_speed_scale);
}

bool RE4VRMinecart::railcar_active() {
    return RE4VRShared::get()->re4_railcar_mode;
}

void RE4VRMinecart::load_pin_pose() {
    if (m_pin_tried && !m_pin_map.empty()) {
        return;
    }
    m_pin_tried = true;
    const auto d = re4vr::load_json_file("re4_vr/re4_vr_movement.json");
    if (!d.contains("pin_pose") || !d["pin_pose"].is_object()) {
        return;
    }
    const auto& pp = d["pin_pose"];
    if (!pp.contains("joints") || !pp["joints"].is_object()) {
        return;
    }
    for (auto it = pp["joints"].begin(); it != pp["joints"].end(); ++it) {
        const auto& s = it.value();
        if (!s.is_object() || !s.contains("px") || !s.contains("rw")) {
            continue;
        }
        PinJoint j;
        j.p = Vector3f{re4vr::j_num(s, "px", 0), re4vr::j_num(s, "py", 0), re4vr::j_num(s, "pz", 0)};
        j.r = glm::quat{re4vr::j_num(s, "rw", 1), re4vr::j_num(s, "rx", 0), re4vr::j_num(s, "ry", 0), re4vr::j_num(s, "rz", 0)};
        m_pin_map[it.key()] = j;
    }
}

bool RE4VRMinecart::resolve_spine(::RETransform* tf) {
    if (m_pin_tf == tf && !m_pin_joints.empty()) {
        if (m_pin_joints[0] && re4vr::safe([&] { sdk::get_joint_position(m_pin_joints[0]); return true; }).value_or(false)) {
            return true;
        }
    }
    m_pin_tf = tf;
    m_pin_joints.clear();
    m_pin_names.clear();
    for (const auto* name : PIN_JOINTS) {
        auto* j = re4vr::joint_by_name(tf, name);
        if (j) {
            m_pin_joints.push_back(j);
            m_pin_names.emplace_back(name);
        }
    }
    return !m_pin_joints.empty();
}

void RE4VRMinecart::apply_spine_pin() {
    if (!railcar_active()) {
        return;
    }
    const float f = (float)RE4VRShared::get()->re4_railcar_reload_fade.value_or(1.0);
    if (f <= 0.0f) {
        return;
    }
    load_pin_pose();
    if (m_pin_map.empty()) {
        return;
    }
    auto* tf = body_tf();
    if (!tf || !resolve_spine(tf)) {
        return;
    }
    const float down = m_cfg.body_down;
    const float back = m_cfg.body_back;
    for (size_t i = 0; i < m_pin_joints.size(); ++i) {
        auto it = m_pin_map.find(m_pin_names[i]);
        if (it == m_pin_map.end()) {
            continue;
        }
        auto p = it->second.p;
        auto r = it->second.r;
        if (m_pin_names[i] == "Hip" && (down != 0.0f || back != 0.0f)) {
            p = Vector3f{p.x, p.y - down, p.z - back};
        }
        auto* j = m_pin_joints[i];
        re4vr::pcall([&] {
            if (f < 1.0f) {
                const auto cp = sdk::get_joint_local_position(j);
                p = Vector3f{cp.x + (p.x - cp.x) * f, cp.y + (p.y - cp.y) * f, cp.z + (p.z - cp.z) * f};
                const auto cr = sdk::get_joint_local_rotation(j);
                r = glm::slerp(cr, it->second.r, f);
            }
            sdk::set_joint_local_position(j, Vector4f{p.x, p.y, p.z, 1.0f});
            sdk::set_joint_local_rotation(j, r);
        });
    }
}

void RE4VRMinecart::update_anim_export() {
    auto* tf = body_tf();
    if (!tf) {
        RE4VRShared::get()->vr_anim_l0.reset();
        m_bw_motion = nullptr;
        return;
    }
    auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(tf, "get_GameObject"); }).value_or(nullptr);
    if (go != m_bw_go) {
        m_bw_go = go;
        m_bw_motion = nullptr;
    }
    if (!m_bw_motion && go) {
        m_bw_motion = re4vr::get_component((::REManagedObject*)go, "via.motion.Motion");
    }
    const auto name = motion_name(m_bw_motion);
    if (name.empty()) {
        RE4VRShared::get()->vr_anim_l0.reset();
    } else {
        RE4VRShared::get()->vr_anim_l0 = std::string{name};
    }
}

void RE4VRMinecart::update_reload_flag() {
    bool reloading = false;
    auto* pe = RE4VRFrameCache::get()->pe();
    auto* weapon = pe ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(pe, "getEquipWeapon"); }).value_or(nullptr) : nullptr;
    auto* wgo = weapon ? re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(weapon, "get_GameObject"); }).value_or(nullptr) : nullptr;
    if (wgo != m_wep_go) {
        m_wep_go = wgo;
        m_wep_mo = nullptr;
    }
    if (!m_wep_mo && wgo) {
        m_wep_mo = re4vr::get_component((::REManagedObject*)wgo, "via.motion.Motion");
    }
    auto nm = motion_name(m_wep_mo);
    std::transform(nm.begin(), nm.end(), nm.begin(), [](unsigned char c) { return (char)std::tolower(c); });
    if (nm.find("reload") != std::string::npos) {
        reloading = true;
    }
    RE4VRShared::get()->re4_railcar_reloading = reloading;
    float f = (float)RE4VRShared::get()->re4_railcar_reload_fade.value_or(1.0);
    if (reloading) {
        if (f > 0.0f) {
            RE4VRShared::get()->re4_railcar_reload_fade = std::max(0.0f, f - 0.09f);
        }
        RE4VRShared::get()->re4_reload_hand_fp = false;
        RE4VRShared::get()->re4_reload_hand_fr = false;
    } else if (f < 1.0f) {
        RE4VRShared::get()->re4_railcar_reload_fade = std::min(1.0f, f + 0.09f);
    }
}

void RE4VRMinecart::force_crosshair() {
    if (!railcar_active()) {
        return;
    }
    RE4VRShared::get()->is_reticle_displayed = true;
    RE4VRShared::get()->is_aim = true;
}

void RE4VRMinecart::update_yaw_follow() {
    m_cfg.yaw_follow = false;
    m_yf_entry_body.reset();
    RE4VRShared::get()->re4_railcar_yaw_delta = false;
}

void RE4VRMinecart::cart_knife_swap() {
    const bool in_cart = railcar_active() || RE4VRShared::get()->re4_minecart_ks4_active || RE4VRShared::get()->re4_minecart2_ks4_active;
    if (!in_cart) {
        return;
    }
    const double now = re4vr::now();
    if (now - m_ck_last < 0.4) {
        return;
    }
    m_ck_last = now;
    RE4VRHolster::get()->defer([]() { RE4VRHolster::get()->force_change_to_main(); });
}

::REManagedObject* RE4VRMinecart::get_player_railcar() {
    if (!re4vr::obj_ok(m_rail_manager)) {
        m_rail_manager = sdk::get_managed_singleton<::REManagedObject>("chainsaw.RailCarManager");
    }
    if (!m_rail_manager) {
        return nullptr;
    }
    return re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(m_rail_manager, "getPlayerRailCar"); }).value_or(nullptr);
}

void RE4VRMinecart::update_cart_lean() {
    RE4VRShared::get()->re4_cart_lean_lx.reset();
    if (!m_cfg.lean_enabled || !railcar_active()) {
        return;
    }
    auto* car = get_player_railcar();
    if (!car) {
        return;
    }
    auto tilt = re4vr::safe([&] { return sdk::call_object_func_easy<float>(car, "get_Tilt"); });
    if (!tilt) {
        return;
    }
    const bool returning = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(car, "get_ReturnTilt"); }).value_or(false);
    if (std::abs(*tilt) < m_cfg.lean_tilt_min || returning) {
        return;
    }
    auto& vr = VR::get();
    const auto q = glm::quat{vr->get_transform(0)};
    const auto right = glm::rotate(q, Vector3f{1.0f, 0.0f, 0.0f});
    const float roll = -right.y;
    const float th = m_cfg.lean_threshold;
    const float full = std::max(th + 0.01f, m_cfg.lean_full);
    const float mag = std::abs(roll);
    if (mag < th) {
        return;
    }
    float amt = (mag - th) / (full - th);
    amt = std::min(amt, 1.0f);
    const float out = amt * ((roll >= 0.0f) ? 1.0f : -1.0f) * m_cfg.lean_sign;
    RE4VRShared::get()->re4_cart_lean_lx = out;
}

void RE4VRMinecart::update_cart_recenter() {
    if (!m_cfg.recenter_enabled || !railcar_active() || !VR::get()->is_hmd_active()) {
        m_rc_last_t.reset();
        return;
    }
    const double now = re4vr::now();
    const double dt = m_rc_last_t ? (now - *m_rc_last_t) : 0.0;
    m_rc_last_t = now;
    if (dt <= 0.0 || dt > 0.25) {
        return;
    }
    auto& vr = VR::get();
    auto hmd = vr->get_position(0);
    auto so = vr->get_standing_origin();
    const float dx = hmd.x - so.x, dz = hmd.z - so.z;
    const float dist = std::sqrt(dx * dx + dz * dz);
    if (dist <= m_cfg.recenter_dead) {
        return;
    }
    const float step = std::min(m_cfg.recenter_rate * (float)dt, dist - m_cfg.recenter_dead);
    if (step <= 0.0f) {
        return;
    }
    so.x += (dx / dist) * step;
    so.z += (dz / dist) * step;
    vr->set_standing_origin(so);
}

float RE4VRMinecart::cart_speed_now() {
    ::RETransform* tf = nullptr;
    if (auto* car = get_player_railcar()) {
        auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(car, "get_GameObject"); }).value_or(nullptr);
        tf = go ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr) : nullptr;
    }
    if (!tf) {
        tf = body_tf();
    }
    if (!tf) {
        m_spd_t.reset();
        m_spd_v = 0;
        return 0.0f;
    }
    const auto p = sdk::get_transform_position(tf);
    const double now = re4vr::now();
    if (!m_spd_t) {
        m_spd_t = now;
        m_spd_x = p.x;
        m_spd_y = p.y;
        m_spd_z = p.z;
        return m_spd_v;
    }
    const double dt = now - *m_spd_t;
    if (dt >= 0.03) {
        const float dx = p.x - m_spd_x, dy = p.y - m_spd_y, dz = p.z - m_spd_z;
        float v = std::sqrt(dx * dx + dy * dy + dz * dz) / (float)dt;
        if (v > 60.0f) {
            v = m_spd_v;
        }
        m_spd_v += (v - m_spd_v) * 0.35f;
        m_spd_t = now;
        m_spd_x = p.x;
        m_spd_y = p.y;
        m_spd_z = p.z;
    }
    return m_spd_v;
}

void RE4VRMinecart::update_cart_rumble() {
    auto& vr = VR::get();
    const bool ride = railcar_active() || (m_cfg.rumble_intro && RE4VRShared::get()->re4_minecart2_ks4_active);
    if (!m_cfg.rumble_enabled || !vr->is_hmd_active() || !ride) {
        m_rum_t0.reset();
        m_spd_t.reset();
        return;
    }
    const double now = re4vr::now();
    if (!m_rum_t0) {
        m_rum_t0 = now;
        m_rum_next_t = 0;
        m_rum_next_clack = now + m_cfg.rumble_clack_every;
    }
    const float v = cart_speed_now();
    const float vmin = m_cfg.rumble_speed_min;
    const float vfull = std::max(vmin + 0.1f, m_cfg.rumble_speed_full);
    if (v < vmin) {
        return;
    }
    float vk = 1.0f;
    if (m_cfg.rumble_speed_scale) {
        vk = std::clamp((v - vmin) / (vfull - vmin), 0.0f, 1.0f);
    }
    if (now < m_rum_next_t) {
        return;
    }
    m_rum_next_t = now + std::max(0.03f, m_cfg.rumble_rate);
    const float t = (float)(now - *m_rum_t0);
    const float wob = 0.75f + 0.15f * std::sin(t * 7.3f) + 0.10f * std::sin(t * 2.1f + 1.3f);
    float amp = m_cfg.rumble_amp * wob * vk;
    float dur = std::max(0.02f, m_cfg.rumble_dur);
    const float frq = std::max(10.0f, m_cfg.rumble_freq);
    float la = amp, ra = amp;
    if (m_cfg.rumble_clack && now >= m_rum_next_clack) {
        m_rum_next_clack = now + std::max(0.3f, m_cfg.rumble_clack_every);
        m_rum_side = (m_rum_side == 0) ? 1 : 0;
        const float ca = m_cfg.rumble_clack_amp * vk;
        if (m_rum_side == 0) {
            la = ca;
            ra = ca * 0.55f;
        } else {
            la = ca * 0.55f;
            ra = ca;
        }
        dur = std::min(0.10f, dur + 0.03f);
    }
    const auto lj = vr->get_left_joystick();
    const auto rj = vr->get_right_joystick();
    if (lj) {
        vr->trigger_haptic_vibration(0.0f, dur, frq, la, lj);
    }
    if (rj) {
        vr->trigger_haptic_vibration(0.0f, dur, frq, ra, rj);
    }
}

std::optional<std::string> RE4VRMinecart::on_initialize() {
    load_json();
    return std::nullopt;
}

void RE4VRMinecart::on_lua_state_created(sol::state& lua) {
    load_json();
    lua["__re4_minecart_apply_spine_pin"] = [this]() { apply_spine_pin(); };
}

void RE4VRMinecart::on_lua_state_destroyed(sol::state&) {
    m_pin_tf = nullptr;
    m_pin_joints.clear();
    m_bw_motion = nullptr;
    m_bw_go = nullptr;
}

void RE4VRMinecart::on_frame() {
    ScriptProfileGuard guard("re4_vr_minecart.lua", "on_frame", re4vr::profile_frame());
    update_cart_rumble();
}

void RE4VRMinecart::on_pre_application_entry(void*, const char*, size_t hash) {
    if (hash != "LockScene"_fnv) {
        return;
    }
    ScriptProfileGuard guard("re4_vr_minecart.lua", "on_pre_application_entry:LockScene", re4vr::profile_frame());
    update_cart_recenter();
    update_cart_lean();
    update_yaw_follow();
    cart_knife_swap();
    if (!railcar_active()) {
        RE4VRShared::get()->re4_railcar_reloading = false;
        return;
    }
    update_anim_export();
    update_reload_flag();
    if (RE4VRShared::get()->re4_railcar_reloading && RE4VRShared::get()->re4_railcar_reload_fade.value_or(0.0) > 0.0) {
        apply_spine_pin();
    }
    force_crosshair();
}

void RE4VRMinecart::on_application_entry(void*, const char*, size_t hash) {
    if (hash != "LateUpdateBehavior"_fnv) {
        return;
    }
    ScriptProfileGuard guard("re4_vr_minecart.lua", "on_application_entry:LateUpdateBehavior", re4vr::profile_frame());
    if (RE4VRShared::get()->re4_railcar_reloading && RE4VRShared::get()->re4_railcar_reload_fade.value_or(0.0) > 0.0) {
        apply_spine_pin();
    }
    force_crosshair();
}
#endif
