#define NOMINMAX
#include "RE4VRWeapons.hpp"

#if defined(RE4)
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <functional>

#include <glm/gtc/quaternion.hpp>
#include <glm/gtx/norm.hpp>
#include <glm/gtx/quaternion.hpp>
#include <imgui.h>
#include <sdk/MotionFsm2Layer.hpp>
#include <sdk/MurmurHash.hpp>
#include <sdk/REString.hpp>
#include <sdk/RETransform.hpp>
#include <sdk/RETypeDB.hpp>
#include <sdk/SceneManager.hpp>
#include <spdlog/spdlog.h>
#include <utility/String.hpp>

#include "RE4VRCrosshair.hpp"
#include "RE4VRFrameCache.hpp"
#include "RE4VRHolster.hpp"
#include "RE4VRMenu.hpp"
#include "RE4VRShared.hpp"
#include "RE4VRWeapons2.hpp"
#include "RE4VRWhitelist.hpp"
#include "../../../ScriptRunner.hpp"

namespace {
void walk_children(::RETransform* t, const std::function<void(::REGameObject*, ::RETransform*)>& fn, int nmax = 64) {
    auto* c = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(t, "get_Child"); }).value_or(nullptr);
    int n = 0;
    while (c && n < nmax) {
        ++n;
        auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(c, "get_GameObject"); }).value_or(nullptr);
        fn(go, c);
        c = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(c, "get_Next"); }).value_or(nullptr);
    }
}

int32_t wid_of(::REManagedObject* o) {
    if (!o) {
        return 0;
    }
    auto n = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(o, "ToInt32"); });
    if (n) {
        return *n;
    }
    return re4vr::safe([&] { return utility::re_managed_object::get_field<int32_t>(o, "value__"); }).value_or(0);
}

::REManagedObject* fsm_node_name(::REManagedObject* go, int layer) {
    auto* fsm = re4vr::get_component((::REManagedObject*)go, "via.motion.MotionFsm2");
    if (!fsm) {
        return nullptr;
    }
    return re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(fsm, "getCurrentNodeName", layer); }).value_or(nullptr);
}
}

std::shared_ptr<RE4VRWeapons>& RE4VRWeapons::get() {
    static auto inst = std::make_shared<RE4VRWeapons>();
    return inst;
}

bool RE4VRWeapons::is_knife_id(int32_t id) const {
    return m_knife_ids.contains(id);
}
bool RE4VRWeapons::is_scope_weapon(int32_t id) const {
    return m_scope_weps.contains(id);
}

::REManagedObject* RE4VRWeapons::get_player_ctx() {
    auto& fc = RE4VRFrameCache::get();
    if (fc->on()) {
        return fc->ctx();
    }
    return re4vr::player_context();
}

std::optional<int32_t> RE4VRWeapons::get_equip_weapon_id() {
    auto& fc = RE4VRFrameCache::get();
    if (fc->on()) {
        return fc->equip_wid();
    }
    auto* ctx = get_player_ctx();
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
        return wid_of(o);
    }
    return std::nullopt;
}

bool RE4VRWeapons::is_knife_equipped() {
    auto w = get_equip_weapon_id();
    return w && m_knife_ids.contains(*w);
}
bool RE4VRWeapons::is_grenade_equipped() {
    auto w = get_equip_weapon_id();
    return w && m_grenade_ids.contains(*w);
}
bool RE4VRWeapons::is_right_grip_held() {
    return re4vr::grip_held(false);
}

void RE4VRWeapons::load_json() {
    auto hb = re4vr::load_json_file("re4_vr/re4_vr_hide_body.json");
    m_hide_body = re4vr::j_bool(hb, "enabled", true);
    m_scope_proto.data = re4vr::load_json_file("re4_vr/re4_vr_scope_proto.json");
    m_scope_proto.enabled = re4vr::j_bool(m_scope_proto.data, "enabled", false);
    m_snappy.data = re4vr::load_json_file("re4_vr/re4_vr_snappy.json");
    m_snappy.enabled = re4vr::j_bool(m_snappy.data, "enabled", true);
    auto th = re4vr::load_json_file("re4_vr/re4_vr_throw.json");
    if (!th.empty()) {
        m_throw.enabled = re4vr::j_bool(th, "enabled", true);
        m_throw.vmin = re4vr::j_num(th, "vmin", m_throw.vmin);
        m_throw.vmax = re4vr::j_num(th, "vmax", m_throw.vmax);
        m_throw.gravity = re4vr::j_num(th, "gravity", m_throw.gravity);
        m_throw.extra = th;
    }
}

void RE4VRWeapons::save_hide_body() {
    re4vr::save_json_file("re4_vr/re4_vr_hide_body.json", {{"enabled", m_hide_body}});
}

void RE4VRWeapons::register_ui() {
    if (m_ui_registered) {
        return;
    }
    m_ui_registered = true;
    RE4VRMenu::get()->add(60, "assist_light", [this]() {
        bool v = m_disable_assist_light;
        if (ImGui::Checkbox("Disable Assist Light", &v)) {
            m_disable_assist_light = v;
        }
    });
}

std::optional<std::string> RE4VRWeapons::on_initialize() {
    load_json();
    if (auto* td = sdk::find_type_definition("chainsaw.PlayerEquipment")) {
        if (auto* m = td->get_method("requestChangeWeaponAction")) {
            g_hookman.add(m, &RE4VRWeapons::pre_change_weapon, &RE4VRWeapons::post_nop);
        }
        for (auto& m : td->get_methods()) {
            const auto n = std::string{m.get_name()};
            if (n == "requestEquipKnife") {
                g_hookman.add(&m, &RE4VRWeapons::pre_request_equip_knife, &RE4VRWeapons::post_nop);
            } else if (n == "equipWeapon") {
                g_hookman.add(&m, &RE4VRWeapons::pre_equip_weapon, &RE4VRWeapons::post_nop);
            } else if (n == "requestChangeActiveWeapon") {
                g_hookman.add(&m, &RE4VRWeapons::pre_change_active, &RE4VRWeapons::post_nop);
            }
        }
    }
    if (auto* td = sdk::find_type_definition("chainsaw.HitController")) {
        if (auto* m = td->get_method("poolDamage")) {
            g_hookman.add(m, &RE4VRWeapons::pre_pool_damage, &RE4VRWeapons::post_nop);
        }
        if (auto* m = td->get_method("callbackAttackHit")) {
            g_hookman.add(m, &RE4VRWeapons::pre_attack_hit, &RE4VRWeapons::post_nop);
        }
        if (auto* m = td->get_method("callbackCalculateDamage")) {
            g_hookman.add(m, &RE4VRWeapons::pre_calc_damage, &RE4VRWeapons::post_nop);
        }
    }
    if (auto* td = sdk::find_type_definition("chainsaw.ThrowingGrenadeGenerator")) {
        if (auto* m = td->get_method("requestFire(via.vec3, via.Quaternion)")) {
            g_hookman.add(m, &RE4VRWeapons::pre_gun_object, &RE4VRWeapons::post_nop);
        }
    }
    register_ui();
    RE4VRShared::get()->re4_knife_change_block_hooked = true;
    RE4VRShared::get()->re4_quickknife_hooked = true;
    RE4VRShared::get()->re4_qk_block = true;
    RE4VRShared::get()->re4_stow_guard_hooked = true;
    RE4VRShared::get()->re4_stow_block = true;
    return std::nullopt;
}

void RE4VRWeapons::export_globals(sol::state& lua) {
    lua["__re4_do_knife_melee"] = [this]() { do_knife_melee(); };
    lua["__re4_find_knife_hc"] = [this]() { return find_knife_hc(); };
    lua["__re4_knife_get_attack_ud"] = [this](::REManagedObject* hc) { return knife_get_attack_ud(hc); };
    lua["__re4_knife_hand_world"] = [this]() -> sol::object {
        re4vr::LuaGuard g;
        auto* L = g.lua();
        if (!L) {
            return sol::nil;
        }
        auto p = knife_hand_world();
        return p ? sol::make_object(*L, *p) : sol::object(sol::nil);
    };
    lua["__re4_knife_grip_held"] = [this]() {
        const bool left = RE4VRShared::get()->re4_knife_hand.value_or("") == "left" || RE4VRShared::get()->re4_knife_left_clone;
        return re4vr::grip_held(left);
    };
    lua["__re4_throw_override"] = [](sol::variadic_args) {};
    if (!lua["__re4_knife_snd"].valid() || lua["__re4_knife_snd"].get_type() == sol::type::nil) {
        auto t = lua.create_table();
        t["swing"] = 1800445513;
        t["throw"] = 3788596668;
        t["hit"] = 686504397;
        t["floor"] = 643584649;
        lua["__re4_knife_snd"] = t;
    }
    if (!lua["__re4_knife_fly_cfg"].valid() || lua["__re4_knife_fly_cfg"].get_type() == sol::type::nil) {
        auto t = lua.create_table();
        t["speed"] = 12.0;
        t["gravity"] = 7.0;
        t["spin"] = 12.0;
        t["max_time"] = 1.5;
        t["return_delay"] = 0.4;
        t["hit_radius"] = 0.5;
        t["break_radius"] = 0.9;
        t["v_min"] = 4.0;
        t["v_max"] = 14.0;
        t["spin_fly"] = 5.0;
        t["spin_fall"] = 22.0;
        t["arm_clear"] = 0.7;
        t["close_hit_radius"] = 0.5;
        t["spin_ax"] = 1.0;
        t["spin_ay"] = 0.0;
        t["spin_az"] = 0.0;
        t["spin_ax_l"] = 1.0;
        t["spin_ay_l"] = 0.0;
        t["spin_az_l"] = 0.0;
        t["dir_max_deg"] = 90;
        t["hmd_force"] = false;
        t["assist_cone_deg"] = 20.0;
        t["assist_homing"] = 0.05;
        t["assist_strength"] = 0.0;
        lua["__re4_knife_fly_cfg"] = t;
    }
    if (lua["__re4_knife_reach"].get_type() != sol::type::number) {
        lua["__re4_knife_reach"] = 1.6;
    }
    if (lua["__re4_knife_dmg_override"].get_type() != sol::type::number) {
        lua["__re4_knife_dmg_override"] = 150;
    }
    if (lua["__re4_knife_wince_override"].get_type() != sol::type::number) {
        lua["__re4_knife_wince_override"] = 90.0;
    }
}

void RE4VRWeapons::on_lua_state_created(sol::state& lua) {
    export_globals(lua);
    register_ui();
}
void RE4VRWeapons::on_lua_state_destroyed(sol::state&) {
    m_fly = {};
}

void RE4VRWeapons::hide_body_weapons_tick() {
    if (!m_hide_body) {
        return;
    }
    auto* ctx = get_player_ctx();
    auto* body = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(ctx, "get_BodyGameObject"); }).value_or(nullptr) : nullptr;
    auto* tf = body ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(body, "get_Transform"); }).value_or(nullptr) : nullptr;
    if (!tf) {
        return;
    }
    auto cur_wid = get_equip_weapon_id();
    std::string cur;
    if (cur_wid) {
        char buf[16];
        std::snprintf(buf, sizeof(buf), "wp%04d", *cur_wid);
        cur = buf;
    }
    bool plain_exists = false;
    if (!cur.empty()) {
        walk_children(tf, [&](::REGameObject* go, ::RETransform*) {
            if (go && re4vr::go_name((::REManagedObject*)go) == cur) {
                plain_exists = true;
            }
        });
    }
    walk_children(tf, [&](::REGameObject* go, ::RETransform*) {
        if (!go) {
            return;
        }
        auto name = re4vr::go_name((::REManagedObject*)go);
        if (name.size() < 2 || name[0] != 'w' || name[1] != 'p') {
            return;
        }
        const bool is_cur = !cur.empty() && (name == cur || (!plain_exists && (name == cur + "_AO" || name == cur + "_MC")));
        if (!is_cur) {
            auto vis = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(go, "get_DrawSelf"); });
            if (vis == true) {
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(go, "set_DrawSelf", false); });
            }
        }
    });
}

void RE4VRWeapons::hide_assist_light() {
    if (!m_disable_assist_light) {
        return;
    }
    auto* body = re4vr::body_game_object();
    auto* tf = body ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(body, "get_Transform"); }).value_or(nullptr) : nullptr;
    if (!tf) {
        return;
    }
    walk_children(tf, [&](::REGameObject* go, ::RETransform*) {
        if (go && re4vr::go_name((::REManagedObject*)go) == "assist_Light") {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(go, "set_DrawSelf", false); });
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(go, "set_UpdateSelf", false); });
        }
    });
}

void RE4VRWeapons::scope_killswitch_tick() {
    auto* ctx = get_player_ctx();
    auto* hu = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_HeadUpdater"); }).value_or(nullptr) : nullptr;
    auto* gun = hu ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(hu, "get_EquipWeapon"); }).value_or(nullptr) : nullptr;
    bool on = false;
    if (gun) {
        on = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(gun, "get__IsViaScope"); }).value_or(false)
            || re4vr::safe([&] { return utility::re_managed_object::get_field<bool>(gun, "_IsViaScope"); }).value_or(false);
    }
    RE4VRShared::get()->re4_scope_via_raw = on;
    auto ewid = get_equip_weapon_id();
    if (ewid && m_scope_weps.contains(*ewid)) {
        RE4VRShared::get()->re4_scope_wid = *ewid;
        m_scope_wid = *ewid;
    } else {
        RE4VRShared::get()->re4_scope_wid.reset();
        m_scope_wid.reset();
    }
    static bool via_seen = false;
    if (!RE4VRShared::get()->vr_aim_input) {
        via_seen = false;
    } else if (on) {
        via_seen = true;
    }
    if (!on && via_seen && RE4VRShared::get()->re4_fork_ok && RE4VRShared::get()->re4_scope_hold_enable
        && RE4VRShared::get()->vr_aim_input && m_scope_wid) {
        on = true;
    }
    if (ewid && m_bolt_rifles.contains(*ewid) && ctx) {
        auto* body = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(ctx, "get_BodyGameObject"); }).value_or(nullptr);
        auto* fsm = body ? re4vr::get_component((::REManagedObject*)body, "via.motion.MotionFsm2") : nullptr;
        auto* n5 = fsm ? re4vr::safe([&] { return sdk::call_object_func_easy<::SystemString*>(fsm, "getCurrentNodeName", 5); }).value_or(nullptr) : nullptr;
        if (n5) {
            auto ns = utility::re_string::get_string(n5);
            if (ns.find("Shoot") != std::string::npos) {
                RE4VRShared::get()->re4_bolt_shoot_t = re4vr::now();
                if (RE4VRShared::get()->re4_bolt_reaim && RE4VRShared::get()->vr_aim_input
                    && !RE4VRShared::get()->re4_bolt_aim_cut_t) {
                    RE4VRShared::get()->re4_bolt_aim_cut_t = re4vr::now();
                }
            }
        }
    }
    const bool iron = on && ewid && m_iron_rifles.contains(*ewid) && !RE4VRShared::get()->re4_scope_id;
    const bool scope_aim = on && !iron;
    const bool native = scope_aim && RE4VRShared::get()->re4_fork_ok && RE4VRShared::get()->re4_scope_mono_enable;
    RE4VRShared::get()->re4_scope_native = native;
    m_scope_native = native;
    bool bolt_win = false;
    if (ewid && m_bolt_rifles.contains(*ewid)) {
        auto st = RE4VRShared::get()->re4_bolt_shoot_t;
        bolt_win = st && (re4vr::now() - *st) < 0.25;
    }
    RE4VRShared::get()->re4_force_killswitch_scope = scope_aim && !bolt_win;
    RE4VRShared::get()->re4_force_killswitch_bolt = false;
    m_force_ks_scope = scope_aim && !bolt_win;
    bool bolt_cycle = false;
    bool bolt_hide_win = false;
    if (ewid && m_bolt_rifles.contains(*ewid)) {
        bolt_cycle = gun_bolt_cycle_active(*ewid);
        auto st = RE4VRShared::get()->re4_bolt_shoot_t;
        bolt_hide_win = st && (re4vr::now() - *st) < 1.10;
    }
    scope_hide_arms_tick(scope_aim && !bolt_cycle && !bolt_hide_win);
    RE4VRShared::get()->vr_unlock_ry = scope_aim;
    if (scope_aim && gun) {
        auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(gun, "get_GameObject"); }).value_or(nullptr);
        auto* gtf = go ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr) : nullptr;
        if (gtf) {
            auto rot = sdk::get_transform_rotation(gtf);
            auto f = re4vr::quat_rotate(rot, Vector3f{0, 0, 1});
            const float fy = std::clamp(f.y, -1.0f, 1.0f);
            auto st = RE4VRShared::get()->re4_bolt_shoot_t;
            const bool freeze = ewid && m_bolt_rifles.contains(*ewid) && st && (re4vr::now() - *st) < 1.6;
            if (!freeze) {
                RE4VRShared::get()->re4_scope_aim_pitch = glm::degrees(std::asin(fy));
            }
        }
    } else {
        RE4VRShared::get()->re4_scope_aim_pitch.reset();
    }
    if (on) {
        // detect_scope_id: look for scope child names
        if (gun) {
            auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(gun, "get_GameObject"); }).value_or(nullptr);
            auto* gtf = go ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr) : nullptr;
            std::optional<std::string> sid;
            if (gtf) {
                walk_children(gtf, [&](::REGameObject* cgo, ::RETransform*) {
                    if (!cgo || sid) {
                        return;
                    }
                    auto nm = re4vr::go_name((::REManagedObject*)cgo);
                    if (nm.find("scope") != std::string::npos || nm.find("Scope") != std::string::npos) {
                        sid = nm;
                    }
                });
            }
            if (sid) {
                RE4VRShared::get()->re4_scope_id = std::string{*sid};
            } else {
                RE4VRShared::get()->re4_scope_id.reset();
            }
        }
    }
    if (scope_aim && gun) {
        auto* sctrl = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(gun, "get_ScopeController"); }).value_or(nullptr);
        auto* cam = sctrl ? re4vr::safe([&] { return utility::re_managed_object::get_field<::REManagedObject*>(sctrl, "_CameraRef"); }).value_or(nullptr) : nullptr;
        auto* cgo = cam ? re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(cam, "get_GameObject"); }).value_or(nullptr) : nullptr;
        auto* ctf = cgo ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(cgo, "get_Transform"); }).value_or(nullptr) : nullptr;
        if (ctf) {
            auto cpos = re4vr::v3(sdk::get_transform_position(ctf));
            auto crot = sdk::get_transform_rotation(ctf);
            auto cf = re4vr::quat_rotate(crot, Vector3f{0, 0, -1});
            const float byaw = (float)RE4VRShared::get()->re4_scope_bullet_yaw.value_or(0);
            if (byaw != 0.0f) {
                auto up = re4vr::quat_rotate(crot, Vector3f{0, 1, 0});
                const float len = glm::length(up);
                if (len > 1e-6f) {
                    up /= len;
                    const float h = byaw * 0.5f;
                    const float s = std::sin(h);
                    const glm::quat yq{std::cos(h), up.x * s, up.y * s, up.z * s};
                    cf = re4vr::quat_rotate(yq, cf);
                }
            }
            RE4VRShared::get()->vr_scope_active = true;
            RE4VRShared::get()->vr_scope_aim_pos = cpos;
            RE4VRShared::get()->vr_scope_aim_dir = cf;
        } else {
            RE4VRShared::get()->vr_scope_active = false;
            RE4VRShared::get()->vr_scope_aim_pos.reset();
            RE4VRShared::get()->vr_scope_aim_dir.reset();
        }
    } else {
        RE4VRShared::get()->vr_scope_active = false;
        RE4VRShared::get()->vr_scope_aim_pos.reset();
        RE4VRShared::get()->vr_scope_aim_dir.reset();
    }
}

void RE4VRWeapons::keep_knife_out() {
    if (m_kko_frames > 0) {
        return;
    }
    auto* ctx = get_player_ctx();
    auto* head = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(ctx, "get_HeadGameObject"); }).value_or(nullptr) : nullptr;
    if (!head) {
        return;
    }
    auto* updater = re4vr::get_component((::REManagedObject*)head, "chainsaw.Ch0a0z0HeadUpdater");
    if (!updater) {
        updater = re4vr::get_component((::REManagedObject*)head, "chainsaw.Ch3a8z0HeadUpdater");
    }
    if (!updater) {
        return;
    }
    auto* timer = re4vr::safe([&] { return utility::re_managed_object::get_field<::REManagedObject*>(updater, "<KnifeCloseTimer>k__BackingField"); }).value_or(nullptr);
    if (!timer) {
        return;
    }
    re4vr::pcall([&] {
        auto* t = sdk::get_object_field<float>(timer, "_TransitTime");
        if (t) {
            *t = 0.0f;
        }
    });
}

::REManagedObject* RE4VRWeapons::find_knife_hc() {
    auto* hm = sdk::get_managed_singleton<::REManagedObject>("chainsaw.HitManager");
    auto* body = re4vr::body_game_object();
    auto* tf = body ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(body, "get_Transform"); }).value_or(nullptr) : nullptr;
    if (!hm || !tf) {
        return nullptr;
    }
    ::REManagedObject* found = nullptr;
    std::function<void(::RETransform*, int)> walk = [&](::RETransform* t, int depth) {
        if (!t || depth > 6 || found) {
            return;
        }
        auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(t, "get_GameObject"); }).value_or(nullptr);
        if (go) {
            auto* hc = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(hm, "getHitController", go); }).value_or(nullptr);
            if (hc) {
                auto wid = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(hc, "get_WeaponId"); });
                if (wid && m_knife_ids.contains(*wid)) {
                    found = hc;
                    return;
                }
            }
        }
        auto* c = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(t, "get_Child"); }).value_or(nullptr);
        while (c && !found) {
            walk(c, depth + 1);
            c = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(c, "get_Next"); }).value_or(nullptr);
        }
    };
    walk(tf, 0);
    return found;
}

::REManagedObject* RE4VRWeapons::knife_get_attack_ud(::REManagedObject* hc) {
    if (!hc) {
        return nullptr;
    }
    auto* arr = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(hc, "get_RequestSetAttackUserData"); }).value_or(nullptr);
    if (!arr) {
        arr = RE4VRShared::get()->re4_knife_atkUD;
        return arr;
    }
    const int n = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(arr, "get_Count"); }).value_or(0);
    if (n > 0) {
        return re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(arr, "get_Item", 0); }).value_or(nullptr);
    }
    return RE4VRShared::get()->re4_knife_atkUD;
}

void RE4VRWeapons::do_knife_melee() {
    static double last_t = 0;
    const double now = re4vr::now();
    if (now - last_t < 0.2) {
        return;
    }
    if (re4vr::call_killswitch_bool("is_active", false)) {
        return;
    }
    last_t = now;
    auto hand = knife_hand_world();
    auto* target = knife_pick_target(hand, false, (float)RE4VRShared::get()->re4_knife_reach.value_or(0.90));
    if (!target) {
        return;
    }
    RE4VRShared::get()->re4_knife_last_target = target;
    auto* hc = find_knife_hc();
    if (!hc) {
        if (hand) {
            RE4VRWeapons2::get()->native_hit(nullptr, *hand);
        }
        return;
    }
    auto* atk = knife_get_attack_ud(hc);
    if (!atk || !hand) {
        return;
    }
    auto* dmg_td = sdk::find_type_definition("chainsaw.collision.DamageUserData");
    auto* dmg = dmg_td ? dmg_td->create_instance() : nullptr;
    if (!dmg) {
        return;
    }
    RE4VRShared::get()->re4_knife_our_until = now + 0.25;
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(hc, "set_AttackEnable", true); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(hc, "requestAttack", target, atk, dmg); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(hc, "set_AttackEnable", false); });
}

std::optional<Vector3f> RE4VRWeapons::knife_hand_world() {
    const bool left = RE4VRShared::get()->re4_knife_hand.value_or("") == "left" || RE4VRShared::get()->re4_knife_left_clone;
    auto p = left ? RE4VRShared::get()->vr_lh_world : RE4VRShared::get()->vr_rh_world;
    if (p) {
        return p;
    }
    auto* tf = re4vr::body_transform();
    auto* j = tf ? re4vr::joint_by_name(tf, left ? "L_Hand" : "R_Hand") : nullptr;
    if (j) {
        return re4vr::v3(sdk::get_joint_position(j));
    }
    return std::nullopt;
}

::REManagedObject* RE4VRWeapons::knife_pick_target(const std::optional<Vector3f>& kpos_in, bool proximity_only, float reach) {
    auto* ctx = get_player_ctx();
    if (!proximity_only && ctx) {
        if (auto* aim = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_AimTargetEnemy"); }).value_or(nullptr)) {
            auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(aim, "get_BodyGameObject"); }).value_or(nullptr);
            if (go) {
                return (::REManagedObject*)go;
            }
            return aim;
        }
    }
    auto* cm = re4vr::character_manager();
    auto* list = cm ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(cm, "get_EnemyContextList"); }).value_or(nullptr) : nullptr;
    const int count = list ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(list, "get_Count"); }).value_or(0) : 0;
    Vector3f kpos{};
    if (kpos_in) {
        kpos = *kpos_in;
    } else if (ctx) {
        auto p = re4vr::safe([&] { return sdk::call_object_func_easy<Vector4f>(ctx, "get_Position"); });
        if (!p) {
            return nullptr;
        }
        kpos = re4vr::v3(*p);
    } else {
        return nullptr;
    }
    ::REManagedObject* bestctx = nullptr;
    float bestd = 9999.0f;
    constexpr float BODY_CENTER_Y = 0.95f;
    for (int i = 0; i < count; ++i) {
        auto* ectx = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(list, "get_Item", i); }).value_or(nullptr);
        auto* hp = ectx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ectx, "get_HitPoint"); }).value_or(nullptr) : nullptr;
        if (!hp) {
            continue;
        }
        const bool dead = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(hp, "get_IsDead"); }).value_or(false);
        const auto chp = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(hp, "get_CurrentHitPoint"); }).value_or(0);
        if (dead || chp <= 0) {
            continue;
        }
        auto pos = re4vr::safe([&] { return sdk::call_object_func_easy<Vector4f>(ectx, "get_Position"); });
        if (!pos) {
            continue;
        }
        const float dx = pos->x - kpos.x;
        const float dy = (pos->y + BODY_CENTER_Y) - kpos.y;
        const float dz = pos->z - kpos.z;
        const float d = std::sqrt(dx * dx + dy * dy + dz * dz);
        if (d < bestd) {
            bestd = d;
            bestctx = ectx;
        }
    }
    if (bestctx && bestd <= reach) {
        auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(bestctx, "get_BodyGameObject"); }).value_or(nullptr);
        return go ? (::REManagedObject*)go : bestctx;
    }
    return nullptr;
}

void RE4VRWeapons::knife_throw_launch(const Vector3f& dir, float speed) {
    if (m_fly.active) {
        return;
    }
    ::REGameObject* go = nullptr;
    ::RETransform* tf = nullptr;
    const bool clone = RE4VRShared::get()->re4_knife_left_clone;
    if (clone) {
        go = (::REGameObject*)RE4VRShared::get()->re4_knife_lh_clone_go;
        tf = go ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr) : nullptr;
        if (tf) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(tf, "set_Parent(via.Transform)", (::RETransform*)nullptr); });
        }
    } else {
        auto* hc = find_knife_hc();
        go = hc ? re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(hc, "get_GameObject"); }).value_or(nullptr) : nullptr;
        tf = go ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr) : nullptr;
    }
    if (!go || !tf) {
        return;
    }
    auto hp = knife_hand_world();
    auto p = hp ? *hp : re4vr::v3(sdk::get_transform_position(tf));
    m_fly = {};
    m_fly.active = true;
    m_fly.go = go;
    m_fly.tf = tf;
    m_fly.pos = p;
    m_fly.home = p;
    m_fly.start_pos = p;
    m_fly.vel = dir * speed;
    m_fly.rot = sdk::get_transform_rotation(tf);
    m_fly.t0 = re4vr::now();
    m_fly.returning = false;
    m_fly.landed = false;
    m_fly.hit_done = false;
    m_fly.clone_throw = clone;
    m_fly.is_left = clone || RE4VRShared::get()->re4_knife_hand.value_or("") == "left";
    m_knife_flying = true;
    RE4VRShared::get()->re4_knife_flying = true;
}

void RE4VRWeapons::knife_flight_hit_scan() {
    if (m_fly.hit_done) {
        return;
    }
    auto* tgt = knife_pick_target(m_fly.pos, true, 0.55f);
    if (tgt) {
        RE4VRWeapons2::get()->native_hit(nullptr, m_fly.pos);
        m_fly.hit_done = true;
        m_fly.landed = true;
        m_fly.t0 = re4vr::now();
        return;
    }
}

void RE4VRWeapons::knife_flight_tick() {
    if (!m_fly.active) {
        return;
    }
    const double now = re4vr::now();
    float dt = (float)(now - (m_last_hand_t.value_or(now)));
    m_last_hand_t = now;
    if (dt <= 0) {
        dt = 0.016f;
    } else if (dt > 0.1f) {
        dt = 0.1f;
    }
    float grav = 7.0f, spin = 12.0f, max_t = 1.5f, ret = 0.4f;
    grav = re4vr::j_num(m_throw.extra, "gravity", grav);
    spin = re4vr::j_num(m_throw.extra, "spin_fly", spin);
    max_t = re4vr::j_num(m_throw.extra, "max_time", max_t);
    ret = re4vr::j_num(m_throw.extra, "return_delay", ret);
    if (!m_fly.returning && !m_fly.landed) {
        m_fly.pos += m_fly.vel * dt;
        m_fly.vel.y -= grav * dt;
        const float spin_dir = m_fly.is_left ? -1.0f : 1.0f;
        m_fly.spin = re4vr::axis_angle(Vector3f{1, 0, 0}, spin * spin_dir * dt) * m_fly.spin;
        if (auto home = RE4VRShared::get()->re4_knife_home) {
            const float hs = (float)RE4VRShared::get()->re4_knife_home_str.value_or(m_throw.homing);
            if (hs > 0) {
                auto to = glm::normalize(*home - m_fly.pos);
                const float sp = glm::length(m_fly.vel);
                if (sp > 0.001f && glm::length(to) > 0.001f) {
                    m_fly.vel = glm::normalize(glm::mix(glm::normalize(m_fly.vel), to, std::clamp(hs, 0.0f, 1.0f))) * sp;
                }
            }
        }
        if (!m_fly.hit_done) {
            knife_flight_hit_scan();
        }
        if ((now - m_fly.t0) > max_t || m_fly.pos.y < m_fly.home.y - 4.0f) {
            m_fly.landed = true;
            m_fly.t0 = now;
        }
    } else if (m_fly.landed && !m_fly.returning) {
        if ((now - m_fly.t0) > ret) {
            m_fly.returning = true;
            m_fly.t0 = now;
        }
    } else if (m_fly.returning) {
        m_fly.active = false;
        m_knife_flying = false;
        RE4VRShared::get()->re4_knife_flying = false;
        RE4VRHolster::get()->play_grab_sound();
    }
}

void RE4VRWeapons::knife_flight_apply() {
    RE4VRShared::get()->re4_knife_flying = m_fly.active;
    if (!m_fly.active || !m_fly.tf) {
        return;
    }
    auto valid = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_fly.tf, "get_Valid"); });
    if (valid == false) {
        m_fly.active = false;
        return;
    }
    sdk::set_transform_position(m_fly.tf, re4vr::v4(m_fly.pos));
    sdk::set_transform_rotation(m_fly.tf, glm::normalize(m_fly.rot * m_fly.spin));
}

void RE4VRWeapons::update_throw_velocity() {
    auto p = RE4VRShared::get()->vr_rh_ctrl_raw;
    if (!p) {
        p = RE4VRShared::get()->vr_rh_world;
    }
    const bool left = RE4VRShared::get()->re4_knife_hand.value_or("") == "left" || RE4VRShared::get()->re4_knife_left_clone;
    if (left) {
        p = RE4VRShared::get()->vr_lh_ctrl_raw;
        if (!p) {
            p = RE4VRShared::get()->vr_lh_world;
        }
    }
    if (!p) {
        return;
    }
    const double now = re4vr::now();
    if (m_last_hand_t) {
        const float dt = (float)(now - *m_last_hand_t);
        if (dt > 1e-4f && dt < 0.2f) {
            m_hand_vel = (*p - m_hand_pos) / dt;
        }
    }
    m_hand_pos = *p;
    m_last_hand_t = now;
}

std::optional<Vector3f> RE4VRWeapons::get_throw_direction() {
    auto v = m_hand_vel;
    if (glm::length2(v) < 1e-6f) {
        return get_hmd_forward();
    }
    return glm::normalize(v);
}

std::optional<Vector3f> RE4VRWeapons::get_hmd_forward() {
    auto* cam = sdk::get_primary_camera();
    if (!cam) {
        return std::nullopt;
    }
    auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(cam, "get_GameObject"); }).value_or(nullptr);
    auto* tf = go ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr) : nullptr;
    if (!tf) {
        return std::nullopt;
    }
    auto az = re4vr::safe([&] { return sdk::call_object_func_easy<Vector3f>(tf, "get_AxisZ"); });
    if (!az) {
        return std::nullopt;
    }
    return glm::normalize(-*az);
}

void RE4VRWeapons::throw_on_frame() {
    const bool knife_equ = is_knife_equipped();
    RE4VRShared::get()->re4_knife_equipped = knife_equ;
    if (!knife_equ) {
        RE4VRShared::get()->re4_knife_hand = std::string{"none"};
        m_knife_hand = "none";
    } else {
        const bool left = RE4VRShared::get()->re4_knife_left_intent;
        RE4VRShared::get()->re4_knife_hand = std::string{left ? "left" : "right"};
        m_knife_hand = left ? "left" : "right";
    }
    if (knife_equ || RE4VRShared::get()->re4_knife_left_clone) {
        knife_flight_tick();
        const bool left_knife = m_knife_hand == "left" || RE4VRShared::get()->re4_knife_left_clone;
        const bool grip = re4vr::grip_held(left_knife);
        const bool hz = left_knife ? RE4VRShared::get()->vr_knife_lh_holster_zone : RE4VRShared::get()->vr_knife_holster_zone;
        const bool flipped = RE4VRShared::get()->vr_knife_flip;
        const bool gripping = !m_fly.active && !hz && !flipped && grip;
        RE4VRShared::get()->re4_knife_throw_gripping = gripping;
        if (gripping) {
            update_throw_velocity();
            if (auto d = get_throw_direction()) {
                RE4VRShared::get()->re4_knife_throw_dir = *d;
            }
            m_winding = true;
        }
        if (m_grip_was && !gripping) {
            auto dir = RE4VRShared::get()->re4_knife_throw_dir;
            if (dir && dir->y < -0.25f) {
                const float h = std::sqrt(dir->x * dir->x + dir->z * dir->z);
                if (h > 0.001f) {
                    const float hs = std::sqrt(std::max(0.0001f, 1.0f - 0.25f * 0.25f)) / h;
                    dir = Vector3f{dir->x * hs, -0.25f, dir->z * hs};
                    RE4VRShared::get()->re4_knife_throw_dir = *dir;
                }
            }
            const float peak = glm::length(m_hand_vel);
            static double last_throw = 0;
            const double now = re4vr::now();
            if (dir && peak >= 1.5f && (now - last_throw) >= 0.4) {
                last_throw = now;
                float spd = 12.0f;
                spd = re4vr::j_num(m_throw.extra, "speed", spd);
                knife_throw_launch(*dir, spd);
            }
        }
        m_grip_was = gripping;
    }
    // melee on swing edge
    const bool swing = RE4VRShared::get()->vr_knife_swing;
    if (swing && !m_prev_swing && !RE4VRShared::get()->re4_knife_throw_gripping && !m_fly.active) {
        do_knife_melee();
    }
    m_prev_swing = swing;
}

HookManager::PreHookResult RE4VRWeapons::pre_change_weapon(std::vector<uintptr_t>&, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    auto& self = *get();
    if (!RE4VRShared::get()->re4_frame_is_gameplay) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    auto until = RE4VRShared::get()->re4_our_equip_until;
    if (until && re4vr::now() < *until) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    auto eid = self.get_equip_weapon_id();
    if (eid && self.m_knife_ids.contains(*eid)) {
        return HookManager::PreHookResult::SKIP_ORIGINAL;
    }
    return HookManager::PreHookResult::CALL_ORIGINAL;
}

HookManager::PreHookResult RE4VRWeapons::pre_request_equip_knife(std::vector<uintptr_t>&, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    if (!RE4VRShared::get()->re4_qk_block) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    auto until = RE4VRShared::get()->re4_our_equip_until;
    if (until && re4vr::now() < *until) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    if ((re4vr::now() - RE4VRShared::get()->re4_knife_draw_ours_t.value_or(-999)) < 1.0) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    if (RE4VRCrosshair::get()->is_finisher_prompt()) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    if (!re4vr::call_killswitch_bool("is_pure_gameplay", RE4VRShared::get()->re4_frame_is_gameplay)) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    const bool aim = RE4VRShared::get()->vr_aim_input;
    const bool rt = RE4VRShared::get()->vr_rt_raw || RE4VRShared::get()->re4_rt_held;
    if (rt && !aim) {
        return HookManager::PreHookResult::SKIP_ORIGINAL;
    }
    return HookManager::PreHookResult::CALL_ORIGINAL;
}

HookManager::PreHookResult RE4VRWeapons::pre_equip_weapon(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    if (!RE4VRShared::get()->re4_qk_block) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    auto until = RE4VRShared::get()->re4_our_equip_until;
    if (until && re4vr::now() < *until) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    return HookManager::PreHookResult::CALL_ORIGINAL;
}

HookManager::PreHookResult RE4VRWeapons::pre_change_active(std::vector<uintptr_t>&, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    auto g = RE4VRShared::get()->re4_stow_guard_until;
    if (g && re4vr::now() < *g) {
        auto ours = RE4VRShared::get()->re4_stow_ours_until;
        if (!(ours && re4vr::now() < *ours) && RE4VRShared::get()->re4_stow_block) {
            return HookManager::PreHookResult::SKIP_ORIGINAL;
        }
    }
    return HookManager::PreHookResult::CALL_ORIGINAL;
}

HookManager::PreHookResult RE4VRWeapons::pre_pool_damage(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    if (args.size() > 5) {
        re4vr::LuaGuard g;
        auto* L = g.lua();
        if (L) {
            (*L)["__re4_lp_atk"] = (uintptr_t)args[3];
            (*L)["__re4_lp_dmg"] = (uintptr_t)args[4];
        }
    }
    return HookManager::PreHookResult::CALL_ORIGINAL;
}
HookManager::PreHookResult RE4VRWeapons::pre_attack_hit(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    if (args.size() > 2 && args[2]) {
        RE4VRShared::get()->re4_knife_last_target = (::REManagedObject*)args[1];
    }
    return HookManager::PreHookResult::CALL_ORIGINAL;
}
HookManager::PreHookResult RE4VRWeapons::pre_calc_damage(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    auto until = RE4VRShared::get()->re4_knife_our_until;
    if (until && re4vr::now() < *until && args.size() > 2) {
        RE4VRShared::get()->re4_knife_last_target = (::REManagedObject*)args[1];
    }
    return HookManager::PreHookResult::CALL_ORIGINAL;
}
HookManager::PreHookResult RE4VRWeapons::pre_gun_object(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    if (args.size() > 1 && args[1]) {
        RE4VRShared::get()->re4_grenade_gen = (::REManagedObject*)args[1];
    }
    return HookManager::PreHookResult::CALL_ORIGINAL;
}
void RE4VRWeapons::post_nop(uintptr_t&, sdk::RETypeDefinition*, uintptr_t) {}

void RE4VRWeapons::snappy_wep_tick() {
    const bool on = m_snappy.enabled && re4vr::j_bool(m_snappy.data, "direct_snap", true);
    RE4VRShared::get()->vr_wsw_pin = on;
    auto* ctx = get_player_ctx();
    auto* body = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(ctx, "get_BodyGameObject"); }).value_or(nullptr) : nullptr;
    const uintptr_t addr = (uintptr_t)body;
    if (addr != m_snappy_last_body) {
        m_snappy_last_body = addr;
        m_snappy_applied = false;
    }
    if (m_snappy_applied || !body) {
        return;
    }
    auto* bu = re4vr::safe([&] { return utility::re_managed_object::get_field<::REManagedObject*>(ctx, "_BodyUpdater"); }).value_or(nullptr);
    auto* mfsm2 = bu ? re4vr::safe([&] { return utility::re_managed_object::get_field<::REManagedObject*>(bu, "<MotionFsm>k__BackingField"); }).value_or(nullptr) : nullptr;
    if (!mfsm2) {
        return;
    }
    auto* layer = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(mfsm2, "getLayer", 4); }).value_or(nullptr);
    if (!layer) {
        return;
    }
    auto* tree = ((sdk::behaviortree::CoreHandle*)layer)->get_tree_object();
    if (!tree) {
        return;
    }
    m_snappy_applied = true;
    if (auto* put = tree->get_node_by_name("wp4000H_0551_put_away")) {
        auto acts = put->get_actions();
        if (acts.size() > 3 && acts[3]) {
            const bool feature = m_snappy.enabled;
            float sf = 0;
            if (feature) {
                if (re4vr::j_bool(m_snappy.data, "direct_snap", true)) {
                    auto* ef = sdk::get_object_field<float>(acts[3], "_EndFrame");
                    sf = (ef && *ef > 1.0f) ? *ef : 9999.0f;
                } else {
                    sf = re4vr::j_num(m_snappy.data, "frameskip", 35.0f);
                }
            }
            if (auto* sfp = sdk::get_object_field<float>(acts[3], "_StartFrame")) {
                *sfp = sf;
            }
            if (auto* ov = sdk::get_object_field<bool>(acts[3], "_OverwriteInterpolation")) {
                *ov = feature;
            }
        }
    }
    if (auto* hend = tree->get_node_by_name("HOLD_END")) {
        auto acts = hend->get_actions();
        if (acts.size() <= 3) {
            acts = hend->get_unloaded_actions();
        }
        if (acts.size() > 3 && acts[3]) {
            const bool fast = re4vr::j_bool(m_snappy.data, "fast_re_aim", true);
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(acts[3], "set_Enabled", !fast); });
        }
    }
}

void RE4VRWeapons::scope_set_all_materials(::REManagedObject* renderer, bool visible) {
    if (!renderer) {
        return;
    }
    const int n = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(renderer, "get_MaterialNum"); }).value_or(0);
    for (int mi = 0; mi < n; ++mi) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(renderer, "setMaterialsEnable", mi, visible); });
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(renderer, "setMaterialsEnable(System.Int32, System.Boolean)", mi, visible); });
    }
}

void RE4VRWeapons::scope_walk_body(::RETransform* tf, bool visible, int depth) {
    if (!tf || depth > 8) {
        return;
    }
    auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(tf, "get_GameObject"); }).value_or(nullptr);
    if (go) {
        const auto nm = re4vr::go_name((::REManagedObject*)go);
        if (nm == "body" || nm == "body_armor") {
            scope_set_all_materials(re4vr::get_component((::REManagedObject*)go, "via.render.Mesh"), visible);
            scope_set_all_materials(re4vr::get_component((::REManagedObject*)go, "via.render.SkinnedMesh"), visible);
        }
    }
    auto* child = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(tf, "get_Child"); }).value_or(nullptr);
    int guard = 0;
    while (child && guard < 256) {
        ++guard;
        scope_walk_body(child, visible, depth + 1);
        child = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(child, "get_Next"); }).value_or(nullptr);
    }
}

void RE4VRWeapons::scope_hide_arms_tick(bool on) {
    if (!on && !m_scope_arms_on) {
        return;
    }
    auto* ctx = get_player_ctx();
    auto* body = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(ctx, "get_BodyGameObject"); }).value_or(nullptr) : nullptr;
    auto* tf = body ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(body, "get_Transform"); }).value_or(nullptr) : nullptr;
    if (tf) {
        scope_walk_body(tf, !on, 0);
    }
    m_scope_arms_on = on;
}

bool RE4VRWeapons::gun_bolt_cycle_active(int32_t ewid) {
    if (!m_bolt_rifles.contains(ewid)) {
        return false;
    }
    auto* ctx = get_player_ctx();
    auto* hu = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_HeadUpdater"); }).value_or(nullptr) : nullptr;
    auto* gun = hu ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(hu, "get_EquipWeapon"); }).value_or(nullptr) : nullptr;
    auto* go = gun ? re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(gun, "get_GameObject"); }).value_or(nullptr) : nullptr;
    auto* fsm = go ? re4vr::get_component((::REManagedObject*)go, "via.motion.MotionFsm2") : nullptr;
    auto* n0 = fsm ? re4vr::safe([&] { return sdk::call_object_func_easy<::SystemString*>(fsm, "getCurrentNodeName", 0); }).value_or(nullptr) : nullptr;
    if (!n0) {
        return false;
    }
    return utility::re_string::get_string(n0).find("PumpAction") != std::string::npos;
}

void RE4VRWeapons::weapon_switch_skip_tick() {
    if (!(m_snappy.enabled && re4vr::j_bool(m_snappy.data, "direct_snap", true))) {
        return;
    }
    auto* ctx = get_player_ctx();
    auto* body = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(ctx, "get_BodyGameObject"); }).value_or(nullptr) : nullptr;
    if (!body) {
        m_wsw_body = nullptr;
        return;
    }
    if (body != m_wsw_body) {
        m_wsw_body = body;
        m_wsw_fsm = re4vr::get_component((::REManagedObject*)body, "via.motion.MotionFsm2");
        m_wsw_mot = re4vr::get_component((::REManagedObject*)body, "via.motion.Motion");
    }
    if (!m_wsw_fsm || !m_wsw_mot) {
        return;
    }
    auto* node = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(m_wsw_fsm, "getCurrentNodeName", 4); }).value_or(nullptr);
    if (!node || re4vr::obj_name(node).find("ChangeWeapon") == std::string::npos) {
        return;
    }
    auto* layer = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(m_wsw_mot, "getLayer", 4); }).value_or(nullptr);
    if (!layer) {
        return;
    }
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(layer, "set_BlendRate", 0.0f); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(layer, "set_Weight", 0.0f); });
    const float ef = re4vr::safe([&] { return sdk::call_object_func_easy<float>(layer, "get_EndFrame"); }).value_or(0);
    if (ef > 1.0f) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(layer, "set_Frame", ef - 0.5f); });
    }
}

void RE4VRWeapons::scope_proto_tick() {
    if (!m_scope_proto.enabled && re4vr::j_num(m_scope_proto.data, "scale", 1.0f) == 1.0f
        && re4vr::j_num(m_scope_proto.data, "ox", 0) == 0 && re4vr::j_num(m_scope_proto.data, "oy", 0) == 0
        && re4vr::j_num(m_scope_proto.data, "oz", 0) == 0) {
        return;
    }
    auto* ctx = get_player_ctx();
    auto* hu = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_HeadUpdater"); }).value_or(nullptr) : nullptr;
    auto* gun = hu ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(hu, "get_EquipWeapon"); }).value_or(nullptr) : nullptr;
    auto* go = gun ? re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(gun, "get_GameObject"); }).value_or(nullptr) : nullptr;
    auto* tf = go ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr) : nullptr;
    if (!tf) {
        return;
    }
    const float sc = re4vr::j_num(m_scope_proto.data, "scale", 1.0f);
    const float ox = re4vr::j_num(m_scope_proto.data, "ox", 0);
    const float oy = re4vr::j_num(m_scope_proto.data, "oy", 0);
    const float oz = re4vr::j_num(m_scope_proto.data, "oz", 0);
    walk_children(tf, [&](::REGameObject* cgo, ::RETransform* ctf) {
        if (!cgo || !ctf) {
            return;
        }
        auto nm = re4vr::go_name((::REManagedObject*)cgo);
        if (nm.find("scope") == std::string::npos && nm.find("Scope") == std::string::npos) {
            return;
        }
        if (sc != 1.0f) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(ctf, "set_LocalScale", Vector3f{sc, sc, sc}); });
        }
        if (ox != 0 || oy != 0 || oz != 0) {
            auto lp = re4vr::safe([&] { return sdk::call_object_func_easy<Vector3f>(ctf, "get_LocalPosition"); });
            if (lp) {
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(ctf, "set_LocalPosition", Vector3f{lp->x + ox, lp->y + oy, lp->z + oz}); });
            }
        }
    });
}

void RE4VRWeapons::iron_sight_tick(std::optional<int32_t> wid) {
    auto* ctx = get_player_ctx();
    auto* body = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(ctx, "get_BodyGameObject"); }).value_or(nullptr) : nullptr;
    auto* tf = body ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(body, "get_Transform"); }).value_or(nullptr) : nullptr;
    std::function<void(::RETransform*, int)> walk = [&](::RETransform* t, int depth) {
        if (!t || depth > 8) {
            return;
        }
        auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(t, "get_GameObject"); }).value_or(nullptr);
        if (go) {
            auto nm = re4vr::go_name((::REManagedObject*)go);
            if (nm == "body" || nm == "body_armor" || nm == "hair" || nm == "head") {
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(go, "set_UpdateSelf", true); });
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(go, "set_DrawSelf", true); });
            }
        }
        auto* c = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(t, "get_Child"); }).value_or(nullptr);
        while (c) {
            walk(c, depth + 1);
            c = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(c, "get_Next"); }).value_or(nullptr);
        }
    };
    walk(tf, 0);
    if (!wid) {
        return;
    }
    char base[16];
    std::snprintf(base, sizeof(base), "wp%04d", *wid);
    ::REGameObject* wgo = nullptr;
    if (tf) {
        walk_children(tf, [&](::REGameObject* go, ::RETransform*) {
            if (wgo || !go) {
                return;
            }
            auto nm = re4vr::go_name((::REManagedObject*)go);
            if (nm == base || nm == std::string(base) + "_AO" || nm == std::string(base) + "_MC") {
                wgo = go;
            }
        });
    }
    if (!wgo) {
        return;
    }
    auto* mesh = re4vr::get_component((::REManagedObject*)wgo, "via.render.Mesh");
    if (mesh) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "setPartsEnable", 0, true); });
    }
    auto* wtf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(wgo, "get_Transform"); }).value_or(nullptr);
    auto* parent = wtf ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(wtf, "get_Parent"); }).value_or(nullptr) : nullptr;
    if (wtf && !parent && tf) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(wtf, "set_Parent", tf); });
    }
}

void RE4VRWeapons::sync_assist_light() {
    hide_assist_light();
}

void RE4VRWeapons::update_knife_holster_timer() {
    if (m_kko_frames <= 0) {
        return;
    }
    auto* ctx = get_player_ctx();
    auto* head = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(ctx, "get_HeadGameObject"); }).value_or(nullptr) : nullptr;
    auto* updater = head ? re4vr::get_component((::REManagedObject*)head, "chainsaw.Ch0a0z0HeadUpdater") : nullptr;
    if (!updater && head) {
        updater = re4vr::get_component((::REManagedObject*)head, "chainsaw.Ch3a8z0HeadUpdater");
    }
    auto* timer = updater ? re4vr::safe([&] { return utility::re_managed_object::get_field<::REManagedObject*>(updater, "<KnifeCloseTimer>k__BackingField"); }).value_or(nullptr) : nullptr;
    if (timer) {
        if (auto* lim = sdk::get_object_field<float>(timer, "_TimeLimit")) {
            if (!m_kko_orig) {
                m_kko_orig = *lim;
            }
            *lim = 0.0f;
        }
    }
    --m_kko_frames;
    if (m_kko_frames == 0 && m_kko_orig && timer) {
        if (auto* lim = sdk::get_object_field<float>(timer, "_TimeLimit")) {
            *lim = *m_kko_orig;
        }
        m_kko_orig.reset();
    }
}

void RE4VRWeapons::grenade_on_frame() {
    if (!is_grenade_equipped()) {
        return;
    }
    update_throw_velocity();
    if (auto d = get_throw_direction()) {
        RE4VRShared::get()->re4_throw_dir = *d;
    }
}

void RE4VRWeapons::melee_on_frame() { throw_on_frame(); }
void RE4VRWeapons::publish_scope_globals() { scope_killswitch_tick(); }
void RE4VRWeapons::save_scope_proto() {
    re4vr::save_json_file("re4_vr/re4_vr_scope_proto.json", m_scope_proto.data);
}
void RE4VRWeapons::save_snappy() {
    re4vr::save_json_file("re4_vr/re4_vr_snappy.json", m_snappy.data);
}
void RE4VRWeapons::save_throw() {
    re4vr::save_json_file("re4_vr/re4_vr_throw.json", m_throw.extra);
}

void RE4VRWeapons::on_frame() {
    ScriptProfileGuard guard("re4_vr_weapons.lua", "on_frame", re4vr::profile_frame());
    hide_assist_light();
    grenade_on_frame();
    weapon_switch_skip_tick();
    update_knife_holster_timer();
    keep_knife_out();
    throw_on_frame();
}

void RE4VRWeapons::on_pre_application_entry(void*, const char* name, size_t hash) {
    const auto call = std::string("on_pre_application_entry:") + (name ? name : "");
    if (hash == "LockScene"_fnv) {
        ScriptProfileGuard guard("re4_vr_weapons.lua", call, re4vr::profile_frame());
        hide_body_weapons_tick();
        snappy_wep_tick();
        auto ewid = get_equip_weapon_id();
        if (ewid && m_iron_rifles.contains(*ewid) && RE4VRShared::get()->vr_aim_input) {
            iron_sight_tick(ewid);
        }
        scope_proto_tick();
        knife_flight_apply();
    } else if (hash == "UpdateScene"_fnv) {
        ScriptProfileGuard guard("re4_vr_weapons.lua", call, re4vr::profile_frame());
        scope_killswitch_tick();
    } else if (hash == "BeginRendering"_fnv) {
        ScriptProfileGuard guard("re4_vr_weapons.lua", call, re4vr::profile_frame());
        knife_flight_apply();
        weapon_switch_skip_tick();
    }
}

void RE4VRWeapons::on_application_entry(void*, const char* name, size_t hash) {
    const auto call = std::string("on_application_entry:") + (name ? name : "");
    if (hash == "LateUpdateBehavior"_fnv || hash == "UpdateJointExpression"_fnv) {
        ScriptProfileGuard guard("re4_vr_weapons.lua", call, re4vr::profile_frame());
        knife_flight_apply();
        if (hash == "UpdateJointExpression"_fnv) {
            weapon_switch_skip_tick();
        }
    } else if (hash == "UpdateMotion"_fnv) {
        ScriptProfileGuard guard("re4_vr_weapons.lua", call, re4vr::profile_frame());
        weapon_switch_skip_tick();
    }
}
#endif
