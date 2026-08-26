#define NOMINMAX
#include "RE4VRShared.hpp"

#if defined(RE4)
#include <sdk/REGameObject.hpp>
#include <sdk/RETypeDB.hpp>
#include <sdk/REString.hpp>
#include <sdk/SceneManager.hpp>
#include <sdk/SystemArray.hpp>
#include <utility/String.hpp>

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
}

#endif
