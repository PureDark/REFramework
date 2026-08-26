#pragma once

#if defined(RE4)
#include <cstdint>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <sdk/REMath.hpp>
#include "../../../../Mod.hpp"
#include "HookManager.hpp"

// Builtin port of scripts/re4/re4_vr_weapons2.lua
class RE4VRWeapons2 : public Mod {
public:
    static std::shared_ptr<RE4VRWeapons2>& get();
    std::string_view get_name() const override { return "RE4VRWeapons2"; }

    std::optional<std::string> on_initialize() override;
    void on_lua_state_created(sol::state& lua) override;
    void on_lua_state_destroyed(sol::state& lua) override;
    void on_frame() override;
    void on_pre_application_entry(void* entry, const char* name, size_t hash) override;
    void on_application_entry(void* entry, const char* name, size_t hash) override;

    void apply_left_knife_pose(::REManagedObject* go);
    void apply_wildwest_fingers();
    void apply_wildwest(Vector3f& wpos, glm::quat& wrot);
    bool knife_lh_off(int32_t wid, Vector3f& pos, Vector3f& euler) const;
    bool knife_lh_flip_pos(int32_t wid, Vector3f& pos) const;
    void native_hit(::REManagedObject* victim_hc, const Vector3f& pos);

private:
    struct Off3 {
        float x{0}, y{0}, z{0};
        float rx{0}, ry{0}, rz{0};
    };

    void export_globals(sol::state& lua);
    void load_json();
    void load_wildwest();
    void save_parry();
    void save_lefthand();
    void save_lh_off();
    void save_lh_flip();
    void parry_tick();
    void lh_char_tick();
    void left_knife_tick();
    void clone_manage();
    void clone_spawn();
    void clone_destroy();
    void clone_apply_pose();
    void clone_isolate_part0();
    void clone_reparent();
    void lh_play_sound(uint32_t id);
    bool direct_damage(const Vector3f& pos, float reach);
    void parry_keep_gun_tick();
    void drop_di_caches();
    void wildwest_tick();
    void blood_tick();
    void knife_di_guard();
    bool prompt_visible();
    bool reverse_grip();
    bool knife_out();
    ::REManagedObject* find_knife_mesh();
    std::optional<int32_t> get_selected_knife_wid();
    void exec_native_melee();

    static HookManager::PreHookResult pre_request_action(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static HookManager::PreHookResult pre_equip_weapon(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static void post_nop(uintptr_t& ret_val, sdk::RETypeDefinition* ret_ty, uintptr_t ret_addr);

    float m_parry_tol{0.18f};
    bool m_blood_on{true};
    bool m_lt_flip_tap{false};
    float m_lh_flip_speed{1.0f};
    float m_lh_swing_speed{1.0f};
    bool m_lh_enabled{true};
    std::string m_char{"leon"};
    std::unordered_map<std::string, Off3> m_lh_off{};
    std::unordered_map<std::string, Off3> m_lh_flip{};
    ::REGameObject* m_lh_clone{nullptr};
    ::REManagedObject* m_lh_clone_mesh{nullptr};
    std::optional<int32_t> m_lh_clone_wid{};
    bool m_lh_intent{false};
    bool m_lh_clone_on{false};
    bool m_lh_part0{false};
    bool m_lh_was_flying{false};
    std::optional<bool> m_lh_vis{};
    float m_lh_flip_lerp{0};
    float m_lh_flip_prev{-1};
    double m_orphan_t{0};
    uintptr_t m_di_body{0};
    double m_di_next{0};
    ::REManagedObject* m_native_di{nullptr};
    ::REManagedObject* m_dmginfo_cap{nullptr};
    bool m_armed{false};
    bool m_prev_lgrip{false};
    std::optional<Vector3f> m_prev_lh{};
    double m_lh_swing_t{0};
    double m_last_lh_hit{0};
    std::optional<int32_t> m_current_knife_wid{};
    bool m_parry_was{false};
    double m_parry_until{0};
    struct WwEuler {
        float x{0}, y{0}, z{0};
    };
    struct WwKf {
        float a{0}, x{0}, y{0}, z{0};
    };
    struct WwCfg {
        bool enabled{true};
        bool sound{true};
        bool rt_gate{true};
        bool pose_preview{false};
        bool prev_interp{false};
        bool block_with_stock{true};
        float sustain{0.60f};
        float sens{1.20f};
        float rt_sens{0.10f};
        float rt_lockout{1.0f};
        float speed{720.0f};
        float dir{1.0f};
        float pivot_x{0}, pivot_y{0}, pivot_z{0};
        float off_x{0}, off_y{0}, off_z{0};
        float prev_angle{90.0f};
        float snd_interval{0.12f};
    };
    struct WwSpin {
        bool active{false};
        bool finishing{false};
        bool by_rt{false};
        float deg{0};
        float finish_target{0};
    };
    struct WwVoice {
        std::optional<double> t0{};
        double dur{0};
        int count{0};
        int end_count{0};
        uint32_t last_id{0};
        bool fired{false};
    };

    std::unordered_map<std::string, WwEuler> m_ww_fing{};
    float m_ww_finger_blend{0};
    WwCfg m_ww{};
    WwSpin m_ww_spin{};
    WwVoice m_ww_voice{};
    std::unordered_map<int32_t, std::vector<WwKf>> m_ww_okeys{};
    std::unordered_map<int32_t, Vector3f> m_ww_pivot{};
    std::optional<Vector3f> m_ww_active_lp{};
    float m_ww_angle{0};
    float m_ww_progress{0};
    std::optional<int32_t> m_ww_cur_wid{};
    std::optional<float> m_ww_prev_y{};
    std::optional<double> m_ww_prev_t{};
    int m_ww_prev_vsign{0};
    double m_ww_prev_vsign_t{0};
    std::optional<double> m_ww_bob_started{};
    double m_ww_last_flip_t{0};
    bool m_ww_rt_gate_prev{false};
    bool m_ww_rt_press_armed{false};
    bool m_ww_rt_prev_raw{false};
    double m_ww_last_shot_t{-999};
    std::optional<double> m_ww_last_shot_seq{};
    double m_ww_snd_next{0};
    std::optional<int32_t> m_ww_stock_wid{};
    double m_ww_stock_t{0};
    bool m_ww_stock_on{false};
    ::REManagedObject* m_ww_pe{nullptr};

    void ww_reset_all();
    void ww_reset_bob();
    bool ww_is_pistol(int32_t wid) const;
    bool ww_stock_mounted(int32_t wid);
    ::REManagedObject* ww_head_updater();
    std::optional<int32_t> ww_wid(::REManagedObject* hu);
    ::RETransform* ww_weap_tf(::REManagedObject* hu);
    std::optional<Vector3f> ww_local_pivot(::RETransform* tf);
    std::optional<Vector3f> ww_offset_at(float phase);
    bool ww_rt_gate();
    std::optional<float> ww_right_ctrl_y();
    void ww_sound_tick(::REManagedObject* hu, double now);
    void ww_sound_reset();
    ::REManagedObject* ww_sound_container(::REManagedObject* hu);
    void ww_voice_tick();
    void ww_voice_end();
    ::REManagedObject* ww_voice_container();
};
#endif
