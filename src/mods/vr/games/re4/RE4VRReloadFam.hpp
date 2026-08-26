#pragma once

#if defined(RE4)
#include "RE4VRReloadCommon.hpp"

namespace re4vr::rl {

inline void clone_destroy(::REGameObject*& obj, ::REManagedObject*& mesh) {
    if (obj) {
        re4vr::destroy_game_object((::REManagedObject*)obj);
    }
    obj = nullptr;
    mesh = nullptr;
}
inline bool clone_spawn(::REGameObject*& obj, ::REManagedObject*& mesh, ::REGameObject* src, const char* name) {
    if (obj) {
        return true;
    }
    auto* gmesh = src ? mesh_of(src) : nullptr;
    auto* holder = gmesh ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(gmesh, "getMesh"); }).value_or(nullptr) : nullptr;
    auto* go = re4vr::create_game_object(name);
    if (!go || !holder) {
        return false;
    }
    re4vr::pcall([&] { utility::re_managed_object::add_ref(go); });
    auto* m = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(go, "createComponent(System.Type)", re4vr::runtime_type("via.render.Mesh")); }).value_or(nullptr);
    if (!m) {
        return false;
    }
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m, "setMesh", holder); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(m, "set_Enabled", true); });
    obj = go;
    mesh = m;
    return true;
}
inline void clone_place_hand(::REGameObject* obj, float x, float y, float z, float rx, float ry, float rz, float scl) {
    if (!obj) {
        return;
    }
    auto* tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(obj, "get_Transform"); }).value_or(nullptr);
    auto* lh = left_hand();
    if (!tf || !lh) {
        return;
    }
    auto hp = jpos(lh);
    auto hr = jrot(lh);
    if (!hp || !hr) {
        return;
    }
    const auto off = glm::rotate(*hr, Vector3f{x, y, z});
    sdk::set_transform_position(tf, re4vr::v4(*hp + off));
    sdk::set_transform_rotation(tf, glm::normalize(*hr * quat_from_euler(rx, ry, rz)));
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(tf, "set_LocalScale", Vector3f{scl, scl, scl}); });
}

struct CylCfg {
    float rx{0}, ry{0}, rz{0}, px{0}, py{0}, pz{0}, lerp{0.08f}, shot_deg{-45.f}, shot_lerp{0.20f};
};
struct RevJoints {
    std::string cylinder, spin, insert, hammer, hand_cart;
    std::vector<std::string> bullets;
};
struct ShellOff {
    std::string pose;
    float x{0}, y{0}, z{0}, rx{0}, ry{0}, rz{0}, scale{1};
};

struct RevolverFamily {
    std::string json_path;
    std::string lua_file{"re4_vr_reload2.lua"};
    bool enabled{true};
    bool reload_ammo{true};
    bool sound_enabled{true};
    float insert_distance{0.15f};
    float support_cooldown{0.45f};
    float cock_dur{0.48f};
    int32_t hammer_wid{0};
    std::unordered_map<int32_t, bool> wids;
    std::unordered_map<int32_t, RevJoints> joints;
    std::unordered_map<int32_t, CylCfg> cyl;
    std::unordered_map<int32_t, ShellOff> shell;
    uint32_t snd_cyl{942865223}, snd_cock{938556079}, snd_insert{942865223}, snd_drop{1351699582};
    uint32_t snd_holster{1839787494}, snd_dry{812850326};

    struct Wep {
        std::optional<int32_t> wid;
        ::RETransform* tf{};
        ::REJoint *cyl{}, *spin{}, *insert{}, *hammer{}, *hand_cart{};
        std::optional<glm::quat> cyl_rest, spin_rest, hammer_rest;
        std::optional<Vector3f> cyl_rest_pos;
        std::vector<std::pair<::REJoint*, Vector3f>> bullets;
    } wep;
    struct {
        bool open{false};
        float prog{0};
        bool prev_b{false};
    } cyl_st;
    struct {
        float target{0}, current{0};
        std::optional<int> prev_seq;
    } spin_st;
    struct {
        float ham_frac{0}, hand_frac{0}, phase{0};
        bool cocked{false}, running{false}, prev_stick{false}, snd{false};
        double t0{0};
        std::optional<int> prev_seq;
        glm::quat hand_off{1, 0, 0, 0};
        float hx{0}, hy{0}, hz{0};
    } ham;
    bool cart{false};
    bool mih_owned{false};
    bool dry_prev{false};
    double insert_t{-1};
    ::REGameObject* clone_obj{};
    ::REManagedObject* clone_mesh{};

    void seed_leon();
    void seed_handcannon();
    void load();
    bool owns() const;
    void refresh();
    void on_frame();
    void apply();
    void apply_late();
    bool set_mag_in_hand(bool active);
    void reset();

private:
    void play(uint32_t id);
    bool insert_one();
    void update_cyl();
    void update_spin();
    void update_hammer();
    void update_reload();
};

inline void RevolverFamily::seed_leon() {
    json_path = "re4_vr/re4_vr_reload2.json";
    lua_file = "re4_vr_reload2.lua";
    hammer_wid = 4500;
    wids = {{5001, true}, {4500, true}};
    joints[5001] = {"_06", "", "", "", "", {}};
    joints[4500] = {"_04", "_05", "_06", "_02", "_101", {"_07", "_08", "_09", "_10", "_11", "_12"}};
    cyl[5001] = {0, -45, 0};
    cyl[4500] = {52, 0, 0};
    shell[4500] = {"RevolverShell", 0.022f, -0.078f, 0.067f, 34, 114, 0, 1};
}
inline void RevolverFamily::seed_handcannon() {
    json_path = "re4_vr/re4_vr_reload3_handcannon.json";
    lua_file = "re4_vr_reload3.lua";
    hammer_wid = 0;
    wids = {{4502, true}};
    joints[4502] = {"_04", "_05", "_04", "_02", "_101", {"_07", "_08", "_09", "_10", "_11"}};
    cyl[4502] = {0, 0, -62};
    shell[4502] = {"RevolverShell", 0.022f, -0.078f, 0.067f, 34, 114, 0, 1};
}
inline void RevolverFamily::load() {
    auto d = re4vr::load_json_file(json_path);
    if (d.empty()) {
        return;
    }
    const auto& c = d.contains("cfg") ? d["cfg"] : d;
    if (c.contains("revolver_enabled") && c["revolver_enabled"].is_boolean()) {
        enabled = c["revolver_enabled"].get<bool>();
    }
    if (c.contains("reload_ammo") && c["reload_ammo"].is_boolean()) {
        reload_ammo = c["reload_ammo"].get<bool>();
    }
    if (c.contains("sound_enabled") && c["sound_enabled"].is_boolean()) {
        sound_enabled = c["sound_enabled"].get<bool>();
    }
    if (c.contains("insert_distance") && c["insert_distance"].is_number()) {
        insert_distance = c["insert_distance"].get<float>();
    }
    if (c.contains("support_cooldown") && c["support_cooldown"].is_number()) {
        support_cooldown = c["support_cooldown"].get<float>();
    }
    if (c.contains("cock_dur") && c["cock_dur"].is_number()) {
        cock_dur = c["cock_dur"].get<float>();
    }
    if (d.contains("cyl") && d["cyl"].is_object()) {
        for (auto it = d["cyl"].begin(); it != d["cyl"].end(); ++it) {
            try {
                auto& r = cyl[std::stoi(it.key())];
                r.rx = re4vr::j_num(it.value(), "rx", r.rx);
                r.ry = re4vr::j_num(it.value(), "ry", r.ry);
                r.rz = re4vr::j_num(it.value(), "rz", r.rz);
                r.px = re4vr::j_num(it.value(), "px", r.px);
                r.py = re4vr::j_num(it.value(), "py", r.py);
                r.pz = re4vr::j_num(it.value(), "pz", r.pz);
                r.lerp = re4vr::j_num(it.value(), "lerp", r.lerp);
                r.shot_deg = re4vr::j_num(it.value(), "shot_deg", r.shot_deg);
                r.shot_lerp = re4vr::j_num(it.value(), "shot_lerp", r.shot_lerp);
            } catch (...) {
            }
        }
    }
    if (d.contains("shell") && d["shell"].is_object()) {
        for (auto it = d["shell"].begin(); it != d["shell"].end(); ++it) {
            try {
                auto& s = shell[std::stoi(it.key())];
                if (it.value().contains("pose") && it.value()["pose"].is_string()) {
                    s.pose = it.value()["pose"].get<std::string>();
                }
                s.x = re4vr::j_num(it.value(), "x", s.x);
                s.y = re4vr::j_num(it.value(), "y", s.y);
                s.z = re4vr::j_num(it.value(), "z", s.z);
                s.rx = re4vr::j_num(it.value(), "rx", s.rx);
                s.ry = re4vr::j_num(it.value(), "ry", s.ry);
                s.rz = re4vr::j_num(it.value(), "rz", s.rz);
                s.scale = re4vr::j_num(it.value(), "scale", s.scale);
            } catch (...) {
            }
        }
    }
}
inline bool RevolverFamily::owns() const {
    auto w = equip_wid();
    return enabled && w && wids.contains(*w) && wids.at(*w);
}
inline void RevolverFamily::play(uint32_t id) {
    if (sound_enabled) {
        play_wep_sound(wep.tf, id);
    }
}
inline void RevolverFamily::refresh() {
    if (!owns()) {
        if (wep.wid) {
            clone_destroy(clone_obj, clone_mesh);
        }
        wep = {};
        return;
    }
    auto w = *equip_wid();
    if (wep.wid == w && wep.tf && re4vr::safe([&] { return sdk::get_transform_position(wep.tf); })) {
        return;
    }
    wep = {};
    auto [go, tf] = find_weapon(w);
    if (!tf) {
        return;
    }
    wep.wid = w;
    wep.tf = tf;
    auto& jc = joints[w];
    wep.cyl = jc.cylinder.empty() ? nullptr : re4vr::joint_by_name(tf, jc.cylinder);
    if (wep.cyl) {
        wep.cyl_rest = jlr(wep.cyl);
        wep.cyl_rest_pos = jlp(wep.cyl);
    }
    wep.spin = jc.spin.empty() ? nullptr : re4vr::joint_by_name(tf, jc.spin);
    if (wep.spin) {
        wep.spin_rest = jlr(wep.spin);
    }
    wep.insert = jc.insert.empty() ? nullptr : re4vr::joint_by_name(tf, jc.insert);
    wep.hammer = jc.hammer.empty() ? nullptr : re4vr::joint_by_name(tf, jc.hammer);
    if (wep.hammer) {
        wep.hammer_rest = re4vr::safe([&] { return sdk::call_object_func_easy<glm::quat>(wep.hammer, "get_BaseLocalRotation"); });
    }
    wep.hand_cart = jc.hand_cart.empty() ? nullptr : re4vr::joint_by_name(tf, jc.hand_cart);
    for (auto& n : jc.bullets) {
        if (auto* j = re4vr::joint_by_name(tf, n)) {
            auto scv = re4vr::safe([&] { return sdk::call_object_func_easy<Vector3f>(j, "get_LocalScale"); }).value_or(Vector3f{1, 1, 1});
            if (scv.x < 0.01f) {
                scv = Vector3f{1, 1, 1};
            }
            wep.bullets.push_back({j, scv});
        }
    }
}
inline bool RevolverFamily::insert_one() {
    if (!reload_ammo) {
        return false;
    }
    auto* wi = live_wi();
    const int loaded = ammo_count(wi).value_or(gun_ammo().value_or(0));
    const int cap = wi ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(wi, "get_CurrentAmmoMax"); }).value_or(0) : 0;
    if (cap > 0 && loaded >= cap) {
        return false;
    }
    if (reserve_of(wi) <= 0 && !unlimited()) {
        return false;
    }
    return load_and_book(1);
}
inline void RevolverFamily::update_cyl() {
    if (!wep.cyl) {
        return;
    }
    auto& r = cyl[wep.wid.value_or(0)];
    const bool b = right_b();
    if (b && !cyl_st.prev_b) {
        cyl_st.open = !cyl_st.open;
        play(cyl_st.open ? snd_cyl : snd_cock);
    }
    cyl_st.prev_b = b;
    const float tgt = cyl_st.open ? 1.f : 0.f;
    if (cyl_st.prog < tgt) {
        cyl_st.prog = std::min(tgt, cyl_st.prog + r.lerp);
    } else if (cyl_st.prog > tgt) {
        cyl_st.prog = std::max(tgt, cyl_st.prog - r.lerp);
    }
    RE4VRShared::get()->vr_revolver_cyl_open = cyl_st.prog > 0.15f;
}
inline void RevolverFamily::update_spin() {
    if (!wep.wid) {
        return;
    }
    const int seq = (int)RE4VRShared::get()->vr_shot_seq.value_or(0);
    if (!spin_st.prev_seq) {
        spin_st.prev_seq = seq;
    } else if (seq > *spin_st.prev_seq) {
        auto& r = cyl[*wep.wid];
        spin_st.target += r.shot_deg;
        spin_st.prev_seq = seq;
    }
    auto& r = cyl[wep.wid.value_or(0)];
    const float diff = spin_st.target - spin_st.current;
    if (std::abs(diff) <= 0.5f) {
        spin_st.current = spin_st.target;
    } else {
        spin_st.current += diff * r.shot_lerp;
    }
}
inline void RevolverFamily::update_hammer() {
    if (!wep.wid || *wep.wid != hammer_wid) {
        ham = {};
        return;
    }
    const float ry = (float)RE4VRShared::get()->vr_right_stick_y.value_or(0);
    const bool stick = ry <= -0.70f;
    const int seq = (int)RE4VRShared::get()->vr_shot_seq.value_or(0);
    if (!ham.prev_seq) {
        ham.prev_seq = seq;
    } else if (seq > *ham.prev_seq) {
        ham.cocked = false;
        ham.running = false;
        ham.prev_seq = seq;
    }
    if (stick && !ham.prev_stick && !ham.cocked && !ham.running) {
        ham.running = true;
        ham.t0 = re4vr::now();
        ham.snd = false;
        ham.phase = 0;
    }
    ham.prev_stick = stick;
    if (ham.running) {
        const float dur = std::max(cock_dur, 0.05f);
        ham.phase = std::min(1.f, (float)(re4vr::now() - ham.t0) / dur);
        float u = std::min(ham.phase / 0.5f, 1.f);
        u = u * u * (3 - 2 * u);
        ham.ham_frac = u;
        constexpr float RAMP = 0.12f;
        float hf = 1.f;
        if (ham.phase <= RAMP) {
            float t = ham.phase / RAMP;
            hf = t * t * (3 - 2 * t);
        } else if (ham.phase >= 1.f - RAMP) {
            float t = (1.f - ham.phase) / RAMP;
            hf = t * t * (3 - 2 * t);
        }
        ham.hand_frac = hf;
        if (!ham.snd && ham.phase >= 0.45f) {
            ham.snd = true;
            play(snd_cock);
            ham.cocked = true;
        }
        if (ham.phase >= 1.f) {
            ham.running = false;
        }
    } else {
        ham.hand_frac = 0;
        ham.ham_frac = ham.cocked ? 1.f : 0.f;
    }
    RE4VRShared::get()->vr_rev_cock_frac = ham.hand_frac;
}
inline void RevolverFamily::update_reload() {
    if (!cart || !wep.insert || !reload_ammo) {
        return;
    }
    if (!RE4VRShared::get()->vr_revolver_cyl_open) {
        return;
    }
    auto hp = lh_world();
    auto ip = jpos(wep.insert);
    if (!hp || !ip) {
        return;
    }
    const float d = glm::distance(*hp, *ip);
    if (d <= insert_distance) {
        auto* ms = mag_slide();
        if (ms && wep.wid && ms->has_shell_keys(*wep.wid)) {
            insert_one();
        } else if (insert_one()) {
            cart = false;
            insert_t = re4vr::now();
            play(snd_insert);
            clone_destroy(clone_obj, clone_mesh);
        }
    }
}
inline void RevolverFamily::on_frame() {
    if (re4vr::is_ks_active()) {
        return;
    }
    refresh();
    if (!wep.wid) {
        cyl_st.prev_b = false;
        RE4VRShared::get()->vr_rev_cock_frac = 0;
        if (mih_owned) {
            RE4VRShared::get()->vr_mag_in_hand = false;
            mih_owned = false;
        }
        return;
    }
    RE4VRShared::get()->vr_manual_reload_consume_b = true;
    const int loaded = ammo_count(live_wi()).value_or(gun_ammo().value_or(0));
    const int cap = live_wi() ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(live_wi(), "get_CurrentAmmoMax"); }).value_or(6) : 6;
    RE4VRShared::get()->re4_reload_grab_empty = loaded >= cap || (reserve_of(live_wi()) <= 0 && !unlimited());
    update_cyl();
    update_spin();
    update_hammer();
    update_reload();
    RE4VRShared::get()->re4_reload_ui_wid = *wep.wid;
    if (*wep.wid == hammer_wid) {
        const bool cd = insert_t > 0 && (re4vr::now() - insert_t) < support_cooldown;
        RE4VRShared::get()->vr_mag_in_hand = cart || cd;
        mih_owned = true;
    } else if (mih_owned) {
        RE4VRShared::get()->vr_mag_in_hand = false;
        mih_owned = false;
    }
    const bool cyl_open = RE4VRShared::get()->vr_revolver_cyl_open;
    const bool single = hammer_wid && *wep.wid == hammer_wid;
    auto* p = pe();
    const bool empty = single && p && re4vr::safe([&] { return sdk::call_object_func_easy<bool>(p, "isGunAmmoEmpty"); }).value_or(false);
    if (single) {
        RE4VRShared::get()->vr_block_fire_when_empty = cyl_open || (!ham.cocked && !unlimited()) || (empty && !unlimited());
    } else {
        RE4VRShared::get()->vr_block_fire_when_empty = cyl_open;
    }
    const bool et = RE4VRShared::get()->re4_empty_trigger_held;
    if (et && !dry_prev) {
        play(snd_dry);
        if (single && ham.cocked && !cyl_open) {
            spin_st.target += cyl[*wep.wid].shot_deg;
            ham.cocked = false;
        }
    }
    dry_prev = et;
}
inline void RevolverFamily::apply() {
    if (!enabled || !wep.cyl || !wep.cyl_rest) {
        return;
    }
    auto& r = cyl[wep.wid.value_or(0)];
    const float p = cyl_st.prog;
    const bool has_pos = r.px != 0 || r.py != 0 || r.pz != 0;
    if (p > 0.0001f) {
        set_jlr(wep.cyl, glm::normalize(*wep.cyl_rest * quat_from_euler(r.rx * p, r.ry * p, r.rz * p)));
        if (has_pos && wep.cyl_rest_pos) {
            set_jlp(wep.cyl, Vector3f{wep.cyl_rest_pos->x + r.px * p, wep.cyl_rest_pos->y + r.py * p, wep.cyl_rest_pos->z + r.pz * p});
        }
    } else if (has_pos && wep.cyl_rest_pos) {
        set_jlp(wep.cyl, *wep.cyl_rest_pos);
    }
    if (wep.spin && wep.spin_rest) {
        auto rot = *wep.spin_rest;
        if (spin_st.current != 0) {
            rot = glm::normalize(*wep.spin_rest * quat_from_euler(0, 0, spin_st.current));
        }
        set_jlr(wep.spin, rot);
    }
    if (wep.wid == hammer_wid && wep.hammer && wep.hammer_rest) {
        const float f = ham.ham_frac;
        set_jlr(wep.hammer, glm::normalize(*wep.hammer_rest * quat_from_euler(14.5f + (-7.5f - 14.5f) * f, 0, 0)));
    }
    const int ammo = ammo_count(live_wi()).value_or(gun_ammo().value_or(0));
    for (int i = 0; i < (int)wep.bullets.size(); ++i) {
        auto [j, vis] = wep.bullets[i];
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(j, "set_LocalScale", i < ammo ? vis : Vector3f{0, 0, 0}); });
    }
    if (cart && wep.wid && shell.contains(*wep.wid)) {
        auto& s = shell[*wep.wid];
        auto* go = go_of(wep.tf);
        if (clone_spawn(clone_obj, clone_mesh, go, "vr_rev_shell")) {
            clone_place_hand(clone_obj, s.x, s.y, s.z, s.rx, s.ry, s.rz, s.scale);
        }
        if (!s.pose.empty()) {
            RE4VRShared::get()->apply_reload_pose(s.pose, 1.0f);
        }
    } else if (clone_obj) {
        clone_destroy(clone_obj, clone_mesh);
    }
}
inline void RevolverFamily::apply_late() {
    if (cart && wep.wid && shell.contains(*wep.wid) && clone_obj) {
        auto& s = shell[*wep.wid];
        clone_place_hand(clone_obj, s.x, s.y, s.z, s.rx, s.ry, s.rz, s.scale);
    }
}
inline bool RevolverFamily::set_mag_in_hand(bool active) {
    if (!owns()) {
        return false;
    }
    if (active) {
        if (cart) {
            return false;
        }
        const int loaded = ammo_count(live_wi()).value_or(0);
        const int cap = live_wi() ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(live_wi(), "get_CurrentAmmoMax"); }).value_or(6) : 6;
        if (loaded >= cap || (reserve_of(live_wi()) <= 0 && !unlimited())) {
            return false;
        }
        cart = true;
        play(snd_holster);
        return true;
    }
    if (cart) {
        cart = false;
        play(snd_drop);
        clone_destroy(clone_obj, clone_mesh);
    }
    return true;
}
inline void RevolverFamily::reset() {
    cart = false;
    cyl_st = {};
    spin_st = {};
    ham = {};
    clone_destroy(clone_obj, clone_mesh);
    wep = {};
}

struct BoltFamily {
    std::string json_path;
    std::string lua_file;
    std::string cycle_node;
    std::string cycle_flag{"__re4_bolt_in_cycle"};
    int32_t wid{4400};
    bool enabled{true};
    bool reload_ammo{true};
    float insert_distance{0.15f};
    float back_off{-0.060f};
    float travel{0.12f};
    float grab_dist{0.16f};
    float brz{-70.f};
    std::string bolt_j{"_01"}, cart_j{"_10"};
    struct Wep {
        std::optional<int32_t> id;
        ::RETransform* tf{};
        ::REJoint *bolt{}, *cart{};
        std::optional<glm::quat> rest_rot;
        std::optional<Vector3f> rest_lp, cart_rest;
    } wep;
    struct {
        bool open{false}, grab{false};
        float roll{0}, zf{0};
        bool needs{false};
        std::optional<int> prev_loaded;
        float gx{0}, gy{0}, gz{0};
        std::optional<float> rgx, rgy, rgz;
    } bolt;
    struct {
        bool active{false}, insert{false};
        double t0{0};
        std::optional<Vector3f> slp;
        std::optional<glm::quat> slr;
    } cart;
    bool mih{false};

    void seed_leon();
    void seed_ada();
    void load();
    bool owns() const;
    void refresh();
    void on_frame();
    void apply();
    bool set_mag_in_hand(bool active);
    void reset();
    void suppress_cycle();
};
inline void BoltFamily::seed_leon() {
    json_path = "re4_vr/re4_vr_reload2_bolt.json";
    lua_file = "re4_vr_reload2.lua";
    cycle_node = "wp4400_general_0513_Aim_Fire_after";
    cycle_flag = "__re4_bolt_in_cycle";
    wid = 4400;
}
inline void BoltFamily::seed_ada() {
    json_path = "re4_vr/re4_vr_reload5_dlc_bolt.json";
    lua_file = "re4_vr_reload5_dlc.lua";
    cycle_node = "wp6114_general_0513_Aim_Fire_after";
    cycle_flag = "__re4_bolt_in_cycle_dlc";
    wid = 6114;
}
inline void BoltFamily::load() {
    auto d = re4vr::load_json_file(json_path);
    if (d.empty()) {
        return;
    }
    const auto& c = d.contains("cfg") ? d["cfg"] : d;
    if (c.contains("enabled") && c["enabled"].is_boolean()) {
        enabled = c["enabled"].get<bool>();
    }
    if (c.contains("reload_ammo") && c["reload_ammo"].is_boolean()) {
        reload_ammo = c["reload_ammo"].get<bool>();
    }
    if (c.contains("insert_distance") && c["insert_distance"].is_number()) {
        insert_distance = c["insert_distance"].get<float>();
    }
    if (d.contains("tune") && d["tune"].is_object()) {
        back_off = re4vr::j_num(d["tune"], "back_off", back_off);
        travel = re4vr::j_num(d["tune"], "travel", travel);
        grab_dist = re4vr::j_num(d["tune"], "grab_dist", grab_dist);
        brz = re4vr::j_num(d["tune"], "brz", brz);
    }
}
inline bool BoltFamily::owns() const {
    auto w = equip_wid();
    return enabled && w && *w == wid;
}
inline void BoltFamily::refresh() {
    if (!owns()) {
        wep = {};
        return;
    }
    if (wep.id == wid && wep.bolt && wep.tf && re4vr::safe([&] { return sdk::get_transform_position(wep.tf); })) {
        return;
    }
    wep = {};
    auto [go, tf] = find_weapon(wid);
    if (!tf) {
        return;
    }
    wep.id = wid;
    wep.tf = tf;
    wep.bolt = re4vr::joint_by_name(tf, bolt_j);
    wep.cart = re4vr::joint_by_name(tf, cart_j);
    if (wep.bolt) {
        wep.rest_rot = jlr(wep.bolt);
        wep.rest_lp = jlp(wep.bolt);
    }
    if (wep.cart) {
        wep.cart_rest = jlp(wep.cart);
    }
}
inline void BoltFamily::suppress_cycle() {
    re4vr::lua_set_bool(cycle_flag, false);
    if (!wep.id) {
        return;
    }
    auto* go = go_of(wep.tf);
    if (!go) {
        return;
    }
    auto* mc = re4vr::get_component((::REManagedObject*)go, "via.motion.Motion");
    auto* layer = mc ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(mc, "getLayer", 0); }).value_or(nullptr) : nullptr;
    auto* node = layer ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(layer, "get_HighestWeightMotionNode"); }).value_or(nullptr) : nullptr;
    auto* nm = node ? re4vr::safe([&] { return sdk::call_object_func_easy<::SystemString*>(node, "get_MotionName"); }).value_or(nullptr) : nullptr;
    if (!nm || utility::re_string::get_string(nm) != cycle_node) {
        return;
    }
    re4vr::lua_set_bool(cycle_flag, true);
    auto ef = re4vr::safe([&] { return sdk::call_object_func_easy<float>(node, "get_EndFrame"); });
    if (ef && *ef > 0) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(node, "set_Frame", *ef); });
    }
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(layer, "set_Speed", 100.0f); });
}
inline void BoltFamily::on_frame() {
    if (re4vr::is_ks_active()) {
        return;
    }
    refresh();
    suppress_cycle();
    if (!wep.id) {
        if (mih) {
            RE4VRShared::get()->vr_mag_in_hand = false;
            mih = false;
        }
        return;
    }
    RE4VRShared::get()->vr_manual_reload_consume_b = true;
    const int loaded = gun_ammo().value_or(ammo_count(live_wi()).value_or(0));
    if (bolt.prev_loaded && loaded < *bolt.prev_loaded) {
        bolt.needs = true;
    }
    bolt.prev_loaded = loaded;
    auto* bj = wep.bolt;
    auto hp = lh_world();
    auto bp = bj ? jpos(bj) : std::nullopt;
    const bool grip = left_grip();
    if (bj && hp && bp) {
        const float d = glm::distance(*hp, *bp);
        if (grip && d <= grab_dist) {
            if (!bolt.grab) {
                bolt.gx = hp->x;
                bolt.gy = hp->y;
                bolt.gz = hp->z;
                auto rhr = RE4VRShared::get()->vr_rh_ctrl_raw;
                if (!rhr) {
                    rhr = RE4VRShared::get()->vr_rh_world;
                }
                if (rhr) {
                    bolt.rgx = rhr->x;
                    bolt.rgy = rhr->y;
                    bolt.rgz = rhr->z;
                } else {
                    bolt.rgx.reset();
                    bolt.rgy.reset();
                    bolt.rgz.reset();
                }
            }
            bolt.grab = true;
            float px = hp->x - bolt.gx, py = hp->y - bolt.gy, pz = hp->z - bolt.gz;
            auto rhn = RE4VRShared::get()->vr_rh_ctrl_raw;
            if (!rhn) {
                rhn = RE4VRShared::get()->vr_rh_world;
            }
            if (bolt.rgx && rhn) {
                px -= rhn->x - *bolt.rgx;
                py -= rhn->y - *bolt.rgy;
                pz -= rhn->z - *bolt.rgz;
            }
            float zf = std::clamp(std::max(0.f, -pz) / std::max(travel, 0.01f), 0.f, 1.f);
            if (!bolt.open) {
                bolt.roll = std::min(1.f, bolt.roll + 0.15f);
                if (bolt.roll >= 0.99f) {
                    bolt.zf = zf;
                    if (zf >= 0.9f) {
                        bolt.open = true;
                        bolt.needs = false;
                    }
                }
            } else {
                bolt.zf = zf;
                if (zf <= 0.1f) {
                    bolt.roll = std::max(0.f, bolt.roll - 0.15f);
                    if (bolt.roll <= 0.01f) {
                        bolt.open = false;
                    }
                }
            }
        } else {
            bolt.grab = false;
        }
    }
    if (cart.active && hp && wep.tf) {
        auto* dj = re4vr::joint_by_name(wep.tf, "_01");
        auto jp = dj ? jpos(dj) : std::nullopt;
        if (jp && glm::distance(*hp, *jp) <= insert_distance && !cart.insert) {
            cart.slp = wep.cart ? jlp(wep.cart) : std::nullopt;
            cart.slr = wep.cart ? jlr(wep.cart) : std::nullopt;
            cart.t0 = re4vr::now();
            cart.insert = true;
            cart.active = false;
        }
    }
    if (cart.insert) {
        const float t = std::min(1.f, (float)(re4vr::now() - cart.t0) / 0.18f);
        if (t >= 1.f) {
            cart.insert = false;
            if (reload_ammo) {
                load_and_book(1);
            }
        }
    }
    RE4VRShared::get()->vr_block_fire_when_empty = bolt.open || bolt.needs;
    RE4VRShared::get()->vr_mag_in_hand = cart.active || cart.insert;
    mih = cart.active || cart.insert;
    const int cap = live_wi() ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(live_wi(), "get_CurrentAmmoMax"); }).value_or(0) : 0;
    RE4VRShared::get()->re4_reload_grab_empty = !bolt.open || loaded >= cap || (reserve_of(live_wi()) <= 0 && !unlimited());
    RE4VRShared::get()->re4_reload_ui_wid = wid;
}
inline void BoltFamily::apply() {
    if (!enabled || !wep.bolt || !wep.rest_lp || !wep.rest_rot) {
        return;
    }
    set_jlp(wep.bolt, Vector3f{wep.rest_lp->x, wep.rest_lp->y, wep.rest_lp->z + back_off * bolt.zf});
    set_jlr(wep.bolt, glm::normalize(*wep.rest_rot * quat_from_euler(0, 0, brz * bolt.roll)));
    if ((cart.active || cart.insert) && wep.cart) {
        if (cart.insert && cart.slp && wep.cart_rest) {
            const float t = ease(std::min(1.f, (float)(re4vr::now() - cart.t0) / 0.18f));
            set_jlp(wep.cart, Vector3f{
                cart.slp->x + (wep.cart_rest->x - cart.slp->x) * t,
                cart.slp->y + (wep.cart_rest->y - cart.slp->y) * t,
                cart.slp->z + (wep.cart_rest->z - cart.slp->z) * t});
        } else {
            auto hp = lh_world();
            auto hr = jrot(left_hand());
            if (hp && hr) {
                set_jpos(wep.cart, *hp);
                if (hr) {
                    set_jrot(wep.cart, *hr);
                }
            }
        }
    }
}
inline bool BoltFamily::set_mag_in_hand(bool active) {
    if (!owns()) {
        return false;
    }
    if (active) {
        if (!bolt.open) {
            return false;
        }
        const int loaded = gun_ammo().value_or(0);
        const int cap = live_wi() ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(live_wi(), "get_CurrentAmmoMax"); }).value_or(0) : 0;
        if (cap > 0 && loaded >= cap) {
            return false;
        }
        if (reserve_of(live_wi()) <= 0 && !unlimited()) {
            return false;
        }
        cart.active = true;
        play_wep_sound(wep.tf, 1839787494);
        return true;
    }
    cart.active = false;
    return true;
}
inline void BoltFamily::reset() {
    bolt = {};
    cart = {};
    wep = {};
}

struct XbowFamily {
    int32_t wid{4600};
    std::string json_path{"re4_vr/re4_vr_reload2_xbow.json"};
    bool enabled{true};
    bool reload_ammo{true};
    float insert_distance{0.15f};
    struct {
        std::optional<int32_t> id;
        ::RETransform* tf{};
    } wep;
    struct {
        bool active{false}, insert{false};
        double t0{0};
    } arrow;
    bool dummy_await{false};
    void load();
    bool owns() const;
    void refresh();
    void on_frame();
    void apply();
    void apply_late();
    bool set_mag_in_hand(bool active);
    void reset();
};
inline void XbowFamily::load() {
    auto d = re4vr::load_json_file(json_path);
    if (d.empty()) {
        return;
    }
    const auto& c = d.contains("cfg") ? d["cfg"] : d;
    if (c.contains("enabled") && c["enabled"].is_boolean()) {
        enabled = c["enabled"].get<bool>();
    }
    if (c.contains("reload_ammo") && c["reload_ammo"].is_boolean()) {
        reload_ammo = c["reload_ammo"].get<bool>();
    }
    if (c.contains("insert_distance") && c["insert_distance"].is_number()) {
        insert_distance = c["insert_distance"].get<float>();
    }
}
inline bool XbowFamily::owns() const {
    auto w = equip_wid();
    return enabled && w && *w == wid;
}
inline void XbowFamily::refresh() {
    if (!owns()) {
        wep = {};
        return;
    }
    auto [go, tf] = find_weapon(wid);
    wep.id = wid;
    wep.tf = tf;
}
inline void XbowFamily::on_frame() {
    if (re4vr::is_ks_active()) {
        return;
    }
    refresh();
    if (!wep.id) {
        RE4VRShared::get()->re4_xbow_dummy_await = false;
        return;
    }
    RE4VRShared::get()->vr_manual_reload_consume_b = true;
    auto hp = lh_world();
    auto gp = wep.tf ? re4vr::safe([&] { return sdk::get_transform_position(wep.tf); }) : std::nullopt;
    if (arrow.active && hp && gp && glm::distance(*hp, *gp) <= insert_distance) {
        arrow.active = false;
        arrow.insert = true;
        arrow.t0 = re4vr::now();
    }
    if (arrow.insert && (re4vr::now() - arrow.t0) >= 0.18) {
        arrow.insert = false;
        if (reload_ammo) {
            load_and_book(1);
        }
    }
    const bool show = arrow.active || arrow.insert;
    RE4VRShared::get()->vr_mag_in_hand = show;
    RE4VRShared::get()->re4_xbow_dummy_await = show;
    const int loaded = ammo_count(live_wi()).value_or(0);
    const int cap = live_wi() ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(live_wi(), "get_CurrentAmmoMax"); }).value_or(0) : 0;
    RE4VRShared::get()->re4_reload_grab_empty = loaded >= cap || (reserve_of(live_wi()) <= 0 && !unlimited());
    RE4VRShared::get()->re4_reload_ui_wid = wid;
}
inline void XbowFamily::apply() {
    if (!owns()) {
        return;
    }
    re4vr::LuaGuard g;
    if (auto* L = g.lua()) {
        sol::object o = (*L)["__re4_xbow_dummy_obj"];
        if (o.is<::REManagedObject*>() && (arrow.active || arrow.insert)) {
            auto* dummy = o.as<::REManagedObject*>();
            auto* tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(dummy, "get_Transform"); }).value_or(nullptr);
            auto* lh = left_hand();
            auto hp = lh ? jpos(lh) : std::nullopt;
            auto hr = lh ? jrot(lh) : std::nullopt;
            if (tf && hp) {
                sdk::set_transform_position(tf, re4vr::v4(*hp));
                if (hr) {
                    sdk::set_transform_rotation(tf, *hr);
                }
            }
        }
    }
}
inline void XbowFamily::apply_late() {
    apply();
}
inline bool XbowFamily::set_mag_in_hand(bool active) {
    if (!owns()) {
        return false;
    }
    if (active) {
        const int loaded = ammo_count(live_wi()).value_or(0);
        const int cap = live_wi() ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(live_wi(), "get_CurrentAmmoMax"); }).value_or(0) : 0;
        if (loaded >= cap || (reserve_of(live_wi()) <= 0 && !unlimited())) {
            return false;
        }
        arrow.active = true;
        return true;
    }
    arrow.active = false;
    return true;
}
inline void XbowFamily::reset() {
    arrow = {};
    wep = {};
}

struct Red9Family {
    int32_t wid{4002};
    std::string json_path;
    std::string lua_file;
    bool enabled{true};
    bool reload_ammo{true};
    float insert_dist{0.12f};
    float insert_dur{0.40f};
    float rack_z{-0.030f};
    float rest_z{0.0267f};
    float rack_grab{0.14f};
    std::string slide_joint{"_01"};
    std::string ip_joint{"_03"};
    float ip_z{0.054f};
    struct {
        std::optional<int32_t> id;
        ::RETransform* tf{};
        ::REJoint* slide{};
    } wep;
    struct {
        bool active{false}, insert{false};
        double t0{0};
    } clip;
    struct {
        bool grabbed{false}, open{false};
        float apply_z{0};
        bool need_regrip{false};
        std::optional<double> heal_done_t;
    } rack;
    ::REGameObject* clone_obj{};
    ::REManagedObject* clone_mesh{};
    void seed_leon();
    void seed_ada();
    void load();
    bool owns() const;
    void refresh();
    void on_frame();
    void apply();
    void apply_late();
    bool set_mag_in_hand(bool active);
    void reset();
};
inline void Red9Family::seed_leon() {
    wid = 4002;
    json_path = "re4_vr/re4_vr_reload2_red9.json";
    lua_file = "re4_vr_reload2.lua";
}
inline void Red9Family::seed_ada() {
    wid = 6113;
    json_path = "re4_vr/re4_vr_reload5_dlc_samuraiedge.json";
    lua_file = "re4_vr_reload5_dlc.lua";
}
inline void Red9Family::load() {
    auto d = re4vr::load_json_file(json_path);
    if (d.empty()) {
        return;
    }
    if (d.contains("enabled") && d["enabled"].is_boolean()) {
        enabled = d["enabled"].get<bool>();
    }
    if (d.contains("reload_ammo") && d["reload_ammo"].is_boolean()) {
        reload_ammo = d["reload_ammo"].get<bool>();
    }
    insert_dist = re4vr::j_num(d, "insert_dist", insert_dist);
    insert_dur = re4vr::j_num(d, "insert_dur", insert_dur);
    rack_z = re4vr::j_num(d, "rack_z", rack_z);
    rest_z = re4vr::j_num(d, "rest_z", rest_z);
    rack_grab = re4vr::j_num(d, "rack_grab", rack_grab);
    if (d.contains("slide_joint") && d["slide_joint"].is_string()) {
        slide_joint = d["slide_joint"].get<std::string>();
    }
    if (d.contains("ip_joint") && d["ip_joint"].is_string()) {
        ip_joint = d["ip_joint"].get<std::string>();
    }
    ip_z = re4vr::j_num(d, "ip_z", ip_z);
}
inline bool Red9Family::owns() const {
    auto w = equip_wid();
    return enabled && w && *w == wid;
}
inline void Red9Family::refresh() {
    if (!owns()) {
        wep = {};
        return;
    }
    auto [go, tf] = find_weapon(wid);
    wep.id = wid;
    wep.tf = tf;
    wep.slide = tf ? re4vr::joint_by_name(tf, slide_joint) : nullptr;
}
inline void Red9Family::on_frame() {
    if (re4vr::is_ks_active()) {
        return;
    }
    refresh();
    if (!wep.id) {
        clone_destroy(clone_obj, clone_mesh);
        return;
    }
    RE4VRShared::get()->vr_manual_reload_consume_b = true;
    auto hp = lh_world();
    if (clip.active && hp && wep.tf) {
        auto* dj = re4vr::joint_by_name(wep.tf, ip_joint);
        auto jp = dj ? jpos(dj) : std::nullopt;
        auto jr = dj ? jrot(dj) : std::nullopt;
        Vector3f dock = jp.value_or(Vector3f{});
        if (jp && jr) {
            dock = *jp + glm::rotate(*jr, Vector3f{0, 0, ip_z});
        }
        if (jp && glm::distance(*hp, dock) <= insert_dist) {
            clip.active = false;
            clip.insert = true;
            clip.t0 = re4vr::now();
        }
    }
    if (clip.insert && (re4vr::now() - clip.t0) >= insert_dur) {
        clip.insert = false;
        if (reload_ammo) {
            load_and_book(5);
        }
        clone_destroy(clone_obj, clone_mesh);
        rack.need_regrip = true;
    }
    if (wep.slide && hp && !clip.active && !clip.insert) {
        auto sp = jpos(wep.slide);
        const bool grip = left_grip();
        if (sp) {
            const float d = glm::distance(*hp, *sp);
            if (!grip) {
                rack.need_regrip = false;
            }
            if (!rack.grabbed && grip && d <= rack_grab && !rack.need_regrip) {
                rack.grabbed = true;
            } else if (rack.grabbed && !grip) {
                rack.grabbed = false;
            } else if (rack.grabbed && grip && d > rack_grab * 3.f) {
                rack.grabbed = false;
            }
            if (rack.grabbed && wep.tf) {
                auto gpos = re4vr::safe([&] { return sdk::get_transform_position(wep.tf); });
                auto grot = re4vr::safe([&] { return sdk::get_transform_rotation(wep.tf); });
                if (gpos && grot) {
                    const auto local = glm::inverse(*grot) * (*hp - *gpos);
                    const float amt = std::clamp(-local.z, 0.f, std::abs(rack_z));
                    rack.open = amt > std::abs(rack_z) * 0.5f;
                    rack.apply_z = rest_z + (rack_z < 0 ? -amt : amt);
                }
            } else if (rack.open) {
                rack.apply_z = rest_z + rack_z;
            } else {
                rack.apply_z = rest_z;
            }
        }
    }
    {
        auto det = RE4VRShared::get()->re4_damage_end_t;
        const double now = re4vr::now();
        if (det && (!rack.heal_done_t || *rack.heal_done_t != *det) && (now - *det) < 3.0 && !rack.grabbed && wep.slide) {
            rack.heal_done_t = det;
            rack.open = false;
            rack.apply_z = rest_z;
        }
    }
    RE4VRShared::get()->vr_block_fire_when_empty = rack.open || rack.grabbed;
    RE4VRShared::get()->vr_mag_in_hand = clip.active || clip.insert;
    RE4VRShared::get()->vr_slide_rack_active = rack.grabbed;
    const int loaded = ammo_count(live_wi()).value_or(0);
    const int cap = live_wi() ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(live_wi(), "get_CurrentAmmoMax"); }).value_or(0) : 0;
    RE4VRShared::get()->re4_reload_grab_empty = loaded >= cap || (reserve_of(live_wi()) <= 0 && !unlimited());
    RE4VRShared::get()->re4_reload_ui_wid = wid;
}
inline void Red9Family::apply() {
    if (!owns() || !wep.slide) {
        return;
    }
    set_jlp_z(wep.slide, rack.apply_z != 0 ? rack.apply_z : rest_z);
    if ((clip.active || clip.insert) && wep.tf) {
        if (clone_spawn(clone_obj, clone_mesh, go_of(wep.tf), "vr_r9_clip")) {
            clone_place_hand(clone_obj, 0, 0, 0, 0, 0, 0, 1);
        }
    } else if (clone_obj) {
        clone_destroy(clone_obj, clone_mesh);
    }
}
inline void Red9Family::apply_late() {
    if (clone_obj && (clip.active || clip.insert)) {
        clone_place_hand(clone_obj, 0, 0, 0, 0, 0, 0, 1);
    }
}
inline bool Red9Family::set_mag_in_hand(bool active) {
    if (!owns()) {
        return false;
    }
    if (active) {
        if (clip.active || clip.insert) {
            return false;
        }
        const int loaded = ammo_count(live_wi()).value_or(0);
        const int cap = live_wi() ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(live_wi(), "get_CurrentAmmoMax"); }).value_or(0) : 0;
        if (loaded >= cap || (reserve_of(live_wi()) <= 0 && !unlimited())) {
            return false;
        }
        clip.active = true;
        play_wep_sound(wep.tf, 1839787494);
        return true;
    }
    if (clip.active) {
        clip.active = false;
        clone_destroy(clone_obj, clone_mesh);
    }
    return true;
}
inline void Red9Family::reset() {
    clip = {};
    rack = {};
    clone_destroy(clone_obj, clone_mesh);
    wep = {};
}

struct RLFamily {
    std::unordered_map<int32_t, bool> wids{{4900, true}, {4901, true}, {4902, true}};
    std::string json_path{"re4_vr/re4_vr_reload3_rl.json"};
    bool enabled{true};
    bool reload_ammo{true};
    float insert_distance{0.15f};
    std::string warhead{"_07"};
    struct {
        std::optional<int32_t> id;
        ::RETransform* tf{};
        ::REJoint* wh{};
        std::optional<Vector3f> rest;
    } wep;
    struct {
        bool active{false}, insert{false};
        double t0{0};
    } hold;
    ::REGameObject* clone_obj{};
    ::REManagedObject* clone_mesh{};
    void load();
    bool owns() const;
    void refresh();
    void on_frame();
    void apply();
    void apply_late();
    bool set_mag_in_hand(bool active);
    void reset();
};
inline void RLFamily::load() {
    auto d = re4vr::load_json_file(json_path);
    if (d.empty()) {
        return;
    }
    const auto& c = d.contains("cfg") ? d["cfg"] : d;
    if (c.contains("rl_enabled") && c["rl_enabled"].is_boolean()) {
        enabled = c["rl_enabled"].get<bool>();
    }
    if (c.contains("reload_ammo") && c["reload_ammo"].is_boolean()) {
        reload_ammo = c["reload_ammo"].get<bool>();
    }
    if (c.contains("insert_distance") && c["insert_distance"].is_number()) {
        insert_distance = c["insert_distance"].get<float>();
    }
}
inline bool RLFamily::owns() const {
    auto w = equip_wid();
    return enabled && w && wids.contains(*w) && wids.at(*w);
}
inline void RLFamily::refresh() {
    if (!owns()) {
        wep = {};
        return;
    }
    auto w = *equip_wid();
    auto [go, tf] = find_weapon(w);
    wep.id = w;
    wep.tf = tf;
    wep.wh = tf ? re4vr::joint_by_name(tf, warhead) : nullptr;
    if (wep.wh && !wep.rest) {
        wep.rest = jlp(wep.wh);
    }
}
inline void RLFamily::on_frame() {
    if (re4vr::is_ks_active()) {
        return;
    }
    refresh();
    if (!wep.id) {
        clone_destroy(clone_obj, clone_mesh);
        return;
    }
    RE4VRShared::get()->vr_manual_reload_consume_b = true;
    auto hp = lh_world();
    auto gp = wep.tf ? re4vr::safe([&] { return sdk::get_transform_position(wep.tf); }) : std::nullopt;
    if (hold.active && hp && gp && glm::distance(*hp, *gp) <= insert_distance) {
        hold.active = false;
        hold.insert = true;
        hold.t0 = re4vr::now();
    }
    if (hold.insert && (re4vr::now() - hold.t0) >= 0.25) {
        hold.insert = false;
        if (reload_ammo) {
            load_and_book(1);
        }
        clone_destroy(clone_obj, clone_mesh);
    }
    RE4VRShared::get()->vr_mag_in_hand = hold.active || hold.insert;
    const int loaded = ammo_count(live_wi()).value_or(0);
    RE4VRShared::get()->re4_reload_grab_empty = loaded > 0 || (reserve_of(live_wi()) <= 0 && !unlimited());
}
inline void RLFamily::apply() {
    if (!owns()) {
        return;
    }
    if (hold.active || hold.insert) {
        if (wep.wh) {
            set_scale(wep.wh, 0);
        }
        if (clone_spawn(clone_obj, clone_mesh, go_of(wep.tf), "vr_rl_warhead")) {
            clone_place_hand(clone_obj, 0, 0, 0, 0, 0, 0, 1);
        }
    } else {
        if (wep.wh) {
            set_scale(wep.wh, 1);
        }
        clone_destroy(clone_obj, clone_mesh);
    }
}
inline void RLFamily::apply_late() {
    if (clone_obj && (hold.active || hold.insert)) {
        clone_place_hand(clone_obj, 0, 0, 0, 0, 0, 0, 1);
    }
}
inline bool RLFamily::set_mag_in_hand(bool active) {
    if (!owns()) {
        return false;
    }
    if (active) {
        if (ammo_count(live_wi()).value_or(0) > 0) {
            return false;
        }
        if (reserve_of(live_wi()) <= 0 && !unlimited()) {
            return false;
        }
        hold.active = true;
        play_wep_sound(wep.tf, 1839787494);
        return true;
    }
    hold.active = false;
    clone_destroy(clone_obj, clone_mesh);
    return true;
}
inline void RLFamily::reset() {
    hold = {};
    clone_destroy(clone_obj, clone_mesh);
    wep = {};
}

struct FlameFamily {
    int32_t wid{4701};
    std::string json_path{"re4_vr/re4_vr_reload3_flamethrower.json"};
    bool enabled{true};
    float saf_rz{-62.f};
    float saf_lerp{0.08f};
    float insert_distance{0.15f};
    int mag_size{100};
    struct {
        std::optional<int32_t> id;
        ::RETransform* tf{};
        ::REJoint *safety{}, *tank{};
        std::optional<glm::quat> saf_rest;
        std::optional<Vector3f> tank_rest;
    } wep;
    struct {
        bool open{false};
        float prog{0};
        bool prev_b{false};
    } saf;
    struct {
        std::string phase{"idle"};
        bool in_hand{false};
        double t0{0};
        float sx{0}, sy{0}, sz{0};
    } tank;
    void load();
    bool owns() const;
    void refresh();
    void on_frame();
    void apply();
    bool set_mag_in_hand(bool active);
    void reset();
};
inline void FlameFamily::load() {
    auto d = re4vr::load_json_file(json_path);
    if (d.empty()) {
        return;
    }
    const auto& c = d.contains("cfg") ? d["cfg"] : d;
    if (c.contains("ft_enabled") && c["ft_enabled"].is_boolean()) {
        enabled = c["ft_enabled"].get<bool>();
    }
    saf_rz = re4vr::j_num(c, "saf_rz", saf_rz);
    saf_lerp = re4vr::j_num(c, "saf_lerp", saf_lerp);
    insert_distance = re4vr::j_num(c, "insert_distance", insert_distance);
    if (c.contains("mag_size") && c["mag_size"].is_number()) {
        mag_size = (int)c["mag_size"].get<float>();
    }
}
inline bool FlameFamily::owns() const {
    auto w = equip_wid();
    return enabled && w && *w == wid;
}
inline void FlameFamily::refresh() {
    if (!owns()) {
        wep = {};
        return;
    }
    auto [go, tf] = find_weapon(wid);
    wep.id = wid;
    wep.tf = tf;
    wep.safety = tf ? re4vr::joint_by_name(tf, "_05") : nullptr;
    wep.tank = tf ? re4vr::joint_by_name(tf, "_04") : nullptr;
    if (wep.safety && !wep.saf_rest) {
        wep.saf_rest = jlr(wep.safety);
    }
    if (wep.tank && !wep.tank_rest) {
        wep.tank_rest = jlp(wep.tank);
    }
}
inline void FlameFamily::on_frame() {
    if (re4vr::is_ks_active()) {
        return;
    }
    refresh();
    if (!wep.id) {
        return;
    }
    RE4VRShared::get()->vr_manual_reload_consume_b = true;
    const bool b = right_b();
    if (b && !saf.prev_b) {
        saf.open = !saf.open;
        play_wep_sound(wep.tf, 942865223);
        if (saf.open && tank.phase == "idle") {
            tank.phase = "dropping";
            tank.t0 = re4vr::now();
            if (auto p = wep.tank ? jpos(wep.tank) : std::nullopt) {
                tank.sx = p->x;
                tank.sy = p->y;
                tank.sz = p->z;
            }
            drain_to_zero(live_wi());
        }
    }
    saf.prev_b = b;
    const float tgt = saf.open ? 1.f : 0.f;
    if (saf.prog < tgt) {
        saf.prog = std::min(tgt, saf.prog + saf_lerp);
    } else if (saf.prog > tgt) {
        saf.prog = std::max(tgt, saf.prog - saf_lerp);
    }
    if (tank.phase == "dropping") {
        const float t = (float)(re4vr::now() - tank.t0);
        if (t > 0.8f) {
            tank.phase = "floor";
        }
    }
    if (tank.in_hand) {
        auto hp = lh_world();
        auto gp = wep.tf ? re4vr::safe([&] { return sdk::get_transform_position(wep.tf); }) : std::nullopt;
        if (hp && gp && glm::distance(*hp, *gp) <= insert_distance && saf.open) {
            tank.in_hand = false;
            tank.phase = "idle";
            saf.open = false;
            write_ammo(live_wi(), mag_size);
            play_wep_sound(wep.tf, 943565871);
        }
    }
    RE4VRShared::get()->vr_mag_in_hand = tank.in_hand;
    RE4VRShared::get()->vr_block_fire_when_empty = saf.open || tank.phase != "idle";
    RE4VRShared::get()->re4_reload_grab_empty = tank.phase == "idle" || tank.in_hand;
}
inline void FlameFamily::apply() {
    if (!owns()) {
        return;
    }
    if (wep.safety && wep.saf_rest) {
        set_jlr(wep.safety, glm::normalize(*wep.saf_rest * quat_from_euler(0, 0, saf_rz * saf.prog)));
    }
    if (wep.tank) {
        if (tank.in_hand) {
            auto hp = lh_world();
            auto hr = jrot(left_hand());
            if (hp) {
                set_jpos(wep.tank, *hp);
            }
            if (hr) {
                set_jrot(wep.tank, *hr);
            }
        } else if (tank.phase == "dropping") {
            const float t = (float)(re4vr::now() - tank.t0);
            set_jpos(wep.tank, Vector3f{tank.sx, tank.sy - 9.8f * t * t * 0.5f, tank.sz});
        } else if (tank.phase == "floor") {
            set_jpos(wep.tank, Vector3f{tank.sx, tank.sy - 0.85f, tank.sz});
        } else if (wep.tank_rest) {
            set_jlp(wep.tank, *wep.tank_rest);
        }
    }
}
inline bool FlameFamily::set_mag_in_hand(bool active) {
    if (!owns()) {
        return false;
    }
    if (active) {
        if (tank.phase != "floor" && tank.phase != "dropping") {
            return false;
        }
        tank.in_hand = true;
        tank.phase = "in_hand";
        play_wep_sound(wep.tf, 1839787494);
        return true;
    }
    if (tank.in_hand) {
        tank.in_hand = false;
        tank.phase = "floor";
    }
    return true;
}
inline void FlameFamily::reset() {
    saf = {};
    tank = {};
    wep = {};
}

struct BlastBow {
    int32_t wid{6102};
    std::string json_path{"re4_vr/re4_vr_reload5_dlc_bow.json"};
    bool enabled{true};
    float rest_z{0.35594f};
    float drawn_z{-0.015f};
    float insert_distance{0.15f};
    std::string string_j{"_01"};
    std::string bolt_j{"_04"};
    struct {
        std::optional<int32_t> id;
        ::RETransform* tf{};
        ::REJoint *str{}, *bolt{};
    } wep;
    bool bolt_hand{false};
    bool drawn{false};
    float zf{0};
    bool prev_dmg{false};
    void load() {
        auto d = re4vr::load_json_file(json_path);
        if (d.empty()) {
            return;
        }
        if (d.contains("enabled") && d["enabled"].is_boolean()) {
            enabled = d["enabled"].get<bool>();
        }
        insert_distance = re4vr::j_num(d, "insert_distance", insert_distance);
    }
    bool owns() const {
        auto w = equip_wid();
        return enabled && w && *w == wid;
    }
    void refresh() {
        if (!owns()) {
            wep = {};
            return;
        }
        auto [go, tf] = find_weapon(wid);
        wep.id = wid;
        wep.tf = tf;
        wep.str = tf ? re4vr::joint_by_name(tf, string_j) : nullptr;
        wep.bolt = tf ? re4vr::joint_by_name(tf, bolt_j) : nullptr;
    }
    void on_frame() {
        if (re4vr::is_ks_active()) {
            return;
        }
        refresh();
        if (!wep.id) {
            return;
        }
        RE4VRShared::get()->vr_manual_reload_consume_b = true;
        const int loaded = ammo_count(live_wi()).value_or(0);
        if (loaded <= 0) {
            drawn = false;
            zf = 0;
        }
        auto hp = lh_world();
        if (bolt_hand && hp && wep.tf) {
            auto gp = re4vr::safe([&] { return sdk::get_transform_position(wep.tf); });
            if (gp && glm::distance(*hp, *gp) <= insert_distance) {
                bolt_hand = false;
                load_and_book(1);
                play_wep_sound(wep.tf, 943565871);
            }
        }
        if (!bolt_hand && loaded > 0 && wep.str && hp && left_grip()) {
            auto sp = jpos(wep.str);
            if (sp && glm::distance(*hp, *sp) < 0.16f) {
                auto lp = lh_ctrl();
                zf = std::clamp(lp ? -lp->z / 0.12f : zf, 0.f, 1.f);
                drawn = zf >= 0.85f;
            }
        }
        const bool dmg = RE4VRShared::get()->re4_damage_active;
        if (prev_dmg && !dmg) {
            if (!drawn) {
                zf = 0;
                bolt_hand = false;
            } else {
                zf = 1;
            }
        }
        if (dmg) {
            bolt_hand = false;
        }
        prev_dmg = dmg;
        RE4VRShared::get()->vr_mag_in_hand = bolt_hand;
        RE4VRShared::get()->vr_block_fire_when_empty = loaded <= 0 || !drawn;
        RE4VRShared::get()->re4_reload_grab_empty = loaded > 0 || (reserve_of(live_wi()) <= 0 && !unlimited());
    }
    void apply() {
        if (!owns()) {
            return;
        }
        if (wep.str) {
            set_jlp_z(wep.str, rest_z + (drawn_z - rest_z) * zf);
        }
        if (bolt_hand && wep.bolt) {
            auto hp = lh_world();
            auto hr = jrot(left_hand());
            if (hp) {
                set_jpos(wep.bolt, *hp);
            }
            if (hr) {
                set_jrot(wep.bolt, *hr);
            }
        }
    }
    bool set_mag_in_hand(bool active) {
        if (!owns()) {
            return false;
        }
        if (active) {
            if (ammo_count(live_wi()).value_or(0) > 0) {
                return false;
            }
            if (reserve_of(live_wi()) <= 0 && !unlimited()) {
                return false;
            }
            bolt_hand = true;
            play_wep_sound(wep.tf, 1839787494);
            return true;
        }
        bolt_hand = false;
        return true;
    }
    void reset() {
        bolt_hand = false;
        drawn = false;
        zf = 0;
        wep = {};
    }
};

struct RifleSwitch {
    std::unordered_map<int32_t, std::string> joint_name{{4401, "_05"}, {4402, "_06"}, {6105, "_05"}};
    std::unordered_map<int32_t, bool> blocks_fire{{4401, true}, {6105, true}};
    std::unordered_map<int32_t, int> burst{{4402, 2}};
    std::unordered_map<int32_t, CylCfg> pose{{4401, {0, 0, -45, 0, 0, 0, 0.18f}}, {4402, {0, 0, -45, 0, 0, 0, 0.18f}}, {6105, {0, 0, -45, 0, 0, 0, 0.18f}}};
    ::REJoint* j{};
    std::optional<glm::quat> rest;
    int32_t wid{0};
    int stage{0};
    float prog{0};
    bool latched{false}, prev_grip{false}, prev_trig{false};
    void tick(::RETransform* tf, int32_t w, bool rack_needs) {
        if (!tf || !joint_name.contains(w)) {
            j = nullptr;
            return;
        }
        if (wid != w) {
            wid = w;
            j = re4vr::joint_by_name(tf, joint_name[w]);
            rest = j ? jlr(j) : std::nullopt;
            stage = 0;
            prog = 0;
        }
        if (!j) {
            return;
        }
        const bool grip = left_grip();
        if (grip && !prev_grip && !rack_needs) {
            auto jp = jpos(j);
            auto hp = lh_world();
            latched = jp && hp && glm::distance(*hp, *jp) <= 0.14f;
        }
        if (!grip || rack_needs) {
            latched = false;
        }
        prev_grip = grip;
        const bool hand = grip && latched;
        const bool trig = left_trigger();
        if (hand && trig && !prev_trig) {
            stage = 1 - stage;
            play_wep_sound(tf, 3805002294);
        }
        prev_trig = trig;
        const float L = pose[w].lerp;
        const float tgt = (float)stage;
        if (prog < tgt) {
            prog = std::min(tgt, prog + L);
        } else if (prog > tgt) {
            prog = std::max(tgt, prog - L);
        }
        RE4VRShared::get()->vr_rifle_fire_mode = stage;
        if (burst.contains(w) && stage == 1) {
            RE4VRShared::get()->vr_burst_active = true;
            RE4VRShared::get()->vr_burst_count = burst[w];
        } else {
            RE4VRShared::get()->vr_burst_active = false;
        }
        if (blocks_fire.contains(w) && blocks_fire[w] && stage == 1) {
            RE4VRShared::get()->vr_block_fire_when_empty = true;
        }
    }
    void apply() {
        if (!j || !rest) {
            return;
        }
        if (prog <= 0.0001f) {
            set_jlr(j, *rest);
            return;
        }
        auto& s = pose[wid];
        set_jlr(j, glm::normalize(*rest * quat_from_euler(s.rx * prog, s.ry * prog, s.rz * prog)));
    }
};

} // namespace re4vr::rl
#endif
