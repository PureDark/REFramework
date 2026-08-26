#define NOMINMAX
#include "RE4VRScope.hpp"

#if defined(RE4)
#include <algorithm>
#include <cmath>
#include <unordered_set>

#include <glm/gtc/constants.hpp>
#include <glm/gtx/quaternion.hpp>
#include <sdk/RETypeDB.hpp>
#include <sdk/RETransform.hpp>
#include <sdk/SceneManager.hpp>
#include <sdk/MurmurHash.hpp>
#include <sdk/Application.hpp>
#include <spdlog/spdlog.h>

#include "RE4VRShared.hpp"
#include "../../../ScriptRunner.hpp"

namespace {
constexpr float PLATEAU = 3.0f;
const std::unordered_set<uint32_t> BOLT_MUTE_IDS{
    748483445u, 1477056167u, 1441789338u, 2498172228u, 1357901439u, 2086827955u, 1545855344u,
};

RE4VRScope::Keyframe kf_from_json(const nlohmann::json& e) {
    RE4VRScope::Keyframe k{};
    k.deg = re4vr::j_num(e, "deg", 0.0f);
    k.x = re4vr::j_num(e, "x", 0.0f);
    k.y = re4vr::j_num(e, "y", 0.0f);
    k.z = re4vr::j_num(e, "z", 0.0f);
    k.zoom = re4vr::j_num(e, "zoom", 1.0f);
    return k;
}

std::vector<RE4VRScope::Keyframe> clean_list(const nlohmann::json& src) {
    std::vector<RE4VRScope::Keyframe> out;
    if (!src.is_array()) {
        return out;
    }
    for (const auto& e : src) {
        if (!e.is_object() || !e.contains("deg") || !e["deg"].is_number()) {
            continue;
        }
        out.push_back(kf_from_json(e));
    }
    std::sort(out.begin(), out.end(), [](const auto& a, const auto& b) { return a.deg < b.deg; });
    return out;
}

nlohmann::json kf_to_json(const RE4VRScope::Keyframe& k) {
    return nlohmann::json{{"deg", k.deg}, {"x", k.x}, {"y", k.y}, {"z", k.z}, {"zoom", k.zoom}};
}
}

std::shared_ptr<RE4VRScope>& RE4VRScope::get() {
    static auto inst = std::make_shared<RE4VRScope>();
    return inst;
}

void RE4VRScope::load_json() {
    auto d = re4vr::load_json_file("re4_vr/re4_vr_scope.json");
    if (d.empty()) {
        return;
    }
    m_cfg.mono = re4vr::j_bool(d, "mono", m_cfg.mono);
    m_cfg.mono_manual = re4vr::j_bool(d, "mono_manual", m_cfg.mono_manual);
    m_cfg.proj_off = re4vr::j_bool(d, "proj_off", m_cfg.proj_off);
    m_cfg.view_off = re4vr::j_bool(d, "view_off", m_cfg.view_off);
    m_cfg.zoom = re4vr::j_num(d, "zoom", m_cfg.zoom);
    m_cfg.fov = re4vr::j_num(d, "fov", m_cfg.fov);
    m_cfg.blank_eye = (int)re4vr::j_num(d, "blank_eye", (float)m_cfg.blank_eye);
    m_cfg.blank_eye_xr = (int)re4vr::j_num(d, "blank_eye_xr", (float)m_cfg.blank_eye_xr);
    m_cfg.xr_dx = re4vr::j_num(d, "xr_dx", m_cfg.xr_dx);
    m_cfg.xr_dy = re4vr::j_num(d, "xr_dy", m_cfg.xr_dy);
    m_cfg.zoom_x = re4vr::j_num(d, "zoom_x", m_cfg.zoom_x);
    m_cfg.zoom_x_bow = re4vr::j_num(d, "zoom_x_bow", m_cfg.zoom_x_bow);
    m_cfg.pitch_y = re4vr::j_num(d, "pitch_y", m_cfg.pitch_y);
    m_cfg.pitch_y_deg = re4vr::j_num(d, "pitch_y_deg", m_cfg.pitch_y_deg);
    m_cfg.pitch_y_pow = re4vr::j_num(d, "pitch_y_pow", m_cfg.pitch_y_pow);
    m_cfg.pitch_y_ada = re4vr::j_num(d, "pitch_y_ada", m_cfg.pitch_y_ada);
    m_cfg.pitch_y_deg_ada = re4vr::j_num(d, "pitch_y_deg_ada", m_cfg.pitch_y_deg_ada);
    m_cfg.pitch_y_pow_ada = re4vr::j_num(d, "pitch_y_pow_ada", m_cfg.pitch_y_pow_ada);
    m_cfg.pitch_y_ada_migrated = re4vr::j_bool(d, "pitch_y_ada_migrated", m_cfg.pitch_y_ada_migrated);
    m_cfg.zoom_y = re4vr::j_num(d, "zoom_y", m_cfg.zoom_y);
    m_cfg.mono_proj = re4vr::j_bool(d, "mono_proj", m_cfg.mono_proj);
    m_cfg.img_x = re4vr::j_num(d, "img_x", m_cfg.img_x);
    m_cfg.img_y = re4vr::j_num(d, "img_y", m_cfg.img_y);
    m_cfg.cam_x = re4vr::j_num(d, "cam_x", m_cfg.cam_x);
    m_cfg.cam_y = re4vr::j_num(d, "cam_y", m_cfg.cam_y);
    m_cfg.cam_z = re4vr::j_num(d, "cam_z", m_cfg.cam_z);
    m_cfg.kfs_migrated = re4vr::j_bool(d, "kfs_migrated", m_cfg.kfs_migrated);
    m_cfg.live = re4vr::j_bool(d, "live", m_cfg.live);
    m_cfg.mid_y = re4vr::j_num(d, "mid_y", m_cfg.mid_y);
    m_cfg.mid_z = re4vr::j_num(d, "mid_z", m_cfg.mid_z);
    m_cfg.up_y = re4vr::j_num(d, "up_y", m_cfg.up_y);
    m_cfg.up_z = re4vr::j_num(d, "up_z", m_cfg.up_z);
    m_cfg.dn_y = re4vr::j_num(d, "dn_y", m_cfg.dn_y);
    m_cfg.dn_z = re4vr::j_num(d, "dn_z", m_cfg.dn_z);
    m_cfg.um_y = re4vr::j_num(d, "um_y", m_cfg.um_y);
    m_cfg.um_z = re4vr::j_num(d, "um_z", m_cfg.um_z);
    m_cfg.dm_y = re4vr::j_num(d, "dm_y", m_cfg.dm_y);
    m_cfg.dm_z = re4vr::j_num(d, "dm_z", m_cfg.dm_z);
    m_cfg.um_on = re4vr::j_bool(d, "um_on", m_cfg.um_on);
    m_cfg.dm_on = re4vr::j_bool(d, "dm_on", m_cfg.dm_on);
    m_cfg.mid_t = re4vr::j_num(d, "mid_t", m_cfg.mid_t);
    m_cfg.pitch_ref = re4vr::j_num(d, "pitch_ref", m_cfg.pitch_ref);
    m_cfg.hold = re4vr::j_num(d, "hold", m_cfg.hold);
    m_cfg.bolt_eye_hold = re4vr::j_num(d, "bolt_eye_hold", m_cfg.bolt_eye_hold);
    m_cfg.bolt_pitch_hold = re4vr::j_num(d, "bolt_pitch_hold", m_cfg.bolt_pitch_hold);
    m_cfg.bolt_reaim = re4vr::j_bool(d, "bolt_reaim", m_cfg.bolt_reaim);
    m_cfg.bolt_mute = re4vr::j_bool(d, "bolt_mute", m_cfg.bolt_mute);
    m_cfg.sens_out = re4vr::j_num(d, "sens_out", m_cfg.sens_out);
    m_cfg.sens_in = re4vr::j_num(d, "sens_in", m_cfg.sens_in);
    m_cfg.stick_zoom = re4vr::j_bool(d, "stick_zoom", m_cfg.stick_zoom);
    m_cfg.zoom_speed = re4vr::j_num(d, "zoom_speed", m_cfg.zoom_speed);
    m_cfg.zoom_min = re4vr::j_num(d, "zoom_min", m_cfg.zoom_min);
    m_cfg.zoom_max = re4vr::j_num(d, "zoom_max", m_cfg.zoom_max);
    m_cfg.bino_bg_scale = re4vr::j_num(d, "bino_bg_scale", m_cfg.bino_bg_scale);

    if (!m_cfg.pitch_y_ada_migrated) {
        m_cfg.pitch_y_ada_migrated = true;
        m_cfg.pitch_y_ada = m_cfg.pitch_y;
        m_cfg.pitch_y_deg_ada = m_cfg.pitch_y_deg;
        m_cfg.pitch_y_pow_ada = m_cfg.pitch_y_pow;
    }

    if (d.contains("pitch_y_ada_sets") && d["pitch_y_ada_sets"].is_object()) {
        for (auto it = d["pitch_y_ada_sets"].begin(); it != d["pitch_y_ada_sets"].end(); ++it) {
            if (!it.value().is_object()) {
                continue;
            }
            AdaY a{};
            a.y = re4vr::j_num(it.value(), "y", m_cfg.pitch_y_ada);
            a.deg = re4vr::j_num(it.value(), "deg", m_cfg.pitch_y_deg_ada);
            a.pow = re4vr::j_num(it.value(), "pow", m_cfg.pitch_y_pow_ada);
            m_cfg.pitch_y_ada_sets[it.key()] = a;
        }
    }

    m_cfg.kfs = clean_list(d.contains("kfs") ? d["kfs"] : nlohmann::json::array());
    m_cfg.kfs_sets.clear();
    if (d.contains("kfs_sets") && d["kfs_sets"].is_object()) {
        for (auto it = d["kfs_sets"].begin(); it != d["kfs_sets"].end(); ++it) {
            m_cfg.kfs_sets[it.key()] = clean_list(it.value());
        }
    }

    for (const char* id : {"normal", "thermal", "hipower", "ironsight"}) {
        auto it = m_cfg.kfs_sets.find(id);
        if (it == m_cfg.kfs_sets.end()) {
            continue;
        }
        const std::string dst = std::string{"4401_"} + id;
        if (!it->second.empty() && m_cfg.kfs_sets[dst].empty()) {
            m_cfg.kfs_sets[dst] = it->second;
        }
        m_cfg.kfs_sets.erase(id);
    }

    auto& sting = m_cfg.kfs_sets["4401_normal"];
    if (!m_cfg.kfs.empty() && sting.empty()) {
        sting = m_cfg.kfs;
        m_cfg.kfs.clear();
    }
    if (sting.empty() && !m_cfg.kfs_migrated) {
        m_cfg.kfs_migrated = true;
        float pr = m_cfg.pitch_ref < 1.0f ? 1.0f : m_cfg.pitch_ref;
        struct Old {
            float deg, y, z;
            bool on;
        };
        const Old old[] = {
            {0.0f, m_cfg.mid_y, m_cfg.mid_z, true},
            {pr, m_cfg.up_y, m_cfg.up_z, true},
            {-pr, m_cfg.dn_y, m_cfg.dn_z, true},
            {pr * m_cfg.mid_t, m_cfg.um_y, m_cfg.um_z, m_cfg.um_on},
            {-pr * m_cfg.mid_t, m_cfg.dm_y, m_cfg.dm_z, m_cfg.dm_on},
        };
        bool any = m_cfg.cam_x != 0.0f;
        for (const auto& o : old) {
            if (o.on && (o.y != 0.0f || o.z != 0.0f)) {
                any = true;
            }
        }
        if (any) {
            for (const auto& o : old) {
                if (o.on) {
                    sting.push_back(Keyframe{o.deg, m_cfg.cam_x, o.y, o.z, 1.0f});
                }
            }
            std::sort(sting.begin(), sting.end(), [](const auto& a, const auto& b) { return a.deg < b.deg; });
        }
    }
}

void RE4VRScope::save_json() {
    nlohmann::json out;
    out["mono"] = m_cfg.mono;
    out["mono_manual"] = m_cfg.mono_manual;
    out["proj_off"] = m_cfg.proj_off;
    out["view_off"] = m_cfg.view_off;
    out["zoom"] = m_cfg.zoom;
    out["fov"] = m_cfg.fov;
    out["blank_eye"] = m_cfg.blank_eye;
    out["blank_eye_xr"] = m_cfg.blank_eye_xr;
    out["xr_dx"] = m_cfg.xr_dx;
    out["xr_dy"] = m_cfg.xr_dy;
    out["zoom_x"] = m_cfg.zoom_x;
    out["zoom_x_bow"] = m_cfg.zoom_x_bow;
    out["pitch_y"] = m_cfg.pitch_y;
    out["pitch_y_deg"] = m_cfg.pitch_y_deg;
    out["pitch_y_pow"] = m_cfg.pitch_y_pow;
    out["pitch_y_ada"] = m_cfg.pitch_y_ada;
    out["pitch_y_deg_ada"] = m_cfg.pitch_y_deg_ada;
    out["pitch_y_pow_ada"] = m_cfg.pitch_y_pow_ada;
    out["pitch_y_ada_migrated"] = m_cfg.pitch_y_ada_migrated;
    nlohmann::json ada_sets = nlohmann::json::object();
    for (const auto& [k, v] : m_cfg.pitch_y_ada_sets) {
        ada_sets[k] = nlohmann::json{{"y", v.y}, {"deg", v.deg}, {"pow", v.pow}};
    }
    out["pitch_y_ada_sets"] = ada_sets;
    out["zoom_y"] = m_cfg.zoom_y;
    out["mono_proj"] = m_cfg.mono_proj;
    out["img_x"] = m_cfg.img_x;
    out["img_y"] = m_cfg.img_y;
    out["cam_x"] = m_cfg.cam_x;
    out["cam_y"] = m_cfg.cam_y;
    out["cam_z"] = m_cfg.cam_z;
    nlohmann::json kfs = nlohmann::json::array();
    for (const auto& k : m_cfg.kfs) {
        kfs.push_back(kf_to_json(k));
    }
    out["kfs"] = kfs;
    nlohmann::json sets = nlohmann::json::object();
    for (const auto& [k, list] : m_cfg.kfs_sets) {
        nlohmann::json arr = nlohmann::json::array();
        for (const auto& e : list) {
            arr.push_back(kf_to_json(e));
        }
        sets[k] = arr;
    }
    out["kfs_sets"] = sets;
    out["kfs_migrated"] = m_cfg.kfs_migrated;
    out["live"] = m_cfg.live;
    out["mid_y"] = m_cfg.mid_y;
    out["mid_z"] = m_cfg.mid_z;
    out["up_y"] = m_cfg.up_y;
    out["up_z"] = m_cfg.up_z;
    out["dn_y"] = m_cfg.dn_y;
    out["dn_z"] = m_cfg.dn_z;
    out["um_y"] = m_cfg.um_y;
    out["um_z"] = m_cfg.um_z;
    out["dm_y"] = m_cfg.dm_y;
    out["dm_z"] = m_cfg.dm_z;
    out["um_on"] = m_cfg.um_on;
    out["dm_on"] = m_cfg.dm_on;
    out["mid_t"] = m_cfg.mid_t;
    out["pitch_ref"] = m_cfg.pitch_ref;
    out["hold"] = m_cfg.hold;
    out["bolt_eye_hold"] = m_cfg.bolt_eye_hold;
    out["bolt_pitch_hold"] = m_cfg.bolt_pitch_hold;
    out["bolt_reaim"] = m_cfg.bolt_reaim;
    out["bolt_mute"] = m_cfg.bolt_mute;
    out["sens_out"] = m_cfg.sens_out;
    out["sens_in"] = m_cfg.sens_in;
    out["stick_zoom"] = m_cfg.stick_zoom;
    out["zoom_speed"] = m_cfg.zoom_speed;
    out["zoom_min"] = m_cfg.zoom_min;
    out["zoom_max"] = m_cfg.zoom_max;
    out["bino_bg_scale"] = m_cfg.bino_bg_scale;
    re4vr::save_json_file("re4_vr/re4_vr_scope.json", out);
    m_save_dirty = false;
}

void RE4VRScope::export_globals(sol::state& lua) {
    lua["__re4_fork_ok"] = true;
    lua["__re4_fork_mono"] = true;
    lua["__re4_fork_gui_matrix"] = true;
    lua["__re4_fork_canvas"] = true;
    lua["__re4_fork_check"] = []() { return std::make_tuple(true, true, true); };
    lua["__re4_mono_request"] = [this](sol::object id, sol::object on) {
        if (!id.is<std::string>()) {
            return;
        }
        const bool want = on.get_type() == sol::type::boolean && on.as<bool>();
        mono_request(id.as<std::string>(), want);
    };
    lua["__re4_bolt_reaim"] = m_cfg.bolt_reaim;
    lua["__re4_bolt_pitch_hold"] = m_cfg.bolt_pitch_hold;
    lua["__re4_scope_sens_factor"] = m_cfg.sens_out;
    lua["__re4_scope_mono_enable"] = m_cfg.mono;
}

void RE4VRScope::probe() {
    m_fork_ok = true;
    m_fork_mono = true;
    m_fork_gui = true;
    m_fork_canvas = true;
    m_probe_done = true;
    re4vr::lua_set_bool("__re4_fork_ok", true);
    re4vr::lua_set_bool("__re4_fork_mono", true);
    re4vr::lua_set_bool("__re4_fork_gui_matrix", true);
    re4vr::lua_set_bool("__re4_fork_canvas", true);
}

void RE4VRScope::mono_request(std::string id, bool on) {
    if (id.empty()) {
        return;
    }
    if (on) {
        m_mono_reqs[std::move(id)] = true;
    } else {
        m_mono_reqs.erase(id);
    }
}

void RE4VRScope::mono_apply() {
    if (!m_fork_mono || m_mono_fail) {
        return;
    }
    const bool want = !m_mono_reqs.empty();
    if (want == m_mono_state) {
        return;
    }
    re4vr::pcall([&] { VR::get()->set_mono_rendering(want); });
    m_mono_state = want;
}

void RE4VRScope::proj_apply(bool on) {
    if (!m_proj_supported) {
        m_proj_supported = true;
    }
    if (on == m_proj_on) {
        return;
    }
    m_proj_on = on;
    auto& vr = VR::get();
    re4vr::pcall([&] {
        vr->set_projection_matrix_override_disabled(on && m_cfg.proj_off);
        vr->set_view_matrix_override_disabled(on && m_cfg.view_off);
        vr->set_mono_projection(on && m_cfg.mono_proj);
        vr->set_projection_zoom(on ? m_cfg.zoom : 1.0f);
        vr->set_projection_fov(on ? m_cfg.fov : 0.0f);
        vr->set_image_shift_x(on ? m_cfg.img_x : 0.0f);
        vr->set_image_shift_y(on ? m_cfg.img_y : 0.0f);
    });
}

float RE4VRScope::zoom_ramp() const {
    if (!(m_cfg.zoom_max > m_cfg.zoom_min)) {
        return 0.0f;
    }
    float t = (m_cfg.zoom - m_cfg.zoom_min) / (m_cfg.zoom_max - m_cfg.zoom_min);
    return std::clamp(t, 0.0f, 1.0f);
}

float RE4VRScope::zoom_x_now() const {
    const float t = zoom_ramp();
    return (m_cfg.zoom_x * t) + (m_cfg.zoom_x_bow * std::sin(glm::pi<float>() * t));
}

float RE4VRScope::zoom_y_now() const {
    return m_cfg.zoom_y * zoom_ramp();
}

int32_t RE4VRScope::scope_raw_wid() {
    if (auto w = re4vr::lua_number("__re4_scope_wid")) {
        m_last_raw_wid = (int32_t)*w;
    }
    return m_last_raw_wid;
}

std::string RE4VRScope::scope_raw_id() {
    if (auto s = re4vr::lua_string("__re4_scope_id")) {
        m_last_raw_id = *s;
    } else if (re4vr::lua_number("__re4_scope_wid")) {
        m_last_raw_id = "ironsight";
    }
    return m_last_raw_id;
}

int32_t RE4VRScope::scope_wid_now() {
    const auto raw = scope_raw_wid();
    if (re4vr::lua_not_false("__re4_ada_uses_leon_scope")) {
        if (raw == 6105) {
            return 4401;
        }
        if (raw == 6114) {
            return 4400;
        }
    }
    return raw;
}

std::string RE4VRScope::scope_id_now() {
    if (auto s = re4vr::lua_string("__re4_scope_id")) {
        m_last_scope_id = *s;
    } else if (re4vr::lua_number("__re4_scope_wid")) {
        m_last_scope_id = "ironsight";
    }
    return m_last_scope_id;
}

std::string RE4VRScope::scope_key_now() {
    return std::to_string(scope_wid_now()) + "_" + scope_id_now();
}

std::vector<RE4VRScope::Keyframe>& RE4VRScope::cur_kfs() {
    return m_cfg.kfs_sets[scope_key_now()];
}

RE4VRScope::AdaY& RE4VRScope::ada_y_set() {
    const auto id = scope_raw_id();
    auto it = m_cfg.pitch_y_ada_sets.find(id);
    if (it == m_cfg.pitch_y_ada_sets.end()) {
        AdaY s{m_cfg.pitch_y_ada, m_cfg.pitch_y_deg_ada, m_cfg.pitch_y_pow_ada};
        it = m_cfg.pitch_y_ada_sets.emplace(id, s).first;
    }
    return it->second;
}

float RE4VRScope::pitch_y_at(float deg) {
    const auto w = scope_raw_wid();
    const bool ada = (w == 6105 || w == 6114);
    const AdaY* set = ada ? &ada_y_set() : nullptr;
    const float k = ada ? set->y : m_cfg.pitch_y;
    if (k == 0.0f) {
        return 0.0f;
    }
    float ref = ada ? set->deg : m_cfg.pitch_y_deg;
    if (ref < 1.0f) {
        ref = 1.0f;
    }
    float t = deg / ref;
    t = std::clamp(t, -1.0f, 1.0f);
    float p = ada ? set->pow : m_cfg.pitch_y_pow;
    p = std::clamp(p, 0.2f, 5.0f);
    const float a = std::abs(t);
    const float s = std::pow(a, p) * (t < 0.0f ? -1.0f : 1.0f);
    return k * s;
}

bool RE4VRScope::detect_runtime_xr() {
    if (m_is_xr) {
        return *m_is_xr;
    }
    auto& vr = VR::get();
    if (vr->is_openxr_loaded()) {
        m_is_xr = true;
    } else if (vr->is_openvr_loaded()) {
        m_is_xr = false;
    }
    return m_is_xr.value_or(false);
}

void RE4VRScope::scope_curve(const std::vector<Keyframe>& pts, float deg, float& x, float& y, float& z) const {
    x = y = z = 0.0f;
    if (pts.empty()) {
        return;
    }
    const auto& a = pts.front();
    if (pts.size() == 1 || deg <= a.deg) {
        x = a.x;
        y = a.y;
        z = a.z;
        return;
    }
    const auto& b = pts.back();
    if (deg >= b.deg) {
        x = b.x;
        y = b.y;
        z = b.z;
        return;
    }
    for (size_t i = 0; i + 1 < pts.size(); ++i) {
        const auto& p = pts[i];
        const auto& q = pts[i + 1];
        if (deg < p.deg || deg > q.deg) {
            continue;
        }
        float pa = p.deg + PLATEAU;
        float qb = q.deg - PLATEAU;
        if (qb <= pa) {
            pa = p.deg;
            qb = q.deg;
        }
        if (deg <= pa) {
            x = p.x;
            y = p.y;
            z = p.z;
            return;
        }
        if (deg >= qb) {
            x = q.x;
            y = q.y;
            z = q.z;
            return;
        }
        const float span = qb - pa;
        const float u = (span > 0.0001f) ? ((deg - pa) / span) : 0.0f;
        x = p.x + (q.x - p.x) * u;
        y = p.y + (q.y - p.y) * u;
        z = p.z + (q.z - p.z) * u;
        return;
    }
    x = b.x;
    y = b.y;
    z = b.z;
}

float RE4VRScope::scope_pitch_deg() {
    auto p = re4vr::lua_number("__re4_scope_aim_pitch");
    if (!m_scope_native) {
        m_deg_hist.clear();
        return p ? (float)*p : 0.0f;
    }
    if (!p) {
        return 0.0f;
    }
    const double now = re4vr::lua_os_clock();
    m_deg_hist.push_back(DegSample{now, (float)*p});
    while (!m_deg_hist.empty() && (now - m_deg_hist.front().t) > 0.5) {
        m_last_scope_deg = m_deg_hist.front().p;
        m_deg_hist.erase(m_deg_hist.begin());
    }
    return (float)*p;
}

void RE4VRScope::apply_cam_offset() {
    if (!m_scope_native) {
        return;
    }
    if (!re4vr::lua_number("__re4_scope_aim_pitch")) {
        return;
    }
    const float deg = scope_pitch_deg();
    const auto& pts = cur_kfs();
    float ox = m_cfg.cam_x, oy = m_cfg.cam_y, oz = m_cfg.cam_z;
    if (!pts.empty()) {
        scope_curve(pts, deg, ox, oy, oz);
        m_cfg.cam_x = ox;
        m_cfg.cam_y = oy;
        m_cfg.cam_z = oz;
    }
    const float py = pitch_y_at(deg);
    const float zx = zoom_x_now();
    const float zy = zoom_y_now();
    if (ox == 0.0f && oy == 0.0f && oz == 0.0f && zx == 0.0f && zy == 0.0f && py == 0.0f) {
        re4vr::lua_set_number("__re4_scope_off_x", 0.0);
        re4vr::lua_set_number("__re4_scope_off_y", 0.0);
        re4vr::lua_set_number("__re4_scope_off_z", 0.0);
        return;
    }
    ox += zx;
    oy += zy + py;
    if (detect_runtime_xr()) {
        ox += m_cfg.xr_dx;
        oy += m_cfg.xr_dy;
    }
    re4vr::lua_set_number("__re4_scope_off_x", ox);
    re4vr::lua_set_number("__re4_scope_off_y", oy);
    re4vr::lua_set_number("__re4_scope_off_z", oz);

    auto* cam = sdk::get_primary_camera();
    if (!cam) {
        return;
    }
    re4vr::pcall([&] {
        auto* cgo = sdk::call_object_func_easy<::REGameObject*>(cam, "get_GameObject");
        if (!cgo) {
            return;
        }
        auto* ctf = sdk::call_object_func_easy<::RETransform*>(cgo, "get_Transform");
        if (!ctf) {
            return;
        }
        const auto p = sdk::get_transform_position(ctf);
        const auto r = sdk::get_transform_rotation(ctf);
        const auto d = glm::rotate(r, Vector3f{ox, oy, oz});
        sdk::set_transform_position(ctf, Vector4f{p.x + d.x, p.y + d.y, p.z + d.z, p.w}, true);
    });
}

HookManager::PreHookResult RE4VRScope::pre_post_event(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    auto& self = *get();
    self.m_bolt_skipped = false;
    if (!self.m_cfg.bolt_mute) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    const auto wid = re4vr::lua_number("__re4_scope_wid");
    if (!wid || (*wid != 4400.0 && *wid != 6114.0)) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    const auto st = re4vr::lua_number("__re4_bolt_shoot_t");
    if (!st) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    const double dt = re4vr::lua_os_clock() - *st;
    if (dt < 0.0 || dt > 1.20) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    // static postEvent: args[0]=vm, args[1] unused/this, args[2]=RequestId, args[3]=EventId
    if (args.size() <= 3 || !args[3]) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    const uint32_t eid = (uint32_t)(uintptr_t)args[3];
    if (!BOLT_MUTE_IDS.count(eid)) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    self.m_bolt_skipped = true;
    return HookManager::PreHookResult::SKIP_ORIGINAL;
}

void RE4VRScope::post_post_event(uintptr_t& ret_val, sdk::RETypeDefinition*, uintptr_t) {
    auto& self = *get();
    if (self.m_bolt_skipped) {
        self.m_bolt_skipped = false;
        ret_val = 0;
    }
}

std::optional<std::string> RE4VRScope::on_initialize() {
    load_json();
    probe();
    if (auto* td = sdk::find_type_definition("soundlib.SoundManager")) {
        for (auto& m : td->get_methods()) {
            if (std::string_view{m.get_name()} == "postEvent" && m.get_num_params() == 7) {
                g_hookman.add(&m, &RE4VRScope::pre_post_event, &RE4VRScope::post_post_event);
                spdlog::info("[RE4VRScope] Hooked SoundManager.postEvent (7 params)");
                break;
            }
        }
    }
    return std::nullopt;
}

void RE4VRScope::on_lua_state_created(sol::state& lua) {
    load_json();
    probe();
    export_globals(lua);
}

void RE4VRScope::on_lua_state_destroyed(sol::state&) {
    m_mono_reqs.clear();
    if (m_mono_state) {
        re4vr::pcall([&] { VR::get()->set_mono_rendering(false); });
        m_mono_state = false;
    }
    proj_apply(false);
    if (m_save_dirty) {
        save_json();
    }
}

void RE4VRScope::on_frame() {
    ScriptProfileGuard guard("re4_vr_scope.lua", "on_frame", re4vr::profile_frame());
    if (!m_probe_done) {
        probe();
    }
    re4vr::lua_set_bool("__re4_scope_mono_enable", m_cfg.mono);
    re4vr::lua_set_number("__re4_bolt_pitch_hold", m_cfg.bolt_pitch_hold);
    re4vr::lua_set_bool("__re4_bolt_reaim", m_cfg.bolt_reaim);

    const bool raw_native = re4vr::lua_is_true("__re4_scope_native");
    const double now = re4vr::lua_os_clock();
    if (raw_native) {
        m_scope_native = true;
        m_native_off_t.reset();
    } else if (m_scope_native) {
        if (!m_native_off_t) {
            m_native_off_t = now;
        }
        if ((now - *m_native_off_t) >= m_cfg.hold) {
            m_scope_native = false;
            m_native_off_t.reset();
        }
    }

    bool bolt_win = false;
    if (auto st = re4vr::lua_number("__re4_bolt_shoot_t")) {
        const auto wid = re4vr::lua_number("__re4_scope_wid");
        if (wid && (*wid == 4400.0 || *wid == 6114.0) && (now - *st) < 1.10) {
            bolt_win = true;
        }
    }

    mono_request("scope", m_scope_native && m_cfg.mono && !bolt_win);
    mono_request("manual", m_cfg.mono_manual);
    mono_apply();
    proj_apply(m_scope_native);

    re4vr::lua_set_number("__re4_scope_sens_factor", m_cfg.sens_out + (m_cfg.sens_in - m_cfg.sens_out) * zoom_ramp());

    if (m_save_dirty && (now - m_save_t) > 1.0) {
        save_json();
    }

    if (m_scope_native) {
        re4vr::pcall([&] {
            VR::get()->set_image_shift_x(m_cfg.img_x);
            VR::get()->set_image_shift_y(m_cfg.img_y);
        });
        if (m_cfg.stick_zoom) {
            float y = 0.0f;
            re4vr::pcall([&] { y = VR::get()->get_left_stick_axis().y; });
            if (y > 0.3f || y < -0.3f) {
                float z = m_cfg.zoom + (y * m_cfg.zoom_speed);
                z = std::clamp(z, m_cfg.zoom_min, m_cfg.zoom_max);
                if (z != m_cfg.zoom) {
                    m_cfg.zoom = z;
                    re4vr::pcall([&] { VR::get()->set_projection_zoom(z); });
                }
            }
        }
    }
}

void RE4VRScope::on_pre_application_entry(void*, const char*, size_t hash) {
    if (hash != "UnlockScene"_fnv) {
        return;
    }
    ScriptProfileGuard guard("re4_vr_scope.lua", "on_pre_application_entry:UnlockScene", re4vr::profile_frame());
    apply_cam_offset();
}

void RE4VRScope::on_application_entry(void*, const char*, size_t hash) {
    if (hash != "LateUpdateBehavior"_fnv && hash != "BeginRendering"_fnv) {
        return;
    }
    ScriptProfileGuard guard("re4_vr_scope.lua",
        hash == "LateUpdateBehavior"_fnv ? "on_application_entry:LateUpdateBehavior" : "on_application_entry:BeginRendering",
        re4vr::profile_frame());
    apply_cam_offset();
}
#endif
