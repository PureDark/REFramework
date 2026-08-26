#define NOMINMAX
#include "RE4VRWeapons2.hpp"

#if defined(RE4)
#include <algorithm>
#include <cmath>
#include <cstdlib>

#include <glm/gtc/quaternion.hpp>
#include <glm/gtx/norm.hpp>
#include <glm/gtx/quaternion.hpp>
#include <sdk/MurmurHash.hpp>
#include <sdk/RETypeDB.hpp>
#include <spdlog/spdlog.h>

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
    return re4vr::lua_call_bool("__re4_is_finisher_prompt", false);
}
bool RE4VRWeapons2::reverse_grip() {
    return re4vr::lua_is_true("__vr_knife_flip");
}
bool RE4VRWeapons2::knife_out() {
    return re4vr::lua_is_true("__re4_knife_equipped") || re4vr::lua_is_true("__re4_knife_left_clone");
}

void RE4VRWeapons2::parry_tick() {
    if (re4vr::lua_is_true("__re4_ks_active")) {
        return;
    }
    const double now = re4vr::now();
    re4vr::lua_set_bool("__re4_knife_finisher_shake", now < m_parry_until);
    bool pose = false;
    if (knife_out() && !re4vr::lua_is_true("__re4_knife_flying") && VR::get()->is_hmd_active()) {
        const bool left = re4vr::lua_string("__re4_knife_hand").value_or("") == "left" || re4vr::lua_is_true("__re4_knife_left_clone");
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
    re4vr::lua_set_bool("__re4_knife_parry_pose", pose);
    if (pose && !m_parry_was) {
        re4vr::lua_set_number("__re4_knife_parry_fresh_until", now + 0.50);
    }
    m_parry_was = pose;
    if (!(knife_out() && reverse_grip() && prompt_visible())) {
        return;
    }
    auto& ctrls = VR::get()->get_controllers();
    const bool left = re4vr::lua_string("__re4_knife_hand").value_or("") == "left" || re4vr::lua_is_true("__re4_knife_left_clone");
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
    re4vr::lua_set_string("__re4_char_now", want);
    load_json();
}

void RE4VRWeapons2::clone_destroy() {
    if (m_lh_clone) {
        re4vr::destroy_game_object((::REManagedObject*)m_lh_clone);
    }
    m_lh_clone = nullptr;
    m_lh_clone_on = false;
    re4vr::lua_set_nil("__re4_knife_lh_clone_go");
    re4vr::lua_set_bool("__re4_knife_left_clone", false);
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
    re4vr::lua_set_object("__re4_knife_lh_clone_go", (::REManagedObject*)go);
    re4vr::lua_set_bool("__re4_knife_left_clone", true);
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
        auto it = re4vr::lua_is_true("__vr_knife_flip") ? m_lh_flip.find(k) : m_lh_off.find(k);
        auto& map = re4vr::lua_is_true("__vr_knife_flip") ? m_lh_flip : m_lh_off;
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
    const bool want = re4vr::lua_is_true("__re4_knife_left_intent") && m_lh_enabled;
    if (want && !m_lh_clone) {
        clone_spawn();
    } else if (!want && m_lh_clone) {
        clone_destroy();
    }
    if (m_lh_clone) {
        clone_apply_pose();
        re4vr::lua_set_bool("__re4_knife_left_clone", true);
        if (m_current_knife_wid) {
            re4vr::lua_set_number("__re4_current_knife_wid", *m_current_knife_wid);
        }
    }
}

void RE4VRWeapons2::left_knife_tick() {
    const bool hz = re4vr::lua_is_true("__re4_knife_lh_in_zone");
    const bool grip = re4vr::grip_held(true);
    static bool was_grip = false;
    if (hz && grip && !was_grip) {
        const bool out = knife_out() || m_lh_clone;
        if (out && (re4vr::lua_is_true("__re4_knife_left_clone") || re4vr::lua_string("__re4_knife_hand").value_or("") == "left")) {
            re4vr::lua_set_bool("__re4_knife_left_intent", false);
            RE4VRHolster::get()->set_suppress(true);
            RE4VRHolster::get()->holster_bare();
        } else if (!re4vr::lua_is_true("__re4_knife_equipped")) {
            re4vr::lua_set_bool("__re4_knife_left_intent", true);
            re4vr::lua_set_number("__re4_knife_draw_ours_t", re4vr::now());
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

void RE4VRWeapons2::wildwest_tick() {
    re4vr::lua_pcall_name("__re4_wildwest_apply");
}
void RE4VRWeapons2::blood_tick() {
    re4vr::lua_set_bool("__re4_knife_blood_on", m_blood_on);
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
    if (!re4vr::lua_is_true("__re4_knife_parry_pose")) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    if (re4vr::lua_number("__re4_knife_parry_fresh_until").value_or(0) < re4vr::now()) {
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
    re4vr::lua_pcall_name("__re4_equipweapon_cb");
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
