#pragma once

#if defined(RE4)
#include <cstring>

#include "RE4VRReloadCommon.hpp"

namespace re4vr::rl {

struct MagCfg {
    bool enabled{true};
    bool pistols_enabled{true}, smgs_enabled{true}, shotguns_enabled{true}, magnum_enabled{true}, rifles_enabled{true};
    float gravity{9.8f};
    std::string mag_hold_pose{"MAG"};
    float insert_dur{0.18f}, insert_distance{0.15f};
    bool insert_punch{true};
    float insert_overshoot{0.005f}, insert_settle{0.07f}, insert_haptic{0.85f}, insert_snd_at{0.80f};
    bool insert_manual{true};
    float insert_travel{0.09f}, insert_snap_at{0.80f}, insert_back_out{0.02f}, insert_redock{0.01f};
    bool reload_ammo{true}, rack_enabled{true};
    float rack_grab_dist{0.18f}, rack_pull_dist{0.09f}, pump_start_pull{0.04f}, pump_push_frac{0.5f};
    bool rack_haptic{true};
    std::string rack_pose{"rack-slide"}, rack_pose_side{"MAGRack"};
    float rack_pose_side_deg{45};
    bool sound_enabled{true};
    float mag_floor_delay{0.45f};
    float shotgun_ratio{2}, pump_haptic_delay{0};
};

struct JointCfg {
    std::string mag, slide, empty;
};
struct DockPort {
    std::string joint{"_03"};
    float x{0}, y{0}, z{0};
};
struct RotaryCfg {
    float rx{0}, ry{0}, rz{90}, grab_dist{0.12f}, lerp{0.12f}, pitch_range{25};
};

class MagFed {
public:
    MagCfg cfg{};
    std::string json_path;
    std::string lua_file;
    bool dlc{false};
    int32_t ss_wid{0}; // skull shaker clone wid (6001 leon / 0 ada unless set)

    std::unordered_map<int32_t, bool> pistols, smgs, shotguns, magnum, rifles;
    std::unordered_map<int32_t, JointCfg> joints;
    std::unordered_map<int32_t, SlidePose> slide, slide2;
    std::unordered_map<int32_t, MagHand> maghand;
    std::unordered_map<int32_t, ShellEject> shell_eject_cfg;
    std::unordered_map<int32_t, std::string> mag_pose, rack_pose, rack_pose_empty;
    std::unordered_map<int32_t, Snd> sounds;
    std::unordered_map<int32_t, DockPort> dock_port, lever_port;
    std::unordered_map<int32_t, float> chamber_z, insert_dist_wid, shotgun_ratio_wid;
    std::unordered_map<std::string, float> insert_dist{{"pistols", 0.15f}, {"smgs", 0.15f}, {"shotguns", 0.15f}, {"magnum", 0.15f}, {"rifles", 0.15f}};
    std::unordered_set<int32_t> chamber_hold_persist, engine_closes, no_cycle_after, no_reload_cycle;
    std::unordered_set<int32_t> parent_space, rotary_cycle, break_action, top_loader;
    std::unordered_map<int32_t, RotaryCfg> rotary;
    std::unordered_map<int32_t, uint32_t> auto_pump_mute;
    std::unordered_map<std::string, std::unordered_map<std::string, glm::quat>> poses;
    std::unordered_map<int32_t, bool> insert_manual_wid{{6104, false}};

    struct Wep {
        std::optional<int32_t> wid;
        ::RETransform* tf{nullptr};
        ::REJoint *mag{nullptr}, *slide{nullptr}, *slide2{nullptr};
        std::optional<Vector3f> rest_lp, chamber_off;
        std::optional<glm::quat> rest_lr, cycle_rest;
    } wep;

    struct Drop {
        bool active{false}, use_module{false};
        ::REJoint* joint{nullptr};
        float sx{0}, sy{0}, sz{0};
        double t0{0};
        std::optional<glm::quat> sr;
    } drop;
    struct MagHandSt {
        bool active{false}, grip_held{false};
        ::REJoint* joint{nullptr};
        std::optional<int32_t> wid;
        std::optional<float> redock_d;
        float dist{99};
    } mag_hand;
    struct Insert {
        bool active{false}, settle{false}, visual{false}, manual{false}, keyframe{false}, punch{false};
        ::REJoint* joint{nullptr};
        double t0{0}, settle_t0{0};
        float dur{0.18f};
        std::optional<Vector3f> slp, rlp, olp;
        std::optional<glm::quat> slr, rlr;
        std::optional<float> d0;
        bool snd{false};
    } mag_insert;
    struct Rack {
        bool needs{false}, grab_active{false}, armed{false}, pulled{false}, pushed{false};
        bool has_mag{false}, empty{false}, empty_when_dropped{false}, empty_reload{false};
        bool tuning{false}, dock_tune{false}, pose_side{false};
        bool chambered_hold{false}, zeroed_by_us{false};
        float gx{0}, gy{0}, gz{0}, frac{0}, dock_blend{0}, tune_frac{0};
        float last_dist{-1};
        std::optional<double> heal_done_t;
        std::optional<float> pump_init, pump_max, g_relz, ammo_input_t;
        std::optional<Vector3f> pump_off;
        std::optional<float> rgx, rgy, rgz;
        std::optional<int> prev_shot_seq, prev_gun_ammo;
        std::unordered_map<int32_t, bool> needs_store, mag_out_store;
        std::unordered_map<int32_t, int> retained_store;
        std::optional<int32_t> gone_wid;
        bool last_grip{false};
        bool pushdock_was{false};
    } rack;
    struct RotarySt {
        float prog{0};
        int dir{0};
        bool prev_trig{false}, pending{false}, grip_latched{false}, prev_grip{false};
    } rot;
    struct BreakSt {
        float prog{0};
        bool open{false}, was_open{false}, prev_b{false};
    } brk;
    struct ShellFly {
        bool preview{false}, flying{false};
        float t{0};
        double last_clock{0};
        bool prev_pulled{false};
    } seject;
    struct SSClone {
        ::REGameObject* obj{nullptr};
        ::REManagedObject* mesh{nullptr};
        bool parented{false};
        std::string parts_sig;
        int part{1};
        float x{0}, y{0}, z{0}, rx{0}, ry{0}, rz{0}, scale{1};
        bool preview{false};
    } ss;
    struct HapticQ {
        double at{0};
        float amp{0}, dur{0};
    };

    bool mag_out{false};
    int mag_retained{0};
    bool mag_tune{false};
    bool managed{false};
    bool b_prev{false};
    bool drop_prev{false};
    bool empty_trig_prev{false};
    double mag_floor_at{0};
    std::optional<int32_t> last_handled;
    bool weapon_reacquired{false};
    bool our_sound{false};
    std::vector<HapticQ> haptic_q;
    ::REJoint* lhand{nullptr};

    void seed_leon();
    void seed_ada();
    void seed_rifle_leon();
    void seed_rifle_ada();
    void seed_chicago();
    void load();
    void on_frame();
    void apply_drop();
    void apply_drop_joint();
    void apply_slide();
    void apply_ss();
    void apply_ss_late();
    void apply_ss_insert_visual();
    bool set_mag_in_hand(bool active);
    void export_globals(sol::state& lua);
    void reset();
    void clear_globals();
    std::optional<int32_t> handled();
    bool shotgun(int32_t w) const { return shotguns.contains(w) && shotguns.at(w); }
    int32_t wid() const { return wep.wid.value_or(0); }

private:
    std::string cat_of(int32_t w) const;
    bool cat_on(const std::string& c) const;
    SlidePose& sp_of(int32_t w);
    SlidePose& sp2_of(int32_t w);
    MagHand& mh_of(int32_t w);
    ShellEject& se_of(int32_t w);
    uint32_t snd(const char* k);
    void play(const char* k);
    void refresh();
    ::REJoint* rack_j();
    SlidePose rack_sp();
    bool mag_present() const { return !(drop.active || mag_hand.active || mag_insert.active); }
    bool start_drop();
    void stop_drop();
    void update_drop();
    void update_in_hand();
    void capture_rest();
    bool start_insert();
    void finish_insert();
    void update_insert();
    void check_proximity();
    bool mag_to_hand();
    bool drop_simple();
    bool force_eject();
    void update_rack_state();
    void update_rack_gesture();
    void update_rotary();
    void update_break();
    void update_dock_blend();
    void publish_dock();
    bool publish_push_dock();
    void apply_slide_park();
    void apply_shell_eject();
    void update_shell_eject();
    void apply_mag_hidden();
    void apply_rack_pose();
    void clear_rack();
    void service_haptics();
    void queue_haptic(float amp, float dur);
    void rack_haptic(float amp, float dur);
    int live_loaded();
    std::optional<Vector3f> dock_world();
    std::optional<Vector3f> chamber_world();
    float mag_push_dist();
    bool pump_one_out();
    void ss_destroy();
    bool ss_spawn();
    void ss_place();
    void sg_force_parts(bool on);
    void reset_reload();
};

inline void MagFed::seed_leon() {
    json_path = "re4_vr/re4_vr_reload.json";
    lua_file = "re4_vr_reload.lua";
    ss_wid = 6001;
    pistols = {{4000, true}, {4001, true}, {4003, true}, {4004, true}, {6000, true}, {4501, true}, {6300, true}, {6301, true}};
    smgs = {{4200, true}, {4202, true}};
    shotguns = {{4100, true}, {4101, true}, {4102, true}, {6001, true}};
    joints = {
        {4004, {"_14", "_01"}}, {4001, {"_14", "_01"}}, {4000, {"_14", "_01"}}, {4003, {"_14", "_01"}},
        {6000, {"_14", "_01"}}, {4501, {"_14", "_01"}}, {6300, {"_14", "_01"}}, {6301, {"_14", "_01"}},
        {4200, {"_04", "_09"}}, {4202, {"_04", "_02"}},
        {4100, {"_04", "_01"}}, {4101, {"_04", "_01", "_08"}}, {4102, {"_06", "_01"}}, {6001, {"_04", "_02"}},
    };
    auto pun = SlidePose{0.10042f, 0.08542f, 0.06042f, 0.045f, 0.032f, -0.192f, 53.7f, 285.7f, -86.1f};
    slide[4004] = {0.06174f, 0.04674f, 0.03174f};
    for (int id : {4001, 4000, 4003, 6000, 4501, 6301, 4002}) {
        slide[id] = pun;
    }
    slide[6300] = {0.06542f, 0.05042f, 0.02542f, 0.045f, 0.032f, -0.192f, 53.7f, 285.7f, -86.1f};
    slide[4200] = {-0.07458f, -0.07458f, -0.10500f, 0.045f, 0.032f, -0.192f, 53.7f, 285.7f, -86.1f};
    slide[4201] = pun;
    slide[4202] = pun;
    SlidePose pump{0.425f, 0.425f, 0.300f};
    slide[4100] = pump;
    slide[4101] = pump;
    slide[4102] = pump;
    slide[6001] = pump;
    mag_pose = {{4202, "LE5MAG"}, {4200, "TMPMAG"}, {4100, "Shotgunshell"}, {4101, "Shotgunshell"}, {4102, "Shotgunshell"}, {6001, "Shotgunshell"}};
    rack_pose = {{4202, "LE5MAGSLIDE"}, {4100, "SGPUMP"}, {4101, "SGPUMP"}, {4102, "StrikerReload"}, {4000, "MAGRack"}, {4003, "MAGRack"}, {6301, "MAGRack"}, {4200, "rack-slide"}};
    rack_pose_empty = {{4101, "RiotSLide"}};
    chamber_hold_persist = {6000, 4000, 4003, 4001, 4004, 4501, 6300, 6301};
    engine_closes = {4202};
    no_cycle_after = {4101, 4102, 6001};
    no_reload_cycle = {4101};
    parent_space = {4200, 6104};
    rotary_cycle = {4102};
    break_action = {6001};
    rotary[4102] = {0, 0, 90, 0.12f, 0.12f, 25};
    chamber_z = {{4100, -0.093f}, {4101, 0}, {4102, -0.093f}, {6001, -0.093f}};
    dock_port = {{4202, {"_03", 0, 0, 0.087f}}, {4102, {"_03", -0.020f, 0.026f, 0.016f}}, {6001, {"_03", 0.021f, 0, 0.055f}}};
    lever_port = {{6001, {"_01", 0, 0, 0}}};
    auto_pump_mute = {{4100, 1964290782u}, {4101, 1964290782u}, {4102, 1964290782u}, {6001, 1964290782u}};
    Snd pun_s{812850326, 1466005368, 1757452382, 3140689763, 943565871, 1839787494};
    sounds[4004] = {1757452382, 1466005368, 3805002294, 3140689763, 943565871, 1839787494};
    for (int id : {4001, 4000, 4003, 6000, 6300, 6301, 4002, 4200, 4201, 4202, 4501}) {
        sounds[id] = pun_s;
    }
    sounds[4100] = {812850326, 1466005368, 942865223, 1351699582, 741230436, 1839787494};
    sounds[4101] = {812850326, 1466005368, 942865223, 1351699582, 1001178976, 1839787494};
    sounds[4102] = {812850326, 1466005368, 942865223, 1351699582, 741230436, 1839787494, 942865223};
    sounds[6001] = {812850326, 1466005368, 942865223, 1351699582, 741230436, 1839787494, 0, 1938228639};
}

inline void MagFed::seed_rifle_leon() {
    json_path = "re4_vr/re4_vr_reload2_rifle.json";
    lua_file = "re4_vr_reload2.lua";
    pistols.clear();
    smgs.clear();
    shotguns.clear();
    magnum.clear();
    rifles = {{4401, true}, {4402, true}};
    joints = {{4401, {"_04", "_02"}}, {4402, {"_04", "_02"}}};
    auto pun = SlidePose{0.10042f, 0.08542f, 0.06042f, 0.045f, 0.032f, -0.192f, 53.7f, 285.7f, -86.1f};
    slide[4401] = pun;
    slide[4402] = pun;
    mag_pose = {{4401, "StingrayMag"}, {4402, "StingrayMag"}};
    rack_pose = {{4401, "StingraySlide"}, {4402, "CqbrSlide"}};
    engine_closes = {4401};
    dock_port = {{4401, {"_03", 0.0f, 0.0f, 0.090f}}};
    sounds[4401] = {812850326, 1466005368, 943565871, 3042341191, 2254736731, 1839787494};
    sounds[4402] = {812850326, 1466005368, 943565871, 3042341191, 611689939, 1839787494};
}

inline void MagFed::seed_rifle_ada() {
    json_path = "re4_vr/re4_vr_reload5_dlc_rifle.json";
    lua_file = "re4_vr_reload5_dlc.lua";
    pistols.clear();
    smgs.clear();
    shotguns.clear();
    magnum.clear();
    rifles = {{6105, true}};
    joints = {{6105, {"_04", "_02"}}};
    slide[6105] = SlidePose{0.10042f, 0.08542f, 0.06042f, 0.045f, 0.032f, -0.192f, 53.7f, 285.7f, -86.1f};
    mag_pose = {{6105, "StingrayMag"}};
    rack_pose = {{6105, "StingraySlide"}};
    engine_closes = {6105};
    dock_port = {{6105, {"_03", 0.0f, 0.0f, 0.090f}}};
    sounds[6105] = {812850326, 1466005368, 943565871, 3042341191, 2254736731, 1839787494};
}

inline void MagFed::seed_chicago() {
    json_path = "re4_vr/re4_vr_reload3_chicago.json";
    lua_file = "re4_vr_reload3.lua";
    pistols.clear();
    shotguns.clear();
    magnum.clear();
    rifles.clear();
    smgs = {{4201, true}};
    joints = {{4201, {"_04", "_01"}}};
    slide[4201] = SlidePose{-0.02336f, 0.08664f, -0.02336f, 0.045f, 0.032f, -0.192f, 53.7f, 285.7f, -86.1f};
    mag_pose = {{4201, "ChicagoMag"}};
    rack_pose = {{4201, "ChicagoSlide"}};
    dock_port = {{4201, {"_03", 0.0f, 0.040f, 0.060f}}};
    sounds[4201] = {812850326, 1466005368, 943565871, 3140689763, 943565871, 1839787494};
}

inline void MagFed::seed_ada() {
    json_path = "re4_vr/re4_vr_reload4_dlc.json";
    lua_file = "re4_vr_reload4_dlc.lua";
    dlc = true;
    pistols = {{6103, true}, {6112, true}};
    smgs = {{6104, true}};
    shotguns = {{6100, true}};
    joints = {{6112, {"_14", "_01"}}, {6103, {"_14", "_01"}}, {6104, {"_04", "_09"}}, {6100, {"_04", "_01"}}};
    auto pun = SlidePose{0.10042f, 0.08542f, 0.06042f, 0.045f, 0.032f, -0.192f, 53.7f, 285.7f, -86.1f};
    slide[6112] = pun;
    slide[6103] = pun;
    slide[6104] = {-0.07458f, -0.07458f, -0.10500f, 0.045f, 0.032f, -0.192f, 53.7f, 285.7f, -86.1f};
    slide[6100] = {0.425f, 0.425f, 0.300f};
    mag_pose = {{6104, "TMPMAG"}, {6100, "Shotgunshell"}, {6112, "MAG"}, {6103, "MAG"}};
    rack_pose = {{6100, "SGPUMP"}, {6103, "MAGRack"}, {6104, "rack-slide"}};
    chamber_hold_persist = {6103, 6112};
    parent_space = {6104};
    no_cycle_after = {};
    chamber_z = {{6100, -0.093f}};
    auto_pump_mute = {{6100, 1964290782u}};
    Snd pun_s{812850326, 1466005368, 1757452382, 3140689763, 943565871, 1839787494};
    sounds[6112] = pun_s;
    sounds[6103] = pun_s;
    sounds[6104] = pun_s;
    sounds[6100] = {812850326, 1466005368, 942865223, 1351699582, 741230436, 1839787494};
}

inline std::string MagFed::cat_of(int32_t w) const {
    if (pistols.contains(w) && pistols.at(w)) {
        return "pistols";
    }
    if (smgs.contains(w) && smgs.at(w)) {
        return "smgs";
    }
    if (shotguns.contains(w) && shotguns.at(w)) {
        return "shotguns";
    }
    if (magnum.contains(w) && magnum.at(w)) {
        return "magnum";
    }
    if (rifles.contains(w) && rifles.at(w)) {
        return "rifles";
    }
    return {};
}
inline bool MagFed::cat_on(const std::string& c) const {
    if (c == "pistols") {
        return cfg.pistols_enabled;
    }
    if (c == "smgs") {
        return cfg.smgs_enabled;
    }
    if (c == "shotguns") {
        return cfg.shotguns_enabled;
    }
    if (c == "magnum") {
        return cfg.magnum_enabled;
    }
    if (c == "rifles") {
        return cfg.rifles_enabled;
    }
    return false;
}
inline SlidePose& MagFed::sp_of(int32_t w) {
    if (!slide.contains(w)) {
        slide[w] = SlidePose{};
    }
    return slide[w];
}
inline SlidePose& MagFed::sp2_of(int32_t w) {
    if (!slide2.contains(w)) {
        slide2[w] = SlidePose{};
    }
    return slide2[w];
}
inline MagHand& MagFed::mh_of(int32_t w) {
    return maghand[w];
}
inline ShellEject& MagFed::se_of(int32_t w) {
    if (!shell_eject_cfg.contains(w)) {
        shell_eject_cfg[w] = ShellEject{};
    }
    return shell_eject_cfg[w];
}

inline void MagFed::load() {
    const auto d = re4vr::load_json_file(json_path);
    if (d.empty()) {
        return;
    }
    const auto& c = d.contains("cfg") ? d["cfg"] : d;
    auto jb = [&](const char* k, bool& v) {
        if (c.contains(k) && c[k].is_boolean()) {
            v = c[k].get<bool>();
        }
    };
    auto jn = [&](const char* k, float& v) {
        if (c.contains(k) && c[k].is_number()) {
            v = c[k].get<float>();
        }
    };
    jb("pistols_enabled", cfg.pistols_enabled);
    jb("smgs_enabled", cfg.smgs_enabled);
    jb("shotguns_enabled", cfg.shotguns_enabled);
    jb("magnum_enabled", cfg.magnum_enabled);
    jb("rifles_enabled", cfg.rifles_enabled);
    if (c.contains("rifle_enabled") && c["rifle_enabled"].is_boolean()) {
        cfg.rifles_enabled = c["rifle_enabled"].get<bool>();
        cfg.enabled = cfg.rifles_enabled;
    }
    if (c.contains("chicago_enabled") && c["chicago_enabled"].is_boolean()) {
        cfg.smgs_enabled = c["chicago_enabled"].get<bool>();
        cfg.enabled = cfg.smgs_enabled;
    }
    jb("reload_ammo", cfg.reload_ammo);
    jb("rack_enabled", cfg.rack_enabled);
    jb("rack_haptic", cfg.rack_haptic);
    jb("sound_enabled", cfg.sound_enabled);
    jb("insert_punch", cfg.insert_punch);
    jb("insert_manual", cfg.insert_manual);
    jn("gravity", cfg.gravity);
    jn("insert_dur", cfg.insert_dur);
    jn("insert_distance", cfg.insert_distance);
    jn("rack_grab_dist", cfg.rack_grab_dist);
    jn("mag_floor_delay", cfg.mag_floor_delay);
    jn("shotgun_ratio", cfg.shotgun_ratio);
    jn("pump_haptic_delay", cfg.pump_haptic_delay);
    jn("insert_overshoot", cfg.insert_overshoot);
    jn("insert_settle", cfg.insert_settle);
    jn("insert_haptic", cfg.insert_haptic);
    jn("insert_snd_at", cfg.insert_snd_at);
    jn("insert_travel", cfg.insert_travel);
    jn("insert_back_out", cfg.insert_back_out);
    jn("insert_redock", cfg.insert_redock);
    jn("insert_snap_at", cfg.insert_snap_at);
    jn("rack_pose_side_deg", cfg.rack_pose_side_deg);
    jn("pump_start_pull", cfg.pump_start_pull);
    jn("pump_push_frac", cfg.pump_push_frac);
    if (c.contains("mag_hold_pose") && c["mag_hold_pose"].is_string()) {
        cfg.mag_hold_pose = c["mag_hold_pose"].get<std::string>();
    }
    if (c.contains("rack_pose") && c["rack_pose"].is_string()) {
        cfg.rack_pose = c["rack_pose"].get<std::string>();
    }
    if (c.contains("rack_pose_side") && c["rack_pose_side"].is_string()) {
        cfg.rack_pose_side = c["rack_pose_side"].get<std::string>();
    }
    if (c.contains("enabled") && c["enabled"].is_boolean()) {
        cfg.enabled = c["enabled"].get<bool>();
    } else if (!c.contains("rifle_enabled") && !c.contains("chicago_enabled")) {
        cfg.enabled = true;
    }
    if (d.contains("maghand") && d["maghand"].is_object()) {
        for (auto it = d["maghand"].begin(); it != d["maghand"].end(); ++it) {
            try {
                load_maghand_json(mh_of(std::stoi(it.key())), it.value());
            } catch (...) {
            }
        }
    }
    if (d.contains("slide_pose") && d["slide_pose"].is_object()) {
        for (auto it = d["slide_pose"].begin(); it != d["slide_pose"].end(); ++it) {
            try {
                load_slide_json(sp_of(std::stoi(it.key())), it.value());
            } catch (...) {
            }
        }
    }
    if (d.contains("sdk_dock") && d["sdk_dock"].is_object()) {
        for (auto it = d["sdk_dock"].begin(); it != d["sdk_dock"].end(); ++it) {
            try {
                load_slide_json(sp_of(std::stoi(it.key())), it.value());
            } catch (...) {
            }
        }
    }
    if (d.contains("slide") && d["slide"].is_object()) {
        for (auto it = d["slide"].begin(); it != d["slide"].end(); ++it) {
            try {
                load_slide_json(sp_of(std::stoi(it.key())), it.value());
            } catch (...) {
            }
        }
    }
    if (d.contains("dock") && d["dock"].is_object()) {
        for (auto it = d["dock"].begin(); it != d["dock"].end(); ++it) {
            try {
                int32_t w = std::stoi(it.key());
                auto& dp = dock_port[w];
                if (it.value().contains("joint") && it.value()["joint"].is_string()) {
                    dp.joint = it.value()["joint"].get<std::string>();
                }
                dp.x = re4vr::j_num(it.value(), "x", dp.x);
                dp.y = re4vr::j_num(it.value(), "y", dp.y);
                dp.z = re4vr::j_num(it.value(), "z", dp.z);
            } catch (...) {
            }
        }
    }
    if (d.contains("shell_eject") && d["shell_eject"].is_object()) {
        for (auto it = d["shell_eject"].begin(); it != d["shell_eject"].end(); ++it) {
            try {
                int32_t w = std::stoi(it.key());
                auto& s = se_of(w);
                s.sx = re4vr::j_num(it.value(), "sx", s.sx);
                s.sy = re4vr::j_num(it.value(), "sy", s.sy);
                s.sz = re4vr::j_num(it.value(), "sz", s.sz);
                s.vx = re4vr::j_num(it.value(), "vx", s.vx);
                s.vy = re4vr::j_num(it.value(), "vy", s.vy);
                s.vz = re4vr::j_num(it.value(), "vz", s.vz);
                s.grav = re4vr::j_num(it.value(), "grav", s.grav);
                s.dur = re4vr::j_num(it.value(), "dur", s.dur);
                s.spin = re4vr::j_num(it.value(), "spin", s.spin);
            } catch (...) {
            }
        }
    }
    if (d.contains("insert_dist") && d["insert_dist"].is_object()) {
        for (auto it = d["insert_dist"].begin(); it != d["insert_dist"].end(); ++it) {
            if (it.value().is_number()) {
                insert_dist[it.key()] = it.value().get<float>();
            }
        }
    }
    if (d.contains("insert_dist_wid") && d["insert_dist_wid"].is_object()) {
        for (auto it = d["insert_dist_wid"].begin(); it != d["insert_dist_wid"].end(); ++it) {
            try {
                if (it.value().is_number()) {
                    insert_dist_wid[std::stoi(it.key())] = it.value().get<float>();
                }
            } catch (...) {
            }
        }
    }
    if (d.contains("shotgun_ratio_wid") && d["shotgun_ratio_wid"].is_object()) {
        for (auto it = d["shotgun_ratio_wid"].begin(); it != d["shotgun_ratio_wid"].end(); ++it) {
            try {
                if (it.value().is_number()) {
                    shotgun_ratio_wid[std::stoi(it.key())] = it.value().get<float>();
                }
            } catch (...) {
            }
        }
    }
    if (d.contains("poses") && d["poses"].is_object()) {
        for (auto it = d["poses"].begin(); it != d["poses"].end(); ++it) {
            if (!it.value().is_object() || !it.value().contains("bones")) {
                continue;
            }
            auto& bones = poses[it.key()];
            for (auto b = it.value()["bones"].begin(); b != it.value()["bones"].end(); ++b) {
                if (b.value().is_array() && b.value().size() >= 4) {
                    bones[b.key()] = glm::quat{(float)b.value()[0], (float)b.value()[1], (float)b.value()[2], (float)b.value()[3]};
                } else if (b.value().is_object()) {
                    bones[b.key()] = glm::quat{re4vr::j_num(b.value(), "w", 1), re4vr::j_num(b.value(), "x", 0), re4vr::j_num(b.value(), "y", 0), re4vr::j_num(b.value(), "z", 0)};
                }
            }
        }
    }
    if (d.contains("shell_clone") && d["shell_clone"].is_object()) {
        ss.part = (int)re4vr::j_num(d["shell_clone"], "part", (float)ss.part);
        ss.x = re4vr::j_num(d["shell_clone"], "x", ss.x);
        ss.y = re4vr::j_num(d["shell_clone"], "y", ss.y);
        ss.z = re4vr::j_num(d["shell_clone"], "z", ss.z);
        ss.rx = re4vr::j_num(d["shell_clone"], "rx", ss.rx);
        ss.ry = re4vr::j_num(d["shell_clone"], "ry", ss.ry);
        ss.rz = re4vr::j_num(d["shell_clone"], "rz", ss.rz);
        ss.scale = re4vr::j_num(d["shell_clone"], "scale", ss.scale);
    }
}

inline std::optional<int32_t> MagFed::handled() {
    auto w = equip_wid();
    if (!w) {
        return std::nullopt;
    }
    auto c = cat_of(*w);
    if (!cat_on(c)) {
        return std::nullopt;
    }
    if (top_loader.contains(*w)) {
        return w;
    }
    auto it = joints.find(*w);
    if (it == joints.end() || it->second.mag.empty()) {
        return std::nullopt;
    }
    return w;
}

inline uint32_t MagFed::snd(const char* k) {
    auto it = sounds.find(wid());
    if (it == sounds.end()) {
        return 0;
    }
    const auto& s = it->second;
    if (std::strcmp(k, "dry_fire") == 0) {
        return s.dry_fire;
    }
    if (std::strcmp(k, "mag_eject") == 0) {
        return s.mag_eject;
    }
    if (std::strcmp(k, "mag_insert") == 0) {
        return s.mag_insert;
    }
    if (std::strcmp(k, "mag_floor") == 0) {
        return s.mag_floor;
    }
    if (std::strcmp(k, "slide_back") == 0) {
        return s.slide_back;
    }
    if (std::strcmp(k, "mag_holster") == 0) {
        return s.mag_holster;
    }
    if (std::strcmp(k, "cycle") == 0) {
        return s.cycle;
    }
    if (std::strcmp(k, "break_open") == 0) {
        return s.break_open;
    }
    if (std::strcmp(k, "chamber") == 0) {
        return s.chamber;
    }
    return 0;
}
inline void MagFed::play(const char* k) {
    if (cfg.sound_enabled) {
        our_sound = true;
        play_wep_sound(wep.tf, snd(k));
        our_sound = false;
    }
}
inline void MagFed::rack_haptic(float amp, float dur) {
    if (cfg.rack_haptic) {
        haptic_left(amp, dur);
    }
}
inline void MagFed::queue_haptic(float amp, float dur) {
    if (cfg.pump_haptic_delay <= 0) {
        rack_haptic(amp, dur);
        return;
    }
    haptic_q.push_back({re4vr::now() + cfg.pump_haptic_delay, amp, dur});
}
inline void MagFed::service_haptics() {
    const double now = re4vr::now();
    for (size_t i = 0; i < haptic_q.size();) {
        if (now >= haptic_q[i].at) {
            rack_haptic(haptic_q[i].amp, haptic_q[i].dur);
            haptic_q.erase(haptic_q.begin() + (std::ptrdiff_t)i);
        } else {
            ++i;
        }
    }
}

inline void MagFed::refresh() {
    auto w = equip_wid();
    if (!w || *w == 0) {
        wep = {};
        return;
    }
    if (wep.wid == w && (wep.mag || top_loader.contains(*w)) && wep.tf) {
        auto p = re4vr::safe([&] { return sdk::get_transform_position(wep.tf); });
        if (p) {
            return;
        }
    }
    const bool same = wep.wid == w;
    wep = {};
    auto cfgj = joints.contains(*w) ? joints[*w] : JointCfg{};
    auto [go, tf] = find_weapon(*w);
    if (!tf) {
        return;
    }
    wep.wid = w;
    wep.tf = tf;
    wep.mag = cfgj.mag.empty() ? nullptr : re4vr::joint_by_name(tf, cfgj.mag);
    wep.slide = cfgj.slide.empty() ? nullptr : re4vr::joint_by_name(tf, cfgj.slide);
    wep.slide2 = cfgj.empty.empty() ? nullptr : re4vr::joint_by_name(tf, cfgj.empty);
    if (!cfgj.empty.empty() && joints[*w].empty.empty() && shotguns.contains(*w)) {
        // empty joint already from JointCfg.empty
    }
    if (*w == 4101) {
        wep.slide2 = re4vr::joint_by_name(tf, "_08");
    }
    RE4VRShared::get()->re4_rack_joint_name = std::string{cfgj.slide};
    RE4VRShared::get()->re4_rack_joint_wid = *w;
    if ((rotary_cycle.contains(*w) || break_action.contains(*w)) && wep.slide) {
        wep.cycle_rest = re4vr::safe([&] { return sdk::call_object_func_easy<glm::quat>(wep.slide, "get_BaseLocalRotation"); }).value_or(sdk::get_joint_local_rotation(wep.slide));
        if (break_action.contains(*w) && wep.cycle_rest) {
            set_jlr(wep.slide, *wep.cycle_rest);
        }
    }
    if (same) {
        weapon_reacquired = true;
    }
}

inline ::REJoint* MagFed::rack_j() {
    return (rack.empty_reload && wep.slide2) ? wep.slide2 : wep.slide;
}
inline SlidePose MagFed::rack_sp() {
    return rack.empty_reload ? sp2_of(wid()) : sp_of(wid());
}

inline bool MagFed::start_drop() {
    if (!wep.mag) {
        return false;
    }
    mag_hand.active = false;
    mag_insert = {};
    mag_tune = false;
    if (cfg.reload_ammo) {
        auto* p = pe();
        mag_retained = p ? gun_ammo().value_or(ammo_count(live_wi()).value_or(0)) : ammo_count(live_wi()).value_or(0);
        RE4VRShared::get()->re4_mag_carry = mag_retained;
        RE4VRShared::get()->re4_mag_carry_wid = wid();
        auto* wi = live_wi();
        drain_to_zero(wi);
        rack.zeroed_by_us = true;
    }
    auto* ms = mag_slide();
    if (ms) {
        std::optional<RE4VRReloadAdv::Vec3> target;
        if (parent_space.contains(wid()) && wep.tf && wep.mag) {
            auto W = ms->dock_world(wep.tf, wid());
            auto jw = jpos(wep.mag);
            auto jr = jrot(wep.mag);
            auto jlpv = jlp(wep.mag);
            auto jlrv = jlr(wep.mag);
            if (W && jw && jr && jlpv && jlrv) {
                auto dd = glm::rotate(*jlrv, glm::rotate(glm::inverse(*jr), *W - *jw));
                target = RE4VRReloadAdv::Vec3{jlpv->x + dd.x, jlpv->y + dd.y, jlpv->z + dd.z};
            }
        } else if (wep.tf) {
            auto loc = ms->dock_local(wep.tf, wid());
            if (loc) {
                target = *loc;
            }
        }
        if (ms->begin_drop(wep.mag, wid(), cfg.insert_dur, target)) {
            drop.active = true;
            drop.use_module = true;
            drop.joint = wep.mag;
            return true;
        }
    }
    auto p = jpos(wep.mag);
    if (!p) {
        return false;
    }
    drop.joint = wep.mag;
    drop.use_module = false;
    drop.sx = p->x;
    drop.sy = p->y;
    drop.sz = p->z;
    drop.sr = jrot(wep.mag);
    drop.t0 = re4vr::now();
    drop.active = true;
    return true;
}

inline void MagFed::stop_drop() {
    if (drop.use_module) {
        if (auto* ms = mag_slide()) {
            ms->cancel();
        }
    }
    drop = {};
}

inline void MagFed::update_drop() {
    if (!drop.active) {
        return;
    }
    if (drop.use_module) {
        if (auto* ms = mag_slide()) {
            ms->tick();
        }
        return;
    }
    if (!drop.joint) {
        return;
    }
    const float t = (float)(re4vr::now() - drop.t0);
    if (t > 1.0f) {
        if (shotgun(wid()) && wep.mag && wep.rest_lp) {
            set_jlp(wep.mag, *wep.rest_lp);
            if (wep.rest_lr) {
                set_jlr(wep.mag, *wep.rest_lr);
            }
        }
        drop.active = false;
        drop.joint = nullptr;
        return;
    }
    const float fall = 0.5f * cfg.gravity * t * t;
    set_jpos(drop.joint, Vector3f{drop.sx, drop.sy - fall, drop.sz});
    if (drop.sr) {
        set_jrot(drop.joint, *drop.sr);
    }
}

inline float MagFed::mag_push_dist() {
    auto lp = RE4VRShared::get()->vr_lh_ctrl_raw;
    return lp ? -lp->y : 0;
}

inline void MagFed::update_in_hand() {
    RE4VRShared::get()->re4_reload_ui_wid = wid();
    auto* joint = mag_hand.active ? mag_hand.joint : (mag_tune ? wep.mag : nullptr);
    if (!joint) {
        RE4VRShared::get()->vr_mag_hand_pose.reset();
        RE4VRShared::get()->vr_mag_hand_trx.reset();
        RE4VRShared::get()->vr_mag_hand_try.reset();
        RE4VRShared::get()->vr_mag_hand_trz.reset();
        return;
    }
    const int32_t wf = mag_hand.active && mag_hand.wid ? *mag_hand.wid : wid();
    auto& m = mh_of(wf);
    std::string mp = mag_pose.contains(wid()) ? mag_pose[wid()] : cfg.mag_hold_pose;
    set_pose_name("__vr_mag_hand_pose", mp);
    RE4VRShared::get()->vr_mag_hand_trx = m.t_rx;
    RE4VRShared::get()->vr_mag_hand_try = m.t_ry;
    RE4VRShared::get()->vr_mag_hand_trz = m.t_rz;
    if (wid() == ss_wid && ss_wid) {
        return;
    }
    auto* lh = left_hand();
    auto hp = jpos(lh);
    if (!hp) {
        return;
    }
    auto hr = jrot(lh);
    Vector3f wp = *hp;
    if (hr) {
        wp += glm::rotate(*hr, Vector3f{m.x, m.y, m.z});
    }
    set_jpos(joint, wp);
    if (hr) {
        set_jrot(joint, glm::normalize(*hr * quat_from_euler(m.rx, m.ry, m.rz)));
    }
}

inline void MagFed::capture_rest() {
    if (!wep.mag || drop.active || mag_hand.active || mag_insert.active || mag_insert.settle) {
        return;
    }
    if (!gameplay() || seject.preview || seject.flying || mag_out) {
        return;
    }
    if (RE4VRShared::get()->re4_mag_eject_kf_preview) {
        return;
    }
    wep.rest_lp = jlp(wep.mag);
    wep.rest_lr = jlr(wep.mag);
    if (shotgun(wid()) && chamber_z.contains(wid()) && wep.tf) {
        auto jw = jpos(wep.mag);
        auto jr = jrot(wep.mag);
        auto gp = re4vr::safe([&] { return re4vr::v3(sdk::get_transform_position(wep.tf)); });
        auto gr = re4vr::safe([&] { return sdk::get_transform_rotation(wep.tf); });
        if (jw && jr && gp && gr) {
            auto cw = *jw + glm::rotate(*jr, Vector3f{0, 0, chamber_z[wid()]});
            wep.chamber_off = glm::inverse(*gr) * (cw - *gp);
        }
    }
}

inline std::optional<Vector3f> MagFed::dock_world() {
    if (auto it = dock_port.find(wid()); it != dock_port.end() && wep.tf) {
        auto* j = re4vr::joint_by_name(wep.tf, it->second.joint);
        auto jp = jpos(j);
        auto jr = jrot(j);
        if (jp && jr) {
            return *jp + glm::rotate(*jr, Vector3f{it->second.x, it->second.y, it->second.z});
        }
    }
    if (auto* ms = mag_slide(); ms && wep.tf) {
        return ms->dock_world(wep.tf, wid());
    }
    return rh_world();
}

inline bool MagFed::start_insert() {
    if (!wep.mag || !wep.rest_lp) {
        return false;
    }
    auto lp = jlp(wep.mag);
    if (!lp) {
        return false;
    }
    mag_insert.joint = wep.mag;
    mag_insert.slp = lp;
    mag_insert.slr = jlr(wep.mag);
    mag_insert.rlp = wep.rest_lp;
    mag_insert.rlr = wep.rest_lr;
    if (chamber_z.contains(wid())) {
        mag_insert.rlp = Vector3f{wep.rest_lp->x, wep.rest_lp->y, wep.rest_lp->z + chamber_z[wid()]};
    }
    auto* ms = mag_slide();
    mag_insert.keyframe = ms && ms->has_shell_keys(wid());
    mag_insert.t0 = re4vr::now();
    mag_insert.dur = cfg.insert_dur;
    if (mag_insert.keyframe && ms) {
        mag_insert.dur = ms->kf_insert_dur(wid()).value_or(ms->has_shell_keys(wid()) ? 0.40f : cfg.insert_dur);
    } else if (ms) {
        mag_insert.dur *= std::max(0.01f, ms->time_mult());
    }
    mag_insert.punch = cfg.insert_punch && !mag_insert.keyframe;
    mag_insert.manual = cfg.insert_manual && !shotgun(wid()) && !rotary_cycle.contains(wid()) && !break_action.contains(wid());
    if (insert_manual_wid.contains(wid()) && !insert_manual_wid[wid()]) {
        mag_insert.manual = false;
    }
    if (ms && mag_insert.manual && !ms->is_active()) {
        // push wids from adv
    }
    if (auto* adv = mag_slide(); adv && mag_insert.manual) {
        // only if PUSH_WIDS
        mag_insert.d0 = mag_push_dist();
        adv->start_push(wid());
        adv->begin_push_hold(wid());
    }
    mag_insert.active = true;
    mag_insert.snd = false;
    mag_insert.settle = false;
    mag_hand.active = false;
    return true;
}

inline void MagFed::finish_insert() {
    if (mag_insert.visual) {
        return;
    }
    mag_insert.active = false;
    if (auto* ms = mag_slide()) {
        ms->end_push_hold();
        ms->stop_push();
    }
    mag_out = false;
    play("mag_insert");
    if (cfg.insert_haptic > 0) {
        haptic_right(cfg.insert_haptic, 0.06f);
    }
    rack.ammo_input_t = (float)re4vr::now();
    auto* p = pe();
    const int loaded0 = p ? gun_ammo().value_or(ammo_count(live_wi()).value_or(0)) : ammo_count(live_wi()).value_or(0);
    const bool empty_chamber = loaded0 == 0 && !shotgun(wid()) && !rack.zeroed_by_us;
    if (rack.empty_when_dropped || empty_chamber) {
        rack.needs = true;
    } else {
        rack.needs = false;
        if (wep.slide && !engine_closes.contains(wid())) {
            set_jlp_z(wep.slide, sp_of(wid()).rest_z);
        }
    }
    rack.zeroed_by_us = false;
    if (shotgun(wid())) {
        if (wep.slide2 && joints.contains(wid())) {
            rack.empty_reload = loaded0 <= 0;
        }
        if (!no_reload_cycle.contains(wid()) || rack.empty_reload) {
            rack.needs = true;
        }
        if (rotary_cycle.contains(wid())) {
            rot.pending = true;
        } else {
            int add = 1;
            auto* wi = live_wi();
            const int cap = wi ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(wi, "get_CurrentAmmoMax"); }).value_or(0) : 0;
            const int loaded = ammo_count(wi).value_or(0);
            const int rsv = reserve_of(wi);
            const int ratio = (int)std::max(1.0f, shotgun_ratio_wid.contains(wid()) ? shotgun_ratio_wid[wid()] : cfg.shotgun_ratio);
            add = std::min({ratio, std::max(0, cap - loaded), rsv});
            if (add > 0 && cfg.reload_ammo) {
                load_and_book(add);
            }
        }
    } else if (cfg.reload_ammo) {
        auto* wi = live_wi();
        const int cap = wi ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(wi, "get_CurrentAmmoMax"); }).value_or(0) : 0;
        const int rsv = reserve_of(wi);
        const int carry = mag_retained;
        mag_retained = 0;
        const int target = std::min(cap, carry + rsv);
        const int cur = ammo_count(wi).value_or(0);
        const int add = std::max(0, target - cur);
        if (add > 0) {
            load_and_book(add);
        }
    }
    if (cfg.insert_punch && mag_insert.rlp && mag_insert.joint) {
        mag_insert.settle = true;
        mag_insert.settle_t0 = re4vr::now();
        auto axis = *mag_insert.rlp - mag_insert.slp.value_or(*mag_insert.rlp);
        auto n = glm::length(axis);
        if (n > 1e-6f) {
            axis /= n;
        }
        mag_insert.olp = *mag_insert.rlp + axis * cfg.insert_overshoot;
        set_jlp(mag_insert.joint, *mag_insert.olp);
    }
}

inline void MagFed::update_insert() {
    if (mag_insert.settle && mag_insert.joint) {
        float st = (float)(re4vr::now() - mag_insert.settle_t0) / std::max(cfg.insert_settle, 0.01f);
        if (st >= 1.0f) {
            st = 1.0f;
            if (!mag_insert.visual) {
                mag_insert.settle = false;
            }
        }
        if (mag_insert.olp && mag_insert.rlp) {
            const float u = ease(st);
            set_jlp(mag_insert.joint, *mag_insert.olp + (*mag_insert.rlp - *mag_insert.olp) * u);
        }
    }
    if (!mag_insert.active || !mag_insert.joint) {
        return;
    }
    float t = (float)(re4vr::now() - mag_insert.t0) / std::max(mag_insert.dur, 0.01f);
    if (mag_insert.manual) {
        const float d = mag_push_dist();
        if (mag_insert.d0) {
            const float travel = std::max(cfg.insert_travel, 0.01f);
            t = (*mag_insert.d0 - d) / travel;
            if (t < -cfg.insert_back_out / travel) {
                mag_insert.active = false;
                mag_hand.active = true;
                mag_hand.joint = wep.mag;
                mag_hand.wid = wep.wid;
                mag_hand.redock_d = true;
                if (auto* ms = mag_slide()) {
                    ms->end_push_hold();
                    ms->stop_push();
                }
                return;
            }
            if (t >= cfg.insert_snap_at && t < 1.0f) {
                t = 1.0f;
            }
        }
    }
    t = std::clamp(t, 0.0f, 1.0f);
    auto* ms = mag_slide();
    if (mag_insert.keyframe && ms && wep.tf) {
        const bool rev = ms->uses_rev_insert(wid()) && ms->has_eject_keys(wid());
        if (rev) {
            ms->apply_eject_keys(wep.tf, mag_insert.joint, wid(), 1.0f - t);
        } else {
            ms->apply_shell_keys(wep.tf, mag_insert.joint, wid(), t);
        }
    } else if (mag_insert.slp && mag_insert.rlp) {
        float u = mag_insert.punch ? (t * t) : ease(t);
        auto p = *mag_insert.slp + (*mag_insert.rlp - *mag_insert.slp) * u;
        set_jlp(mag_insert.joint, p);
        if (mag_insert.slr && mag_insert.rlr) {
            auto a = *mag_insert.slr;
            auto b = *mag_insert.rlr;
            if (glm::dot(a, b) < 0) {
                b = -b;
            }
            set_jlr(mag_insert.joint, glm::normalize(a + (b - a) * u));
        }
    }
    if (!mag_insert.visual && t >= 1.0f) {
        finish_insert();
    }
}

inline void MagFed::check_proximity() {
    if (!mag_hand.active) {
        return;
    }
    auto* lh = left_hand();
    auto hp = jpos(lh);
    auto gp = dock_world();
    if (!hp || !gp) {
        return;
    }
    const float d = glm::length(*hp - *gp);
    mag_hand.dist = d;
    auto c = cat_of(wid());
    float idist = insert_dist_wid.contains(wid()) ? insert_dist_wid[wid()] : (insert_dist.contains(c) ? insert_dist[c] : 0.15f);
    if (mag_hand.redock_d) {
        if (*mag_hand.redock_d < 0) {
            mag_hand.redock_d = d;
            return;
        }
        if (d > idist) {
            mag_hand.redock_d.reset();
        } else if (d <= *mag_hand.redock_d - cfg.insert_redock) {
            mag_hand.redock_d.reset();
        } else {
            return;
        }
    }
    if (d <= idist) {
        mag_hand.active = false;
        start_insert();
    }
}

inline bool MagFed::mag_to_hand() {
    if (!wep.mag) {
        return false;
    }
    stop_drop();
    mag_insert = {};
    mag_tune = false;
    mag_hand.active = true;
    mag_hand.joint = wep.mag;
    mag_hand.wid = wep.wid;
    mag_hand.redock_d.reset();
    return true;
}
inline bool MagFed::drop_simple() {
    auto p = jpos(wep.mag);
    if (!p) {
        return false;
    }
    drop.joint = wep.mag;
    drop.use_module = false;
    drop.sx = p->x;
    drop.sy = p->y;
    drop.sz = p->z;
    drop.sr = jrot(wep.mag);
    drop.t0 = re4vr::now();
    drop.active = true;
    return true;
}

inline bool MagFed::force_eject() {
    if (unlimited()) {
        return false;
    }
    refresh();
    if (!wep.mag || mag_out) {
        return false;
    }
    if (reserve_of(live_wi()) <= 0) {
        return false;
    }
    auto* p = pe();
    auto ga = p ? gun_ammo() : std::nullopt;
    rack.empty_when_dropped = ga ? (*ga == 0) : (live_loaded() == 0);
    if (RE4VRShared::get()->re4_mag_carry.value_or(0) > 0) {
        rack.empty_when_dropped = false;
    }
    rack.chambered_hold = false;
    stop_drop();
    mag_hand.active = false;
    mag_insert = {};
    mag_tune = false;
    if (wep.rest_lp) {
        set_jlp(wep.mag, *wep.rest_lp);
    }
    if (wep.rest_lr) {
        set_jlr(wep.mag, *wep.rest_lr);
    }
    const bool started = start_drop();
    if (started) {
        mag_out = true;
        play("mag_eject");
        mag_floor_at = re4vr::now() + cfg.mag_floor_delay;
    }
    return started;
}

inline int MagFed::live_loaded() {
    return ammo_count(live_wi()).value_or(0);
}

inline void MagFed::clear_rack() {
    const bool was_er = rack.empty_reload;
    rack.empty_reload = false;
    if (was_er && wep.slide2) {
        set_jlp_z(wep.slide2, sp2_of(wid()).rest_z);
    }
    rack.needs = false;
    rack.grab_active = false;
    rack.pulled = false;
    rack.pushed = false;
    rack.frac = 0;
    RE4VRShared::get()->vr_needs_rack = false;
    RE4VRShared::get()->vr_block_fire_when_empty = false;
    RE4VRShared::get()->vr_rack_block_left_knife = false;
    auto* p = pe();
    auto* g = p ? re4vr::safe([&] { return utility::re_managed_object::get_field<::REManagedObject*>(p, "WeaponList"); }).value_or(nullptr) : nullptr;
    (void)g;
    if (engine_closes.contains(wid()) || rotary_cycle.contains(wid())) {
        rack.chambered_hold = false;
        rack.prev_gun_ammo.reset();
        return;
    }
    rack.chambered_hold = true;
    rack.prev_gun_ammo.reset();
    if (wep.slide) {
        set_jlp_z(wep.slide, sp_of(wid()).rest_z);
    }
}

inline void MagFed::update_rack_state() {
    if (rack.tuning) {
        return;
    }
    if (!handled()) {
        rack.empty = false;
        if (rack.needs) {
            clear_rack();
        }
        return;
    }
    const int loaded = live_loaded();
    rack.has_mag = loaded > 0;
    auto* p = pe();
    rack.empty = p && re4vr::safe([&] { return sdk::call_object_func_easy<bool>(p, "isGunAmmoEmpty"); }).value_or(false);
    if (rack.chambered_hold) {
        auto ga = p ? gun_ammo() : std::nullopt;
        if (chamber_hold_persist.contains(wid())) {
            if (rack.empty) {
                rack.chambered_hold = false;
            }
        } else if (ga && rack.prev_gun_ammo && *ga < *rack.prev_gun_ammo) {
            rack.chambered_hold = false;
        }
        rack.prev_gun_ammo = ga;
    }
    if (shotgun(wid())) {
        const int seq = (int)RE4VRShared::get()->vr_shot_seq.value_or(0);
        if (rack.prev_shot_seq && seq > *rack.prev_shot_seq && rack.has_mag && !no_cycle_after.contains(wid())) {
            rack.needs = true;
        }
        rack.prev_shot_seq = seq;
    }
    RE4VRShared::get()->vr_needs_rack = rack.needs && !shotgun(wid());
    RE4VRShared::get()->vr_slide_rack_active = rack.grab_active;
    const bool flow = !mag_present();
    bool block = false;
    if (break_action.contains(wid())) {
        block = brk.open || mag_hand.active || mag_insert.active;
        RE4VRShared::get()->vr_break_open = brk.open;
    } else if (rotary_cycle.contains(wid())) {
        block = rack.needs || mag_hand.active || mag_insert.active;
    } else {
        block = (rack.needs && cfg.rack_enabled) || mag_out || flow || (rack.empty && cfg.rack_enabled);
        if (no_reload_cycle.contains(wid()) && rack.empty_reload) {
            block = true;
        }
    }
    RE4VRShared::get()->vr_block_fire_when_empty = block;
    RE4VRShared::get()->vr_shotgun_pump_active = shotgun(wid()) && rack.grab_active;
    RE4VRShared::get()->vr_rack_block_left_knife = rack.needs || rack.grab_active;
    RE4VRShared::get()->vr_block_two_hand = rot.grip_latched;
}

inline void MagFed::update_rack_gesture() {
    if (rotary_cycle.contains(wid()) || break_action.contains(wid())) {
        return;
    }
    if (no_reload_cycle.contains(wid()) && rack.needs && !rack.empty_reload) {
        return;
    }
    auto* sj = rack_j();
    auto hp = shotgun(wid()) ? (RE4VRShared::get()->vr_lh_ctrl_world ? RE4VRShared::get()->vr_lh_ctrl_world : lh_world()) : lh_world();
    auto sp = jpos(sj);
    const bool grip = left_grip();
    rack.last_grip = grip;
    rack.last_dist = (hp && sp) ? glm::length(*hp - *sp) : -1;
    if (!sj || !hp || !sp) {
        return;
    }
    if (!rack.grab_active) {
        if (mag_hand.active || mag_insert.active) {
            rack.armed = false;
            rack.pump_init.reset();
            return;
        }
        if (!shotgun(wid()) && rack.ammo_input_t && (re4vr::now() - *rack.ammo_input_t) < 0.2) {
            rack.armed = false;
            return;
        }
        if (shotgun(wid()) && !rack.empty_reload && !no_reload_cycle.contains(wid())) {
            if (grip && rack.last_dist >= 0 && rack.last_dist <= cfg.rack_grab_dist) {
                auto rhp = rh_world();
                auto dist = rhp ? glm::length(*hp - *rhp) : 0.f;
                if (!rack.pump_init) {
                    rack.pump_init = dist;
                }
                float pull = rack.pump_init ? (*rack.pump_init - dist) : 0;
                if (pull < 0) {
                    rack.pump_init = dist;
                    pull = 0;
                }
                if (pull > cfg.pump_start_pull) {
                    rack.grab_active = true;
                    rack.armed = false;
                    rack.pulled = false;
                    rack.pushed = false;
                    rack.frac = 0;
                    rack.gx = hp->x;
                    rack.gy = hp->y;
                    rack.gz = hp->z;
                    rack.pump_init = dist;
                    rack.pump_max = 0;
                    rack_haptic(0.25f, 0.03f);
                    auto shp = RE4VRShared::get()->vr_support_hand_world_pos;
                    auto srot = jrot(sj);
                    if (shp && srot) {
                        rack.pump_off = glm::inverse(*srot) * (*shp - *sp);
                    }
                }
            } else {
                rack.pump_init.reset();
            }
            return;
        }
        if (!grip) {
            rack.armed = true;
            return;
        }
        if (!rack.armed) {
            return;
        }
        if (rack.last_dist >= 0 && rack.last_dist <= cfg.rack_grab_dist) {
            rack.grab_active = true;
            rack.armed = false;
            rack.pulled = false;
            rack.pushed = false;
            rack.frac = 0;
            auto hpr = RE4VRShared::get()->vr_lh_ctrl_world.value_or(*hp);
            rack.gx = hpr.x;
            rack.gy = hpr.y;
            rack.gz = hpr.z;
            auto rhr = RE4VRShared::get()->vr_rh_ctrl_raw ? RE4VRShared::get()->vr_rh_ctrl_raw : rh_world();
            if (rhr) {
                rack.rgx = rhr->x;
                rack.rgy = rhr->y;
                rack.rgz = rhr->z;
            }
            auto srot = jrot(sj);
            if (srot) {
                auto rel = glm::inverse(*srot) * (*hp - *sp);
                rack.g_relz = rel.z;
                rack.pose_side = rack.dock_tune ? rack.pose_side : false;
                if (!rack.dock_tune && wid() != 4501) {
                    const float ang = glm::degrees(std::atan2(std::abs(rel.x), -rel.z));
                    rack.pose_side = ang >= cfg.rack_pose_side_deg;
                }
            }
            rack_haptic(0.25f, 0.03f);
        }
        return;
    }
    auto pose = rack_sp();
    const float travel = std::max(std::abs(pose.back_z - pose.park_z), 0.005f);
    if (grip) {
        float pull = 0;
        if (shotgun(wid()) && rack.pump_init) {
            auto rhp = rh_world();
            auto hpr = RE4VRShared::get()->vr_lh_ctrl_world.value_or(*hp);
            if (rhp) {
                const float dist = glm::length(hpr - *rhp);
                pull = *rack.pump_init - dist;
                if (!rack.pulled && pull < 0) {
                    rack.pump_init = dist;
                    pull = 0;
                    rack.pump_max = 0;
                }
                pull = std::max(0.f, pull);
                rack.pump_max = std::max(rack.pump_max.value_or(0), pull);
            }
        } else {
            auto hpr = RE4VRShared::get()->vr_lh_ctrl_world.value_or(*hp);
            Vector3f delta{hpr.x - rack.gx, hpr.y - rack.gy, hpr.z - rack.gz};
            if (rack.rgx && RE4VRShared::get()->vr_rh_ctrl_raw) {
                auto rh = *RE4VRShared::get()->vr_rh_ctrl_raw;
                delta -= Vector3f{rh.x - *rack.rgx, rh.y - *rack.rgy, rh.z - *rack.rgz};
            }
            auto srot = jrot(sj);
            if (srot) {
                auto rel = glm::inverse(*srot) * delta;
                pull = shotgun(wid()) ? -rel.z : std::max(0.f, -rel.z);
            }
        }
        rack.frac = std::clamp(pull / travel, 0.f, 1.f);
        if (rack.frac >= 0.98f && !rack.pulled) {
            rack.pulled = true;
            queue_haptic(0.9f, 0.06f);
            play("slide_back");
        }
        if (shotgun(wid()) && rack.pulled && rack.pump_max) {
            auto rhp = rh_world();
            auto hpr = RE4VRShared::get()->vr_lh_ctrl_world.value_or(*hp);
            if (rhp && rack.pump_init) {
                const float dist = glm::length(hpr - *rhp);
                const float from_max = *rack.pump_max - std::max(0.f, *rack.pump_init - dist);
                if (from_max >= travel * cfg.pump_push_frac) {
                    rack.pushed = true;
                }
            }
        }
        return;
    }
    // release
    if (shotgun(wid()) && !rack.empty_reload) {
        if (rack.pulled && rack.pushed) {
            queue_haptic(0.7f, 0.05f);
            play("slide_back");
            clear_rack();
        } else {
            rack.grab_active = false;
            rack.frac = 0;
            rack.pulled = false;
            rack.pushed = false;
        }
        return;
    }
    if (rack.pulled) {
        queue_haptic(0.9f, 0.06f);
        play("slide_back");
        clear_rack();
    } else {
        rack.grab_active = false;
        rack.frac = 0;
    }
}

inline void MagFed::update_rotary() {
    if (!rotary_cycle.contains(wid())) {
        rot.prog = 0;
        return;
    }
    const bool trig = left_trigger();
    if (rack.needs && trig && !rot.prev_trig) {
        rot.dir = 1;
    }
    rot.prev_trig = trig;
    auto& rc = rotary[wid()];
    if (rot.dir > 0) {
        rot.prog = std::min(1.f, rot.prog + rc.lerp);
        if (rot.prog >= 0.98f) {
            if (rot.pending && cfg.reload_ammo) {
                auto* wi = live_wi();
                const int cap = wi ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(wi, "get_CurrentAmmoMax"); }).value_or(0) : 0;
                const int loaded = ammo_count(wi).value_or(0);
                const int rsv = reserve_of(wi);
                const int ratio = (int)std::max(1.0f, shotgun_ratio_wid.contains(wid()) ? shotgun_ratio_wid[wid()] : cfg.shotgun_ratio);
                const int add = std::min({ratio, std::max(0, cap - loaded), rsv});
                if (add > 0) {
                    load_and_book(add);
                }
                rot.pending = false;
            }
            play("cycle");
            clear_rack();
            rot.dir = -1;
        }
    } else if (rot.dir < 0) {
        rot.prog = std::max(0.f, rot.prog - rc.lerp);
        if (rot.prog <= 0.001f) {
            rot.dir = 0;
            rot.prog = 0;
        }
    }
}

inline void MagFed::update_break() {
    if (!break_action.contains(wid())) {
        return;
    }
    const bool b = right_b();
    if (b && !brk.prev_b) {
        brk.open = !brk.open;
        play("break_open");
    }
    brk.prev_b = b;
    const float lerp = rotary.contains(wid()) ? rotary[wid()].lerp : 0.12f;
    const float want = brk.open ? 1.f : 0.f;
    if (brk.prog < want) {
        brk.prog = std::min(want, brk.prog + lerp);
    } else {
        brk.prog = std::max(want, brk.prog - lerp);
    }
    RE4VRShared::get()->vr_break_open = brk.open;
}

inline void MagFed::update_dock_blend() {
    const float want = ((rack.grab_active || rack.dock_tune) && wep.slide) ? 1.f : 0.f;
    float b = rack.dock_blend;
    constexpr float spd = 0.10f;
    if (b < want) {
        b = std::min(b + spd, want);
    } else if (b > want) {
        float down = shotgun(wid()) ? 0.30f : spd;
        if (rotary_cycle.contains(wid())) {
            down = 1.f;
        }
        b = std::max(b - down, want);
    }
    rack.dock_blend = b;
    RE4VRShared::get()->vr_slide_dock_blend_factor = ease(b);
}

inline bool MagFed::publish_push_dock() {
    auto* ms = mag_slide();
    if (!ms || !wep.mag || rack.dock_blend > 0.001f) {
        return false;
    }
    const float b = ms->push_blend();
    if (b <= 0.001f) {
        return false;
    }
    auto p = jpos(wep.mag);
    auto r = jrot(wep.mag);
    if (!p || !r) {
        return false;
    }
    float ox, oy, oz;
    ms->push_pos(wid(), ox, oy, oz);
    *p += glm::rotate(*r, Vector3f{ox, oy, oz});
    (void)b;
    // rotation offsets from push
    RE4VRShared::get()->vr_slide_hand_world_pos = *p;
    RE4VRShared::get()->vr_slide_hand_world_rot = *r;
    RE4VRShared::get()->vr_slide_dock_blend_factor = b;
    rack.pushdock_was = true;
    return true;
}

inline void MagFed::publish_dock() {
    auto* rj = rack_j();
    if (rack.dock_blend > 0.001f && rj) {
        auto p = jpos(rj);
        auto r = jrot(rj);
        auto sd = rack_sp();
        if (shotgun(wid()) && rack.pump_off && !rotary_cycle.contains(wid())) {
            if (p && r) {
                *p += glm::rotate(*r, *rack.pump_off);
            }
            if (auto srot = RE4VRShared::get()->vr_support_hand_world_rot) {
                r = srot;
            }
        } else {
            float dX = sd.dock_x, dY = sd.dock_y, dZ = sd.dock_z, rX = sd.rack_rx, rY = sd.rack_ry, rZ = sd.rack_rz;
            if (rack.pose_side && !rack.empty_reload && cat_of(wid()) == "pistols") {
                dX = sd.sdock_x;
                dY = sd.sdock_y;
                dZ = sd.sdock_z;
                rX = sd.srack_rx;
                rY = sd.srack_ry;
                rZ = sd.srack_rz;
            }
            if (p && r && (dX || dY || dZ)) {
                *p += glm::rotate(*r, Vector3f{dX, dY, dZ});
            }
            if (r && (rX || rY || rZ)) {
                r = glm::normalize(*r * quat_from_euler(rX, rY, rZ));
            }
        }
        if (p) {
            RE4VRShared::get()->vr_slide_hand_world_pos = *p;
        }
        if (r) {
            RE4VRShared::get()->vr_slide_hand_world_rot = *r;
        }
        return;
    }
    if (!publish_push_dock()) {
        if (rack.pushdock_was) {
            RE4VRShared::get()->re4_reload_lexit_t = re4vr::now();
            rack.pushdock_was = false;
        }
        RE4VRShared::get()->vr_slide_hand_world_pos.reset();
        RE4VRShared::get()->vr_slide_hand_world_rot.reset();
        RE4VRShared::get()->vr_slide_dock_blend_factor = 0;
    }
}

inline void MagFed::apply_slide_park() {
    if (top_loader.contains(wid()) || rotary_cycle.contains(wid()) || break_action.contains(wid())) {
        return;
    }
    if (shotgun(wid())) {
        if (rack.empty_reload) {
            if (wep.slide) {
                set_jlp_z(wep.slide, sp_of(wid()).rest_z);
            }
        } else if (!(rack.grab_active || rack.tuning)) {
            if (wep.slide) {
                set_jlp_z(wep.slide, sp_of(wid()).rest_z);
            }
            return;
        }
    }
    bool chambered_idle = false;
    if (!engine_closes.contains(wid()) && !(rack.needs || rack.grab_active || rack.tuning || mag_out || rack.empty || rack.empty_when_dropped || rack.empty_reload)) {
        auto ga = gun_ammo();
        if (ga && *ga > 0) {
            chambered_idle = true;
        }
    }
    if (!(rack.empty || mag_out || rack.needs || rack.grab_active || rack.tuning || rack.chambered_hold || chambered_idle)) {
        return;
    }
    auto* sj = rack_j();
    if (!sj) {
        return;
    }
    auto sp = rack_sp();
    float z = sp.rest_z;
    if (rack.tuning) {
        z = sp.park_z + (sp.back_z - sp.park_z) * rack.tune_frac;
    } else if (rack.grab_active) {
        z = sp.park_z + (sp.back_z - sp.park_z) * rack.frac;
    } else if (rack.chambered_hold) {
        if (engine_closes.contains(wid())) {
            return;
        }
        z = sp.rest_z;
    } else if (chambered_idle) {
        z = sp.rest_z;
    } else if (rack.needs || rack.empty_when_dropped || rack.empty) {
        z = sp.park_z;
    } else {
        if (engine_closes.contains(wid())) {
            return;
        }
        z = sp.rest_z;
    }
    set_jlp_z(sj, z);
}

inline void MagFed::apply_shell_eject() {
    if (!shotgun(wid()) || !wep.mag || !wep.rest_lp) {
        return;
    }
    if (!(seject.preview || seject.flying)) {
        return;
    }
    auto& s = se_of(wid());
    Vector3f p = *wep.rest_lp + Vector3f{s.sx, s.sy, s.sz};
    float spin = 0;
    if (seject.flying) {
        p.x += s.vx * seject.t;
        p.y += s.vy * seject.t - 0.5f * s.grav * seject.t * seject.t;
        p.z += s.vz * seject.t;
        spin = s.spin * seject.t;
    }
    set_jlp(wep.mag, p);
    if (wep.rest_lr) {
        set_jlr(wep.mag, glm::normalize(*wep.rest_lr * quat_from_euler(s.srx + spin, s.sry, s.srz)));
    }
}
inline void MagFed::update_shell_eject() {
    if (!shotgun(wid())) {
        seject.flying = false;
        seject.prev_pulled = false;
        return;
    }
    const double now = re4vr::now();
    float dt = (float)(now - seject.last_clock);
    seject.last_clock = now;
    if (dt < 0 || dt > 0.1f) {
        dt = 0.016f;
    }
    if (rack.pulled && !seject.prev_pulled && !seject.preview && pump_one_out()) {
        seject.flying = true;
        seject.t = 0;
    }
    seject.prev_pulled = rack.pulled;
    if (seject.flying) {
        seject.t += dt;
        if (seject.t >= se_of(wid()).dur) {
            seject.flying = false;
        }
    }
}
inline bool MagFed::pump_one_out() {
    return live_loaded() > 0;
}

inline void MagFed::apply_mag_hidden() {
    if (mag_out && wep.mag && !mag_hand.active && !mag_insert.active && !drop.active) {
        set_scale(wep.mag, 0);
    } else if (wep.mag && !shotgun(wid())) {
        set_scale(wep.mag, 1);
    }
}

inline void MagFed::apply_rack_pose() {
    std::string name;
    if (rack.grab_active || rack.dock_tune) {
        if (rack.empty_reload && rack_pose_empty.contains(wid())) {
            name = rack_pose_empty[wid()];
        } else if (rack.pose_side && cat_of(wid()) == "pistols") {
            name = cfg.rack_pose_side;
        } else if (rack_pose.contains(wid())) {
            name = rack_pose[wid()];
        } else {
            name = cfg.rack_pose;
        }
    }
    set_pose_name("__vr_rack_hand_pose", name);
    if (!name.empty() && poses.contains(name)) {
        re4vr::apply_pose_bones(poses[name], 1.0f);
    }
}

inline void MagFed::sg_force_parts(bool on) {
    if (!shotgun(wid()) || !wep.tf) {
        return;
    }
    auto* mesh = mesh_of(go_of(wep.tf));
    if (!mesh) {
        return;
    }
    // keep shell part visible when carrying
    (void)on;
}

inline void MagFed::ss_destroy() {
    if (ss.obj) {
        re4vr::destroy_game_object((::REManagedObject*)ss.obj);
    }
    ss.obj = nullptr;
    ss.mesh = nullptr;
    ss.parented = false;
    ss.parts_sig.clear();
}
inline bool MagFed::ss_spawn() {
    auto [go_src, tf_src] = find_weapon(ss_wid);
    auto* gmesh = go_src ? mesh_of(go_src) : nullptr;
    if (!gmesh) {
        return false;
    }
    auto* holder = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(gmesh, "getMesh"); }).value_or(nullptr);
    auto* go = re4vr::create_game_object("vr_ss_shell");
    if (!go || !holder) {
        return false;
    }
    re4vr::pcall([&] { utility::re_managed_object::add_ref(go); });
    auto* mesh = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(go, "createComponent(System.Type)", re4vr::runtime_type("via.render.Mesh")); }).value_or(nullptr);
    if (!mesh) {
        return false;
    }
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "setMesh", holder); });
    re4vr::pcall([&] { sdk::call_object_func_easy<void*>(mesh, "set_Enabled", true); });
    ss.obj = go;
    ss.mesh = mesh;
    auto* ctf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr);
    auto* bt = body_tf();
    ss.parented = false;
    if (ctf && bt) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(ctf, "set_Parent", bt); });
        if (re4vr::pcall([&] { sdk::call_object_func_easy<void*>(ctf, "set_ParentJoint", sdk::VM::create_managed_string(L"L_Hand")); })) {
            ss.parented = true;
        }
    }
    return true;
}
inline void MagFed::ss_place() {
    if (!ss.obj) {
        return;
    }
    auto* tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(ss.obj, "get_Transform"); }).value_or(nullptr);
    if (!tf) {
        return;
    }
    if (ss.parented) {
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(tf, "set_LocalPosition", Vector3f{ss.x, ss.y, ss.z}); });
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(tf, "set_LocalRotation", quat_from_euler(ss.rx, ss.ry, ss.rz)); });
        re4vr::pcall([&] { sdk::call_object_func_easy<void*>(tf, "set_LocalScale", Vector3f{ss.scale, ss.scale, ss.scale}); });
        return;
    }
    auto* lh = left_hand();
    auto hp = jpos(lh);
    auto hr = jrot(lh);
    if (!hp) {
        return;
    }
    Vector3f wp = *hp;
    if (hr) {
        wp += glm::rotate(*hr, Vector3f{ss.x, ss.y, ss.z});
    }
    sdk::set_transform_position(tf, re4vr::v4(wp), true);
    if (hr) {
        sdk::set_transform_rotation(tf, glm::normalize(*hr * quat_from_euler(ss.rx, ss.ry, ss.rz)));
    }
}
inline void MagFed::apply_ss() {
    if (!cfg.enabled || wid() != ss_wid || !ss_wid) {
        if (ss.obj) {
            ss_destroy();
        }
        return;
    }
    const bool show = mag_hand.active || ss.preview;
    if (!show) {
        if (ss.obj) {
            ss_destroy();
        }
        return;
    }
    if (!ss.obj && !ss_spawn()) {
        return;
    }
    if (ss.mesh) {
        const std::string sig = "part:" + std::to_string(ss.part);
        if (ss.parts_sig != sig) {
            mesh_parts(ss.mesh, ss.part, true);
            ss.parts_sig = sig;
        }
    }
    ss_place();
}
inline void MagFed::apply_ss_late() {
    if (ss.obj && wid() == ss_wid && (mag_hand.active || ss.preview)) {
        ss_place();
    }
}
inline void MagFed::apply_ss_insert_visual() {
    if (wid() == ss_wid && ss_wid && mag_insert.active) {
        mag_insert.visual = true;
        update_insert();
        mag_insert.visual = false;
    }
}

inline void MagFed::reset_reload() {
    stop_drop();
    mag_hand = {};
    mag_insert = {};
    mag_tune = false;
    rack.grab_active = false;
    rack.pulled = false;
    rack.pushed = false;
    rack.frac = 0;
    rack.has_mag = false;
    rack.empty_when_dropped = false;
    rack.zeroed_by_us = false;
    rack.empty_reload = false;
    rot = {};
    brk = {};
    RE4VRShared::get()->vr_block_two_hand = false;
    RE4VRShared::get()->vr_break_open = false;
    rack.chambered_hold = false;
    rack.prev_shot_seq.reset();
    RE4VRShared::get()->vr_block_fire_when_empty = false;
    RE4VRShared::get()->vr_needs_rack = false;
    RE4VRShared::get()->vr_shotgun_pump_active = false;
    RE4VRShared::get()->vr_rack_block_left_knife = false;
    RE4VRShared::get()->vr_manual_reload_consume_b = false;
    RE4VRShared::get()->vr_slide_hand_world_pos.reset();
    RE4VRShared::get()->vr_slide_hand_world_rot.reset();
    RE4VRShared::get()->vr_slide_dock_blend_factor = 0;
    rack.dock_blend = 0;
    RE4VRShared::get()->vr_rack_hand_pose.reset();
    RE4VRShared::get()->re4_live_wi = nullptr;
}

inline void MagFed::clear_globals() {
    managed = false;
    RE4VRShared::get()->vr_manual_reload_consume_b = false;
    RE4VRShared::get()->vr_block_fire_when_empty = false;
    RE4VRShared::get()->vr_needs_rack = false;
    RE4VRShared::get()->vr_rack_block_left_knife = false;
    RE4VRShared::get()->vr_rack_hand_pose.reset();
    RE4VRShared::get()->re4_reload_grab_empty = false;
    RE4VRShared::get()->vr_motion_paused = false;
    if (dlc) {
        RE4VRShared::get()->vr_mag_hand_pose.reset();
        RE4VRShared::get()->vr_mag_hand_trx.reset();
        RE4VRShared::get()->vr_mag_hand_try.reset();
        RE4VRShared::get()->vr_mag_hand_trz.reset();
    }
}

inline void MagFed::reset() {
    reset_reload();
    clear_globals();
    mag_out = false;
    mag_retained = 0;
    last_handled.reset();
    ss_destroy();
}

inline bool MagFed::set_mag_in_hand(bool active) {
    mag_hand.grip_held = active;
    if (active) {
        if (!managed) {
            return false;
        }
        if (shotgun(wid())) {
            if (rotary_cycle.contains(wid()) && rack.needs) {
                return false;
            }
            if (break_action.contains(wid()) && !brk.open) {
                return false;
            }
            auto* wi = live_wi();
            const int lo = ammo_count(wi).value_or(0);
            const int cp = wi ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(wi, "get_CurrentAmmoMax"); }).value_or(0) : 0;
            if (reserve_of(wi) <= 0 || (cp > 0 && lo >= cp)) {
                return false;
            }
            play("mag_holster");
            return mag_to_hand();
        }
        if (!mag_out) {
            return false;
        }
        play("mag_holster");
        return mag_to_hand();
    }
    if (mag_hand.active) {
        mag_hand.active = false;
        drop_simple();
    }
    return true;
}

inline void MagFed::apply_drop() {
    if (!cfg.enabled) {
        return;
    }
    check_proximity();
    update_drop();
    update_in_hand();
    update_insert();
    apply_mag_hidden();
}
inline void MagFed::apply_drop_joint() {
    if (cfg.enabled && drop.active) {
        update_drop();
    }
}
inline void MagFed::apply_slide() {
    if (!cfg.enabled) {
        return;
    }
    if (managed) {
        apply_slide_park();
        if ((rotary_cycle.contains(wid()) || break_action.contains(wid())) && wep.slide && wep.cycle_rest) {
            const float p = rotary_cycle.contains(wid()) ? rot.prog : brk.prog;
            if (p > 0.0001f) {
                auto r = rotary.contains(wid()) ? rotary[wid()] : RotaryCfg{};
                set_jlr(wep.slide, glm::normalize(*wep.cycle_rest * quat_from_euler(r.rx * p, r.ry * p, r.rz * p)));
            }
        }
        if (wep.slide2 && !rack.empty_reload && wid() == 4101) {
            set_jlp_z(wep.slide2, sp2_of(wid()).rest_z);
        }
        const bool ss_insert = (wid() == ss_wid) && mag_insert.active;
        if (wep.mag && (ss_insert || (shotgun(wid()) && wid() != ss_wid && (mag_hand.active || mag_tune || mag_insert.active)))) {
            set_scale(wep.mag, 1);
            sg_force_parts(true);
        } else {
            sg_force_parts(false);
        }
        apply_shell_eject();
        publish_dock();
        apply_rack_pose();
    }
}

inline void MagFed::on_frame() {
    if (re4vr::is_ks_active()) {
        return;
    }
    if (!cfg.enabled) {
        clear_globals();
        return;
    }
    refresh();
    auto hwid = handled();
    if (hwid != last_handled) {
        if (last_handled) {
            rack.mag_out_store[*last_handled] = mag_out;
            rack.needs_store[*last_handled] = rack.needs;
            rack.retained_store[*last_handled] = mag_retained;
            if (!hwid) {
                rack.gone_wid = last_handled;
            }
        }
        reset_reload();
        if (hwid && rack.gone_wid == hwid) {
            mag_out = false;
            rack.mag_out_store[*hwid] = false;
            mag_retained = 0;
            rack.gone_wid.reset();
        } else {
            mag_out = hwid && rack.mag_out_store.contains(*hwid) && rack.mag_out_store[*hwid];
            mag_retained = hwid && rack.retained_store.contains(*hwid) ? rack.retained_store[*hwid] : 0;
            if (hwid) {
                rack.gone_wid.reset();
            }
        }
        rack.needs = hwid && rack.needs_store.contains(*hwid) && rack.needs_store[*hwid];
        last_handled = hwid;
    }
    if (weapon_reacquired) {
        weapon_reacquired = false;
        if (hwid) {
            reset_reload();
            mag_out = false;
            rack.mag_out_store.clear();
            rack.needs_store.clear();
            rack.retained_store.clear();
            rack.gone_wid.reset();
            mag_retained = 0;
        }
    }
    if (!hwid) {
        clear_globals();
        if (dlc) {
            RE4VRShared::get()->re4_r4dlc_had = false;
        }
        return;
    }
    managed = true;
    if (dlc) {
        RE4VRShared::get()->re4_r4dlc_had = true;
    }
    capture_rest();
    check_proximity();
    if (auto* ms = mag_slide()) {
        // keep current mag joint for adv preview
        (void)ms;
    }
    if (drop.active && !drop.use_module && drop.joint != wep.mag) {
        stop_drop();
    }
    RE4VRShared::get()->vr_manual_reload_consume_b = !top_loader.contains(*hwid);
    if (mag_out && !mag_insert.active) {
        auto* wi = live_wi();
        if (ammo_count(wi).value_or(0) > 0) {
            drain_to_zero(wi);
        }
    }
    // grab empty flag
    if (shotgun(wid())) {
        auto* wi = live_wi();
        const int lo = ammo_count(wi).value_or(0);
        const int cp = wi ? re4vr::safe([&] { return sdk::call_object_func_easy<int32_t>(wi, "get_CurrentAmmoMax"); }).value_or(0) : 0;
        const bool full = cp > 0 && lo >= cp;
        const bool rb = rotary_cycle.contains(wid()) && rack.needs;
        const bool bb = break_action.contains(wid()) && !RE4VRShared::get()->vr_break_open;
        RE4VRShared::get()->re4_reload_grab_empty = !mag_hand.active && !mag_insert.active && (reserve_of(wi) <= 0 || full || rb || bb);
    } else {
        bool avail = false;
        if (mag_out && !mag_hand.active && !mag_insert.active) {
            avail = mag_retained > 0 || reserve_of(live_wi()) > 0;
        }
        RE4VRShared::get()->re4_reload_grab_empty = mag_out && !mag_hand.active && !mag_insert.active && !avail;
    }
    const bool b = right_b();
    if (b && !b_prev && !shotgun(wid()) && !top_loader.contains(wid()) && !break_action.contains(wid())) {
        force_eject();
    }
    if (break_action.contains(wid())) {
        update_break();
    }
    b_prev = b;
    if (drop.active && !drop_prev) {
        mag_floor_at = re4vr::now() + cfg.mag_floor_delay;
    }
    if (mag_floor_at > 0 && re4vr::now() >= mag_floor_at) {
        play("mag_floor");
        mag_floor_at = 0;
    }
    drop_prev = drop.active;
    update_rack_state();
    {
        auto det = RE4VRShared::get()->re4_damage_end_t;
        const double now = re4vr::now();
        if (det && (!rack.heal_done_t || *rack.heal_done_t != *det) && (now - *det) < 3.0 && !rack.needs && !rack.empty && !mag_out && wep.slide) {
            rack.heal_done_t = det;
            set_jlp_z(wep.slide, sp_of(wid()).rest_z);
            rack.grab_active = false;
            rack.pulled = false;
            rack.pushed = false;
            rack.frac = 0;
            rack.chambered_hold = true;
        }
    }
    update_rack_gesture();
    update_rotary();
    update_dock_blend();
    update_shell_eject();
    service_haptics();
    if (rack.empty && !empty_trig_prev && RE4VRShared::get()->vr_rt_down) {
        play("dry_fire");
    }
    empty_trig_prev = rack.empty;
    RE4VRShared::get()->vr_mag_in_hand = mag_hand.active;
    RE4VRShared::get()->re4_shotgun_ratio = shotgun_ratio_wid.contains(wid()) ? shotgun_ratio_wid[wid()] : cfg.shotgun_ratio;
}

inline void MagFed::export_globals(sol::state& lua) {
    lua["__re4_real_wi"] = [](sol::object w) -> ::REManagedObject* {
        std::optional<int32_t> want;
        if (w.is<int>()) {
            want = w.as<int>();
        } else if (w.is<double>()) {
            want = (int32_t)w.as<double>();
        }
        return real_wi(want);
    };
    lua["__re4_safe_reduce"] = [](::REManagedObject* inv, ::REManagedObject* id, sol::object n) {
        return safe_reduce(inv, id, n.is<int>() ? n.as<int>() : (n.is<double>() ? (int)n.as<double>() : 0));
    };
    lua["__re4_item_count_sum"] = [](::REManagedObject* inv, ::REManagedObject* id) { return item_count_sum(inv, id); };
    lua["__re4_item_count_sum_num"] = [](::REManagedObject* inv, sol::object n) {
        return item_count_sum_num(inv, n.is<int>() ? n.as<int>() : (n.is<double>() ? (int32_t)n.as<double>() : 0));
    };
    lua["__re4_id_num"] = [](sol::object x) -> sol::object {
        re4vr::LuaGuard g;
        auto* L = g.lua();
        if (!L) {
            return sol::nil;
        }
        if (x.is<int>()) {
            return sol::make_object(*L, x.as<int>());
        }
        if (x.is<double>()) {
            return sol::make_object(*L, (int)x.as<double>());
        }
        if (x.is<::REManagedObject*>()) {
            return sol::make_object(*L, id_num(x.as<::REManagedObject*>()));
        }
        return sol::nil;
    };
    lua["__re4_pe"] = []() { return pe(); };
    lua["__re4_live_gun"] = []() { return live_wi(); };
    lua["__re4_gun_ammo"] = []() { return gun_ammo(); };
    lua["__re4_sync_gun_ammo"] = []() { sync_gun_ammo(); };
    lua["__re4_equip_gun"] = []() {
        auto* p = pe();
        return p ? re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(p, "getEquipWeapon"); }).value_or(nullptr) : nullptr;
    };
    lua["__re4_load_and_book"] = [](::REManagedObject*, sol::object, sol::object n, sol::object) {
        return load_and_book(n.is<int>() ? n.as<int>() : (n.is<double>() ? (int)n.as<double>() : 0));
    };
    lua["__re4_safe_inv_reload"] = lua["__re4_load_and_book"];
    lua["__re4_carry_capture"] = [](::REManagedObject* wi, sol::object, sol::object) {
        auto c = ammo_count(wi).value_or(0);
        if (c > 0 && RE4VRShared::get()->re4_mag_carry.value_or(0) <= 0) {
            RE4VRShared::get()->re4_mag_carry = c;
        }
    };
    lua["__re4_run_pending_reload"] = []() {};
    lua["__re4_mag_push_dist"] = []() { auto lp = RE4VRShared::get()->vr_lh_ctrl_raw; return lp ? sol::optional<float>{-lp->y} : sol::optional<float>{}; };
    lua["__re4_shotgun_ratio_get"] = [this](sol::object w) {
        int32_t id = w.is<int>() ? w.as<int>() : (w.is<double>() ? (int32_t)w.as<double>() : 0);
        return shotgun_ratio_wid.contains(id) ? shotgun_ratio_wid[id] : cfg.shotgun_ratio;
    };
    lua["__re4_reload_apply_pose"] = [this](const std::string& name, sol::object blend) {
        float b = blend.is<double>() ? (float)blend.as<double>() : 1.f;
        RE4VRShared::get()->apply_reload_pose(name, b);
    };
    RE4VRShared::get()->apply_reload_pose_fn = [this](const std::string& name, float b) {
        if (poses.contains(name)) {
            re4vr::apply_pose_bones(poses[name], b);
        }
    };
    lua["__re4_reload_pose_names"] = [this]() {
        re4vr::LuaGuard g;
        auto* L = g.lua();
        if (!L) {
            return sol::object(sol::nil);
        }
        auto t = L->create_table();
        int i = 1;
        for (auto& [n, _] : poses) {
            t[i++] = n;
        }
        return sol::object(t);
    };
    lua["__re4_is_loop_reload"] = []() {
        auto* p = pe();
        return p && re4vr::safe([&] { return sdk::call_object_func_easy<bool>(p, "isLoopReload"); }).value_or(false);
    };
    pose_fade_export();
}

} // namespace re4vr::rl
#endif
