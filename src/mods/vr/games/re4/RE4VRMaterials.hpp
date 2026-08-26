#pragma once

#if defined(RE4)
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "../../../../Mod.hpp"

// Builtin port of scripts/re4/re4_vr_materials.lua
class RE4VRMaterials : public Mod {
public:
    static std::shared_ptr<RE4VRMaterials>& get();
    std::string_view get_name() const override { return "RE4VRMaterials"; }

    std::optional<std::string> on_initialize() override;
    void on_lua_state_destroyed(sol::state& lua) override;
    void on_frame() override;

private:
    struct ExtraMat {
        ::REManagedObject* mesh{nullptr};
        int idx{0};
        std::string name{};
    };
    struct WalkItem {
        ::RETransform* tf{nullptr};
        bool weapon{false};
    };

    void load_json();
    ::REGameObject* get_body_go();
    void set_mat(::REManagedObject* renderer, int mi, bool enable);
    void set_mesh_draw(::REManagedObject* renderer, bool draw_color, std::optional<bool> shadow);
    bool renderer_is_hh_only(::REManagedObject* renderer, int mcount);
    void hide_mats_on(::REManagedObject* renderer, bool fullhide_go);
    void process_go(::REGameObject* go, bool in_weapon);
    void start_walk(::RETransform* root);
    void walk_chunk();
    void scan_extra_mats();
    bool extra_mats_alive();
    void apply_extra_mats(bool off);
    void gondola_tick();
    void gondola_unhide();
    void gondola_set_tree(::RETransform* tf, bool enable);

    std::unordered_map<std::string, bool> m_hide_leon{};
    std::unordered_map<std::string, bool> m_hide_ashley{};
    std::unordered_map<std::string, bool> m_hide_ada{};
    const std::unordered_map<std::string, bool>* m_hide_materials{nullptr};
    std::unordered_set<std::string> m_fullhide_go{};
    std::unordered_set<std::string> m_fullhide_extra{};
    std::vector<ExtraMat> m_extra_mats{};
    std::vector<::REManagedObject*> m_extra_furs{};
    bool m_extra_mats_off{false};
    double m_extra_scan_t{0.0};
    bool m_mat_set_enable{false};
    bool m_fp_only{false};
    bool m_scope_body_hide{false};
    bool m_holster_hide{false};
    std::vector<WalkItem> m_walk_stack{};
    bool m_walk_active{false};
    ::REGameObject* m_cached_body{nullptr};
    ::REGameObject* m_lamp_go{nullptr};
    bool m_lamp_hidden{false};
    ::REGameObject* m_fl_go{nullptr};
    bool m_fl_hidden{false};
    bool m_gondola_hide{true};
    std::unordered_set<::REManagedObject*> m_gondola_hidden{};
    double m_gondola_next_t{0.0};
    double m_refresh_timer{0.0};
    double m_last_time{0.0};
    ::REManagedObject* m_t_mesh{nullptr};
    ::REManagedObject* m_t_fur{nullptr};
    ::REManagedObject* m_t_shellfur{nullptr};
    ::REManagedObject* m_t_oillamp{nullptr};
};
#endif
