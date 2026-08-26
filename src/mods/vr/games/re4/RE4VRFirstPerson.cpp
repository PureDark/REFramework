#define NOMINMAX
#include "RE4VRFirstPerson.hpp"

#if defined(RE4)
#include <algorithm>
#include <cmath>

#include <glm/gtc/constants.hpp>
#include <glm/gtc/quaternion.hpp>
#include <glm/gtx/quaternion.hpp>
#include <spdlog/spdlog.h>

#include <sdk/SceneManager.hpp>
#include <sdk/RETypeDB.hpp>
#include <sdk/REString.hpp>
#include <sdk/REGameObject.hpp>
#include <sdk/SystemArray.hpp>
#include <sdk/MurmurHash.hpp>
#include <sdk/Application.hpp>
#include <utility/String.hpp>

#include "RE4VRFrameCache.hpp"
#include "RE4VRKillswitch.hpp"
#include "RE4VRScope.hpp"
#include "RE4VRShared.hpp"
#include "../../../ScriptRunner.hpp"

namespace {
constexpr float CAPY_TAU = 0.12f;
constexpr float CROUCH_CAM_WINDOW = 0.8f;
constexpr float STANDUP_WINDOW = 0.5f;

Vector3f v3(const Vector4f& v) {
    return Vector3f{v.x, v.y, v.z};
}

bool json_bool(const nlohmann::json& d, const char* k, bool cur) {
    if (!d.contains(k) || d[k].is_null()) {
        return cur;
    }
    if (d[k].is_boolean()) {
        return d[k].get<bool>();
    }
    if (d[k].is_number()) {
        return d[k].get<double>() != 0.0;
    }
    return cur;
}

float json_num(const nlohmann::json& d, const char* k, float cur) {
    if (d.contains(k) && d[k].is_number()) {
        return d[k].get<float>();
    }
    return cur;
}

std::optional<glm::quat> flat_yaw_from_fwd(Vector3f fwd) {
    fwd.y = 0.0f;
    const float len = std::sqrt(fwd.x * fwd.x + fwd.z * fwd.z);
    if (len < 0.0001f) {
        return std::nullopt;
    }
    fwd = Vector3f{fwd.x / len, 0.0f, fwd.z / len};
    const auto mat = glm::rowMajor4(glm::lookAtLH(Vector3f{0.0f, 0.0f, 0.0f}, fwd, Vector3f{0.0f, 1.0f, 0.0f}));
    return glm::quat{mat};
}

int32_t resolve_static_enum(const char* type_name, const char* field, int32_t fallback) {
    auto* t = sdk::find_type_definition(type_name);
    if (!t) {
        return fallback;
    }
    for (auto* fld : t->get_fields()) {
        if (!fld || !fld->is_static()) {
            continue;
        }
        if (std::string{fld->get_name()} == field) {
            return fld->get_data<int32_t>(nullptr);
        }
    }
    return fallback;
}
}

std::shared_ptr<RE4VRFirstPerson>& RE4VRFirstPerson::get() {
    static auto inst = std::make_shared<RE4VRFirstPerson>();
    return inst;
}

double RE4VRFirstPerson::now_clock() const {
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - m_clock_origin).count();
}

void RE4VRFirstPerson::load_json() {
    const auto d = re4vr::load_json_file("re4_vr/re4_vr_firstperson.json");
    m_cfg.off_x = json_num(d, "off_x", m_cfg.off_x);
    m_cfg.off_y = json_num(d, "off_y", m_cfg.off_y);
    m_cfg.off_z = json_num(d, "off_z", m_cfg.off_z);
    m_cfg.cart_off_x = json_num(d, "cart_off_x", m_cfg.cart_off_x);
    m_cfg.cart_off_y = json_num(d, "cart_off_y", m_cfg.cart_off_y);
    m_cfg.cart_off_z = json_num(d, "cart_off_z", m_cfg.cart_off_z);
    m_cfg.headpin_fade_dur = json_num(d, "headpin_fade_dur", m_cfg.headpin_fade_dur);
    m_cfg.block_force_twirler = json_bool(d, "block_force_twirler", m_cfg.block_force_twirler);
    m_cfg.event_off_x = json_num(d, "event_off_x", m_cfg.event_off_x);
    m_cfg.event_off_y = json_num(d, "event_off_y", m_cfg.event_off_y);
    m_cfg.event_off_z = json_num(d, "event_off_z", m_cfg.event_off_z);
    m_cfg.event2_off_x = json_num(d, "event2_off_x", m_cfg.event2_off_x);
    m_cfg.event2_off_y = json_num(d, "event2_off_y", m_cfg.event2_off_y);
    m_cfg.event2_off_z = json_num(d, "event2_off_z", m_cfg.event2_off_z);
    m_cfg.event3_off_x = json_num(d, "event3_off_x", m_cfg.event3_off_x);
    m_cfg.event3_off_y = json_num(d, "event3_off_y", m_cfg.event3_off_y);
    m_cfg.event3_off_z = json_num(d, "event3_off_z", m_cfg.event3_off_z);
    m_cfg.event4_off_x = json_num(d, "event4_off_x", m_cfg.event4_off_x);
    m_cfg.event4_off_y = json_num(d, "event4_off_y", m_cfg.event4_off_y);
    m_cfg.event4_off_z = json_num(d, "event4_off_z", m_cfg.event4_off_z);
    m_cfg.event5_mono = json_bool(d, "event5_mono", m_cfg.event5_mono);
    m_cfg.event5_off_x = json_num(d, "event5_off_x", m_cfg.event5_off_x);
    m_cfg.event5_off_y = json_num(d, "event5_off_y", m_cfg.event5_off_y);
    m_cfg.event5_off_z = json_num(d, "event5_off_z", m_cfg.event5_off_z);
    m_cfg.event6_off_x = json_num(d, "event6_off_x", m_cfg.event6_off_x);
    m_cfg.event6_off_y = json_num(d, "event6_off_y", m_cfg.event6_off_y);
    m_cfg.event6_off_z = json_num(d, "event6_off_z", m_cfg.event6_off_z);
    m_cfg.turret_off_x = json_num(d, "turret_off_x", m_cfg.turret_off_x);
    m_cfg.turret_off_y = json_num(d, "turret_off_y", m_cfg.turret_off_y);
    m_cfg.turret_off_z = json_num(d, "turret_off_z", m_cfg.turret_off_z);
    m_cfg.jetski_off_x = json_num(d, "jetski_off_x", m_cfg.jetski_off_x);
    m_cfg.jetski_off_y = json_num(d, "jetski_off_y", m_cfg.jetski_off_y);
    m_cfg.jetski_off_z = json_num(d, "jetski_off_z", m_cfg.jetski_off_z);
    m_cfg.boat_off_x = json_num(d, "boat_off_x", m_cfg.boat_off_x);
    m_cfg.boat_off_y = json_num(d, "boat_off_y", m_cfg.boat_off_y);
    m_cfg.boat_off_z = json_num(d, "boat_off_z", m_cfg.boat_off_z);
    m_cfg.begcrouch_off_x = json_num(d, "begcrouch_off_x", m_cfg.begcrouch_off_x);
    m_cfg.begcrouch_off_y = json_num(d, "begcrouch_off_y", m_cfg.begcrouch_off_y);
    m_cfg.begcrouch_off_z = json_num(d, "begcrouch_off_z", m_cfg.begcrouch_off_z);
    m_cfg.ada_fc_off_x = json_num(d, "ada_fc_off_x", m_cfg.ada_fc_off_x);
    m_cfg.ada_fc_off_y = json_num(d, "ada_fc_off_y", m_cfg.ada_fc_off_y);
    m_cfg.ada_fc_off_z = json_num(d, "ada_fc_off_z", m_cfg.ada_fc_off_z);
    m_cfg.ada_box_off_x = json_num(d, "ada_box_off_x", m_cfg.ada_box_off_x);
    m_cfg.ada_box_off_y = json_num(d, "ada_box_off_y", m_cfg.ada_box_off_y);
    m_cfg.ada_box_off_z = json_num(d, "ada_box_off_z", m_cfg.ada_box_off_z);
    m_cfg.leon_fc_off_x = json_num(d, "leon_fc_off_x", m_cfg.leon_fc_off_x);
    m_cfg.leon_fc_off_y = json_num(d, "leon_fc_off_y", m_cfg.leon_fc_off_y);
    m_cfg.leon_fc_off_z = json_num(d, "leon_fc_off_z", m_cfg.leon_fc_off_z);
    m_cfg.leon_evt_off_x = json_num(d, "leon_evt_off_x", m_cfg.leon_evt_off_x);
    m_cfg.leon_evt_off_y = json_num(d, "leon_evt_off_y", m_cfg.leon_evt_off_y);
    m_cfg.leon_evt_off_z = json_num(d, "leon_evt_off_z", m_cfg.leon_evt_off_z);
    m_cfg.acrouch_off_x = json_num(d, "acrouch_off_x", m_cfg.acrouch_off_x);
    m_cfg.acrouch_off_y = json_num(d, "acrouch_off_y", m_cfg.acrouch_off_y);
    m_cfg.acrouch_off_z = json_num(d, "acrouch_off_z", m_cfg.acrouch_off_z);
    m_cfg.movement_stabilization = json_bool(d, "movement_stabilization", m_cfg.movement_stabilization);
    m_cfg.movement_follows_hmd = json_bool(d, "movement_follows_hmd", m_cfg.movement_follows_hmd);
    m_cfg.bob_tau = json_num(d, "bob_tau", m_cfg.bob_tau);
    m_cfg.surge_tau = json_num(d, "surge_tau", m_cfg.surge_tau);
    m_cfg.crouch_cam_lerp = json_bool(d, "crouch_cam_lerp", m_cfg.crouch_cam_lerp);
    m_cfg.crouch_cam_tau = json_num(d, "crouch_cam_tau", m_cfg.crouch_cam_tau);
    m_cfg.standup_cam_track = json_bool(d, "standup_cam_track", m_cfg.standup_cam_track);
    m_cfg.hide_streaming_dummy = json_bool(d, "hide_streaming_dummy", m_cfg.hide_streaming_dummy);
    m_cfg.recenter_on_killswitch = json_bool(d, "recenter_on_killswitch", m_cfg.recenter_on_killswitch);
    m_cfg.bino_start = json_num(d, "bino_start", m_cfg.bino_start);
    m_cfg.bino_min = json_num(d, "bino_min", m_cfg.bino_min);
    m_cfg.bino_max = json_num(d, "bino_max", m_cfg.bino_max);
    m_cfg.bino_speed = json_num(d, "bino_speed", m_cfg.bino_speed);
}

void RE4VRFirstPerson::publish_bino() {
    RE4VRShared::get()->re4_bino_start = m_cfg.bino_start;
    RE4VRShared::get()->re4_bino_min = m_cfg.bino_min;
    RE4VRShared::get()->re4_bino_max = m_cfg.bino_max;
    RE4VRShared::get()->re4_bino_speed = m_cfg.bino_speed;
}

void RE4VRFirstPerson::publish_camera_fix(bool active, const Vector3f* pos, const glm::quat* rot) {
    RE4VRShared::get()->vr_camera_fix_active = active;
    if (pos) {
        RE4VRShared::get()->vr_camera_fix_pos = *pos;
    }
    if (rot) {
        RE4VRShared::get()->vr_camera_fix_rot = *rot;
    }
    if (!active) {
        RE4VRShared::get()->vr_camera_fix_pos.reset();
        RE4VRShared::get()->vr_camera_fix_rot.reset();
    }
}

bool RE4VRFirstPerson::fp_perf_on() const {
    return !RE4VRShared::get()->re4_fp_perf_off;
}

std::optional<int32_t> RE4VRFirstPerson::fp_stage_cached() {
    auto* ctx = re4vr::player_context();
    if (!re4vr::obj_ok(ctx)) {
        return std::nullopt;
    }
    if (!fp_perf_on()) {
        return re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(ctx, "get_CurrentStageID"); });
    }
    if (m_fp_stage_f == m_fp_frame) {
        return m_fp_stage;
    }
    m_fp_stage = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(ctx, "get_CurrentStageID"); });
    m_fp_stage_f = m_fp_frame;
    return m_fp_stage;
}

::REManagedObject* RE4VRFirstPerson::fp_busy_cached() {
    auto* sys = re4vr::camera_system();
    auto get_busy = [&]() -> ::REManagedObject* {
        auto* main = sys ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(sys, "get_MainCameraController"); }).value_or(nullptr) : nullptr;
        return main ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(main, "get_BusyCameraController"); }).value_or(nullptr) : nullptr;
    };
    if (!fp_perf_on()) {
        return get_busy();
    }
    if (m_fp_busy_f == m_fp_frame) {
        return m_fp_busy;
    }
    m_fp_busy = get_busy();
    m_fp_busy_f = m_fp_frame;
    return m_fp_busy;
}

std::string RE4VRFirstPerson::body_name() {
    auto* body = re4vr::body_game_object();
    if (!re4vr::obj_ok((::REManagedObject*)body)) {
        return {};
    }
    auto* nm = re4vr::safe([&] { return sdk::call_object_func_easy<::SystemString*>(body, "get_Name"); }).value_or(nullptr);
    return nm ? utility::re_string::get_string(nm) : std::string{};
}

bool RE4VRFirstPerson::is_ada_now() {
    return body_name() == "ch3a8z0_body";
}

bool RE4VRFirstPerson::is_ashley_now() {
    return body_name() == "ch0a1z0_body";
}

bool RE4VRFirstPerson::joint_valid(::REJoint* j) {
    if (!j || !utility::re_managed_object::is_managed_object(j)) {
        return false;
    }
    return re4vr::pcall([&] { (void)sdk::get_joint_position(j); });
}

::REJoint* RE4VRFirstPerson::get_camera_joint() {
    auto* cam = sdk::get_primary_camera();
    if (!cam) {
        return nullptr;
    }
    auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(cam, "get_GameObject"); }).value_or(nullptr);
    if (!re4vr::obj_ok((::REManagedObject*)go)) {
        return nullptr;
    }
    auto* tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr);
    if (!tf) {
        return nullptr;
    }
    auto* joints = sdk::get_transform_joints(tf);
    if (!joints || joints->get_size() == 0) {
        return nullptr;
    }
    return (::REJoint*)joints->get_element(0);
}

::REJoint* RE4VRFirstPerson::get_head_joint() {
    if (joint_valid(m_head_joint)) {
        return m_head_joint;
    }
    m_head_joint = nullptr;
    auto* btf = re4vr::body_transform();
    if (!btf) {
        return nullptr;
    }
    auto* j = sdk::get_transform_joint_by_name(btf, L"Head");
    if (joint_valid(j)) {
        m_head_joint = j;
        return j;
    }
    return nullptr;
}

bool RE4VRFirstPerson::active() {
    if (!VR::get()->is_hmd_active()) {
        return false;
    }
    if (re4vr::call_killswitch_bool("is_active", RE4VRShared::get()->re4_ks_active)) {
        const bool keep = re4vr::call_killswitch_bool("is_ks2")
            || re4vr::call_killswitch_bool("is_ks3")
            || re4vr::call_killswitch_bool("is_ks4")
            || re4vr::call_killswitch_bool("is_ks5");
        if (!keep) {
            return false;
        }
    }
    return true;
}

std::optional<glm::quat> RE4VRFirstPerson::get_game_cam_yaw() {
    auto* busy = fp_busy_cached();
    if (!re4vr::obj_ok(busy) || !m_player_cam_td) {
        return std::nullopt;
    }
    if (!utility::re_managed_object::is_a(busy, "chainsaw.PlayerCameraController")) {
        return std::nullopt;
    }
    auto cam_rot = re4vr::safe([&] {
        if (auto* f = sdk::get_object_field<glm::quat>(busy, "_CameraRotation")) {
            return *f;
        }
        return sdk::call_object_func_easy<glm::quat>(busy, "get_CameraRotation");
    });
    if (!cam_rot) {
        return std::nullopt;
    }
    return flat_yaw_from_fwd(*cam_rot * Vector3f{0, 0, 1});
}

std::optional<glm::quat> RE4VRFirstPerson::get_primary_cam_flat_yaw() {
    auto* cam = sdk::get_primary_camera();
    if (!cam) {
        return std::nullopt;
    }
    auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(cam, "get_GameObject"); }).value_or(nullptr);
    auto* tf = go ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr) : nullptr;
    if (!tf) {
        return std::nullopt;
    }
    const auto rot = sdk::get_transform_rotation(tf);
    return flat_yaw_from_fwd(rot * Vector3f{0, 0, 1});
}

::REManagedObject* RE4VRFirstPerson::get_player_cam() {
    auto* busy = fp_busy_cached();
    if (!re4vr::obj_ok(busy)) {
        return nullptr;
    }
    if (!utility::re_managed_object::is_a(busy, "chainsaw.PlayerCameraController")) {
        return nullptr;
    }
    return busy;
}

Vector3f RE4VRFirstPerson::apply_bob_filter(const Vector3f& hp, bool frame_tick) {
    const float tau = m_cfg.bob_tau;
    if (tau <= 0.001f) {
        m_bob_ema.reset();
        return hp;
    }
    if (m_cfg.standup_cam_track && m_crouch_standup_until && now_clock() < *m_crouch_standup_until) {
        m_bob_ema.reset();
    }
    auto* btf = re4vr::body_transform();
    if (!btf) {
        return hp;
    }
    auto bp = v3(sdk::get_transform_position(btf));
    if (frame_tick) {
        const double nowc = now_clock();
        const float dtc = m_capy_last_t ? (float)std::min(nowc - *m_capy_last_t, 0.1) : 0.016f;
        m_capy_last_t = nowc;
        if (!m_capy_ema || std::abs(bp.y - *m_capy_ema) > 0.5f) {
            m_capy_ema = bp.y;
        } else {
            const float ac = 1.0f - std::exp(-dtc / CAPY_TAU);
            m_capy_ema = *m_capy_ema + (bp.y - *m_capy_ema) * ac;
        }
    }
    if (m_capy_ema) {
        bp.y = *m_capy_ema;
    }
    const Vector3f rel{hp.x - bp.x, hp.y - bp.y, hp.z - bp.z};
    if (!m_bob_ema) {
        m_bob_ema = rel;
        return hp;
    }
    auto e = *m_bob_ema;
    const float dx = rel.x - e.x, dy = rel.y - e.y, dz = rel.z - e.z;
    if ((dx * dx + dy * dy + dz * dz) > 0.25f) {
        m_bob_ema = rel;
        return hp;
    }
    if (frame_tick) {
        const double now = now_clock();
        const float dt = m_bob_last_t ? (float)std::min(now - *m_bob_last_t, 0.1) : 0.016f;
        m_bob_last_t = now;
        const float a = 1.0f - std::exp(-dt / tau);
        e = Vector3f{e.x + dx * a, e.y + dy * a, e.z + dz * a};
        m_bob_ema = e;
    }
    return Vector3f{bp.x + e.x, bp.y + e.y, bp.z + e.z};
}

Vector3f RE4VRFirstPerson::apply_surge_filter(const Vector3f& hp, const std::optional<Vector3f>& bp, bool frame_tick) {
    const float tau = m_cfg.surge_tau;
    if (tau <= 0.001f || !bp) {
        m_surge_px.reset();
        RE4VRShared::get()->vr_surge_dx.reset();
        RE4VRShared::get()->vr_surge_dz.reset();
        return hp;
    }
    if (frame_tick) {
        const double now = now_clock();
        const float dt = m_surge_last_t ? (float)std::min(now - *m_surge_last_t, 0.1) : 0.016f;
        m_surge_last_t = now;
        if (!m_surge_px || !m_surge_lx) {
            m_surge_px = bp->x;
            m_surge_pz = bp->z;
            m_surge_vx = 0.0f;
            m_surge_vz = 0.0f;
        } else {
            const float rvx = (bp->x - *m_surge_lx) / dt;
            const float rvz = (bp->z - *m_surge_lz) / dt;
            const float rspeed = std::sqrt(rvx * rvx + rvz * rvz);
            const float ex = bp->x - *m_surge_px;
            const float ez = bp->z - *m_surge_pz;
            if ((ex * ex + ez * ez) > 1.0f) {
                m_surge_px = bp->x;
                m_surge_pz = bp->z;
                m_surge_vx = 0.0f;
                m_surge_vz = 0.0f;
            } else if (rspeed < 0.3f) {
                const float a = 1.0f - std::exp(-dt / 0.07f);
                m_surge_px = *m_surge_px + ex * a;
                m_surge_pz = *m_surge_pz + ez * a;
                m_surge_vx = 0.0f;
                m_surge_vz = 0.0f;
            } else {
                float yaw_rate = 0.0f;
                if (auto* btf2 = re4vr::body_transform()) {
                    const auto br = sdk::get_transform_rotation(btf2);
                    const auto f = br * Vector3f{0.0f, 0.0f, 1.0f};
                    const float yl = std::sqrt(f.x * f.x + f.z * f.z);
                    if (yl > 0.0001f) {
                        const float yaw = std::atan2(f.x / yl, f.z / yl);
                        if (m_surge_lyaw) {
                            float dyw = yaw - *m_surge_lyaw;
                            if (dyw > glm::pi<float>()) {
                                dyw -= 2.0f * glm::pi<float>();
                            } else if (dyw < -glm::pi<float>()) {
                                dyw += 2.0f * glm::pi<float>();
                            }
                            yaw_rate = std::abs(dyw) / dt;
                        }
                        m_surge_lyaw = yaw;
                    }
                }
                if (yaw_rate > glm::radians(60.0f)) {
                    m_surge_turn_n += 1;
                } else {
                    m_surge_turn_n = 0;
                }
                if (m_surge_turn_n >= 3) {
                    const float a = 1.0f - std::exp(-dt / 0.07f);
                    m_surge_px = *m_surge_px + ex * a;
                    m_surge_pz = *m_surge_pz + ez * a;
                    m_surge_vx = rvx;
                    m_surge_vz = rvz;
                } else {
                    const float av = 1.0f - std::exp(-dt / tau);
                    m_surge_vx += (rvx - m_surge_vx) * av;
                    m_surge_vz += (rvz - m_surge_vz) * av;
                    m_surge_px = *m_surge_px + m_surge_vx * dt;
                    m_surge_pz = *m_surge_pz + m_surge_vz * dt;
                    const float fx0 = bp->x - *m_surge_px;
                    const float fz0 = bp->z - *m_surge_pz;
                    const float fl0 = std::sqrt(fx0 * fx0 + fz0 * fz0);
                    if (fl0 > 0.10f) {
                        float t = (fl0 - 0.10f) / 0.15f;
                        if (t > 1.0f) {
                            t = 1.0f;
                        }
                        const float ap = (1.0f - std::exp(-dt / 0.15f)) * t * t;
                        m_surge_px = *m_surge_px + fx0 * ap;
                        m_surge_pz = *m_surge_pz + fz0 * ap;
                    }
                }
                const float fx = bp->x - *m_surge_px;
                const float fz = bp->z - *m_surge_pz;
                const float fl = std::sqrt(fx * fx + fz * fz);
                if (fl > 0.25f) {
                    const float s = 1.0f - (0.25f / fl);
                    m_surge_px = *m_surge_px + fx * s;
                    m_surge_pz = *m_surge_pz + fz * s;
                }
            }
        }
        m_surge_lx = bp->x;
        m_surge_lz = bp->z;
    }
    if (!m_surge_px) {
        RE4VRShared::get()->vr_surge_dx.reset();
        RE4VRShared::get()->vr_surge_dz.reset();
        return hp;
    }
    RE4VRShared::get()->vr_surge_dx = *m_surge_px - bp->x;
    RE4VRShared::get()->vr_surge_dz = *m_surge_pz - bp->z;
    return Vector3f{hp.x + (*m_surge_px - bp->x), hp.y, hp.z + (*m_surge_pz - bp->z)};
}

bool RE4VRFirstPerson::is_crouch_now() {
    return re4vr::call_killswitch_bool("is_crouch_active");
}

float RE4VRFirstPerson::apply_crouch_cam_lerp(float y, bool frame_tick) {
    const bool crouching = is_crouch_now();
    const double now = now_clock();
    if (crouching && !m_crouch_was) {
        m_crouch_until_t = now + CROUCH_CAM_WINDOW;
        m_crouch_ema = y;
        m_crouch_last_t = now;
    } else if (!crouching && m_crouch_was) {
        m_crouch_standup_until = now + STANDUP_WINDOW;
        m_crouch_until_t.reset();
    }
    m_crouch_was = crouching;

    const float tau = m_cfg.crouch_cam_tau;
    if (!m_cfg.crouch_cam_lerp || tau <= 0.001f) {
        m_crouch_ema = y;
        m_crouch_until_t.reset();
        return y;
    }
    const bool in_window = m_crouch_until_t && now < *m_crouch_until_t && crouching;
    if (!in_window) {
        m_crouch_ema = y;
        m_crouch_until_t.reset();
        return y;
    }
    if (!m_crouch_ema) {
        m_crouch_ema = y;
    }
    if (frame_tick) {
        const float dt = m_crouch_last_t ? (float)std::min(now - *m_crouch_last_t, 0.1) : 0.016f;
        m_crouch_last_t = now;
        if (y < *m_crouch_ema) {
            const float a = 1.0f - std::exp(-dt / tau);
            m_crouch_ema = *m_crouch_ema + (y - *m_crouch_ema) * a;
        } else {
            m_crouch_ema = y;
        }
        if (std::abs(*m_crouch_ema - y) < 0.005f) {
            m_crouch_until_t.reset();
        }
    }
    return *m_crouch_ema;
}

bool RE4VRFirstPerson::on_ladder_climb() {
    if (!(re4vr::call_killswitch_bool("is_ks2") || re4vr::call_killswitch_bool("is_ks4"))) {
        return false;
    }
    auto* ctx = re4vr::player_context();
    return re4vr::obj_ok(ctx) && re4vr::safe([&] { return sdk::call_object_func_easy<bool>(ctx, "get_IsLadder"); }).value_or(false);
}

bool RE4VRFirstPerson::is_gimmick_ks3_now() {
    return RE4VRKillswitch::get()->get_activating_controller().value_or("") == "ks3_gimmick";
}

void RE4VRFirstPerson::compute_and_set(bool frame_tick) {
    if (!active()) {
        publish_camera_fix(false);
        return;
    }
    auto* hj = get_head_joint();
    if (!hj) {
        publish_camera_fix(false);
        return;
    }

    const bool grappled_now = RE4VRShared::get()->re4_grappled_active;
    const bool boxbreak_now = RE4VRShared::get()->re4_boxbreak_active;
    const bool ashley_ev_now = is_gimmick_ks3_now();
    const bool ladder_now = on_ladder_climb();
    const bool fatalkick_now = RE4VRShared::get()->re4_fatalkick_active;
    const bool forcecrouch_now = RE4VRShared::get()->re4_forcecrouch_active;
    const bool gondola_now = RE4VRShared::get()->re4_gondola_active;
    const bool jetski_now = RE4VRShared::get()->re4_jetski_active;
    const bool boat_now = RE4VRShared::get()->re4_boat_active;
    const bool begcrouch_now = RE4VRShared::get()->re4_forcecrouch_ks4_active;
    const bool ks2_now = re4vr::call_killswitch_bool("is_ks2");
    const bool ks4_now = re4vr::call_killswitch_bool("is_ks4");
    const bool headpin_now = grappled_now || boxbreak_now || ashley_ev_now || ladder_now || ks2_now
        || fatalkick_now || forcecrouch_now || gondola_now || jetski_now || boat_now || begcrouch_now || ks4_now;
    const bool cart_now = RE4VRShared::get()->re4_railcar_mode
        || RE4VRShared::get()->re4_minecart_ks4_active
        || RE4VRShared::get()->re4_minecart2_ks4_active;

    if (cart_now || headpin_now) {
        const auto head = v3(sdk::get_joint_position(hj));
        Vector3f cam_pos = head;
        float ax = 0, ay = 0, az = 0;
        if (cart_now) {
            ax = m_cfg.cart_off_x; ay = m_cfg.cart_off_y; az = m_cfg.cart_off_z;
        } else if (jetski_now) {
            ax = m_cfg.jetski_off_x; ay = m_cfg.jetski_off_y; az = m_cfg.jetski_off_z;
        } else if (boat_now) {
            ax = m_cfg.boat_off_x; ay = m_cfg.boat_off_y; az = m_cfg.boat_off_z;
        } else if (begcrouch_now) {
            ax = m_cfg.begcrouch_off_x; ay = m_cfg.begcrouch_off_y; az = m_cfg.begcrouch_off_z;
        } else if (forcecrouch_now && is_ada_now()) {
            ax = m_cfg.ada_fc_off_x; ay = m_cfg.ada_fc_off_y; az = m_cfg.ada_fc_off_z;
        } else if (forcecrouch_now) {
            ax = m_cfg.leon_fc_off_x; ay = m_cfg.leon_fc_off_y; az = m_cfg.leon_fc_off_z;
        } else if (is_ada_now()) {
            ax = m_cfg.ada_box_off_x; ay = m_cfg.ada_box_off_y; az = m_cfg.ada_box_off_z;
        } else {
            ax = m_cfg.leon_evt_off_x; ay = m_cfg.leon_evt_off_y; az = m_cfg.leon_evt_off_z;
        }
        if (headpin_now && !grappled_now && !fatalkick_now && !cart_now) {
            m_headpin_was = true;
            m_headpin_ax = ax; m_headpin_ay = ay; m_headpin_az = az;
        } else {
            m_headpin_was = false;
        }
        const float ox = m_cfg.off_x + ax, oy = m_cfg.off_y + ay, oz = m_cfg.off_z + az;
        if (ox != 0.0f || oy != 0.0f || oz != 0.0f) {
            if (auto* btf = re4vr::body_transform()) {
                const auto rr = sdk::get_transform_rotation(btf);
                const auto fwd = rr * Vector3f{0, 0, 1};
                const auto right = rr * Vector3f{1, 0, 0};
                cam_pos = Vector3f{
                    head.x + right.x * ox + fwd.x * oz,
                    head.y + oy,
                    head.z + right.z * ox + fwd.z * oz};
            }
        }
        auto* cj = get_camera_joint();
        if (!cj) {
            return;
        }
        re4vr::pcall([&] { sdk::set_joint_position(cj, Vector4f{cam_pos.x, cam_pos.y, cam_pos.z, 1.0f}); });
        auto yaw = get_game_cam_yaw();
        if (!yaw) {
            yaw = get_primary_cam_flat_yaw();
        }
        if (yaw) {
            publish_camera_fix(true, &cam_pos, &*yaw);
        } else {
            publish_camera_fix(false);
        }
        return;
    }

    if (m_headpin_was) {
        m_headpin_was = false;
        m_headpin_t = now_clock();
    }

    Vector3f hp = v3(sdk::get_joint_position(hj));
    if (RE4VRShared::get()->vr_surge_bridged) {
        if (auto* btf0 = re4vr::body_transform()) {
            const auto bp0 = v3(sdk::get_transform_position(btf0));
            hp = Vector3f{bp0.x, hp.y, bp0.z};
        }
    }
    hp = apply_bob_filter(hp, frame_tick);
    {
        std::optional<Vector3f> bp;
        if (auto* btf = re4vr::body_transform()) {
            bp = v3(sdk::get_transform_position(btf));
        }
        hp = apply_surge_filter(hp, bp, frame_tick);
    }

    Vector3f cam_pos = hp;
    float ox = m_cfg.off_x, oy = m_cfg.off_y, oz = m_cfg.off_z;
    if (is_crouch_now() && is_ashley_now()) {
        ox = m_cfg.acrouch_off_x; oy = m_cfg.acrouch_off_y; oz = m_cfg.acrouch_off_z;
    }
    if (ox != 0.0f || oy != 0.0f || oz != 0.0f) {
        if (auto* btf = re4vr::body_transform()) {
            const auto rr = sdk::get_transform_rotation(btf);
            const auto fwd = rr * Vector3f{0, 0, 1};
            const auto right = rr * Vector3f{1, 0, 0};
            cam_pos = Vector3f{
                hp.x + right.x * ox + fwd.x * oz,
                hp.y + oy,
                hp.z + right.z * ox + fwd.z * oz};
        }
    }
    cam_pos.y = apply_crouch_cam_lerp(cam_pos.y, frame_tick);

    if (m_headpin_t > 0.0) {
        const float dur = m_cfg.headpin_fade_dur;
        const float el = (float)(now_clock() - m_headpin_t);
        if (dur <= 0.001f || el >= dur) {
            m_headpin_t = 0.0;
        } else {
            Vector3f pin{hp.x, hp.y, hp.z};
            const float px = m_cfg.off_x + m_headpin_ax;
            const float py = m_cfg.off_y + m_headpin_ay;
            const float pz = m_cfg.off_z + m_headpin_az;
            if (px != 0.0f || py != 0.0f || pz != 0.0f) {
                if (auto* btf2 = re4vr::body_transform()) {
                    const auto rr2 = sdk::get_transform_rotation(btf2);
                    const auto fwd2 = rr2 * Vector3f{0, 0, 1};
                    const auto right2 = rr2 * Vector3f{1, 0, 0};
                    pin = Vector3f{
                        hp.x + right2.x * px + fwd2.x * pz,
                        hp.y + py,
                        hp.z + right2.z * px + fwd2.z * pz};
                }
            }
            const float f = el / dur;
            cam_pos = Vector3f{
                pin.x + (cam_pos.x - pin.x) * f,
                pin.y + (cam_pos.y - pin.y) * f,
                pin.z + (cam_pos.z - pin.z) * f};
        }
    }

    auto* cj = get_camera_joint();
    if (!cj) {
        return;
    }
    re4vr::pcall([&] { sdk::set_joint_position(cj, Vector4f{cam_pos.x, cam_pos.y, cam_pos.z, 1.0f}); });
    if (auto yaw = get_game_cam_yaw()) {
        publish_camera_fix(true, &cam_pos, &*yaw);
    } else {
        publish_camera_fix(false);
    }
}

Vector2f RE4VRFirstPerson::get_left_input_axis() {
    auto& vr = VR::get();
    if (vr->is_using_controllers()) {
        auto axis = vr->get_left_stick_axis();
        if (glm::length(axis) > 0.0f) {
            return axis;
        }
    }
    auto* gp = sdk::get_native_singleton("via.hid.GamePad");
    auto* td = sdk::find_type_definition("via.hid.GamePad");
    if (!gp || !td) {
        return Vector2f{0, 0};
    }
    auto* pad = re4vr::safe([&] { return sdk::call_native_func_easy<::REManagedObject*>(gp, td, "get_LastInputDevice"); }).value_or(nullptr);
    if (!re4vr::obj_ok(pad)) {
        return Vector2f{0, 0};
    }
    if (auto a = re4vr::safe([&] { return sdk::call_object_func_easy<Vector2f>(pad, "get_AxisL"); })) {
        return *a;
    }
    if (auto a = re4vr::safe([&] { return sdk::call_object_func_easy<Vector3f>(pad, "get_AxisL"); })) {
        return Vector2f{a->x, a->y};
    }
    return Vector2f{0, 0};
}

void RE4VRFirstPerson::apply_movement_stabilization() {
    if (!m_cfg.movement_stabilization) {
        m_move_has_valid = false;
        return;
    }
    if (re4vr::call_killswitch_bool("is_active", RE4VRShared::get()->re4_ks_active) || RE4VRShared::get()->re4_throwsight_active) {
        m_move_has_valid = false;
        m_move_last_t.reset();
        return;
    }
    if (!active()) {
        m_move_has_valid = false;
        m_move_last_t.reset();
        return;
    }
    auto* body_tr = re4vr::body_transform();
    if (!body_tr) {
        m_move_has_valid = false;
        return;
    }
    auto* cam_joint = get_camera_joint();
    if (!cam_joint) {
        return;
    }
    const double now = now_clock();
    if (!m_move_last_t) {
        m_move_last_t = now;
    }
    float dt = (float)(now - *m_move_last_t);
    m_move_last_t = now;
    if (dt < 0.001f) {
        dt = 0.001f;
    }
    if (dt > 0.1f) {
        dt = 0.1f;
    }
    const auto cur = v3(sdk::get_transform_position(body_tr));
    if (m_move_has_valid && m_move_last_pos) {
        Vector3f delta = cur - *m_move_last_pos;
        delta.y = 0.0f;
        float speed = glm::length(delta);
        speed = std::min(speed, 1.0f);
        auto camera_rot = sdk::get_joint_rotation(cam_joint);
        if (m_cfg.movement_follows_hmd) {
            auto& vr = VR::get();
            const auto t0 = vr->get_transform(0);
            const glm::quat hmd_quat{t0};
            const auto rot_offset = vr->get_rotation_offset();
            const auto combined = rot_offset * hmd_quat;
            const float siny = 2.0f * (combined.w * combined.y + combined.z * combined.x);
            const float cosy = 1.0f - 2.0f * (combined.y * combined.y + combined.x * combined.x);
            const float hmd_yaw = std::atan2(siny, cosy);
            const float half = hmd_yaw * 0.5f;
            const glm::quat hmd_flat{std::cos(half), 0.0f, std::sin(half), 0.0f};
            camera_rot = camera_rot * hmd_flat;
        }
        const auto camera_dir = camera_rot * Vector3f{0, 0, 1};
        const auto axis_l = get_left_input_axis();
        if (glm::length(axis_l) > 0.0f) {
            auto flat = Vector3f{camera_dir.x, 0.0f, camera_dir.z};
            const float fl = glm::length(flat);
            if (fl > 0.0001f) {
                flat /= fl;
                const auto flat_camera_rot = glm::quat{glm::rowMajor4(glm::lookAtLH(Vector3f{0, 0, 0}, flat, Vector3f{0, 1, 0}))};
                auto axis_l_dir = flat_camera_rot * Vector3f{axis_l.x, 0.0f, -axis_l.y};
                const float al = glm::length(axis_l_dir);
                if (al > 0.0f) {
                    axis_l_dir /= al;
                    auto new_pos = *m_move_last_pos + (axis_l_dir * speed);
                    new_pos.y = cur.y;
                    re4vr::pcall([&] { sdk::set_transform_position(body_tr, Vector4f{new_pos.x, new_pos.y, new_pos.z, 1.0f}); });
                }
            }
        }
    }
    m_move_last_pos = v3(sdk::get_transform_position(body_tr));
    m_move_has_valid = true;
}

std::optional<float> RE4VRFirstPerson::rc_yaw_of_quat(const glm::quat& q) {
    const auto f = q * Vector3f{0, 0, 1};
    const float len = std::sqrt(f.x * f.x + f.z * f.z);
    if (len < 1e-4f) {
        return std::nullopt;
    }
    return std::atan2(f.x / len, f.z / len);
}

glm::quat RE4VRFirstPerson::rc_yaw_quat(float y) {
    const float h = y * 0.5f;
    return glm::quat{std::cos(h), 0.0f, std::sin(h), 0.0f};
}

bool RE4VRFirstPerson::recenter_neutralize_headset() {
    auto& vr = VR::get();
    const glm::quat hq{vr->get_transform(0)};
    auto h = rc_yaw_of_quat(hq);
    if (!h) {
        return false;
    }
    vr->set_rotation_offset(rc_yaw_quat(-*h));
    return true;
}

void RE4VRFirstPerson::recenter_tick() {
    if (!m_cfg.recenter_on_killswitch) {
        if (m_rc_was_active) {
            RE4VRShared::get()->vr_recenter_hold = false;
            m_rc_was_active = false;
        }
        return;
    }
    if (!VR::get()->is_hmd_active()) {
        return;
    }
    const bool ks = re4vr::call_killswitch_bool("is_active", RE4VRShared::get()->re4_ks_active);
    if (ks && !m_rc_was_active) {
        recenter_neutralize_headset();
        RE4VRShared::get()->vr_recenter_hold = true;
    } else if (!ks && m_rc_was_active) {
        RE4VRShared::get()->vr_recenter_hold = false;
    }
    m_rc_was_active = ks;
}

void RE4VRFirstPerson::apply_world_cam_offset(float ox, float oy, float oz) {
    auto* cam = sdk::get_primary_camera();
    if (!cam) {
        return;
    }
    auto* cgo = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(cam, "get_GameObject"); }).value_or(nullptr);
    auto* ctf = cgo ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(cgo, "get_Transform"); }).value_or(nullptr) : nullptr;
    if (!ctf) {
        return;
    }
    const auto p = sdk::get_transform_position(ctf);
    re4vr::pcall([&] { sdk::set_transform_position(ctf, Vector4f{p.x + ox, p.y + oy, p.z + oz, p.w}, true); });
}

void RE4VRFirstPerson::apply_event_hmd_offset() {
    if (m_cfg.event_off_x == 0 && m_cfg.event_off_y == 0 && m_cfg.event_off_z == 0) {
        return;
    }
    auto stage = fp_stage_cached();
    if (!stage || (*stage != 51503 && *stage != 51502)) {
        return;
    }
    auto* busy = fp_busy_cached();
    if (!re4vr::obj_ok(busy) || !m_gimmickfix_cam_td || !utility::re_managed_object::is_a(busy, "chainsaw.GimmickFixCameraController")) {
        return;
    }
    auto* btf = re4vr::body_transform();
    if (!btf) {
        return;
    }
    const auto bp = v3(sdk::get_transform_position(btf));
    const float dx = bp.x + 8.61f, dy = bp.y - 26.87f, dz = bp.z + 43.75f;
    if (dx * dx + dy * dy + dz * dz > 25.0f) {
        return;
    }
    apply_world_cam_offset(m_cfg.event_off_x, m_cfg.event_off_y, m_cfg.event_off_z);
}

void RE4VRFirstPerson::apply_event2_hmd_offset() {
    if (m_cfg.event2_off_x == 0 && m_cfg.event2_off_y == 0 && m_cfg.event2_off_z == 0) {
        return;
    }
    auto stage = fp_stage_cached();
    if (!stage || *stage != 61400) {
        return;
    }
    auto* busy = fp_busy_cached();
    if (!re4vr::obj_ok(busy) || !m_gimmickfix_cam_td || !utility::re_managed_object::is_a(busy, "chainsaw.GimmickFixCameraController")) {
        return;
    }
    auto* btf = re4vr::body_transform();
    if (!btf) {
        return;
    }
    const auto bp = v3(sdk::get_transform_position(btf));
    const float dx = bp.x - 115.55f, dy = bp.y - 18.50f, dz = bp.z + 93.56f;
    if (dx * dx + dy * dy + dz * dz > 25.0f) {
        return;
    }
    apply_world_cam_offset(m_cfg.event2_off_x, m_cfg.event2_off_y, m_cfg.event2_off_z);
}

void RE4VRFirstPerson::apply_event3_hmd_offset() {
    if (m_cfg.event3_off_x == 0 && m_cfg.event3_off_y == 0 && m_cfg.event3_off_z == 0) {
        return;
    }
    auto stage = fp_stage_cached();
    if (!stage || *stage != 61305) {
        return;
    }
    auto* busy = fp_busy_cached();
    if (!re4vr::obj_ok(busy) || !m_gimmickfix_cam_td || !utility::re_managed_object::is_a(busy, "chainsaw.GimmickFixCameraController")) {
        return;
    }
    auto* btf = re4vr::body_transform();
    if (!btf) {
        return;
    }
    const auto bp = v3(sdk::get_transform_position(btf));
    const float dx = bp.x - 90.83f, dy = bp.y - 18.50f, dz = bp.z + 91.04f;
    if (dx * dx + dy * dy + dz * dz > 25.0f) {
        return;
    }
    apply_world_cam_offset(m_cfg.event3_off_x, m_cfg.event3_off_y, m_cfg.event3_off_z);
}

void RE4VRFirstPerson::apply_event4_hmd_offset() {
    if (m_cfg.event4_off_x == 0 && m_cfg.event4_off_y == 0 && m_cfg.event4_off_z == 0) {
        return;
    }
    auto stage = fp_stage_cached();
    if (!stage || *stage != 63108) {
        return;
    }
    auto* busy = fp_busy_cached();
    if (!re4vr::obj_ok(busy) || !m_gimmickfix_cam_td || !utility::re_managed_object::is_a(busy, "chainsaw.GimmickFixCameraController")) {
        return;
    }
    auto* btf = re4vr::body_transform();
    if (!btf) {
        return;
    }
    const auto bp = v3(sdk::get_transform_position(btf));
    const float dx = bp.x + 13.89f, dy = bp.y - 21.77f, dz = bp.z + 122.40f;
    if (dx * dx + dy * dy + dz * dz > 25.0f) {
        return;
    }
    apply_world_cam_offset(m_cfg.event4_off_x, m_cfg.event4_off_y, m_cfg.event4_off_z);
}

void RE4VRFirstPerson::apply_event5_hmd_offset() {
    if (m_cfg.event5_off_x == 0 && m_cfg.event5_off_y == 0 && m_cfg.event5_off_z == 0) {
        return;
    }
    auto stage = fp_stage_cached();
    if (!stage || *stage != 44110) {
        return;
    }
    auto* busy = fp_busy_cached();
    if (!re4vr::obj_ok(busy) || !m_gimmickfix_cam_td || !utility::re_managed_object::is_a(busy, "chainsaw.GimmickFixCameraController")) {
        return;
    }
    auto* btf = re4vr::body_transform();
    if (!btf) {
        return;
    }
    const auto bp = v3(sdk::get_transform_position(btf));
    const float dx = bp.x - 10.75f, dy = bp.y - 12.87f, dz = bp.z - 107.76f;
    if (dx * dx + dy * dy + dz * dz > 4.0f) {
        return;
    }
    apply_world_cam_offset(m_cfg.event5_off_x, m_cfg.event5_off_y, m_cfg.event5_off_z);
}

void RE4VRFirstPerson::apply_event5_mono() {
    bool on = false;
    if (m_cfg.event5_mono) {
        auto* ctx = re4vr::player_context();
        auto stage = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(ctx, "get_CurrentStageID"); }) : std::nullopt;
        if (stage && *stage == 44110) {
            auto* sys = re4vr::camera_system();
            auto* main = sys ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(sys, "get_MainCameraController"); }).value_or(nullptr) : nullptr;
            auto* busy = main ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(main, "get_BusyCameraController"); }).value_or(nullptr) : nullptr;
            if (re4vr::obj_ok(busy) && m_gimmickfix_cam_td && utility::re_managed_object::is_a(busy, "chainsaw.GimmickFixCameraController")) {
                if (auto* btf = re4vr::body_transform()) {
                    const auto bp = v3(sdk::get_transform_position(btf));
                    const float dx = bp.x - 10.75f, dy = bp.y - 12.87f, dz = bp.z - 107.76f;
                    on = (dx * dx + dy * dy + dz * dz) <= 4.0f;
                }
            }
        }
    }
    RE4VRScope::get()->mono_request("symbol_riddle", on);
}

void RE4VRFirstPerson::apply_event6_hmd_offset() {
    if (m_cfg.event6_off_x == 0 && m_cfg.event6_off_y == 0 && m_cfg.event6_off_z == 0) {
        return;
    }
    auto stage = fp_stage_cached();
    if (!stage || *stage != 45401) {
        return;
    }
    auto* busy = fp_busy_cached();
    if (!re4vr::obj_ok(busy) || !m_gimmickfix_cam_td || !utility::re_managed_object::is_a(busy, "chainsaw.GimmickFixCameraController")) {
        return;
    }
    auto* btf = re4vr::body_transform();
    if (!btf) {
        return;
    }
    const auto bp = v3(sdk::get_transform_position(btf));
    const float dx = bp.x - 106.80f, dy = bp.y - 11.63f, dz = bp.z - 100.55f;
    if (dx * dx + dy * dy + dz * dz > 25.0f) {
        return;
    }
    apply_world_cam_offset(m_cfg.event6_off_x, m_cfg.event6_off_y, m_cfg.event6_off_z);
}

void RE4VRFirstPerson::apply_turret_hmd_offset() {
    if (m_cfg.turret_off_x == 0 && m_cfg.turret_off_y == 0 && m_cfg.turret_off_z == 0) {
        return;
    }
    auto* busy = fp_busy_cached();
    if (!re4vr::obj_ok(busy)) {
        return;
    }
    auto* sp = sdk::get_object_field<::REManagedObject*>(busy, "_CurrentStateParam");
    if (!sp || !re4vr::obj_ok(*sp)) {
        return;
    }
    int32_t gt = -1;
    if (auto* f = sdk::get_object_field<int32_t>(*sp, "<GimmickType>k__BackingField")) {
        gt = *f;
    } else if (auto* boxed = sdk::get_object_field<::REManagedObject*>(*sp, "<GimmickType>k__BackingField")) {
        if (re4vr::obj_ok(*boxed)) {
            if (auto* v = sdk::get_object_field<int32_t>(*boxed, "value__")) {
                gt = *v;
            }
        }
    }
    if (gt != m_turret_gimmick) {
        return;
    }
    apply_world_cam_offset(m_cfg.turret_off_x, m_cfg.turret_off_y, m_cfg.turret_off_z);
}

void RE4VRFirstPerson::apply_all_event_offsets() {
    apply_event_hmd_offset();
    apply_event2_hmd_offset();
    apply_event3_hmd_offset();
    apply_event4_hmd_offset();
    apply_event5_hmd_offset();
    apply_event6_hmd_offset();
    apply_turret_hmd_offset();
}

void RE4VRFirstPerson::force_twirler_tick() {
    if (now_clock() < m_ftw_block_until) {
        return;
    }
    auto* cam = get_player_cam();
    if (!cam) {
        m_ftw_twirl = false;
        m_ftw_block_until = now_clock() + 0.20;
        return;
    }
    auto tw = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(cam, "get_IsForceTwirler"); });
    if (!tw) {
        m_ftw_twirl = false;
        m_ftw_fail_streak = std::min(m_ftw_fail_streak + 1, 3);
        m_ftw_block_until = now_clock() + std::min(0.5 * std::pow(2.0, m_ftw_fail_streak - 1), 2.0);
        return;
    }
    m_ftw_fail_streak = 0;
    m_ftw_twirl = *tw;
    if (!m_cfg.block_force_twirler || !m_ftw_twirl) {
        return;
    }
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(cam, "stopForceTwirler"); });
    m_ftw_stopped += 1;
}

void RE4VRFirstPerson::sd_hide_subtree(::RETransform* tf) {
    if (!tf) {
        return;
    }
    auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(tf, "get_GameObject"); }).value_or(nullptr);
    if (re4vr::obj_ok((::REManagedObject*)go)) {
        for (auto* t : {m_mesh_t, m_skin_t}) {
            if (!t) {
                continue;
            }
            auto* m = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(go, "getComponent(System.Type)", t); }).value_or(nullptr);
            if (re4vr::obj_ok(m)) {
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m, "set_DrawDefault", false); });
                m_sd_cache.push_back(m);
            }
        }
    }
    auto* child = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(tf, "get_Child"); }).value_or(nullptr);
    while (child) {
        sd_hide_subtree(child);
        child = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(child, "get_Next"); }).value_or(nullptr);
    }
}

void RE4VRFirstPerson::sd_scan() {
    auto* sm = sdk::get_native_singleton("via.SceneManager");
    if (!sm || !m_scene_td || !m_ctrl_t) {
        return;
    }
    auto* scene = re4vr::safe([&] { return sdk::call_native_func_easy<::REManagedObject*>(sm, m_scene_td, "get_CurrentScene"); }).value_or(nullptr);
    if (!re4vr::obj_ok(scene)) {
        return;
    }
    auto* comps = re4vr::safe([&] { return sdk::call_object_func_easy<sdk::SystemArray*>(scene, "findComponents(System.Type)", m_ctrl_t); }).value_or(nullptr);
    if (!comps) {
        return;
    }
    m_sd_cache.clear();
    const auto n = comps->get_size();
    for (size_t i = 0; i < n; ++i) {
        auto* c = comps->get_element((int32_t)i);
        auto* go = c ? re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(c, "get_GameObject"); }).value_or(nullptr) : nullptr;
        auto* tf = go ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr) : nullptr;
        sd_hide_subtree(tf);
    }
}

void RE4VRFirstPerson::sd_tick() {
    if (!m_cfg.hide_streaming_dummy) {
        return;
    }
    bool stale = false;
    for (auto* m : m_sd_cache) {
        bool valid = false;
        re4vr::pcall([&] { valid = sdk::call_object_func_easy<bool>(m, "get_Valid"); });
        if (valid) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m, "set_DrawDefault", false); });
        } else {
            stale = true;
        }
    }
    if (stale) {
        m_sd_cache.clear();
        m_sd_last_scan = 0.0;
    }
    const double now = now_clock();
    if ((now - m_sd_last_scan) >= 0.5) {
        m_sd_last_scan = now;
        re4vr::pcall([&] { sd_scan(); });
    }
}

void RE4VRFirstPerson::reset_runtime() {
    m_bob_ema.reset();
    m_bob_last_t.reset();
    m_capy_ema.reset();
    m_capy_last_t.reset();
    m_surge_px.reset();
    m_surge_pz.reset();
    m_surge_lx.reset();
    m_surge_lz.reset();
    m_surge_last_t.reset();
    m_surge_vx = 0;
    m_surge_vz = 0;
    m_surge_lyaw.reset();
    m_surge_turn_n = 0;
    m_crouch_ema.reset();
    m_crouch_until_t.reset();
    m_crouch_was = false;
    m_crouch_last_t.reset();
    m_crouch_standup_until.reset();
    m_head_joint = nullptr;
    m_move_has_valid = false;
    m_move_last_pos.reset();
    m_move_last_t.reset();
    m_sd_cache.clear();
    m_sd_last_scan = 0.0;
    m_rc_was_active = false;
    RE4VRShared::get()->vr_recenter_hold = false;
    publish_camera_fix(false);
}

std::optional<std::string> RE4VRFirstPerson::on_initialize() {
    load_json();
    m_player_cam_td = sdk::find_type_definition("chainsaw.PlayerCameraController");
    m_gimmickfix_cam_td = sdk::find_type_definition("chainsaw.GimmickFixCameraController");
    m_turret_gimmick = resolve_static_enum("chainsaw.CameraDefine.GimmickType", "InstalledMachineGun", 6);
    m_scene_td = sdk::find_type_definition("via.SceneManager");
    if (auto* t = sdk::find_type_definition("chainsaw.StreamingDummyController")) {
        m_ctrl_t = t->get_runtime_type();
    }
    if (auto* t = sdk::find_type_definition("via.render.Mesh")) {
        m_mesh_t = t->get_runtime_type();
    }
    if (auto* t = sdk::find_type_definition("via.render.SkinnedMesh")) {
        m_skin_t = t->get_runtime_type();
    }
    return std::nullopt;
}

void RE4VRFirstPerson::on_config_load(const utility::Config&) {
    load_json();
    publish_bino();
}

void RE4VRFirstPerson::on_lua_state_created(sol::state& lua) {
    if (!lua["vr_camera_fix"].is<sol::table>()) {
        auto t = lua.create_table();
        t["active"] = false;
        lua["vr_camera_fix"] = t;
    }
    publish_bino();
}

void RE4VRFirstPerson::on_lua_state_destroyed(sol::state&) {
    reset_runtime();
}

void RE4VRFirstPerson::on_frame() {
    ScriptProfileGuard guard("re4_vr_firstperson.lua", "on_frame", re4vr::profile_frame());
    m_fp_frame += 1;
    force_twirler_tick();
    sd_tick();
}

void RE4VRFirstPerson::on_pre_application_entry(void*, const char* name, size_t hash) {
    if (hash == "LockScene"_fnv) {
        ScriptProfileGuard guard("re4_vr_firstperson.lua", "on_pre_application_entry:LockScene", re4vr::profile_frame());
        recenter_tick();
        if (m_cfg.movement_stabilization && active()) {
            if (auto* body_tr = re4vr::body_transform()) {
                m_move_last_pos = v3(sdk::get_transform_position(body_tr));
                m_move_has_valid = true;
            }
        }
        compute_and_set(true);
        apply_all_event_offsets();
        apply_event5_mono();
    } else if (hash == "UnlockScene"_fnv) {
        ScriptProfileGuard guard("re4_vr_firstperson.lua", "on_pre_application_entry:UnlockScene", re4vr::profile_frame());
        compute_and_set(false);
        apply_all_event_offsets();
    }
}

void RE4VRFirstPerson::on_application_entry(void*, const char* name, size_t hash) {
    if (hash == "LateUpdateBehavior"_fnv) {
        ScriptProfileGuard guard("re4_vr_firstperson.lua", "on_application_entry:LateUpdateBehavior", re4vr::profile_frame());
        compute_and_set(false);
        apply_all_event_offsets();
    } else if (hash == "BeginRendering"_fnv) {
        ScriptProfileGuard guard("re4_vr_firstperson.lua", "on_application_entry:BeginRendering", re4vr::profile_frame());
        compute_and_set(false);
        apply_all_event_offsets();
    } else if (hash == "UpdateMotion"_fnv) {
        ScriptProfileGuard guard("re4_vr_firstperson.lua", "on_application_entry:UpdateMotion", re4vr::profile_frame());
        apply_movement_stabilization();
    }
}
#endif
