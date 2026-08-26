#pragma once

#if defined(RE4)
#include <array>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <json.hpp>

#include <sdk/REMath.hpp>
#include <reframework/API.h>

#include "HookManager.hpp"
#include "../../../../Mod.hpp"

// Builtin port of scripts/re4/re4_vr_movement.lua (RE4-only).
class RE4VRMovement : public Mod {
public:
    static std::shared_ptr<RE4VRMovement>& get();

    std::string_view get_name() const override { return "RE4VRMovement"; }

    std::optional<std::string> on_initialize() override;
    void on_config_load(const utility::Config& cfg) override;
    void on_config_save(utility::Config& cfg) override;

    void on_lua_state_created(sol::state& lua) override;
    void on_lua_state_destroyed(sol::state& lua) override;

    void on_frame() override;
    void on_pre_application_entry(void* entry, const char* name, size_t hash) override;
    void on_application_entry(void* entry, const char* name, size_t hash) override;

    bool roomscale_enabled() const { return m_cfg.roomscale; }
    void set_roomscale_enabled(bool v);

    struct ScopeSlot {
        float x_r{0.0f};
        float z_r{0.0f};
        float yaw{0.0f};
    };

    struct StoredJoint {
        Vector3f p{0.0f, 0.0f, 0.0f};
        glm::quat r{1.0f, 0.0f, 0.0f, 0.0f};
        std::optional<glm::quat> par_inv{};
    };

    struct StoredPose {
        std::unordered_map<std::string, StoredJoint> joints{};
        std::optional<StoredJoint> null_off{};
    };

    struct Cfg {
        bool enabled{true};
        int32_t scope_submit_mode{2};
        bool hmd_yaw_drive{true};
        float yaw_offset_deg{0.0f};
        bool roomscale{false};
        bool rs_lean{false};
        float rs_lean_radius{0.10f};
        bool rs_recenter{true};
        bool rs_crouch{false};
        float rs_crouch_pct{0.20f};
        float rs_stand_height{0.0f};
        bool hmd_follow{true};
        float hmd_follow_deadzone{0.005f};
        float hmd_follow_alpha{0.25f};
        bool hip_follow{true};
        float spine_yaw_deg{0.0f};
        bool ub_lock{false};
        float ub_trim_deg{0.0f};
        bool ub_lock_world{true};
        bool spine_pin{true};
        std::unordered_map<std::string, float> pin_z{
            {"Hip", 0.0f}, {"Spine_0", 0.0f}, {"Spine_1", 0.0f}, {"Spine_2", 0.0f},
            {"Neck_0", 0.0f}, {"Neck_1", 0.0f}, {"Head", 0.0f},
        };
        float pin_z_hip_walk{0.0f};
        std::optional<float> pin_z_hip_crouch{};
        float pin_x_hip{0.0f};
        std::unordered_map<std::string, float> pin_x{
            {"Spine_0", 0.0f}, {"Spine_1", 0.0f}, {"Spine_2", 0.0f},
            {"Neck_0", 0.0f}, {"Neck_1", 0.0f}, {"Head", 0.0f},
        };
        float pin_ub_z{0.0f};
        float pin_ub_x{0.0f};
        float pin_ub_x_crouch{0.0f};
        float pin_ub_yaw{0.0f};
        float pin_ub_z_crouch{0.0f};
        float pin_hip_yaw{0.0f};
        float pin_spine1_roll{0.0f};
        float body_yaw_speed{12.0f};
        bool yaw_hmd_target{false};
        bool cam_body_rotate{false};
        bool stop_skip{true};
        float stop_skip_frames{30.0f};
        bool start_skip{true};
        float start_skip_frames{30.0f};
        bool no_pivot{false};
        float scope_pitch_gain{1.0f};
        std::unordered_map<std::string, std::unordered_map<std::string, ScopeSlot>> scope_sets{};
        float scope_yaw_xr{0.0f};
        bool grav_fix{true};
        float grav_value{150.0f};
        bool grav_in_elevator{false};
        bool lag_boost_on{true};
        float lag_boost_target{2.01f};
        float lag_boost_max{2.41f};
        float lag_boost_window{0.40f};
        bool lag_brake_on{true};
        float lag_brake_gain{0.00f};
        float lag_brake_window{1.50f};
        std::optional<StoredPose> pin_pose{};
        std::optional<StoredPose> crouch_pose{};
    };

private:
    struct PinRel {
        Vector3f p{};
        glm::quat r{1.0f, 0.0f, 0.0f, 0.0f};
    };

    static constexpr float BODY_YAW_EPS_DEG = 0.05f;
    static constexpr float SCOPE_PITCH_SIGN = 1.0f;
    static constexpr float SQAB_RETRIG_WINDOW = 1.5f;
    static constexpr float SQAB_SAME_SPOT = 3.5f;

    static const std::array<const char*, 6> SCOPE_WIDS;
    static const std::array<const char*, 4> SCOPE_STATES;
    static const std::array<const char*, 7> PIN_JOINTS;
    static const std::array<const char*, 4> SPINE_YAW_JOINTS;
    static const std::unordered_set<std::string> UB_JOINTS;
    static const std::vector<const char*> STOP_NODES;
    static const std::vector<const char*> START_NODES;
    static const std::vector<const char*> RUN_START_NODES;

    static std::filesystem::path cfg_path();
    void load_json();
    void save_json();
    void init_default_scope_sets();
    void apply_json(const nlohmann::json& d);
    nlohmann::json dump_json() const;

    void reset_runtime();
    void install_compat_globals(sol::state& lua);

    double now_clock() const;

    bool is_ks_active();
    bool is_pin_release();
    bool is_crouch_active();
    bool is_aim();
    bool pure_gameplay_only();

    ::RETransform* get_body_transform();
    ::REManagedObject* get_player_cam_controller();
    ::REManagedObject* ground_adsorber(::REManagedObject** out_ctx = nullptr);
    ::REManagedObject* get_motion_fsm(::REManagedObject** out_ctx = nullptr);

    static bool joint_alive(::REJoint* j);
    ::REJoint* get_hip_joint(::RETransform* tf);
    ::REJoint* get_spine_joint(::RETransform* tf, const char* name);

    static std::optional<float> flat_yaw_of(const glm::quat& rot);
    static glm::quat yaw_to_quat(float yaw);
    static glm::quat spin_axis_quat(float ax, float ay, float az, float rad);
    static std::optional<float> spin_yaw_of(const glm::quat& rot);
    static glm::quat spin_yaw_quat(float yaw);
    static Vector3f quat_rotate_vec3(const glm::quat& q, const Vector3f& v);
    static glm::quat hmd_quat();
    static float hmd_wrap(float a);
    static bool quat_approx_equal(const glm::quat& a, const glm::quat& b);
    static bool is_ub_joint(std::string_view name);

    bool is_user_turning();
    void apply_hip_follow(::RETransform* tf, const glm::quat& root_yaw_quat);

    bool spinepin_resolve(::RETransform* tf);
    bool spinepin_capture(::RETransform* tf, std::vector<PinRel>& rel, std::vector<std::optional<glm::quat>>& par_inv, std::optional<PinRel>& null_rel);
    void spinepin_store(const std::vector<PinRel>& rel, const std::vector<std::optional<glm::quat>>& par_inv, const std::optional<PinRel>& null_rel, bool crouch);
    bool spinepin_restore(bool crouch, std::vector<PinRel>& rel, std::vector<std::optional<glm::quat>>& par_inv, std::optional<PinRel>& null_rel);
    void apply_spine_pin(bool can_capture = false);
    void apply_crouch_pin(bool can_capture = false);
    void apply_crouch_ub_z(bool capture_base);
    void apply_ub_lock(bool can_capture = false);
    void apply_spine_yaw(::RETransform* tf);

    void apply_hard_yaw(bool sample);
    void enforce_hard_yaw();
    void apply_auto_center();
    void roomscale_recenter();
    void roomscale_recenter_events();
    void roomscale_crouch();
    void apply_hmd_body_follow();
    void roomscale_flush_body();

    ScopeSlot* active_scope_slot();
    void drive_hmd_yaw();
    void apply_pose_freeze(bool on);
    void apply_scope_freeze_late();

    bool apply_skip_nodes(const std::vector<const char*>& nodes, float frames, bool enable, bool overwrite_interp = true, ::REManagedObject** out_ctx = nullptr);
    bool apply_stop_skip(bool enable);
    bool apply_start_skip(bool enable);
    bool apply_no_pivot(bool disable);
    void update_stop_skip();
    void update_anim_export();

    void apply_grav_fix();
    float lag_pad_axis();
    void apply_lag_fix();

    void sqab_tick();
    bool sqab_in_gimmick();
    bool sqab_is_retrigger();
    Vector3f sqab_body_pos();

    static HookManager::PreHookResult pre_update_camera_position(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static void post_update_camera_position(uintptr_t& ret_val, sdk::RETypeDefinition* ret_ty, uintptr_t ret_addr);
    static HookManager::PreHookResult pre_setup_jack_layer(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static void post_setup_jack_layer(uintptr_t& ret_val, sdk::RETypeDefinition* ret_ty, uintptr_t ret_addr);

private:
    Cfg m_cfg{};
    std::chrono::steady_clock::time_point m_clock_origin{std::chrono::steady_clock::now()};

    ::REManagedObject* m_pause_manager{nullptr};
    ::REManagedObject* m_gui_manager{nullptr};
    sdk::RETypeDefinition* m_player_cam_td{nullptr};
    sdk::RETypeDefinition* m_gimmick_cam_td{nullptr};

    ::REJoint* m_hip_joint{nullptr};
    double m_hipjv_bad{-999.0};
    std::optional<glm::quat> m_hip_ref_offset{};

    std::unordered_map<std::string, ::REJoint*> m_spine_joint_cache{};
    std::unordered_map<std::string, glm::quat> m_spine_last_written{};

    ::RETransform* m_spinepin_tf{nullptr};
    std::vector<::REJoint*> m_spinepin_joints{};
    std::vector<std::string> m_spinepin_names{};
    ::REJoint* m_spinepin_null_off{nullptr};
    std::optional<std::vector<PinRel>> m_spinepin_rel{};
    std::vector<std::optional<glm::quat>> m_spinepin_par_inv{};
    std::optional<PinRel> m_spinepin_null_rel{};
    bool m_spinepin_cfg_tried{false};
    bool m_spinepin_provisional{false};
    float m_spinepin_run_blend{0.0f};
    float m_spinepin_walk_blend{0.0f};

    std::optional<std::vector<PinRel>> m_crouchpin_rel{};
    std::vector<std::optional<glm::quat>> m_crouchpin_par_inv{};
    std::optional<PinRel> m_crouchpin_null_rel{};
    bool m_crouchpin_cfg_tried{false};
    bool m_crouchpin_capture_req{false};

    std::unordered_map<int, Vector3f> m_crouch_ubz_base{};
    bool m_crouch_ubz_has_base{false};

    std::unordered_map<std::string, glm::quat> m_ub_lock_pose{};
    std::unordered_map<std::string, glm::quat> m_ub_lock_rel{};
    bool m_ub_lock_has_pose{false};
    bool m_ub_lock_has_rel{false};
    struct {
        glm::quat raw{1.0f, 0.0f, 0.0f, 0.0f};
        glm::quat parent{1.0f, 0.0f, 0.0f, 0.0f};
        glm::quat world{1.0f, 0.0f, 0.0f, 0.0f};
        bool valid{false};
    } m_ub_lock_base{};
    std::optional<float> m_ub_trim_applied{};

    std::optional<glm::quat> m_last_yaw_quat{};
    std::optional<double> m_body_yaw_last_t{};
    std::optional<float> m_owned_yaw{};

    std::optional<double> m_hmd_follow_last_t{};
    ::REManagedObject* m_auto_center_ctx{nullptr};
    bool m_rs_prev_ks{false};
    std::optional<Vector3f> m_rs_prev_pos{};
    std::optional<Vector3f> m_rs_prev_hmd{};
    Vector3f m_rs_pending{0.0f, 0.0f, 0.0f};
    double m_rs_crouch_next_t{0.0};

    ::REManagedObject* m_hmd_yaw_pcc{nullptr};
    std::optional<float> m_hmd_yaw_prev{};
    std::optional<float> m_scope_pitch_base{};
    bool m_pose_freeze_now{false};
    std::optional<int32_t> m_pose_submit_now{};

    struct SkipState {
        bool applied{false};
        ::REManagedObject* last_ctx{nullptr};
    };
    SkipState m_stop_skip{};
    SkipState m_start_skip{};
    SkipState m_no_pivot{};
    ::REManagedObject* m_bw_motion{nullptr};

    std::optional<float> m_grav_orig{};
    bool m_grav_active{false};

    struct {
        std::optional<Vector4f> last_pos{};
        std::optional<double> last_t{};
        float spd{0.0f};
        float pad_was{0.0f};
        std::optional<double> edge_t{};
        const char* edge_kind{nullptr};
        float boost_now{0.0f};
        bool brake_now{false};
    } m_lagm{};

    bool m_sqab_active{false};
    std::optional<Vector3f> m_sqab_last{};
    bool m_sqab_pin{false};
    std::optional<Vector3f> m_sqab_pin_pos{};
    std::optional<int32_t> m_sqab_skip_ret{};
};
#endif
