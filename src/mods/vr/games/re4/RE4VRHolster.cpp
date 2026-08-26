#define NOMINMAX
#include "RE4VRHolster.hpp"

#if defined(RE4)
#include <algorithm>
#include <cmath>
#include <functional>
#include <tuple>

#include <glm/gtc/quaternion.hpp>
#include <glm/gtx/norm.hpp>
#include <glm/gtx/quaternion.hpp>
#include <sdk/MurmurHash.hpp>
#include <sdk/RETypeDB.hpp>
#include <sdk/SceneManager.hpp>
#include <sdk/SystemArray.hpp>
#include <spdlog/spdlog.h>

#include "RE4VRCrosshair.hpp"
#include "RE4VRFrameCache.hpp"
#include "RE4VRMenu.hpp"
#include "RE4VRShared.hpp"
#include "../../../ScriptRunner.hpp"

#include <imgui.h>
#include <sdk/RETransform.hpp>

namespace {
const char* CHEST_JOINTS[] = {"Spine_1", "Spine1", "Spine_2", "Spine2", "Chest", "Kammer", "Spine", "Hip"};
constexpr uint32_t HOLSTER_GRAB_SND = 1839787494u;
constexpr uint32_t GRENADE_GRAB_SND = 3388506884u;
constexpr int32_t NO_WEP_STAGES[] = {40500, 40501, 40502, 40510};
constexpr int32_t KNIFE_ONLY_STAGE = 55302;
constexpr int32_t KRAUSER_KIND = 200011;

float jn(const nlohmann::json& c, const char* k, float d = 0.0f) {
    return re4vr::j_num(c, k, d);
}
bool jb(const nlohmann::json& c, const char* k, bool d = false) {
    return re4vr::j_bool(c, k, d);
}
std::string js(const nlohmann::json& c, const char* k) {
    if (!c.contains(k) || !c[k].is_string()) {
        return {};
    }
    return c[k].get<std::string>();
}

void walk_tf(::RETransform* t, int depth, const std::function<void(::REGameObject*)>& fn) {
    if (!t || depth > 5) {
        return;
    }
    auto* go = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(t, "get_GameObject"); }).value_or(nullptr);
    if (go) {
        fn(go);
    }
    auto* c = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(t, "get_Child"); }).value_or(nullptr);
    while (c) {
        walk_tf(c, depth + 1, fn);
        c = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(c, "get_Next"); }).value_or(nullptr);
    }
}

int32_t enum_num(::REManagedObject* o) {
    if (!o) {
        return 0;
    }
    if (auto n = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(o, "ToInt32"); })) {
        return *n;
    }
    auto v = re4vr::safe([&] { return utility::re_managed_object::get_field<int32_t>(o, "value__"); });
    return v.value_or(0);
}

void* typeof_t(const char* n) {
    return re4vr::runtime_type(n);
}
}

std::shared_ptr<RE4VRHolster>& RE4VRHolster::get() {
    static auto inst = std::make_shared<RE4VRHolster>();
    return inst;
}

void RE4VRHolster::default_slot_cfg(nlohmann::json& c) {
    c = {
        {"enabled", true}, {"off_x", 0.10}, {"off_y", 0.10}, {"off_z", 0.12},
        {"rx", 0.0}, {"ry", 0.0}, {"rz", 0.0}, {"scale", 1.0}, {"smooth", 0.8},
        {"grab_trigger", 0.16}, {"grab_release", 0.24}, {"grab_haptic", true}, {"grab_haptic_delay", 0.0},
        {"pl_x", 0.0}, {"pl_y", 0.0}, {"pl_z", 0.0},
        {"md_x", 0.0}, {"md_y", 0.0}, {"md_z", 0.0},
        {"md_x_wid", nlohmann::json::object()},
        {"dim_in_use", true}, {"dim_factor", 0.12}, {"joint", ""},
        {"zx", 0.18}, {"zy", 0.20}, {"zz", -0.20}, {"shift_x", 0.0},
    };
}

glm::quat RE4VRHolster::hol_quat(float rx, float ry, float rz) {
    const float cx = std::cos(rx * 0.5f), sx = std::sin(rx * 0.5f);
    const float cy = std::cos(ry * 0.5f), sy = std::sin(ry * 0.5f);
    const float cz = std::cos(rz * 0.5f), sz = std::sin(rz * 0.5f);
    return glm::normalize(glm::quat{
        cx * cy * cz + sx * sy * sz,
        sx * cy * cz - cx * sy * sz,
        cx * sy * cz + sx * cy * sz,
        cx * cy * sz - sx * sy * cz,
    });
}

std::optional<std::string> RE4VRHolster::on_initialize() {
    m_knife = Slot{"knife", "re4_vr/re4_vr_knife.json", "re4_vr/re4_vr_knife_ada.json",
        "__vr_knife_chest_pos", "__vr_knife_holster_zone",
        {5000, 5001, 5002, 5003, 5006, 6107, 6108, 6305}};
    m_pistol = Slot{"pistol", "re4_vr/re4_vr_pistol_holster.json", "",
        "__vr_pistol_holster_pos", "__vr_pistol_holster_zone",
        {4000, 4001, 4002, 4003, 4004, 4500, 4501, 4502, 6000, 6103, 6112, 6113, 6300, 6301}};
    m_grenade = Slot{"grenade", "re4_vr/re4_vr_grenade_holster.json", "",
        "__vr_grenade_holster_pos", "__vr_grenade_holster_zone", {5400, 5401, 5402}};
    m_shoulder = Slot{"shoulder", "re4_vr/re4_vr_shoulder_holster.json", "",
        "__vr_shoulder_holster_pos", "__vr_shoulder_holster_zone",
        {4100, 4101, 4102, 4200, 4201, 4202, 4400, 4401, 4402, 4600, 4701, 4702, 4900, 4901, 4902,
            6001, 6100, 6101, 6102, 6104, 6105, 6106, 6111, 6114, 6304, 4800, 4801, 6109}};
    m_shoulder.detached_zone = true;
    m_shoulder.all_parts = true;
    for (auto* s : {&m_knife, &m_pistol, &m_grenade, &m_shoulder}) {
        default_slot_cfg(s->cfg);
        if (s->name == "shoulder") {
            s->cfg["zx"] = 0.20;
            s->cfg["zy"] = -0.15;
            s->cfg["zz"] = -0.30;
            s->cfg["grab_trigger"] = 0.22;
            s->cfg["grab_release"] = 0.32;
        }
        load_slot(*s, s->path);
    }
    default_slot_cfg(m_mag_cfg);
    m_mag_cfg["off_x"] = -0.16;
    m_mag_cfg["off_y"] = -0.28;
    m_mag_cfg["off_z"] = 0.06;
    auto mag = re4vr::load_json_file("re4_vr/re4_vr_mag_holster.json");
    if (!mag.empty()) {
        for (auto it = mag.begin(); it != mag.end(); ++it) {
            if (m_mag_cfg.contains(it.key())) {
                m_mag_cfg[it.key()] = it.value();
            }
        }
    }
    auto tap = re4vr::load_json_file("re4_vr/re4_vr_holster_tap.json");
    m_aim_hold = re4vr::j_num(tap, "aim_hold", 0.35f);
    RE4VRShared::get()->re4_holster_crouch_gain = re4vr::j_num(tap, "crouch_gain", 0.0f);
    RE4VRShared::get()->re4_holster_ada_mesh_z = re4vr::j_num(tap, "ada_mesh_z", 0.0f);

    m_mesh_t = typeof_t("via.render.Mesh");
    m_snd_t = typeof_t("soundlib.SoundContainer");

    if (auto* td = sdk::find_type_definition("share.Startup")) {
        if (auto* m = td->get_method("updateOnFrameHead")) {
            g_hookman.add(m, &RE4VRHolster::pre_nop, &RE4VRHolster::post_update_head);
        }
    }
    if (auto* td = sdk::find_type_definition("chainsaw.PlayerEquipment")) {
        for (auto& m : td->get_methods()) {
            const auto n = std::string{m.get_name()};
            if (n == "requestEquipKnife") {
                g_hookman.add(&m, &RE4VRHolster::pre_request_equip_knife, &RE4VRHolster::post_nop);
            } else if (n == "requestEquipMelee") {
                g_hookman.add(&m, &RE4VRHolster::pre_melee_gate, &RE4VRHolster::post_nop);
            }
        }
    }
    RE4VRShared::get()->re4_knife_gate = true;
    RE4VRShared::get()->re4_melee_gate = true;
    RE4VRShared::get()->re4_knife_holster_hook = true;
    RE4VRShared::get()->re4_knife_gate_hook = true;
    RE4VRShared::get()->re4_melee_gate_hook = true;
    register_ui();
    return std::nullopt;
}

void RE4VRHolster::load_slot(Slot& s, const std::string& path) {
    auto d = re4vr::load_json_file(path);
    if (d.empty()) {
        return;
    }
    static const std::unordered_map<std::string, std::string> map{
        {"chest_enabled", "enabled"}, {"chest_off_x", "off_x"}, {"chest_off_y", "off_y"}, {"chest_off_z", "off_z"},
        {"chest_rx", "rx"}, {"chest_ry", "ry"}, {"chest_rz", "rz"}, {"chest_scale", "scale"},
        {"chest_smooth", "smooth"}, {"chest_joint", "joint"},
    };
    for (auto& [oldk, newk] : map) {
        if (d.contains(oldk) && s.cfg.contains(newk)) {
            s.cfg[newk] = d[oldk];
        }
    }
    for (auto it = d.begin(); it != d.end(); ++it) {
        if (s.cfg.contains(it.key())) {
            s.cfg[it.key()] = it.value();
        }
    }
}

void RE4VRHolster::save_slot(Slot& s) {
    const auto ch = RE4VRShared::get()->re4_knife_char.value_or("");
    if (ch == "ada" && s.path == "re4_vr/re4_vr_knife.json") {
        return;
    }
    if (ch == "leon" && s.path == "re4_vr/re4_vr_knife_ada.json") {
        return;
    }
    re4vr::save_json_file(s.path, s.cfg);
}

::REManagedObject* RE4VRHolster::ctx() {
    auto& fc = RE4VRFrameCache::get();
    if (fc->on()) {
        return fc->ctx();
    }
    return re4vr::player_context();
}

::RETransform* RE4VRHolster::body_tf() {
    auto& fc = RE4VRFrameCache::get();
    if (fc->on()) {
        return fc->body_tf();
    }
    return re4vr::body_transform();
}

std::optional<int32_t> RE4VRHolster::equip_wid() {
    auto& fc = RE4VRFrameCache::get();
    if (fc->on()) {
        return fc->equip_wid();
    }
    auto* c = ctx();
    if (!c) {
        return std::nullopt;
    }
    auto* hu = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(c, "get_HeadUpdater"); }).value_or(nullptr);
    if (!hu) {
        return std::nullopt;
    }
    auto wid = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(hu, "get_EquipWeaponID"); });
    if (wid) {
        return *wid;
    }
    auto* wido = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(hu, "get_EquipWeaponID"); }).value_or(nullptr);
    if (wido) {
        return enum_num(wido);
    }
    return std::nullopt;
}

::REManagedObject* RE4VRHolster::get_pe() {
    auto& fc = RE4VRFrameCache::get();
    if (fc->on()) {
        return fc->pe();
    }
    if (re4vr::obj_ok(m_pe) && re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(m_pe, "get_Context"); })) {
        return m_pe;
    }
    auto* c = ctx();
    auto* head = c ? re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(c, "get_HeadGameObject"); }).value_or(nullptr) : nullptr;
    m_pe = head ? re4vr::get_component((::REManagedObject*)head, "chainsaw.PlayerEquipment") : nullptr;
    return m_pe;
}

::REManagedObject* RE4VRHolster::equip_type_main() {
    if (m_et_main) {
        return m_et_main;
    }
    auto* td = sdk::find_type_definition("chainsaw.EquipType");
    auto* f = td ? td->get_field("Main") : nullptr;
    m_et_main = f ? (::REManagedObject*)f->get_data<void*>(nullptr) : nullptr;
    return m_et_main;
}

std::string RE4VRHolster::guid_to_string(::REManagedObject* g) {
    if (!g) {
        return {};
    }
    static const char* sets[][4] = {{"mData1", "mData2", "mData3", "mData4"}, {"_a", "_b", "_c", "_d"}};
    for (auto& set : sets) {
        auto a = re4vr::safe([&] { return utility::re_managed_object::get_field<int32_t>(g, set[0]); });
        if (!a) {
            continue;
        }
        std::string out;
        for (int i = 0; i < 4; ++i) {
            auto v = re4vr::safe([&] { return utility::re_managed_object::get_field<int32_t>(g, set[i]); });
            if (i) {
                out += "-";
            }
            out += std::to_string(v.value_or(0));
        }
        return out;
    }
    return {};
}

std::vector<::REManagedObject*> RE4VRHolster::inventory_rows(::REManagedObject* inv) {
    std::vector<::REManagedObject*> out;
    if (!inv) {
        return out;
    }
    auto* list = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(inv, "getInventoryItemList"); }).value_or(nullptr);
    if (!list) {
        return out;
    }
    const int n = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(list, "get_Count"); }).value_or(0);
    for (int i = 0; i < n; ++i) {
        auto* row = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(list, "get_Item", i); }).value_or(nullptr);
        auto* wid = row ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(row, "get_WeaponId"); }).value_or(nullptr) : nullptr;
        if (wid && enum_num(wid) != 0) {
            out.push_back(row);
        }
    }
    return out;
}

bool RE4VRHolster::has_weapon_in_inventory(const std::unordered_set<int32_t>& ids) {
    auto* pe = get_pe();
    auto* inv = pe ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(pe, "get_InventoryController"); }).value_or(nullptr) : nullptr;
    if (!inv) {
        return false;
    }
    for (auto* row : inventory_rows(inv)) {
        auto* w = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(row, "get_WeaponId"); }).value_or(nullptr);
        if (w && ids.contains(enum_num(w))) {
            return true;
        }
    }
    return false;
}

::REManagedObject* RE4VRHolster::find_row(::REManagedObject* inv, int32_t wid, const std::string& guid) {
    auto rows = inventory_rows(inv);
    if (!guid.empty()) {
        std::string want = guid;
        std::transform(want.begin(), want.end(), want.begin(), [](unsigned char c) { return (char)std::tolower(c); });
        for (auto* row : rows) {
            auto* id = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(row, "get_ID"); }).value_or(nullptr);
            auto g = guid_to_string(id);
            std::transform(g.begin(), g.end(), g.begin(), [](unsigned char c) { return (char)std::tolower(c); });
            if (g == want) {
                return row;
            }
        }
    }
    for (auto* row : rows) {
        auto* w = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(row, "get_WeaponId"); }).value_or(nullptr);
        if (w && enum_num(w) == wid) {
            return row;
        }
    }
    return nullptr;
}

::REGameObject* RE4VRHolster::find_weapon_go(const std::unordered_set<int32_t>& ids, std::optional<int32_t> want) {
    auto* tf = body_tf();
    if (!tf) {
        return nullptr;
    }
    ::REGameObject* any = nullptr;
    ::REGameObject* wanted = nullptr;
    walk_tf(tf, 0, [&](::REGameObject* go) {
        if (wanted || !go) {
            return;
        }
        const auto nm = re4vr::go_name((::REManagedObject*)go);
        int id = 0;
        if (nm.size() > 2 && nm[0] == 'w' && nm[1] == 'p') {
            id = std::atoi(nm.c_str() + 2);
        }
        if (id && ids.contains(id) && re4vr::go_valid((::REManagedObject*)go)) {
            if (!any) {
                any = go;
            }
            if (want && id == *want) {
                wanted = go;
            }
        }
    });
    return wanted ? wanted : any;
}

bool RE4VRHolster::slot_dormant(const Slot& s) const {
    if (RE4VRShared::get()->re4_holster_killswitch) {
        return true;
    }
    return RE4VRShared::get()->re4_holster_knife_only && s.name != "knife";
}

::REJoint* RE4VRHolster::slot_joint(Slot& s) {
    auto* tf = body_tf();
    if (!tf) {
        return nullptr;
    }
    if (s.joint && s.joint_ok_frame == m_hol_frame) {
        return s.joint;
    }
    bool valid = false;
    if (s.joint) {
        valid = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(s.joint, "get_Valid"); }).value_or(false);
    }
    if (valid) {
        s.joint_ok_frame = m_hol_frame;
        return s.joint;
    }
    s.joint = nullptr;
    for (auto* nm : CHEST_JOINTS) {
        if (auto* j = re4vr::joint_by_name(tf, nm)) {
            s.joint = j;
            s.cfg["joint"] = nm;
            break;
        }
    }
    return s.joint;
}

void RE4VRHolster::destroy_slot(Slot& s) {
    if (s.clone_obj) {
        re4vr::destroy_game_object((::REManagedObject*)s.clone_obj);
    }
    s.clone_obj = nullptr;
    s.clone_mesh = nullptr;
    s.clone_tf = nullptr;
    s.clone_wid.reset();
    s.parented = false;
    s.part0_done = false;
    s.sm_has = false;
    s.mat_dim.clear();
    s.mat_zero.clear();
    s.scale_written.reset();
    s.src_addr = 0;
}

bool RE4VRHolster::spawn_slot(Slot& s, ::REManagedObject* gmesh) {
    if (!gmesh) {
        return false;
    }
    auto* holder = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(gmesh, "getMesh"); }).value_or(nullptr);
    if (!holder) {
        return false;
    }
    auto* gmat = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(gmesh, "get_Material"); }).value_or(nullptr);
    auto* go = re4vr::create_game_object(std::string("vr_holster_") + s.name);
    if (!go) {
        return false;
    }
    re4vr::pcall([&] { utility::re_managed_object::add_ref(go); });
    re4vr::pcall([&] { sdk::call_object_func_easy<::REManagedObject*>(go, "createComponent(System.Type)", typeof_t("via.motion.Motion")); });
    auto* mesh = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(go, "createComponent(System.Type)", typeof_t("via.render.Mesh")); }).value_or(nullptr);
    if (!mesh) {
        return false;
    }
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "setMesh", holder); });
    if (gmat) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "set_Material", gmat); });
    }
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "set_DrawDefault", true); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "set_Enabled", true); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "set_FrustumCulling", false); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "set_DrawShadowCast", false); });
    slot_joint(s);
    auto* ctf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr);
    auto* bgo = re4vr::body_game_object();
    auto* btf = (bgo && re4vr::go_valid((::REManagedObject*)bgo))
        ? re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(bgo, "get_Transform"); }).value_or(nullptr)
        : nullptr;
    s.parented = false;
    if (ctf && btf && re4vr::go_valid((::REManagedObject*)go)) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(ctf, "set_Parent", btf); });
        std::string jn = js(s.cfg, "joint");
        if (jn.empty()) {
            jn = "Spine_1";
        }
        if (re4vr::pcall([&] { sdk::call_object_func_easy<void*>(ctf, "set_ParentJoint", sdk::VM::create_managed_string(utility::widen(jn))); })) {
            s.parented = true;
        }
    }
    s.clone_obj = go;
    s.clone_mesh = mesh;
    s.clone_tf = ctf;
    return true;
}

void RE4VRHolster::apply_slot(Slot& s) {
    if (s.detached_zone) {
        Vector3f hmd, right, up, fwd;
        if (hmd_basis(hmd, right, up, fwd)) {
            const float ox = jn(s.cfg, "zx"), oy = jn(s.cfg, "zy"), oz = jn(s.cfg, "zz");
            re4vr::lua_set_vec3(s.anchor_g, hmd + right * ox + up * oy + fwd * oz);
        }
    }
    if (!s.clone_obj) {
        return;
    }
    auto* tf = s.clone_tf;
    if (!tf) {
        tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(s.clone_obj, "get_Transform"); }).value_or(nullptr);
        s.clone_tf = tf;
    }
    if (!tf) {
        return;
    }
    const float scv = jn(s.cfg, "scale", 1.0f);
    const float d = (float)RE4VRShared::get()->re4_ub_z_delta.value_or(0);
    const float g = (float)RE4VRShared::get()->re4_holster_crouch_gain.value_or(0);
    const float az = (RE4VRShared::get()->re4_knife_char.value_or("") == "ada")
        ? (float)RE4VRShared::get()->re4_holster_ada_mesh_z.value_or(0)
        : 0.0f;
    const float cz = -d * g + az;
    auto write_scale = [&] {
        if (!s.scale_written || *s.scale_written != scv) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(tf, "set_LocalScale", Vector3f{scv, scv, scv}); });
            s.scale_written = scv;
        }
    };
    if (s.parented) {
        float wx = 0;
        if (s.cfg.contains("md_x_wid") && s.cfg["md_x_wid"].is_object() && s.clone_wid) {
            wx = re4vr::j_num(s.cfg["md_x_wid"], std::to_string(*s.clone_wid).c_str(), 0);
        }
        const float lx = jn(s.cfg, "off_x") + jn(s.cfg, "md_x") + jn(s.cfg, "shift_x") + wx;
        const float ly = jn(s.cfg, "off_y") + jn(s.cfg, "md_y");
        const float lz = jn(s.cfg, "off_z") + jn(s.cfg, "md_z");
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(tf, "set_LocalPosition", Vector3f{lx, ly, lz + cz}); });
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(tf, "set_LocalRotation", hol_quat(jn(s.cfg, "rx"), jn(s.cfg, "ry"), jn(s.cfg, "rz"))); });
        write_scale();
        auto wp = re4vr::safe([&] { return sdk::get_transform_position(tf); });
        auto wr = re4vr::safe([&] { return sdk::get_transform_rotation(tf); });
        if (wp && !s.detached_zone) {
            Vector3f a = re4vr::v3(*wp);
            if (cz != 0 && s.joint) {
                auto jr = sdk::get_joint_rotation(s.joint);
                a -= re4vr::quat_rotate(jr, Vector3f{0, 0, cz});
            }
            const float plx = jn(s.cfg, "pl_x"), ply = jn(s.cfg, "pl_y"), plz = jn(s.cfg, "pl_z");
            if (wr && (plx != 0 || ply != 0 || plz != 0)) {
                a += re4vr::quat_rotate(*wr, Vector3f{plx, ply, plz});
            }
            re4vr::lua_set_vec3(s.anchor_g, a);
        }
        return;
    }
    auto* j = slot_joint(s);
    if (!j) {
        return;
    }
    const auto jp = re4vr::v3(sdk::get_joint_position(j));
    const auto jr = sdk::get_joint_rotation(j);
    const auto off = re4vr::quat_rotate(jr, Vector3f{jn(s.cfg, "off_x") + jn(s.cfg, "shift_x"), jn(s.cfg, "off_y"), jn(s.cfg, "off_z")});
    const auto tp = jp + off;
    const auto tr = glm::normalize(jr * hol_quat(jn(s.cfg, "rx"), jn(s.cfg, "ry"), jn(s.cfg, "rz")));
    sdk::set_transform_position(tf, re4vr::v4(tp));
    sdk::set_transform_rotation(tf, tr);
    write_scale();
    if (!s.detached_zone) {
        Vector3f a = tp;
        const float plx = jn(s.cfg, "pl_x"), ply = jn(s.cfg, "pl_y"), plz = jn(s.cfg, "pl_z");
        if (plx != 0 || ply != 0 || plz != 0) {
            a += re4vr::quat_rotate(tr, Vector3f{plx, ply, plz});
        }
        re4vr::lua_set_vec3(s.anchor_g, a);
    }
}

void RE4VRHolster::tick_slot(Slot& s) {
    if (slot_dormant(s) || !jb(s.cfg, "enabled", true)) {
        if (s.clone_obj) {
            destroy_slot(s);
        }
        s.grab_in_zone = false;
        s.last_dist = 99;
        re4vr::lua_set_bool(s.zone_g, false);
    }
    // manage
    const double now = re4vr::now();
    if (!slot_dormant(s) && jb(s.cfg, "enabled", true)) {
        if (now - s.inv_check_t > 0.5) {
            s.inv_check_t = now;
            s.has_inv = has_weapon_in_inventory(s.ids);
        }
        if (!s.has_inv) {
            if (s.clone_obj) {
                destroy_slot(s);
            }
        } else {
            auto ew = equip_wid();
            s.in_use = ew && s.ids.contains(*ew);
            if (s.clone_obj && !re4vr::go_valid((::REManagedObject*)s.clone_obj)) {
                destroy_slot(s);
            }
            if (s.clone_obj && now - s.last_check > 0.5) {
                s.last_check = now;
                auto* go = find_weapon_go(s.ids, s.clone_wid);
                const auto addr = (uintptr_t)go;
                if (addr && addr != s.src_addr) {
                    destroy_slot(s);
                }
            }
            if (!s.clone_obj) {
                auto* go = find_weapon_go(s.ids, s.name == "knife" ? std::optional<int32_t>(m_last_knife.wid ? m_last_knife.wid : 0) : std::nullopt);
                if (s.name == "pistol" && m_last_pistol.wid) {
                    go = find_weapon_go(s.ids, m_last_pistol.wid);
                }
                if (s.name == "grenade") {
                    go = find_weapon_go(s.ids, m_last_grenade.wid);
                }
                if (s.name == "shoulder" && m_last_rifle.wid) {
                    go = find_weapon_go(s.ids, m_last_rifle.wid);
                }
                if (s.name == "knife" && m_last_knife.wid) {
                    go = find_weapon_go(s.ids, m_last_knife.wid);
                }
                auto* mesh = go && m_mesh_t
                    ? re4vr::get_component((::REManagedObject*)go, "via.render.Mesh")
                    : nullptr;
                if (mesh && spawn_slot(s, mesh)) {
                    auto nm = re4vr::go_name((::REManagedObject*)go);
                    if (nm.size() > 2) {
                        s.clone_wid = std::atoi(nm.c_str() + 2);
                    }
                    s.src_addr = (uintptr_t)go;
                }
            }
            if (s.clone_obj && s.clone_mesh && !s.part0_done) {
                auto ready = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(s.clone_mesh, "get_MeshReady"); }).value_or(false);
                if (ready) {
                    for (int i = 0; i < 64; ++i) {
                        const bool en = s.all_parts || (s.clone_wid && *s.clone_wid == 4501) || i == 0;
                        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(s.clone_mesh, "setPartsEnable", i, en); });
                    }
                    s.part0_done = true;
                }
            }
            if (s.clone_obj && s.clone_mesh) {
                bool dark = jb(s.cfg, "dim_in_use", true) && s.in_use;
                if (s.name == "knife" && RE4VRShared::get()->re4_knife_left_clone) {
                    dark = true;
                }
                if (!s.last_dim || *s.last_dim != dark) {
                    if (s.mat_dim.empty()) {
                        const int mnum = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(s.clone_mesh, "get_MaterialNum"); }).value_or(0);
                        for (int mi = 0; mi < mnum; ++mi) {
                            const int vnum = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(s.clone_mesh, "getMaterialVariableNum", mi); }).value_or(0);
                            for (int vi = 0; vi < vnum; ++vi) {
                                auto* vn = re4vr::safe([&] { return sdk::call_object_func_easy<::SystemString*>(s.clone_mesh, "getMaterialVariableName", mi, vi); }).value_or(nullptr);
                                if (!vn) {
                                    continue;
                                }
                                auto name = utility::re_string::get_string(vn);
                                std::string low = name;
                                std::transform(low.begin(), low.end(), low.begin(), [](unsigned char c) { return (char)std::tolower(c); });
                                if (low.find("color") != std::string::npos || low.find("albedo") != std::string::npos
                                    || low.find("diffuse") != std::string::npos || low.find("basecol") != std::string::npos) {
                                    auto f4 = re4vr::safe([&] { return sdk::call_object_func_easy<Vector4f>(s.clone_mesh, "getMaterialFloat4", mi, vi); });
                                    if (f4) {
                                        s.mat_dim.push_back({mi, vi, f4->x, f4->y, f4->z, f4->w});
                                    }
                                } else if (low == "metallic" || low == "cavity") {
                                    auto v = re4vr::safe([&] { return sdk::call_object_func_easy<float>(s.clone_mesh, "getMaterialFloat", mi, vi); });
                                    if (v) {
                                        s.mat_zero.push_back({mi, vi, *v});
                                    }
                                }
                            }
                        }
                    }
                    const float df = dark ? jn(s.cfg, "dim_factor", 0.12f) : 1.0f;
                    for (auto& e : s.mat_dim) {
                        re4vr::pcall([&] {
                            sdk::call_object_func_easy<void*>(s.clone_mesh, "setMaterialFloat4", e.mi, e.vi,
                                Vector4f{e.x * df, e.y * df, e.z * df, e.w});
                        });
                    }
                    for (auto& e : s.mat_zero) {
                        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(s.clone_mesh, "setMaterialFloat", e.mi, e.vi, dark ? 0.0f : e.orig); });
                    }
                    s.last_dim = dark;
                }
            }
        }
    }
    // update_smooth: publish anchor from joint even without clone
    if (s.detached_zone) {
        Vector3f hmd, right, up, fwd;
        if (hmd_basis(hmd, right, up, fwd)) {
            re4vr::lua_set_vec3(s.anchor_g, hmd + right * jn(s.cfg, "zx") + up * jn(s.cfg, "zy") + fwd * jn(s.cfg, "zz"));
        }
    } else if (auto* j = slot_joint(s)) {
        const auto jp = re4vr::v3(sdk::get_joint_position(j));
        const auto jr = sdk::get_joint_rotation(j);
        const auto off = re4vr::quat_rotate(jr, Vector3f{jn(s.cfg, "off_x") + jn(s.cfg, "shift_x"), jn(s.cfg, "off_y"), jn(s.cfg, "off_z")});
        auto tp = jp + off;
        auto tr = glm::normalize(jr * hol_quat(jn(s.cfg, "rx"), jn(s.cfg, "ry"), jn(s.cfg, "rz")));
        const float a = 1.0f - std::clamp(jn(s.cfg, "smooth", 0.8f), 0.0f, 0.98f);
        if (!s.sm_has) {
            s.sm_p = tp;
            s.sm_r = tr;
            s.sm_has = true;
        } else {
            s.sm_p = glm::mix(s.sm_p, tp, a);
            if (glm::dot(s.sm_r, tr) < 0) {
                tr = -tr;
            }
            s.sm_r = glm::normalize(glm::slerp(s.sm_r, tr, a));
        }
        Vector3f an = s.sm_p;
        const float plx = jn(s.cfg, "pl_x"), ply = jn(s.cfg, "pl_y"), plz = jn(s.cfg, "pl_z");
        if (plx != 0 || ply != 0 || plz != 0) {
            an += re4vr::quat_rotate(s.sm_r, Vector3f{plx, ply, plz});
        }
        re4vr::lua_set_vec3(s.anchor_g, an);
    }
    // update_grab + knife lh zone
    if (s.name == "knife") {
        RE4VRShared::get()->re4_knife_grab_trigger = jn(s.cfg, "grab_trigger", 0.16f);
        RE4VRShared::get()->re4_knife_grab_release = jn(s.cfg, "grab_release", 0.24f);
        auto anchor = (!slot_dormant(s) && jb(s.cfg, "enabled", true)) ? re4vr::lua_vec3(s.anchor_g) : std::nullopt;
        auto lhp = anchor ? (RE4VRShared::get()->vr_lh_ctrl_raw ? RE4VRShared::get()->vr_lh_ctrl_raw : lh_world()) : std::nullopt;
        if (!anchor || !lhp) {
            RE4VRShared::get()->re4_knife_lh_dist.reset();
            m_lh_knife_zone = false;
            RE4VRShared::get()->re4_knife_lh_in_zone = false;
        } else {
            const float ld = glm::length(*lhp - *anchor);
            RE4VRShared::get()->re4_knife_lh_dist = ld;
            if (!m_lh_knife_zone) {
                if (ld <= jn(s.cfg, "grab_trigger", 0.16f)) {
                    m_lh_knife_zone = true;
                }
            } else if (ld > jn(s.cfg, "grab_release", 0.24f)) {
                m_lh_knife_zone = false;
            }
            RE4VRShared::get()->re4_knife_lh_in_zone = m_lh_knife_zone;
        }
    }
    if (slot_dormant(s)
        || (s.name == "shoulder" && RE4VRShared::get()->vr_throw_windup_until.value_or(0) > re4vr::now())
        || (s.name == "knife" && RE4VRShared::get()->re4_knife_left_clone)) {
        s.grab_in_zone = false;
        s.last_dist = 99;
        re4vr::lua_set_bool(s.zone_g, false);
        return;
    }
    auto anchor = re4vr::lua_vec3(s.anchor_g);
    auto rh = anchor ? (RE4VRShared::get()->vr_rh_ctrl_raw ? RE4VRShared::get()->vr_rh_ctrl_raw : rh_world()) : std::nullopt;
    if (!jb(s.cfg, "enabled", true) || !anchor || !rh) {
        s.grab_in_zone = false;
        s.last_dist = 99;
        re4vr::lua_set_bool(s.zone_g, false);
        return;
    }
    s.last_dist = glm::length(*rh - *anchor);
    if (!s.grab_in_zone) {
        if (s.last_dist <= jn(s.cfg, "grab_trigger", 0.16f)) {
            s.grab_in_zone = true;
        }
    } else if (s.last_dist > jn(s.cfg, "grab_release", 0.24f)) {
        s.grab_in_zone = false;
    }
    re4vr::lua_set_bool(s.zone_g, s.grab_in_zone);
}

bool RE4VRHolster::hmd_basis(Vector3f& pos, Vector3f& right, Vector3f& up, Vector3f& fwd) {
    auto* cam = sdk::get_primary_camera();
    if (!cam) {
        return false;
    }
    auto wm = re4vr::safe([&] { return sdk::call_object_func_easy<Matrix4x4f>(cam, "get_WorldMatrix"); });
    if (!wm) {
        return false;
    }
    pos = Vector3f{(*wm)[3].x, (*wm)[3].y, (*wm)[3].z};
    float fx = (*wm)[2].x, fz = (*wm)[2].z;
    if (auto* tf = body_tf()) {
        auto rot = re4vr::safe([&] { return sdk::get_transform_rotation(tf); });
        if (rot) {
            auto fv = re4vr::quat_rotate(*rot, Vector3f{0, 0, 1});
            fx = fv.x;
            fz = fv.z;
        }
    }
    const float len = std::sqrt(fx * fx + fz * fz);
    if (len < 1e-6f) {
        fx = 0;
        fz = 1;
    } else {
        fx /= len;
        fz /= len;
    }
    right = Vector3f{fz, 0, -fx};
    up = Vector3f{0, 1, 0};
    fwd = Vector3f{fx, 0, fz};
    return true;
}

std::optional<Vector3f> RE4VRHolster::rh_world() {
    if (auto p = RE4VRShared::get()->vr_rh_world) {
        return p;
    }
    auto* tf = body_tf();
    auto* j = tf ? (re4vr::joint_by_name(tf, "R_Hand") ? re4vr::joint_by_name(tf, "R_Hand") : re4vr::joint_by_name(tf, "R_Arm_Hand")) : nullptr;
    if (!j) {
        return std::nullopt;
    }
    return re4vr::v3(sdk::get_joint_position(j));
}

std::optional<Vector3f> RE4VRHolster::lh_world() {
    if (auto p = RE4VRShared::get()->vr_lh_joint_pos) {
        return p;
    }
    if (auto p = RE4VRShared::get()->vr_lh_world) {
        return p;
    }
    auto* tf = body_tf();
    auto* j = tf ? (re4vr::joint_by_name(tf, "L_Hand") ? re4vr::joint_by_name(tf, "L_Hand") : re4vr::joint_by_name(tf, "L_Arm_Hand")) : nullptr;
    if (!j) {
        return std::nullopt;
    }
    return re4vr::v3(sdk::get_joint_position(j));
}

bool RE4VRHolster::right_grip() {
    return re4vr::grip_held(false);
}
bool RE4VRHolster::left_grip() {
    return re4vr::grip_held(true);
}

void RE4VRHolster::haptic_right(float dur, float freq, float amp) {
    auto& vr = VR::get();
    vr->trigger_haptic_vibration(0.0f, dur, freq, amp, vr->get_right_joystick());
}
void RE4VRHolster::haptic_left(float dur, float freq, float amp) {
    auto& vr = VR::get();
    vr->trigger_haptic_vibration(0.0f, dur, freq, amp, vr->get_left_joystick());
}

void RE4VRHolster::play_go_sound(::REManagedObject* go, uint32_t id) {
    if (!go || !id || !m_snd_t) {
        return;
    }
    auto* scn = re4vr::get_component(go, "soundlib.SoundContainer");
    if (scn) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(scn, "trigger(System.UInt32)", id); });
    }
}

void RE4VRHolster::play_grab_sound() {
    play_go_sound((::REManagedObject*)find_weapon_go(m_knife.ids, std::nullopt), HOLSTER_GRAB_SND);
}

std::tuple<std::optional<bool>, bool, bool, bool> RE4VRHolster::weapon_in_hand() {
    auto* c = ctx();
    if (!c) {
        return {std::nullopt, false, false, false};
    }
    auto* hu = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(c, "get_HeadUpdater"); }).value_or(nullptr);
    if (!hu) {
        return {std::nullopt, false, false, false};
    }
    auto gun = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(hu, "get_IsEquipGun"); });
    auto knife = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(hu, "get_IsEquipKnife"); });
    auto gren = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(hu, "get_IsEquipGrenade"); });
    auto melee = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(hu, "get_IsEquipMelee"); });
    if (!gun && !knife && !gren && !melee) {
        auto wid = equip_wid();
        if (!wid) {
            return {std::nullopt, false, false, false};
        }
        if (*wid < 0) {
            return {false, false, false, false};
        }
        return {true, false, false, true};
    }
    const bool g = gun.value_or(false), k = knife.value_or(false), gr = gren.value_or(false);
    return {g || k || gr, k, gr, false};
}

bool RE4VRHolster::knife_only_stage() {
    const double now = re4vr::now();
    if (now - m_knife_only_t < 0.5) {
        return m_knife_only_v;
    }
    m_knife_only_t = now;
    m_knife_only_v = false;
    auto stage = re4vr::call_killswitch_string("get_stage_name");
    if (!stage) {
        return false;
    }
    int st = 0;
    try {
        st = std::stoi(*stage);
    } catch (...) {
        return false;
    }
    if (st != KNIFE_ONLY_STAGE) {
        return false;
    }
    auto* cm = re4vr::character_manager();
    auto* list = cm ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(cm, "get_EnemyContextList"); }).value_or(nullptr) : nullptr;
    const int count = list ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(list, "get_Count"); }).value_or(0) : 0;
    for (int i = 0; i < count; ++i) {
        auto* ectx = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(list, "get_Item", i); }).value_or(nullptr);
        if (!ectx) {
            continue;
        }
        auto kind = re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(ectx, "get_KindID"); });
        if (kind && *kind == KRAUSER_KIND) {
            m_knife_only_v = true;
            break;
        }
    }
    return m_knife_only_v;
}

bool RE4VRHolster::no_weapons_yet() {
    const double now = re4vr::now();
    if (now - m_nowep_t < 0.3) {
        return m_nowep_v;
    }
    m_nowep_t = now;
    auto stage = re4vr::call_killswitch_string("get_stage_name");
    int st = -1;
    if (stage) {
        try {
            st = std::stoi(*stage);
        } catch (...) {
            st = -1;
        }
    }
    bool hit = false;
    for (int s : NO_WEP_STAGES) {
        if (s == st) {
            hit = true;
        }
    }
    if (!hit) {
        m_nowep_v = false;
        return false;
    }
    auto* c = ctx();
    if (!c) {
        m_nowep_v = true;
        return true;
    }
    m_nowep_v = re4vr::safe([&] { return sdk::call_object_func_easy<bool>(c, "get_IsRestrictionWeaponShortcut"); }).value_or(false);
    return m_nowep_v;
}

void RE4VRHolster::draw_last_pistol(::REManagedObject* pe) {
    auto* inv = pe ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(pe, "get_InventoryController"); }).value_or(nullptr) : nullptr;
    auto* et = equip_type_main();
    if (inv) {
        auto* row = (m_last_pistol.wid != 0) ? find_row(inv, m_last_pistol.wid, m_last_pistol.guid) : nullptr;
        if (!row) {
            for (auto* r : inventory_rows(inv)) {
                auto* w = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(r, "get_WeaponId"); }).value_or(nullptr);
                if (w && m_pistol.ids.contains(enum_num(w))) {
                    row = r;
                    m_last_pistol.wid = enum_num(w);
                    break;
                }
            }
        }
        auto* gid = row ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(row, "get_ID"); }).value_or(nullptr) : nullptr;
        if (gid) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(inv, "equip", gid); });
        }
        auto equipped_ok = [&] {
            if (!et) {
                return true;
            }
            auto eq = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(inv, "getEquippedWeapon", et); });
            return !eq || *eq != nullptr;
        };
        if (!equipped_ok()) {
            auto* row2 = (m_last_pistol.wid != 0) ? find_row(inv, m_last_pistol.wid, m_last_pistol.guid) : nullptr;
            auto* gid2 = row2 ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(row2, "get_ID"); }).value_or(nullptr) : nullptr;
            if (gid2) {
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(inv, "equip", gid2); });
            }
        }
        if (!equipped_ok()) {
            return;
        }
    }
    bool ok = false;
    if (et) {
        ok = re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "requestChangeActiveWeapon(chainsaw.EquipType, System.Boolean, System.Boolean)", et, false, false); });
    }
    if (!ok) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "requestEquipGun"); });
    }
}

void RE4VRHolster::draw_last_grenade(::REManagedObject* pe) {
    auto* inv = pe ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(pe, "get_InventoryController"); }).value_or(nullptr) : nullptr;
    auto* et = equip_type_main();
    if (inv) {
        auto* row = find_row(inv, m_last_grenade.wid, m_last_grenade.guid);
        auto* gid = row ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(row, "get_ID"); }).value_or(nullptr) : nullptr;
        if (gid) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(inv, "equip", gid); });
        }
    }
    bool ok = false;
    if (et) {
        ok = re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "requestChangeActiveWeapon(chainsaw.EquipType, System.Boolean, System.Boolean)", et, false, false); });
    }
    if (!ok) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "requestEquipGrenade"); });
    }
}

void RE4VRHolster::draw_last_rifle(::REManagedObject* pe) {
    auto* inv = pe ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(pe, "get_InventoryController"); }).value_or(nullptr) : nullptr;
    auto* et = equip_type_main();
    if (inv) {
        auto* row = (m_last_rifle.wid != 0) ? find_row(inv, m_last_rifle.wid, m_last_rifle.guid) : nullptr;
        if (!row) {
            for (auto* r : inventory_rows(inv)) {
                auto* w = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(r, "get_WeaponId"); }).value_or(nullptr);
                if (w && m_shoulder.ids.contains(enum_num(w))) {
                    row = r;
                    m_last_rifle.wid = enum_num(w);
                    break;
                }
            }
        }
        auto* gid = row ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(row, "get_ID"); }).value_or(nullptr) : nullptr;
        if (gid) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(inv, "equip", gid); });
        }
    }
    bool ok = false;
    if (et) {
        ok = re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "requestChangeActiveWeapon(chainsaw.EquipType, System.Boolean, System.Boolean)", et, false, false); });
    }
    if (!ok) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "requestEquipGun"); });
    }
}

void RE4VRHolster::do_grab(Slot* best) {
    if (!best) {
        return;
    }
    if (best->name == "knife"
        && (RE4VRShared::get()->re4_knife_hand.value_or("") == "left" || RE4VRShared::get()->re4_knife_left_clone)) {
        return;
    }
    auto ew = equip_wid();
    auto [really, knife_now, gren_now, amb] = weapon_in_hand();
    const bool in_hand = really.value_or(false) && ew && best->ids.contains(*ew);
    const double now = re4vr::now();
    if (in_hand) {
        RE4VRShared::get()->vr_post_stow_until = now + 0.6;
    }
    RE4VRShared::get()->re4_aim_relatch = true;
    defer([this, best, in_hand]() {
        auto* pe = get_pe();
        if (!pe) {
            return;
        }
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "clearRequest"); });
        const double t = re4vr::now();
        if (best->name == "knife") {
            RE4VRShared::get()->re4_stow_guard_until = t + 0.5;
            RE4VRShared::get()->re4_stow_ours_until = t + 0.2;
            if (in_hand) {
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "requestEquipBareHand", false, false); });
                m_ar.suppress = true;
                m_ar.stow_until = t + 0.5;
            } else {
                RE4VRShared::get()->re4_knife_draw_ours_t = t;
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "requestEquipKnife"); });
                m_ar.suppress = false;
                RE4VRShared::get()->re4_knife_left_intent = false;
                RE4VRShared::get()->re4_knife_left_clone = false;
            }
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "execChangeWeapon"); });
            RE4VRShared::get()->re4_stow_ours_until = 0;
            return;
        }
        if (in_hand) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "requestEquipBareHand", false, false); });
            m_ar.suppress = true;
            m_ar.stow_until = t + 0.5;
        } else {
            if (best->name == "shoulder") {
                auto* inv = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(pe, "get_InventoryController"); }).value_or(nullptr);
                bool has_long = inv == nullptr;
                if (inv) {
                    for (auto* r : inventory_rows(inv)) {
                        auto* w = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(r, "get_WeaponId"); }).value_or(nullptr);
                        if (w && m_shoulder.ids.contains(enum_num(w))) {
                            has_long = true;
                            break;
                        }
                    }
                }
                if (!has_long) {
                    return;
                }
                draw_last_rifle(pe);
            } else if (best->name == "grenade") {
                draw_last_grenade(pe);
            } else {
                draw_last_pistol(pe);
            }
            m_ar.suppress = false;
            RE4VRShared::get()->re4_clone_no_autogun = false;
        }
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "execChangeWeapon"); });
    });
    const uint32_t snd = best->name == "grenade" ? GRENADE_GRAB_SND : HOLSTER_GRAB_SND;
    play_go_sound((::REManagedObject*)find_weapon_go(best->ids, std::nullopt), snd);
    if (jb(best->cfg, "grab_haptic", true)) {
        const float delay = jn(best->cfg, "grab_haptic_delay");
        if (delay > 0) {
            m_grab_haptic_at = now + delay;
        } else {
            haptic_right(0.06f, 200.0f, 0.9f);
        }
    }
}

RE4VRHolster::Slot* RE4VRHolster::nearest_with_clone() {
    Slot* best = nullptr;
    float bestd = 1e9f;
    for (auto* s : {&m_knife, &m_pistol, &m_grenade, &m_shoulder}) {
        const bool cloneless_knife = s->name == "knife" && RE4VRShared::get()->re4_knife_clonless_grab && s->has_inv;
        const bool grabbable = s->clone_obj || s->detached_zone || cloneless_knife;
        if (!slot_dormant(*s) && jb(s->cfg, "enabled", true) && grabbable && s->last_dist < bestd) {
            best = s;
            bestd = s->last_dist;
        }
    }
    return best;
}

void RE4VRHolster::grab_dispatch() {
    if (RE4VRShared::get()->re4_holster_killswitch) {
        m_grip_prev = right_grip();
        m_press_armed = false;
        m_tap_mode = false;
        RE4VRShared::get()->vr_holster_grab_armed = false;
        return;
    }
    const double now = re4vr::now();
    if (m_grab_haptic_at > 0 && now >= m_grab_haptic_at) {
        m_grab_haptic_at = 0;
        haptic_right(0.06f, 200.0f, 0.9f);
    }
    const bool grip = right_grip();
    if (grip && !m_grip_prev) {
        m_grip_t0 = now;
        auto* s = nearest_with_clone();
        const bool in_zone = s && s->last_dist <= jn(s->cfg, "grab_trigger", 0.16f);
        auto [wih, k, g, a] = weapon_in_hand();
        if (in_zone && wih == true) {
            m_tap_mode = true;
            m_press_armed = false;
        } else {
            m_tap_mode = false;
            m_press_armed = in_zone;
        }
    }
    if (m_grip_prev && !grip) {
        const float held = (float)(now - m_grip_t0);
        Slot* s = nullptr;
        bool fire = false;
        if (m_tap_mode) {
            s = (held <= m_aim_hold) ? nearest_with_clone() : nullptr;
            fire = s && s->last_dist <= jn(s->cfg, "grab_release", 0.24f);
        } else {
            s = m_press_armed ? nearest_with_clone() : nullptr;
            fire = s && s->last_dist <= jn(s->cfg, "grab_release", 0.24f);
        }
        if (fire) {
            do_grab(s);
        }
        m_press_armed = false;
        m_tap_mode = false;
    }
    m_grip_prev = grip;
    if (m_tap_mode && RE4VRShared::get()->re4_scope_wid) {
        RE4VRShared::get()->vr_holster_grab_armed = grip && (now - m_grip_t0) < m_aim_hold;
    } else {
        RE4VRShared::get()->vr_holster_grab_armed = m_press_armed;
    }
}

void RE4VRHolster::start_calibration(Slot* slot, bool left) {
    m_cal_slot = slot;
    m_cal_mag = false;
    m_cal_left = left;
    m_cal_deadline = re4vr::now() + 5.0;
    m_cal_last_beep = -1;
    haptic_right(0.10f, 200.0f, 0.9f);
}

void RE4VRHolster::start_mag_calibration() {
    m_cal_slot = nullptr;
    m_cal_mag = true;
    m_cal_left = true;
    m_cal_deadline = re4vr::now() + 5.0;
    m_cal_last_beep = -1;
    haptic_right(0.10f, 200.0f, 0.9f);
}

bool RE4VRHolster::calibrate_slot(Slot& s, const Vector3f& P) {
    if (s.detached_zone) {
        Vector3f hmd, right, up, fwd;
        if (!hmd_basis(hmd, right, up, fwd)) {
            return false;
        }
        const float dx = P.x - hmd.x, dy = P.y - hmd.y, dz = P.z - hmd.z;
        s.cfg["zx"] = dx * right.x + dy * right.y + dz * right.z;
        s.cfg["zy"] = dx * up.x + dy * up.y + dz * up.z;
        s.cfg["zz"] = dx * fwd.x + dy * fwd.y + dz * fwd.z;
        save_slot(s);
        return true;
    }
    if (s.parented && s.clone_obj) {
        auto* tf = s.clone_tf;
        if (!tf) {
            tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(s.clone_obj, "get_Transform"); }).value_or(nullptr);
            s.clone_tf = tf;
        }
        if (!tf) {
            return false;
        }
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(tf, "set_LocalRotation", hol_quat(jn(s.cfg, "rx"), jn(s.cfg, "ry"), jn(s.cfg, "rz"))); });
        sdk::set_transform_position(tf, re4vr::v4(P));
        auto lp = re4vr::safe([&] { return sdk::call_object_func_easy<Vector3f>(tf, "get_LocalPosition"); });
        if (!lp) {
            return false;
        }
        const float d = (float)RE4VRShared::get()->re4_ub_z_delta.value_or(0);
        const float g = (float)RE4VRShared::get()->re4_holster_crouch_gain.value_or(0);
        const float az = (RE4VRShared::get()->re4_knife_char.value_or("") == "ada")
            ? (float)RE4VRShared::get()->re4_holster_ada_mesh_z.value_or(0) : 0.0f;
        const float cz = -d * g + az;
        s.cfg["off_x"] = lp->x;
        s.cfg["off_y"] = lp->y;
        s.cfg["off_z"] = lp->z - cz;
        s.cfg["pl_x"] = 0;
        s.cfg["pl_y"] = 0;
        s.cfg["pl_z"] = 0;
        s.sm_has = false;
        save_slot(s);
        return true;
    }
    auto* j = slot_joint(s);
    if (!j) {
        return false;
    }
    const auto jp = re4vr::v3(sdk::get_joint_position(j));
    const auto jr = sdk::get_joint_rotation(j);
    const auto q = glm::normalize(jr * hol_quat(jn(s.cfg, "rx"), jn(s.cfg, "ry"), jn(s.cfg, "rz")));
    const auto qpl = re4vr::quat_rotate(q, Vector3f{jn(s.cfg, "pl_x"), jn(s.cfg, "pl_y"), jn(s.cfg, "pl_z")});
    const Vector3f tgt{P.x - jp.x - qpl.x, P.y - jp.y - qpl.y, P.z - jp.z - qpl.z};
    const auto off = re4vr::quat_rotate(glm::inverse(jr), tgt);
    s.cfg["off_x"] = off.x;
    s.cfg["off_y"] = off.y;
    s.cfg["off_z"] = off.z;
    s.sm_has = false;
    save_slot(s);
    return true;
}

bool RE4VRHolster::calibrate_mag(const Vector3f& P) {
    if (!m_mag_joint) {
        auto* tf = body_tf();
        if (tf) {
            for (auto* nm : CHEST_JOINTS) {
                if (auto* j = re4vr::joint_by_name(tf, nm)) {
                    m_mag_joint = j;
                    break;
                }
            }
        }
    }
    if (!m_mag_joint) {
        return false;
    }
    const auto jp = re4vr::v3(sdk::get_joint_position(m_mag_joint));
    const auto jr = sdk::get_joint_rotation(m_mag_joint);
    const auto off = re4vr::quat_rotate(glm::inverse(jr), Vector3f{P.x - jp.x, P.y - jp.y, P.z - jp.z});
    m_mag_cfg["off_x"] = off.x;
    m_mag_cfg["off_y"] = off.y;
    m_mag_cfg["off_z"] = off.z;
    re4vr::save_json_file("re4_vr/re4_vr_mag_holster.json", m_mag_cfg);
    return true;
}

void RE4VRHolster::calibration_tick() {
    if (!m_cal_slot && !m_cal_mag) {
        return;
    }
    const double remaining = m_cal_deadline - re4vr::now();
    if (remaining <= 0) {
        std::optional<Vector3f> P;
        if (m_cal_left) {
            P = RE4VRShared::get()->vr_lh_ctrl_raw;
            if (!P) {
                P = lh_world();
            }
        } else {
            P = RE4VRShared::get()->vr_rh_ctrl_raw;
            if (!P) {
                P = rh_world();
            }
        }
        if (P) {
            if (m_cal_mag) {
                calibrate_mag(*P);
            } else if (m_cal_slot) {
                calibrate_slot(*m_cal_slot, *P);
            }
        }
        haptic_right(0.30f, 200.0f, 1.0f);
        m_cal_slot = nullptr;
        m_cal_mag = false;
        m_cal_last_beep = -1;
        m_cal_deadline = 0;
    } else {
        const int int_s = (int)std::ceil(remaining);
        if (int_s != m_cal_last_beep) {
            m_cal_last_beep = int_s;
            haptic_right(0.09f, 200.0f, 0.9f);
        }
    }
}

void RE4VRHolster::register_ui() {
    if (m_ui_registered) {
        return;
    }
    m_ui_registered = true;
    RE4VRMenu::get()->add(70, "holster_cal", [this]() {
        ImGui::TextUnformatted("Holster calibration (5s)");
        if (ImGui::Button("Calibrate knife")) {
            start_calibration(&m_knife, false);
        }
        if (ImGui::Button("Calibrate pistol")) {
            start_calibration(&m_pistol, false);
        }
        if (ImGui::Button("Calibrate grenade")) {
            start_calibration(&m_grenade, false);
        }
        if (ImGui::Button("Calibrate shoulder")) {
            start_calibration(&m_shoulder, false);
        }
        if (ImGui::Button("Calibrate mag (left)")) {
            start_mag_calibration();
        }
    });
}

void RE4VRHolster::mag_tick() {
    if (RE4VRShared::get()->re4_holster_killswitch || RE4VRShared::get()->re4_holster_knife_only || !jb(m_mag_cfg, "enabled", true)) {
        if (m_mag_holding) {
            m_mag_holding = false;
            RE4VRShared::get()->set_mag_in_hand(false);
        }
        RE4VRShared::get()->vr_in_mag_holster_zone = false;
        return;
    }
    auto* tf = body_tf();
    if (tf && (!m_mag_joint || !re4vr::safe([&] { return sdk::call_object_func_easy<bool>(m_mag_joint, "get_Valid"); }).value_or(false))) {
        m_mag_joint = nullptr;
        for (auto* nm : CHEST_JOINTS) {
            if (auto* j = re4vr::joint_by_name(tf, nm)) {
                m_mag_joint = j;
                break;
            }
        }
    }
    std::optional<Vector3f> anchor;
    if (m_mag_joint) {
        const auto jp = re4vr::v3(sdk::get_joint_position(m_mag_joint));
        const auto jr = sdk::get_joint_rotation(m_mag_joint);
        anchor = jp + re4vr::quat_rotate(jr, Vector3f{jn(m_mag_cfg, "off_x"), jn(m_mag_cfg, "off_y"), jn(m_mag_cfg, "off_z")});
    }
    auto lh = RE4VRShared::get()->vr_lh_ctrl_raw;
    if (!lh) {
        lh = lh_world();
    }
    if (!anchor || !lh) {
        RE4VRShared::get()->vr_in_mag_holster_zone = m_mag_holding;
        return;
    }
    m_mag_dist = glm::length(*lh - *anchor);
    if (!m_mag_in_zone) {
        if (m_mag_dist <= jn(m_mag_cfg, "grab_trigger", 0.16f)) {
            m_mag_in_zone = true;
        }
    } else if (m_mag_dist > jn(m_mag_cfg, "grab_release", 0.24f)) {
        m_mag_in_zone = false;
    }
    const bool lgrip = left_grip();
    if (!m_mag_holding) {
        if (m_mag_in_zone && lgrip) {
            if (RE4VRShared::get()->re4_reload_grab_empty) {
                haptic_left(0.16f, 80.0f, 1.0f);
            } else {
                m_mag_holding = true;
                RE4VRShared::get()->set_mag_in_hand(true);
                haptic_left(0.16f, 80.0f, 1.0f);
            }
        }
    } else if (!lgrip) {
        m_mag_holding = false;
        RE4VRShared::get()->set_mag_in_hand(false);
    }
    RE4VRShared::get()->vr_in_mag_holster_zone = m_mag_in_zone || m_mag_holding;
}

void RE4VRHolster::track_last_weapons() {
    auto ew = equip_wid();
    if (!ew) {
        return;
    }
    auto* pe = get_pe();
    auto* inv = pe ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(pe, "get_InventoryController"); }).value_or(nullptr) : nullptr;
    auto* et = equip_type_main();
    auto guid = [&]() -> std::string {
        if (!inv || !et) {
            return {};
        }
        auto* id = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(inv, "getEquippedID", et); }).value_or(nullptr);
        return guid_to_string(id);
    };
    if (m_pistol.ids.contains(*ew)) {
        m_last_pistol.wid = *ew;
        auto g = guid();
        if (!g.empty()) {
            m_last_pistol.guid = g;
        }
    }
    if (m_knife.ids.contains(*ew)) {
        m_last_knife.wid = *ew;
    }
    if (m_grenade.ids.contains(*ew)) {
        m_last_grenade.wid = *ew;
        auto g = guid();
        if (!g.empty()) {
            m_last_grenade.guid = g;
        }
    }
    if (m_shoulder.ids.contains(*ew)) {
        m_last_rifle.wid = *ew;
        auto g = guid();
        if (!g.empty()) {
            m_last_rifle.guid = g;
        }
    }
}

void RE4VRHolster::knife_char_tick() {
    auto* c = ctx();
    auto* b = c ? re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(c, "get_BodyGameObject"); }).value_or(nullptr) : nullptr;
    if (!b) {
        return;
    }
    const auto n = re4vr::go_name((::REManagedObject*)b);
    std::string want;
    if (n == "ch3a8z0_body") {
        want = "ada";
    } else if (n == "ch0a0z0_body" || n == "ch0a1z0_body") {
        want = "leon";
    } else {
        return;
    }
    if (want == m_char) {
        return;
    }
    m_char = want;
    RE4VRShared::get()->re4_knife_char = std::string{want};
    const auto path = (want == "ada") ? m_knife.path_ada : std::string("re4_vr/re4_vr_knife.json");
    if (want == "ada") {
        auto existing = re4vr::load_json_file(path);
        if (existing.empty()) {
            m_knife.path = path;
            save_slot(m_knife);
        }
    }
    m_knife.path = path;
    load_slot(m_knife, path);
}

void RE4VRHolster::auto_redraw_tick() {
    auto [in_hand_now, knife_now, gren_now, amb] = weapon_in_hand();
    if (in_hand_now) {
        RE4VRShared::get()->vr_bare_hands = !*in_hand_now;
        RE4VRShared::get()->vr_knife_in_hand = knife_now;
        RE4VRShared::get()->vr_grenade_in_hand = gren_now;
    }
    auto* c = ctx();
    if (c) {
        static std::optional<int32_t> dmg_mask;
        if (!dmg_mask) {
            int32_t m = 0;
            re4vr::pcall([&] {
                auto* td = sdk::find_type_definition("chainsaw.PlayerDefine.State");
                auto* f = td ? td->get_field("Damage") : nullptr;
                auto* ev = f ? (::REManagedObject*)f->get_data<void*>(nullptr) : nullptr;
                if (ev) {
                    m = utility::re_managed_object::get_field<int32_t>(ev, "value__");
                }
            });
            dmg_mask = m;
            RE4VRShared::get()->re4_state_damage_mask = m;
        }
        if (dmg_mask && *dmg_mask) {
            auto* sv = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(c, "get_State"); }).value_or(nullptr);
            auto svn = sv ? re4vr::safe([&] { return utility::re_managed_object::get_field<int32_t>(sv, "value__"); }) : std::nullopt;
            if (svn && (*svn & *dmg_mask) == *dmg_mask) {
                RE4VRShared::get()->vr_stagger_recent_until = re4vr::now() + 0.6;
            }
        }
    }
    bool pg = re4vr::call_killswitch_bool("is_pure_gameplay", false);
    if (!pg && RE4VRShared::get()->re4_hookshot_recent_until.value_or(0) > re4vr::now()
        && !RE4VRShared::get()->re4_holster_killswitch) {
        pg = true;
    }
    const double now = re4vr::now();
    if (pg) {
        if (m_ar.pure_since == 0) {
            m_ar.pure_since = now;
        }
    } else {
        m_ar.pure_since = 0;
        m_ar.left_pure_t = now;
    }
    if (RE4VRShared::get()->re4_in_mercs) {
        const bool body_da = re4vr::body_game_object() != nullptr;
        if (!body_da) {
            m_merc_body_weg = true;
        } else if (m_merc_body_weg) {
            m_merc_body_weg = false;
            m_ar.has_snap = false;
            m_ar.snap_bare = false;
            m_ar.suppress = false;
        }
    }
    if (pg && in_hand_now && !amb) {
        if (*in_hand_now) {
            if (m_ar.suppress && now >= m_ar.stow_until) {
                m_ar.suppress = false;
            }
            auto w = equip_wid();
            if (w && *w >= 0) {
                m_ar.snap = *w;
                m_ar.snap_bare = false;
                m_ar.has_snap = true;
            }
        } else if (m_ar.suppress) {
            m_ar.snap_bare = true;
            m_ar.has_snap = true;
        }
    }
    RE4VRShared::get()->re4_ar_suppress = m_ar.suppress;
    RE4VRShared::get()->re4_ar_pg = pg;
    float stable_need = 0.4f;
    if ((now - RE4VRShared::get()->re4_finisher_prompt_seen.value_or(-999)) < 5.0) {
        stable_need = 0.05f;
    }
    if (in_hand_now == false && !m_ar.suppress && m_ar.has_snap && !m_ar.snap_bare && m_ar.snap
        && pg && (now - m_ar.pure_since) >= stable_need && now >= m_ar.next_try
        && ((now - m_ar.left_pure_t) < 2.0 || RE4VRShared::get()->vr_stagger_recent_until.value_or(0) > now)
        && !no_weapons_yet()) {
        m_ar.next_try = now + 0.20;
        auto* pe = get_pe();
        if (pe) {
            RE4VRShared::get()->re4_our_equip_until = now + 0.5;
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "clearRequest"); });
            const int32_t snap = *m_ar.snap;
            if (m_knife.ids.contains(snap)) {
                RE4VRShared::get()->re4_knife_draw_ours_t = now;
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "requestEquipKnife"); });
            } else if (m_grenade.ids.contains(snap)) {
                draw_last_grenade(pe);
            } else if (m_shoulder.ids.contains(snap)) {
                draw_last_rifle(pe);
            } else if (m_pistol.ids.contains(snap)) {
                draw_last_pistol(pe);
            } else {
                re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "requestEquipGun"); });
            }
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "execChangeWeapon"); });
        }
    }
}

void RE4VRHolster::apply_all() {
    apply_slot(m_knife);
    apply_slot(m_pistol);
    apply_slot(m_grenade);
    apply_slot(m_shoulder);
}

void RE4VRHolster::defer(std::function<void()> fn) {
    m_pending = std::move(fn);
}
void RE4VRHolster::set_suppress(bool v) {
    m_ar.suppress = v;
    if (v) {
        m_ar.stow_until = re4vr::now() + 0.5;
    }
}
void RE4VRHolster::holster_exec() {
    run_pending();
}
void RE4VRHolster::holster_bare() {
    m_ar.suppress = true;
    m_ar.stow_until = re4vr::now() + 0.5;
    RE4VRShared::get()->re4_our_equip_until = re4vr::now() + 0.5;
    defer([this]() {
        auto* pe = get_pe();
        if (!pe) {
            return;
        }
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "clearRequest"); });
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "requestEquipBareHand", false, false); });
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "execChangeWeapon"); });
    });
}
void RE4VRHolster::force_change_to_main() {
    auto* pe = get_pe();
    if (!pe) {
        return;
    }
    auto cur = equip_wid();
    if (cur && *cur == 4005) {
        return;
    }
    auto* et = equip_type_main();
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "clearRequest"); });
    auto* wtd = sdk::find_type_definition("chainsaw.WeaponID");
    auto* f = wtd ? wtd->get_field("wp4005") : nullptr;
    auto* wid = f ? (::REManagedObject*)f->get_data<void*>(nullptr) : nullptr;
    if (wid && et) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "equipWeapon", et, wid, false, false); });
    }
    if (et) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "requestChangeActiveWeapon(chainsaw.EquipType, System.Boolean, System.Boolean)", et, false, false); });
    }
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "execChangeWeapon"); });
}

void RE4VRHolster::run_pending() {
    if (!m_pending) {
        return;
    }
    auto pa = std::move(m_pending);
    m_pending = {};
    RE4VRShared::get()->re4_our_equip_until = re4vr::now() + 0.5;
    re4vr::pcall([&] { pa(); });
}

bool RE4VRHolster::knife_gate_skip() {
    if (!RE4VRShared::get()->re4_knife_gate) {
        return false;
    }
    if ((re4vr::now() - RE4VRShared::get()->re4_knife_draw_ours_t.value_or(-999)) < 1.0) {
        return false;
    }
    if (RE4VRShared::get()->re4_holster_killswitch || RE4VRShared::get()->re4_ks4_active
        || RE4VRShared::get()->re4_holster_knife_only || RE4VRShared::get()->re4_knife_equipped
        || RE4VRShared::get()->re4_knife_left_clone || RE4VRShared::get()->re4_knife_left_intent
        || RE4VRShared::get()->re4_knife_flying || RE4VRShared::get()->re4_clone_finisher_restore) {
        return false;
    }
    return true;
}
bool RE4VRHolster::melee_gate_skip() {
    if (!RE4VRShared::get()->re4_melee_gate) {
        return false;
    }
    if (RE4VRCrosshair::get()->is_finisher_prompt()) {
        return false;
    }
    if ((re4vr::now() - RE4VRShared::get()->re4_knife_draw_ours_t.value_or(-999)) < 1.0) {
        return false;
    }
    if (RE4VRShared::get()->re4_holster_killswitch || RE4VRShared::get()->re4_ks4_active
        || RE4VRShared::get()->re4_ks_active || RE4VRShared::get()->re4_holster_knife_only
        || RE4VRShared::get()->re4_knife_equipped || RE4VRShared::get()->re4_knife_left_clone
        || RE4VRShared::get()->re4_knife_left_intent || RE4VRShared::get()->re4_knife_flying
        || RE4VRShared::get()->re4_clone_finisher_restore) {
        return false;
    }
    return true;
}

HookManager::PreHookResult RE4VRHolster::pre_nop(std::vector<uintptr_t>&, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    return HookManager::PreHookResult::CALL_ORIGINAL;
}
void RE4VRHolster::post_update_head(uintptr_t&, sdk::RETypeDefinition*, uintptr_t) {
    get()->run_pending();
}
void RE4VRHolster::post_nop(uintptr_t&, sdk::RETypeDefinition*, uintptr_t) {}
HookManager::PreHookResult RE4VRHolster::pre_request_equip_knife(std::vector<uintptr_t>&, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    return get()->knife_gate_skip() ? HookManager::PreHookResult::SKIP_ORIGINAL : HookManager::PreHookResult::CALL_ORIGINAL;
}
HookManager::PreHookResult RE4VRHolster::pre_melee_gate(std::vector<uintptr_t>&, std::vector<sdk::RETypeDefinition*>&, uintptr_t) {
    return get()->melee_gate_skip() ? HookManager::PreHookResult::SKIP_ORIGINAL : HookManager::PreHookResult::CALL_ORIGINAL;
}

void RE4VRHolster::export_globals(sol::state& lua) {
    lua["__re4_knife_defer"] = [this](sol::object fn) {
        if (fn.is<sol::protected_function>()) {
            auto f = fn.as<sol::protected_function>();
            defer([f]() mutable {
                re4vr::LuaGuard g;
                auto r = f();
                (void)r;
            });
        }
    };
    lua["__re4_knife_set_suppress"] = [this](sol::object b) { set_suppress(b.get_type() == sol::type::boolean && b.as<bool>()); };
    lua["__re4_knife_holster_exec"] = [this]() { holster_exec(); };
    lua["__re4_knife_holster_bare"] = [this]() { holster_bare(); };
    lua["__re4_force_change_to_main"] = [this]() { force_change_to_main(); return true; };
    lua["__re4_knife_play_grab_sound"] = [this]() { play_grab_sound(); };
}

void RE4VRHolster::on_lua_state_created(sol::state& lua) {
    export_globals(lua);
}

void RE4VRHolster::on_lua_state_destroyed(sol::state&) {
    destroy_slot(m_knife);
    destroy_slot(m_pistol);
    destroy_slot(m_grenade);
    destroy_slot(m_shoulder);
    m_pending = {};
    m_pe = nullptr;
}

void RE4VRHolster::on_frame() {
    ScriptProfileGuard guard("re4_vr_holster.lua", "on_frame", re4vr::profile_frame());
    m_hol_frame++;
    const bool ks = re4vr::call_killswitch_bool("is_active", RE4VRShared::get()->re4_ks_active)
        || RE4VRShared::get()->re4_throwsight_active || no_weapons_yet();
    RE4VRShared::get()->re4_holster_killswitch = ks;
    RE4VRShared::get()->re4_holster_knife_only = knife_only_stage();
    knife_char_tick();
    calibration_tick();
    track_last_weapons();
    auto_redraw_tick();
    tick_slot(m_knife);
    tick_slot(m_pistol);
    tick_slot(m_grenade);
    tick_slot(m_shoulder);
    mag_tick();
    grab_dispatch();
    auto [in_hand_now, k, g, a] = weapon_in_hand();
    if (no_weapons_yet() && in_hand_now == true) {
        auto* pe = get_pe();
        if (pe) {
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "clearRequest"); });
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "requestEquipBareHand", false, false); });
            re4vr::pcall([&] { sdk::call_object_func_easy<void*>(pe, "execChangeWeapon"); });
        }
    }
}

void RE4VRHolster::on_pre_application_entry(void*, const char* name, size_t hash) {
    if (hash == "LockScene"_fnv || hash == "BeginRendering"_fnv) {
        ScriptProfileGuard guard("re4_vr_holster.lua", std::string("on_pre_application_entry:") + (name ? name : ""), re4vr::profile_frame());
        apply_all();
    }
}

void RE4VRHolster::on_application_entry(void*, const char* name, size_t hash) {
    if (hash == "UpdateMotion"_fnv || hash == "UpdateJointExpression"_fnv
        || hash == "LateUpdateBehavior"_fnv || hash == "BeginRendering"_fnv) {
        ScriptProfileGuard guard("re4_vr_holster.lua", std::string("on_application_entry:") + (name ? name : ""), re4vr::profile_frame());
        apply_all();
    }
}
#endif
