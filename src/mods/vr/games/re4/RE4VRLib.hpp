#pragma once

#if defined(RE4)
#include "../../../../Mod.hpp"
#include <sdk/REMath.hpp>

// Builtin port of scripts/re4/utility/RE4.lua
class RE4VRLib : public Mod {
public:
    static std::shared_ptr<RE4VRLib>& get();
    std::string_view get_name() const override { return "RE4VRLib"; }

    void on_lua_state_created(sol::state& lua) override;
    void on_pre_application_entry(void* entry, const char* name, size_t hash) override;
    bool on_pre_gui_draw_element(REComponent* gui_element, void* primitive_context) override;

    ::REManagedObject* player() const { return m_player; }
    ::REGameObject* body() const { return m_body; }
    ::REGameObject* head() const { return m_head; }
    ::REManagedObject* equipment() const { return m_equipment; }
    ::REManagedObject* weapon() const { return m_weapon; }
    bool is_player_controlled() const { return m_is_player_controlled; }
    bool is_in_inventory_menu() const;

private:
    void init_globals();
    void update();

    ::REManagedObject* m_player{nullptr};
    ::REGameObject* m_body{nullptr};
    ::REGameObject* m_head{nullptr};
    ::REManagedObject* m_equipment{nullptr};
    ::REManagedObject* m_weapon{nullptr};
    ::REManagedObject* m_weapon_go{nullptr};
    bool m_is_player_controlled{false};
    bool m_is_crouching{false};
    double m_last_inventory_shown{0.0};
    sdk::RETypeDefinition* m_player_cam_td{nullptr};
};
#endif
