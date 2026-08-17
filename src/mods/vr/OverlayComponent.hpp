#pragma once

#include <string>
#include <optional>
#include <cstdint>

#include "imgui.h"

namespace vrmod{
class OverlayComponent {
public:
    void on_reset();
    std::optional<std::string> on_initialize_openvr();

    void on_pre_imgui_frame();
    // Laeuft INNERHALB des ImGui-Frames (REFramework::call_on_frame, direkt nach
    // ImGui::NewFrame) -- nur dort darf in eine DrawList gezeichnet werden.
    void on_frame();
    void on_post_compositor_submit();

private:
    // Cached data for imgui VR overlay so we know when we need to update it
    // instead of doing it constantly every frame
    struct {
        uint32_t last_render_target_width{};
        uint32_t last_render_target_height{};
        float last_width{};
        float last_height{};
        float last_x{};
        float last_y{};
    } m_overlay_data;

    // overlay handle
    vr::VROverlayHandle_t m_overlay_handle{};
    vr::VROverlayHandle_t m_thumbnail_handle{};

    // Anzeige des Menues, je Runtime: SteamVR-Overlay bzw. OpenXR-Quad-Layer.
    // Beide zeigen dasselbe Menue an derselben Stelle; geoeffnet wird es ueber die
    // Menue-Taste (Insert), spaeter zusaetzlich aus Lua. Zeigetests und Controller-
    // Eingaben gibt es bewusst keine.
    void update_overlay();
    void update_openxr();

    // [XR_UI_POINTER 2026-08-14] Auswaehlen mit der rechten Hand, in BEIDEN Runtimes gleich:
    // Strahl auf die Menueflaeche -> Mausposition, Trigger -> Klick, rechter Stick -> Rad.
    // Laeuft NUR, solange das Menue offen ist; oeffnen tut es weiterhin allein die
    // Tastenkombination (LT + linkes B) bzw. Insert.
    void update_pointer();

    bool m_pointer_mouse_down{false};
    // ImGui zeichnet seinen eigenen Cursor, damit man SIEHT, wohin man zeigt: einen echten
    // Strahl durch den Raum gibt es nicht mehr (der kam frueher von SteamVR, und OpenXR
    // hat dafuer gar nichts). Gemerkt, um ihn nur bei Wechseln umzuschalten.
    bool m_pointer_cursor_shown{false};
    // Zuletzt gesetzte Zeigerposition. Muss gemerkt werden, weil ImGui bei Multipass
    // mehrfach pro Augenpaar aufgebaut wird und der Win32-Backend dazwischen die echte
    // Desktop-Maus einsetzt -- ohne Zurueckschreiben springt der Zeiger hin und her.
    ImVec2 m_pointer_last_pos{};

    // Pose der Menueflaeche: linke Hand samt Overlay-Offsets, ohne getrackte Hand vor dem
    // Kopf. Hier statt in einer freien Funktion, weil die Offsets private VR-Member sind.
    // (Keine OpenXR-Typen in diesem Header: VR.hpp bindet uns VOR OpenXR.hpp ein.)
    Matrix4x4f compute_panel_transform() const;
    uint32_t hand_transform_index(bool right) const;
    bool is_hand_valid(bool right) const;
};}
