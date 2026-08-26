#pragma once

#if defined(RE4)
#include <chrono>
#include <optional>
#include <string>
#include <vector>

#include <sdk/REMath.hpp>
#include <sdk/RETransform.hpp>

#include "../../../../Mod.hpp"

// Builtin port of scripts/re4/re4_vr_firstperson.lua
class RE4VRFirstPerson : public Mod {
public:
    static std::shared_ptr<RE4VRFirstPerson>& get();
    std::string_view get_name() const override { return "RE4VRFirstPerson"; }

    std::optional<std::string> on_initialize() override;
    void on_config_load(const utility::Config& cfg) override;
    void on_lua_state_created(sol::state& lua) override;
    void on_lua_state_destroyed(sol::state& lua) override;
    void on_frame() override;
    void on_pre_application_entry(void* entry, const char* name, size_t hash) override;
    void on_application_entry(void* entry, const char* name, size_t hash) override;

private:
    struct Cfg {
        float off_x{0.0f}, off_y{0.0f}, off_z{0.0f};
        float event_off_x{0.0f}, event_off_y{0.0f}, event_off_z{0.0f};
        float event2_off_x{0.0f}, event2_off_y{0.0f}, event2_off_z{0.0f};
        float event3_off_x{0.0f}, event3_off_y{0.0f}, event3_off_z{0.0f};
        float event4_off_x{0.0f}, event4_off_y{0.0f}, event4_off_z{0.0f};
        bool event5_mono{true};
        float event5_off_x{0.0f}, event5_off_y{0.0f}, event5_off_z{0.0f};
        float event6_off_x{0.0f}, event6_off_y{0.0f}, event6_off_z{0.0f};
        float turret_off_x{0.0f}, turret_off_y{0.0f}, turret_off_z{0.0f};
        float jetski_off_x{0.0f}, jetski_off_y{0.0f}, jetski_off_z{0.0f};
        float boat_off_x{0.0f}, boat_off_y{0.0f}, boat_off_z{0.0f};
        float begcrouch_off_x{0.0f}, begcrouch_off_y{0.0f}, begcrouch_off_z{0.0f};
        float ada_fc_off_x{0.0f}, ada_fc_off_y{0.0f}, ada_fc_off_z{-0.08f};
        float leon_fc_off_x{0.0f}, leon_fc_off_y{0.0f}, leon_fc_off_z{0.0f};
        float ada_box_off_x{0.0f}, ada_box_off_y{0.0f}, ada_box_off_z{0.0f};
        float leon_evt_off_x{0.0f}, leon_evt_off_y{0.0f}, leon_evt_off_z{-0.08f};
        float acrouch_off_x{0.0f}, acrouch_off_y{0.0f}, acrouch_off_z{0.0f};
        float cart_off_x{0.0f}, cart_off_y{0.0f}, cart_off_z{0.0f};
        float headpin_fade_dur{0.25f};
        bool movement_stabilization{true};
        bool movement_follows_hmd{true};
        float bob_tau{0.5f};
        float surge_tau{0.35f};
        bool crouch_cam_lerp{true};
        float crouch_cam_tau{0.18f};
        bool standup_cam_track{true};
        bool hide_streaming_dummy{true};
        bool recenter_on_killswitch{true};
        float bino_start{2.5f};
        float bino_min{-7.0f};
        float bino_max{2.5f};
        float bino_speed{3.0f};
        bool block_force_twirler{true};
    };

    void load_json();
    void publish_bino();
    void publish_camera_fix(bool active, const Vector3f* pos = nullptr, const glm::quat* rot = nullptr);
    double now_clock() const;
    bool fp_perf_on() const;
    std::optional<int32_t> fp_stage_cached();
    ::REManagedObject* fp_busy_cached();
    std::string body_name();
    bool is_ada_now();
    bool is_ashley_now();
    ::REJoint* get_camera_joint();
    ::REJoint* get_head_joint();
    bool joint_valid(::REJoint* j);
    bool active();
    std::optional<glm::quat> get_game_cam_yaw();
    std::optional<glm::quat> get_primary_cam_flat_yaw();
    ::REManagedObject* get_player_cam();
    Vector3f apply_bob_filter(const Vector3f& hp, bool frame_tick);
    Vector3f apply_surge_filter(const Vector3f& hp, const std::optional<Vector3f>& bp, bool frame_tick);
    bool is_crouch_now();
    float apply_crouch_cam_lerp(float y, bool frame_tick);
    bool on_ladder_climb();
    bool is_gimmick_ks3_now();
    void compute_and_set(bool frame_tick);
    Vector2f get_left_input_axis();
    void apply_movement_stabilization();
    std::optional<float> rc_yaw_of_quat(const glm::quat& q);
    glm::quat rc_yaw_quat(float y);
    bool recenter_neutralize_headset();
    void recenter_tick();
    void apply_world_cam_offset(float ox, float oy, float oz);
    void apply_event_hmd_offset();
    void apply_event2_hmd_offset();
    void apply_event3_hmd_offset();
    void apply_event4_hmd_offset();
    void apply_event5_hmd_offset();
    void apply_event5_mono();
    void apply_event6_hmd_offset();
    void apply_turret_hmd_offset();
    void apply_all_event_offsets();
    void force_twirler_tick();
    void sd_hide_subtree(::RETransform* tf);
    void sd_scan();
    void sd_tick();
    void reset_runtime();

    Cfg m_cfg{};
    int32_t m_fp_frame{0};
    std::optional<int32_t> m_fp_stage{};
    int32_t m_fp_stage_f{-1};
    ::REManagedObject* m_fp_busy{nullptr};
    int32_t m_fp_busy_f{-1};
    ::REJoint* m_head_joint{nullptr};
    sdk::RETypeDefinition* m_player_cam_td{nullptr};
    sdk::RETypeDefinition* m_gimmickfix_cam_td{nullptr};
    int32_t m_turret_gimmick{6};

    bool m_ftw_twirl{false};
    bool m_ftw_control{true};
    int m_ftw_stopped{0};
    double m_ftw_block_until{0.0};
    int m_ftw_fail_streak{0};

    std::optional<Vector3f> m_bob_ema{};
    std::optional<double> m_bob_last_t{};
    std::optional<float> m_capy_ema{};
    std::optional<double> m_capy_last_t{};

    std::optional<float> m_surge_px{};
    std::optional<float> m_surge_pz{};
    float m_surge_vx{0.0f};
    float m_surge_vz{0.0f};
    std::optional<float> m_surge_lx{};
    std::optional<float> m_surge_lz{};
    std::optional<double> m_surge_last_t{};
    std::optional<float> m_surge_lyaw{};
    int m_surge_turn_n{0};

    std::optional<float> m_crouch_ema{};
    bool m_crouch_was{false};
    std::optional<double> m_crouch_until_t{};
    std::optional<double> m_crouch_last_t{};
    std::optional<double> m_crouch_standup_until{};

    bool m_headpin_was{false};
    double m_headpin_t{0.0};
    float m_headpin_ax{0.0f}, m_headpin_ay{0.0f}, m_headpin_az{0.0f};

    bool m_move_has_valid{false};
    std::optional<Vector3f> m_move_last_pos{};
    std::optional<double> m_move_last_t{};

    bool m_rc_was_active{false};

    std::vector<::REManagedObject*> m_sd_cache{};
    double m_sd_last_scan{0.0};
    sdk::RETypeDefinition* m_scene_td{nullptr};
    void* m_ctrl_t{nullptr};
    void* m_mesh_t{nullptr};
    void* m_skin_t{nullptr};

    std::chrono::steady_clock::time_point m_clock_origin{std::chrono::steady_clock::now()};
};
#endif
