#pragma once

#if defined(RE4)
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "../../../../Mod.hpp"

// Builtin port of scripts/re4/re4_vr_ui.lua
class RE4VRUI : public Mod {
public:
    static std::shared_ptr<RE4VRUI>& get();
    std::string_view get_name() const override { return "RE4VRUI"; }

    std::optional<std::string> on_initialize() override;
    void on_lua_state_destroyed(sol::state& lua) override;
    void on_frame() override;
    bool on_pre_gui_draw_element(REComponent* gui_element, void* primitive_context) override;

private:
    struct GlueLayer {
        const char* name{};
        int order{0};
    };

    void load_json();
    void save_json();
    bool is_supported();
    void apply_override(bool want);
    void apply_elem(bool want);
    void apply_mono(bool want);
    void apply_canvas(bool want);
    void apply_suspend(bool want);
    void apply_mapglue(bool want);
    void push_glue_layers();
    void apply_ptr_pitch();
    bool is_map_gui_open();
    bool is_inventory_open();
    bool is_main_menu_open();
    ::REManagedObject* gui_view(::REManagedObject* go);
    ::REManagedObject* gui_root_control(::REManagedObject* go);
    bool force_viewtype(::REManagedObject* go, const std::string& name);
    void apply_viewtype(::REManagedObject* go, const std::string& name, bool want);

    struct Opt {
        bool gui_matrix{true};
        bool gui_elem{false};
        bool mono{false};
        bool canvas{false};
        bool suspend{false};
        bool binoglue{false};
        bool mapglue{false};
    } m_opt{};

    float m_glue_distance{1.5f};
    float m_glue_gap{0.002f};
    float m_bino_distance{1.0f};
    float m_canvas_width{2.5f};
    float m_canvas_distance{2.0f};
    float m_ptr_pitch{-45.0f};
    float m_ui3101_scale{1.0f};
    bool m_hide_3121{true};
    bool m_hide_bg{true};
    std::unordered_map<std::string, bool> m_global_hide{
        {"hide_dot", true}, {"hide_vignette", true}, {"hide_vignette2", true}};
    std::unordered_map<std::string, bool> m_map_hide{
        {"Gui_ui3140", false}, {"Gui_ui3141", false}, {"Gui_ui3131_AO", true}};
    std::unordered_map<std::string, bool> m_glue_on{};
    std::unordered_map<std::string, bool> m_vt_on{{"vt_3120", false}};
    std::unordered_map<std::string, int32_t> m_vt_orig{};
    std::unordered_map<std::string, int32_t> m_vt_force{};
    std::unordered_map<std::string, std::string> m_vt_seen{};
    std::unordered_set<std::string> m_glue_auto{};

    std::optional<bool> m_supported{};
    std::optional<bool> m_elem_supported{};
    std::optional<bool> m_suspend_supported{};
    std::optional<bool> m_glue_supported{};
    std::optional<bool> m_ptr_pitch_ok{};
    std::optional<float> m_ptr_pitch_sent{};
    bool m_applied{false};
    bool m_elem{false};
    bool m_mono{false};
    bool m_canvas{false};
    bool m_suspend{false};
    bool m_mapglue{false};
    bool m_map_open{false};
    bool m_inv_open{false};
    bool m_menu_open{false};
    std::optional<double> m_bino_seen_t{};
    std::optional<double> m_cfg_dirty_t{};
    ::REManagedObject* m_map_manager{nullptr};
    ::REManagedObject* m_case_manager{nullptr};
    ::REManagedObject* m_gui_manager{nullptr};
};
#endif
