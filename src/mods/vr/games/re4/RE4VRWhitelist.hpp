#pragma once

#if defined(RE4)
#include <string>
#include <unordered_set>
#include <vector>

#include "../../../../Mod.hpp"

// Builtin port of scripts/re4/re4_vr_whitelist.lua
class RE4VRWhitelist : public Mod {
public:
    static std::shared_ptr<RE4VRWhitelist>& get();
    std::string_view get_name() const override { return "RE4VRWhitelist"; }

    std::optional<std::string> on_initialize() override;
    void on_lua_state_created(sol::state& lua) override;

    bool is_real_breakable_prop(::REManagedObject* go);
    float breakable_yoff(::REManagedObject* go);
    float enemy_off_y(::REManagedObject* ctx);
    void animal_center(::REManagedObject* anim, float fx, float fy, float fz, float& ox, float& oy, float& oz);

private:
    void load_stems();
    void export_globals(sol::state& lua);
    void refresh_types();

    std::vector<std::string> m_types{"chainsaw.GmWoodBoxBase", "chainsaw.GmWindow"};
    std::vector<::REManagedObject*> m_tds{};
    std::vector<std::string> m_prefixes{};
    std::vector<std::string> m_name_only{"gm84_508_00_"};
    std::vector<std::string> m_contains{};
    std::vector<std::string> m_contains_only{};
    bool m_require_type{true};
    float m_coin_off_y{-1.2f};
    float m_vase_off_y{-0.4f};
    float m_snake_off_y{-0.8f};
    float m_animal_off_y{-0.3f};
    float m_mouse_off_y{-0.9f};
    float m_animal_center_max_d{3.0f};
};
#endif
