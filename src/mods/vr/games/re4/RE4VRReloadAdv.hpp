#pragma once

#if defined(RE4)
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <sdk/REMath.hpp>
#include "../../../../Mod.hpp"

// Builtin port of scripts/re4/re4_vr_reload_adv.lua
class RE4VRReloadAdv : public Mod {
public:
    static std::shared_ptr<RE4VRReloadAdv>& get();
    std::string_view get_name() const override { return "RE4VRReloadAdv"; }

    std::optional<std::string> on_initialize() override;
    void on_lua_state_created(sol::state& lua) override;
    void on_lua_state_destroyed(sol::state& lua) override;
    void on_pre_application_entry(void* entry, const char* name, size_t hash) override;
    void on_application_entry(void* entry, const char* name, size_t hash) override;

    struct Vec3 {
        float x{0}, y{0}, z{0};
    };
    struct Keyframe {
        float x{0}, y{0}, z{0}, rx{0}, ry{0}, rz{0};
    };
    struct Land {
        bool on{true};
        float rx{89.5f}, ry{-157.5f}, rz{125.0f};
    };
    struct Wcfg {
        Vec3 exit{0.0f, -0.10f, 0.0f};
        float slide_dur{0.18f};
        float gravity{9.8f};
        float fall_dist{0.85f};
        float fall_dur{0.55f};
        Land land{};
    };
    struct Dock {
        std::string joint{"_03"};
        float x{0}, y{-0.092f}, z{-0.061f};
    };
    struct Push {
        bool on{true};
        float in_dur{0.07f}, hold{0.10f}, out_dur{0.14f};
        float curl{85.0f}, thumb{15.0f};
        float release_dur{0.20f};
        float reload_speed{1.0f};
        float fall_grav_mult{2.5f};
        float rx{0}, ry{0}, rz{0};
        float px{0}, py{0}, pz{0};
        float ada_px{0}, ada_py{0}, ada_pz{0};
        std::unordered_map<std::string, glm::quat> bones{};
    };

    bool begin_drop(::REJoint* joint, int32_t wid, std::optional<float> dur, std::optional<Vec3> exit_local);
    void cancel();
    bool is_active() const { return m_drop.active; }
    void tick();
    void start_push(int32_t wid);
    void stop_push();
    void begin_push_hold(int32_t wid);
    void end_push_hold();
    float push_blend();
    void push_pos(std::optional<int32_t> wid, float& x, float& y, float& z);
    float time_mult() const;
    bool has_shell_keys(int32_t wid);
    bool uses_rev_insert(int32_t wid);
    bool has_eject_keys(int32_t wid);
    bool apply_shell_keys(::RETransform* weapon_tf, ::REJoint* joint, int32_t wid, float tt);
    bool apply_eject_keys(::RETransform* weapon_tf, ::REJoint* joint, int32_t wid, float tt);
    std::optional<Keyframe> shell_pose_at(int32_t wid, float tt);
    std::optional<Keyframe> eject_pose_at(int32_t wid, float tt);
    std::optional<float> kf_insert_dur(int32_t wid);
    std::optional<Vector3f> dock_world(::RETransform* weapon_tf, int32_t wid);
    std::optional<Vec3> dock_local(::RETransform* weapon_tf, int32_t wid);

private:
    void load_json();
    void save_json();
    void seed_eject_keys();
    void export_module(sol::state& lua);
    void push_apply();
    void shell_preview_apply();
    void eject_preview_apply();
    void tick_preview();
    void sync_lua_fields();
    bool apply_kf_world(::RETransform* weapon_tf, ::REJoint* joint, const Keyframe& p);
    Wcfg& wcfg(int32_t wid);
    Dock* dock(int32_t wid);
    glm::quat quat_from_euler(float rx, float ry, float rz);
    static glm::quat qnlerp(const glm::quat& a, const glm::quat& b, float t);
    std::optional<float> get_floor_y();

    struct Drop {
        bool active{false};
        std::string phase{};
        ::REJoint* joint{nullptr};
        int32_t wid{0};
        double t0{0};
        float lx0{0}, ly0{0}, lz0{0}, ex{0}, ey{0}, ez{0};
        float sx{0}, sy{0}, sz{0};
        float slide_dur{0.18f}, gravity{9.8f};
        float fall_dist{0.85f}, fall_dur{0.55f};
        bool use_keys{false};
        float srw{1}, srx{0}, sry{0}, srz{0};
        bool has_sr{false};
        std::optional<float> floor_y{};
    };

    std::unordered_map<int32_t, Wcfg> m_weapons{};
    std::unordered_map<int32_t, Dock> m_docks{};
    std::unordered_map<int32_t, std::vector<Keyframe>> m_shell_keys{};
    std::unordered_map<int32_t, std::vector<Keyframe>> m_eject_keys{};
    std::unordered_set<int32_t> m_keyframe_insert{};
    std::unordered_set<int32_t> m_keyframe_eject{};
    std::unordered_set<int32_t> m_dock_allowed{};
    std::unordered_set<int32_t> m_push_wids{};
    std::unordered_map<int32_t, bool> m_rev_insert{};
    std::unordered_map<int32_t, float> m_push_y_by_wid{};
    Push m_push{};
    Drop m_drop{};
    float m_shell_dur{0.40f};
    float m_r9_anlauf{0.30f};
    int m_shell_clone_part{1};
    float m_shell_clone_scale{1.0f};
    float m_eject_dur{0.35f};
    float m_rev_insert_dur{0.35f};
    Keyframe m_shell_live{};
    Keyframe m_eject_live{};
    bool m_shell_preview{false};
    bool m_eject_preview{false};
    bool m_push_tune{false};
    bool m_push_hold{false};
    std::optional<double> m_push_t0{};
    std::optional<int32_t> m_push_wid{};
    ::REJoint* m_current_mag_joint{nullptr};
    struct Preview {
        bool active{false};
        double until_t{0};
        ::REJoint* joint{nullptr};
        float lx0{0}, ly0{0}, lz0{0};
        int32_t wid{0};
    } m_preview{};
};
#endif
