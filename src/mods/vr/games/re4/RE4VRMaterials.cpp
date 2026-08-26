#define NOMINMAX
#include "RE4VRMaterials.hpp"

#if defined(RE4)
#include <algorithm>
#include <cctype>

#include <sdk/RETypeDB.hpp>
#include <sdk/RETransform.hpp>
#include <sdk/REString.hpp>
#include <sdk/REContext.hpp>
#include <sdk/SystemArray.hpp>
#include <sdk/SceneManager.hpp>
#include <utility/String.hpp>

#include "RE4VRShared.hpp"
#include "../../../ScriptRunner.hpp"

namespace {
std::string mat_name(::REManagedObject* renderer, int mi) {
    auto* nm = re4vr::safe([&] { return sdk::call_object_func_easy<::SystemString*>(renderer, "getMaterialName", mi); }).value_or(nullptr);
    return nm ? utility::re_string::get_string(nm) : std::string{};
}

void fill_leon(std::unordered_map<std::string, bool>& m) {
    for (const char* n : {"EyeAO_mat", "EyeOut_mat", "Face_mat", "EyeWet_mat", "BrowsEyeLashes_mat", "Eye_inside_mat", "Mouth_mat",
                          "Hair00_Mat", "Hair01_Mat", "Hat00_Mat", "Hat01_Mat", "pl0074_Hair_Mat", "pl0074_Hair2_Mat"}) {
        m[n] = true;
    }
}
void fill_ashley(std::unordered_map<std::string, bool>& m) {
    for (const char* n : {"Eye_out_mat", "Face_mat", "Mouth_mat", "Ao_mat", "EyeLash_mat", "Eye_in_mat", "Eyebrows_mat", "Eyewet_mat",
                          "Hair_A_Mat", "Hair_B_Mat", "Hair_C_Mat"}) {
        m[n] = true;
    }
}
void fill_ada(std::unordered_map<std::string, bool>& m) {
    for (const char* n : {"Ao_mat", "Blow_mat", "EyeLash_mat", "Eye_in_mat", "Eye_out_mat", "Eyewet_mat", "Face_mat", "Mouth_mat",
                          "Lens_Inside_mat", "Hair00_mat", "Hair01_mat", "Hair02_mat"}) {
        m[n] = true;
    }
}
}

std::shared_ptr<RE4VRMaterials>& RE4VRMaterials::get() {
    static auto inst = std::make_shared<RE4VRMaterials>();
    return inst;
}

void RE4VRMaterials::load_json() {
    const auto d = re4vr::load_json_file("re4_vr/re4_vr_materials.json");
    m_gondola_hide = re4vr::j_bool(d, "gondola_hide", true);
}

::REGameObject* RE4VRMaterials::get_body_go() {
    auto* body = re4vr::body_game_object();
    if (body) {
        const auto nm = re4vr::go_name((::REManagedObject*)body);
        if (nm == "ch0a0z0_body" || nm == "ch0a1z0_body" || nm == "ch3a8z0_body") {
            return body;
        }
    }
    auto* scene = re4vr::current_scene();
    if (!scene) {
        return nullptr;
    }
    for (const char* nm : {"ch0a0z0_body", "ch0a1z0_body"}) {
        auto* s = sdk::VM::create_managed_string(utility::widen(nm));
        auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(scene, "findGameObject(System.String)", s); }).value_or(nullptr);
        if (go && re4vr::go_valid((::REManagedObject*)go)) {
            return go;
        }
    }
    return nullptr;
}

void RE4VRMaterials::set_mat(::REManagedObject* renderer, int mi, bool enable) {
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(renderer, "setMaterialsEnable", mi, enable); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(renderer, "setMaterialsEnable(System.Int32, System.Boolean)", mi, enable); });
}

void RE4VRMaterials::set_mesh_draw(::REManagedObject* renderer, bool draw_color, std::optional<bool> shadow) {
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(renderer, "set_DrawDefault", draw_color); });
    if (shadow) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(renderer, "set_DrawShadowCast", *shadow); });
    }
}

bool RE4VRMaterials::renderer_is_hh_only(::REManagedObject* renderer, int mcount) {
    if (!m_hide_materials || mcount < 1) {
        return false;
    }
    for (int mi = 0; mi < mcount; ++mi) {
        const auto name = mat_name(renderer, mi);
        if (!m_hide_materials->count(name)) {
            return false;
        }
    }
    return true;
}

void RE4VRMaterials::hide_mats_on(::REManagedObject* renderer, bool fullhide_go) {
    if (!renderer) {
        return;
    }
    const int mcount = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(renderer, "get_MaterialNum"); }).value_or(0);
    if (mcount < 1) {
        return;
    }
    static const std::unordered_set<std::string> EXTRA{"JacketFur_Mat", "Jacket_Mat"};
    if (renderer_is_hh_only(renderer, mcount)) {
        for (int mi = 0; mi < mcount; ++mi) {
            set_mat(renderer, mi, true);
        }
        if (m_fp_only || m_scope_body_hide) {
            set_mesh_draw(renderer, false, true);
        } else {
            set_mesh_draw(renderer, m_mat_set_enable, true);
        }
        return;
    }
    if (fullhide_go && (m_fp_only || m_scope_body_hide)) {
        for (int mi = 0; mi < mcount; ++mi) {
            const auto nm = mat_name(renderer, mi);
            set_mat(renderer, mi, !EXTRA.count(nm));
        }
        set_mesh_draw(renderer, false, true);
        return;
    }
    set_mesh_draw(renderer, true, std::nullopt);
    for (int mi = 0; mi < mcount; ++mi) {
        const auto name = mat_name(renderer, mi);
        const bool is_hh = m_hide_materials && m_hide_materials->count(name);
        if (EXTRA.count(name)) {
            set_mat(renderer, mi, true);
        } else if (fullhide_go) {
            bool enable = true;
            if (m_fp_only || m_scope_body_hide) {
                enable = false;
            } else if (is_hh) {
                enable = m_mat_set_enable;
            }
            set_mat(renderer, mi, enable);
        } else if (is_hh) {
            set_mat(renderer, mi, m_mat_set_enable);
        }
    }
}

void RE4VRMaterials::process_go(::REGameObject* go, bool in_weapon) {
    if (!go) {
        return;
    }
    const auto nm = re4vr::go_name((::REManagedObject*)go);
    auto* mesh = m_t_mesh ? re4vr::safe([&] {
        return sdk::call_object_func_easy<::REManagedObject*>(go, "getComponent(System.Type)", m_t_mesh);
    }).value_or(nullptr) : nullptr;
    if (m_holster_hide && nm.rfind("vr_holster_", 0) == 0) {
        if (mesh) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "set_DrawDefault", false); });
        }
        return;
    }
    if (in_weapon) {
        const bool want = !m_fp_only;
        if (mesh) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "set_DrawDefault", want); });
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "set_DrawShadowCast", true); });
        }
        return;
    }
    static const std::unordered_set<std::string> FULLHIDE{
        "body", "body_armor", "headhair", "cloth", "cha200_00", "cha200_10", "cha200_20",
        "sm61_342_00", "HookShot_Rope", "HookShot_Gun",
    };
    std::string lower = nm;
    std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) { return (char)std::tolower(c); });
    const bool fullhide_go = m_fp_only || m_scope_body_hide || FULLHIDE.count(lower);
    if (mesh) {
        hide_mats_on(mesh, fullhide_go);
    }
}

void RE4VRMaterials::start_walk(::RETransform* root) {
    m_walk_stack.clear();
    m_walk_active = false;
    if (!root) {
        return;
    }
    m_walk_stack.push_back(WalkItem{root, false});
    m_walk_active = true;
}

void RE4VRMaterials::walk_chunk() {
    if (!m_walk_active || m_walk_stack.empty()) {
        m_walk_active = false;
        return;
    }
    int processed = 0;
    while (!m_walk_stack.empty() && processed < 12) {
        ++processed;
        auto item = m_walk_stack.back();
        m_walk_stack.pop_back();
        auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(item.tf, "get_GameObject"); }).value_or(nullptr);
        bool here_weapon = item.weapon;
        if (!here_weapon && go) {
            const auto nm = re4vr::go_name((::REManagedObject*)go);
            here_weapon = nm.size() >= 3 && nm.compare(0, 2, "wp") == 0 && std::isdigit((unsigned char)nm[2]);
        }
        if (go) {
            process_go(go, here_weapon);
        }
        std::vector<::RETransform*> kids;
        auto* child = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(item.tf, "get_Child"); }).value_or(nullptr);
        while (child) {
            kids.push_back(child);
            child = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(child, "get_Next"); }).value_or(nullptr);
        }
        for (auto it = kids.rbegin(); it != kids.rend(); ++it) {
            m_walk_stack.push_back(WalkItem{*it, here_weapon});
        }
    }
}

bool RE4VRMaterials::extra_mats_alive() {
    if (m_extra_mats.empty()) {
        return false;
    }
    for (const auto& e : m_extra_mats) {
        bool ok = false;
        re4vr::pcall([&] {
            auto* go = sdk::call_object_func_easy<::REGameObject*>(e.mesh, "get_GameObject");
            ok = go && mat_name(e.mesh, e.idx) == e.name;
        });
        if (!ok) {
            return false;
        }
    }
    for (auto* f : m_extra_furs) {
        bool ok = false;
        re4vr::pcall([&] { ok = sdk::call_object_func_easy<::REGameObject*>(f, "get_GameObject") != nullptr; });
        if (!ok) {
            return false;
        }
    }
    return true;
}

void RE4VRMaterials::scan_extra_mats() {
    if (!m_extra_mats.empty() && !extra_mats_alive()) {
        m_extra_mats.clear();
        m_extra_furs.clear();
        m_extra_mats_off = false;
        m_extra_scan_t = 0;
    }
    if (!m_extra_mats.empty()) {
        return;
    }
    const double now = re4vr::lua_os_clock();
    if ((now - m_extra_scan_t) < 5.0) {
        return;
    }
    m_extra_scan_t = now;
    auto* scene = re4vr::current_scene();
    if (!scene || !m_t_mesh) {
        return;
    }
    auto* arr = re4vr::safe([&] {
        return sdk::call_object_func_easy<sdk::SystemArray*>(scene, "findComponents(System.Type)", m_t_mesh);
    }).value_or(nullptr);
    if (!arr) {
        return;
    }
    static const std::unordered_set<std::string> EXTRA{"JacketFur_Mat", "Jacket_Mat"};
    const auto n = arr->get_size();
    for (int i = 0; i < n; ++i) {
        auto* mesh = arr->get_element(i);
        if (!mesh) {
            continue;
        }
        const int mc = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(mesh, "get_MaterialNum"); }).value_or(0);
        for (int mi = 0; mi < mc; ++mi) {
            const auto mn = mat_name(mesh, mi);
            if (EXTRA.count(mn)) {
                m_extra_mats.push_back(ExtraMat{mesh, mi, mn});
            }
        }
    }
    if (!m_extra_mats.empty() && m_extra_furs.empty()) {
        auto take = [&](::REManagedObject* go) {
            if (!go) {
                return;
            }
            for (auto* t : {m_t_fur, m_t_shellfur}) {
                if (!t) {
                    continue;
                }
                auto* c = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(go, "getComponent(System.Type)", t); }).value_or(nullptr);
                if (c) {
                    m_extra_furs.push_back(c);
                }
            }
        };
        for (const auto& e : m_extra_mats) {
            auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(e.mesh, "get_GameObject"); }).value_or(nullptr);
            take((::REManagedObject*)go);
            auto* tf = go ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr) : nullptr;
            if (tf) {
                auto* par = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(tf, "get_Parent"); }).value_or(nullptr);
                auto* pgo = par ? re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(par, "get_GameObject"); }).value_or(nullptr) : nullptr;
                take((::REManagedObject*)pgo);
                auto* ch = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(tf, "get_Child"); }).value_or(nullptr);
                while (ch) {
                    auto* cgo = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(ch, "get_GameObject"); }).value_or(nullptr);
                    take((::REManagedObject*)cgo);
                    ch = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(ch, "get_Next"); }).value_or(nullptr);
                }
            }
        }
    }
}

void RE4VRMaterials::apply_extra_mats(bool off) {
    if (m_extra_mats.empty()) {
        return;
    }
    for (const auto& e : m_extra_mats) {
        bool ok = true;
        re4vr::pcall([&] { set_mat(e.mesh, e.idx, !off); });
        (void)ok;
    }
    for (auto* f : m_extra_furs) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(f, "set_DrawDefault", !off); });
        if (off) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(f, "set_DrawShadowCast", true); });
        }
    }
    m_extra_mats_off = off;
}

void RE4VRMaterials::gondola_set_tree(::RETransform* tf, bool enable) {
    if (!tf) {
        return;
    }
    auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(tf, "get_GameObject"); }).value_or(nullptr);
    auto* mesh = (go && m_t_mesh) ? re4vr::safe([&] {
        return sdk::call_object_func_easy<::REManagedObject*>(go, "getComponent(System.Type)", m_t_mesh);
    }).value_or(nullptr) : nullptr;
    if (mesh) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "set_Enabled", enable); });
        if (enable) {
            m_gondola_hidden.erase(mesh);
        } else {
            m_gondola_hidden.insert(mesh);
        }
    }
    auto* child = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(tf, "get_Child"); }).value_or(nullptr);
    while (child) {
        gondola_set_tree(child, enable);
        child = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(child, "get_Next"); }).value_or(nullptr);
    }
}

void RE4VRMaterials::gondola_unhide() {
    for (auto* mesh : m_gondola_hidden) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "set_Enabled", true); });
    }
    m_gondola_hidden.clear();
}

void RE4VRMaterials::gondola_tick() {
    const double now = re4vr::lua_os_clock();
    if (now < m_gondola_next_t) {
        return;
    }
    m_gondola_next_t = now + 1.0;
    auto* ctx = re4vr::player_context();
    const auto st = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(ctx, "get_CurrentStageID"); }) : std::nullopt;
    if (st && *st == 60850 && m_gondola_hide) {
        auto* gm = sdk::get_managed_singleton<::REManagedObject>("chainsaw.GimmickManager");
        auto* arrp = gm ? sdk::get_object_field<::REManagedObject*>(gm, "_MoveArray") : nullptr;
        auto* arr = arrp ? *arrp : nullptr;
        if (!arr) {
            return;
        }
        const int n = (int)((sdk::SystemArray*)arr)->get_size();
        for (int i = 0; i < n; ++i) {
            auto* core = ((sdk::SystemArray*)arr)->get_element(i);
            auto* go = core ? re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(core, "get_GameObject"); }).value_or(nullptr) : nullptr;
            const auto nm = re4vr::go_name((::REManagedObject*)go);
            if (nm.find("gm81_303_00_0_") != std::string::npos && nm.find("PLGondola") == std::string::npos) {
                auto* tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr);
                gondola_set_tree(tf, false);
            }
        }
    } else if (!m_gondola_hidden.empty()) {
        gondola_unhide();
    }
}

std::optional<std::string> RE4VRMaterials::on_initialize() {
    fill_leon(m_hide_leon);
    fill_ashley(m_hide_ashley);
    fill_ada(m_hide_ada);
    m_hide_materials = &m_hide_leon;
    load_json();
    if (auto* td = sdk::find_type_definition("via.render.Mesh")) {
        m_t_mesh = td->get_runtime_type();
    }
    if (auto* td = sdk::find_type_definition("via.render.Fur")) {
        m_t_fur = td->get_runtime_type();
    }
    if (auto* td = sdk::find_type_definition("via.render.ShellFurMesh")) {
        m_t_shellfur = td->get_runtime_type();
    }
    if (auto* td = sdk::find_type_definition("chainsaw.OilLampController")) {
        m_t_oillamp = td->get_runtime_type();
    }
    return std::nullopt;
}

void RE4VRMaterials::on_lua_state_destroyed(sol::state&) {
    gondola_unhide();
    m_cached_body = nullptr;
}

void RE4VRMaterials::on_frame() {
    ScriptProfileGuard guard("re4_vr_materials.lua", "on_frame", re4vr::profile_frame());
    gondola_tick();
    const bool ks2 = re4vr::call_killswitch_bool("is_ks2");
    const bool ks3 = re4vr::call_killswitch_bool("is_ks3");
    const bool ks4 = re4vr::call_killswitch_bool("is_ks4");
    const bool ks5 = re4vr::call_killswitch_bool("is_ks5");

    auto* body = get_body_go();
    m_cached_body = body;
    if (body) {
        const auto bname = re4vr::go_name((::REManagedObject*)body);
        if (bname == "ch0a1z0_body") {
            m_hide_materials = &m_hide_ashley;
        } else if (bname == "ch3a8z0_body") {
            m_hide_materials = &m_hide_ada;
        } else {
            m_hide_materials = &m_hide_leon;
        }
    }

    m_fp_only = ks3 || ks5;
    m_holster_hide = ks4;
    if (re4vr::lua_is_true("__re4_throwsight_active")) {
        m_fp_only = true;
    }
    if (ks4 && re4vr::lua_is_true("__re4_railcar_mode")) {
        auto st = re4vr::call_killswitch_number("get_stage_name");
        if (!st) {
            if (auto s = re4vr::call_killswitch_string("get_stage_name")) {
                try {
                    st = std::stod(*s);
                } catch (...) {
                }
            }
        }
        if (st && *st == 55300.0) {
            m_fp_only = true;
        }
    }
    if (re4vr::lua_is_true("__re4_evt60874_fullhide") && re4vr::lua_not_false("__re4_ks_fp_enabled")) {
        m_fp_only = true;
    }
    if (ks4 && re4vr::lua_not_false("__re4_ks_fp_enabled")) {
        auto st = re4vr::call_killswitch_number("get_stage_name");
        auto rs = re4vr::call_killswitch_string("get_activating_controller");
        if (st && *st == 60880.0 && rs && *rs == "ks3_gimmick" && body) {
            auto* btf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(body, "get_Transform"); }).value_or(nullptr);
            if (btf) {
                const auto p = sdk::get_transform_position(btf);
                const float dx = p.x - 64.33f, dy = p.y - (-3.66f), dz = p.z - 237.35f;
                if (dx * dx + dy * dy + dz * dz <= 36.0f) {
                    m_fp_only = true;
                }
            }
        }
    }
    m_scope_body_hide = re4vr::lua_is_true("__re4_force_killswitch_scope");
    if (m_fp_only || m_scope_body_hide) {
        scan_extra_mats();
    }
    apply_extra_mats(m_fp_only || m_scope_body_hide);
    m_mat_set_enable = re4vr::call_killswitch_bool("is_active") && !ks2 && !ks3 && !ks4 && !ks5;

    auto fl_mesh_now = [&]() -> ::REManagedObject* {
        if (auto* flm = re4vr::lua_object("__re4_fl_mesh")) {
            return flm;
        }
        auto* scene = re4vr::current_scene();
        if (!scene) {
            return nullptr;
        }
        auto* s = sdk::VM::create_managed_string(utility::widen("ch0a0z0_body"));
        auto* b = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(scene, "findGameObject(System.String)", s); }).value_or(nullptr);
        if (!b) {
            return nullptr;
        }
        auto* tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(b, "get_Transform"); }).value_or(nullptr);
        auto* child = tf ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(tf, "get_Child"); }).value_or(nullptr) : nullptr;
        while (child) {
            auto* cgo = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(child, "get_GameObject"); }).value_or(nullptr);
            if (re4vr::go_name((::REManagedObject*)cgo) == "ac0000_00") {
                m_fl_go = cgo;
                return m_t_mesh ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(cgo, "getComponent(System.Type)", m_t_mesh); }).value_or(nullptr) : nullptr;
            }
            child = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(child, "get_Next"); }).value_or(nullptr);
        }
        return nullptr;
    };

    if (ks3 || ks5) {
        if (auto* flm = fl_mesh_now()) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(flm, "set_Enabled", false); });
            m_fl_hidden = true;
        }
        if (m_t_oillamp) {
            auto* scene = re4vr::current_scene();
            auto* arr = scene ? re4vr::safe([&] {
                return sdk::call_object_func_easy<sdk::SystemArray*>(scene, "findComponents(System.Type)", m_t_oillamp);
            }).value_or(nullptr) : nullptr;
            if (arr && arr->get_size() > 0) {
                auto* lamp = arr->get_element(0);
                auto* lgo = lamp ? re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(lamp, "get_GameObject"); }).value_or(nullptr) : nullptr;
                m_lamp_go = lgo;
                auto* mesh = (lgo && m_t_mesh) ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(lgo, "getComponent(System.Type)", m_t_mesh); }).value_or(nullptr) : nullptr;
                if (mesh) {
                    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "set_Enabled", false); });
                    m_lamp_hidden = true;
                }
            }
        }
    } else {
        if (m_fl_hidden) {
            if (auto* flm = fl_mesh_now()) {
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(flm, "set_Enabled", true); });
            }
            m_fl_hidden = false;
        }
        if (m_lamp_hidden && m_lamp_go && m_t_mesh) {
            auto* mesh = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(m_lamp_go, "getComponent(System.Type)", m_t_mesh); }).value_or(nullptr);
            if (mesh) {
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "set_Enabled", true); });
            }
            m_lamp_hidden = false;
        }
    }

    if (!body) {
        return;
    }
    auto* tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(body, "get_Transform"); }).value_or(nullptr);
    if (!tf) {
        return;
    }
    const double now = re4vr::lua_os_clock();
    const double delta = m_last_time > 0.0 ? (now - m_last_time) : 0.0;
    m_last_time = now;
    m_refresh_timer += delta;
    if (!m_walk_active || m_refresh_timer >= 2.5) {
        m_refresh_timer = 0;
        start_walk(tf);
    }
    walk_chunk();
}
#endif
