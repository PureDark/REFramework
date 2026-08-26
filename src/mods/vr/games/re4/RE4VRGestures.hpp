#pragma once

#if defined(RE4)
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <sdk/REMath.hpp>
#include "../../../../Mod.hpp"

// Builtin port of scripts/re4/re4_vr_guestures.lua
class RE4VRGestures : public Mod {
public:
    static std::shared_ptr<RE4VRGestures>& get();
    std::string_view get_name() const override { return "RE4VRGestures"; }

    std::optional<std::string> on_initialize() override;
    void on_lua_state_created(sol::state& lua) override;
    void on_lua_state_destroyed(sol::state& lua) override;
    void on_frame() override;
    void on_pre_application_entry(void* entry, const char* name, size_t hash) override;
    void on_application_entry(void* entry, const char* name, size_t hash) override;

private:
    void load_poses();
    void rebuild(const std::string& name);
    bool hands_free();
    void start(const std::string& name);
    std::optional<float> blend_now();
    void apply();
    void fire_stagger();
    void taunt_load();
    std::optional<uint32_t> taunt_next(const std::string& body);
    void play_taunt();
    ::REManagedObject* pin(::REManagedObject* o);
    ::REManagedObject* flash_ud();
    ::REManagedObject* flash_table();
    ::REManagedObject* dmg_ud();

    std::unordered_map<std::string, std::unordered_map<std::string, float>> m_deg{};
    std::unordered_map<std::string, std::unordered_map<std::string, float>> m_rot{};
    std::unordered_map<std::string, std::unordered_map<std::string, glm::quat>> m_poses{};
    std::optional<std::string> m_active_name{};
    double m_active_t0{0.0};
    std::optional<double> m_hold_t0{};
    bool m_hold_fired{false};
    bool m_stagger_enabled{true};
    bool m_taunt_enabled{true};
    std::unordered_map<std::string, std::vector<uint32_t>> m_taunt_pools{};
    std::unordered_map<std::string, std::vector<uint32_t>> m_taunt_bags{};
    bool m_taunt_seeded{false};
    ::REManagedObject* m_ud{nullptr};
    ::REManagedObject* m_tbl{nullptr};
    ::REManagedObject* m_dmg{nullptr};
};
#endif
