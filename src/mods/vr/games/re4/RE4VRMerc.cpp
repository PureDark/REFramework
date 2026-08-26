#define NOMINMAX
#include "RE4VRMerc.hpp"

#if defined(RE4)
#include <algorithm>
#include <cmath>
#include <functional>
#include <tuple>
#include <Windows.h>

#include <glm/gtc/constants.hpp>
#include <glm/gtx/quaternion.hpp>
#include <imgui.h>
#include <sdk/RETypeDB.hpp>
#include <sdk/RETransform.hpp>
#include <sdk/REString.hpp>
#include <sdk/REContext.hpp>
#include <sdk/SystemArray.hpp>
#include <sdk/MurmurHash.hpp>
#include <sdk/Application.hpp>
#include <utility/String.hpp>

#include "RE4VRShared.hpp"
#include "RE4VRMenu.hpp"
#include "../../../ScriptRunner.hpp"

namespace {
const std::unordered_map<int32_t, std::string> MERC_BODIES{
    {600000, "ch6i0z0_body"}, {600001, "ch6i1z0_body"}, {600002, "ch6i2z0_body"},
    {600003, "ch6i3z0_body"}, {380000, "ch3a8z0_MC_body"}, {600005, "ch6i5z0_body"},
};
const std::unordered_set<std::string> MERC_BODY_SET{
    "ch6i0z0_body", "ch6i1z0_body", "ch6i2z0_body", "ch6i3z0_body", "ch3a8z0_MC_body", "ch6i5z0_body",
};
const std::unordered_map<int32_t, const char*> MERC_ARM_KEYS{
    {600000, "merc_leon"}, {600001, "merc_luis"}, {600002, "merc_krauser"},
    {600003, "merc_hunk"}, {380000, "merc_ada"}, {600005, "merc_wesker"},
};
const std::unordered_set<int32_t> LASER_WIDS{6304, 4000, 4501};
constexpr int32_t BOW_WID = 6304;
const char* BOW_PIN_JOINT = "R_Hand";

std::string mat_name(::REManagedObject* mesh, int mi) {
    auto* nm = re4vr::safe([&] { return sdk::call_object_func_easy<::SystemString*>(mesh, "getMaterialName", mi); }).value_or(nullptr);
    return nm ? utility::re_string::get_string(nm) : std::string{};
}

std::unordered_map<std::string, bool> hide_for(int32_t kind) {
    std::unordered_map<std::string, bool> m;
    auto add = [&](std::initializer_list<const char*> n) {
        for (auto* s : n) {
            m[s] = true;
        }
    };
    if (kind == 600000) {
        add({"EyeAO_mat", "EyeOut_mat", "Face_mat", "EyeWet_mat", "BrowsEyeLashes_mat", "Eye_inside_mat", "Mouth_mat",
             "Hair00_Mat", "Hair01_Mat", "pl0074_Hair_Mat", "pl0074_Hair2_Mat"});
    } else if (kind == 600001) {
        add({"Beard_Mat", "BrowsEyelashes_mat", "EyeAO_mat", "EyeInside_mat", "EyeOut_mat", "EyeWet_mat", "Face_mat", "Mouth_mat", "Hair_A_Mat"});
    } else if (kind == 600002) {
        add({"EyeAO_mat", "Eye_out_mat", "Face_mat", "Mouth_mat", "Blow_mat", "Eye_in_mat", "Eyewet_mat", "Eye_Lashes_mat",
             "Hair1_Mat", "Hair2_Mat", "Hair3_Mat", "Hair4_Mat"});
    } else if (kind == 600003) {
        add({"Face_Mat", "Body_Mat", "Glass_out_Mat", "Glass_in_Mat"});
    } else if (kind == 380000) {
        add({"Ao_mat", "Blow_mat", "EyeLash_mat", "Eye_in_mat", "Eye_out_mat", "Eyewet_mat", "Face_mat", "Mouth_mat",
             "Lens_Inside_mat", "Hair00_mat", "Hair01_mat", "Hair02_mat"});
    } else if (kind == 600005) {
        add({"Ao_mat", "Blow_mat", "Eye_in_mat", "Eye_out_mat", "Face_mat", "Mouth_mat", "GlassLens_mat", "Glass_mat",
             "NosePad_Mat", "Emi_Glass_mat"});
    }
    return m;
}

const std::unordered_set<std::string> HIDE_EXTRA{"Hat00_Mat", "Hat01_Mat", "Beret_Mat", "pl0074_Hair_Mat", "pl0074_Hair2_Mat"};
const std::unordered_set<std::string> FULLHIDE_EXTRA{"JacketFur_Mat", "Jacket_Mat", "Boa_Mat"};
}

std::shared_ptr<RE4VRMerc>& RE4VRMerc::get() {
    static auto inst = std::make_shared<RE4VRMerc>();
    return inst;
}

void RE4VRMerc::load_json() {
    const auto d = re4vr::load_json_file("re4_vr/re4_vr_merc.json");
    if (d.empty()) {
        return;
    }
    m_wep_off_on = re4vr::j_bool(d, "wep_off_on", m_wep_off_on);
    m_bow_pose_on = re4vr::j_bool(d, "bow_pose_on", m_bow_pose_on);
    m_hide_2770 = re4vr::j_bool(d, "hide_2770", m_hide_2770);
    m_hide_timer_bg = re4vr::j_bool(d, "hide_timer_bg", m_hide_timer_bg);
    m_bow_mirror_mode = (int)re4vr::j_num(d, "bow_mirror_mode", (float)m_bow_mirror_mode);
    m_bow_pose_blend = re4vr::j_num(d, "bow_pose_blend", m_bow_pose_blend);
    if (d.contains("wep_off") && d["wep_off"].is_object()) {
        for (auto it = d["wep_off"].begin(); it != d["wep_off"].end(); ++it) {
            if (!it.value().is_object()) {
                continue;
            }
            WepOff o;
            o.px = re4vr::j_num(it.value(), "px", 0);
            o.py = re4vr::j_num(it.value(), "py", 0);
            o.pz = re4vr::j_num(it.value(), "pz", 0);
            o.rx = re4vr::j_num(it.value(), "rx", 0);
            o.ry = re4vr::j_num(it.value(), "ry", 0);
            o.rz = re4vr::j_num(it.value(), "rz", 0);
            m_wep_off[it.key()] = o;
        }
    }
    if (d.contains("poses") && d["poses"].is_object()) {
        m_bow_poses.clear();
        m_bow_mirror_cache.clear();
        for (auto it = d["poses"].begin(); it != d["poses"].end(); ++it) {
            BowPose p;
            if (it.value().contains("bones") && it.value()["bones"].is_object()) {
                for (auto b = it.value()["bones"].begin(); b != it.value()["bones"].end(); ++b) {
                    if (b.value().is_array() && b.value().size() >= 4) {
                        p.bones[b.key()] = glm::quat{
                            b.value()[0].get<float>(), b.value()[1].get<float>(),
                            b.value()[2].get<float>(), b.value()[3].get<float>(),
                        };
                    }
                }
            }
            m_bow_poses[it.key()] = std::move(p);
        }
    }
    if (d.contains("hud") && d["hud"].is_object()) {
        for (auto it = d["hud"].begin(); it != d["hud"].end(); ++it) {
            if (!it.value().is_object() || !m_hud.count(it.key())) {
                continue;
            }
            auto& h = m_hud[it.key()];
            h.on = re4vr::j_bool(it.value(), "on", h.on);
            h.scale = re4vr::j_num(it.value(), "scale", h.scale);
            h.x = re4vr::j_num(it.value(), "x", h.x);
            h.y = re4vr::j_num(it.value(), "y", h.y);
            if (it.value().contains("bx") && it.value()["bx"].is_number()) {
                h.bx = it.value()["bx"].get<float>();
            }
            if (it.value().contains("by") && it.value()["by"].is_number()) {
                h.by = it.value()["by"].get<float>();
            }
        }
    }
}

void RE4VRMerc::save_json() {
    nlohmann::json out;
    out["wep_off_on"] = m_wep_off_on;
    out["bow_pose_on"] = m_bow_pose_on;
    out["hide_2770"] = m_hide_2770;
    out["hide_timer_bg"] = m_hide_timer_bg;
    out["bow_mirror_mode"] = m_bow_mirror_mode;
    out["bow_pose_blend"] = m_bow_pose_blend;
    nlohmann::json wo = nlohmann::json::object();
    for (const auto& [k, o] : m_wep_off) {
        wo[k] = {{"px", o.px}, {"py", o.py}, {"pz", o.pz}, {"rx", o.rx}, {"ry", o.ry}, {"rz", o.rz}};
    }
    out["wep_off"] = wo;
    nlohmann::json poses = nlohmann::json::object();
    for (const auto& [k, p] : m_bow_poses) {
        nlohmann::json bones = nlohmann::json::object();
        for (const auto& [bn, q] : p.bones) {
            bones[bn] = nlohmann::json::array({q.w, q.x, q.y, q.z});
        }
        poses[k] = {{"bones", bones}};
    }
    out["poses"] = poses;
    nlohmann::json hud = nlohmann::json::object();
    for (const auto& [k, h] : m_hud) {
        nlohmann::json e{{"on", h.on}, {"scale", h.scale}, {"x", h.x}, {"y", h.y}};
        if (h.bx) {
            e["bx"] = *h.bx;
        }
        if (h.by) {
            e["by"] = *h.by;
        }
        hud[k] = e;
    }
    out["hud"] = hud;
    re4vr::save_json_file("re4_vr/re4_vr_merc.json", out);
}

void RE4VRMerc::export_globals() {
    RE4VRShared::get()->re4_in_mercs = m_in_mercs;
}

std::pair<bool, std::optional<int32_t>> RE4VRMerc::detect() {
    if (!re4vr::obj_ok(m_merc_mgr)) {
        m_merc_mgr = sdk::get_managed_singleton<::REManagedObject>("chainsaw.MercenariesManager");
    }
    auto* gui = m_merc_mgr ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(m_merc_mgr, "get_GuiManager"); }).value_or(nullptr) : nullptr;
    if (m_merc_mgr && !gui) {
        m_merc_mgr = nullptr;
    }
    if (!re4vr::obj_ok(m_campaign_mgr)) {
        m_campaign_mgr = sdk::get_managed_singleton<::REManagedObject>("chainsaw.CampaignManager");
    }
    std::optional<int32_t> cid;
    if (m_campaign_mgr) {
        cid = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(m_campaign_mgr, "get_CurrentCampaign"); });
        if (!cid) {
            m_campaign_mgr = nullptr;
        }
    }
    return {gui != nullptr, cid};
}

bool RE4VRMerc::get_player_body(std::optional<int32_t>& kind, std::string& name, ::RETransform*& tf) {
    kind.reset();
    name.clear();
    tf = nullptr;
    auto* ctx = re4vr::player_context();
    if (!ctx) {
        return false;
    }
    kind = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(ctx, "get_KindID"); });
    auto* go = re4vr::body_game_object();
    if (!go) {
        return false;
    }
    name = re4vr::go_name((::REManagedObject*)go);
    tf = re4vr::body_transform();
    return !name.empty();
}

void RE4VRMerc::collect_hh(::RETransform* tf, const std::unordered_map<std::string, bool>* hide) {
    m_hh_meshes.clear();
    if (!tf || !m_t_mesh) {
        return;
    }
    std::function<void(::RETransform*, int)> walk = [&](::RETransform* t, int depth) {
        if (!t || depth > 14) {
            return;
        }
        auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(t, "get_GameObject"); }).value_or(nullptr);
        auto* mesh = go ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(go, "getComponent(System.Type)", m_t_mesh); }).value_or(nullptr) : nullptr;
        if (mesh) {
            const int n = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(mesh, "get_MaterialNum"); }).value_or(0);
            if (n > 0) {
                auto gname = re4vr::go_name((::REManagedObject*)go);
                std::string gl = gname;
                std::transform(gl.begin(), gl.end(), gl.begin(), [](unsigned char c) { return (char)std::tolower(c); });
                bool hit = (gl == "head" || gl == "hair");
                if (!hit && hide) {
                    hit = true;
                    for (int i = 0; i < n; ++i) {
                        if (!hide->count(mat_name(mesh, i))) {
                            hit = false;
                            break;
                        }
                    }
                }
                if (hit) {
                    m_hh_meshes.push_back(HhMesh{mesh, std::nullopt, gname});
                } else {
                    for (int i = 0; i < n; ++i) {
                        const auto mn = mat_name(mesh, i);
                        if (HIDE_EXTRA.count(mn)) {
                            m_hh_meshes.push_back(HhMesh{mesh, i, gname + "/" + mn});
                        }
                    }
                }
            }
        }
        auto* c = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(t, "get_Child"); }).value_or(nullptr);
        while (c) {
            walk(c, depth + 1);
            c = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(c, "get_Next"); }).value_or(nullptr);
        }
    };
    walk(tf, 0);
}

void RE4VRMerc::collect_all_meshes(::RETransform* tf) {
    m_all_meshes.clear();
    std::function<void(::RETransform*, int)> walk = [&](::RETransform* t, int depth) {
        if (!t || depth > 14) {
            return;
        }
        auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(t, "get_GameObject"); }).value_or(nullptr);
        auto* mesh = (go && m_t_mesh) ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(go, "getComponent(System.Type)", m_t_mesh); }).value_or(nullptr) : nullptr;
        if (mesh) {
            m_all_meshes.push_back(mesh);
        }
        auto* c = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(t, "get_Child"); }).value_or(nullptr);
        while (c) {
            walk(c, depth + 1);
            c = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(c, "get_Next"); }).value_or(nullptr);
        }
    };
    walk(tf, 0);
}

bool RE4VRMerc::show_head_now() {
    if (!re4vr::call_killswitch_bool("is_active")) {
        return false;
    }
    for (const char* fn : {"is_ks2", "is_ks3", "is_ks4", "is_ks5"}) {
        if (re4vr::call_killswitch_bool(fn)) {
            return false;
        }
    }
    return true;
}

bool RE4VRMerc::full_hide_now() {
    return re4vr::call_killswitch_bool("is_ks3") || re4vr::call_killswitch_bool("is_ks5");
}

bool RE4VRMerc::extra_cache_alive() {
    if (m_extra_mats.empty()) {
        return false;
    }
    for (const auto& e : m_extra_mats) {
        bool ok = false;
        re4vr::pcall([&] {
            ok = sdk::call_object_func_easy<::REGameObject*>(e.mesh, "get_GameObject") && mat_name(e.mesh, e.idx) == e.name;
        });
        if (!ok) {
            return false;
        }
    }
    return true;
}

void RE4VRMerc::scan_extra_mats() {
    if (!m_extra_mats.empty() && !extra_cache_alive()) {
        m_extra_mats.clear();
        m_extra_furs.clear();
        m_extra_mats_off = false;
        m_extra_scan_t = 0;
    }
    if (!m_extra_mats.empty()) {
        return;
    }
    const double now = re4vr::now();
    if ((now - m_extra_scan_t) < 5.0) {
        return;
    }
    m_extra_scan_t = now;
    auto* scene = re4vr::current_scene();
    if (!scene || !m_t_mesh) {
        return;
    }
    auto* arr = re4vr::safe([&] { return sdk::call_object_func_easy<sdk::SystemArray*>(scene, "findComponents(System.Type)", m_t_mesh); }).value_or(nullptr);
    if (!arr) {
        return;
    }
    const int n = (int)arr->get_size();
    for (int i = 0; i < n; ++i) {
        auto* mesh = arr->get_element(i);
        const int mc = mesh ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(mesh, "get_MaterialNum"); }).value_or(0) : 0;
        for (int mi = 0; mi < mc; ++mi) {
            const auto mn = mat_name(mesh, mi);
            if (FULLHIDE_EXTRA.count(mn)) {
                m_extra_mats.push_back(ExtraMat{mesh, mi, mn});
            }
        }
    }
}

void RE4VRMerc::apply_extra_mats(bool off) {
    for (const auto& e : m_extra_mats) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(e.mesh, "setMaterialsEnable", e.idx, !off); });
    }
    m_extra_mats_off = off;
}

void RE4VRMerc::apply_full_hide() {
    const bool want_extra = m_hide_enabled && full_hide_now();
    if (want_extra) {
        scan_extra_mats();
    }
    apply_extra_mats(want_extra);
    if (m_all_meshes.empty()) {
        return;
    }
    const bool want = m_hide_enabled && full_hide_now();
    if (!want && !m_full_hidden) {
        return;
    }
    for (auto* m : m_all_meshes) {
        re4vr::pcall([&] {
            sdk::call_object_func_easy<void*>(m, "set_DrawDefault", !want);
            sdk::call_object_func_easy<void*>(m, "set_DrawShadowCast", true);
        });
    }
    m_full_hidden = want;
}

void RE4VRMerc::apply_hide() {
    if (m_hh_meshes.empty()) {
        return;
    }
    const bool want_hidden = m_hide_enabled && !show_head_now();
    for (auto& e : m_hh_meshes) {
        if (e.idx) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(e.mesh, "setMaterialsEnable", *e.idx, !want_hidden); });
        } else {
            re4vr::pcall([&] {
                sdk::call_object_func_easy<void*>(e.mesh, "set_DrawDefault", !want_hidden);
                sdk::call_object_func_easy<void*>(e.mesh, "set_DrawShadowCast", true);
            });
        }
    }
}

void RE4VRMerc::bow_unpin() {
    if (m_bowp_tf && m_bowp_pinned) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_bowp_tf, "set_ParentJoint", sdk::VM::create_managed_string(L"")); });
    }
    m_bowp_go = nullptr;
    m_bowp_tf = nullptr;
    m_bowp_pinned = false;
}

void RE4VRMerc::update_bow_pin() {
    const auto wid = RE4VRShared::get()->vr_dbg_wep_id;
    const bool want = m_bow_pin_on && m_in_mercs && wid && (int)*wid == BOW_WID
        && !RE4VRShared::get()->re4_ks4_active && !RE4VRShared::get()->re4_ks_active;
    if (!want) {
        if (m_bowp_pinned) {
            bow_unpin();
        }
        RE4VRShared::get()->re4_merc_bow_pinned = false;
        return;
    }
    if (!m_bowp_pinned) {
        auto* bgo = re4vr::body_game_object();
        auto* btf = re4vr::body_transform();
        if (!bgo || !btf || !re4vr::go_valid((::REManagedObject*)bgo)) {
            return;
        }
        ::REGameObject* found = nullptr;
        ::RETransform* found_tf = nullptr;
        std::function<void(::RETransform*, int)> walk = [&](::RETransform* t, int depth) {
            if (!t || found || depth > 10) {
                return;
            }
            auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(t, "get_GameObject"); }).value_or(nullptr);
            const auto nm = re4vr::go_name((::REManagedObject*)go);
            if (nm.find("wp6304") != std::string::npos || nm.find("6304") != std::string::npos) {
                found = go;
                found_tf = t;
                return;
            }
            auto* c = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(t, "get_Child"); }).value_or(nullptr);
            while (c && !found) {
                walk(c, depth + 1);
                c = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(c, "get_Next"); }).value_or(nullptr);
            }
        };
        walk(btf, 0);
        if (!found || !found_tf || !re4vr::go_valid((::REManagedObject*)found)) {
            return;
        }
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(found_tf, "set_Parent", btf); });
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(found_tf, "set_ParentJoint", sdk::VM::create_managed_string(utility::widen(BOW_PIN_JOINT))); });
        m_bowp_go = found;
        m_bowp_tf = found_tf;
        m_bowp_pinned = true;
    }
    auto it = m_wep_off.find("6304");
    WepOff o = it != m_wep_off.end() ? it->second : WepOff{};
    re4vr::pcall([&] {
        sdk::call_object_func_easy<void*>(m_bowp_tf, "set_LocalPosition", Vector3f{o.px, o.py, o.pz});
        sdk::call_object_func_easy<void*>(m_bowp_tf, "set_LocalRotation", re4vr::quat_euler_yxz_deg(o.rx, o.ry, o.rz));
    });
    RE4VRShared::get()->re4_merc_bow_pinned = true;
}

bool RE4VRMerc::wep_apply(const Vector3f& wpos, const glm::quat& wrot, int32_t wid, const glm::quat* hand_rot, Vector3f& np, glm::quat& nr) {
    if (!m_wep_off_on || !m_in_mercs) {
        return false;
    }
    auto it = m_wep_off.find(std::to_string(wid));
    if (it == m_wep_off.end()) {
        return false;
    }
    const auto& o = it->second;
    if (o.px == 0 && o.py == 0 && o.pz == 0 && o.rx == 0 && o.ry == 0 && o.rz == 0) {
        return false;
    }
    glm::quat rr = hand_rot ? *hand_rot : glm::quat{1, 0, 0, 0};
    if (!hand_rot) {
        if (auto q = RE4VRShared::get()->vr_rh_rot) {
            rr = *q;
        } else {
            return false;
        }
    }
    const auto ov = glm::rotate(rr, Vector3f{o.px, o.py, o.pz});
    np = Vector3f{wpos.x + ov.x, wpos.y + ov.y, wpos.z + ov.z};
    if (o.rx != 0 || o.ry != 0 || o.rz != 0) {
        nr = glm::normalize(wrot * re4vr::quat_euler_yxz_deg(o.rx, o.ry, o.rz));
    } else {
        nr = wrot;
    }
    return true;
}

void RE4VRMerc::apply_bow_pose() {
    if (!m_bow_pose_on || !m_in_mercs) {
        return;
    }
    const auto wid = RE4VRShared::get()->vr_dbg_wep_id;
    if (!wid || (int)*wid != BOW_WID) {
        return;
    }
    auto mirror = [&](const std::string& name) -> std::unordered_map<std::string, glm::quat> {
        auto it = m_bow_poses.find(name);
        if (it == m_bow_poses.end()) {
            return {};
        }
        std::unordered_map<std::string, glm::quat> out;
        for (const auto& [bn, q] : it->second.bones) {
            glm::quat mq = q;
            if (m_bow_mirror_mode == 1) {
                mq = glm::quat{q.w, q.x, -q.y, -q.z};
            } else if (m_bow_mirror_mode == 2) {
                mq = glm::quat{q.w, -q.x, q.y, -q.z};
            } else if (m_bow_mirror_mode == 3) {
                mq = glm::quat{q.w, -q.x, -q.y, q.z};
            }
            std::string nn = bn;
            if (nn.size() >= 2 && nn[0] == 'L' && nn[1] == '_') {
                nn[0] = 'R';
            } else if (nn.size() >= 2 && nn[0] == 'R' && nn[1] == '_') {
                nn[0] = 'L';
            }
            out[nn] = mq;
        }
        return out;
    };
    auto rp = mirror("compoundBOW");
    auto lp = mirror("compoundBOWLEFT");
    if (auto kh = RE4VRShared::get()->re4_knife_hand; kh && *kh == "left") {
        lp.clear();
    }
    if (!rp.empty()) {
        re4vr::apply_pose_bones(rp, m_bow_pose_blend);
    }
    if (!lp.empty()) {
        re4vr::apply_pose_bones(lp, m_bow_pose_blend);
    }
}

void RE4VRMerc::update_bulletrush() {
    const auto kind = RE4VRShared::get()->re4_merc_kind;
    if (!m_in_mercs || !kind || (int)*kind != 600005) {
        m_br_hu = nullptr;
        m_br_since = 0;
        RE4VRShared::get()->re4_force_ks4_bulletrush = false;
        return;
    }
    if (!m_br_hu) {
        auto* ctx = re4vr::player_context();
        m_br_hu = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_HeadUpdater"); }).value_or(nullptr) : nullptr;
    }
    bool on = false;
    if (m_br_hu) {
        auto v = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_br_hu, "get_PlayingBulletRush"); });
        if (!v) {
            m_br_hu = nullptr;
        } else {
            on = *v;
        }
    }
    const double now = re4vr::now();
    if (on) {
        if (m_br_since == 0) {
            m_br_since = now;
        } else if ((now - m_br_since) > 60.0) {
            on = false;
        }
    } else {
        m_br_since = 0;
    }
    RE4VRShared::get()->re4_force_ks4_bulletrush = on;
}

void RE4VRMerc::hud_apply() {
    if (!m_in_mercs) {
        return;
    }
    auto* scene = re4vr::current_scene();
    if (!scene) {
        return;
    }
    const double now = re4vr::now();
    if ((now - m_hud_scan_t) < 1.0 && !m_hud_cache.empty()) {
        return;
    }
    m_hud_scan_t = now;
    struct Spec {
        const char* key;
        const char* type;
    };
    const Spec specs[] = {
        {"timer", "chainsaw.Cp1021TimerGuiBehavior"},
        {"score", "chainsaw.Cp1021HudScoreDispGuiBehavior"},
        {"combo", "chainsaw.Cp1021HudComboGuiBehavior"},
        {"total", "chainsaw.Cp1021HudTotalScoreGuiBehavior"},
        {"gauge", "chainsaw.BulletRushGaugeGuiBehavior"},
    };
    for (const auto& s : specs) {
        auto hit = m_hud.find(s.key);
        if (hit == m_hud.end() || !hit->second.on) {
            continue;
        }
        auto* td = sdk::find_type_definition(s.type);
        auto* rt = td ? td->get_runtime_type() : nullptr;
        if (!rt) {
            continue;
        }
        auto* arr = re4vr::safe([&] { return sdk::call_object_func_easy<sdk::SystemArray*>(scene, "findComponents(System.Type)", rt); }).value_or(nullptr);
        if (!arr || arr->get_size() == 0) {
            continue;
        }
        auto* beh = arr->get_element(0);
        auto* mainp = beh ? sdk::get_object_field<::REManagedObject*>(beh, "_Main") : nullptr;
        auto* ctrl = mainp ? *mainp : nullptr;
        if (!ctrl) {
            continue;
        }
        m_hud_cache[s.key] = ctrl;
        auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(beh, "get_GameObject"); }).value_or(nullptr);
        if (go) {
            m_hud_names.insert(re4vr::go_name((::REManagedObject*)go));
        }
        const auto& h = hit->second;
        if (h.bx && h.by) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(ctrl, "set_Position", Vector3f{*h.bx + h.x, *h.by + h.y, 0}); });
        }
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(ctrl, "set_Scale", Vector3f{h.scale, h.scale, h.scale}); });
    }
}

::REManagedObject* RE4VRMerc::hud_root_ctrl(::REManagedObject* go) {
    auto* comp = re4vr::get_component(go, "via.gui.GUI");
    auto* view = comp ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(comp, "get_View"); }).value_or(nullptr) : nullptr;
    return view ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(view, "get_Child"); }).value_or(nullptr) : nullptr;
}

::REManagedObject* RE4VRMerc::child_by_name(::REManagedObject* ctrl, const std::string& want) {
    if (!ctrl) {
        return nullptr;
    }
    auto* ch = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctrl, "get_Child"); }).value_or(nullptr);
    while (ch) {
        const auto nm = re4vr::obj_name(ch);
        if (nm == want) {
            return ch;
        }
        auto* found = child_by_name(ch, want);
        if (found) {
            return found;
        }
        ch = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ch, "get_Next"); }).value_or(nullptr);
    }
    return nullptr;
}

void RE4VRMerc::dot_tick() {
    if (!RE4VRShared::get()->re4_merc_dot) {
        return;
    }
    auto* body = re4vr::body_game_object();
    if (!body) {
        m_dot_body_weg = true;
    } else if (m_dot_body_weg) {
        m_dot_body_weg = false;
        m_dot_aimed = false;
        m_dot_lsc = nullptr;
        m_dot_key.reset();
        m_dot_tries = 0;
    }
    if (!m_in_mercs) {
        m_dot_lsc = nullptr;
        m_dot_key.reset();
        m_dot_aimed = false;
        return;
    }
    auto* ctx = re4vr::player_context();
    auto* hu = ctx ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(ctx, "get_HeadUpdater"); }).value_or(nullptr) : nullptr;
    auto* g = hu ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(hu, "get_EquipWeapon"); }).value_or(nullptr) : nullptr;
    if (!g) {
        return;
    }
    auto* td = utility::re_managed_object::get_type_definition(g);
    if (!td || !td->is_a("chainsaw.Gun")) {
        return;
    }
    const auto wid = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(g, "get_WeaponID"); });
    if (!wid || !LASER_WIDS.count(*wid)) {
        return;
    }
    if (re4vr::safe([&] { return sdk::call_object_func_easy<bool>(g, "get_EnableLaserSight"); }).value_or(false)) {
        return;
    }
    auto* wgo = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(g, "get_GameObject"); }).value_or(nullptr);
    if (!wgo) {
        return;
    }
    const uintptr_t key = (uintptr_t)wgo;
    if (!m_dot_key || *m_dot_key != key) {
        m_dot_key = key;
        m_dot_lsc = nullptr;
        m_dot_tries = 0;
        m_dot_aimed = false;
    }
    if (!m_dot_aimed) {
        if (!RE4VRShared::get()->vr_aim_input) {
            return;
        }
        m_dot_aimed = true;
    }
    if (!m_dot_lsc) {
        const double t = re4vr::now();
        if (t < m_dot_next_scan) {
            return;
        }
        m_dot_next_scan = t + 0.5;
        auto* lsc_t = sdk::find_type_definition("chainsaw.LaserSightController");
        auto* rt = lsc_t ? lsc_t->get_runtime_type() : nullptr;
        std::function<::REManagedObject*(::REManagedObject*, int)> find = [&](::REManagedObject* go, int depth) -> ::REManagedObject* {
            if (!go || !rt || depth > 6) {
                return nullptr;
            }
            auto* c = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(go, "getComponent(System.Type)", rt); }).value_or(nullptr);
            if (c) {
                return c;
            }
            auto* tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr);
            auto* child = tf ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(tf, "get_Child"); }).value_or(nullptr) : nullptr;
            int guard = 0;
            while (child && guard++ < 128) {
                auto* cgo = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(child, "get_GameObject"); }).value_or(nullptr);
                if (auto* r = find((::REManagedObject*)cgo, depth + 1)) {
                    return r;
                }
                child = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(child, "get_Next"); }).value_or(nullptr);
            }
            return nullptr;
        };
        m_dot_lsc = find((::REManagedObject*)wgo, 0);
        if (!m_dot_lsc) {
            return;
        }
    }
    auto* pe_eq = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(g, "get_OwnerEquipment"); }).value_or(nullptr);
    if (pe_eq) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe_eq, "set_IsEnableLaserSight", true); });
    }
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(g, "castLaserSightTip"); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(g, "updateLaserSightTip"); });
    auto* isdraw = sdk::get_object_field<bool>(m_dot_lsc, "_IsDraw");
    if (!isdraw || !*isdraw) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_dot_lsc, "setDraw", true); });
        if (isdraw) {
            *isdraw = true;
        }
    }
    if (m_dot_tries < 3) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m_dot_lsc, "start"); });
        ++m_dot_tries;
    }
}

HookManager::PreHookResult RE4VRMerc::pre_bare_hand(std::vector<uintptr_t>&, std::vector<sdk::RETypeDefinition*>&, uintptr_t ret_addr) {
    auto& self = *get();
    self.m_bk_skipped = false;
    if (!self.m_in_mercs) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    const auto wid = RE4VRShared::get()->vr_dbg_wep_id;
    if (!wid || (int)*wid != BOW_WID) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    if (RE4VRShared::get()->re4_holster_killswitch || RE4VRShared::get()->re4_ks4_active) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    HMODULE mod = nullptr;
    const bool from_ref = GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        (LPCSTR)ret_addr, &mod)
        && mod == REFramework::get_reframework_module();
    if (from_ref) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }
    self.m_bk_skipped = true;
    self.m_bk_blocked++;
    RE4VRShared::get()->re4_merc_bow_keep_blocked = self.m_bk_blocked;
    return HookManager::PreHookResult::SKIP_ORIGINAL;
}

void RE4VRMerc::post_bare_hand(uintptr_t& ret_val, sdk::RETypeDefinition*, uintptr_t) {
    auto& self = *get();
    if (self.m_bk_skipped) {
        self.m_bk_skipped = false;
        if (!self.m_bk_void) {
            ret_val = 0;
        }
    }
}

std::optional<std::string> RE4VRMerc::on_initialize() {
    m_hud["timer"] = HudPart{true, 1.0f, 0, 0, 960.0f, 0.0f, "chainsaw.Cp1021TimerGuiBehavior", "_Main", "", false};
    m_hud["score"] = HudPart{true, 1.0f, 0, 0, 1444.0f, 0.0f, "chainsaw.Cp1021HudScoreDispGuiBehavior", "_Main", "", false};
    m_hud["combo"] = HudPart{true, 1.0f, 0, 0, 1920.0f, 0.0f, "chainsaw.Cp1021HudComboGuiBehavior", "_Main", "", false};
    m_hud["total"] = HudPart{true, 1.0f, 0, 0, 1520.0f, 66.0f, "chainsaw.Cp1021HudTotalScoreGuiBehavior", "_Main", "", false};
    m_hud["gauge"] = HudPart{true, 1.0f, 0, 0, 0.0f, -20.0f, "chainsaw.BulletRushGaugeGuiBehavior", "_Main", "", false};
    m_hud["ui2710"] = HudPart{true, 1.0f, 0, 0, std::nullopt, std::nullopt, "", "", "Gui_ui2710", false};
    m_hud["ui2764"] = HudPart{true, 1.0f, 0, 0, std::nullopt, std::nullopt, "", "", "Gui_ui2764", false};
    load_json();
    RE4VRMenu::get()->add(70, "merc_hud", [this]() {
        if (!m_in_mercs) {
            return;
        }
        ImGui::Text("HUD (nur Mercenaries)");
        if (ImGui::Checkbox("Gui_ui2770 ausblenden", &m_hide_2770)) {
            save_json();
        }
        if (ImGui::Checkbox("Hintergrund hinter dem Countdown aus", &m_hide_timer_bg)) {
            save_json();
        }
    });
    if (auto* td = sdk::find_type_definition("via.render.Mesh")) {
        m_t_mesh = td->get_runtime_type();
    }
    if (auto* td = sdk::find_type_definition("via.render.Fur")) {
        m_t_fur = td->get_runtime_type();
    }
    if (auto* td = sdk::find_type_definition("via.render.ShellFurMesh")) {
        m_t_shellfur = td->get_runtime_type();
    }
    if (auto* ptd = sdk::find_type_definition("chainsaw.PlayerEquipment")) {
        if (auto* m = ptd->get_method("requestEquipBareHand(System.Boolean, System.Boolean)")) {
            auto* rt = m->get_return_type();
            m_bk_void = !rt || std::string{rt->get_full_name()} == "System.Void";
            g_hookman.add(m, &RE4VRMerc::pre_bare_hand, &RE4VRMerc::post_bare_hand);
        }
    }
    return std::nullopt;
}

void RE4VRMerc::on_lua_state_created(sol::state& lua) {
    re4vr::export_pose_api(lua);
    lua["__re4_merc_wep_apply"] = [this](sol::object wpos, sol::object wrot, sol::object wid_o, sol::object hand)
        -> std::optional<std::tuple<Vector3f, glm::quat>> {
        auto p = re4vr::as_vec3(wpos);
        auto r = re4vr::as_quat(wrot);
        int32_t wid = 0;
        if (wid_o.is<int>()) {
            wid = wid_o.as<int>();
        } else if (wid_o.is<double>()) {
            wid = (int32_t)wid_o.as<double>();
        }
        if (!p || !r) {
            return std::nullopt;
        }
        glm::quat hr{};
        const glm::quat* hrp = nullptr;
        if (auto hq = re4vr::as_quat(hand)) {
            hr = *hq;
            hrp = &hr;
        }
        Vector3f np{};
        glm::quat nr{};
        if (!wep_apply(*p, *r, wid, hrp, np, nr)) {
            return std::nullopt;
        }
        return std::make_tuple(np, nr);
    };
    lua["__re4_merc_apply_bow_pose"] = [this]() { apply_bow_pose(); };
}

void RE4VRMerc::on_lua_state_destroyed(sol::state&) {
    bow_unpin();
    m_hh_meshes.clear();
    m_all_meshes.clear();
}

void RE4VRMerc::on_frame() {
    ScriptProfileGuard guard("re4_vr_merc.lua", "on_frame", re4vr::profile_frame());
    update_bulletrush();
    update_bow_pin();
    apply_full_hide();
    apply_hide();
    hud_apply();
    ++m_frames;
    if (m_frames % 30 != 0) {
        return;
    }
    auto [in_mercs, cid] = detect();
    if (in_mercs) {
        std::optional<int32_t> kind;
        std::string body;
        ::RETransform* tf = nullptr;
        get_player_body(kind, body, tf);
        if (!body.empty()) {
            m_merc_body_ok = MERC_BODY_SET.count(body) > 0;
        }
        in_mercs = m_merc_body_ok;
    } else {
        m_merc_body_ok = false;
    }
    m_in_mercs = in_mercs;
    RE4VRShared::get()->re4_in_mercs = in_mercs;
    if (cid) {
        RE4VRShared::get()->re4_merc_cid = *cid;
    } else {
        RE4VRShared::get()->re4_merc_cid.reset();
    }
    if (!in_mercs) {
        RE4VRShared::get()->re4_merc_kind.reset();
        RE4VRShared::get()->re4_merc_body.reset();
        RE4VRShared::get()->vr_active_char.reset();
        m_hh_meshes.clear();
        m_all_meshes.clear();
        m_full_hidden = false;
        return;
    }
    std::optional<int32_t> kind;
    std::string body;
    ::RETransform* tf = nullptr;
    get_player_body(kind, body, tf);
    if (kind) {
        RE4VRShared::get()->re4_merc_kind = *kind;
    }
    if (!body.empty()) {
        RE4VRShared::get()->re4_merc_body = std::string{body};
    }
    if (body.empty()) {
        m_hh_meshes.clear();
        m_all_meshes.clear();
        m_full_hidden = false;
        if (!m_round_gap) {
            m_round_gap = true;
            const int round = (int)RE4VRShared::get()->re4_merc_round.value_or(0) + 1;
            RE4VRShared::get()->re4_merc_round = round;
        }
        return;
    }
    m_round_gap = false;
    if (kind) {
        auto ak = MERC_ARM_KEYS.find(*kind);
        RE4VRShared::get()->vr_active_char = std::string{ak != MERC_ARM_KEYS.end() ? ak->second : "leon"};
    }
    if (m_hh_body != body || m_hh_meshes.empty()) {
        auto hide = kind ? hide_for(*kind) : std::unordered_map<std::string, bool>{};
        collect_hh(tf, hide.empty() ? nullptr : &hide);
        collect_all_meshes(tf);
        m_hh_body = body;
    }
}

void RE4VRMerc::on_application_entry(void*, const char*, size_t hash) {
    if (hash == "LateUpdateBehavior"_fnv) {
        ScriptProfileGuard guard("re4_vr_merc.lua", "on_application_entry:LateUpdateBehavior", re4vr::profile_frame());
        dot_tick();
        hud_apply();
    } else if (hash == "BeginRendering"_fnv) {
        ScriptProfileGuard guard("re4_vr_merc.lua", "on_application_entry:BeginRendering", re4vr::profile_frame());
        hud_apply();
    }
}

bool RE4VRMerc::on_pre_gui_draw_element(REComponent* gui_element, void*) {
    if (!m_in_mercs || !gui_element) {
        return true;
    }
    auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(gui_element, "get_GameObject"); }).value_or(nullptr);
    const auto nm = re4vr::go_name((::REManagedObject*)go);
    if (nm.empty()) {
        return true;
    }
    for (auto& [k, cfg] : m_hud) {
        if (cfg.go == nm && cfg.on) {
            auto* ctrl = hud_root_ctrl((::REManagedObject*)go);
            if (ctrl) {
                if (!cfg.bx || !cfg.by) {
                    auto p = re4vr::safe([&] { return sdk::call_object_func_easy<Vector3f>(ctrl, "get_Position"); });
                    if (p) {
                        cfg.bx = p->x;
                        cfg.by = p->y;
                    }
                }
                if (cfg.bx && cfg.by) {
                    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(ctrl, "set_Position", Vector3f{*cfg.bx + cfg.x, *cfg.by + cfg.y, 0}); });
                }
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(ctrl, "set_Scale", Vector3f{cfg.scale, cfg.scale, cfg.scale}); });
            }
        }
    }
    if (nm == "Gui_ui2770" && m_hide_2770) {
        return false;
    }
    if (nm == "Gui_ui2700" && m_hide_timer_bg) {
        auto* root = hud_root_ctrl((::REManagedObject*)go);
        if (auto* a = child_by_name(root, "c_bg_new")) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(a, "set_Visible", false); });
        }
        if (auto* t = child_by_name(root, "c_timer")) {
            if (auto* b = child_by_name(t, "c_bg")) {
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(b, "set_Visible", false); });
            }
        }
    }
    return true;
}
#endif
