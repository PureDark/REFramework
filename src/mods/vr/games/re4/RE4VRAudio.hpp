#pragma once

#if defined(RE4)
#include "../../../../Mod.hpp"
#include "HookManager.hpp"

// Builtin port of scripts/re4/re4_vr_audio.lua
class RE4VRAudio : public Mod {
public:
    static std::shared_ptr<RE4VRAudio>& get();
    std::string_view get_name() const override { return "RE4VRAudio"; }

    std::optional<std::string> on_initialize() override;
    void on_application_entry(void* entry, const char* name, size_t hash) override;

private:
    bool compute_hmd_orientation(Vector3f& fwd, Vector3f& up);
    glm::quat hmd_full_rotation();
    glm::quat hmd_yaw_flat();
    std::optional<glm::quat> game_camera_rotation();

    static HookManager::PreHookResult pre_set_listener(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static void post_set_listener(uintptr_t& ret_val, sdk::RETypeDefinition* ret_ty, uintptr_t ret_addr);

    bool m_enabled{true};
    bool m_use_full_hmd{true};
    bool m_hooked{false};
    int m_cached_frame{-1};
    Vector3f m_cached_fwd{0, 0, 1};
    Vector3f m_cached_up{0, 1, 0};
};
#endif
