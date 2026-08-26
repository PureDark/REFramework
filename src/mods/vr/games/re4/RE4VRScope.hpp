#pragma once

#if defined(RE4)
#include <chrono>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include <json.hpp>
#include "../../../../Mod.hpp"
#include "HookManager.hpp"

// Builtin port of scripts/re4/re4_vr_scope.lua
class RE4VRScope : public Mod {
public:
    static std::shared_ptr<RE4VRScope>& get();
    std::string_view get_name() const override { return "RE4VRScope"; }

    std::optional<std::string> on_initialize() override;
    void on_lua_state_created(sol::state& lua) override;
    void on_lua_state_destroyed(sol::state& lua) override;
    void on_frame() override;
    void on_pre_application_entry(void* entry, const char* name, size_t hash) override;
    void on_application_entry(void* entry, const char* name, size_t hash) override;

    // Only this class may call VR::set_mono_rendering.
    void mono_request(std::string id, bool on);

    struct Keyframe {
        float deg{0.0f};
        float x{0.0f};
        float y{0.0f};
        float z{0.0f};
        float zoom{1.0f};
    };

private:
    struct AdaY {
        float y{0.0f};
        float deg{75.0f};
        float pow{1.0f};
    };
    struct Cfg {
        bool mono{true};
        bool mono_manual{false};
        bool proj_off{true};
        bool view_off{true};
        float zoom{1.0f};
        float fov{0.0f};
        int blank_eye{-1};
        int blank_eye_xr{-1};
        float xr_dx{0.0f};
        float xr_dy{0.0f};
        float zoom_x{0.0f};
        float zoom_x_bow{0.0f};
        float pitch_y{0.0f};
        float pitch_y_deg{75.0f};
        float pitch_y_pow{1.0f};
        float pitch_y_ada{0.0f};
        float pitch_y_deg_ada{75.0f};
        float pitch_y_pow_ada{1.0f};
        std::unordered_map<std::string, AdaY> pitch_y_ada_sets{};
        bool pitch_y_ada_migrated{false};
        float zoom_y{0.0f};
        bool mono_proj{false};
        float img_x{0.0f};
        float img_y{0.0f};
        float cam_x{0.0f};
        float cam_y{0.0f};
        float cam_z{0.0f};
        std::unordered_map<std::string, std::vector<Keyframe>> kfs_sets{};
        std::vector<Keyframe> kfs{};
        bool kfs_migrated{false};
        bool live{false};
        float mid_y{0.0f}, mid_z{0.0f}, up_y{0.0f}, up_z{0.0f}, dn_y{0.0f}, dn_z{0.0f};
        float um_y{0.0f}, um_z{0.0f}, dm_y{0.0f}, dm_z{0.0f};
        bool um_on{false}, dm_on{false};
        float mid_t{0.5f};
        float pitch_ref{45.0f};
        float hold{0.35f};
        float bolt_eye_hold{1.50f};
        float bolt_pitch_hold{0.0f};
        bool bolt_reaim{true};
        bool bolt_mute{true};
        float sens_out{0.85f};
        float sens_in{0.35f};
        bool stick_zoom{true};
        float zoom_speed{0.04f};
        float zoom_min{1.0f};
        float zoom_max{3.0f};
        float bino_bg_scale{1.0f};
    };

    void load_json();
    void save_json();
    void export_globals(sol::state& lua);
    void probe();
    void mono_apply();
    void proj_apply(bool on);
    void apply_cam_offset();
    float zoom_ramp() const;
    float zoom_x_now() const;
    float zoom_y_now() const;
    float pitch_y_at(float deg);
    int32_t scope_raw_wid();
    std::string scope_raw_id();
    int32_t scope_wid_now();
    std::string scope_id_now();
    std::string scope_key_now();
    std::vector<Keyframe>& cur_kfs();
    void scope_curve(const std::vector<Keyframe>& pts, float deg, float& x, float& y, float& z) const;
    float scope_pitch_deg();
    bool detect_runtime_xr();
    AdaY& ada_y_set();

    static HookManager::PreHookResult pre_post_event(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static void post_post_event(uintptr_t& ret_val, sdk::RETypeDefinition* ret_ty, uintptr_t ret_addr);

    Cfg m_cfg{};
    std::unordered_map<std::string, bool> m_mono_reqs{};
    bool m_mono_state{false};
    bool m_mono_fail{false};
    bool m_probe_done{false};
    int m_probe_tries{0};
    bool m_fork_ok{true};
    bool m_fork_mono{true};
    bool m_fork_gui{true};
    bool m_fork_canvas{true};
    bool m_scope_native{false};
    std::optional<double> m_native_off_t{};
    bool m_proj_on{false};
    std::optional<bool> m_proj_supported{};
    std::optional<bool> m_is_xr{};
    bool m_save_dirty{false};
    double m_save_t{0.0};
    int32_t m_last_raw_wid{4401};
    std::string m_last_raw_id{"normal"};
    std::string m_last_scope_id{"normal"};
    float m_last_scope_deg{0.0f};
    struct DegSample { double t{0.0}; float p{0.0f}; };
    std::vector<DegSample> m_deg_hist{};
    bool m_bolt_skipped{false};
};
#endif
