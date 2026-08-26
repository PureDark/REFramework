#pragma once

#if defined(RE4)
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include <json.hpp>
#include <sdk/REMath.hpp>
#include <sdk/RETransform.hpp>
#include "../../../../Mod.hpp"

// Builtin port of scripts/re4/re4_vr_motion.lua
class RE4VRMotion : public Mod {
public:
    static std::shared_ptr<RE4VRMotion>& get();
    std::string_view get_name() const override { return "RE4VRMotion"; }

    std::optional<std::string> on_initialize() override;
    void on_lua_state_created(sol::state& lua) override;
    void on_lua_state_destroyed(sol::state& lua) override;
    void on_frame() override;
    void on_pre_application_entry(void* entry, const char* name, size_t hash) override;
    void on_application_entry(void* entry, const char* name, size_t hash) override;

private:
    struct HandOff {
        float px{0}, py{0}, pz{0};
        float rx{0}, ry{0}, rz{0};
    };
    struct SupportOff {
        float px{0}, py{0}, pz{0};
        float rx{0}, ry{0}, rz{0};
        float dock_threshold{0.110f};
        float undock_threshold{0.150f};
        bool grip_on{true};
        float grip_x{0}, grip_y{0}, grip_z{0};
        float grip_back{0}, grip_fwd{0};
        bool grip_anchor{false};
        bool grip_noroll{false};
        float blend_in{0.18f};
        float blend_out{0.18f};
        float dock_dist{0.060f};
        float blend_speed{0.150f};
        float burst_rot{0};
        float burst_count{0};
        float single_rot{0};
        float lerp{0.15f};
        float idx_rx{0}, idx_ry{0}, idx_rz{0};
    };
    struct WepRel {
        float px{0}, py{0}, pz{0};
        float qx{0}, qy{0}, qz{0}, qw{1};
    };
    struct CamData {
        Vector3f pos{0, 0, 0};
        glm::quat rot{1, 0, 0, 0};
        glm::quat yaw{1, 0, 0, 0};
    };
    struct VrData {
        Vector3f rh_pos{}, lh_pos{};
        glm::quat rh_rot{1, 0, 0, 0}, lh_rot{1, 0, 0, 0};
        bool rh_ok{false}, lh_ok{false};
    };
    struct Cfg {
        bool enabled{true};
        bool openxr_corr{true};
        bool metavr{false};
        float smooth_pos{0.0f};
        float smooth_rot{0.0f};
        bool two_hand{true};
        bool support{true};
        nlohmann::json extra{nlohmann::json::object()};
    };

    void load_config();
    void save_config();
    void export_globals(sol::state& lua);
    void register_ui();
    void tick(bool late);
    void attach_right_hand(const CamData& cam, const VrData& vr);
    void attach_left_hand(const CamData& cam, const VrData& vr, bool update_dock);
    void attach_weapon();
    void apply_two_hand_aim(const VrData& vr, const CamData& cam);
    void restore_hands_native();
    void write_joint_pose(::REJoint* j, const Vector3f& pos, const glm::quat& rot);
    Vector3f apply_hand_offset(const Vector3f& pos, const glm::quat& rot, const HandOff& off, glm::quat& out_rot);
    Vector3f clamp_hand_to_arm_reach(const Vector3f& hand_pos, bool left);
    std::optional<CamData> get_camera_data();
    std::optional<VrData> get_vr_data();
    std::pair<Vector3f, glm::quat> controller_to_world(const Vector3f& pos, const glm::quat& rot, const CamData& cam);
    void find_joints();
    std::optional<int32_t> get_equip_weapon_id();
    std::string current_weapon_key();
    HandOff& get_weapon_offset(const std::string& key);
    bool is_killswitch_active();
    bool is_two_hand_aim_weapon();
    bool is_support_hand_weapon();
    void flashlight_tick(const Vector3f& hp, const glm::quat& hr);
    void find_weapon();
    void update_knife_swing();
    void apply_flashlight(const Vector3f& hp, const glm::quat& hr);
    void knife_ks_restore_native();
    bool native_reload_active();
    void release_motion_targets();
    void elevator_unparent();
    void apply_pump_locks(const CamData& cam);
    void compute_grip_pull(const Vector3f& gp);
    void repin_left();
    ::REJoint* get_pump_joint();
    ::REJoint* get_switch_joint();
    SupportOff* soff(std::unordered_map<std::string, SupportOff>& m, const std::string& key);
    int fire_mode_next(int32_t wid, int cur) const;
    bool switch_dock_weapon() const;
    bool pump_grip_weapon() const;
    void apply_ada_lazy_pose();
    void apply_ada_flashlight();
    void apply_switch_hand_pose();
    void apply_switch_rotation();
    void apply_skullshaker_open_pose();
    void knife_flip_finger_open();
    void apply_pistol_support_pose();
    void apply_mag_hand_pose();
    void apply_fl_hold_pose();
    bool fl_left_hand_busy() const;
    void add_joint_local_euler(::REJoint* j, float rx, float ry, float rz);
    void post_poses(bool lock_pass);
    void publish_globals();
    glm::quat knife_flip_spin(const glm::quat& wrot);
    std::string rel_key(int32_t wid);
    std::optional<std::pair<Vector3f, glm::quat>> get_support_pose();
    void update_support_dock(const Vector3f& free_pos, const std::optional<Vector3f>& support_pos);

    struct Corr {
        float pos_x{0}, pos_y{0}, pos_z{0};
        float rot_pitch{0}, rot_yaw{0}, rot_roll{0};
    };
    struct TwoHand {
        bool enabled{true};
        float min_dist{0.04f};
        float max_dist{0.90f};
        float blend_speed{0.05f};
        float blend{0};
        bool active{false};
        std::optional<glm::quat> engage0{};
        std::optional<glm::quat> smooth_rot{};
        std::optional<Vector3f> pump_ref{};
        std::optional<Vector3f> pump_cam{};
        Vector3f give{0, 0, 0};
    };
    struct Support {
        bool enabled{true};
        bool docked{false};
        float blend_speed{0.05f};
        float blend_factor{0};
        float aim_blend{0};
        float grip_latch_reach{0.75f};
        float target_blend{0};
        float switch2_blend{0};
        float burst_anim{0};
        bool switch_docked{false};
        bool switch_blend_lock{false};
        bool switch_latched{false};
        bool prev_left_grip{false};
        bool prev_switch_trigger{false};
        bool sw_consumed{false};
        bool free_near{false};
        int fire_mode{0};
        int prev_fire_mode{0};
        bool burst_active{false};
        bool motion_owns_burst{false};
        std::optional<Vector3f> grip_off{};
        std::optional<Vector3f> grip_rhprev{};
        std::optional<int32_t> grip_off_wid{};
        std::optional<Vector3f> grip_pull{};
    };
    struct WepCache {
        std::optional<int32_t> id{};
        ::REGameObject* go{nullptr};
        ::RETransform* tf{nullptr};
        std::optional<Vector3f> rel_pos{};
        std::optional<glm::quat> rel_rot{};
        bool frozen{false};
        bool changing{false};
        int calib_wait{0};
        int calib_sample{0};
        std::optional<int32_t> parry_last_gun{};
        bool matilda_stock{false};
    };
    struct FlOff {
        float pos_x{0}, pos_y{0}, pos_z{0};
        float rot_pitch{0}, rot_yaw{0}, rot_roll{0};
    };

    Cfg m_cfg{};
    HandOff m_hand_l{};
    std::unordered_map<std::string, HandOff> m_weapon_offset{};
    std::unordered_map<std::string, WepRel> m_weapon_rel{};
    std::unordered_map<std::string, SupportOff> m_support_off{};
    std::unordered_map<std::string, SupportOff> m_support_off_aim{};
    std::unordered_map<std::string, SupportOff> m_support_off_switch{};
    std::unordered_map<std::string, SupportOff> m_support_off_switch_aim{};
    std::unordered_map<std::string, SupportOff> m_support_off_switch2{};
    std::unordered_map<std::string, SupportOff> m_support_off_switch2_aim{};
    ::REJoint* m_rh{nullptr};
    ::REJoint* m_lh{nullptr};
    ::RETransform* m_body_tf{nullptr};
    int32_t m_tick_id{0};
    bool m_paused{false};
    bool m_ui_registered{false};
    bool m_openxr{false};
    bool m_metavr{false};
    Vector3f m_last_rh{}, m_last_lh{};
    glm::quat m_last_rh_r{1, 0, 0, 0}, m_last_lh_r{1, 0, 0, 0};
    Vector3f m_standing{};
    bool m_standing_set{false};
    bool m_init{false};
    std::string m_runtime{"openvr"};
    std::string m_controller{"steamvr"};
    Corr m_oxr{0.015f, -0.006f, -0.104f, -16.341f, -2.011f, -0.754f};
    Corr m_ctrl{-0.004f, -0.002f, -0.002f, 0.0f, 0.0f, 5.606f};
    TwoHand m_th{};
    Support m_sup{};
    WepCache m_wep{};
    std::string m_weapon_key{"-1"};
    Vector3f m_rh_world{}, m_lh_world{};
    glm::quat m_rh_rot{1, 0, 0, 0}, m_lh_rot{1, 0, 0, 0}, m_rh_aim{1, 0, 0, 0};
    bool m_rh_ok{false}, m_lh_ok{false};
    std::optional<Vector3f> m_rh_jpos{}, m_lh_jpos{};
    std::optional<glm::quat> m_rh_jrot{}, m_lh_jrot{};
    std::optional<Vector3f> m_smooth_rh_p{}, m_smooth_lh_p{};
    std::optional<glm::quat> m_smooth_rh_r{}, m_smooth_lh_r{};
    float m_flip_lerp{0};
    float m_flip_prev{-1};
    struct FlipPos {
        float x{0}, y{0}, z{0};
    };
    std::unordered_map<int32_t, FlipPos> m_flip_pos{};
    std::unordered_map<int32_t, FlipPos> m_flip_pos_ada{};
    std::optional<double> m_skull_spin_t0{};
    bool m_skull_open_prev{false};
    double m_skull_open_t{-1};
    struct MagFade {
        std::optional<std::string> name{};
        float trx{0}, try_{0}, trz{0};
        std::optional<double> release_t{};
    } m_mag_fade;
    bool m_was_changing{false};
    bool m_knife_swing{false};
    double m_swing_end{0};
    std::optional<Vector3f> m_swing_last{};
    int m_swing_cidx{-1};
    double m_swing_t{0};
    bool m_fl_enabled{true};
    bool m_fl_keep_knife{true};
    FlOff m_fl_off{}, m_fl_light{}, m_fl_dock{}, m_fl_dock_light{};
    ::RETransform* m_fl_tf{nullptr};
    ::RETransform* m_fl_light_tf{nullptr};
    double m_fl_check{0};
    bool m_ada_body{false};
    double m_ada_body_t{-1.0};
    ::RETransform* m_ada_fl_tf{nullptr};
    ::RETransform* m_ada_fl_light_tf{nullptr};
    double m_ada_fl_check{0};
    nlohmann::json m_cfg_raw{nlohmann::json::object()};
    std::unordered_set<int32_t> m_two_hand_ids{
        4100, 4101, 4102, 4200, 4201, 4202, 4400, 4401, 4402, 4500, 4501, 4502, 4600, 4701,
        4900, 4901, 4902, 6000, 6001, 6100, 6101, 6102, 6104, 6105, 6106, 6111, 6112, 6113, 6114};
    std::unordered_set<int32_t> m_support_ids{
        4000, 4001, 4002, 4003, 4004, 4005, 4500, 4501, 4502, 6000, 6103, 6112, 6113, 6300, 6301,
        4100, 4101, 4102, 4200, 4201, 4202, 4400, 4401, 4402, 4600, 4701, 4900, 4901, 4902, 6001,
        6100, 6101, 6102, 6104, 6105, 6106, 6111, 6114, 6304};
    std::unordered_set<int32_t> m_grip_dock{
        4100, 4101, 4102, 4200, 4201, 4202, 4400, 4401, 4402, 4600, 4701, 4900, 4901, 4902, 6001,
        6100, 6101, 6102, 6104, 6105, 6106, 6111, 6114, 6304};
    std::unordered_set<int32_t> m_knife_ids{5000, 5001, 5002, 5003, 5006, 6107, 6108, 6305};
    std::string m_switch_jn{};
    std::optional<int32_t> m_switch_jn_wid{};
};
#endif
