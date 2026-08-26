#pragma once

#if defined(RE4)
#include <functional>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "../../../../Mod.hpp"

// Builtin port of scripts/re4/#re4_vr_menu.lua
class RE4VRMenu : public Mod {
public:
    static std::shared_ptr<RE4VRMenu>& get();
    std::string_view get_name() const override { return "RE4VRMenu"; }

    void on_lua_state_created(sol::state& lua) override;
    void on_lua_state_destroyed(sol::state& lua) override;
    void on_draw_ui() override;

    void add(int order, std::string id, std::function<void()> fn);

private:
    struct Entry {
        int order{999};
        std::function<void()> fn{};
    };
    std::mutex m_mutex{};
    std::unordered_map<std::string, Entry> m_entries{};
};
#endif
