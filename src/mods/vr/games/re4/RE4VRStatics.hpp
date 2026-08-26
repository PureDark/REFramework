#pragma once

#if defined(RE4)
#include "../../../../Mod.hpp"

// Builtin port of scripts/re4/utility/Statics.lua
class RE4VRStatics : public Mod {
public:
    static std::shared_ptr<RE4VRStatics>& get();
    std::string_view get_name() const override { return "RE4VRStatics"; }

    void on_lua_state_created(sol::state& lua) override;
};
#endif
