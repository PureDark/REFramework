#pragma once

#if defined(RE4)
#include <chrono>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include <sdk/REMath.hpp>
#include <sdk/RETransform.hpp>
#include <sol/sol.hpp>

#include "../../../../Mod.hpp"
#include "HookManager.hpp"

// Builtin port of scripts/re4/re4_vr_binding.lua
class RE4VRBinding : public Mod {
public:
    static std::shared_ptr<RE4VRBinding>& get();
    std::string_view get_name() const override { return "RE4VRBinding"; }

    std::optional<std::string> on_initialize() override;
    void on_config_load(const utility::Config& cfg) override;
    void on_lua_state_created(sol::state& lua) override;
    void on_lua_state_destroyed(sol::state& lua) override;
    void on_frame() override;
    bool on_pre_gui_draw_element(REComponent* gui_element, void* primitive_context) override;

private:
    struct Prefs {
        bool hide_ref_overlay{false};
        float long_press_sec{1.5f};
        float short_min_sec{0.0f};
        bool enable_180_rotation{false};
        float turn180_window_sec{0.17f};
        float turn180_ly_sec{0.10f};
        float turn180_rb_sec{0.35f};
        bool enable_snapturn{false};
        float snapturn_deg{45.0f};
        float snapturn_thresh{0.75f};
        float turn180_sec{0.15f};
    };
    struct Frame {
        bool A{false}, B{false}, X{false}, Y{false};
        bool LB{false}, RB{false}, LS{false}, RS{false};
        bool BACK{false}, START{false};
        bool DPAD_UP{false}, DPAD_DOWN{false}, DPAD_LEFT{false}, DPAD_RIGHT{false};
        float LT{0.0f}, RT{0.0f};
        float LX{0.0f}, LY{0.0f}, RX{0.0f}, RY{0.0f};
    };
    struct Edge {
        bool prev{false};
        int timer{0};
    };
    struct Zone {
        int32_t stage{0};
        float x{0}, y{0}, z{0}, r{3.0f};
    };
    struct AdaRA {
        bool prev{false};
        std::optional<double> down_t{};
        bool fired_rb{false};
        int a_timer{0};
        int rb_timer{0};
        double a_until{0};
        double rb_until{0};
        double last_a{-999.0};
    };

    void load_json();
    void save_json();
    void register_ui();
    void draw_snapturn_ui(const char* sfx);
    void reset_runtime();
    double now_clock() const;

    bool ensure_init();
    bool digital(uint64_t action, uint64_t hand) const;
    ::REManagedObject* binding_cm();
    ::REManagedObject* binding_ctx();
    std::optional<int32_t> equip_wid();
    bool grenade_equipped_live();
    bool player_in_grapple();
    bool player_in_battle();
    bool stage_parent_chain_has(const char* prefix);
    bool is_throwsight_stage();
    bool is_boat_stage();
    bool is_symbol_riddle();
    bool is_turret_mounted();
    bool is_ada_raw_a_zone();
    bool is_mercs_active();
    bool is_ada_active();
    void cache_menu_singletons();
    void resolve_chapter_gui_enums();
    void resolve_file_reader_enums();
    bool is_chapter_result_gui_open();
    bool is_file_reader_gui_open();
    bool is_any_menu_open(bool ignore_hud_off = false);
    bool is_map_open_now();
    bool is_binoculars_active();
    bool is_binoculars_active_this_frame();
    float bino_val(const char* key, float fallback);
    void bino_zoom_tick();
    ::REManagedObject* find_ctl(::REManagedObject* c, const char* want, int depth, int& budget);
    bool is_dodge_gimmick_now();
    bool is_rect_prompt_now();
    bool is_leon_lb_prompt_now();
    bool is_dodge_prompt_now();
    bool ada_pitch_free();
    void apply_prompt_grip(Frame& f, bool grip_down);
    void apply_finisher_rt(Frame& f, bool window_on, bool trigger_down);
    void play_gui_sound(int32_t enum_val);
    void play_body_sound(uint32_t id);
    void grant_flamethrower_to_armoury();
    bool edge_detect(Edge& e, bool pressed);
    void qt_reset();
    void qt_update(float ly, float dt);
    void apply_yaw_delta(float step);
    void apply_frame(Frame& f);
    void vigem_init();
    void vigem_axis(const char* n, float v);
    void vigem_trigger(const char* n, float v);
    void vigem_button(const char* n, bool v);
    void overlay_set_enabled(bool on);
    void overlay_tick();
    void publish_ada_ra();
    void tick_main();
    void apply_dpad_shift(Frame& f, bool l_trigger, bool lt_flip_shift, const Vector2f& rstick);
    void apply_rt_attack(Frame& f, bool r_trigger, bool gren_live, bool& grenade_motion_rt_armed);
    bool scope_grip_aim_blocked(bool grip_now);
    void apply_r_grip_aim(Frame& f, bool gren_blocks);
    bool right_grip_maps_to_gamepad();
    bool holster_right_grip_counts_as_knife_ready();
    bool ks_active();
    bool ks2();
    bool ks4();
    ::REManagedObject* busy_controller();
    int32_t resolve_enum(const char* type_name, const char* field, int32_t fallback);

    static void post_is_enable_fire(uintptr_t& ret_val, sdk::RETypeDefinition* ret_ty, uintptr_t ret_addr);
    static void post_is_enable_autoreload(uintptr_t& ret_val, sdk::RETypeDefinition* ret_ty, uintptr_t ret_addr);
    static HookManager::PreHookResult pre_nop(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);

    Prefs m_prefs{};
    bool m_inited{false};
    bool m_was_active{false};
    bool m_ref_overlay_synced{false};
    int m_ref_overlay_tick{0};
    bool m_lt_b_overlay_was{false};
    bool m_prev_l_grip{false};
    int m_grenade_throw_cooldown{0};
    int m_grenade_rt_pulse_frames{0};
    bool m_prev_vr_grenade_throw{false};
    std::optional<double> m_dual_trigger_start_clock{};
    bool m_dual_trigger_fired{false};
    std::optional<double> m_dual_trigger_gap_clock{};
    int m_start_hold_timer{0};
    std::optional<double> m_ee_flame_clock{};
    bool m_ee_flame_fired{false};
    std::optional<double> m_ee_flame_gap_clock{};
    struct LaHold {
        bool pressed{false};
        int frames{0};
        bool fired_long{false};
        int short_timer{0};
        bool short_is_ada{false};
        int long_timer{0};
        bool long_is_ada{false};
        bool long_consumed{false};
        bool back_guard{false};
        bool ks_x_guard{false};
    } m_la{};
    Edge m_edge_r_a{}, m_edge_r_b{}, m_edge_r_jc{}, m_edge_l_a_b{};
    struct Qt {
        float DOWN{-0.7f}, RELEASE{-0.3f}, WINDOW{0.17f};
        float LY_SEC{0.10f}, RB_SEC{0.35f};
        int POST_FRAMES{60};
        int phase{0};
        float window_time{0.0f};
        int seq{0};
        bool cooldown{false};
        int post{0};
        double t0{0.0};
        bool st_armed{true};
        float turn_left{0.0f};
        double turn_last{0.0};
    } m_qt{};
    struct Bino {
        bool active{false};
        float offset{0.0f};
        float start_offset{2.5f};
        float min_offset{-7.0f};
        float max_offset{2.5f};
        float stick_speed{3.0f};
        int scan_frame{-1};
        bool scan_active{false};
    } m_bino{};
    struct PGrip {
        bool fired{false};
        std::string btn{};
        int frames{0};
        double until_t{0};
        double win_t{-999};
    } m_pgrip{};
    struct RtP {
        bool fired{false};
        int frames{0};
        double until_t{0};
        double win_t{-999};
    } m_rtp{};
    AdaRA m_ada_ra{};
    double m_rect_prompt_last{-999};
    double m_leon_lb_last{-999};
    double m_dodge_circle_last{-999};
    double m_ada_pitch_gui_last{-999};
    int32_t m_turret_gimmick{6};
    sdk::RETypeDefinition* m_gimmickfix_td{nullptr};
    sdk::RETypeDefinition* m_player_cam_td{nullptr};
    ::REManagedObject* m_gui_manager{nullptr};
    ::REManagedObject* m_attache_case{nullptr};
    ::REManagedObject* m_map_manager{nullptr};
    ::REManagedObject* m_pause_manager{nullptr};
    ::REManagedObject* m_armoury_manager{nullptr};
    std::vector<int32_t> m_chapter_gui_vals{};
    std::vector<int32_t> m_file_reader_gui_vals{};
    int32_t m_render_default{0};
    bool m_chapter_resolved{false};
    bool m_file_resolved{false};
    bool m_ui_registered{false};
    sol::protected_function m_vigem_axis_fn;
    sol::protected_function m_vigem_trigger_fn;
    sol::protected_function m_vigem_button_fn;
    std::chrono::steady_clock::time_point m_clock_origin{std::chrono::steady_clock::now()};
};
#endif
