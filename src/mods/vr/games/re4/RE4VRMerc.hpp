#pragma once

#if defined(RE4)
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <sdk/REMath.hpp>
#include "../../../../Mod.hpp"
#include "HookManager.hpp"

// Builtin port of scripts/re4/re4_vr_merc.lua
class RE4VRMerc : public Mod {
public:
    static std::shared_ptr<RE4VRMerc>& get();
    std::string_view get_name() const override { return "RE4VRMerc"; }

    std::optional<std::string> on_initialize() override;
    void on_lua_state_created(sol::state& lua) override;
    void on_lua_state_destroyed(sol::state& lua) override;
    void on_frame() override;
    void on_application_entry(void* entry, const char* name, size_t hash) override;
    bool on_pre_gui_draw_element(REComponent* gui_element, void* primitive_context) override;

private:
    struct HhMesh {
        ::REManagedObject* mesh{nullptr};
        std::optional<int> idx{};
        std::string name{};
    };
    struct ExtraMat {
        ::REManagedObject* mesh{nullptr};
        int idx{0};
        std::string name{};
    };
    struct WepOff {
        float px{0}, py{0}, pz{0}, rx{0}, ry{0}, rz{0};
    };
    struct HudPart {
        bool on{true};
        float scale{1.0f};
        float x{0}, y{0};
        std::optional<float> bx{};
        std::optional<float> by{};
        std::string type{};
        std::string field{"_Main"};
        std::string go{};
        bool to_parent{false};
    };
    struct BowPose {
        std::unordered_map<std::string, glm::quat> bones{};
    };

    void load_json();
    void save_json();
    void export_globals();
    std::pair<bool, std::optional<int32_t>> detect();
    bool get_player_body(std::optional<int32_t>& kind, std::string& name, ::RETransform*& tf);
    void collect_hh(::RETransform* tf, const std::unordered_map<std::string, bool>* hide);
    void collect_all_meshes(::RETransform* tf);
    void apply_hide();
    void apply_full_hide();
    bool show_head_now();
    bool full_hide_now();
    void scan_extra_mats();
    bool extra_cache_alive();
    void apply_extra_mats(bool off);
    void update_bow_pin();
    void bow_unpin();
    void update_bulletrush();
    void hud_apply();
    void apply_bow_pose();
    bool wep_apply(const Vector3f& wpos, const glm::quat& wrot, int32_t wid, const glm::quat* hand_rot, Vector3f& np, glm::quat& nr);
    void dot_tick();
    ::REManagedObject* hud_root_ctrl(::REManagedObject* go);
    ::REManagedObject* child_by_name(::REManagedObject* ctrl, const std::string& want);

    static HookManager::PreHookResult pre_bare_hand(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static void post_bare_hand(uintptr_t& ret_val, sdk::RETypeDefinition* ret_ty, uintptr_t ret_addr);

    int m_frames{0};
    std::optional<bool> m_last_state{};
    std::optional<int32_t> m_last_kind{};
    bool m_merc_body_ok{false};
    bool m_in_mercs{false};
    bool m_hide_enabled{true};
    bool m_round_gap{false};
    std::vector<HhMesh> m_hh_meshes{};
    std::string m_hh_body{};
    std::vector<::REManagedObject*> m_all_meshes{};
    bool m_full_hidden{false};
    std::vector<ExtraMat> m_extra_mats{};
    std::vector<::REManagedObject*> m_extra_furs{};
    bool m_extra_mats_off{false};
    double m_extra_scan_t{0.0};
    bool m_wep_off_on{true};
    std::unordered_map<std::string, WepOff> m_wep_off{};
    bool m_bow_pose_on{true};
    int m_bow_mirror_mode{1};
    float m_bow_pose_blend{1.0f};
    bool m_hide_2770{true};
    bool m_hide_timer_bg{true};
    bool m_bow_pin_on{true};
    std::unordered_map<std::string, BowPose> m_bow_poses{};
    std::unordered_map<std::string, std::unordered_map<std::string, glm::quat>> m_bow_mirror_cache{};
    ::REGameObject* m_bowp_go{nullptr};
    ::RETransform* m_bowp_tf{nullptr};
    bool m_bowp_pinned{false};
    std::unordered_map<std::string, HudPart> m_hud{};
    std::unordered_map<std::string, ::REManagedObject*> m_hud_cache{};
    std::unordered_set<std::string> m_hud_names{};
    double m_hud_scan_t{0.0};
    ::REManagedObject* m_merc_mgr{nullptr};
    ::REManagedObject* m_campaign_mgr{nullptr};
    ::REManagedObject* m_char_mgr{nullptr};
    ::REManagedObject* m_br_hu{nullptr};
    double m_br_since{0.0};
    ::REManagedObject* m_dot_lsc{nullptr};
    std::optional<uintptr_t> m_dot_key{};
    int m_dot_tries{0};
    double m_dot_next_scan{0.0};
    bool m_dot_body_weg{false};
    bool m_dot_aimed{false};
    bool m_bk_skipped{false};
    bool m_bk_void{true};
    int m_bk_blocked{0};
    ::REManagedObject* m_t_mesh{nullptr};
    ::REManagedObject* m_t_fur{nullptr};
    ::REManagedObject* m_t_shellfur{nullptr};
};
#endif
