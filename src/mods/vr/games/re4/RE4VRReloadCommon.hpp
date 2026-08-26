#pragma once

#if defined(RE4)
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include <glm/gtc/quaternion.hpp>
#include <glm/gtx/norm.hpp>
#include <glm/gtx/quaternion.hpp>
#include <sdk/RETransform.hpp>
#include <sdk/RETypeDB.hpp>
#include <sdk/SystemArray.hpp>
#include <utility/String.hpp>

#include "RE4VRFrameCache.hpp"
#include "RE4VRReloadAdv.hpp"
#include "RE4VRShared.hpp"
#include "HookManager.hpp"
#include "../../../VR.hpp"

namespace re4vr::rl {
inline float ease(float t) {
    return t * t * (3.0f - 2.0f * t);
}
inline glm::quat quat_from_euler(float rx, float ry, float rz) {
    return re4vr::quat_euler_xyz_deg(rx, ry, rz);
}
inline int32_t enum_num(::REManagedObject* o) {
    if (!o) {
        return 0;
    }
    if (auto n = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(o, "ToInt32"); })) {
        return *n;
    }
    return re4vr::safe([&] { return utility::re_managed_object::get_field<int32_t>(o, "value__"); }).value_or(0);
}
inline int32_t id_num(::REManagedObject* o) {
    if (!o) {
        return 0;
    }
    if (auto n = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(o, "ToInt32"); })) {
        return *n;
    }
    auto v = re4vr::safe([&] { return utility::re_managed_object::get_field<int32_t>(o, "value__"); });
    if (v) {
        return *v;
    }
    return 0;
}
inline ::REManagedObject* pe() {
    auto& fc = RE4VRFrameCache::get();
    if (fc->on()) {
        return fc->pe();
    }
    auto* head = re4vr::head_game_object();
    return re4vr::get_component((::REManagedObject*)head, "chainsaw.PlayerEquipment");
}
inline std::optional<int32_t> equip_wid() {
    auto& fc = RE4VRFrameCache::get();
    if (fc->on()) {
        return fc->equip_wid();
    }
    auto* ctx = re4vr::player_context();
    auto* hu = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_HeadUpdater"); }).value_or(nullptr) : nullptr;
    if (!hu) {
        return std::nullopt;
    }
    if (auto n = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(hu, "get_EquipWeaponID"); })) {
        return n;
    }
    auto* o = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(hu, "get_EquipWeaponID"); }).value_or(nullptr);
    return o ? std::optional<int32_t>{enum_num(o)} : std::nullopt;
}
inline ::RETransform* body_tf() {
    auto& fc = RE4VRFrameCache::get();
    if (fc->on()) {
        return fc->body_tf();
    }
    return re4vr::body_transform();
}
inline ::REGameObject* search_tree(::RETransform* tf, const std::string& target, int depth) {
    if (!tf || depth < 0) {
        return nullptr;
    }
    auto* child = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(tf, "get_Child"); }).value_or(nullptr);
    int n = 0;
    while (child && n < 128) {
        ++n;
        auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(child, "get_GameObject"); }).value_or(nullptr);
        if (go) {
            auto nm = re4vr::go_name((::REManagedObject*)go);
            auto draw = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(go, "get_DrawSelf"); });
            if (nm == target && draw.value_or(true)) {
                return go;
            }
        }
        if (auto* f = search_tree(child, target, depth - 1)) {
            return f;
        }
        child = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(child, "get_Next"); }).value_or(nullptr);
    }
    return nullptr;
}
inline std::pair<::REGameObject*, ::RETransform*> find_weapon(int32_t wid) {
    auto* bt = body_tf();
    if (!bt || !wid) {
        return {nullptr, nullptr};
    }
    char base[32];
    std::snprintf(base, sizeof(base), "wp%04d", wid);
    static const char* suf[] = {"", "_AO", "_MC"};
    for (auto* s : suf) {
        auto* go = search_tree(bt, std::string(base) + s, 5);
        if (go) {
            auto* tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr);
            return {go, tf};
        }
    }
    return {nullptr, nullptr};
}
inline ::REJoint* left_hand() {
    auto* bt = body_tf();
    auto* j = bt ? re4vr::joint_by_name(bt, "L_Hand") : nullptr;
    return j ? j : (bt ? re4vr::joint_by_name(bt, "L_Arm_Hand") : nullptr);
}
inline ::REJoint* right_hand() {
    auto* bt = body_tf();
    auto* j = bt ? re4vr::joint_by_name(bt, "R_Hand") : nullptr;
    return j ? j : (bt ? re4vr::joint_by_name(bt, "R_Arm_Hand") : nullptr);
}
inline std::optional<Vector3f> lh_world() {
    if (auto p = RE4VRShared::get()->vr_lh_world) {
        return p;
    }
    if (auto p = RE4VRShared::get()->vr_unified_lh_pos) {
        return p;
    }
    if (auto p = RE4VRShared::get()->vr_lh_joint_pos) {
        return p;
    }
    auto* j = left_hand();
    return j ? std::optional<Vector3f>{re4vr::v3(sdk::get_joint_position(j))} : std::nullopt;
}
inline std::optional<Vector3f> lh_ctrl() {
    if (auto p = RE4VRShared::get()->vr_lh_ctrl_world) {
        return p;
    }
    if (auto p = RE4VRShared::get()->vr_lh_ctrl_raw) {
        return p;
    }
    return lh_world();
}
inline std::optional<Vector3f> rh_world() {
    if (auto p = RE4VRShared::get()->vr_rh_world) {
        return p;
    }
    if (auto p = RE4VRShared::get()->vr_unified_rh_pos) {
        return p;
    }
    auto* j = right_hand();
    return j ? std::optional<Vector3f>{re4vr::v3(sdk::get_joint_position(j))} : std::nullopt;
}
inline bool right_b() {
    return RE4VRShared::get()->vr_raw_r_bbutton;
}
inline bool left_grip() {
    return re4vr::grip_held(true);
}
inline bool right_grip() {
    return re4vr::grip_held(false);
}
inline bool left_trigger() {
    auto& vr = VR::get();
    const auto act = vr->get_action_trigger();
    const auto joy = vr->get_left_joystick();
    return act && joy && vr->is_action_active(act, joy);
}
inline void haptic_left(float amp, float dur) {
    auto& vr = VR::get();
    auto h = vr->get_left_joystick();
    if (h) {
        vr->trigger_haptic_vibration(0.0f, dur, 169.385f, amp, h);
    }
}
inline void haptic_right(float amp, float dur) {
    auto& vr = VR::get();
    auto h = vr->get_right_joystick();
    if (h) {
        vr->trigger_haptic_vibration(0.0f, dur, 90.0f, amp, h);
    }
}
inline void play_go_sound(::REManagedObject* go, uint32_t id) {
    if (!re4vr::obj_ok(go) || id == 0) {
        return;
    }
    auto* scn = re4vr::get_component(go, "soundlib.SoundContainer");
    if (scn) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(scn, "trigger", id); });
    }
}
inline void write_ammo(::REManagedObject* wi, int32_t n) {
    if (!re4vr::obj_ok(wi)) {
        return;
    }
    *(int32_t*)((uintptr_t)wi + 0x44) = n;
}
inline std::optional<int32_t> ammo_count(::REManagedObject* wi) {
    if (!re4vr::obj_ok(wi)) {
        return std::nullopt;
    }
    return re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(wi, "get_CurrentAmmoCount"); });
}
inline ::REManagedObject* real_wi(std::optional<int32_t> want = std::nullopt) {
    if (RE4VRShared::get()->re4_use_accessor_item == false) {
        return nullptr;
    }
    auto* p = pe();
    if (!p) {
        return nullptr;
    }
    auto* acc = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(p, "getEquipWeaponAccessor"); }).value_or(nullptr);
    if (!acc) {
        return nullptr;
    }
    auto* real = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(acc, "get_Item"); }).value_or(nullptr);
    if (!real) {
        return nullptr;
    }
    if (!ammo_count(real)) {
        return nullptr;
    }
    if (want) {
        auto* wido = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(real, "get_WeaponId"); }).value_or(nullptr);
        int32_t w = 0;
        if (auto n = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(real, "get_WeaponId"); })) {
            w = *n;
        } else {
            w = enum_num(wido);
        }
        if (w && w != *want) {
            return nullptr;
        }
    }
    return real;
}
inline ::REManagedObject* live_wi() {
    if (auto* r = real_wi()) {
        return r;
    }
    auto* cached = (::REManagedObject*)RE4VRShared::get()->re4_live_wi;
    if (re4vr::obj_ok(cached)) {
        auto t = RE4VRShared::get()->re4_live_wi_t.value_or(-1);
        if (re4vr::now() - t < 0.25) {
            return cached;
        }
    }
    auto* p = pe();
    return p ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(p, "getEquipWeaponItem"); }).value_or(nullptr) : nullptr;
}
inline int32_t item_count_sum_num(::REManagedObject* inv, int32_t num) {
    if (!inv || !num) {
        return 0;
    }
    auto* items = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(inv, "getItems"); }).value_or(nullptr);
    if (!items) {
        return 0;
    }
    const int n = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(items, "get_Count"); }).value_or(0);
    int32_t sum = 0;
    for (int i = 0; i < n; ++i) {
        auto* it = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(items, "get_Item(System.Int32)", i); }).value_or(nullptr);
        auto* iid = it ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(it, "get_ItemId"); }).value_or(nullptr) : nullptr;
        if (id_num(iid) == num) {
            sum += re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(it, "get_CurrentItemCount"); }).value_or(0);
        }
    }
    return sum;
}
inline int32_t item_count_sum(::REManagedObject* inv, ::REManagedObject* id) {
    return item_count_sum_num(inv, id_num(id));
}
inline bool safe_reduce(::REManagedObject* inv, ::REManagedObject* ammo_id, int n) {
    if (!inv || !ammo_id || n <= 0) {
        return false;
    }
    const int32_t want = id_num(ammo_id);
    auto* items = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(inv, "getItems"); }).value_or(nullptr);
    if (!items) {
        return false;
    }
    const int cnt = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(items, "get_Count"); }).value_or(0);
    int left = n;
    for (int i = 0; i < cnt && left > 0; ++i) {
        auto* it = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(items, "get_Item(System.Int32)", i); }).value_or(nullptr);
        auto* iid = it ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(it, "get_ItemId"); }).value_or(nullptr) : nullptr;
        if (id_num(iid) != want) {
            continue;
        }
        const int cur = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(it, "get_CurrentItemCount"); }).value_or(0);
        const int take = std::min(cur, left);
        if (take > 0) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(it, "set_CurrentItemCount", cur - take); });
            left -= take;
        }
    }
    return left < n;
}
inline bool drain_to_zero(::REManagedObject* wi) {
    if (!wi) {
        return false;
    }
    auto cur = ammo_count(wi).value_or(0);
    if (cur <= 0) {
        return true;
    }
    write_ammo(wi, 0);
    if (ammo_count(wi).value_or(0) > 0) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(wi, "reduceAmmoCount", ammo_count(wi).value_or(cur)); });
    }
    if (ammo_count(wi).value_or(0) > 0) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(wi, "addAmmoCount", -ammo_count(wi).value_or(cur), false); });
    }
    if (ammo_count(wi).value_or(0) > 0) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(wi, "forceSetAmmoCount", 0); });
    }
    if (ammo_count(wi).value_or(0) > 0) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(wi, "setAmmoCount", 0); });
    }
    return true;
}
inline void sync_gun_ammo() {
    auto* p = pe();
    if (p) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(p, "updateGunAmmo"); });
    }
}
inline std::optional<int32_t> gun_ammo() {
    auto* p = pe();
    if (!p) {
        return std::nullopt;
    }
    return re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(p, "getCurrentGunAmmo"); });
}
inline ::REManagedObject* inv_of(::REManagedObject* p) {
    return p ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(p, "get_InventoryController"); }).value_or(nullptr) : nullptr;
}
inline ::REManagedObject* current_ammo(::REManagedObject* wi) {
    return wi ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(wi, "get_CurrentAmmo"); }).value_or(nullptr) : nullptr;
}
inline int32_t reserve_of(::REManagedObject* wi) {
    auto* p = pe();
    auto* inv = inv_of(p);
    auto* aid = current_ammo(wi);
    return (inv && aid) ? item_count_sum(inv, aid) : 0;
}
inline bool add_ammo(::REManagedObject* wi, int add, bool sync = true) {
    if (!wi || add <= 0) {
        return false;
    }
    const int b4 = ammo_count(wi).value_or(0);
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(wi, "addAmmoCount", add, true); });
    if (sync) {
        sync_gun_ammo();
    }
    if (ammo_count(wi).value_or(b4) <= b4) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(wi, "addAmmoCount", add, false); });
        if (sync) {
            sync_gun_ammo();
        }
    }
    if (ammo_count(wi).value_or(b4) <= b4) {
        write_ammo(wi, b4 + add);
        if (sync) {
            sync_gun_ammo();
        }
    }
    return ammo_count(wi).value_or(b4) > b4;
}
inline bool load_and_book(int add) {
    if (add <= 0) {
        return false;
    }
    auto* wi = live_wi();
    auto* p = pe();
    auto* inv = inv_of(p);
    auto* aid = current_ammo(wi);
    const int hud_b4 = gun_ammo().value_or(ammo_count(wi).value_or(0));
    const int r_b4 = (inv && aid) ? item_count_sum(inv, aid) : 0;
    const bool ok = add_ammo(wi, add, true);
    const int hud_af = gun_ammo().value_or(hud_b4);
    const int gained = std::max(0, hud_af - hud_b4);
    if (gained > 0 && inv && aid) {
        const int r_now = item_count_sum(inv, aid);
        if (r_now >= r_b4) {
            safe_reduce(inv, aid, gained);
        }
    }
    return ok || gained > 0;
}
inline RE4VRReloadAdv* mag_slide() {
    return RE4VRReloadAdv::get().get();
}
inline void cache_live_wi(::REManagedObject* wi) {
    if (!re4vr::obj_ok(wi)) {
        return;
    }
    RE4VRShared::get()->re4_live_wi = wi;
    RE4VRShared::get()->re4_live_wi_t = re4vr::now();
}
inline void set_pose_name(std::string_view g, const std::string& name) {
    if (name.empty()) {
        re4vr::lua_set_nil(g);
    } else {
        re4vr::lua_set_string(g, name);
    }
}
inline std::optional<Vector3f> jpos(::REJoint* j) {
    return j ? std::optional<Vector3f>{re4vr::v3(sdk::get_joint_position(j))} : std::nullopt;
}
inline std::optional<glm::quat> jrot(::REJoint* j) {
    return j ? std::optional<glm::quat>{sdk::get_joint_rotation(j)} : std::nullopt;
}
inline std::optional<Vector3f> jlp(::REJoint* j) {
    return j ? std::optional<Vector3f>{re4vr::v3(sdk::get_joint_local_position(j))} : std::nullopt;
}
inline std::optional<glm::quat> jlr(::REJoint* j) {
    return j ? std::optional<glm::quat>{sdk::get_joint_local_rotation(j)} : std::nullopt;
}
inline void set_jpos(::REJoint* j, const Vector3f& p) {
    if (j) {
        sdk::set_joint_position(j, re4vr::v4(p));
    }
}
inline void set_jrot(::REJoint* j, const glm::quat& q) {
    if (j) {
        sdk::set_joint_rotation(j, q);
    }
}
inline void set_jlp(::REJoint* j, const Vector3f& p) {
    if (j) {
        sdk::set_joint_local_position(j, re4vr::v4(p));
    }
}
inline void set_jlr(::REJoint* j, const glm::quat& q) {
    if (j) {
        sdk::set_joint_local_rotation(j, q);
    }
}
inline void set_jlp_z(::REJoint* j, float z) {
    auto p = jlp(j);
    if (p && j) {
        set_jlp(j, Vector3f{p->x, p->y, z});
    }
}
inline ::REGameObject* go_of(::RETransform* tf) {
    return tf ? re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(tf, "get_GameObject"); }).value_or(nullptr) : nullptr;
}
inline void play_wep_sound(::RETransform* tf, uint32_t id) {
    if (id) {
        play_go_sound((::REManagedObject*)go_of(tf), id);
    }
}
inline bool unlimited() {
    return RE4VRShared::get()->refresh_unlimited();
}
inline bool gameplay() {
    return RE4VRShared::get()->re4_frame_is_gameplay;
}
inline void mesh_parts(::REManagedObject* mesh, int part, bool enable_only) {
    if (!mesh) {
        return;
    }
    for (int i = 0; i <= 48; ++i) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "setPartsEnable", i, enable_only ? (i == part) : false); });
    }
}
inline ::REManagedObject* mesh_of(::REGameObject* go) {
    return re4vr::get_component((::REManagedObject*)go, "via.render.Mesh");
}
inline void set_scale(::REJoint* j, float s) {
    if (!j) {
        return;
    }
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(j, "set_LocalScale", Vector3f{s, s, s}); });
}
inline void pose_fade_export() {
    if (!RE4VRShared::get()->re4_pose_fade_dur) {
        RE4VRShared::get()->re4_pose_fade_dur = 0.10;
    }
}

struct PoseFade {
    std::string name;
    double release_t{-1};
    std::pair<std::string, float> step(const std::string& want) {
        if (!want.empty()) {
            name = want;
            release_t = -1;
            return {want, 1.0f};
        }
        if (name.empty()) {
            return {{}, 0.0f};
        }
        if (release_t < 0) {
            release_t = re4vr::now();
        }
        const float dur = (float)RE4VRShared::get()->re4_pose_fade_dur.value_or(0.10);
        const float el = (float)(re4vr::now() - release_t);
        if (el >= dur) {
            name.clear();
            return {{}, 0.0f};
        }
        return {name, 1.0f - el / dur};
    }
};

struct SlidePose {
    float rest_z{0.06174f}, park_z{0.04674f}, back_z{0.03174f};
    float dock_x{0}, dock_y{0}, dock_z{0}, rack_rx{0}, rack_ry{0}, rack_rz{0};
    float sdock_x{0.077f}, sdock_y{-0.008f}, sdock_z{-0.056f};
    float srack_rx{4.7f}, srack_ry{153.7f}, srack_rz{-37.6f};
};
struct MagHand {
    float x{0}, y{0}, z{0}, rx{0}, ry{0}, rz{0}, t_rx{0}, t_ry{0}, t_rz{0};
};
struct ShellEject {
    float sx{0}, sy{0}, sz{0}, srx{0}, sry{0}, srz{0};
    float vx{0.8f}, vy{0.5f}, vz{0}, grav{4}, dur{0.7f}, spin{540};
};
struct Snd {
    uint32_t dry_fire{0}, mag_eject{0}, mag_insert{0}, mag_floor{0}, slide_back{0}, mag_holster{0};
    uint32_t cycle{0}, break_open{0}, chamber{0};
};

inline void load_slide_json(SlidePose& sp, const nlohmann::json& v) {
    if (!v.is_object()) {
        return;
    }
    sp.rest_z = re4vr::j_num(v, "rest_z", sp.rest_z);
    sp.park_z = re4vr::j_num(v, "park_z", sp.park_z);
    sp.back_z = re4vr::j_num(v, "back_z", sp.back_z);
    sp.dock_x = re4vr::j_num(v, "dock_x", sp.dock_x);
    sp.dock_y = re4vr::j_num(v, "dock_y", sp.dock_y);
    sp.dock_z = re4vr::j_num(v, "dock_z", sp.dock_z);
    sp.rack_rx = re4vr::j_num(v, "rack_rx", sp.rack_rx);
    sp.rack_ry = re4vr::j_num(v, "rack_ry", sp.rack_ry);
    sp.rack_rz = re4vr::j_num(v, "rack_rz", sp.rack_rz);
    sp.sdock_x = re4vr::j_num(v, "sdock_x", sp.sdock_x);
    sp.sdock_y = re4vr::j_num(v, "sdock_y", sp.sdock_y);
    sp.sdock_z = re4vr::j_num(v, "sdock_z", sp.sdock_z);
    sp.srack_rx = re4vr::j_num(v, "srack_rx", sp.srack_rx);
    sp.srack_ry = re4vr::j_num(v, "srack_ry", sp.srack_ry);
    sp.srack_rz = re4vr::j_num(v, "srack_rz", sp.srack_rz);
}
inline void load_maghand_json(MagHand& m, const nlohmann::json& v) {
    if (!v.is_object()) {
        return;
    }
    m.x = re4vr::j_num(v, "x", m.x);
    m.y = re4vr::j_num(v, "y", m.y);
    m.z = re4vr::j_num(v, "z", m.z);
    m.rx = re4vr::j_num(v, "rx", m.rx);
    m.ry = re4vr::j_num(v, "ry", m.ry);
    m.rz = re4vr::j_num(v, "rz", m.rz);
    m.t_rx = re4vr::j_num(v, "t_rx", m.t_rx);
    m.t_ry = re4vr::j_num(v, "t_ry", m.t_ry);
    m.t_rz = re4vr::j_num(v, "t_rz", m.t_rz);
}

inline HookManager::PreHookResult skip_if(bool skip) {
    return skip ? HookManager::PreHookResult::SKIP_ORIGINAL : HookManager::PreHookResult::CALL_ORIGINAL;
}

inline void wrap_smih(sol::state&, std::function<std::optional<bool>(bool)> handler) {
    RE4VRShared::get()->mag_in_hand_handlers.push_back(std::move(handler));
}
} // namespace re4vr::rl
#endif
