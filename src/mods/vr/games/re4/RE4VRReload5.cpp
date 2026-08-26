#define NOMINMAX
#include "RE4VRReload5.hpp"

#if defined(RE4)
#include <sdk/MurmurHash.hpp>
#include <sdk/RETypeDB.hpp>

#include "RE4VRReloadFam.hpp"
#include "RE4VRReloadMag.hpp"
#include "../../../ScriptRunner.hpp"

namespace {
re4vr::rl::MagFed g_rifle;
re4vr::rl::RifleSwitch g_sw;
re4vr::rl::BoltFamily g_bolt;
re4vr::rl::Red9Family g_edge;
re4vr::rl::BlastBow g_bow;
bool g_hooks{false};
}

std::shared_ptr<RE4VRReload5>& RE4VRReload5::get() {
    static auto inst = std::make_shared<RE4VRReload5>();
    return inst;
}

HookManager::PreHookResult RE4VRReload5::pre_bolt_cycle(std::vector<uintptr_t>&, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    if (RE4VRShared::get()->re4_bolt_in_cycle || RE4VRShared::get()->re4_bolt_in_cycle_dlc) {
        return HookManager::PreHookResult::SKIP_ORIGINAL;
    }
    return HookManager::PreHookResult::CALL_ORIGINAL;
}
void RE4VRReload5::post_nop(uintptr_t&, sdk::RETypeDefinition*, uintptr_t) {}

std::optional<std::string> RE4VRReload5::on_initialize() {
    g_rifle.seed_rifle_ada();
    g_rifle.load();
    g_bolt.seed_ada();
    g_bolt.load();
    g_edge.seed_ada();
    g_edge.load();
    g_bow.load();
    if (!g_hooks) {
        if (auto* td = sdk::find_type_definition("chainsaw.Gun")) {
            for (auto& m : td->get_methods()) {
                if (m.get_name() == std::string_view{"callbackTracks"}) {
                    g_hookman.add(&m, &RE4VRReload5::pre_bolt_cycle, &RE4VRReload5::post_nop);
                }
            }
        }
        g_hooks = true;
    }
    return std::nullopt;
}

void RE4VRReload5::on_lua_state_created(sol::state& lua) {
    g_rifle.seed_rifle_ada();
    g_rifle.load();
    g_bolt.seed_ada();
    g_bolt.load();
    g_edge.seed_ada();
    g_edge.load();
    g_bow.load();
    re4vr::rl::wrap_smih(lua, [](bool a) -> std::optional<bool> {
        if (g_rifle.handled()) {
            return g_rifle.set_mag_in_hand(a);
        }
        return std::nullopt;
    });
    re4vr::rl::wrap_smih(lua, [](bool a) -> std::optional<bool> {
        if (g_bolt.owns()) {
            return g_bolt.set_mag_in_hand(a);
        }
        return std::nullopt;
    });
    re4vr::rl::wrap_smih(lua, [](bool a) -> std::optional<bool> {
        if (g_edge.owns()) {
            return g_edge.set_mag_in_hand(a);
        }
        return std::nullopt;
    });
    re4vr::rl::wrap_smih(lua, [](bool a) -> std::optional<bool> {
        if (g_bow.owns()) {
            return g_bow.set_mag_in_hand(a);
        }
        return std::nullopt;
    });
}

void RE4VRReload5::on_lua_state_destroyed(sol::state&) {
    g_rifle.reset();
    g_bolt.reset();
    g_edge.reset();
    g_bow.reset();
}

void RE4VRReload5::on_frame() {
    ScriptProfileGuard guard("re4_vr_reload5_dlc.lua", "on_frame", re4vr::profile_frame());
    g_rifle.on_frame();
    if (auto h = g_rifle.handled()) {
        g_sw.tick(g_rifle.wep.tf, *h, g_rifle.rack.needs);
    }
    g_bolt.on_frame();
    g_edge.on_frame();
    g_bow.on_frame();
}

void RE4VRReload5::on_pre_application_entry(void*, const char*, size_t hash) {
    if (hash != "LockScene"_fnv && hash != "BeginRendering"_fnv) {
        return;
    }
    ScriptProfileGuard guard("re4_vr_reload5_dlc.lua",
        hash == "LockScene"_fnv ? "on_pre_application_entry:LockScene" : "on_pre_application_entry:BeginRendering",
        re4vr::profile_frame());
    g_rifle.apply_drop();
    if (hash == "BeginRendering"_fnv) {
        g_rifle.apply_drop_joint();
    }
    g_rifle.apply_slide();
    g_sw.apply();
    g_bolt.apply();
    g_edge.apply();
    g_bow.apply();
}

void RE4VRReload5::on_application_entry(void*, const char*, size_t hash) {
    if (hash != "LateUpdateBehavior"_fnv && hash != "UpdateJointExpression"_fnv && hash != "BeginRendering"_fnv) {
        return;
    }
    ScriptProfileGuard guard("re4_vr_reload5_dlc.lua", "on_application_entry", re4vr::profile_frame());
    if (hash == "BeginRendering"_fnv) {
        g_rifle.apply_drop();
        g_edge.apply_late();
        return;
    }
    if (hash == "UpdateJointExpression"_fnv) {
        g_rifle.apply_drop_joint();
    } else {
        g_rifle.apply_drop();
    }
    g_rifle.apply_slide();
    g_sw.apply();
    g_bolt.apply();
    g_edge.apply();
    g_bow.apply();
}
#endif
