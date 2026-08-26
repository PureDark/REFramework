#pragma once

#if defined(RE4)
#include <chrono>
#include <optional>
#include <random>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <sdk/REMath.hpp>

#include "../../../../Mod.hpp"
#include "HookManager.hpp"

// Builtin port of scripts/re4/re4_vr_recoil.lua
class RE4VRRecoil : public Mod {
public:
    static std::shared_ptr<RE4VRRecoil>& get();
    std::string_view get_name() const override { return "RE4VRRecoil"; }

    std::optional<std::string> on_initialize() override;
    void on_config_load(const utility::Config& cfg) override;
    void on_lua_state_created(sol::state& lua) override;
    void on_lua_state_destroyed(sol::state& lua) override;
    void on_frame() override;
    void on_application_entry(void* entry, const char* name, size_t hash) override;

private:
    void load_json();
    void save_json();
    void load_haptic_json();
    void publish_vr_recoil();
    void register_ui();

    double now_clock() const;
    std::optional<int32_t> current_weapon_id();
    static std::string weapon_key(std::optional<int32_t> wid);
    float effective_weapon_recoil_multiplier(float* out_base = nullptr);
    bool fp_active();
    bool hmd_active();
    void on_pre_request_recoil_body();
    void update_spring_and_export();
    void haptic_tick();
    void haptic_fire(bool support);
    void haptic_pulse(uint64_t handle, float amp);

    static HookManager::PreHookResult pre_request_recoil(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static void post_nop(uintptr_t& ret_val, sdk::RETypeDefinition* ret_ty, uintptr_t ret_addr);
    static HookManager::PreHookResult pre_update_recoil(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static HookManager::PreHookResult pre_update_handshake(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);

    struct Cfg {
        bool enable_recoil{false};
        float recoil_intensity_multiplier{1.0f};
        float recoil_position_intensity{0.008f};
        float recoil_rotation_intensity{0.055f};
        float recoil_horizontal_spread{0.024f};
        float recoil_vertical_spread{0.016f};
        float recoil_randomness{0.35f};
        float recoil_mult_exponent{0.35f};
        float recoil_stack_cap{2.0f};
        float recoil_spring_stiffness{120.0f};
        float recoil_spring_damping{18.0f};
        float recoil_attack_duration{0.022f};
        float recoil_auto_scale{0.15f};
        float recoil_sustained_damping{28.0f};
        float recoil_sustained_window{0.12f};
        float recoil_supported_impulse_mult{0.70f};
        float recoil_unsupported_light_mult{1.18f};
        float recoil_unsupported_heavy_mult{1.90f};
    };
    Cfg m_cfg{};
    std::unordered_map<std::string, float> m_weapon_intensity{};
    std::unordered_map<std::string, float> m_weapon_support{};

    struct HapticCfg {
        bool enabled{true};
        float amp_solo{1.00f};
        float amp_right_sup{0.70f};
        float amp_left_sup{0.30f};
        float dur{0.05f};
        float freq{180.0f};
        float delay{0.00f};
    };
    HapticCfg m_haptic{};
    struct PendingPulse {
        double at{};
        bool support{false};
    };
    std::optional<double> m_last_seq{};
    std::vector<PendingPulse> m_pending{};

    bool m_recoil_attack_active{false};
    float m_recoil_attack_t{0.0f};
    float m_recoil_attack_pos_y{0.0f};
    float m_recoil_attack_pos_z{0.0f};
    float m_recoil_attack_pitch{0.0f};
    float m_recoil_attack_yaw{0.0f};
    std::optional<double> m_recoil_last_t{};
    std::optional<double> m_recoil_last_shot_t{};
    bool m_recoil_active{false};
    float m_spring_pos_y{0.0f};
    float m_spring_pos_z{0.0f};
    float m_spring_pitch{0.0f};
    float m_spring_yaw{0.0f};
    float m_spring_vel_y{0.0f};
    float m_spring_vel_z{0.0f};
    float m_spring_vel_pitch{0.0f};
    float m_spring_vel_yaw{0.0f};

    Vector3f m_export_pos{0.0f, 0.0f, 0.0f};
    glm::quat m_export_rot{1.0f, 0.0f, 0.0f, 0.0f};
    bool m_export_active{false};

    std::mt19937 m_rng{std::random_device{}()};
    std::chrono::steady_clock::time_point m_clock_origin{std::chrono::steady_clock::now()};
    bool m_ui_registered{false};
};
#endif
