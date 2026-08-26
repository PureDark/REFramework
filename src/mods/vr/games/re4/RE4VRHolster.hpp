#pragma once

#if defined(RE4)
#include <functional>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <json.hpp>
#include <sdk/REMath.hpp>
#include "../../../../Mod.hpp"
#include "HookManager.hpp"

// Builtin port of scripts/re4/re4_vr_holster.lua
class RE4VRHolster : public Mod {
public:
    static std::shared_ptr<RE4VRHolster>& get();
    std::string_view get_name() const override { return "RE4VRHolster"; }

    std::optional<std::string> on_initialize() override;
    void on_lua_state_created(sol::state& lua) override;
    void on_lua_state_destroyed(sol::state& lua) override;
    void on_frame() override;
    void on_pre_application_entry(void* entry, const char* name, size_t hash) override;
    void on_application_entry(void* entry, const char* name, size_t hash) override;

    void defer(std::function<void()> fn);
    void set_suppress(bool v);
    void holster_exec();
    void holster_bare();
    void force_change_to_main();
    void play_grab_sound();

    struct Slot {
        std::string name;
        std::string path;
        std::string path_ada;
        std::string anchor_g;
        std::string zone_g;
        std::unordered_set<int32_t> ids;
        nlohmann::json cfg{nlohmann::json::object()};
        bool detached_zone{false};
        bool all_parts{false};
        ::REGameObject* clone_obj{nullptr};
        ::REManagedObject* clone_mesh{nullptr};
        ::RETransform* clone_tf{nullptr};
        ::REJoint* joint{nullptr};
        std::optional<int32_t> clone_wid{};
        uintptr_t src_addr{0};
        bool parented{false};
        bool in_use{false};
        bool has_inv{false};
        bool part0_done{false};
        bool dim_applied{false};
        std::optional<bool> last_dim{};
        std::optional<float> scale_written{};
        bool grab_in_zone{false};
        float last_dist{99.0f};
        double last_check{0};
        double inv_check_t{0};
        int32_t joint_ok_frame{-1};
        bool sm_has{false};
        Vector3f sm_p{};
        glm::quat sm_r{1, 0, 0, 0};
        struct Mat4 {
            int mi{}, vi{};
            float x{}, y{}, z{}, w{};
        };
        struct Mat1 {
            int mi{}, vi{};
            float orig{};
        };
        std::vector<Mat4> mat_dim{};
        std::vector<Mat1> mat_zero{};
    };

private:
    struct LastWep {
        int32_t wid{0};
        std::string guid;
    };
    struct AutoRedraw {
        std::optional<int32_t> snap{}; // nullopt=unknown, -1 encoded as false via snap_bare
        bool snap_bare{false};
        bool has_snap{false};
        bool suppress{false};
        double stow_until{0};
        double next_try{0};
        double pure_since{0};
        double left_pure_t{-999};
    };

    void export_globals(sol::state& lua);
    void load_slot(Slot& s, const std::string& path);
    void save_slot(Slot& s);
    void default_slot_cfg(nlohmann::json& c);
    void apply_slot(Slot& s);
    void tick_slot(Slot& s);
    void destroy_slot(Slot& s);
    bool spawn_slot(Slot& s, ::REManagedObject* mesh);
    ::REJoint* slot_joint(Slot& s);
    bool slot_dormant(const Slot& s) const;
    void apply_all();
    void grab_dispatch();
    void do_grab(Slot* best);
    Slot* nearest_with_clone();
    void mag_tick();
    void start_calibration(Slot* slot, bool left);
    void start_mag_calibration();
    bool calibrate_slot(Slot& s, const Vector3f& P);
    bool calibrate_mag(const Vector3f& P);
    void calibration_tick();
    void register_ui();
    void knife_char_tick();
    void track_last_weapons();
    void auto_redraw_tick();
    bool knife_only_stage();
    bool no_weapons_yet();
    ::REGameObject* find_weapon_go(const std::unordered_set<int32_t>& ids, std::optional<int32_t> want);
    ::REManagedObject* get_pe();
    bool has_weapon_in_inventory(const std::unordered_set<int32_t>& ids);
    std::vector<::REManagedObject*> inventory_rows(::REManagedObject* inv);
    void draw_last_pistol(::REManagedObject* pe);
    void draw_last_grenade(::REManagedObject* pe);
    void draw_last_rifle(::REManagedObject* pe);
    ::REManagedObject* find_row(::REManagedObject* inv, int32_t wid, const std::string& guid);
    std::optional<Vector3f> rh_world();
    std::optional<Vector3f> lh_world();
    bool right_grip();
    bool left_grip();
    void haptic_right(float dur, float freq, float amp);
    void haptic_left(float dur, float freq, float amp);
    void play_go_sound(::REManagedObject* go, uint32_t id);
    std::optional<int32_t> equip_wid();
    std::tuple<std::optional<bool>, bool, bool, bool> weapon_in_hand();
    ::REManagedObject* ctx();
    ::RETransform* body_tf();
    bool is_knife(int32_t id) const { return m_knife.ids.contains(id); }
    bool is_pistol(int32_t id) const { return m_pistol.ids.contains(id); }
    bool is_grenade(int32_t id) const { return m_grenade.ids.contains(id); }
    bool is_shoulder(int32_t id) const { return m_shoulder.ids.contains(id); }
    glm::quat hol_quat(float rx, float ry, float rz);
    bool hmd_basis(Vector3f& pos, Vector3f& right, Vector3f& up, Vector3f& fwd);
    ::REManagedObject* equip_type_main();
    std::string guid_to_string(::REManagedObject* g);
    void run_pending();
    bool knife_gate_skip();
    bool melee_gate_skip();

    static HookManager::PreHookResult pre_nop(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static void post_update_head(uintptr_t& ret_val, sdk::RETypeDefinition* ret_ty, uintptr_t ret_addr);
    static HookManager::PreHookResult pre_request_equip_knife(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static HookManager::PreHookResult pre_melee_gate(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static void post_nop(uintptr_t& ret_val, sdk::RETypeDefinition* ret_ty, uintptr_t ret_addr);

    Slot m_knife{};
    Slot m_pistol{};
    Slot m_grenade{};
    Slot m_shoulder{};
    std::function<void()> m_pending{};
    AutoRedraw m_ar{};
    LastWep m_last_pistol{};
    LastWep m_last_knife{};
    LastWep m_last_grenade{5400, ""};
    LastWep m_last_rifle{};
    nlohmann::json m_mag_cfg{nlohmann::json::object()};
    ::REJoint* m_mag_joint{nullptr};
    bool m_mag_in_zone{false};
    bool m_mag_holding{false};
    float m_mag_dist{99};
    std::string m_char{};
    bool m_grip_prev{false};
    bool m_press_armed{false};
    bool m_tap_mode{false};
    double m_grip_t0{0};
    double m_grab_haptic_at{0};
    float m_aim_hold{0.35f};
    int32_t m_hol_frame{0};
    double m_knife_only_t{0};
    bool m_knife_only_v{false};
    double m_nowep_t{0};
    bool m_nowep_v{false};
    bool m_lh_knife_zone{false};
    bool m_merc_body_weg{false};
    Slot* m_cal_slot{nullptr};
    double m_cal_deadline{0};
    int m_cal_last_beep{-1};
    bool m_cal_left{false};
    bool m_cal_mag{false};
    bool m_ui_registered{false};
    ::REManagedObject* m_pe{nullptr};
    ::REManagedObject* m_et_main{nullptr};
    void* m_mesh_t{nullptr};
    void* m_snd_t{nullptr};
};
#endif
