#include <algorithm>
#include <cmath>

#include "../VR.hpp"

#include "OverlayComponent.hpp"

namespace vrmod {
void OverlayComponent::on_reset() {
    m_overlay_data = {};
}

std::optional<std::string> OverlayComponent::on_initialize_openvr() {
    m_overlay_data = {};

    // create vr overlay
    auto overlay_error = vr::VROverlay()->CreateOverlay("REFramework", "REFramework", &m_overlay_handle);

    if (overlay_error != vr::VROverlayError_None) {
        return "VROverlay failed to create overlay: " + std::string{vr::VROverlay()->GetOverlayErrorNameFromEnum(overlay_error)};
    }

    // set overlay to visible
    vr::VROverlay()->ShowOverlay(m_overlay_handle);

    overlay_error = vr::VROverlay()->SetOverlayWidthInMeters(m_overlay_handle, 0.25f);

    if (overlay_error != vr::VROverlayError_None) {
        return "VROverlay failed to set overlay width: " + std::string{vr::VROverlay()->GetOverlayErrorNameFromEnum(overlay_error)};
    }

    // same thing as above but absolute instead
    // get absolute tracking pose of hmd with GetDeviceToAbsoluteTrackingPose
    // then get the matrix from that
    // then set it as the overlay transform
    vr::TrackedDevicePose_t pose{};
    vr::VRSystem()->GetDeviceToAbsoluteTrackingPose(vr::TrackingUniverseStanding, 0.0f, &pose, 1);
    vr::VROverlay()->SetOverlayTransformAbsolute(m_overlay_handle, vr::TrackingUniverseStanding, &pose.mDeviceToAbsoluteTracking);

    spdlog::info("Made overlay with handle {}", m_overlay_handle);

    return std::nullopt;
}

void OverlayComponent::on_pre_imgui_frame() {
    // OpenXR: Pose und Ausschnitt des Quad-Layers stellen. Die Textur holt sich
    // D3D12Component spaeter im Renderpfad, rechtzeitig vor xrEndFrame.
    this->update_openxr();

    // Zeiger fuer beide Runtimes. Muss vor dem ImGui-Frame stehen, sonst kaeme die
    // Mausposition einen Frame zu spaet.
    this->update_pointer();
}

// [XR_UI_POINTER 2026-08-14] Der sichtbare Zeiger: ein roter Punkt, den wir SELBST in die
// Vordergrund-DrawList zeichnen. Ein ImGui-Mauszeiger (io.MouseDrawCursor) taugt hier
// nicht -- REFramework::draw_ui setzt das Flag jeden Frame neu (REFramework.cpp:1540, aus
// is_always_show_cursor) und wuerde uns damit ueberschreiben.
void OverlayComponent::on_frame() {
    if (!m_pointer_cursor_shown || !g_framework->is_drawing_ui()) {
        return;
    }

    auto draw_list = ImGui::GetForegroundDrawList();

    if (draw_list == nullptr) {
        return;
    }

    // Weisser Ring um den roten Kern: auf hellem Menuegrund waere reines Rot schlecht zu
    // sehen, und im Headset ist das Menue stark verkleinert.
    draw_list->AddCircleFilled(m_pointer_last_pos, 7.0f, IM_COL32(255, 40, 40, 230));
    draw_list->AddCircle(m_pointer_last_pos, 8.5f, IM_COL32(255, 255, 255, 200), 0, 2.0f);
}

void OverlayComponent::on_post_compositor_submit() {
    this->update_overlay();
}

// ---------------------------------------------------------------------------
// Wo das Menue haengt
// ---------------------------------------------------------------------------
// [XR_UI_OVERLAY 2026-08-14] Gilt fuer BEIDE Runtimes, damit sich das Menue gleich
// verhaelt: an der linken Hand mit den Overlay-Offsets, ohne getrackte Hand vor dem Kopf.
// Zeigetests und Controller-Eingaben gibt es bewusst KEINE mehr -- geoeffnet wird das
// Menue ueber die Menue-Taste (Insert), spaeter zusaetzlich aus Lua.
uint32_t OverlayComponent::hand_transform_index(bool right) const {
    auto& vr = VR::get();

    if (vr->get_runtime()->is_openxr()) {
        return (uint32_t)((right ? VRRuntime::Hand::RIGHT : VRRuntime::Hand::LEFT) + 1);
    }

    const auto& controllers = vr->get_controllers();

    if (controllers.size() < 2) {
        return vr::k_unTrackedDeviceIndexInvalid;
    }

    return (uint32_t)(right ? controllers[1] : controllers[0]);
}

bool OverlayComponent::is_hand_valid(bool right) const {
    auto& vr = VR::get();

    if (vr->get_runtime()->is_openxr()) {
        const auto& location = vr->m_openxr->hands[right ? VRRuntime::Hand::RIGHT : VRRuntime::Hand::LEFT].location;

        return (location.locationFlags &
            (XR_SPACE_LOCATION_POSITION_VALID_BIT | XR_SPACE_LOCATION_ORIENTATION_VALID_BIT)) != 0;
    }

    return hand_transform_index(right) != vr::k_unTrackedDeviceIndexInvalid;
}

Matrix4x4f OverlayComponent::compute_panel_transform() const {
    auto& vr = VR::get();

    Matrix4x4f panel{glm::identity<Matrix4x4f>()};

    if (is_hand_valid(false)) {
        panel = vr->get_transform(hand_transform_index(false)) * Matrix4x4f{glm::quat{vr->m_overlay_rotation}};
        panel[3] -= glm::extractMatrixRotation(panel) * vr->m_overlay_position;
    } else {
        // Ohne getrackte linke Hand haengt das Menue vor dem Kopf -- sonst waere es beim
        // Oeffnen per Taste nicht auffindbar.
        panel = vr->get_transform(0);
        panel[3] -= glm::extractMatrixRotation(panel) * Vector4f{0.0f, 0.0f, 0.5f, 0.0f};
    }

    panel[3].w = 1.0f;

    return panel;
}

// ---------------------------------------------------------------------------
// Auswaehlen mit der rechten Hand
// ---------------------------------------------------------------------------
// [XR_UI_POINTER 2026-08-14] Bewusst selbst gerechnet statt ueber SteamVR: dessen
// ComputeOverlayIntersection braucht die Tip-Komponente des Controllers (nicht jedes
// Modell meldet sie), und unter OpenXR gibt es gar kein Gegenstueck. So verhaelt sich
// die Bedienung in beiden Runtimes identisch.
//
// Wichtig: Das hier OEFFNET nichts. Es laeuft nur, wenn das Menue bereits offen ist --
// aufgemacht wird es allein per Tastenkombination (LT + linkes B) oder Insert.
namespace {
struct PanelHit {
    bool hit{false};
    float u{0.0f};
    float v{0.0f};
};

// Eine Menueflaeche liegt in der XY-Ebene ihrer Pose und schaut nach +Z -- das gilt fuer
// den OpenXR-Quad-Layer wie fuer das SteamVR-Overlay, deshalb reicht eine Funktion.
PanelHit ray_vs_panel(const Matrix4x4f& panel, float width, float height, const Matrix4x4f& source) {
    PanelHit out{};

    const auto plane_right = Vector3f{panel[0]};
    const auto plane_up = Vector3f{panel[1]};
    const auto plane_normal = Vector3f{panel[2]};
    const auto plane_origin = Vector3f{panel[3]};

    const auto ray_origin = Vector3f{source[3]};
    const auto ray_direction = -Vector3f{source[2]}; // -Z ist die Zeigerichtung

    const auto denom = glm::dot(plane_normal, ray_direction);

    if (denom > -0.0001f) {
        return out; // parallel, oder der Strahl kommt von hinten
    }

    const auto t = glm::dot(plane_normal, plane_origin - ray_origin) / denom;

    if (t <= 0.0f) {
        return out;
    }

    const auto hit = (ray_origin + ray_direction * t) - plane_origin;

    out.u = (glm::dot(hit, plane_right) / width) + 0.5f;
    out.v = 0.5f - (glm::dot(hit, plane_up) / height);
    out.hit = out.u >= 0.0f && out.u <= 1.0f && out.v >= 0.0f && out.v <= 1.0f;

    return out;
}
}

void OverlayComponent::update_pointer() {
    auto& vr = VR::get();
    auto& io = ImGui::GetIO();

    // Cursor wieder ausblenden, sobald der Strahl die Flaeche verlaesst oder das Menue
    // zugeht -- sonst bliebe er als Pfeil im Bild stehen.
    auto hide_cursor = [&]() {
        if (m_pointer_cursor_shown) {
            m_pointer_cursor_shown = false;
        }
    };

    // [MULTIPASS 2026-08-14] Zuerst den eigenen Zeigerzustand ZURUECKSCHREIBEN, bevor
    // irgendetwas neu gerechnet wird. Bei Multipass wird ImGui mehr als einmal pro
    // Augenpaar aufgebaut, und der Win32-Backend setzt dazwischen die echte Desktop-Maus
    // in io.MousePos -- der Zeiger sprang dadurch zwischen zwei Stellen hin und her und
    // war kaum zu treffen (im master-Release faellt es nicht auf, weil dort nur ein Frame
    // pro Augenpaar entsteht). Praydogs Originalcode macht fuer die Overlay-Maus mit
    // m_initial_imgui_input_state genau dasselbe.
    if (m_pointer_cursor_shown) {
        io.MousePos = m_pointer_last_pos;
        io.MouseDown[0] = m_pointer_mouse_down;
    }

    if (!vr->is_hmd_active() || !g_framework->is_drawing_ui()) {
        hide_cursor();
        return;
    }

    if (!is_hand_valid(true)) {
        hide_cursor();
        return;
    }

    const auto window_pos = g_framework->get_last_window_pos();
    const auto window_size = g_framework->get_last_window_size();

    if (window_size.x < 1.0f || window_size.y < 1.0f) {
        hide_cursor();
        return;
    }

    // Dieselben Masse wie die Anzeige: 0.25 m breit, Hoehe aus dem Seitenverhaeltnis des
    // Menuefensters. Weichen sie ab, zeigt der Strahl neben das, was man sieht -- unter
    // OpenXR deshalb direkt die Werte, mit denen der Quad-Layer gerade angehaengt wird
    // (dort ist der Ausschnitt zusaetzlich auf das Rendertarget begrenzt).
    auto panel_width = 0.25f;
    auto panel_height = panel_width * (window_size.y / window_size.x);

    if (vr->get_runtime()->is_openxr()) {
        panel_width = vr->m_openxr->ui_width;
        panel_height = vr->m_openxr->ui_height;
    }

    const auto panel = compute_panel_transform();

    // [POINTER_PITCH 2026-08-15] Der Strahl kommt aus der GRIFF-Pose, deren -Z die Achse des
    // Griffs ist -- nicht die Zeigerichtung. Deshalb hier eine Drehung um die EIGENE X-Achse
    // des Controllers (Rechtsmultiplikation, damit sie mitwandert statt im Raum zu stehen).
    // Die Position bleibt dabei unangetastet: (A * R)[3] == A[3], solange R rein rotatorisch ist.
    auto hand = vr->get_transform(hand_transform_index(true));

    const auto pointer_pitch = glm::radians(vr->get_overlay_pointer_pitch());

    if (pointer_pitch != 0.0f) {
        hand = hand * Matrix4x4f{glm::angleAxis(pointer_pitch, glm::vec3{1.0f, 0.0f, 0.0f})};
    }

    const auto hit = ray_vs_panel(panel, panel_width, panel_height, hand);

    if (!hit.hit) {
        hide_cursor();
        return;
    }

    // Der sichtbare Zeiger: ImGui zeichnet seinen Cursor an der Trefferstelle mit ins
    // Menue. Ein Strahl durch den Raum waere ein eigener 3D-Renderer -- der Cursor sagt
    // dasselbe und sieht in beiden Runtimes gleich aus.
    m_pointer_cursor_shown = true;

    m_pointer_last_pos = ImVec2{
        window_pos.x + (hit.u * window_size.x),
        window_pos.y + (hit.v * window_size.y)
    };

    io.MousePos = m_pointer_last_pos;

    const auto trigger_down = vr->is_action_active(vr->get_action_trigger(), vr->get_right_joystick());

    if (trigger_down != m_pointer_mouse_down) {
        m_pointer_mouse_down = trigger_down;
        io.MouseDown[0] = trigger_down;
        io.AddMouseButtonEvent(0, trigger_down);
    }

    const auto stick = vr->get_right_stick_axis();

    if (std::abs(stick.y) > 0.2f) {
        io.MouseWheel += stick.y * 0.25f;
    }
}

// ---------------------------------------------------------------------------
// OpenVR: Anzeige ueber das SteamVR-Overlay
// ---------------------------------------------------------------------------
void OverlayComponent::update_overlay() {
    auto& vr = VR::get();

    if (!vr->get_runtime()->is_openvr()) {
        return;
    }

    const auto is_d3d11 = g_framework->get_renderer_type() == REFramework::RendererType::D3D11;

    const auto last_window_pos = g_framework->get_last_window_pos();
    const auto last_window_size = g_framework->get_last_window_size();
    const auto render_target_width = is_d3d11 ? g_framework->get_rendertarget_width_d3d11() : g_framework->get_rendertarget_width_d3d12();
    const auto render_target_height = is_d3d11 ? g_framework->get_rendertarget_height_d3d11() : g_framework->get_rendertarget_height_d3d12();

    // Sichtbarer Ausschnitt = das Menuefenster im Rendertarget. Nur neu setzen, wenn sich
    // Fenster oder Rendertarget geaendert haben.
    if (m_overlay_data.last_x != last_window_pos.x || m_overlay_data.last_y != last_window_pos.y ||
        m_overlay_data.last_width != last_window_size.x || m_overlay_data.last_height != last_window_size.y ||
        m_overlay_data.last_render_target_width != render_target_width ||
        m_overlay_data.last_render_target_height != render_target_height)
    {
        vr::VRTextureBounds_t bounds{};
        bounds.uMin = last_window_pos.x / render_target_width;
        bounds.uMax = (last_window_pos.x + last_window_size.x) / render_target_width;
        bounds.vMin = last_window_pos.y / render_target_height;
        bounds.vMax = (last_window_pos.y + last_window_size.y) / render_target_height;

        vr::VROverlay()->SetOverlayTextureBounds(m_overlay_handle, &bounds);

        m_overlay_data.last_x = last_window_pos.x;
        m_overlay_data.last_y = last_window_pos.y;
        m_overlay_data.last_width = last_window_size.x;
        m_overlay_data.last_height = last_window_size.y;
        m_overlay_data.last_render_target_width = render_target_width;
        m_overlay_data.last_render_target_height = render_target_height;
    }

    const auto panel = compute_panel_transform();
    const auto steamvr_transform = Matrix3x4f{ glm::rowMajor4(panel) };

    vr::VROverlay()->SetOverlayTransformAbsolute(m_overlay_handle,
        vr::ETrackingUniverseOrigin::TrackingUniverseStanding, (vr::HmdMatrix34_t*)&steamvr_transform);

    // Solange das Menue offen ist, zeigt das Overlay das Rendertarget, sonst eine leere
    // Textur. Nicht HideOverlay: ein verstecktes Overlay muesste beim Oeffnen erst wieder
    // hochkommen, die leere Textur ist der ruhigere Weg.
    const auto drawing_ui = g_framework->is_drawing_ui();

    if (is_d3d11) {
        auto rt = drawing_ui ? g_framework->get_rendertarget_d3d11() : g_framework->get_blank_rendertarget_d3d11();
        vr::Texture_t imgui_tex{(void*)rt.Get(), vr::TextureType_DirectX, vr::ColorSpace_Auto};
        vr::VROverlay()->SetOverlayTexture(m_overlay_handle, &imgui_tex);
    } else {
        auto& hook = g_framework->get_d3d12_hook();

        vr::D3D12TextureData_t texture_data {
            drawing_ui ? g_framework->get_rendertarget_d3d12().Get() : g_framework->get_blank_rendertarget_d3d12().Get(),
            hook->get_command_queue(),
            0
        };

        vr::Texture_t imgui_tex{(void*)&texture_data, vr::TextureType_DirectX12, vr::ColorSpace_Auto};
        vr::VROverlay()->SetOverlayTexture(m_overlay_handle, &imgui_tex);
    }
}

// ---------------------------------------------------------------------------
// OpenXR: Anzeige ueber einen Quad-Layer
// ---------------------------------------------------------------------------
// OpenXR kennt keine Overlays, deshalb ist das Menue hier ein eigener Compositor-Layer
// mit eigener Swapchain (angelegt in D3D12Component::OpenXR::create_swapchains, gefuellt
// in D3D12Component::on_frame, angehaengt in OpenXR::end_frame). Pose und Ausschnitt
// stellen wir hier -- ansonsten verhaelt es sich genau wie der OpenVR-Weg darueber.
void OverlayComponent::update_openxr() {
    auto& vr = VR::get();

    if (!vr->get_runtime()->is_openxr() || !vr->m_openxr->ready()) {
        return;
    }

    // Wie die Flatscreen-Leinwand nur D3D12: die Slate-Swapchain gibt es nur dort.
    if (g_framework->get_renderer_type() != REFramework::RendererType::D3D12) {
        return;
    }

    auto& xr = vr->m_openxr;

    const auto window_pos = g_framework->get_last_window_pos();
    const auto window_size = g_framework->get_last_window_size();
    const auto rt_width = (float)g_framework->get_rendertarget_width_d3d12();
    const auto rt_height = (float)g_framework->get_rendertarget_height_d3d12();

    if (window_size.x < 1.0f || window_size.y < 1.0f || rt_width < 1.0f || rt_height < 1.0f) {
        xr->ui_layer = false;
        return;
    }

    // Sichtbarer Ausschnitt der Swapchain = das Menuefenster, das Gegenstueck zu
    // SetOverlayTextureBounds unter OpenVR.
    const auto rect_x = std::clamp(window_pos.x, 0.0f, rt_width);
    const auto rect_y = std::clamp(window_pos.y, 0.0f, rt_height);
    const auto rect_w = std::clamp(window_size.x, 1.0f, rt_width - rect_x);
    const auto rect_h = std::clamp(window_size.y, 1.0f, rt_height - rect_y);

    xr->ui_rect.offset = {(int32_t)rect_x, (int32_t)rect_y};
    xr->ui_rect.extent = {(int32_t)rect_w, (int32_t)rect_h};

    // Breite wie das SteamVR-Overlay (0.25 m), Hoehe aus dem Seitenverhaeltnis.
    xr->ui_width = 0.25f;
    xr->ui_height = xr->ui_width * (rect_h / rect_w);

    const auto panel = compute_panel_transform();
    const auto panel_orientation = glm::normalize(glm::quat{glm::extractMatrixRotation(panel)});

    xr->ui_pose.orientation = {panel_orientation.x, panel_orientation.y, panel_orientation.z, panel_orientation.w};
    xr->ui_pose.position = {panel[3].x, panel[3].y, panel[3].z};

    // Der Layer wird nur angehaengt, solange das Menue offen ist -- D3D12Component kopiert
    // dann auch nur dann.
    xr->ui_layer = g_framework->is_drawing_ui();
}
}
