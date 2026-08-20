#pragma once

#include <chrono>
#include <bitset>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <shared_mutex>

#include <openvr.h>

#include <d3d11.h>
#include <d3d12.h>
#include <dxgi.h>
#include <wrl.h>

#include "utility/Patch.hpp"
#include "sdk/Math.hpp"
#include "sdk/helpers/NativeObject.hpp"
#include "sdk/Renderer.hpp"
#include "sdk/intrusive_ptr.hpp"
#include "vr/D3D11Component.hpp"
#include "vr/D3D12Component.hpp"
#include "vr/OverlayComponent.hpp"
#include "vr/runtimes/OpenXR.hpp"
#include "vr/runtimes/OpenVR.hpp"
#include "vr/CameraDuplicator.hpp"

#include "HookManager.hpp"

#include "Mod.hpp"

#include "PDAFWPlugin.h"

class REManagedObject;

class VR : public Mod {
public:
    CameraData cameraData[2];
    ID3D12Resource* depthTex = NULL;
    ID3D12Resource* motionVectorsTex = NULL;
    ID3D12Resource* uiBufferTex = NULL;
    D3D12RendererAPI* d3d12Renderer = nullptr;
    
    int m_camera_data_update_frame_count{};
    void update_camera_data();
    CameraData& get_camera_data(int index) { return cameraData[index]; };

public:
    enum RenderingTechnique {
        ALTERNATING, // AFR
        SEQUENTIAL_FRAME, // Two frames, synchronized
        MULTIPASS, // Native stereo rendering, single frame
        ALTERNATE_FRAME_WARPING // AFW
    };

public:
    static std::shared_ptr<VR>& get();

public:
    std::string_view get_name() const override { return "VR"; }

    // Called when the mod is initialized
    std::optional<std::string> on_initialize_d3d_thread() override;

    void on_lua_state_created(sol::state& lua) override;

    void on_pre_imgui_frame() override;
    // Laeuft innerhalb des ImGui-Frames -- dort zeichnet OverlayComponent den Zeigerpunkt.
    void on_frame() override;
    void on_present() override;
    void on_post_present() override;
    void on_update_transform(RETransform* transform) override;
    void on_update_camera_controller(RopewayPlayerCameraController* controller) override;
    bool on_pre_gui_draw_element(REComponent* gui_element, void* primitive_context) override;
    void on_gui_draw_element(REComponent* gui_element, void* primitive_context) override;
    void on_pre_update_before_lock_scene(void* ctx) override;
    void on_pre_lightshaft_draw(void* shaft, void* render_context) override;
    void on_lightshaft_draw(void* shaft, void* render_context) override;

    void on_pre_application_entry(void* entry, const char* name, size_t hash) override;
    void on_application_entry(void* entry, const char* name, size_t hash) override;

    void on_draw_ui() override;
    // Drawn by the Upscaler UI, the rendering technique lives at the end of that tree
    void draw_rendering_technique_ui();
    // Bare "Recenter View" button, drawn at the very top of the REFramework window
    // (REFramework.cpp) because the whole VR tree is hidden by the mod filter in Mods.cpp.
    void draw_recenter_button();
    // Arms the one-shot auto recenter; called at the end of both initialize_openvr/openxr.
    void arm_auto_recenter();
    // Neigung des Zeigestrahls in Grad (negativ = nach unten).
    float get_overlay_pointer_pitch() const {
        return m_overlay_pointer_pitch->value();
    }

    // [LUA 2026-08-15] Setter, damit der Wert aus einem Lua-Script kommen kann statt aus der
    // ImGui-UI -- im Headset ist ImGui nicht lesbar, eingestellt wird am Desktop bzw. per JSON.
    // Geklemmt auf denselben Bereich wie der Slider (-60 .. +60 Grad).
    void set_overlay_pointer_pitch(float deg) {
        if (deg < -60.0f) { deg = -60.0f; }
        if (deg >  60.0f) { deg =  60.0f; }
        m_overlay_pointer_pitch->value() = deg;
    }

    void on_device_reset() override;

    void on_config_load(const utility::Config& cfg) override;
    void on_config_save(utility::Config& cfg) override;

    // Application entries
    void on_pre_update_hid(void* entry);
    void on_update_hid(void* entry);
    void on_pre_begin_rendering(void* entry);
    void on_begin_rendering(void* entry);
    void on_pre_end_rendering(void* entry);
    void on_end_rendering(void* entry);
    void on_pre_wait_rendering(void* entry);
    void on_wait_rendering(void* entry);

    template<typename T = VRRuntime>
    T* get_runtime() const {
        return (T*)m_runtime.get();
    }

    auto get_hmd() const {
        return m_openvr->hmd;
    }

    auto& get_openvr_poses() const {
        return m_openvr->render_poses;
    }

    auto get_hmd_width() const {
        return get_runtime()->get_width();
    }

    auto get_hmd_height() const {
        return get_runtime()->get_height();
    }

    auto get_last_controller_update() const {
        return m_last_controller_update;
    }

    int32_t get_frame_count() const;
    int32_t get_game_frame_count() const;
    int32_t get_render_frame_count() const {
        return m_render_frame_count;
    }

    bool is_using_afr() const {
        return m_rendering_technique->value() == RenderingTechnique::ALTERNATING;
    }

    bool is_using_multipass() const {
        return m_rendering_technique->value() == RenderingTechnique::MULTIPASS;
    }

    bool is_using_afw() const {
        return m_rendering_technique->value() == RenderingTechnique::ALTERNATE_FRAME_WARPING;
    }

    RenderingTechnique get_rendering_technique() const {
        return (RenderingTechnique)m_rendering_technique->value();
    }

    // Functions that generally use a mutex or have more complex logic
    float get_standing_height();
    Vector4f get_standing_origin();
    void set_standing_origin(const Vector4f& origin);

    glm::quat get_rotation_offset();
    void set_rotation_offset(const glm::quat& offset);
    void recenter_view();

    glm::quat get_gui_rotation_offset();
    void set_gui_rotation_offset(const glm::quat& offset);
    void recenter_gui(const glm::quat& from);

    Vector4f get_current_offset();

    Matrix4x4f get_current_eye_transform(bool flip = false);
    Matrix4x4f get_current_projection_matrix(bool flip = false);
    Matrix4x4f get_projection_matrix(uint32_t pass);
    Matrix4x4f get_eye_transform(uint32_t pass);

    auto& get_controllers() const {
        return m_controllers;
    }

    bool is_using_controllers() const {
        return !m_controllers.empty() && (std::chrono::steady_clock::now() - m_last_controller_update) <= std::chrono::seconds((int32_t)m_motion_controls_inactivity_timer->value());
    }

    bool is_hmd_active() const {
        return get_runtime()->ready();
    }
    
    bool is_openvr_loaded() const {
        return m_openvr != nullptr && m_openvr->loaded;
    }

    bool is_openxr_loaded() const {
        return m_openxr != nullptr && m_openxr->loaded;
    }

    bool is_using_hmd_oriented_audio() {
        return m_hmd_oriented_audio->value();
    }

    void toggle_hmd_oriented_audio() {
        m_hmd_oriented_audio->toggle();
    }

    // "Disable GUI Projection Matrix Override" checkbox, exposed to Lua
    bool is_gui_projection_matrix_override_disabled() const {
        return m_disable_gui_camera_projection_matrix_override;
    }

    void set_gui_projection_matrix_override_disabled(bool state) {
        m_disable_gui_camera_projection_matrix_override = state;
    }

    // Stops on_pre_gui_draw_element from repositioning GUI elements in VR space (the
    // hook behind "2D UI Distance" / "World-Space UI Scale"), handing each element back
    // untouched instead.
    //
    // Belongs together with the projection override above: a screen that draws through an
    // ORTHOGRAPHIC gui camera - RE4's map does, measured live: OrthographicRH - has no
    // parallax at all, every layer sits exactly on top of the others. Keeping that matrix
    // while still placing the individual elements in space is a contradiction, and it is
    // what makes a map's markers drift against its outline. Separate flag so both halves
    // can be compared on their own.
    bool is_gui_element_override_disabled() const {
        return m_disable_gui_element_override;
    }

    void set_gui_element_override_disabled(bool state) {
        m_disable_gui_element_override = state;
    }

    // Mono rendering. Both eyes render from the same eye transform, so both displays
    // end up showing the exact same image (scopes, binoculars, map).
    bool is_mono_rendering() const {
        return m_mono_rendering;
    }

    void set_mono_rendering(bool state) {
        m_mono_rendering = state;
    }

    uint32_t get_mono_rendering_eye() const {
        return m_mono_rendering_eye;
    }

    // 0 = left eye, 1 = right eye
    void set_mono_rendering_eye(uint32_t eye) {
        m_mono_rendering_eye = eye != 0 ? 1 : 0;
    }

    // Whether mono rendering also forces the chosen eye's PROJECTION matrix onto both eyes.
    //
    // Default (false) is what you almost always want: both eyes render from the same
    // position, but each display keeps its own off-center frustum, so the two identical
    // images still line up and fuse into one flat picture.
    //
    // With this on, both displays get the same asymmetric frustum. The pixels are then
    // identical but sit laterally offset on the right panel, and the eyes can no longer
    // fuse them - the image visibly refuses to come together. Kept switchable only so
    // both variants can be compared without another rebuild.
    bool is_mono_projection() const {
        return m_mono_projection;
    }

    void set_mono_projection(bool state) {
        m_mono_projection = state;
    }

    // --- Flatscreen canvas ---------------------------------------------------
    // Shows the finished game frame as a flat quad in front of the head (a SteamVR
    // overlay) instead of stretching it across both eyes as a stereo image. While it
    // runs, all camera overrides are suspended, so the engine renders exactly what it
    // would render on a monitor - every UI layer then sits relative to the others just
    // like it does on a TV, which is something no stereo setting can achieve.
    //
    // Requirements: OpenVR and D3D12. Under OpenXR or D3D11 nothing happens at all.
    // Everything here is additive and off by default; with the flag off, not a single
    // existing code path changes.
    bool is_flatscreen_overlay() const {
        return m_flatscreen_overlay;
    }

    void set_flatscreen_overlay(bool state) {
        m_flatscreen_overlay = state;
    }

    // Width of the canvas in meters (height follows from the frame's aspect ratio).
    float get_flatscreen_overlay_width() const {
        return m_flatscreen_overlay_width;
    }

    void set_flatscreen_overlay_width(float width) {
        if (width < 0.1f) { width = 0.1f; }
        if (width > 20.0f) { width = 20.0f; }
        m_flatscreen_overlay_width = width;
    }

    // Distance of the canvas in front of the head, in meters.
    float get_flatscreen_overlay_distance() const {
        return m_flatscreen_overlay_distance;
    }

    void set_flatscreen_overlay_distance(float distance) {
        if (distance < 0.1f) { distance = 0.1f; }
        if (distance > 20.0f) { distance = 20.0f; }
        m_flatscreen_overlay_distance = distance;
    }

    // --- Suspend: echtes Flatscreen ------------------------------------------
    // Parkt saemtliche Engine-Eingriffe auf einmal: Kamera-, Projektions-, GUI-
    // Projektions- und GUI-Element-Override, die HMD-Groesse fuer den Backbuffer
    // sowie die Overlay-/PostEffect-Layer-Eingriffe. Das Spiel rendert dann so,
    // als liefe es flach -- inklusive der orthografischen GUI-Kamera, an der die
    // Karte sonst scheitert; beide Augen bekommen dasselbe Bild.
    //
    // Was BEWUSST weiterlaeuft: der Frame-Zyklus der Runtime (Submit bzw.
    // xrEndFrame). Eine Runtime, die kein Frame mehr bekommt, reprojiziert das
    // alte weiter -- das Headset wuerde einfrieren statt flach zu zeigen.
    //
    // Default false, und jede Abfrage ist ein zusaetzliches ||: solange kein
    // Script set_vr_suspended(true) ruft, ist der Code bitgleich zu vorher.
    bool is_vr_suspended() const {
        return m_vr_suspended;
    }

    void set_vr_suspended(bool state) {
        m_vr_suspended = state;
    }

    // --- RE4: Karte am Kopf festpinnen --------------------------------------
    // Messbefund 2026-08-10: on_pre_gui_draw_element heftet jede Screen-View vor die
    // SPIELKAMERA (m_original_camera_matrix) und dreht/skaliert sie aus ihrem eigenen
    // Abstand zum Render-Auge. Der Kopf bewegt sich davon unabhaengig -- deshalb driften
    // Kartenumriss, Navigationskreuz und Funde im HMD gegeneinander, obwohl die Karte am
    // Monitor korrekt aussieht (ihre GUI-Kamera ist orthografisch, dort gibt es keine
    // Parallaxe). Gui_ui3120 kam obendrein als World herein und wurde gar nicht angefasst.
    //
    // Mit diesem Flag bekommen alle sechs Karten-GUIs denselben Anker (den Kopf), dieselbe
    // Distanz und dieselbe Rotation -- sie koennen sich dann gar nicht mehr gegeneinander
    // verschieben. Default aus; bei false ist der Code bitgleich zu vorher.
    bool is_map_face_glue() const {
        return m_map_face_glue;
    }

    void set_map_face_glue(bool state) {
        m_map_face_glue = state;
    }

    // Staffelung der Karten-Ebenen in Metern (Default 2 mm). 0 = alle exakt gleich weit,
    // dann entscheidet die Zeichenreihenfolge und eine Ebene kann eine andere schlucken.
    float get_map_glue_layer_gap() const {
        return m_map_glue_layer_gap;
    }

    void set_map_glue_layer_gap(float gap) {
        if (gap < 0.0f) { gap = 0.0f; }
        if (gap > 0.05f) { gap = 0.05f; }
        m_map_glue_layer_gap = gap;
    }

    // --- Welche GUIs gepinnt werden: Liste, KEIN Hardcode --------------------
    // Frueher standen die sechs Karten-GUIs fest im Code. Jetzt ist es eine Liste
    // Name-Hash -> Reihenfolge, die ein Script zur Laufzeit fuellt: eine neue Problem-GUI
    // braucht damit kein Compile mehr, nur eine Zeile Lua. Ohne Zutun stehen die sechs
    // Karten-GUIs drin, das Verhalten bleibt also wie gehabt.
    // Die Reihenfolge (0 = am weitesten hinten) staffelt die Ebenen um `layer_gap`.
    bool is_glue_gui(uint32_t name_hash, int* order_out = nullptr);
    void set_glue_gui_hash(uint32_t name_hash, int order);
    void remove_glue_gui_hash(uint32_t name_hash);
    void clear_glue_guis();
    void reset_glue_guis();          // zurueck auf die sechs Karten-GUIs
    size_t get_glue_gui_count();

    float get_map_glue_distance() const {
        return m_map_glue_distance;
    }

    void set_map_glue_distance(float distance) {
        if (distance < 0.2f) { distance = 0.2f; }
        if (distance > 10.0f) { distance = 10.0f; }
        m_map_glue_distance = distance;
    }

    // True while the engine must be left alone (canvas mode or suspend). Deliberately
    // separate from the m_disable_*_override checkboxes so those keep whatever was set there.
    bool should_suspend_camera_overrides() const {
        return m_flatscreen_overlay || m_vr_suspended;
    }

    // Canvas mode shows the finished monitor frame on a quad in front of the head.
    // For that to look like a TV, the stereo image behind it must go away - otherwise
    // the canvas merely floats in front of a still-rendered (and, with the overrides
    // suspended, badly distorted) world. So both eyes get black while it is on.
    //
    // Black is submitted, the submit itself is NOT skipped: a runtime that gets no
    // frame starts reprojecting the previous one, which is exactly the judder we are
    // trying to avoid. The eye textures are cleared instead of filled.
    bool should_blank_all_eyes() const {
        return m_flatscreen_overlay;
    }

    // The two remaining override checkboxes, exposed so a script can reach them without
    // the VR menu (which a release build may not show at all).
    bool is_projection_matrix_override_disabled() const {
        return m_disable_projection_matrix_override;
    }

    void set_projection_matrix_override_disabled(bool state) {
        m_disable_projection_matrix_override = state;
    }

    bool is_view_matrix_override_disabled() const {
        return m_disable_view_matrix_override;
    }

    void set_view_matrix_override_disabled(bool state) {
        m_disable_view_matrix_override = state;
    }

    // --- Projection tweaks (scope zoom) --------------------------------------
    // A scope zoom is nothing but a narrow FOV on the game camera - and that FOV is
    // exactly what gets thrown away in VR, because the projection is built from the
    // headset frustum instead. These let a script put the zoom back.
    //
    // Applied to the projection we already have rather than building a new matrix, so
    // handedness, near/far and the per-eye asymmetry all survive untouched.
    //
    // zoom: factor, 1.0 = off (2.0 = twice as close).
    float get_projection_zoom() const {
        return m_projection_zoom;
    }

    void set_projection_zoom(float zoom) {
        if (zoom < 0.01f) { zoom = 0.01f; }
        if (zoom > 50.0f) { zoom = 50.0f; }
        m_projection_zoom = zoom;
    }

    // [ZOOM_STEREO] Siehe m_zoom_scales_eye_offset. Umschaltbar, um beide Varianten im
    // Spiel zu vergleichen, ohne neu zu bauen.
    bool is_zoom_scaling_eye_offset() const {
        return m_zoom_scales_eye_offset->value();
    }

    void set_zoom_scales_eye_offset(bool state) {
        m_zoom_scales_eye_offset->value() = state;
    }

    // [ZOOM_DEPTH] Siehe m_zoom_shrinks_ipd.
    bool is_zoom_shrinking_ipd() const {
        return m_zoom_shrinks_ipd->value();
    }

    void set_zoom_shrinks_ipd(bool state) {
        m_zoom_shrinks_ipd->value() = state;
    }

    // fov: vertical field of view in degrees, 0 = off. Wins over zoom when set, so a
    // script can hand over the game's own scope FOV directly.
    float get_projection_fov() const {
        return m_projection_fov;
    }

    void set_projection_fov(float fov) {
        if (fov < 0.0f) { fov = 0.0f; }
        if (fov > 179.0f) { fov = 179.0f; }
        m_projection_fov = fov;
    }

    // --- Image shift ---------------------------------------------------------
    // Moves the finished image inside the panel, applied at submit time via the
    // compositor's texture bounds.
    //
    // This is deliberately the LAST step in the chain: once the projection and the view
    // matrix are handed back to the game (scope aiming), nothing we compute upstream is
    // used any more, so a shift built into the projection has no effect at all. The
    // bounds, however, are ours in every configuration.
    //
    // Units are fractions of the image: 0.01 = one percent of its width/height.
    float get_image_shift_x() const {
        return m_image_shift_x;
    }

    void set_image_shift_x(float shift) {
        if (shift < -0.5f) { shift = -0.5f; }
        if (shift > 0.5f) { shift = 0.5f; }
        m_image_shift_x = shift;
    }

    float get_image_shift_y() const {
        return m_image_shift_y;
    }

    void set_image_shift_y(float shift) {
        if (shift < -0.5f) { shift = -0.5f; }
        if (shift > 0.5f) { shift = 0.5f; }
        m_image_shift_y = shift;
    }

    // The bounds to submit with, shift included. Sampling outside 0..1 is clamped by the
    // runtime, so the edge smears rather than wrapping - fine for the small nudges this
    // is meant for.
    vr::VRTextureBounds_t get_shifted_bounds(bool right_eye) const {
        auto bounds = right_eye ? m_right_bounds : m_left_bounds;

        bounds.uMin -= m_image_shift_x;
        bounds.uMax -= m_image_shift_x;
        bounds.vMin -= m_image_shift_y;
        bounds.vMax -= m_image_shift_y;

        return bounds;
    }

    // Blanks one eye entirely (that display gets black instead of the frame).
    // -1 = off, 0 = blank the left eye, 1 = blank the right eye.
    //
    // For a scope this is what you actually want: with both eyes fed the same image the
    // brain still tries to fuse two slightly different views of the reticle. Blacking the
    // non-aiming eye removes the conflict outright, the way closing an eye does in reality.
    // [POSE_FREEZE 2026-08-11] Blick einfrieren, ohne aus Lua hinterherzuschreiben.
    //
    // Warum im Fork und nicht im Script: das Scope-Lua neutralisiert die Kopfdrehung, indem
    // es pro Frame rotation_offset = conjugate(HMD) setzt -- aber nur an zwei Punkten
    // (Frame-Mitte und BeginRendering). Danach holt der Renderer die HMD-Pose erneut, im
    // Multipass sogar je Pass, und der Compositor bekommt zusaetzlich die frische Pose zum
    // Reprojizieren. Jede dieser Stellen sieht eine andere Kopfhaltung, und weil das
    // Scope-Bild bewusst kopfunabhaengig ist, bleibt die Differenz als Wackeln stehen --
    // sichtbar sogar am Scope-RAND, der ja bildschirmfest sein muesste.
    //
    // Mit diesem Schalter liefert die HMD-Rotation ab dem Einfrieren ueberall denselben
    // Wert: fuer jeden Renderpass, fuer die Kamera-Overrides und fuer die Pose, die an den
    // Compositor geht. Die POSITION bleibt echt -- der seitliche Augen-Versatz im Scope
    // laeuft weiter ueber standing_origin.
    bool is_pose_freeze() const {
        return m_pose_freeze;
    }

    void set_pose_freeze(bool on);

    // [POSE_FREEZE/SUBMIT 2026-08-11] Welche Pose der Compositor als "dafuer wurde
    // gerendert" bekommt, waehrend der Blick eingefroren ist. Live umschaltbar, damit die
    // Richtung im Spiel entschieden werden kann statt per Neubau:
    //   0 = wie bisher: gar keine Angabe (Runtime nimmt ihre eigene Pose an)
    //   1 = die EINGEFRORENE Pose -> Compositor dreht die Differenz nach, das Bild bleibt
    //       weltfest und wandert bei Kopfbewegung
    //   2 = die FRISCHE Pose -> Differenz ~0, der Compositor dreht nichts nach, das Bild
    //       klebt am Display; das ist es, was ein eingefrorener Blick braucht
    int32_t get_pose_freeze_submit() const {
        return m_pose_freeze_submit;
    }

    void set_pose_freeze_submit(int32_t mode) {
        m_pose_freeze_submit = (mode >= 0 && mode <= 2) ? mode : 0;

        if (m_openxr != nullptr) {
            m_openxr->pose_freeze_submit = m_pose_freeze_submit;
        }
    }

    vr::HmdMatrix34_t get_submit_pose() const;

    int32_t get_blank_eye() const {
        return m_blank_eye;
    }

    void set_blank_eye(int32_t eye) {
        m_blank_eye = (eye == 0 || eye == 1) ? eye : -1;
    }

    // Lens shift in projection units, for lining the zoomed image up with the optic.
    float get_projection_shift_x() const {
        return m_projection_shift_x;
    }

    void set_projection_shift_x(float shift) {
        m_projection_shift_x = shift;
    }

    float get_projection_shift_y() const {
        return m_projection_shift_y;
    }

    void set_projection_shift_y(float shift) {
        m_projection_shift_y = shift;
    }

    const Matrix4x4f& get_last_render_matrix() {
        return m_render_camera_matrix;
    }

    Vector4f get_position(uint32_t index)  const;
    Vector4f get_velocity(uint32_t index)  const;
    Vector4f get_angular_velocity(uint32_t index)  const;
    Matrix4x4f get_rotation(uint32_t index)  const;
    Matrix4x4f get_transform(uint32_t index) const;
    vr::HmdMatrix34_t get_raw_transform(uint32_t index) const;

    const auto& get_eyes() const {
        return get_runtime()->eyes;
    }

    void apply_hmd_transform(glm::quat& rotation, Vector4f& position);
    void apply_hmd_transform(::REJoint* camera_joint);
    
    bool is_hand_behind_head(VRRuntime::Hand hand, float sensitivity = 0.2f) const;
    bool is_action_active(vr::VRActionHandle_t action, vr::VRInputValueHandle_t source = vr::k_ulInvalidInputValueHandle) const;

    // [GRIP_FORCE] Everything about the grip threshold is configured from Lua
    // (autorun/re4_vr_capacitive.lua) -- deliberately NO UI in the framework.
    // hand: 0 = left, 1 = right.
    float get_grip_analog(int hand) const {
        if (hand < 0 || hand > 1) {
            return 0.0f;
        }

        return m_grip_last_value[hand];
    }

    // 0 = runtime boolean (no analog input bound), 1 = squeeze/value (capacitive), 2 = squeeze/force.
    int get_grip_source(int hand) const {
        if (hand < 0 || hand > 1) {
            return 0;
        }

        return m_grip_last_source[hand];
    }

    void set_grip_settings(bool use_analog, bool prefer_force, float press, float release) {
        m_grip_use_analog->value() = use_analog;
        m_grip_prefer_force->value() = prefer_force;
        m_grip_activate_threshold->value() = press;
        // A release point above the press point would latch the grip on forever.
        m_grip_deactivate_threshold->value() = (release > press) ? press : release;
    }
    Vector2f get_joystick_axis(vr::VRInputValueHandle_t handle) const;

    Vector2f get_left_stick_axis() const;
    Vector2f get_right_stick_axis() const;

    void trigger_haptic_vibration(float seconds_from_now, float duration, float frequency, float amplitude, vr::VRInputValueHandle_t source = vr::k_ulInvalidInputValueHandle);
    
    auto get_action_set() const { return m_action_set; }
    auto& get_active_action_set() const { return m_active_action_set; }
    auto get_action_trigger() const { return m_action_trigger; }
    auto get_action_grip() const { return m_action_grip; }
    auto get_action_joystick() const { return m_action_joystick; }
    auto get_action_joystick_click() const { return m_action_joystick_click; }
    auto get_action_a_button() const { return m_action_a_button; }
    auto get_action_b_button() const { return m_action_b_button; }
    auto get_action_weapon_dial() const { return m_action_weapon_dial; }
    auto get_action_minimap() const { return m_action_minimap; }
    auto get_action_block() const { return m_action_block; }
    auto get_action_dpad_up() const { return m_action_dpad_up; }
    auto get_action_dpad_down() const { return m_action_dpad_down; }
    auto get_action_dpad_left() const { return m_action_dpad_left; }
    auto get_action_dpad_right() const { return m_action_dpad_right; }
    auto get_action_heal() const { return m_action_heal; }
    auto get_left_joystick() const { return m_left_joystick; }
    auto get_right_joystick() const { return m_right_joystick; }

    const auto& get_action_handles() const { return m_action_handles;}

    auto get_ui_scale() const { return m_ui_scale_option->value(); }
    const auto& get_raw_projections() const { return get_runtime()->raw_projections; }

    void unhide_crosshair() {
        m_last_crosshair_hide = std::chrono::steady_clock::now();
    }
    
    void notify_camera_destroyed(RECamera* camera) {
        for (auto& existing_camera : m_multipass_cameras) {
            if (existing_camera == camera) {
                existing_camera = nullptr;
            }
        }
    }

    void set_multipass_camera(RECamera* camera, uint32_t index) {
        if (index >= 2) {
            return;
        }

        m_multipass_cameras[index] = camera;
    }

    std::array<RECamera*, 2> get_cameras() const;
    auto& get_camera_duplicator() {
        return m_camera_duplicator;
    }

private:
    Vector4f get_position_unsafe(uint32_t index) const;
    Vector4f get_velocity_unsafe(uint32_t index) const;
    Vector4f get_angular_velocity_unsafe(uint32_t index) const;

private:
    // Hooks
    void on_view_get_size(REManagedObject* scene_view, float* result) override;
    static void inputsystem_update_hook(void* ctx, REManagedObject* input_system);
    void on_camera_get_projection_matrix(REManagedObject* camera, Matrix4x4f* result) override;
    static Matrix4x4f* gui_camera_get_projection_matrix_hook(REManagedObject* camera, Matrix4x4f* result);
    void on_camera_get_view_matrix(REManagedObject* camera, Matrix4x4f* result) override;
    
    static HookManager::PreHookResult pre_set_hdr_mode(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr);
    static void post_set_hdr_mode(uintptr_t& ret_val, sdk::RETypeDefinition* ret_ty, uintptr_t ret_addr) {}

    bool on_pre_overlay_layer_update(sdk::renderer::layer::Overlay* layer, void* render_context) override;
    bool on_pre_overlay_layer_draw(sdk::renderer::layer::Overlay* layer, void* render_context) override;

    bool on_pre_post_effect_layer_update(sdk::renderer::layer::PostEffect* layer, void* render_context) override;
    bool on_pre_post_effect_layer_draw(sdk::renderer::layer::PostEffect* layer, void* render_context) override;
    void on_post_effect_layer_draw(sdk::renderer::layer::PostEffect* layer, void* render_context) override;
    uint32_t m_previous_distortion_type{};
    bool m_set_next_post_effect_distortion_type{false};

    bool on_pre_scene_layer_update(sdk::renderer::layer::Scene* layer, void* render_context) override;
    void on_scene_layer_update(sdk::renderer::layer::Scene* layer, void* render_context) override;
    bool on_pre_scene_layer_draw(sdk::renderer::layer::Scene* layer, void* render_context) override;

    void on_prepare_output_layer_draw(sdk::renderer::layer::PrepareOutput* layer, void* render_context) override;

    struct SceneLayerData {
        SceneLayerData() = default;
        SceneLayerData(sdk::renderer::SceneInfo* info) {
            setup(info);
        }

        void setup(sdk::renderer::SceneInfo* info) {
            scene_info = info;
            if (scene_info != nullptr) {
                this->view_projection_matrix = scene_info->view_projection_matrix;
            }
        }

        void post_setup(int32_t index) {
            scene_info->old_view_projection_matrix = previous_view_projection_matrices[(index - 1) % 2];
            previous_view_projection_matrices[index % 2] = scene_info->view_projection_matrix;
        }

        sdk::renderer::SceneInfo* scene_info{};
        Matrix4x4f view_projection_matrix{};
        std::array<Matrix4x4f, 2> previous_view_projection_matrices{};
    };

    std::unordered_map<sdk::renderer::layer::Scene*, std::array<SceneLayerData, 5>> m_scene_layer_data {};

    static void wwise_listener_update_hook(void* listener);

    //static float get_sharpness_hook(void* tonemapping);

    // initialization functions
    std::optional<std::string> initialize_openvr();
    std::optional<std::string> initialize_openvr_input();
    std::optional<std::string> initialize_openxr();
    std::optional<std::string> initialize_openxr_input();
    std::optional<std::string> initialize_openxr_swapchains();
    std::optional<std::string> hijack_resolution();
    std::optional<std::string> hijack_input();
    std::optional<std::string> hijack_camera();
    std::optional<std::string> hijack_wwise_listeners(); // audio hook

    std::optional<std::string> reinitialize_openvr() {
        spdlog::info("Reinitializing OpenVR");
        std::scoped_lock _{m_openvr_mtx};

        m_runtime.reset();
        m_runtime = std::make_shared<VRRuntime>();
        m_openvr.reset();

        // Reinitialize openvr input, hopefully this fixes the issue
        m_controllers.clear();
        m_controllers_set.clear();

        auto e = initialize_openvr();

        if (e) {
            spdlog::error("Failed to reinitialize OpenVR: {}", *e);
        }

        return e;
    }

    std::optional<std::string> reinitialize_openxr() {
        spdlog::info("Reinitializing OpenXR");
        std::scoped_lock _{m_openvr_mtx};

        if (m_is_d3d12) {
            m_d3d12.openxr().destroy_swapchains();
        } else {
            m_d3d11.openxr().destroy_swapchains();
        }

        m_openxr.reset();
        m_runtime.reset();
        m_runtime = std::make_shared<VRRuntime>();
        
        m_controllers.clear();
        m_controllers_set.clear();

        auto e = initialize_openxr();

        if (e) {
            spdlog::error("Failed to reinitialize OpenXR: {}", *e);
        }

        return e;
    }

    bool detect_controllers();
    bool is_any_action_down();
    void update_hmd_state();
    void update_action_states();
    void update_camera(); // if not in firstperson mode
    void update_camera_origin(); // every frame
    void update_audio_camera();
    void update_render_matrix();
    void restore_audio_camera(); // after wwise listener update
    void restore_camera(); // After rendering
    void set_lens_distortion(bool value);
    void disable_bad_effects();
    void fix_temporal_effects();

    // input functions
    // Purpose: "Emulate" OpenVR input to the game
    // By setting things like input flags based on controller state
    void openvr_input_to_re2_re3(REManagedObject* input_system);
    void openvr_input_to_re_engine(); // generic, can be used on any game

    // Sets overlay layer to return instantly
    // causes world-space gui elements to render properly
    Patch::Ptr m_overlay_draw_patch{};
    
    mutable std::recursive_mutex m_openvr_mtx{};
    mutable std::recursive_mutex m_wwise_mtx{};
    mutable std::recursive_mutex m_scene_update_mtx{};
    mutable std::shared_mutex m_gui_mtx{};
    mutable std::shared_mutex m_rotation_mtx{};

    vr::VRTextureBounds_t m_right_bounds{ 0.0f, 0.0f, 1.0f, 1.0f };
    vr::VRTextureBounds_t m_left_bounds{ 0.0f, 0.0f, 1.0f, 1.0f };

    glm::vec3 m_overlay_rotation{-1.550f, 0.0f, -1.330f};
    glm::vec4 m_overlay_position{0.0f, 0.06f, -0.07f, 1.0f};

    float m_nearz{ 0.1f };
    float m_farz{ 3000.0f };

    std::array<RECamera*, 2> m_multipass_cameras{};

    std::shared_ptr<VRRuntime> m_runtime{std::make_shared<VRRuntime>()}; // will point to the real runtime if it exists
    std::shared_ptr<runtimes::OpenVR> m_openvr{std::make_shared<runtimes::OpenVR>()};
    std::shared_ptr<runtimes::OpenXR> m_openxr{std::make_shared<runtimes::OpenXR>()};

    Vector4f m_standing_origin{ 0.0f, 1.5f, 0.0f, 0.0f };
    glm::quat m_rotation_offset{ glm::identity<glm::quat>() };
    glm::quat m_gui_rotation_offset{ glm::identity<glm::quat>() };

    std::vector<int32_t> m_controllers{};
    std::unordered_set<int32_t> m_controllers_set{};

    // Action set handles
    vr::VRActionSetHandle_t m_action_set{};
    vr::VRActiveActionSet_t m_active_action_set{};

    // Action handles
    vr::VRActionHandle_t m_action_trigger{ };
    vr::VRActionHandle_t m_action_grip{ };
    // [GRIP_THRESHOLD] Analog counterpart of m_action_grip, OpenXR only (see VR::is_action_active).
    vr::VRActionHandle_t m_action_grip_value{ };
    // [GRIP_FORCE] Index force sensor -- the input the OpenVR profile actually thresholds.
    vr::VRActionHandle_t m_action_grip_force{ };
    // Hysteresis state per hand: index 0 = left, 1 = right. mutable because is_action_active is const.
    mutable bool m_grip_value_state[2]{ false, false };
    // [GRIP_FORCE] Purely informational, for the readout in the main menu: last analog value seen
    // per hand and where it came from (0 = boolean fallback, 1 = squeeze/value, 2 = squeeze/force).
    mutable float m_grip_last_value[2]{ 0.0f, 0.0f };
    mutable int m_grip_last_source[2]{ 0, 0 };
    vr::VRActionHandle_t m_action_joystick{};
    vr::VRActionHandle_t m_action_joystick_click{};
    vr::VRActionHandle_t m_action_a_button{};
    vr::VRActionHandle_t m_action_b_button{};
    vr::VRActionHandle_t m_action_dpad_up{};
    vr::VRActionHandle_t m_action_dpad_right{};
    vr::VRActionHandle_t m_action_dpad_down{};
    vr::VRActionHandle_t m_action_dpad_left{};
    vr::VRActionHandle_t m_action_system_button{};
    vr::VRActionHandle_t m_action_weapon_dial{};
    vr::VRActionHandle_t m_action_re3_dodge{};
    vr::VRActionHandle_t m_action_re2_quickturn{};
    vr::VRActionHandle_t m_action_re2_firstperson_toggle{};
    vr::VRActionHandle_t m_action_re2_reset_view{};
    vr::VRActionHandle_t m_action_re2_change_ammo{};
    vr::VRActionHandle_t m_action_re2_toggle_flashlight{};
    vr::VRActionHandle_t m_action_minimap{};
    vr::VRActionHandle_t m_action_block{};
    vr::VRActionHandle_t m_action_haptic{};
    vr::VRActionHandle_t m_action_heal{};

    bool m_was_firstperson_toggle_down{false};
    bool m_was_flashlight_toggle_down{false};
    
    
    std::unordered_map<std::string, std::reference_wrapper<vr::VRActionHandle_t>> m_action_handles {
        { "/actions/default/in/Trigger", m_action_trigger },
        { "/actions/default/in/Grip", m_action_grip },
        { "/actions/default/in/GripValue", m_action_grip_value },
        { "/actions/default/in/GripForce", m_action_grip_force },
        { "/actions/default/in/Joystick", m_action_joystick },
        { "/actions/default/in/JoystickClick", m_action_joystick_click },
        { "/actions/default/in/AButton", m_action_a_button },
        { "/actions/default/in/BButton", m_action_b_button },
        { "/actions/default/in/DPad_Up", m_action_dpad_up },
        { "/actions/default/in/DPad_Right", m_action_dpad_right },
        { "/actions/default/in/DPad_Down", m_action_dpad_down },
        { "/actions/default/in/DPad_Left", m_action_dpad_left },
        { "/actions/default/in/SystemButton", m_action_system_button },
        { "/actions/default/in/WeaponDial_Start", m_action_weapon_dial },
        { "/actions/default/in/RE3_Dodge", m_action_re3_dodge },
        { "/actions/default/in/RE2_Quickturn", m_action_re2_quickturn },
        { "/actions/default/in/RE2_FirstPerson_Toggle", m_action_re2_firstperson_toggle },
        { "/actions/default/in/RE2_Reset_View", m_action_re2_reset_view },
        { "/actions/default/in/RE2_Change_Ammo", m_action_re2_change_ammo },
        { "/actions/default/in/RE2_Toggle_Flashlight", m_action_re2_toggle_flashlight },
        { "/actions/default/in/MiniMap", m_action_minimap },
        { "/actions/default/in/Block", m_action_block },
        { "/actions/default/in/Heal", m_action_heal },

        // Out
        { "/actions/default/out/Haptic", m_action_haptic },
    };

    // Input sources
    vr::VRInputValueHandle_t m_left_joystick{};
    vr::VRInputValueHandle_t m_right_joystick{};

    // Input system history
    std::bitset<64> m_button_states_down{};
    std::bitset<64> m_button_states_on{};
    std::bitset<64> m_button_states_up{};
    std::chrono::steady_clock::time_point m_last_controller_update{};
    // [AUTO_RECENTER 2026-08-18] Einmaliges Recenter kurz nach JEDER Runtime-Initialisierung.
    // OpenXR braucht es zwingend (der Blick steht sonst schief), unter OpenVR schadet es nicht.
    // Ein Reinit (wants_reinitialize) laeuft durch dieselben initialize_*-Funktionen und macht
    // es damit automatisch wieder scharf.
    bool m_wants_auto_recenter{false};
    std::chrono::steady_clock::time_point m_auto_recenter_armed_at{};
    std::chrono::steady_clock::time_point m_last_interaction_display{};
    std::chrono::steady_clock::time_point m_last_crosshair_hide{};
    uint32_t m_backbuffer_inconsistency_start{};
    std::chrono::nanoseconds m_last_input_delay{};
    std::chrono::nanoseconds m_avg_input_delay{};

    HANDLE m_present_finished_event{CreateEvent(nullptr, TRUE, FALSE, nullptr)};

    Vector4f m_raw_projections[2]{};

    vrmod::D3D11Component m_d3d11{};
    vrmod::D3D12Component m_d3d12{};
    vrmod::OverlayComponent m_overlay_component{};
    vrmod::CameraDuplicator m_camera_duplicator{};

    template <typename T> using ComPtr = Microsoft::WRL::ComPtr<T>;

    struct MultiPass {
        std::array<d3d12::TextureContext, 2> eye_contexts{}; // For the SRV
        std::array<ComPtr<ID3D12Resource>, 2> eye_textures{};
        std::array<sdk::intrusive_ptr<sdk::renderer::Texture>, 2> native_res_copies{}; // used with TemporalUpscaler disabled
        std::array<uint32_t, 2> allocated_size{};
        uint32_t pass{0};
    } m_multipass{};
    

    Vector4f m_original_camera_position{ 0.0f, 0.0f, 0.0f, 0.0f };
    glm::quat m_original_camera_rotation{ glm::identity<glm::quat>() };

    Matrix4x4f m_original_camera_matrix{ glm::identity<Matrix4x4f>() };

    Vector4f m_original_audio_camera_position{ 0.0f, 0.0f, 0.0f, 0.0f };
    glm::quat m_original_audio_camera_rotation{ glm::identity<glm::quat>() };

    Matrix4x4f m_render_camera_matrix{ glm::identity<Matrix4x4f>() };

    sdk::helpers::NativeObject m_via_hid_gamepad{ "via.hid.GamePad" };

    // options
    int m_frame_count{};
    int m_render_frame_count{};
    int m_last_frame_count{-1};
    int m_left_eye_frame_count{0};
    int m_right_eye_frame_count{0};

    bool m_submitted{false};
    //bool m_disable_sharpening{true};

    bool m_needs_camera_restore{false};
    bool m_needs_audio_restore{false};
    bool m_in_render{false};
    bool m_in_lightshaft{false};
    bool m_positional_tracking{true};
    bool m_is_d3d12{false};
    bool m_backbuffer_inconsistency{false};
    bool m_init_finished{false};
    bool m_has_hw_scheduling{false}; // hardware accelerated GPU scheduling

    // on the backburner
    bool m_depth_aided_reprojection{false};

    // == 1 or == 0
    uint8_t m_left_eye_interval{0};
    uint8_t m_right_eye_interval{1};

    static std::string actions_json;
    static std::string binding_rift_json;
    static std::string bindings_oculus_touch_json;
    static std::string binding_vive;
    static std::string bindings_vive_controller;
    static std::string bindings_knuckles;

    const std::unordered_map<std::string, std::string> m_binding_files {
        { "actions.json", actions_json },
        { "binding_rift.json", binding_rift_json },
        { "bindings_oculus_touch.json", bindings_oculus_touch_json },
        { "binding_vive.json", binding_vive },
        { "bindings_vive_controller.json", bindings_vive_controller },
        { "bindings_knuckles.json", bindings_knuckles }
    };

    const ModKey::Ptr m_set_standing_key{ ModKey::create(generate_name("SetStandingOriginKey")) };
    const ModKey::Ptr m_recenter_view_key{ ModKey::create(generate_name("RecenterViewKey")) };
    const ModToggle::Ptr m_decoupled_pitch{ ModToggle::create(generate_name("DecoupledPitch_V2"), true) };
    // [ZOOM_STEREO 2026-08-14] Ob der Scope-Zoom die Off-Center-Terme der Projektion
    // mitskaliert. Die sind PRO AUGE verschieden (asymmetrisches HMD-Frustum), beim
    // Skalieren waechst der Versatz zwischen beiden Bildern also mit dem Zoomfaktor --
    // gemessen im Spiel: "je mehr Zoom, desto schlimmer", bis hin zum Schielen.
    // false (Default) = jedes Auge zoomt um SEINE Blickachse, die Bilder bleiben
    // fusionierbar. true = altes Verhalten, nur fuer den direkten Vergleich.
    const ModToggle::Ptr m_zoom_scales_eye_offset{ ModToggle::create(generate_name("ZoomScalesEyeOffset"), false) };
    // [ZOOM_DEPTH 2026-08-14] Beim Zoom den AUGENABSTAND mitverkleinern (IPD / Zoom).
    // Der Zoom vergroessert auch die Parallaxe zwischen den Augen, und daraus liest das
    // Gehirn die Entfernung: im Spiel gemessen "ausgezoomt wirkt der Scope-Mittelpunkt
    // weit weg, eingezoomt nah dran", und jede Zoomstufe braucht neues Einstellen der
    // Augen. Ein echtes Fernglas hat dafuer eine kleinere Basis. Mit dieser Kopplung
    // bleibt die wahrgenommene Tiefe ueber alle Zoomstufen gleich.
    const ModToggle::Ptr m_zoom_shrinks_ipd{ ModToggle::create(generate_name("ZoomShrinksIPD"), true) };
    // Zuletzt in apply_projection_tweaks errechneter Zoomfaktor -- auch der aus einem
    // gesetzten FOV, den man ohne die Projektion nicht kennt.
    mutable float m_last_zoom_factor{1.0f};
    const ModToggle::Ptr m_clear_before_framewarp{ModToggle::create(generate_name("ClearBeforeFramewarp"), false)};
    const ModToggle::Ptr m_enable_ui_fix{ModToggle::create(generate_name("EnableUIFix"), true)};
    const ModToggle::Ptr m_framewarp_debug{ModToggle::create(generate_name("FramewarpDebug"), false)};
    const ModSlider::Ptr m_ignore_motion_threshold{ModSlider::create(generate_name("IgnoreMotionThreshold"), 1.0f, 100.0f, 2.5f)};

    const ModCombo::Ptr m_framewarp_mode{ModCombo::create(generate_name("Framewarp Mode"),
        {
            "None",
            "AlternateEyeWarping",
            "PreviousFrameWarping",
            "CombinedWarping",
        },
        (int)FrameWarpMode::CombinedWarping)};
    const ModCombo::Ptr m_rendering_technique{ 
        ModCombo::create(generate_name("RenderingTechnique_V2"),
        {
            "Alternating/AFR", 
            "Two Frame Sequential", 
            "Single Frame Multipass",
            "AFW (experimental)"
        }, 
#if TDB_VER < 69
        1 // Previous rendering technique
#else
        // [KEIN_AFW_START 2026-08-15] War 3 (Alternate Frame Warping). AFW ist hier buggy und
        // laesst sich im Spiel nicht gefahrlos wechseln (Umschalten zur Laufzeit crasht),
        // also darf es gar nicht erst der Startwert sein. 2 = Single Frame Multipass, der
        // Upstream-Weg vor AFW. Wer AFW testen will, setzt VR_RenderingTechnique_V2=3 in
        // re2_fw_config.txt -- die Config sticht diesen Default ohnehin.
        2 // Single Frame Multipass
#endif
        ) 
    };
    const ModToggle::Ptr m_use_custom_view_distance{ ModToggle::create(generate_name("UseCustomViewDistance"), false) };
    const ModToggle::Ptr m_hmd_oriented_audio{ ModToggle::create(generate_name("HMDOrientedAudio"), true) };
    const ModSlider::Ptr m_view_distance{ ModSlider::create(generate_name("CustomViewDistance"), 10.0f, 3000.0f, 500.0f) };
    const ModSlider::Ptr m_motion_controls_inactivity_timer{ ModSlider::create(generate_name("MotionControlsInactivityTimer"), 30.0f, 100.0f, 30.0f) };
    const ModSlider::Ptr m_joystick_deadzone{ ModSlider::create(generate_name("JoystickDeadzone"), 0.01f, 0.9f, 0.15f) };
    // [GRIP_THRESHOLD] OpenXR only. Defaults match the OpenVR Index profile (Bindings.cpp): press at
    // 0.3, release at 0.25. Toggle off to go back to the runtime's own thresholding.
    const ModToggle::Ptr m_grip_use_analog{ ModToggle::create(generate_name("GripUseAnalogThreshold"), true) };
    // [GRIP_FORCE] Off = ignore the force sensor and threshold squeeze/value again (old behaviour).
    const ModToggle::Ptr m_grip_prefer_force{ ModToggle::create(generate_name("GripPreferForceSensor"), true) };
    const ModSlider::Ptr m_grip_activate_threshold{ ModSlider::create(generate_name("GripActivateThreshold"), 0.05f, 0.95f, 0.30f) };
    const ModSlider::Ptr m_grip_deactivate_threshold{ ModSlider::create(generate_name("GripDeactivateThreshold"), 0.05f, 0.95f, 0.25f) };
    const ModSlider::Ptr m_ui_scale_option{ ModSlider::create(generate_name("2DUIScale"), 1.0f, 100.0f, 12.0f) };
    const ModSlider::Ptr m_ui_distance_option{ ModSlider::create(generate_name("2DUIDistance"), 0.01f, 100.0f, 1.0f) };
    const ModSlider::Ptr m_world_ui_scale_option{ ModSlider::create(generate_name("WorldSpaceUIScale"), 1.0f, 100.0f, 15.0f) };
    const ModSlider::Ptr m_resolution_scale{ ModSlider::create(generate_name("OpenXRResolutionScale"), 0.1f, 5.0f, 1.0f) };
    // [POINTER_PITCH 2026-08-15] Neigung des Menue-Zeigestrahls, in GRAD um die eigene X-Achse
    // des rechten Controllers. Grund: gezeigt wird mit der GRIFF-Pose ("/user/hand/*/input/grip/pose"
    // bzw. der rohen OpenVR-Controller-Pose) -- deren -Z ist die Achse des Griffs, nicht die
    // Zeigerichtung des Zeigefingers. Der Strahl tritt dadurch zu hoch aus (gefuehlt am Daumen),
    // man muss den Controller nach unten kippen. Eine Aim-Pose ist hier nicht gebunden, in OpenVR
    // gibt es sie gar nicht -- deshalb ein fester Winkelausgleich statt einer zweiten Pose.
    // Negativ = Strahl nach UNTEN (das ist die Korrekturrichtung), 0 = altes Verhalten.
    // BEWUSST OHNE UI (wie DLSSPreset): eingestellt wird ueber VR_OverlayPointerPitch in
    // re2_fw_config.txt bei beendetem Spiel, im fertigen Menue soll kein Regler stehen.
    const ModSlider::Ptr m_overlay_pointer_pitch{ ModSlider::create(generate_name("OverlayPointerPitch"), -60.0f, 60.0f, -35.0f) };

    const ModToggle::Ptr m_force_fps_settings{ ModToggle::create(generate_name("ForceFPS"), true) };

#if TDB_VER < 69
    const ModToggle::Ptr m_force_aa_settings{ ModToggle::create(generate_name("ForceAntiAliasing"), true) };
#else
    // On new versions, since we're using the new rendering technique, we don't need to turn AA off
    const ModToggle::Ptr m_force_aa_settings{ ModToggle::create(generate_name("ForceAntiAliasing_V2"), false) };
#endif

    const ModToggle::Ptr m_force_motionblur_settings{ ModToggle::create(generate_name("ForceMotionBlur"), true) };
    const ModToggle::Ptr m_force_vsync_settings{ ModToggle::create(generate_name("ForceVSync"), true) };
    const ModToggle::Ptr m_force_lensdistortion_settings{ ModToggle::create(generate_name("ForceLensDistortion"), true) };
    const ModToggle::Ptr m_force_volumetrics_settings{ ModToggle::create(generate_name("ForceVolumetrics"), true) };
    const ModToggle::Ptr m_force_lensflares_settings{ ModToggle::create(generate_name("ForceLensFlares"), true) };
    const ModToggle::Ptr m_force_dynamic_shadows_settings{ ModToggle::create(generate_name("ForceDynamicShadows"), true) };

#if TDB_VER < 73
    const ModToggle::Ptr m_allow_engine_overlays{ ModToggle::create(generate_name("AllowEngineOverlays_V2"), true) };
#else
    const ModToggle::Ptr m_allow_engine_overlays{ ModToggle::create(generate_name("AllowEngineOverlays_V2"), false) };
#endif

    const ModToggle::Ptr m_desktop_fix{ ModToggle::create(generate_name("DesktopRecordingFix"), true) };
    const ModToggle::Ptr m_desktop_fix_skip_present{ ModToggle::create(generate_name("DesktopRecordingFixSkipPresent"), true) };

#if TDB_VER >= 73
    const ModToggle::Ptr m_enable_asynchronous_rendering{ ModToggle::create(generate_name("AsyncRendering_V3"), false) };
#else
    const ModToggle::Ptr m_enable_asynchronous_rendering{ ModToggle::create(generate_name("AsyncRendering_V3"), true) };
#endif

    bool m_disable_projection_matrix_override{ false };
    bool m_disable_gui_camera_projection_matrix_override{ false };
    bool m_disable_gui_element_override{ false };
    bool m_disable_view_matrix_override{false};
    bool m_disable_backbuffer_size_override{false};
    bool m_disable_temporal_fix{false};
    bool m_disable_post_effect_fix{false};

    bool m_mono_rendering{false};
    uint32_t m_mono_rendering_eye{0}; // 0 = left, 1 = right
    bool m_mono_projection{false};    // also force the chosen eye's projection (breaks fusion)

    bool m_flatscreen_overlay{false};          // show the frame as a flat quad instead of stereo
    float m_flatscreen_overlay_width{2.5f};    // meters
    float m_flatscreen_overlay_distance{2.0f}; // meters in front of the head

    bool m_vr_suspended{false};                // park every engine override, see is_vr_suspended()
    bool m_map_face_glue{false};               // RE4 map layers head-locked, see is_map_face_glue()
    float m_map_glue_distance{1.5f};           // meters in front of the head while glued
    float m_map_glue_layer_gap{0.002f};        // per-layer stagger, see get_map_glue_layer_gap()
    // Liste der gepinnten GUIs, siehe is_glue_gui(). Wird beim ersten Zugriff mit den
    // Karten-GUIs vorbelegt; ein bewusstes clear_glue_guis() bleibt leer.
    std::unordered_map<uint32_t, int> m_glue_guis{};
    bool m_glue_guis_initialized{false};
    std::mutex m_glue_guis_mutex{};

    int32_t m_blank_eye{-1};          // -1 = off, 0 = left, 1 = right
    bool m_pose_freeze{false};        // [POSE_FREEZE] HMD-Rotation eingefroren (Scope)
    int32_t m_pose_freeze_submit{2};  // 0 = keine Angabe, 1 = eingefrorene, 2 = frische Pose
    glm::quat m_frozen_hmd_rotation{glm::identity<glm::quat>()};
    Vector4f m_frozen_hmd_position{};
    float m_image_shift_x{0.0f};      // fractions of the image, applied at submit
    float m_image_shift_y{0.0f};
    float m_projection_zoom{1.0f};    // 1 = off
    float m_projection_fov{0.0f};     // 0 = off, else vertical FOV in degrees (wins over zoom)
    float m_projection_shift_x{0.0f};
    float m_projection_shift_y{0.0f};

    Matrix4x4f apply_projection_tweaks(Matrix4x4f proj) const;
    // [ZOOM_DEPTH] Augenversatz durch den Zoomfaktor teilen, siehe m_zoom_shrinks_ipd.
    Matrix4x4f apply_zoom_eye_offset(Matrix4x4f eye) const;

    ValueList m_options{
        *m_set_standing_key,
        *m_recenter_view_key,
        *m_decoupled_pitch,
        *m_zoom_scales_eye_offset,
        *m_zoom_shrinks_ipd,
        *m_rendering_technique,
        *m_use_custom_view_distance,
        *m_hmd_oriented_audio,
        *m_view_distance,
        *m_motion_controls_inactivity_timer,
        *m_joystick_deadzone,
        *m_grip_use_analog,
        *m_grip_prefer_force,
        *m_grip_activate_threshold,
        *m_grip_deactivate_threshold,
        *m_force_fps_settings,
        *m_force_aa_settings,
        *m_force_motionblur_settings,
        *m_force_vsync_settings,
        *m_force_lensdistortion_settings,
        *m_force_volumetrics_settings,
        *m_force_lensflares_settings,
        *m_force_dynamic_shadows_settings,
        *m_ui_scale_option,
        *m_ui_distance_option,
        *m_world_ui_scale_option,
        *m_allow_engine_overlays,
        *m_resolution_scale,
        *m_overlay_pointer_pitch,
        *m_desktop_fix,
        *m_desktop_fix_skip_present,
        *m_enable_asynchronous_rendering
    };

    bool m_use_rotation{true};

    friend class vrmod::D3D11Component;
    friend class vrmod::D3D12Component;
    friend class vrmod::OverlayComponent;
};
