#pragma once

#if defined(RE4)
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <json.hpp>
#include <sdk/REMath.hpp>
#include "../../../../Mod.hpp"
#include "HookManager.hpp"

// Builtin port of scripts/re4/re4_vr_weapons.lua
class RE4VRWeapons : public Mod {
public:
    static std::shared_ptr<RE4VRWeapons>& get();
    std::string_view get_name() const override { return "RE4VRWeapons"; }

    std::optional<std::string> on_initialize() override;
    void on_lua_state_created(sol::state& lua) override;
    void on_lua_state_destroyed(sol::state& lua) override;
    void on_frame() override;
    void on_pre_application_entry(void* entry, const char* name, size_t hash) override;
    void on_application_entry(void* entry, const char* name, size_t hash) override;

    bool is_knife_id(int32_t id) const;
    bool is_scope_weapon(int32_t id) const;
    ::REManagedObject* find_knife_hc();
    ::REManagedObject* knife_get_attack_ud(::REManagedObject* hc);
    void do_knife_melee();

private:
    struct ThrowCfg {
        bool enabled{true};
        float vmin{4.0f};
        float vmax{18.0f};
        float gravity{9.8f};
        float tumble{12.0f};
        float homing{0.35f};
        float assist_cone{18.0f};
        float assist_dist{12.0f};
        float windup{0.12f};
        float return_time{0.45f};
        nlohmann::json extra{nlohmann::json::object()};
    };
    struct Flight {
        bool active{false};
        Vector3f pos{};
        Vector3f vel{};
        glm::quat rot{1, 0, 0, 0};
        glm::quat spin{1, 0, 0, 0};
        double t0{0};
        bool returning{false};
        bool landed{false};
        ::REGameObject* go{nullptr};
        ::RETransform* tf{nullptr};
        Vector3f home{};
        Vector3f start_pos{};
        bool hit_done{false};
        bool clone_throw{false};
        bool is_left{false};
    };
    struct ScopeProto {
        bool enabled{false};
        nlohmann::json data{nlohmann::json::object()};
    };
    struct Snappy {
        bool enabled{false};
        nlohmann::json data{nlohmann::json::object()};
    };

    void export_globals(sol::state& lua);
    void load_json();
    void save_hide_body();
    void save_scope_proto();
    void save_snappy();
    void save_throw();
    void scope_killswitch_tick();
    void scope_hide_arms_tick(bool on);
    void scope_walk_body(::RETransform* tf, bool visible, int depth);
    void scope_set_all_materials(::REManagedObject* renderer, bool visible);
    bool gun_bolt_cycle_active(int32_t ewid);
    void scope_proto_tick();
    void iron_sight_tick(std::optional<int32_t> wid);
    void hide_body_weapons_tick();
    void hide_assist_light();
    void sync_assist_light();
    void snappy_wep_tick();
    void weapon_switch_skip_tick();
    void keep_knife_out();
    void update_knife_holster_timer();
    void knife_flight_tick();
    void knife_flight_apply();
    void update_throw_velocity();
    void throw_on_frame();
    void melee_on_frame();
    void grenade_on_frame();
    void publish_scope_globals();
    bool is_grenade_equipped();
    bool is_knife_equipped();
    bool is_right_grip_held();
    std::optional<Vector3f> get_hmd_forward();
    std::optional<Vector3f> get_throw_direction();
    void knife_throw_launch(const Vector3f& dir, float speed);
    std::optional<Vector3f> knife_hand_world();
    ::REManagedObject* knife_pick_target(const std::optional<Vector3f>& kpos, bool proximity_only, float reach);
    void knife_flight_hit_scan();
    ::REManagedObject* get_player_ctx();
    std::optional<int32_t> get_equip_weapon_id();
    void register_ui();

    static HookManager::PreHookResult pre_change_weapon(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static HookManager::PreHookResult pre_request_equip_knife(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static HookManager::PreHookResult pre_equip_weapon(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static HookManager::PreHookResult pre_change_active(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static HookManager::PreHookResult pre_pool_damage(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static HookManager::PreHookResult pre_attack_hit(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static HookManager::PreHookResult pre_calc_damage(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static HookManager::PreHookResult pre_gun_object(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static void post_nop(uintptr_t& ret_val, sdk::RETypeDefinition* ret_ty, uintptr_t ret_addr);

    std::unordered_set<int32_t> m_knife_ids{5000, 5001, 5002, 5003, 5006, 6107, 6108, 6305};
    std::unordered_set<int32_t> m_scope_weps{4400, 4401, 4402, 4202, 6105, 6114};
    std::unordered_set<int32_t> m_iron_rifles{4400, 4401, 4402, 6105, 6114};
    std::unordered_set<int32_t> m_bolt_rifles{4400, 6114};
    std::unordered_set<int32_t> m_grenade_ids{5400, 5401, 5402};

    bool m_hide_body{true};
    bool m_disable_assist_light{false};
    ScopeProto m_scope_proto{};
    Snappy m_snappy{};
    ThrowCfg m_throw{};
    Flight m_fly{};
    bool m_knife_equipped{false};
    bool m_knife_flying{false};
    std::string m_knife_hand{"R"};
    bool m_prev_swing{false};
    bool m_grip_was{false};
    double m_windup_t{0};
    bool m_winding{false};
    Vector3f m_hand_pos{};
    Vector3f m_hand_vel{};
    std::optional<double> m_last_hand_t{};
    std::optional<int32_t> m_scope_wid{};
    std::string m_scope_id{};
    bool m_scope_via_raw{false};
    bool m_scope_native{false};
    bool m_force_ks_scope{false};
    bool m_force_ks_bolt{false};
    bool m_scope_arms_on{false};
    bool m_ui_registered{false};
    bool m_snappy_applied{false};
    uintptr_t m_snappy_last_body{0};
    int m_kko_frames{0};
    std::optional<float> m_kko_orig{};
    ::REGameObject* m_wsw_body{nullptr};
    ::REManagedObject* m_wsw_fsm{nullptr};
    ::REManagedObject* m_wsw_mot{nullptr};
};
#endif
