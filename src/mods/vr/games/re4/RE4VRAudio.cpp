#define NOMINMAX
#include "RE4VRAudio.hpp"

#if defined(RE4)
#include <cmath>

#include <glm/gtc/constants.hpp>
#include <glm/gtx/quaternion.hpp>
#include <spdlog/spdlog.h>
#include <sdk/RETypeDB.hpp>
#include <sdk/MurmurHash.hpp>
#include <sdk/Application.hpp>

#include "RE4VRShared.hpp"
#include "../../../ScriptRunner.hpp"

std::shared_ptr<RE4VRAudio>& RE4VRAudio::get() {
    static auto inst = std::make_shared<RE4VRAudio>();
    return inst;
}

glm::quat RE4VRAudio::hmd_full_rotation() {
    auto& vr = VR::get();
    const auto hq = glm::quat{vr->get_transform(0)};
    return vr->get_rotation_offset() * hq;
}

glm::quat RE4VRAudio::hmd_yaw_flat() {
    const auto combined = hmd_full_rotation();
    const float siny = 2.0f * (combined.w * combined.y + combined.z * combined.x);
    const float cosy = 1.0f - 2.0f * (combined.y * combined.y + combined.x * combined.x);
    const float yaw = std::atan2(siny, cosy);
    const float half = yaw * 0.5f;
    return glm::quat{std::cos(half), 0.0f, std::sin(half), 0.0f};
}

std::optional<glm::quat> RE4VRAudio::game_camera_rotation() {
    auto* sys = re4vr::camera_system();
    if (!sys) {
        return std::nullopt;
    }
    auto* ctrl = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(sys, "get_MainCameraController"); }).value_or(nullptr);
    if (!re4vr::obj_ok(ctrl)) {
        return std::nullopt;
    }
    return re4vr::safe([&] { return sdk::call_object_func_easy<glm::quat>(ctrl, "get_CameraRotation"); });
}

bool RE4VRAudio::compute_hmd_orientation(Vector3f& fwd, Vector3f& up) {
    const auto frame = VR::get()->get_frame_count();
    if (frame == m_cached_frame) {
        fwd = m_cached_fwd;
        up = m_cached_up;
        return true;
    }
    auto cam = game_camera_rotation();
    if (!cam) {
        return false;
    }
    auto& vr = VR::get();
    if (!vr->is_hmd_active()) {
        return false;
    }
    const auto hmd = m_use_full_hmd ? hmd_full_rotation() : hmd_yaw_flat();
    const auto q = (*cam) * hmd;

    float fx = 2.0f * (q.x * q.z + q.w * q.y);
    float fy = 2.0f * (q.y * q.z - q.w * q.x);
    float fz = 1.0f - 2.0f * (q.x * q.x + q.y * q.y);
    float ux = 2.0f * (q.x * q.y - q.w * q.z);
    float uy = 1.0f - 2.0f * (q.x * q.x + q.z * q.z);
    float uz = 2.0f * (q.y * q.z + q.w * q.x);
    fz = -fz; // cfg.negate_fwd_z = true

    fwd = Vector3f{fx, fy, fz};
    up = Vector3f{ux, uy, uz};
    m_cached_fwd = fwd;
    m_cached_up = up;
    m_cached_frame = frame;
    return true;
}

HookManager::PreHookResult RE4VRAudio::pre_set_listener(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    auto& self = *get();
    if (!self.m_enabled) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    if (re4vr::is_ks_active()) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    Vector3f fwd{}, up{};
    if (!self.compute_hmd_orientation(fwd, up)) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    // args: [0]=vm, [1]=this, [2]=index, [3]=pos, [4]=fwd, [5]=up
    if (args.size() > 5 && args[4] && args[5]) {
        auto* f = (Vector3f*)args[4];
        auto* u = (Vector3f*)args[5];
        *f = fwd;
        *u = up;
    }
    return HookManager::PreHookResult::CALL_ORIGINAL;
}

void RE4VRAudio::post_set_listener(uintptr_t&, sdk::RETypeDefinition*, uintptr_t) {}

std::optional<std::string> RE4VRAudio::on_initialize() {
    if (auto* td = sdk::find_type_definition("via.simplewwise.SendRequest")) {
        if (auto* m = td->get_method("setListenerPosition")) {
            g_hookman.add(m, &RE4VRAudio::pre_set_listener, &RE4VRAudio::post_set_listener);
            m_hooked = true;
            spdlog::info("[RE4VRAudio] Hooked setListenerPosition");
        }
    }
    return std::nullopt;
}

void RE4VRAudio::on_application_entry(void*, const char* name, size_t hash) {
    if (m_hooked || hash != "UpdateAudioRender"_fnv) {
        return;
    }
    ScriptProfileGuard guard("re4_vr_audio.lua", "on_application_entry:UpdateAudioRender", re4vr::profile_frame());
    if (!m_enabled || re4vr::is_ks_active()) {
        return;
    }
    Vector3f fwd{}, up{};
    if (!compute_hmd_orientation(fwd, up)) {
        return;
    }
    auto* drv = sdk::get_native_singleton("via.simplewwise.Driver");
    auto* drv_td = sdk::find_type_definition("via.simplewwise.Driver");
    auto* send_td = sdk::find_type_definition("via.simplewwise.SendRequest");
    auto* send = sdk::get_native_singleton("via.simplewwise.SendRequest");
    if (!drv || !drv_td || !send || !send_td) {
        return;
    }
    auto pos = re4vr::safe([&] { return sdk::call_native_func_easy<Vector3f>(drv, drv_td, "getListenerPosition", 0); });
    if (!pos) {
        return;
    }
    re4vr::pcall([&] { sdk::call_native_func_easy<void*>(send, send_td, "setListenerPosition", 0, *pos, fwd, up); });
}
#endif
