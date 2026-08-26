#pragma once

#if defined(RE4)
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include <sdk/REMath.hpp>
#include "../../../../Mod.hpp"

// Builtin port of scripts/re4/re4_vr_minecart.lua
class RE4VRMinecart : public Mod {
public:
    static std::shared_ptr<RE4VRMinecart>& get();
    std::string_view get_name() const override { return "RE4VRMinecart"; }

    std::optional<std::string> on_initialize() override;
    void on_lua_state_created(sol::state& lua) override;
    void on_lua_state_destroyed(sol::state& lua) override;
    void on_frame() override;
    void on_pre_application_entry(void* entry, const char* name, size_t hash) override;
    void on_application_entry(void* entry, const char* name, size_t hash) override;

    void apply_spine_pin();

private:
    struct PinJoint {
        Vector3f p{};
        glm::quat r{1.0f, 0.0f, 0.0f, 0.0f};
    };
    struct Cfg {
        float body_down{0.0f};
        float body_back{0.0f};
        bool yaw_follow{false};
        float yaw_sign{1.0f};
        bool lean_enabled{true};
        float lean_threshold{0.10f};
        float lean_full{0.28f};
        float lean_sign{1.0f};
        float lean_tilt_min{0.15f};
        bool recenter_enabled{true};
        float recenter_dead{0.08f};
        float recenter_rate{0.35f};
        bool rumble_enabled{true};
        float rumble_amp{0.22f};
        float rumble_rate{0.09f};
        float rumble_dur{0.07f};
        float rumble_freq{45.0f};
        bool rumble_clack{true};
        float rumble_clack_every{1.7f};
        float rumble_clack_amp{0.50f};
        bool rumble_intro{true};
        float rumble_speed_min{3.0f};
        float rumble_speed_full{9.0f};
        bool rumble_speed_scale{true};
    };

    void load_json();
    bool railcar_active();
    void update_anim_export();
    void update_reload_flag();
    void load_pin_pose();
    bool resolve_spine(::RETransform* tf);
    void force_crosshair();
    void update_yaw_follow();
    void cart_knife_swap();
    void update_cart_lean();
    void update_cart_recenter();
    void update_cart_rumble();
    float cart_speed_now();
    ::REManagedObject* get_player_railcar();

    Cfg m_cfg{};
    std::unordered_map<std::string, PinJoint> m_pin_map{};
    bool m_pin_tried{false};
    ::RETransform* m_pin_tf{nullptr};
    std::vector<::REJoint*> m_pin_joints{};
    std::vector<std::string> m_pin_names{};
    ::REManagedObject* m_bw_motion{nullptr};
    ::REGameObject* m_bw_go{nullptr};
    ::REGameObject* m_wep_go{nullptr};
    ::REManagedObject* m_wep_mo{nullptr};
    ::REManagedObject* m_rail_manager{nullptr};
    double m_ck_last{0.0};
    std::optional<float> m_yf_entry_body{};
    std::optional<float> m_yf_entry_hmd{};
    std::optional<double> m_rc_last_t{};
    std::optional<double> m_rum_t0{};
    double m_rum_next_t{0.0};
    double m_rum_next_clack{0.0};
    int m_rum_side{0};
    std::optional<double> m_spd_t{};
    float m_spd_x{0}, m_spd_y{0}, m_spd_z{0}, m_spd_v{0};
};
#endif
