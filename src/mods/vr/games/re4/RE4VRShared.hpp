#pragma once

#if defined(RE4)
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <type_traits>
#include <unordered_map>
#include <vector>

#include <glm/gtc/quaternion.hpp>
#include <glm/gtx/quaternion.hpp>
#include <json.hpp>
#include <sdk/REMath.hpp>
#include <sdk/REManagedObject.hpp>
#include <sdk/REGameObject.hpp>
#include <sdk/REString.hpp>
#include <sdk/RETransform.hpp>
#include <sdk/RETypeDB.hpp>
#include <sdk/REContext.hpp>
#include <reframework/API.h>
#include <utility/String.hpp>

#include "../../../ScriptRunner.hpp"
#include "../../../VR.hpp"
#include "../../../../REFramework.hpp"

namespace re4vr {
template <typename Fn>
inline bool pcall(Fn&& fn) {
    try {
        fn();
        return true;
    } catch (...) {
        return false;
    }
}

template <typename Fn>
inline auto safe(Fn&& fn) -> std::optional<std::invoke_result_t<Fn>> {
    try {
        return fn();
    } catch (...) {
        return std::nullopt;
    }
}

inline bool obj_ok(::REManagedObject* o) {
    return o != nullptr && utility::re_managed_object::is_managed_object(o);
}

inline std::filesystem::path data_path(std::string_view rel) {
    return REFramework::get_persistent_dir() / "reframework" / "data" / rel;
}

inline nlohmann::json load_json_file(std::string_view rel) {
    std::ifstream f{data_path(rel)};
    if (!f) {
        return nlohmann::json::object();
    }
    try {
        nlohmann::json d;
        f >> d;
        return d.is_object() ? d : nlohmann::json::object();
    } catch (...) {
        return nlohmann::json::object();
    }
}

inline void save_json_file(std::string_view rel, const nlohmann::json& d) {
    try {
        const auto path = data_path(rel);
        std::filesystem::create_directories(path.parent_path());
        std::ofstream f{path};
        f << d.dump(4);
    } catch (...) {
    }
}

struct LuaGuard {
    LuaGuard() {
        m_sr = ScriptRunner::get();
        if (m_sr) {
            m_sr->lock();
        }
    }
    ~LuaGuard() {
        if (m_sr) {
            m_sr->unlock();
        }
    }
    sol::state* lua() {
        if (!m_sr || !m_sr->get_state()) {
            return nullptr;
        }
        return &m_sr->get_state()->lua();
    }
    std::shared_ptr<ScriptRunner> m_sr{};
};

inline bool lua_is_true(std::string_view name) {
    LuaGuard g;
    auto* L = g.lua();
    if (!L) {
        return false;
    }
    sol::object o = (*L)[std::string{name}];
    return o.get_type() == sol::type::boolean && o.as<bool>();
}

inline bool lua_not_false(std::string_view name) {
    LuaGuard g;
    auto* L = g.lua();
    if (!L) {
        return true;
    }
    sol::object o = (*L)[std::string{name}];
    if (o.get_type() == sol::type::boolean && !o.as<bool>()) {
        return false;
    }
    return true;
}

inline std::optional<double> lua_number(std::string_view name) {
    LuaGuard g;
    auto* L = g.lua();
    if (!L) {
        return std::nullopt;
    }
    sol::object o = (*L)[std::string{name}];
    if (o.get_type() == sol::type::number) {
        return o.as<double>();
    }
    return std::nullopt;
}

inline std::optional<std::string> lua_string(std::string_view name) {
    LuaGuard g;
    auto* L = g.lua();
    if (!L) {
        return std::nullopt;
    }
    sol::object o = (*L)[std::string{name}];
    if (o.get_type() == sol::type::string) {
        return o.as<std::string>();
    }
    return std::nullopt;
}

inline void lua_set_bool(std::string_view name, bool v) {
    LuaGuard g;
    if (auto* L = g.lua()) {
        (*L)[std::string{name}] = v;
    }
}

inline void lua_set_number(std::string_view name, double v) {
    LuaGuard g;
    if (auto* L = g.lua()) {
        (*L)[std::string{name}] = v;
    }
}

inline void lua_set_string(std::string_view name, std::string_view v) {
    LuaGuard g;
    if (auto* L = g.lua()) {
        (*L)[std::string{name}] = std::string{v};
    }
}

inline void lua_set_nil(std::string_view name) {
    LuaGuard g;
    if (auto* L = g.lua()) {
        (*L)[std::string{name}] = sol::nil;
    }
}

bool call_killswitch_bool(const char* fn, bool default_v = false);
bool is_ks_active();
std::optional<double> call_killswitch_number(const char* fn);
std::optional<std::string> call_killswitch_string(const char* fn);

inline uint64_t profile_frame() {
    return (uint64_t)VR::get()->get_frame_count();
}

inline std::optional<Vector3f> as_vec3(sol::object o) {
    if (!o.valid() || o.get_type() == sol::type::nil || o.get_type() == sol::type::none) {
        return std::nullopt;
    }
    if (o.is<Vector3f>()) {
        return o.as<Vector3f>();
    }
    if (o.is<Vector4f>()) {
        const auto v = o.as<Vector4f>();
        return Vector3f{v.x, v.y, v.z};
    }
    if (o.is<sol::table>()) {
        auto t = o.as<sol::table>();
        return Vector3f{(float)t.get_or("x", 0.0), (float)t.get_or("y", 0.0), (float)t.get_or("z", 0.0)};
    }
    return std::nullopt;
}

inline std::optional<glm::quat> as_quat(sol::object o) {
    if (!o.valid() || o.get_type() == sol::type::nil || o.get_type() == sol::type::none) {
        return std::nullopt;
    }
    if (o.is<glm::quat>()) {
        return o.as<glm::quat>();
    }
    return std::nullopt;
}

inline std::optional<Vector3f> lua_vec3(std::string_view name) {
    LuaGuard g;
    auto* L = g.lua();
    if (!L) {
        return std::nullopt;
    }
    return as_vec3((*L)[std::string{name}]);
}

inline std::optional<glm::quat> lua_quat(std::string_view name) {
    LuaGuard g;
    auto* L = g.lua();
    if (!L) {
        return std::nullopt;
    }
    return as_quat((*L)[std::string{name}]);
}

inline void lua_set_vec3(std::string_view name, const Vector3f& v) {
    LuaGuard g;
    if (auto* L = g.lua()) {
        (*L)[std::string{name}] = v;
    }
}

inline void lua_set_quat(std::string_view name, const glm::quat& q) {
    LuaGuard g;
    if (auto* L = g.lua()) {
        (*L)[std::string{name}] = q;
    }
}

inline ::REManagedObject* lua_object(std::string_view name) {
    LuaGuard g;
    auto* L = g.lua();
    if (!L) {
        return nullptr;
    }
    sol::object o = (*L)[std::string{name}];
    if (o.is<::REManagedObject*>()) {
        auto* p = o.as<::REManagedObject*>();
        return obj_ok(p) ? p : nullptr;
    }
    return nullptr;
}

inline void lua_set_object(std::string_view name, ::REManagedObject* o) {
    LuaGuard g;
    if (auto* L = g.lua()) {
        (*L)[std::string{name}] = o;
    }
}

inline bool lua_call_bool(std::string_view name, bool default_v = false) {
    LuaGuard g;
    auto* L = g.lua();
    if (!L) {
        return default_v;
    }
    sol::object o = (*L)[std::string{name}];
    if (o.get_type() == sol::type::boolean) {
        return o.as<bool>();
    }
    if (o.is<sol::protected_function>()) {
        auto r = o.as<sol::protected_function>()();
        if (r.valid() && r.get_type() == sol::type::boolean) {
            return r.get<bool>();
        }
    }
    return default_v;
}

template <typename... Args>
inline void lua_pcall_name(std::string_view name, Args&&... args) {
    LuaGuard g;
    auto* L = g.lua();
    if (!L) {
        return;
    }
    sol::object o = (*L)[std::string{name}];
    if (!o.is<sol::protected_function>()) {
        return;
    }
    auto r = o.as<sol::protected_function>()(std::forward<Args>(args)...);
    (void)r;
}

inline std::string obj_name(::REManagedObject* o) {
    if (!obj_ok(o)) {
        return {};
    }
    auto* nm = safe([&] { return sdk::call_object_func_easy<::SystemString*>(o, "get_Name"); }).value_or(nullptr);
    if (!nm) {
        return {};
    }
    return utility::re_string::get_string(nm);
}

inline void* runtime_type(const char* name) {
    auto* td = sdk::find_type_definition(name);
    return td ? td->get_runtime_type() : nullptr;
}

inline bool grip_held(bool left) {
    auto& vr = VR::get();
    const auto act = vr->get_action_grip();
    const auto joy = left ? vr->get_left_joystick() : vr->get_right_joystick();
    if (!act || !joy) {
        return false;
    }
    return vr->is_action_active(act, joy);
}

inline glm::quat quat_euler_yxz_deg(float px, float py, float pz) {
    const auto ax = [](float a, float x, float y, float z) {
        const float h = glm::radians(a) * 0.5f;
        const float s = std::sin(h);
        return glm::quat{std::cos(h), x * s, y * s, z * s};
    };
    return glm::normalize(ax(py, 0.0f, 1.0f, 0.0f) * ax(px, 1.0f, 0.0f, 0.0f) * ax(pz, 0.0f, 0.0f, 1.0f));
}

inline glm::quat axis_angle(const Vector3f& axis, float ang) {
    const float h = ang * 0.5f;
    const float s = std::sin(h);
    return glm::quat{std::cos(h), axis.x * s, axis.y * s, axis.z * s};
}

inline Vector3f quat_rotate(const glm::quat& q, const Vector3f& v) {
    return glm::rotate(q, v);
}

inline glm::quat quat_euler_xyz_deg(float x, float y, float z) {
    return glm::normalize(glm::quat(Vector3f{glm::radians(x), glm::radians(y), glm::radians(z)}));
}

inline double now() {
    using clock = std::chrono::steady_clock;
    static const auto origin = clock::now();
    return std::chrono::duration<double>(clock::now() - origin).count();
}

inline double lua_os_clock() {
    LuaGuard g;
    auto* L = g.lua();
    if (!L) {
        return now();
    }
    sol::object clock = (*L)["os"]["clock"];
    if (clock.get_type() == sol::type::function) {
        auto r = clock.as<sol::protected_function>()();
        if (r.valid() && r.get_type() == sol::type::number) {
            return r.get<double>();
        }
    }
    return now();
}

inline ::REGameObject* create_game_object(std::string_view name) {
    auto* td = sdk::find_type_definition("via.GameObject");
    auto* m = td ? td->get_method("create(System.String)") : nullptr;
    if (!m) {
        return nullptr;
    }
    auto* s = sdk::VM::create_managed_string(utility::widen(std::string{name}));
    return safe([&] { return m->call<::REGameObject*>(sdk::get_thread_context(), s); }).value_or(nullptr);
}

inline void destroy_game_object(::REManagedObject* go) {
    if (!obj_ok(go)) {
        return;
    }
    auto* td = sdk::find_type_definition("via.GameObject");
    auto* m = td ? td->get_method("destroy(via.GameObject)") : nullptr;
    if (m) {
        pcall([&] { m->call<void*>(sdk::get_thread_context(), go); });
    }
}

inline Vector4f v4(const Vector3f& v, float w = 1.0f) {
    return Vector4f{v.x, v.y, v.z, w};
}

inline Vector3f v3(const Vector4f& v) {
    return Vector3f{v.x, v.y, v.z};
}

inline bool j_bool(const nlohmann::json& d, const char* k, bool def) {
    if (!d.contains(k) || d[k].is_null()) {
        return def;
    }
    if (d[k].is_boolean()) {
        return d[k].get<bool>();
    }
    if (d[k].is_number()) {
        return d[k].get<double>() != 0.0;
    }
    return def;
}

inline float j_num(const nlohmann::json& d, const char* k, float def) {
    if (!d.contains(k) || !d[k].is_number()) {
        return def;
    }
    return d[k].get<float>();
}

::REManagedObject* character_manager();
::REManagedObject* player_context();
::REGameObject* body_game_object();
::RETransform* body_transform();
::REGameObject* head_game_object();
::REManagedObject* camera_system();
::REManagedObject* get_component(::REManagedObject* go, const char* type_name);
::REManagedObject* get_component(::REManagedObject* go, sdk::RETypeDefinition* td);
::REManagedObject* current_scene();
std::string go_name(::REManagedObject* go);
bool go_valid(::REManagedObject* go);
::REJoint* joint_by_name(::RETransform* tf, std::string_view name);
bool apply_pose_bones(const std::unordered_map<std::string, glm::quat>& bones, float blend);
void export_pose_api(sol::state& lua);

void reset_pointer_cache();
}
#endif
