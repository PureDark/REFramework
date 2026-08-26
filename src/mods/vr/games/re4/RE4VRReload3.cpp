#define NOMINMAX
#include "RE4VRReload3.hpp"

#if defined(RE4)
#include <algorithm>
#include <unordered_set>

#include <sdk/MurmurHash.hpp>
#include <sdk/RETypeDB.hpp>

#include "RE4VRReloadFam.hpp"
#include "RE4VRReloadMag.hpp"
#include "../../../ScriptRunner.hpp"

namespace {
re4vr::rl::MagFed g_chicago;
re4vr::rl::RevolverFamily g_hc;
re4vr::rl::RLFamily g_rl;
re4vr::rl::FlameFamily g_ft;
bool g_hooks{false};
}

std::shared_ptr<RE4VRReload3>& RE4VRReload3::get() {
    static auto inst = std::make_shared<RE4VRReload3>();
    return inst;
}

HookManager::PreHookResult RE4VRReload3::pre_ft_damage(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    ::REManagedObject* hc = nullptr;
    ::REManagedObject* dv = nullptr;
    for (size_t i = 1; i < args.size() && i < 6; ++i) {
        auto* o = (::REManagedObject*)args[i];
        if (!re4vr::obj_ok(o)) {
            continue;
        }
        auto* td = utility::re_managed_object::get_type_definition(o);
        if (!td) {
            continue;
        }
        const auto n = std::string{td->get_full_name()};
        if (n == "chainsaw.HitController") {
            hc = o;
        } else if (n == "chainsaw.HitController.DamageValue") {
            dv = o;
        }
    }
    if (!hc || !dv) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    int32_t wid = 0;
    if (auto n = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(hc, "get_WeaponID"); })) {
        wid = *n;
    } else {
        auto* o = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(hc, "get_WeaponID"); }).value_or(nullptr);
        wid = re4vr::rl::enum_num(o);
    }
    static const std::unordered_set<int32_t> flame{4701, 5801, 5803, 5804};
    if (!flame.contains(wid)) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    auto dmg = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(dv, "get_Damage"); }).value_or(1);
    const int boosted = std::max(30, dmg * 5);
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(dv, "set_Damage", boosted); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(dv, "set_Stopping", 495); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(dv, "set_Wince", 400); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(dv, "set_Break", 400); });
    return HookManager::PreHookResult::CALL_ORIGINAL;
}
void RE4VRReload3::post_nop(uintptr_t&, sdk::RETypeDefinition*, uintptr_t) {}

std::optional<std::string> RE4VRReload3::on_initialize() {
    g_chicago.seed_chicago();
    g_chicago.load();
    g_hc.seed_handcannon();
    g_hc.load();
    g_rl.load();
    g_ft.load();
    if (!g_hooks) {
        if (auto* td = sdk::find_type_definition("chainsaw.HitController")) {
            if (auto* m = td->get_method("callbackCalculateDamage")) {
                g_hookman.add(m, &RE4VRReload3::pre_ft_damage, &RE4VRReload3::post_nop);
            }
        }
        g_hooks = true;
    }
    return std::nullopt;
}

void RE4VRReload3::on_lua_state_created(sol::state& lua) {
    g_chicago.seed_chicago();
    g_chicago.load();
    g_hc.seed_handcannon();
    g_hc.load();
    g_rl.load();
    g_ft.load();
    re4vr::rl::wrap_smih(lua, [](bool a) -> std::optional<bool> {
        if (g_chicago.handled()) {
            return g_chicago.set_mag_in_hand(a);
        }
        return std::nullopt;
    });
    re4vr::rl::wrap_smih(lua, [](bool a) -> std::optional<bool> {
        if (g_hc.owns()) {
            return g_hc.set_mag_in_hand(a);
        }
        return std::nullopt;
    });
    re4vr::rl::wrap_smih(lua, [](bool a) -> std::optional<bool> {
        if (g_rl.owns()) {
            return g_rl.set_mag_in_hand(a);
        }
        return std::nullopt;
    });
    re4vr::rl::wrap_smih(lua, [](bool a) -> std::optional<bool> {
        if (g_ft.owns()) {
            return g_ft.set_mag_in_hand(a);
        }
        return std::nullopt;
    });
}

void RE4VRReload3::on_lua_state_destroyed(sol::state&) {
    g_chicago.reset();
    g_hc.reset();
    g_rl.reset();
    g_ft.reset();
}

void RE4VRReload3::on_frame() {
    ScriptProfileGuard guard("re4_vr_reload3.lua", "on_frame", re4vr::profile_frame());
    g_chicago.on_frame();
    g_hc.on_frame();
    g_rl.on_frame();
    g_ft.on_frame();
}

void RE4VRReload3::on_pre_application_entry(void*, const char*, size_t hash) {
    if (hash != "LockScene"_fnv && hash != "BeginRendering"_fnv) {
        return;
    }
    ScriptProfileGuard guard("re4_vr_reload3.lua",
        hash == "LockScene"_fnv ? "on_pre_application_entry:LockScene" : "on_pre_application_entry:BeginRendering",
        re4vr::profile_frame());
    g_chicago.apply_drop();
    if (hash == "BeginRendering"_fnv) {
        g_chicago.apply_drop_joint();
    }
    g_chicago.apply_slide();
    g_hc.apply();
    g_rl.apply();
    g_ft.apply();
}

void RE4VRReload3::on_application_entry(void*, const char*, size_t hash) {
    if (hash != "LateUpdateBehavior"_fnv && hash != "UpdateJointExpression"_fnv && hash != "BeginRendering"_fnv) {
        return;
    }
    ScriptProfileGuard guard("re4_vr_reload3.lua", "on_application_entry", re4vr::profile_frame());
    if (hash == "BeginRendering"_fnv) {
        g_chicago.apply_drop();
        g_hc.apply_late();
        g_rl.apply_late();
        return;
    }
    if (hash == "UpdateJointExpression"_fnv) {
        g_chicago.apply_drop_joint();
    } else {
        g_chicago.apply_drop();
    }
    g_chicago.apply_slide();
    g_hc.apply();
    g_rl.apply();
    g_ft.apply();
}
#endif
