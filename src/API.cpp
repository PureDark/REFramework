#include "mods/APIProxy.hpp"
#include "mods/ScriptRunner.hpp"

#include "../include/API.hpp"

bool reframework_is_ready() {
    if (g_framework == nullptr) {
        return false;
    }

    return g_framework->is_ready();
}

bool reframework_on_initialized(REFInitializedCb cb) {
    return APIProxy::add_on_initialized(cb);
}

bool reframework_on_lua_state_created(REFLuaStateCreatedCb cb) {
    if (cb == nullptr) {
        return false;
    }

    return APIProxy::add_on_initialized([cb]() {
        APIProxy::get()->add_on_lua_state_created(cb);
    });
}

bool reframework_on_lua_state_destroyed(REFLuaStateDestroyedCb cb) {
    if (cb == nullptr) {
        return false;
    }

    return APIProxy::add_on_initialized([cb]() {
        APIProxy::get()->add_on_lua_state_destroyed(cb);
    });
}

bool reframework_on_frame(REFOnFrameCb cb) {
    if (cb == nullptr) {
        return false;
    }

    return APIProxy::add_on_initialized([cb]() {
        APIProxy::get()->add_on_frame(cb);
    });
}