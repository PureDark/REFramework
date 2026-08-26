#define NOMINMAX
#include "RE4VRReloadAdv.hpp"

#if defined(RE4)
#include <algorithm>
#include <cmath>
#include <string>
#include <tuple>

#include <glm/gtc/constants.hpp>
#include <glm/gtx/quaternion.hpp>
#include <sdk/RETypeDB.hpp>
#include <sdk/RETransform.hpp>
#include <sdk/MurmurHash.hpp>
#include <sdk/Application.hpp>

#include "RE4VRShared.hpp"
#include "../../../ScriptRunner.hpp"

namespace {
float ease(float t) {
    return t * t * (3.0f - 2.0f * t);
}

RE4VRReloadAdv::Keyframe lerp_kf(const RE4VRReloadAdv::Keyframe& a, const RE4VRReloadAdv::Keyframe& b, float f) {
    return {a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f, a.z + (b.z - a.z) * f,
            a.rx + (b.rx - a.rx) * f, a.ry + (b.ry - a.ry) * f, a.rz + (b.rz - a.rz) * f};
}

std::optional<RE4VRReloadAdv::Keyframe> pose_at(const std::vector<RE4VRReloadAdv::Keyframe>& k, float tt) {
    if (k.empty()) {
        return std::nullopt;
    }
    if (k.size() == 1 || tt <= 0.0f) {
        return k.front();
    }
    if (tt >= 1.0f) {
        return k.back();
    }
    const float seg = tt * (float)(k.size() - 1);
    size_t i = (size_t)std::floor(seg);
    if (i >= k.size() - 1) {
        i = k.size() - 2;
    }
    return lerp_kf(k[i], k[i + 1], seg - (float)i);
}
}

std::shared_ptr<RE4VRReloadAdv>& RE4VRReloadAdv::get() {
    static auto inst = std::make_shared<RE4VRReloadAdv>();
    return inst;
}

glm::quat RE4VRReloadAdv::quat_from_euler(float rx, float ry, float rz) {
    const auto ax = [](float a, float x, float y, float z) {
        const float h = glm::radians(a) * 0.5f;
        const float s = std::sin(h);
        return glm::quat{std::cos(h), x * s, y * s, z * s};
    };
    return glm::normalize(ax(rz, 0, 0, 1) * ax(ry, 0, 1, 0) * ax(rx, 1, 0, 0));
}

glm::quat RE4VRReloadAdv::qnlerp(const glm::quat& a, const glm::quat& b, float t) {
    auto bw = b;
    if (glm::dot(a, bw) < 0.0f) {
        bw = -bw;
    }
    return glm::normalize(a + (bw - a) * t);
}

RE4VRReloadAdv::Wcfg& RE4VRReloadAdv::wcfg(int32_t wid) {
    auto it = m_weapons.find(wid);
    if (it == m_weapons.end()) {
        Wcfg w;
        m_weapons[wid] = w;
        it = m_weapons.find(wid);
    }
    return it->second;
}

RE4VRReloadAdv::Dock* RE4VRReloadAdv::dock(int32_t wid) {
    auto it = m_docks.find(wid);
    return it == m_docks.end() ? nullptr : &it->second;
}

std::optional<float> RE4VRReloadAdv::get_floor_y() {
    auto* tf = re4vr::body_transform();
    if (!tf) {
        return std::nullopt;
    }
    return sdk::get_transform_position(tf).y;
}

void RE4VRReloadAdv::seed_eject_keys() {
    auto seed = [&](int32_t wid, std::vector<Keyframe> k) {
        if (m_eject_keys[wid].empty()) {
            m_eject_keys[wid] = std::move(k);
        }
    };
    seed(6103, {{0, 0, 0, 0, 0, 0}, {0, -0.102f, -0.029f, 0, 0, 0}});
    seed(6112, {{0, 0, 0, 0, 0, 0}, {0, -0.102f, -0.017f, 0, 0, 0}});
    seed(6300, {{0, 0, 0, 0, 0, 0}, {0, -0.102f, -0.017f, 0, 0, 0}});
    seed(6301, {{0, 0, 0, 0, 0, 0}, {0, -0.102f, -0.029f, 0, 0, 0}});
}

void RE4VRReloadAdv::load_json() {
    m_docks = {
        {6000, {"_03", 0, -0.092f, -0.061f}},
        {4003, {"_03", 0, -0.087f, -0.057f}},
        {6103, {"_03", 0, -0.087f, -0.057f}},
        {4000, {"_03", 0, -0.087f, -0.068f}},
        {4001, {"_03", 0, -0.075f, -0.050f}},
        {6112, {"_03", 0, -0.075f, -0.050f}},
        {6300, {"_03", 0, -0.075f, -0.050f}},
        {6301, {"_03", 0, -0.087f, -0.057f}},
        {4004, {"_03", 0, -0.077f, -0.0949f}},
        {4200, {"_03", 0, -0.097f, -0.052f}},
        {6104, {"_03", 0, -0.097f, -0.052f}},
        {4501, {"_03", 0, -0.097f, -0.070f}},
        {4002, {"_03", 0, 0.064f, 0.051f}},
        {6113, {"_03", 0, 0.064f, 0.051f}},
    };
    m_dock_allowed = {4000, 4001, 4002, 4003, 4004, 4501, 6000, 4200, 6112, 6103, 6113, 6104, 6300, 6301};
    m_keyframe_insert = {4102, 4100, 4101, 4500, 4502, 4002, 40021, 6100, 6001, 4400, 4600};
    m_keyframe_eject = {4003, 4001, 4000, 4004, 4200, 4501, 6000, 6103, 6112, 6300, 6301};
    m_push_wids = {4000, 4001, 4003, 4004, 4501, 6000, 6103, 6112, 6300, 6301, 4200, 6104};
    m_rev_insert = {{4000, true}, {4001, true}, {4003, true}, {4004, true}, {4200, true}, {4501, true}, {6000, true}, {6103, true}, {6112, true}, {6300, true}, {6301, true}};
    seed_eject_keys();

    const auto d = re4vr::load_json_file("re4_vr/re4_vr_reload_adv.json");
    if (d.empty()) {
        return;
    }
    auto read_kf = [](const nlohmann::json& e) {
        Keyframe k;
        k.x = re4vr::j_num(e, "x", 0);
        k.y = re4vr::j_num(e, "y", 0);
        k.z = re4vr::j_num(e, "z", 0);
        k.rx = re4vr::j_num(e, "rx", 0);
        k.ry = re4vr::j_num(e, "ry", 0);
        k.rz = re4vr::j_num(e, "rz", 0);
        return k;
    };
    if (d.contains("weapons") && d["weapons"].is_object()) {
        for (auto it = d["weapons"].begin(); it != d["weapons"].end(); ++it) {
            int32_t wid = 0;
            try {
                wid = std::stoi(it.key());
            } catch (...) {
                continue;
            }
            auto& w = wcfg(wid);
            if (it.value().contains("exit") && it.value()["exit"].is_object()) {
                w.exit.x = re4vr::j_num(it.value()["exit"], "x", w.exit.x);
                w.exit.y = re4vr::j_num(it.value()["exit"], "y", w.exit.y);
                w.exit.z = re4vr::j_num(it.value()["exit"], "z", w.exit.z);
            }
            w.slide_dur = re4vr::j_num(it.value(), "slide_dur", w.slide_dur);
            w.gravity = re4vr::j_num(it.value(), "gravity", w.gravity);
            w.fall_dist = re4vr::j_num(it.value(), "fall_dist", w.fall_dist);
            w.fall_dur = re4vr::j_num(it.value(), "fall_dur", w.fall_dur);
            if (it.value().contains("land") && it.value()["land"].is_object()) {
                w.land.on = re4vr::j_bool(it.value()["land"], "on", w.land.on);
                w.land.rx = re4vr::j_num(it.value()["land"], "rx", w.land.rx);
                w.land.ry = re4vr::j_num(it.value()["land"], "ry", w.land.ry);
                w.land.rz = re4vr::j_num(it.value()["land"], "rz", w.land.rz);
            }
        }
    }
    if (d.contains("docks") && d["docks"].is_object()) {
        for (auto it = d["docks"].begin(); it != d["docks"].end(); ++it) {
            int32_t wid = 0;
            try {
                wid = std::stoi(it.key());
            } catch (...) {
                continue;
            }
            Dock dk = m_docks.count(wid) ? m_docks[wid] : Dock{};
            if (it.value().contains("joint") && it.value()["joint"].is_string()) {
                dk.joint = it.value()["joint"].get<std::string>();
            }
            dk.x = re4vr::j_num(it.value(), "x", dk.x);
            dk.y = re4vr::j_num(it.value(), "y", dk.y);
            dk.z = re4vr::j_num(it.value(), "z", dk.z);
            m_docks[wid] = dk;
        }
    }
    auto load_keys = [&](const char* name, std::unordered_map<int32_t, std::vector<Keyframe>>& dst) {
        if (!d.contains(name) || !d[name].is_object()) {
            return;
        }
        for (auto it = d[name].begin(); it != d[name].end(); ++it) {
            int32_t wid = 0;
            try {
                wid = std::stoi(it.key());
            } catch (...) {
                continue;
            }
            if (!it.value().is_array()) {
                continue;
            }
            std::vector<Keyframe> arr;
            for (const auto& e : it.value()) {
                if (e.is_object()) {
                    arr.push_back(read_kf(e));
                }
            }
            dst[wid] = std::move(arr);
        }
    };
    load_keys("shell_keys", m_shell_keys);
    load_keys("mag_eject_keys", m_eject_keys);
    m_shell_dur = re4vr::j_num(d, "shell_dur", m_shell_dur);
    m_r9_anlauf = re4vr::j_num(d, "r9_anlauf", m_r9_anlauf);
    m_shell_clone_part = (int)re4vr::j_num(d, "shell_clone_part", (float)m_shell_clone_part);
    m_shell_clone_scale = re4vr::j_num(d, "shell_clone_scale", m_shell_clone_scale);
    m_eject_dur = re4vr::j_num(d, "eject_dur", m_eject_dur);
    m_rev_insert_dur = re4vr::j_num(d, "rev_insert_dur", m_rev_insert_dur);
    if (d.contains("rev_insert_by_wid") && d["rev_insert_by_wid"].is_object()) {
        for (auto it = d["rev_insert_by_wid"].begin(); it != d["rev_insert_by_wid"].end(); ++it) {
            try {
                m_rev_insert[std::stoi(it.key())] = it.value().is_boolean() ? it.value().get<bool>() : true;
            } catch (...) {
            }
        }
    }
    if (d.contains("push") && d["push"].is_object()) {
        const auto& p = d["push"];
        m_push.on = re4vr::j_bool(p, "on", m_push.on);
        m_push.in_dur = re4vr::j_num(p, "in_dur", m_push.in_dur);
        m_push.hold = re4vr::j_num(p, "hold", m_push.hold);
        m_push.out_dur = re4vr::j_num(p, "out_dur", m_push.out_dur);
        m_push.curl = re4vr::j_num(p, "curl", m_push.curl);
        m_push.thumb = re4vr::j_num(p, "thumb", m_push.thumb);
        m_push.release_dur = re4vr::j_num(p, "release_dur", m_push.release_dur);
        m_push.reload_speed = re4vr::j_num(p, "reload_speed", m_push.reload_speed);
        m_push.fall_grav_mult = re4vr::j_num(p, "fall_grav_mult", m_push.fall_grav_mult);
        m_push.rx = re4vr::j_num(p, "rx", m_push.rx);
        m_push.ry = re4vr::j_num(p, "ry", m_push.ry);
        m_push.rz = re4vr::j_num(p, "rz", m_push.rz);
        m_push.px = re4vr::j_num(p, "px", m_push.px);
        m_push.py = re4vr::j_num(p, "py", m_push.py);
        m_push.pz = re4vr::j_num(p, "pz", m_push.pz);
        m_push.ada_px = re4vr::j_num(p, "ada_px", m_push.ada_px);
        m_push.ada_py = re4vr::j_num(p, "ada_py", m_push.ada_py);
        m_push.ada_pz = re4vr::j_num(p, "ada_pz", m_push.ada_pz);
        if (p.contains("bones") && p["bones"].is_object()) {
            m_push.bones.clear();
            for (auto it = p["bones"].begin(); it != p["bones"].end(); ++it) {
                if (it.value().is_array() && it.value().size() >= 4) {
                    m_push.bones[it.key()] = glm::quat{it.value()[0].get<float>(), it.value()[1].get<float>(),
                        it.value()[2].get<float>(), it.value()[3].get<float>()};
                }
            }
        }
    }
    if (d.contains("push_y_by_wid") && d["push_y_by_wid"].is_object()) {
        for (auto it = d["push_y_by_wid"].begin(); it != d["push_y_by_wid"].end(); ++it) {
            try {
                if (it.value().is_number()) {
                    m_push_y_by_wid[std::stoi(it.key())] = it.value().get<float>();
                }
            } catch (...) {
            }
        }
    }
}

void RE4VRReloadAdv::save_json() {
    nlohmann::json out;
    nlohmann::json weapons = nlohmann::json::object();
    for (const auto& [wid, w] : m_weapons) {
        weapons[std::to_string(wid)] = {
            {"exit", {{"x", w.exit.x}, {"y", w.exit.y}, {"z", w.exit.z}}},
            {"slide_dur", w.slide_dur},
            {"gravity", w.gravity},
            {"fall_dist", w.fall_dist},
            {"fall_dur", w.fall_dur},
            {"land", {{"on", w.land.on}, {"rx", w.land.rx}, {"ry", w.land.ry}, {"rz", w.land.rz}}},
        };
    }
    out["weapons"] = weapons;
    nlohmann::json docks = nlohmann::json::object();
    for (const auto& [wid, d] : m_docks) {
        docks[std::to_string(wid)] = {{"joint", d.joint}, {"x", d.x}, {"y", d.y}, {"z", d.z}};
    }
    out["docks"] = docks;
    auto dump_keys = [](const std::unordered_map<int32_t, std::vector<Keyframe>>& src) {
        nlohmann::json o = nlohmann::json::object();
        for (const auto& [wid, arr] : src) {
            nlohmann::json a = nlohmann::json::array();
            for (const auto& k : arr) {
                a.push_back({{"x", k.x}, {"y", k.y}, {"z", k.z}, {"rx", k.rx}, {"ry", k.ry}, {"rz", k.rz}});
            }
            o[std::to_string(wid)] = a;
        }
        return o;
    };
    out["shell_keys"] = dump_keys(m_shell_keys);
    out["mag_eject_keys"] = dump_keys(m_eject_keys);
    out["shell_dur"] = m_shell_dur;
    out["r9_anlauf"] = m_r9_anlauf;
    out["shell_clone_part"] = m_shell_clone_part;
    out["shell_clone_scale"] = m_shell_clone_scale;
    out["eject_dur"] = m_eject_dur;
    out["rev_insert_dur"] = m_rev_insert_dur;
    nlohmann::json ri = nlohmann::json::object();
    for (const auto& [w, v] : m_rev_insert) {
        ri[std::to_string(w)] = v;
    }
    out["rev_insert_by_wid"] = ri;
    nlohmann::json bones = nlohmann::json::object();
    for (const auto& [n, q] : m_push.bones) {
        bones[n] = nlohmann::json::array({q.w, q.x, q.y, q.z});
    }
    out["push"] = {
        {"on", m_push.on}, {"in_dur", m_push.in_dur}, {"hold", m_push.hold}, {"out_dur", m_push.out_dur},
        {"curl", m_push.curl}, {"thumb", m_push.thumb}, {"release_dur", m_push.release_dur},
        {"reload_speed", m_push.reload_speed}, {"fall_grav_mult", m_push.fall_grav_mult},
        {"rx", m_push.rx}, {"ry", m_push.ry}, {"rz", m_push.rz},
        {"px", m_push.px}, {"py", m_push.py}, {"pz", m_push.pz},
        {"ada_px", m_push.ada_px}, {"ada_py", m_push.ada_py}, {"ada_pz", m_push.ada_pz},
        {"bones", bones},
    };
    nlohmann::json py = nlohmann::json::object();
    for (const auto& [w, y] : m_push_y_by_wid) {
        py[std::to_string(w)] = y;
    }
    out["push_y_by_wid"] = py;
    re4vr::save_json_file("re4_vr/re4_vr_reload_adv.json", out);
}

bool RE4VRReloadAdv::begin_drop(::REJoint* joint, int32_t wid, std::optional<float> dur, std::optional<Vec3> exit_local) {
    if (!joint) {
        return false;
    }
    const auto lp = sdk::get_joint_local_position(joint);
    auto& w = wcfg(wid);
    m_drop = {};
    m_drop.joint = joint;
    m_drop.wid = wid;
    m_drop.lx0 = lp.x;
    m_drop.ly0 = lp.y;
    m_drop.lz0 = lp.z;
    if (exit_local) {
        m_drop.ex = exit_local->x;
        m_drop.ey = exit_local->y;
        m_drop.ez = exit_local->z;
    } else {
        m_drop.ex = lp.x + w.exit.x;
        m_drop.ey = lp.y + w.exit.y;
        m_drop.ez = lp.z + w.exit.z;
    }
    m_drop.slide_dur = (dur && *dur > 0) ? *dur : w.slide_dur;
    m_drop.gravity = w.gravity;
    m_drop.fall_dist = w.fall_dist;
    m_drop.fall_dur = w.fall_dur;
    m_drop.use_keys = has_eject_keys(wid);
    if (m_drop.use_keys) {
        m_drop.slide_dur = m_eject_dur;
    }
    m_drop.t0 = re4vr::now();
    m_drop.phase = "slide";
    m_drop.active = true;
    return true;
}

void RE4VRReloadAdv::cancel() {
    m_drop.active = false;
    m_drop.joint = nullptr;
    m_drop.phase.clear();
}

void RE4VRReloadAdv::tick() {
    if (!m_drop.active || !m_drop.joint) {
        return;
    }
    const double now = re4vr::now();
    if (m_drop.phase == "slide") {
        if (m_drop.use_keys) {
            auto* wtf = (::RETransform*)RE4VRShared::get()->re4_reload_weapon_tf;
            if (wtf) {
                float t = (float)((now - m_drop.t0) / std::max(m_drop.slide_dur, 0.01f));
                t = std::min(t, 1.0f);
                apply_eject_keys(wtf, m_drop.joint, m_drop.wid, t);
                if (t >= 1.0f) {
                    const auto p = sdk::get_joint_position(m_drop.joint);
                    m_drop.sx = p.x;
                    m_drop.sy = p.y;
                    m_drop.sz = p.z;
                    const auto r = sdk::get_joint_rotation(m_drop.joint);
                    m_drop.srw = r.w;
                    m_drop.srx = r.x;
                    m_drop.sry = r.y;
                    m_drop.srz = r.z;
                    m_drop.has_sr = true;
                    m_drop.floor_y = get_floor_y();
                    m_drop.phase = "fall";
                    m_drop.t0 = now;
                }
                return;
            }
            m_drop.use_keys = false;
        }
        float t = (float)((now - m_drop.t0) / std::max(m_drop.slide_dur, 0.01f));
        t = std::min(t, 1.0f);
        const float u = ease(t);
        sdk::set_joint_local_position(m_drop.joint, Vector4f{
            m_drop.lx0 + (m_drop.ex - m_drop.lx0) * u,
            m_drop.ly0 + (m_drop.ey - m_drop.ly0) * u,
            m_drop.lz0 + (m_drop.ez - m_drop.lz0) * u, 1.0f});
        if (t >= 1.0f) {
            const auto p = sdk::get_joint_position(m_drop.joint);
            m_drop.sx = p.x;
            m_drop.sy = p.y;
            m_drop.sz = p.z;
            const auto r = sdk::get_joint_rotation(m_drop.joint);
            m_drop.srw = r.w;
            m_drop.srx = r.x;
            m_drop.sry = r.y;
            m_drop.srz = r.z;
            m_drop.has_sr = true;
            m_drop.floor_y = get_floor_y();
            m_drop.phase = "fall";
            m_drop.t0 = now;
        }
        return;
    }
    const float t = (float)(now - m_drop.t0);
    const float g = m_drop.gravity * m_push.fall_grav_mult;
    float fall = 0.5f * g * t * t;
    float total = m_drop.fall_dist;
    if (m_drop.floor_y) {
        total = m_drop.sy - (*m_drop.floor_y + 0.02f);
        if (total < 0) {
            total = 0;
        }
    }
    if (fall > total) {
        fall = total;
    }
    const float tf = (total > 1e-4f) ? (fall / total) : 1.0f;
    sdk::set_joint_position(m_drop.joint, Vector4f{m_drop.sx, m_drop.sy - fall, m_drop.sz, 1.0f});
    if (m_drop.has_sr) {
        glm::quat q{m_drop.srw, m_drop.srx, m_drop.sry, m_drop.srz};
        const auto& lc = wcfg(m_drop.wid).land;
        if (lc.on) {
            q = qnlerp(q, quat_from_euler(lc.rx, lc.ry, lc.rz), tf);
        }
        sdk::set_joint_rotation(m_drop.joint, q);
    }
}

void RE4VRReloadAdv::start_push(int32_t wid) {
    if (!m_push.on || !m_push_wids.count(wid)) {
        return;
    }
    m_push_t0 = re4vr::now();
    m_push_wid = wid;
}

void RE4VRReloadAdv::stop_push() {
    m_push_t0.reset();
}

void RE4VRReloadAdv::begin_push_hold(int32_t wid) {
    start_push(wid);
    m_push_hold = m_push_t0.has_value();
}

void RE4VRReloadAdv::end_push_hold() {
    if (!m_push_hold) {
        return;
    }
    m_push_hold = false;
    const float tm = time_mult();
    m_push_t0 = re4vr::now() - (m_push.in_dur * tm + m_push.hold * tm);
}

float RE4VRReloadAdv::time_mult() const {
    const float sp = m_push.reload_speed <= 0.0f ? 1.0f : m_push.reload_speed;
    return 1.0f / sp;
}

float RE4VRReloadAdv::push_blend() {
    if (m_push_tune) {
        return 1.0f;
    }
    if (m_push_hold) {
        if (!m_push_t0) {
            return 1.0f;
        }
        const float e2 = (float)(re4vr::now() - *m_push_t0);
        const float i2 = m_push.in_dur * time_mult();
        return (e2 < i2) ? (e2 / std::max(i2, 0.01f)) : 1.0f;
    }
    if (!m_push_t0) {
        return 0.0f;
    }
    const float tm = time_mult();
    const float e = (float)(re4vr::now() - *m_push_t0);
    const float i_dur = m_push.in_dur * tm, h_dur = m_push.hold * tm, o_dur = m_push.out_dur * tm;
    const float total = i_dur + h_dur + o_dur;
    if (e >= total) {
        m_push_t0.reset();
        return 0.0f;
    }
    if (e < i_dur) {
        return e / std::max(i_dur, 0.01f);
    }
    if (e < i_dur + h_dur) {
        return 1.0f;
    }
    return 1.0f - ((e - i_dur - h_dur) / std::max(o_dur, 0.01f));
}

void RE4VRReloadAdv::push_pos(std::optional<int32_t> wid, float& x, float& y, float& z) {
    x = m_push.px;
    y = m_push.py;
    z = m_push.pz;
    const int32_t w = wid ? *wid : (m_push_wid ? *m_push_wid : 0);
    if (m_push_y_by_wid.count(w)) {
        y += m_push_y_by_wid[w];
    }
    bool ada = RE4VRShared::get()->re4_char_now.value_or("") == "ada";
    if (ada) {
        x += m_push.ada_px;
        y += m_push.ada_py;
        z += m_push.ada_pz;
    }
}

void RE4VRReloadAdv::push_apply() {
    const float blend = push_blend();
    if (blend <= 0.0f) {
        RE4VRShared::get()->re4_push_blend.reset();
        return;
    }
    RE4VRShared::get()->re4_push_blend = blend;
    std::unordered_map<std::string, glm::quat> bones = m_push.bones;
    if (bones.empty()) {
        auto pq = [](float deg, int axis, float sign = 1.0f) {
            const float r = glm::radians(deg) * 0.5f * sign;
            glm::quat q{std::cos(r), 0, 0, 0};
            const float s = std::sin(r);
            if (axis == 2) {
                q.x = s;
            } else if (axis == 3) {
                q.y = s;
            } else {
                q.z = s;
            }
            return q;
        };
        bones["L_Palm"] = pq(0, 4);
        for (const char* pre : {"L_IndexF", "L_MiddleF", "L_RingF", "L_PinkyF"}) {
            for (int i = 1; i <= 3; ++i) {
                bones[std::string{pre} + std::to_string(i)] = pq(m_push.curl, 4, -1.0f);
            }
        }
        bones["L_Thumb1"] = pq(m_push.thumb, 2);
        bones["L_Thumb2"] = pq(m_push.thumb * 0.5f, 3);
        bones["L_Thumb3"] = pq(m_push.thumb * 0.5f, 3);
    }
    re4vr::apply_pose_bones(bones, blend);
}

bool RE4VRReloadAdv::has_eject_keys(int32_t wid) {
    return m_keyframe_eject.count(wid) && m_eject_keys[wid].size() >= 2;
}

bool RE4VRReloadAdv::uses_rev_insert(int32_t wid) {
    auto it = m_rev_insert.find(wid);
    return it != m_rev_insert.end() && it->second && has_eject_keys(wid);
}

bool RE4VRReloadAdv::has_shell_keys(int32_t wid) {
    if (uses_rev_insert(wid)) {
        return true;
    }
    return m_keyframe_insert.count(wid) && !m_shell_keys[wid].empty();
}

std::optional<RE4VRReloadAdv::Keyframe> RE4VRReloadAdv::eject_pose_at(int32_t wid, float tt) {
    return pose_at(m_eject_keys[wid], tt);
}

std::optional<RE4VRReloadAdv::Keyframe> RE4VRReloadAdv::shell_pose_at(int32_t wid, float tt) {
    if (uses_rev_insert(wid)) {
        return eject_pose_at(wid, 1.0f - tt);
    }
    return pose_at(m_shell_keys[wid], tt);
}

bool RE4VRReloadAdv::apply_kf_world(::RETransform* weapon_tf, ::REJoint* joint, const Keyframe& p) {
    if (!weapon_tf || !joint) {
        return false;
    }
    const auto gp = sdk::get_transform_position(weapon_tf);
    const auto gr = sdk::get_transform_rotation(weapon_tf);
    const auto off = glm::rotate(gr, Vector3f{p.x, p.y, p.z});
    sdk::set_joint_position(joint, Vector4f{gp.x + off.x, gp.y + off.y, gp.z + off.z, 1.0f});
    sdk::set_joint_rotation(joint, glm::normalize(gr * quat_from_euler(p.rx, p.ry, p.rz)));
    return true;
}

bool RE4VRReloadAdv::apply_shell_keys(::RETransform* weapon_tf, ::REJoint* joint, int32_t wid, float tt) {
    auto p = shell_pose_at(wid, tt);
    if (!p) {
        return false;
    }
    return apply_kf_world(weapon_tf, joint, *p);
}

bool RE4VRReloadAdv::apply_eject_keys(::RETransform* weapon_tf, ::REJoint* joint, int32_t wid, float tt) {
    auto p = eject_pose_at(wid, tt);
    if (!p) {
        return false;
    }
    return apply_kf_world(weapon_tf, joint, *p);
}

std::optional<float> RE4VRReloadAdv::kf_insert_dur(int32_t wid) {
    if (uses_rev_insert(wid)) {
        return m_rev_insert_dur;
    }
    return std::nullopt;
}

std::optional<Vector3f> RE4VRReloadAdv::dock_world(::RETransform* weapon_tf, int32_t wid) {
    if (!weapon_tf || !m_dock_allowed.count(wid)) {
        return std::nullopt;
    }
    auto* d = dock(wid);
    if (!d) {
        return std::nullopt;
    }
    auto* j = re4vr::joint_by_name(weapon_tf, d->joint);
    if (!j) {
        return std::nullopt;
    }
    const auto jp = sdk::get_joint_position(j);
    const auto jr = sdk::get_joint_rotation(j);
    const auto off = glm::rotate(jr, Vector3f{d->x, d->y, d->z});
    return Vector3f{jp.x + off.x, jp.y + off.y, jp.z + off.z};
}

std::optional<RE4VRReloadAdv::Vec3> RE4VRReloadAdv::dock_local(::RETransform* weapon_tf, int32_t wid) {
    auto w = dock_world(weapon_tf, wid);
    if (!w) {
        return std::nullopt;
    }
    const auto gp = sdk::get_transform_position(weapon_tf);
    const auto gr = sdk::get_transform_rotation(weapon_tf);
    const auto rel = glm::inverse(gr) * (Vector3f{w->x - gp.x, w->y - gp.y, w->z - gp.z});
    return Vec3{rel.x, rel.y, rel.z};
}

void RE4VRReloadAdv::shell_preview_apply() {
    const int32_t wid = (int32_t)RE4VRShared::get()->re4_reload_ui_wid.value_or(0);
    if (m_shell_preview && m_keyframe_insert.count(wid)) {
        RE4VRShared::get()->re4_shell_kf_preview = wid;
    } else {
        RE4VRShared::get()->re4_shell_kf_preview.reset();
    }
    RE4VRShared::get()->re4_shell_clone_part = m_shell_clone_part;
    RE4VRShared::get()->re4_shell_clone_scale = m_shell_clone_scale;
    if (!m_shell_preview || !m_keyframe_insert.count(wid)) {
        return;
    }
    auto* joint = (::REJoint*)RE4VRShared::get()->re4_reload_shell_joint;
    auto* tf = (::RETransform*)RE4VRShared::get()->re4_reload_weapon_tf;
    if (!joint || !tf) {
        return;
    }
    apply_kf_world(tf, joint, m_shell_live);
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(joint, "set_LocalScale", Vector3f{1, 1, 1}); });
}

void RE4VRReloadAdv::eject_preview_apply() {
    const int32_t wid = (int32_t)RE4VRShared::get()->re4_reload_ui_wid.value_or(0);
    if (m_eject_preview && m_keyframe_eject.count(wid)) {
        RE4VRShared::get()->re4_mag_eject_kf_preview = wid;
    } else {
        RE4VRShared::get()->re4_mag_eject_kf_preview.reset();
    }
    if (!m_eject_preview || !m_keyframe_eject.count(wid)) {
        return;
    }
    auto* joint = (::REJoint*)RE4VRShared::get()->re4_reload_shell_joint;
    auto* tf = (::RETransform*)RE4VRShared::get()->re4_reload_weapon_tf;
    if (!joint || !tf) {
        return;
    }
    apply_kf_world(tf, joint, m_eject_live);
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(joint, "set_LocalScale", Vector3f{1, 1, 1}); });
}

void RE4VRReloadAdv::tick_preview() {
    if (!m_preview.active) {
        return;
    }
    if (re4vr::now() >= m_preview.until_t || !m_preview.joint) {
        m_preview.active = false;
        m_preview.joint = nullptr;
        return;
    }
    const auto& w = wcfg(m_preview.wid);
    sdk::set_joint_local_position(m_preview.joint, Vector4f{
        m_preview.lx0 + w.exit.x, m_preview.ly0 + w.exit.y, m_preview.lz0 + w.exit.z, 1.0f});
}

void RE4VRReloadAdv::sync_lua_fields() {
    re4vr::LuaGuard g;
    auto* L = g.lua();
    if (!L) {
        return;
    }
    sol::object o = (*L)["__re4_reload_mag_slide"];
    if (!o.is<sol::table>()) {
        return;
    }
    auto t = o.as<sol::table>();
    t["push_hold"] = m_push_hold;
    t["shell_dur"] = m_shell_dur;
    t["r9_anlauf"] = m_r9_anlauf;
    t["release_dur"] = m_push.release_dur;
    t["shell_preview"] = m_shell_preview;
    t["eject_preview"] = m_eject_preview;
    if (t["current_mag_joint"].is<::REJoint*>()) {
        m_current_mag_joint = t["current_mag_joint"];
    }
}

void RE4VRReloadAdv::export_module(sol::state& lua) {
    auto t = lua.create_table();
    t["begin_drop"] = [this](::REJoint* j, sol::object wid_o, sol::object dur_o, sol::object exit_o) {
        int32_t wid = wid_o.is<int>() ? wid_o.as<int>() : (wid_o.is<double>() ? (int32_t)wid_o.as<double>() : 0);
        std::optional<float> dur;
        if (dur_o.is<double>()) {
            dur = (float)dur_o.as<double>();
        }
        std::optional<Vec3> ex;
        if (auto v = re4vr::as_vec3(exit_o)) {
            ex = Vec3{v->x, v->y, v->z};
        }
        return begin_drop(j, wid, dur, ex);
    };
    t["cancel"] = [this]() { cancel(); };
    t["is_active"] = [this]() { return is_active(); };
    t["tick"] = [this]() { tick(); };
    t["start_push"] = [this](sol::object w) {
        if (w.is<int>()) {
            start_push(w.as<int>());
        } else if (w.is<double>()) {
            start_push((int32_t)w.as<double>());
        }
    };
    t["stop_push"] = [this]() { stop_push(); };
    t["begin_push_hold"] = [this](sol::object w) {
        if (w.is<int>()) {
            begin_push_hold(w.as<int>());
        } else if (w.is<double>()) {
            begin_push_hold((int32_t)w.as<double>());
        }
    };
    t["end_push_hold"] = [this]() { end_push_hold(); };
    t["push_blend"] = [this]() { return push_blend(); };
    t["push_pos"] = [this](sol::object w) {
        std::optional<int32_t> wid;
        if (w.is<int>()) {
            wid = w.as<int>();
        } else if (w.is<double>()) {
            wid = (int32_t)w.as<double>();
        }
        float x, y, z;
        push_pos(wid, x, y, z);
        return std::make_tuple(x, y, z);
    };
    t["time_mult"] = [this]() { return time_mult(); };
    t["has_shell_keys"] = [this](sol::object w) {
        int32_t wid = w.is<int>() ? w.as<int>() : (w.is<double>() ? (int32_t)w.as<double>() : 0);
        return has_shell_keys(wid);
    };
    t["uses_rev_insert"] = [this](sol::object w) {
        int32_t wid = w.is<int>() ? w.as<int>() : (w.is<double>() ? (int32_t)w.as<double>() : 0);
        return uses_rev_insert(wid);
    };
    t["has_eject_keys"] = [this](sol::object w) {
        int32_t wid = w.is<int>() ? w.as<int>() : (w.is<double>() ? (int32_t)w.as<double>() : 0);
        return has_eject_keys(wid);
    };
    t["apply_shell_keys"] = [this](::RETransform* tf, ::REJoint* j, sol::object w, sol::object tt) {
        int32_t wid = w.is<int>() ? w.as<int>() : (w.is<double>() ? (int32_t)w.as<double>() : 0);
        float t = tt.is<double>() ? (float)tt.as<double>() : 0.0f;
        return apply_shell_keys(tf, j, wid, t);
    };
    t["apply_eject_keys"] = [this](::RETransform* tf, ::REJoint* j, sol::object w, sol::object tt) {
        int32_t wid = w.is<int>() ? w.as<int>() : (w.is<double>() ? (int32_t)w.as<double>() : 0);
        float t = tt.is<double>() ? (float)tt.as<double>() : 0.0f;
        return apply_eject_keys(tf, j, wid, t);
    };
    t["kf_insert_dur"] = [this](sol::object w) -> std::optional<float> {
        int32_t wid = w.is<int>() ? w.as<int>() : (w.is<double>() ? (int32_t)w.as<double>() : 0);
        return kf_insert_dur(wid);
    };
    t["dock_world"] = [this](::RETransform* tf, sol::object w) -> std::optional<Vector3f> {
        int32_t wid = w.is<int>() ? w.as<int>() : (w.is<double>() ? (int32_t)w.as<double>() : 0);
        return dock_world(tf, wid);
    };
    t["dock_local"] = [this](::RETransform* tf, sol::object w) -> std::optional<Vector3f> {
        int32_t wid = w.is<int>() ? w.as<int>() : (w.is<double>() ? (int32_t)w.as<double>() : 0);
        auto p = dock_local(tf, wid);
        if (!p) {
            return std::nullopt;
        }
        return Vector3f{p->x, p->y, p->z};
    };
    using Pose6 = std::tuple<float, float, float, float, float, float>;
    t["shell_pose_at"] = [this](sol::object w, sol::object tt) -> std::optional<Pose6> {
        int32_t wid = w.is<int>() ? w.as<int>() : (w.is<double>() ? (int32_t)w.as<double>() : 0);
        const float prog = tt.is<double>() ? (float)tt.as<double>() : 0.0f;
        auto p = shell_pose_at(wid, prog);
        if (!p) {
            return std::nullopt;
        }
        return Pose6{p->x, p->y, p->z, p->rx, p->ry, p->rz};
    };
    t["eject_pose_at"] = [this](sol::object w, sol::object tt) -> std::optional<Pose6> {
        int32_t wid = w.is<int>() ? w.as<int>() : (w.is<double>() ? (int32_t)w.as<double>() : 0);
        const float prog = tt.is<double>() ? (float)tt.as<double>() : 0.0f;
        auto p = eject_pose_at(wid, prog);
        if (!p) {
            return std::nullopt;
        }
        return Pose6{p->x, p->y, p->z, p->rx, p->ry, p->rz};
    };
    auto pw = lua.create_table();
    for (int32_t w : m_push_wids) {
        pw[w] = true;
    }
    t["PUSH_WIDS"] = pw;
    auto ki = lua.create_table();
    for (int32_t w : m_keyframe_insert) {
        ki[w] = true;
    }
    t["KEYFRAME_INSERT"] = ki;
    auto ke = lua.create_table();
    for (int32_t w : m_keyframe_eject) {
        ke[w] = true;
    }
    t["KEYFRAME_EJECT"] = ke;
    auto sl = lua.create_table();
    sl["x"] = m_shell_live.x;
    sl["y"] = m_shell_live.y;
    sl["z"] = m_shell_live.z;
    sl["rx"] = m_shell_live.rx;
    sl["ry"] = m_shell_live.ry;
    sl["rz"] = m_shell_live.rz;
    t["shell_live"] = sl;
    auto push = lua.create_table();
    push["on"] = m_push.on;
    push["px"] = m_push.px;
    push["py"] = m_push.py;
    push["pz"] = m_push.pz;
    push["rx"] = m_push.rx;
    push["ry"] = m_push.ry;
    push["rz"] = m_push.rz;
    push["release_dur"] = m_push.release_dur;
    t["push"] = push;
    t["shell_dur"] = m_shell_dur;
    t["r9_anlauf"] = m_r9_anlauf;
    t["release_dur"] = m_push.release_dur;
    t["push_hold"] = m_push_hold;
    t["shell_preview"] = m_shell_preview;
    t["eject_preview"] = m_eject_preview;
    t["current_mag_joint"] = sol::nil;
    lua["__re4_reload_mag_slide"] = t;
}

std::optional<std::string> RE4VRReloadAdv::on_initialize() {
    load_json();
    return std::nullopt;
}

void RE4VRReloadAdv::on_lua_state_created(sol::state& lua) {
    load_json();
    export_module(lua);
    re4vr::export_pose_api(lua);
}

void RE4VRReloadAdv::on_lua_state_destroyed(sol::state&) {
    cancel();
    stop_push();
    m_push_tune = false;
    m_shell_preview = false;
    m_eject_preview = false;
}

void RE4VRReloadAdv::on_pre_application_entry(void*, const char*, size_t hash) {
    if (hash != "LockScene"_fnv && hash != "BeginRendering"_fnv) {
        return;
    }
    ScriptProfileGuard guard("re4_vr_reload_adv.lua",
        hash == "LockScene"_fnv ? "on_pre_application_entry:LockScene" : "on_pre_application_entry:BeginRendering",
        re4vr::profile_frame());
    sync_lua_fields();
    push_apply();
}

void RE4VRReloadAdv::on_application_entry(void*, const char*, size_t hash) {
    if (hash != "LateUpdateBehavior"_fnv && hash != "UpdateJointExpression"_fnv && hash != "BeginRendering"_fnv) {
        return;
    }
    ScriptProfileGuard guard("re4_vr_reload_adv.lua", "on_application_entry", re4vr::profile_frame());
    sync_lua_fields();
    if (hash == "LateUpdateBehavior"_fnv || hash == "BeginRendering"_fnv) {
        shell_preview_apply();
        eject_preview_apply();
        tick_preview();
    }
    push_apply();
}
#endif
