#define NOMINMAX
#include "RE4VRWeapons2.hpp"

#if defined(RE4)
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <functional>
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
            o.x = re4vr::j_num(it.value(), "px", re4vr::j_num(it.value(), "x", 0));
            o.y = re4vr::j_num(it.value(), "py", re4vr::j_num(it.value(), "y", 0));
            o.z = re4vr::j_num(it.value(), "pz", re4vr::j_num(it.value(), "z", 0));
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
            o.x = re4vr::j_num(it.value(), "px", re4vr::j_num(it.value(), "x", 0));
            o.y = re4vr::j_num(it.value(), "py", re4vr::j_num(it.value(), "y", 0));
            o.z = re4vr::j_num(it.value(), "pz", re4vr::j_num(it.value(), "z", 0));
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

void RE4VRWeapons2::drop_di_caches() {
    m_native_di = nullptr;
    m_dmginfo_cap = nullptr;
}

void RE4VRWeapons2::clone_destroy() {
    if (m_lh_clone) {
        re4vr::destroy_game_object((::REManagedObject*)m_lh_clone);
    }
    m_lh_clone = nullptr;
    m_lh_clone_mesh = nullptr;
    m_lh_clone_wid.reset();
    m_lh_clone_on = false;
    m_lh_part0 = false;
    m_lh_was_flying = false;
    m_lh_vis.reset();
    RE4VRShared::get()->re4_knife_lh_clone_go = nullptr;
    RE4VRShared::get()->re4_knife_left_clone = false;
}

void RE4VRWeapons2::lh_play_sound(uint32_t id) {
    if (id == 0) {
        return;
    }
    auto* tf = re4vr::body_transform();
    if (!tf) {
        return;
    }
    auto* c = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(tf, "get_Child"); }).value_or(nullptr);
    int guard = 0;
    while (c && guard++ < 256) {
        auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(c, "get_GameObject"); }).value_or(nullptr);
        auto nm = go ? re4vr::go_name((::REManagedObject*)go) : std::string{};
        int wid = 0;
        if (nm.size() > 2 && nm[0] == 'w' && nm[1] == 'p') {
            wid = std::atoi(nm.c_str() + 2);
        }
        if (wid && RE4VRWeapons::get()->is_knife_id(wid)) {
            if (auto* scn = re4vr::get_component((::REManagedObject*)go, "soundlib.SoundContainer")) {
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(scn, "trigger(System.UInt32)", id); });
                return;
            }
        }
        c = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(c, "get_Next"); }).value_or(nullptr);
    }
}

::REManagedObject* RE4VRWeapons2::find_knife_mesh() {
    const auto want = get_selected_knife_wid();
    auto* tf = re4vr::body_transform();
    if (!tf) {
        return nullptr;
    }
    ::REManagedObject* want_mesh = nullptr;
    ::REManagedObject* any_mesh = nullptr;
    int32_t want_id = 0, any_id = 0;
    std::function<void(::RETransform*, int)> walk;
    walk = [&](::RETransform* t, int depth) {
        if (!t || depth > 12 || want_mesh) {
            return;
        }
        auto* child = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(t, "get_Child"); }).value_or(nullptr);
        int guard = 0;
        while (child && guard++ < 400 && !want_mesh) {
            auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(child, "get_GameObject"); }).value_or(nullptr);
            auto nm = go ? re4vr::go_name((::REManagedObject*)go) : std::string{};
            int id = 0;
            if (nm.size() > 2 && nm[0] == 'w' && nm[1] == 'p') {
                id = std::atoi(nm.c_str() + 2);
            }
            if (id && RE4VRWeapons::get()->is_knife_id(id)) {
                if (auto* mesh = re4vr::get_component((::REManagedObject*)go, "via.render.Mesh")) {
                    if (want && id == *want) {
                        want_mesh = mesh;
                        want_id = id;
                        return;
                    }
                    if (!any_mesh) {
                        any_mesh = mesh;
                        any_id = id;
                    }
                }
            }
            walk(child, depth + 1);
            child = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(child, "get_Next"); }).value_or(nullptr);
        }
    };
    walk(tf, 0);
    if (want_mesh) {
        m_current_knife_wid = want_id;
        m_lh_clone_wid = want_id;
        return want_mesh;
    }
    if (any_mesh) {
        m_current_knife_wid = any_id;
        m_lh_clone_wid = any_id;
    }
    return any_mesh;
}

void RE4VRWeapons2::clone_spawn() {
    auto* gmesh = find_knife_mesh();
    if (!gmesh) {
        return;
    }
    auto* holder = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(gmesh, "getMesh"); }).value_or(nullptr);
    if (!holder) {
        return;
    }
    auto* gmat = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(gmesh, "get_Material"); }).value_or(nullptr);
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
    if (gmat) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "set_Material", gmat); });
    }
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
    m_lh_clone_mesh = mesh;
    m_lh_part0 = false;
    m_lh_vis.reset();
    RE4VRShared::get()->re4_knife_lh_clone_go = (::REManagedObject*)go;
    RE4VRShared::get()->re4_knife_left_clone = true;
    m_lh_clone_on = true;
}

void RE4VRWeapons2::clone_isolate_part0() {
    if (!m_lh_clone_mesh || m_lh_part0) {
        return;
    }
    auto ready = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_lh_clone_mesh, "get_MeshReady"); });
    if (ready != true) {
        return;
    }
    for (int i = 0; i < 64; ++i) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_lh_clone_mesh, "setPartsEnable", i, i == 0); });
    }
    m_lh_part0 = true;
}

void RE4VRWeapons2::clone_reparent() {
    if (!m_lh_clone) {
        return;
    }
    auto* ctf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(m_lh_clone, "get_Transform"); }).value_or(nullptr);
    auto* btf = re4vr::body_transform();
    if (ctf && btf) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(ctf, "set_Parent", btf); });
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(ctf, "set_ParentJoint", sdk::VM::create_managed_string(L"L_Hand")); });
    }
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
    const auto wid = m_lh_clone_wid ? m_lh_clone_wid : m_current_knife_wid;
    if (wid) {
        auto k = std::to_string(*wid);
        if (auto f = m_lh_off.find(k); f != m_lh_off.end()) {
            o = f->second;
        }
    }
    float px = o.x, py = o.y, pz = o.z;
    const float target = RE4VRShared::get()->vr_knife_flip ? 1.0f : 0.0f;
    if (m_lh_flip_prev != target) {
        m_lh_flip_prev = target;
        lh_play_sound(1007228839u);
    }
    const float spd = m_lh_flip_speed > 0 ? m_lh_flip_speed : 0.5f;
    if (m_lh_flip_lerp < target) {
        m_lh_flip_lerp = std::min(target, m_lh_flip_lerp + spd);
    } else if (m_lh_flip_lerp > target) {
        m_lh_flip_lerp = std::max(target, m_lh_flip_lerp - spd);
    }
    auto rot = re4vr::quat_euler_yxz_deg(o.rx, o.ry, o.rz);
    if (m_lh_flip_lerp > 0.0001f) {
        rot = glm::normalize(rot * re4vr::quat_euler_yxz_deg(180.0f * m_lh_flip_lerp, 0, 0));
        if (wid) {
            auto k = std::to_string(*wid);
            if (auto fp = m_lh_flip.find(k); fp != m_lh_flip.end()) {
                px += fp->second.x * m_lh_flip_lerp;
                py += fp->second.y * m_lh_flip_lerp;
                pz += fp->second.z * m_lh_flip_lerp;
            }
        }
    }
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(tf, "set_LocalPosition", Vector3f{px, py, pz}); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(tf, "set_LocalRotation", rot); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(tf, "set_LocalScale", Vector3f{1, 1, 1}); });
}

void RE4VRWeapons2::apply_left_knife_pose(::REManagedObject* go) {
    if (go) {
        m_lh_clone = (::REGameObject*)go;
    }
    clone_apply_pose();
}

void RE4VRWeapons2::clone_manage() {
    if (RE4VRShared::get()->re4_knife_left_clone != true) {
        if (m_lh_clone) {
            clone_destroy();
        }
        return;
    }
    if (RE4VRShared::get()->re4_holster_killswitch || RE4VRShared::get()->re4_ks4_active) {
        if (m_lh_clone) {
            clone_destroy();
        }
        return;
    }
    if (m_lh_clone && re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_lh_clone, "get_Valid"); }).value_or(true) == false) {
        clone_destroy();
    }
    if (m_lh_clone && m_lh_clone_wid) {
        auto sel = get_selected_knife_wid();
        if (sel && *sel != *m_lh_clone_wid) {
            clone_destroy();
        }
    }
    if (!m_lh_clone) {
        clone_spawn();
    }
    if (!m_lh_clone) {
        return;
    }
    clone_isolate_part0();
    if (m_lh_clone_mesh) {
        const bool want = !RE4VRShared::get()->re4_knife_equipped;
        if (!m_lh_vis || *m_lh_vis != want) {
            m_lh_vis = want;
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_lh_clone_mesh, "set_DrawDefault", want); });
        }
    }
    if (RE4VRShared::get()->re4_knife_flying) {
        m_lh_was_flying = true;
    } else {
        if (m_lh_was_flying) {
            m_lh_was_flying = false;
            clone_reparent();
        }
        clone_apply_pose();
    }
    RE4VRShared::get()->re4_knife_left_clone = true;
    if (m_lh_clone_wid) {
        RE4VRShared::get()->re4_current_knife_wid = *m_lh_clone_wid;
    } else if (m_current_knife_wid) {
        RE4VRShared::get()->re4_current_knife_wid = *m_current_knife_wid;
    }
}

void RE4VRWeapons2::left_knife_tick() {
    if (RE4VRShared::get()->re4_holster_killswitch || RE4VRShared::get()->re4_ks4_active) {
        if (m_lh_clone) {
            clone_destroy();
        }
        m_prev_lgrip = re4vr::grip_held(true);
        m_armed = false;
        return;
    }
    const bool in_zone = RE4VRShared::get()->re4_knife_lh_in_zone;
    const bool lgrip = re4vr::grip_held(true);
    if (lgrip && !m_prev_lgrip) {
        m_armed = in_zone;
    } else if (m_prev_lgrip && !lgrip) {
        if (m_armed && in_zone) {
            const bool in_clone = RE4VRShared::get()->re4_knife_left_clone;
            const bool equipped = RE4VRShared::get()->re4_knife_equipped;
            if (in_clone) {
                RE4VRShared::get()->re4_knife_left_clone = false;
                clone_destroy();
                {
                    auto& vr = VR::get();
                    vr->trigger_haptic_vibration(0.0f, 0.16f, 80.0f, 1.0f, vr->get_left_joystick());
                }
                RE4VRHolster::get()->play_grab_sound();
            } else if (!equipped) {
                RE4VRShared::get()->re4_knife_left_clone = true;
                auto* ctx = re4vr::player_context();
                auto* hu = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_HeadUpdater"); }).value_or(nullptr) : nullptr;
                const bool gun = hu && re4vr::safe([&] { return sdk::call_object_func_easy<bool>(hu, "get_IsEquipGun"); }).value_or(false);
                RE4VRShared::get()->re4_clone_no_autogun = !gun;
                {
                    auto& vr = VR::get();
                    vr->trigger_haptic_vibration(0.0f, 0.16f, 80.0f, 1.0f, vr->get_left_joystick());
                }
                RE4VRHolster::get()->play_grab_sound();
            }
        }
        m_armed = false;
    }
    m_prev_lgrip = lgrip;

    if (RE4VRShared::get()->re4_knife_left_clone && !RE4VRShared::get()->re4_knife_flying && VR::get()->is_hmd_active()) {
        auto& ctrls = VR::get()->get_controllers();
        if (!ctrls.empty()) {
            const auto wp = re4vr::v3(VR::get()->get_position(ctrls[0]));
            const double now = re4vr::now();
            const float dt = (float)(now - m_lh_swing_t);
            float spd = 0;
            if (m_prev_lh && dt > 0.001f && dt < 0.2f) {
                const auto d = wp - *m_prev_lh;
                const float horiz = std::sqrt(d.x * d.x + d.z * d.z);
                if (!(d.y > 0 && d.y > horiz)) {
                    spd = glm::length(d) / dt;
                }
            }
            m_prev_lh = wp;
            m_lh_swing_t = now;
            const bool finisher = RE4VRShared::get()->vr_knife_flip && prompt_visible();
            const bool gates = !finisher && !in_zone && !RE4VRShared::get()->re4_knife_throw_gripping;
            if (gates && spd >= m_lh_swing_speed && (now - m_last_lh_hit) > 0.30) {
                m_last_lh_hit = now;
                auto pos = RE4VRShared::get()->vr_lh_world;
                if (pos) {
                    direct_damage(*pos, 1.8f);
                }
                lh_play_sound(238304172u);
            }
        }
    } else {
        m_prev_lh.reset();
    }
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

bool RE4VRWeapons2::knife_lh_off(int32_t wid, Vector3f& pos, Vector3f& euler) const {
    auto it = m_lh_off.find(std::to_string(wid));
    if (it == m_lh_off.end()) {
        return false;
    }
    pos = Vector3f{it->second.x, it->second.y, it->second.z};
    euler = Vector3f{it->second.rx, it->second.ry, it->second.rz};
    return true;
}

bool RE4VRWeapons2::knife_lh_flip_pos(int32_t wid, Vector3f& pos) const {
    auto it = m_lh_flip.find(std::to_string(wid));
    if (it == m_lh_flip.end()) {
        return false;
    }
    pos = Vector3f{it->second.x, it->second.y, it->second.z};
    return true;
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
void RE4VRWeapons2::knife_di_guard() {
    const double now = re4vr::now();
    if (now < m_di_next) {
        return;
    }
    m_di_next = now + 0.25;
    auto* pb = re4vr::body_game_object();
    if (!pb) {
        return;
    }
    const auto a = (uintptr_t)pb;
    if (m_di_body == 0) {
        m_di_body = a;
        return;
    }
    if (a == m_di_body) {
        return;
    }
    m_di_body = a;
    drop_di_caches();
}
void RE4VRWeapons2::exec_native_melee() {
    RE4VRWeapons::get()->do_knife_melee();
}
void RE4VRWeapons2::native_hit(::REManagedObject* victim_hc, const Vector3f& pos) {
    if (!victim_hc) {
        return;
    }
    direct_damage(pos, 1.2f);
}
bool RE4VRWeapons2::direct_damage(const Vector3f& pos, float reach) {
    auto* cm = re4vr::character_manager();
    auto* hm = sdk::get_managed_singleton<::REManagedObject>("chainsaw.HitManager");
    auto* pb = re4vr::body_game_object();
    if (!cm || !hm || !pb) {
        return false;
    }
    auto* atkhc = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(hm, "getHitController", pb); }).value_or(nullptr);
    if (!atkhc) {
        return false;
    }
    auto* list = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(cm, "get_EnemyContextList"); }).value_or(nullptr);
    const int n = list ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(list, "get_Count"); }).value_or(0) : 0;
    ::REManagedObject* best_hc = nullptr;
    ::REGameObject* best_body = nullptr;
    Vector3f best_pos{};
    float best_d2 = reach * reach;
    const float box = 1.30f;
    for (int i = 0; i < n; ++i) {
        auto* e = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(list, "get_Item", i); }).value_or(nullptr);
        auto* body = e ? re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(e, "get_BodyGameObject"); }).value_or(nullptr) : nullptr;
        auto* tf = body ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(body, "get_Transform"); }).value_or(nullptr) : nullptr;
        if (!tf) {
            continue;
        }
        const auto p = re4vr::v3(sdk::get_transform_position(tf));
        auto* hc = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(hm, "getHitController", body); }).value_or(nullptr);
        const auto hp = hc ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(hc, "get_CurrentHitPoint"); }).value_or(0) : 0;
        if (!hc || hp <= 0) {
            continue;
        }
        const float ylo = p.y, yhi = p.y + 1.9f;
        float dy = 0;
        if (pos.y < ylo) {
            dy = ylo - pos.y;
        } else if (pos.y > yhi) {
            dy = pos.y - yhi;
        }
        const float dx = std::abs(p.x - pos.x), dz = std::abs(p.z - pos.z);
        const float edge = std::max(dx, dz) / box;
        const float d2 = edge * edge + dy * dy;
        if (d2 < best_d2) {
            best_d2 = d2;
            best_hc = hc;
            best_body = body;
            best_pos = p;
        }
    }
    if (!best_hc || !best_body) {
        return false;
    }
    const auto hp0 = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(best_hc, "get_CurrentHitPoint"); }).value_or(0);
    if (hp0 <= 0) {
        return false;
    }
    if (re4vr::safe([&] { return sdk::call_object_func_easy<bool>(best_hc, "get_Valid"); }).value_or(true) == false) {
        return false;
    }
    if (re4vr::safe([&] { return sdk::call_object_func_easy<bool>(best_hc, "get_IsLive"); }).value_or(true) == false) {
        return false;
    }
    const float R = 0.15f, ymin = 0.20f, ymax = 1.80f;
    float y = pos.y;
    y = std::clamp(y, best_pos.y + ymin, best_pos.y + ymax);
    float dx = pos.x - best_pos.x, dz = pos.z - best_pos.z;
    const float d = std::sqrt(dx * dx + dz * dz);
    if (d > R && d > 0.0001f) {
        dx *= R / d;
        dz *= R / d;
    }
    const Vector3f cpos{best_pos.x + dx, y, best_pos.z + dz};
    if (!m_native_di) {
        auto* td = sdk::find_type_definition("chainsaw.HitController.DamageInfo");
        m_native_di = td ? td->create_instance_full(true) : nullptr;
        if (m_native_di) {
            re4vr::pcall([&] { utility::re_managed_object::add_ref(m_native_di); });
        }
    }
    if (!m_native_di) {
        return false;
    }
    auto* base = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(best_hc, "get_DamageCalcInfo"); }).value_or(nullptr);
    if (base) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_native_di, "copy", base); });
    }
    const int32_t wid = (int32_t)RE4VRShared::get()->re4_current_knife_wid.value_or(5006);
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_native_di, "set_Damage", 225); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_native_di, "set_Wince", 64.0f); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_native_di, "set_Break", 1.0f); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_native_di, "set_Stopping", 1.0f); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_native_di, "set_IsCritical", false); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_native_di, "set_IsKill", false); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_native_di, "set_AttackOwnerObject", pb); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_native_di, "set_WeaponID", wid); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_native_di, "set_AttackGameObject", pb); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_native_di, "set_DamageGameObject", best_body); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_native_di, "set_Position", cpos); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_native_di, "set_IsActive", true); });
    if (auto* khc = RE4VRWeapons::get()->find_knife_hc()) {
        auto* kgo = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(khc, "get_GameObject"); }).value_or(nullptr);
        if (kgo) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_native_di, "set_AttackGameObject", kgo); });
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_native_di, "set_WeaponGameObject", kgo); });
        }
        if (auto* atk = RE4VRWeapons::get()->knife_get_attack_ud(khc)) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_native_di, "set_AttackUserData", atk); });
            auto* ad = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(khc, "getAttackData(chainsaw.collision.AttackUserData)", atk); }).value_or(nullptr);
            if (ad) {
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_native_di, "set_AttackData", ad); });
            }
        }
    }
    re4vr::pcall([&] {
        sdk::call_object_func_easy<void*>(hm, "calcInfo(chainsaw.HitController.DamageInfo, chainsaw.HitController, chainsaw.HitController)", m_native_di, atkhc, best_hc);
    });
    re4vr::pcall([&] {
        sdk::call_object_func_easy<void*>(hm, "hitSetting(chainsaw.HitController.DamageInfo, chainsaw.HitController, chainsaw.HitController)", m_native_di, atkhc, best_hc);
    });
    const auto hp1 = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(best_hc, "get_CurrentHitPoint"); }).value_or(hp0);
    if (hp1 < hp0) {
        lh_play_sound(238304172u);
        RE4VRShared::get()->re4_knife_last_target = best_hc;
        return true;
    }
    return false;
}
std::optional<int32_t> RE4VRWeapons2::get_selected_knife_wid() {
    if (auto cur = RE4VRShared::get()->re4_current_knife_wid) {
        if (RE4VRWeapons::get()->is_knife_id((int32_t)*cur)) {
            return (int32_t)*cur;
        }
    }
    auto* ctx = re4vr::player_context();
    auto* arr = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_MountWeaponIDs"); }).value_or(nullptr) : nullptr;
    const int n = arr ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(arr, "get_Length"); }).value_or(0) : 0;
    for (int i = 0; i < n; ++i) {
        auto w = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(arr, "get_Item", i); });
        if (w && RE4VRWeapons::get()->is_knife_id(*w)) {
            return *w;
        }
        auto* o = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(arr, "get_Item", i); }).value_or(nullptr);
        if (o) {
            auto v = re4vr::safe([&] { return utility::re_managed_object::get_field<int32_t>(o, "value__"); });
            if (v && RE4VRWeapons::get()->is_knife_id(*v)) {
                return *v;
            }
        }
    }
    return m_current_knife_wid;
}

void RE4VRWeapons2::parry_keep_gun_tick() {
    auto* ctx = re4vr::player_context();
    auto* hu = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_HeadUpdater"); }).value_or(nullptr) : nullptr;
    if (!hu) {
        return;
    }
    int32_t wn = -1;
    auto n = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(hu, "get_EquipWeaponID"); });
    if (n) {
        wn = *n;
    } else if (auto* o = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(hu, "get_EquipWeaponID"); }).value_or(nullptr)) {
        wn = re4vr::safe([&] { return utility::re_managed_object::get_field<int32_t>(o, "value__"); }).value_or(-1);
    }
    if (wn > 0 && !RE4VRWeapons::get()->is_knife_id(wn)) {
        RE4VRShared::get()->re4_parry_last_gun_wid = wn;
    }
    auto ku = RE4VRShared::get()->re4_parry_keep_gun_until;
    if (!ku) {
        return;
    }
    const double now = re4vr::now();
    const double kf = RE4VRShared::get()->re4_parry_keep_gun_from.value_or(0);
    const bool stable = (now >= kf) && !RE4VRShared::get()->re4_knife_equipped && wn <= 0;
    if (!stable && now < *ku) {
        return;
    }
    RE4VRShared::get()->re4_parry_keep_gun_until.reset();
    RE4VRShared::get()->re4_parry_keep_gun_from.reset();
    if (RE4VRShared::get()->re4_knife_equipped || wn > 0) {
        return;
    }
    if (!RE4VRShared::get()->re4_parry_last_gun_wid) {
        return;
    }
    auto* eq = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(hu, "get_Equipment"); }).value_or(nullptr);
    if (eq) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(eq, "requestEquipGun"); });
    }
}

HookManager::PreHookResult RE4VRWeapons2::pre_request_action(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    if (RE4VRShared::get()->re4_knife_parry_fresh_until.value_or(0) < re4vr::now()) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    if (args.size() > 1 && args[1]) {
        auto* self = (::REManagedObject*)args[1];
        auto* info = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(self, "get_ParryInfo"); }).value_or(nullptr);
        if (info && re4vr::safe([&] { return sdk::call_object_func_easy<bool>(info, "get_IsEnable"); }).value_or(false)) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(info, "set_RequestAction", true); });
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(info, "set_RequestReserve", true); });
            if (RE4VRShared::get()->re4_knife_left_clone) {
                const double now = re4vr::now();
                RE4VRShared::get()->re4_parry_keep_gun_until = now + 2.0;
                RE4VRShared::get()->re4_parry_keep_gun_from = now + 0.30;
            }
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
    knife_di_guard();
    parry_tick();
    lh_char_tick();
    left_knife_tick();
    parry_keep_gun_tick();
    wildwest_tick();
    blood_tick();
    RE4VRShared::get()->refresh_unlimited();
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
