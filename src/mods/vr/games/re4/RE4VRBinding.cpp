#define NOMINMAX
#include "RE4VRBinding.hpp"

#if defined(RE4)
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

#include <glm/gtc/constants.hpp>
#include <glm/gtx/quaternion.hpp>
#include <imgui.h>
#include <spdlog/spdlog.h>
#include <sdk/SceneManager.hpp>
#include <sdk/RETypeDB.hpp>
#include <sdk/REString.hpp>
#include <sdk/REGameObject.hpp>
#include <sdk/MurmurHash.hpp>
#include <sdk/Application.hpp>
#include <utility/String.hpp>

#include "RE4VRFrameCache.hpp"
#include "RE4VRMenu.hpp"
#include "RE4VRShared.hpp"
#include "../../../ScriptRunner.hpp"
#include "../../runtimes/VRRuntime.hpp"

namespace {
constexpr int EDGE_HOLD_FRAMES = 4;
constexpr int GRENADE_COOLDOWN_FRAMES = 60;
constexpr int START_HOLD_FRAMES = 20;
constexpr float COMBO_GRACE_SEC = 0.15f;
constexpr float DUAL_TRIGGER_HOLD_SEC = 2.0f;
constexpr float EE_FLAME_HOLD_SEC = 5.0f;
constexpr int32_t EE_FLAME_SOUND = 764414311;
constexpr int32_t EE_FLAME_ITEM_ID = 275957056;
constexpr int32_t REFUI_SOUND = 801086617;
constexpr uint64_t BATTLE_FLAG = 0x1000000000000000ULL;
constexpr int DODGE_GMK_PRIO = 23;
constexpr int DODGE_GMK_CAMTYPE = 5;
constexpr float SCOPE_GRIP_AIM_DELAY = 0.08f;

struct AdaZone {
    int32_t stage{0};
    float x{0}, y{0}, z{0}, r{3.0f};
};

const AdaZone k_ada_raw_zones[] = {
    {44210, -0.06f, -0.81f, 181.36f, 3.0f},
    {51859, -29.79f, 6.20f, -2.30f, 3.0f},
    {51504, -33.42f, 28.89f, -69.48f, 3.0f},
    {55852, 116.22f, -29.01f, -69.86f, 3.0f},
    {56104, 207.78f, 50.29f, -94.80f, 3.0f},
    {60870, 25.75f, 1.44f, 248.27f, 3.0f},
    {60880, 40.14f, -3.66f, 260.06f, 3.0f},
};

float clampf(float v, float a, float b) {
    return v < a ? a : (v > b ? b : v);
}

int32_t resolve_static_enum(const char* type_name, const char* field, int32_t fallback) {
    auto* t = sdk::find_type_definition(type_name);
    if (!t) {
        return fallback;
    }
    for (auto* fld : t->get_fields()) {
        if (fld && fld->is_static() && std::string{fld->get_name()} == field) {
            return fld->get_data<int32_t>(nullptr);
        }
    }
    return fallback;
}

bool lua_nil_or_missing(sol::state& lua, const char* name) {
    sol::object o = lua[name];
    return !o.valid() || o.get_type() == sol::type::nil || o.get_type() == sol::type::none;
}
}

std::shared_ptr<RE4VRBinding>& RE4VRBinding::get() {
    static auto inst = std::make_shared<RE4VRBinding>();
    return inst;
}

double RE4VRBinding::now_clock() const {
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - m_clock_origin).count();
}

void RE4VRBinding::load_json() {
    const auto d = re4vr::load_json_file("re4_vr/re4_vr_bindings.json");
    m_prefs.hide_ref_overlay = re4vr::j_bool(d, "hide_ref_overlay", m_prefs.hide_ref_overlay);
    m_prefs.long_press_sec = re4vr::j_num(d, "long_press_sec", m_prefs.long_press_sec);
    m_prefs.short_min_sec = re4vr::j_num(d, "short_min_sec", m_prefs.short_min_sec);
    m_prefs.enable_180_rotation = re4vr::j_bool(d, "enable_180_rotation", m_prefs.enable_180_rotation);
    m_prefs.turn180_window_sec = re4vr::j_num(d, "turn180_window_sec", m_prefs.turn180_window_sec);
    m_prefs.turn180_ly_sec = re4vr::j_num(d, "turn180_ly_sec", m_prefs.turn180_ly_sec);
    m_prefs.turn180_rb_sec = re4vr::j_num(d, "turn180_rb_sec", m_prefs.turn180_rb_sec);
    m_prefs.enable_snapturn = re4vr::j_bool(d, "enable_snapturn", m_prefs.enable_snapturn);
    m_prefs.snapturn_deg = re4vr::j_num(d, "snapturn_deg", m_prefs.snapturn_deg);
    m_prefs.snapturn_thresh = re4vr::j_num(d, "snapturn_thresh", m_prefs.snapturn_thresh);
    m_prefs.turn180_sec = re4vr::j_num(d, "turn180_sec", m_prefs.turn180_sec);
}

void RE4VRBinding::save_json() {
    nlohmann::json out;
    out["hide_ref_overlay"] = m_prefs.hide_ref_overlay;
    out["long_press_sec"] = m_prefs.long_press_sec;
    out["short_min_sec"] = m_prefs.short_min_sec;
    out["enable_180_rotation"] = m_prefs.enable_180_rotation;
    out["turn180_window_sec"] = m_prefs.turn180_window_sec;
    out["turn180_ly_sec"] = m_prefs.turn180_ly_sec;
    out["turn180_rb_sec"] = m_prefs.turn180_rb_sec;
    out["enable_snapturn"] = m_prefs.enable_snapturn;
    out["snapturn_deg"] = m_prefs.snapturn_deg;
    out["snapturn_thresh"] = m_prefs.snapturn_thresh;
    out["turn180_sec"] = m_prefs.turn180_sec;
    re4vr::save_json_file("re4_vr/re4_vr_bindings.json", out);
}

void RE4VRBinding::draw_snapturn_ui(const char* sfx) {
    std::string id = std::string("Enable Snapturn##st") + sfx;
    bool v = m_prefs.enable_snapturn;
    if (ImGui::Checkbox(id.c_str(), &v)) {
        m_prefs.enable_snapturn = v;
        save_json();
    }
    if (!m_prefs.enable_snapturn) {
        return;
    }
    for (int d : {30, 45, 90}) {
        const bool active = (int)m_prefs.snapturn_deg == d;
        char lab[32];
        std::snprintf(lab, sizeof(lab), "%d deg##st%s", d, sfx);
        if (active) {
            ImGui::PushStyleColor(ImGuiCol_Text, IM_COL32(255, 165, 0, 255));
        }
        if (ImGui::Button(lab)) {
            m_prefs.snapturn_deg = (float)d;
            save_json();
        }
        if (active) {
            ImGui::PopStyleColor(1);
        }
        ImGui::SameLine();
    }
    ImGui::NewLine();
    float thr = m_prefs.snapturn_thresh;
    if (ImGui::SliderFloat((std::string("Snapturn stick threshold##st") + sfx).c_str(), &thr, 0.30f, 0.99f, "%.2f")) {
        m_prefs.snapturn_thresh = thr;
        save_json();
    }
}

void RE4VRBinding::register_ui() {
    if (m_ui_registered) {
        return;
    }
    m_ui_registered = true;
    RE4VRMenu::get()->add(60, "binding_180turn", [this]() {
        bool v = m_prefs.enable_180_rotation;
        if (ImGui::Checkbox("Enable 180 degree turn", &v)) {
            m_prefs.enable_180_rotation = v;
            if (!v) {
                qt_reset();
            }
            save_json();
        }
        draw_snapturn_ui("pub");
        re4vr::LuaGuard g;
        auto* L = g.lua();
        if (!L) {
            return;
        }
        sol::object getter = (*L)["__re4_roomscale_get"];
        sol::object setter = (*L)["__re4_roomscale_set"];
        if (getter.is<sol::protected_function>() && setter.is<sol::protected_function>()) {
            auto r = getter.as<sol::protected_function>()();
            bool rs = r.valid() && r.get_type() == sol::type::boolean && r.get<bool>();
            if (ImGui::Checkbox("Enable Roomscale", &rs)) {
                setter.as<sol::protected_function>()(rs);
            }
        }
    });
}

void RE4VRBinding::reset_runtime() {
    m_inited = false;
    m_prev_l_grip = false;
    m_grenade_throw_cooldown = 0;
    m_grenade_rt_pulse_frames = 0;
    m_prev_vr_grenade_throw = false;
    m_la = {};
    m_was_active = false;
    m_lt_b_overlay_was = false;
    m_ref_overlay_synced = false;
    m_ref_overlay_tick = 0;
    qt_reset();
    m_dual_trigger_start_clock.reset();
    m_dual_trigger_fired = false;
    m_dual_trigger_gap_clock.reset();
    m_start_hold_timer = 0;
    m_ee_flame_clock.reset();
    m_ee_flame_fired = false;
    m_ee_flame_gap_clock.reset();
    m_edge_r_a = m_edge_r_b = m_edge_r_jc = m_edge_l_a_b = {};
    m_gui_manager = m_attache_case = m_map_manager = m_pause_manager = m_armoury_manager = nullptr;
}

bool RE4VRBinding::ks_active() {
    return re4vr::call_killswitch_bool("is_active", re4vr::lua_is_true("__re4_ks_active"));
}

bool RE4VRBinding::ks2() {
    return re4vr::call_killswitch_bool("is_ks2");
}

bool RE4VRBinding::ks4() {
    return re4vr::call_killswitch_bool("is_ks4");
}

::REManagedObject* RE4VRBinding::busy_controller() {
    re4vr::LuaGuard g;
    auto* L = g.lua();
    if (L) {
        sol::object loaded = (*L)["package"]["loaded"]["re4vr/re4_vr_killswitch"];
        if (loaded.is<sol::table>()) {
            sol::protected_function f = loaded.as<sol::table>()["get_busy_controller"];
            if (f.valid()) {
                auto r = f();
                if (r.valid() && r.is<::REManagedObject*>()) {
                    auto* p = r.get<::REManagedObject*>();
                    if (re4vr::obj_ok(p)) {
                        return p;
                    }
                }
            }
        }
    }
    auto* cs = sdk::get_managed_singleton<::REManagedObject>("chainsaw.CameraSystem");
    auto* main = cs ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(cs, "get_MainCameraController"); }).value_or(nullptr) : nullptr;
    return main ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(main, "get_BusyCameraController"); }).value_or(nullptr) : nullptr;
}

int32_t RE4VRBinding::resolve_enum(const char* type_name, const char* field, int32_t fallback) {
    return resolve_static_enum(type_name, field, fallback);
}

bool RE4VRBinding::digital(uint64_t action, uint64_t hand) const {
    if (!action || !hand) {
        return false;
    }
    return VR::get()->is_action_active((vr::VRActionHandle_t)action, (vr::VRInputValueHandle_t)hand);
}

void RE4VRBinding::vigem_init() {
    re4vr::LuaGuard g;
    auto* L = g.lua();
    if (!L) {
        return;
    }
    sol::object v = (*L)["vigem"];
    if (!v.is<sol::table>()) {
        return;
    }
    sol::protected_function init = v.as<sol::table>()["init"];
    if (init.valid()) {
        (void)init();
    }
}

void RE4VRBinding::vigem_axis(const char* n, float v) {
    re4vr::LuaGuard g;
    auto* L = g.lua();
    if (!L) {
        return;
    }
    sol::object vg = (*L)["vigem"];
    if (!vg.is<sol::table>()) {
        return;
    }
    sol::protected_function f = vg.as<sol::table>()["set_axis"];
    if (f.valid()) {
        (void)f(n, v);
    }
}

void RE4VRBinding::vigem_trigger(const char* n, float v) {
    re4vr::LuaGuard g;
    auto* L = g.lua();
    if (!L) {
        return;
    }
    sol::object vg = (*L)["vigem"];
    if (!vg.is<sol::table>()) {
        return;
    }
    sol::protected_function f = vg.as<sol::table>()["set_trigger"];
    if (f.valid()) {
        (void)f(n, v);
    }
}

void RE4VRBinding::vigem_button(const char* n, bool v) {
    re4vr::LuaGuard g;
    auto* L = g.lua();
    if (!L) {
        return;
    }
    sol::object vg = (*L)["vigem"];
    if (!vg.is<sol::table>()) {
        return;
    }
    sol::protected_function f = vg.as<sol::table>()["set_button"];
    if (f.valid()) {
        (void)f(n, v);
    }
}

void RE4VRBinding::overlay_set_enabled(bool on) {
    re4vr::LuaGuard g;
    auto* L = g.lua();
    if (!L) {
        return;
    }
    sol::object o = (*L)["overlay"];
    if (!o.is<sol::table>()) {
        return;
    }
    sol::protected_function f = o.as<sol::table>()["set_enabled"];
    if (f.valid()) {
        (void)f(on);
    }
}

void RE4VRBinding::overlay_tick() {
    re4vr::LuaGuard g;
    auto* L = g.lua();
    if (!L) {
        return;
    }
    sol::object o = (*L)["overlay"];
    if (!o.is<sol::table>()) {
        return;
    }
    sol::protected_function f = o.as<sol::table>()["tick"];
    if (f.valid()) {
        (void)f();
    }
}

bool RE4VRBinding::ensure_init() {
    if (m_inited) {
        return true;
    }
    auto& vr = VR::get();
    if (vr->get_controllers().size() < 2) {
        return false;
    }
    if (!vr->get_left_joystick() || !vr->get_right_joystick()) {
        return false;
    }
    re4vr::LuaGuard g;
    auto* L = g.lua();
    if (!L) {
        return false;
    }
    sol::object vg = (*L)["vigem"];
    if (!vg.is<sol::table>()) {
        return false;
    }
    sol::protected_function init = vg.as<sol::table>()["init"];
    if (!init.valid()) {
        return false;
    }
    auto r = init();
    if (!r.valid()) {
        return false;
    }
    bool ok = false;
    if (r.get_type() == sol::type::boolean) {
        ok = r.get<bool>();
    } else {
        ok = true;
    }
    if (!ok) {
        return false;
    }
    m_inited = true;
    return true;
}

::REManagedObject* RE4VRBinding::binding_cm() {
    if (RE4VRFrameCache::get()->on()) {
        return sdk::get_managed_singleton<::REManagedObject>("chainsaw.CharacterManager");
    }
    return sdk::get_managed_singleton<::REManagedObject>("chainsaw.CharacterManager");
}

::REManagedObject* RE4VRBinding::binding_ctx() {
    if (RE4VRFrameCache::get()->on()) {
        return RE4VRFrameCache::get()->ctx();
    }
    auto* cm = binding_cm();
    if (!cm) {
        return nullptr;
    }
    return re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(cm, "getPlayerContextRef"); }).value_or(nullptr);
}

std::optional<int32_t> RE4VRBinding::equip_wid() {
    if (RE4VRFrameCache::get()->on()) {
        auto w = RE4VRFrameCache::get()->equip_wid();
        if (w && *w != 0) {
            return w;
        }
        return std::nullopt;
    }
    auto* ctx = binding_ctx();
    if (!re4vr::obj_ok(ctx)) {
        return std::nullopt;
    }
    auto* hu = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_HeadUpdater"); }).value_or(nullptr);
    if (!re4vr::obj_ok(hu)) {
        return std::nullopt;
    }
    auto w = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(hu, "get_EquipWeaponID"); });
    if (!w || *w == 0) {
        return std::nullopt;
    }
    return w;
}

bool RE4VRBinding::grenade_equipped_live() {
    auto w = equip_wid();
    return w && *w >= 5400 && *w <= 5410;
}

bool RE4VRBinding::player_in_grapple() {
    auto* ctx = binding_ctx();
    if (!re4vr::obj_ok(ctx)) {
        return false;
    }
    return re4vr::safe([&] { return sdk::call_object_func_easy<bool>(ctx, "get_IsInGrappleDamage"); }).value_or(false);
}

bool RE4VRBinding::player_in_battle() {
    auto* ctx = binding_ctx();
    if (!re4vr::obj_ok(ctx)) {
        return false;
    }
    auto st = re4vr::safe([&] { return sdk::call_object_func_easy<int64_t>(ctx, "get_State"); });
    if (!st) {
        auto st32 = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(ctx, "get_State"); });
        if (!st32) {
            return false;
        }
        return ((int64_t)*st32 & (int64_t)BATTLE_FLAG) != 0;
    }
    return (*st & (int64_t)BATTLE_FLAG) != 0;
}

bool RE4VRBinding::stage_parent_chain_has(const char* prefix) {
    auto* ctx = binding_ctx();
    if (!re4vr::obj_ok(ctx)) {
        return false;
    }
    auto stage = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(ctx, "get_CurrentStageID"); });
    auto space = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(ctx, "get_CurrentSpaceID"); });
    if (!stage || !space) {
        return false;
    }
    if (std::to_string(*stage) + "_" + std::to_string(*space) != "46900_46900") {
        return false;
    }
    auto* body = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(ctx, "get_BodyGameObject"); }).value_or(nullptr);
    auto* tf = body ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(body, "get_Transform"); }).value_or(nullptr) : nullptr;
    auto* current = tf;
    for (int i = 0; i < 10 && current; ++i) {
        auto* parent = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(current, "get_Parent"); }).value_or(nullptr);
        if (!parent) {
            return false;
        }
        auto* pgo = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(parent, "get_GameObject"); }).value_or(nullptr);
        const auto name = re4vr::go_name((::REManagedObject*)pgo);
        if (name.find(prefix) != std::string::npos) {
            return true;
        }
        current = parent;
    }
    return false;
}

bool RE4VRBinding::is_throwsight_stage() {
    return stage_parent_chain_has("gm02_500_00_1");
}

bool RE4VRBinding::is_boat_stage() {
    return stage_parent_chain_has("gm02_500_00_2");
}

bool RE4VRBinding::is_symbol_riddle() {
    auto* ctx = binding_ctx();
    if (!re4vr::obj_ok(ctx)) {
        return false;
    }
    auto st = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(ctx, "get_CurrentStageID"); });
    if (!st || (*st != 44110 && *st != 45401 && *st != 51503 && *st != 51502)) {
        return false;
    }
    auto* cs = sdk::get_managed_singleton<::REManagedObject>("chainsaw.CameraSystem");
    auto* main = cs ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(cs, "get_MainCameraController"); }).value_or(nullptr) : nullptr;
    auto* busy = main ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(main, "get_BusyCameraController"); }).value_or(nullptr) : nullptr;
    if (!re4vr::obj_ok(busy) || !m_gimmickfix_td) {
        return false;
    }
    auto* td = utility::re_managed_object::get_type_definition(busy);
    return td && td->is_a(m_gimmickfix_td);
}

bool RE4VRBinding::is_turret_mounted() {
    auto* busy = busy_controller();
    if (!re4vr::obj_ok(busy)) {
        return false;
    }
    auto* spp = sdk::get_object_field<::REManagedObject*>(busy, "_CurrentStateParam");
    auto* sp = spp ? *spp : nullptr;
    if (!re4vr::obj_ok(sp)) {
        return false;
    }
    int32_t gt = -1;
    if (auto* f = sdk::get_object_field<int32_t>(sp, "<GimmickType>k__BackingField")) {
        gt = *f;
    } else if (auto* boxed = sdk::get_object_field<::REManagedObject*>(sp, "<GimmickType>k__BackingField")) {
        if (*boxed) {
            if (auto* v = sdk::get_object_field<int32_t>(*boxed, "value__")) {
                gt = *v;
            }
        }
    }
    return gt == m_turret_gimmick;
}

bool RE4VRBinding::is_ada_raw_a_zone() {
    auto* ctx = binding_ctx();
    if (!re4vr::obj_ok(ctx)) {
        return false;
    }
    auto stage = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(ctx, "get_CurrentStageID"); });
    if (!stage) {
        return false;
    }
    auto* body = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(ctx, "get_BodyGameObject"); }).value_or(nullptr);
    auto* tf = body ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(body, "get_Transform"); }).value_or(nullptr) : nullptr;
    if (!tf) {
        return false;
    }
    const auto p4 = sdk::get_transform_position(tf);
    const Vector3f p{p4.x, p4.y, p4.z};
    std::vector<Zone> zones;
    for (auto& z : k_ada_raw_zones) {
        zones.push_back(Zone{z.stage, z.x, z.y, z.z, z.r});
    }
    re4vr::LuaGuard g;
    auto* L = g.lua();
    if (L) {
        sol::object zo = (*L)["__re4_ada_raw_a_zones"];
        if (zo.is<sol::table>()) {
            zones.clear();
            for (auto& kv : zo.as<sol::table>()) {
                if (!kv.second.is<sol::table>()) {
                    continue;
                }
                auto t = kv.second.as<sol::table>();
                Zone z;
                z.stage = (int32_t)t.get_or("stage", 0);
                z.x = (float)t.get_or("x", 0.0);
                z.y = (float)t.get_or("y", 0.0);
                z.z = (float)t.get_or("z", 0.0);
                z.r = (float)t.get_or("r", 3.0);
                zones.push_back(z);
            }
        }
    }
    for (auto& z : zones) {
        if (*stage != z.stage) {
            continue;
        }
        const float dx = p.x - z.x, dy = p.y - z.y, dz = p.z - z.z;
        if ((dx * dx + dy * dy + dz * dz) <= (z.r * z.r)) {
            return true;
        }
    }
    return false;
}

bool RE4VRBinding::is_mercs_active() {
    return re4vr::lua_is_true("__re4_in_mercs");
}

bool RE4VRBinding::is_ada_active() {
    re4vr::LuaGuard g;
    auto* L = g.lua();
    if (L) {
        sol::object fn = (*L)["__re4_char_now"];
        if (fn.is<sol::protected_function>()) {
            auto r = fn.as<sol::protected_function>()();
            if (r.valid() && r.get_type() == sol::type::string) {
                return r.get<std::string>() == "ada";
            }
        }
    }
    auto* ctx = binding_ctx();
    if (!re4vr::obj_ok(ctx)) {
        return false;
    }
    auto* body = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(ctx, "get_BodyGameObject"); }).value_or(nullptr);
    return re4vr::go_name((::REManagedObject*)body) == "ch3a8z0_body";
}

void RE4VRBinding::cache_menu_singletons() {
    if (!m_gui_manager) {
        m_gui_manager = sdk::get_managed_singleton<::REManagedObject>("chainsaw.GuiManager");
    }
    if (!m_attache_case) {
        m_attache_case = sdk::get_managed_singleton<::REManagedObject>("chainsaw.AttacheCaseManager");
    }
    if (!m_map_manager) {
        m_map_manager = sdk::get_managed_singleton<::REManagedObject>("chainsaw.MapManager");
    }
    if (!m_pause_manager) {
        m_pause_manager = sdk::get_managed_singleton<::REManagedObject>("share.PauseManager");
    }
    if (!m_armoury_manager) {
        m_armoury_manager = sdk::get_managed_singleton<::REManagedObject>("chainsaw.ArmouryManager");
    }
}

void RE4VRBinding::resolve_chapter_gui_enums() {
    if (m_chapter_resolved) {
        return;
    }
    m_chapter_resolved = true;
    static const char* names[] = {"ChapterEnd", "ChapterDetailResult", "ChapterDetailResultGuide", "ChapterStats", "GameClearResult"};
    for (auto* nm : names) {
        const int32_t v = resolve_static_enum("chainsaw.GuiType", nm, -1);
        if (v >= 0) {
            m_chapter_gui_vals.push_back(v);
        }
    }
    m_render_default = resolve_static_enum("chainsaw.RenderOutputType", "Default", 0);
}

void RE4VRBinding::resolve_file_reader_enums() {
    if (m_file_resolved) {
        return;
    }
    m_file_resolved = true;
    for (auto* nm : {"FileDetail", "FileSelect"}) {
        const int32_t v = resolve_static_enum("chainsaw.GuiType", nm, -1);
        if (v >= 0) {
            m_file_reader_gui_vals.push_back(v);
        }
    }
    resolve_chapter_gui_enums();
}

bool RE4VRBinding::is_chapter_result_gui_open() {
    if (!m_gui_manager) {
        return false;
    }
    resolve_chapter_gui_enums();
    for (auto gv : m_chapter_gui_vals) {
        if (re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_gui_manager, "isOpenGui", gv, m_render_default); }).value_or(false)) {
            return true;
        }
    }
    return false;
}

bool RE4VRBinding::is_file_reader_gui_open() {
    if (!m_gui_manager) {
        return false;
    }
    resolve_file_reader_enums();
    for (auto gv : m_file_reader_gui_vals) {
        if (re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_gui_manager, "isOpenGui", gv, m_render_default); }).value_or(false)) {
            return true;
        }
    }
    return false;
}

bool RE4VRBinding::is_any_menu_open(bool ignore_hud_off) {
    cache_menu_singletons();
    if (!re4vr::player_context() || !re4vr::body_game_object()) {
        return true;
    }
    if (m_pause_manager && re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_pause_manager, "isPaused()"); }).value_or(false)) {
        return true;
    }
    if (!ignore_hud_off && m_gui_manager && re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_gui_manager, "get_IsHudOff"); }).value_or(false)) {
        return true;
    }
    if (m_gui_manager && re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_gui_manager, "get_hasOccupiedPauseMenuSystemLock"); }).value_or(false)) {
        return true;
    }
    if (m_attache_case && re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_attache_case, "get_IsAttacheCaseBusy"); }).value_or(false)) {
        return true;
    }
    if (m_armoury_manager && re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_armoury_manager, "get_IsTypewriterWindow"); }).value_or(false)) {
        return true;
    }
    if (m_map_manager && re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_map_manager, "isMapGuiOpen"); }).value_or(false)) {
        return true;
    }
    if (is_chapter_result_gui_open() || is_file_reader_gui_open()) {
        return true;
    }
    return false;
}

bool RE4VRBinding::is_map_open_now() {
    if (!m_map_manager) {
        return false;
    }
    return re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_map_manager, "isMapGuiOpen"); }).value_or(false);
}

bool RE4VRBinding::is_binoculars_active() {
    auto* ctx = binding_ctx();
    if (!re4vr::obj_ok(ctx)) {
        return false;
    }
    auto* body = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(ctx, "get_BodyGameObject"); }).value_or(nullptr);
    auto* tf = body ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(body, "get_Transform"); }).value_or(nullptr) : nullptr;
    auto* child = tf ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(tf, "get_Child"); }).value_or(nullptr) : nullptr;
    int count = 0;
    while (child && count < 200) {
        ++count;
        auto* cgo = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(child, "get_GameObject"); }).value_or(nullptr);
        if (re4vr::go_name((::REManagedObject*)cgo) == "Binoculars") {
            return true;
        }
        child = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(child, "get_Next"); }).value_or(nullptr);
    }
    return false;
}

bool RE4VRBinding::is_binoculars_active_this_frame() {
    const auto frame = VR::get()->get_frame_count();
    re4vr::LuaGuard g;
    auto* L = g.lua();
    if (L) {
        sol::object c = (*L)["__re4_bino_scan_cache"];
        if (c.is<sol::table>()) {
            auto t = c.as<sol::table>();
            if (t.get_or("frame", -1) == frame) {
                return t.get_or("active", false);
            }
        }
        const bool active = is_binoculars_active();
        auto t = c.is<sol::table>() ? c.as<sol::table>() : L->create_table();
        t["frame"] = frame;
        t["active"] = active;
        (*L)["__re4_bino_scan_cache"] = t;
        return active;
    }
    return is_binoculars_active();
}

float RE4VRBinding::bino_val(const char* key, float fallback) {
    re4vr::LuaGuard g;
    auto* L = g.lua();
    if (!L) {
        return fallback;
    }
    sol::object c = (*L)["__re4_bino_cfg"];
    if (c.is<sol::table>()) {
        sol::object v = c.as<sol::table>()[key];
        if (v.get_type() == sol::type::number) {
            return v.as<float>();
        }
    }
    return fallback;
}

void RE4VRBinding::bino_zoom_tick() {
    const bool found = is_binoculars_active_this_frame();
    auto& vr = VR::get();
    if (found) {
        if (!m_bino.active) {
            m_bino.active = true;
            m_bino.offset = bino_val("start", m_bino.start_offset);
        }
        if (vr->is_hmd_active() && vr->is_using_controllers()) {
            const float stick_y = vr->get_left_stick_axis().y;
            if (std::abs(stick_y) > 0.1f) {
                m_bino.offset -= stick_y * bino_val("speed", m_bino.stick_speed) * 0.016f;
                m_bino.offset = clampf(m_bino.offset, bino_val("min", m_bino.min_offset), bino_val("max", m_bino.max_offset));
            }
        }
    } else if (m_bino.active) {
        m_bino.active = false;
        m_bino.offset = 0.0f;
    }
    if (m_bino.offset == 0.0f) {
        return;
    }
    auto* camera = sdk::get_primary_camera();
    if (!camera) {
        return;
    }
    auto* cam_go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(camera, "get_GameObject"); }).value_or(nullptr);
    auto* cam_tf = cam_go ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(cam_go, "get_Transform"); }).value_or(nullptr) : nullptr;
    if (!cam_tf) {
        return;
    }
    const auto cam_pos = sdk::get_transform_position(cam_tf);
    const auto cam_rot = sdk::get_transform_rotation(cam_tf);
    const auto forward = glm::rotate(cam_rot, Vector3f{0, 0, 1});
    sdk::set_transform_position(cam_tf, Vector4f{
        cam_pos.x + forward.x * m_bino.offset,
        cam_pos.y + forward.y * m_bino.offset,
        cam_pos.z + forward.z * m_bino.offset,
        cam_pos.w
    }, true);
}

::REManagedObject* RE4VRBinding::find_ctl(::REManagedObject* c, const char* want, int depth, int& budget) {
    while (c && budget < 80) {
        ++budget;
        if (re4vr::obj_name(c) == want) {
            return c;
        }
        if (depth < 5) {
            auto* ch = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(c, "get_Child"); }).value_or(nullptr);
            if (ch) {
                if (auto* hit = find_ctl(ch, want, depth + 1, budget)) {
                    return hit;
                }
            }
        }
        c = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(c, "get_Next"); }).value_or(nullptr);
    }
    return nullptr;
}

bool RE4VRBinding::is_dodge_gimmick_now() {
    auto* pctx = binding_ctx();
    if (!re4vr::obj_ok(pctx)) {
        return false;
    }
    auto st = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(pctx, "get_CurrentStageID"); });
    if (!st || (*st != 60871 && *st != 60874)) {
        return false;
    }
    auto* occ = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(pctx, "get_OccupiedInfo"); }).value_or(nullptr);
    auto prio = occ ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(occ, "get_Priority"); }) : std::nullopt;
    if (!prio || *prio != DODGE_GMK_PRIO) {
        return false;
    }
    auto* csys = sdk::get_managed_singleton<::REManagedObject>("chainsaw.CameraSystem");
    auto* main = csys ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(csys, "get_MainCameraController"); }).value_or(nullptr) : nullptr;
    auto cam = main ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(main, "get_BusyCameraType"); }) : std::nullopt;
    return cam && *cam == DODGE_GMK_CAMTYPE;
}

bool RE4VRBinding::is_rect_prompt_now() {
    if ((now_clock() - m_rect_prompt_last) >= 0.15) {
        return false;
    }
    auto* pctx = binding_ctx();
    if (!re4vr::obj_ok(pctx)) {
        return false;
    }
    auto st = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(pctx, "get_CurrentStageID"); });
    return st && *st == 60874;
}

bool RE4VRBinding::is_leon_lb_prompt_now() {
    if ((now_clock() - m_leon_lb_last) >= 0.15) {
        return false;
    }
    return !is_ada_active();
}

bool RE4VRBinding::is_dodge_prompt_now() {
    if ((now_clock() - m_dodge_circle_last) < 0.15) {
        return true;
    }
    if (!re4vr::lua_call_bool("__re4_is_dodge_prompt")) {
        return false;
    }
    return !is_rect_prompt_now() && !is_leon_lb_prompt_now();
}

bool RE4VRBinding::ada_pitch_free() {
    if ((now_clock() - m_ada_pitch_gui_last) >= 0.25) {
        return false;
    }
    return is_ada_active();
}

void RE4VRBinding::apply_prompt_grip(Frame& f, bool grip_down) {
    const double now = now_clock();
    if (grip_down) {
        const char* btn = nullptr;
        if (is_rect_prompt_now()) {
            btn = "RB";
        } else if ((now_clock() - m_dodge_circle_last) < 0.15) {
            btn = "B";
        } else if (is_leon_lb_prompt_now()) {
            btn = "LB";
        } else if (is_dodge_prompt_now()) {
            btn = "B";
        } else if (is_dodge_gimmick_now()) {
            btn = "B";
        }
        if (btn) {
            m_pgrip.win_t = now;
            if (!m_pgrip.fired) {
                m_pgrip.fired = true;
                m_pgrip.btn = btn;
                m_pgrip.frames = 4;
                m_pgrip.until_t = now + 0.12;
            }
        } else if ((now - m_pgrip.win_t) > 0.20) {
            m_pgrip.fired = false;
        }
    } else {
        m_pgrip.fired = false;
    }
    if (m_pgrip.frames > 0 && now > m_pgrip.until_t) {
        m_pgrip.frames = 0;
    }
    if (m_pgrip.frames > 0 && !m_pgrip.btn.empty()) {
        if (m_pgrip.btn == "RB") {
            f.RB = true;
        } else if (m_pgrip.btn == "LB") {
            f.LB = true;
        } else if (m_pgrip.btn == "B") {
            f.B = true;
        }
        m_pgrip.frames -= 1;
    }
}

void RE4VRBinding::apply_finisher_rt(Frame& f, bool window_on, bool trigger_down) {
    const double now = now_clock();
    if (window_on && trigger_down) {
        m_rtp.win_t = now;
        if (!m_rtp.fired) {
            m_rtp.fired = true;
            m_rtp.frames = 6;
            m_rtp.until_t = now + 0.15;
        }
    } else if (!trigger_down || (now - m_rtp.win_t) > 0.20) {
        m_rtp.fired = false;
    }
    if (m_rtp.frames > 0 && now > m_rtp.until_t) {
        m_rtp.frames = 0;
    }
    if (m_rtp.frames > 0) {
        f.RT = 1.0f;
        m_rtp.frames -= 1;
    }
}

void RE4VRBinding::play_gui_sound(int32_t enum_val) {
    if (enum_val == 0) {
        return;
    }
    auto* gsm = sdk::get_managed_singleton<::REManagedObject>("chainsaw.GuiSoundManager");
    if (gsm) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(gsm, "wwiseTriggerTarget(chainsaw.gui.GuiSoundType)", enum_val); });
    }
}

void RE4VRBinding::play_body_sound(uint32_t id) {
    if (id == 0) {
        return;
    }
    auto* ctx = binding_ctx();
    if (!re4vr::obj_ok(ctx)) {
        return;
    }
    auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(ctx, "get_BodyGameObject"); }).value_or(nullptr);
    auto* con = re4vr::get_component((::REManagedObject*)go, "soundlib.SoundContainer");
    if (re4vr::obj_ok(con)) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(con, "trigger(System.UInt32)", id); });
    }
}

void RE4VRBinding::grant_flamethrower_to_armoury() {
    auto* am = sdk::get_managed_singleton<::REManagedObject>("chainsaw.ArmouryManager");
    if (!am) {
        return;
    }
    const bool has = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(am, "existsItem", EE_FLAME_ITEM_ID); }).value_or(false);
    if (has) {
        return;
    }
    auto* gu = sdk::find_type_definition("chainsaw.ChainsawGuiUtil");
    auto* gen = gu ? gu->get_method("generateItem") : nullptr;
    if (!gen) {
        return;
    }
    auto* item = re4vr::safe([&] {
        return gen->call<::REManagedObject*>(sdk::get_thread_context(), nullptr, EE_FLAME_ITEM_ID, 1, -1, -1, 100, false);
    }).value_or(nullptr);
    if (!item) {
        return;
    }
    const bool added = re4vr::pcall([&] { sdk::call_object_func_easy<void*>(am, "addArmouryItem(chainsaw.Item)", item); });
    if (added) {
        play_gui_sound(EE_FLAME_SOUND);
    }
}

bool RE4VRBinding::edge_detect(Edge& e, bool pressed) {
    if (pressed) {
        if (!e.prev) {
            e.prev = true;
            e.timer = EDGE_HOLD_FRAMES;
        }
        if (e.timer > 0) {
            e.timer -= 1;
            return true;
        }
        return false;
    }
    e.prev = false;
    e.timer = 0;
    return false;
}

void RE4VRBinding::qt_reset() {
    m_qt.phase = 0;
    m_qt.window_time = 0;
    m_qt.seq = 0;
    m_qt.cooldown = false;
    m_qt.post = 0;
}

void RE4VRBinding::qt_update(float ly, float dt) {
    if (m_qt.seq > 0) {
        m_qt.seq += 1;
        const float ly_s = m_prefs.turn180_ly_sec;
        const float rb_s = m_prefs.turn180_rb_sec;
        if ((now_clock() - m_qt.t0) > (ly_s + rb_s)) {
            m_qt.seq = 0;
            m_qt.cooldown = true;
            m_qt.phase = 0;
            m_qt.post = m_qt.POST_FRAMES;
        }
        return;
    }
    if (m_qt.post > 0) {
        m_qt.post -= 1;
    }
    if (m_qt.cooldown) {
        if (ly > m_qt.RELEASE) {
            m_qt.cooldown = false;
        }
        return;
    }
    if (m_qt.phase == 0) {
        if (ly <= m_qt.DOWN) {
            m_qt.phase = 1;
        }
    } else if (m_qt.phase == 1) {
        if (ly >= m_qt.RELEASE) {
            m_qt.phase = 2;
            m_qt.window_time = 0;
        }
    } else if (m_qt.phase == 2) {
        m_qt.window_time += dt;
        if (ly <= m_qt.DOWN) {
            m_qt.seq = 1;
            m_qt.phase = 0;
            m_qt.t0 = now_clock();
        } else if (m_qt.window_time > m_prefs.turn180_window_sec) {
            m_qt.phase = 0;
        }
    }
}

void RE4VRBinding::apply_yaw_delta(float step) {
    auto* cs = sdk::get_managed_singleton<::REManagedObject>("chainsaw.CameraSystem");
    auto* main = cs ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(cs, "get_MainCameraController"); }).value_or(nullptr) : nullptr;
    auto* busy = main ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(main, "get_BusyCameraController"); }).value_or(nullptr) : nullptr;
    if (!re4vr::obj_ok(busy) || !m_player_cam_td) {
        return;
    }
    auto* td = utility::re_managed_object::get_type_definition(busy);
    if (!td || !td->is_a(m_player_cam_td)) {
        return;
    }
    if (auto* y = sdk::get_object_field<float>(busy, "_Yaw")) {
        *y += step;
    }
}

void RE4VRBinding::publish_ada_ra() {
    re4vr::LuaGuard g;
    auto* L = g.lua();
    if (!L) {
        return;
    }
    auto t = L->create_table();
    t["prev"] = m_ada_ra.prev;
    if (m_ada_ra.down_t) {
        t["down_t"] = *m_ada_ra.down_t;
    }
    t["fired_rb"] = m_ada_ra.fired_rb;
    t["a_timer"] = m_ada_ra.a_timer;
    t["rb_timer"] = m_ada_ra.rb_timer;
    t["a_until"] = m_ada_ra.a_until;
    t["rb_until"] = m_ada_ra.rb_until;
    t["last_a"] = m_ada_ra.last_a;
    (*L)["__re4_ada_ra"] = t;
}

HookManager::PreHookResult RE4VRBinding::pre_nop(std::vector<uintptr_t>&, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    return HookManager::PreHookResult::CALL_ORIGINAL;
}

void RE4VRBinding::post_is_enable_fire(uintptr_t& ret_val, sdk::RETypeDefinition*, uintptr_t) {
    if (re4vr::lua_is_true("__vr_block_fire_when_empty") && re4vr::lua_is_true("__re4_frame_is_gameplay")) {
        ret_val = 0;
        return;
    }
    if (!re4vr::lua_is_true("__re4_burst_gate")) {
        return;
    }
    if (!re4vr::lua_is_true("__vr_burst_active")) {
        return;
    }
    if (!re4vr::lua_is_true("__re4_frame_is_gameplay")) {
        return;
    }
    if (!re4vr::lua_is_true("__vr_burst_rt_down")) {
        return;
    }
    const int n = (int)re4vr::lua_number("__vr_burst_count").value_or(0.0);
    if (n <= 0) {
        return;
    }
    const int press = (int)re4vr::lua_number("__vr_burst_press_id").value_or(0.0);
    const int seen = (int)re4vr::lua_number("__vr_burst_seen_press").value_or(-1.0);
    if (press != seen) {
        re4vr::lua_set_number("__vr_burst_seen_press", press);
        re4vr::lua_set_number("__vr_burst_start_seq", re4vr::lua_number("__vr_shot_seq").value_or(0.0));
    }
    const int fired = (int)re4vr::lua_number("__vr_shot_seq").value_or(0.0) - (int)re4vr::lua_number("__vr_burst_start_seq").value_or(0.0);
    if (fired >= n) {
        ret_val = 0;
    }
}

void RE4VRBinding::post_is_enable_autoreload(uintptr_t& ret_val, sdk::RETypeDefinition*, uintptr_t) {
    if (!re4vr::lua_is_true("__re4_autoreload_gate")) {
        return;
    }
    if (!re4vr::lua_is_true("__vr_manual_reload_consume_b")) {
        return;
    }
    ret_val = 0;
    re4vr::lua_set_number("__re4_autoreload_blocked", re4vr::lua_number("__re4_autoreload_blocked").value_or(0.0) + 1.0);
}

std::optional<std::string> RE4VRBinding::on_initialize() {
    load_json();
    m_turret_gimmick = resolve_static_enum("chainsaw.CameraDefine.GimmickType", "InstalledMachineGun", 6);
    m_gimmickfix_td = sdk::find_type_definition("chainsaw.GimmickFixCameraController");
    m_player_cam_td = sdk::find_type_definition("chainsaw.PlayerCameraController");
    if (auto* td = sdk::find_type_definition("chainsaw.PlayerEquipment")) {
        if (auto* m = td->get_method("isEnableFire")) {
            g_hookman.add(m, &RE4VRBinding::pre_nop, &RE4VRBinding::post_is_enable_fire);
        }
        if (auto* m = td->get_method("isEnableAutoReload")) {
            g_hookman.add(m, &RE4VRBinding::pre_nop, &RE4VRBinding::post_is_enable_autoreload);
        }
    }
    register_ui();
    spdlog::info("[RE4VRBinding] Hooks installed");
    return std::nullopt;
}

void RE4VRBinding::on_config_load(const utility::Config&) {
    load_json();
}

void RE4VRBinding::on_lua_state_created(sol::state& lua) {
    if (lua_nil_or_missing(lua, "vr_controller_type")) {
        lua["vr_controller_type"] = "index";
    }
    auto init_false = [&](const char* n) {
        if (lua_nil_or_missing(lua, n)) {
            lua[n] = false;
        }
    };
    init_false("vr_knife_swing");
    init_false("vr_grenade_throw");
    init_false("vr_is_grenade_equipped");
    init_false("vr_holster_knife");
    init_false("vr_knife_equip");
    init_false("vr_knife_active");
    init_false("__vr_melee_physical_active");
    lua["__re4_burst_gate"] = true;
    lua["__re4_burst_gate_hook"] = true;
    lua["__re4_autoreload_gate"] = true;
    lua["__re4_autoreload_gate_hook"] = true;
    lua["__re4_autoreload_blocked"] = 0;
    register_ui();
}

void RE4VRBinding::on_lua_state_destroyed(sol::state&) {
    reset_runtime();
}

bool RE4VRBinding::on_pre_gui_draw_element(REComponent* gui_element, void*) {
    if (!gui_element) {
        return true;
    }
    auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(gui_element, "get_GameObject"); }).value_or(nullptr);
    const auto n = re4vr::go_name((::REManagedObject*)go);
    if (n == "Gui_ui2022") {
        m_ada_pitch_gui_last = now_clock();
    }
    if (n == "Gui_ui2191_3") {
        auto* view = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(gui_element, "get_View"); }).value_or(nullptr);
        auto* ch = view ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(view, "get_Child"); }).value_or(nullptr) : nullptr;
        int b1 = 0, b2 = 0, b3 = 0;
        if (auto* hit = find_ctl(ch, "c_btn_rect_anime", 0, b1)) {
            if (re4vr::safe([&] { return sdk::call_object_func_easy<bool>(hit, "get_Visible"); }).value_or(false)) {
                m_rect_prompt_last = now_clock();
            }
        }
        if (auto* lhit = find_ctl(ch, "c_btn_rect", 0, b2)) {
            if (re4vr::safe([&] { return sdk::call_object_func_easy<bool>(lhit, "get_Visible"); }).value_or(false)) {
                m_leon_lb_last = now_clock();
            }
        }
        if (auto* dhit = find_ctl(ch, "c_btn_circle_anime", 0, b3)) {
            if (re4vr::safe([&] { return sdk::call_object_func_easy<bool>(dhit, "get_Visible"); }).value_or(false)) {
                m_dodge_circle_last = now_clock();
            }
        }
    }
    return true;
}

void RE4VRBinding::on_frame() {
    ScriptProfileGuard guard("re4_vr_binding.lua", "on_frame", re4vr::profile_frame());
    bino_zoom_tick();
    if (!ensure_init()) {
        return;
    }
    tick_main();
}

bool RE4VRBinding::right_grip_maps_to_gamepad() {
    auto& vr = VR::get();
    if (!digital((uint64_t)vr->get_action_grip(), (uint64_t)vr->get_right_joystick())) {
        return false;
    }
    if (re4vr::lua_is_true("__vr_in_holster_zone")) {
        return false;
    }
    if (re4vr::lua_is_true("__vr_bare_hands")) {
        const auto u = re4vr::lua_number("__vr_stagger_recent_until");
        if (!(u && now_clock() < *u)) {
            return false;
        }
    }
    if (re4vr::lua_is_true("__vr_block_shoot_ready")) {
        return false;
    }
    if (re4vr::lua_is_true("__vr_holster_block_right_grip_gamepad")) {
        return false;
    }
    if (re4vr::lua_is_true("__vr_block_aim")) {
        return false;
    }
    return true;
}

bool RE4VRBinding::holster_right_grip_counts_as_knife_ready() {
    auto& vr = VR::get();
    return re4vr::lua_is_true("__vr_holster_rgrip_as_knife_ready")
        && digital((uint64_t)vr->get_action_grip(), (uint64_t)vr->get_right_joystick());
}

void RE4VRBinding::apply_dpad_shift(Frame& f, bool l_trigger, bool lt_flip_shift, const Vector2f& rstick) {
    const bool left_knife = re4vr::lua_string("__re4_knife_hand") == std::optional<std::string>{"left"}
        || re4vr::lua_is_true("__re4_knife_left_clone");
    const bool shift_on = l_trigger && (!left_knife || lt_flip_shift);
    if (shift_on) {
        if (rstick.y >= 0.9f) {
            f.DPAD_UP = true;
        } else if (rstick.y <= -0.9f) {
            f.DPAD_DOWN = true;
        }
        if (rstick.x >= 0.9f) {
            f.DPAD_RIGHT = true;
        } else if (rstick.x <= -0.9f) {
            f.DPAD_LEFT = true;
        }
        f.RX = 0.0f;
    } else {
        auto& vr = VR::get();
        const auto lj = (uint64_t)vr->get_left_joystick();
        if (digital((uint64_t)vr->get_action_dpad_up(), lj)) {
            f.DPAD_UP = true;
        }
        if (digital((uint64_t)vr->get_action_dpad_down(), lj)) {
            f.DPAD_DOWN = true;
        }
        if (digital((uint64_t)vr->get_action_dpad_left(), lj)) {
            f.DPAD_LEFT = true;
        }
        if (digital((uint64_t)vr->get_action_dpad_right(), lj)) {
            f.DPAD_RIGHT = true;
        }
    }
}

void RE4VRBinding::apply_rt_attack(Frame& f, bool r_trigger, bool gren_live, bool& grenade_motion_rt_armed) {
    if (m_grenade_throw_cooldown > 0) {
        m_grenade_throw_cooldown -= 1;
        re4vr::lua_set_bool("vr_knife_swing", false);
    }
    if (re4vr::lua_is_true("vr_grenade_throw") || re4vr::lua_is_true("vr_is_grenade_equipped") || gren_live) {
        m_grenade_throw_cooldown = GRENADE_COOLDOWN_FRAMES;
    }
    const bool disable_motion_grenade_rt = re4vr::lua_is_true("__vr_disable_motion_grenade_rt");
    const bool motion_attack = grenade_motion_rt_armed && !disable_motion_grenade_rt;
    const bool block_empty = re4vr::lua_is_true("__vr_block_fire_when_empty") && !motion_attack;
    re4vr::lua_set_bool("__re4_empty_trigger_held", r_trigger && block_empty && !motion_attack);
    const bool aiming = re4vr::lua_is_true("__vr_aim_input");
    if (((r_trigger && aiming) || motion_attack) && !block_empty) {
        f.RT = 1.0f;
        re4vr::lua_set_number("__re4_rt_given_t", now_clock());
    }
    if (motion_attack) {
        f.LT = 1.0f;
    }
}

bool RE4VRBinding::scope_grip_aim_blocked(bool grip_now) {
    if (!re4vr::lua_number("__re4_scope_wid")) {
        re4vr::lua_set_nil("__vr_scope_grip_edge_t");
        re4vr::lua_set_bool("__vr_scope_grip_prev", grip_now);
        return false;
    }
    const bool prev = re4vr::lua_is_true("__vr_scope_grip_prev");
    if (grip_now && !prev) {
        re4vr::lua_set_number("__vr_scope_grip_edge_t", now_clock());
    } else if (!grip_now) {
        re4vr::lua_set_nil("__vr_scope_grip_edge_t");
    }
    re4vr::lua_set_bool("__vr_scope_grip_prev", grip_now);
    const auto t = re4vr::lua_number("__vr_scope_grip_edge_t");
    return t && (now_clock() - *t) < SCOPE_GRIP_AIM_DELAY;
}

void RE4VRBinding::apply_r_grip_aim(Frame& f, bool gren_blocks) {
    auto& vr = VR::get();
    const auto rg = digital((uint64_t)vr->get_action_grip(), (uint64_t)vr->get_right_joystick());
    if (holster_right_grip_counts_as_knife_ready() && !gren_blocks) {
        f.LB = true;
    } else if (re4vr::lua_is_true("__re4_knife_equipped")) {
    } else if (scope_grip_aim_blocked(rg)) {
    } else if (re4vr::lua_is_true("__vr_holster_grab_armed")) {
    } else if (auto u = re4vr::lua_number("__vr_post_stow_until"); u && now_clock() < *u) {
    } else if (re4vr::lua_is_true("__vr_bare_hands")) {
    } else if (re4vr::lua_is_true("__vr_knife_in_hand")) {
    } else if (right_grip_maps_to_gamepad()) {
        f.LT = 1.0f;
    }
}

void RE4VRBinding::apply_frame(Frame& f) {
    if (re4vr::lua_is_true("__vr_red9_reloading") && re4vr::lua_is_true("__re4_frame_is_gameplay")) {
        f.LT = 1.0f;
    }
    if (re4vr::lua_number("__re4_bolt_aim_cut_t")) {
        const bool held = f.LT >= 0.5f;
        const auto bw = re4vr::lua_number("__re4_scope_wid");
        const int bwi = bw ? (int)*bw : -1;
        if (!held || (bwi != 4400 && bwi != 6114) || !re4vr::lua_is_true("__re4_frame_is_gameplay")) {
            re4vr::lua_set_nil("__re4_bolt_aim_cut_t");
        } else {
            f.LT = 0.0f;
        }
    }
    re4vr::lua_set_bool("__vr_aim_input", f.LT >= 0.5f);
    if (auto lean = re4vr::lua_number("__re4_cart_lean_lx"); lean && *lean != 0.0) {
        f.LX = (float)*lean;
    }
    if (m_prefs.enable_snapturn && re4vr::lua_is_true("__re4_frame_pure_gameplay")) {
        const float rx = f.RX;
        const float thr = m_prefs.snapturn_thresh;
        if (std::abs(rx) < (thr * 0.5f)) {
            m_qt.st_armed = true;
        }
        if (m_qt.st_armed && std::abs(rx) >= thr) {
            m_qt.st_armed = false;
            const float d = glm::radians(m_prefs.snapturn_deg) * (rx > 0 ? -1.0f : 1.0f);
            apply_yaw_delta(d);
        }
        f.RX = 0.0f;
    } else {
        m_qt.st_armed = true;
    }
    if (m_prefs.enable_180_rotation && re4vr::lua_is_true("__re4_frame_pure_gameplay")) {
        qt_update(f.LY, 1.0f / 60.0f);
        if (m_qt.seq > 0) {
            m_qt.turn_left = glm::pi<float>();
            m_qt.turn_last = now_clock();
            m_qt.seq = 0;
            m_qt.cooldown = true;
            m_qt.phase = 0;
            m_qt.post = m_qt.POST_FRAMES;
        }
        if (m_qt.turn_left > 0.0f) {
            const float dur = m_prefs.turn180_sec;
            const double now = now_clock();
            const float dt = (float)(now - m_qt.turn_last);
            m_qt.turn_last = now;
            float step = (dur <= 0.001f) ? m_qt.turn_left : glm::pi<float>() * (dt / dur);
            if (step > m_qt.turn_left) {
                step = m_qt.turn_left;
            }
            m_qt.turn_left -= step;
            apply_yaw_delta(step);
        }
    } else if (m_qt.phase != 0 || m_qt.seq > 0 || m_qt.cooldown || m_qt.post > 0) {
        qt_reset();
    }
    if (re4vr::lua_is_true("__re4_want_crouch_press")) {
        re4vr::lua_set_bool("__re4_want_crouch_press", false);
        re4vr::lua_set_number("__re4_crouch_press_frames", 4);
    }
    const int cpf = (int)re4vr::lua_number("__re4_crouch_press_frames").value_or(0.0);
    if (cpf > 0) {
        re4vr::lua_set_number("__re4_crouch_press_frames", cpf - 1);
        f.B = true;
    }
    if (auto sf = re4vr::lua_number("__re4_scope_sens_factor"); sf && *sf < 1.0 && *sf > 0.0 && re4vr::lua_is_true("vr_scope_active")) {
        f.RX *= (float)*sf;
        f.RY *= (float)*sf;
    }
    vigem_axis("LX", clampf(f.LX, -1, 1));
    vigem_axis("LY", clampf(f.LY, -1, 1));
    vigem_axis("RX", clampf(f.RX, -1, 1));
    vigem_axis("RY", clampf(f.RY, -1, 1));
    if (re4vr::lua_is_true("__re4_aim_relatch")) {
        f.LT = 0.0f;
        if (!re4vr::lua_is_true("__vr_raw_l_grip")) {
            re4vr::lua_set_bool("__re4_aim_relatch", false);
        }
    }
    const bool map_block_triggers = is_map_open_now();
    if (map_block_triggers) {
        f.LT = 0.0f;
    }
    vigem_trigger("LT", f.LT);
    const bool rt_down = f.RT >= 0.5f;
    if (rt_down && !re4vr::lua_is_true("__vr_burst_prev_rt")) {
        re4vr::lua_set_number("__vr_burst_press_id", re4vr::lua_number("__vr_burst_press_id").value_or(0.0) + 1.0);
    }
    re4vr::lua_set_bool("__vr_burst_rt_down", rt_down);
    re4vr::lua_set_bool("__vr_burst_prev_rt", rt_down);
    const bool fin_on = re4vr::lua_call_bool("__re4_is_finisher_prompt");
    const bool flip = re4vr::lua_is_true("__vr_knife_flip");
    if (re4vr::lua_is_true("__re4_knife_equipped") && re4vr::lua_is_true("__re4_frame_is_gameplay")) {
        f.RT = 0.0f;
        if (fin_on && flip && re4vr::lua_is_true("__re4_knife_finisher_shake")) {
            f.RT = 1.0f;
        }
        apply_finisher_rt(f, fin_on && !flip, re4vr::lua_is_true("__vr_raw_r_trigger"));
    }
    if (re4vr::lua_is_true("__re4_knife_left_clone") && re4vr::lua_is_true("__re4_frame_is_gameplay") && fin_on) {
        if (flip) {
            f.RT = re4vr::lua_is_true("__re4_knife_finisher_shake") ? 1.0f : 0.0f;
        }
    }
    const auto bind_wid = equip_wid();
    const bool is_bare_hands = !bind_wid || *bind_wid < 0;
    if ((re4vr::lua_is_true("__re4_knife_equipped") || re4vr::lua_is_true("__re4_knife_flying") || is_bare_hands)
        && re4vr::lua_is_true("__re4_frame_is_gameplay")) {
        f.X = false;
    }
    if (re4vr::lua_is_true("__re4_gest_mute")) {
        f.A = false;
    }
    if (re4vr::lua_is_true("__vr_raw_r_trigger") && player_in_grapple()) {
        f.RT = 1.0f;
    }
    const bool knife_owns_rt = re4vr::lua_is_true("__re4_knife_equipped")
        && re4vr::lua_string("__re4_knife_hand") != std::optional<std::string>{"left"}
        && !fin_on;
    if (re4vr::lua_is_true("__vr_raw_r_trigger") && player_in_battle() && !knife_owns_rt) {
        f.RT = 1.0f;
    }
    if (map_block_triggers) {
        f.RT = 0.0f;
    }
    vigem_trigger("RT", f.RT);
    vigem_button("A", f.A);
    vigem_button("B", f.B);
    vigem_button("X", f.X);
    vigem_button("Y", f.Y);
    vigem_button("LB", f.LB);
    vigem_button("RB", f.RB);
    vigem_button("LS", f.LS);
    vigem_button("RS", f.RS);
    vigem_button("BACK", f.BACK);
    vigem_button("START", f.START);
    vigem_button("DPAD_UP", f.DPAD_UP);
    vigem_button("DPAD_DOWN", f.DPAD_DOWN);
    vigem_button("DPAD_LEFT", f.DPAD_LEFT);
    vigem_button("DPAD_RIGHT", f.DPAD_RIGHT);
    if (f.DPAD_UP || f.DPAD_DOWN || f.DPAD_LEFT || f.DPAD_RIGHT) {
        re4vr::lua_set_number("__re4_our_equip_until", now_clock() + 0.5);
    }
    char pad[256];
    std::snprintf(pad, sizeof(pad),
        "RT=%.2f LT=%.2f A=%d B=%d X=%d Y=%d LB=%d RB=%d LS=%d RS=%d DP=%s%s%s%s LX=%.2f LY=%.2f RX=%.2f RY=%.2f",
        f.RT, f.LT, f.A ? 1 : 0, f.B ? 1 : 0, f.X ? 1 : 0, f.Y ? 1 : 0,
        f.LB ? 1 : 0, f.RB ? 1 : 0, f.LS ? 1 : 0, f.RS ? 1 : 0,
        f.DPAD_UP ? "U" : "-", f.DPAD_DOWN ? "D" : "-", f.DPAD_LEFT ? "L" : "-", f.DPAD_RIGHT ? "R" : "-",
        f.LX, f.LY, f.RX, f.RY);
    re4vr::lua_set_string("__re4_last_pad", pad);
}

void RE4VRBinding::tick_main() {
    auto& vr = VR::get();
    const bool vr_active = vr->is_hmd_active() && vr->is_using_controllers();
    if (!vr_active) {
        if (m_was_active) {
            Frame z{};
            apply_frame(z);
            m_was_active = false;
        }
        return;
    }
    m_was_active = true;

    bool has_overlay = false;
    {
        re4vr::LuaGuard g;
        auto* L = g.lua();
        if (L) {
            sol::object o = (*L)["overlay"];
            has_overlay = o.is<sol::table>();
        }
    }
    if (has_overlay) {
        if (!m_ref_overlay_synced) {
            m_ref_overlay_synced = true;
            overlay_set_enabled(!m_prefs.hide_ref_overlay);
        }
        if (m_prefs.hide_ref_overlay) {
            m_ref_overlay_tick += 1;
            if (m_ref_overlay_tick >= 30) {
                m_ref_overlay_tick = 0;
                overlay_tick();
            }
        }
    }

    Vector2f left_stick = vr->get_left_stick_axis();
    if (re4vr::lua_is_true("__re4_scope_native") && re4vr::lua_not_false("__re4_scope_no_walk")) {
        left_stick = Vector2f{0, 0};
    }
    Vector2f right_stick = vr->get_right_stick_axis();
    re4vr::lua_set_bool("__vr_user_stick_active", std::abs(right_stick.x) > 0.12f || std::abs(right_stick.y) > 0.12f);
    re4vr::lua_set_number("__vr_right_stick_y", right_stick.y);

    if (re4vr::lua_is_true("__vr_hmd_movement_enabled") && re4vr::lua_is_true("__vr_camera_decoupled")
        && !re4vr::lua_is_true("__vr_save_restore_active")) {
        bool in_menu_sim = false;
        re4vr::LuaGuard g;
        auto* L = g.lua();
        if (L) {
            sol::object re4 = (*L)["re4"];
            if (re4.is<sol::table>()) {
                sol::protected_function inv = re4.as<sol::table>()["is_in_inventory_menu"];
                if (inv.valid()) {
                    auto r = inv();
                    in_menu_sim = r.valid() && r.get_type() == sol::type::boolean && r.get<bool>();
                }
            }
        }
        if (!in_menu_sim) {
            const float sim_x = (float)re4vr::lua_number("__vr_yaw_sim_x").value_or(0.0);
            if (std::abs(sim_x) > 0.001f) {
                right_stick.x = clampf(right_stick.x + sim_x, -1.0f, 1.0f);
            }
        }
    }

    Frame f{};
    f.LX = left_stick.x;
    f.LY = left_stick.y;
    f.RX = right_stick.x;
    f.RY = right_stick.y;
    const bool moving_backward = f.LY < 0;

    const auto lj = (uint64_t)vr->get_left_joystick();
    const auto rj = (uint64_t)vr->get_right_joystick();
    const auto act_trig = (uint64_t)vr->get_action_trigger();
    const auto act_grip = (uint64_t)vr->get_action_grip();
    const auto act_a = (uint64_t)vr->get_action_a_button();
    const auto act_b = (uint64_t)vr->get_action_b_button();
    const auto act_jc = (uint64_t)vr->get_action_joystick_click();
    const auto act_wd = (uint64_t)vr->get_action_weapon_dial();

    const bool l_grip_from_left = digital(act_grip, lj);
    const bool holster_left_chest_rgrip_as_lgrip = re4vr::lua_is_true("__vr_holster_left_chest_rgrip_as_left_grip") && digital(act_grip, rj);
    (void)holster_left_chest_rgrip_as_lgrip;
    const bool gren_live = grenade_equipped_live() || re4vr::lua_is_true("__vr_grenade_in_hand");
    const bool signal = (re4vr::lua_is_true("vr_is_grenade_equipped") || gren_live) && re4vr::lua_is_true("vr_grenade_throw");
    if (signal && !m_prev_vr_grenade_throw) {
        m_grenade_rt_pulse_frames = 6;
    }
    m_prev_vr_grenade_throw = signal;
    bool grenade_motion_rt = false;
    if (m_grenade_rt_pulse_frames > 0) {
        grenade_motion_rt = true;
        m_grenade_rt_pulse_frames -= 1;
    }
    bool grenade_motion_rt_armed = grenade_motion_rt;
    const bool grenade_blocks = re4vr::lua_is_true("vr_is_grenade_equipped") || gren_live;

    bool l_trigger = digital(act_wd, lj);
    bool r_trigger = digital(act_trig, rj);
    re4vr::lua_set_bool("__vr_raw_r_trigger", r_trigger);

    if (re4vr::lua_is_true("__re4_knife_equipped") && re4vr::lua_string("__re4_knife_hand") != std::optional<std::string>{"left"}) {
        if (r_trigger && !re4vr::lua_is_true("__vr_knife_flip_prev_rt") && !player_in_grapple()
            && !re4vr::lua_call_bool("__re4_is_finisher_prompt")) {
            re4vr::lua_set_bool("__vr_knife_flip", !re4vr::lua_is_true("__vr_knife_flip"));
        }
        re4vr::lua_set_bool("__vr_knife_flip_prev_rt", r_trigger);
    } else {
        re4vr::lua_set_bool("__vr_knife_flip_prev_rt", false);
        if (re4vr::lua_string("__re4_knife_hand") != std::optional<std::string>{"left"} && !re4vr::lua_is_true("__re4_knife_left_clone")) {
            re4vr::lua_set_bool("__vr_knife_flip", false);
        }
    }

    bool lt_flip_shift = false;
    const float LT_FLIP_TAP = (float)re4vr::lua_number("__re4_knife_lt_flip_tap").value_or(0.18);
    const bool left_knife = (re4vr::lua_is_true("__re4_knife_equipped") && re4vr::lua_string("__re4_knife_hand") == std::optional<std::string>{"left"})
        || re4vr::lua_is_true("__re4_knife_left_clone");
    if (left_knife) {
        if (l_trigger) {
            if (!re4vr::lua_is_true("__vr_lt_flip_prev")) {
                re4vr::lua_set_number("__vr_lt_flip_press_t", now_clock());
                re4vr::lua_set_bool("__vr_lt_flip_hold", false);
            }
            if (!re4vr::lua_is_true("__vr_lt_flip_hold")
                && (now_clock() - re4vr::lua_number("__vr_lt_flip_press_t").value_or(now_clock())) >= LT_FLIP_TAP) {
                re4vr::lua_set_bool("__vr_lt_flip_hold", true);
            }
            lt_flip_shift = re4vr::lua_is_true("__vr_lt_flip_hold");
        } else {
            if (re4vr::lua_is_true("__vr_lt_flip_prev") && !re4vr::lua_is_true("__vr_lt_flip_hold") && !player_in_grapple()) {
                re4vr::lua_set_bool("__vr_knife_flip", !re4vr::lua_is_true("__vr_knife_flip"));
            }
            re4vr::lua_set_bool("__vr_lt_flip_hold", false);
        }
        re4vr::lua_set_bool("__vr_lt_flip_prev", l_trigger);
    } else {
        re4vr::lua_set_bool("__vr_lt_flip_prev", false);
        re4vr::lua_set_bool("__vr_lt_flip_hold", false);
    }

    const bool l_abutton = digital(act_a, lj);
    const bool r_abutton = digital(act_a, rj);
    bool l_bbutton = digital(act_b, lj);
    bool r_bbutton = digital(act_b, rj);
    re4vr::lua_set_bool("__vr_raw_r_bbutton", r_bbutton);
    if (re4vr::lua_is_true("__vr_manual_reload_consume_b") && !is_any_menu_open()) {
        r_bbutton = false;
    }
    const bool l_joyclick = digital(act_jc, lj);
    const bool r_joyclick = digital(act_jc, rj);

    bool handle_pause = false;
    if (auto* rt = vr->get_runtime()) {
        if (rt->handle_pause) {
            handle_pause = true;
            rt->handle_pause = false;
        }
    }

    const bool combo = l_trigger && l_bbutton;
    if (combo && !m_lt_b_overlay_was) {
        const bool want_ui = !g_framework->is_drawing_ui();
        g_framework->set_draw_ui(want_ui);
        if (has_overlay) {
            m_prefs.hide_ref_overlay = !want_ui;
            save_json();
            overlay_set_enabled(!m_prefs.hide_ref_overlay);
        }
        play_body_sound(REFUI_SOUND);
    }
    m_lt_b_overlay_was = combo;
    if (combo) {
        l_bbutton = false;
    }

    bool dual_trigger_start = false;
    if (l_trigger && r_trigger) {
        m_dual_trigger_gap_clock.reset();
        if (!m_dual_trigger_start_clock) {
            m_dual_trigger_start_clock = now_clock();
        }
        if (!m_dual_trigger_fired && (now_clock() - *m_dual_trigger_start_clock) >= DUAL_TRIGGER_HOLD_SEC) {
            dual_trigger_start = true;
            m_dual_trigger_fired = true;
        }
    } else if (m_dual_trigger_start_clock) {
        if (!m_dual_trigger_gap_clock) {
            m_dual_trigger_gap_clock = now_clock();
        }
        if ((now_clock() - *m_dual_trigger_gap_clock) >= COMBO_GRACE_SEC) {
            m_dual_trigger_start_clock.reset();
            m_dual_trigger_fired = false;
            m_dual_trigger_gap_clock.reset();
        }
    } else {
        m_dual_trigger_fired = false;
        m_dual_trigger_gap_clock.reset();
    }

    const bool ks = ks_active();
    const bool in_throwsight = is_throwsight_stage();
    const bool in_boat = is_boat_stage();
    const bool in_menu = is_any_menu_open();
    if (in_menu) {
        m_ada_ra.prev = r_abutton;
        m_ada_ra.down_t.reset();
        m_ada_ra.fired_rb = false;
        m_ada_ra.a_timer = 0;
        publish_ada_ra();
    }
    const bool in_binoculars = is_binoculars_active_this_frame();
    const bool in_turret = is_turret_mounted();
    const bool in_jetski = re4vr::lua_is_true("__re4_jetski_active");
    const bool boat_active = re4vr::lua_is_true("__re4_boat_active");
    if ((in_menu || in_turret) && l_abutton) {
        m_la.back_guard = true;
    }
    if (ks && re4vr::lua_is_true("__vr_raw_r_bbutton")) {
        m_la.ks_x_guard = true;
    }

    const bool gameplay = !in_menu && !in_boat && !in_throwsight && !in_binoculars && !ks;
    re4vr::lua_set_bool("__re4_frame_is_gameplay", gameplay);
    const char* why = gameplay ? "gameplay"
        : (in_menu ? "menu" : (in_boat ? "boat" : (in_throwsight ? "throwsight" : (in_binoculars ? "bino" : (ks ? "killswitch" : "?")))));
    re4vr::lua_set_string("__re4_gameplay_why", why);
    re4vr::lua_set_bool("__re4_frame_pure_gameplay", gameplay && !in_turret && !in_jetski);

    bool right_free = re4vr::lua_is_true("__vr_bare_hands");
    if (!right_free && re4vr::lua_is_true("__re4_knife_equipped") && re4vr::lua_string("__re4_knife_hand") == std::optional<std::string>{"left"}) {
        right_free = true;
    }
    if (right_free && re4vr::lua_string("__re4_knife_hand") == std::optional<std::string>{"right"}) {
        right_free = false;
    }
    std::string gname;
    if (l_trigger && re4vr::lua_is_true("__re4_frame_pure_gameplay") && right_free && !is_mercs_active()) {
        if (r_abutton) {
            gname = "point";
        } else if (r_bbutton) {
            gname = "fuck_you";
        }
    }
    re4vr::lua_set_bool("__re4_gest_mute", !gname.empty());
    {
        re4vr::LuaGuard lg;
        auto* L = lg.lua();
        std::string prev;
        if (L) {
            sol::object o = (*L)["__re4_gest_prev"];
            if (o.get_type() == sol::type::string) {
                prev = o.as<std::string>();
            }
        }
        if (!gname.empty() && gname != prev) {
            re4vr::lua_set_string("__re4_gesture_fire", gname);
        }
        if (L) {
            if (gname.empty()) {
                (*L)["__re4_gest_prev"] = sol::nil;
            } else {
                (*L)["__re4_gest_prev"] = gname;
            }
        }
    }

    const bool both_a = l_abutton && r_abutton;
    const bool ee_gameplay = gameplay && !is_ada_active() && !is_mercs_active();
    if (both_a && ee_gameplay) {
        m_ee_flame_gap_clock.reset();
        if (!m_ee_flame_clock) {
            m_ee_flame_clock = now_clock();
        }
        if (!m_ee_flame_fired && (now_clock() - *m_ee_flame_clock) >= EE_FLAME_HOLD_SEC) {
            m_ee_flame_fired = true;
            grant_flamethrower_to_armoury();
        }
    } else if (m_ee_flame_clock) {
        if (!m_ee_flame_gap_clock) {
            m_ee_flame_gap_clock = now_clock();
        }
        if ((now_clock() - *m_ee_flame_gap_clock) >= COMBO_GRACE_SEC) {
            m_ee_flame_clock.reset();
            m_ee_flame_fired = false;
            m_ee_flame_gap_clock.reset();
        }
    } else {
        m_ee_flame_fired = false;
        m_ee_flame_gap_clock.reset();
    }

    auto apply_common_face = [&]() {
        if (l_bbutton) {
            f.Y = true;
        }
        if (handle_pause) {
            f.START = true;
        }
    };

    if (in_boat && !in_menu) {
        if (l_joyclick) {
            f.LS = true;
        }
        if (l_trigger) {
            f.LT = 1.0f;
        }
        const bool l_grip_boot = digital(act_grip, lj);
        if (l_grip_boot) {
            f.LB = true;
        }
        if (m_prev_l_grip && !l_grip_boot) {
            re4vr::lua_set_bool("vr_holster_knife", true);
        }
        m_prev_l_grip = l_grip_boot;
        if (l_abutton) {
            f.BACK = true;
        }
        apply_common_face();
        if (edge_detect(m_edge_r_jc, r_joyclick)) {
            f.B = true;
        }
        if (r_trigger) {
            f.RT = 1.0f;
        }
        if (digital(act_grip, rj)) {
            f.LB = true;
        }
        if (edge_detect(m_edge_r_a, r_abutton)) {
            f.A = true;
        }
        if (edge_detect(m_edge_r_b, r_bbutton)) {
            f.X = true;
        }
    } else if (in_throwsight && !in_menu) {
        if (l_trigger) {
            f.LB = true;
        }
        const bool lgrip = digital(act_grip, lj);
        re4vr::lua_set_bool("__vr_raw_l_grip", lgrip);
        if (lgrip) {
            f.LT = 1.0f;
        }
        if (edge_detect(m_edge_l_a_b, l_abutton)) {
            f.B = true;
        }
        apply_common_face();
        if (r_trigger) {
            f.LB = true;
        }
        if (digital(act_grip, rj)) {
            f.LB = true;
        }
        if (edge_detect(m_edge_r_a, r_abutton)) {
            f.A = true;
        }
        if (edge_detect(m_edge_r_b, r_bbutton)) {
            f.X = true;
        }
    } else if (in_menu) {
        bool dodge_hudoff = false;
        if (is_rect_prompt_now() && l_grip_from_left && !is_any_menu_open(true)) {
            dodge_hudoff = true;
            f.RB = true;
        } else if (is_leon_lb_prompt_now() && l_grip_from_left && !is_any_menu_open(true)) {
            dodge_hudoff = true;
            f.LB = true;
        } else if (re4vr::lua_call_bool("__re4_is_dodge_prompt") && l_grip_from_left && !is_any_menu_open(true)) {
            dodge_hudoff = true;
            f.B = true;
        }
        const bool symbol_riddle = is_symbol_riddle();
        if (symbol_riddle) {
            if (right_stick.x <= -0.5f) {
                f.LB = true;
            } else if (right_stick.x >= 0.5f) {
                f.RB = true;
            }
        }
        if (l_joyclick) {
            f.LS = true;
        }
        if (l_trigger) {
            f.LT = 1.0f;
            if (!symbol_riddle) {
                if (right_stick.y >= 0.9f) {
                    f.DPAD_UP = true;
                } else if (right_stick.y <= -0.9f) {
                    f.DPAD_DOWN = true;
                }
                if (right_stick.x >= 0.9f) {
                    f.DPAD_RIGHT = true;
                } else if (right_stick.x <= -0.9f) {
                    f.DPAD_LEFT = true;
                }
            }
            f.RX = 0;
            f.RY = 0;
        }
        if (digital(act_grip, lj) && !dodge_hudoff) {
            f.LB = true;
        }
        if (edge_detect(m_edge_l_a_b, l_abutton) && !m_la.long_consumed) {
            f.B = true;
        }
        apply_common_face();
        if (r_joyclick) {
            f.RS = true;
        }
        if (r_trigger) {
            f.RT = 1.0f;
        }
        if (digital(act_grip, rj)) {
            f.RB = true;
        }
        if (r_abutton) {
            f.A = true;
        }
        if (edge_detect(m_edge_r_b, r_bbutton)) {
            f.X = true;
        }
    } else if (in_turret) {
        f.RX = right_stick.x;
        f.RY = right_stick.y;
        if (l_joyclick) {
            f.LS = true;
        }
        apply_dpad_shift(f, l_trigger, lt_flip_shift, right_stick);
        if (l_abutton) {
            f.B = true;
        }
        apply_common_face();
        if (r_joyclick) {
            f.B = true;
        }
        if (r_trigger) {
            f.RT = 1.0f;
        }
        apply_r_grip_aim(f, grenade_blocks);
        if (r_abutton) {
            f.A = true;
        }
        if (r_bbutton) {
            f.X = true;
        }
    } else if (in_jetski) {
        const float jx_l = left_stick.x, jy_l = left_stick.y, jx_r = right_stick.x, jy_r = right_stick.y;
        f.LX = (std::abs(jx_r) > std::abs(jx_l)) ? jx_r : jx_l;
        f.LY = (std::abs(jy_r) > std::abs(jy_l)) ? jy_r : jy_l;
        f.RX = 0;
        f.RY = 0;
        if (l_joyclick) {
            f.LS = true;
        }
        apply_dpad_shift(f, l_trigger, lt_flip_shift, right_stick);
        if (l_abutton) {
            f.BACK = true;
        }
        apply_common_face();
        if (r_joyclick) {
            f.B = true;
        }
        if (r_trigger) {
            f.RT = 1.0f;
        }
        apply_r_grip_aim(f, grenade_blocks);
        if (r_abutton) {
            f.A = true;
        }
        if (r_bbutton) {
            f.X = true;
        }
    } else if (ks) {
        if (l_joyclick) {
            f.LS = true;
        }
        apply_dpad_shift(f, l_trigger, lt_flip_shift, right_stick);
        if (l_grip_from_left) {
            if (is_rect_prompt_now()) {
                f.RB = true;
            } else if (is_leon_lb_prompt_now()) {
                f.LB = true;
            } else if (is_dodge_gimmick_now()) {
                f.B = true;
            }
        }
        if (l_abutton) {
            f.BACK = true;
        }
        apply_common_face();
        if (r_joyclick) {
            f.B = true;
        }
        apply_rt_attack(f, r_trigger, gren_live, grenade_motion_rt_armed);
        apply_r_grip_aim(f, grenade_blocks);
        if (r_abutton) {
            f.A = true;
        }
        if (edge_detect(m_edge_r_b, r_bbutton)) {
            f.X = true;
        }
    } else if (in_binoculars) {
        f.LX = 0;
        f.LY = 0;
        f.RX = right_stick.x * 2.0f;
        f.RY = right_stick.y * 2.0f;
        if (l_joyclick) {
            f.LS = true;
        }
        apply_dpad_shift(f, l_trigger, lt_flip_shift, right_stick);
        if (l_abutton) {
            f.BACK = true;
        }
        apply_common_face();
        if (r_joyclick) {
            f.B = true;
        }
        apply_rt_attack(f, r_trigger, gren_live, grenade_motion_rt_armed);
        apply_r_grip_aim(f, grenade_blocks);
        if (r_abutton) {
            f.A = true;
        }
        if (r_bbutton) {
            f.X = true;
        }
    } else if (is_mercs_active()) {
        m_bino.active = false;
        m_bino.offset = 0;
        if (l_joyclick) {
            f.LS = true;
        }
        apply_dpad_shift(f, l_trigger, lt_flip_shift, right_stick);
        if (l_abutton && !both_a) {
            f.RS = true;
            f.LS = true;
        }
        m_la.pressed = false;
        m_la.frames = 0;
        m_la.fired_long = false;
        apply_common_face();
        if (r_joyclick) {
            f.B = true;
        }
        apply_prompt_grip(f, l_grip_from_left);
        apply_rt_attack(f, r_trigger, gren_live, grenade_motion_rt_armed);
        apply_r_grip_aim(f, grenade_blocks);
        if (r_abutton && !both_a) {
            f.A = true;
        }
        const bool r_b_edge = edge_detect(m_edge_r_b, r_bbutton);
        if (r_b_edge && !both_a && re4vr::lua_number("__vr_dbg_wep_id") == std::optional<double>{6304.0}
            && re4vr::lua_is_true("__re4_frame_pure_gameplay") && !re4vr::lua_is_true("__re4_knife_equipped")) {
            f.X = true;
        }
    } else if (is_ada_active()) {
        m_bino.active = false;
        m_bino.offset = 0;
        if (l_joyclick) {
            f.LS = true;
        }
        apply_dpad_shift(f, l_trigger, lt_flip_shift, right_stick);
        if (l_abutton && !both_a) {
            f.BACK = true;
        }
        m_la.pressed = false;
        m_la.frames = 0;
        m_la.fired_long = false;
        apply_common_face();
        if (r_joyclick) {
            f.B = true;
        }
        apply_prompt_grip(f, l_grip_from_left);
        apply_rt_attack(f, r_trigger, gren_live, grenade_motion_rt_armed);
        apply_r_grip_aim(f, grenade_blocks);
        {
            auto& st = m_ada_ra;
            const double now = now_clock();
            const float hold = (float)re4vr::lua_number("__re4_ada_a_long_sec").value_or(0.35);
            if (is_ada_raw_a_zone()) {
                if (r_abutton && !both_a) {
                    f.A = true;
                }
                st.prev = r_abutton;
                st.down_t.reset();
                st.fired_rb = false;
                st.a_timer = 0;
                st.rb_timer = 0;
                st.a_until = 0;
                st.rb_until = 0;
            } else if (r_abutton && !st.prev) {
                st.down_t = now;
                st.fired_rb = false;
            } else if (r_abutton && st.down_t && !st.fired_rb && (now - *st.down_t) >= hold) {
                st.fired_rb = true;
                st.rb_timer = 20;
                st.rb_until = now + 0.22;
            } else if (!r_abutton && st.prev) {
                if (!st.fired_rb && (now - st.last_a) > 0.25) {
                    st.a_timer = 4;
                    st.a_until = now + 0.10;
                    st.last_a = now;
                }
                st.down_t.reset();
                st.fired_rb = false;
            }
            st.prev = r_abutton;
            if (st.a_timer > 0 && now > st.a_until) {
                st.a_timer = 0;
            }
            if (st.rb_timer > 0 && now > st.rb_until) {
                st.rb_timer = 0;
            }
            if (st.a_timer > 0 && !both_a) {
                f.A = true;
                st.a_timer -= 1;
            }
            if (st.rb_timer > 0) {
                f.RB = true;
                st.rb_timer -= 1;
            }
            publish_ada_ra();
        }
    } else {
        m_bino.active = false;
        m_bino.offset = 0;
        if (l_joyclick) {
            f.LS = true;
        }
        apply_dpad_shift(f, l_trigger, lt_flip_shift, right_stick);
        int long_frames = (int)std::floor(m_prefs.long_press_sec * 90.0f + 0.5f);
        if (long_frames < 3) {
            long_frames = 3;
        }
        const int short_min_frames = (int)std::floor(m_prefs.short_min_sec * 90.0f + 0.5f);
        if (both_a) {
            m_la.pressed = false;
            m_la.frames = 0;
            m_la.fired_long = false;
        } else if (l_abutton) {
            if (!m_la.pressed) {
                m_la.pressed = true;
                m_la.frames = 0;
                m_la.fired_long = false;
            }
            m_la.frames += 1;
            if (m_la.frames >= long_frames && !m_la.fired_long) {
                m_la.long_timer = 20;
                m_la.long_is_ada = false;
                m_la.fired_long = true;
                m_la.long_consumed = true;
            }
        } else {
            if (m_la.pressed && !m_la.fired_long && m_la.frames >= short_min_frames) {
                m_la.short_timer = 20;
                m_la.short_is_ada = false;
            }
            m_la.pressed = false;
            m_la.frames = 0;
            m_la.fired_long = false;
        }
        apply_common_face();
        if (r_joyclick) {
            f.B = true;
        }
        apply_prompt_grip(f, l_grip_from_left);
        apply_rt_attack(f, r_trigger, gren_live, grenade_motion_rt_armed);
        apply_r_grip_aim(f, grenade_blocks);
        if (r_abutton && !both_a) {
            f.A = true;
        }
    }

    if (dual_trigger_start) {
        m_start_hold_timer = START_HOLD_FRAMES;
    }
    if (m_start_hold_timer > 0) {
        if (!in_menu) {
            f.START = true;
        }
        m_start_hold_timer -= 1;
    }
    if (m_la.short_timer > 0) {
        if (m_la.short_is_ada) {
            f.BACK = true;
        } else {
            f.RS = true;
        }
        m_la.short_timer -= 1;
    }
    if (m_la.long_timer > 0) {
        if (m_la.long_is_ada) {
            f.RB = true;
        } else {
            f.BACK = true;
        }
        m_la.long_timer -= 1;
    }
    if (m_la.back_guard) {
        f.BACK = false;
    }
    if (m_la.ks_x_guard && !ks) {
        f.X = false;
    }
    if (!l_abutton) {
        m_la.long_consumed = false;
        m_la.back_guard = false;
    }
    if (!re4vr::lua_is_true("__vr_raw_r_bbutton")) {
        m_la.ks_x_guard = false;
    }
    if (!re4vr::lua_is_true("__vr_unlock_ry") && !in_menu && !in_throwsight && !in_binoculars
        && !re4vr::lua_is_true("__re4_at_cannon") && !in_turret && !in_jetski && !ada_pitch_free()) {
        f.RY = 0.0f;
    }
    const bool ks_stick_exempt = in_boat || re4vr::lua_is_true("__re4_railcar_mode") || re4vr::lua_is_true("__re4_force_ks4_bulletrush");
    if (!in_menu && !in_throwsight && !in_binoculars && !in_turret && !in_jetski && !ks_stick_exempt
        && (ks2() || ks4())) {
        f.RX = 0;
        f.RY = 0;
    }
    if (boat_active && !in_menu) {
        f.RX = right_stick.x;
        f.RY = right_stick.y;
    }
    if (moving_backward) {
        f.LS = false;
    }
    apply_frame(f);
}
#endif
