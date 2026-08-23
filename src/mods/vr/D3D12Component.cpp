#include <openvr.h>
#include <utility/ScopeGuard.hpp>
#include <utility/Profiler.hpp>

#include "../VR.hpp"
#include "../TemporalUpscaler.hpp"

#include <../../directxtk12-src/Inc/ResourceUploadBatch.h>
#include <../../directxtk12-src/Inc/RenderTargetState.h>
#include <../../directxtk12-src/Src/d3dx12.h>

#include "d3d12/DirectXTK.hpp"

#include "D3D12Component.hpp"

namespace vrmod {
vr::EVRCompositorError D3D12Component::on_frame(VR* vr) {
    REF_PROFILE_FUNCTION();

    if (m_openvr.left_eye_tex[0].texture == nullptr || m_force_reset) {
        setup();
    }

    auto& hook = g_framework->get_d3d12_hook();
    
    // get device
    auto device = hook->get_device();

    // get command queue
    auto command_queue = hook->get_command_queue();

    // get swapchain
    auto swapchain = hook->get_swap_chain();

    // get back buffer
    ComPtr<ID3D12Resource> backbuffer{};

    const auto backbuffer_index = swapchain->GetCurrentBackBufferIndex();

    if (FAILED(swapchain->GetBuffer(backbuffer_index, IID_PPV_ARGS(&backbuffer)))) {
        spdlog::error("[VR] Failed to get back buffer");
        return vr::VRCompositorError_None;
    }

    if (backbuffer == nullptr) {
        spdlog::error("[VR] Failed to get back buffer.");
        return vr::VRCompositorError_None;
    }

    // TODO: Correct this for the upscaler...?
    if (!m_backbuffer_is_8bit && (!vr->is_using_multipass() || (vr->m_multipass.eye_textures[0] != nullptr && vr->m_multipass.eye_textures[1]!= nullptr))) {
        auto& commands = m_backbuffer_copy_commands[backbuffer_index % m_backbuffer_copy_commands.size()];
        auto command_list = commands.cmd_list.Get();
        commands.wait(INFINITE);

        // Copy current backbuffer into our copy so we can use it as an SRV.
        commands.copy(backbuffer.Get(), m_backbuffer_copy.texture.Get(), D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_PRESENT);

        float clear_color[4]{0.0f, 0.0f, 0.0f, 0.0f};
        commands.clear_rtv(m_converted_eye_tex, clear_color, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);

        // Convert the backbuffer to 8-bit.
        render_srv_to_rtv(command_list, m_backbuffer_copy, m_converted_eye_tex, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);

        commands.execute();
    }

    auto eye_texture = m_backbuffer_is_8bit ? backbuffer : m_converted_eye_tex.texture;

    // --- Ein Auge schwarz unter OpenXR -----------------------------------
    // Das gab es bisher nur im OpenVR-Zweig (clear_left/clear_right). Unter OpenXR
    // wurde `get_blank_eye()` gar nicht ausgewertet, das Auge blieb hell -- damit war
    // das Scope-Bild dort unbrauchbar, obwohl Mono und Zoom laengst runtime-unabhaengig
    // arbeiten. `copy()` nimmt ohnehin eine CopyFn (der Multipass-Zweig nutzt sie
    // bereits), also wird hier statt des Bildes einfach der Rendertarget geleert.
    // Rueckgabe nullptr = ganz normal kopieren, es aendert sich also nichts, solange
    // weder ein Auge geschwaerzt noch die Leinwand aktiv ist.
    auto xr_black = [](d3d12::CommandContext& cmds, d3d12::TextureContext& dst,
                       D3D12_RESOURCE_STATES src_state, D3D12_RESOURCE_STATES dst_state) {
        const float black[4]{0.0f, 0.0f, 0.0f, 1.0f};
        cmds.clear_rtv(dst, black, dst_state);
    };

    auto xr_fn = [&](uint32_t eye) -> OpenXR::CopyFn {
        if (vr->should_blank_all_eyes() || vr->get_blank_eye() == (int32_t)eye) {
            return xr_black;
        }

        return nullptr;
    };

    // [BLANK_EYE DIAG 2026-08-14] Nur bei ZUSTANDSWECHSEL schreiben, sonst Logflut.
    // Zeigt, ob der Schwaerz-Wunsch ueberhaupt in der DLL ankommt und welcher Kopierzweig
    // unter OpenXR gerade laeuft -- genau daran haengt, ob die CopyFn zieht.
    // Wieder RAUS, sobald das linke Auge im Scope schwarz wird.
    // (vr->get_runtime() statt des lokalen `runtime` -- das wird erst weiter unten angelegt)
    if (vr->get_runtime()->is_openxr()) {
        static int32_t s_last_blank = -99;
        static int32_t s_last_branch = -99;

        const auto is_mp = vr->is_using_multipass();
        const auto has_mp_tex = vr->m_multipass.eye_textures[0].Get() != nullptr &&
                                vr->m_multipass.eye_textures[1].Get() != nullptr;
        const auto upscaler_ready = TemporalUpscaler::get()->ready();
        // 0 = AFR/AFW-Zweig, 1 = Multipass mit Eye-Texturen, 2 = Multipass ohne (ctx0/ctx1)
        const int32_t branch = !is_mp ? 0 : (has_mp_tex ? 1 : 2);

        if (vr->get_blank_eye() != s_last_blank || branch != s_last_branch) {
            s_last_blank = vr->get_blank_eye();
            s_last_branch = branch;

            spdlog::info("[VR][BLANK_EYE] blank_eye={} blank_all={} branch={} multipass={} mp_tex={} upscaler={}",
                vr->get_blank_eye(), vr->should_blank_all_eyes(), branch, is_mp, has_mp_tex, upscaler_ready);
        }
    }


    auto runtime = vr->get_runtime();

    // Flatscreen canvas. Purely additive: it only reads the finished frame and drives its
    // own overlay, so with the feature off (the default) nothing below changes at all.
    if (runtime->is_openvr()) {
        update_flatscreen_overlay(vr, eye_texture.Get(), command_queue);
    } else if (runtime->is_openxr() && vr->m_openxr->ready()) {
        // Zustand und Masse an die Runtime durchreichen -- OpenXR.cpp haengt das Quad
        // daran auf und darf VR.hpp nicht einbinden (Zyklus).
        vr->m_openxr->flatscreen_layer = vr->is_flatscreen_overlay();
        vr->m_openxr->flatscreen_width = vr->get_flatscreen_overlay_width();
        vr->m_openxr->flatscreen_distance = vr->get_flatscreen_overlay_distance();
    }

    if (runtime->is_openxr() && vr->is_flatscreen_overlay() && vr->m_openxr->ready()) {
        // OpenXR kennt keine Overlays -- dort ist die Leinwand ein zweiter Compositor-
        // Layer (Quad). Hier wird nur der fertige Frame in dessen eigene Swapchain
        // kopiert; aufgehaengt wird das Quad in OpenXR::end_frame.
        const auto canvas_idx = (uint32_t)vr->m_openxr->views.size();

        if (this->m_openxr.contexts.size() > canvas_idx) {
            m_openxr.copy(canvas_idx, eye_texture.Get(), nullptr, D3D12_RESOURCE_STATE_PRESENT);
        }
    }

    // [XR_UI_OVERLAY 2026-08-14] Das Menue-Rendertarget in die Slate-Swapchain kopieren.
    // ui_layer setzt OverlayComponent, sobald das Menue offen ist -- ist es zu, wird hier
    // gar nichts getan, der Layer wird dann auch nicht angehaengt.
    if (runtime->is_openxr() && vr->m_openxr->ready() && vr->m_openxr->ui_layer) {
        const auto ui_idx = (uint32_t)vr->m_openxr->views.size() + 1;
        auto& ui_rt = g_framework->get_rendertarget_d3d12();

        if (this->m_openxr.contexts.size() > ui_idx && ui_rt.Get() != nullptr) {
            // Das Rendertarget ruht als PIXEL_SHADER_RESOURCE -- REFramework schaltet es
            // nur zum Zeichnen kurz auf RENDER_TARGET und danach wieder zurueck.
            m_openxr.copy(ui_idx, ui_rt.Get(), nullptr, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        }
    }

    // Sometimes this can happen if pipeline execution does not go exactly as planned
    // so we need to resynchronized or begin the frame again.
    if (runtime->ready()) {
        runtime->fix_frame();
    }

    const auto frame_count = vr->m_render_frame_count;

    
    //#############################
    //#Frame Warp Module Start
    //#############################
    EyeIndex nEye = (frame_count % 2 == vr->m_left_eye_interval) ? EyeLeft : EyeRight;
    EyeIndex nEyeOther = (frame_count % 2 == vr->m_left_eye_interval) ? EyeRight : EyeLeft;
    FrameWarpEvaluateParams params;
    if (vr->is_using_afw() && (!m_eyeFrameBuffers.eyeFrameBuffers[0].color.pTexture || !m_eyeFrameBuffers.eyeFrameBuffers[1].color.pTexture))
        force_reset();
    if (vr->is_using_afw() && m_eyeFrameBuffers.eyeFrameBuffers[0].color.pTexture && 
        vr->m_eye_states[nEye].depth_copy && vr->m_eye_states[nEye].motion_vectors_copy && vr->m_framewarp_mode->value() > 0) {
        static TextureDesc texDesc[6];
        int texIndex = m_backbuffer_is_8bit ? backbuffer_index : 3;
        if (texDesc[texIndex].pTexture != eye_texture.Get()) {
            texDesc[texIndex].pTexture = eye_texture.Get();
            texDesc[texIndex].initialState = D3D12_RESOURCE_STATE_PRESENT;
            texDesc[texIndex].srvPos = vr->d3d12Renderer->CreateSRV(texDesc[texIndex].pTexture, texDesc[texIndex].srvPos);
            texDesc[texIndex].shaderResourceViewHandle = vr->d3d12Renderer->GetGPUDescriptorHandle(texDesc[texIndex].srvPos);
        }

        const auto& state = vr->m_eye_states[nEye];

        const auto motion_vectors = state.motion_vectors_copy->get_d3d12_resource_container()->get_native_resource();
        const auto depth = state.depth_copy->get_d3d12_resource_container()->get_native_resource();

        static TextureDesc depthDesc[2];
        if (depthDesc[nEye].pTexture != depth) {
            depthDesc[nEye].pTexture = depth;
            depthDesc[nEye].initialState = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
            depthDesc[nEye].srvPos = vr->d3d12Renderer->CreateSRV(depthDesc[nEye].pTexture, depthDesc[nEye].srvPos);
            depthDesc[nEye].shaderResourceViewHandle = vr->d3d12Renderer->GetGPUDescriptorHandle(depthDesc[nEye].srvPos);
        }
        static TextureDesc motionVectorsDesc[2];
        if (motionVectorsDesc[nEye].pTexture != motion_vectors) {
            motionVectorsDesc[nEye].pTexture = motion_vectors;
            motionVectorsDesc[nEye].initialState = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
            motionVectorsDesc[nEye].srvPos = vr->d3d12Renderer->CreateSRV(motionVectorsDesc[nEye].pTexture, motionVectorsDesc[nEye].srvPos);
            motionVectorsDesc[nEye].shaderResourceViewHandle = vr->d3d12Renderer->GetGPUDescriptorHandle(motionVectorsDesc[nEye].srvPos);
        }
        static TextureDesc uiBufferDesc[2];
        if (vr->m_enable_ui_fix->value() && state.uiBufferTex) {
            uiBufferDesc[nEye].pTexture = state.uiBufferTex.Get();
            uiBufferDesc[nEye].initialState = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
            uiBufferDesc[nEye].srvPos = vr->d3d12Renderer->CreateSRV(uiBufferDesc[nEye].pTexture, uiBufferDesc[nEye].srvPos);
            uiBufferDesc[nEye].shaderResourceViewHandle = vr->d3d12Renderer->GetGPUDescriptorHandle(uiBufferDesc[nEye].srvPos);
            uiBufferDesc[nEye].renderTargetViewHandle = vr->d3d12Renderer->GetRTV(uiBufferDesc[nEye].pTexture);
        }
        static FrameBufferDesc s_CurrentEyeFrameBuffer{};

        s_CurrentEyeFrameBuffer.color = texDesc[texIndex];
        s_CurrentEyeFrameBuffer.depth = depthDesc[nEye];
        s_CurrentEyeFrameBuffer.motionVectors = motionVectorsDesc[nEye];

        auto cmdList = vr->d3d12Renderer->BeginCommandList(backbuffer_index);
        params.InCmdList = cmdList;
        params.InEyeFrameBuffer = &s_CurrentEyeFrameBuffer;
        if (vr->m_enable_ui_fix->value() && state.uiBufferTex) {
            params.InUIColorAlpha = &uiBufferDesc[nEye];
            params.IsHudlessColor = false;
        } else if (vr->m_enable_ui_fix->value() && TemporalUpscaler::get()->is_enabled_ui_fix() &&
                   TemporalUpscaler::get()->extractedUIBufferDesc[nEye].pTexture) {
            params.InUIColorAlpha = &TemporalUpscaler::get()->extractedUIBufferDesc[nEye];
            params.IsHudlessColor = false;
        } else {
            params.InUIColorAlpha = NULL;
            params.IsHudlessColor = true;
        }

        auto colorDesc = s_CurrentEyeFrameBuffer.color.pTexture->GetDesc();

        params.MotionVectorsType = TemporalUpscaler::get()->activated() ? Normal : FromOtherEye;
        params.InMotionScale[0] = (float)colorDesc.Width / 2.0f;
        params.InMotionScale[1] = -1.0f * ((float)colorDesc.Height / 2.0f);
        params.Mode = (FrameWarpMode)vr->m_framewarp_mode->value();
        params.EyeIndex = nEye;
        params.ClearBeforeWarping = vr->m_clear_before_framewarp->value();
        params.CameraData = &vr->cameraData[nEye];
        params.IgnoreMotionThreshold = vr->m_ignore_motion_threshold->value();
        params.Debug = vr->m_framewarp_debug->value();
        EvaluateFrameWarp(params);
        vr->d3d12Renderer->EndCommandList(backbuffer_index);
    }
    //#############################
    //#Frame Warp Module End
    //#############################

    const auto is_multipass = vr->is_using_multipass();
    auto eye_format = DXGI_FORMAT_UNKNOWN;
    if (is_multipass && (vr->m_multipass.eye_textures[0] != nullptr && vr->m_multipass.eye_textures[1] != nullptr)) {
        const auto eye_desc = vr->m_multipass.eye_textures[0]->GetDesc();
        eye_format = eye_desc.Format;
    } else {
        eye_format = backbuffer->GetDesc().Format;
    }

    if (runtime->is_openxr()) {
        if (eye_format != m_openxr.last_format) {
            spdlog::info("[VR] OpenXR format changed from {} to {}", m_openxr.last_format, eye_format);
            m_openxr.create_swapchains();
        }
    } else {
        if (eye_format != m_openvr.last_format) {
            spdlog::info("[VR] OpenVR format changed from {} to {}", m_openvr.last_format, eye_format);
            on_reset(vr);
            setup();
        }
    }

    // If m_frame_count is even, we're rendering the left eye.
    if (frame_count % 2 == vr->m_left_eye_interval && !is_multipass) {
        // OpenXR texture
        if (runtime->is_openxr() && vr->m_openxr->ready()) {
            // Quelle und Resource-State bleiben die des AFW-Forks; ergaenzt ist nur die
            // CopyFn, mit der ein Auge unter OpenXR schwarz bleibt (VR::get_blank_eye).
            m_openxr.copy(0, m_openvr.get_left().texture.Get(), nullptr, D3D12_RESOURCE_STATE_ALL_SHADER_RESOURCE, xr_fn(0));
            if (vr->is_using_afw()) {
                m_openxr.copy(1, m_openvr.get_right().texture.Get(), nullptr, D3D12_RESOURCE_STATE_ALL_SHADER_RESOURCE, xr_fn(1));
            }
        }

        // OpenVR texture
        // Copy the back buffer to the left eye texture (m_left_eye_tex0 holds the intermediate frame).
        if (runtime->is_openvr()) {
            // get_blank_eye(): that eye gets black instead of the frame (scope aiming).
            // should_blank_all_eyes(): canvas mode - nothing but the quad may be visible.
            if (vr->get_blank_eye() == 0 || vr->should_blank_all_eyes()) {
                m_openvr.clear_left();
            } else {
                m_openvr.copy_left(eye_texture.Get());
            }

            vr::D3D12TextureData_t left {
                m_openvr.get_left().texture.Get(),
                command_queue,
                0
            };
            
            // [POSE_FREEZE 2026-08-11] Im Scope ist das Bild bewusst kopfunabhaengig.
            // Ohne Angabe nimmt SteamVR seine eigene Pose an und reprojiziert dagegen.
            // Modus 1 gibt die eingefrorene Pose an (Compositor dreht die Differenz nach),
            // Modus 2 die frische (er dreht nichts nach), Modus 0 laesst alles wie frueher.
            vr::VRTextureWithPose_t left_eye{};
            left_eye.handle = (void*)&left;
            left_eye.eType = vr::TextureType_DirectX12;
            left_eye.eColorSpace = vr::ColorSpace_Auto;
            left_eye.mDeviceToAbsoluteTracking = vr->get_submit_pose();

            const auto submit_flags = (vr->is_pose_freeze() && vr->get_pose_freeze_submit() != 0)
                ? (vr::EVRSubmitFlags)(vr::Submit_Default | vr::Submit_TextureWithPose)
                : vr::Submit_Default;

            const auto left_bounds = vr->get_shifted_bounds(false);
            auto e = vr::VRCompositor()->Submit(vr::Eye_Left, (vr::Texture_t*)&left_eye, &left_bounds, submit_flags);

            if (e != vr::VRCompositorError_None) {
                spdlog::error("[VR] VRCompositor failed to submit left eye: {}", (int)e);
                return e;
            }
            if (vr->is_using_afw()) {
                //auto& ctx = m_openvr.acquire_right();
                //if (params.OutEyeFrameBuffer && vr->m_framewarp_mode->value() > 0) {
                //    ctx.commands.copy((ID3D12Resource*)params.OutEyeFrameBuffer->color.pTexture, ctx.texture.Get(), D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
                //}
                //ctx.commands.execute();

                vr::D3D12TextureData_t right{m_openvr.get_right().texture.Get(), command_queue, 0};

                vr::Texture_t right_eye{(void*)&right, vr::TextureType_DirectX12, vr::ColorSpace_Auto};

                auto e = vr::VRCompositor()->Submit(vr::Eye_Right, &right_eye, &vr->m_right_bounds);
                runtime->frame_synced = false;

                if (e != vr::VRCompositorError_None) {
                    spdlog::error("[VR] VRCompositor failed to submit right eye: {}", (int)e);
                    return e;
                } else {
                    vr->m_submitted = true;
                }

                ++m_openvr.texture_counter;
            }
        }
    } else {
        // OpenXR texture
        if (runtime->is_openxr() && vr->m_openxr->ready()) {
            if (is_multipass) {
                /*D3D12_BOX src_box{};
                src_box.back = 1;
                src_box.right = vr->get_hmd_width();
                src_box.bottom = vr->get_hmd_height();
                m_openxr.copy(0, (ID3D12Resource*)vr->m_multipass.eye_textures[0], &src_box, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);

                src_box.left = src_box.right;
                src_box.right *= 2;
                m_openxr.copy(1, (ID3D12Resource*)vr->m_multipass.eye_textures[0], &src_box, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);*/

                if (vr->m_multipass.eye_textures[0].Get() != nullptr && vr->m_multipass.eye_textures[1].Get() != nullptr) {
                    auto& ctx0 = vr->m_multipass.eye_contexts[0];
                    auto& ctx1 = vr->m_multipass.eye_contexts[1];

                    if (ctx0.texture.Get() != vr->m_multipass.eye_textures[0].Get()) {
                        ctx0.reset();
                        const auto desc = vr->m_multipass.eye_textures[0]->GetDesc();
                        ctx0.setup(device, vr->m_multipass.eye_textures[0].Get(), desc.Format, desc.Format);
                    }

                    if (ctx1.texture.Get() != vr->m_multipass.eye_textures[1].Get()) {
                        ctx1.reset();
                        const auto desc = vr->m_multipass.eye_textures[1]->GetDesc();
                        ctx1.setup(device, vr->m_multipass.eye_textures[1].Get(), desc.Format, desc.Format);
                    }

                    if (m_backbuffer_is_8bit) {
                        if (!TemporalUpscaler::get()->ready()) {
                            m_openxr.copy(0, vr->m_multipass.eye_textures[0].Get(), nullptr, D3D12_RESOURCE_STATE_COPY_DEST, xr_fn(0));
                            m_openxr.copy(1, vr->m_multipass.eye_textures[1].Get(), nullptr, D3D12_RESOURCE_STATE_COPY_DEST, xr_fn(1));
                        } else {
                            m_openxr.copy(0, vr->m_multipass.eye_textures[0].Get(), nullptr, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, xr_fn(0));
                            m_openxr.copy(1, vr->m_multipass.eye_textures[1].Get(), nullptr, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, xr_fn(1));
                        }
                    } else {
                        auto copy0fn = [&](d3d12::CommandContext& ctx, d3d12::TextureContext& dst, D3D12_RESOURCE_STATES src_state, D3D12_RESOURCE_STATES dst_state) {
                            const float clear_color[4]{0.0f, 0.0f, 0.0f, 0.0f};
                            ctx.clear_rtv(dst, clear_color, dst_state);
                            render_srv_to_rtv(ctx.cmd_list.Get(), vr->m_multipass.eye_contexts[0], dst, src_state, dst_state);
                        };

                        auto copy1fn = [&](d3d12::CommandContext& ctx, d3d12::TextureContext& dst, D3D12_RESOURCE_STATES src_state, D3D12_RESOURCE_STATES dst_state) {
                            const float clear_color[4]{0.0f, 0.0f, 0.0f, 0.0f};
                            ctx.clear_rtv(dst, clear_color, dst_state);
                            render_srv_to_rtv(ctx.cmd_list.Get(), vr->m_multipass.eye_contexts[1], dst, src_state, dst_state);
                        };

                        if (!TemporalUpscaler::get()->ready()) {
                            m_openxr.copy(0, ctx0.texture.Get(), nullptr, D3D12_RESOURCE_STATE_COPY_DEST, xr_fn(0) ? xr_fn(0) : OpenXR::CopyFn{copy0fn});
                            m_openxr.copy(1, ctx1.texture.Get(), nullptr, D3D12_RESOURCE_STATE_COPY_DEST, xr_fn(1) ? xr_fn(1) : OpenXR::CopyFn{copy1fn});
                        } else {
                            m_openxr.copy(0, ctx0.texture.Get(), nullptr, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, xr_fn(0) ? xr_fn(0) : OpenXR::CopyFn{copy0fn});
                            m_openxr.copy(1, ctx1.texture.Get(), nullptr, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, xr_fn(1) ? xr_fn(1) : OpenXR::CopyFn{copy1fn});
                        }
                    }
                } else {
                    // just copy the backbuffer to both eyes as a fallback
                    m_openxr.copy(0, eye_texture.Get(), nullptr, D3D12_RESOURCE_STATE_PRESENT, xr_fn(0));
                    m_openxr.copy(1, eye_texture.Get(), nullptr, D3D12_RESOURCE_STATE_PRESENT, xr_fn(1));
                }

                vr->m_multipass.eye_textures[0].Reset();
                vr->m_multipass.eye_textures[1].Reset();
            } else {
                // wie oben: AFW-Quelle/State, plus die CopyFn fuer das geschwaerzte Auge
                m_openxr.copy(1, m_openvr.get_right().texture.Get(), nullptr, D3D12_RESOURCE_STATE_ALL_SHADER_RESOURCE, xr_fn(1));
                if (vr->is_using_afw()) {
                    m_openxr.copy(0, m_openvr.get_left().texture.Get(), nullptr, D3D12_RESOURCE_STATE_ALL_SHADER_RESOURCE, xr_fn(0));
                }
            }
        }

        // OpenVR texture
        // Copy the back buffer to the right eye texture.
        if (runtime->is_openvr()) {
            if (is_multipass) {
                if (vr->m_multipass.eye_textures[0].Get() != nullptr && vr->m_multipass.eye_textures[1].Get() != nullptr) {
                    if (!TemporalUpscaler::get()->ready()) {
                        m_openvr.copy_left(vr->m_multipass.eye_textures[0].Get(), D3D12_RESOURCE_STATE_COPY_DEST);
                        m_openvr.copy_right(vr->m_multipass.eye_textures[1].Get(), D3D12_RESOURCE_STATE_COPY_DEST);
                    } else {
                        m_openvr.copy_left(vr->m_multipass.eye_textures[0].Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
                        m_openvr.copy_right(vr->m_multipass.eye_textures[1].Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
                    }
                } else {
                    // just copy the backbuffer to both eyes as a fallback
                    m_openvr.copy_left(eye_texture.Get());
                    m_openvr.copy_right(eye_texture.Get());
                }

                // get_blank_eye(): overwrite that eye with black again (scope aiming).
                // should_blank_all_eyes(): canvas mode - both eyes black.
                if (vr->should_blank_all_eyes()) {
                    m_openvr.clear_left();
                    m_openvr.clear_right();
                } else if (vr->get_blank_eye() == 0) {
                    m_openvr.clear_left();
                } else if (vr->get_blank_eye() == 1) {
                    m_openvr.clear_right();
                }
            } else {
                if (vr->get_blank_eye() == 1 || vr->should_blank_all_eyes()) {
                    m_openvr.clear_right();
                } else {
                    m_openvr.copy_right(eye_texture.Get());
                }
            }

            vr::D3D12TextureData_t right {
                m_openvr.get_right().texture.Get(),
                command_queue,
                0
            };

            // [POSE_FREEZE] siehe oben -- gilt fuer beide Augen und beide Renderwege.
            const auto submit_flags = (vr->is_pose_freeze() && vr->get_pose_freeze_submit() != 0)
                ? (vr::EVRSubmitFlags)(vr::Submit_Default | vr::Submit_TextureWithPose)
                : vr::Submit_Default;
            const auto submit_pose = vr->get_submit_pose();

            vr::VRTextureWithPose_t right_eye{};
            right_eye.handle = (void*)&right;
            right_eye.eType = vr::TextureType_DirectX12;
            right_eye.eColorSpace = vr::ColorSpace_Auto;
            right_eye.mDeviceToAbsoluteTracking = submit_pose;

            if (is_multipass) {
                vr::D3D12TextureData_t left {
                    m_openvr.get_left().texture.Get(),
                    command_queue,
                    0
                };

                vr::VRTextureWithPose_t left_eye{};
                left_eye.handle = (void*)&left;
                left_eye.eType = vr::TextureType_DirectX12;
                left_eye.eColorSpace = vr::ColorSpace_Auto;
                left_eye.mDeviceToAbsoluteTracking = submit_pose;

                const auto left_bounds = vr->get_shifted_bounds(false);
            auto e = vr::VRCompositor()->Submit(vr::Eye_Left, (vr::Texture_t*)&left_eye, &left_bounds, submit_flags);
                runtime->frame_synced = false;

                if (e != vr::VRCompositorError_None) {
                    spdlog::error("[VR] VRCompositor failed to submit left eye: {}", (int)e);
                    return e;
                }
            }

            const auto right_bounds = vr->get_shifted_bounds(true);
            auto e = vr::VRCompositor()->Submit(vr::Eye_Right, (vr::Texture_t*)&right_eye, &right_bounds, submit_flags);

            if (e != vr::VRCompositorError_None) {
                spdlog::error("[VR] VRCompositor failed to submit right eye: {}", (int)e);
                return e;
            } else {
                vr->m_submitted = true;
            }
            if (vr->is_using_afw()) {
                //auto& ctx = m_openvr.acquire_left();
                //if (params.OutEyeFrameBuffer && vr->m_framewarp_mode->value() > 0) {
                //    ctx.commands.copy((ID3D12Resource*)params.OutEyeFrameBuffer->color.pTexture, ctx.texture.Get(), D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
                //}
                //ctx.commands.execute();

                vr::D3D12TextureData_t left{m_openvr.get_left().texture.Get(), command_queue, 0};

                vr::Texture_t left_eye{(void*)&left, vr::TextureType_DirectX12, vr::ColorSpace_Auto};

                auto e = vr::VRCompositor()->Submit(vr::Eye_Left, &left_eye, &vr->m_left_bounds);
                runtime->frame_synced = false;

                if (e != vr::VRCompositorError_None) {
                    spdlog::error("[VR] VRCompositor failed to submit left eye: {}", (int)e);
                    return e;
                }
            }
            ++m_openvr.texture_counter;
        }
    }

    vr::EVRCompositorError e = vr::EVRCompositorError::VRCompositorError_None;

    if (frame_count % 2 == vr->m_right_eye_interval || is_multipass || vr->is_using_afw()) {
        ////////////////////////////////////////////////////////////////////////////////
        // OpenXR start ////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////
        if (runtime->ready() && runtime->get_synchronize_stage() == VRRuntime::SynchronizeStage::VERY_LATE) {
            runtime->synchronize_frame();

            if (!runtime->got_first_poses) {
                runtime->update_poses();
            }
        }

        if (runtime->is_openxr() && vr->m_openxr->ready()) {
            if (runtime->get_synchronize_stage() == VRRuntime::SynchronizeStage::VERY_LATE || !vr->m_openxr->frame_began) {
                vr->m_openxr->begin_frame();
            }

            auto result = vr->m_openxr->end_frame();

            if (result == XR_ERROR_LAYER_INVALID) {
                spdlog::info("[VR] Attempting to correct invalid layer");

                m_openxr.wait_for_all_copies();

                spdlog::info("[VR] Calling xrEndFrame again");
                result = vr->m_openxr->end_frame();
            }

            vr->m_openxr->needs_pose_update = true;
            vr->m_submitted = result == XR_SUCCESS;
        }

        ////////////////////////////////////////////////////////////////////////////////
        // OpenVR start ////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////
        if (runtime->is_openvr()) {
            if (runtime->needs_pose_update) {
                vr->m_submitted = false;
                spdlog::info("[VR] Runtime needed pose update inside present (frame {})", vr->m_frame_count);
                return vr::VRCompositorError_None;
            }

            //++m_openvr.texture_counter;
        }

        // Allows the desktop window to be recorded.
        if (vr->m_desktop_fix->value() && (frame_count % 2 == vr->m_right_eye_interval)) {
            if (runtime->ready() && m_prev_backbuffer != backbuffer && m_prev_backbuffer != nullptr) {
                auto& copier = m_generic_copiers[frame_count % m_generic_copiers.size()];
                copier.wait(INFINITE);
                copier.copy(m_prev_backbuffer.Get(), backbuffer.Get(), D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_PRESENT);
                copier.execute();
            }
        }
    }

    m_prev_backbuffer = backbuffer;

    return e;
}

void D3D12Component::on_post_present(VR* vr) {
}

void D3D12Component::on_reset(VR* vr) {
    REF_PROFILE_FUNCTION();

    auto runtime = vr->get_runtime();

    for (auto& ctx : m_openvr.left_eye_tex) {
        ctx.reset();
    }

    for (auto& ctx : m_openvr.right_eye_tex) {
        ctx.reset();
    }

    for (auto& copier : m_generic_copiers) {
        copier.reset();
    }

    for (auto& commands : m_backbuffer_copy_commands) {
        commands.reset();
    }
    
    m_prev_backbuffer.Reset();
    m_backbuffer_copy.reset();
    m_converted_eye_tex.reset();

    // The canvas holds a device resource too, so it has to go with the rest.
    reset_flatscreen_overlay();

    if (runtime->is_openxr() && runtime->loaded) {
        if (m_openxr.last_resolution[0] != vr->get_hmd_width() || m_openxr.last_resolution[1] != vr->get_hmd_height()) {
            m_openxr.create_swapchains();
        }

        // end the frame before something terrible happens
        //vr->m_openxr.synchronize_frame();
        //vr->m_openxr.begin_frame();
        //vr->m_openxr.end_frame();
    }

    m_openvr.texture_counter = 0;
}

void D3D12Component::reset_flatscreen_overlay() {
    auto& ov = m_flatscreen_overlay;

    if (ov.handle != vr::k_ulOverlayHandleInvalid && vr::VROverlay() != nullptr) {
        vr::VROverlay()->DestroyOverlay(ov.handle);
    }

    ov.handle = vr::k_ulOverlayHandleInvalid;
    ov.tex.reset();
    ov.size[0] = 0;
    ov.size[1] = 0;
    ov.format = DXGI_FORMAT_UNKNOWN;
    ov.shown = false;
    ov.failed = false;
}

void D3D12Component::update_flatscreen_overlay(VR* vr, ID3D12Resource* frame, ID3D12CommandQueue* queue) {
    auto& ov = m_flatscreen_overlay;

    // Switched off: hide once, then stay out of the way entirely.
    if (!vr->is_flatscreen_overlay()) {
        if (ov.shown && ov.handle != vr::k_ulOverlayHandleInvalid && vr::VROverlay() != nullptr) {
            vr::VROverlay()->HideOverlay(ov.handle);
            ov.shown = false;
        }

        return;
    }

    // ov.failed: something went wrong once - never retry every frame, that would flood the log.
    if (ov.failed || frame == nullptr || queue == nullptr || vr::VROverlay() == nullptr) {
        return;
    }

    auto& hook = g_framework->get_d3d12_hook();
    auto device = hook->get_device();

    if (device == nullptr) {
        return;
    }

    const auto desc = frame->GetDesc();

    // Our own copy of the frame, recreated whenever resolution or format changes.
    if (ov.tex.texture == nullptr || ov.size[0] != (uint32_t)desc.Width || ov.size[1] != (uint32_t)desc.Height ||
        ov.format != desc.Format) {
        ov.tex.reset();

        auto tex_desc = desc;
        tex_desc.Flags |= D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
        tex_desc.Flags &= ~D3D12_RESOURCE_FLAG_DENY_SHADER_RESOURCE;

        D3D12_HEAP_PROPERTIES heap_props{};
        heap_props.Type = D3D12_HEAP_TYPE_DEFAULT;
        heap_props.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_UNKNOWN;
        heap_props.MemoryPoolPreference = D3D12_MEMORY_POOL_UNKNOWN;

        ComPtr<ID3D12Resource> tex{};

        if (FAILED(device->CreateCommittedResource(&heap_props, D3D12_HEAP_FLAG_NONE, &tex_desc,
                D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, nullptr, IID_PPV_ARGS(tex.GetAddressOf())))) {
            spdlog::error("[VR] Flatscreen canvas: failed to create texture.");
            ov.failed = true;
            return;
        }

        tex->SetName(L"Flatscreen Canvas Texture");

        if (!ov.tex.setup(device, tex.Get(), std::nullopt, std::nullopt)) {
            spdlog::error("[VR] Flatscreen canvas: failed to set up texture context.");
            ov.failed = true;
            return;
        }

        ov.size[0] = (uint32_t)desc.Width;
        ov.size[1] = (uint32_t)desc.Height;
        ov.format = desc.Format;

        spdlog::info("[VR] Flatscreen canvas: texture {}x{} format {}", ov.size[0], ov.size[1], (int)ov.format);
    }

    if (ov.handle == vr::k_ulOverlayHandleInvalid) {
        const auto err = vr::VROverlay()->CreateOverlay("REFrameworkFlatscreen", "REFramework Flatscreen", &ov.handle);

        if (err != vr::VROverlayError_None) {
            spdlog::error("[VR] Flatscreen canvas: failed to create overlay: {}", (int)err);
            ov.handle = vr::k_ulOverlayHandleInvalid;
            ov.failed = true;
            return;
        }

        // It is a picture, not a panel - no input, no interaction.
        vr::VROverlay()->SetOverlayInputMethod(ov.handle, vr::VROverlayInputMethod_None);
        vr::VROverlay()->SetOverlayFlag(ov.handle, vr::VROverlayFlags::VROverlayFlags_MakeOverlaysInteractiveIfVisible, false);

        spdlog::info("[VR] Flatscreen canvas: created overlay with handle {}", ov.handle);
    }

    // Sits in front of the head. Recomputed every frame so the sliders act live.
    vr::HmdMatrix34_t transform{};
    transform.m[0][0] = 1.0f;
    transform.m[1][1] = 1.0f;
    transform.m[2][2] = 1.0f;
    transform.m[2][3] = -vr->get_flatscreen_overlay_distance();

    vr::VROverlay()->SetOverlayWidthInMeters(ov.handle, vr->get_flatscreen_overlay_width());
    vr::VROverlay()->SetOverlayTransformTrackedDeviceRelative(ov.handle, vr::k_unTrackedDeviceIndex_Hmd, &transform);

    // Same copy pattern the eye textures use.
    ov.tex.commands.wait(INFINITE);
    ov.tex.commands.copy(frame, ov.tex.texture.Get(), D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
    ov.tex.commands.execute();

    vr::D3D12TextureData_t texture_data{ov.tex.texture.Get(), queue, 0};
    vr::Texture_t overlay_tex{(void*)&texture_data, vr::TextureType_DirectX12, vr::ColorSpace_Auto};

    vr::VROverlay()->SetOverlayTexture(ov.handle, &overlay_tex);

    if (!ov.shown) {
        vr::VROverlay()->ShowOverlay(ov.handle);
        ov.shown = true;
    }
}

void D3D12Component::setup() {
    REF_PROFILE_FUNCTION();

    if (VR::get()->is_hmd_active()) {
        spdlog::info("[VR] Setting up d3d12 textures...");
    }
    
    m_prev_backbuffer.Reset();

    auto& hook = g_framework->get_d3d12_hook();

    auto device = hook->get_device();
    auto swapchain = hook->get_swap_chain();

    ComPtr<ID3D12Resource> backbuffer{};
    ComPtr<ID3D12Resource> real_backbuffer{};

    const auto& vr = VR::get();
    const auto is_multipass = vr->is_using_multipass();
    
    if (is_multipass && vr->m_multipass.eye_textures[0].Get() != nullptr && vr->m_multipass.eye_textures[1].Get() != nullptr) {
        backbuffer = vr->m_multipass.eye_textures[0];
    } else if (is_multipass) {
        spdlog::warn("[VR] Multipass textures are not setup correctly.");
    }

    if (FAILED(swapchain->GetBuffer(0, IID_PPV_ARGS(&real_backbuffer)))) {
        spdlog::error("[VR] Failed to get back buffer.");
        return;
    }

    if (backbuffer == nullptr) {
        backbuffer = real_backbuffer;
    }

    if (backbuffer == nullptr) {
        spdlog::error("[VR] Failed to get back buffer.");
        return;
    }

    auto backbuffer_desc = backbuffer->GetDesc();
    const auto real_backbuffer_desc = real_backbuffer->GetDesc();

    if (is_multipass) {
        backbuffer_desc.Width = vr->get_hmd_width();
        backbuffer_desc.Height = vr->get_hmd_height();

        if (backbuffer.Get() == real_backbuffer.Get()) {
            //backbuffer_desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
            spdlog::warn("[VR] Multipass textures are not setup correctly: Re-using backbuffer.");
        } else {
            spdlog::info("[VR] Multipass textures are setup correctly.");
        }
    } else {
        backbuffer_desc.Width = real_backbuffer_desc.Width;
        backbuffer_desc.Height = real_backbuffer_desc.Height;
    }

    m_openvr.last_format = backbuffer_desc.Format;

    spdlog::info("[VR] D3D12 Backbuffer width: {}, height: {}, format: {}", backbuffer_desc.Width, backbuffer_desc.Height, backbuffer_desc.Format);
    spdlog::info("[VR] D3D12 Real Backbuffer width: {}, height: {}, format: {}", real_backbuffer_desc.Width, real_backbuffer_desc.Height, real_backbuffer_desc.Format);

    m_backbuffer_is_8bit = backbuffer_desc.Format == DXGI_FORMAT_R8G8B8A8_UNORM || backbuffer_desc.Format == DXGI_FORMAT_B8G8R8A8_UNORM;

    auto backbuffer_srv_desc = backbuffer_desc;
    backbuffer_srv_desc.Flags |= D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    backbuffer_srv_desc.Flags &= ~D3D12_RESOURCE_FLAG_DENY_SHADER_RESOURCE;

    D3D12_HEAP_PROPERTIES heap_props{};
    heap_props.Type = D3D12_HEAP_TYPE_DEFAULT;
    heap_props.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_UNKNOWN;
    heap_props.MemoryPoolPreference = D3D12_MEMORY_POOL_UNKNOWN;

    // Create copy of backbuffer to use as SRV to convert from HDR to 8bit
    if (!m_backbuffer_is_8bit) {
        ComPtr<ID3D12Resource> backbuffer_copy{};
        if (FAILED(device->CreateCommittedResource(&heap_props, D3D12_HEAP_FLAG_NONE, &backbuffer_srv_desc, D3D12_RESOURCE_STATE_PRESENT, nullptr,
                IID_PPV_ARGS(backbuffer_copy.GetAddressOf())))) {
            spdlog::error("[VR] Failed to create backbuffer copy.");
            return;
        }

        if (!m_backbuffer_copy.setup(device, backbuffer_copy.Get(), std::nullopt, std::nullopt)) {
            spdlog::error("[VR] Error setting up backbuffer copy texture RTV/SRV.");
        }
    }

    auto rt_desc = backbuffer_desc;

    rt_desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    rt_desc.Flags |= D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    rt_desc.Flags &= ~D3D12_RESOURCE_FLAG_DENY_SHADER_RESOURCE;

    switch (backbuffer_desc.Format) {
        case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:
        case DXGI_FORMAT_R8G8B8A8_UNORM:
        case DXGI_FORMAT_R8G8B8A8_TYPELESS:
        case DXGI_FORMAT_R8G8B8A8_UINT:
        case DXGI_FORMAT_R8G8B8A8_SNORM:
        case DXGI_FORMAT_R8G8B8A8_SINT:
            rt_desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            break;

        case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:
        case DXGI_FORMAT_B8G8R8A8_UNORM:
        case DXGI_FORMAT_B8G8R8A8_TYPELESS:
            rt_desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
            break;
        
        default:
            spdlog::error("[OpenVR] Possibly unsupported backbuffer format: {}", backbuffer_desc.Format);
            break;
    };

    //#############################
    //#Frame Warp Module Start
    //#############################
    static uint32_t lastSize[2]{0, 0};
    static DXGI_FORMAT lastFormat = DXGI_FORMAT_UNKNOWN;
    if ((lastSize[0] != vr->get_hmd_width() || lastSize[1] != vr->get_hmd_height() || lastFormat != rt_desc.Format)) {
        FrameWarpInitParams params = {vr->get_hmd_width(), vr->get_hmd_height(), rt_desc.Format};
        m_eyeFrameBuffers = InitFrameWarp(params);
        lastSize[0] = vr->get_hmd_width();
        lastSize[1] = vr->get_hmd_height();
    }
    //#############################
    //#Frame Warp Module End
    //#############################

    // Create converted eye texture
    if (!m_backbuffer_is_8bit) {
        ComPtr<ID3D12Resource> eye_tex{};
        if (FAILED(device->CreateCommittedResource(&heap_props, D3D12_HEAP_FLAG_NONE, &rt_desc, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, nullptr,
                IID_PPV_ARGS(eye_tex.GetAddressOf())))) {
            spdlog::error("[VR] Failed to create converted eye texture.");
            return;
        }

        if (!m_converted_eye_tex.setup(device, eye_tex.Get(), std::nullopt, std::nullopt)) {
            spdlog::error("[VR] Error setting up converted eye texture RTV/SRV.");
        }
    }

    for (auto& ctx : m_openvr.left_eye_tex) {
        ComPtr<ID3D12Resource> left_eye_tex{};
        if (m_eyeFrameBuffers.eyeFrameBuffers[0].color.pTexture != NULL) {
            left_eye_tex = m_eyeFrameBuffers.eyeFrameBuffers[0].color.pTexture;
        } else {
            if (FAILED(device->CreateCommittedResource(&heap_props, D3D12_HEAP_FLAG_NONE, &rt_desc,
                    D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, nullptr, IID_PPV_ARGS(left_eye_tex.GetAddressOf())))) {
                spdlog::error("[VR] Failed to create left eye texture.");
                return;
            }
        }

        left_eye_tex->SetName(L"OpenVR Left Eye Texture");
        if (!ctx.setup(device, left_eye_tex.Get(), std::nullopt, std::nullopt)) {
            spdlog::error("[VR] Error setting up left eye texture RTV/SRV.");
        }
    }

    for (auto& ctx : m_openvr.right_eye_tex) {
        ComPtr<ID3D12Resource> right_eye_tex{};
        if (m_eyeFrameBuffers.eyeFrameBuffers[1].color.pTexture != NULL) {
            right_eye_tex = m_eyeFrameBuffers.eyeFrameBuffers[1].color.pTexture;
        } else {
            if (FAILED(device->CreateCommittedResource(&heap_props, D3D12_HEAP_FLAG_NONE, &rt_desc,
                    D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, nullptr, IID_PPV_ARGS(right_eye_tex.GetAddressOf())))) {
                spdlog::error("[VR] Failed to create right eye texture.");
                return;
            }
        }

        right_eye_tex->SetName(L"OpenVR Right Eye Texture");
        if (!ctx.setup(device, right_eye_tex.Get(), std::nullopt, std::nullopt)) {
            spdlog::error("[VR] Error setting up right eye texture RTV/SRV.");
        }
    }

    for (auto& copier : m_generic_copiers) {
        copier.setup(L"Generic Copier");
    }
    
    for (auto& commands : m_backbuffer_copy_commands) {
        commands.setup(L"Backbuffer Copy Commands");
    }

    setup_sprite_batch_pso(rt_desc.Format);

    m_backbuffer_size[0] = real_backbuffer_desc.Width;
    m_backbuffer_size[1] = real_backbuffer_desc.Height;

    spdlog::info("[VR] d3d12 textures have been setup");
    m_force_reset = false;
}

void D3D12Component::setup_sprite_batch_pso(DXGI_FORMAT output_format) {
    spdlog::info("[D3D12] Setting up sprite batch PSO");

    auto& hook = g_framework->get_d3d12_hook();

    auto device = hook->get_device();
    auto command_queue = hook->get_command_queue();
    auto swapchain = hook->get_swap_chain();

    DirectX::ResourceUploadBatch upload{ device };
    upload.Begin();

    DirectX::RenderTargetState output_state{output_format, DXGI_FORMAT_UNKNOWN};
    DirectX::SpriteBatchPipelineStateDescription pd{output_state};

    m_sprite_batch = std::make_unique<DirectX::DX12::SpriteBatch>(device, upload, pd);

    auto result = upload.End(command_queue);
    result.wait();

    spdlog::info("[D3D12] Sprite batch PSO setup complete");
}

void D3D12Component::render_srv_to_rtv(ID3D12GraphicsCommandList* command_list, const d3d12::TextureContext& src, const d3d12::TextureContext& dst, D3D12_RESOURCE_STATES src_state, D3D12_RESOURCE_STATES dst_state) {
    if (m_sprite_batch == nullptr) {
        return;
    }
    
    d3d12::render_srv_to_rtv(m_sprite_batch.get(), command_list, src, dst, src_state, dst_state);
}

void D3D12Component::OpenXR::initialize(XrSessionCreateInfo& session_info) {
    REF_PROFILE_FUNCTION();

    std::scoped_lock _{this->mtx};

	auto& hook = g_framework->get_d3d12_hook();

    auto device = hook->get_device();
    auto command_queue = hook->get_command_queue();

    this->binding.device = device;
    this->binding.queue = command_queue;

    spdlog::info("[VR] Searching for xrGetD3D12GraphicsRequirementsKHR...");
    PFN_xrGetD3D12GraphicsRequirementsKHR fn = nullptr;
    xrGetInstanceProcAddr(VR::get()->m_openxr->instance, "xrGetD3D12GraphicsRequirementsKHR", (PFN_xrVoidFunction*)(&fn));

    XrGraphicsRequirementsD3D12KHR gr{XR_TYPE_GRAPHICS_REQUIREMENTS_D3D12_KHR};
    gr.adapterLuid = device->GetAdapterLuid();
    gr.minFeatureLevel = D3D_FEATURE_LEVEL_11_0;

    spdlog::info("[VR] Calling xrGetD3D12GraphicsRequirementsKHR");
    fn(VR::get()->m_openxr->instance, VR::get()->m_openxr->system, &gr);

    session_info.next = &this->binding;
}

std::optional<std::string> D3D12Component::OpenXR::create_swapchains() {
    std::scoped_lock _{this->mtx};

    spdlog::info("[VR] Creating OpenXR swapchains for D3D12");

    this->destroy_swapchains();
    
    auto& hook = g_framework->get_d3d12_hook();
    auto device = hook->get_device();
    auto swapchain = hook->get_swap_chain();

    ComPtr<ID3D12Resource> backbuffer{};

    const auto& vr = VR::get();
    const auto is_multipass = vr->is_using_multipass();

    // Get the existing backbuffer
    // so we can get the format and stuff.
    bool has_multipass_buffer = false;
    if (is_multipass && vr->m_multipass.eye_textures[0].Get() != nullptr) {
        backbuffer = vr->m_multipass.eye_textures[0];
        has_multipass_buffer = true;
    }

    if (backbuffer.Get() == nullptr && FAILED(swapchain->GetBuffer(0, IID_PPV_ARGS(&backbuffer)))) {
        spdlog::error("[VR] Failed to get back buffer.");
        return "Failed to get back buffer.";
    }

    D3D12_HEAP_PROPERTIES heap_props{};
    heap_props.Type = D3D12_HEAP_TYPE_DEFAULT;
    heap_props.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_UNKNOWN;
    heap_props.MemoryPoolPreference = D3D12_MEMORY_POOL_UNKNOWN;

    auto backbuffer_desc = backbuffer->GetDesc();
    auto& openxr = vr->m_openxr;

    this->contexts.clear();
    // +2: die vorletzte Swapchain ist die Flatscreen-Leinwand, die letzte das ImGui-Slate
    // (beides Quad-Layer). Sie werden nur befuellt, wenn das jeweilige Feature laeuft --
    // angelegt werden sie aber immer, damit beim Einschalten nicht mitten im Frame
    // Ressourcen entstehen muessen.
    this->contexts.resize(openxr->views.size() + 2);

    this->last_format = backbuffer_desc.Format;

    DXGI_FORMAT swapchain_format{DXGI_FORMAT_R8G8B8A8_UNORM_SRGB};

    switch (backbuffer_desc.Format) {
        case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:
        case DXGI_FORMAT_R8G8B8A8_UNORM:
        case DXGI_FORMAT_R8G8B8A8_TYPELESS:
        case DXGI_FORMAT_R8G8B8A8_UINT:
        case DXGI_FORMAT_R8G8B8A8_SNORM:
        case DXGI_FORMAT_R8G8B8A8_SINT:
            swapchain_format = DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;
            break;

        case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:
        case DXGI_FORMAT_B8G8R8A8_UNORM:
        case DXGI_FORMAT_B8G8R8A8_TYPELESS:
            swapchain_format = DXGI_FORMAT_B8G8R8A8_UNORM_SRGB;
            break;
        
        default:
            spdlog::error("[VR] Possibly unsupported backbuffer format: {}", backbuffer_desc.Format);
            break;
    };
    
    for (auto i = 0; i < openxr->views.size(); ++i) {
        spdlog::info("[VR] Creating swapchain for eye {}", i);
        spdlog::info("[VR] Width: {}", vr->get_hmd_width());
        spdlog::info("[VR] Height: {}", vr->get_hmd_height());

        backbuffer_desc.Width = vr->get_hmd_width();
        backbuffer_desc.Height = vr->get_hmd_height();

        if (swapchain_format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB) {
            backbuffer_desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        } else {
            backbuffer_desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        }
        spdlog::info("[VR] Format: {}", backbuffer_desc.Format);

        // Create the swapchain.
        XrSwapchainCreateInfo swapchain_create_info{XR_TYPE_SWAPCHAIN_CREATE_INFO};
        swapchain_create_info.arraySize = 1;
        swapchain_create_info.format = swapchain_format;
        swapchain_create_info.width = backbuffer_desc.Width;
        swapchain_create_info.height = backbuffer_desc.Height;
        swapchain_create_info.mipCount = 1;
        swapchain_create_info.faceCount = 1;
        swapchain_create_info.sampleCount = backbuffer_desc.SampleDesc.Count;
        swapchain_create_info.usageFlags = XR_SWAPCHAIN_USAGE_MUTABLE_FORMAT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT | XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT;

        runtimes::OpenXR::Swapchain swapchain{};
        swapchain.width = swapchain_create_info.width;
        swapchain.height = swapchain_create_info.height;

        if (xrCreateSwapchain(openxr->session, &swapchain_create_info, &swapchain.handle) != XR_SUCCESS) {
            spdlog::error("[VR] D3D12: Failed to create swapchain.");
            return "Failed to create swapchain.";
        }

        vr->m_openxr->swapchains.push_back(swapchain);

        uint32_t image_count{};
        auto result = xrEnumerateSwapchainImages(swapchain.handle, 0, &image_count, nullptr);

        if (result != XR_SUCCESS) {
            spdlog::error("[VR] Failed to enumerate swapchain images.");
            return "Failed to enumerate swapchain images.";
        }

        spdlog::info("[VR] Runtime wants {} images for swapchain {}", image_count, i);

        auto& ctx = this->contexts[i];

        ctx.textures.clear();
        ctx.textures.resize(image_count);
        ctx.texture_contexts.clear();
        ctx.texture_contexts.resize(image_count);

        for (uint32_t j = 0; j < image_count; ++j) {
            ctx.textures[j] = {XR_TYPE_SWAPCHAIN_IMAGE_D3D12_KHR};
        }

        result = xrEnumerateSwapchainImages(swapchain.handle, image_count, &image_count, (XrSwapchainImageBaseHeader*)&ctx.textures[0]);

        if (result != XR_SUCCESS) {
            spdlog::error("[VR] Failed to enumerate swapchain images after texture creation.");
            return "Failed to enumerate swapchain images after texture creation.";
        }

        // [XR_EYE_RTV 2026-08-15] Hier stand vorher nur `commands.setup(...)` -- die
        // Augen-Kontexte hatten damit KEIN RTV/SRV. Ohne RTV steigt CommandContext::clear_rtv
        // STILL aus (kein Log, kein Fehler): das Auge wurde nicht schwarz geraeumt und zeigte
        // den vorigen Frame weiter -- das ist das zitternde/nachziehende linke Auge unter
        // OpenXR und das "eingefrorene statt schwarze" Auge vom 11.08. Der Upscaler-Fork hat
        // genau diesen Block seither korrekt; hier war er beim AFW-Port verlorengegangen.
        // Warum acquire/wait vor dem setup: eine Swapchain-Textur darf erst benutzt werden,
        // wenn die Runtime sie uns gegeben hat, und `real_index` ist der Index, den SIE
        // vergibt -- nicht zwingend `j`. Das anschliessende Release gibt sie sofort zurueck,
        // die Deskriptoren bleiben gueltig. TextureContext::setup ruft commands.setup selbst,
        // die alte Zeile ist damit ersetzt und nicht verloren.
        for (uint32_t j = 0; j < image_count; ++j) {
            uint32_t real_index{};
            XrSwapchainImageAcquireInfo acquire_info{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};

            result = xrAcquireSwapchainImage(swapchain.handle, &acquire_info, &real_index);
            if (result != XR_SUCCESS) {
                spdlog::error("[VR] Failed to acquire swapchain image.");
                return "Failed to acquire swapchain image.";
            }

            XrSwapchainImageWaitInfo wait_info{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
            result = xrWaitSwapchainImage(swapchain.handle, &wait_info);

            if (result != XR_SUCCESS) {
                spdlog::error("[VR] Failed to wait for swapchain image.");
                return "Failed to wait for swapchain image.";
            }

            ctx.texture_contexts[j] = std::make_unique<d3d12::TextureContext>();
            ctx.texture_contexts[j]->setup(device, ctx.textures[j].texture, swapchain_format, swapchain_format,
                (std::wstring{L"OpenXR Swapchain "} + std::to_wstring(i) + L" " + std::to_wstring(j)).c_str());

            XrSwapchainImageReleaseInfo release_info{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
            result = xrReleaseSwapchainImage(swapchain.handle, &release_info);

            if (result != XR_SUCCESS) {
                spdlog::error("[VR] Failed to release swapchain image.");
                return "Failed to release swapchain image.";
            }
        }
    }

    // ---------------------------------------------------------------------
    // Flatscreen-Leinwand: eigene Swapchain in BACKBUFFER-Aufloesung
    // ---------------------------------------------------------------------
    // Unter OpenVR haengt die Leinwand an einem Overlay (vr::VROverlay). Ein Gegenstueck
    // dazu gibt es in OpenXR nicht -- dort ist es ein zweiter Compositor-Layer, und der
    // braucht zwingend eine eigene Swapchain. Aufloesung ist die des fertigen Bildes,
    // NICHT die des HMD: wir zeigen ja den Monitor-Frame.
    {
        ComPtr<ID3D12Resource> bb{};

        if (SUCCEEDED(swapchain->GetBuffer(0, IID_PPV_ARGS(&bb)))) {
            const auto bb_desc = bb->GetDesc();

            XrSwapchainCreateInfo ci{XR_TYPE_SWAPCHAIN_CREATE_INFO};
            ci.arraySize = 1;
            ci.format = swapchain_format;
            ci.width = (uint32_t)bb_desc.Width;
            ci.height = (uint32_t)bb_desc.Height;
            ci.mipCount = 1;
            ci.faceCount = 1;
            ci.sampleCount = 1;
            ci.usageFlags = XR_SWAPCHAIN_USAGE_MUTABLE_FORMAT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT |
                            XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT;

            runtimes::OpenXR::Swapchain sc{};
            sc.width = ci.width;
            sc.height = ci.height;

            if (xrCreateSwapchain(openxr->session, &ci, &sc.handle) == XR_SUCCESS) {
                const auto canvas_idx = (uint32_t)openxr->views.size();
                openxr->swapchains.push_back(sc);

                uint32_t image_count{};

                if (xrEnumerateSwapchainImages(sc.handle, 0, &image_count, nullptr) == XR_SUCCESS && image_count > 0) {
                    auto& cctx = this->contexts[canvas_idx];
                    cctx.textures.clear();
                    cctx.textures.resize(image_count);
                    cctx.texture_contexts.clear();
                    cctx.texture_contexts.resize(image_count);

                    for (uint32_t j = 0; j < image_count; ++j) {
                        cctx.textures[j] = {XR_TYPE_SWAPCHAIN_IMAGE_D3D12_KHR};
                    }

                    if (xrEnumerateSwapchainImages(sc.handle, image_count, &image_count,
                            (XrSwapchainImageBaseHeader*)&cctx.textures[0]) == XR_SUCCESS) {
                        for (uint32_t j = 0; j < image_count; ++j) {
                            uint32_t real_index{};
                            XrSwapchainImageAcquireInfo ai{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};

                            if (xrAcquireSwapchainImage(sc.handle, &ai, &real_index) != XR_SUCCESS) {
                                break;
                            }

                            XrSwapchainImageWaitInfo wi{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
                            xrWaitSwapchainImage(sc.handle, &wi);

                            cctx.texture_contexts[j] = std::make_unique<d3d12::TextureContext>();
                            cctx.texture_contexts[j]->setup(device, cctx.textures[j].texture,
                                swapchain_format, swapchain_format,
                                (std::wstring{L"OpenXR Flatscreen "} + std::to_wstring(j)).c_str());

                            XrSwapchainImageReleaseInfo ri{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
                            xrReleaseSwapchainImage(sc.handle, &ri);
                        }

                        spdlog::info("[VR] OpenXR flatscreen swapchain: {}x{} ({} images)", sc.width, sc.height, image_count);
                    }
                }
            } else {
                spdlog::error("[VR] Failed to create OpenXR flatscreen swapchain.");
            }
        }
    }

    // ---------------------------------------------------------------------
    // ImGui-Slate: eigene Swapchain in der Groesse des Menue-Rendertargets
    // ---------------------------------------------------------------------
    // [XR_UI_OVERLAY 2026-08-14] Aufbau bewusst wie der Leinwand-Block darueber und
    // NICHT zusammengefasst: der Leinwand-Weg laeuft und soll dafuer nicht angefasst
    // werden. Das Rendertarget ist so gross wie der Backbuffer, deshalb reicht dessen
    // Beschreibung; der sichtbare Ausschnitt wird spaeter ueber subImage.imageRect
    // auf das Menuefenster begrenzt.
    {
        ComPtr<ID3D12Resource> bb{};

        if (SUCCEEDED(swapchain->GetBuffer(0, IID_PPV_ARGS(&bb)))) {
            const auto bb_desc = bb->GetDesc();

            XrSwapchainCreateInfo ci{XR_TYPE_SWAPCHAIN_CREATE_INFO};
            ci.arraySize = 1;
            ci.format = swapchain_format;
            ci.width = (uint32_t)bb_desc.Width;
            ci.height = (uint32_t)bb_desc.Height;
            ci.mipCount = 1;
            ci.faceCount = 1;
            ci.sampleCount = 1;
            ci.usageFlags = XR_SWAPCHAIN_USAGE_MUTABLE_FORMAT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT |
                            XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT;

            runtimes::OpenXR::Swapchain sc{};
            sc.width = ci.width;
            sc.height = ci.height;

            if (xrCreateSwapchain(openxr->session, &ci, &sc.handle) == XR_SUCCESS) {
                const auto ui_idx = (uint32_t)openxr->views.size() + 1;
                openxr->swapchains.push_back(sc);

                uint32_t image_count{};

                if (xrEnumerateSwapchainImages(sc.handle, 0, &image_count, nullptr) == XR_SUCCESS && image_count > 0) {
                    auto& uctx = this->contexts[ui_idx];
                    uctx.textures.clear();
                    uctx.textures.resize(image_count);
                    uctx.texture_contexts.clear();
                    uctx.texture_contexts.resize(image_count);

                    for (uint32_t j = 0; j < image_count; ++j) {
                        uctx.textures[j] = {XR_TYPE_SWAPCHAIN_IMAGE_D3D12_KHR};
                    }

                    if (xrEnumerateSwapchainImages(sc.handle, image_count, &image_count,
                            (XrSwapchainImageBaseHeader*)&uctx.textures[0]) == XR_SUCCESS) {
                        for (uint32_t j = 0; j < image_count; ++j) {
                            uint32_t real_index{};
                            XrSwapchainImageAcquireInfo ai{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};

                            if (xrAcquireSwapchainImage(sc.handle, &ai, &real_index) != XR_SUCCESS) {
                                break;
                            }

                            XrSwapchainImageWaitInfo wi{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
                            xrWaitSwapchainImage(sc.handle, &wi);

                            uctx.texture_contexts[j] = std::make_unique<d3d12::TextureContext>();
                            uctx.texture_contexts[j]->setup(device, uctx.textures[j].texture,
                                swapchain_format, swapchain_format,
                                (std::wstring{L"OpenXR UI Slate "} + std::to_wstring(j)).c_str());

                            XrSwapchainImageReleaseInfo ri{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
                            xrReleaseSwapchainImage(sc.handle, &ri);
                        }

                        spdlog::info("[VR] OpenXR UI slate swapchain: {}x{} ({} images)", sc.width, sc.height, image_count);
                    }
                }
            } else {
                spdlog::error("[VR] Failed to create OpenXR UI slate swapchain.");
            }
        }
    }

    this->last_resolution = {vr->get_hmd_width(), vr->get_hmd_height()};

    return std::nullopt;
}

void D3D12Component::OpenXR::destroy_swapchains() {
    std::scoped_lock _{this->mtx};

	if (this->contexts.empty()) {
        return;
    }

    spdlog::info("[VR] Destroying swapchains.");

    this->wait_for_all_copies();

    for (auto i = 0; i < this->contexts.size(); ++i) {
        auto& ctx = this->contexts[i];
        ctx.texture_contexts.clear();

        // Es gibt zwei Zusatz-Swapchains (Leinwand, UI-Slate). Schlaegt eine davon beim
        // Anlegen fehl, sind es weniger Swapchains als Kontexte -- dann hier nicht ins
        // Leere greifen.
        if (i >= VR::get()->m_openxr->swapchains.size()) {
            ctx.textures.clear();
            continue;
        }

        auto result = xrDestroySwapchain(VR::get()->m_openxr->swapchains[i].handle);

        if (result != XR_SUCCESS) {
            spdlog::error("[VR] Failed to destroy swapchain {}.", i);
        } else {
            spdlog::info("[VR] Destroyed swapchain {}.", i);
        }

        ctx.textures.clear();
    }

    this->contexts.clear();
    VR::get()->m_openxr->swapchains.clear();
}

void D3D12Component::OpenXR::copy(
    uint32_t swapchain_idx, 
    ID3D12Resource* resource, 
    D3D12_BOX* src_box, 
    D3D12_RESOURCE_STATES src_state,
    OpenXR::CopyFn copy_fn)
{
    REF_PROFILE_FUNCTION();

    std::scoped_lock _{this->mtx};

    auto& vr = VR::get();

    if (vr->m_openxr->frame_state.shouldRender != XR_TRUE) {
        return;
    }

    if (!vr->m_openxr->frame_began) {
        if (vr->m_openxr->get_synchronize_stage() != VRRuntime::SynchronizeStage::VERY_LATE) {
            spdlog::error("[VR] OpenXR: Frame not begun when trying to copy.");
            return;
        }
    }

    if (this->contexts[swapchain_idx].num_textures_acquired > 0) {
        spdlog::info("[VR] Already acquired textures for swapchain {}?", swapchain_idx);
    }

    const auto& swapchain = vr->m_openxr->swapchains[swapchain_idx];
    auto& ctx = this->contexts[swapchain_idx];

    XrSwapchainImageAcquireInfo acquire_info{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};

    uint32_t texture_index{};
    auto result = xrAcquireSwapchainImage(swapchain.handle, &acquire_info, &texture_index);

    if (result == XR_ERROR_RUNTIME_FAILURE) {
        spdlog::error("[VR] xrAcquireSwapchainImage failed: {}", vr->m_openxr->get_result_string(result));
        spdlog::info("[VR] Attempting to correct...");

        for (auto& texture_ctx : ctx.texture_contexts) {
            texture_ctx->commands.reset();
        }

        texture_index = 0;
        result = xrAcquireSwapchainImage(swapchain.handle, &acquire_info, &texture_index);
    }


    if (result != XR_SUCCESS) {
        spdlog::error("[VR] xrAcquireSwapchainImage failed: {}", vr->m_openxr->get_result_string(result));
    } else {
        ctx.num_textures_acquired++;

        XrSwapchainImageWaitInfo wait_info{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
        //wait_info.timeout = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::seconds(1)).count();
        wait_info.timeout = XR_INFINITE_DURATION;
        result = xrWaitSwapchainImage(swapchain.handle, &wait_info);

        if (result != XR_SUCCESS) {
            spdlog::error("[VR] xrWaitSwapchainImage failed: {}", vr->m_openxr->get_result_string(result));
        } else {
            auto& texture_ctx = ctx.texture_contexts[texture_index];
            texture_ctx->commands.wait(INFINITE);

            // [IMAGE_SHIFT 2026-08-11] Bild-Versatz unter OpenXR am GLEICHEN Angriffspunkt
            // wie unter OpenVR: dort verschiebt VR::get_shifted_bounds den AUSSCHNITT des
            // fertigen Bildes beim Submit, das Fadenkreuz wandert also mit. Vorher wurde
            // der Versatz in XR ersatzweise in die Projektion gerechnet (VR.cpp) -- das
            // verschiebt aber die gerenderte WELT, waehrend das GUI-Fadenkreuz stehen
            // bleibt, und es skaliert zusaetzlich mit dem Zoom. Genau daher stimmten die
            // in OpenVR eingestellten Scope-Offsets in XR nicht mehr.
            // Greift nur beim einfachen Weg (kein eigener src_box, keine CopyFn): der
            // geschwaerzte Zweig braucht ihn nicht, und im Upscaler-Multipass-Zweig
            // schreibt render_srv_to_rtv das Bild selbst.
            const auto shift_x = vr->get_image_shift_x();
            const auto shift_y = vr->get_image_shift_y();

            const auto dst_desc = ctx.textures[texture_index].texture->GetDesc();
            const auto src_desc = resource->GetDesc();

            const bool same_size = src_desc.Width == dst_desc.Width && src_desc.Height == dst_desc.Height;
            const bool has_shift = same_size && src_box == nullptr && (shift_x != 0.0f || shift_y != 0.0f);

            if (copy_fn == nullptr) {
                if (has_shift) {
                    const auto w = (int32_t)dst_desc.Width;
                    const auto h = (int32_t)dst_desc.Height;

                    // Vorzeichen wie in get_shifted_bounds: dort wandert der gelesene
                    // Bereich um -shift, das Bild im Auge also um +shift.
                    int32_t dx = (int32_t)(shift_x * (float)w);
                    int32_t dy = (int32_t)(shift_y * (float)h);

                    if (dx > w - 1) dx = w - 1;
                    if (dx < -(w - 1)) dx = -(w - 1);
                    if (dy > h - 1) dy = h - 1;
                    if (dy < -(h - 1)) dy = -(h - 1);

                    D3D12_BOX box{};
                    box.left   = dx < 0 ? (UINT)(-dx) : 0u;
                    box.right  = dx < 0 ? (UINT)w : (UINT)(w - dx);
                    box.top    = dy < 0 ? (UINT)(-dy) : 0u;
                    box.bottom = dy < 0 ? (UINT)h : (UINT)(h - dy);
                    box.front  = 0;
                    box.back   = 1;

                    // Erst schwarz, sonst steht im freiwerdenden Rand der alte Frame.
                    const float black[4]{0.0f, 0.0f, 0.0f, 1.0f};
                    texture_ctx->commands.clear_rtv(*texture_ctx, black, D3D12_RESOURCE_STATE_RENDER_TARGET);

                    texture_ctx->commands.copy_region(
                        resource,
                        ctx.textures[texture_index].texture,
                        &box, src_state,
                        D3D12_RESOURCE_STATE_RENDER_TARGET,
                        dx > 0 ? (UINT)dx : 0u,
                        dy > 0 ? (UINT)dy : 0u);
                } else if (src_box != nullptr) {
                    texture_ctx->commands.copy_region(
                        resource,
                        ctx.textures[texture_index].texture,
                        src_box, src_state,
                        D3D12_RESOURCE_STATE_RENDER_TARGET);
                } else {
                    texture_ctx->commands.copy(
                        resource,
                        ctx.textures[texture_index].texture,
                        src_state,
                        D3D12_RESOURCE_STATE_RENDER_TARGET);
                }
            } else {
                copy_fn(texture_ctx->commands, *texture_ctx, src_state, D3D12_RESOURCE_STATE_RENDER_TARGET);
            }
            texture_ctx->commands.execute();

            XrSwapchainImageReleaseInfo release_info{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
            auto result = xrReleaseSwapchainImage(swapchain.handle, &release_info);

            // SteamVR shenanigans.
            if (result == XR_ERROR_RUNTIME_FAILURE) {
                spdlog::error("[VR] xrReleaseSwapchainImage failed: {}", vr->m_openxr->get_result_string(result));
                spdlog::info("[VR] Attempting to correct...");

                result = xrWaitSwapchainImage(swapchain.handle, &wait_info);

                if (result != XR_SUCCESS) {
                    spdlog::error("[VR] xrWaitSwapchainImage failed: {}", vr->m_openxr->get_result_string(result));
                }

                for (auto& texture_ctx : ctx.texture_contexts) {
                    texture_ctx->commands.wait(INFINITE);
                }

                result = xrReleaseSwapchainImage(swapchain.handle, &release_info);
            }

            if (result != XR_SUCCESS) {
                spdlog::error("[VR] xrReleaseSwapchainImage failed: {}", vr->m_openxr->get_result_string(result));
                return;
            }

            ctx.num_textures_acquired--;
        }
    }
}
} // namespace vrmod
