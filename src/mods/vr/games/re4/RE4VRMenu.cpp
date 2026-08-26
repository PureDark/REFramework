#define NOMINMAX
#include "RE4VRMenu.hpp"

#if defined(RE4)
#include <algorithm>

#include <imgui.h>
#include <spdlog/spdlog.h>

std::shared_ptr<RE4VRMenu>& RE4VRMenu::get() {
    static auto inst = std::make_shared<RE4VRMenu>();
    return inst;
}

void RE4VRMenu::add(int order, std::string id, std::function<void()> fn) {
    if (!fn) {
        return;
    }
    std::lock_guard lock(m_mutex);
    m_entries[std::move(id)] = Entry{order, std::move(fn)};
}

void RE4VRMenu::on_lua_state_created(sol::state& lua) {
    lua["__re4_ui_entries"] = lua.create_table();
    lua["__re4_ui_add"] = [this](sol::object order, sol::object id, sol::protected_function fn) {
        if (!fn.valid()) {
            return;
        }
        const int o = order.is<int>() ? order.as<int>() : (order.is<double>() ? (int)order.as<double>() : 999);
        const auto sid = id.is<std::string>() ? id.as<std::string>() : std::string{"anon"};
        add(o, sid, [fn]() {
            auto r = fn();
            (void)r;
        });
    };
}

void RE4VRMenu::on_lua_state_destroyed(sol::state&) {
    std::lock_guard lock(m_mutex);
    m_entries.clear();
}

void RE4VRMenu::on_draw_ui() {
    std::vector<std::pair<std::string, Entry>> list;
    {
        std::lock_guard lock(m_mutex);
        list.reserve(m_entries.size());
        for (auto& [id, e] : m_entries) {
            list.emplace_back(id, e);
        }
    }
    if (list.empty()) {
        return;
    }
    std::sort(list.begin(), list.end(), [](const auto& a, const auto& b) {
        if (a.second.order != b.second.order) {
            return a.second.order < b.second.order;
        }
        return a.first < b.first;
    });
    for (auto& [id, e] : list) {
        if (e.fn) {
            try {
                e.fn();
            } catch (...) {
            }
        }
    }
    ImGui::Separator();
}
#endif
