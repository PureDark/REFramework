#pragma once

#if defined(RE4)
#include <chrono>
#include <functional>
#include <memory>
#include <cstdint>
#include <filesystem>
#include <fstream>
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

class RE4VRShared {
public:
    static std::shared_ptr<RE4VRShared>& get();

    std::optional<Vector3f>& arm_root(std::string_view prefix) {
        return (prefix.size() && prefix[0] == 'L') ? vr_arm_chain_L_root : vr_arm_chain_R_root;
    }
    std::optional<double>& arm_maxreach(std::string_view prefix) {
        return (prefix.size() && prefix[0] == 'L') ? vr_arm_chain_L_maxreach : vr_arm_chain_R_maxreach;
    }

    bool refresh_unlimited();

    bool set_mag_in_hand(bool v) {
        if (v) {
            refresh_unlimited();
            if (re4_is_unlimited) {
                return false;
            }
        }
        for (auto& h : mag_in_hand_handlers) {
            if (auto r = h(v)) {
                return *r;
            }
        }
        vr_mag_in_hand = v;
        return false;
    }

    void apply_reload_pose(const std::string& name, float blend) {
        if (apply_reload_pose_fn) {
            apply_reload_pose_fn(name, blend);
        }
    }

    std::vector<std::function<std::optional<bool>(bool)>> mag_in_hand_handlers;
    std::function<void(const std::string&, float)> apply_reload_pose_fn;

    bool* bool_at(std::string_view n);
    std::optional<double>* num_at(std::string_view n);
    std::optional<bool>* opt_bool_at(std::string_view n);
    std::optional<std::string>* str_at(std::string_view n);
    std::optional<Vector3f>* vec3_at(std::string_view n);
    std::optional<glm::quat>* quat_at(std::string_view n);
    ::REManagedObject** obj_at(std::string_view n);

    bool _IsWeaponChanging{false};  // _IsWeaponChanging
    bool is_aim{false};  // is_aim
    bool is_reticle_displayed{false};  // is_reticle_displayed
    std::optional<Vector3f> ldock_off{};  // __ldock_off
    std::optional<Vector3f> ldock_rhprev{};  // __ldock_rhprev
    std::optional<double> re4_ada_a_long_sec{};  // __re4_ada_a_long_sec
    bool re4_ada_relfix{false};  // __re4_ada_relfix
    bool re4_ada_relfix2{false};  // __re4_ada_relfix2
    bool re4_ada_relfix3{false};  // __re4_ada_relfix3
    bool re4_ada_uses_leon_scope{true};  // __re4_ada_uses_leon_scope
    bool re4_aim_relatch{false};  // __re4_aim_relatch
    std::optional<double> re4_animal_center_max_d{};  // __re4_animal_center_max_d
    bool re4_ar_pg{false};  // __re4_ar_pg
    bool re4_ar_suppress{false};  // __re4_ar_suppress
    bool re4_at_cannon{false};  // __re4_at_cannon
    std::optional<double> re4_bino_max{2.5};  // __re4_bino_cfg.max
    std::optional<double> re4_bino_min{-7.0};  // __re4_bino_cfg.min
    std::optional<double> re4_bino_speed{3.0};  // __re4_bino_cfg.speed
    std::optional<double> re4_bino_start{2.5};  // __re4_bino_cfg.start
    bool re4_block_b_drop{false};  // __re4_block_b_drop
    std::optional<double> re4_autoreload_blocked{};  // __re4_autoreload_blocked
    bool re4_autoreload_gate{false};  // __re4_autoreload_gate
    bool re4_boat_active{false};  // __re4_boat_active
    std::optional<double> re4_bolt_aim_cut_t{};  // __re4_bolt_aim_cut_t
    bool re4_bolt_in_cycle{false};  // __re4_bolt_in_cycle
    bool re4_bolt_in_cycle_dlc{false};  // __re4_bolt_in_cycle_dlc
    std::optional<double> re4_bolt_pitch_hold{};  // __re4_bolt_pitch_hold
    bool re4_bolt_reaim{true};  // __re4_bolt_reaim
    std::optional<double> re4_bolt_shoot_t{};  // __re4_bolt_shoot_t
    bool re4_boxbreak_active{false};  // __re4_boxbreak_active
    bool re4_burst_gate{false};  // __re4_burst_gate
    std::optional<double> re4_cart_lean_lx{};  // __re4_cart_lean_lx
    std::optional<std::string> re4_char_now{};  // __re4_char_now
    bool re4_is_unlimited{false};  // __re4_is_unlimited
    std::optional<double> re4_unlim_t{};
    bool re4_clone_finisher_restore{false};  // __re4_clone_finisher_restore
    bool re4_clone_no_autogun{false};  // __re4_clone_no_autogun
    std::optional<double> re4_coin_off_y{};  // __re4_coin_off_y
    std::optional<double> re4_crouch_press_frames{};  // __re4_crouch_press_frames
    std::optional<double> re4_current_knife_wid{};  // __re4_current_knife_wid
    bool re4_damage_active{false};  // __re4_damage_active
    std::optional<double> re4_damage_end_t{};  // __re4_damage_end_t
    std::optional<double> re4_dodge_prompt_seen{};  // __re4_dodge_prompt_seen
    bool re4_empty_trigger_held{false};  // __re4_empty_trigger_held
    std::optional<double> re4_evt40510_t{};  // __re4_evt40510_t
    bool re4_evt60874_fullhide{false};  // __re4_evt60874_fullhide
    bool re4_fatalkick_active{false};  // __re4_fatalkick_active
    bool re4_fc_off{false};  // __re4_fc_off
    std::optional<double> re4_finisher_prompt_seen{};  // __re4_finisher_prompt_seen
    ::REManagedObject* re4_fl_mesh{nullptr};  // __re4_fl_mesh
    bool re4_force_killswitch_bolt{false};  // __re4_force_killswitch_bolt
    bool re4_force_killswitch_scope{false};  // __re4_force_killswitch_scope
    bool re4_force_ks4_bulletrush{false};  // __re4_force_ks4_bulletrush
    bool re4_forcecrouch_active{false};  // __re4_forcecrouch_active
    bool re4_forcecrouch_ks4_active{false};  // __re4_forcecrouch_ks4_active
    bool re4_fork_canvas{true};  // __re4_fork_canvas
    bool re4_fork_gui_matrix{false};  // __re4_fork_gui_matrix
    bool re4_fork_mono{false};  // __re4_fork_mono
    bool re4_fork_ok{false};  // __re4_fork_ok
    bool re4_fp_perf_off{false};  // __re4_fp_perf_off
    bool re4_frame_is_gameplay{false};  // __re4_frame_is_gameplay
    bool re4_frame_pure_gameplay{false};  // __re4_frame_pure_gameplay
    std::optional<std::string> re4_gameplay_why{};  // __re4_gameplay_why
    std::optional<double> re4_gang3rd_t{};  // __re4_gang3rd_t
    bool re4_gest_mute{false};  // __re4_gest_mute
    std::optional<std::string> re4_gest_prev{};  // __re4_gest_prev
    std::optional<std::string> re4_gesture_fire{};  // __re4_gesture_fire
    std::optional<double> re4_gfix_latch_t{};  // __re4_gfix_latch_t
    bool re4_gondola_active{false};  // __re4_gondola_active
    bool re4_grappled_active{false};  // __re4_grappled_active
    ::REManagedObject* re4_grenade_gen{nullptr};  // __re4_grenade_gen
    std::optional<double> re4_holster_ada_mesh_z{};  // __re4_holster_ada_mesh_z
    std::optional<double> re4_holster_crouch_gain{};  // __re4_holster_crouch_gain
    bool re4_holster_killswitch{false};  // __re4_holster_killswitch
    bool re4_holster_knife_only{false};  // __re4_holster_knife_only
    std::optional<double> re4_hookshot_grace_sec{};  // __re4_hookshot_grace_sec
    std::optional<double> re4_hookshot_ks4_sec{};  // __re4_hookshot_ks4_sec
    std::optional<double> re4_hookshot_recent_until{};  // __re4_hookshot_recent_until
    bool re4_in_mercs{false};  // __re4_in_mercs
    bool re4_in_squeeze{false};  // __re4_in_squeeze
    bool re4_jetski_active{false};  // __re4_jetski_active
    ::REManagedObject* re4_knife_atkUD{nullptr};  // __re4_knife_atkUD
    bool re4_knife_blood_on{false};  // __re4_knife_blood_on
    bool re4_knife_change_block_hooked{false};  // __re4_knife_change_block_hooked
    std::optional<std::string> re4_knife_char{};  // __re4_knife_char
    bool re4_knife_clonless_grab{true};  // __re4_knife_clonless_grab
    std::optional<double> re4_knife_draw_ours_t{};  // __re4_knife_draw_ours_t
    bool re4_knife_equipped{false};  // __re4_knife_equipped
    bool re4_knife_finisher_shake{false};  // __re4_knife_finisher_shake
    bool re4_knife_flip_pre_ks{false};  // __re4_knife_flip_pre_ks
    std::optional<double> re4_knife_flip_speed{};  // __re4_knife_flip_speed
    std::optional<double> re4_knife_flip_finger_deg{};  // __re4_knife_flip_finger_deg
    std::optional<double> re4_knife_flip_pos_x{};  // __re4_knife_flip_pos_x
    std::optional<double> re4_knife_flip_pos_y{};  // __re4_knife_flip_pos_y
    std::optional<double> re4_knife_flip_pos_z{};  // __re4_knife_flip_pos_z
    bool re4_knife_flying{false};  // __re4_knife_flying
    bool re4_knife_gate{true};  // __re4_knife_gate
    bool re4_knife_gate_hook{false};  // __re4_knife_gate_hook
    std::optional<double> re4_knife_grab_release{};  // __re4_knife_grab_release
    std::optional<double> re4_knife_grab_trigger{};  // __re4_knife_grab_trigger
    std::optional<std::string> re4_knife_hand{};  // __re4_knife_hand
    bool re4_knife_holster_hook{false};  // __re4_knife_holster_hook
    std::optional<Vector3f> re4_knife_home{};  // __re4_knife_home
    std::optional<double> re4_knife_home_str{};  // __re4_knife_home_str
    ::REManagedObject* re4_knife_last_target{nullptr};  // __re4_knife_last_target
    bool re4_knife_left_clone{false};  // __re4_knife_left_clone
    bool re4_knife_left_intent{false};  // __re4_knife_left_intent
    ::REManagedObject* re4_knife_lh_clone_go{nullptr};  // __re4_knife_lh_clone_go
    std::optional<double> re4_knife_lh_dist{};  // __re4_knife_lh_dist
    bool re4_knife_lh_in_zone{false};  // __re4_knife_lh_in_zone
    std::optional<double> re4_knife_lt_flip_tap{};  // __re4_knife_lt_flip_tap
    std::optional<double> re4_knife_our_until{};  // __re4_knife_our_until
    std::optional<double> re4_knife_parry_fresh_until{};  // __re4_knife_parry_fresh_until
    bool re4_knife_parry_pose{false};  // __re4_knife_parry_pose
    std::optional<double> re4_knife_reach{};  // __re4_knife_reach
    std::optional<double> re4_knife_swing_threshold{};  // __re4_knife_swing_threshold
    std::optional<Vector3f> re4_knife_throw_dir{};  // __re4_knife_throw_dir
    bool re4_knife_throw_gripping{false};  // __re4_knife_throw_gripping
    bool re4_ks2_as_ks4{true};  // __re4_ks2_as_ks4
    bool re4_ks4_active{false};  // __re4_ks4_active
    std::optional<double> re4_ks4_exit_t{};  // __re4_ks4_exit_t
    bool re4_ks_active{false};  // __re4_ks_active
    std::optional<std::string> re4_ks_err{};  // __re4_ks_err
    bool re4_ks_fp_enabled{true};  // __re4_ks_fp_enabled
    bool re4_ks_keep_movement{false};  // __re4_ks_keep_movement
    std::optional<std::string> re4_last_pad{};  // __re4_last_pad
    bool re4_leaning_ladder_active{false};  // __re4_leaning_ladder_active
    bool re4_leaning_ladder_mounted{false};  // __re4_leaning_ladder_mounted
    ::REManagedObject* re4_live_wi{nullptr};  // __re4_live_wi
    std::optional<double> re4_live_wi_t{};  // __re4_live_wi_t
    std::optional<double> re4_mag_carry{};  // __re4_mag_carry
    std::optional<double> re4_mag_carry_wid{};  // __re4_mag_carry_wid
    std::optional<double> re4_mag_eject_kf_preview{};  // __re4_mag_eject_kf_preview
    bool re4_melee_gate{true};  // __re4_melee_gate
    bool re4_melee_gate_hook{false};  // __re4_melee_gate_hook
    std::optional<std::string> re4_merc_body{};  // __re4_merc_body
    std::optional<double> re4_merc_bow_keep_blocked{};  // __re4_merc_bow_keep_blocked
    bool re4_merc_bow_pinned{false};  // __re4_merc_bow_pinned
    bool re4_merc_dot{true};  // __re4_merc_dot
    std::optional<double> re4_merc_cid{};  // __re4_merc_cid
    std::optional<double> re4_merc_kind{};  // __re4_merc_kind
    std::optional<double> re4_merc_round{};  // __re4_merc_round
    bool re4_minecart2_ks4_active{false};  // __re4_minecart2_ks4_active
    bool re4_minecart_ks4_active{false};  // __re4_minecart_ks4_active
    std::optional<double> re4_minidemo_latch_t{};  // __re4_minidemo_latch_t
    bool re4_on_elevator2{false};  // __re4_on_elevator2
    std::optional<double> re4_our_equip_until{};  // __re4_our_equip_until
    std::optional<double> re4_parry_keep_gun_until{};  // __re4_parry_keep_gun_until
    std::optional<double> re4_parry_keep_gun_from{};  // __re4_parry_keep_gun_from
    std::optional<double> re4_parry_last_gun_wid{};  // __re4_parry_last_gun_wid
    std::optional<double> re4_pose_fade_dur{};  // __re4_pose_fade_dur
    std::optional<double> re4_push_blend{};  // __re4_push_blend
    bool re4_qk_block{true};  // __re4_qk_block
    bool re4_quickknife_hooked{false};  // __re4_quickknife_hooked
    bool re4_r4dlc_had{false};  // __re4_r4dlc_had
    std::optional<std::string> re4_rack_joint_name{};  // __re4_rack_joint_name
    std::optional<double> re4_rack_joint_wid{};  // __re4_rack_joint_wid
    bool re4_railcar_mode{false};  // __re4_railcar_mode
    std::optional<double> re4_railcar_reload_fade{};  // __re4_railcar_reload_fade
    bool re4_railcar_reloading{false};  // __re4_railcar_reloading
    bool re4_railcar_yaw_delta{false};  // __re4_railcar_yaw_delta
    bool re4_reload_grab_empty{false};  // __re4_reload_grab_empty
    bool re4_reload_hand_fp{false};  // __re4_reload_hand_fp
    bool re4_reload_hand_fr{false};  // __re4_reload_hand_fr
    std::optional<double> re4_reload_lexit_t{};  // __re4_reload_lexit_t
    ::REManagedObject* re4_reload_shell_joint{nullptr};  // __re4_reload_shell_joint
    std::optional<double> re4_reload_ui_wid{};  // __re4_reload_ui_wid
    ::REManagedObject* re4_reload_weapon_tf{nullptr};  // __re4_reload_weapon_tf
    std::optional<double> re4_rt_given_t{};  // __re4_rt_given_t
    bool re4_rt_held{false};  // __re4_rt_held
    std::optional<double> re4_scope_aim_pitch{};  // __re4_scope_aim_pitch
    std::optional<std::string> re4_scope_bullet_src{};  // __re4_scope_bullet_src
    std::optional<double> re4_scope_bullet_yaw{};  // __re4_scope_bullet_yaw
    std::optional<double> re4_scope_eye{};  // __re4_scope_eye
    bool re4_scope_hold_enable{true};  // __re4_scope_hold_enable
    std::optional<std::string> re4_scope_id{};  // __re4_scope_id
    bool re4_scope_mono_enable{true};  // __re4_scope_mono_enable
    bool re4_scope_native{false};  // __re4_scope_native
    bool re4_scope_no_walk{true};  // __re4_scope_no_walk
    std::optional<double> re4_scope_off_x{};  // __re4_scope_off_x
    std::optional<double> re4_scope_off_y{};  // __re4_scope_off_y
    std::optional<double> re4_scope_off_z{};  // __re4_scope_off_z
    std::optional<double> re4_scope_sens_factor{};  // __re4_scope_sens_factor
    bool re4_scope_via_raw{false};  // __re4_scope_via_raw
    std::optional<double> re4_scope_wid{};  // __re4_scope_wid
    std::optional<double> re4_shell_clone_part{};  // __re4_shell_clone_part
    std::optional<double> re4_shell_clone_scale{};  // __re4_shell_clone_scale
    std::optional<double> re4_shell_kf_preview{};  // __re4_shell_kf_preview
    std::optional<double> re4_shotgun_ratio{};  // __re4_shotgun_ratio
    std::optional<double> re4_snake_off_y{};  // __re4_snake_off_y
    std::optional<double> re4_sq_end_t{};  // __re4_sq_end_t
    std::optional<Vector3f> re4_sq_exit{};  // __re4_sq_exit
    std::optional<double> re4_squeeze_latch_t{};  // __re4_squeeze_latch_t
    std::optional<double> re4_state_damage_mask{};  // __re4_state_damage_mask
    bool re4_stow_block{true};  // __re4_stow_block
    bool re4_stow_guard_hooked{false};  // __re4_stow_guard_hooked
    std::optional<double> re4_stow_guard_until{};  // __re4_stow_guard_until
    std::optional<double> re4_stow_ours_until{};  // __re4_stow_ours_until
    std::optional<Vector3f> re4_throw_dir{};  // __re4_throw_dir
    bool re4_throwsight_active{false};  // __re4_throwsight_active
    std::optional<double> re4_ub_z_delta{};  // __re4_ub_z_delta
    std::optional<bool> re4_use_accessor_item{};  // __re4_use_accessor_item
    std::optional<double> re4_vase_off_y{};  // __re4_vase_off_y
    bool re4_want_crouch_press{false};  // __re4_want_crouch_press
    bool re4_wl_require_type{true};  // __re4_wl_require_type
    bool re4_xbow_dummy_await{false};  // __re4_xbow_dummy_await
    ::REManagedObject* re4_xbow_dummy_obj{nullptr};  // __re4_xbow_dummy_obj
    std::optional<std::string> vr_active_char{};  // __vr_active_char
    bool vr_aim_input{false};  // __vr_aim_input
    std::optional<std::string> vr_anim_l0{};  // __vr_anim_l0
    std::optional<double> vr_arm_chain_L_maxreach{};  // __vr_arm_chain_L_maxreach
    std::optional<Vector3f> vr_arm_chain_L_root{};  // __vr_arm_chain_L_root
    std::optional<Vector3f> vr_arm_chain_lh_clamped_pos{};  // __vr_arm_chain_lh_clamped_pos
    std::optional<double> vr_arm_chain_R_maxreach{};  // __vr_arm_chain_R_maxreach
    std::optional<Vector3f> vr_arm_chain_R_root{};  // __vr_arm_chain_R_root
    std::optional<Vector3f> vr_arm_chain_rh_clamped_pos{};  // __vr_arm_chain_rh_clamped_pos
    bool vr_bare_hands{false};  // __vr_bare_hands
    bool vr_block_aim{false};  // __vr_block_aim
    bool vr_block_fire_when_empty{false};  // __vr_block_fire_when_empty
    bool vr_block_shoot_ready{false};  // __vr_block_shoot_ready
    bool vr_block_two_hand{false};  // __vr_block_two_hand
    bool vr_break_open{false};  // __vr_break_open
    bool vr_burst_active{false};  // __vr_burst_active
    bool vr_camera_fix_active{false};  // vr_camera_fix.active
    std::optional<Vector3f> vr_camera_fix_pos{};  // vr_camera_fix.camera_pos
    std::optional<glm::quat> vr_camera_fix_rot{};  // vr_camera_fix.camera_rot
    std::optional<double> vr_burst_count{};  // __vr_burst_count
    std::optional<double> vr_burst_press_id{};  // __vr_burst_press_id
    bool vr_burst_prev_rt{false};  // __vr_burst_prev_rt
    bool vr_burst_rt_down{false};  // __vr_burst_rt_down
    std::optional<double> vr_burst_seen_press{};  // __vr_burst_seen_press
    std::optional<double> vr_burst_start_seq{};  // __vr_burst_start_seq
    bool vr_camera_decoupled{false};  // __vr_camera_decoupled
    std::optional<double> vr_dbg_fire_mode{};  // __vr_dbg_fire_mode
    bool vr_dbg_switch_docked{false};  // __vr_dbg_switch_docked
    std::optional<double> vr_dbg_wep_id{};  // __vr_dbg_wep_id
    bool vr_disable_motion_grenade_rt{false};  // __vr_disable_motion_grenade_rt
    bool vr_grenade_in_hand{false};  // __vr_grenade_in_hand
    bool vr_grenade_throw{false};  // vr_grenade_throw
    bool vr_hmd_movement_enabled{false};  // __vr_hmd_movement_enabled
    bool vr_holster_block_right_grip_gamepad{false};  // __vr_holster_block_right_grip_gamepad
    bool vr_holster_grab_armed{false};  // __vr_holster_grab_armed
    bool vr_holster_knife{false};  // vr_holster_knife
    bool vr_holster_left_chest_rgrip_as_left_grip{false};  // __vr_holster_left_chest_rgrip_as_left_grip
    bool vr_holster_rgrip_as_knife_ready{false};  // __vr_holster_rgrip_as_knife_ready
    bool vr_in_holster_zone{false};  // __vr_in_holster_zone
    bool vr_in_mag_holster_zone{false};  // __vr_in_mag_holster_zone
    bool vr_is_grenade_equipped{false};  // vr_is_grenade_equipped
    bool vr_knife_flip{false};  // __vr_knife_flip
    bool vr_knife_flip_prev_rt{false};  // __vr_knife_flip_prev_rt

    std::optional<Vector3f> vr_knife_chest_pos{};  // __vr_knife_chest_pos
    std::optional<Vector3f> vr_pistol_holster_pos{};  // __vr_pistol_holster_pos
    bool vr_pistol_holster_zone{false};  // __vr_pistol_holster_zone
    std::optional<Vector3f> vr_grenade_holster_pos{};  // __vr_grenade_holster_pos
    bool vr_grenade_holster_zone{false};  // __vr_grenade_holster_zone
    std::optional<Vector3f> vr_shoulder_holster_pos{};  // __vr_shoulder_holster_pos
    bool vr_shoulder_holster_zone{false};  // __vr_shoulder_holster_zone
    bool vr_knife_holster_zone{false};  // __vr_knife_holster_zone
    bool vr_knife_in_hand{false};  // __vr_knife_in_hand
    bool vr_knife_lh_holster_zone{false};  // __vr_knife_lh_holster_zone
    bool vr_knife_swing{false};  // vr_knife_swing
    std::optional<Vector3f> vr_ldock_anchored{};  // __vr_ldock_anchored
    std::optional<Vector3f> vr_lh_ctrl_raw{};  // __vr_lh_ctrl_raw
    std::optional<Vector3f> vr_lh_ctrl_world{};  // __vr_lh_ctrl_world
    std::optional<Vector3f> vr_lh_joint_pos{};  // __vr_lh_joint_pos
    std::optional<glm::quat> vr_lh_joint_rot{};  // __vr_lh_joint_rot
    std::optional<glm::quat> vr_lh_rot{};  // __vr_lh_rot
    std::optional<Vector3f> vr_lh_world{};  // __vr_lh_world
    bool vr_lt_flip_hold{false};  // __vr_lt_flip_hold
    std::optional<double> vr_lt_flip_press_t{};  // __vr_lt_flip_press_t
    bool vr_lt_flip_prev{false};  // __vr_lt_flip_prev
    std::optional<std::string> vr_mag_hand_pose{};  // __vr_mag_hand_pose
    std::optional<double> vr_mag_hand_trx{};  // __vr_mag_hand_trx
    std::optional<double> vr_mag_hand_try{};  // __vr_mag_hand_try
    std::optional<double> vr_mag_hand_trz{};  // __vr_mag_hand_trz
    bool vr_mag_in_hand{false};  // __vr_mag_in_hand
    bool vr_manual_reload_consume_b{false};  // __vr_manual_reload_consume_b
    bool vr_motion_paused{false};  // __vr_motion_paused
    std::optional<double> vr_motion_tick_id{};  // __vr_motion_tick_id
    bool vr_needs_rack{false};  // __vr_needs_rack
    std::optional<double> vr_post_stow_until{};  // __vr_post_stow_until
    bool vr_pump_anim_active{false};  // __vr_pump_anim_active
    std::optional<double> vr_pump_anim_progress{};  // __vr_pump_anim_progress
    bool vr_rack_block_left_knife{false};  // __vr_rack_block_left_knife
    std::optional<std::string> vr_rack_hand_pose{};  // __vr_rack_hand_pose
    bool vr_raw_l_grip{false};  // __vr_raw_l_grip
    bool vr_raw_r_bbutton{false};  // __vr_raw_r_bbutton
    bool vr_raw_r_trigger{false};  // __vr_raw_r_trigger
    bool vr_re4_two_bone_ik_active{false};  // __vr_re4_two_bone_ik_active
    bool vr_recenter_hold{false};  // __vr_recenter_hold
    std::optional<Vector3f> vr_recoil_pos{};  // vr_recoil_pos
    bool vr_red9_reloading{false};  // __vr_red9_reloading
    std::optional<double> vr_rev_cock_frac{};  // __vr_rev_cock_frac
    bool vr_revolver_cyl_open{false};  // __vr_revolver_cyl_open
    std::optional<glm::quat> vr_rh_aim_rot{};  // __vr_rh_aim_rot
    std::optional<Vector3f> vr_rh_ctrl_raw{};  // __vr_rh_ctrl_raw
    std::optional<Vector3f> vr_rh_joint_pos{};  // __vr_rh_joint_pos
    std::optional<glm::quat> vr_rh_joint_rot{};  // __vr_rh_joint_rot
    std::optional<glm::quat> vr_rh_rot{};  // __vr_rh_rot
    std::optional<Vector3f> vr_rh_world{};  // __vr_rh_world
    std::optional<double> vr_rifle_fire_mode{};  // __vr_rifle_fire_mode
    std::optional<double> vr_right_stick_y{};  // __vr_right_stick_y
    bool vr_rt_down{false};  // __vr_rt_down
    bool vr_rt_raw{false};  // __vr_rt_raw
    bool vr_save_restore_active{false};  // __vr_save_restore_active
    bool vr_scope_active{false};  // vr_scope_active
    std::optional<Vector3f> vr_scope_aim_dir{};  // vr_scope_aim_dir
    std::optional<Vector3f> vr_scope_aim_pos{};  // vr_scope_aim_pos
    std::optional<double> vr_scope_grip_edge_t{};  // __vr_scope_grip_edge_t
    bool vr_scope_grip_prev{false};  // __vr_scope_grip_prev
    std::optional<double> vr_shot_seq{};  // __vr_shot_seq
    bool vr_shotgun_pump_active{false};  // __vr_shotgun_pump_active
    std::optional<double> vr_slide_dock_blend_factor{};  // __vr_slide_dock_blend_factor
    std::optional<Vector3f> vr_slide_hand_world_pos{};  // __vr_slide_hand_world_pos
    std::optional<glm::quat> vr_slide_hand_world_rot{};  // __vr_slide_hand_world_rot
    bool vr_slide_rack_active{false};  // __vr_slide_rack_active
    std::optional<double> vr_stagger_recent_until{};  // __vr_stagger_recent_until
    std::optional<double> vr_support_blend_factor{};  // __vr_support_blend_factor
    bool vr_support_hand_docked{false};  // __vr_support_hand_docked
    std::optional<Vector3f> vr_support_hand_world_pos{};  // __vr_support_hand_world_pos
    std::optional<glm::quat> vr_support_hand_world_rot{};  // __vr_support_hand_world_rot
    bool vr_surge_bridged{false};  // __vr_surge_bridged
    std::optional<double> vr_surge_dx{};  // __vr_surge_dx
    std::optional<double> vr_surge_dz{};  // __vr_surge_dz
    std::optional<double> vr_throw_windup_until{};  // __vr_throw_windup_until
    std::optional<Vector3f> vr_unified_lh_pos{};  // __vr_unified_lh_pos
    std::optional<Vector3f> vr_unified_rh_pos{};  // __vr_unified_rh_pos
    bool vr_unlock_ry{false};  // __vr_unlock_ry
    bool vr_user_stick_active{false};  // __vr_user_stick_active
    bool vr_wsw_pin{false};  // __vr_wsw_pin
    std::optional<double> vr_yaw_sim_x{};  // __vr_yaw_sim_x
};

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
    if (auto* p = RE4VRShared::get()->bool_at(name)) {
        return *p;
    }
    if (auto* p = RE4VRShared::get()->opt_bool_at(name)) {
        return p->value_or(false);
    }
    return false;
}

inline bool lua_not_false(std::string_view name) {
    if (auto* p = RE4VRShared::get()->bool_at(name)) {
        return *p;
    }
    if (auto* p = RE4VRShared::get()->opt_bool_at(name)) {
        return p->value_or(true);
    }
    return true;
}

inline std::optional<double> lua_number(std::string_view name) {
    if (auto* p = RE4VRShared::get()->num_at(name)) {
        return *p;
    }
    return std::nullopt;
}

inline std::optional<std::string> lua_string(std::string_view name) {
    if (auto* p = RE4VRShared::get()->str_at(name)) {
        return *p;
    }
    return std::nullopt;
}

inline void lua_set_bool(std::string_view name, bool v) {
    if (auto* p = RE4VRShared::get()->bool_at(name)) {
        *p = v;
        return;
    }
    if (auto* p = RE4VRShared::get()->opt_bool_at(name)) {
        *p = v;
    }
}

inline void lua_set_number(std::string_view name, double v) {
    if (auto* p = RE4VRShared::get()->num_at(name)) {
        *p = v;
    }
}

inline void lua_set_string(std::string_view name, std::string_view v) {
    if (auto* p = RE4VRShared::get()->str_at(name)) {
        *p = std::string{v};
    }
}

inline void lua_set_nil(std::string_view name) {
    auto& s = *RE4VRShared::get();
    if (auto* p = s.bool_at(name)) {
        *p = false;
        return;
    }
    if (auto* p = s.opt_bool_at(name)) {
        p->reset();
        return;
    }
    if (auto* p = s.num_at(name)) {
        p->reset();
        return;
    }
    if (auto* p = s.str_at(name)) {
        p->reset();
        return;
    }
    if (auto* p = s.vec3_at(name)) {
        p->reset();
        return;
    }
    if (auto* p = s.quat_at(name)) {
        p->reset();
        return;
    }
    if (auto* p = s.obj_at(name)) {
        *p = nullptr;
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
    if (auto* p = RE4VRShared::get()->vec3_at(name)) {
        return *p;
    }
    return std::nullopt;
}

inline std::optional<glm::quat> lua_quat(std::string_view name) {
    if (auto* p = RE4VRShared::get()->quat_at(name)) {
        return *p;
    }
    return std::nullopt;
}

inline void lua_set_vec3(std::string_view name, const Vector3f& v) {
    if (auto* p = RE4VRShared::get()->vec3_at(name)) {
        *p = v;
    }
}

inline void lua_set_quat(std::string_view name, const glm::quat& q) {
    if (auto* p = RE4VRShared::get()->quat_at(name)) {
        *p = q;
    }
}

inline ::REManagedObject* lua_object(std::string_view name) {
    if (auto* p = RE4VRShared::get()->obj_at(name)) {
        return *p;
    }
    return nullptr;
}

inline void lua_set_object(std::string_view name, ::REManagedObject* o) {
    if (auto* p = RE4VRShared::get()->obj_at(name)) {
        *p = o;
    }
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
