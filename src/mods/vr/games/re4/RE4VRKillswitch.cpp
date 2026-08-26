#define NOMINMAX
#include "RE4VRKillswitch.hpp"

#if defined(RE4)
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <utility>
#include <unordered_set>

#include <imgui.h>
#include <spdlog/spdlog.h>
#include <sdk/RETypeDB.hpp>
#include <sdk/REString.hpp>
#include <sdk/RETransform.hpp>
#include <sdk/REGameObject.hpp>
#include <sdk/SystemArray.hpp>
#include <sdk/MurmurHash.hpp>
#include <sdk/Application.hpp>
#include <utility/String.hpp>

#include "RE4VRShared.hpp"
#include "RE4VRMenu.hpp"

namespace {
std::string to_lower(std::string s) {
    for (auto& c : s) {
        c = (char)std::tolower((unsigned char)c);
    }
    return s;
}

bool contains_ci(std::string_view hay, std::string_view needle) {
    if (needle.empty()) {
        return false;
    }
    const auto h = to_lower(std::string{hay});
    const auto n = to_lower(std::string{needle});
    return h.find(n) != std::string::npos;
}

bool ends_with_ci(std::string_view hay, std::string_view needle) {
    if (needle.empty() || hay.size() < needle.size()) {
        return false;
    }
    const auto h = to_lower(std::string{hay});
    const auto n = to_lower(std::string{needle});
    return h.size() >= n.size() && h.compare(h.size() - n.size(), n.size(), n) == 0;
}

std::string opt_to_str(std::optional<int32_t> v) {
    return v ? std::to_string(*v) : std::string{"nil"};
}

std::optional<int32_t> read_int_at(void* p, sdk::RETypeDefinition* ty) {
    if (!p) {
        return std::nullopt;
    }
    const auto sz = ty ? ty->get_size() : 4u;
    if (sz >= 8) {
        return (int32_t) * (int64_t*)p;
    }
    if (sz >= 4) {
        return *(int32_t*)p;
    }
    if (sz >= 2) {
        return (int32_t) * (int16_t*)p;
    }
    return (int32_t) * (int8_t*)p;
}

std::optional<int64_t> read_i64_at(void* p, sdk::RETypeDefinition* ty) {
    if (!p) {
        return std::nullopt;
    }
    const auto sz = ty ? ty->get_size() : 8u;
    if (sz >= 8) {
        return *(int64_t*)p;
    }
    if (sz >= 4) {
        return (int64_t) * (int32_t*)p;
    }
    if (sz >= 2) {
        return (int64_t) * (int16_t*)p;
    }
    return (int64_t) * (int8_t*)p;
}

std::optional<int32_t> static_enum_i32(sdk::REField* f) {
    if (!f) {
        return std::nullopt;
    }
    void* p = f->get_data_raw(nullptr);
    return read_int_at(p, f->get_type());
}

std::optional<int64_t> static_enum_i64(sdk::REField* f) {
    if (!f) {
        return std::nullopt;
    }
    void* p = f->get_data_raw(nullptr);
    return read_i64_at(p, f->get_type());
}

std::optional<int32_t> nested_int(::REManagedObject* obj, const char* outer, const char* inner) {
    if (!re4vr::obj_ok(obj)) {
        return std::nullopt;
    }
    auto* td = utility::re_managed_object::get_type_definition(obj);
    if (!td) {
        return std::nullopt;
    }
    auto* of = td->get_field(outer);
    if (!of) {
        return std::nullopt;
    }
    auto* oty = of->get_type();
    const bool outer_vt = oty && oty->is_value_type();
    // Parent is a managed object: always offset-from-base, even when the field type is a value struct.
    void* optr = of->get_data_raw(obj, false);
    if (!optr) {
        return std::nullopt;
    }
    if (!outer_vt) {
        auto* managed = *(::REManagedObject**)optr;
        if (!re4vr::obj_ok(managed)) {
            return std::nullopt;
        }
        if (auto* f = sdk::get_object_field<int32_t>(managed, inner)) {
            return *f;
        }
        return std::nullopt;
    }
    auto* inf = oty->get_field(inner);
    if (!inf) {
        return std::nullopt;
    }
    void* iptr = inf->get_data_raw(optr, true);
    return read_int_at(iptr, inf->get_type());
}

std::optional<int32_t> call_priority(::REManagedObject* occ) {
    if (!re4vr::obj_ok(occ)) {
        return std::nullopt;
    }
    if (auto v = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(occ, "get_Priority"); })) {
        return v;
    }
    auto* boxed = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(occ, "get_Priority"); }).value_or(nullptr);
    if (re4vr::obj_ok(boxed)) {
        if (auto* f = sdk::get_object_field<int32_t>(boxed, "value__")) {
            return *f;
        }
    }
    return std::nullopt;
}

std::optional<std::string> sys_str(::SystemString* s) {
    if (!s) {
        return std::nullopt;
    }
    return utility::re_string::get_string(s);
}

sol::table zone_to_lua(sol::state_view lua, const RE4VRKillswitch::Zone& z) {
    auto t = lua.create_table();
    if (z.stage) {
        t["stage"] = *z.stage;
    }
    if (z.space) {
        t["space"] = *z.space;
    }
    t["x"] = z.x;
    t["y"] = z.y;
    t["z"] = z.z;
    t["r"] = z.r;
    t["level"] = z.level;
    if (z.camstate) {
        t["camstate"] = *z.camstate;
    }
    t["name"] = z.name;
    return t;
}

sol::table entry_to_lua(sol::state_view lua, const RE4VRKillswitch::EpisodeEntry& e) {
    auto t = lua.create_table();
    if (e.stage) {
        t["stage"] = *e.stage;
    }
    if (e.space) {
        t["space"] = *e.space;
    }
    if (e.camstate) {
        t["camstate"] = *e.camstate;
    }
    if (e.pos) {
        auto p = lua.create_table();
        p["x"] = e.pos->x;
        p["y"] = e.pos->y;
        p["z"] = e.pos->z;
        t["pos"] = p;
    }
    return t;
}

const std::vector<const char*> GAMEPLAY_CAM_STATES{
    "Normal", "Jog", "Sprint", "Combat", "BattleNormal",
    "WallAlongJog", "QuickTurm", "CrouchQuickTurm", "Crouch", "ForceCrouch",
    "Hold", "HoldVariation", "HoldIronSight", "HoldGrenade", "HoldExtraScope",
    "HoldOpticalScope", "HoldSpecialOpticalScope", "ViaScope",
    "PumpAction", "RifleChangeWeapon",
};
const std::vector<const char*> PIN_RELEASE_CAM_STATES{};
const std::vector<const char*> KS2_CAM_STATES{
    "TerrainAction", "TerrainAction_2m", "TerrainAction_Jump", "TerrainAction_Window",
    "Fall", "Fall_Jump", "Fall_Window", "Landing",
    "TerrainUpWithPartner", "TerrainUpWithPartner_1m", "HookShot",
    "Damage", "PartnerRescue", "AutoMove",
};
const std::vector<const char*> KS3_CAM_STATES{};
const std::vector<const char*> KS4_CAM_STATES{"FatalKick", "FatalRoundKick"};
const std::vector<const char*> GIMMICK_FLAGS{
    "get_IsTerrainUpWithPartner",
    "get_IsHookShot",
    "get_IsLiftActing",
};
const std::unordered_set<int32_t> GONDOLA_PARENT_STAGES{60850};
const std::unordered_set<int32_t> GKS3_STAGES{53303, 53302, 54400, 50401, 50500, 55850, 55851, 55852, 61302, 61301, 60880};
const std::unordered_set<int32_t> PRIO_ONLY_STAGES{55850};
const std::unordered_set<int32_t> MINIDEMO_KS4_STAGES{55850};
const std::unordered_set<int32_t> GFIX_KS5_STAGES{55852};
const std::unordered_set<int32_t> GFIX_KS4_STAGES{44400};
const std::unordered_set<int32_t> JETSKI_KS4_STAGES{
    59103, 59201, 59202, 59203, 59204, 59205, 59206, 59207,
    59209, 59210, 59211, 59214, 59215, 59216, 59217,
    59218, 59219, 59220, 59221, 59222,
};
const std::unordered_set<int32_t> MINECART_KS4_STAGES{55201, 55202};

struct ElevBox {
    int32_t stage;
    float x1, y1, z1, x2, y2, z2, mxz, start_release, top_release, y_pad;
};
const ElevBox ELEV{
    53202,
    130.45f, 27.33f, 64.28f,
    131.32f, 33.20f, 63.60f,
    3.0f, 0.005f, 0.005f, 0.0f,
};
const ElevBox ELEV2{
    53302,
    89.77f, 19.03f, 107.50f,
    90.14f, 13.22f, 108.50f,
    3.0f, 0.0f, 0.0f, 0.30f,
};
constexpr float ELEV5_X = 300.85f, ELEV5_Z = -105.44f, ELEV5_R = 4.0f;
constexpr float ELEV5_Y_UNTEN = -3.26f, ELEV5_Y_OBEN = 48.23f, ELEV5_Y_TOL = 1.5f;
}

std::shared_ptr<RE4VRKillswitch>& RE4VRKillswitch::get() {
    static auto inst = std::make_shared<RE4VRKillswitch>();
    return inst;
}

double RE4VRKillswitch::now_clock() const {
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - m_clock_origin).count();
}

bool RE4VRKillswitch::is_ks2() const {
    return m_ks2_active && m_fp_enabled;
}

bool RE4VRKillswitch::is_ks3() const {
    return m_ks3_active && m_fp_enabled;
}

bool RE4VRKillswitch::is_ks4() const {
    if (m_ks4_active && m_jetski_active) {
        return true;
    }
    return m_ks4_active && m_fp_enabled;
}

void RE4VRKillswitch::set_fp_enabled(bool v) {
    m_fp_enabled = v;
    RE4VRShared::get()->re4_ks_fp_enabled = v;
    save_ks_cfg();
}

const RE4VRKillswitch::EpisodeEntry* RE4VRKillswitch::get_current_entry() const {
    if (m_cur_episode_entry) {
        return &*m_cur_episode_entry;
    }
    if (m_last_episode_entry) {
        return &*m_last_episode_entry;
    }
    return nullptr;
}

::REManagedObject* RE4VRKillswitch::get_player_context_api() {
    return player_context();
}

::REGameObject* RE4VRKillswitch::get_player_body_api() {
    return player_body();
}

void RE4VRKillswitch::load_ks_cfg() {
    const auto d = re4vr::load_json_file(KS_CFG_FILE);
    if (d.contains("fp_enabled") && d["fp_enabled"].is_boolean()) {
        m_fp_enabled = d["fp_enabled"].get<bool>();
    }
    if (d.contains("ks2_as_ks4") && d["ks2_as_ks4"].is_boolean()) {
        m_ks2_as_ks4 = d["ks2_as_ks4"].get<bool>();
    }
}

void RE4VRKillswitch::save_ks_cfg() {
    nlohmann::json d;
    d["fp_enabled"] = m_fp_enabled;
    d["ks2_as_ks4"] = m_ks2_as_ks4;
    re4vr::save_json_file(KS_CFG_FILE, d);
}

void RE4VRKillswitch::load_zones() {
    m_zones.clear();
    std::ifstream f{re4vr::data_path(ZONES_FILE)};
    if (!f) {
        return;
    }
    nlohmann::json d;
    try {
        f >> d;
    } catch (...) {
        return;
    }
    if (!d.is_array()) {
        return;
    }
    for (const auto& e : d) {
        if (!e.is_object()) {
            continue;
        }
        Zone z{};
        if (e.contains("stage") && e["stage"].is_number()) {
            z.stage = e["stage"].get<int32_t>();
        }
        if (e.contains("space") && e["space"].is_number()) {
            z.space = e["space"].get<int32_t>();
        }
        z.x = e.value("x", 0.0f);
        z.y = e.value("y", 0.0f);
        z.z = e.value("z", 0.0f);
        z.r = e.value("r", 3.0f);
        z.level = e.value("level", 2);
        if (e.contains("camstate") && e["camstate"].is_number()) {
            z.camstate = e["camstate"].get<int32_t>();
        }
        if (e.contains("name") && e["name"].is_string()) {
            z.name = e["name"].get<std::string>();
        }
        m_zones.push_back(std::move(z));
    }
}

void RE4VRKillswitch::save_zones() {
    nlohmann::json arr = nlohmann::json::array();
    for (const auto& z : m_zones) {
        nlohmann::json e;
        if (z.stage) {
            e["stage"] = *z.stage;
        } else {
            e["stage"] = nullptr;
        }
        if (z.space) {
            e["space"] = *z.space;
        } else {
            e["space"] = nullptr;
        }
        e["x"] = z.x;
        e["y"] = z.y;
        e["z"] = z.z;
        e["r"] = z.r;
        e["level"] = z.level;
        if (z.camstate) {
            e["camstate"] = *z.camstate;
        } else {
            e["camstate"] = nullptr;
        }
        e["name"] = z.name;
        arr.push_back(std::move(e));
    }
    re4vr::save_json_file(ZONES_FILE, arr);
}

int RE4VRKillswitch::reload_zones() {
    load_zones();
    return (int)m_zones.size();
}

std::pair<bool, std::string> RE4VRKillswitch::mark_current_zone(int level, std::optional<float> radius) {
    if (level != 2 && level != 3 && level != 4) {
        return {false, "level muss 2, 3 oder 4 sein"};
    }
    const auto* e = get_current_entry();
    if (!e || !e->pos) {
        return {false, "kein Event-Eintritt erfasst"};
    }
    Zone z{};
    z.stage = e->stage;
    z.space = e->space;
    z.x = e->pos->x;
    z.y = e->pos->y;
    z.z = e->pos->z;
    z.r = radius.value_or(3.0f);
    z.level = level;
    z.camstate = e->camstate;
    char buf[128]{};
    std::snprintf(buf, sizeof(buf), "KS%d stage=%s cam=%s", level, opt_to_str(e->stage).c_str(), opt_to_str(e->camstate).c_str());
    z.name = buf;
    m_zones.push_back(z);
    save_zones();
    return {true, {}};
}

std::pair<bool, std::string> RE4VRKillswitch::remove_last_zone() {
    if (m_zones.empty()) {
        return {false, "keine Zonen"};
    }
    m_zones.pop_back();
    save_zones();
    return {true, {}};
}

void RE4VRKillswitch::reset_runtime() {
    m_killswitch_active = false;
    m_pin_release_active = false;
    m_ks2_active = false;
    m_ks3_active = false;
    m_ks5_active = false;
    m_fp_latch = false;
    m_fp_latch_state.reset();
    m_fp_latch_level = 0;
    m_damage_until = 0.0;
    m_jumpdown_until = 0.0;
    m_jumpdown_confirmed = false;
    m_was_active = false;
    m_prev_full_off = false;
    m_prev_ks4_exit = false;
    RE4VRShared::get()->re4_ks4_exit_t.reset();
    m_anim_blend_back = 0.0f;
    m_force_killswitch = false;
    m_character_manager = nullptr;
    m_camera_system = nullptr;
    m_gui_manager = nullptr;
    m_mfsm2 = nullptr;
    m_mfsm2_body = nullptr;
    m_motion = nullptr;
    m_motion_body = nullptr;
    m_cur_episode_entry.reset();
    m_last_episode_entry.reset();
    m_eval_frame = -1;
    load_zones();
}

std::optional<std::string> RE4VRKillswitch::on_initialize() {
    load_ks_cfg();
    load_zones();

    m_player_cam_td = sdk::find_type_definition("chainsaw.PlayerCameraController");
    m_gimmick_motion_td = sdk::find_type_definition("chainsaw.GimmickMotionCameraController");
    m_gimmick_fix_td = sdk::find_type_definition("chainsaw.GimmickFixCameraController");
    m_action_camera_td = sdk::find_type_definition("chainsaw.ActionCameraController");
    m_vehicle_camera_td = sdk::find_type_definition("chainsaw.VehicleCameraController");
    m_leaning_ladder_td = sdk::find_type_definition("chainsaw.GmLeaningLadder");

    if (auto* ladder_td = sdk::find_type_definition("chainsaw.GmLadderBase")) {
        if (auto* m = ladder_td->get_method("tryUse")) {
            g_hookman.add(m, &RE4VRKillswitch::pre_try_use, &RE4VRKillswitch::post_try_use);
            m_hooked = true;
            spdlog::info("[RE4VRKillswitch] Hooked GmLadderBase.tryUse");
        }
    }

    if (!m_ui_added) {
        RE4VRMenu::get()->add(20, "ks_fp_events", [this]() {
            bool on = m_fp_enabled;
            if (ImGui::Checkbox("Enable Firstperson Events", &on)) {
                set_fp_enabled(on);
            }
        });
        m_ui_added = true;
    }
    return std::nullopt;
}

void RE4VRKillswitch::on_lua_state_created(sol::state& lua) {
    m_fp_enabled = true;
    m_ks2_as_ks4 = true;
    load_ks_cfg();
    lua["__re4_ks_fp_enabled"] = m_fp_enabled;
    lua["__re4_ks2_as_ks4"] = m_ks2_as_ks4;
    lua["__re4_evt40510_t"] = sol::nil;
    lua["__re4_gang3rd_t"] = sol::nil;
    lua["__re4_leaning_ladder_hook"] = true;
    lua["__re4_ks_active"] = false;
    lua["__re4_ks4_active"] = false;
    install_lua_api(lua);
}

void RE4VRKillswitch::on_lua_state_destroyed(sol::state&) {
    reset_runtime();
}

void RE4VRKillswitch::install_lua_api(sol::state& lua) {
    auto t = lua.create_table();
    t["is_active"] = [this]() { return is_active(); };
    t["is_pin_release"] = [this]() { return is_pin_release(); };
    t["is_ks2"] = [this]() { return is_ks2(); };
    t["is_ks3"] = [this]() { return is_ks3(); };
    t["is_ks4"] = [this]() { return is_ks4(); };
    t["is_ks5"] = [this]() { return is_ks5(); };
    t["is_fp_only"] = [this]() { return is_fp_only(); };
    t["just_activated"] = [this]() { return just_activated(); };
    t["just_deactivated"] = [this]() { return just_deactivated(); };
    t["is_cutscene_active"] = [this]() { return is_cutscene_active(); };
    t["is_real_cutscene"] = [this]() { return is_real_cutscene(); };
    t["is_crouch_active"] = [this]() { return is_crouch_active(); };
    t["is_player_camera_active"] = [this]() { return is_player_camera_active(); };
    t["is_pure_gameplay"] = [this]() { return is_pure_gameplay(); };
    t["get_busy_controller"] = [this]() { return get_busy_controller(); };
    t["get_controller"] = [this]() { return get_controller(); };
    t["get_previous_controller"] = [this]() { return get_previous_controller(); };
    t["get_cam_state"] = [this]() { return get_cam_state(); };
    t["get_stage_name"] = [this]() { return get_stage_name(); };
    t["get_space_id"] = [this]() { return get_space_id(); };
    t["get_anim_blend_back"] = [this]() { return get_anim_blend_back(); };
    t["get_activating_controller"] = [this]() { return get_activating_controller(); };
    t["get_fp_enabled"] = [this]() { return get_fp_enabled(); };
    t["set_fp_enabled"] = [this](sol::object v) {
        set_fp_enabled(v.is<bool>() ? v.as<bool>() : (v.get_type() != sol::type::nil && v.get_type() != sol::type::none));
    };
    t["get_player_context"] = [this]() { return get_player_context_api(); };
    t["get_zone_count"] = [this]() { return get_zone_count(); };
    t["reload_zones"] = [this]() { return reload_zones(); };
    t["get_zones"] = [this](sol::this_state s) {
        sol::state_view lua(s);
        auto arr = lua.create_table();
        int i = 1;
        for (const auto& z : m_zones) {
            arr[i++] = zone_to_lua(lua, z);
        }
        return arr;
    };
    t["get_current_entry"] = [this](sol::this_state s) -> sol::object {
        sol::state_view lua(s);
        const auto* e = get_current_entry();
        if (!e) {
            return sol::nil;
        }
        return entry_to_lua(lua, *e);
    };
    t["mark_current_zone"] = [this](sol::this_state s, sol::object level_o, sol::object radius_o) {
        sol::state_view lua(s);
        int level = 0;
        if (level_o.is<int>()) {
            level = level_o.as<int>();
        } else if (level_o.is<double>()) {
            level = (int)level_o.as<double>();
        }
        std::optional<float> radius;
        if (radius_o.is<double>()) {
            radius = (float)radius_o.as<double>();
        } else if (radius_o.is<int>()) {
            radius = (float)radius_o.as<int>();
        }
        auto [ok, err] = mark_current_zone(level, radius);
        sol::variadic_results r;
        r.push_back({s, sol::in_place, ok});
        if (ok) {
            r.push_back({s, sol::in_place, zone_to_lua(lua, m_zones.back())});
        } else {
            r.push_back({s, sol::in_place, err});
        }
        return r;
    };
    t["remove_last_zone"] = [this](sol::this_state s) {
        Zone removed{};
        const bool had = !m_zones.empty();
        if (had) {
            removed = m_zones.back();
        }
        auto [ok, err] = remove_last_zone();
        sol::variadic_results r;
        r.push_back({s, sol::in_place, ok});
        if (ok && had) {
            r.push_back({s, sol::in_place, zone_to_lua(sol::state_view(s), removed)});
        } else {
            r.push_back({s, sol::in_place, err});
        }
        return r;
    };
    lua["package"]["loaded"]["re4vr/re4_vr_killswitch"] = t;
    lua["__re4_ks_cam_now"] = [this]() { return m_current_cam_state; };
}

void RE4VRKillswitch::on_pre_application_entry(void*, const char*, size_t hash) {
    if (hash != "UpdateScene"_fnv) {
        return;
    }
    tick_update_scene();
}

void RE4VRKillswitch::on_application_entry(void*, const char*, size_t hash) {
    if (hash != "UpdateScene"_fnv) {
        return;
    }
    tick_update_scene();
}

void RE4VRKillswitch::tick_update_scene() {
    ScriptProfileGuard guard("re4vr/re4_vr_killswitch.lua", "on_application_entry:UpdateScene", re4vr::profile_frame());
    const auto f = VR::get()->get_frame_count();
    if (f == m_eval_frame) {
        return;
    }
    m_eval_frame = f;
    try {
        evaluate();
    } catch (...) {
        if (!m_has_err) {
            m_has_err = true;
            RE4VRShared::get()->re4_ks_err = std::string{"evaluate exception"};
        }
    }
}

HookManager::PreHookResult RE4VRKillswitch::pre_try_use(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    auto& self = *get();
    auto* ladder = args.size() > 1 ? (::REManagedObject*)args[1] : nullptr;
    if (!re4vr::obj_ok(ladder)) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    if (!self.m_leaning_ladder_td) {
        self.m_leaning_ladder_td = sdk::find_type_definition("chainsaw.GmLeaningLadder");
    }
    if (self.m_leaning_ladder_td) {
        auto* td = utility::re_managed_object::get_type_definition(ladder);
        if (td && td->is_a(self.m_leaning_ladder_td)) {
            RE4VRShared::get()->re4_leaning_ladder_mounted = true;
        }
    }
    return HookManager::PreHookResult::CALL_ORIGINAL;
}

void RE4VRKillswitch::post_try_use(uintptr_t&, sdk::RETypeDefinition*, uintptr_t) {}

::REManagedObject* RE4VRKillswitch::character_manager() {
    if (!re4vr::obj_ok(m_character_manager)) {
        m_character_manager = sdk::get_managed_singleton<::REManagedObject>("chainsaw.CharacterManager");
    }
    return re4vr::obj_ok(m_character_manager) ? m_character_manager : nullptr;
}

::REManagedObject* RE4VRKillswitch::camera_system() {
    if (!re4vr::obj_ok(m_camera_system)) {
        m_camera_system = re4vr::camera_system();
    }
    return re4vr::obj_ok(m_camera_system) ? m_camera_system : nullptr;
}

::REManagedObject* RE4VRKillswitch::gui_manager() {
    if (!re4vr::obj_ok(m_gui_manager)) {
        m_gui_manager = sdk::get_managed_singleton<::REManagedObject>("chainsaw.GuiManager");
    }
    return re4vr::obj_ok(m_gui_manager) ? m_gui_manager : nullptr;
}

::REManagedObject* RE4VRKillswitch::player_context() {
    return re4vr::player_context();
}

::REGameObject* RE4VRKillswitch::player_body() {
    return re4vr::body_game_object();
}

std::optional<Vector3f> RE4VRKillswitch::player_pos() {
    auto* tf = re4vr::body_transform();
    if (!tf) {
        return std::nullopt;
    }
    auto p = re4vr::safe([&] { return sdk::get_transform_position(tf); });
    if (!p) {
        return std::nullopt;
    }
    return Vector3f{p->x, p->y, p->z};
}

std::pair<std::optional<int32_t>, std::optional<int32_t>> RE4VRKillswitch::read_stage_space() {
    auto* ctx = player_context();
    if (!re4vr::obj_ok(ctx)) {
        return {std::nullopt, std::nullopt};
    }
    auto stage = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(ctx, "get_CurrentStageID"); });
    auto space = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(ctx, "get_CurrentSpaceID"); });
    return {stage, space};
}

::REManagedObject* RE4VRKillswitch::get_busy_controller() {
    auto* csys = camera_system();
    if (!csys) {
        return nullptr;
    }
    auto* main = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(csys, "get_MainCameraController"); }).value_or(nullptr);
    if (!re4vr::obj_ok(main)) {
        return nullptr;
    }
    auto* busy = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(main, "get_BusyCameraController"); }).value_or(nullptr);
    return re4vr::obj_ok(busy) ? busy : nullptr;
}

bool RE4VRKillswitch::is_player_cam(::REManagedObject* busy) {
    if (!re4vr::obj_ok(busy)) {
        return false;
    }
    if (!m_player_cam_td) {
        m_player_cam_td = sdk::find_type_definition("chainsaw.PlayerCameraController");
    }
    if (!m_player_cam_td) {
        return false;
    }
    auto* td = utility::re_managed_object::get_type_definition(busy);
    return td && td->is_a(m_player_cam_td);
}

bool RE4VRKillswitch::player_gimmick_active() {
    auto* ctx = player_context();
    if (!re4vr::obj_ok(ctx)) {
        return false;
    }
    for (auto* fn : GIMMICK_FLAGS) {
        if (re4vr::safe([&] { return sdk::call_object_func_easy<bool>(ctx, fn); }).value_or(false)) {
            return true;
        }
    }
    return false;
}

std::optional<int32_t> RE4VRKillswitch::coop_jacked_prio() {
    if (m_coop_jacked_tried && m_coop_jacked_prio) {
        return m_coop_jacked_prio;
    }
    auto* td = sdk::find_type_definition("chainsaw.OccupiedMediatorPriority");
    auto* f = td ? td->get_field("PL_JACKED_COOP_READY") : nullptr;
    m_coop_jacked_prio = static_enum_i32(f);
    m_coop_jacked_tried = m_coop_jacked_prio.has_value();
    return m_coop_jacked_prio;
}

bool RE4VRKillswitch::player_is_coop_jacked() {
    auto want = coop_jacked_prio();
    if (!want) {
        return false;
    }
    auto* ctx = player_context();
    if (!re4vr::obj_ok(ctx)) {
        return false;
    }
    auto* occ = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_OccupiedInfo"); }).value_or(nullptr);
    auto prio = call_priority(occ);
    return prio && *prio == *want;
}

const std::unordered_set<int32_t>* RE4VRKillswitch::grappled_prio() {
    if (m_grappled_prio) {
        return &*m_grappled_prio;
    }
    auto* td = sdk::find_type_definition("chainsaw.OccupiedMediatorPriority");
    if (!td) {
        return nullptr;
    }
    std::unordered_set<int32_t> set;
    for (auto* nm : {"GRAPPLED", "GRAPPLED_FATAL"}) {
        if (auto v = static_enum_i32(td->get_field(nm))) {
            set.insert(*v);
        }
    }
    if (set.empty()) {
        return nullptr;
    }
    m_grappled_prio = std::move(set);
    return &*m_grappled_prio;
}

bool RE4VRKillswitch::player_is_grappled() {
    auto* want = grappled_prio();
    if (!want) {
        return false;
    }
    auto* ctx = player_context();
    if (!re4vr::obj_ok(ctx)) {
        return false;
    }
    auto* occ = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_OccupiedInfo"); }).value_or(nullptr);
    auto prio = call_priority(occ);
    return prio && want->count(*prio) != 0;
}

bool RE4VRKillswitch::player_is_boxbreak() {
    auto* ctx = player_context();
    if (!re4vr::obj_ok(ctx)) {
        return false;
    }
    return re4vr::safe([&] { return sdk::call_object_func_easy<bool>(ctx, "get_IsBoxBreak"); }).value_or(false);
}

bool RE4VRKillswitch::player_is_ladder() {
    auto* ctx = player_context();
    if (!re4vr::obj_ok(ctx)) {
        return false;
    }
    return re4vr::safe([&] { return sdk::call_object_func_easy<bool>(ctx, "get_IsLadder"); }).value_or(false);
}

::REManagedObject* RE4VRKillswitch::find_mfsm2(::REGameObject* body) {
    auto* c = re4vr::get_component((::REManagedObject*)body, "via.motion.MotionFsm2");
    if (re4vr::obj_ok(c)) {
        return c;
    }
    auto* comps = re4vr::safe([&] { return sdk::call_object_func_easy<::sdk::SystemArray*>((::REManagedObject*)body, "get_Components"); }).value_or(nullptr);
    if (!comps) {
        return nullptr;
    }
    const auto n = comps->get_size();
    for (int i = 0; i < (int)n; ++i) {
        auto* c2 = comps->get_element(i);
        if (!re4vr::obj_ok(c2)) {
            continue;
        }
        auto* td = utility::re_managed_object::get_type_definition(c2);
        if (!td) {
            continue;
        }
        auto tn = to_lower(td->get_full_name());
        if (tn.find("motionfsm2") != std::string::npos) {
            return c2;
        }
    }
    return nullptr;
}

::REManagedObject* RE4VRKillswitch::find_motion(::REGameObject* body) {
    return re4vr::get_component((::REManagedObject*)body, "via.motion.Motion");
}

bool RE4VRKillswitch::is_crouch_active() {
    auto* body = player_body();
    if (!re4vr::obj_ok((::REManagedObject*)body)) {
        m_mfsm2 = nullptr;
        m_mfsm2_body = nullptr;
        return false;
    }
    if (body != m_mfsm2_body) {
        m_mfsm2 = nullptr;
        m_mfsm2_body = body;
    }
    if (!re4vr::obj_ok(m_mfsm2)) {
        m_mfsm2 = find_mfsm2(body);
    }
    if (!re4vr::obj_ok(m_mfsm2)) {
        return false;
    }
    auto* node = re4vr::safe([&] { return sdk::call_object_func_easy<::SystemString*>(m_mfsm2, "getCurrentNodeName", 0); }).value_or(nullptr);
    auto s = sys_str(node);
    return s && contains_ci(*s, "CROUCH");
}

bool RE4VRKillswitch::player_node_has(std::string_view token) {
    if (token.empty()) {
        return false;
    }
    auto* body = player_body();
    if (!re4vr::obj_ok((::REManagedObject*)body)) {
        m_mfsm2 = nullptr;
        m_mfsm2_body = nullptr;
        return false;
    }
    if (body != m_mfsm2_body) {
        m_mfsm2 = nullptr;
        m_mfsm2_body = body;
    }
    if (!re4vr::obj_ok(m_mfsm2)) {
        m_mfsm2 = find_mfsm2(body);
    }
    if (!re4vr::obj_ok(m_mfsm2)) {
        return false;
    }
    for (int layer = 0; layer <= 7; ++layer) {
        auto* n = re4vr::safe([&] { return sdk::call_object_func_easy<::SystemString*>(m_mfsm2, "getCurrentNodeName", layer); }).value_or(nullptr);
        auto s = sys_str(n);
        if (s && contains_ci(*s, token)) {
            return true;
        }
    }
    return false;
}

bool RE4VRKillswitch::player_jack_has(std::string_view token) {
    if (token.empty()) {
        return false;
    }
    auto* body = player_body();
    if (!re4vr::obj_ok((::REManagedObject*)body)) {
        m_motion = nullptr;
        m_motion_body = nullptr;
        return false;
    }
    if (body != m_motion_body) {
        m_motion = nullptr;
        m_motion_body = body;
    }
    if (!re4vr::obj_ok(m_motion)) {
        m_motion = find_motion(body);
    }
    if (!re4vr::obj_ok(m_motion)) {
        return false;
    }
    const auto lc = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(m_motion, "getLayerCount"); }).value_or(0);
    for (int i = 0; i < lc; ++i) {
        auto* lay = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(m_motion, "getLayer", i); }).value_or(nullptr);
        if (!re4vr::obj_ok(lay)) {
            continue;
        }
        if (!re4vr::safe([&] { return sdk::call_object_func_easy<bool>(lay, "get_Jacked"); }).value_or(false)) {
            continue;
        }
        auto* jf = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(lay, "get_JackFrom"); }).value_or(nullptr);
        auto* nm = jf ? re4vr::safe([&] { return sdk::call_object_func_easy<::SystemString*>(jf, "get_Name"); }).value_or(nullptr) : nullptr;
        auto s = sys_str(nm);
        if (s && ends_with_ci(*s, token)) {
            return true;
        }
    }
    return false;
}

bool RE4VRKillswitch::player_is_ladder_exit(bool cam_is_gameplay) {
    auto* ctx = player_context();
    if (!re4vr::obj_ok(ctx)) {
        return false;
    }
    if (m_ladder_exit_latched) {
        if (cam_is_gameplay) {
            m_ladder_exit_latched = false;
            return false;
        }
        return true;
    }
    if (!re4vr::safe([&] { return sdk::call_object_func_easy<bool>(ctx, "get_IsLadder"); }).value_or(false)) {
        return false;
    }
    auto* body = player_body();
    if (!re4vr::obj_ok((::REManagedObject*)body)) {
        m_motion = nullptr;
        m_motion_body = nullptr;
        return false;
    }
    if (body != m_motion_body) {
        m_motion = nullptr;
        m_motion_body = body;
    }
    if (!re4vr::obj_ok(m_motion)) {
        m_motion = find_motion(body);
    }
    if (!re4vr::obj_ok(m_motion)) {
        return false;
    }
    const auto lc = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(m_motion, "getLayerCount"); }).value_or(0);
    for (int i = 0; i < lc; ++i) {
        auto* lay = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(m_motion, "getLayer", i); }).value_or(nullptr);
        if (!re4vr::obj_ok(lay) || !re4vr::safe([&] { return sdk::call_object_func_easy<bool>(lay, "get_Jacked"); }).value_or(false)) {
            continue;
        }
        auto ef = re4vr::safe([&] { return sdk::call_object_func_easy<float>(lay, "get_EndFrame"); });
        if (!ef) {
            if (auto efi = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(lay, "get_EndFrame"); })) {
                ef = (float)*efi;
            }
        }
        if (ef && *ef > LADDER_EXIT_ENDFRAME) {
            m_ladder_exit_latched = true;
            return true;
        }
    }
    return false;
}

void RE4VRKillswitch::resolve_state_vals() {
    if (m_gameplay_vals) {
        return;
    }
    auto* td = sdk::find_type_definition("chainsaw.CameraDefine.PlayerCameraState");
    if (!td) {
        return;
    }
    std::unordered_set<std::string> want_gp, want_pr, want_k2, want_k3, want_k4;
    for (auto* n : GAMEPLAY_CAM_STATES) {
        want_gp.insert(n);
    }
    for (auto* n : PIN_RELEASE_CAM_STATES) {
        want_pr.insert(n);
    }
    for (auto* n : KS2_CAM_STATES) {
        want_k2.insert(n);
    }
    for (auto* n : KS3_CAM_STATES) {
        want_k3.insert(n);
    }
    for (auto* n : KS4_CAM_STATES) {
        want_k4.insert(n);
    }
    std::unordered_map<std::string, int32_t> name_to_int;
    std::unordered_set<int32_t> gp, pr, k2, k3, k4;
    for (auto* f : td->get_fields()) {
        if (!f || !f->is_static()) {
            continue;
        }
        const char* nm = f->get_name();
        if (!nm) {
            continue;
        }
        auto v = static_enum_i32(f);
        if (!v) {
            continue;
        }
        name_to_int[nm] = *v;
        if (want_gp.count(nm)) {
            gp.insert(*v);
        }
        if (want_pr.count(nm)) {
            pr.insert(*v);
        }
        if (want_k2.count(nm)) {
            k2.insert(*v);
        }
        if (want_k3.count(nm)) {
            k3.insert(*v);
        }
        if (want_k4.count(nm)) {
            k4.insert(*v);
        }
    }
    if (name_to_int.empty()) {
        return;
    }
    m_gameplay_vals = std::move(gp);
    m_pinrelease_vals = std::move(pr);
    m_ks2_vals = std::move(k2);
    m_ks3_vals = std::move(k3);
    m_ks4_vals = std::move(k4);
    if (auto it = name_to_int.find("Damage"); it != name_to_int.end()) {
        m_damage_int = it->second;
    }
    if (auto it = name_to_int.find("HookShot"); it != name_to_int.end()) {
        m_hookshot_int = it->second;
    }
    if (auto it = name_to_int.find("Gimmick"); it != name_to_int.end()) {
        m_gimmick_int = it->second;
    }
    if (auto it = name_to_int.find("Landing"); it != name_to_int.end()) {
        m_landing_int = it->second;
    }
    if (auto it = name_to_int.find("ForceCrouch"); it != name_to_int.end()) {
        m_forcecrouch_int = it->second;
    }
}

bool RE4VRKillswitch::is_gameplay_camstate(std::optional<int32_t> st) {
    if (!st) {
        return true;
    }
    resolve_state_vals();
    if (!m_gameplay_vals) {
        return true;
    }
    return m_gameplay_vals->count(*st) != 0;
}

bool RE4VRKillswitch::is_pinrelease_camstate(std::optional<int32_t> st) {
    if (!st) {
        return false;
    }
    resolve_state_vals();
    if (!m_pinrelease_vals) {
        return false;
    }
    return m_pinrelease_vals->count(*st) != 0;
}

bool RE4VRKillswitch::is_airborne_camstate(std::optional<int32_t> st) {
    if (!st) {
        return false;
    }
    if (is_pinrelease_camstate(st)) {
        return true;
    }
    return m_landing_int && *st == *m_landing_int;
}

bool RE4VRKillswitch::match_level(std::optional<int32_t> st, const std::optional<std::unordered_set<int32_t>>& vals, const std::vector<LevelRule>& rules) {
    if (!st) {
        return false;
    }
    resolve_state_vals();
    if (vals && vals->count(*st)) {
        return true;
    }
    for (const auto& r : rules) {
        if (r.state != *st) {
            continue;
        }
        for (const auto& tk : r.jack) {
            if (player_jack_has(tk)) {
                return true;
            }
        }
        for (const auto& tk : r.node) {
            if (player_node_has(tk)) {
                return true;
            }
        }
    }
    return false;
}

bool RE4VRKillswitch::is_ks2_camstate(std::optional<int32_t> st) {
    return match_level(st, m_ks2_vals, m_ks2_rules);
}
bool RE4VRKillswitch::is_ks3_camstate(std::optional<int32_t> st) {
    return match_level(st, m_ks3_vals, m_ks3_rules);
}
bool RE4VRKillswitch::is_ks4_camstate(std::optional<int32_t> st) {
    return match_level(st, m_ks4_vals, m_ks4_rules);
}

std::optional<int> RE4VRKillswitch::zone_level_for(const EpisodeEntry* entry) {
    if (!entry || !entry->pos) {
        return std::nullopt;
    }
    const auto px = entry->pos->x, py = entry->pos->y, pz = entry->pos->z;
    std::optional<int> best_lvl;
    std::optional<float> best_d2;
    for (const auto& z : m_zones) {
        if (z.stage != entry->stage) {
            continue;
        }
        if (z.camstate && z.camstate != entry->camstate) {
            continue;
        }
        const float dx = px - z.x, dy = py - z.y, dz = pz - z.z;
        const float d2 = dx * dx + dy * dy + dz * dz;
        const float r = z.r;
        if (d2 <= r * r) {
            if (z.level == 3) {
                return 3;
            }
            if (!best_lvl || d2 < *best_d2) {
                best_lvl = z.level;
                best_d2 = d2;
            }
        }
    }
    return best_lvl;
}

bool RE4VRKillswitch::is_real_cutscene_impl(std::optional<std::string>* why) {
    auto* csys = camera_system();
    if (csys) {
        if (re4vr::safe([&] { return sdk::call_object_func_easy<bool>(csys, "get_IsEventCamera"); }).value_or(false)) {
            if (why) {
                *why = "IsEventCamera";
            }
            return true;
        }
    }
    auto* gm = gui_manager();
    if (gm && re4vr::safe([&] { return sdk::call_object_func_easy<bool>(gm, "get_IsPlayingEvent"); }).value_or(false)) {
        auto* busy = get_busy_controller();
        if (!is_player_cam(busy)) {
            if (why) {
                *why = "IsPlayingEvent";
            }
            return true;
        }
    }
    return false;
}

bool RE4VRKillswitch::is_real_cutscene() {
    return is_real_cutscene_impl(nullptr);
}

bool RE4VRKillswitch::is_player_camera_active() {
    return is_player_cam(get_busy_controller());
}

bool RE4VRKillswitch::is_pure_gameplay() {
    if (m_killswitch_active || m_pin_release_active || !m_current_cam_state) {
        return false;
    }
    return is_gameplay_camstate(m_current_cam_state);
}

std::optional<int32_t> RE4VRKillswitch::read_cam_state(::REManagedObject* busy) {
    return nested_int(busy, "_CurrentStateParam", "<State>k__BackingField");
}

std::optional<int32_t> RE4VRKillswitch::read_gimmick_type(::REManagedObject* busy) {
    return nested_int(busy, "_CurrentStateParam", "<GimmickType>k__BackingField");
}

std::optional<int32_t> RE4VRKillswitch::read_live_cam_state() {
    auto* busy = get_busy_controller();
    if (!is_player_cam(busy)) {
        return std::nullopt;
    }
    return read_cam_state(busy);
}

const std::unordered_set<int32_t>* RE4VRKillswitch::gondola_vals() {
    if (m_gondola_vals) {
        return &*m_gondola_vals;
    }
    auto* td = sdk::find_type_definition("chainsaw.CameraDefine.GimmickType");
    if (!td) {
        return nullptr;
    }
    std::unordered_set<int32_t> out;
    for (auto* f : td->get_fields()) {
        if (!f || !f->is_static()) {
            continue;
        }
        const char* nm = f->get_name();
        if (!nm || std::string_view{nm}.substr(0, 7) != "Gondola") {
            continue;
        }
        if (auto v = static_enum_i32(f)) {
            out.insert(*v);
        }
    }
    m_gondola_vals = std::move(out);
    return &*m_gondola_vals;
}

bool RE4VRKillswitch::has_parent_gimmick() {
    auto* ctx = player_context();
    if (!re4vr::obj_ok(ctx)) {
        return false;
    }
    std::optional<int64_t> v = re4vr::safe([&] { return sdk::call_object_func_easy<int64_t>(ctx, "get_State"); });
    if (!v) {
        if (auto v32 = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(ctx, "get_State"); })) {
            v = (int64_t)*v32;
        }
    }
    if (!v) {
        return false;
    }
    const int64_t bit = PARENT_GIMMICK_BIT;
    return ((*v % (bit * 2)) >= bit);
}

bool RE4VRKillswitch::is_on_gondola() {
    auto* vals = gondola_vals();
    if (!vals) {
        return false;
    }
    auto* busy = get_busy_controller();
    if (!is_player_cam(busy)) {
        return false;
    }
    auto gt = read_gimmick_type(busy);
    return gt && vals->count(*gt) != 0;
}

const std::unordered_set<int32_t>* RE4VRKillswitch::legtrap_vals() {
    if (m_legtrap_vals) {
        return &*m_legtrap_vals;
    }
    auto* td = sdk::find_type_definition("chainsaw.CameraDefine.GimmickType");
    if (!td) {
        return nullptr;
    }
    std::unordered_set<int32_t> out;
    for (auto* f : td->get_fields()) {
        if (!f || !f->is_static()) {
            continue;
        }
        const char* nm = f->get_name();
        if (!nm || std::string_view{nm}.size() < 11 || std::string_view{nm}.substr(0, 11) != "LegHoldTrap") {
            continue;
        }
        if (auto v = static_enum_i32(f)) {
            out.insert(*v);
        }
    }
    m_legtrap_vals = std::move(out);
    return &*m_legtrap_vals;
}

bool RE4VRKillswitch::is_in_legholdtrap() {
    auto* vals = legtrap_vals();
    if (!vals) {
        return false;
    }
    resolve_state_vals();
    if (!m_gimmick_int) {
        return false;
    }
    auto* busy = get_busy_controller();
    if (!is_player_cam(busy)) {
        return false;
    }
    if (read_cam_state(busy) != m_gimmick_int) {
        return false;
    }
    auto gt = read_gimmick_type(busy);
    return gt && vals->count(*gt) != 0;
}

std::optional<int32_t> RE4VRKillswitch::squeeze_high_prio() {
    if (m_squeeze_high_tried) {
        return m_squeeze_high_prio;
    }
    auto* td = sdk::find_type_definition("chainsaw.OccupiedMediatorPriority");
    m_squeeze_high_prio = static_enum_i32(td ? td->get_field("CH_JACKED_GMK_HIGH") : nullptr);
    m_squeeze_high_tried = m_squeeze_high_prio.has_value();
    return m_squeeze_high_prio;
}

bool RE4VRKillswitch::is_gimmick_ks3_spot() {
    auto [stage, space] = read_stage_space();
    (void)space;
    if (!stage || !GKS3_STAGES.count(*stage)) {
        return false;
    }
    bool raw = false;
    if (!m_gimmick_motion_td) {
        m_gimmick_motion_td = sdk::find_type_definition("chainsaw.GimmickMotionCameraController");
    }
    if (m_gimmick_motion_td && !PRIO_ONLY_STAGES.count(*stage)) {
        auto* busy = get_busy_controller();
        if (re4vr::obj_ok(busy)) {
            auto* td = utility::re_managed_object::get_type_definition(busy);
            if (td && td->is_a(m_gimmick_motion_td)) {
                raw = true;
            }
        }
    }
    if (!raw) {
        auto want = squeeze_high_prio();
        if (want) {
            auto* ctx = player_context();
            auto* occ = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_OccupiedInfo"); }).value_or(nullptr) : nullptr;
            auto prio = call_priority(occ);
            if (prio && *prio == *want) {
                raw = true;
            }
        }
    }
    if (raw) {
        m_squeeze_latch_t = now_clock();
        RE4VRShared::get()->re4_squeeze_latch_t = m_squeeze_latch_t;
        return true;
    }
    return (now_clock() - m_squeeze_latch_t) < 0.30;
}

std::optional<int32_t> RE4VRKillswitch::minidemo_prio() {
    if (m_minidemo_prio) {
        return m_minidemo_prio;
    }
    auto* td = sdk::find_type_definition("chainsaw.OccupiedMediatorPriority");
    m_minidemo_prio = static_enum_i32(td ? td->get_field("MINI_DEMO") : nullptr);
    return m_minidemo_prio;
}

bool RE4VRKillswitch::is_minidemo_ks4_spot() {
    auto [stage, space] = read_stage_space();
    (void)space;
    if (!stage || !MINIDEMO_KS4_STAGES.count(*stage)) {
        return false;
    }
    bool raw = false;
    if (!m_gimmick_motion_td) {
        m_gimmick_motion_td = sdk::find_type_definition("chainsaw.GimmickMotionCameraController");
    }
    if (m_gimmick_motion_td && !PRIO_ONLY_STAGES.count(*stage)) {
        auto* busy = get_busy_controller();
        if (re4vr::obj_ok(busy)) {
            auto* td = utility::re_managed_object::get_type_definition(busy);
            if (td && td->is_a(m_gimmick_motion_td)) {
                raw = true;
            }
        }
    }
    if (!raw) {
        auto want = minidemo_prio();
        if (want) {
            auto* ctx = player_context();
            auto* occ = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_OccupiedInfo"); }).value_or(nullptr) : nullptr;
            auto prio = call_priority(occ);
            if (prio && *prio == *want) {
                raw = true;
            }
        }
    }
    if (raw) {
        m_minidemo_latch_t = now_clock();
        RE4VRShared::get()->re4_minidemo_latch_t = m_minidemo_latch_t;
        return true;
    }
    return (now_clock() - m_minidemo_latch_t) < 0.30;
}

std::optional<int32_t> RE4VRKillswitch::gfix_low_prio() {
    if (m_gfix_low_prio) {
        return m_gfix_low_prio;
    }
    auto* td = sdk::find_type_definition("chainsaw.OccupiedMediatorPriority");
    m_gfix_low_prio = static_enum_i32(td ? td->get_field("CH_JACKED_GMK_LOW") : nullptr).value_or(3);
    return m_gfix_low_prio;
}

bool RE4VRKillswitch::is_gimmickfix_ks4_spot() {
    auto [stage, space] = read_stage_space();
    (void)space;
    if (!stage || !GFIX_KS4_STAGES.count(*stage)) {
        return false;
    }
    if (!m_gimmick_fix_td) {
        m_gimmick_fix_td = sdk::find_type_definition("chainsaw.GimmickFixCameraController");
    }
    auto* busy = get_busy_controller();
    if (!m_gimmick_fix_td || !re4vr::obj_ok(busy)) {
        return false;
    }
    auto* td = utility::re_managed_object::get_type_definition(busy);
    if (!td || !td->is_a(m_gimmick_fix_td)) {
        return false;
    }
    auto want = gfix_low_prio();
    auto* ctx = player_context();
    auto* occ = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_OccupiedInfo"); }).value_or(nullptr) : nullptr;
    auto prio = call_priority(occ);
    return prio && want && *prio == *want;
}

bool RE4VRKillswitch::is_gimmickfix_ks5_spot() {
    auto [stage, space] = read_stage_space();
    (void)space;
    if (!stage || !GFIX_KS5_STAGES.count(*stage)) {
        return false;
    }
    bool raw = false;
    if (!m_gimmick_fix_td) {
        m_gimmick_fix_td = sdk::find_type_definition("chainsaw.GimmickFixCameraController");
    }
    if (m_gimmick_fix_td) {
        auto* busy = get_busy_controller();
        if (re4vr::obj_ok(busy)) {
            auto* td = utility::re_managed_object::get_type_definition(busy);
            if (td && td->is_a(m_gimmick_fix_td)) {
                auto want = squeeze_high_prio();
                if (want) {
                    auto* ctx = player_context();
                    auto* occ = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_OccupiedInfo"); }).value_or(nullptr) : nullptr;
                    auto prio = call_priority(occ);
                    if (prio && *prio == *want) {
                        raw = true;
                    }
                }
            }
        }
    }
    if (raw) {
        m_gfix_latch_t = now_clock();
        RE4VRShared::get()->re4_gfix_latch_t = m_gfix_latch_t;
        return true;
    }
    return (now_clock() - m_gfix_latch_t) < 0.30;
}

bool RE4VRKillswitch::is_gimmick_motion_now() {
    if (!m_gimmick_motion_td) {
        m_gimmick_motion_td = sdk::find_type_definition("chainsaw.GimmickMotionCameraController");
    }
    auto* busy = get_busy_controller();
    if (!m_gimmick_motion_td || !re4vr::obj_ok(busy)) {
        return false;
    }
    auto* td = utility::re_managed_object::get_type_definition(busy);
    return td && td->is_a(m_gimmick_motion_td);
}

const std::unordered_set<int32_t>* RE4VRKillswitch::demo_prios() {
    if (m_demo_prios) {
        return &*m_demo_prios;
    }
    auto* td = sdk::find_type_definition("chainsaw.OccupiedMediatorPriority");
    if (!td) {
        return nullptr;
    }
    std::unordered_set<int32_t> out;
    for (auto* f : td->get_fields()) {
        if (!f || !f->is_static()) {
            continue;
        }
        const char* nm = f->get_name();
        if (!nm || std::string_view{nm}.find("FOR_DEMO") == std::string_view::npos) {
            continue;
        }
        if (auto v = static_enum_i32(f)) {
            out.insert(*v);
        }
    }
    m_demo_prios = std::move(out);
    return &*m_demo_prios;
}

bool RE4VRKillswitch::is_demo_priority_now() {
    auto* vals = demo_prios();
    if (!vals) {
        return false;
    }
    auto* ctx = player_context();
    if (!re4vr::obj_ok(ctx)) {
        return false;
    }
    auto* occ = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_OccupiedInfo"); }).value_or(nullptr);
    auto p = call_priority(occ);
    return p && vals->count(*p) != 0;
}

bool RE4VRKillswitch::is_carrying() {
    auto* ctx = player_context();
    if (!re4vr::obj_ok(ctx)) {
        return false;
    }
    if (auto* f = sdk::get_object_field<bool>(ctx, "<TargetJacked>k__BackingField")) {
        return *f;
    }
    return false;
}

::REManagedObject* RE4VRKillswitch::find_elevator_59100() {
    auto* gm = sdk::get_managed_singleton<::REManagedObject>("chainsaw.GimmickManager");
    if (!re4vr::obj_ok(gm)) {
        return nullptr;
    }
    auto visit = [](::REManagedObject* core) -> ::REManagedObject* {
        if (!re4vr::obj_ok(core)) {
            return nullptr;
        }
        auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(core, "get_GameObject"); }).value_or(nullptr);
        auto* comp = go ? re4vr::get_component((::REManagedObject*)go, "chainsaw.GmElevator") : nullptr;
        return re4vr::obj_ok(comp) ? comp : nullptr;
    };
    if (auto** arrp = sdk::get_object_field<::sdk::SystemArray*>(gm, "_MoveArray")) {
        if (auto* arr = *arrp) {
            const auto n = arr->get_size();
            for (int i = 0; i < (int)n; ++i) {
                if (auto* comp = visit(arr->get_element(i))) {
                    return comp;
                }
            }
        }
    }
    if (auto** objp = sdk::get_object_field<::REManagedObject*>(gm, "_MoveArray")) {
        auto* list = *objp;
        if (re4vr::obj_ok(list)) {
            const auto n = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(list, "get_Count"); }).value_or(0);
            for (int i = 0; i < n; ++i) {
                auto* core = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(list, "get_Item", i); }).value_or(nullptr);
                if (auto* comp = visit(core)) {
                    return comp;
                }
            }
        }
    }
    return nullptr;
}

bool RE4VRKillswitch::is_riding_elevator_59100() {
    auto [stage, space] = read_stage_space();
    (void)space;
    if (!stage || *stage != 59100) {
        m_elev59100_comp = nullptr;
        return false;
    }
    if (!re4vr::obj_ok(m_elev59100_comp)) {
        m_elev59100_comp = find_elevator_59100();
    }
    if (!re4vr::obj_ok(m_elev59100_comp)) {
        return false;
    }
    return re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_elev59100_comp, "get_IsPlInElevator"); }).value_or(false);
}

bool RE4VRKillswitch::is_jetski_stage() {
    auto [stage, space] = read_stage_space();
    (void)space;
    return stage && JETSKI_KS4_STAGES.count(*stage) != 0;
}

std::optional<std::string> RE4VRKillswitch::minecart_ks4_kind() {
    auto [stage, space] = read_stage_space();
    (void)space;
    if (!stage || !MINECART_KS4_STAGES.count(*stage)) {
        return std::nullopt;
    }
    auto* busy = get_busy_controller();
    if (!re4vr::obj_ok(busy)) {
        return std::nullopt;
    }
    auto* td = utility::re_managed_object::get_type_definition(busy);
    if (!td) {
        return std::nullopt;
    }
    if (!m_action_camera_td) {
        m_action_camera_td = sdk::find_type_definition("chainsaw.ActionCameraController");
    }
    if (!m_vehicle_camera_td) {
        m_vehicle_camera_td = sdk::find_type_definition("chainsaw.VehicleCameraController");
    }
    if (m_action_camera_td && td->is_a(m_action_camera_td)) {
        return std::string{"cart"};
    }
    if (m_vehicle_camera_td && td->is_a(m_vehicle_camera_td)) {
        return std::string{"cart2"};
    }
    return std::nullopt;
}

bool RE4VRKillswitch::is_on_jetski() {
    auto [stage, space] = read_stage_space();
    (void)space;
    if (!stage || !JETSKI_KS4_STAGES.count(*stage)) {
        return false;
    }
    if (*stage != 59103) {
        return true;
    }
    auto* busy = get_busy_controller();
    if (!m_vehicle_camera_td) {
        m_vehicle_camera_td = sdk::find_type_definition("chainsaw.VehicleCameraController");
    }
    if (!re4vr::obj_ok(busy) || !m_vehicle_camera_td) {
        return false;
    }
    auto* td = utility::re_managed_object::get_type_definition(busy);
    return td && td->is_a(m_vehicle_camera_td);
}

bool RE4VRKillswitch::is_on_boat() {
    auto* ctx = player_context();
    if (!re4vr::obj_ok(ctx)) {
        return false;
    }
    if (!re4vr::safe([&] { return sdk::call_object_func_easy<bool>(ctx, "get_IsBoat"); }).value_or(false)) {
        return false;
    }
    auto* busy = get_busy_controller();
    if (!m_action_camera_td) {
        m_action_camera_td = sdk::find_type_definition("chainsaw.ActionCameraController");
    }
    if (re4vr::obj_ok(busy) && m_action_camera_td) {
        auto* td = utility::re_managed_object::get_type_definition(busy);
        if (td && td->is_a(m_action_camera_td)) {
            return false;
        }
    }
    return true;
}

void RE4VRKillswitch::resolve_parentgimmick_bit() {
    if (m_parentgimmick_bit) {
        return;
    }
    auto* td = sdk::find_type_definition("chainsaw.PlayerDefine.State");
    if (!td) {
        return;
    }
    for (auto* f : td->get_fields()) {
        if (!f || !f->is_static()) {
            continue;
        }
        const char* nm = f->get_name();
        if (!nm || std::string_view{nm} != "ParentGimmick") {
            continue;
        }
        m_parentgimmick_bit = static_enum_i64(f);
        return;
    }
}

bool RE4VRKillswitch::is_on_railcar() {
    if (!re4vr::obj_ok(m_railcar_mgr)) {
        m_railcar_mgr = sdk::get_managed_singleton<::REManagedObject>("chainsaw.RailCarManager");
    }
    if (!re4vr::obj_ok(m_railcar_mgr)) {
        return false;
    }
    auto* car = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(m_railcar_mgr, "getPlayerRailCar"); }).value_or(nullptr);
    if (!re4vr::obj_ok(car)) {
        return false;
    }
    auto* busy = get_busy_controller();
    if (!m_vehicle_camera_td) {
        m_vehicle_camera_td = sdk::find_type_definition("chainsaw.VehicleCameraController");
    }
    if (re4vr::obj_ok(busy) && m_vehicle_camera_td) {
        auto* td = utility::re_managed_object::get_type_definition(busy);
        if (td && td->is_a(m_vehicle_camera_td)) {
            return true;
        }
    }
    resolve_parentgimmick_bit();
    if (!m_parentgimmick_bit) {
        return false;
    }
    auto* ctx = player_context();
    if (!re4vr::obj_ok(ctx)) {
        return false;
    }
    std::optional<int64_t> st = re4vr::safe([&] { return sdk::call_object_func_easy<int64_t>(ctx, "get_State"); });
    if (!st) {
        if (auto v32 = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(ctx, "get_State"); })) {
            st = (int64_t)*v32;
        }
    }
    if (!st) {
        return false;
    }
    return (*st & *m_parentgimmick_bit) != 0;
}

bool RE4VRKillswitch::is_throwsight_stage() {
    auto* ctx = player_context();
    if (!re4vr::obj_ok(ctx)) {
        return false;
    }
    auto [stage, space] = read_stage_space();
    if (!stage || !space) {
        return false;
    }
    if (std::to_string(*stage) + "_" + std::to_string(*space) != "46900_46900") {
        return false;
    }
    auto* body = player_body();
    auto* tf = body ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(body, "get_Transform"); }).value_or(nullptr) : nullptr;
    if (!tf) {
        return false;
    }
    auto* current = tf;
    for (int i = 0; i < 10; ++i) {
        auto* parent_tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(current, "get_Parent"); }).value_or(nullptr);
        if (!parent_tf) {
            return false;
        }
        auto* parent_go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(parent_tf, "get_GameObject"); }).value_or(nullptr);
        if (parent_go) {
            auto* name = re4vr::safe([&] { return sdk::call_object_func_easy<::SystemString*>(parent_go, "get_Name"); }).value_or(nullptr);
            auto s = sys_str(name);
            if (s && s->find("gm02_500_00_1") != std::string::npos) {
                return true;
            }
        }
        current = parent_tf;
    }
    return false;
}

bool RE4VRKillswitch::is_in_elevator() {
    auto [stage, space] = read_stage_space();
    (void)space;
    if (!stage || *stage != ELEV.stage) {
        return false;
    }
    auto p = player_pos();
    if (!p) {
        return false;
    }
    const float xmin = std::min(ELEV.x1, ELEV.x2) - ELEV.mxz;
    const float xmax = std::max(ELEV.x1, ELEV.x2) + ELEV.mxz;
    const float zmin = std::min(ELEV.z1, ELEV.z2) - ELEV.mxz;
    const float zmax = std::max(ELEV.z1, ELEV.z2) + ELEV.mxz;
    const float ymin = std::min(ELEV.y1, ELEV.y2) + ELEV.start_release;
    const float ymax = std::max(ELEV.y1, ELEV.y2) - ELEV.top_release;
    return p->x >= xmin && p->x <= xmax && p->z >= zmin && p->z <= zmax && p->y >= ymin && p->y <= ymax;
}

const std::unordered_set<int32_t>* RE4VRKillswitch::elevtrouble_vals() {
    if (m_elevtrouble_vals) {
        return &*m_elevtrouble_vals;
    }
    auto* td = sdk::find_type_definition("chainsaw.CameraDefine.GimmickType");
    if (!td) {
        return nullptr;
    }
    std::unordered_set<int32_t> out;
    for (auto* f : td->get_fields()) {
        if (!f || !f->is_static()) {
            continue;
        }
        const char* nm = f->get_name();
        if (!nm || std::string_view{nm}.size() < 15 || std::string_view{nm}.substr(0, 15) != "ElevatorTrouble") {
            continue;
        }
        if (auto v = static_enum_i32(f)) {
            out.insert(*v);
        }
    }
    m_elevtrouble_vals = std::move(out);
    return &*m_elevtrouble_vals;
}

bool RE4VRKillswitch::is_elevator_trouble() {
    auto* vals = elevtrouble_vals();
    if (!vals) {
        return false;
    }
    resolve_state_vals();
    if (!m_gimmick_int) {
        return false;
    }
    auto* busy = get_busy_controller();
    if (!is_player_cam(busy)) {
        return false;
    }
    if (read_cam_state(busy) != m_gimmick_int) {
        return false;
    }
    auto gt = read_gimmick_type(busy);
    return gt && vals->count(*gt) != 0;
}

bool RE4VRKillswitch::is_in_elevator2_zone() {
    auto [stage, space] = read_stage_space();
    (void)space;
    if (!stage || *stage != ELEV2.stage) {
        return false;
    }
    auto p = player_pos();
    if (!p) {
        return false;
    }
    const float xmin = std::min(ELEV2.x1, ELEV2.x2) - ELEV2.mxz;
    const float xmax = std::max(ELEV2.x1, ELEV2.x2) + ELEV2.mxz;
    const float zmin = std::min(ELEV2.z1, ELEV2.z2) - ELEV2.mxz;
    const float zmax = std::max(ELEV2.z1, ELEV2.z2) + ELEV2.mxz;
    const float ymin = std::min(ELEV2.y1, ELEV2.y2) - ELEV2.y_pad;
    const float ymax = std::max(ELEV2.y1, ELEV2.y2) + ELEV2.y_pad;
    return p->x >= xmin && p->x <= xmax && p->z >= zmin && p->z <= zmax && p->y >= ymin && p->y <= ymax;
}

bool RE4VRKillswitch::is_in_elevator3_zone() {
    auto [stage, space] = read_stage_space();
    (void)space;
    if (!stage || *stage != 55300) {
        return false;
    }
    auto p = player_pos();
    if (!p) {
        return false;
    }
    return p->x >= 175.5f && p->x <= 181.6f && p->z >= 85.8f && p->z <= 92.0f && p->y >= -75.14f;
}

bool RE4VRKillswitch::is_parented_to_elevator() {
    return RE4VRShared::get()->re4_on_elevator2;
}

bool RE4VRKillswitch::is_in_elevator5_cabin() {
    auto [stg, space] = read_stage_space();
    (void)space;
    if (!stg || (*stg != 56300 && *stg != 56201)) {
        return false;
    }
    auto p = player_pos();
    if (!p) {
        return false;
    }
    if (p->y < -10.0f || p->y > 55.0f) {
        return false;
    }
    const float dx = p->x - ELEV5_X, dz = p->z - ELEV5_Z;
    return (dx * dx + dz * dz) <= (ELEV5_R * ELEV5_R);
}

bool RE4VRKillswitch::elev5_at_endpoint(float y) {
    return std::abs(y - ELEV5_Y_UNTEN) <= ELEV5_Y_TOL || std::abs(y - ELEV5_Y_OBEN) <= ELEV5_Y_TOL;
}

bool RE4VRKillswitch::elevator5_update() {
    auto p = player_pos();
    if (!p) {
        m_elev5.latch = false;
        m_elev5.prev_gim = false;
        m_elev5.y.reset();
        return false;
    }
    resolve_state_vals();
    const auto now = now_clock();
    auto cam = read_live_cam_state();
    const bool gim = m_gimmick_int && cam == m_gimmick_int;
    if (m_elev5.prev_gim && !gim && elev5_at_endpoint(p->y)) {
        m_elev5.latch = true;
        m_elev5.y = p->y;
        m_elev5.t = now;
        m_elev5.still_since = now;
        m_elev5.moved_once = false;
        m_elev5.target = (std::abs(p->y - ELEV5_Y_UNTEN) <= ELEV5_Y_TOL) ? ELEV5_Y_OBEN : ELEV5_Y_UNTEN;
    }
    m_elev5.prev_gim = gim;
    if (m_elev5.latch) {
        if ((now - m_elev5.t) >= 0.15) {
            if (std::abs(p->y - m_elev5.y.value_or(p->y)) > 0.05f) {
                m_elev5.still_since = now;
                m_elev5.moved_once = true;
            }
            m_elev5.y = p->y;
            m_elev5.t = now;
        }
        if (m_elev5.target && std::abs(p->y - *m_elev5.target) <= ELEV5_Y_TOL) {
            m_elev5.latch = false;
        }
        if (m_elev5.moved_once && (now - m_elev5.still_since) > 1.5) {
            m_elev5.latch = false;
        }
    }
    return m_elev5.latch;
}

void RE4VRKillswitch::reset_frame_flags() {
    m_pin_release_active = false;
    m_ks2_active = false;
    m_ks3_active = false;
    m_ks4_active = false;
    m_ks5_active = false;
    m_boxbreak_active = false;
    RE4VRShared::get()->re4_leaning_ladder_active = false;
    RE4VRShared::get()->re4_minecart_ks4_active = false;
    RE4VRShared::get()->re4_minecart2_ks4_active = false;
    RE4VRShared::get()->re4_grappled_active = false;
    RE4VRShared::get()->re4_gondola_active = false;
    RE4VRShared::get()->re4_railcar_mode = false;
    m_jetski_active = false;
    RE4VRShared::get()->re4_jetski_active = false;
    RE4VRShared::get()->re4_boat_active = false;
    RE4VRShared::get()->re4_forcecrouch_ks4_active = false;
    RE4VRShared::get()->re4_in_squeeze = false;
    RE4VRShared::get()->re4_ks_keep_movement = false;
}

void RE4VRKillswitch::evaluate_core() {
    reset_frame_flags();
    m_fp_enabled = RE4VRShared::get()->re4_ks_fp_enabled;
    m_ks2_as_ks4 = RE4VRShared::get()->re4_ks2_as_ks4;

    auto set_ks4 = [&](const char* reason, bool latch = true, int latch_level = 4) {
        m_killswitch_active = true;
        m_ks4_active = true;
        m_pin_release_active = false;
        m_activating_reason = reason;
        if (latch) {
            m_fp_latch = true;
            m_fp_latch_state.reset();
            m_fp_latch_level = latch_level;
        }
    };
    auto set_gameplay = [&](const char* reason) {
        m_killswitch_active = false;
        m_pin_release_active = false;
        RE4VRShared::get()->re4_throwsight_active = false;
        m_activating_reason = reason;
        m_fp_latch = false;
        m_fp_latch_state.reset();
        m_fp_latch_level = 0;
    };

    if (m_force_killswitch) {
        m_killswitch_active = true;
        m_activating_reason = "force";
        return;
    }
    if (RE4VRShared::get()->re4_force_killswitch_scope) {
        m_killswitch_active = true;
        m_activating_reason = "viascope";
        return;
    }
    if (RE4VRShared::get()->re4_force_killswitch_bolt) {
        m_killswitch_active = true;
        m_ks4_active = true;
        RE4VRShared::get()->re4_ks4_active = true;
        m_activating_reason = "boltcycle";
        return;
    }
    if (RE4VRShared::get()->re4_force_ks4_bulletrush) {
        set_ks4("ks4_bulletrush");
        RE4VRShared::get()->re4_ks4_active = true;
        return;
    }
    if (is_elevator_trouble()) {
        set_ks4("ks4_elevatortrouble", false);
        RE4VRShared::get()->re4_ks4_active = true;
        RE4VRShared::get()->re4_throwsight_active = false;
        return;
    }
    if (is_in_elevator()) {
        set_gameplay("gameplay_elevator");
        return;
    }

    if (is_in_elevator5_cabin()) {
        if (elevator5_update() && !is_real_cutscene()) {
            set_gameplay("gameplay_elevator5");
            return;
        }
    } else {
        m_elev5.latch = false;
        m_elev5.prev_gim = false;
        m_elev5.y.reset();
        m_elev5.target.reset();
        m_elev5.moved_once = false;
    }

    if ((is_parented_to_elevator() || is_in_elevator2_zone() || is_in_elevator3_zone()) && !is_real_cutscene()) {
        auto ep = player_pos();
        auto [estg, espc] = read_stage_space();
        auto ecam = read_live_cam_state();
        EpisodeEntry tmp{};
        tmp.stage = estg;
        tmp.camstate = ecam;
        if (ep) {
            tmp.pos = *ep;
        }
        auto zlvl = ep ? zone_level_for(&tmp) : std::nullopt;
        if (!zlvl) {
            if (ep) {
                tmp.space = espc;
                m_cur_episode_entry = tmp;
            }
            set_gameplay("gameplay_elevator2");
            return;
        }
    }

    if (is_on_gondola() && !is_real_cutscene()) {
        m_killswitch_active = true;
        m_ks4_active = true;
        if (m_fp_enabled) {
            m_ks5_active = true;
        }
        m_pin_release_active = false;
        RE4VRShared::get()->re4_throwsight_active = false;
        RE4VRShared::get()->re4_gondola_active = true;
        m_activating_reason = "ks5_gondola";
        m_fp_latch = true;
        m_fp_latch_state.reset();
        m_fp_latch_level = 4;
        return;
    }

    auto [stg_now, spc_now] = read_stage_space();
    (void)spc_now;
    if (stg_now && GONDOLA_PARENT_STAGES.count(*stg_now) && has_parent_gimmick() && !is_real_cutscene()) {
        auto* busy = get_busy_controller();
        bool is_pc_cam = true;
        if (re4vr::obj_ok(busy) && m_player_cam_td) {
            is_pc_cam = is_player_cam(busy);
        }
        if (is_pc_cam) {
            set_ks4("ks4_gondola_parent");
            RE4VRShared::get()->re4_throwsight_active = false;
            return;
        }
    }

    if (is_in_legholdtrap() && !is_real_cutscene()) {
        set_ks4("ks4_beartrap");
        RE4VRShared::get()->re4_throwsight_active = false;
        return;
    }

    if (is_riding_elevator_59100() && !is_real_cutscene() && !is_gimmick_motion_now() && !is_demo_priority_now()) {
        set_gameplay("gameplay_elevator_59100");
        return;
    }

    if (is_on_jetski() && !is_real_cutscene() && !is_gimmick_motion_now() && !is_demo_priority_now()) {
        set_ks4("ks4_jetski");
        RE4VRShared::get()->re4_throwsight_active = false;
        m_jetski_active = true;
        RE4VRShared::get()->re4_jetski_active = true;
        return;
    }

    if (is_on_boat() && !is_throwsight_stage() && !is_real_cutscene() && !is_gimmick_motion_now() && !is_demo_priority_now()) {
        set_ks4("ks4_boat");
        RE4VRShared::get()->re4_throwsight_active = false;
        RE4VRShared::get()->re4_boat_active = true;
        return;
    }

    {
        const auto now = now_clock();
        auto [fc_stg, fc_spc] = read_stage_space();
        if (fc_stg && fc_spc && *fc_stg == 40501 && *fc_spc == 40500 && m_forcecrouch_int && read_live_cam_state() == m_forcecrouch_int) {
            m_fc_ks4_until = now + 1.0;
        }
        if (now < m_fc_ks4_until && !is_real_cutscene()) {
            set_ks4("ks4_forcecrouch");
            RE4VRShared::get()->re4_throwsight_active = false;
            RE4VRShared::get()->re4_forcecrouch_active = false;
            RE4VRShared::get()->re4_forcecrouch_ks4_active = true;
            return;
        }
    }

    {
        bool in_gang = false;
        auto [gs, sp] = read_stage_space();
        (void)sp;
        if (gs && *gs == 60874) {
            auto gp = player_pos();
            if (gp) {
                const float ax = 30.80f, ay = 1.32f, az = 232.38f;
                const float abx = 0.46f - ax, aby = 2.66f - ay, abz = 232.14f - az;
                const float apx = gp->x - ax, apy = gp->y - ay, apz = gp->z - az;
                const float ab2 = abx * abx + aby * aby + abz * abz;
                float t = 0.0f;
                if (ab2 > 0.0f) {
                    t = (apx * abx + apy * aby + apz * abz) / ab2;
                }
                t = std::clamp(t, 0.0f, 1.0f);
                const float dx = apx - abx * t, dy = apy - aby * t, dz = apz - abz * t;
                in_gang = (dx * dx + dy * dy + dz * dz) <= 9.0f;
            }
        }
        if (!in_gang) {
            RE4VRShared::get()->re4_gang3rd_t.reset();
        } else {
            auto gt = RE4VRShared::get()->re4_gang3rd_t;
            if (!gt) {
                gt = now_clock();
                RE4VRShared::get()->re4_gang3rd_t = *gt;
            }
            if ((now_clock() - *gt) < 0.5) {
                auto* gtf = re4vr::body_transform();
                if (gtf) {
                    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(gtf, "resetBasePose"); });
                }
            }
            m_killswitch_active = true;
            m_pin_release_active = false;
            RE4VRShared::get()->re4_evt60874_fullhide = false;
            m_evt60874_t0.reset();
            m_activating_reason = "gang3rd_60874";
            return;
        }
    }

    {
        auto [ev_stg, ev_spc] = read_stage_space();
        (void)ev_spc;
        bool ev_on = false;
        if (ev_stg && *ev_stg == 60874) {
            auto want = squeeze_high_prio();
            if (want) {
                auto* ectx = player_context();
                auto* eocc = ectx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ectx, "get_OccupiedInfo"); }).value_or(nullptr) : nullptr;
                auto eprio = call_priority(eocc);
                ev_on = eprio && *eprio == *want;
            }
        }
        if (ev_on) {
            if (!m_evt60874_t0) {
                m_evt60874_t0 = now_clock();
            }
            if ((now_clock() - *m_evt60874_t0) >= EVT60874_DELAY && !is_real_cutscene()) {
                set_ks4("ks4_evt60874");
                RE4VRShared::get()->re4_evt60874_fullhide = true;
                return;
            }
            RE4VRShared::get()->re4_evt60874_fullhide = false;
        } else {
            m_evt60874_t0.reset();
            RE4VRShared::get()->re4_evt60874_fullhide = false;
        }
    }

    auto [carry_stg, carry_spc] = read_stage_space();
    (void)carry_spc;
    if (carry_stg && (*carry_stg == 68102 || *carry_stg == 68103 || *carry_stg == 68105)
        && is_carrying() && !is_real_cutscene() && !is_gimmick_motion_now() && !is_demo_priority_now()) {
        set_ks4("ks4_ashley_carry");
        RE4VRShared::get()->re4_throwsight_active = false;
        RE4VRShared::get()->re4_ks_keep_movement = true;
        return;
    }

    if (is_gimmickfix_ks4_spot()) {
        set_ks4("ks4_gfix");
        RE4VRShared::get()->re4_ks4_active = true;
        RE4VRShared::get()->re4_throwsight_active = false;
        return;
    }
    if (is_gimmickfix_ks5_spot()) {
        m_killswitch_active = true;
        m_ks4_active = true;
        if (m_fp_enabled) {
            m_ks5_active = true;
        }
        m_pin_release_active = false;
        RE4VRShared::get()->re4_throwsight_active = false;
        m_activating_reason = "ks5_gfix";
        m_fp_latch = true;
        m_fp_latch_state.reset();
        m_fp_latch_level = 4;
        return;
    }
    if (is_gimmick_ks3_spot()) {
        set_ks4("ks3_gimmick");
        RE4VRShared::get()->re4_ks4_active = true;
        RE4VRShared::get()->re4_in_squeeze = true;
        RE4VRShared::get()->re4_throwsight_active = false;
        return;
    }
    if (is_minidemo_ks4_spot()) {
        m_killswitch_active = true;
        m_ks4_active = true;
        if (m_fp_enabled) {
            m_ks5_active = true;
        }
        m_pin_release_active = false;
        RE4VRShared::get()->re4_throwsight_active = false;
        m_activating_reason = "ks5_minidemo";
        m_fp_latch = true;
        m_fp_latch_state.reset();
        m_fp_latch_level = 4;
        return;
    }

    if (auto mc_kind = minecart_ks4_kind()) {
        m_killswitch_active = true;
        m_pin_release_active = false;
        RE4VRShared::get()->re4_throwsight_active = false;
        m_ks4_active = true;
        m_fp_latch = true;
        m_fp_latch_state.reset();
        m_fp_latch_level = 4;
        if (*mc_kind == "cart2") {
            RE4VRShared::get()->re4_minecart2_ks4_active = true;
            m_activating_reason = "minecart2_ks4";
        } else {
            RE4VRShared::get()->re4_minecart_ks4_active = true;
            m_activating_reason = "minecart_ks4";
        }
        return;
    }

    if (is_on_railcar()) {
        set_ks4("railcar_mode");
        RE4VRShared::get()->re4_throwsight_active = false;
        RE4VRShared::get()->re4_railcar_mode = true;
        return;
    }

    if (player_is_grappled()) {
        m_killswitch_active = true;
        m_pin_release_active = false;
        RE4VRShared::get()->re4_throwsight_active = false;
        RE4VRShared::get()->re4_grappled_active = true;
        auto [gstg, gspc] = read_stage_space();
        (void)gspc;
        if (gstg && *gstg == 65100) {
            m_ks4_active = true;
            RE4VRShared::get()->re4_ks4_active = true;
            m_activating_reason = "ks4_grappled";
            m_fp_latch = true;
            m_fp_latch_state.reset();
            m_fp_latch_level = 4;
        } else {
            m_ks2_active = true;
            m_activating_reason = "ks2_grappled";
            m_fp_latch = true;
            m_fp_latch_state.reset();
            m_fp_latch_level = 2;
        }
        return;
    }

    {
        auto [s405, sp405] = read_stage_space();
        (void)sp405;
        if (s405 && *s405 == 40510 && is_real_cutscene()) {
            auto t0 = RE4VRShared::get()->re4_evt40510_t;
            if (!t0) {
                auto ep = player_pos();
                bool hit = false;
                if (ep) {
                    const float dx = ep->x - (-183.43f), dy = ep->y - 6.53f, dz = ep->z - 85.46f;
                    hit = (dx * dx + dy * dy + dz * dz) <= 9.0f;
                }
                t0 = hit ? now_clock() : -1.0;
                RE4VRShared::get()->re4_evt40510_t = *t0;
            }
            if (*t0 >= 0.0 && (now_clock() - *t0) < EVT40510_DELAY) {
                set_ks4("ks4_evt40510");
                return;
            }
        } else {
            RE4VRShared::get()->re4_evt40510_t.reset();
        }
    }

    std::optional<std::string> why;
    if (is_real_cutscene_impl(&why)) {
        m_killswitch_active = true;
        m_activating_reason = why;
        RE4VRShared::get()->re4_throwsight_active = false;
        return;
    }

    if (is_throwsight_stage()) {
        RE4VRShared::get()->re4_throwsight_active = true;
        m_killswitch_active = true;
        m_ks2_active = true;
        m_pin_release_active = false;
        m_activating_reason = "throwsight_ks2";
        m_fp_latch = true;
        m_fp_latch_state.reset();
        m_fp_latch_level = 2;
        return;
    }
    RE4VRShared::get()->re4_throwsight_active = false;

    auto* busy = get_busy_controller();
    std::optional<std::string> ctrl_name;
    if (re4vr::obj_ok(busy)) {
        auto* td = utility::re_managed_object::get_type_definition(busy);
        if (td) {
            ctrl_name = td->get_full_name();
        }
    }
    if (ctrl_name != m_current_controller) {
        m_previous_controller = m_current_controller;
        m_current_controller = ctrl_name;
    }

    const bool is_pc = is_player_cam(busy);
    if (is_pc) {
        auto st = read_cam_state(busy);
        m_current_cam_state = st;
        const bool gimmick_ng = player_gimmick_active() || player_is_coop_jacked();
        resolve_state_vals();
        if (m_damage_int && st == m_damage_int) {
            m_damage_until = now_clock() + DAMAGE_HOLD;
        }
        if (m_damage_int && now_clock() < m_damage_until && is_gameplay_camstate(st)) {
            st = m_damage_int;
            m_current_cam_state = st;
        }
        {
            const bool dmg_now = m_damage_int && now_clock() < m_damage_until;
            if (RE4VRShared::get()->re4_damage_active && !dmg_now) {
                RE4VRShared::get()->re4_damage_end_t = now_clock();
            }
            RE4VRShared::get()->re4_damage_active = dmg_now;
        }
        const auto now = now_clock();
        if (player_node_has("jumpdown") || player_node_has("jumpoff") || player_node_has("jump_large") || player_node_has("_jump_")) {
            m_jumpdown_confirmed = true;
            m_jumpdown_until = now + JUMPDOWN_HOLD;
        }
        if (m_jumpdown_confirmed) {
            if (is_airborne_camstate(st)) {
                m_jumpdown_until = now + JUMPDOWN_HOLD;
            } else if (is_gameplay_camstate(st)) {
                m_jumpdown_confirmed = false;
            }
        }
        if (player_is_boxbreak()) {
            m_killswitch_active = true;
            m_ks2_active = true;
            m_boxbreak_active = true;
            m_pin_release_active = false;
            m_activating_reason = std::string{"ks2_boxbreak:"} + opt_to_str(st);
            m_fp_latch = false;
            m_fp_latch_state.reset();
            m_fp_latch_level = 2;
        } else if (player_is_ladder_exit(is_gameplay_camstate(st))) {
            m_killswitch_active = true;
            m_ks2_active = true;
            m_pin_release_active = false;
            m_activating_reason = std::string{"ks2_ladder_exit:"} + opt_to_str(st);
            m_fp_latch = true;
            m_fp_latch_state = st;
            m_fp_latch_level = 2;
        } else if (player_is_ladder()) {
            m_killswitch_active = true;
            m_ks2_active = true;
            m_pin_release_active = false;
            m_activating_reason = std::string{"ks2_ladder:"} + opt_to_str(st);
            m_fp_latch = true;
            m_fp_latch_state = st;
            m_fp_latch_level = 2;
            RE4VRShared::get()->re4_leaning_ladder_active = RE4VRShared::get()->re4_leaning_ladder_mounted;
        } else if (now < m_jumpdown_until) {
            m_killswitch_active = true;
            m_ks2_active = true;
            m_pin_release_active = false;
            m_activating_reason = std::string{"jumpdown:"} + opt_to_str(st);
            m_fp_latch = false;
            m_fp_latch_state.reset();
            m_fp_latch_level = 0;
        } else if (is_gameplay_camstate(st) && !gimmick_ng) {
            m_killswitch_active = false;
            m_activating_reason.reset();
            m_fp_latch = false;
            m_fp_latch_state.reset();
            m_fp_latch_level = 0;
            RE4VRShared::get()->re4_leaning_ladder_mounted = false;
            if (m_cur_episode_entry) {
                m_last_episode_entry = m_cur_episode_entry;
                m_cur_episode_entry.reset();
            }
        } else if (is_pinrelease_camstate(st) && !gimmick_ng) {
            m_killswitch_active = false;
            m_pin_release_active = true;
            m_activating_reason = std::string{"pinrelease:"} + opt_to_str(st);
            m_fp_latch = false;
            m_fp_latch_state.reset();
            m_fp_latch_level = 0;
        } else {
            if (st != m_fp_latch_state) {
                m_fp_latch = false;
                m_fp_latch_state = st;
                m_fp_latch_level = 0;
                EpisodeEntry e{};
                auto [stg, spc] = read_stage_space();
                e.stage = stg;
                e.space = spc;
                e.camstate = st;
                e.pos = player_pos();
                m_cur_episode_entry = e;
            }
            if (!m_fp_latch) {
                auto zlvl = zone_level_for(m_cur_episode_entry ? &*m_cur_episode_entry : nullptr);
                if (zlvl == 3) {
                    m_fp_latch = true;
                    m_fp_latch_level = 3;
                } else if (zlvl == 4) {
                    m_fp_latch = true;
                    m_fp_latch_level = 4;
                } else if (zlvl == 2) {
                    m_fp_latch = true;
                    m_fp_latch_level = 2;
                } else if (is_ks3_camstate(st)) {
                    m_fp_latch = true;
                    m_fp_latch_level = 3;
                } else if (is_ks4_camstate(st)) {
                    m_fp_latch = true;
                    m_fp_latch_level = 4;
                } else if (is_ks2_camstate(st)) {
                    m_fp_latch = true;
                    m_fp_latch_level = 2;
                }
            }
            if (m_hookshot_int && st == m_hookshot_int) {
                m_hookshot_seen_t = now_clock();
                const double grace = RE4VRShared::get()->re4_hookshot_grace_sec.value_or(4.0);
                RE4VRShared::get()->re4_hookshot_recent_until = now_clock() + grace;
            }
            const double ks4_sec = RE4VRShared::get()->re4_hookshot_ks4_sec.value_or(1.5);
            if (m_gimmick_int && st == m_gimmick_int && m_hookshot_seen_t > 0.0 && (now_clock() - m_hookshot_seen_t) < ks4_sec) {
                m_fp_latch = true;
                m_fp_latch_level = 4;
            }
            if (m_fp_latch && m_damage_int && st == m_damage_int && (m_fp_latch_level == 2 || m_fp_latch_level == 4)) {
                m_fp_latch_level = 3;
            }
            m_killswitch_active = true;
            if (m_fp_latch && m_fp_latch_level == 3) {
                m_ks3_active = true;
                m_activating_reason = std::string{"ks3:"} + opt_to_str(st);
            } else if (m_fp_latch && m_fp_latch_level == 4) {
                m_ks4_active = true;
                m_activating_reason = std::string{"ks4:"} + opt_to_str(st);
            } else if (m_fp_latch && m_fp_latch_level == 2) {
                m_ks2_active = true;
                m_activating_reason = std::string{"ks2:"} + opt_to_str(st);
            } else {
                m_activating_reason = std::string{"camstate:"} + opt_to_str(st);
            }
        }
    } else {
        m_current_cam_state.reset();
        m_killswitch_active = true;
        m_activating_reason = ctrl_name.value_or("no_controller");
        m_fp_latch = false;
        m_fp_latch_state.reset();
        m_fp_latch_level = 0;
        const double ks4_sec = RE4VRShared::get()->re4_hookshot_ks4_sec.value_or(1.5);
        if (m_hookshot_seen_t > 0.0 && (now_clock() - m_hookshot_seen_t) < ks4_sec) {
            m_ks4_active = true;
            RE4VRShared::get()->re4_ks4_active = true;
            m_fp_latch = true;
            m_fp_latch_level = 4;
            m_activating_reason = "ks4_hook_actioncam";
        }
    }
}

void RE4VRKillswitch::evaluate() {
    const bool prev = m_killswitch_active;
    evaluate_core();

    if (m_ks2_as_ks4 && m_ks2_active && !m_boxbreak_active) {
        m_ks2_active = false;
        m_ks4_active = true;
    }

    RE4VRShared::get()->re4_ks4_active = m_ks4_active || m_ks5_active || (!m_fp_enabled && m_killswitch_active);
    RE4VRShared::get()->re4_ks_active = m_killswitch_active;
    RE4VRShared::get()->re4_boxbreak_active = m_boxbreak_active;
    RE4VRShared::get()->re4_fatalkick_active = m_ks4_active && !m_boxbreak_active && m_current_cam_state && is_ks4_camstate(m_current_cam_state);
    RE4VRShared::get()->re4_forcecrouch_active = m_forcecrouch_int && m_current_cam_state == m_forcecrouch_int;

    auto [stg, spc] = read_stage_space();
    m_current_stage = stg;
    m_current_space = spc;

    if ((m_prev_ks4_exit && !m_ks4_active) || (m_prev_ks3_exit && !m_ks3_active) || (m_prev_ks2_exit && !m_ks2_active)) {
        RE4VRShared::get()->re4_ks4_exit_t = now_clock();
    }
    m_prev_ks4_exit = m_ks4_active;
    m_prev_ks3_exit = m_ks3_active;
    m_prev_ks2_exit = m_ks2_active;

    if (prev && !m_killswitch_active) {
        m_anim_blend_back = 1.0f;
        m_anim_blend_back_t = now_clock();
    }
    if (m_anim_blend_back > 0.0f) {
        const double el = now_clock() - m_anim_blend_back_t;
        if (el >= ANIM_BLEND_DURATION) {
            m_anim_blend_back = 0.0f;
        } else {
            m_anim_blend_back = 1.0f - (float)(el / ANIM_BLEND_DURATION);
        }
    }

    {
        const bool ks1 = m_killswitch_active && !m_ks2_active && !m_ks3_active && !m_ks4_active && !m_ks5_active;
        bool full_off = ks1 || m_ks4_active || m_ks5_active;
        if (!m_fp_enabled && m_killswitch_active) {
            full_off = true;
        }
        if (full_off && !m_prev_full_off) {
            auto* tf = re4vr::body_transform();
            if (tf) {
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(tf, "resetBasePose"); });
            }
        }
        m_prev_full_off = full_off;
    }

    m_was_active = prev;
    publish_globals();
}

void RE4VRKillswitch::publish_globals() {
    RE4VRShared::get()->re4_ks_fp_enabled = m_fp_enabled;
    RE4VRShared::get()->re4_ks2_as_ks4 = m_ks2_as_ks4;
}

#endif

