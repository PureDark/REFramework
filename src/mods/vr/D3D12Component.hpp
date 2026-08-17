#pragma once

#include <array>
#include <optional>

#include <d3d11.h>
#include <d3d12.h>
#include <dxgi.h>
#include <mutex>
#include <wrl.h>

#include <../../directxtk12-src/Inc/GraphicsMemory.h>
#include <../../directxtk12-src/Inc/SpriteBatch.h>

#include "d3d12/CommandContext.hpp"
#include "d3d12/TextureContext.hpp"

#define XR_USE_PLATFORM_WIN32
#define XR_USE_GRAPHICS_API_D3D11
#define XR_USE_GRAPHICS_API_D3D12
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include <openvr.h>

#include "PDAFWPlugin.h"

class VR;

namespace vrmod {
class D3D12Component {
public:
    vr::EVRCompositorError on_frame(VR* vr);
    void on_post_present(VR* vr);

    void on_reset(VR* vr);

    void force_reset() { m_force_reset = true; }

    const auto& get_backbuffer_size() const { return m_backbuffer_size; }

    auto is_initialized() const { return m_openvr.left_eye_tex[0].texture != nullptr; }

    auto& openxr() { return m_openxr; }

    auto& get_sprite_batch() {
        return m_sprite_batch;
    }

private:
    void setup();
    void setup_sprite_batch_pso(DXGI_FORMAT output_format);

    // Flatscreen canvas: shows the finished frame as a flat SteamVR overlay quad.
    // Entirely self-contained - it owns its handle and its own copy of the frame and
    // touches none of the eye textures. Does nothing while VR::is_flatscreen_overlay()
    // is false, which is the default.
    void update_flatscreen_overlay(VR* vr, ID3D12Resource* frame, ID3D12CommandQueue* queue);
    void reset_flatscreen_overlay();
    void render_srv_to_rtv(ID3D12GraphicsCommandList* command_list, const d3d12::TextureContext& src, const d3d12::TextureContext& dst, D3D12_RESOURCE_STATES src_state, D3D12_RESOURCE_STATES dst_state);

    template <typename T> using ComPtr = Microsoft::WRL::ComPtr<T>;

    EyeFrameBuffers m_eyeFrameBuffers;

    ComPtr<ID3D12Resource> m_prev_backbuffer{};
    d3d12::TextureContext m_backbuffer_copy{};
    d3d12::TextureContext m_converted_eye_tex{};
    std::array<d3d12::CommandContext, 3> m_generic_copiers{};
    std::array<d3d12::CommandContext, 3> m_backbuffer_copy_commands{};
    
    std::unique_ptr<DirectX::DX12::SpriteBatch> m_sprite_batch{};

    // Mimicking what OpenXR does.
    struct OpenVR {
        d3d12::TextureContext& get_left() {
            auto& ctx = this->left_eye_tex[this->texture_counter % left_eye_tex.size()];

            return ctx;
        }

        d3d12::TextureContext& get_right() {
            auto& ctx = this->right_eye_tex[this->texture_counter % right_eye_tex.size()];

            return ctx;
        }

        d3d12::TextureContext& acquire_left() {
            auto& ctx = get_left();
            ctx.commands.wait(INFINITE);

            return ctx;
        }

        d3d12::TextureContext& acquire_right() {
            auto& ctx = get_right();
            ctx.commands.wait(INFINITE);

            return ctx;
        }

        void copy_left(ID3D12Resource* src, D3D12_RESOURCE_STATES src_state = D3D12_RESOURCE_STATE_PRESENT) {
            auto& ctx = this->acquire_left();
            ctx.commands.copy(src, ctx.texture.Get(), src_state, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            ctx.commands.execute();
        }

        void copy_right(ID3D12Resource* src, D3D12_RESOURCE_STATES src_state = D3D12_RESOURCE_STATE_PRESENT) {
            auto& ctx = this->acquire_right();
            ctx.commands.copy(src, ctx.texture.Get(), src_state, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            ctx.commands.execute();
        }

        // Same as the copies, but the eye gets black instead of the frame (VR::get_blank_eye).
        void clear_left() {
            auto& ctx = this->acquire_left();
            const float black[4]{0.0f, 0.0f, 0.0f, 1.0f};
            ctx.commands.clear_rtv(ctx, black, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            ctx.commands.execute();
        }

        void clear_right() {
            auto& ctx = this->acquire_right();
            const float black[4]{0.0f, 0.0f, 0.0f, 1.0f};
            ctx.commands.clear_rtv(ctx, black, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            ctx.commands.execute();
        }

        // Ringgroesse bleibt die des AFW-Forks (1 statt 3) - dessen Renderpfad haengt daran.
        std::array<d3d12::TextureContext, 1> left_eye_tex{};
        std::array<d3d12::TextureContext, 1> right_eye_tex{};
        uint32_t texture_counter{0};
        DXGI_FORMAT last_format{};
    } m_openvr;

    struct OpenXR {
        void initialize(XrSessionCreateInfo& session_info);
        std::optional<std::string> create_swapchains();
        void destroy_swapchains();
        using CopyFn = std::function<void(d3d12::CommandContext& ctx, d3d12::TextureContext& dst, D3D12_RESOURCE_STATES src_state, D3D12_RESOURCE_STATES dst_state)>;
        void copy(uint32_t swapchain_idx, ID3D12Resource* src, D3D12_BOX* src_box, D3D12_RESOURCE_STATES src_state, CopyFn copy_fn = nullptr);
        void wait_for_all_copies() {
            std::scoped_lock _{this->mtx};

            for (auto& ctx : this->contexts) {
                for (auto& texture_ctx : ctx.texture_contexts) {
                    // [XR_EYE_RTV 2026-08-15] Seit die Kontexte erst NACH dem Enumerieren
                    // angelegt werden, kann hier ein leerer Platz stehen, wenn create_swapchains
                    // vorher mit einem Fehler aussteigt -- destroy_swapchains raeumt dann ueber
                    // genau diese Liste. Ohne die Pruefung waere das ein Absturz statt eines Logs.
                    if (texture_ctx == nullptr) {
                        continue;
                    }

                    texture_ctx->commands.wait(INFINITE);
                }
            }
        }

        XrGraphicsBindingD3D12KHR binding{XR_TYPE_GRAPHICS_BINDING_D3D12_KHR};

        struct SwapchainContext {
            std::vector<XrSwapchainImageD3D12KHR> textures{};
            std::vector<std::unique_ptr<d3d12::TextureContext>> texture_contexts{};
            uint32_t num_textures_acquired{0};
        };

        std::vector<SwapchainContext> contexts{};
        std::recursive_mutex mtx{};
        std::array<uint32_t, 2> last_resolution{};
        DXGI_FORMAT last_format{};
    } m_openxr;

    struct FlatscreenOverlay {
        vr::VROverlayHandle_t handle{vr::k_ulOverlayHandleInvalid};
        d3d12::TextureContext tex{};
        uint32_t size[2]{};
        DXGI_FORMAT format{DXGI_FORMAT_UNKNOWN};
        bool shown{false};
        bool failed{false};   // creation failed once - don't retry every frame
    } m_flatscreen_overlay;

    uint32_t m_backbuffer_size[2]{};
    bool m_backbuffer_is_8bit{false};
    bool m_force_reset{false};
};
} // namespace vrmod
