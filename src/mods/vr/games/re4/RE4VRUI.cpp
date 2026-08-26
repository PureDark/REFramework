#define NOMINMAX
#include "RE4VRUI.hpp"

#if defined(RE4)
#include <regex>

#include <sdk/RETypeDB.hpp>
#include <sdk/REString.hpp>
#include <utility/String.hpp>

#include "RE4VRScope.hpp"
#include "RE4VRShared.hpp"
#include "../../../ScriptRunner.hpp"

namespace {
struct GlueLayer {
    const char* name{};
    int order{0};
};
const GlueLayer GLUE_LAYERS[] = {
    {"Gui_ui3120", 0},
    {"Gui_ui3121", 1},
    {"Gui_ui3140", 2},
    {"Gui_ui3141", 3},
    {"Gui_ui3104", 4},
    {"Gui_ui3103", 5},
    {"Gui_ui3101", 6},
    {"Gui_ui3100", 7},
};
constexpr const char* BINO_GUI = "Gui_ui2110";
constexpr double BINO_SEEN_SEC = 0.25;
}

std::shared_ptr<RE4VRUI>& RE4VRUI::get() {
    static auto inst = std::make_shared<RE4VRUI>();
    return inst;
}

void RE4VRUI::load_json() {
    const auto d = re4vr::load_json_file("re4_vr/re4_vr_ui.json");
    if (d.empty()) {
        return;
    }
    m_opt.gui_matrix = re4vr::j_bool(d, "gui_matrix", m_opt.gui_matrix);
    m_opt.gui_elem = re4vr::j_bool(d, "gui_elem", m_opt.gui_elem);
    m_opt.mono = re4vr::j_bool(d, "mono", m_opt.mono);
    m_opt.canvas = re4vr::j_bool(d, "canvas", m_opt.canvas);
    m_opt.suspend = re4vr::j_bool(d, "suspend", m_opt.suspend);
    m_opt.mapglue = re4vr::j_bool(d, "mapglue", m_opt.mapglue);
    m_opt.binoglue = re4vr::j_bool(d, "binoglue", m_opt.binoglue);
    m_glue_distance = re4vr::j_num(d, "glue_distance", m_glue_distance);
    m_glue_gap = re4vr::j_num(d, "glue_gap", m_glue_gap);
    m_bino_distance = re4vr::j_num(d, "bino_distance", m_bino_distance);
    m_canvas_width = re4vr::j_num(d, "canvas_width", m_canvas_width);
    m_canvas_distance = re4vr::j_num(d, "canvas_distance", m_canvas_distance);
    m_ptr_pitch = re4vr::j_num(d, "ptr_pitch", m_ptr_pitch);
    m_ui3101_scale = re4vr::j_num(d, "ui3101_scale", m_ui3101_scale);
    m_hide_3121 = re4vr::j_bool(d, "hide_3121", m_hide_3121);
    m_hide_bg = re4vr::j_bool(d, "hide_bg", m_hide_bg);
    if (d.contains("global_hide") && d["global_hide"].is_object()) {
        for (auto it = d["global_hide"].begin(); it != d["global_hide"].end(); ++it) {
            if (m_global_hide.count(it.key()) && it.value().is_boolean()) {
                m_global_hide[it.key()] = it.value().get<bool>();
            }
        }
    }
    if (d.contains("map_hide") && d["map_hide"].is_object()) {
        for (auto it = d["map_hide"].begin(); it != d["map_hide"].end(); ++it) {
            if (m_map_hide.count(it.key()) && it.value().is_boolean()) {
                m_map_hide[it.key()] = it.value().get<bool>();
            }
        }
    }
    if (d.contains("glue_on") && d["glue_on"].is_object()) {
        for (auto it = d["glue_on"].begin(); it != d["glue_on"].end(); ++it) {
            if (it.value().is_boolean()) {
                m_glue_on[it.key()] = it.value().get<bool>();
            }
        }
    }
    if (re4vr::j_bool(d, "viewtype", false)) {
        for (auto& [k, v] : m_vt_on) {
            v = true;
        }
    }
    if (d.contains("vt_on") && d["vt_on"].is_object()) {
        for (auto it = d["vt_on"].begin(); it != d["vt_on"].end(); ++it) {
            if (m_vt_on.count(it.key()) && it.value().is_boolean()) {
                m_vt_on[it.key()] = it.value().get<bool>();
            }
        }
    }
}

void RE4VRUI::save_json() {
    nlohmann::json out;
    out["gui_matrix"] = m_opt.gui_matrix;
    out["gui_elem"] = m_opt.gui_elem;
    out["mono"] = m_opt.mono;
    out["canvas"] = m_opt.canvas;
    out["suspend"] = m_opt.suspend;
    out["mapglue"] = m_opt.mapglue;
    out["binoglue"] = m_opt.binoglue;
    out["glue_distance"] = m_glue_distance;
    out["glue_gap"] = m_glue_gap;
    out["bino_distance"] = m_bino_distance;
    out["glue_on"] = m_glue_on;
    out["map_hide"] = m_map_hide;
    out["vt_on"] = m_vt_on;
    out["canvas_width"] = m_canvas_width;
    out["canvas_distance"] = m_canvas_distance;
    out["hide_3121"] = m_hide_3121;
    out["hide_bg"] = m_hide_bg;
    out["global_hide"] = m_global_hide;
    out["ui3101_scale"] = m_ui3101_scale;
    out["ptr_pitch"] = m_ptr_pitch;
    re4vr::save_json_file("re4_vr/re4_vr_ui.json", out);
}

bool RE4VRUI::is_supported() {
    if (m_supported) {
        return *m_supported;
    }
    m_supported = true;
    return true;
}

void RE4VRUI::apply_override(bool want) {
    if (want == m_applied) {
        return;
    }
    re4vr::pcall([&] { VR::get()->set_gui_projection_matrix_override_disabled(want); });
    m_applied = want;
}

void RE4VRUI::apply_elem(bool want) {
    if (!m_elem_supported) {
        m_elem_supported = true;
    }
    if (want == m_elem) {
        return;
    }
    re4vr::pcall([&] { VR::get()->set_gui_element_override_disabled(want); });
    m_elem = want;
}

void RE4VRUI::apply_mono(bool want) {
    m_mono = want;
    RE4VRScope::get()->mono_request("map", m_mono);
}

void RE4VRUI::apply_canvas(bool want) {
    if (!re4vr::lua_is_true("__re4_fork_canvas") && !re4vr::lua_not_false("__re4_fork_canvas")) {
        // still try: builtin fork always has canvas
    }
    if (want == m_canvas) {
        return;
    }
    re4vr::pcall([&] { VR::get()->set_flatscreen_overlay(want); });
    m_canvas = want;
    if (want) {
        re4vr::pcall([&] {
            VR::get()->set_flatscreen_overlay_width(m_canvas_width);
            VR::get()->set_flatscreen_overlay_distance(m_canvas_distance);
        });
    }
}

void RE4VRUI::apply_suspend(bool want) {
    if (!m_suspend_supported) {
        m_suspend_supported = true;
    }
    if (want == m_suspend) {
        return;
    }
    re4vr::pcall([&] { VR::get()->set_vr_suspended(want); });
    m_suspend = want;
}

void RE4VRUI::apply_mapglue(bool want) {
    if (!m_glue_supported) {
        m_glue_supported = true;
    }
    if (want == m_mapglue) {
        return;
    }
    re4vr::pcall([&] { VR::get()->set_map_face_glue(want); });
    m_mapglue = want;
    if (want) {
        re4vr::pcall([&] { VR::get()->set_map_glue_distance(m_glue_distance); });
    }
}

void RE4VRUI::push_glue_layers() {
    auto& vr = VR::get();
    for (const auto& g : GLUE_LAYERS) {
        const bool on = m_glue_on.count(g.name) ? m_glue_on[g.name] : true;
        if (on) {
            vr->set_glue_gui_hash(utility::hash(std::string{g.name}), g.order);
        } else {
            vr->remove_glue_gui_hash(utility::hash(std::string{g.name}));
        }
    }
}

void RE4VRUI::apply_ptr_pitch() {
    if (m_ptr_pitch_ok == false) {
        return;
    }
    if (!m_ptr_pitch_ok) {
        m_ptr_pitch_ok = true;
    }
    if (m_ptr_pitch_sent && *m_ptr_pitch_sent == m_ptr_pitch) {
        return;
    }
    re4vr::pcall([&] { VR::get()->set_overlay_pointer_pitch(m_ptr_pitch); });
    m_ptr_pitch_sent = m_ptr_pitch;
}

bool RE4VRUI::is_map_gui_open() {
    if (!re4vr::obj_ok(m_map_manager)) {
        m_map_manager = sdk::get_managed_singleton<::REManagedObject>("chainsaw.MapManager");
    }
    if (!m_map_manager) {
        return false;
    }
    auto open = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_map_manager, "isMapGuiOpen"); });
    if (!open) {
        m_map_manager = nullptr;
        return false;
    }
    return *open;
}

bool RE4VRUI::is_inventory_open() {
    if (!re4vr::obj_ok(m_case_manager)) {
        m_case_manager = sdk::get_managed_singleton<::REManagedObject>("chainsaw.AttacheCaseManager");
    }
    if (!m_case_manager) {
        return false;
    }
    auto busy = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_case_manager, "get_IsAttacheCaseBusy"); });
    if (!busy) {
        m_case_manager = nullptr;
        return false;
    }
    return *busy;
}

bool RE4VRUI::is_main_menu_open() {
    if (m_map_open || m_inv_open) {
        return false;
    }
    if (!re4vr::obj_ok(m_gui_manager)) {
        m_gui_manager = sdk::get_managed_singleton<::REManagedObject>("chainsaw.GuiManager");
    }
    if (!m_gui_manager) {
        return false;
    }
    auto locked = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_gui_manager, "get_hasOccupiedPauseMenuSystemLock"); });
    if (!locked) {
        m_gui_manager = nullptr;
        return false;
    }
    return *locked;
}

::REManagedObject* RE4VRUI::gui_view(::REManagedObject* go) {
    auto* comp = re4vr::get_component(go, "via.gui.GUI");
    if (!comp) {
        return nullptr;
    }
    return re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(comp, "get_View"); }).value_or(nullptr);
}

::REManagedObject* RE4VRUI::gui_root_control(::REManagedObject* go) {
    auto* view = gui_view(go);
    if (!view) {
        return nullptr;
    }
    return re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(view, "get_Child"); }).value_or(nullptr);
}

bool RE4VRUI::force_viewtype(::REManagedObject* go, const std::string& name) {
    auto it = m_vt_force.find(name);
    if (it == m_vt_force.end()) {
        return false;
    }
    if (auto* view = gui_view(go)) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(view, "set_ViewType", it->second); });
    }
    m_vt_orig.erase(name);
    m_vt_force.erase(it);
    return true;
}

void RE4VRUI::apply_viewtype(::REManagedObject* go, const std::string& name, bool want) {
    auto* view = gui_view(go);
    if (!view) {
        m_vt_seen[name] = "keine View";
        return;
    }
    auto cur = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(view, "get_ViewType"); });
    if (!cur) {
        m_vt_seen[name] = "kein ViewType";
        return;
    }
    m_vt_seen[name] = std::to_string(*cur);
    constexpr int32_t VIEWTYPE_SCREEN = 0;
    if (want) {
        if (!m_vt_orig.count(name)) {
            m_vt_orig[name] = *cur;
        }
        if (*cur != VIEWTYPE_SCREEN) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(view, "set_ViewType", VIEWTYPE_SCREEN); });
        }
    } else if (m_vt_orig.count(name)) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(view, "set_ViewType", m_vt_orig[name]); });
        m_vt_orig.erase(name);
    }
}

std::optional<std::string> RE4VRUI::on_initialize() {
    load_json();
    for (const auto& g : GLUE_LAYERS) {
        if (!m_glue_on.count(g.name)) {
            m_glue_on[g.name] = true;
        }
    }
    return std::nullopt;
}

void RE4VRUI::on_lua_state_destroyed(sol::state&) {
    apply_override(false);
    apply_elem(false);
    apply_mono(false);
    apply_canvas(false);
    apply_suspend(false);
    apply_mapglue(false);
    m_map_open = m_inv_open = m_menu_open = false;
    m_map_manager = m_case_manager = m_gui_manager = nullptr;
}

void RE4VRUI::on_frame() {
    ScriptProfileGuard guard("re4_vr_ui.lua", "on_frame", re4vr::profile_frame());
    apply_ptr_pitch();
    const double now = re4vr::lua_os_clock();
    if (m_cfg_dirty_t && (now - *m_cfg_dirty_t) > 0.5) {
        m_cfg_dirty_t.reset();
        save_json();
    }
    if (!is_supported()) {
        return;
    }
    m_map_open = is_map_gui_open();
    m_inv_open = is_inventory_open();
    m_menu_open = is_main_menu_open();

    apply_override(m_map_open && m_opt.gui_matrix);
    apply_elem(m_map_open && m_opt.gui_elem);
    apply_mono(m_map_open && m_opt.mono);
    apply_canvas(m_map_open && m_opt.canvas);
    apply_suspend(m_map_open && m_opt.suspend);

    const bool bino_up = m_opt.binoglue && m_bino_seen_t && (now - *m_bino_seen_t) < BINO_SEEN_SEC;
    const bool map_pin = m_map_open && m_opt.mapglue;
    apply_mapglue(map_pin || bino_up);

    if (m_mapglue) {
        auto& vr = VR::get();
        if (map_pin) {
            re4vr::pcall([&] {
                vr->set_map_glue_distance(m_glue_distance);
                vr->set_map_glue_layer_gap(m_glue_gap);
            });
            push_glue_layers();
            vr->remove_glue_gui_hash(utility::hash(std::string{BINO_GUI}));
        } else {
            re4vr::pcall([&] { vr->set_map_glue_distance(m_bino_distance); });
            vr->set_glue_gui_hash(utility::hash(std::string{BINO_GUI}), 0);
        }
    }

    if (m_canvas) {
        re4vr::pcall([&] {
            VR::get()->set_flatscreen_overlay_width(m_canvas_width);
            VR::get()->set_flatscreen_overlay_distance(m_canvas_distance);
        });
    }
}

bool RE4VRUI::on_pre_gui_draw_element(REComponent* gui_element, void*) {
    if (!gui_element) {
        return true;
    }
    ScriptProfileGuard guard("re4_vr_ui.lua", "on_pre_gui_draw_element", re4vr::profile_frame());
    auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(gui_element, "get_GameObject"); }).value_or(nullptr);
    if (!go) {
        return true;
    }
    const auto name = re4vr::go_name((::REManagedObject*)go);
    if (name.empty()) {
        return true;
    }

    static const std::unordered_map<std::string, std::string> GLOBAL_GUIS{
        {"Gui_ui2041", "hide_dot"},
        {"Gui_ui2152", "hide_vignette"},
        {"Gui_ui2151", "hide_vignette2"},
    };
    if (auto it = GLOBAL_GUIS.find(name); it != GLOBAL_GUIS.end()) {
        auto h = m_global_hide.find(it->second);
        return !(h != m_global_hide.end() && h->second);
    }

    if (name == BINO_GUI) {
        m_bino_seen_t = re4vr::lua_os_clock();
    }

    if (m_map_open && m_opt.mapglue && !m_glue_auto.count(name)) {
        static const std::regex map_re{"^Gui_ui31\\d\\d$"};
        if (std::regex_match(name, map_re)) {
            m_glue_auto.insert(name);
        }
    }

    if (!force_viewtype((::REManagedObject*)go, name)) {
        if (name == "Gui_ui3120") {
            apply_viewtype((::REManagedObject*)go, name, m_map_open && m_vt_on["vt_3120"]);
        }
    }

    if (!(m_map_open || m_inv_open || m_menu_open)) {
        return true;
    }

    if (name == "AcBackGround") {
        if (m_map_open || m_inv_open) {
            return !m_hide_bg;
        }
        return true;
    }
    if (name == "Gui_ui0502" || name == "Gui_ui0501") {
        return !m_menu_open;
    }
    if (!m_map_open) {
        return true;
    }
    if (auto it = m_map_hide.find(name); it != m_map_hide.end() && it->second) {
        return false;
    }
    if (name == "Gui_ui3121") {
        return !m_hide_3121;
    }
    if (name == "Gui_ui3101") {
        if (auto* ctrl = gui_root_control((::REManagedObject*)go)) {
            re4vr::pcall([&] {
                sdk::call_object_func_easy<void*>(ctrl, "set_Scale", Vector3f{m_ui3101_scale, m_ui3101_scale, m_ui3101_scale});
            });
        }
    }
    return true;
}
#endif
