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

private:
    struct Off3 {
        float x{0}, y{0}, z{0};
        float rx{0}, ry{0}, rz{0};
    };

    void export_globals(sol::state& lua);
    void load_json();
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
    void wildwest_tick();
    void blood_tick();
    void knife_di_guard();
    bool prompt_visible();
    bool reverse_grip();
    bool knife_out();
    ::REManagedObject* find_knife_mesh();
    std::optional<int32_t> get_selected_knife_wid();
    void exec_native_melee();
    void native_hit(::REManagedObject* victim_hc, const Vector3f& pos);

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
    bool m_lh_intent{false};
    bool m_lh_clone_on{false};
    std::optional<int32_t> m_current_knife_wid{};
    bool m_parry_was{false};
    double m_parry_until{0};
};
#endif
