#define NOMINMAX
#include "RE4VRShared.hpp"

#if defined(RE4)
#include <sdk/REGameObject.hpp>
#include <sdk/RETypeDB.hpp>
#include <sdk/REString.hpp>
#include <sdk/SceneManager.hpp>
#include <sdk/SystemArray.hpp>
#include <utility/String.hpp>

#include "RE4VRKillswitch.hpp"

namespace re4vr {
namespace {
::REManagedObject* g_character_manager{nullptr};
::REManagedObject* g_camera_system{nullptr};

struct PoseMap {
    ::RETransform* tf{nullptr};
    std::unordered_map<std::string, ::REJoint*> joints{};
};

PoseMap g_pose_map{};
}

::REManagedObject* character_manager() {
    if (!obj_ok(g_character_manager)) {
        g_character_manager = sdk::get_managed_singleton<::REManagedObject>("chainsaw.CharacterManager");
    }
    return obj_ok(g_character_manager) ? g_character_manager : nullptr;
}

::REManagedObject* player_context() {
    auto* cm = character_manager();
    if (!cm) {
        return nullptr;
    }
    return safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(cm, "getPlayerContextRef"); }).value_or(nullptr);
}

::REGameObject* body_game_object() {
    auto* ctx = player_context();
    if (!obj_ok(ctx)) {
        return nullptr;
    }
    return safe([&] { return sdk::call_object_func_easy<::REGameObject*>(ctx, "get_BodyGameObject"); }).value_or(nullptr);
}

::RETransform* body_transform() {
    auto* body = body_game_object();
    if (!obj_ok((::REManagedObject*)body)) {
        return nullptr;
    }
    return safe([&] { return sdk::call_object_func_easy<::RETransform*>(body, "get_Transform"); }).value_or(nullptr);
}

::REGameObject* head_game_object() {
    auto* ctx = player_context();
    if (!obj_ok(ctx)) {
        return nullptr;
    }
    return safe([&] { return sdk::call_object_func_easy<::REGameObject*>(ctx, "get_HeadGameObject"); }).value_or(nullptr);
}

::REManagedObject* camera_system() {
    if (!obj_ok(g_camera_system)) {
        g_camera_system = sdk::get_managed_singleton<::REManagedObject>("chainsaw.CameraSystem");
    }
    return obj_ok(g_camera_system) ? g_camera_system : nullptr;
}

::REManagedObject* get_component(::REManagedObject* go, const char* type_name) {
    if (!obj_ok(go) || type_name == nullptr) {
        return nullptr;
    }
    return get_component(go, sdk::find_type_definition(type_name));
}

::REManagedObject* get_component(::REManagedObject* go, sdk::RETypeDefinition* td) {
    if (!obj_ok(go) || td == nullptr) {
        return nullptr;
    }
    auto* rt = td->get_runtime_type();
    if (!rt) {
        return nullptr;
    }
    return safe([&] {
        return sdk::call_object_func_easy<::REManagedObject*>(go, "getComponent(System.Type)", rt);
    }).value_or(nullptr);
}

::REManagedObject* current_scene() {
    return sdk::get_current_scene();
}

std::string go_name(::REManagedObject* go) {
    if (!obj_ok(go)) {
        return {};
    }
    auto* nm = safe([&] { return sdk::call_object_func_easy<::SystemString*>(go, "get_Name"); }).value_or(nullptr);
    if (!nm) {
        return {};
    }
    return utility::re_string::get_string(nm);
}

bool go_valid(::REManagedObject* go) {
    if (!obj_ok(go)) {
        return false;
    }
    auto v = safe([&] { return sdk::call_object_func_easy<bool>(go, "get_Valid"); });
    return v.value_or(true);
}

::REJoint* joint_by_name(::RETransform* tf, std::string_view name) {
    if (!tf || name.empty()) {
        return nullptr;
    }
    return sdk::get_transform_joint_by_name(tf, utility::widen(std::string{name}));
}

static void rebuild_pose_map(::RETransform* tf) {
    g_pose_map.tf = tf;
    g_pose_map.joints.clear();
    if (!tf) {
        return;
    }
    auto* arr = sdk::get_transform_joints(tf);
    if (!arr) {
        return;
    }
    const auto n = arr->get_size();
    for (size_t i = 0; i < n; ++i) {
        auto* j = (::REJoint*)arr->get_element((int32_t)i);
        if (!j) {
            continue;
        }
        auto nm = sdk::get_joint_name(j);
        if (!nm.empty()) {
            g_pose_map.joints[std::move(nm)] = j;
        }
    }
}

bool apply_pose_bones(const std::unordered_map<std::string, glm::quat>& bones, float blend) {
    auto* tf = body_transform();
    if (!tf || bones.empty() || blend <= 0.0f) {
        return blend <= 0.0f;
    }
    if (g_pose_map.tf != tf || g_pose_map.joints.empty()) {
        rebuild_pose_map(tf);
    }
    if (g_pose_map.joints.empty()) {
        return false;
    }
    for (const auto& [bone, target] : bones) {
        auto it = g_pose_map.joints.find(bone);
        if (it == g_pose_map.joints.end() || !it->second) {
            continue;
        }
        auto* j = it->second;
        pcall([&] {
            if (blend >= 0.9999f) {
                sdk::set_joint_local_rotation(j, target);
            } else {
                auto cur = sdk::get_joint_local_rotation(j);
                auto tw = target;
                if (glm::dot(cur, tw) < 0.0f) {
                    tw = -tw;
                }
                auto q = glm::normalize(cur + (tw - cur) * blend);
                sdk::set_joint_local_rotation(j, q);
            }
        });
    }
    return true;
}

void export_pose_api(sol::state& lua) {
    lua["__re4_reload_apply_pose_bones"] = [](sol::object bones_obj, sol::object blend_obj) -> bool {
        if (!bones_obj.is<sol::table>()) {
            return false;
        }
        float blend = 1.0f;
        if (blend_obj.is<float>()) {
            blend = blend_obj.as<float>();
        } else if (blend_obj.is<double>()) {
            blend = (float)blend_obj.as<double>();
        }
        std::unordered_map<std::string, glm::quat> bones;
        sol::table t = bones_obj.as<sol::table>();
        for (auto& kv : t) {
            if (!kv.first.is<std::string>() || !kv.second.is<sol::table>()) {
                continue;
            }
            sol::table q = kv.second.as<sol::table>();
            const float w = q.get_or(1, 1.0f);
            const float x = q.get_or(2, 0.0f);
            const float y = q.get_or(3, 0.0f);
            const float z = q.get_or(4, 0.0f);
            bones[kv.first.as<std::string>()] = glm::quat{w, x, y, z};
        }
        return apply_pose_bones(bones, blend);
    };
}

void reset_pointer_cache() {
    g_character_manager = nullptr;
    g_camera_system = nullptr;
    g_pose_map = {};
}

bool call_killswitch_bool(const char* fn, bool default_v) {
    auto ks = RE4VRKillswitch::get();
    if (!ks || fn == nullptr) {
        return default_v;
    }
    const std::string_view n{fn};
    if (n == "is_active") {
        return ks->is_active();
    }
    if (n == "is_pin_release") {
        return ks->is_pin_release();
    }
    if (n == "is_ks2") {
        return ks->is_ks2();
    }
    if (n == "is_ks3") {
        return ks->is_ks3();
    }
    if (n == "is_ks4") {
        return ks->is_ks4();
    }
    if (n == "is_ks5") {
        return ks->is_ks5();
    }
    if (n == "is_fp_only") {
        return ks->is_fp_only();
    }
    if (n == "just_activated") {
        return ks->just_activated();
    }
    if (n == "just_deactivated") {
        return ks->just_deactivated();
    }
    if (n == "is_cutscene_active") {
        return ks->is_cutscene_active();
    }
    if (n == "is_real_cutscene") {
        return ks->is_real_cutscene();
    }
    if (n == "is_crouch_active") {
        return ks->is_crouch_active();
    }
    if (n == "is_player_camera_active") {
        return ks->is_player_camera_active();
    }
    if (n == "is_pure_gameplay") {
        return ks->is_pure_gameplay();
    }
    return default_v;
}

bool is_ks_active() {
    if (lua_is_true("__re4_throwsight_active")) {
        return true;
    }
    if (lua_is_true("__re4_ks_keep_movement")) {
        return false;
    }
    return RE4VRKillswitch::get()->is_active();
}

std::optional<double> call_killswitch_number(const char* fn) {
    auto ks = RE4VRKillswitch::get();
    if (!ks || fn == nullptr) {
        return std::nullopt;
    }
    const std::string_view n{fn};
    if (n == "get_stage_name") {
        if (auto v = ks->get_stage_name()) {
            return (double)*v;
        }
        return std::nullopt;
    }
    if (n == "get_space_id") {
        if (auto v = ks->get_space_id()) {
            return (double)*v;
        }
        return std::nullopt;
    }
    if (n == "get_cam_state") {
        if (auto v = ks->get_cam_state()) {
            return (double)*v;
        }
        return std::nullopt;
    }
    if (n == "get_anim_blend_back") {
        return (double)ks->get_anim_blend_back();
    }
    if (n == "get_zone_count") {
        return (double)ks->get_zone_count();
    }
    return std::nullopt;
}

std::optional<std::string> call_killswitch_string(const char* fn) {
    auto ks = RE4VRKillswitch::get();
    if (!ks || fn == nullptr) {
        return std::nullopt;
    }
    const std::string_view n{fn};
    if (n == "get_stage_name") {
        if (auto v = ks->get_stage_name()) {
            return std::to_string(*v);
        }
        return std::nullopt;
    }
    if (n == "get_activating_controller") {
        return ks->get_activating_controller();
    }
    if (n == "get_controller") {
        return ks->get_controller();
    }
    if (n == "get_previous_controller") {
        return ks->get_previous_controller();
    }
    return std::nullopt;
}
}

#endif
