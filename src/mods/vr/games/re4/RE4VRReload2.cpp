#define NOMINMAX
#include "RE4VRReload2.hpp"

#if defined(RE4)
#include <sdk/MurmurHash.hpp>
#include <sdk/RETypeDB.hpp>

#include "RE4VRReloadFam.hpp"
#include "RE4VRReloadMag.hpp"
#include "../../../ScriptRunner.hpp"

namespace {
re4vr::rl::RevolverFamily g_rev;
re4vr::rl::MagFed g_rifle;
re4vr::rl::RifleSwitch g_sw;
re4vr::rl::BoltFamily g_bolt;
re4vr::rl::XbowFamily g_xbow;
re4vr::rl::Red9Family g_red9;
bool g_hooks{false};
}

std::shared_ptr<RE4VRReload2>& RE4VRReload2::get() {
    static auto inst = std::make_shared<RE4VRReload2>();
    return inst;
}

HookManager::PreHookResult RE4VRReload2::pre_bolt_cycle(std::vector<uintptr_t>&, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    if (re4vr::lua_is_true("__re4_bolt_in_cycle") || re4vr::lua_is_true("__re4_bolt_in_cycle_dlc")) {
        return HookManager::PreHookResult::SKIP_ORIGINAL;
    }
    return HookManager::PreHookResult::CALL_ORIGINAL;
}
HookManager::PreHookResult RE4VRReload2::pre_xbow_dummy(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    if (re4vr::lua_is_true("__re4_xbow_dummy_await") && args.size() > 1) {
        auto* thiz = (::REManagedObject*)args[1];
        if (re4vr::obj_ok(thiz)) {
            re4vr::lua_set_object("__re4_xbow_dummy_obj", thiz);
            re4vr::lua_set_bool("__re4_xbow_dummy_await", false);
        }
    }
    return HookManager::PreHookResult::CALL_ORIGINAL;
}
void RE4VRReload2::post_nop(uintptr_t&, sdk::RETypeDefinition*, uintptr_t) {}

std::optional<std::string> RE4VRReload2::on_initialize() {
    g_rev.seed_leon();
    g_rev.load();
    g_rifle.seed_rifle_leon();
    g_rifle.load();
    g_bolt.seed_leon();
    g_bolt.load();
    g_xbow.load();
    g_red9.seed_leon();
    g_red9.load();
    if (!g_hooks) {
        if (auto* td = sdk::find_type_definition("chainsaw.Gun")) {
            for (auto& m : td->get_methods()) {
                if (m.get_name() == std::string_view{"callbackTracks"}) {
                    g_hookman.add(&m, &RE4VRReload2::pre_bolt_cycle, &RE4VRReload2::post_nop);
                }
            }
        }
        if (auto* td = sdk::find_type_definition("chainsaw.ShellDummyBase")) {
            auto* m = td->get_method("requestStart");
            if (!m) {
                m = td->get_method("start");
            }
            if (m) {
                g_hookman.add(m, &RE4VRReload2::pre_xbow_dummy, &RE4VRReload2::post_nop);
            }
        }
        g_hooks = true;
    }
    return std::nullopt;
}

void RE4VRReload2::on_lua_state_created(sol::state& lua) {
    g_rev.seed_leon();
    g_rev.load();
    g_rifle.seed_rifle_leon();
    g_rifle.load();
    g_bolt.seed_leon();
    g_bolt.load();
    g_xbow.load();
    g_red9.seed_leon();
    g_red9.load();
    re4vr::rl::wrap_smih(lua, [](bool a) -> std::optional<bool> {
        if (g_rev.owns()) {
            return g_rev.set_mag_in_hand(a);
        }
        return std::nullopt;
    });
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
        if (g_xbow.owns()) {
            return g_xbow.set_mag_in_hand(a);
        }
        return std::nullopt;
    });
    re4vr::rl::wrap_smih(lua, [](bool a) -> std::optional<bool> {
        if (g_red9.owns()) {
            return g_red9.set_mag_in_hand(a);
        }
        return std::nullopt;
    });
}

void RE4VRReload2::on_lua_state_destroyed(sol::state&) {
    g_rev.reset();
    g_rifle.reset();
    g_bolt.reset();
    g_xbow.reset();
    g_red9.reset();
}

void RE4VRReload2::on_frame() {
    ScriptProfileGuard guard("re4_vr_reload2.lua", "on_frame", re4vr::profile_frame());
    g_rev.on_frame();
    g_rifle.on_frame();
    if (auto h = g_rifle.handled()) {
        g_sw.tick(g_rifle.wep.tf, *h, g_rifle.rack.needs);
    }
    g_bolt.on_frame();
    g_xbow.on_frame();
    g_red9.on_frame();
}

void RE4VRReload2::on_pre_application_entry(void*, const char*, size_t hash) {
    if (hash != "LockScene"_fnv && hash != "BeginRendering"_fnv) {
        return;
    }
    ScriptProfileGuard guard("re4_vr_reload2.lua",
        hash == "LockScene"_fnv ? "on_pre_application_entry:LockScene" : "on_pre_application_entry:BeginRendering",
        re4vr::profile_frame());
    g_rev.apply();
    g_rifle.apply_drop();
    if (hash == "BeginRendering"_fnv) {
        g_rifle.apply_drop_joint();
    }
    g_rifle.apply_slide();
    g_sw.apply();
    g_bolt.apply();
    g_xbow.apply();
    g_red9.apply();
}

void RE4VRReload2::on_application_entry(void*, const char*, size_t hash) {
    if (hash != "LateUpdateBehavior"_fnv && hash != "UpdateJointExpression"_fnv && hash != "BeginRendering"_fnv && hash != "UpdateMotion"_fnv) {
        return;
    }
    ScriptProfileGuard guard("re4_vr_reload2.lua", "on_application_entry", re4vr::profile_frame());
    if (hash == "BeginRendering"_fnv) {
        g_rev.apply_late();
        g_rifle.apply_drop();
        g_xbow.apply_late();
        g_red9.apply_late();
        return;
    }
    g_rev.apply();
    if (hash == "UpdateJointExpression"_fnv) {
        g_rifle.apply_drop_joint();
    } else {
        g_rifle.apply_drop();
    }
    g_rifle.apply_slide();
    g_sw.apply();
    g_bolt.apply();
    g_xbow.apply();
    g_red9.apply();
}
#endif
