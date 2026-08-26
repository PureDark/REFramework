#pragma once

#if defined(RE4)
#include <chrono>

#include "../../../../Mod.hpp"

// Builtin port of scripts/re4/re4_vr_capacitive.lua
class RE4VRCapacitive : public Mod {
public:
    static std::shared_ptr<RE4VRCapacitive>& get();
    std::string_view get_name() const override { return "RE4VRCapacitive"; }

    std::optional<std::string> on_initialize() override;
    void on_config_load(const utility::Config& cfg) override;
    void on_frame() override;

private:
    void load_json();
    void apply();

    struct Cfg {
        bool use_analog{true};
        bool prefer_force{true};
        float press{0.30f};
        float release{0.25f};
    };
    Cfg m_cfg{};
    std::chrono::steady_clock::time_point m_next_push{std::chrono::steady_clock::now()};
};
#endif
