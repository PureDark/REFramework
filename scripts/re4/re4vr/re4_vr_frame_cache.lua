-- Builtin implementation: src/mods/vr/games/re4/RE4VRFrameCache.cpp
return

-- Shared, frame-local lookup cache for the RE4VR autorun scripts.
-- It deliberately keeps no value beyond the current engine frame.  Setting
-- _G.__re4_fc_off = true disables it and lets each caller use its legacy path.
local cache = rawget(_G, "__re4_frame_cache")
if type(cache) ~= "table" then
    cache = {}
    _G.__re4_frame_cache = cache
end

local state = {
    frame = nil,
    singletons = {},
}

local function clear_for_frame(frame)
    if state.frame == frame then return end
    state.frame = frame
    state.singletons = {}
    state.ctx, state.ctx_done = nil, false
    state.body_go, state.body_go_done = nil, false
    state.body_tf, state.body_tf_done = nil, false
    state.pe, state.pe_done = nil, false
    state.equip_wid, state.equip_wid_done = nil, false
end

local function begin_frame()
    if rawget(_G, "__re4_fc_off") == true then return false end
    if not re or type(re.get_frame_count) ~= "function" then return false end
    local ok, frame = pcall(re.get_frame_count)
    if not ok or type(frame) ~= "number" then return false end
    clear_for_frame(frame)
    return true
end

local function call(object, method, argument)
    if not object then return nil end
    local ok, value
    if argument ~= nil then
        ok, value = pcall(function() return object:call(method, argument) end)
    else
        ok, value = pcall(function() return object:call(method) end)
    end
    if ok then return value end
    return nil
end

function cache.on()
    return begin_frame()
end

function cache.get_managed_singleton(name)
    if not begin_frame() then return sdk.get_managed_singleton(name) end
    local entry = state.singletons[name]
    if entry then return entry.value end
    local value = sdk.get_managed_singleton(name)
    state.singletons[name] = { value = value }
    return value
end

function cache.ctx()
    if not begin_frame() then
        local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
        return call(cm, "getPlayerContextRef")
    end
    if state.ctx_done then return state.ctx end
    state.ctx = call(cache.get_managed_singleton("chainsaw.CharacterManager"), "getPlayerContextRef")
    state.ctx_done = true
    return state.ctx
end

function cache.body_go()
    if not begin_frame() then return call(cache.ctx(), "get_BodyGameObject") end
    if state.body_go_done then return state.body_go end
    state.body_go = call(cache.ctx(), "get_BodyGameObject")
    state.body_go_done = true
    return state.body_go
end

function cache.body_tf()
    if not begin_frame() then return call(cache.body_go(), "get_Transform") end
    if state.body_tf_done then return state.body_tf end
    state.body_tf = call(cache.body_go(), "get_Transform")
    state.body_tf_done = true
    return state.body_tf
end

function cache.pe()
    if not begin_frame() then
        local head = call(cache.ctx(), "get_HeadGameObject")
        local td = sdk.typeof("chainsaw.PlayerEquipment")
        return head and td and call(head, "getComponent(System.Type)", td) or nil
    end
    if state.pe_done then return state.pe end
    local head = call(cache.ctx(), "get_HeadGameObject")
    local td = sdk.typeof("chainsaw.PlayerEquipment")
    state.pe = head and td and call(head, "getComponent(System.Type)", td) or nil
    state.pe_done = true
    return state.pe
end

function cache.equip_wid()
    if not begin_frame() then
        local hu = call(cache.ctx(), "get_HeadUpdater")
        local wid = call(hu, "get_EquipWeaponID")
        if type(wid) == "number" then return wid end
        local ok, value = pcall(function() return wid and wid.value__ end)
        return ok and type(value) == "number" and value or nil
    end
    if state.equip_wid_done then return state.equip_wid end
    local hu = call(cache.ctx(), "get_HeadUpdater")
    local wid = call(hu, "get_EquipWeaponID")
    if type(wid) == "number" then
        state.equip_wid = wid
    else
        local ok, value = pcall(function() return wid and wid.value__ end)
        state.equip_wid = ok and type(value) == "number" and value or nil
    end
    state.equip_wid_done = true
    return state.equip_wid
end

if re and type(re.on_script_reset) == "function" then
    re.on_script_reset(function()
        state.frame = nil
        state.singletons = {}
    end)
end

return cache
