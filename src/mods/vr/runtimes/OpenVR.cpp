#include "../../VR.hpp"

#include "OpenVR.hpp"

namespace runtimes {
VRRuntime::Error OpenVR::synchronize_frame() {
    if (this->got_first_poses && !this->is_hmd_active) {
        return VRRuntime::Error::SUCCESS;
    }
    if (!hiddenAreaMesh[0].pVertexData) {
        update_hidden_area_mesh();
    }
    vr::VRCompositor()->SetTrackingSpace(vr::TrackingUniverseStanding);
    auto ret = vr::VRCompositor()->WaitGetPoses(this->real_render_poses.data(), vr::k_unMaxTrackedDeviceCount, this->real_game_poses.data(), vr::k_unMaxTrackedDeviceCount);

    if (ret == vr::VRCompositorError_None) {
        this->got_first_valid_poses = true;
        this->got_first_sync = true;
    }

    return (VRRuntime::Error)ret;
}

VRRuntime::Error OpenVR::update_poses() {
    if (!this->ready()) {
        return VRRuntime::Error::SUCCESS;
    }

    std::unique_lock _{ this->pose_mtx };

    memcpy(this->render_poses.data(), this->real_render_poses.data(), sizeof(this->render_poses));
    this->needs_pose_update = false;
    return VRRuntime::Error::SUCCESS;
}

VRRuntime::Error OpenVR::update_render_target_size() {
    this->hmd->GetRecommendedRenderTargetSize(&this->w, &this->h);

    return VRRuntime::Error::SUCCESS;
}

uint32_t OpenVR::get_width() const {
    return this->w;
}

uint32_t OpenVR::get_height() const {
    return this->h;
}

VRRuntime::Error OpenVR::consume_events(std::function<void(void*)> callback) {
    // Process OpenVR events
    vr::VREvent_t event{};
    while (this->hmd->PollNextEvent(&event, sizeof(event))) {
        if (callback) {
            callback(&event);
        }

        switch ((vr::EVREventType)event.eventType) {
            // Detect whether video settings changed
            case vr::VREvent_SteamVRSectionSettingChanged: {
                spdlog::info("VR: VREvent_SteamVRSectionSettingChanged");
                update_render_target_size();
            } break;

            // Detect whether SteamVR reset the standing/seated pose
            case vr::VREvent_SeatedZeroPoseReset: [[fallthrough]];
            case vr::VREvent_StandingZeroPoseReset: {
                spdlog::info("VR: VREvent_SeatedZeroPoseReset");
                this->wants_reset_origin = true;
            } break;

            case vr::VREvent_DashboardActivated: {
                this->handle_pause = true;
            } break;

            default:
                spdlog::info("VR: Unknown event: {}", (uint32_t)event.eventType);
                break;
        }
    }

    return VRRuntime::Error::SUCCESS;
}

VRRuntime::Error OpenVR::update_matrices(float nearz, float farz){
    std::unique_lock __{ this->eyes_mtx };

    for (int i = 0; i < 2; i++) {
        auto nEye = (vr::EVREye)i;
        const auto local = this->hmd->GetEyeToHeadTransform(nEye);

        this->eyes[nEye] = glm::rowMajor4(Matrix4x4f{*(Matrix3x4f*)&local});

        auto projection = this->hmd->GetProjectionMatrix(nEye, nearz, farz);

        this->projections[nEye] = glm::rowMajor4(Matrix4x4f{*(Matrix4x4f*)&projection});

        this->hmd->GetProjectionRaw(nEye, &this->raw_projections[nEye][0], &this->raw_projections[nEye][1], &this->raw_projections[nEye][2], &this->raw_projections[nEye][3]);

        XrFovf fov;
        fov.angleLeft = this->raw_projections[nEye][0];
        fov.angleRight = this->raw_projections[nEye][1];
        fov.angleUp = this->raw_projections[nEye][2];
        fov.angleDown = this->raw_projections[nEye][3];

        float L_full = tan(fov.angleLeft);
        float R_full = tan(fov.angleRight);
        float U_full = tan(fov.angleUp);
        float D_full = tan(fov.angleDown);

        float scale_uv = VR::get()->get_foveated_ratio();
        float gaze_uv_x = 0;
        float gaze_uv_y = 0;

        float L_fove = L_full * scale_uv + gaze_uv_x;
        float R_fove = R_full * scale_uv + gaze_uv_x;
        float U_fove = U_full * scale_uv + gaze_uv_y;
        float D_fove = D_full * scale_uv + gaze_uv_y;
        
        XrMatrix4x4f_CreateProjection((XrMatrix4x4f*)&this->foveated_projections[i], GRAPHICS_D3D, L_fove, R_fove, U_fove, D_fove, nearz, farz);

        float totalTanW = R_full - L_full;
        float u0 = (L_fove - L_full) / totalTanW;
        float u1 = (R_fove - L_full) / totalTanW;

        // ´¹Ö± UV
        float totalTanH = U_full - D_full;
        float v0 = (D_fove - D_full) / totalTanH;
        float v1 = (U_fove - D_full) / totalTanH;

        ViewPort vp = {};
        vp.TopLeftX = u0;
        vp.TopLeftY = v0;
        vp.Width = (u1 - u0);
        vp.Height = (v1 - v0);

        foveated_viewports[i] = vp;
    }

    return VRRuntime::Error::SUCCESS;
}

void OpenVR::destroy() {
    if (this->loaded) {
        vr::VR_Shutdown();
    }
}

VRRuntime::Error OpenVR::update_hidden_area_mesh() {
    auto hiddenAreaMeshLeft = this->hmd->GetHiddenAreaMesh(vr::EVREye::Eye_Left);
    auto hiddenAreaMeshRight = this->hmd->GetHiddenAreaMesh(vr::EVREye::Eye_Right);
    hiddenAreaMesh[0].pVertexData = (float*)hiddenAreaMeshLeft.pVertexData;
    hiddenAreaMesh[0].unTriangleCount = hiddenAreaMeshLeft.unTriangleCount;
    hiddenAreaMesh[1].pVertexData = (float*)hiddenAreaMeshRight.pVertexData;
    hiddenAreaMesh[1].unTriangleCount = hiddenAreaMeshRight.unTriangleCount;
    return VRRuntime::Error::SUCCESS;
}

}

