#define NOMINMAX
#include "RE4VRGestures.hpp"

#if defined(RE4)
#include <algorithm>
#include <cmath>
#include <ctime>
#include <random>
#include <unordered_set>

#include <glm/gtc/constants.hpp>
#include <sdk/RETypeDB.hpp>
#include <sdk/RETransform.hpp>
#include <sdk/REContext.hpp>
#include <sdk/MurmurHash.hpp>
#include <sdk/Application.hpp>
#include <sdk/SystemArray.hpp>

#include "RE4VRShared.hpp"
#include "../../../ScriptRunner.hpp"

namespace {
constexpr float LERP_IN = 0.18f;
constexpr float HOLD = 2.50f;
constexpr float LERP_OUT = 0.30f;
constexpr float STAGGER_HOLD = 0.50f;
constexpr float STAGGER_REACH = 30.0f;
constexpr int STAGGER_MAX = 16;
constexpr uint32_t FLASH_KEYHASH = 2056866634u;
const char* POSE_ORDER[] = {"point", "fuck_you"};
const char* FINGERS[] = {"R_Index", "R_Middle", "R_Ring", "R_Pinky"};
const char* LEON_BODY = "ch0a0z0_body";
const std::unordered_set<uint32_t> TAUNT_SKIP{2778708114u, 3778512958u, 3878582777u};

int axis_of(const std::string& jn) {
    if (jn == "R_Thumb1") {
        return 1; // x
    }
    if (jn == "R_Thumb2" || jn == "R_Thumb3") {
        return 2; // y
    }
    return 3; // z
}

glm::quat deg_to_quat(float d, const std::string& jn) {
    const float r = glm::radians(d) * 0.5f;
    glm::quat q{std::cos(r), 0.0f, 0.0f, 0.0f};
    const float s = std::sin(r);
    const int ax = axis_of(jn);
    if (ax == 1) {
        q.x = s;
    } else if (ax == 2) {
        q.y = s;
    } else {
        q.z = s;
    }
    return q;
}

float quat_to_deg(const nlohmann::json& v, const std::string& jn) {
    if (!v.is_array() || v.size() < 4) {
        return 0.0f;
    }
    const float w = v[0].is_number() ? v[0].get<float>() : 1.0f;
    const int ax = axis_of(jn);
    const float c = (ax < (int)v.size() && v[ax].is_number()) ? v[ax].get<float>() : 0.0f;
    return glm::degrees(2.0f * std::atan2(c, w));
}

glm::quat twist_quat(float d) {
    const float r = glm::radians(d) * 0.5f;
    return glm::quat{std::cos(r), std::sin(r), 0.0f, 0.0f};
}

std::vector<std::string> joint_names() {
    std::vector<std::string> t{"R_Palm"};
    for (const auto* f : FINGERS) {
        for (int i = 1; i <= 3; ++i) {
            t.push_back(std::string{f} + "F" + std::to_string(i));
        }
    }
    for (int i = 1; i <= 3; ++i) {
        t.push_back(std::string{"R_Thumb"} + std::to_string(i));
    }
    return t;
}

template <typename T>
void set_field(void* obj, const char* name, T v) {
    if (auto* f = sdk::get_object_field<T>(obj, name)) {
        *f = v;
    }
}
}

std::shared_ptr<RE4VRGestures>& RE4VRGestures::get() {
    static auto inst = std::make_shared<RE4VRGestures>();
    return inst;
}

void RE4VRGestures::rebuild(const std::string& name) {
    auto& bones = m_poses[name];
    bones.clear();
    for (const auto& jn : joint_names()) {
        bones[jn] = deg_to_quat(m_deg[name][jn], jn);
    }
    for (const auto* f : FINGERS) {
        const float r = m_rot[name][f];
        if (r == 0.0f) {
            continue;
        }
        const std::string base = std::string{f} + "F1";
        bones[base] = bones[base] * twist_quat(r);
    }
}

void RE4VRGestures::load_poses() {
    const auto d = re4vr::load_json_file("re4_vr/re4_vr_guestures.json");
    nlohmann::json poses = nlohmann::json::object();
    if (d.contains("poses") && d["poses"].is_object()) {
        poses = d["poses"];
    }
    m_deg.clear();
    m_rot.clear();
    m_poses.clear();
    const auto joints = joint_names();
    for (const auto* name : POSE_ORDER) {
        nlohmann::json entry = nlohmann::json::object();
        if (poses.contains(name) && poses[name].is_object()) {
            entry = poses[name];
        }
        nlohmann::json src = nlohmann::json::object();
        if (entry.contains("bones") && entry["bones"].is_object()) {
            src = entry["bones"];
        }
        for (const auto& jn : joints) {
            m_deg[name][jn] = src.contains(jn) ? quat_to_deg(src[jn], jn) : 0.0f;
        }
        nlohmann::json rot = nlohmann::json::object();
        if (entry.contains("rot") && entry["rot"].is_object()) {
            rot = entry["rot"];
        }
        for (const auto* f : FINGERS) {
            m_rot[name][f] = rot.contains(f) && rot[f].is_number() ? rot[f].get<float>() : 0.0f;
        }
        rebuild(name);
    }
}

bool RE4VRGestures::hands_free() {
    const auto kh = re4vr::lua_string("__re4_knife_hand");
    if (kh && *kh == "right") {
        return false;
    }
    if (re4vr::lua_is_true("__vr_bare_hands")) {
        return true;
    }
    if (re4vr::lua_is_true("__re4_knife_equipped") && kh && *kh == "left") {
        return true;
    }
    return false;
}

void RE4VRGestures::start(const std::string& name) {
    if (m_poses.empty()) {
        load_poses();
    }
    if (!m_poses.count(name)) {
        return;
    }
    m_active_name = name;
    m_active_t0 = re4vr::lua_os_clock();
}

std::optional<float> RE4VRGestures::blend_now() {
    if (!m_active_name) {
        return std::nullopt;
    }
    const float e = (float)(re4vr::lua_os_clock() - m_active_t0);
    if (e >= (LERP_IN + HOLD + LERP_OUT)) {
        return std::nullopt;
    }
    if (e < LERP_IN) {
        return e / LERP_IN;
    }
    if (e < LERP_IN + HOLD) {
        return 1.0f;
    }
    const float f = 1.0f - ((e - LERP_IN - HOLD) / LERP_OUT);
    return f > 0.0f ? f : 0.0f;
}

void RE4VRGestures::apply() {
    if (!m_active_name) {
        return;
    }
    if (!hands_free() || !re4vr::lua_is_true("__re4_frame_pure_gameplay")) {
        m_active_name.reset();
        return;
    }
    const auto b = blend_now();
    if (!b) {
        m_active_name.reset();
        return;
    }
    re4vr::apply_pose_bones(m_poses[*m_active_name], *b);
}

::REManagedObject* RE4VRGestures::pin(::REManagedObject* o) {
    if (re4vr::obj_ok(o)) {
        utility::re_managed_object::add_ref(o);
    }
    return o;
}

::REManagedObject* RE4VRGestures::flash_ud() {
    if (m_ud) {
        return m_ud;
    }
    auto* td = sdk::find_type_definition("chainsaw.collision.AttackUserData");
    if (!td) {
        return nullptr;
    }
    auto* u = td->create_instance_full(true);
    if (!u) {
        return nullptr;
    }
    set_field<int32_t>(u, "_AttackHitDataID", 2);
    set_field<uint32_t>(u, "_KeyNameHash", FLASH_KEYHASH);
    if (auto* f = sdk::get_object_field<int32_t>(u, "<AttackID>k__BackingField")) {
        *f = 26;
    }
    m_ud = pin(u);
    return m_ud;
}

::REManagedObject* RE4VRGestures::flash_table() {
    if (m_tbl) {
        return m_tbl;
    }
    auto* ahu_td = sdk::find_type_definition("chainsaw.collision.AttackHitUserData");
    auto* ad_td = sdk::find_type_definition("chainsaw.collision.AttackHitUserData.AttackData");
    if (!ahu_td || !ad_td) {
        return nullptr;
    }
    auto* ahu = ahu_td->create_instance_full(true);
    auto* ad = ad_td->create_instance_full(true);
    auto* arr = sdk::VM::create_managed_array(ad_td->get_runtime_type(), 1);
    if (!ahu || !ad || !arr) {
        return nullptr;
    }
    pin(ahu);
    pin(ad);
    pin((::REManagedObject*)arr);
    set_field<uint32_t>(ad, "_KeyNameHash", FLASH_KEYHASH);
    set_field<int32_t>(ad, "_Damage", 0);
    set_field<bool>(ad, "_IsPartnerDamage", true);
    set_field<int32_t>(ad, "_AttackType", 15);
    set_field<int32_t>(ad, "_AttackPower", 1);
    set_field<int32_t>(ad, "_DeadType", 1);
    set_field<int32_t>(ad, "_Priority", 0);
    set_field<int32_t>(ad, "_SortType", 1);
    set_field<int32_t>(ad, "_Option", 0);
    set_field<float>(ad, "_IntervalTime", 0.0f);
    set_field<int32_t>(ad, "_Enchant", 0);
    set_field<bool>(ad, "_IsThroughRestriction", false);
    set_field<int32_t>(ad, "_ThroughNum", 1);
    set_field<int32_t>(ad, "_DirectionType", 2);
    set_field<bool>(ad, "_IsShieldingDecision", true);
    set_field<bool>(ad, "_EnableBackFacingHits", false);
    set_field<int32_t>(ad, "_ShieldingDecisioningType", 3);
    set_field<uint32_t>(ad, "_JointNameHash", 2180083513u);
    set_field<bool>(ad, "_Mute", true);
    set_field<uint32_t>(ad, "_SoundTriggerId", 4294967295u);
    set_field<bool>(ad, "_MuteEffect", false);
    set_field<bool>(ad, "_CheckEffectCollision", false);
    set_field<bool>(ad, "_IsEmitEffect", false);
    set_field<int32_t>(ad, "_AxisType", 0);
    set_field<float>(ad, "_EffectCheckInterval", 0.0f);
    set_field<bool>(ad, "_CheckRigidBody", false);
    set_field<int32_t>(ad, "_DefaultThroughNum", 1);
    re4vr::pcall([&] { ((sdk::SystemArray*)arr)->set_element(0, ad); });
    if (auto* f = sdk::get_object_field<::REManagedObject*>(ahu, "_AttackDataList")) {
        *f = (::REManagedObject*)arr;
    } else {
        return nullptr;
    }
    m_tbl = ahu;
    return m_tbl;
}

::REManagedObject* RE4VRGestures::dmg_ud() {
    if (m_dmg) {
        return m_dmg;
    }
    auto* td = sdk::find_type_definition("chainsaw.collision.DamageUserData");
    if (!td) {
        return nullptr;
    }
    m_dmg = pin(td->create_instance_full(true));
    return m_dmg;
}

void RE4VRGestures::fire_stagger() {
    if (!m_stagger_enabled) {
        return;
    }
    auto* cm = re4vr::character_manager();
    auto* go = re4vr::body_game_object();
    auto* tf = re4vr::body_transform();
    if (!cm || !go || !tf) {
        return;
    }
    auto* hm = sdk::get_managed_singleton<::REManagedObject>("chainsaw.HitManager");
    if (!hm) {
        return;
    }
    auto* hc = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(hm, "getHitController", go); }).value_or(nullptr);
    if (!re4vr::obj_ok(hc)) {
        return;
    }
    const auto ppos = sdk::get_transform_position(tf);
    auto* ud = flash_ud();
    auto* tbl = flash_table();
    auto* dmg = dmg_ud();
    if (!ud || !tbl || !dmg) {
        return;
    }
    auto* hud = sdk::get_object_field<::REManagedObject*>(hc, "_UserData");
    if (!hud || !*hud) {
        return;
    }
    auto* oldp = sdk::get_object_field<::REManagedObject*>(*hud, "_AttackHitUserData");
    if (oldp && *oldp) {
        auto* lst = sdk::get_object_field<::REManagedObject*>(*oldp, "_AttackDataList");
        int n = 0;
        if (lst && *lst) {
            n = (int)re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(*lst, "get_Length"); }).value_or(0);
            if (n == 0) {
                n = (int)((sdk::SystemArray*)*lst)->get_size();
            }
        }
        if (n != 1) {
            return;
        }
    }
    if (auto* f = sdk::get_object_field<::REManagedObject*>(*hud, "_AttackHitUserData")) {
        *f = tbl;
    } else {
        return;
    }

    auto* list = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(cm, "get_EnemyContextList"); }).value_or(nullptr);
    const int count = list ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(list, "get_Count"); }).value_or(0) : 0;
    int hits = 0;
    for (int i = 0; i < count && hits < STAGGER_MAX; ++i) {
        auto* ectx = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(list, "get_Item", i); }).value_or(nullptr);
        if (!ectx) {
            continue;
        }
        auto* hp = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ectx, "get_HitPoint"); }).value_or(nullptr);
        if (!hp) {
            continue;
        }
        const bool dead = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(hp, "get_IsDead"); }).value_or(false);
        const auto chp = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(hp, "get_CurrentHitPoint"); }).value_or(0);
        if (dead || chp <= 0) {
            continue;
        }
        auto pos = re4vr::safe([&] { return sdk::call_object_func_easy<Vector4f>(ectx, "get_Position"); });
        auto* ego = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(ectx, "get_BodyGameObject"); }).value_or(nullptr);
        if (!pos || !ego) {
            continue;
        }
        const float dx = pos->x - ppos.x, dy = pos->y - ppos.y, dz = pos->z - ppos.z;
        if (dx * dx + dy * dy + dz * dz > STAGGER_REACH * STAGGER_REACH) {
            continue;
        }
        const bool was = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(hc, "get_AttackEnable"); }).value_or(false);
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(hc, "set_AttackEnable", true); });
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(hc, "requestAttack", ego, ud, dmg); });
        if (!was) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(hc, "set_AttackEnable", false); });
        }
        ++hits;
    }
    if (auto* f = sdk::get_object_field<::REManagedObject*>(*hud, "_AttackHitUserData")) {
        *f = nullptr;
    }
}

void RE4VRGestures::taunt_load() {
    m_taunt_pools.clear();
    m_taunt_bags.clear();
    if (!m_taunt_seeded) {
        m_taunt_seeded = true;
        std::srand((unsigned)std::time(nullptr));
    }
    const auto d = re4vr::load_json_file("re4_vr/re4_vr_voice.json");
    if (!d.contains("entries") || !d["entries"].is_array()) {
        return;
    }
    for (const auto& m : d["entries"]) {
        if (!m.is_object()) {
            continue;
        }
        const uint32_t id = (uint32_t)re4vr::j_num(m, "id", 0.0f);
        std::string lab;
        if (m.contains("label") && m["label"].is_string()) {
            lab = m["label"].get<std::string>();
        }
        if (id == 0 || lab.empty()) {
            continue;
        }
        if (lab == LEON_BODY && TAUNT_SKIP.count(id)) {
            continue;
        }
        m_taunt_pools[lab].push_back(id);
    }
}

std::optional<uint32_t> RE4VRGestures::taunt_next(const std::string& body) {
    if (m_taunt_pools.empty()) {
        taunt_load();
    }
    auto pit = m_taunt_pools.find(body);
    if (pit == m_taunt_pools.end() || pit->second.empty()) {
        return std::nullopt;
    }
    auto& bag = m_taunt_bags[body];
    if (bag.empty()) {
        bag = pit->second;
        std::shuffle(bag.begin(), bag.end(), std::mt19937{std::random_device{}()});
    }
    const uint32_t id = bag.back();
    bag.pop_back();
    return id;
}

void RE4VRGestures::play_taunt() {
    if (!m_taunt_enabled) {
        return;
    }
    auto* go = re4vr::body_game_object();
    if (!go) {
        return;
    }
    const auto nm = re4vr::go_name((::REManagedObject*)go);
    auto id = taunt_next(nm);
    if (!id) {
        return;
    }
    auto* con = re4vr::get_component((::REManagedObject*)go, "soundlib.SoundContainer");
    if (!con) {
        return;
    }
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(con, "trigger(System.UInt32)", *id); });
}

std::optional<std::string> RE4VRGestures::on_initialize() {
    load_poses();
    taunt_load();
    return std::nullopt;
}

void RE4VRGestures::on_lua_state_created(sol::state& lua) {
    re4vr::export_pose_api(lua);
    load_poses();
    taunt_load();
}

void RE4VRGestures::on_lua_state_destroyed(sol::state&) {
    m_active_name.reset();
    m_hold_t0.reset();
    m_ud = m_tbl = m_dmg = nullptr;
}

void RE4VRGestures::on_frame() {
    ScriptProfileGuard guard("re4_vr_guestures.lua", "on_frame", re4vr::profile_frame());
    if (auto fire = re4vr::lua_string("__re4_gesture_fire")) {
        re4vr::lua_set_nil("__re4_gesture_fire");
        if (hands_free() && re4vr::lua_is_true("__re4_frame_pure_gameplay")) {
            start(*fire);
            play_taunt();
        }
    } else {
        re4vr::LuaGuard g;
        if (auto* L = g.lua()) {
            sol::object o = (*L)["__re4_gesture_fire"];
            if (o.get_type() != sol::type::nil && o.get_type() != sol::type::none) {
                if (o.is<std::string>()) {
                    re4vr::lua_set_nil("__re4_gesture_fire");
                    if (hands_free() && re4vr::lua_is_true("__re4_frame_pure_gameplay")) {
                        start(o.as<std::string>());
                        play_taunt();
                    }
                }
            }
        }
    }

    const bool gate = re4vr::lua_is_true("__re4_frame_pure_gameplay") && hands_free();
    std::optional<std::string> g;
    if (gate) {
        g = re4vr::lua_string("__re4_gest_prev");
    }
    if (!g || *g != "fuck_you") {
        m_hold_t0.reset();
        m_hold_fired = false;
    } else {
        const double now = re4vr::lua_os_clock();
        if (!m_hold_t0) {
            m_hold_t0 = now;
            m_hold_fired = false;
        }
        if (!m_hold_fired && (now - *m_hold_t0) >= STAGGER_HOLD) {
            m_hold_fired = true;
            fire_stagger();
        }
    }
}

void RE4VRGestures::on_pre_application_entry(void*, const char*, size_t hash) {
    if (hash != "LockScene"_fnv && hash != "BeginRendering"_fnv) {
        return;
    }
    ScriptProfileGuard guard("re4_vr_guestures.lua",
        hash == "LockScene"_fnv ? "on_pre_application_entry:LockScene" : "on_pre_application_entry:BeginRendering",
        re4vr::profile_frame());
    apply();
}

void RE4VRGestures::on_application_entry(void*, const char*, size_t hash) {
    if (hash != "LateUpdateBehavior"_fnv && hash != "UpdateJointExpression"_fnv) {
        return;
    }
    ScriptProfileGuard guard("re4_vr_guestures.lua",
        hash == "LateUpdateBehavior"_fnv ? "on_application_entry:LateUpdateBehavior" : "on_application_entry:UpdateJointExpression",
        re4vr::profile_frame());
    apply();
}
#endif
