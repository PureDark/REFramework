#define NOMINMAX
#include "RE4VRRecoil.hpp"

#if defined(RE4)
#include <algorithm>
#include <cmath>
#include <cstdio>

#include <glm/gtc/constants.hpp>
#include <glm/gtc/quaternion.hpp>
#include <imgui.h>
#include <spdlog/spdlog.h>
#include <sdk/RETypeDB.hpp>
#include <sdk/MurmurHash.hpp>
#include <sdk/Application.hpp>

#include "RE4VRFrameCache.hpp"
#include "RE4VRMenu.hpp"
#include "RE4VRShared.hpp"
#include "../../../ScriptRunner.hpp"

namespace {
const std::unordered_map<int32_t, float> WEAPON_RECOIL_MULTIPLIERS{
    {4000, 1.2f}, {4001, 1.2f}, {4002, 1.2f}, {4003, 1.2f}, {4004, 1.2f}, {4005, 1.4f},
    {4100, 1.8f}, {4101, 1.8f}, {4102, 1.8f},
    {4200, 1.5f}, {4201, 1.5f}, {4202, 1.5f},
    {4400, 1.8f}, {4401, 1.8f}, {4402, 1.8f},
    {4500, 2.0f}, {4501, 2.0f}, {4502, 2.0f},
    {4600, 1.8f},
    {4900, 2.5f}, {4901, 2.5f}, {4902, 2.5f},
    {6000, 1.2f}, {6001, 1.2f},
    {6100, 1.2f}, {6101, 1.2f}, {6102, 1.2f}, {6103, 1.2f}, {6104, 1.2f}, {6105, 1.8f},
    {6106, 1.2f}, {6107, 0.0f}, {6108, 0.0f}, {6111, 1.2f}, {6112, 1.2f}, {6113, 1.2f}, {6114, 1.8f},
    {6300, 1.2f}, {6301, 1.2f}, {6302, 1.2f}, {6304, 1.2f}, {6305, 1.2f},
};
const std::unordered_set<int32_t> WEAPON_AUTO_FLAGS{4005, 4200, 4201, 4202, 4402};

}

std::shared_ptr<RE4VRRecoil>& RE4VRRecoil::get() {
    static auto inst = std::make_shared<RE4VRRecoil>();
    return inst;
}

double RE4VRRecoil::now_clock() const {
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - m_clock_origin).count();
}

void RE4VRRecoil::load_json() {
    auto d = re4vr::load_json_file("re4_vr/re4_vr_recoil.json");
    if (d.empty()) {
        d = re4vr::load_json_file("re4_vr/re4_vr_firstperson.json");
        if (d.empty()) {
            return;
        }
        if (d.contains("enable_recoil") || d.contains("recoil_intensity_multiplier")
            || d.contains("weapon_intensity_overrides") || d.contains("weapon_support_overrides")) {
            if (d.contains("enable_recoil") && !d["enable_recoil"].is_null()) {
                m_cfg.enable_recoil = d["enable_recoil"].is_boolean() ? d["enable_recoil"].get<bool>()
                    : (d["enable_recoil"].is_number() && d["enable_recoil"].get<double>() != 0.0);
            }
            if (d.contains("recoil_intensity_multiplier") && d["recoil_intensity_multiplier"].is_number()) {
                m_cfg.recoil_intensity_multiplier = d["recoil_intensity_multiplier"].get<float>();
            }
            if (d.contains("weapon_intensity_overrides") && d["weapon_intensity_overrides"].is_object()) {
                for (auto it = d["weapon_intensity_overrides"].begin(); it != d["weapon_intensity_overrides"].end(); ++it) {
                    if (it.value().is_number()) {
                        m_weapon_intensity[it.key()] = it.value().get<float>();
                    }
                }
            }
            if (d.contains("weapon_support_overrides") && d["weapon_support_overrides"].is_object()) {
                for (auto it = d["weapon_support_overrides"].begin(); it != d["weapon_support_overrides"].end(); ++it) {
                    if (it.value().is_number()) {
                        m_weapon_support[it.key()] = it.value().get<float>();
                    }
                }
            }
            save_json();
        }
        return;
    }
    if (d.contains("enable_recoil") && !d["enable_recoil"].is_null()) {
        m_cfg.enable_recoil = d["enable_recoil"].is_boolean() ? d["enable_recoil"].get<bool>()
            : (d["enable_recoil"].is_number() && d["enable_recoil"].get<double>() != 0.0);
    }
    if (d.contains("recoil_intensity_multiplier") && d["recoil_intensity_multiplier"].is_number()) {
        m_cfg.recoil_intensity_multiplier = d["recoil_intensity_multiplier"].get<float>();
    }
    if (d.contains("weapon_intensity_overrides") && d["weapon_intensity_overrides"].is_object()) {
        for (auto it = d["weapon_intensity_overrides"].begin(); it != d["weapon_intensity_overrides"].end(); ++it) {
            if (it.value().is_number()) {
                m_weapon_intensity[it.key()] = it.value().get<float>();
            }
        }
    }
    if (d.contains("weapon_support_overrides") && d["weapon_support_overrides"].is_object()) {
        for (auto it = d["weapon_support_overrides"].begin(); it != d["weapon_support_overrides"].end(); ++it) {
            if (it.value().is_number()) {
                m_weapon_support[it.key()] = it.value().get<float>();
            }
        }
    }
}

void RE4VRRecoil::save_json() {
    nlohmann::json out;
    out["enable_recoil"] = m_cfg.enable_recoil;
    out["recoil_intensity_multiplier"] = m_cfg.recoil_intensity_multiplier;
    out["weapon_intensity_overrides"] = m_weapon_intensity;
    out["weapon_support_overrides"] = m_weapon_support;
    re4vr::save_json_file("re4_vr/re4_vr_recoil.json", out);
}

void RE4VRRecoil::load_haptic_json() {
    const auto d = re4vr::load_json_file("re4_vr/re4_vr_haptic.json");
    if (d.contains("enabled") && !d["enabled"].is_null()) {
        m_haptic.enabled = d["enabled"].is_boolean() ? d["enabled"].get<bool>()
            : (d["enabled"].is_number() && d["enabled"].get<double>() != 0.0);
    }
    if (d.contains("amp_solo") && d["amp_solo"].is_number()) {
        m_haptic.amp_solo = d["amp_solo"].get<float>();
    }
    if (d.contains("amp_right_sup") && d["amp_right_sup"].is_number()) {
        m_haptic.amp_right_sup = d["amp_right_sup"].get<float>();
    }
    if (d.contains("amp_left_sup") && d["amp_left_sup"].is_number()) {
        m_haptic.amp_left_sup = d["amp_left_sup"].get<float>();
    }
    if (d.contains("dur") && d["dur"].is_number()) {
        m_haptic.dur = d["dur"].get<float>();
    }
    if (d.contains("freq") && d["freq"].is_number()) {
        m_haptic.freq = d["freq"].get<float>();
    }
    if (d.contains("delay") && d["delay"].is_number()) {
        m_haptic.delay = d["delay"].get<float>();
    }
}

void RE4VRRecoil::publish_vr_recoil() {
    if (m_export_active) {
        RE4VRShared::get()->vr_recoil_pos = m_export_pos;
    } else {
        RE4VRShared::get()->vr_recoil_pos.reset();
    }
}

void RE4VRRecoil::register_ui() {
    if (m_ui_registered) {
        return;
    }
    m_ui_registered = true;
    RE4VRMenu::get()->add(50, "recoil_level", [this]() {
        const float steps[3] = {0.0f, 0.75f, 1.50f};
        const char* labels[3] = {"OFF", "Mid", "Max"};
        const float cur = m_cfg.recoil_intensity_multiplier;
        ImGui::Text("Recoil:");
        for (int i = 0; i < 3; ++i) {
            ImGui::SameLine();
            const bool active = std::abs(cur - steps[i]) < 0.001f;
            if (active) {
                ImGui::PushStyleColor(ImGuiCol_Text, IM_COL32(64, 224, 208, 255));
            }
            if (ImGui::Button((std::string(labels[i]) + "##recoilpublic").c_str())) {
                m_cfg.recoil_intensity_multiplier = steps[i];
                save_json();
            }
            if (active) {
                ImGui::PopStyleColor(1);
            }
        }
    });
}

std::optional<int32_t> RE4VRRecoil::current_weapon_id() {
    if (RE4VRFrameCache::get()->on()) {
        return RE4VRFrameCache::get()->equip_wid();
    }
    auto* ctx = re4vr::player_context();
    if (!re4vr::obj_ok(ctx)) {
        return std::nullopt;
    }
    auto* hu = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_HeadUpdater"); }).value_or(nullptr);
    if (!re4vr::obj_ok(hu)) {
        return std::nullopt;
    }
    return re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(hu, "get_EquipWeaponID"); });
}

std::string RE4VRRecoil::weapon_key(std::optional<int32_t> wid) {
    if (!wid) {
        return {};
    }
    char buf[16]{};
    std::snprintf(buf, sizeof(buf), "wp%04d", *wid);
    return buf;
}

float RE4VRRecoil::effective_weapon_recoil_multiplier(float* out_base) {
    const auto wid = current_weapon_id();
    float base = 1.0f;
    if (wid) {
        auto it = WEAPON_RECOIL_MULTIPLIERS.find(*wid);
        if (it != WEAPON_RECOIL_MULTIPLIERS.end()) {
            base = it->second;
        }
    }
    if (out_base) {
        *out_base = base;
    }
    const auto key = weapon_key(wid);
    float per = 1.0f;
    if (!key.empty()) {
        auto it = m_weapon_intensity.find(key);
        if (it != m_weapon_intensity.end()) {
            per = it->second;
        }
    }
    return base * m_cfg.recoil_intensity_multiplier * per;
}

bool RE4VRRecoil::fp_active() {
    if (!re4vr::call_killswitch_bool("is_active", RE4VRShared::get()->re4_ks_active)) {
        return true;
    }
    if (re4vr::call_killswitch_bool("is_reload_active")) {
        return true;
    }
    if (re4vr::call_killswitch_bool("is_first_person_action_active")) {
        return true;
    }
    if (re4vr::call_killswitch_bool("is_first_person_animation_active")) {
        return true;
    }
    return false;
}

bool RE4VRRecoil::hmd_active() {
    return VR::get()->is_hmd_active();
}

void RE4VRRecoil::on_pre_request_recoil_body() {
    float weapon_base = 1.0f;
    const float weapon_multiplier = effective_weapon_recoil_multiplier(&weapon_base);
    if (!m_cfg.enable_recoil) {
        return;
    }
    if (weapon_multiplier <= 0.0f) {
        return;
    }

    std::uniform_real_distribution<float> dist(0.0f, 1.0f);
    const float random_factor = 1.0f + (dist(m_rng) - 0.5f) * m_cfg.recoil_randomness;
    const float expn = std::clamp(m_cfg.recoil_mult_exponent, 0.1f, 1.0f);
    float total_mult = std::pow(weapon_multiplier, expn) * random_factor;

    bool support_hand_active = false;
    if (RE4VRShared::get()->vr_support_hand_docked) {
        support_hand_active = true;
    } else if (auto bf = RE4VRShared::get()->vr_support_blend_factor) {
        support_hand_active = *bf > 0.5;
    }

    if (support_hand_active) {
        const auto skey = weapon_key(current_weapon_id());
        float sm = m_cfg.recoil_supported_impulse_mult;
        if (!skey.empty()) {
            auto it = m_weapon_support.find(skey);
            if (it != m_weapon_support.end()) {
                sm = it->second;
            }
        }
        if (sm > 0.0f) {
            total_mult *= sm;
        }
    } else {
        const bool heavy = weapon_base >= 2.0f;
        const float um = heavy ? m_cfg.recoil_unsupported_heavy_mult : m_cfg.recoil_unsupported_light_mult;
        if (um > 0.0f) {
            total_mult *= um;
        }
    }

    const auto wid_auto = current_weapon_id();
    if (wid_auto && WEAPON_AUTO_FLAGS.count(*wid_auto)) {
        total_mult *= std::max(0.05f, m_cfg.recoil_auto_scale);
    }

    const float pos_peak = m_cfg.recoil_position_intensity * total_mult;
    const float new_pos_y = pos_peak * 0.6f;
    const float new_pos_z = -pos_peak;
    const float pitch_peak = m_cfg.recoil_rotation_intensity * total_mult
        + (dist(m_rng) - 0.5f) * m_cfg.recoil_vertical_spread * total_mult;
    const float yaw_peak = (dist(m_rng) - 0.5f) * 2.0f * m_cfg.recoil_horizontal_spread * total_mult;

    m_recoil_attack_pos_y += new_pos_y;
    m_recoil_attack_pos_z += new_pos_z;
    m_recoil_attack_pitch += pitch_peak;
    m_recoil_attack_yaw += yaw_peak;

    if (m_cfg.recoil_stack_cap > 0.0f) {
        const float cap_pos = m_cfg.recoil_position_intensity * total_mult * m_cfg.recoil_stack_cap;
        const float cap_rot = m_cfg.recoil_rotation_intensity * total_mult * m_cfg.recoil_stack_cap;
        const float cap_yaw = m_cfg.recoil_horizontal_spread * total_mult * m_cfg.recoil_stack_cap;
        m_recoil_attack_pos_y = std::min(m_recoil_attack_pos_y, cap_pos * 0.6f);
        m_recoil_attack_pos_z = std::max(m_recoil_attack_pos_z, -cap_pos);
        m_recoil_attack_pitch = std::min(m_recoil_attack_pitch, cap_rot);
        m_recoil_attack_yaw = std::clamp(m_recoil_attack_yaw, -cap_yaw, cap_yaw);
    }

    m_recoil_attack_t = 0.0f;
    m_recoil_attack_active = true;
    m_recoil_active = true;
    const double now_shot = now_clock();
    if (!m_recoil_last_t) {
        m_recoil_last_t = now_shot;
    }
    m_recoil_last_shot_t = now_shot;
}

HookManager::PreHookResult RE4VRRecoil::pre_request_recoil(std::vector<uintptr_t>&, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    auto& self = *get();
    if (self.hmd_active()) {
        if (self.fp_active()) {
            self.on_pre_request_recoil_body();
        }
        return HookManager::PreHookResult::SKIP_ORIGINAL;
    }
    if (!self.fp_active()) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    self.on_pre_request_recoil_body();
    return HookManager::PreHookResult::SKIP_ORIGINAL;
}

void RE4VRRecoil::post_nop(uintptr_t&, sdk::RETypeDefinition*, uintptr_t) {}

HookManager::PreHookResult RE4VRRecoil::pre_update_recoil(std::vector<uintptr_t>&, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    auto& self = *get();
    if (self.hmd_active()) {
        return HookManager::PreHookResult::SKIP_ORIGINAL;
    }
    if (!self.fp_active()) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    return HookManager::PreHookResult::SKIP_ORIGINAL;
}

HookManager::PreHookResult RE4VRRecoil::pre_update_handshake(std::vector<uintptr_t>&, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    auto& self = *get();
    if (self.hmd_active()) {
        return HookManager::PreHookResult::SKIP_ORIGINAL;
    }
    if (!self.fp_active()) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    return HookManager::PreHookResult::SKIP_ORIGINAL;
}

void RE4VRRecoil::update_spring_and_export() {
    if (m_recoil_active || m_recoil_attack_active) {
        const double now = now_clock();
        float dt = 0.0f;
        if (m_recoil_last_t) {
            dt = (float)std::min(now - *m_recoil_last_t, 0.05);
        }
        m_recoil_last_t = now;

        if (m_recoil_attack_active && dt > 0.0f) {
            const float T = std::max(m_cfg.recoil_attack_duration, 0.001f);
            m_recoil_attack_t += dt;
            if (m_recoil_attack_t >= T) {
                m_spring_pos_y = m_recoil_attack_pos_y;
                m_spring_pos_z = m_recoil_attack_pos_z;
                m_spring_pitch = m_recoil_attack_pitch;
                m_spring_yaw = m_recoil_attack_yaw;
                m_spring_vel_y = 0.0f;
                m_spring_vel_z = 0.0f;
                m_spring_vel_pitch = 0.0f;
                m_spring_vel_yaw = 0.0f;
                m_recoil_attack_pos_y = 0.0f;
                m_recoil_attack_pos_z = 0.0f;
                m_recoil_attack_pitch = 0.0f;
                m_recoil_attack_yaw = 0.0f;
                m_recoil_attack_t = 0.0f;
                m_recoil_attack_active = false;
            } else {
                const float s = std::sin((m_recoil_attack_t / T) * (glm::pi<float>() * 0.5f));
                m_spring_pos_y = m_recoil_attack_pos_y * s;
                m_spring_pos_z = m_recoil_attack_pos_z * s;
                m_spring_pitch = m_recoil_attack_pitch * s;
                m_spring_yaw = m_recoil_attack_yaw * s;
                m_spring_vel_y = 0.0f;
                m_spring_vel_z = 0.0f;
                m_spring_vel_pitch = 0.0f;
                m_spring_vel_yaw = 0.0f;
            }
        }

        if (!m_recoil_attack_active && dt > 0.0f) {
            const float k = m_cfg.recoil_spring_stiffness;
            float c = m_cfg.recoil_spring_damping;
            if (m_recoil_last_shot_t) {
                const float since_last = (float)(now - *m_recoil_last_shot_t);
                const float win = std::max(0.01f, m_cfg.recoil_sustained_window);
                if (since_last < win) {
                    const float t_blend = 1.0f - (since_last / win);
                    c = c + (m_cfg.recoil_sustained_damping - c) * t_blend;
                }
            }
            const int steps = std::max(1, (int)std::floor(dt / 0.008f));
            const float sub = dt / (float)steps;
            for (int i = 0; i < steps; ++i) {
                const float ay = -k * m_spring_pos_y - c * m_spring_vel_y;
                m_spring_vel_y += ay * sub;
                m_spring_pos_y += m_spring_vel_y * sub;
                const float az = -k * m_spring_pos_z - c * m_spring_vel_z;
                m_spring_vel_z += az * sub;
                m_spring_pos_z += m_spring_vel_z * sub;
                const float ap = -k * m_spring_pitch - c * m_spring_vel_pitch;
                m_spring_vel_pitch += ap * sub;
                m_spring_pitch += m_spring_vel_pitch * sub;
                const float aw = -k * m_spring_yaw - c * m_spring_vel_yaw;
                m_spring_vel_yaw += aw * sub;
                m_spring_yaw += m_spring_vel_yaw * sub;
            }
            const float pos_mag = std::abs(m_spring_pos_y) + std::abs(m_spring_pos_z);
            const float rot_mag = std::abs(m_spring_pitch) + std::abs(m_spring_yaw);
            const float vel_mag = std::abs(m_spring_vel_y) + std::abs(m_spring_vel_z)
                + std::abs(m_spring_vel_pitch) + std::abs(m_spring_vel_yaw);
            if (pos_mag < 0.00005f && rot_mag < 0.0002f && vel_mag < 0.001f) {
                m_spring_pos_y = 0.0f;
                m_spring_pos_z = 0.0f;
                m_spring_vel_y = 0.0f;
                m_spring_vel_z = 0.0f;
                m_spring_pitch = 0.0f;
                m_spring_yaw = 0.0f;
                m_spring_vel_pitch = 0.0f;
                m_spring_vel_yaw = 0.0f;
                m_recoil_active = false;
                m_recoil_last_t.reset();
            }
        }
    }

    if (m_cfg.enable_recoil && (m_recoil_active || m_recoil_attack_active)) {
        m_export_pos = Vector3f{0.0f, m_spring_pos_y, m_spring_pos_z};
        constexpr float PITCH_KICK_GAIN = 2.0f;
        const float ph = -(m_spring_pitch * PITCH_KICK_GAIN) * 0.5f;
        const float yw = m_spring_yaw * 0.5f;
        const glm::quat pitch_q{std::cos(ph), std::sin(ph), 0.0f, 0.0f};
        const glm::quat yaw_q{std::cos(yw), 0.0f, std::sin(yw), 0.0f};
        m_export_rot = glm::normalize(pitch_q * yaw_q);
        m_export_active = true;
    } else {
        m_export_pos = Vector3f{0.0f, 0.0f, 0.0f};
        m_export_rot = glm::identity<glm::quat>();
        m_export_active = false;
    }
    publish_vr_recoil();
}

void RE4VRRecoil::haptic_pulse(uint64_t handle, float amp) {
    if (handle == 0 || amp <= 0.0f) {
        return;
    }
    re4vr::pcall([&] {
        VR::get()->trigger_haptic_vibration(0.0f, m_haptic.dur, m_haptic.freq, amp, (vr::VRInputValueHandle_t)handle);
    });
}

void RE4VRRecoil::haptic_fire(bool support) {
    auto& vr = VR::get();
    haptic_pulse((uint64_t)vr->get_right_joystick(), support ? m_haptic.amp_right_sup : m_haptic.amp_solo);
    if (support) {
        haptic_pulse((uint64_t)vr->get_left_joystick(), m_haptic.amp_left_sup);
    }
}

void RE4VRRecoil::haptic_tick() {
    if (RE4VRShared::get()->re4_ks_active) {
        return;
    }
    if (!m_haptic.enabled) {
        return;
    }
    if (!VR::get()->is_hmd_active()) {
        return;
    }
    const double now = now_clock();
    for (size_t i = 0; i < m_pending.size();) {
        if (now >= m_pending[i].at) {
            haptic_fire(m_pending[i].support);
            m_pending.erase(m_pending.begin() + (std::ptrdiff_t)i);
        } else {
            ++i;
        }
    }
    const double seq = RE4VRShared::get()->vr_shot_seq.value_or(0.0);
    if (!m_last_seq) {
        m_last_seq = seq;
        return;
    }
    if (seq <= *m_last_seq) {
        return;
    }
    m_last_seq = seq;
    const bool support = RE4VRShared::get()->vr_support_hand_docked;
    if (m_haptic.delay <= 0.0f) {
        haptic_fire(support);
    } else {
        m_pending.push_back(PendingPulse{now + m_haptic.delay, support});
    }
}

std::optional<std::string> RE4VRRecoil::on_initialize() {
    load_json();
    load_haptic_json();
    if (auto* td = sdk::find_type_definition("chainsaw.PlayerCameraController")) {
        if (auto* m = td->get_method("requestRecoil(chainsaw.CameraRecoilParam)")) {
            g_hookman.add(m, &RE4VRRecoil::pre_request_recoil, &RE4VRRecoil::post_nop);
        } else if (auto* m2 = td->get_method("requestRecoil")) {
            g_hookman.add(m2, &RE4VRRecoil::pre_request_recoil, &RE4VRRecoil::post_nop);
        }
        if (auto* m = td->get_method("updateRecoil")) {
            g_hookman.add(m, &RE4VRRecoil::pre_update_recoil, &RE4VRRecoil::post_nop);
        }
        if (auto* m = td->get_method("updateHandShake")) {
            g_hookman.add(m, &RE4VRRecoil::pre_update_handshake, &RE4VRRecoil::post_nop);
        }
        spdlog::info("[RE4VRRecoil] Hooked PlayerCameraController recoil methods");
    }
    register_ui();
    return std::nullopt;
}

void RE4VRRecoil::on_config_load(const utility::Config&) {
    load_json();
    load_haptic_json();
}

void RE4VRRecoil::on_lua_state_created(sol::state& lua) {
    auto t = lua.create_table();
    t["position"] = Vector3f{0.0f, 0.0f, 0.0f};
    t["rotation"] = glm::identity<glm::quat>();
    t["active"] = false;
    lua["vr_recoil"] = t;
    lua["__re4_vr_recoil_hooks_installed"] = true;
    register_ui();
}

void RE4VRRecoil::on_lua_state_destroyed(sol::state&) {
    m_last_seq.reset();
    m_pending.clear();
}

void RE4VRRecoil::on_frame() {
    ScriptProfileGuard guard("re4_vr_recoil.lua", "on_frame", re4vr::profile_frame());
    haptic_tick();
}

void RE4VRRecoil::on_application_entry(void*, const char*, size_t hash) {
    if (hash != "LateUpdateBehavior"_fnv) {
        return;
    }
    ScriptProfileGuard guard("re4_vr_recoil.lua", "on_application_entry:LateUpdateBehavior", re4vr::profile_frame());
    update_spring_and_export();
}
#endif
