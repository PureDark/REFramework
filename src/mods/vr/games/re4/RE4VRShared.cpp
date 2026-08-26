#define NOMINMAX
#include "RE4VRShared.hpp"

#if defined(RE4)
#include <sdk/REGameObject.hpp>
#include <sdk/RETypeDB.hpp>
#include <sdk/REString.hpp>
#include <sdk/SceneManager.hpp>
#include <sdk/SystemArray.hpp>
#include <utility/String.hpp>

#include "RE4VRKillswitch.hpp"


std::shared_ptr<RE4VRShared>& RE4VRShared::get() {
    static auto inst = std::make_shared<RE4VRShared>();
    return inst;
}


bool* RE4VRShared::bool_at(std::string_view n) {
    if (n == "_IsWeaponChanging") {
        return &_IsWeaponChanging;
    }
    if (n == "is_aim") {
        return &is_aim;
    }
    if (n == "is_reticle_displayed") {
        return &is_reticle_displayed;
    }
    if (n == "__re4_ada_relfix") {
        return &re4_ada_relfix;
    }
    if (n == "__re4_ada_relfix2") {
        return &re4_ada_relfix2;
    }
    if (n == "__re4_ada_relfix3") {
        return &re4_ada_relfix3;
    }
    if (n == "__re4_ada_uses_leon_scope") {
        return &re4_ada_uses_leon_scope;
    }
    if (n == "__re4_aim_relatch") {
        return &re4_aim_relatch;
    }
    if (n == "__re4_ar_pg") {
        return &re4_ar_pg;
    }
    if (n == "__re4_ar_suppress") {
        return &re4_ar_suppress;
    }
    if (n == "__re4_at_cannon") {
        return &re4_at_cannon;
    }
    if (n == "__re4_autoreload_gate") {
        return &re4_autoreload_gate;
    }
    if (n == "__re4_boat_active") {
        return &re4_boat_active;
    }
    if (n == "__re4_bolt_in_cycle") {
        return &re4_bolt_in_cycle;
    }
    if (n == "__re4_bolt_in_cycle_dlc") {
        return &re4_bolt_in_cycle_dlc;
    }
    if (n == "__re4_bolt_reaim") {
        return &re4_bolt_reaim;
    }
    if (n == "__re4_boxbreak_active") {
        return &re4_boxbreak_active;
    }
    if (n == "__re4_burst_gate") {
        return &re4_burst_gate;
    }
    if (n == "__re4_clone_finisher_restore") {
        return &re4_clone_finisher_restore;
    }
    if (n == "__re4_clone_no_autogun") {
        return &re4_clone_no_autogun;
    }
    if (n == "__re4_damage_active") {
        return &re4_damage_active;
    }
    if (n == "__re4_empty_trigger_held") {
        return &re4_empty_trigger_held;
    }
    if (n == "__re4_evt60874_fullhide") {
        return &re4_evt60874_fullhide;
    }
    if (n == "__re4_fatalkick_active") {
        return &re4_fatalkick_active;
    }
    if (n == "__re4_fc_off") {
        return &re4_fc_off;
    }
    if (n == "__re4_force_killswitch_bolt") {
        return &re4_force_killswitch_bolt;
    }
    if (n == "__re4_force_killswitch_scope") {
        return &re4_force_killswitch_scope;
    }
    if (n == "__re4_force_ks4_bulletrush") {
        return &re4_force_ks4_bulletrush;
    }
    if (n == "__re4_forcecrouch_active") {
        return &re4_forcecrouch_active;
    }
    if (n == "__re4_forcecrouch_ks4_active") {
        return &re4_forcecrouch_ks4_active;
    }
    if (n == "__re4_fork_canvas") {
        return &re4_fork_canvas;
    }
    if (n == "__re4_fork_gui_matrix") {
        return &re4_fork_gui_matrix;
    }
    if (n == "__re4_fork_mono") {
        return &re4_fork_mono;
    }
    if (n == "__re4_fork_ok") {
        return &re4_fork_ok;
    }
    if (n == "__re4_fp_perf_off") {
        return &re4_fp_perf_off;
    }
    if (n == "__re4_frame_is_gameplay") {
        return &re4_frame_is_gameplay;
    }
    if (n == "__re4_frame_pure_gameplay") {
        return &re4_frame_pure_gameplay;
    }
    if (n == "__re4_gest_mute") {
        return &re4_gest_mute;
    }
    if (n == "__re4_gondola_active") {
        return &re4_gondola_active;
    }
    if (n == "__re4_grappled_active") {
        return &re4_grappled_active;
    }
    if (n == "__re4_holster_killswitch") {
        return &re4_holster_killswitch;
    }
    if (n == "__re4_holster_knife_only") {
        return &re4_holster_knife_only;
    }
    if (n == "__re4_in_mercs") {
        return &re4_in_mercs;
    }
    if (n == "__re4_is_unlimited") {
        return &re4_is_unlimited;
    }
    if (n == "__re4_block_b_drop") {
        return &re4_block_b_drop;
    }
    if (n == "__re4_merc_dot") {
        return &re4_merc_dot;
    }
    if (n == "__re4_in_squeeze") {
        return &re4_in_squeeze;
    }
    if (n == "__re4_jetski_active") {
        return &re4_jetski_active;
    }
    if (n == "__re4_knife_blood_on") {
        return &re4_knife_blood_on;
    }
    if (n == "__re4_knife_change_block_hooked") {
        return &re4_knife_change_block_hooked;
    }
    if (n == "__re4_knife_clonless_grab") {
        return &re4_knife_clonless_grab;
    }
    if (n == "__re4_knife_equipped") {
        return &re4_knife_equipped;
    }
    if (n == "__re4_knife_finisher_shake") {
        return &re4_knife_finisher_shake;
    }
    if (n == "__re4_knife_flip_pre_ks") {
        return &re4_knife_flip_pre_ks;
    }
    if (n == "__re4_knife_flying") {
        return &re4_knife_flying;
    }
    if (n == "__re4_knife_gate") {
        return &re4_knife_gate;
    }
    if (n == "__re4_knife_gate_hook") {
        return &re4_knife_gate_hook;
    }
    if (n == "__re4_knife_holster_hook") {
        return &re4_knife_holster_hook;
    }
    if (n == "__re4_knife_left_clone") {
        return &re4_knife_left_clone;
    }
    if (n == "__re4_knife_left_intent") {
        return &re4_knife_left_intent;
    }
    if (n == "__re4_knife_lh_in_zone") {
        return &re4_knife_lh_in_zone;
    }
    if (n == "__re4_knife_parry_pose") {
        return &re4_knife_parry_pose;
    }
    if (n == "__re4_knife_throw_gripping") {
        return &re4_knife_throw_gripping;
    }
    if (n == "__re4_ks2_as_ks4") {
        return &re4_ks2_as_ks4;
    }
    if (n == "__re4_ks4_active") {
        return &re4_ks4_active;
    }
    if (n == "__re4_ks_active") {
        return &re4_ks_active;
    }
    if (n == "__re4_ks_fp_enabled") {
        return &re4_ks_fp_enabled;
    }
    if (n == "__re4_ks_keep_movement") {
        return &re4_ks_keep_movement;
    }
    if (n == "__re4_leaning_ladder_active") {
        return &re4_leaning_ladder_active;
    }
    if (n == "__re4_leaning_ladder_mounted") {
        return &re4_leaning_ladder_mounted;
    }
    if (n == "__re4_melee_gate") {
        return &re4_melee_gate;
    }
    if (n == "__re4_melee_gate_hook") {
        return &re4_melee_gate_hook;
    }
    if (n == "__re4_merc_bow_pinned") {
        return &re4_merc_bow_pinned;
    }
    if (n == "__re4_minecart2_ks4_active") {
        return &re4_minecart2_ks4_active;
    }
    if (n == "__re4_minecart_ks4_active") {
        return &re4_minecart_ks4_active;
    }
    if (n == "__re4_on_elevator2") {
        return &re4_on_elevator2;
    }
    if (n == "__re4_qk_block") {
        return &re4_qk_block;
    }
    if (n == "__re4_quickknife_hooked") {
        return &re4_quickknife_hooked;
    }
    if (n == "__re4_r4dlc_had") {
        return &re4_r4dlc_had;
    }
    if (n == "__re4_railcar_mode") {
        return &re4_railcar_mode;
    }
    if (n == "__re4_railcar_reloading") {
        return &re4_railcar_reloading;
    }
    if (n == "__re4_railcar_yaw_delta") {
        return &re4_railcar_yaw_delta;
    }
    if (n == "__re4_reload_grab_empty") {
        return &re4_reload_grab_empty;
    }
    if (n == "__re4_reload_hand_fp") {
        return &re4_reload_hand_fp;
    }
    if (n == "__re4_reload_hand_fr") {
        return &re4_reload_hand_fr;
    }
    if (n == "__re4_rt_held") {
        return &re4_rt_held;
    }
    if (n == "__re4_scope_hold_enable") {
        return &re4_scope_hold_enable;
    }
    if (n == "__re4_scope_mono_enable") {
        return &re4_scope_mono_enable;
    }
    if (n == "__re4_scope_native") {
        return &re4_scope_native;
    }
    if (n == "__re4_scope_no_walk") {
        return &re4_scope_no_walk;
    }
    if (n == "__re4_scope_via_raw") {
        return &re4_scope_via_raw;
    }
    if (n == "__re4_stow_block") {
        return &re4_stow_block;
    }
    if (n == "__re4_stow_guard_hooked") {
        return &re4_stow_guard_hooked;
    }
    if (n == "__re4_throwsight_active") {
        return &re4_throwsight_active;
    }
    if (n == "__re4_want_crouch_press") {
        return &re4_want_crouch_press;
    }
    if (n == "__re4_wl_require_type") {
        return &re4_wl_require_type;
    }
    if (n == "__re4_xbow_dummy_await") {
        return &re4_xbow_dummy_await;
    }
    if (n == "__vr_aim_input") {
        return &vr_aim_input;
    }
    if (n == "__vr_bare_hands") {
        return &vr_bare_hands;
    }
    if (n == "__vr_block_aim") {
        return &vr_block_aim;
    }
    if (n == "__vr_block_fire_when_empty") {
        return &vr_block_fire_when_empty;
    }
    if (n == "__vr_block_shoot_ready") {
        return &vr_block_shoot_ready;
    }
    if (n == "__vr_block_two_hand") {
        return &vr_block_two_hand;
    }
    if (n == "__vr_break_open") {
        return &vr_break_open;
    }
    if (n == "__vr_burst_active") {
        return &vr_burst_active;
    }
    if (n == "__vr_burst_prev_rt") {
        return &vr_burst_prev_rt;
    }
    if (n == "__vr_burst_rt_down") {
        return &vr_burst_rt_down;
    }
    if (n == "__vr_camera_decoupled") {
        return &vr_camera_decoupled;
    }
    if (n == "__vr_dbg_switch_docked") {
        return &vr_dbg_switch_docked;
    }
    if (n == "__vr_disable_motion_grenade_rt") {
        return &vr_disable_motion_grenade_rt;
    }
    if (n == "__vr_grenade_in_hand") {
        return &vr_grenade_in_hand;
    }
    if (n == "vr_grenade_throw") {
        return &vr_grenade_throw;
    }
    if (n == "__vr_hmd_movement_enabled") {
        return &vr_hmd_movement_enabled;
    }
    if (n == "__vr_holster_block_right_grip_gamepad") {
        return &vr_holster_block_right_grip_gamepad;
    }
    if (n == "__vr_holster_grab_armed") {
        return &vr_holster_grab_armed;
    }
    if (n == "vr_holster_knife") {
        return &vr_holster_knife;
    }
    if (n == "__vr_holster_left_chest_rgrip_as_left_grip") {
        return &vr_holster_left_chest_rgrip_as_left_grip;
    }
    if (n == "__vr_holster_rgrip_as_knife_ready") {
        return &vr_holster_rgrip_as_knife_ready;
    }
    if (n == "__vr_in_holster_zone") {
        return &vr_in_holster_zone;
    }
    if (n == "__vr_in_mag_holster_zone") {
        return &vr_in_mag_holster_zone;
    }
    if (n == "vr_is_grenade_equipped") {
        return &vr_is_grenade_equipped;
    }
    if (n == "__vr_knife_flip") {
        return &vr_knife_flip;
    }
    if (n == "__vr_knife_flip_prev_rt") {
        return &vr_knife_flip_prev_rt;
    }
    if (n == "__vr_pistol_holster_zone") {
        return &vr_pistol_holster_zone;
    }
    if (n == "__vr_grenade_holster_zone") {
        return &vr_grenade_holster_zone;
    }
    if (n == "__vr_shoulder_holster_zone") {
        return &vr_shoulder_holster_zone;
    }
    if (n == "__vr_knife_holster_zone") {
        return &vr_knife_holster_zone;
    }
    if (n == "__vr_knife_in_hand") {
        return &vr_knife_in_hand;
    }
    if (n == "__vr_knife_lh_holster_zone") {
        return &vr_knife_lh_holster_zone;
    }
    if (n == "vr_knife_swing") {
        return &vr_knife_swing;
    }
    if (n == "__vr_lt_flip_hold") {
        return &vr_lt_flip_hold;
    }
    if (n == "__vr_lt_flip_prev") {
        return &vr_lt_flip_prev;
    }
    if (n == "__vr_mag_in_hand") {
        return &vr_mag_in_hand;
    }
    if (n == "__vr_manual_reload_consume_b") {
        return &vr_manual_reload_consume_b;
    }
    if (n == "__vr_motion_paused") {
        return &vr_motion_paused;
    }
    if (n == "__vr_needs_rack") {
        return &vr_needs_rack;
    }
    if (n == "__vr_pump_anim_active") {
        return &vr_pump_anim_active;
    }
    if (n == "__vr_rack_block_left_knife") {
        return &vr_rack_block_left_knife;
    }
    if (n == "__vr_raw_l_grip") {
        return &vr_raw_l_grip;
    }
    if (n == "__vr_raw_r_bbutton") {
        return &vr_raw_r_bbutton;
    }
    if (n == "__vr_raw_r_trigger") {
        return &vr_raw_r_trigger;
    }
    if (n == "__vr_re4_two_bone_ik_active") {
        return &vr_re4_two_bone_ik_active;
    }
    if (n == "__vr_recenter_hold") {
        return &vr_recenter_hold;
    }
    if (n == "__vr_red9_reloading") {
        return &vr_red9_reloading;
    }
    if (n == "__vr_revolver_cyl_open") {
        return &vr_revolver_cyl_open;
    }
    if (n == "__vr_rt_down") {
        return &vr_rt_down;
    }
    if (n == "__vr_rt_raw") {
        return &vr_rt_raw;
    }
    if (n == "__vr_save_restore_active") {
        return &vr_save_restore_active;
    }
    if (n == "vr_scope_active") {
        return &vr_scope_active;
    }
    if (n == "vr_camera_fix_active") {
        return &vr_camera_fix_active;
    }
    if (n == "__vr_scope_grip_prev") {
        return &vr_scope_grip_prev;
    }
    if (n == "__vr_shotgun_pump_active") {
        return &vr_shotgun_pump_active;
    }
    if (n == "__vr_slide_rack_active") {
        return &vr_slide_rack_active;
    }
    if (n == "__vr_support_hand_docked") {
        return &vr_support_hand_docked;
    }
    if (n == "__vr_surge_bridged") {
        return &vr_surge_bridged;
    }
    if (n == "__vr_unlock_ry") {
        return &vr_unlock_ry;
    }
    if (n == "__vr_user_stick_active") {
        return &vr_user_stick_active;
    }
    if (n == "__vr_wsw_pin") {
        return &vr_wsw_pin;
    }
    return nullptr;

}

std::optional<double>* RE4VRShared::num_at(std::string_view n) {
    if (n == "__re4_ada_a_long_sec") {
        return &re4_ada_a_long_sec;
    }
    if (n == "__re4_animal_center_max_d") {
        return &re4_animal_center_max_d;
    }
    if (n == "__re4_autoreload_blocked") {
        return &re4_autoreload_blocked;
    }
    if (n == "__re4_bolt_aim_cut_t") {
        return &re4_bolt_aim_cut_t;
    }
    if (n == "__re4_bolt_pitch_hold") {
        return &re4_bolt_pitch_hold;
    }
    if (n == "__re4_bolt_shoot_t") {
        return &re4_bolt_shoot_t;
    }
    if (n == "__re4_cart_lean_lx") {
        return &re4_cart_lean_lx;
    }
    if (n == "__re4_coin_off_y") {
        return &re4_coin_off_y;
    }
    if (n == "__re4_crouch_press_frames") {
        return &re4_crouch_press_frames;
    }
    if (n == "__re4_current_knife_wid") {
        return &re4_current_knife_wid;
    }
    if (n == "__re4_damage_end_t") {
        return &re4_damage_end_t;
    }
    if (n == "__re4_dodge_prompt_seen") {
        return &re4_dodge_prompt_seen;
    }
    if (n == "__re4_evt40510_t") {
        return &re4_evt40510_t;
    }
    if (n == "__re4_finisher_prompt_seen") {
        return &re4_finisher_prompt_seen;
    }
    if (n == "__re4_gang3rd_t") {
        return &re4_gang3rd_t;
    }
    if (n == "__re4_gfix_latch_t") {
        return &re4_gfix_latch_t;
    }
    if (n == "__re4_holster_ada_mesh_z") {
        return &re4_holster_ada_mesh_z;
    }
    if (n == "__re4_holster_crouch_gain") {
        return &re4_holster_crouch_gain;
    }
    if (n == "__re4_hookshot_grace_sec") {
        return &re4_hookshot_grace_sec;
    }
    if (n == "__re4_hookshot_ks4_sec") {
        return &re4_hookshot_ks4_sec;
    }
    if (n == "__re4_hookshot_recent_until") {
        return &re4_hookshot_recent_until;
    }
    if (n == "__re4_knife_draw_ours_t") {
        return &re4_knife_draw_ours_t;
    }
    if (n == "__re4_knife_flip_speed") {
        return &re4_knife_flip_speed;
    }
    if (n == "__re4_knife_flip_finger_deg") {
        return &re4_knife_flip_finger_deg;
    }
    if (n == "__re4_knife_flip_pos_x") {
        return &re4_knife_flip_pos_x;
    }
    if (n == "__re4_knife_flip_pos_y") {
        return &re4_knife_flip_pos_y;
    }
    if (n == "__re4_knife_flip_pos_z") {
        return &re4_knife_flip_pos_z;
    }
    if (n == "__re4_knife_reach") {
        return &re4_knife_reach;
    }
    if (n == "__re4_knife_grab_release") {
        return &re4_knife_grab_release;
    }
    if (n == "__re4_knife_grab_trigger") {
        return &re4_knife_grab_trigger;
    }
    if (n == "__re4_knife_home_str") {
        return &re4_knife_home_str;
    }
    if (n == "__re4_knife_lh_dist") {
        return &re4_knife_lh_dist;
    }
    if (n == "__re4_knife_lt_flip_tap") {
        return &re4_knife_lt_flip_tap;
    }
    if (n == "__re4_knife_our_until") {
        return &re4_knife_our_until;
    }
    if (n == "__re4_knife_parry_fresh_until") {
        return &re4_knife_parry_fresh_until;
    }
    if (n == "__re4_knife_swing_threshold") {
        return &re4_knife_swing_threshold;
    }
    if (n == "__re4_ks4_exit_t") {
        return &re4_ks4_exit_t;
    }
    if (n == "__re4_live_wi_t") {
        return &re4_live_wi_t;
    }
    if (n == "__re4_mag_carry") {
        return &re4_mag_carry;
    }
    if (n == "__re4_mag_carry_wid") {
        return &re4_mag_carry_wid;
    }
    if (n == "__re4_mag_eject_kf_preview") {
        return &re4_mag_eject_kf_preview;
    }
    if (n == "__re4_merc_bow_keep_blocked") {
        return &re4_merc_bow_keep_blocked;
    }
    if (n == "__re4_merc_cid") {
        return &re4_merc_cid;
    }
    if (n == "__re4_merc_kind") {
        return &re4_merc_kind;
    }
    if (n == "__re4_merc_round") {
        return &re4_merc_round;
    }
    if (n == "__re4_minidemo_latch_t") {
        return &re4_minidemo_latch_t;
    }
    if (n == "__re4_our_equip_until") {
        return &re4_our_equip_until;
    }
    if (n == "__re4_parry_keep_gun_until") {
        return &re4_parry_keep_gun_until;
    }
    if (n == "__re4_parry_keep_gun_from") {
        return &re4_parry_keep_gun_from;
    }
    if (n == "__re4_parry_last_gun_wid") {
        return &re4_parry_last_gun_wid;
    }
    if (n == "__re4_pose_fade_dur") {
        return &re4_pose_fade_dur;
    }
    if (n == "__re4_push_blend") {
        return &re4_push_blend;
    }
    if (n == "__re4_rack_joint_wid") {
        return &re4_rack_joint_wid;
    }
    if (n == "__re4_railcar_reload_fade") {
        return &re4_railcar_reload_fade;
    }
    if (n == "__re4_reload_lexit_t") {
        return &re4_reload_lexit_t;
    }
    if (n == "__re4_reload_ui_wid") {
        return &re4_reload_ui_wid;
    }
    if (n == "__re4_rt_given_t") {
        return &re4_rt_given_t;
    }
    if (n == "__re4_scope_aim_pitch") {
        return &re4_scope_aim_pitch;
    }
    if (n == "__re4_scope_bullet_yaw") {
        return &re4_scope_bullet_yaw;
    }
    if (n == "__re4_scope_eye") {
        return &re4_scope_eye;
    }
    if (n == "__re4_scope_off_x") {
        return &re4_scope_off_x;
    }
    if (n == "__re4_scope_off_y") {
        return &re4_scope_off_y;
    }
    if (n == "__re4_scope_off_z") {
        return &re4_scope_off_z;
    }
    if (n == "__re4_scope_sens_factor") {
        return &re4_scope_sens_factor;
    }
    if (n == "__re4_scope_wid") {
        return &re4_scope_wid;
    }
    if (n == "__re4_shell_clone_part") {
        return &re4_shell_clone_part;
    }
    if (n == "__re4_shell_clone_scale") {
        return &re4_shell_clone_scale;
    }
    if (n == "__re4_shell_kf_preview") {
        return &re4_shell_kf_preview;
    }
    if (n == "__re4_shotgun_ratio") {
        return &re4_shotgun_ratio;
    }
    if (n == "__re4_snake_off_y") {
        return &re4_snake_off_y;
    }
    if (n == "__re4_sq_end_t") {
        return &re4_sq_end_t;
    }
    if (n == "__re4_squeeze_latch_t") {
        return &re4_squeeze_latch_t;
    }
    if (n == "__re4_state_damage_mask") {
        return &re4_state_damage_mask;
    }
    if (n == "__re4_stow_guard_until") {
        return &re4_stow_guard_until;
    }
    if (n == "__re4_stow_ours_until") {
        return &re4_stow_ours_until;
    }
    if (n == "__re4_ub_z_delta") {
        return &re4_ub_z_delta;
    }
    if (n == "__re4_vase_off_y") {
        return &re4_vase_off_y;
    }
    if (n == "__vr_arm_chain_L_maxreach") {
        return &vr_arm_chain_L_maxreach;
    }
    if (n == "__vr_arm_chain_R_maxreach") {
        return &vr_arm_chain_R_maxreach;
    }
    if (n == "__vr_burst_count") {
        return &vr_burst_count;
    }
    if (n == "__vr_burst_press_id") {
        return &vr_burst_press_id;
    }
    if (n == "__vr_burst_seen_press") {
        return &vr_burst_seen_press;
    }
    if (n == "__vr_burst_start_seq") {
        return &vr_burst_start_seq;
    }
    if (n == "__vr_dbg_fire_mode") {
        return &vr_dbg_fire_mode;
    }
    if (n == "__vr_dbg_wep_id") {
        return &vr_dbg_wep_id;
    }
    if (n == "__vr_lt_flip_press_t") {
        return &vr_lt_flip_press_t;
    }
    if (n == "__vr_mag_hand_trx") {
        return &vr_mag_hand_trx;
    }
    if (n == "__vr_mag_hand_try") {
        return &vr_mag_hand_try;
    }
    if (n == "__vr_mag_hand_trz") {
        return &vr_mag_hand_trz;
    }
    if (n == "__vr_motion_tick_id") {
        return &vr_motion_tick_id;
    }
    if (n == "__vr_post_stow_until") {
        return &vr_post_stow_until;
    }
    if (n == "__vr_pump_anim_progress") {
        return &vr_pump_anim_progress;
    }
    if (n == "__vr_rev_cock_frac") {
        return &vr_rev_cock_frac;
    }
    if (n == "__vr_rifle_fire_mode") {
        return &vr_rifle_fire_mode;
    }
    if (n == "__vr_right_stick_y") {
        return &vr_right_stick_y;
    }
    if (n == "__vr_scope_grip_edge_t") {
        return &vr_scope_grip_edge_t;
    }
    if (n == "__vr_shot_seq") {
        return &vr_shot_seq;
    }
    if (n == "__vr_slide_dock_blend_factor") {
        return &vr_slide_dock_blend_factor;
    }
    if (n == "__vr_stagger_recent_until") {
        return &vr_stagger_recent_until;
    }
    if (n == "__vr_support_blend_factor") {
        return &vr_support_blend_factor;
    }
    if (n == "__vr_surge_dx") {
        return &vr_surge_dx;
    }
    if (n == "__vr_surge_dz") {
        return &vr_surge_dz;
    }
    if (n == "__vr_throw_windup_until") {
        return &vr_throw_windup_until;
    }
    if (n == "__vr_yaw_sim_x") {
        return &vr_yaw_sim_x;
    }
    return nullptr;

}

std::optional<bool>* RE4VRShared::opt_bool_at(std::string_view n) {
    if (n == "__re4_use_accessor_item") {
        return &re4_use_accessor_item;
    }
    return nullptr;

}

std::optional<std::string>* RE4VRShared::str_at(std::string_view n) {
    if (n == "__re4_char_now") {
        return &re4_char_now;
    }
    if (n == "__re4_gameplay_why") {
        return &re4_gameplay_why;
    }
    if (n == "__re4_gest_prev") {
        return &re4_gest_prev;
    }
    if (n == "__re4_gesture_fire") {
        return &re4_gesture_fire;
    }
    if (n == "__re4_knife_char") {
        return &re4_knife_char;
    }
    if (n == "__re4_knife_hand") {
        return &re4_knife_hand;
    }
    if (n == "__re4_ks_err") {
        return &re4_ks_err;
    }
    if (n == "__re4_last_pad") {
        return &re4_last_pad;
    }
    if (n == "__re4_merc_body") {
        return &re4_merc_body;
    }
    if (n == "__re4_rack_joint_name") {
        return &re4_rack_joint_name;
    }
    if (n == "__re4_scope_bullet_src") {
        return &re4_scope_bullet_src;
    }
    if (n == "__re4_scope_id") {
        return &re4_scope_id;
    }
    if (n == "__vr_active_char") {
        return &vr_active_char;
    }
    if (n == "__vr_anim_l0") {
        return &vr_anim_l0;
    }
    if (n == "__vr_mag_hand_pose") {
        return &vr_mag_hand_pose;
    }
    if (n == "__vr_rack_hand_pose") {
        return &vr_rack_hand_pose;
    }
    return nullptr;

}

std::optional<Vector3f>* RE4VRShared::vec3_at(std::string_view n) {
    if (n == "__ldock_off") {
        return &ldock_off;
    }
    if (n == "__ldock_rhprev") {
        return &ldock_rhprev;
    }
    if (n == "__re4_knife_home") {
        return &re4_knife_home;
    }
    if (n == "__re4_knife_throw_dir") {
        return &re4_knife_throw_dir;
    }
    if (n == "__re4_sq_exit") {
        return &re4_sq_exit;
    }
    if (n == "__re4_throw_dir") {
        return &re4_throw_dir;
    }
    if (n == "__vr_arm_chain_L_root") {
        return &vr_arm_chain_L_root;
    }
    if (n == "__vr_arm_chain_lh_clamped_pos") {
        return &vr_arm_chain_lh_clamped_pos;
    }
    if (n == "__vr_arm_chain_R_root") {
        return &vr_arm_chain_R_root;
    }
    if (n == "__vr_arm_chain_rh_clamped_pos") {
        return &vr_arm_chain_rh_clamped_pos;
    }
    if (n == "__vr_knife_chest_pos") {
        return &vr_knife_chest_pos;
    }
    if (n == "__vr_pistol_holster_pos") {
        return &vr_pistol_holster_pos;
    }
    if (n == "__vr_grenade_holster_pos") {
        return &vr_grenade_holster_pos;
    }
    if (n == "__vr_shoulder_holster_pos") {
        return &vr_shoulder_holster_pos;
    }
    if (n == "__vr_ldock_anchored") {
        return &vr_ldock_anchored;
    }
    if (n == "__vr_lh_ctrl_raw") {
        return &vr_lh_ctrl_raw;
    }
    if (n == "__vr_lh_ctrl_world") {
        return &vr_lh_ctrl_world;
    }
    if (n == "__vr_lh_joint_pos") {
        return &vr_lh_joint_pos;
    }
    if (n == "__vr_lh_world") {
        return &vr_lh_world;
    }
    if (n == "vr_recoil_pos") {
        return &vr_recoil_pos;
    }
    if (n == "__vr_rh_ctrl_raw") {
        return &vr_rh_ctrl_raw;
    }
    if (n == "__vr_rh_joint_pos") {
        return &vr_rh_joint_pos;
    }
    if (n == "__vr_rh_world") {
        return &vr_rh_world;
    }
    if (n == "vr_scope_aim_pos") {
        return &vr_scope_aim_pos;
    }
    if (n == "vr_scope_aim_dir") {
        return &vr_scope_aim_dir;
    }
    if (n == "vr_camera_fix_pos") {
        return &vr_camera_fix_pos;
    }
    if (n == "__vr_slide_hand_world_pos") {
        return &vr_slide_hand_world_pos;
    }
    if (n == "__vr_support_hand_world_pos") {
        return &vr_support_hand_world_pos;
    }
    if (n == "__vr_unified_lh_pos") {
        return &vr_unified_lh_pos;
    }
    if (n == "__vr_unified_rh_pos") {
        return &vr_unified_rh_pos;
    }
    return nullptr;

}

std::optional<glm::quat>* RE4VRShared::quat_at(std::string_view n) {
    if (n == "__vr_lh_joint_rot") {
        return &vr_lh_joint_rot;
    }
    if (n == "__vr_lh_rot") {
        return &vr_lh_rot;
    }
    if (n == "__vr_rh_aim_rot") {
        return &vr_rh_aim_rot;
    }
    if (n == "__vr_rh_joint_rot") {
        return &vr_rh_joint_rot;
    }
    if (n == "__vr_rh_rot") {
        return &vr_rh_rot;
    }
    if (n == "vr_camera_fix_rot") {
        return &vr_camera_fix_rot;
    }
    if (n == "__vr_slide_hand_world_rot") {
        return &vr_slide_hand_world_rot;
    }
    if (n == "__vr_support_hand_world_rot") {
        return &vr_support_hand_world_rot;
    }
    return nullptr;

}

::REManagedObject** RE4VRShared::obj_at(std::string_view n) {
    if (n == "__re4_fl_mesh") {
        return &re4_fl_mesh;
    }
    if (n == "__re4_grenade_gen") {
        return &re4_grenade_gen;
    }
    if (n == "__re4_knife_atkUD") {
        return &re4_knife_atkUD;
    }
    if (n == "__re4_knife_last_target") {
        return &re4_knife_last_target;
    }
    if (n == "__re4_knife_lh_clone_go") {
        return &re4_knife_lh_clone_go;
    }
    if (n == "__re4_live_wi") {
        return &re4_live_wi;
    }
    if (n == "__re4_reload_shell_joint") {
        return &re4_reload_shell_joint;
    }
    if (n == "__re4_reload_weapon_tf") {
        return &re4_reload_weapon_tf;
    }
    if (n == "__re4_xbow_dummy_obj") {
        return &re4_xbow_dummy_obj;
    }
    return nullptr;

}

bool RE4VRShared::refresh_unlimited() {
    const double now = re4vr::now();
    if (re4_unlim_t && (now - *re4_unlim_t) < 0.10) {
        return re4_is_unlimited;
    }
    re4_unlim_t = now;
    ::REManagedObject* wi = re4vr::obj_ok(re4_live_wi) ? re4_live_wi : nullptr;
    if (!wi) {
        auto* head = re4vr::head_game_object();
        auto* pe = head ? re4vr::get_component((::REManagedObject*)head, "chainsaw.PlayerEquipment") : nullptr;
        wi = pe ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(pe, "getEquipWeaponItem"); }).value_or(nullptr) : nullptr;
        if (!wi && pe) {
            auto* acc = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(pe, "getEquipWeaponAccessor"); }).value_or(nullptr);
            wi = acc ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(acc, "get_Item"); }).value_or(nullptr) : nullptr;
        }
    }
    re4_is_unlimited = wi && re4vr::safe([&] { return sdk::call_object_func_easy<bool>(wi, "get_IsBulletFull"); }).value_or(false);
    re4_block_b_drop = re4_is_unlimited;
    if (re4_is_unlimited) {
        re4_reload_grab_empty = true;
    }
    return re4_is_unlimited;
}

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

bool call_killswitch_bool(const char* fn, bool default_v) {
    auto ks = RE4VRKillswitch::get();
    if (!ks || fn == nullptr) {
        return default_v;
    }
    const std::string_view n{fn};
    if (n == "is_active") {
        return ks->is_active();
    }
    if (n == "is_pin_release") {
        return ks->is_pin_release();
    }
    if (n == "is_ks2") {
        return ks->is_ks2();
    }
    if (n == "is_ks3") {
        return ks->is_ks3();
    }
    if (n == "is_ks4") {
        return ks->is_ks4();
    }
    if (n == "is_ks5") {
        return ks->is_ks5();
    }
    if (n == "is_fp_only") {
        return ks->is_fp_only();
    }
    if (n == "just_activated") {
        return ks->just_activated();
    }
    if (n == "just_deactivated") {
        return ks->just_deactivated();
    }
    if (n == "is_cutscene_active") {
        return ks->is_cutscene_active();
    }
    if (n == "is_real_cutscene") {
        return ks->is_real_cutscene();
    }
    if (n == "is_crouch_active") {
        return ks->is_crouch_active();
    }
    if (n == "is_player_camera_active") {
        return ks->is_player_camera_active();
    }
    if (n == "is_pure_gameplay") {
        return ks->is_pure_gameplay();
    }
    return default_v;
}

bool is_ks_active() {
    if (RE4VRShared::get()->re4_throwsight_active) {
        return true;
    }
    if (RE4VRShared::get()->re4_ks_keep_movement) {
        return false;
    }
    return RE4VRKillswitch::get()->is_active();
}

std::optional<double> call_killswitch_number(const char* fn) {
    auto ks = RE4VRKillswitch::get();
    if (!ks || fn == nullptr) {
        return std::nullopt;
    }
    const std::string_view n{fn};
    if (n == "get_stage_name") {
        if (auto v = ks->get_stage_name()) {
            return (double)*v;
        }
        return std::nullopt;
    }
    if (n == "get_space_id") {
        if (auto v = ks->get_space_id()) {
            return (double)*v;
        }
        return std::nullopt;
    }
    if (n == "get_cam_state") {
        if (auto v = ks->get_cam_state()) {
            return (double)*v;
        }
        return std::nullopt;
    }
    if (n == "get_anim_blend_back") {
        return (double)ks->get_anim_blend_back();
    }
    if (n == "get_zone_count") {
        return (double)ks->get_zone_count();
    }
    return std::nullopt;
}

std::optional<std::string> call_killswitch_string(const char* fn) {
    auto ks = RE4VRKillswitch::get();
    if (!ks || fn == nullptr) {
        return std::nullopt;
    }
    const std::string_view n{fn};
    if (n == "get_stage_name") {
        if (auto v = ks->get_stage_name()) {
            return std::to_string(*v);
        }
        return std::nullopt;
    }
    if (n == "get_activating_controller") {
        return ks->get_activating_controller();
    }
    if (n == "get_controller") {
        return ks->get_controller();
    }
    if (n == "get_previous_controller") {
        return ks->get_previous_controller();
    }
    return std::nullopt;
}
}

#endif
