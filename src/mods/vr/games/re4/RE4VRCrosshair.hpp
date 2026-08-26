#pragma once

#if defined(RE4)
#include <chrono>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <sdk/REMath.hpp>
#include <sdk/RETransform.hpp>

#include "../../../../Mod.hpp"
#include "HookManager.hpp"

// Builtin port of scripts/re4/re4_vr_crosshair.lua
class RE4VRCrosshair : public Mod {
public:
    static std::shared_ptr<RE4VRCrosshair>& get();
    std::string_view get_name() const override { return "RE4VRCrosshair"; }

    std::optional<std::string> on_initialize() override;
    void on_config_load(const utility::Config& cfg) override;
    void on_lua_state_created(sol::state& lua) override;
    void on_lua_state_destroyed(sol::state& lua) override;
    void on_pre_application_entry(void* entry, const char* name, size_t hash) override;
    bool on_pre_gui_draw_element(REComponent* gui_element, void* primitive_context) override;

    double now_clock() const;
    bool is_finisher_prompt() const;
    bool is_dodge_prompt() const;

private:
    void load_json();
    void save_json();
    void load_hud_json();
    void save_hud_json();
    void load_laser_json();
    void save_laser_json();
    void register_ui();
    void publish_re4();
    bool ks_active();
    void* resolve_type(const char* name);
    int32_t resolve_enum(const char* type_name, const char* field, int32_t fallback);
    ::REManagedObject* create_instance(const char* name);
    void cast_ray_async(::REManagedObject* ray_result, const Vector3f& start_pos, const Vector3f& end_pos, int32_t layer, ::REManagedObject* filter_info = nullptr);
    void update_crosshair_world_pos(const Vector3f& start_pos, const Vector3f& end_pos);
    ::REGameObject* find_weapon_on_player_body(const std::string& weapon_name);
    ::REManagedObject* current_scene();
    void update_muzzle_data();
    void apply_reticle_params();
    void write_vec4(::REManagedObject* obj, const Vector4f& v, int offset);
    glm::quat hud_quat_from_euler_deg(float dxg, float dyg, float dzg);
    void apply_hand_hud(::REGameObject* game_object);
    void on_pre_request_fire(std::vector<uintptr_t>& args);
    void on_pre_rocket_generate(std::vector<uintptr_t>& args);
    void laser_post(::REManagedObject* self);

    static HookManager::PreHookResult pre_concentrate(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static HookManager::PreHookResult pre_apply_concentrate(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static void post_nop(uintptr_t& ret_val, sdk::RETypeDefinition* ret_ty, uintptr_t ret_addr);
    static HookManager::PreHookResult pre_request_fire(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static void post_request_fire(uintptr_t& ret_val, sdk::RETypeDefinition* ret_ty, uintptr_t ret_addr);
    static HookManager::PreHookResult pre_rocket(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static HookManager::PreHookResult pre_laser(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static void post_laser(uintptr_t& ret_val, sdk::RETypeDefinition* ret_ty, uintptr_t ret_addr);

    struct Cfg {
        bool bullet_hook{true};
        bool crosshair_off{false};
        std::unordered_map<std::string, float> reticle_scale{};
        bool reticle_color{false};
        float reticle_r{1.0f}, reticle_g{0.0f}, reticle_b{0.0f};
        bool force_reticle_concentrate{false};
        float concentrate_ratio{1.0f};
    };
    Cfg m_cfg{};

    struct HudTarget {
        std::string name;
        bool enabled{true};
    };
    struct HudCfg {
        bool enabled{true};
        bool hide_hud{false};
        float dx{-0.143f}, dy{-0.094f}, dz{0.10f}, scale{0.289f};
        float rx{-180.0f}, ry{55.0f}, rz{102.0f};
        bool ada_rot{false};
        float ada_rx{-180.0f}, ada_ry{55.0f}, ada_rz{102.0f};
        float ada_dx{-0.143f}, ada_dy{-0.094f}, ada_dz{0.10f};
        std::unordered_map<std::string, bool> guis{};
    };
    HudCfg m_hud{};

    struct LaserCfg {
        bool enabled{true};
        float width{1.5f};
        float length{2.4f};
        bool force_color{false};
        float r{0.0f}, g{1.0f}, b{0.0f};
        bool tune_glow{true};
        float glow{8.0f};
        float alpha{0.03f};
        bool smoke{true};
        float smoke_amt{0.28f};
        float smoke_speed{30.0f};
        bool dot_raycast{true};
        float dot_dist{5.0f};
        float dot_size{1.0f};
    };
    LaserCfg m_laser{};

    Vector3f m_crosshair_pos{0, 0, 0};
    Vector3f m_crosshair_dir{0, 0, 1};
    Vector3f m_crosshair_normal{0, 0, 0};
    std::optional<float> m_crosshair_distance{};
    Vector3f m_last_muzzle_pos{0, 0, 0};
    Vector3f m_last_muzzle_forward{0, 0, 1};
    Vector3f m_last_shoot_dir{0, 0, 1};
    Vector3f m_last_shoot_pos{0, 0, 0};
    bool m_has_muzzle{false};

    ::REManagedObject* m_attack_ray{nullptr};
    ::REManagedObject* m_bullet_ray{nullptr};
    ::REManagedObject* m_scene{nullptr};
    ::REGameObject* m_cached_pl_head{nullptr};
    ::REGameObject* m_cached_gun_obj{nullptr};
    std::optional<int32_t> m_cached_weapon_id{};
    std::optional<int32_t> m_current_weapon_id{};
    ::REJoint* m_current_muzzle_joint{nullptr};
    bool m_current_laser_active{false};
    double m_cache_refresh_time{0.0};
    bool m_reticle_params_applied{false};
    double m_finisher_prompt_seen{-999.0};
    double m_dodge_prompt_seen{-999.0};
    ::REManagedObject* m_laser_this{nullptr};
    sdk::REMethodDefinition* m_cast_ray_async{nullptr};
    int32_t m_filter_damage_other{-1};
    bool m_ui_registered{false};
    std::chrono::steady_clock::time_point m_clock_origin{std::chrono::steady_clock::now()};
};
#endif
