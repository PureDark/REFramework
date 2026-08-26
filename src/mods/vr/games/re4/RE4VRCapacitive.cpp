#define NOMINMAX
#include "RE4VRCapacitive.hpp"

#if defined(RE4)
#include "RE4VRShared.hpp"

#include <algorithm>

std::shared_ptr<RE4VRCapacitive>& RE4VRCapacitive::get() {
    static auto inst = std::make_shared<RE4VRCapacitive>();
    return inst;
}

void RE4VRCapacitive::load_json() {
    const auto d = re4vr::load_json_file("re4_vr/re4_vr_capacitive.json");
    if (d.contains("use_analog") && !d["use_analog"].is_null()) {
        m_cfg.use_analog = d["use_analog"].is_boolean() ? d["use_analog"].get<bool>() : (d["use_analog"].is_number() && d["use_analog"].get<double>() != 0.0);
    }
    if (d.contains("prefer_force") && !d["prefer_force"].is_null()) {
        m_cfg.prefer_force = d["prefer_force"].is_boolean() ? d["prefer_force"].get<bool>() : (d["prefer_force"].is_number() && d["prefer_force"].get<double>() != 0.0);
    }
    if (d.contains("press") && d["press"].is_number()) {
        m_cfg.press = d["press"].get<float>();
    }
    if (d.contains("release") && d["release"].is_number()) {
        m_cfg.release = d["release"].get<float>();
    }
    m_cfg.press = std::clamp(m_cfg.press, 0.05f, 0.95f);
    m_cfg.release = std::clamp(m_cfg.release, 0.05f, 0.95f);
    if (m_cfg.release > m_cfg.press) {
        m_cfg.release = m_cfg.press;
    }
}

void RE4VRCapacitive::apply() {
    auto& vr = VR::get();
    if (!vr->is_openxr_loaded()) {
        return;
    }
    vr->set_grip_settings(m_cfg.use_analog, m_cfg.prefer_force, m_cfg.press, m_cfg.release);
}

std::optional<std::string> RE4VRCapacitive::on_initialize() {
    load_json();
    apply();
    return std::nullopt;
}

void RE4VRCapacitive::on_config_load(const utility::Config&) {
    load_json();
    apply();
}

void RE4VRCapacitive::on_frame() {
    ScriptProfileGuard guard("re4_vr_capacitive.lua", "on_frame", re4vr::profile_frame());
    const auto now = std::chrono::steady_clock::now();
    if (now < m_next_push) {
        return;
    }
    m_next_push = now + std::chrono::seconds(2);
    apply();
}
#endif
