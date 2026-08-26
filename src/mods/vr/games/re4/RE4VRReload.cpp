#define NOMINMAX
#include "RE4VRReload.hpp"

#if defined(RE4)
#include <sdk/MurmurHash.hpp>
#include <sdk/RETypeDB.hpp>

#include "RE4VRReloadMag.hpp"
#include "../../../ScriptRunner.hpp"

namespace {
re4vr::rl::MagFed g_mag;
bool g_hooks{false};

HookManager::PreHookResult cache_wi(std::vector<uintptr_t>& args) {
    if (args.size() > 1) {
        auto* wi = (::REManagedObject*)args[1];
        if (re4vr::obj_ok(wi)) {
            const double now = re4vr::lua_os_clock();
            const double t = re4vr::lua_number("__re4_live_wi_t").value_or(-1);
            if (now - t > 0.1) {
                int32_t cwid = 0;
                if (auto n = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(wi, "get_WeaponId"); })) {
                    cwid = *n;
                } else {
                    auto* o = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(wi, "get_WeaponId"); }).value_or(nullptr);
                    cwid = re4vr::rl::enum_num(o);
                }
                auto ewid = re4vr::rl::equip_wid();
                if (cwid && ewid && cwid == *ewid) {
                    re4vr::rl::cache_live_wi(wi);
                }
            } else {
                re4vr::rl::cache_live_wi(wi);
            }
        }
    }
    return HookManager::PreHookResult::CALL_ORIGINAL;
}
}

std::shared_ptr<RE4VRReload>& RE4VRReload::get() {
    static auto inst = std::make_shared<RE4VRReload>();
    return inst;
}

HookManager::PreHookResult RE4VRReload::pre_ammo(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    return cache_wi(args);
}
HookManager::PreHookResult RE4VRReload::pre_pump_mute(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    if (!g_mag.shotgun(g_mag.wid()) || g_mag.our_sound) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    auto it = g_mag.auto_pump_mute.find(g_mag.wid());
    if (it == g_mag.auto_pump_mute.end() || args.size() < 3 || !args[2]) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    auto* info = (::REManagedObject*)args[2];
    const uint32_t tid = *(uint32_t*)((uintptr_t)info + 0x10);
    const uint32_t eid = *(uint32_t*)((uintptr_t)info + 0x14);
    if (tid == it->second || eid == it->second) {
        return HookManager::PreHookResult::SKIP_ORIGINAL;
    }
    return HookManager::PreHookResult::CALL_ORIGINAL;
}
void RE4VRReload::post_nop(uintptr_t&, sdk::RETypeDefinition*, uintptr_t) {}

std::optional<std::string> RE4VRReload::on_initialize() {
    g_mag.seed_leon();
    g_mag.load();
    if (!g_hooks) {
        if (auto* td = sdk::find_type_definition("chainsaw.WeaponItem")) {
            for (const char* n : {"reduceAmmoCount", "addAmmoCount", "get_CurrentAmmoCount"}) {
                if (auto* m = td->get_method(n)) {
                    g_hookman.add(m, &RE4VRReload::pre_ammo, &RE4VRReload::post_nop);
                }
            }
        }
        if (auto* td = sdk::find_type_definition("soundlib.SoundManager")) {
            if (auto* m = td->get_method("postRequestInfo(soundlib.SoundManager.RequestInfo)")) {
                g_hookman.add(m, &RE4VRReload::pre_pump_mute, &RE4VRReload::post_nop);
            }
        }
        g_hooks = true;
    }
    return std::nullopt;
}

void RE4VRReload::on_lua_state_created(sol::state& lua) {
    g_mag.seed_leon();
    g_mag.load();
    g_mag.export_globals(lua);
    re4vr::rl::wrap_smih(lua, [](bool a) -> std::optional<bool> {
        if (g_mag.handled()) {
            return g_mag.set_mag_in_hand(a);
        }
        return std::nullopt;
    });
    lua["__re4_insert_manual_wid"] = lua.create_table();
    lua["__re4_insert_manual_wid"][6104] = false;
    auto sc = lua.create_table();
    sc["part"] = g_mag.ss.part;
    sc["x"] = g_mag.ss.x;
    sc["y"] = g_mag.ss.y;
    sc["z"] = g_mag.ss.z;
    sc["rx"] = g_mag.ss.rx;
    sc["ry"] = g_mag.ss.ry;
    sc["rz"] = g_mag.ss.rz;
    sc["scale"] = g_mag.ss.scale;
    sc["preview"] = g_mag.ss.preview;
    lua["__re4_ss_clone"] = sc;
    re4vr::export_pose_api(lua);
}

void RE4VRReload::on_lua_state_destroyed(sol::state&) {
    g_mag.reset();
}

void RE4VRReload::on_frame() {
    ScriptProfileGuard guard("re4_vr_reload.lua", "on_frame", re4vr::profile_frame());
    g_mag.on_frame();
}

void RE4VRReload::on_pre_application_entry(void*, const char*, size_t hash) {
    if (hash != "LockScene"_fnv && hash != "BeginRendering"_fnv) {
        return;
    }
    ScriptProfileGuard guard("re4_vr_reload.lua",
        hash == "LockScene"_fnv ? "on_pre_application_entry:LockScene" : "on_pre_application_entry:BeginRendering",
        re4vr::profile_frame());
    if (hash == "LockScene"_fnv) {
        g_mag.apply_drop();
        g_mag.apply_ss();
        g_mag.apply_slide();
    } else {
        g_mag.apply_drop_joint();
        g_mag.apply_ss_insert_visual();
        g_mag.apply_ss();
        g_mag.apply_slide();
    }
}

void RE4VRReload::on_application_entry(void*, const char*, size_t hash) {
    if (hash != "LateUpdateBehavior"_fnv && hash != "UpdateJointExpression"_fnv && hash != "BeginRendering"_fnv) {
        return;
    }
    ScriptProfileGuard guard("re4_vr_reload.lua",
        hash == "LateUpdateBehavior"_fnv ? "on_application_entry:LateUpdateBehavior"
            : (hash == "UpdateJointExpression"_fnv ? "on_application_entry:UpdateJointExpression" : "on_application_entry:BeginRendering"),
        re4vr::profile_frame());
    if (hash == "LateUpdateBehavior"_fnv) {
        g_mag.apply_drop();
        g_mag.apply_ss();
        g_mag.apply_slide();
    } else if (hash == "UpdateJointExpression"_fnv) {
        g_mag.apply_drop_joint();
        g_mag.apply_ss();
        g_mag.apply_slide();
    } else {
        g_mag.apply_drop();
        g_mag.apply_ss_late();
    }
}
#endif
