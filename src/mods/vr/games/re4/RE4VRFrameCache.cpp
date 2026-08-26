#define NOMINMAX
#include "RE4VRFrameCache.hpp"

#if defined(RE4)
#include "RE4VRShared.hpp"

std::shared_ptr<RE4VRFrameCache>& RE4VRFrameCache::get() {
    static auto inst = std::make_shared<RE4VRFrameCache>();
    return inst;
}

void RE4VRFrameCache::begin_frame() {
    m_off = RE4VRShared::get()->re4_fc_off;
    const auto f = VR::get()->get_frame_count();
    if (f != m_frame) {
        m_frame = f;
        re4vr::reset_pointer_cache();
    }
}

bool RE4VRFrameCache::on() {
    begin_frame();
    return !m_off;
}

::REManagedObject* RE4VRFrameCache::ctx() {
    begin_frame();
    return re4vr::player_context();
}

::REGameObject* RE4VRFrameCache::body_go() {
    begin_frame();
    return re4vr::body_game_object();
}

::RETransform* RE4VRFrameCache::body_tf() {
    begin_frame();
    return re4vr::body_transform();
}

::REManagedObject* RE4VRFrameCache::pe() {
    begin_frame();
    auto* head = re4vr::head_game_object();
    return re4vr::get_component((::REManagedObject*)head, "chainsaw.PlayerEquipment");
}

std::optional<int32_t> RE4VRFrameCache::equip_wid() {
    begin_frame();
    auto* ctx = re4vr::player_context();
    if (!re4vr::obj_ok(ctx)) {
        return std::nullopt;
    }
    auto* hu = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_HeadUpdater"); }).value_or(nullptr);
    if (!re4vr::obj_ok(hu)) {
        return std::nullopt;
    }
    if (auto w = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(hu, "get_EquipWeaponID"); })) {
        return w;
    }
    return std::nullopt;
}

void RE4VRFrameCache::on_lua_state_created(sol::state& lua) {
    auto t = lua.create_table();
    t["on"] = [this]() { return on(); };
    t["ctx"] = [this]() { return ctx(); };
    t["pe"] = [this]() { return pe(); };
    t["equip_wid"] = [this]() { return equip_wid(); };
    t["get_managed_singleton"] = [](const std::string& name) {
        return sdk::get_managed_singleton<::REManagedObject>(name);
    };
    lua["__re4_frame_cache"] = t;
    lua["package"]["loaded"]["re4vr/re4_vr_frame_cache"] = t;
}

void RE4VRFrameCache::on_lua_state_destroyed(sol::state&) {
    re4vr::reset_pointer_cache();
    m_frame = -1;
}
#endif
