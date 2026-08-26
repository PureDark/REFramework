#define NOMINMAX
#include "RE4VRArmChain.hpp"

#if defined(RE4)
#include <algorithm>
#include <cmath>

#include <glm/gtc/quaternion.hpp>
#include <glm/gtx/norm.hpp>
#include <glm/gtx/quaternion.hpp>
#include <sdk/MurmurHash.hpp>
#include <sdk/RETypeDB.hpp>
#include <spdlog/spdlog.h>

#include "RE4VRShared.hpp"
#include "../../../ScriptRunner.hpp"

namespace {
constexpr float IK_REACH_SLACK = 0.018f;
constexpr float IK_LOWER_POLE_MIX = 0.64f;
constexpr float IK_POLE_OUTWARD_MUL = 1.0f;
constexpr float ARM_SEG_CAP = 0.40f;
constexpr float AUTORESET_DIST = 0.15f;
constexpr float AUTORESET_COOLDOWN = 1.0f;

const char* kJointNames[] = {
    "R_Hand", "R_Forearm", "R_UpperArm", "R_Shoulder",
    "L_Hand", "L_Forearm", "L_UpperArm", "L_Shoulder",
};

Vector3f nrm(const Vector3f& v) {
    const float l = glm::length(v);
    if (l < 1e-8f) {
        return Vector3f{0, 0, 0};
    }
    return v / l;
}
Vector3f reject_n(const Vector3f& v, const Vector3f& from_unit) {
    return nrm(v - from_unit * glm::dot(v, from_unit));
}

std::optional<glm::quat> quat_bone_x_along_dir(const Vector3f& bone_dir, const Vector3f& pole_hint) {
    const auto x = nrm(bone_dir);
    if (glm::length2(x) < 1e-12f) {
        return std::nullopt;
    }
    auto p = nrm(pole_hint);
    if (glm::length2(p) < 1e-12f) {
        p = Vector3f{0, 1, 0};
    }
    auto z = glm::cross(p, x);
    float zl = glm::length(z);
    if (zl < 1e-5f) {
        z = glm::cross(Vector3f{0, 1, 0}, x);
        zl = glm::length(z);
    }
    if (zl < 1e-5f) {
        return std::nullopt;
    }
    z /= zl;
    auto y = glm::cross(z, x);
    const float yl = glm::length(y);
    if (yl < 1e-5f) {
        return std::nullopt;
    }
    y /= yl;
    const float m00 = x.x, m01 = y.x, m02 = z.x;
    const float m10 = x.y, m11 = y.y, m12 = z.y;
    const float m20 = x.z, m21 = y.z, m22 = z.z;
    const float trace = m00 + m11 + m22;
    glm::quat q{1, 0, 0, 0};
    if (trace > 0.0f) {
        const float s = 0.5f / std::sqrt(trace + 1.0f);
        q.w = 0.25f / s;
        q.x = (m21 - m12) * s;
        q.y = (m02 - m20) * s;
        q.z = (m10 - m01) * s;
    } else if (m00 > m11 && m00 > m22) {
        const float s = 2.0f * std::sqrt(1.0f + m00 - m11 - m22);
        q.w = (m21 - m12) / s;
        q.x = 0.25f * s;
        q.y = (m01 + m10) / s;
        q.z = (m02 + m20) / s;
    } else if (m11 > m22) {
        const float s = 2.0f * std::sqrt(1.0f + m11 - m00 - m22);
        q.w = (m02 - m20) / s;
        q.x = (m01 + m10) / s;
        q.y = 0.25f * s;
        q.z = (m12 + m21) / s;
    } else {
        const float s = 2.0f * std::sqrt(1.0f + m22 - m00 - m11);
        q.w = (m10 - m01) / s;
        q.x = (m02 + m20) / s;
        q.y = (m12 + m21) / s;
        q.z = 0.25f * s;
    }
    return glm::normalize(q);
}

std::optional<std::pair<Vector3f, Vector3f>> solve_arm_ik(const Vector3f& shoulder, const Vector3f& hand,
    float upper_len, float lower_len, const Vector3f& pole, float bend_sign) {
    if (upper_len < 1e-4f || lower_len < 1e-4f) {
        return std::nullopt;
    }
    const auto w = hand - shoulder;
    const float dist = glm::length(w);
    if (dist < 1e-6f) {
        return std::nullopt;
    }
    float max_reach = upper_len + lower_len - IK_REACH_SLACK;
    if (max_reach < 1e-3f) {
        max_reach = upper_len + lower_len - 1e-4f;
    }
    float reach = std::min(dist, max_reach - 1e-4f);
    if (reach < 1e-4f) {
        return std::nullopt;
    }
    const auto to_target = w / dist;
    const auto effector = shoulder + to_target * reach;
    float cos_s = (upper_len * upper_len + reach * reach - lower_len * lower_len) / (2.0f * upper_len * reach);
    cos_s = std::clamp(cos_s, -1.0f, 1.0f);
    const float sin_s = std::sqrt(std::max(0.0f, 1.0f - cos_s * cos_s));
    auto pole_planar = reject_n(pole, to_target);
    if (glm::length2(pole_planar) < 1e-12f) {
        pole_planar = pole;
    }
    auto n = glm::cross(pole_planar, to_target);
    float nl = glm::length(n);
    if (nl < 1e-5f) {
        n = glm::cross(pole_planar, Vector3f{0, 1, 0});
        nl = glm::length(n);
    }
    if (nl < 1e-5f) {
        return std::nullopt;
    }
    n /= nl;
    auto perp = glm::cross(n, to_target);
    const float pl = glm::length(perp);
    if (pl < 1e-5f) {
        return std::nullopt;
    }
    perp *= bend_sign / pl;

    auto dirs = [&](const Vector3f& pu) -> std::optional<std::pair<Vector3f, Vector3f>> {
        const auto ud = nrm(to_target * cos_s + pu * sin_s);
        if (glm::length2(ud) < 1e-12f) {
            return std::nullopt;
        }
        const auto elbow = shoulder + ud * upper_len;
        const auto fr = nrm(effector - elbow);
        if (glm::length2(fr) < 1e-12f) {
            return std::nullopt;
        }
        return std::pair{ud, fr};
    };

    auto r = dirs(perp);
    if (!r) {
        return std::nullopt;
    }
    auto [upper_dir, fore] = *r;
    const auto elbow_pos = shoulder + upper_dir * upper_len;
    if (hand.y < shoulder.y - 0.06f && elbow_pos.y > shoulder.y - 0.03f) {
        if (auto r2 = dirs(perp * -1.0f)) {
            upper_dir = r2->first;
            fore = r2->second;
        }
    }
    return std::pair{upper_dir, fore};
}

std::optional<std::pair<glm::quat, glm::quat>> ik_world_rots(const Vector3f& upper_dir, const Vector3f& fore,
    const Vector3f& pole, float bone_axis_flip) {
    const auto ud = upper_dir * bone_axis_flip;
    const auto fd = fore * bone_axis_flip;
    auto q_upper = quat_bone_x_along_dir(ud, pole);
    if (!q_upper) {
        return std::nullopt;
    }
    auto pole_lower = pole;
    const auto elbow_axis = nrm(glm::cross(ud, fd));
    if (glm::length2(elbow_axis) > 1e-12f) {
        const float w_el = std::clamp(IK_LOWER_POLE_MIX, 0.0f, 1.0f);
        const auto mix = nrm(elbow_axis * w_el + pole * (1.0f - w_el));
        if (glm::length2(mix) > 1e-12f) {
            pole_lower = mix;
        }
    }
    auto q_lower = quat_bone_x_along_dir(fd, pole_lower);
    if (!q_lower) {
        return std::nullopt;
    }
    return std::pair{*q_upper, *q_lower};
}

Vector3f arm_pole_world(const glm::quat& char_rot, bool is_right) {
    const Vector3f world_down{0, -1, 0};
    const auto char_right = re4vr::quat_rotate(char_rot, Vector3f{1, 0, 0});
    const auto char_fwd = re4vr::quat_rotate(char_rot, Vector3f{0, 0, 1});
    const auto char_down = re4vr::quat_rotate(char_rot, Vector3f{0, -1, 0});
    const auto char_back = char_fwd * -1.0f;
    const auto outward = is_right ? (char_right * -1.0f) : char_right;
    const float out_w = 0.46f * std::clamp(IK_POLE_OUTWARD_MUL, 0.0f, 2.5f);
    const auto blend = outward * out_w + char_down * 0.36f + char_back * 0.12f + world_down * 0.06f;
    const auto p = nrm(blend);
    return glm::length2(p) > 1e-12f ? p : char_down;
}
}

std::shared_ptr<RE4VRArmChain>& RE4VRArmChain::get() {
    static auto inst = std::make_shared<RE4VRArmChain>();
    return inst;
}

std::optional<std::string> RE4VRArmChain::on_initialize() {
    for (auto* n : kJointNames) {
        m_chain_offset[n] = JointOff{};
        m_seg_enabled[n] = true;
    }
    load_json();
    apply_key_config(resolve_config_key());
    return std::nullopt;
}

void RE4VRArmChain::load_json() {
    m_all_configs = re4vr::load_json_file("re4_vr/re4_vr_arm_chain.json");
}

void RE4VRArmChain::save_json() {
    const auto key = resolve_config_key();
    nlohmann::json pin = nlohmann::json::object();
    auto dump_pin = [&](const char* side, const std::optional<PinRel>& r) {
        if (!r) {
            return;
        }
        pin[side] = {{"px", r->p.x}, {"py", r->p.y}, {"pz", r->p.z},
            {"rw", r->r.w}, {"rx", r->r.x}, {"ry", r->r.y}, {"rz", r->r.z}};
    };
    dump_pin("L", m_pin_l);
    dump_pin("R", m_pin_r);
    nlohmann::json chain = nlohmann::json::object();
    for (auto& [name, off] : m_chain_offset) {
        chain[name] = {{"pos_x", off.pos_x}, {"pos_y", off.pos_y}, {"pos_z", off.pos_z},
            {"rot_x", off.rot_x}, {"rot_y", off.rot_y}, {"rot_z", off.rot_z},
            {"scale_x", off.scale_x}, {"scale_y", off.scale_y}, {"scale_z", off.scale_z}};
    }
    nlohmann::json segs = nlohmann::json::object();
    for (auto& [name, en] : m_seg_enabled) {
        segs[name] = en;
    }
    m_all_configs[key] = {
        {"enabled", m_enabled},
        {"chain", chain},
        {"segments", segs},
        {"wrist_y", {{"L", m_wrist_y_l}, {"R", m_wrist_y_r}}},
        {"wrist_x", {{"L", m_wrist_x_l}, {"R", m_wrist_x_r}}},
        {"shoulder_reach_follow", m_shoulder_reach_follow},
        {"shoulder_reach_follow_max", m_shoulder_reach_follow_max},
        {"hand_clamp", m_hand_clamp},
        {"shoulder_pin", m_shoulder_pin},
        {"shoulder_pin_pose", pin},
    };
    re4vr::save_json_file("re4_vr/re4_vr_arm_chain.json", m_all_configs);
}

std::string RE4VRArmChain::resolve_config_key() {
    if (auto s = re4vr::lua_string("__vr_active_char")) {
        if (!s->empty()) {
            std::string k = *s;
            std::transform(k.begin(), k.end(), k.begin(), [](unsigned char c) { return (char)std::tolower(c); });
            return k;
        }
    }
    return "leon";
}

void RE4VRArmChain::apply_key_config(const std::string& resolved) {
    nlohmann::json data;
    if (m_all_configs.contains(resolved)) {
        data = m_all_configs[resolved];
    } else if (m_all_configs.contains("default")) {
        data = m_all_configs["default"];
    } else if (m_all_configs.contains("leon")) {
        data = m_all_configs["leon"];
    } else {
        return;
    }
    m_current_key = resolved;
    m_enabled = re4vr::j_bool(data, "enabled", m_enabled);
    if (data.contains("chain") && data["chain"].is_object()) {
        for (auto it = data["chain"].begin(); it != data["chain"].end(); ++it) {
            auto f = m_chain_offset.find(it.key());
            if (f == m_chain_offset.end() || !it.value().is_object()) {
                continue;
            }
            auto& o = f->second;
            auto& d = it.value();
            o.pos_x = re4vr::j_num(d, "pos_x", o.pos_x);
            o.pos_y = re4vr::j_num(d, "pos_y", o.pos_y);
            o.pos_z = re4vr::j_num(d, "pos_z", o.pos_z);
            o.rot_x = re4vr::j_num(d, "rot_x", o.rot_x);
            o.rot_y = re4vr::j_num(d, "rot_y", o.rot_y);
            o.rot_z = re4vr::j_num(d, "rot_z", o.rot_z);
            o.scale_x = re4vr::j_num(d, "scale_x", o.scale_x);
            o.scale_y = re4vr::j_num(d, "scale_y", o.scale_y);
            o.scale_z = re4vr::j_num(d, "scale_z", o.scale_z);
        }
    }
    if (data.contains("segments") && data["segments"].is_object()) {
        for (auto it = data["segments"].begin(); it != data["segments"].end(); ++it) {
            if (m_seg_enabled.contains(it.key())) {
                m_seg_enabled[it.key()] = it.value().is_boolean() ? it.value().get<bool>() : true;
            }
        }
    }
    if (data.contains("wrist_y") && data["wrist_y"].is_object()) {
        m_wrist_y_l = re4vr::j_num(data["wrist_y"], "L", m_wrist_y_l);
        m_wrist_y_r = re4vr::j_num(data["wrist_y"], "R", m_wrist_y_r);
    }
    if (data.contains("wrist_x") && data["wrist_x"].is_object()) {
        m_wrist_x_l = re4vr::j_num(data["wrist_x"], "L", m_wrist_x_l);
        m_wrist_x_r = re4vr::j_num(data["wrist_x"], "R", m_wrist_x_r);
    }
    m_shoulder_reach_follow = re4vr::j_bool(data, "shoulder_reach_follow", m_shoulder_reach_follow);
    m_shoulder_reach_follow_max = re4vr::j_num(data, "shoulder_reach_follow_max", m_shoulder_reach_follow_max);
    m_hand_clamp = re4vr::j_bool(data, "hand_clamp", m_hand_clamp);
    m_shoulder_pin = re4vr::j_bool(data, "shoulder_pin", m_shoulder_pin);
    if (data.contains("shoulder_pin_pose") && data["shoulder_pin_pose"].is_object()) {
        auto loadp = [&](const char* side, std::optional<PinRel>& out) {
            if (!data["shoulder_pin_pose"].contains(side) || !data["shoulder_pin_pose"][side].is_object()) {
                return;
            }
            auto& s = data["shoulder_pin_pose"][side];
            if (!s.contains("px") || !s.contains("rw") || !s["px"].is_number() || !s["rw"].is_number()) {
                return;
            }
            out = PinRel{
                Vector3f{re4vr::j_num(s, "px", 0), re4vr::j_num(s, "py", 0), re4vr::j_num(s, "pz", 0)},
                glm::quat{re4vr::j_num(s, "rw", 1), re4vr::j_num(s, "rx", 0), re4vr::j_num(s, "ry", 0), re4vr::j_num(s, "rz", 0)},
            };
        };
        loadp("L", m_pin_l);
        loadp("R", m_pin_r);
    }
}

void RE4VRArmChain::load_from_config_bodychain(sol::table bc) {
    if (!bc.valid()) {
        return;
    }
    sol::object en = bc["enabled"];
    if (en.get_type() == sol::type::boolean) {
        m_enabled = en.as<bool>();
    }
    if (sol::object chain = bc["chain"]; chain.is<sol::table>()) {
        for (auto& [k, v] : chain.as<sol::table>()) {
            if (!k.is<std::string>() || !v.is<sol::table>()) {
                continue;
            }
            auto f = m_chain_offset.find(k.as<std::string>());
            if (f == m_chain_offset.end()) {
                continue;
            }
            auto t = v.as<sol::table>();
            auto setf = [&](const char* n, float& dst) {
                sol::object o = t[n];
                if (o.get_type() == sol::type::number) {
                    dst = o.as<float>();
                }
            };
            setf("pos_x", f->second.pos_x);
            setf("pos_y", f->second.pos_y);
            setf("pos_z", f->second.pos_z);
            setf("rot_x", f->second.rot_x);
            setf("rot_y", f->second.rot_y);
            setf("rot_z", f->second.rot_z);
            setf("scale_x", f->second.scale_x);
            setf("scale_y", f->second.scale_y);
            setf("scale_z", f->second.scale_z);
        }
    }
    if (sol::object segs = bc["segments"]; segs.is<sol::table>()) {
        for (auto& [k, v] : segs.as<sol::table>()) {
            if (!k.is<std::string>()) {
                continue;
            }
            auto f = m_seg_enabled.find(k.as<std::string>());
            if (f != m_seg_enabled.end() && v.get_type() == sol::type::boolean) {
                f->second = v.as<bool>();
            }
        }
    }
}

sol::table RE4VRArmChain::get_save_bodychain(sol::state_view lua) {
    auto t = lua.create_table();
    t["enabled"] = m_enabled;
    auto chain = lua.create_table();
    for (auto& [name, off] : m_chain_offset) {
        auto o = lua.create_table();
        o["pos_x"] = off.pos_x;
        o["pos_y"] = off.pos_y;
        o["pos_z"] = off.pos_z;
        o["rot_x"] = off.rot_x;
        o["rot_y"] = off.rot_y;
        o["rot_z"] = off.rot_z;
        o["scale_x"] = off.scale_x;
        o["scale_y"] = off.scale_y;
        o["scale_z"] = off.scale_z;
        chain[name] = o;
    }
    t["chain"] = chain;
    auto segs = lua.create_table();
    for (auto& [name, en] : m_seg_enabled) {
        segs[name] = en;
    }
    t["segments"] = segs;
    return t;
}

void RE4VRArmChain::export_module(sol::state& lua) {
    auto t = lua.create_table();
    t["apply"] = [](sol::variadic_args) {};
    t["load_from_config_bodychain"] = [this](sol::object o) {
        if (o.is<sol::table>()) {
            load_from_config_bodychain(o.as<sol::table>());
        }
    };
    t["get_save_bodychain"] = [this, &lua]() { return get_save_bodychain(lua); };
    t["clear_joint_cache"] = [this]() { flush_joint_cache(); };
    t["upperbody_apply"] = sol::nil;
    t["upperbody_draw_ui"] = sol::nil;
    auto mt = lua.create_table();
    mt["__index"] = [this](sol::object, sol::object k) -> sol::object {
        re4vr::LuaGuard g;
        auto* L = g.lua();
        if (!L || !k.is<std::string>()) {
            return sol::nil;
        }
        const auto s = k.as<std::string>();
        if (s == "enabled") {
            return sol::make_object(*L, m_enabled);
        }
        if (s == "arm_segment_enabled") {
            auto t2 = L->create_table();
            for (auto& [n, e] : m_seg_enabled) {
                t2[n] = e;
            }
            return t2;
        }
        if (s == "chain_offset") {
            auto t2 = L->create_table();
            for (auto& [n, o] : m_chain_offset) {
                auto u = L->create_table();
                u["pos_x"] = o.pos_x;
                u["pos_y"] = o.pos_y;
                u["pos_z"] = o.pos_z;
                u["rot_x"] = o.rot_x;
                u["rot_y"] = o.rot_y;
                u["rot_z"] = o.rot_z;
                u["scale_x"] = o.scale_x;
                u["scale_y"] = o.scale_y;
                u["scale_z"] = o.scale_z;
                t2[n] = u;
            }
            return t2;
        }
        return sol::nil;
    };
    mt["__newindex"] = [this](sol::object, sol::object k, sol::object v) {
        if (k.is<std::string>() && k.as<std::string>() == "enabled") {
            if (v.get_type() == sol::type::boolean) {
                m_enabled = v.as<bool>();
            }
        }
    };
    t[sol::metatable_key] = mt;
    lua["__re4_vr_arm_chain_module"] = t;
    lua["package"]["loaded"]["re4_vr_arm_chain"] = t;
    lua["__vr_flush_arm_joint_cache"] = [this](sol::variadic_args) { flush_joint_cache(); };
}

void RE4VRArmChain::on_lua_state_created(sol::state& lua) {
    export_module(lua);
}

void RE4VRArmChain::on_lua_state_destroyed(sol::state&) {
    flush_joint_cache();
    m_cached_tf = nullptr;
    m_first_load = true;
    m_hooks_ready = false;
}

void RE4VRArmChain::flush_joint_cache() {
    m_joints.clear();
}

bool RE4VRArmChain::should_pause() {
    if (re4vr::lua_is_true("__re4_railcar_mode") && !re4vr::lua_is_true("__re4_railcar_reloading")) {
        return false;
    }
    if (re4vr::call_killswitch_bool("is_active", re4vr::lua_is_true("__re4_ks_active"))) {
        return true;
    }
    return re4vr::lua_is_true("__vr_motion_paused");
}

bool RE4VRArmChain::should_apply_now() {
    if (m_require_motion_tick) {
        const int32_t mt = (int32_t)re4vr::lua_number("__vr_motion_tick_id").value_or(-1);
        if (mt <= m_last_motion_tick) {
            return false;
        }
    }
    if (m_apply_once) {
        int32_t f = (int32_t)VR::get()->get_frame_count();
        if (f == m_last_frame_applied) {
            return false;
        }
        m_last_frame_applied = f;
    }
    if (m_require_motion_tick) {
        m_last_motion_tick = (int32_t)re4vr::lua_number("__vr_motion_tick_id").value_or(m_last_motion_tick);
    }
    return true;
}

void RE4VRArmChain::check_player_changed() {
    auto* tf = re4vr::body_transform();
    if (!tf) {
        return;
    }
    if (m_cached_tf && tf != m_cached_tf) {
        flush_joint_cache();
    }
    m_cached_tf = tf;
}

bool RE4VRArmChain::is_joint_valid(::REJoint* j) {
    if (!j) {
        return false;
    }
    const auto addr = (uintptr_t)j;
    const double t = re4vr::now();
    auto it = m_jv_bad.find(addr);
    if (it != m_jv_bad.end() && (t - it->second) < 0.5) {
        return false;
    }
    auto pos = re4vr::safe([&] { return sdk::get_joint_position(j); });
    if (!pos) {
        m_jv_bad[addr] = t;
        return false;
    }
    m_jv_bad.erase(addr);
    return true;
}

::REJoint* RE4VRArmChain::get_chain_joint(const std::string& name) {
    auto it = m_joints.find(name);
    if (it != m_joints.end() && is_joint_valid(it->second)) {
        return it->second;
    }
    auto* tf = re4vr::body_transform();
    if (!tf) {
        return nullptr;
    }
    auto* j = re4vr::joint_by_name(tf, name);
    m_joints[name] = j;
    return j;
}

std::pair<float, float> RE4VRArmChain::arm_ik_segment_lengths(const std::string& upper, const std::string& lower) {
    auto mag = [&](const std::string& n) {
        auto f = m_chain_offset.find(n);
        if (f == m_chain_offset.end()) {
            return 0.0f;
        }
        const auto& o = f->second;
        return std::sqrt(o.pos_x * o.pos_x + o.pos_y * o.pos_y + o.pos_z * o.pos_z);
    };
    const float u_json = mag(upper);
    const float l_json = mag(lower);
    const float upper_len = std::min(std::max(u_json, 0.26f), ARM_SEG_CAP);
    const float lower_len = std::min(std::max(l_json, 0.24f), ARM_SEG_CAP);
    return {upper_len, lower_len};
}

void RE4VRArmChain::apply_ik_rotation(::REJoint* joint, const std::string& name, const glm::quat& world_rot) {
    if (!joint) {
        return;
    }
    glm::quat rot_off{1, 0, 0, 0};
    bool has_off = false;
    if (auto f = m_chain_offset.find(name); f != m_chain_offset.end()) {
        const auto& o = f->second;
        if (o.rot_x != 0 || o.rot_y != 0 || o.rot_z != 0) {
            rot_off = re4vr::quat_euler_xyz_deg(o.rot_x, o.rot_y, o.rot_z);
            has_off = true;
        }
    }
    auto* parent = sdk::get_joint_parent(joint);
    if (parent) {
        const auto parent_rot = sdk::get_joint_rotation(parent);
        auto local_rot = glm::normalize(glm::inverse(parent_rot) * world_rot);
        if (has_off) {
            local_rot = glm::normalize(local_rot * rot_off);
        }
        sdk::set_joint_local_rotation(joint, local_rot);
    } else {
        auto wr = world_rot;
        if (has_off) {
            wr = glm::normalize(world_rot * rot_off);
        }
        sdk::set_joint_rotation(joint, wr);
    }
    if (auto f = m_chain_offset.find(name); f != m_chain_offset.end()) {
        Vector3f sc{
            std::max(f->second.scale_x, 0.001f),
            std::max(f->second.scale_y, 0.001f),
            std::max(f->second.scale_z, 0.001f),
        };
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(joint, "set_LocalScale", sc); });
    }
}

void RE4VRArmChain::apply_shoulder_pin(const char* prefix) {
    auto& slot = (prefix[0] == 'L') ? m_pin_l : m_pin_r;
    if (!m_shoulder_pin) {
        slot.reset();
        return;
    }
    auto* sj = get_chain_joint(std::string(prefix) + "_Shoulder");
    if (!sj || !slot) {
        return;
    }
    sdk::set_joint_local_position(sj, re4vr::v4(slot->p));
    sdk::set_joint_local_rotation(sj, slot->r);
}

void RE4VRArmChain::check_autoreset(const char* prefix, const Vector3f& hand_target) {
    const double t = re4vr::now();
    if ((t - m_autoreset_last) < AUTORESET_COOLDOWN) {
        return;
    }
    auto* hj = m_joints[std::string(prefix) + "_Hand"];
    if (!hj) {
        return;
    }
    auto actual = re4vr::safe([&] { return re4vr::v3(sdk::get_joint_position(hj)); });
    if (!actual) {
        return;
    }
    if (glm::length(*actual - hand_target) > AUTORESET_DIST) {
        flush_joint_cache();
        m_autoreset_last = t;
    }
}

void RE4VRArmChain::apply_arm_ik_side(const char* prefix, Vector3f hand_pos, const std::optional<glm::quat>& char_rot,
    const std::optional<RootPose>& root) {
    const std::string upper_name = std::string(prefix) + "_UpperArm";
    const std::string lower_name = std::string(prefix) + "_Forearm";
    const std::string hand_name = std::string(prefix) + "_Hand";
    if (m_seg_enabled[upper_name] == false && m_seg_enabled[lower_name] == false) {
        return;
    }
    const float wy = (prefix[0] == 'L') ? m_wrist_y_l : m_wrist_y_r;
    if (wy != 0.0f) {
        hand_pos.y += wy;
    }
    const float wx = (prefix[0] == 'L') ? m_wrist_x_l : m_wrist_x_r;
    if (wx != 0.0f) {
        const auto off = char_rot ? re4vr::quat_rotate(*char_rot, Vector3f{wx, 0, 0}) : Vector3f{wx, 0, 0};
        hand_pos += off;
    }
    auto* upper_joint = get_chain_joint(upper_name);
    auto* lower_joint = get_chain_joint(lower_name);
    auto* hand_joint = get_chain_joint(hand_name);
    if (!upper_joint) {
        return;
    }
    apply_shoulder_pin(prefix);
    auto sw = re4vr::safe([&] { return re4vr::v3(sdk::get_joint_position(upper_joint)); });
    if (!sw) {
        return;
    }
    auto [upper_len, lower_len] = arm_ik_segment_lengths(upper_name, lower_name);
    if (m_hand_clamp) {
        const float maxreach = upper_len + lower_len - m_shoulder_reach_follow_slack
            + (m_shoulder_reach_follow ? m_shoulder_reach_follow_max : 0.0f);
        re4vr::lua_set_vec3(std::string("__vr_arm_chain_") + prefix + "_root", *sw);
        re4vr::lua_set_number(std::string("__vr_arm_chain_") + prefix + "_maxreach", maxreach);
    } else {
        re4vr::lua_set_nil(std::string("__vr_arm_chain_") + prefix + "_root");
        re4vr::lua_set_nil(std::string("__vr_arm_chain_") + prefix + "_maxreach");
    }
    auto& pin = (prefix[0] == 'L') ? m_pin_l : m_pin_r;
    if (m_shoulder_pin && !pin) {
        const float max_r0 = upper_len + lower_len - m_shoulder_reach_follow_slack;
        const float d0 = glm::length(hand_pos - *sw);
        auto anim = re4vr::lua_string("__vr_anim_l0");
        bool stand = false;
        if (anim) {
            std::string a = *anim;
            std::transform(a.begin(), a.end(), a.begin(), [](unsigned char c) { return (char)std::tolower(c); });
            stand = a.find("stand") != std::string::npos;
        }
        if (stand && max_r0 > 0.05f && d0 < max_r0) {
            auto* sj = get_chain_joint(std::string(prefix) + "_Shoulder");
            if (sj) {
                pin = PinRel{re4vr::v3(sdk::get_joint_local_position(sj)), sdk::get_joint_local_rotation(sj)};
                save_json();
            }
        }
    }
    Vector3f shoulder_world = *sw;
    if (m_shoulder_reach_follow) {
        const float max_r = upper_len + lower_len - m_shoulder_reach_follow_slack;
        const auto w = hand_pos - shoulder_world;
        const float d = glm::length(w);
        if (max_r > 0.05f && d > max_r) {
            const auto dir = nrm(w);
            auto* sj = get_chain_joint(std::string(prefix) + "_Shoulder");
            if (sj && glm::length2(dir) > 1e-12f) {
                auto sp = re4vr::safe([&] { return re4vr::v3(sdk::get_joint_position(sj)); });
                if (sp) {
                    float excess = d - max_r;
                    if (!re4vr::lua_is_true("__re4_railcar_mode") && excess > m_shoulder_reach_follow_max) {
                        excess = m_shoulder_reach_follow_max;
                    }
                    const auto delta = dir * excess;
                    sdk::set_joint_position(sj, re4vr::v4(*sp + delta));
                    shoulder_world += delta;
                }
            }
        }
    }
    if (m_hand_clamp && !re4vr::lua_is_true("__re4_railcar_mode")) {
        const float max_r = upper_len + lower_len - m_shoulder_reach_follow_slack;
        const auto w = hand_pos - shoulder_world;
        const float d = glm::length(w);
        if (max_r > 0.05f && d > max_r + 1e-4f) {
            const auto dir = nrm(w);
            if (glm::length2(dir) > 1e-12f) {
                hand_pos = shoulder_world + dir * max_r;
            }
        }
    }
    const bool do_local = root && root->parented;
    Vector3f shoulder_solve = shoulder_world;
    Vector3f hand_solve = hand_pos;
    std::optional<Vector3f> pole_solve{};
    if (do_local) {
        shoulder_solve = re4vr::quat_rotate(root->inv_rot, shoulder_world - root->pos);
        hand_solve = re4vr::quat_rotate(root->inv_rot, hand_pos - root->pos);
    }
    if (prefix[0] == 'R') {
        re4vr::lua_set_vec3("__vr_arm_chain_rh_clamped_pos", hand_solve);
    } else {
        re4vr::lua_set_vec3("__vr_arm_chain_lh_clamped_pos", hand_solve);
    }
    const bool is_right = prefix[0] == 'R';
    Vector3f pole_vec = char_rot ? arm_pole_world(*char_rot, is_right) : Vector3f{0, -1, 0};
    if (do_local) {
        pole_vec = re4vr::quat_rotate(root->inv_rot, pole_vec);
    }
    pole_vec = nrm(pole_vec);
    const float bend_sign = -1.0f;
    const float bone_axis_flip = is_right ? -1.0f : 1.0f;
    auto dirs = solve_arm_ik(shoulder_solve, hand_solve, upper_len, lower_len, pole_vec, bend_sign);
    if (!dirs) {
        return;
    }
    auto upper_dir = dirs->first;
    auto fore_dir = dirs->second;
    if (do_local) {
        upper_dir = re4vr::quat_rotate(root->rot, upper_dir);
        fore_dir = re4vr::quat_rotate(root->rot, fore_dir);
        pole_vec = re4vr::quat_rotate(root->rot, pole_vec);
    }
    auto qs = ik_world_rots(upper_dir, fore_dir, pole_vec, bone_axis_flip);
    if (!qs) {
        return;
    }
    if (m_seg_enabled[upper_name] != false) {
        apply_ik_rotation(upper_joint, upper_name, qs->first);
    }
    if (m_seg_enabled[lower_name] != false) {
        apply_ik_rotation(lower_joint, lower_name, qs->second);
    }
    (void)hand_joint;
}

void RE4VRArmChain::apply_body_chain() {
    re4vr::lua_set_bool("__vr_re4_two_bone_ik_active", false);
    if (!m_enabled || should_pause() || !should_apply_now()) {
        return;
    }
    if (m_first_load) {
        m_first_load = false;
        flush_joint_cache();
        return;
    }
    check_player_changed();
    const auto new_key = resolve_config_key();
    if (new_key != m_current_key) {
        flush_joint_cache();
        apply_key_config(new_key);
    }
    auto* player_tf = re4vr::body_transform();
    if (!player_tf) {
        return;
    }
    re4vr::lua_set_bool("__vr_re4_two_bone_ik_active", true);
    std::optional<RootPose> root;
    auto pos = re4vr::safe([&] { return sdk::get_transform_position(player_tf); });
    auto rot = re4vr::safe([&] { return sdk::get_transform_rotation(player_tf); });
    if (pos && rot) {
        RootPose rp;
        rp.pos = re4vr::v3(*pos);
        rp.rot = *rot;
        rp.inv_rot = glm::inverse(*rot);
        auto* parent = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(player_tf, "get_Parent"); }).value_or(nullptr);
        rp.parented = parent != nullptr;
        root = rp;
    }
    std::optional<glm::quat> char_rot = rot;

    auto rh_pos = re4vr::lua_vec3("__vr_rh_joint_pos");
    if (!rh_pos) {
        rh_pos = re4vr::lua_vec3("__vr_unified_rh_pos");
    }
    if (!rh_pos) {
        rh_pos = re4vr::lua_vec3("__vr_rh_world");
    }
    auto lh_raw = re4vr::lua_vec3("__vr_lh_joint_pos");
    if (!lh_raw) {
        lh_raw = re4vr::lua_vec3("__vr_unified_lh_pos");
    }
    if (!lh_raw) {
        lh_raw = re4vr::lua_vec3("__vr_lh_world");
    }
    auto lh_pos = lh_raw;
    if (auto dock = re4vr::lua_vec3("__vr_slide_hand_world_pos")) {
        const float sblend = (float)re4vr::lua_number("__vr_slide_dock_blend_factor").value_or(0.0);
        if (sblend > 0.001f) {
            auto rh_rot = re4vr::lua_quat("__vr_rh_joint_rot");
            if (rh_pos && rh_rot) {
                auto prev = re4vr::lua_vec3("__ldock_rhprev");
                const float moved = prev ? glm::length(*rh_pos - *prev) : 999.0f;
                re4vr::lua_set_vec3("__ldock_rhprev", *rh_pos);
                if (!re4vr::lua_vec3("__ldock_off") || moved < 0.006f) {
                    const auto inv = glm::inverse(*rh_rot);
                    re4vr::lua_set_vec3("__ldock_off", re4vr::quat_rotate(inv, *dock - *rh_pos));
                }
                if (auto off = re4vr::lua_vec3("__ldock_off")) {
                    *dock = *rh_pos + re4vr::quat_rotate(*rh_rot, *off);
                }
            }
            if (lh_raw && sblend < 0.999f) {
                lh_pos = glm::mix(*lh_raw, *dock, sblend);
            } else {
                lh_pos = dock;
            }
            if (lh_pos) {
                re4vr::lua_set_vec3("__vr_ldock_anchored", *lh_pos);
            }
        }
    }
    if (rh_pos) {
        apply_arm_ik_side("R", *rh_pos, char_rot, root);
        check_autoreset("R", *rh_pos);
    }
    if (lh_pos) {
        apply_arm_ik_side("L", *lh_pos, char_rot, root);
        check_autoreset("L", *lh_pos);
    }
    auto repin = [&](const char* prefix, const std::optional<Vector3f>& p, std::string_view rot_name) {
        if (!p) {
            return;
        }
        auto* hj = get_chain_joint(std::string(prefix) + "_Hand");
        if (!hj) {
            return;
        }
        sdk::set_joint_position(hj, re4vr::v4(*p));
        if (auto r = re4vr::lua_quat(rot_name)) {
            sdk::set_joint_rotation(hj, *r);
        }
    };
    if (rh_pos) {
        repin("R", rh_pos, "__vr_rh_joint_rot");
    }
    if (lh_pos) {
        repin("L", lh_pos, "__vr_lh_joint_rot");
    }
}

void RE4VRArmChain::publish_clamp_anchors() {
    if (!m_hand_clamp) {
        re4vr::lua_set_nil("__vr_arm_chain_R_root");
        re4vr::lua_set_nil("__vr_arm_chain_R_maxreach");
        re4vr::lua_set_nil("__vr_arm_chain_L_root");
        re4vr::lua_set_nil("__vr_arm_chain_L_maxreach");
        return;
    }
    for (const char* prefix : {"R", "L"}) {
        auto* uj = get_chain_joint(std::string(prefix) + "_UpperArm");
        if (!uj) {
            continue;
        }
        auto sw = re4vr::safe([&] { return re4vr::v3(sdk::get_joint_position(uj)); });
        if (!sw) {
            continue;
        }
        auto [ul, ll] = arm_ik_segment_lengths(std::string(prefix) + "_UpperArm", std::string(prefix) + "_Forearm");
        const float maxreach = ul + ll - m_shoulder_reach_follow_slack
            + (m_shoulder_reach_follow ? m_shoulder_reach_follow_max : 0.0f);
        re4vr::lua_set_vec3(std::string("__vr_arm_chain_") + prefix + "_root", *sw);
        re4vr::lua_set_number(std::string("__vr_arm_chain_") + prefix + "_maxreach", maxreach);
    }
}

void RE4VRArmChain::railcar_pin_spine() {
    if (!re4vr::lua_is_true("__re4_railcar_mode") || re4vr::lua_is_true("__re4_railcar_reloading")) {
        return;
    }
    re4vr::lua_pcall_name("__re4_minecart_apply_spine_pin");
}

void RE4VRArmChain::phase_pre(const char* lua_call, bool enabled) {
    ScriptProfileGuard guard("re4_vr_arm_chain.lua", lua_call, re4vr::profile_frame());
    if (should_pause()) {
        re4vr::lua_set_bool("__vr_re4_two_bone_ik_active", false);
        publish_clamp_anchors();
        return;
    }
    railcar_pin_spine();
    if (enabled) {
        apply_body_chain();
    }
}

void RE4VRArmChain::phase_post(const char* lua_call, bool enabled) {
    phase_pre(lua_call, enabled);
}

void RE4VRArmChain::on_frame() {
    ScriptProfileGuard guard("re4_vr_arm_chain.lua", "on_frame", re4vr::profile_frame());
    m_hooks_ready = true;
}

void RE4VRArmChain::on_pre_application_entry(void*, const char* name, size_t hash) {
    if (!m_hooks_ready) {
        return;
    }
    if (hash == "LockScene"_fnv) {
        phase_pre("on_pre_application_entry:LockScene", m_hook_lock);
    } else if (hash == "BeginRendering"_fnv) {
        phase_pre("on_pre_application_entry:BeginRendering", m_hook_begin);
    }
    (void)name;
}

void RE4VRArmChain::on_application_entry(void*, const char* name, size_t hash) {
    if (!m_hooks_ready) {
        return;
    }
    if (hash == "LateUpdateBehavior"_fnv) {
        phase_post("on_application_entry:LateUpdateBehavior", m_hook_late);
    } else if (hash == "UpdateJointExpression"_fnv) {
        phase_post("on_application_entry:UpdateJointExpression", m_hook_expr);
    }
    (void)name;
}
#endif
