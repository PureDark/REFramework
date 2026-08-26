#pragma once

#if defined(RE4)
#include <chrono>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <sdk/REMath.hpp>
#include <reframework/API.h>

#include "HookManager.hpp"
#include "../../../../Mod.hpp"

// Builtin port of scripts/re4/re4vr/re4_vr_killswitch.lua (RE4-only).
class RE4VRKillswitch : public Mod {
public:
    static std::shared_ptr<RE4VRKillswitch>& get();

    std::string_view get_name() const override { return "RE4VRKillswitch"; }

    std::optional<std::string> on_initialize() override;
    void on_lua_state_created(sol::state& lua) override;
    void on_lua_state_destroyed(sol::state& lua) override;
    void on_pre_application_entry(void* entry, const char* name, size_t hash) override;
    void on_application_entry(void* entry, const char* name, size_t hash) override;

    struct Zone {
        std::optional<int32_t> stage{};
        std::optional<int32_t> space{};
        float x{0.0f};
        float y{0.0f};
        float z{0.0f};
        float r{3.0f};
        int level{2};
        std::optional<int32_t> camstate{};
        std::string name{};
    };

    struct EpisodeEntry {
        std::optional<int32_t> stage{};
        std::optional<int32_t> space{};
        std::optional<int32_t> camstate{};
        std::optional<Vector3f> pos{};
    };

    bool is_active() const { return m_killswitch_active; }
    bool is_pin_release() const { return m_pin_release_active; }
    bool is_ks2() const;
    bool is_ks3() const;
    bool is_ks4() const;
    bool is_ks5() const { return m_ks5_active; }
    bool is_fp_only() const { return m_ks3_active; }
    bool is_crouch_active();
    bool is_pure_gameplay();
    bool is_player_camera_active();
    bool is_real_cutscene();
    bool just_activated() const { return m_killswitch_active && !m_was_active; }
    bool just_deactivated() const { return !m_killswitch_active && m_was_active; }
    bool is_cutscene_active() const { return m_killswitch_active; }

    ::REManagedObject* get_busy_controller();
    std::optional<std::string> get_controller() const { return m_current_controller; }
    std::optional<std::string> get_previous_controller() const { return m_previous_controller; }
    std::optional<int32_t> get_cam_state() const { return m_current_cam_state; }
    std::optional<int32_t> get_stage_name() const { return m_current_stage; }
    std::optional<int32_t> get_space_id() const { return m_current_space; }
    float get_anim_blend_back() const { return m_anim_blend_back; }
    std::optional<std::string> get_activating_controller() const { return m_activating_reason; }

    bool get_fp_enabled() const { return m_fp_enabled; }
    void set_fp_enabled(bool v);

    std::pair<bool, std::string> mark_current_zone(int level, std::optional<float> radius);
    std::pair<bool, std::string> remove_last_zone();
    int reload_zones();
    const std::vector<Zone>& get_zones() const { return m_zones; }
    int get_zone_count() const { return (int)m_zones.size(); }
    const EpisodeEntry* get_current_entry() const;

    ::REManagedObject* get_player_context_api();
    ::REGameObject* get_player_body_api();

private:
    struct LevelRule {
        int32_t state{0};
        std::vector<std::string> jack{};
        std::vector<std::string> node{};
    };

    static constexpr float JUMPDOWN_HOLD = 0.5f;
    static constexpr float ANIM_BLEND_DURATION = 0.2f;
    static constexpr float EVT60874_DELAY = 1.2f;
    static constexpr float EVT40510_DELAY = 5.5f;
    static constexpr float DAMAGE_HOLD = 0.35f;
    static constexpr float LADDER_EXIT_ENDFRAME = 100.0f;
    static constexpr int64_t PARENT_GIMMICK_BIT = 9007199254740992LL;
    static constexpr const char* ZONES_FILE = "re4_vr/re4_vr_killswitch_zones.json";
    static constexpr const char* KS_CFG_FILE = "re4_vr/re4_vr_killswitch_cfg.json";

    void install_lua_api(sol::state& lua);
    void load_zones();
    void save_zones();
    void load_ks_cfg();
    void save_ks_cfg();
    void reset_runtime();
    void tick_update_scene();
    void evaluate();
    void evaluate_core();
    void publish_globals();
    void reset_frame_flags();

    double now_clock() const;

    ::REManagedObject* character_manager();
    ::REManagedObject* camera_system();
    ::REManagedObject* gui_manager();
    ::REManagedObject* player_context();
    ::REGameObject* player_body();
    std::optional<Vector3f> player_pos();
    std::pair<std::optional<int32_t>, std::optional<int32_t>> read_stage_space();

    bool player_gimmick_active();
    std::optional<int32_t> coop_jacked_prio();
    bool player_is_coop_jacked();
    const std::unordered_set<int32_t>* grappled_prio();
    bool player_is_grappled();
    bool player_is_boxbreak();
    bool player_is_ladder();
    bool player_is_ladder_exit(bool cam_is_gameplay);

    ::REManagedObject* find_mfsm2(::REGameObject* body);
    ::REManagedObject* find_motion(::REGameObject* body);
    bool player_node_has(std::string_view token);
    bool player_jack_has(std::string_view token);

    void resolve_state_vals();
    bool is_gameplay_camstate(std::optional<int32_t> st);
    bool is_pinrelease_camstate(std::optional<int32_t> st);
    bool is_airborne_camstate(std::optional<int32_t> st);
    bool match_level(std::optional<int32_t> st, const std::optional<std::unordered_set<int32_t>>& vals, const std::vector<LevelRule>& rules);
    bool is_ks2_camstate(std::optional<int32_t> st);
    bool is_ks3_camstate(std::optional<int32_t> st);
    bool is_ks4_camstate(std::optional<int32_t> st);
    std::optional<int> zone_level_for(const EpisodeEntry* entry);

    bool is_real_cutscene_impl(std::optional<std::string>* why = nullptr);
    std::optional<int32_t> read_cam_state(::REManagedObject* busy);
    std::optional<int32_t> read_gimmick_type(::REManagedObject* busy);
    std::optional<int32_t> read_live_cam_state();
    bool is_player_cam(::REManagedObject* busy);

    const std::unordered_set<int32_t>* gondola_vals();
    bool has_parent_gimmick();
    bool is_on_gondola();
    const std::unordered_set<int32_t>* legtrap_vals();
    bool is_in_legholdtrap();

    std::optional<int32_t> squeeze_high_prio();
    bool is_gimmick_ks3_spot();
    std::optional<int32_t> minidemo_prio();
    bool is_minidemo_ks4_spot();
    std::optional<int32_t> gfix_low_prio();
    bool is_gimmickfix_ks4_spot();
    bool is_gimmickfix_ks5_spot();
    bool is_gimmick_motion_now();
    const std::unordered_set<int32_t>* demo_prios();
    bool is_demo_priority_now();
    bool is_carrying();

    ::REManagedObject* find_elevator_59100();
    bool is_riding_elevator_59100();
    bool is_jetski_stage();
    std::optional<std::string> minecart_ks4_kind();
    bool is_on_jetski();
    bool is_on_boat();
    void resolve_parentgimmick_bit();
    bool is_on_railcar();
    bool is_throwsight_stage();

    bool is_in_elevator();
    const std::unordered_set<int32_t>* elevtrouble_vals();
    bool is_elevator_trouble();
    bool is_in_elevator2_zone();
    bool is_in_elevator3_zone();
    bool is_parented_to_elevator();
    bool is_in_elevator5_cabin();
    bool elev5_at_endpoint(float y);
    bool elevator5_update();

    static HookManager::PreHookResult pre_try_use(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static void post_try_use(uintptr_t& ret_val, sdk::RETypeDefinition* ret_ty, uintptr_t ret_addr);

    bool m_fp_enabled{true};
    bool m_ks2_as_ks4{true};
    bool m_killswitch_active{false};
    bool m_pin_release_active{false};
    bool m_ks2_active{false};
    bool m_ks3_active{false};
    bool m_ks4_active{false};
    bool m_ks5_active{false};
    bool m_boxbreak_active{false};
    bool m_fp_latch{false};
    std::optional<int32_t> m_fp_latch_state{};
    int m_fp_latch_level{0};
    bool m_was_active{false};
    bool m_prev_full_off{false};
    std::optional<std::string> m_current_controller{};
    std::optional<std::string> m_previous_controller{};
    std::optional<int32_t> m_current_cam_state{};
    std::optional<int32_t> m_current_stage{};
    std::optional<int32_t> m_current_space{};
    std::optional<std::string> m_activating_reason{};
    bool m_force_killswitch{false};
    float m_anim_blend_back{0.0f};
    double m_anim_blend_back_t{0.0};
    bool m_prev_ks4_exit{false};
    bool m_prev_ks2_exit{false};
    bool m_prev_ks3_exit{false};
    bool m_ladder_exit_latched{false};
    double m_jumpdown_until{0.0};
    bool m_jumpdown_confirmed{false};
    double m_fc_ks4_until{0.0};
    std::optional<double> m_evt60874_t0{};
    double m_damage_until{0.0};
    double m_hookshot_seen_t{0.0};
    bool m_has_err{false};
    int32_t m_eval_frame{-1};
    bool m_ui_added{false};
    bool m_hooked{false};

    std::vector<Zone> m_zones{};
    std::optional<EpisodeEntry> m_cur_episode_entry{};
    std::optional<EpisodeEntry> m_last_episode_entry{};

    ::REManagedObject* m_character_manager{nullptr};
    ::REManagedObject* m_camera_system{nullptr};
    ::REManagedObject* m_gui_manager{nullptr};
    ::REManagedObject* m_mfsm2{nullptr};
    ::REGameObject* m_mfsm2_body{nullptr};
    ::REManagedObject* m_motion{nullptr};
    ::REGameObject* m_motion_body{nullptr};
    ::REManagedObject* m_elev59100_comp{nullptr};
    ::REManagedObject* m_railcar_mgr{nullptr};

    sdk::RETypeDefinition* m_player_cam_td{nullptr};
    sdk::RETypeDefinition* m_gimmick_motion_td{nullptr};
    sdk::RETypeDefinition* m_gimmick_fix_td{nullptr};
    sdk::RETypeDefinition* m_action_camera_td{nullptr};
    sdk::RETypeDefinition* m_vehicle_camera_td{nullptr};
    sdk::RETypeDefinition* m_leaning_ladder_td{nullptr};

    std::optional<std::unordered_set<int32_t>> m_gameplay_vals{};
    std::optional<std::unordered_set<int32_t>> m_pinrelease_vals{};
    std::optional<std::unordered_set<int32_t>> m_ks2_vals{};
    std::optional<std::unordered_set<int32_t>> m_ks3_vals{};
    std::optional<std::unordered_set<int32_t>> m_ks4_vals{};
    std::vector<LevelRule> m_ks2_rules{};
    std::vector<LevelRule> m_ks3_rules{};
    std::vector<LevelRule> m_ks4_rules{};
    std::optional<int32_t> m_damage_int{};
    std::optional<int32_t> m_hookshot_int{};
    std::optional<int32_t> m_gimmick_int{};
    std::optional<int32_t> m_landing_int{};
    std::optional<int32_t> m_forcecrouch_int{};

    std::optional<int32_t> m_coop_jacked_prio{};
    bool m_coop_jacked_tried{false};
    std::optional<std::unordered_set<int32_t>> m_grappled_prio{};
    std::optional<std::unordered_set<int32_t>> m_gondola_vals{};
    std::optional<std::unordered_set<int32_t>> m_legtrap_vals{};
    std::optional<int32_t> m_squeeze_high_prio{};
    bool m_squeeze_high_tried{false};
    std::optional<int32_t> m_minidemo_prio{};
    std::optional<int32_t> m_gfix_low_prio{};
    std::optional<std::unordered_set<int32_t>> m_demo_prios{};
    std::optional<std::unordered_set<int32_t>> m_elevtrouble_vals{};
    std::optional<int64_t> m_parentgimmick_bit{};

    double m_squeeze_latch_t{-1.0e9};
    double m_minidemo_latch_t{-1.0e9};
    double m_gfix_latch_t{-1.0e9};

    struct {
        bool latch{false};
        bool prev_gim{false};
        std::optional<float> y{};
        double t{0.0};
        double still_since{0.0};
        std::optional<float> target{};
        bool moved_once{false};
    } m_elev5{};

    bool m_jetski_active{false};
    std::chrono::steady_clock::time_point m_clock_origin{std::chrono::steady_clock::now()};
};
#endif
