#pragma once

#if defined(RE4)
#include <memory>
#include <optional>
#include <string>
#include <string_view>

#include "../../../../Mod.hpp"
#include "HookManager.hpp"

class RE4VRReload5 : public Mod {
public:
    static std::shared_ptr<RE4VRReload5>& get();
    std::string_view get_name() const override { return "RE4VRReload5"; }

    std::optional<std::string> on_initialize() override;
    void on_lua_state_created(sol::state& lua) override;
    void on_lua_state_destroyed(sol::state& lua) override;
    void on_frame() override;
    void on_pre_application_entry(void* entry, const char* name, size_t hash) override;
    void on_application_entry(void* entry, const char* name, size_t hash) override;

    static HookManager::PreHookResult pre_bolt_cycle(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static void post_nop(uintptr_t& ret_val, sdk::RETypeDefinition* ret_ty, uintptr_t ret_addr);
};
#endif
