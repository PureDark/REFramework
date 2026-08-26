#pragma once

#if defined(RE4)
#include "../../../../Mod.hpp"
#include <sdk/REMath.hpp>

// Builtin port of scripts/re4/re4vr/re4_vr_frame_cache.lua
class RE4VRFrameCache : public Mod {
public:
    static std::shared_ptr<RE4VRFrameCache>& get();
    std::string_view get_name() const override { return "RE4VRFrameCache"; }

    void on_lua_state_created(sol::state& lua) override;
    void on_lua_state_destroyed(sol::state& lua) override;

    bool on();
    ::REManagedObject* ctx();
    ::REGameObject* body_go();
    ::RETransform* body_tf();
    ::REManagedObject* pe();
    std::optional<int32_t> equip_wid();

private:
    void begin_frame();

    int32_t m_frame{-1};
    bool m_off{false};
};
#endif
