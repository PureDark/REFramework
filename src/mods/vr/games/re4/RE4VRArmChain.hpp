#pragma once

#if defined(RE4)
#include <optional>
#include <string>
#include <unordered_map>

#include <sdk/REMath.hpp>
#include <sdk/RETransform.hpp>
#include <json.hpp>

#include "../../../../Mod.hpp"

// Builtin port of scripts/re4/re4_vr_arm_chain.lua
class RE4VRArmChain : public Mod {
public:
    static std::shared_ptr<RE4VRArmChain>& get();
    std::string_view get_name() const override { return "RE4VRArmChain"; }

    std::optional<std::string> on_initialize() override;
    void on_lua_state_created(sol::state& lua) override;
    void on_lua_state_destroyed(sol::state& lua) override;
    void on_frame() override;
    void on_pre_application_entry(void* entry, const char* name, size_t hash) override;
    void on_application_entry(void* entry, const char* name, size_t hash) override;

private:
    struct JointOff {
        float pos_x{0}, pos_y{0}, pos_z{0};
        float rot_x{0}, rot_y{0}, rot_z{0};
        float scale_x{1}, scale_y{1}, scale_z{1};
    };
    struct PinRel {
        Vector3f p{0, 0, 0};
        glm::quat r{1, 0, 0, 0};
    };
    struct RootPose {
        Vector3f pos{0, 0, 0};
        glm::quat rot{1, 0, 0, 0};
        glm::quat inv_rot{1, 0, 0, 0};
        bool parented{false};
    };

    void load_json();
    void save_json();
    void apply_key_config(const std::string& key);
    void load_from_config_bodychain(sol::table bc);
    sol::table get_save_bodychain(sol::state_view lua);
    void export_module(sol::state& lua);
    void flush_joint_cache();
    bool should_pause();
    bool should_apply_now();
    void check_player_changed();
    void check_autoreset(const char* prefix, const Vector3f& hand_target);
    ::REJoint* get_chain_joint(const std::string& name);
    bool is_joint_valid(::REJoint* j);
    void apply_ik_rotation(::REJoint* joint, const std::string& name, const glm::quat& world_rot);
    void apply_shoulder_pin(const char* prefix);
    void apply_arm_ik_side(const char* prefix, Vector3f hand_pos, const std::optional<glm::quat>& char_rot, const std::optional<RootPose>& root);
    void apply_body_chain();
    void publish_clamp_anchors();
    void railcar_pin_spine();
    void phase_pre(const char* lua_call, bool enabled);
    void phase_post(const char* lua_call, bool enabled);
    std::string resolve_config_key();
    std::pair<float, float> arm_ik_segment_lengths(const std::string& upper, const std::string& lower);

    bool m_enabled{true};
    std::unordered_map<std::string, JointOff> m_chain_offset{};
    std::unordered_map<std::string, bool> m_seg_enabled{};
    nlohmann::json m_all_configs{nlohmann::json::object()};
    std::string m_current_key{"default"};
    float m_wrist_y_l{0}, m_wrist_y_r{0};
    float m_wrist_x_l{0}, m_wrist_x_r{0};
    bool m_shoulder_reach_follow{true};
    float m_shoulder_reach_follow_max{0.45f};
    float m_shoulder_reach_follow_slack{0.018f};
    bool m_hand_clamp{true};
    bool m_shoulder_pin{true};
    std::optional<PinRel> m_pin_l{};
    std::optional<PinRel> m_pin_r{};
    std::unordered_map<std::string, ::REJoint*> m_joints{};
    std::unordered_map<uintptr_t, double> m_jv_bad{};
    ::RETransform* m_cached_tf{nullptr};
    bool m_first_load{true};
    bool m_hooks_ready{false};
    bool m_require_motion_tick{false};
    bool m_apply_once{false};
    bool m_hook_lock{true};
    bool m_hook_late{true};
    bool m_hook_expr{true};
    bool m_hook_begin{true};
    int32_t m_last_frame_applied{-1};
    int32_t m_last_motion_tick{-1};
    double m_autoreset_last{0.0};
};
#endif
