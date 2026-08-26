#define NOMINMAX
#include "RE4VRWeapons2.hpp"

#if defined(RE4)
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <utility>

#include <glm/gtc/quaternion.hpp>
#include <glm/gtx/norm.hpp>
#include <glm/gtx/quaternion.hpp>
#include <sdk/MurmurHash.hpp>
#include <sdk/REManagedObject.hpp>
#include <sdk/RETransform.hpp>
#include <sdk/RETypeDB.hpp>
#include <spdlog/spdlog.h>

#include "RE4VRCrosshair.hpp"
#include "RE4VRFrameCache.hpp"
#include "RE4VRHolster.hpp"
#include "RE4VRShared.hpp"
#include "RE4VRWeapons.hpp"
#include "../../../ScriptRunner.hpp"

std::shared_ptr<RE4VRWeapons2>& RE4VRWeapons2::get() {
    static auto inst = std::make_shared<RE4VRWeapons2>();
    return inst;
}

void RE4VRWeapons2::save_parry() {
    re4vr::save_json_file("re4_vr/re4_vr_knife_parry.json", {{"parry_tol", m_parry_tol}});
}
void RE4VRWeapons2::save_lefthand() {
    re4vr::save_json_file(m_char == "ada" ? "re4_vr/re4_vr_knife_lefthand_ada.json" : "re4_vr/re4_vr_knife_lefthand.json", {{"enabled", m_lh_enabled}});
}
void RE4VRWeapons2::save_lh_off() {}
void RE4VRWeapons2::save_lh_flip() {}

void RE4VRWeapons2::load_json() {
    auto p = re4vr::load_json_file("re4_vr/re4_vr_knife_parry.json");
    m_parry_tol = re4vr::j_num(p, "parry_tol", 1.0f);
    auto lh = re4vr::load_json_file(m_char == "ada" ? "re4_vr/re4_vr_knife_lefthand_ada.json" : "re4_vr/re4_vr_knife_lefthand.json");
    m_lh_enabled = re4vr::j_bool(lh, "enabled", true);
    auto offp = re4vr::load_json_file(m_char == "ada" ? "re4_vr/re4_vr_knife_lh_offsets_ada.json" : "re4_vr/re4_vr_knife_lh_offsets.json");
    if (offp.is_object()) {
        for (auto it = offp.begin(); it != offp.end(); ++it) {
            if (!it.value().is_object()) {
                continue;
            }
            Off3 o;
            o.x = re4vr::j_num(it.value(), "px", 0);
            o.y = re4vr::j_num(it.value(), "py", 0);
            o.z = re4vr::j_num(it.value(), "pz", 0);
            o.rx = re4vr::j_num(it.value(), "rx", 0);
            o.ry = re4vr::j_num(it.value(), "ry", 0);
            o.rz = re4vr::j_num(it.value(), "rz", 0);
            m_lh_off[it.key()] = o;
        }
    }
    auto flp = re4vr::load_json_file(m_char == "ada" ? "re4_vr/re4_vr_knife_lh_flip_offsets_ada.json" : "re4_vr/re4_vr_knife_lh_flip_offsets.json");
    if (flp.is_object()) {
        for (auto it = flp.begin(); it != flp.end(); ++it) {
            if (!it.value().is_object()) {
                continue;
            }
            Off3 o;
            o.x = re4vr::j_num(it.value(), "px", 0);
            o.y = re4vr::j_num(it.value(), "py", 0);
            o.z = re4vr::j_num(it.value(), "pz", 0);
            o.rx = re4vr::j_num(it.value(), "rx", 0);
            o.ry = re4vr::j_num(it.value(), "ry", 0);
            o.rz = re4vr::j_num(it.value(), "rz", 0);
            m_lh_flip[it.key()] = o;
        }
    }
    load_wildwest();
}

void RE4VRWeapons2::load_wildwest() {
    static const char* k_joints[] = {
        "R_Thumb1", "R_Thumb2", "R_Thumb3",
        "R_IndexF1", "R_IndexF2", "R_IndexF3",
        "R_MiddleF1", "R_MiddleF2", "R_MiddleF3",
        "R_RingF1", "R_RingF2", "R_RingF3",
        "R_PinkyF1", "R_PinkyF2", "R_PinkyF3",
    };
    m_ww_fing.clear();
    for (auto* n : k_joints) {
        m_ww_fing[n] = {};
    }
    auto d = re4vr::load_json_file("re4_vr/re4_vr_wildwest.json");
    if (!d.is_object()) {
        return;
    }
    m_ww.enabled = re4vr::j_bool(d, "enabled", true);
    m_ww.sound = re4vr::j_bool(d, "sound", true);
    m_ww.rt_gate = re4vr::j_bool(d, "rt_gate", true);
    m_ww.block_with_stock = re4vr::j_bool(d, "block_with_stock", true);
    m_ww.sustain = re4vr::j_num(d, "sustain", 0.60f);
    m_ww.sens = re4vr::j_num(d, "sens", 1.20f);
    m_ww.rt_sens = re4vr::j_num(d, "rt_sens", 0.10f);
    m_ww.rt_lockout = re4vr::j_num(d, "rt_lockout", 1.0f);
    m_ww.speed = re4vr::j_num(d, "speed", 720.0f);
    m_ww.dir = re4vr::j_num(d, "dir", 1.0f);
    m_ww.snd_interval = re4vr::j_num(d, "snd_interval", 0.12f);
    if (d.contains("pivot") && d["pivot"].is_object()) {
        m_ww.pivot_x = re4vr::j_num(d["pivot"], "x", 0);
        m_ww.pivot_y = re4vr::j_num(d["pivot"], "y", 0);
        m_ww.pivot_z = re4vr::j_num(d["pivot"], "z", 0);
    }
    if (d.contains("offset") && d["offset"].is_object()) {
        m_ww.off_x = re4vr::j_num(d["offset"], "x", 0);
        m_ww.off_y = re4vr::j_num(d["offset"], "y", 0);
        m_ww.off_z = re4vr::j_num(d["offset"], "z", 0);
    }
    if (d.contains("joints") && d["joints"].is_object()) {
        for (auto it = d["joints"].begin(); it != d["joints"].end(); ++it) {
            if (!it.value().is_object()) {
                continue;
            }
            WwEuler e;
            e.x = re4vr::j_num(it.value(), "x", 0);
            e.y = re4vr::j_num(it.value(), "y", 0);
            e.z = re4vr::j_num(it.value(), "z", 0);
            m_ww_fing[it.key()] = e;
        }
    } else if (d.contains("fingers") && d["fingers"].is_object()) {
        static const std::pair<const char*, std::array<const char*, 3>> old_map[] = {
            {"thumb", {"R_Thumb1", "R_Thumb2", "R_Thumb3"}},
            {"index", {"R_IndexF1", "R_IndexF2", "R_IndexF3"}},
            {"middle", {"R_MiddleF1", "R_MiddleF2", "R_MiddleF3"}},
            {"ring", {"R_RingF1", "R_RingF2", "R_RingF3"}},
            {"pinky", {"R_PinkyF1", "R_PinkyF2", "R_PinkyF3"}},
        };
        for (auto& [fn, joints] : old_map) {
            if (!d["fingers"].contains(fn) || !d["fingers"][fn].is_object()) {
                continue;
            }
            auto& s = d["fingers"][fn];
            WwEuler e;
            e.x = re4vr::j_num(s, "x", 0);
            e.y = re4vr::j_num(s, "y", 0);
            e.z = re4vr::j_num(s, "z", 0);
            for (auto* jn : joints) {
                m_ww_fing[jn] = e;
            }
        }
    }
    m_ww_okeys.clear();
    auto load_arr = [](const nlohmann::json& arr) {
        std::vector<WwKf> t2;
        if (!arr.is_array()) {
            return t2;
        }
        for (auto& kf : arr) {
            if (!kf.is_object() || !kf.contains("a") || !kf["a"].is_number()) {
                continue;
            }
            t2.push_back(WwKf{re4vr::j_num(kf, "a", 0), re4vr::j_num(kf, "x", 0), re4vr::j_num(kf, "y", 0), re4vr::j_num(kf, "z", 0)});
        }
        std::sort(t2.begin(), t2.end(), [](const WwKf& a, const WwKf& b) { return a.a < b.a; });
        return t2;
    };
    if (d.contains("okeys_by_wid") && d["okeys_by_wid"].is_object()) {
        for (auto it = d["okeys_by_wid"].begin(); it != d["okeys_by_wid"].end(); ++it) {
            const int32_t wn = (int32_t)std::strtol(it.key().c_str(), nullptr, 10);
            if (wn) {
                m_ww_okeys[wn] = load_arr(it.value());
            }
        }
    } else if (d.contains("okeys")) {
        m_ww_okeys[4003] = load_arr(d["okeys"]);
    }
}

void RE4VRWeapons2::apply_wildwest_fingers() {
    if (m_ww_finger_blend <= 0.001f) {
        return;
    }
    auto* tf = re4vr::body_transform();
    if (!tf) {
        return;
    }
    const float b = m_ww_finger_blend;
    auto ax = [](float a, float x, float y, float z) {
        const float h = glm::radians(a) * 0.5f;
        const float s = std::sin(h);
        return glm::quat{std::cos(h), x * s, y * s, z * s};
    };
    for (auto& [name, e] : m_ww_fing) {
        const float dx = e.x * b, dy = e.y * b, dz = e.z * b;
        if (dx == 0.f && dy == 0.f && dz == 0.f) {
            continue;
        }
        auto* j = re4vr::joint_by_name(tf, name);
        if (!j) {
            continue;
        }
        const auto add = glm::normalize(ax(dx, 1, 0, 0) * ax(dy, 0, 1, 0) * ax(dz, 0, 0, 1));
        const auto cur = sdk::get_joint_local_rotation(j);
        sdk::set_joint_local_rotation(j, glm::normalize(cur * add));
    }
}

std::optional<std::string> RE4VRWeapons2::on_initialize() {
    load_json();
    if (auto* td = sdk::find_type_definition("chainsaw.PlayerHeadActionSign")) {
        for (auto& m : td->get_methods()) {
            if (std::string{m.get_name()} == "updateParryRequest") {
                g_hookman.add(&m, &RE4VRWeapons2::pre_request_action, &RE4VRWeapons2::post_nop);
            }
        }
    }
    if (auto* td = sdk::find_type_definition("chainsaw.PlayerEquipment")) {
        if (auto* m = td->get_method("equipWeapon")) {
            g_hookman.add(m, &RE4VRWeapons2::pre_equip_weapon, &RE4VRWeapons2::post_nop);
        }
    }
    return std::nullopt;
}

void RE4VRWeapons2::export_globals(sol::state& lua) {
    lua["__re4_knife_blood_on"] = m_blood_on;
    lua["__re4_knife_lt_flip_tap"] = m_lt_flip_tap;
    lua["__re4_lh_flip_speed"] = m_lh_flip_speed;
    lua["__re4_lh_swing_speed"] = m_lh_swing_speed;
    lua["__re4_apply_left_knife_pose"] = [this](::REManagedObject* go) { apply_left_knife_pose(go); };
    lua["__re4_char_now"] = m_char;
    auto off = lua.create_table();
    for (auto& [k, o] : m_lh_off) {
        auto t = lua.create_table();
        t["px"] = o.x;
        t["py"] = o.y;
        t["pz"] = o.z;
        t["rx"] = o.rx;
        t["ry"] = o.ry;
        t["rz"] = o.rz;
        off[k] = t;
    }
    lua["__re4_knife_lh_off_map"] = off;
    auto fl = lua.create_table();
    for (auto& [k, o] : m_lh_flip) {
        auto t = lua.create_table();
        t["px"] = o.x;
        t["py"] = o.y;
        t["pz"] = o.z;
        t["rx"] = o.rx;
        t["ry"] = o.ry;
        t["rz"] = o.rz;
        fl[k] = t;
    }
    lua["__re4_knife_flip_lh_map"] = fl;
}

void RE4VRWeapons2::on_lua_state_created(sol::state& lua) {
    export_globals(lua);
}
void RE4VRWeapons2::on_lua_state_destroyed(sol::state&) {
    clone_destroy();
}

bool RE4VRWeapons2::prompt_visible() {
    return RE4VRCrosshair::get()->is_finisher_prompt();
}
bool RE4VRWeapons2::reverse_grip() {
    return RE4VRShared::get()->vr_knife_flip;
}
bool RE4VRWeapons2::knife_out() {
    return RE4VRShared::get()->re4_knife_equipped || RE4VRShared::get()->re4_knife_left_clone;
}

void RE4VRWeapons2::parry_tick() {
    if (RE4VRShared::get()->re4_ks_active) {
        return;
    }
    const double now = re4vr::now();
    RE4VRShared::get()->re4_knife_finisher_shake = now < m_parry_until;
    bool pose = false;
    if (knife_out() && !RE4VRShared::get()->re4_knife_flying && VR::get()->is_hmd_active()) {
        const bool left = RE4VRShared::get()->re4_knife_hand.value_or("") == "left" || RE4VRShared::get()->re4_knife_left_clone;
        auto& ctrls = VR::get()->get_controllers();
        const int cidx = left ? 0 : 1;
        if ((int)ctrls.size() > cidx) {
            const auto hp = re4vr::v3(VR::get()->get_position(0));
            const auto hq = glm::quat{VR::get()->get_rotation(0)};
            const auto rp = re4vr::v3(VR::get()->get_position(ctrls[cidx]));
            const auto rq = glm::quat{VR::get()->get_rotation(ctrls[cidx])};
            const float rpx = left ? -0.026f : 0.026f;
            const glm::quat pref{0.057f, 0.653f, left ? 0.054f : -0.054f, left ? -0.753f : 0.753f};
            const auto hqc = glm::conjugate(hq);
            const auto relp = re4vr::quat_rotate(hqc, rp - hp);
            const auto relq = glm::normalize(hqc * rq);
            const float pdist = glm::length(relp - Vector3f{rpx, 0.015f, -0.469f});
            float dot = std::abs(relq.w * pref.w + relq.x * pref.x + relq.y * pref.y + relq.z * pref.z);
            dot = std::min(dot, 1.0f);
            const float rang = 2.0f * std::acos(dot);
            if (pdist < (0.30f * m_parry_tol) && rang < (0.70f * m_parry_tol)) {
                pose = true;
            }
        }
    }
    RE4VRShared::get()->re4_knife_parry_pose = pose;
    if (pose && !m_parry_was) {
        RE4VRShared::get()->re4_knife_parry_fresh_until = now + 0.50;
    }
    m_parry_was = pose;
    if (!(knife_out() && reverse_grip() && prompt_visible())) {
        return;
    }
    auto& ctrls = VR::get()->get_controllers();
    const bool left = RE4VRShared::get()->re4_knife_hand.value_or("") == "left" || RE4VRShared::get()->re4_knife_left_clone;
    const int cidx = left ? 0 : 1;
    if ((int)ctrls.size() <= cidx) {
        return;
    }
    const auto wp = re4vr::v3(VR::get()->get_position(ctrls[cidx]));
    static std::optional<Vector3f> last_p;
    static double last_t = 0;
    static int last_dir = 0, reversals = 0;
    static int last_cidx = -1;
    if (last_cidx != cidx) {
        last_cidx = cidx;
        last_p.reset();
        reversals = 0;
        last_dir = 0;
    }
    if (last_p) {
        const float dt = (float)(now - last_t);
        if (dt > 1e-4f && dt < 0.2f) {
            const auto d = wp - *last_p;
            const float vy = d.y / dt;
            const float vh = std::sqrt(d.x * d.x + d.z * d.z) / dt;
            if (std::abs(vy) > 0.80f && std::abs(vy) > 0.50f * vh) {
                const int dir = vy > 0 ? 1 : -1;
                if (last_dir != 0 && dir != last_dir) {
                    ++reversals;
                }
                last_dir = dir;
                if (reversals >= 1) {
                    m_parry_until = now + 0.12;
                    reversals = 0;
                }
            }
        }
    }
    last_p = wp;
    last_t = now;
}

void RE4VRWeapons2::lh_char_tick() {
    auto* body = re4vr::body_game_object();
    if (!body) {
        return;
    }
    const auto n = re4vr::go_name((::REManagedObject*)body);
    std::string want;
    if (n == "ch3a8z0_body") {
        want = "ada";
    } else if (n == "ch0a0z0_body" || n == "ch0a1z0_body") {
        want = "leon";
    } else {
        return;
    }
    if (want == m_char) {
        return;
    }
    m_char = want;
    RE4VRShared::get()->re4_char_now = std::string{want};
    load_json();
}

void RE4VRWeapons2::clone_destroy() {
    if (m_lh_clone) {
        re4vr::destroy_game_object((::REManagedObject*)m_lh_clone);
    }
    m_lh_clone = nullptr;
    m_lh_clone_on = false;
    RE4VRShared::get()->re4_knife_lh_clone_go = nullptr;
    RE4VRShared::get()->re4_knife_left_clone = false;
}

void RE4VRWeapons2::clone_spawn() {
    auto* body = re4vr::body_game_object();
    auto* tf = body ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(body, "get_Transform"); }).value_or(nullptr) : nullptr;
    if (!tf) {
        return;
    }
    ::REManagedObject* gmesh = nullptr;
    auto* c = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(tf, "get_Child"); }).value_or(nullptr);
    int guard = 0;
    while (c && guard++ < 256 && !gmesh) {
        auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(c, "get_GameObject"); }).value_or(nullptr);
        auto nm = go ? re4vr::go_name((::REManagedObject*)go) : std::string{};
        int wid = 0;
        if (nm.size() > 2 && nm[0] == 'w' && nm[1] == 'p') {
            wid = std::atoi(nm.c_str() + 2);
        }
        if (wid && RE4VRWeapons::get()->is_knife_id(wid)) {
            gmesh = re4vr::get_component((::REManagedObject*)go, "via.render.Mesh");
            m_current_knife_wid = wid;
        }
        c = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(c, "get_Next"); }).value_or(nullptr);
    }
    if (!gmesh) {
        return;
    }
    auto* holder = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(gmesh, "getMesh"); }).value_or(nullptr);
    if (!holder) {
        return;
    }
    auto* go = re4vr::create_game_object("vr_lh_knife");
    if (!go) {
        return;
    }
    re4vr::pcall([&] { utility::re_managed_object::add_ref(go); });
    re4vr::pcall([&] { sdk::call_object_func_easy<::REManagedObject*>(go, "createComponent(System.Type)", re4vr::runtime_type("via.motion.Motion")); });
    auto* mesh = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(go, "createComponent(System.Type)", re4vr::runtime_type("via.render.Mesh")); }).value_or(nullptr);
    if (!mesh) {
        return;
    }
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "setMesh", holder); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "set_DrawDefault", true); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "set_Enabled", true); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "set_FrustumCulling", false); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "set_DrawShadowCast", false); });
    auto* ctf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr);
    auto* btf = re4vr::body_transform();
    if (ctf && btf && re4vr::go_valid((::REManagedObject*)go)) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(ctf, "set_Parent", btf); });
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(ctf, "set_ParentJoint", sdk::VM::create_managed_string(L"L_Hand")); });
    }
    m_lh_clone = go;
    RE4VRShared::get()->re4_knife_lh_clone_go = (::REManagedObject*)go;
    RE4VRShared::get()->re4_knife_left_clone = true;
    m_lh_clone_on = true;
}

void RE4VRWeapons2::clone_apply_pose() {
    if (!m_lh_clone) {
        return;
    }
    auto* tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(m_lh_clone, "get_Transform"); }).value_or(nullptr);
    if (!tf) {
        return;
    }
    Off3 o{};
    if (m_current_knife_wid) {
        auto k = std::to_string(*m_current_knife_wid);
        auto it = RE4VRShared::get()->vr_knife_flip ? m_lh_flip.find(k) : m_lh_off.find(k);
        auto& map = RE4VRShared::get()->vr_knife_flip ? m_lh_flip : m_lh_off;
        if (auto f = map.find(k); f != map.end()) {
            o = f->second;
        }
    }
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(tf, "set_LocalPosition", Vector3f{o.x, o.y, o.z}); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(tf, "set_LocalRotation", re4vr::quat_euler_yxz_deg(o.rx, o.ry, o.rz)); });
}

void RE4VRWeapons2::apply_left_knife_pose(::REManagedObject* go) {
    if (go) {
        m_lh_clone = (::REGameObject*)go;
    }
    clone_apply_pose();
}

void RE4VRWeapons2::clone_manage() {
    const bool want = RE4VRShared::get()->re4_knife_left_intent && m_lh_enabled;
    if (want && !m_lh_clone) {
        clone_spawn();
    } else if (!want && m_lh_clone) {
        clone_destroy();
    }
    if (m_lh_clone) {
        clone_apply_pose();
        RE4VRShared::get()->re4_knife_left_clone = true;
        if (m_current_knife_wid) {
            RE4VRShared::get()->re4_current_knife_wid = *m_current_knife_wid;
        }
    }
}

void RE4VRWeapons2::left_knife_tick() {
    const bool hz = RE4VRShared::get()->re4_knife_lh_in_zone;
    const bool grip = re4vr::grip_held(true);
    static bool was_grip = false;
    if (hz && grip && !was_grip) {
        const bool out = knife_out() || m_lh_clone;
        if (out && (RE4VRShared::get()->re4_knife_left_clone || RE4VRShared::get()->re4_knife_hand.value_or("") == "left")) {
            RE4VRShared::get()->re4_knife_left_intent = false;
            RE4VRHolster::get()->set_suppress(true);
            RE4VRHolster::get()->holster_bare();
        } else if (!RE4VRShared::get()->re4_knife_equipped) {
            RE4VRShared::get()->re4_knife_left_intent = true;
            RE4VRShared::get()->re4_knife_draw_ours_t = re4vr::now();
            RE4VRHolster::get()->defer([this]() {
                auto* pe = RE4VRFrameCache::get()->pe();
                if (!pe) {
                    auto* head = re4vr::head_game_object();
                    pe = head ? re4vr::get_component((::REManagedObject*)head, "chainsaw.PlayerEquipment") : nullptr;
                }
                if (!pe) {
                    return;
                }
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "clearRequest"); });
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "requestEquipKnife"); });
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "execChangeWeapon"); });
            });
            RE4VRHolster::get()->play_grab_sound();
        }
    }
    was_grip = grip;
    clone_manage();
}

namespace {
constexpr float WW_BOB_GAP = 0.5f;
constexpr float WW_BLEND_SPD = 8.0f;
constexpr float WW_VOICE_MIN = 1.5f;
constexpr int WW_VOICE_EVERY = 7;
constexpr int WW_VOICE_END_EVERY = 11;
constexpr uint32_t WW_TWIRL_SND = 288425943u;
constexpr uint32_t WW_VOICE_END = 3778512958u;
constexpr uint32_t WW_VOICE[] = {1517954045u, 2778708114u, 3878582777u};
constexpr const char* WW_VOICE_BODY = "ch0a0z0_body";
constexpr const char* WW_TRIGGER_JOINT = "_03";
} // namespace

void RE4VRWeapons2::ww_reset_bob() {
    m_ww_prev_vsign = 0;
    m_ww_prev_vsign_t = 0;
    m_ww_bob_started.reset();
    m_ww_last_flip_t = 0;
}

void RE4VRWeapons2::ww_sound_reset() {
    m_ww_snd_next = 0;
}

void RE4VRWeapons2::ww_reset_all() {
    m_ww_spin = {};
    m_ww_angle = 0;
    m_ww_progress = 0;
    m_ww_finger_blend = 0;
    m_ww_prev_y.reset();
    m_ww_active_lp.reset();
    ww_reset_bob();
    ww_sound_reset();
}

bool RE4VRWeapons2::ww_is_pistol(int32_t wid) const {
    switch (wid) {
    case 4000:
    case 4001:
    case 4002:
    case 4003:
    case 4004:
    case 4500:
    case 4501:
    case 4502:
    case 6000:
    case 6103:
    case 6112:
    case 6113:
    case 6300:
        return true;
    default:
        return false;
    }
}

::REManagedObject* RE4VRWeapons2::ww_head_updater() {
    auto* ctx = re4vr::player_context();
    if (!re4vr::obj_ok(ctx)) {
        return nullptr;
    }
    return re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_HeadUpdater"); }).value_or(nullptr);
}

std::optional<int32_t> RE4VRWeapons2::ww_wid(::REManagedObject* hu) {
    if (!re4vr::obj_ok(hu)) {
        return std::nullopt;
    }
    if (auto n = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(hu, "get_EquipWeaponID"); })) {
        return n;
    }
    auto* o = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(hu, "get_EquipWeaponID"); }).value_or(nullptr);
    if (!re4vr::obj_ok(o)) {
        return std::nullopt;
    }
    return re4vr::safe([&] { return utility::re_managed_object::get_field<int32_t>(o, "value__"); });
}

::RETransform* RE4VRWeapons2::ww_weap_tf(::REManagedObject* hu) {
    if (!re4vr::obj_ok(hu)) {
        return nullptr;
    }
    auto* weap = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(hu, "get_EquipWeapon"); }).value_or(nullptr);
    if (!re4vr::obj_ok(weap)) {
        return nullptr;
    }
    auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(weap, "get_GameObject"); }).value_or(nullptr);
    if (!re4vr::obj_ok((::REManagedObject*)go)) {
        return nullptr;
    }
    return re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr);
}

bool RE4VRWeapons2::ww_stock_mounted(int32_t wid) {
    if (!m_ww.block_with_stock) {
        return false;
    }
    const double now = re4vr::now();
    if (m_ww_stock_wid == wid && (now - m_ww_stock_t) < 0.25) {
        return m_ww_stock_on;
    }
    m_ww_stock_wid = wid;
    m_ww_stock_t = now;
    m_ww_stock_on = false;

    auto pe_ok = [&](::REManagedObject* pe) {
        if (!re4vr::obj_ok(pe)) {
            return false;
        }
        return re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(pe, "get_Context"); }).has_value();
    };
    if (!pe_ok(m_ww_pe)) {
        m_ww_pe = nullptr;
        auto* head = re4vr::head_game_object();
        m_ww_pe = head ? re4vr::get_component((::REManagedObject*)head, "chainsaw.PlayerEquipment") : nullptr;
    }
    auto* acc = m_ww_pe ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(m_ww_pe, "getEquipWeaponAccessor"); }).value_or(nullptr) : nullptr;
    auto* wi = acc ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(acc, "get_Item"); }).value_or(nullptr) : nullptr;
    const bool eqp = wi ? re4vr::safe([&] { return sdk::call_object_func_easy<bool>(wi, "isPartsEquipped"); }).value_or(false) : false;
    if (!eqp) {
        return false;
    }
    std::optional<int32_t> pid = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(wi, "getEquippedPartsItemId"); });
    if (!pid) {
        auto* po = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(wi, "getEquippedPartsItemId"); }).value_or(nullptr);
        if (re4vr::obj_ok(po)) {
            pid = re4vr::safe([&] { return utility::re_managed_object::get_field<int32_t>(po, "value__"); });
        }
    }
    m_ww_stock_on = pid && (*pid == 116001600 || *pid == 116009600);
    return m_ww_stock_on;
}

std::optional<Vector3f> RE4VRWeapons2::ww_local_pivot(::RETransform* tf) {
    if (!tf) {
        return std::nullopt;
    }
    auto O = re4vr::safe([&] { return sdk::get_transform_position(tf); });
    auto Q = re4vr::safe([&] { return sdk::get_transform_rotation(tf); });
    if (!O || !Q) {
        return std::nullopt;
    }
    auto* jt = re4vr::joint_by_name(tf, WW_TRIGGER_JOINT);
    if (!jt) {
        return std::nullopt;
    }
    auto J = re4vr::safe([&] { return sdk::get_joint_position(jt); });
    if (!J) {
        return std::nullopt;
    }
    const Vector3f diff = re4vr::v3(*J) - re4vr::v3(*O);
    return re4vr::quat_rotate(glm::conjugate(*Q), diff);
}

std::optional<Vector3f> RE4VRWeapons2::ww_offset_at(float phase) {
    if (!m_ww_cur_wid) {
        return std::nullopt;
    }
    auto it = m_ww_okeys.find(*m_ww_cur_wid);
    if (it == m_ww_okeys.end() || it->second.empty()) {
        return std::nullopt;
    }
    const auto& keys = it->second;
    const int n = (int)keys.size();
    phase = std::fmod(phase, 360.0f);
    if (phase < 0) {
        phase += 360.0f;
    }
    if (n == 1) {
        return Vector3f{keys[0].x, keys[0].y, keys[0].z};
    }
    int lo = -1, hi = -1;
    for (int i = 0; i < n; ++i) {
        if (keys[i].a <= phase) {
            lo = i;
        } else {
            break;
        }
    }
    for (int i = n - 1; i >= 0; --i) {
        if (keys[i].a >= phase) {
            hi = i;
        } else {
            break;
        }
    }
    if (lo >= 0 && hi >= 0 && lo == hi) {
        return Vector3f{keys[lo].x, keys[lo].y, keys[lo].z};
    }
    float t = 0;
    const WwKf* loa = nullptr;
    const WwKf* hia = nullptr;
    if (lo < 0 || hi < 0) {
        loa = &keys[n - 1];
        hia = &keys[0];
        const float span = keys[0].a + 360.0f - keys[n - 1].a;
        const float d = (phase >= keys[n - 1].a) ? (phase - keys[n - 1].a) : (phase + 360.0f - keys[n - 1].a);
        t = (span > 0.0001f) ? (d / span) : 0.0f;
    } else {
        loa = &keys[lo];
        hia = &keys[hi];
        const float span = hia->a - loa->a;
        t = (span > 0.0001f) ? ((phase - loa->a) / span) : 0.0f;
    }
    t = std::clamp(t, 0.0f, 1.0f);
    return Vector3f{
        loa->x + (hia->x - loa->x) * t,
        loa->y + (hia->y - loa->y) * t,
        loa->z + (hia->z - loa->z) * t,
    };
}

std::optional<float> RE4VRWeapons2::ww_right_ctrl_y() {
    auto vr = VR::get();
    if (!vr || !vr->is_hmd_active()) {
        return std::nullopt;
    }
    auto& cs = vr->get_controllers();
    if (cs.size() < 2) {
        return std::nullopt;
    }
    return vr->get_position(cs[1]).y;
}

bool RE4VRWeapons2::ww_rt_gate() {
    if (!m_ww.rt_gate) {
        return false;
    }
    auto* s = RE4VRShared::get().get();
    if (s->vr_shot_seq) {
        const double seq = *s->vr_shot_seq;
        if (!m_ww_last_shot_seq || seq != *m_ww_last_shot_seq) {
            if (m_ww_last_shot_seq) {
                m_ww_last_shot_t = re4vr::now();
            }
            m_ww_last_shot_seq = seq;
        }
    }
    const bool raw = s->vr_raw_r_trigger;
    if (raw && !m_ww_rt_prev_raw) {
        m_ww_rt_press_armed = !s->vr_aim_input && !s->is_aim;
    } else if (!raw) {
        m_ww_rt_press_armed = false;
    }
    m_ww_rt_prev_raw = raw;
    if (!raw || !m_ww_rt_press_armed) {
        return false;
    }
    if ((re4vr::now() - m_ww_last_shot_t) < m_ww.rt_lockout) {
        return false;
    }
    if (!s->re4_frame_pure_gameplay) {
        return false;
    }
    if (s->re4_knife_equipped && s->re4_knife_hand.value_or("") != "left") {
        return false;
    }
    return true;
}

::REManagedObject* RE4VRWeapons2::ww_sound_container(::REManagedObject* hu) {
    auto* T = ww_weap_tf(hu);
    if (!T) {
        return nullptr;
    }
    auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(T, "get_GameObject"); }).value_or(nullptr);
    if (!re4vr::obj_ok((::REManagedObject*)go)) {
        return nullptr;
    }
    return re4vr::get_component((::REManagedObject*)go, "soundlib.SoundContainer");
}

void RE4VRWeapons2::ww_sound_tick(::REManagedObject* hu, double now) {
    if (!m_ww.sound) {
        return;
    }
    if (now < m_ww_snd_next) {
        return;
    }
    auto* scn = ww_sound_container(hu);
    if (!scn) {
        return;
    }
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(scn, "trigger(System.UInt32)", WW_TWIRL_SND); });
    m_ww_snd_next = now + std::max(0.03f, m_ww.snd_interval);
}

::REManagedObject* RE4VRWeapons2::ww_voice_container() {
    auto* go = re4vr::body_game_object();
    if (!re4vr::obj_ok((::REManagedObject*)go)) {
        return nullptr;
    }
    if (re4vr::go_name((::REManagedObject*)go) != WW_VOICE_BODY) {
        return nullptr;
    }
    return re4vr::get_component((::REManagedObject*)go, "soundlib.SoundContainer");
}

void RE4VRWeapons2::ww_voice_tick() {
    if (m_ww_voice.fired || !m_ww_voice.t0) {
        return;
    }
    if (m_ww_voice.dur < WW_VOICE_MIN) {
        return;
    }
    m_ww_voice.fired = true;
    m_ww_voice.count += 1;
    if ((m_ww_voice.count % WW_VOICE_EVERY) != 0) {
        return;
    }
    auto* scn = ww_voice_container();
    if (!scn) {
        return;
    }
    constexpr int n = (int)(sizeof(WW_VOICE) / sizeof(WW_VOICE[0]));
    int li = -1;
    for (int i = 0; i < n; ++i) {
        if (WW_VOICE[i] == m_ww_voice.last_id) {
            li = i;
            break;
        }
    }
    int pick = 0;
    if (n > 1 && li >= 0) {
        pick = std::rand() % (n - 1);
        if (pick >= li) {
            pick += 1;
        }
    } else {
        pick = std::rand() % n;
    }
    const uint32_t id = WW_VOICE[pick];
    if (re4vr::pcall([&] { sdk::call_object_func_easy<void*>(scn, "trigger(System.UInt32)", id); })) {
        m_ww_voice.last_id = id;
    }
}

void RE4VRWeapons2::ww_voice_end() {
    if (!m_ww_voice.fired) {
        return;
    }
    m_ww_voice.end_count += 1;
    if ((m_ww_voice.end_count % WW_VOICE_END_EVERY) != 0) {
        return;
    }
    auto* scn = ww_voice_container();
    if (!scn) {
        return;
    }
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(scn, "trigger(System.UInt32)", WW_VOICE_END); });
}

void RE4VRWeapons2::apply_wildwest(Vector3f& wpos, glm::quat& wrot) {
    const float a = m_ww_angle;
    if (a == 0.0f) {
        return;
    }
    glm::quat new_wrot = wrot;
    Vector3f new_wpos = wpos;
    const float h = a * 0.5f;
    const glm::quat R{std::cos(h), std::sin(h), 0.0f, 0.0f};
    new_wrot = glm::normalize(wrot * R);
    if (m_ww_active_lp) {
        new_wpos = (wpos + re4vr::quat_rotate(wrot, *m_ww_active_lp)) - re4vr::quat_rotate(new_wrot, *m_ww_active_lp);
    }
    float ox = 0, oy = 0, oz = 0;
    const bool editing = m_ww.pose_preview && !m_ww_spin.active && !m_ww.prev_interp;
    const auto* keys = m_ww_cur_wid ? &m_ww_okeys[*m_ww_cur_wid] : nullptr;
    if (editing || !keys || keys->empty()) {
        ox = m_ww.off_x;
        oy = m_ww.off_y;
        oz = m_ww.off_z;
    } else if (auto off = ww_offset_at(m_ww_progress)) {
        ox = off->x;
        oy = off->y;
        oz = off->z;
    }
    if (ox != 0.0f || oy != 0.0f || oz != 0.0f) {
        new_wpos += re4vr::quat_rotate(wrot, Vector3f{ox, oy, oz});
    }
    wpos = new_wpos;
    wrot = new_wrot;
}

void RE4VRWeapons2::wildwest_tick() {
    if (!m_ww.enabled) {
        ww_reset_all();
        return;
    }
    const double now = re4vr::now();
    auto* hu = ww_head_updater();
    auto wid = ww_wid(hu);
    if (!wid || !ww_is_pistol(*wid) || ww_stock_mounted(*wid)) {
        ww_reset_all();
        return;
    }
    m_ww_cur_wid = wid;
    if (m_ww_okeys.find(*wid) == m_ww_okeys.end()) {
        m_ww_okeys[*wid] = {};
    }

    if (!m_ww_spin.active) {
        if (auto* T = ww_weap_tf(hu)) {
            if (auto lp = ww_local_pivot(T)) {
                m_ww_pivot[*wid] = *lp;
            }
        }
    }
    if (auto it = m_ww_pivot.find(*wid); it != m_ww_pivot.end()) {
        m_ww_active_lp = it->second + Vector3f{m_ww.pivot_x, m_ww.pivot_y, m_ww.pivot_z};
    } else {
        m_ww_active_lp.reset();
    }

    float dt = m_ww_prev_t ? (float)(now - *m_ww_prev_t) : 0.016f;
    if (dt <= 0) {
        dt = 0.016f;
    } else if (dt > 0.1f) {
        dt = 0.1f;
    }
    const bool aiming = RE4VRShared::get()->is_aim;

    const bool gate = ww_rt_gate();
    const float ww_sens_now = gate ? m_ww.rt_sens : m_ww.sens;
    if (m_ww_rt_gate_prev && !gate && m_ww_spin.active && m_ww_spin.by_rt && !m_ww_spin.finishing) {
        m_ww_spin.finishing = true;
        m_ww_spin.finish_target = std::ceil(m_ww_spin.deg / 360.0f) * 360.0f;
    }
    m_ww_rt_gate_prev = gate;

    auto y = ww_right_ctrl_y();
    if (y && m_ww_prev_y && m_ww_prev_t) {
        const double d = now - *m_ww_prev_t;
        if (d > 0.0005) {
            const float vy = (float)((*y - *m_ww_prev_y) / d);
            if (std::abs(vy) >= ww_sens_now) {
                const int vsign = vy > 0 ? 1 : -1;
                if (m_ww_prev_vsign != 0 && (now - m_ww_prev_vsign_t) > WW_BOB_GAP) {
                    m_ww_prev_vsign = 0;
                }
                if (m_ww_prev_vsign != 0 && vsign != m_ww_prev_vsign) {
                    if (!m_ww_bob_started || (now - m_ww_last_flip_t) > WW_BOB_GAP) {
                        m_ww_bob_started = now;
                    }
                    m_ww_last_flip_t = now;
                }
                m_ww_prev_vsign = vsign;
                m_ww_prev_vsign_t = now;
            }
        }
    }
    if (m_ww_bob_started && (now - m_ww_last_flip_t) > WW_BOB_GAP) {
        ww_reset_bob();
    }
    const bool bobbing = m_ww_bob_started && ((now - m_ww_last_flip_t) <= WW_BOB_GAP);

    if (m_ww_spin.active) {
        m_ww_spin.deg += m_ww.speed * dt;
        if (!m_ww_spin.finishing && m_ww_voice.t0) {
            m_ww_voice.dur = now - *m_ww_voice.t0;
            ww_voice_tick();
        }
        if (m_ww_spin.finishing) {
            if (m_ww_spin.deg >= m_ww_spin.finish_target) {
                m_ww_spin.active = false;
                m_ww_spin.finishing = false;
                m_ww_spin.deg = 0;
                m_ww_angle = 0;
                m_ww_voice.t0.reset();
                ww_voice_end();
            }
        } else if (!bobbing || aiming) {
            m_ww_spin.finishing = true;
            m_ww_spin.finish_target = std::ceil(m_ww_spin.deg / 360.0f) * 360.0f;
        }
        if (m_ww_spin.active) {
            const float dir = m_ww.dir >= 0 ? 1.0f : -1.0f;
            m_ww_angle = glm::radians(m_ww_spin.deg) * dir;
            m_ww_progress = std::fmod(m_ww_spin.deg, 360.0f);
            if (m_ww_progress < 0) {
                m_ww_progress += 360.0f;
            }
        }
    } else {
        const float sustain_now = gate ? 0.0f : m_ww.sustain;
        const bool start_allowed = !m_ww.rt_gate || gate;
        if (start_allowed && !aiming && m_ww_bob_started && (now - *m_ww_bob_started) >= sustain_now) {
            m_ww_spin.active = true;
            m_ww_spin.finishing = false;
            m_ww_spin.deg = 0;
            m_ww_spin.by_rt = gate;
            m_ww_voice.t0 = now;
            m_ww_voice.dur = 0;
            m_ww_voice.fired = false;
            if (auto* Tsp = ww_weap_tf(hu)) {
                if (auto lp = ww_local_pivot(Tsp)) {
                    m_ww_pivot[*wid] = *lp;
                }
            }
        }
    }

    if (m_ww_spin.active && m_ww.sound) {
        ww_sound_tick(hu, now);
    } else {
        ww_sound_reset();
    }

    const float tgt = (m_ww_spin.active || m_ww.pose_preview) ? 1.0f : 0.0f;
    m_ww_finger_blend += (tgt - m_ww_finger_blend) * std::min(1.0f, dt * WW_BLEND_SPD);
    if (m_ww_finger_blend < 0.0005f) {
        m_ww_finger_blend = 0.0f;
    }

    if (!m_ww_spin.active && m_ww.pose_preview) {
        const float dir = m_ww.dir >= 0 ? 1.0f : -1.0f;
        m_ww_angle = glm::radians(m_ww.prev_angle) * dir;
        m_ww_progress = std::fmod(m_ww.prev_angle, 360.0f);
        if (m_ww_progress < 0) {
            m_ww_progress += 360.0f;
        }
    }

    m_ww_prev_y = y;
    m_ww_prev_t = now;
}
void RE4VRWeapons2::blood_tick() {
    RE4VRShared::get()->re4_knife_blood_on = m_blood_on;
}
void RE4VRWeapons2::knife_di_guard() {}
void RE4VRWeapons2::exec_native_melee() {
    RE4VRWeapons::get()->do_knife_melee();
}
void RE4VRWeapons2::native_hit(::REManagedObject*, const Vector3f&) {}
std::optional<int32_t> RE4VRWeapons2::get_selected_knife_wid() {
    return m_current_knife_wid;
}
::REManagedObject* RE4VRWeapons2::find_knife_mesh() {
    return nullptr;
}

HookManager::PreHookResult RE4VRWeapons2::pre_request_action(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    if (!RE4VRShared::get()->re4_knife_parry_pose) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    if (RE4VRShared::get()->re4_knife_parry_fresh_until.value_or(0) < re4vr::now()) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    if (args.size() > 1 && args[1]) {
        auto* self = (::REManagedObject*)args[1];
        auto* info = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(self, "get_ParryInfo"); }).value_or(nullptr);
        if (info && re4vr::safe([&] { return sdk::call_object_func_easy<bool>(info, "get_IsEnable"); }).value_or(false)) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(info, "set_RequestAction", true); });
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(info, "set_Reserve", true); });
        }
    }
    return HookManager::PreHookResult::CALL_ORIGINAL;
}
HookManager::PreHookResult RE4VRWeapons2::pre_equip_weapon(std::vector<uintptr_t>&, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    return HookManager::PreHookResult::CALL_ORIGINAL;
}
void RE4VRWeapons2::post_nop(uintptr_t&, sdk::RETypeDefinition*, uintptr_t) {}

void RE4VRWeapons2::on_frame() {
    ScriptProfileGuard guard("re4_vr_weapons2.lua", "on_frame", re4vr::profile_frame());
    parry_tick();
    lh_char_tick();
    left_knife_tick();
    wildwest_tick();
    blood_tick();
}

void RE4VRWeapons2::on_pre_application_entry(void*, const char*, size_t hash) {
    if (hash == "LockScene"_fnv && m_lh_clone) {
        ScriptProfileGuard guard("re4_vr_weapons2.lua", "on_pre_application_entry:LockScene", re4vr::profile_frame());
        clone_apply_pose();
    }
}
void RE4VRWeapons2::on_application_entry(void*, const char*, size_t hash) {
    if ((hash == "LateUpdateBehavior"_fnv || hash == "BeginRendering"_fnv) && m_lh_clone) {
        ScriptProfileGuard guard("re4_vr_weapons2.lua", "on_application_entry", re4vr::profile_frame());
        clone_apply_pose();
    }
}
#endif
