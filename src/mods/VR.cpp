#define NOMINMAX

#include <fstream>
#include <imgui.h>
#include <imgui_internal.h>
#include <glm/gtx/transform.hpp>

#include <utility/ScopeGuard.hpp>

#include <sdk/TDBVer.hpp>
#include <reframework/API.hpp>

#if TDB_VER >= 83
#include "sdk/regenny/re9/via/Window.hpp"
#include "sdk/regenny/re9/via/SceneView.hpp"
#elif TDB_VER <= 49
#include "sdk/regenny/re7/via/Window.hpp"
#include "sdk/regenny/re7/via/SceneView.hpp"
#elif TDB_VER < 69
#include "sdk/regenny/re3/via/Window.hpp"
#include "sdk/regenny/re3/via/SceneView.hpp"
#elif TDB_VER == 69
#include "sdk/regenny/re8/via/Window.hpp"
#include "sdk/regenny/re8/via/SceneView.hpp"
#elif TDB_VER == 70
#include "sdk/regenny/re2_tdb70/via/Window.hpp"
#include "sdk/regenny/re2_tdb70/via/SceneView.hpp"
#elif TDB_VER >= 71
#ifdef SF6
#include "sdk/regenny/sf6/via/Window.hpp"
#include "sdk/regenny/sf6/via/SceneView.hpp"
#elif defined(RE4)
#include "sdk/regenny/re4/via/Window.hpp"
#include "sdk/regenny/re4/via/SceneView.hpp"
#elif defined(DD2) || TDB_VER >= 74
#include "sdk/regenny/dd2/via/Window.hpp"
#include "sdk/regenny/dd2/via/SceneView.hpp"
#else
#include "sdk/regenny/mhrise_tdb71/via/Window.hpp"
#include "sdk/regenny/mhrise_tdb71/via/SceneView.hpp"
#endif
#endif

#include "sdk/Math.hpp"
#include "sdk/SceneManager.hpp"
#include "sdk/RETypeDB.hpp"
#include "sdk/Renderer.hpp"
#include "sdk/Application.hpp"
#include "sdk/Renderer.hpp"
#include "sdk/REMath.hpp"
#include "sdk/REGameObject.hpp"

#include "utility/Scan.hpp"
#include "utility/FunctionHook.hpp"
#include "utility/Module.hpp"
#include "utility/Memory.hpp"
#include "utility/Registry.hpp"
#include "utility/ScopeGuard.hpp"

#include "FirstPerson.hpp"
#include "ManualFlashlight.hpp"
//#include "TemporalUpscaler.hpp"
#include "VR.hpp"
#include <MinHook.h>

bool inside_on_end = false;
uint32_t actual_frame_count = 0;

thread_local bool inside_gui_draw = false;

std::shared_ptr<VR>& VR::get() {
    static auto inst = std::make_shared<VR>();
    return inst;
}

std::unique_ptr<FunctionHook> g_input_hook{};
std::unique_ptr<FunctionHook> g_projection_matrix_hook2{};
std::unique_ptr<FunctionHook> g_overlay_draw_hook{};
std::unique_ptr<FunctionHook> g_post_effect_draw_hook{};
std::unique_ptr<FunctionHook> g_wwise_listener_update_hook{};
//std::unique_ptr<FunctionHook> g_get_sharpness_hook{};

#if TDB_VER <= 49
std::optional<regenny::via::Size> g_previous_size{};
#endif

// Purpose: spoof the render target size to the size of the HMD displays
void VR::on_view_get_size(REManagedObject* scene_view, float* result) {
    // There are some very dumb optimizations that cause set_DisplayType
    // to go through this hook. This function is actually something like "updateSceneView"
    static thread_local bool already_inside = false;

    if (already_inside) {
        return;
    }

    already_inside = true;

    utility::ScopeGuard _{ [&]() { already_inside = false; } };

    if (!g_framework->is_ready()) {
        return;
    }

    if (!get_runtime()->loaded) {
        return;
    }

    if (m_disable_backbuffer_size_override) {
        return;
    }

    auto regenny_view = (regenny::via::SceneView*)scene_view;
    auto window = regenny_view->window;

    static auto via_scene_view = sdk::find_type_definition("via.SceneView");
    static auto set_display_type_method = via_scene_view != nullptr ? via_scene_view->get_method("set_DisplayType") : nullptr;

    // Force the display to stretch to the window size
    if (set_display_type_method != nullptr) {
        set_display_type_method->call(sdk::get_thread_context(), regenny_view, via::DisplayType::Fit);
    } else {
#if not defined(RE7) || TDB_VER <= 49
        static auto is_sunbreak = utility::get_module_path(utility::get_executable())->find("MHRiseSunbreakDemo") != std::string::npos;

        if (is_sunbreak) {
            *(regenny::via::DisplayType*)((uintptr_t)&regenny_view->display_type + 4) = regenny::via::DisplayType::Fit;
        } else {
            regenny_view->display_type = regenny::via::DisplayType::Fit;
        }
#else
        *(regenny::via::DisplayType*)((uintptr_t)&regenny_view->display_type + 4) = regenny::via::DisplayType::Fit;
#endif
    }

    auto wanted_width = 0.0f;
    auto wanted_height = 0.0f;

    // Set the window size, which will increase the size of the backbuffer
    if (window != nullptr) {
        static const auto is_gng = utility::get_module_path(utility::get_executable())->find("makaimura_GG_RE.exe") != std::string::npos;

        auto& window_width = is_gng ? *(uint32_t*)((uintptr_t)window + 0x48) : window->width;
        auto& window_height = is_gng ? *(uint32_t*)((uintptr_t)window + 0x4C) : window->height;

        if (is_hmd_active()) {
#if TDB_VER <= 49
            if (!g_previous_size) {
                g_previous_size = regenny::via::Size{ (float)window->width, (float)window->height };
            }
#endif

            bool isFR = is_using_afw_foveated();
            uint32_t render_width = (isFR) ? round(get_hmd_width() * get_foveated_ratio()) : get_hmd_width();
            uint32_t render_height = (isFR) ? round(get_hmd_height() * get_foveated_ratio()) : get_hmd_height();

            window_width = render_width;
            window_height = render_height;

            if (m_is_d3d12 && m_d3d12.is_initialized()) {
                const auto& backbuffer_size = m_d3d12.get_backbuffer_size();

                if (backbuffer_size[0] > 0 && backbuffer_size[1] > 0) {
                    if (std::abs((int)backbuffer_size[0] - (int)render_width) > 50 || std::abs((int)backbuffer_size[1] - (int)render_height) > 50) {
                        const auto now = get_game_frame_count();

                        if (!m_backbuffer_inconsistency) {
                            m_backbuffer_inconsistency_start = now;
                            m_backbuffer_inconsistency = true;
                        }

                        const auto is_true_inconsistency = (now - m_backbuffer_inconsistency_start) >= 5;

                        if (is_true_inconsistency) {
                            // Force a reset of the backbuffer size
                            window_width = render_width + 1;
                            window_height = render_height + 1;

                            spdlog::info("[VR] Previous backbuffer size: {}x{}", backbuffer_size[0], backbuffer_size[1]);
                            if (isFR)
                                spdlog::info("[VR] Backbuffer size inconsistency detected, resetting backbuffer size to {}x{} for foveated rendering, target buffer size {}x{}",
                                    render_width, render_height, window_width, window_height);
                            else
                                spdlog::info("[VR] Backbuffer size inconsistency detected, resetting backbuffer size to {}x{}", render_width, render_height);

                            // m_backbuffer_inconsistency gets set to false on device reset.
                        }
                    }
                } else {
                    m_backbuffer_inconsistency = false;
                }
            }

            render_size[0] = window_width;
            render_size[1] = window_height;
        } else {
            m_backbuffer_inconsistency = false;

#if TDB_VER > 49
            window_width = is_gng ? (uint32_t)*(float*)((uintptr_t)window + 0x88) : (uint32_t)window->borderless_size.w;
            window_height = is_gng ? (uint32_t)*(float*)((uintptr_t)window + 0x8C) : (uint32_t)window->borderless_size.h;
#else
            if (g_previous_size) {
                window->width = (uint32_t)g_previous_size->w;
                window->height = (uint32_t)g_previous_size->h;

                g_previous_size = std::nullopt;
            }
#endif
        }

        wanted_width = (float)window_width;
        wanted_height = (float)window_height;

        // Might be usable in other games too
#if defined(SF6) || TDB_VER >= 73
        if (!is_gng) {
            window->borderless_size.w = (float)window_width;
            window->borderless_size.h = (float)window_height;
        }
#endif
    }

    //auto out = original_func(scene_view, result);

    if (!m_in_render) {
        //return original_func(scene_view, result);
    }

    // spoof the size to the HMD's size
#if TDB_VER < 73
    result[0] = wanted_width;
    result[1] = wanted_height;
#else
    // Stupid optimizations cause the game to not use the result variant of this function
    // but rather update the current scene view's size directly.
    regenny_view->size.w = wanted_width;
    regenny_view->size.h = wanted_height;
#endif
}

void VR::on_camera_get_projection_matrix(REManagedObject* camera, Matrix4x4f* result) {
    if (result == nullptr || !g_framework->is_ready() || !is_hmd_active() || m_disable_projection_matrix_override) {
        return;
    }

    /*if (camera != sdk::get_primary_camera()) {
        return original_func(camera, result);
    }*/

    if (!m_in_render) {
       // return original_func(camera, result);
    }

    if (m_in_lightshaft) {
        //return original_func(camera, result);
    }

    if (is_using_afw_foveated()) {
        if (camera != m_multipass_cameras[0] && camera != m_multipass_cameras[1]) {
            return;
        }
    }

#ifdef RE4
    if (const auto game_object = ((REComponent*)camera)->ownerGameObject; game_object != nullptr) {
        if (game_object->name != nullptr) {
            // Allows the sniper scope to work
            if (utility::re_string::get_view(game_object->name).starts_with(L"ScopeCamera")) {
                return;
            }
        }
    }
#endif

    // Get the projection matrix for the correct eye
    // For some reason we need to flip the projection matrix here?

    auto cameras = get_cameras();
    if (m_fix_item_inspection->value() && (camera != cameras[0] && camera != cameras[1])) {
        return;
    } else if (is_using_any_afw()) {
        std::shared_lock _{get_runtime()->eyes_mtx};
        auto eye_index = (m_render_frame_count + 1) % 2 == m_left_eye_interval ? EyeLeft : EyeRight;
        auto other_eye_index = (m_render_frame_count + 1) % 2 == m_left_eye_interval ? EyeRight : EyeLeft;
        if ((is_using_afw_foveated() && m_multipass.pass == 1)) {
            *result = get_runtime()->foveated_projections[eye_index];
        }
        else {
            if (eye_index == EyeLeft) {
                eye_index = m_frame_count % 2 == m_left_eye_interval ? EyeLeft : EyeRight;
            }
            *result = get_runtime()->projections[eye_index];
        }
    }
    else {
        *result = get_current_projection_matrix(false);
    }
}

Matrix4x4f* VR::gui_camera_get_projection_matrix_hook(REManagedObject* camera, Matrix4x4f* result) {
    auto original_func = g_projection_matrix_hook2->get_original<decltype(VR::gui_camera_get_projection_matrix_hook)>();

    auto& vr = VR::get();

    if (result == nullptr || !g_framework->is_ready() || !vr->is_hmd_active() || vr->m_disable_gui_camera_projection_matrix_override) {
        return original_func(camera, result);
    }

    /*if (camera != sdk::get_primary_camera()) {
        return original_func(camera, result);
    }*/

    if (!vr->m_in_render) {
       // return original_func(camera, result);
    }

    if (vr->m_in_lightshaft) {
        //return original_func(camera, result);
    }

    // Get the projection matrix for the correct eye
    // For some reason we need to flip the projection matrix here?
#if TDB_VER > 49
    *result = vr->get_current_projection_matrix(false);
#else
    *result = vr->get_current_projection_matrix(true);
#endif

    return result;
}

void VR::on_camera_get_view_matrix(REManagedObject* camera, Matrix4x4f* result) {
    if (result == nullptr || !g_framework->is_ready()) {
        return;
    }

    if (!is_hmd_active() || m_disable_view_matrix_override) {
        return;
    }

    auto cameras = get_cameras();

    if (camera != cameras[0] && camera != cameras[1]) {
        return;
    }

    // A little note on this. We can't actually use the camera (when using multipass) to detect how to adjust the view matrix
    // For some reason, the game *always* uses the main camera when calling this function, even though it's rendering the other camera
    // So we detect which pass is getting called and adjust the view matrix accordingly
    //if (!is_using_multipass()) {
        auto& mtx = *result;

        //get the flipped eye to get the correct transform. something something right->left handedness i think
        const auto current_eye_transform = get_current_eye_transform(true);
        //auto current_head_pos = -(glm::inverse(vr->get_rotation(0)) * ((vr->get_position(0)) - vr->m_standing_origin));
        //current_head_pos.w = 0.0f;

        // Apply the complete eye transform. This fixes the need for parallel projections on all canted headsets like Pimax
        mtx = current_eye_transform * mtx;
    //}
}

HookManager::PreHookResult VR::pre_set_hdr_mode(std::vector<uintptr_t>& args, std::vector<sdk::RETypeDefinition*>& arg_tys, uintptr_t ret_addr) {
    if (!VR::get()->is_hmd_active()) {
        return HookManager::PreHookResult::CALL_ORIGINAL;
    }

    if (args.size() >= 2) {
        args[1] = 0;
    }

    return HookManager::PreHookResult::CALL_ORIGINAL;
}

void VR::inputsystem_update_hook(void* ctx, REManagedObject* input_system) {
    auto original_func = g_input_hook->get_original<decltype(VR::inputsystem_update_hook)>();

    if (!g_framework->is_ready()) {
        original_func(ctx, input_system);
        return;
    }

    auto& mod = VR::get();
    const auto now = std::chrono::steady_clock::now();
    auto is_using_controller = (now - mod->get_last_controller_update()) <= std::chrono::seconds(10);

    if (mod->get_controllers().empty()) {
        // no controllers connected, don't do anything
        original_func(ctx, input_system);
        return;
    }

    auto lstick = sdk::call_object_func<REManagedObject*>(input_system, "get_LStick", sdk::get_thread_context());
    auto rstick = sdk::call_object_func<REManagedObject*>(input_system, "get_RStick", sdk::get_thread_context());

    if (lstick == nullptr || rstick == nullptr) {
        original_func(ctx, input_system);
        return;
    }

    auto button_bits_obj = sdk::call_object_func<REManagedObject*>(input_system, "get_ButtonBits", sdk::get_thread_context(), input_system);

    if (button_bits_obj == nullptr) {
        original_func(ctx, input_system);
        return;
    }

    auto left_axis = mod->get_left_stick_axis();
    auto right_axis = mod->get_right_stick_axis();
    const auto left_axis_len = glm::length(left_axis);
    const auto right_axis_len = glm::length(right_axis);

    // Current actual button bits used by the game
    auto& button_bits_down = *sdk::get_object_field<uint64_t>(button_bits_obj, "Down");
    auto& button_bits_on = *sdk::get_object_field<uint64_t>(button_bits_obj, "On");
    auto& button_bits_up = *sdk::get_object_field<uint64_t>(button_bits_obj, "Up");

    //button_bits_down |= mod->m_button_states_down.to_ullong();
    //button_bits_on |= mod-> m_button_states_on.to_ullong();
    //button_bits_up |= mod->m_button_states_up.to_ullong();

    auto keep_button_down = [&](app::ropeway::InputDefine::Kind button) {
        if ((mod->m_button_states_on.to_ullong() & (uint64_t)button) == 0 && (mod->m_button_states_down.to_ullong() & (uint64_t)button) == 0) {
            return;
        }

        if ((mod->m_button_states_on.to_ullong() & (uint64_t)button) == 0) {
            if (mod->m_button_states_down.to_ullong() & (uint64_t)button) {
                button_bits_on |= (uint64_t)button;
                button_bits_down &= ~(uint64_t)button;
            } else {
                button_bits_down |= (uint64_t)button;
            }
        } else {
            button_bits_down &= ~(uint64_t)button;
            button_bits_on |= (uint64_t)button;
        }
    };

    const auto deadzone = mod->m_joystick_deadzone->value();

    if (left_axis_len > deadzone) {
        mod->m_last_controller_update = now;
        is_using_controller = true;

        // Override the left stick's axis values to the VR controller's values
        Vector3f axis{ left_axis.x, left_axis.y, 0.0f };
        sdk::call_object_func<void*>(lstick, "update", sdk::get_thread_context(), lstick, &axis, &axis);

        keep_button_down(app::ropeway::InputDefine::Kind::UI_L_STICK);
    }

    if (right_axis_len > deadzone) {
        mod->m_last_controller_update = now;
        is_using_controller = true;

        // Override the right stick's axis values to the VR controller's values
        Vector3f axis{ right_axis.x, right_axis.y, 0.0f };
        sdk::call_object_func<void*>(rstick, "update", sdk::get_thread_context(), rstick, &axis, &axis);

        keep_button_down(app::ropeway::InputDefine::Kind::UI_R_STICK);
    }

    // Causes the right stick to take effect properly
    if (is_using_controller) {
        sdk::call_object_func<void*>(input_system, "set_InputMode", sdk::get_thread_context(), input_system, app::ropeway::InputDefine::InputMode::Pad);
    }

    original_func(ctx, input_system);

    mod->openvr_input_to_re2_re3(input_system);
}

bool VR::on_pre_overlay_layer_draw(sdk::renderer::layer::Overlay* layer, void* render_ctx) {

    uiBufferTex = layer->get_ui_buffer_tex_d3d12();
    uiBufferNativeTex = layer->get_ui_buffer_tex();

    // just don't render anything at all.
    // overlays just seem to break stuff in VR.
    if (!is_hmd_active()) {
        return true;
    }

    // NOT RE3
    // for some reason RE3 has weird issues with the overlay rendering
    // causing double vision
#if (TDB_VER < 70 and not defined(RE3)) or (TDB_VER >= 70 and (not defined(RE3) and not defined(RE2) and not defined(RE7) and not defined(RE4) and not defined(SF6)))
    if (m_allow_engine_overlays->value()) {
        return true;
    }
#endif

    return false;
}

bool VR::on_pre_overlay_layer_update(sdk::renderer::layer::Overlay* layer, void* render_ctx) {
    return true;
}

bool VR::on_pre_post_effect_layer_draw(sdk::renderer::layer::PostEffect* layer, void* render_ctx) {
    if (!is_hmd_active()) {
        return true;
    }

    auto scene_layer = layer->get_parent();
    const auto camera = sdk::get_primary_camera();

    if (camera == nullptr) {
        return true;
    }
    
    static auto render_output_type = sdk::find_type_definition("via.render.RenderOutput")->get_type();
    auto render_output_component = utility::re_component::find(camera, render_output_type);

    if (render_output_component == nullptr) {
        return true;
    }

    if (!m_disable_post_effect_fix) {
        // Set the distortion type back to flatscreen mode
        // this will fix various graphical bugs
        //sdk::call_object_func_easy<void*>(render_output_component, "set_DistortionType", 0); // None

        if (scene_layer != nullptr) {
            m_previous_distortion_type = sdk::call_object_func_easy<uint32_t>(scene_layer, "get_DistortionType");
            m_set_next_post_effect_distortion_type = true;
            sdk::call_object_func_easy<void*>(scene_layer, "set_DistortionType", 0); // None
        }
    }

    return true;
}

void VR::on_post_effect_layer_draw(sdk::renderer::layer::PostEffect* layer, void* render_ctx) {
    if (!is_hmd_active()) {
        return;
    }

    if (!m_disable_post_effect_fix && m_set_next_post_effect_distortion_type) {
        auto scene_layer = layer->get_parent();

        // Restore the distortion type back to VR mode
        // to fix TAA
        if (scene_layer != nullptr) {
            sdk::call_object_func_easy<void*>(scene_layer, "set_DistortionType", m_previous_distortion_type); // Left
        }

        //mod->fix_temporal_effects();
        m_set_next_post_effect_distortion_type = false;
    }
}

bool VR::on_pre_post_effect_layer_update(sdk::renderer::layer::PostEffect* layer, void* render_ctx) {
    return true;
}

bool VR::on_pre_scene_layer_draw(sdk::renderer::layer::Scene* layer, void* render_ctx) {
    return true;
}

void VR::on_prepare_output_layer_draw(sdk::renderer::layer::PrepareOutput* layer, void* render_context) {
    return;
}


void VR::on_overlay_layer_draw(sdk::renderer::layer::Overlay* layer, void* render_context) {

    if (!is_hmd_active()) {
        return;
    }

    if (!is_using_afw_foveated()) {
        return;
    }

    auto context = (sdk::renderer::RenderContext*)render_context;
    auto scene_layer = (sdk::renderer::layer::Scene*)layer->get_parent();

    if (scene_layer == nullptr) {
        return;
    }

    const auto ui_target_state = layer->get_ui_target();

    if (ui_target_state == nullptr) {
        return;
    }

    const auto rtv = ui_target_state->get_rtv(0);

    if (rtv == nullptr) {
        return;
    }

    const auto tex = rtv->get_texture_d3d12();

    if (tex == nullptr) {
        return;
    }

    auto scene_layers = m_camera_duplicator.get_relevant_scene_layers();

    if (scene_layers.size() < 2) {
        return;
    }

    const auto parent_layer = layer->get_parent();

    if (parent_layer == nullptr) {
        return;
    }

    if (parent_layer == scene_layers[0]) {
        float w = (is_left_eye()) ? 0 : 1.0f;
        float red[4] = {1.0f, 0, 0, w};
        context->clear_rtv(rtv, red);
        // if (m_multipass.native_res_copies[0] != nullptr) {
        //     context->copy_texture(m_multipass.native_res_copies[0], tex);
        // }
    } else {
        // float w = (is_left_eye()) ? 0 : 1.0f;
        // float green[4] = {0, 1.0f, 0, w};
        // context->clear_rtv(rtv, green);
        // if (m_multipass.native_res_copies[1] != nullptr) {
        //    context->copy_texture(m_multipass.native_res_copies[1], tex);
        //}
    }
}

bool VR::on_pre_scene_layer_update(sdk::renderer::layer::Scene* layer, void* render_ctx) {
    

    m_scene_update_mtx.lock();
    
    if (!is_hmd_active()) {
        return true;
    }

    if (!layer->is_fully_rendered()) {
        return true;
    }

    if (is_using_afw_foveated()) {
        const auto real_main_camera = sdk::get_primary_camera();
        const auto layer_camera = layer->get_main_camera_if_possible();

        if (layer_camera != nullptr) {
            if (layer_camera == real_main_camera) {
                m_multipass.pass = 0;
                m_multipass_cameras[0] = real_main_camera;
                m_multipass_cameras[1] = m_camera_duplicator.get_new_camera_counterpart(real_main_camera);
            } else if (layer_camera == m_camera_duplicator.get_new_camera_counterpart(real_main_camera)) {
                m_multipass.pass = 1;
                m_multipass_cameras[1] = m_camera_duplicator.get_new_camera_counterpart(real_main_camera);
            } else {
                return true; // dont care
            }
        } else {
            return true; // dont care
        }
    }
    
    auto scene_info = layer->get_scene_info();
    auto depth_distortion_scene_info = layer->get_depth_distortion_scene_info();
    auto filter_scene_info = layer->get_filter_scene_info();
    auto jitter_disable_scene_info = layer->get_jitter_disable_scene_info();
    auto z_prepass_scene_info = layer->get_z_prepass_scene_info();

    auto& layer_data = m_scene_layer_data[layer];

    layer_data[0].setup(scene_info);
    layer_data[1].setup(depth_distortion_scene_info);
    layer_data[2].setup(filter_scene_info);
    layer_data[3].setup(jitter_disable_scene_info);
    layer_data[4].setup(z_prepass_scene_info);

    return true;
}

int32_t GetJitterPhaseCount(int32_t renderWidth, int32_t displayWidth) {
    const float basePhaseCount = 8.0f;
    const int32_t jitterPhaseCount = int32_t(basePhaseCount * pow((float(displayWidth) / renderWidth), 2.0f));
    return jitterPhaseCount;
}

// Calculate halton number for index and base.
float halton(int32_t index, int32_t base) {
    float f = 1.0f, result = 0.0f;

    for (int32_t currentIndex = index; currentIndex > 0;) {

        f /= (float)base;
        result = result + f * (float)(currentIndex % base);
        currentIndex = (uint32_t)(floorf((float)(currentIndex) / (float)(base)));
    }

    return result;
}

int GetJitterOffset(float* outX, float* outY, int index, int phaseCount) {
    phaseCount = std::max(phaseCount, 8);
    const float x = halton((index % phaseCount) + 1, 2) - 0.5f;
    const float y = halton((index % phaseCount) + 1, 3) - 0.5f;

    *outX = x;
    *outY = y;
    return 0;
}

void VR::on_scene_layer_update(sdk::renderer::layer::Scene* layer, void* render_ctx) {
    

    utility::ScopeGuard ___([&]() {
        m_scene_update_mtx.unlock();
    });

    if (!is_hmd_active()) {
        return;
    }

    if (!layer->is_fully_rendered()) {
        return;
    }

    if (is_using_afw_foveated()) {
        const auto layer_camera = layer->get_camera();

        if (layer_camera != m_multipass_cameras[0] && layer_camera != m_multipass_cameras[1]) {
            return;
        }
    }


    auto fix_motion_vectors = [&](SceneLayerData& d) {
        auto eye_index = m_frame_count % 2 == m_left_eye_interval ? EyeLeft : EyeRight;
        auto other_eye_index = m_frame_count % 2 == m_left_eye_interval ? EyeRight : EyeLeft;
        auto old_view_matrix = d.old_view_matrix[eye_index];
        auto old_projection_matrix = get_runtime()->projections[eye_index];
        d.scene_info->old_view_projection_matrix = old_projection_matrix * old_view_matrix;
        d.old_view_matrix[eye_index] = d.scene_info->view_matrix;
    };

    auto& layer_data = m_scene_layer_data[layer];

    if (is_using_afw_foveated() && m_multipass.pass == 1 && (vrDLSSHandleFR[0] != NULL || vrContextsFR[0] != NULL)) {
        const auto fr_index = is_left_eye();

        const auto phase = GetJitterPhaseCount(render_size[0], render_size[1]);
        const auto w = (float)render_size[0];
        const auto h = (float)render_size[1];

        float x = 0.0f;
        float y = 0.0f;

        m_jitter_indices[fr_index]++;
        GetJitterOffset(&x, &y, m_jitter_indices[fr_index], phase);

        m_jitter_offsets[fr_index][0] = -x;
        m_jitter_offsets[fr_index][1] = -y;

        x = 2.0f * (x / w);
        y = -2.0f * (y / h);

        auto add_jitter = [&](SceneLayerData& d) {
            d.scene_info->projection_matrix[2][0] += x;
            d.scene_info->projection_matrix[2][1] += y;
            d.scene_info->inverse_projection_matrix = glm::inverse(d.scene_info->projection_matrix);

            d.scene_info->view_projection_matrix = d.scene_info->projection_matrix * d.scene_info->view_matrix;
            d.scene_info->inverse_view_projection_matrix = glm::inverse(d.scene_info->view_projection_matrix);
        };
        for (auto& d : layer_data) {
            if (d.scene_info != nullptr) {
                add_jitter(d);
            }
        }
    }
    else {
        for (auto& d : layer_data) {
            if (d.scene_info != nullptr) {
                if (is_fix_dlss()) {
                    fix_motion_vectors(d);
                } else if (!m_disable_temporal_fix) {
                    // TAA fix
                    d.scene_info->old_view_projection_matrix = d.view_projection_matrix;
                }
            }
        }
    }
}

void VR::wwise_listener_update_hook(void* listener) {
    auto original_func = g_wwise_listener_update_hook->get_original<decltype(VR::wwise_listener_update_hook)>();

    if (!g_framework->is_ready()) {
        original_func(listener);
        return;
    }

    auto& mod = VR::get();

    if (!mod->is_hmd_active() || !mod->get_runtime()->loaded) {
        original_func(listener);
        return;
    }

    if (!mod->m_hmd_oriented_audio->value()) {
        original_func(listener);
        return;
    }

    std::scoped_lock _{mod->m_wwise_mtx};

#if defined(RE2) || defined(RE3)
    const auto skip_camera_set = FirstPerson::get()->will_be_used();
#else
    const auto skip_camera_set = false;
#endif

    if (!skip_camera_set) {
        mod->update_audio_camera();
    }

#if TDB_VER > 49
    constexpr auto CAMERA_OFFSET = 0x50;
#else
    constexpr auto CAMERA_OFFSET = 0x58;
#endif

    auto& listener_camera = *(::REManagedObject**)((uintptr_t)listener + CAMERA_OFFSET);
    bool changed = false;

    if (listener_camera == nullptr) {
        auto primary_camera = sdk::get_primary_camera();

        if (primary_camera != nullptr) {
            listener_camera = primary_camera;
            changed = true;
        }
    }

    original_func(listener);

    if (changed) {
        listener_camera = nullptr;
    }

    if (!skip_camera_set) {
        mod->restore_audio_camera();
    }
}

// put it on the backburner
/*
float VR::get_sharpness_hook(void* tonemapping) {
    auto original_func = g_get_sharpness_hook->get_original<decltype(get_sharpness_hook)>();
    
    if (!g_framework->is_ready()) {
        return original_func(tonemapping);
    }

    auto& mod = VR::get();

    if (mod->m_disable_sharpening) {
        return 0.0f;
    }

    return original_func(tonemapping);
}
*/

NVSDK_NGX_Result hk_NVSDK_NGX_D3D12_CreateFeature(
    ID3D12GraphicsCommandList* InCmdList, NVSDK_NGX_Feature InFeatureID, NVSDK_NGX_Parameter* InParameters, NVSDK_NGX_Handle** OutHandle) {
    spdlog::info("hk_NVSDK_NGX_D3D12_CreateFeature FeatureID {}", (int)InFeatureID);
    auto result = o_NVSDK_NGX_D3D12_CreateFeature(InCmdList, InFeatureID, InParameters, OutHandle);
    const auto& vr = VR::get();
    int flag;
    InParameters->Get(NVSDK_NGX_Parameter_DLSS_Feature_Create_Flags, &flag);
    spdlog::info("hk_NVSDK_NGX_D3D12_CreateFeature 0x{0:x}", (INT64)result);
    if (vr->vrDLSSHandle[0] == NULL && (InFeatureID == NVSDK_NGX_Feature_SuperSampling || InFeatureID == NVSDK_NGX_Feature_RayReconstruction)) {
        vr->vrDLSSHandle[0] = *OutHandle;
        UINT width = 0, height = 0;
        InParameters->Get(NVSDK_NGX_Parameter_OutWidth, &width);
        InParameters->Get(NVSDK_NGX_Parameter_OutHeight, &height);
        vr->upscaled_size[0] = width;
        vr->upscaled_size[1] = height;
        spdlog::info("Creating additional DLSS instance");
        auto result2 = o_NVSDK_NGX_D3D12_CreateFeature(InCmdList, InFeatureID, InParameters, &vr->vrDLSSHandle[1]);
        spdlog::info("Additional DLSS instance create result 0x{0:x}", (INT64)result2);
        spdlog::info("Creating additional Foveated Rendering DLSS instance");
        result2 = o_NVSDK_NGX_D3D12_CreateFeature(InCmdList, InFeatureID, InParameters, &vr->vrDLSSHandleFR[0]);
        spdlog::info("Additional Foveated Rendering DLSS instance create result 0x{0:x}", (INT64)result2);
        result2 = o_NVSDK_NGX_D3D12_CreateFeature(InCmdList, InFeatureID, InParameters, &vr->vrDLSSHandleFR[1]);
        spdlog::info("Additional Foveated Rendering DLSS instance create result 0x{0:x}", (INT64)result2);
    }
    return result;
}

NVSDK_NGX_Result hk_NVSDK_NGX_D3D12_ReleaseFeature(NVSDK_NGX_Handle* InHandle) {
    spdlog::info("hk_NVSDK_NGX_D3D12_ReleaseFeature Starts");
    auto result = o_NVSDK_NGX_D3D12_ReleaseFeature(InHandle);
    spdlog::info("hk_NVSDK_NGX_D3D12_ReleaseFeature 0x{0:x}", (INT64)result);
    const auto& vr = VR::get();
    if (vr->vrDLSSHandle[0] == InHandle) {
        vr->vrDLSSHandle[0] = NULL;
        vr->depthDesc[0].pTexture = NULL;
        vr->depthDesc[1].pTexture = NULL;
        //vr->renderDepthDesc.pTexture = NULL;
        if (vr->vrDLSSHandle[1] != NULL) {
            auto result2 = o_NVSDK_NGX_D3D12_ReleaseFeature(vr->vrDLSSHandle[1]);
            spdlog::info("Additional DLSS instance release result 0x{0:x}", (INT64)result2);
            vr->vrDLSSHandle[1] = NULL;
        }
        if (vr->vrDLSSHandleFR[0] != NULL) {
            auto result2 = o_NVSDK_NGX_D3D12_ReleaseFeature(vr->vrDLSSHandleFR[0]);
            spdlog::info("Additional Foveated Rendering DLSS instance release result 0x{0:x}", (INT64)result2);
            vr->vrDLSSHandleFR[0] = NULL;
        }
        if (vr->vrDLSSHandleFR[0] != NULL) {
            auto result2 = o_NVSDK_NGX_D3D12_ReleaseFeature(vr->vrDLSSHandleFR[1]);
            spdlog::info("Additional Foveated Rendering DLSS instance release result 0x{0:x}", (INT64)result2);
            vr->vrDLSSHandleFR[1] = NULL;
        }
    }
    return result;
}

NVSDK_NGX_Result hk_NVSDK_NGX_D3D12_EvaluateFeature(
    ID3D12GraphicsCommandList* InCmdList, const NVSDK_NGX_Handle* InFeatureHandle, NVSDK_NGX_Parameter* InParameters, void* InCallback) {
    const auto& vr = VR::get();
    if (InFeatureHandle == vr->vrDLSSHandle[0]) {
        vr->vrDLSSParameters = InParameters;
        ID3D12Resource* color;
        ID3D12Resource* depth;
        ID3D12Resource* motionVectors;
        ID3D12Resource* output;
        InParameters->Get(NVSDK_NGX_Parameter_Color, &color);
        InParameters->Get(NVSDK_NGX_Parameter_Depth, &depth);
        InParameters->Get(NVSDK_NGX_Parameter_MotionVectors, &motionVectors);
        InParameters->Get(NVSDK_NGX_Parameter_Output, &output);
        float mvScaleX;
        float mvScaleY;
        InParameters->Get(NVSDK_NGX_Parameter_MV_Scale_X, &mvScaleX);
        InParameters->Get(NVSDK_NGX_Parameter_MV_Scale_Y, &mvScaleY);
        if (vr->is_hmd_active() && motionVectors && vr->motionVectorsDesc.pTexture) {

            //if (vr->renderDepthDesc.pTexture != depth) {
            //    vr->renderDepthDesc.pTexture = depth;
            //    vr->renderDepthDesc.initialState = D3D12_RESOURCE_STATE_DEPTH_READ;
            //    vr->d3d12Renderer->SetupTextureDesc(vr->renderDepthDesc);
            //    vr->renderDepthDesc.type = Depth;
            //}

            auto desc1 = motionVectors->GetDesc();
            auto desc2 = vr->motionVectorsDesc.pTexture->GetDesc();
            if ((abs((float)(desc1.Width - desc2.Width)) <= 2 && abs((float)(desc1.Height - desc2.Height)) <= 2 && desc1.Format == desc2.Format)) {
                TextureDesc src;
                src.pTexture = motionVectors;
                vr->d3d12Renderer->Copy(InCmdList, vr->motionVectorsDesc, src);

                if (vr->is_fix_dlss()) {
                    EyeIndex nEye = (vr->get_vr_frame_count() % 2 == 0) ? EyeLeft : EyeRight;
                    auto currHandle = vr->vrDLSSHandle[0];
                    if (nEye == EyeLeft) {
                        currHandle = vr->vrDLSSHandle[0];
                    } else {
                        currHandle = vr->vrDLSSHandle[1];
                    }

                    // current rendered eye
                    auto result = vr->o_NVSDK_NGX_D3D12_EvaluateFeature(InCmdList, currHandle, InParameters, InCallback);
                    if (NVSDK_NGX_FAILED(result)) {
                        spdlog::error("Failed DLSS 00, code = 0x{0:x}", result);
                    }
                    return result;
                }
            }
            else {
                spdlog::error("hk_NVSDK_NGX_D3D12_EvaluateFeature motionVectorsTex mistmatch! Desc1:{}x{} {}  Desc2:{}x{} {}", desc1.Width,
                    desc1.Height, (int)desc1.Format, desc2.Width, desc2.Height, (int)desc2.Format);
            }
        }
    }
    auto result = vr->o_NVSDK_NGX_D3D12_EvaluateFeature(InCmdList, InFeatureHandle, InParameters, InCallback);
    return result;
}

ffxReturnCode_t hk_ffxCreateContext(ffxContext* context, ffxCreateContextDescHeader* desc, const void** memCb) {
    auto vr = VR::get();
    auto result = o_ffxCreateContext(context, desc, memCb);
    spdlog::info("hk_ffxCreateContext 0x{0:x}", (INT64)result);
    if (desc->type == FFX_API_CREATE_CONTEXT_DESC_TYPE_UPSCALE) {
        auto createDesc = reinterpret_cast<const ffxCreateContextDescUpscale*>(desc);
        vr->upscaled_size[0] = createDesc->maxUpscaleSize.width;
        vr->upscaled_size[1] = createDesc->maxUpscaleSize.height;
        vr->vrContexts[0] = *context;
        spdlog::info("Creating additional FSR context");
        auto result2 = o_ffxCreateContext(&vr->vrContexts[1], desc, NULL);
        spdlog::info("Additional FSR context create result 0x{0:x}", (INT64)result2);
        spdlog::info("Creating additional Foveated Rendering FSR context");
        result2 = o_ffxCreateContext(&vr->vrContextsFR[0], desc, NULL);
        spdlog::info("Additional Foveated Rendering FSR context create result 0x{0:x}", (INT64)result2);
        result2 = o_ffxCreateContext(&vr->vrContextsFR[1], desc, NULL);
        spdlog::info("Additional Foveated Rendering FSR context create result 0x{0:x}", (INT64)result2);
    }
    return o_ffxCreateContext(context, desc, memCb);
}

ffxReturnCode_t hk_ffxDestroyContext(ffxContext* context, const void** memCb) {
    auto vr = VR::get();
    if (context == vr->vrContexts[0]) {
        spdlog::info("hk_ffxDestroyContext 0x{0:x}", (INT64)context);
        vr->vrContexts[0] = NULL;
        vr->depthDesc[0].pTexture = NULL;
        vr->depthDesc[1].pTexture = NULL;
        //vr->renderDepthDesc.pTexture = NULL;
        if (vr->vrContexts[1] != NULL) {
            auto result2 = o_ffxDestroyContext(&vr->vrContexts[1], NULL);
            spdlog::info("Additional FSR context release result 0x{0:x}", (INT64)result2);
            vr->vrContexts[1] = NULL;
        }
        if (vr->vrContexts[1] != NULL) {
            auto result2 = o_ffxDestroyContext(&vr->vrContextsFR[0], NULL);
            spdlog::info("Additional Foveated Rendering FSR context release result 0x{0:x}", (INT64)result2);
            vr->vrContextsFR[0] = NULL;
        }
        if (vr->vrContexts[1] != NULL) {
            auto result2 = o_ffxDestroyContext(&vr->vrContextsFR[1], NULL);
            spdlog::info("Additional Foveated Rendering FSR context release result 0x{0:x}", (INT64)result2);
            vr->vrContextsFR[1] = NULL;
        }
    }
    return o_ffxDestroyContext(context, memCb);
}

ffxReturnCode_t hk_ffxDispatch(ffxContext* context, const ffxDispatchDescHeader* desc) {
    auto vr = VR::get();
    if (desc->type == FFX_API_DISPATCH_DESC_TYPE_UPSCALE) {
        auto upscaleDesc = reinterpret_cast<const ffxDispatchDescUpscale*>(desc);

        FfxApiResource depthApiResource = upscaleDesc->depth;
        FfxApiResource mvApiResource = upscaleDesc->motionVectors;
        float mvScaleX = upscaleDesc->motionVectorScale[0];
        float mvScaleY = upscaleDesc->motionVectorScale[1];
        if (vr->is_hmd_active() && mvApiResource.resource && vr->motionVectorsDesc.pTexture) {
            auto InCmdList = (ID3D12GraphicsCommandList*)upscaleDesc->commandList;
            auto motionVectors = (ID3D12Resource*)mvApiResource.resource;
            auto desc1 = motionVectors->GetDesc();
            auto desc2 = vr->motionVectorsDesc.pTexture->GetDesc();
            if ((desc1.Width == desc2.Width && desc1.Height == desc2.Height && desc1.Format == desc2.Format)) {
                TextureDesc src;
                src.pTexture = motionVectors;
                vr->d3d12Renderer->Copy(InCmdList, vr->motionVectorsDesc, src);
                if (vr->is_fix_dlss()) {
                    EyeIndex nEye = (vr->get_vr_frame_count() % 2 == 0) ? EyeLeft : EyeRight;
                    auto currHandle = vr->vrContexts[0];
                    if (nEye == EyeLeft) {
                        currHandle = vr->vrContexts[0];
                    } else {
                        currHandle = vr->vrContexts[1];
                    }

                    // current rendered eye
                    auto result = vr->o_ffxDispatch(&currHandle, desc);
                    if (NVSDK_NGX_FAILED(result)) {
                        spdlog::error("Failed FSR 00, code = 0x{0:x}", result);
                    }
                    return result;
                }
            } else {
                spdlog::error("hk_ffxDispatch motionVectorsTex mistmatch! Desc1:{}x{} {}  Desc2:{}x{} {}", desc1.Width,
                    desc1.Height, (int)desc1.Format, desc2.Width, desc2.Height, (int)desc2.Format);
            }
        }
    }
    return vr->o_ffxDispatch(context, desc);
}

static std::unordered_map<SIZE_T, ID3D12Resource*> rtvMap{};

decltype(&ID3D12GraphicsCommandList::ClearRenderTargetView) ptrClearRenderTargetView; // 48
void WINAPI hk_ID3D12GraphicsCommandList_ClearRenderTargetView(ID3D12GraphicsCommandList* This, D3D12_CPU_DESCRIPTOR_HANDLE RenderTargetView, const FLOAT  ColorRGBA[4], UINT NumRects, const D3D12_RECT* pRects)
{
    const auto& vr = VR::get();
    if ((ColorRGBA[0] == 1.0f || ColorRGBA[1] == 1.0f) && rtvMap.contains(RenderTargetView.ptr)) {
        auto rtvTex = rtvMap[RenderTargetView.ptr];
        int eyeIndex = 0;
        if (ColorRGBA[0] == 1.0f) {
            //spdlog::info("Cleared RED! rtvTex = {:p}", (void*)rtvMap[RenderTargetView.ptr]);
            eyeIndex = ColorRGBA[3] == 0 ? 0 : 1;
        }
        else if (ColorRGBA[1] == 1.0f) {
            //spdlog::info("Cleared GREEN! rtvTex = {:p}", (void*)rtvMap[RenderTargetView.ptr]);
            eyeIndex = ColorRGBA[3] == 0 ? 0 : 1;
        }

        static TextureDesc tempBufferDesc[2];
        if (tempBufferDesc[eyeIndex].pTexture != rtvTex) {
            tempBufferDesc[eyeIndex].pTexture = rtvTex;
            tempBufferDesc[eyeIndex].initialState = D3D12_RESOURCE_STATE_RENDER_TARGET;
            vr->d3d12Renderer->SetupTextureDesc(tempBufferDesc[eyeIndex]);
        }
        //vr->d3d12Renderer->Blit(This, vr->m_d3d12.m_eyeFrameBuffers.eyeFrameBuffers[eyeIndex].color, tempBufferDesc[eyeIndex]);

        if (!vr->multipassBackupDesc[eyeIndex].pTexture) {
            auto desc = tempBufferDesc[eyeIndex].pTexture->GetDesc();
            vr->d3d12Renderer->CreateTexture(desc.Width, desc.Height, desc.Format, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, vr->multipassBackupDesc[eyeIndex], true);
            vr->d3d12Renderer->CreateTexture(vr->upscaled_size[0], vr->upscaled_size[1], desc.Format, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, vr->multipassUpscaledDesc[eyeIndex], true);
        } else {
            auto desc1 = vr->multipassBackupDesc[eyeIndex].pTexture->GetDesc();
            auto desc2 = tempBufferDesc[eyeIndex].pTexture->GetDesc();
            if (desc1.Width != desc2.Width || desc1.Height != desc2.Height || desc1.Format != desc2.Format) {
                vr->d3d12Renderer->CreateTexture(desc2.Width, desc2.Height, desc2.Format, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, vr->multipassBackupDesc[eyeIndex], true);
                vr->d3d12Renderer->CreateTexture(vr->upscaled_size[0], vr->upscaled_size[1], desc2.Format, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, vr->multipassUpscaledDesc[eyeIndex],true);
            }
        }

        if (vr->multipassBackupDesc[eyeIndex].pTexture) {
            vr->d3d12Renderer->Copy(This, vr->multipassBackupDesc[eyeIndex], tempBufferDesc[eyeIndex]);
        }
        return;

        //ID3D12Resource* destTex = vr->m_multipass.eye_textures[eyeIndex].Get();
        //if (destTex) {
        //    D3D12_RESOURCE_BARRIER barriers1[] = {
        //        CD3DX12_RESOURCE_BARRIER::Transition(rtvTex, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_SOURCE),
        //        CD3DX12_RESOURCE_BARRIER::Transition(destTex, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_DEST)};
        //    This->ResourceBarrier(_countof(barriers1), barriers1);
        //    This->CopyResource(destTex, rtvTex);
        //    D3D12_RESOURCE_BARRIER barriers2[] = {
        //        CD3DX12_RESOURCE_BARRIER::Transition(rtvTex, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET),
        //        CD3DX12_RESOURCE_BARRIER::Transition(destTex, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_RENDER_TARGET)};
        //    This->ResourceBarrier(_countof(barriers2), barriers2);
        //}
    }

    return (This->*ptrClearRenderTargetView)(RenderTargetView, ColorRGBA, NumRects, pRects);
}

//decltype(&ID3D12GraphicsCommandList::CopyTextureRegion) ptrCopyTextureRegion; // 16
//void WINAPI hk_ID3D12GraphicsCommandList_CopyTextureRegion(ID3D12GraphicsCommandList* This, const D3D12_TEXTURE_COPY_LOCATION* pDst,
//    UINT DstX, UINT DstY, UINT DstZ, _In_ const D3D12_TEXTURE_COPY_LOCATION* pSrc, _In_opt_ const D3D12_BOX* pSrcBox) {
//    const auto& vr = VR::get();
//    if (pDst->pResource == vr->m_multipass.eye_textures[0].Get() || pDst->pResource == vr->m_multipass.eye_textures[1].Get()) {
//        spdlog::info("Copy Resource dest eye texture {:p}", (void*)pDst->pResource);
//    }
//    if (pSrc->pResource == vr->m_multipass.native_textures[0].Get() || pSrc->pResource == vr->m_multipass.native_textures[1].Get()) {
//        spdlog::info("Copy Resource src native texture {:p}", (void*)pSrc->pResource);
//    }
//    return (This->*ptrCopyTextureRegion)(pDst, DstX, DstY, DstZ, pSrc, pSrcBox);
//}
//
//decltype(&ID3D12GraphicsCommandList::CopyResource) ptrCopyResource; // 17
//void WINAPI hk_ID3D12GraphicsCommandList_CopyResource(ID3D12GraphicsCommandList* This, ID3D12Resource* pDstResource, ID3D12Resource* pSrcResource) {
//    const auto& vr = VR::get();
//    if (pDstResource == vr->m_multipass.eye_textures[0].Get() || pDstResource == vr->m_multipass.eye_textures[1].Get()) {
//        spdlog::info("Copy Resource dest eye texture {:p}", (void*)pDstResource);
//    }
//    if (pSrcResource == vr->m_multipass.native_textures[0].Get() || pSrcResource == vr->m_multipass.native_textures[1].Get()) {
//        spdlog::info("Copy Resource src native texture {:p}", (void*)pSrcResource);
//    }
//    return (This->*ptrCopyResource)(pDstResource, pSrcResource);
//}

decltype(&ID3D12Device::CreateRenderTargetView) ptrCreateRenderTargetView; // 20
void WINAPI hk_ID3D12Device_CreateRenderTargetView(ID3D12Device* This, ID3D12Resource* pResource, const D3D12_RENDER_TARGET_VIEW_DESC* pDesc, D3D12_CPU_DESCRIPTOR_HANDLE DestDescriptor) 
{
    (This->*ptrCreateRenderTargetView)(pResource, pDesc, DestDescriptor);
    rtvMap[DestDescriptor.ptr] = pResource;
}

uintptr_t hookVtable(void* target, int index, void* detours) {
    uintptr_t* pVTable = *(uintptr_t**)target;
    DWORD dwOldProct = 0;
    BOOL bRet = ::VirtualProtect(pVTable, 4, PAGE_READWRITE, &dwOldProct);
    auto origFunc = pVTable[index];
    pVTable[index] = (uintptr_t)detours;
    return origFunc;
}

// Called when the mod is initialized
std::optional<std::string> VR::on_initialize_d3d_thread() try {

    // #############################
    // #Frame Warp Module Start
    // #############################
    auto& hook = g_framework->get_d3d12_hook();
    hook->get_command_queue();
    pd::DeviceParams params{};
    params.d3d12Device = hook->get_device();
    params.d3d12Queue = hook->get_command_queue();
    d3d12Renderer = InitDevice(params);

    *(uintptr_t*)&ptrCreateRenderTargetView = hookVtable(params.d3d12Device, 20, hk_ID3D12Device_CreateRenderTargetView);

    auto cmdList = d3d12Renderer->BeginCommandList(0);
    *(uintptr_t*)&ptrClearRenderTargetView = hookVtable(cmdList, 48, hk_ID3D12GraphicsCommandList_ClearRenderTargetView);
    //*(uintptr_t*)&ptrCopyTextureRegion = hookVtable(cmdList, 16, hk_ID3D12GraphicsCommandList_CopyTextureRegion);
    //*(uintptr_t*)&ptrCopyResource = hookVtable(cmdList, 17, hk_ID3D12GraphicsCommandList_CopyResource);
    d3d12Renderer->EndCommandList(0);

    if (auto mr = MH_Initialize(); mr != MH_OK) {
        spdlog::error("MH_Initialize failed: {}", (INT)mr);
    }
    
    auto dllNGX = GetModuleHandle("_nvngx.dll");
    if (!dllNGX)
        dllNGX = GetModuleHandle("nvngx.dll");
    if (!dllNGX) {
        spdlog::error("nvngx.dll not loaded!");
    } else {
        if (auto mr = MH_CreateHook(GetProcAddress(dllNGX, "NVSDK_NGX_D3D12_CreateFeature"), &hk_NVSDK_NGX_D3D12_CreateFeature,
                (PVOID*)&o_NVSDK_NGX_D3D12_CreateFeature);
            mr != MH_OK) {
            spdlog::error("Hook NVSDK_NGX_D3D12_CreateFeature Failed! {}", (INT)mr);
            return Mod::on_initialize();
        }
        if (auto mr = MH_CreateHook(GetProcAddress(dllNGX, "NVSDK_NGX_D3D12_ReleaseFeature"), &hk_NVSDK_NGX_D3D12_ReleaseFeature,
                (PVOID*)&o_NVSDK_NGX_D3D12_ReleaseFeature);
            mr != MH_OK) {
            spdlog::error("Hook NVSDK_NGX_D3D12_ReleaseFeature Failed! {}", (INT)mr);
            return Mod::on_initialize();
        }
        if (auto mr = MH_CreateHook(GetProcAddress(dllNGX, "NVSDK_NGX_D3D12_EvaluateFeature"), &hk_NVSDK_NGX_D3D12_EvaluateFeature,
                (PVOID*)&o_NVSDK_NGX_D3D12_EvaluateFeature);
            mr != MH_OK) {
            spdlog::error("Hook NVSDK_NGX_D3D12_EvaluateFeature Failed! {}", (INT)mr);
            return Mod::on_initialize();
        }
        if (MH_EnableHook(MH_ALL_HOOKS) != MH_OK)
            throw std::runtime_error("UpscalerHooks::Install - Failed to enable hooks!");
    }
    auto dllFfx = GetModuleHandle("amd_fidelityfx_upscaler_dx12.dll");
    if (!dllFfx)
        dllFfx = GetModuleHandle("amd_fidelityfx_loader_dx12.dll");
    if (!dllFfx) {
        spdlog::error("amd_fidelityfx_upscaler_dx12.dll not loaded!");
    } else {
        if (auto mr = MH_CreateHook(GetProcAddress(dllFfx, "ffxCreateContext"), &hk_ffxCreateContext, (PVOID*)&o_ffxCreateContext);
            mr != MH_OK) {
            spdlog::error("Hook ffxCreateContext Failed! {}", (INT)mr);
            return Mod::on_initialize();
        }
        if (auto mr = MH_CreateHook(GetProcAddress(dllFfx, "ffxDestroyContext"), &hk_ffxDestroyContext, (PVOID*)&o_ffxDestroyContext);
            mr != MH_OK) {
            spdlog::error("Hook ffxDestroyContext Failed! {}", (INT)mr);
            return Mod::on_initialize();
        }
        if (auto mr = MH_CreateHook(GetProcAddress(dllFfx, "ffxDispatch"), &hk_ffxDispatch, (PVOID*)&o_ffxDispatch);
            mr != MH_OK) {
            spdlog::error("Hook ffxDispatch Failed! {}", (INT)mr);
            return Mod::on_initialize();
        }
        if (MH_EnableHook(MH_ALL_HOOKS) != MH_OK)
            throw std::runtime_error("UpscalerHooks::Install - Failed to enable hooks!");
    }

    // #############################
    // #Frame Warp Module End
    // #############################

    auto openvr_error = initialize_openvr();

    if (openvr_error || !m_openvr->loaded) {
        if (m_openvr->error) {
            spdlog::info("OpenVR failed to load: {}", *m_openvr->error);
        }

        m_openvr->is_hmd_active = false;
        m_openvr->was_hmd_active = false;
        m_openvr->needs_pose_update = false;

        // Attempt to load OpenXR instead
        auto openxr_error = initialize_openxr();

        if (openxr_error || !m_openxr->loaded) {
            m_openxr->needs_pose_update = false;
        }
    } else {
        m_openxr->error = 
R"(OpenVR loaded first.
If you want to use OpenXR, remove the openvr_api.dll from your game folder, 
and place the openxr_loader.dll in the same folder.)";
    }

    if (!get_runtime()->loaded) {
        // this is okay. we're not going to fail the whole thing entirely
        // so we're just going to return OK, but
        // when the VR mod draws its menu, it'll say "VR is not available"
        return Mod::on_initialize();
    }

    // Check whether the user has Hardware accelerated GPU scheduling enabled
    const auto hw_schedule_value = utility::get_registry_dword(
        HKEY_LOCAL_MACHINE,
        "SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers",
        "HwSchMode");

    if (hw_schedule_value) {
        m_has_hw_scheduling = *hw_schedule_value == 2;
    }

    auto hijack_error = hijack_resolution();

    if (hijack_error) {
        return hijack_error;
    }

    hijack_error = hijack_input();

    if (hijack_error) {
        return hijack_error;
    }

    hijack_error = hijack_camera();

    if (hijack_error) {
        return hijack_error;
    }

    hijack_error = hijack_wwise_listeners();

    if (hijack_error) {
        return hijack_error;
    }

    const auto renderer_t = sdk::find_type_definition("via.render.Renderer");

    if (renderer_t != nullptr) {
        const auto set_hdr_method = renderer_t->get_method("set_HDRMode");

        if (set_hdr_method != nullptr) {
            spdlog::info("Hooking setHDRMode");
            g_hookman.add(set_hdr_method, &pre_set_hdr_mode, &post_set_hdr_mode);
        }
    }

    m_init_finished = true;

    // all OK
    return Mod::on_initialize();
} catch(...) {
    spdlog::error("Exception occurred in VR::on_initialize()");

    m_runtime->error = "Exception occurred in VR::on_initialize()";
    m_openxr->dll_missing = false;
    m_openvr->dll_missing = false;
    m_openxr->error = "Exception occurred in VR::on_initialize()";
    m_openvr->error = "Exception occurred in VR::on_initialize()";
    m_openvr->loaded = false;
    m_openvr->is_hmd_active = false;
    m_openxr->loaded = false;
    m_init_finished = false;

    return Mod::on_initialize();
}

void VR::on_lua_state_created(sol::state& lua) {
    lua.new_usertype<VR>("VR",
        "get_controllers", &VR::get_controllers,
        "get_position", &VR::get_position,
        "get_velocity", &VR::get_velocity,
        "get_angular_velocity", &VR::get_angular_velocity,
        "get_rotation", &VR::get_rotation,
        "get_transform", &VR::get_transform,
        "get_left_stick_axis", &VR::get_left_stick_axis,
        "get_right_stick_axis", &VR::get_right_stick_axis,
        "get_current_eye_transform", &VR::get_current_eye_transform,
        "get_current_projection_matrix", &VR::get_current_projection_matrix,
        "get_standing_origin", &VR::get_standing_origin,
        "set_standing_origin", &VR::set_standing_origin,
        "get_rotation_offset", &VR::get_rotation_offset,
        "set_rotation_offset", &VR::set_rotation_offset,
        "recenter_view", &VR::recenter_view,
        "get_gui_rotation_offset", &VR::get_gui_rotation_offset,
        "set_gui_rotation_offset", &VR::set_gui_rotation_offset,
        "recenter_gui", &VR::recenter_gui,
        "get_action_set", &VR::get_action_set,
        "get_active_action_set", &VR::get_active_action_set,
        "get_action_trigger", &VR::get_action_trigger,
        "get_action_grip", &VR::get_action_grip,
        "get_action_joystick", &VR::get_action_joystick,
        "get_action_joystick_click", &VR::get_action_joystick_click,
        "get_action_a_button", &VR::get_action_a_button,
        "get_action_b_button", &VR::get_action_b_button,
        "get_action_weapon_dial", &VR::get_action_weapon_dial,
        "get_action_minimap", &VR::get_action_minimap,
        "get_action_block", &VR::get_action_block,
        "get_action_dpad_up", &VR::get_action_dpad_up,
        "get_action_dpad_down", &VR::get_action_dpad_down,
        "get_action_dpad_left", &VR::get_action_dpad_left,
        "get_action_dpad_right", &VR::get_action_dpad_right,
        "get_action_heal", &VR::get_action_heal,
        "get_left_joystick", &VR::get_left_joystick,
        "get_right_joystick", &VR::get_right_joystick,
        "is_using_controllers", &VR::is_using_controllers,
        "is_openvr_loaded", &VR::is_openvr_loaded,
        "is_openxr_loaded", &VR::is_openxr_loaded,
        "is_hmd_active", &VR::is_hmd_active,
        "is_action_active", &VR::is_action_active,
        "is_using_hmd_oriented_audio", &VR::is_using_hmd_oriented_audio,
        "toggle_hmd_oriented_audio", &VR::toggle_hmd_oriented_audio,
        "apply_hmd_transform", [](VR* vr, glm::quat& rotation, Vector4f& position) {
            vr->apply_hmd_transform(rotation, position);
        },
        "trigger_haptic_vibration", &VR::trigger_haptic_vibration,
        "get_last_render_matrix", &VR::get_last_render_matrix,
        "should_handle_pause", [](VR* vr) { 
            return vr->get_runtime()->handle_pause;
        },
        "set_handle_pause", [](VR* vr, bool state) { 
            return vr->get_runtime()->handle_pause = state;
        },
        "unhide_crosshair", &VR::unhide_crosshair
    );

    lua["vrmod"] = this;
}

std::optional<std::string> VR::initialize_openvr() {
    m_openvr = std::make_shared<runtimes::OpenVR>();
    m_openvr->loaded = false;

    if (utility::load_module_from_current_directory(L"openvr_api.dll") == nullptr) {
        spdlog::info("[VR] Could not load openvr_api.dll");

        m_openvr->dll_missing = true;
        m_openvr->error = "Could not load openvr_api.dll";
        return Mod::on_initialize();
    }

    if (g_framework->is_dx12()) {
        m_d3d12.on_reset(this);
    } else {
        m_d3d11.on_reset(this);
    }

    m_openvr->needs_pose_update = true;
    m_openvr->got_first_poses = false;
    m_openvr->is_hmd_active = true;
    m_openvr->was_hmd_active = true;

    auto error = vr::VRInitError_None;
	m_openvr->hmd = vr::VR_Init(&error, vr::VRApplication_Scene);

    // check if error
    if (error != vr::VRInitError_None) {
        m_openvr->error = "VR_Init failed: " + std::string{vr::VR_GetVRInitErrorAsEnglishDescription(error)};
        return Mod::on_initialize();
    }

    if (m_openvr->hmd == nullptr) {
        m_openvr->error = "VR_Init failed: HMD is null";
        return Mod::on_initialize();
    }

    // get render target size
    m_openvr->update_render_target_size();

    if (vr::VRCompositor() == nullptr) {
        m_openvr->error = "VRCompositor failed to initialize.";
        return Mod::on_initialize();
    }

    auto input_error = initialize_openvr_input();

    if (input_error) {
        m_openvr->error = *input_error;
        return Mod::on_initialize();
    }

    auto overlay_error = m_overlay_component.on_initialize_openvr();

    if (overlay_error) {
        m_openvr->error = *overlay_error;
        return Mod::on_initialize();
    }
    
    m_openvr->loaded = true;
    m_openvr->error = std::nullopt;
    m_runtime = m_openvr;

    return Mod::on_initialize();
}

std::optional<std::string> VR::initialize_openvr_input() {
    const auto module_directory = REFramework::get_persistent_dir();

    // write default actions and bindings with the static strings we have
    for (auto& it : m_binding_files) {
        spdlog::info("Writing default binding file {}", it.first);

        std::ofstream file{ module_directory / it.first };
        file << it.second;
    }

    const auto actions_path = module_directory / "actions.json";
    auto input_error = vr::VRInput()->SetActionManifestPath(actions_path.string().c_str());

    if (input_error != vr::VRInputError_None) {
        return "VRInput failed to set action manifest path: " + std::to_string((uint32_t)input_error);
    }

    // get action set
    auto action_set_error = vr::VRInput()->GetActionSetHandle("/actions/default", &m_action_set);

    if (action_set_error != vr::VRInputError_None) {
        return "VRInput failed to get action set: " + std::to_string((uint32_t)action_set_error);
    }

    if (m_action_set == vr::k_ulInvalidActionSetHandle) {
        return "VRInput failed to get action set handle.";
    }

    for (auto& it : m_action_handles) {
        auto error = vr::VRInput()->GetActionHandle(it.first.c_str(), &it.second.get());

        if (error != vr::VRInputError_None) {
            return "VRInput failed to get action handle: (" + it.first + "): " + std::to_string((uint32_t)error);
        }

        if (it.second == vr::k_ulInvalidActionHandle) {
            return "VRInput failed to get action handle: (" + it.first + ")";
        }
    }

    m_active_action_set.ulActionSet = m_action_set;
    m_active_action_set.ulRestrictedToDevice = vr::k_ulInvalidInputValueHandle;
    m_active_action_set.nPriority = 0;

    detect_controllers();

    return std::nullopt;
}

std::optional<std::string> VR::initialize_openxr() {
    m_openxr = std::make_shared<runtimes::OpenXR>();

    spdlog::info("[VR] Initializing OpenXR");

    if (utility::load_module_from_current_directory(L"openxr_loader.dll") == nullptr) {
        spdlog::info("[VR] Could not load openxr_loader.dll");

        m_openxr->loaded = false;
        m_openxr->error = "Could not load openxr_loader.dll";

        return std::nullopt;
    }

    if (g_framework->is_dx12()) {
        m_d3d12.on_reset(this);
    } else {
        m_d3d11.on_reset(this);
    }

    m_openxr->needs_pose_update = true;
    m_openxr->got_first_poses = false;

    // Step 1: Create an instance
    spdlog::info("[VR] Creating OpenXR instance");

    XrResult result{XR_SUCCESS};

    // We may just be restarting OpenXR, so try to find an existing instance first
    if (m_openxr->instance == XR_NULL_HANDLE) {
        std::vector<const char*> extensions{};

        if (g_framework->is_dx12()) {
            extensions.push_back(XR_KHR_D3D12_ENABLE_EXTENSION_NAME);
        } else {
            extensions.push_back(XR_KHR_D3D11_ENABLE_EXTENSION_NAME);
        }
        XrResult res;
        uint32_t extCount = 0;

        res = xrEnumerateInstanceExtensionProperties(nullptr, 0, &extCount, nullptr);
        assert(res == XR_SUCCESS);

        std::vector<XrExtensionProperties> exts(extCount, {XR_TYPE_EXTENSION_PROPERTIES});
        res = xrEnumerateInstanceExtensionProperties(nullptr, extCount, &extCount, exts.data());
        assert(res == XR_SUCCESS);

        bool supportsEyeGaze = false;
        for (const auto& ext : exts) {
            if (strcmp(ext.extensionName, XR_EXT_EYE_GAZE_INTERACTION_EXTENSION_NAME) == 0) {
                supportsEyeGaze = true;
                break;
            }
        }

        if (!supportsEyeGaze) {
            spdlog::info("[VR] OpenXR no eye gaze support!");
        } else {
            extensions.push_back(XR_EXT_EYE_GAZE_INTERACTION_EXTENSION_NAME);
        }

        XrInstanceCreateInfo instance_create_info{XR_TYPE_INSTANCE_CREATE_INFO};
        instance_create_info.next = nullptr;
        instance_create_info.enabledExtensionCount = (uint32_t)extensions.size();
        instance_create_info.enabledExtensionNames = extensions.data();

        strcpy(instance_create_info.applicationInfo.applicationName, g_framework->get_game_name());
        instance_create_info.applicationInfo.apiVersion = XR_CURRENT_API_VERSION;
        
        result = xrCreateInstance(&instance_create_info, &m_openxr->instance);

        // we can't convert the result to a string here
        // because the function requires the instance to be valid
        if (result != XR_SUCCESS) {
            m_openxr->error = "Could not create openxr instance: " + std::to_string((int32_t)result);
            spdlog::error("[VR] {}", m_openxr->error.value());

            return std::nullopt;
        }

    } else {
        spdlog::info("[VR] Found existing openxr instance");
    }
    
    // Step 2: Create a system
    spdlog::info("[VR] Creating OpenXR system");

    // We may just be restarting OpenXR, so try to find an existing system first
    if (m_openxr->system == XR_NULL_SYSTEM_ID) {
        XrSystemGetInfo system_info{XR_TYPE_SYSTEM_GET_INFO};
        system_info.formFactor = m_openxr->form_factor;

        result = xrGetSystem(m_openxr->instance, &system_info, &m_openxr->system);

        if (result != XR_SUCCESS) {
            m_openxr->error = "Could not create openxr system: " + m_openxr->get_result_string(result);
            spdlog::error("[VR] {}", m_openxr->error.value());

            return std::nullopt;
        }
    } else {
        spdlog::info("[VR] Found existing openxr system");
    }

    // Step 3: Create a session
    spdlog::info("[VR] Initializing graphics info");

    XrSessionCreateInfo session_create_info{XR_TYPE_SESSION_CREATE_INFO};

    if (g_framework->is_dx12()) {
        m_d3d12.openxr().initialize(session_create_info);
    } else {
        m_d3d11.openxr().initialize(session_create_info);
    }

    spdlog::info("[VR] Creating OpenXR session");
    session_create_info.systemId = m_openxr->system;
    result = xrCreateSession(m_openxr->instance, &session_create_info, &m_openxr->session);

    if (result != XR_SUCCESS) {
        m_openxr->error = "Could not create openxr session: " + m_openxr->get_result_string(result);
        spdlog::error("[VR] {}", m_openxr->error.value());

        return std::nullopt;
    }

    XrSystemEyeGazeInteractionPropertiesEXT eyeGazeProps = {.type = XR_TYPE_SYSTEM_EYE_GAZE_INTERACTION_PROPERTIES_EXT, .next = nullptr};
    XrSystemProperties systemProps = {.type = XR_TYPE_SYSTEM_PROPERTIES, .next = &eyeGazeProps};
    xrGetSystemProperties(m_openxr->instance, m_openxr->system, &systemProps);
    m_openxr->supportsEyeGazeInteraction = eyeGazeProps.supportsEyeGazeInteraction;

    // Step 4: Create a space
    spdlog::info("[VR] Creating OpenXR space");

    // We may just be restarting OpenXR, so try to find an existing space first

    if (m_openxr->stage_space == XR_NULL_HANDLE) {
        XrReferenceSpaceCreateInfo space_create_info{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
        space_create_info.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
        space_create_info.poseInReferenceSpace = {};
        space_create_info.poseInReferenceSpace.orientation.w = 1.0f;

        result = xrCreateReferenceSpace(m_openxr->session, &space_create_info, &m_openxr->stage_space);

        if (result != XR_SUCCESS) {
            m_openxr->error = "Could not create openxr stage space: " + m_openxr->get_result_string(result);
            spdlog::error("[VR] {}", m_openxr->error.value());

            return std::nullopt;
        }
    }

    if (m_openxr->view_space == XR_NULL_HANDLE) {
        XrReferenceSpaceCreateInfo space_create_info{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
        space_create_info.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW;
        space_create_info.poseInReferenceSpace = {};
        space_create_info.poseInReferenceSpace.orientation.w = 1.0f;

        result = xrCreateReferenceSpace(m_openxr->session, &space_create_info, &m_openxr->view_space);

        if (result != XR_SUCCESS) {
            m_openxr->error = "Could not create openxr view space: " + m_openxr->get_result_string(result);
            spdlog::error("[VR] {}", m_openxr->error.value());

            return std::nullopt;
        }
    }

    // Step 5: Get the system properties
    spdlog::info("[VR] Getting OpenXR system properties");

    XrSystemProperties system_properties{XR_TYPE_SYSTEM_PROPERTIES};
    result = xrGetSystemProperties(m_openxr->instance, m_openxr->system, &system_properties);

    if (result != XR_SUCCESS) {
        m_openxr->error = "Could not get system properties: " + m_openxr->get_result_string(result);
        spdlog::error("[VR] {}", m_openxr->error.value());

        return std::nullopt;
    }

    spdlog::info("[VR] OpenXR system Name: {}", system_properties.systemName);
    spdlog::info("[VR] OpenXR system Vendor: {}", system_properties.vendorId);
    spdlog::info("[VR] OpenXR system max width: {}", system_properties.graphicsProperties.maxSwapchainImageWidth);
    spdlog::info("[VR] OpenXR system max height: {}", system_properties.graphicsProperties.maxSwapchainImageHeight);
    spdlog::info("[VR] OpenXR system supports {} layers", system_properties.graphicsProperties.maxLayerCount);
    spdlog::info("[VR] OpenXR system orientation: {}", system_properties.trackingProperties.orientationTracking);
    spdlog::info("[VR] OpenXR system position: {}", system_properties.trackingProperties.positionTracking);

    // Step 6: Get the view configuration properties
    m_openxr->update_render_target_size();

    // Step 7: Create a view
    if (!m_openxr->view_configs.empty()){
        m_openxr->views.resize(m_openxr->view_configs.size(), {XR_TYPE_VIEW});
        m_openxr->stage_views.resize(m_openxr->view_configs.size(), {XR_TYPE_VIEW});
    }

    if (m_openxr->view_configs.empty()) {
        m_openxr->error = "No view configurations found";
        spdlog::error("[VR] {}", m_openxr->error.value());

        return std::nullopt;
    }

    m_openxr->loaded = true;
    m_runtime = m_openxr;

    if (auto err = initialize_openxr_input()) {
        m_openxr->error = err.value();
        m_openxr->loaded = false;
        spdlog::error("[VR] {}", m_openxr->error.value());

        return std::nullopt;
    }

    detect_controllers();

    if (m_init_finished) {
        // This is usually done in on_config_load
        // but the runtime can be reinitialized, so we do it here instead
        initialize_openxr_swapchains();
    }

    return std::nullopt;
}

std::optional<std::string> VR::initialize_openxr_input() {
    if (auto err = m_openxr->initialize_actions(VR::actions_json)) {
        m_openxr->error = err.value();
        spdlog::error("[VR] {}", m_openxr->error.value());

        return std::nullopt;
    }
    
    for (auto& it : m_action_handles) {
        auto openxr_action_name = m_openxr->translate_openvr_action_name(it.first);

        if (m_openxr->action_set.action_map.contains(openxr_action_name)) {
            it.second.get() = (decltype(it.second)::type)m_openxr->action_set.action_map[openxr_action_name];
            spdlog::info("[VR] Successfully mapped action {} to {}", it.first, openxr_action_name);
        }
    }

    m_left_joystick = (decltype(m_left_joystick))VRRuntime::Hand::LEFT;
    m_right_joystick = (decltype(m_right_joystick))VRRuntime::Hand::RIGHT;

    return std::nullopt;
}

std::optional<std::string> VR::initialize_openxr_swapchains() {
    // This depends on the config being loaded.
    if (!m_init_finished) {
        return std::nullopt;
    }

    spdlog::info("[VR] Creating OpenXR swapchain");

    if (g_framework->is_dx12()) {
        auto err = m_d3d12.openxr().create_swapchains();

        if (err) {
            m_openxr->error = err.value();
            m_openxr->loaded = false;
            spdlog::error("[VR] {}", m_openxr->error.value());

            return m_openxr->error;
        }
    } else {
        auto err = m_d3d11.openxr().create_swapchains();

        if (err) {
            m_openxr->error = err.value();
            m_openxr->loaded = false;
            spdlog::error("[VR] {}", m_openxr->error.value());
            return m_openxr->error;
        }
    }

    return std::nullopt;
}

std::optional<std::string> VR::hijack_resolution() {
    // moved to global hook class
    return std::nullopt;
}

std::optional<std::string> VR::hijack_input() {
#if defined(RE2) || defined(RE3)
    spdlog::info("[VR] Hijacking InputSystem");

    // We're going to hook InputSystem.update so we can
    // override the analog stick values with the VR controller's
    auto func = sdk::find_native_method(game_namespace("InputSystem"), "update");

    if (func == nullptr) {
        return "VR init failed: InputSystem.update function not found.";
    }

    spdlog::info("InputSystem.update: {:x}", (uintptr_t)func);

    // Hook the native function
    g_input_hook = std::make_unique<FunctionHook>(func, inputsystem_update_hook);

    if (!g_input_hook->create()) {
        return "VR init failed: InputSystem.update native function hook failed.";
    }
#endif

    return std::nullopt;
}

std::optional<std::string> VR::hijack_camera() {
    spdlog::info("[VR] Hijacking Camera");

    const auto get_projection_matrix = (uintptr_t)sdk::find_native_method("via.Camera", "get_ProjectionMatrix");

    ///////////////////////////////
    // Hook GUI camera projection matrix start
    ///////////////////////////////
    auto func = sdk::find_native_method("via.gui.GUICamera", "get_ProjectionMatrix");

    if (func != nullptr) {
        spdlog::info("via.gui.GUICamera.get_ProjectionMatrix: {:x}", (uintptr_t)func);
        
        // Pattern scan for the native function call
        auto ref = utility::scan((uintptr_t)func, 0x100, "49 8B C8 E8");

        if (ref) {
            auto native_func = utility::calculate_absolute(*ref + 4);

            if (native_func != get_projection_matrix) {
                // Hook the native function
                g_projection_matrix_hook2 = std::make_unique<FunctionHook>(native_func, gui_camera_get_projection_matrix_hook);

                if (g_projection_matrix_hook2->create()) {
                    spdlog::info("Hooked via.gui.GUICamera.get_ProjectionMatrix");
                }
            } else {
                spdlog::info("Did not hook via.gui.GUICamera.get_ProjectionMatrix, same as via.Camera.get_ProjectionMatrix");
            }
        }
    }

    return std::nullopt;
}

std::optional<std::string> VR::hijack_wwise_listeners() {
#ifndef RE4
#ifndef SF6
#if TDB_VER < 73
    spdlog::info("[VR] Hijacking WwiseListener");

    const auto t = sdk::find_type_definition("via.wwise.WwiseListener");

    if (t == nullptr) {
        return "VR init failed: via.wwise.WwiseListener type not found.";
    }

    const auto update_method = t->get_method("update");

    if (update_method == nullptr) {
        return "VR init failed: via.wwise.WwiseListener.update method not found.";
    }

    const auto func_wrapper = update_method->get_function();

    if (func_wrapper == nullptr) {
        return "VR init failed: via.wwise.WwiseListener.update native function not found.";
    }
    
    spdlog::info("via.wwise.WwiseListener.update: {:x}", (uintptr_t)func_wrapper);
    
    // Use hde to disassemble the method and find the first jmp, which jmps to the real function
    // in the vtable
    const auto jmp = utility::scan_disasm((uintptr_t)func_wrapper, 10, "48 FF");

    if (!jmp) {
        return "VR init failed: could not find jmp opcode in via.wwise.WwiseListener.update native function.";
    }

    const auto vtable_index = *(uint8_t*)(*jmp + 3) / sizeof(void*);
    spdlog::info("via.wwise.WwiseListener.update vtable index: {}", vtable_index);
    spdlog::info("Attempting to create fake via.wwise.WwiseListener instance");

    const void* fake_obj = t->create_instance_full();

    if (fake_obj == nullptr) {
        return "VR init failed: Failed to create fake via.wwise.WwiseListener instance.";
    }
    
    spdlog::info("Attempting to read vtable from fake via.wwise.WwiseListener instance");
    auto obj_vtable = *(void***)fake_obj;

    if (obj_vtable == nullptr) {
        return "VR init failed: via.wwise.WwiseListener vtable not found.";
    }

    spdlog::info("via.wwise.WwiseListener vtable: {:x}", (uintptr_t)obj_vtable - g_framework->get_module());

    auto update_native = obj_vtable[vtable_index];

    if (update_native == 0) {
        return "VR init failed: via.wwise.WwiseListener update native not found.";
    }

    spdlog::info("via.wwise.WwiseListener.update: {:x}", (uintptr_t)update_native);

    g_wwise_listener_update_hook = std::make_unique<FunctionHook>(update_native, wwise_listener_update_hook);

    if (!g_wwise_listener_update_hook->create()) {
        return "VR init failed: via.wwise.WwiseListener update native function hook failed.";
    }
#endif
#endif
#endif

    return std::nullopt;
}

bool VR::detect_controllers() {
    // already detected
    if (!m_controllers.empty()) {
        return true;
    }

    if (get_runtime()->is_openvr()) {
        auto left_joystick_origin_error = vr::EVRInputError::VRInputError_None;
        auto right_joystick_origin_error = vr::EVRInputError::VRInputError_None;

        vr::InputOriginInfo_t left_joystick_origin_info{};
        vr::InputOriginInfo_t right_joystick_origin_info{};

        // Get input origin info for the joysticks
        // get the source input device handles for the joysticks
        auto left_joystick_error = vr::VRInput()->GetInputSourceHandle("/user/hand/left", &m_left_joystick);

        if (left_joystick_error != vr::VRInputError_None) {
            return false;
        }

        auto right_joystick_error = vr::VRInput()->GetInputSourceHandle("/user/hand/right", &m_right_joystick);

        if (right_joystick_error != vr::VRInputError_None) {
            return false;
        }

        left_joystick_origin_info = {};
        right_joystick_origin_info = {};

        left_joystick_origin_error = vr::VRInput()->GetOriginTrackedDeviceInfo(m_left_joystick, &left_joystick_origin_info, sizeof(left_joystick_origin_info));
        right_joystick_origin_error = vr::VRInput()->GetOriginTrackedDeviceInfo(m_right_joystick, &right_joystick_origin_info, sizeof(right_joystick_origin_info));
        if (left_joystick_origin_error != vr::EVRInputError::VRInputError_None || right_joystick_origin_error != vr::EVRInputError::VRInputError_None) {
            return false;
        }

        // Instead of manually going through the devices,
        // We do this. The order of the devices isn't always guaranteed to be
        // Left, and then right. Using the input state handles will always
        // Get us the correct device indices.
        m_controllers.push_back(left_joystick_origin_info.trackedDeviceIndex);
        m_controllers.push_back(right_joystick_origin_info.trackedDeviceIndex);
        m_controllers_set.insert(left_joystick_origin_info.trackedDeviceIndex);
        m_controllers_set.insert(right_joystick_origin_info.trackedDeviceIndex);

        spdlog::info("Left Hand: {}", left_joystick_origin_info.trackedDeviceIndex);
        spdlog::info("Right Hand: {}", right_joystick_origin_info.trackedDeviceIndex);
    } else if (get_runtime()->is_openxr()) {
        // ezpz
        m_controllers.push_back(1);
        m_controllers.push_back(2);
        m_controllers_set.insert(1);
        m_controllers_set.insert(2);

        spdlog::info("Left Hand: {}", 1);
        spdlog::info("Right Hand: {}", 2);
    }


    return true;
}

bool VR::is_any_action_down() {
    if (!m_runtime->ready() || !is_using_controllers()) {
        return false;
    }

    const auto left_axis = get_left_stick_axis();
    const auto right_axis = get_right_stick_axis();

    if (glm::length(left_axis) >= m_joystick_deadzone->value()) {
        return true;
    }

    if (glm::length(right_axis) >= m_joystick_deadzone->value()) {
        return true;
    }

    for (auto& it : m_action_handles) {
        if (is_action_active(it.second, m_left_joystick) || is_action_active(it.second, m_right_joystick)) {
            return true;
        }
    }

    return false;
}

void VR::update_hmd_state() {
    

    auto runtime = get_runtime();
    
    if (runtime->get_synchronize_stage() == VRRuntime::SynchronizeStage::EARLY) {
        if (runtime->is_openxr()) {
            if (g_framework->get_renderer_type() == REFramework::RendererType::D3D11) {
                if (!runtime->got_first_sync || runtime->synchronize_frame() != VRRuntime::Error::SUCCESS) {
                    return;
                }  
            } else if (runtime->synchronize_frame() != VRRuntime::Error::SUCCESS) {
                return;
            }

            m_openxr->begin_frame();
        } else {
            if (runtime->synchronize_frame() != VRRuntime::Error::SUCCESS) {
                return;
            }
        }
    }
    
    runtime->update_poses();

    // Update the poses used for the game
    // If we used the data directly from the WaitGetPoses call, we would have to lock a different mutex and wait a long time
    // This is because the WaitGetPoses call is blocking, and we don't want to block any game logic
    if (runtime->wants_reset_origin && runtime->ready() && runtime->got_first_valid_poses) {
        std::unique_lock _{ runtime->pose_mtx };
        set_rotation_offset(glm::identity<glm::quat>());
        m_standing_origin = get_position_unsafe(vr::k_unTrackedDeviceIndex_Hmd);

        runtime->wants_reset_origin = false;
    }

    runtime->update_matrices(m_nearz, m_farz);

    runtime->got_first_poses = true;

    // Forcefully update the camera transform after submitting the frame
    // because the game logic thread does not run in sync with the rendering thread
    // This will massively improve HMD rotation smoothness for the user
    // if this is not done, the left eye will jitter a lot
#if defined(RE2) || defined(RE3)
    const auto cameras = get_cameras();

    for (auto camera : cameras) {
        if (camera == nullptr) {
            continue;
        }

        if (camera->ownerGameObject != nullptr && camera->ownerGameObject->transform != nullptr) {
            if (camera == cameras[0]) {
                FirstPerson::get()->on_update_transform(camera->ownerGameObject->transform);
            } else if (cameras[0] != nullptr && cameras[0]->ownerGameObject != nullptr && cameras[0]->ownerGameObject->transform != nullptr) {
                auto transform0 = cameras[0]->ownerGameObject->transform;
                auto transform1 = camera->ownerGameObject->transform;

                const auto camera_joint = utility::re_transform::get_joint(*transform1, 0);

                if (camera_joint == nullptr) {
                    continue;
                }

                auto& fp = FirstPerson::get();

                const auto mat = fp->get_last_camera_matrix();
                const auto pos = mat[3];

                //transform1->angles = transform0->angles;
                //transform1->position = transform0->position;
                transform1->worldTransform = transform0->worldTransform;

                sdk::set_joint_position(camera_joint, pos);
                sdk::set_joint_rotation(camera_joint, mat);
            }
        }
    }
#endif
}

void VR::update_action_states() {
    

    auto runtime = get_runtime();

    if (runtime->wants_reinitialize) {
        return;
    }

    if (runtime->is_openvr()) {
        const auto start_time = std::chrono::high_resolution_clock::now();

        auto error = vr::VRInput()->UpdateActionState(&m_active_action_set, sizeof(m_active_action_set), 1);

        if (error != vr::VRInputError_None) {
            spdlog::error("VRInput failed to update action state: {}", (uint32_t)error);
        }

        const auto end_time = std::chrono::high_resolution_clock::now();
        const auto time_delta = end_time - start_time;

        m_last_input_delay = time_delta;
        m_avg_input_delay = (m_avg_input_delay + time_delta) / 2;

        if ((end_time - start_time) >= std::chrono::milliseconds(30)) {
            spdlog::warn("VRInput update action state took too long: {}ms", std::chrono::duration_cast<std::chrono::milliseconds>(end_time - start_time).count());

            //reinitialize_openvr();
            runtime->wants_reinitialize = true;
        }   
    } else {
        get_runtime()->update_input();
    }

    if (m_recenter_view_key->is_key_down_once()) {
        recenter_view();
    }

    if (m_set_standing_key->is_key_down_once()) {
        set_standing_origin(get_position(0));
    }
}

void VR::update_camera() {
    

    if (!is_hmd_active()) {
        m_needs_camera_restore = false;
        return;
    }

    if (inside_on_end) {
        return;
    }

    auto cameras = get_cameras();

    if (cameras[0] == nullptr) {
        spdlog::error("VR: Failed to get primary camera!");
        return;
    }

    for (auto camera : cameras) {
        if (camera == nullptr) {
            break;
        }

        static auto via_camera = sdk::find_type_definition("via.Camera");
        static auto get_near_clip_plane_method = via_camera->get_method("get_NearClipPlane");
        static auto get_far_clip_plane_method = via_camera->get_method("get_FarClipPlane");
        static auto set_far_clip_plane_method = via_camera->get_method("set_FarClipPlane");
        static auto set_fov_method = via_camera->get_method("set_FOV");
        static auto set_vertical_enable_method = via_camera->get_method("set_VerticalEnable");
        static auto set_aspect_ratio_method = via_camera->get_method("set_AspectRatio");

        if (m_use_custom_view_distance->value()) {
            set_far_clip_plane_method->call<void*>(sdk::get_thread_context(), camera, m_view_distance->value());
        }

        m_nearz = get_near_clip_plane_method->call<float>(sdk::get_thread_context(), camera);
        m_farz = get_far_clip_plane_method->call<float>(sdk::get_thread_context(), camera);

        // Disable certain effects like the 3D overlay during the sewer gators
        // section in RE7
        disable_bad_effects();
        // Disable lens distortion
        set_lens_distortion(false);

    #if defined(RE2) || defined(RE3)
        if (FirstPerson::get()->will_be_used()) {
            m_needs_camera_restore = false;

            auto camera_object = utility::re_component::get_game_object(camera);

            if (camera_object == nullptr || camera_object->transform == nullptr) {
                return;
            }

            auto camera_joint = utility::re_transform::get_joint(*camera_object->transform, 0);

            if (camera_joint == nullptr) {
                return;
            }

            m_original_camera_position = sdk::get_joint_position(camera_joint);
            m_original_camera_rotation = sdk::get_joint_rotation(camera_joint);
            m_original_camera_matrix = Matrix4x4f{m_original_camera_rotation};
            m_original_camera_matrix[3] = m_original_camera_position;

            return;
        }
    #endif

        auto projection_matrix = is_using_afw_foveated() ? get_projection_matrix(0) : get_current_projection_matrix(true);

        // Steps towards getting lens flares and volumetric lighting working
        // Get the FOV from the projection matrix
        const auto vfov = glm::degrees(2.0f * std::atan(1.0f / projection_matrix[1][1]));
        const auto aspect = projection_matrix[1][1] / projection_matrix[0][0];
        const auto hfov = vfov * aspect;
        
        //spdlog::info("vFOV: {}", vfov);
        //spdlog::info("Aspect: {}", aspect);

        set_fov_method->call<void*>(sdk::get_thread_context(), camera, vfov);
        set_vertical_enable_method->call<void*>(sdk::get_thread_context(), camera, true);
        set_aspect_ratio_method->call<void*>(sdk::get_thread_context(), camera, aspect);
    }

    update_camera_origin();
    m_needs_camera_restore = true;
}

void VR::update_camera_origin() {
    

    if (!is_hmd_active()) {
        return;
    }

    // this means that the user just put the headset on or something
    // and we caught them in a bad frame
    if (inside_on_end && !m_needs_camera_restore) {
        return;
    }

    auto cameras = get_cameras();

    if (cameras[0] == nullptr) {
        m_needs_camera_restore = false;
        return;
    }

    for (auto camera : cameras) {
        if (camera == nullptr) {
            return;
        }

        auto camera_object = utility::re_component::get_game_object(camera);

        if (camera_object == nullptr || camera_object->transform == nullptr) {
            spdlog::error("VR: Failed to get camera game object or transform!");
            m_needs_camera_restore = false;
            return;
        }

        auto camera_joint = utility::re_transform::get_joint(*camera_object->transform, 0);

        if (camera_joint == nullptr) {
            spdlog::error("VR: Failed to get camera joint!");
            m_needs_camera_restore = false;
            return;
        }

        if (!inside_on_end && camera == cameras[0]) {
            m_original_camera_position = sdk::get_joint_position(camera_joint);
            m_original_camera_rotation = sdk::get_joint_rotation(camera_joint);
            m_original_camera_matrix = Matrix4x4f{m_original_camera_rotation};
            m_original_camera_matrix[3] = m_original_camera_position;
        }

        apply_hmd_transform(camera_joint);
    }
}

void VR::apply_hmd_transform(glm::quat& rotation, Vector4f& position) {
    

    const auto rotation_offset = get_rotation_offset();
    const auto current_hmd_rotation = glm::normalize(rotation_offset * glm::quat{get_rotation(0)});
    
    glm::quat new_rotation{};
    glm::quat camera_rotation{};
    
    if (!m_decoupled_pitch->value()) {
        camera_rotation = rotation;
        new_rotation = glm::normalize(rotation * current_hmd_rotation);
    } else if (m_decoupled_pitch->value()) {
        // facing forward matrix
        const auto camera_rotation_matrix = utility::math::remove_y_component(Matrix4x4f{rotation});
        camera_rotation = glm::quat{camera_rotation_matrix};
        new_rotation = glm::normalize(camera_rotation * current_hmd_rotation);
    }

    auto current_relative_pos = rotation_offset * (get_position(0) - m_standing_origin) /*+ current_relative_eye_pos*/;
    current_relative_pos.w = 0.0f;

    auto current_head_pos = camera_rotation * current_relative_pos;

    rotation = new_rotation;
    position = position + current_head_pos;
}

void VR::apply_hmd_transform(::REJoint* camera_joint) {
    

    auto rotation = m_original_camera_rotation;
    auto position = m_original_camera_position;

    apply_hmd_transform(rotation, position);

    sdk::set_joint_rotation(camera_joint, rotation);

    if (m_positional_tracking) {
        sdk::set_joint_position(camera_joint, position);   
    }
}

bool VR::is_hand_behind_head(VRRuntime::Hand hand, float sensitivity) const {
    if (hand > VRRuntime::Hand::RIGHT || !is_using_controllers()) {
        return false;
    }

    const auto hand_index = get_controllers()[(uint32_t)hand];

    const auto hmd = get_transform(0);
    const auto hand_pos = get_position(hand_index);
    const auto hmd_delta = Vector3f{hand_pos - hmd[3]};
    const auto distance = glm::length(hmd_delta);

    if (distance >= 0.3f) {
        return false;
    }

    const auto hmd_dir = glm::normalize(hmd_delta);

    const auto& hmd_forward = hmd[2];
    const auto flattened_forward = glm::normalize(Vector3f{hmd_forward.x, 0.0f, hmd_forward.z});

    const auto hand_dot_flat_raw = glm::dot(flattened_forward, hmd_dir);
    return hand_dot_flat_raw >= sensitivity;
}

void VR::update_audio_camera() {
    

    if (!is_hmd_active()) {
        return;
    }

    auto camera = sdk::get_primary_camera();

    if (camera == nullptr) {
        return;
    }

    auto camera_object = utility::re_component::get_game_object(camera);

    if (camera_object == nullptr || camera_object->transform == nullptr) {
        return;
    }

    auto camera_joint = utility::re_transform::get_joint(*camera_object->transform, 0);

    if (camera_joint == nullptr) {
        return;
    }

    m_original_audio_camera_position = sdk::get_joint_position(camera_joint);
    m_original_audio_camera_rotation = sdk::get_joint_rotation(camera_joint);
    m_needs_audio_restore = true;

    auto rotation = m_original_audio_camera_rotation;
    auto position = m_original_audio_camera_position;

    apply_hmd_transform(rotation, position);

    sdk::set_joint_rotation(camera_joint, rotation);

    if (m_positional_tracking) {
        sdk::set_joint_position(camera_joint, position);   
    }
}

void VR::update_render_matrix() {
    

    auto cameras = get_cameras();

    if (cameras[0] == nullptr) {
        return;
    }

    for (auto camera : cameras) {
        if (camera == nullptr || camera != cameras[0]) {
            return;
        }

        auto camera_object = utility::re_component::get_game_object(camera);

        if (camera_object == nullptr || camera_object->transform == nullptr) {
            return;
        }

        auto camera_joint = utility::re_transform::get_joint(*camera_object->transform, 0);

        if (camera_joint == nullptr) {
            return;
        }

        m_render_camera_matrix = Matrix4x4f{sdk::get_joint_rotation(camera_joint)};
        m_render_camera_matrix[3] = sdk::get_joint_position(camera_joint);
    }
}

void VR::restore_audio_camera() {
    if (!m_needs_audio_restore) {
        return;
    }

#if defined(RE2) || defined(RE3)
    if (FirstPerson::get()->will_be_used()) {
        m_needs_audio_restore = false;
        return;
    }
#endif

    auto camera = sdk::get_primary_camera();

    if (camera == nullptr) {
        m_needs_audio_restore = false;
        return;
    }

    auto camera_object = utility::re_component::get_game_object(camera);

    if (camera_object == nullptr || camera_object->transform == nullptr) {
        m_needs_audio_restore = false;
        return;
    }

    //camera_object->transform->worldTransform = m_original_camera_matrix;

    auto joint = utility::re_transform::get_joint(*camera_object->transform, 0);

    if (joint == nullptr) {
        m_needs_audio_restore = false;
        return;
    }

    sdk::set_joint_rotation(joint, m_original_audio_camera_rotation);
    sdk::set_joint_position(joint, m_original_audio_camera_position);

    m_needs_audio_restore = false;
}

void VR::restore_camera() {
    

    if (!m_needs_camera_restore) {
        return;
    }

#if defined(RE2) || defined(RE3)
    if (FirstPerson::get()->will_be_used()) {
        m_needs_camera_restore = false;
        return;
    }
#endif

    auto cameras = get_cameras();

    if (cameras[0] == nullptr) {
        m_needs_camera_restore = false;
        return;
    }

    for (auto camera : cameras) {
        if (camera == nullptr) {
            return;
        }

        auto camera_object = utility::re_component::get_game_object(camera);

        if (camera_object == nullptr || camera_object->transform == nullptr) {
            m_needs_camera_restore = false;
            return;
        }

        //camera_object->transform->worldTransform = m_original_camera_matrix;

        auto joint = utility::re_transform::get_joint(*camera_object->transform, 0);

        if (joint == nullptr) {
            m_needs_camera_restore = false;
            return;
        }

        sdk::set_joint_rotation(joint, m_original_camera_rotation);
        sdk::set_joint_position(joint, m_original_camera_position);
    }


    m_needs_camera_restore = false;
}

void VR::set_lens_distortion(bool value) {
    

    if (!m_force_lensdistortion_settings->value()) {
        return;
    }

#ifdef RE7
    auto camera = sdk::get_primary_camera();

    if (camera == nullptr) {
        return;
    }

    static auto lens_distortion_tdef = sdk::find_type_definition(game_namespace("LensDistortionController"));
    static auto lens_distortion_t = lens_distortion_tdef->get_type();

    auto lens_distortion_component = utility::re_component::find(camera, lens_distortion_t);

    if (lens_distortion_component != nullptr) {
        // Get "LensDistortion" field
        auto lens_distortion = *sdk::get_object_field<REManagedObject*>(lens_distortion_component, "LensDistortion");

        if (lens_distortion != nullptr) {
            // Call "set_Enabled" method
            sdk::call_object_func<void*>(lens_distortion, "set_Enabled", sdk::get_thread_context(), lens_distortion, value);
        }
    }
#endif
}

void VR::disable_bad_effects() {
    

    auto context = sdk::get_thread_context();

    auto application = sdk::Application::get();

    // minor optimizations to prevent hashing and map lookups every frame
    static auto renderer_t = sdk::find_type_definition("via.render.Renderer");

    static auto get_render_config_method = renderer_t->get_method("get_RenderConfig");

    static auto render_config_t = sdk::find_type_definition("via.render.RenderConfig");

    static auto get_framerate_setting_method = render_config_t->get_method("get_FramerateSetting");
    static auto set_framerate_setting_method = render_config_t->get_method("set_FramerateSetting");

    static auto get_antialiasing_method = render_config_t->get_method("get_AntiAliasing");
    static auto set_antialiasing_method = render_config_t->get_method("set_AntiAliasing");

    static auto get_lens_distortion_setting_method = render_config_t->get_method("getLensDistortionSetting");
    static auto set_lens_distortion_setting_method = render_config_t->get_method("setLensDistortionSetting");

    static auto get_motion_blur_enable_method = render_config_t->get_method("get_MotionBlurEnable");
    static auto set_motion_blur_enable_method = render_config_t->get_method("set_MotionBlurEnable");

    static auto get_vsync_method = render_config_t->get_method("get_VSync");
    static auto set_vsync_method = render_config_t->get_method("set_VSync");

    static auto get_transparent_buffer_quality_method = render_config_t->get_method("get_TransparentBufferQuality");
    static auto set_transparent_buffer_quality_method = render_config_t->get_method("set_TransparentBufferQuality");

    static auto get_lensflare_enable_method = render_config_t->get_method("get_LensFlareEnable");
    static auto set_lensflare_enable_method = render_config_t->get_method("set_LensFlareEnable");

    static auto get_colorspace_method = render_config_t->get_method("get_ColorSpace");
    static auto set_colorspace_method = render_config_t->get_method("set_ColorSpace");

    static auto get_dynamic_shadow_enable_method = render_config_t->get_method("get_DynamicShadowEnable");
    static auto set_dynamic_shadow_enable_method = render_config_t->get_method("set_DynamicShadowEnable");

    static auto get_hdrmode_method = renderer_t->get_method("get_HDRMode");
    static auto set_hdrmode_method = renderer_t->get_method("set_HDRMode");

    static auto get_hdr_display_mode_enable_method = renderer_t->get_method("get_HDRDisplayModeEnable");
    static auto set_hdr_display_mode_enable_method = renderer_t->get_method("set_HDRDisplayModeEnable");

    static auto get_delay_render_enable_method = renderer_t->get_method("get_DelayRenderEnable");
    static auto set_delay_render_enable_method = renderer_t->get_method("set_DelayRenderEnable");

    auto renderer = renderer_t->get_instance();

    auto render_config = get_render_config_method->call<::REManagedObject*>(context, renderer);

    if (render_config == nullptr) {
        spdlog::info("No render config!");
        return;
    }

    static const auto is_sf6 = utility::get_module_path(utility::get_executable())->find("StreetFighter") != std::string::npos;

    if (!is_sf6 && m_force_fps_settings->value() && get_framerate_setting_method != nullptr && set_framerate_setting_method != nullptr) {
        const auto framerate_setting = get_framerate_setting_method->call<via::render::RenderConfig::FramerateType>(context, render_config);

        // Allow FPS to go above 60
        if (framerate_setting != via::render::RenderConfig::FramerateType::VARIABLE) {
            set_framerate_setting_method->call<void*>(context, render_config, via::render::RenderConfig::FramerateType::VARIABLE);
            spdlog::info("[VR] Set framerate to variable");
        }
    }
    
    // get_MaxFps on application
    if (!is_sf6 && m_force_fps_settings->value() && application->get_max_fps() <  600.0f) {
        application->set_max_fps(600.0f);

        static bool once = []() {
            spdlog::info("[VR] Max FPS set to {}", 600.0f);
            return true;
        }();
    }

    if (m_force_aa_settings->value() && get_antialiasing_method != nullptr && set_antialiasing_method != nullptr) {
        const auto antialiasing = get_antialiasing_method->call<via::render::RenderConfig::AntiAliasingType>(context, render_config);

        // Disable TAA
        switch (antialiasing) {
            case via::render::RenderConfig::AntiAliasingType::TAA: [[fallthrough]];
            case via::render::RenderConfig::AntiAliasingType::FXAA_TAA:
                set_antialiasing_method->call<void*>(context, render_config, via::render::RenderConfig::AntiAliasingType::NONE);
                spdlog::info("[VR] TAA disabled");
                break;
            default:
                break;
        }
    }

    if (m_force_lensdistortion_settings->value() && get_lens_distortion_setting_method != nullptr && set_lens_distortion_setting_method != nullptr) {
        const auto lens_distortion_setting = get_lens_distortion_setting_method->call<via::render::RenderConfig::LensDistortionSetting>(context, render_config);

        // Disable lens distortion
        if (lens_distortion_setting != via::render::RenderConfig::LensDistortionSetting::OFF) {
            set_lens_distortion_setting_method->call<void*>(context, render_config, via::render::RenderConfig::LensDistortionSetting::OFF);
            spdlog::info("[VR] Lens distortion disabled");
        }
    }

    if (m_force_motionblur_settings->value() && get_motion_blur_enable_method != nullptr && set_motion_blur_enable_method != nullptr) {
        const auto is_motion_blur_enabled = get_motion_blur_enable_method->call<bool>(context, render_config);

        // Disable motion blur
        if (is_motion_blur_enabled) {
            set_motion_blur_enable_method->call<void*>(context, render_config, false);
            spdlog::info("[VR] Motion blur disabled");
        }
    }

    if (m_force_vsync_settings->value() && get_vsync_method != nullptr && set_vsync_method != nullptr) {
#ifndef MHRISE
        const auto vsync = get_vsync_method->call<bool>(context, render_config);

        // Disable vsync
        if (vsync) {
            set_vsync_method->call<void*>(context, render_config, false);
            spdlog::info("[VR] VSync disabled");
        }
#else
        // We are only calling set_vsync instead of checking with get_vsync in MHRise
        // because get_VSync has some insane code protection on it for some reason
        // which would increase frametimes to 15+
        set_vsync_method->call<void*>(context, render_config, false);
#endif
    }

    if (m_force_volumetrics_settings->value() && get_transparent_buffer_quality_method != nullptr && set_transparent_buffer_quality_method != nullptr) {
        const auto transparent_buffer_quality = get_transparent_buffer_quality_method->call<via::render::RenderConfig::Quality>(context, render_config);

        // Disable volumetrics
        if (transparent_buffer_quality != via::render::RenderConfig::Quality::NONE) {
            set_transparent_buffer_quality_method->call<void*>(context, render_config, via::render::RenderConfig::Quality::NONE);
            spdlog::info("[VR] Volumetrics disabled");
        }
    }

    if (m_force_lensflares_settings->value() && get_lensflare_enable_method != nullptr && set_lensflare_enable_method != nullptr) {
        const auto is_lensflare_enabled = get_lensflare_enable_method->call<bool>(context, render_config);

        // Disable lensflares
        if (is_lensflare_enabled) {
            set_lensflare_enable_method->call<void*>(context, render_config, false);
            spdlog::info("[VR] Lensflares disabled");
        }
    }

    if (get_hdrmode_method != nullptr && set_hdrmode_method != nullptr) {
        // static
        const auto is_hdr_enabled = get_hdrmode_method->call<bool>(context);

        // Disable HDR
        if (is_hdr_enabled) {
            set_hdrmode_method->call<void*>(context, false);
            
            if (set_hdr_display_mode_enable_method != nullptr) {
                set_hdr_display_mode_enable_method->call<void*>(context, false);
            }

            spdlog::info("[VR] HDR disabled");
        }
    }

    if (get_colorspace_method != nullptr && set_colorspace_method != nullptr) {
        const auto is_hdr_enabled = get_colorspace_method->call<via::render::ColorSpace>(context, render_config) == via::render::ColorSpace::HDR10;

        if (is_hdr_enabled) {
            set_colorspace_method->call<void*>(context, render_config, via::render::ColorSpace::HDTV);
            spdlog::info("[VR] HDR disabled (ColorSpace)");
        }
    }

    if (m_force_dynamic_shadows_settings->value() && get_dynamic_shadow_enable_method != nullptr && set_dynamic_shadow_enable_method != nullptr) {
        const auto is_dynamic_shadow_enabled = get_dynamic_shadow_enable_method->call<bool>(context, render_config);

        // Enable dynamic shadows
        if (!is_dynamic_shadow_enabled) {
            set_dynamic_shadow_enable_method->call<void*>(context, render_config, true);
            spdlog::info("[VR] Dynamic shadows enabled");
        }
    }

    // Causes crashes on D3D11. May be a performance detriment in VR with new rendering method.
    const auto is_new_rendering_method = is_using_afw_foveated();

    if (!is_new_rendering_method && !is_sf6 && g_framework->get_renderer_type() == REFramework::RendererType::D3D12 && m_enable_asynchronous_rendering->value()) {
        if (get_delay_render_enable_method != nullptr && set_delay_render_enable_method != nullptr) {
            const auto is_delay_render_enabled = get_delay_render_enable_method->call<bool>(context);

            if (is_delay_render_enabled == true) {
                set_delay_render_enable_method->call<void*>(context, !m_enable_asynchronous_rendering->value());
                spdlog::info("[VR] Delay render modified");
            }
        }
    } else if (is_sf6) {
        // Must be on in SF6 or left eye gets stuck
        if (set_delay_render_enable_method != nullptr) {
            set_delay_render_enable_method->call<void*>(context, true);
        }
    }

#ifdef RE7
    auto camera = sdk::get_primary_camera();

    if (camera == nullptr) {
        return;
    }

    auto camera_game_object = utility::re_component::get_game_object(camera);

    if (camera_game_object == nullptr) {
        return;
    }
    
    auto camera_transform = camera_game_object->transform;

    if (camera_transform == nullptr) {
        return;
    }

    auto get_type = [](std::string name) {
        auto tdef = sdk::find_type_definition(name);
        return tdef->get_type();
    };

    static auto effect_player_t = get_type("via.effect.EffectPlayer");
    static auto hide_effect_for_vr_t = get_type(game_namespace("EPVStandard.HideEffectForVR"));

    // Do not draw the game object if it is hidden for VR (this was there for the original PSVR release i guess)
    for (auto child = camera_transform->child; child != nullptr; child = child->child) {
        if (utility::re_component::find(child, effect_player_t) != nullptr) {
            if (utility::re_component::find(child, hide_effect_for_vr_t) != nullptr) {
                auto game_object = child->ownerGameObject;

                game_object->shouldDraw = false;
                //sdk::call_object_func<void*>(game_object, "set_Draw", sdk::get_thread_context(), game_object, false);
            }
        }
    }
#endif
}

void VR::fix_temporal_effects() {
    // this is SO DUMB!!!!!
    const auto camera = sdk::get_primary_camera();

    if (camera == nullptr) {
        return;
    }
    
    static auto render_output_type = sdk::find_type_definition("via.render.RenderOutput")->get_type();
    auto render_output_component = utility::re_component::find(camera, render_output_type);

    if (render_output_component == nullptr) {
        return;
    }

    if (!get_runtime()->ready() || m_disable_temporal_fix) {
        sdk::call_object_func_easy<void*>(render_output_component, "set_DistortionType", 0); // None
        return;
    }

    if (m_frame_count % 2 == m_left_eye_interval) {
        sdk::call_object_func_easy<void*>(render_output_component, "set_DistortionType", 1); // left
    } else {
        sdk::call_object_func_easy<void*>(render_output_component, "set_DistortionType", 2); // right
    }
}

int32_t VR::get_frame_count() const {
    return get_game_frame_count();
}

int32_t VR::get_game_frame_count() const {
    static auto renderer_type = sdk::find_type_definition("via.render.Renderer");

    if (renderer_type == nullptr) {
        renderer_type = sdk::find_type_definition("via.render.Renderer");
        spdlog::warn("VR: Failed to find renderer type, trying again next time");
        return 0;
    }

    auto renderer = renderer_type->get_instance();

    if (renderer == nullptr) {
        return 0;
    }

    static auto get_render_frame_method = renderer_type->get_method("get_RenderFrame");

    return get_render_frame_method->call<int32_t>(sdk::get_thread_context(), renderer);
}

float VR::get_standing_height() {
    std::shared_lock _{ get_runtime()->pose_mtx };

    return m_standing_origin.y;
}

Vector4f VR::get_standing_origin() {
    std::shared_lock _{ get_runtime()->pose_mtx };

    return m_standing_origin;
}

void VR::set_standing_origin(const Vector4f& origin) {
    std::unique_lock _{ get_runtime()->pose_mtx };
    
    m_standing_origin = origin;
}

glm::quat VR::get_rotation_offset() {
    std::shared_lock _{ m_rotation_mtx };

    return m_rotation_offset;
}

void VR::set_rotation_offset(const glm::quat& offset) {
    std::unique_lock _{ m_rotation_mtx };

    m_rotation_offset = offset;
}

void VR::recenter_view() {
    const auto new_rotation_offset = glm::normalize(glm::inverse(utility::math::flatten(glm::quat{get_rotation(0)})));

    set_rotation_offset(new_rotation_offset);
}

glm::quat VR::get_gui_rotation_offset() {
    std::shared_lock _{ m_gui_mtx };

    return m_gui_rotation_offset;
}

void VR::set_gui_rotation_offset(const glm::quat& offset) {
    std::unique_lock _{ m_gui_mtx };

    m_gui_rotation_offset = offset;
}

void VR::recenter_gui(const glm::quat& from) {
    const auto new_gui_offset = glm::normalize(glm::inverse(utility::math::flatten(from)));
    set_gui_rotation_offset(new_gui_offset);
}

Vector4f VR::get_current_offset() {
    if (!is_hmd_active()) {
        return Vector4f{};
    }

    std::shared_lock _{ get_runtime()->eyes_mtx };

    const auto count = m_frame_count;

    if (count % 2 == m_left_eye_interval) {
        //return Vector4f{m_eye_distance * -1.0f, 0.0f, 0.0f, 0.0f};
        return get_runtime()->eyes[vr::Eye_Left][3];
    }
    
    return get_runtime()->eyes[vr::Eye_Right][3];
    //return Vector4f{m_eye_distance, 0.0f, 0.0f, 0.0f};
}

Matrix4x4f VR::get_current_eye_transform(bool flip) {
    if (!is_hmd_active()) {
        return glm::identity<Matrix4x4f>();
    }

    std::shared_lock _{get_runtime()->eyes_mtx};

    const auto count = m_frame_count;
    const auto mod_count = flip ? m_right_eye_interval : m_left_eye_interval;

    if (count % 2 == mod_count) {
        return get_runtime()->eyes[vr::Eye_Left];
    }

    return get_runtime()->eyes[vr::Eye_Right];
}

Matrix4x4f VR::get_current_projection_matrix(bool flip) {
    if (!is_hmd_active()) {
        return glm::identity<Matrix4x4f>();
    }

    std::shared_lock _{get_runtime()->eyes_mtx};

    const auto count = m_frame_count;
    const auto mod_count = flip ? m_right_eye_interval : m_left_eye_interval;

    if (count % 2 == mod_count) {
        return get_runtime()->projections[(uint32_t)VRRuntime::Eye::LEFT];
    }

    return get_runtime()->projections[(uint32_t)VRRuntime::Eye::RIGHT];
}

Matrix4x4f VR::get_projection_matrix(uint32_t pass) {
    if (!is_hmd_active()) {
        return glm::identity<Matrix4x4f>();
    }

    std::shared_lock _{get_runtime()->eyes_mtx};

    if (pass % 2 == 0) {
        return get_runtime()->projections[(uint32_t)VRRuntime::Eye::LEFT];
    }

    return get_runtime()->projections[(uint32_t)VRRuntime::Eye::RIGHT];
}

Matrix4x4f VR::get_eye_transform(uint32_t pass) {
    if (!is_hmd_active()) {
        return glm::identity<Matrix4x4f>();
    }

    std::shared_lock _{get_runtime()->eyes_mtx};

    if (pass % 2 == 0) {
        return get_runtime()->eyes[vr::Eye_Left];
    }

    return get_runtime()->eyes[vr::Eye_Right];
}

void VR::on_pre_imgui_frame() {
    

    if (!get_runtime()->ready()) {
        return;
    }

    m_overlay_component.on_pre_imgui_frame();
}

glm::mat4 to_reverseZ(const glm::mat4& proj) {

	glm::mat4 transformMat = glm::mat4(
		1, 0, 0, 0,
		0, 1, 0, 0,
		0, 0, -1,0,
		0, 0, 1, 1
	);

    return transformMat * proj;
}

void VR::get_camera_data() {
}

void VR::update_camera_data(int frame_count) {

    if (last_update_camera_data_frame_count < frame_count) {
        last_update_camera_data_frame_count = frame_count;

        EyeIndex nEye = (m_render_frame_count % 2 == m_left_eye_interval) ? EyeLeft : EyeRight;
        EyeIndex nEyeOther = (m_render_frame_count % 2 == m_left_eye_interval) ? EyeRight : EyeLeft;

        glm::mat4 matEyePosRender = get_current_eye_transform(false);
        glm::mat4 matEyePosProj = get_current_eye_transform(true);

        cameraData[nEye].camWorldToViewMatrix = glm::inverse(m_original_camera_matrix);
        cameraData[nEye].camViewToWorldMatrix = m_original_camera_matrix;
        cameraData[nEye].destViewToWorldMatrix = m_render_camera_matrix * matEyePosProj;
        cameraData[nEye].srcViewToWorldMatrix = m_render_camera_matrix * matEyePosRender;
        cameraData[nEye].destWorldToViewMatrix = glm::inverse(cameraData[nEye].destViewToWorldMatrix);
        cameraData[nEye].srcWorldToViewMatrix = glm::inverse(cameraData[nEye].srcViewToWorldMatrix);

        cameraData[nEye].destViewToClipMatrix = to_reverseZ(get_current_projection_matrix(true));
        cameraData[nEye].destClipToViewMatrix = glm::inverse(cameraData[nEye].destViewToClipMatrix);
        cameraData[nEye].srcViewToClipMatrix = to_reverseZ(get_current_projection_matrix(false));
        cameraData[nEye].srcClipToViewMatrix = glm::inverse(cameraData[nEye].srcViewToClipMatrix);
        cameraData[nEye].camViewToClipMatrix = cameraData[nEye].srcViewToClipMatrix;
        cameraData[nEye].camClipToViewMatrix = cameraData[nEye].srcClipToViewMatrix;

        // dest -> current eye previous frame (reprojected)
        // src -> current eye current frame (rendered)
        // srcPrev -> other eye previous farme (rendered)

        cameraDataForMV[nEye].destViewToWorldMatrix = cameraData[nEyeOther].destViewToWorldMatrix;
        cameraDataForMV[nEye].destWorldToViewMatrix = cameraData[nEyeOther].destWorldToViewMatrix;
        cameraDataForMV[nEye].destViewToClipMatrix = cameraData[nEyeOther].destViewToClipMatrix;
        cameraDataForMV[nEye].destClipToViewMatrix = cameraData[nEyeOther].destClipToViewMatrix;

        cameraDataForMV[nEye].srcViewToWorldMatrix = cameraData[nEye].srcViewToWorldMatrix;
        cameraDataForMV[nEye].srcWorldToViewMatrix = cameraData[nEye].srcWorldToViewMatrix;
        cameraDataForMV[nEye].srcViewToClipMatrix = cameraData[nEye].srcViewToClipMatrix;
        cameraDataForMV[nEye].srcClipToViewMatrix = cameraData[nEye].srcClipToViewMatrix;

        cameraDataForMV[nEye].srcViewToWorldMatrixPrev = cameraData[nEyeOther].srcViewToWorldMatrix;
        cameraDataForMV[nEye].srcWorldToViewMatrixPrev = cameraData[nEyeOther].srcWorldToViewMatrix;
        cameraDataForMV[nEye].srcViewToClipMatrixPrev = cameraData[nEyeOther].srcViewToClipMatrix;
        cameraDataForMV[nEye].srcClipToViewMatrixPrev = cameraData[nEyeOther].srcClipToViewMatrix;
    }
}

void VR::on_present() {
    

    static bool btn1 = false;
    if (GetAsyncKeyState(VK_NUMPAD1) < 0 && btn1 == false) {
        btn1 = true;
    }
    if (GetAsyncKeyState(VK_NUMPAD1) == 0 && btn1 == true) {
        btn1 = false;
        mDebug1 = !mDebug1;
    }
    static bool btn2 = false;
    if (GetAsyncKeyState(VK_NUMPAD2) < 0 && btn2 == false) {
        btn2 = true;
    }
    if (GetAsyncKeyState(VK_NUMPAD2) == 0 && btn2 == true) {
        btn2 = false;
        mDebug2 = !mDebug2;
    }
    static bool btn3 = false;
    if (GetAsyncKeyState(VK_NUMPAD3) < 0 && btn3 == false) {
        btn3 = true;
    }
    if (GetAsyncKeyState(VK_NUMPAD3) == 0 && btn3 == true) {
        btn3 = false;
        mDebug3 = !mDebug3;
    }
    static bool btn4 = false;
    if (GetAsyncKeyState(VK_NUMPAD4) < 0 && btn4 == false) {
        btn4 = true;
    }
    if (GetAsyncKeyState(VK_NUMPAD4) == 0 && btn4 == true) {
        btn4 = false;
        m_fix_upscalers_wobbling->toggle();
    }

    // case 1: sequential frames and rendered frame == right eye (every two frames)
    // case 2: AFW and no foveated rendering (each frame)
    // case 3: AFW and foveated rendering and rendered frame is FR frame
    if ((is_using_sf() && m_render_frame_count % 2 == m_right_eye_interval) || 
        (is_using_afw()) ||
        (is_using_afw_foveated())) {
        ResetEvent(m_present_finished_event);
    }

    auto runtime = get_runtime();

    if (!get_runtime()->loaded) {
        return;
    }

    auto openvr = get_runtime<runtimes::OpenVR>();

    if (runtime->is_openvr()) {
        if (openvr->got_first_poses) {
            const auto hmd_activity = openvr->hmd->GetTrackedDeviceActivityLevel(vr::k_unTrackedDeviceIndex_Hmd);
            auto hmd_active = hmd_activity == vr::k_EDeviceActivityLevel_UserInteraction || hmd_activity == vr::k_EDeviceActivityLevel_UserInteraction_Timeout;

            if (hmd_active) {
                openvr->last_hmd_active_time = std::chrono::system_clock::now();
            }

            const auto now = std::chrono::system_clock::now();

            if (now - openvr->last_hmd_active_time <= std::chrono::seconds(5)) {
                hmd_active = true;
            }

            openvr->is_hmd_active = hmd_active;
            openvr->is_hmd_active = true;

            // upon headset re-entry, reinitialize OpenVR
            if (openvr->is_hmd_active && !openvr->was_hmd_active) {
                openvr->wants_reinitialize = true;
            }

            openvr->was_hmd_active = openvr->is_hmd_active;

            if (!is_hmd_active()) {
                return;
            }
        } else {
            openvr->is_hmd_active = true; // We need to force out an initial WaitGetPoses call
            openvr->was_hmd_active = true;
        }
    }

    // attempt to fix crash when reinitializing openvr
    std::scoped_lock _{m_openvr_mtx};
    m_submitted = false;
    static bool btn5 = false;
    if (GetAsyncKeyState(VK_NUMPAD5) < 0 && btn5 == false) {
        btn5 = true;
    }
    if (GetAsyncKeyState(VK_NUMPAD5) == 0 && btn5 == true) {
        btn5 = false;
        m_enable_foveated_rendering->toggle();
    }
    static bool btn6 = false;
    if (GetAsyncKeyState(VK_NUMPAD6) < 0 && btn6 == false) {
        btn6 = true;
    }
    if (GetAsyncKeyState(VK_NUMPAD6) == 0 && btn6 == true) {
        btn6 = false;
        m_framewarp_debug->toggle();
    }
    static bool btn7 = false;
    if (GetAsyncKeyState(VK_NUMPAD7) < 0 && btn7 == false) {
        btn7 = true;
    }
    if (GetAsyncKeyState(VK_NUMPAD7) == 0 && btn7 == true) {
        btn7 = false;
        //m_use_afr->toggle();
        int32_t& value = m_rendering_technique->value();
        value = (value + 1) % 2;
    }
    static bool btn8 = false;
    if (GetAsyncKeyState(VK_NUMPAD8) < 0 && btn8 == false) {
        btn8 = true;
    }
    if (GetAsyncKeyState(VK_NUMPAD8) == 0 && btn8 == true) {
        btn8 = false;
    }
    static bool btn9 = false;
    if (GetAsyncKeyState(VK_NUMPAD9) < 0 && btn9 == false) {
        btn9 = true;
    }
    if (GetAsyncKeyState(VK_NUMPAD9) == 0 && btn9 == true) {
        btn9 = false;
        m_enable_ui_fix->toggle();
    }
    static bool btnAdd = false;
    if (GetAsyncKeyState(VK_ADD) < 0 && btnAdd == false) {
        btnAdd = true;
    }
    if (GetAsyncKeyState(VK_ADD) == 0 && btnAdd == true) {
        btnAdd = false;
        auto& sharpness = m_sharpness->value();
        sharpness += 0.05f;
    }
    static bool btnSub = false;
    if (GetAsyncKeyState(VK_SUBTRACT) < 0 && btnSub == false) {
        btnSub = true;
    }
    if (GetAsyncKeyState(VK_SUBTRACT) == 0 && btnSub == true) {
        btnSub = false;
        auto& sharpness = m_sharpness->value();
        sharpness -= 0.05f;
    }
    static bool btnMul = false;
    if (GetAsyncKeyState(VK_MULTIPLY) < 0 && btnMul == false) {
        btnMul = true;
    }
    if (GetAsyncKeyState(VK_MULTIPLY) == 0 && btnMul == true) {
        btnMul = false;
        m_enable_sharpening->toggle();
    }

    // only update camera data when not rendering FR frame (which has lower FOV)
    update_camera_data(m_render_frame_count);

    const auto renderer = g_framework->get_renderer_type();
    vr::EVRCompositorError e = vr::EVRCompositorError::VRCompositorError_None;

    if (renderer == REFramework::RendererType::D3D11) {
        // if we don't do this then D3D11 OpenXR freezes for some reason.
        if (!runtime->got_first_sync) {
            runtime->synchronize_frame();
            runtime->update_poses();
        }

        m_is_d3d12 = false;
        e = m_d3d11.on_frame(this);
    } else if (renderer == REFramework::RendererType::D3D12) {
        m_is_d3d12 = true;
        e = m_d3d12.on_frame(this);
    }

    // force a waitgetposes call to fix this...
    if (e == vr::EVRCompositorError::VRCompositorError_AlreadySubmitted && runtime->is_openvr()) {
        openvr->got_first_poses = false;
        openvr->needs_pose_update = true;
    }

    m_last_frame_count = m_render_frame_count;

    if (m_submitted || runtime->needs_pose_update) {
        if (m_submitted) {
            m_overlay_component.on_post_compositor_submit();

            if (runtime->is_openvr()) {
                //vr::VRCompositor()->SetExplicitTimingMode(vr::VRCompositorTimingMode_Explicit_ApplicationPerformsPostPresentHandoff);
                vr::VRCompositor()->PostPresentHandoff();
            }
        }

        runtime->needs_pose_update = true;
        m_submitted = false;
    }

    // case 1: sequential frames and rendered frame == right eye (every two frames)
    // case 2: AFW and no foveated rendering (each frame)
    // case 3: AFW and foveated rendering and rendered frame is FR frame
    if ((is_using_sf() && m_render_frame_count % 2 == m_right_eye_interval) || 
        (is_using_afw()) ||
        (is_using_afw_foveated())) {
        SetEvent(m_present_finished_event);
    }
}

void VR::on_post_present() {
    

    auto runtime = get_runtime();

    if (!runtime->loaded) {
        return;
    }

    const auto renderer = g_framework->get_renderer_type();

    if (renderer == REFramework::RendererType::D3D12) {
        m_d3d12.on_post_present(this);
    }
    
    // case 1: sequential frames and rendered frame == right eye (every two frames)
    // case 2: AFW and no foveated rendering (each frame)
    // case 3: AFW and foveated rendering and rendered frame is FR frame
    if ((is_using_sf() && m_render_frame_count % 2 == m_right_eye_interval) || 
        (is_using_afw()) ||
        (is_using_afw_foveated())) {
        runtime->consume_events(nullptr);
    }

    if (!inside_on_end && runtime->wants_reinitialize) {
        std::scoped_lock _{m_openvr_mtx};

        if (runtime->is_openvr()) {
            m_openvr->wants_reinitialize = false;
            reinitialize_openvr();
        } else if (runtime->is_openxr()) {
            m_openxr->wants_reinitialize = false;
            reinitialize_openxr();
        }
    }
}

void VR::on_update_transform(RETransform* transform) {
    
}

void VR::on_update_camera_controller(RopewayPlayerCameraController* controller) {
    // get headset rotation
    /*const auto& headset_pose = m_game_poses[0];

    if (!headset_pose.bPoseIsValid) {
        return;
    }

    auto headset_matrix = Matrix4x4f{ *(Matrix3x4f*)&headset_pose.mDeviceToAbsoluteTracking };
    auto headset_rotation = glm::extractMatrixRotation(glm::rowMajor4(headset_matrix));

    headset_rotation *= get_current_rotation_offset();

    *(glm::quat*)&controller->worldRotation = glm::quat{ headset_rotation  };

    controller->worldPosition += get_current_offset();*/
}

struct GUIRestoreData {
    REComponent* element{nullptr};
    REComponent* view{nullptr};
    Vector4f original_position{ 0.0f, 0.0f, 0.0f, 1.0f };
    via::gui::ViewType view_type{ via::gui::ViewType::Screen };
    bool overlay{false};
    bool detonemap{true};
};

thread_local std::vector<std::unique_ptr<GUIRestoreData>> g_elements_to_reset{};

bool VR::on_pre_gui_draw_element(REComponent* gui_element, void* primitive_context) {
    

    inside_gui_draw = true;

    if (!get_runtime()->ready()) {
        return true;
    }

    auto game_object = utility::re_component::get_game_object(gui_element);

    if (game_object != nullptr && game_object->transform != nullptr) {
        auto context = sdk::get_thread_context();

        const auto name = utility::re_game_object::get_name(game_object);
        const auto name_hash = utility::hash(name);

        switch (name_hash) {
        // Don't mess with this, causes weird black boxes on the sides of the screen
        case "GUI_PillarBox"_fnv:
        case "GUIEventPillar"_fnv:
        // These allow the cutscene transitions to display (fade to black)
        case "BlackFade"_fnv:
        case "WhiteFade"_fnv:
        case "Fade_In_Out_Black"_fnv:
        case "Fade_In_Out_White"_fnv:
        case "FadeInOutBlack"_fnv:
        case "FadeInOutWhite"_fnv:
        case "GUIBlackMask"_fnv:
        case "GenomeCodexGUI"_fnv:
        case "sm42_020_keystrokeDevice01A_gimmick"_fnv: // this one is the keypad in the locker room...
            return true;

#if defined(RE2) || defined(RE3)
        // the weird buggy overlay in the inventory
        case "GuiBack"_fnv:
            return false;
#endif

#if defined(RE4)
        case "Gui_ui2510"_fnv: // Black bars in cutscenes
            return false;
#endif

#if defined(RE9)
        case "Gui_ui0440"_fnv: // Black bars in cutscenes
            game_object->shouldDraw = false;
            return false;
        case "GuiTimelineEvent_ui1640_00"_fnv:
        case "GuiPlayerGimmick0040"_fnv:  //blood analyzer
            return true;
#endif

#if TDB_VER >= 73
        case "ui0199"_fnv: // weird black bars in Kunitsu-Gami
            return false;
#endif

        default:
            break;
        };

        // Certain UI elements we want to remove when in VR (FirstPerson enabled)
#if defined(RE2) || defined(RE3)
        if (std::chrono::steady_clock::now() - m_last_crosshair_hide > std::chrono::seconds(1)) {
            auto& fp = FirstPerson::get();

            if (fp->is_enabled() && fp->will_be_used()) {
                const auto has_motion_controls = this->is_using_controllers();

                switch(name_hash) {
                case "GUI_Reticle"_fnv: // Crosshair
                    if (has_motion_controls) {
                        return false;
                    }
                    
                    break;
                default:
                    break;
                }
            }
        }
#endif

#ifdef RE7
        if (name_hash == "HUD"_fnv) { // not a hero
            // Stops HUD element from being stuck to the screen
            sdk::call_object_func<REComponent*>(gui_element, "set_RenderTarget", context, gui_element, nullptr);
        }
#endif

        //if (m_ui_last_frame_counts[name_hash] == 0 || m_ui_last_frame_counts[name_hash] - m_frame_count > 1) {
        //    m_ui_last_frame_counts[name_hash] = m_frame_count;
        //    return true;
        //}
        //m_ui_last_frame_counts[name_hash] = m_frame_count;

        //spdlog::info("VR: on_pre_gui_draw_element: {}", name);
        //spdlog::info("VR: on_pre_gui_draw_element: {} {:x}", name, (uintptr_t)game_object);

        auto view = sdk::call_object_func<REComponent*>(gui_element, "get_View", context, gui_element);

        if (view != nullptr) {
            const auto current_view_type = sdk::call_object_func<uint32_t>(view, "get_ViewType", context, view);

            if (current_view_type == (uint32_t)via::gui::ViewType::Screen) {
                static sdk::RETypeDefinition* via_render_mesh_typedef = nullptr;

                if (via_render_mesh_typedef == nullptr) {
                    via_render_mesh_typedef = sdk::find_type_definition("via.render.Mesh");

                    // wait
                    if (via_render_mesh_typedef == nullptr) {
                        return true;
                    }
                }

                // we don't want to mess with any game object that has a mesh
                // because it might be something physical in the game world
                // that the player can interact with
                if (utility::re_component::find(game_object->transform, via_render_mesh_typedef->get_type()) != nullptr) {
                    return true;
                }

#ifdef RE7
                static auto ui_world_pos_attach_typedef = sdk::find_type_definition("app.UIWorldPosAttach");
#endif

                auto ui_scale = m_ui_scale_option->value();
                const auto world_ui_scale = m_world_ui_scale_option->value();

                auto& restore_data = g_elements_to_reset.emplace_back(std::make_unique<GUIRestoreData>());
                auto original_game_object_pos = sdk::get_transform_position(game_object->transform);

                restore_data->element = gui_element;
                restore_data->view = view;
                restore_data->original_position = original_game_object_pos;
                restore_data->overlay = sdk::call_object_func<bool>(view, "get_Overlay", context, view);
                restore_data->detonemap = sdk::call_object_func<bool>(view, "get_Detonemap", context, view);
                restore_data->view_type = (via::gui::ViewType)current_view_type;

                original_game_object_pos.w = 0.0f;

                // Set view type to world
                sdk::call_object_func<void*>(view, "set_ViewType", context, view, (uint32_t)via::gui::ViewType::World);

                // Set overlay = true (fixes double vision in VR)
                sdk::call_object_func<void*>(view, "set_Overlay", context, view, true);

                // Set detonemap = true (fixes weird tint)
                sdk::call_object_func<void*>(view, "set_Detonemap", context, view, true);

                // Go through the children until we hit a blur filter
                // And then remove it
                /*for (auto child = sdk::call_object_func<REComponent*>(view, "get_Child", sdk::get_thread_context(), view); child != nullptr; child = sdk::call_object_func<REComponent*>(child, "get_Child", sdk::get_thread_context(), child)) {
                    if (utility::re_managed_object::is_a(child, "via.gui.BlurFilter")) {
                        // Call remove()
                        sdk::call_object_func<void*>(child, "remove", sdk::get_thread_context(), child);
                        break;
                    }
                }*/

                auto camera = sdk::get_primary_camera();

                // Set the gui element's position to be in front of the camera
                if (camera != nullptr) {
                    auto camera_object = utility::re_component::get_game_object(camera);

                    if (camera_object != nullptr && camera_object->transform != nullptr) {
                        auto& gui_matrix = game_object->transform->worldTransform;
                        auto child = sdk::call_object_func<REManagedObject*>(view, "get_Child", context, view);

                        auto fix_2d_position = [&](const Vector4f& target_position, 
                                                    bool screen_correction = true,
                                                    std::optional<float> custom_ui_scale = std::nullopt)
                        {
                            if (!custom_ui_scale) {
                                custom_ui_scale = world_ui_scale;
                            }

                            auto delta = target_position - m_render_camera_matrix[3];
                            delta.w = 0.0f;

                            auto dir = glm::normalize(delta);
                            dir.w = 0.0f;
                            
                            // make matrix from dir
                            const auto look_mat = glm::rowMajor4(glm::lookAtLH(Vector3f{}, Vector3f{ dir }, Vector3f(0.0f, 1.0f, 0.0f)));
                            const auto look_rot = glm::quat{look_mat};

                            auto new_pos = target_position;
                            new_pos.w = 1.0f;

                            gui_matrix = look_mat;
                            gui_matrix[3] = new_pos;

                            // LESSON: DO NOT CALL THESE METHODS ON THE TRANSFORM!
                            // THEY CAUSE SOME STRANGE BUGS WHEN THE GUI ELEMENT HAS A PARENT TRANSFORM!
                            // THE GUI RENDERING FUNCTIONS PERFORM ON THE WORLD MATRIX, SO THIS IS NOT NECESSARY.
                            //sdk::set_transform_position(game_object->transform, new_pos);
                            //sdk::set_transform_rotation(game_object->transform, look_rot);
                            
                            const auto scaled_ui_scale = *custom_ui_scale * 0.01f;
                            const auto distance = glm::length(delta);
                            const auto scale = std::clamp<float>(distance * scaled_ui_scale, 0.1f, 100.0f);

                            regenny::via::Size gui_size{};
                            sdk::call_object_func<void*>(view, "get_ScreenSize", &gui_size, context, view);
                            
                            auto fix_transform_object = [&](::REManagedObject* object) {
                                static auto transform_object_type = sdk::find_type_definition("via.gui.TransformObject");

                                if (object == nullptr) {
                                    return;
                                }

                                const auto t = utility::re_managed_object::get_type_definition(object);

                                if (t == nullptr || !t->is_a(transform_object_type)) {
                                    return;
                                }

                                //sdk::call_object_func<void*>(object, "set_ResolutionAdjust", context, object, true);

                                if (screen_correction) {
                                    Vector3f half_size{ gui_size.w / 2.0f, gui_size.h / 2.0f, 0.0f };
                                    sdk::call_object_func<void*>(object, "set_Position", context, object, &half_size);
                                }

                                //Vector4f new_scale{ scale, scale, scale, 1.0f };
                                const auto old_scale = sdk::call_object_func_easy<Vector4f>(object, "get_Scale");
                                Vector4f new_scale{ old_scale.y, old_scale.y, old_scale.z, 1.0f };
                                sdk::call_object_func<void*>(object, "set_Scale", context, object, &new_scale);
                            };

                            for (auto c = child; c != nullptr; c = sdk::call_object_func<REManagedObject*>(c, "get_Next", context, c)) {
                                fix_transform_object(c);
                            }

                            // Fix for other kinds of world pos attach elements.
#ifdef RE7
                            if (name_hash == "InteractOperationCursor"_fnv) {
                                auto world_pos_attach_comp = utility::re_component::find(game_object->transform, ui_world_pos_attach_typedef->get_type());

                                // Fix the world position of the gui element
                                if (world_pos_attach_comp != nullptr) {
                                    auto target_cache = sdk::get_object_field<::REManagedObject*>(world_pos_attach_comp, "_TargetGUIElem");

                                    if (target_cache != nullptr && *target_cache != nullptr) {
                                        auto element = sdk::get_object_field<::REManagedObject*>(*target_cache, "_Element");

                                        if (element != nullptr && *element != nullptr) {
                                            Vector3f zero_size{ 0.0f, 0.0f, 0.0f };
                                            sdk::call_object_func<void*>(*element, "set_Position", context, *element, &zero_size);
                                        }
                                    }
                                }
                            }
#endif

                            gui_matrix = glm::scale(gui_matrix, Vector3f{ scale, scale, scale });
                        };

                        auto camera_transform = camera_object->transform;

                        const auto& camera_matrix = m_original_camera_matrix;
                        auto camera_position = camera_matrix[3];

                        glm::quat wanted_rotation{};
                        
                        bool wants_face_glue = false;
                        auto ui_distance = m_ui_distance_option->value();

                        switch (name_hash) {
                        case "damage_ui2102"_fnv:
                        case "NightVision_Filter"_fnv:
                            wants_face_glue = true;
                            break;
                        default:
                            break;
                        };

                        float right_world_adjust{};

                        switch (name_hash) {
                        case "GuiFront"_fnv:
                        case "GUI_Pause"_fnv:
                        case "GUIPause"_fnv:
                        case "GUIMapBg"_fnv:
                        case "BG"_fnv:
                            ui_distance += 0.1f; // give everything a little pop in the inventory.
                            break;
                        case "GUI_MapBG"_fnv:
                        case "GUI_Map"_fnv:
                        case "GUI_MapGrid"_fnv:
                        case "GUIMap"_fnv:
                        case "GUIMapIcon"_fnv:
                            ui_distance -= 0.025f; // give everything a little pop in the inventory.
                            break;
                        case "GuiCaption"_fnv:
                        case "GUIInventory"_fnv:
                        case "GUIInventoryCraft"_fnv:
                        case "GUIInventoryKeyItem"_fnv:
                        case "GUIInventoryTreasure"_fnv:
                        case "GUIBinder"_fnv:
                        case "GUIEquip"_fnv:
                            ui_distance -= 0.1f; // give everything a little pop in the inventory.
                            break;
                        case "GUI_RemainingBullet"_fnv:
                            right_world_adjust = 0.15f;
                            break;
                        case "GUI_Reticle"_fnv:
                        case "ReticleGUI"_fnv:
                        case "GUIReticle"_fnv:
                            ui_distance = 5.0f;
                            ui_scale = 2.0f;
                            break;
                        case "hud_hunterwirewindow"_fnv:
                            ui_distance = 10.0f;
                            ui_scale = 1.0f;
                            break;
                        default:
                            break;
                        }

                        if (ui_distance < 0.0f) {
                            ui_distance = 0.0f;
                        }

                        // glues the GUI to the camera rotation and position
                        if (wants_face_glue) {
                            ui_distance = 5.0f;

                            wanted_rotation = glm::extractMatrixRotation(m_render_camera_matrix) * Matrix4x4f{
                                -1, 0, 0, 0,
                                0, 1, 0, 0,
                                0, 0, -1, 0,
                                0, 0, 0, 1
                            };
                        } else {
                            const auto gui_rotation_offset = get_gui_rotation_offset();

                            wanted_rotation = glm::extractMatrixRotation(camera_matrix) * Matrix4x4f{
                                -1, 0, 0, 0,
                                0, 1, 0, 0,
                                0, 0, -1, 0,
                                0, 0, 0, 1
                            };

                            if (m_decoupled_pitch->value()) {
                                bool is_exception = false;

                                switch (name_hash) {
                                    case "GUIReticle"_fnv:[[fallthrough]];
                                    case "ReticleGUI"_fnv:[[fallthrough]];
                                    case "GUI_Reticle"_fnv:
                                        is_exception = true;
                                        break;
                                    default:
                                        break;
                                }

                                if (!is_exception) {
                                    wanted_rotation = utility::math::flatten(wanted_rotation);
                                }
                            }

                            wanted_rotation = gui_rotation_offset * wanted_rotation;
                        }

                        const auto wanted_rotation_mat = Matrix4x4f{wanted_rotation};

#if defined(RE9)
                        // fix double vision on button prompts when using AFW/AFR
                        if ((is_using_afw() || is_using_afw_foveated()) && name_hash == "Gui_ui2010"_fnv) {
                            const auto eye_camera_matrix = m_original_camera_matrix * get_current_eye_transform(true);
                            camera_position = eye_camera_matrix[3];
                        }
 #endif

                        gui_matrix = wanted_rotation_mat;
                        gui_matrix[3] = camera_position + (wanted_rotation_mat[2] * ui_distance) + (wanted_rotation_mat[0] * right_world_adjust);
                        gui_matrix[3].w = 1.0f;

                        // Scales the GUI so it's not massive.
                        if (!wants_face_glue) {
                            const auto scale = 1.0f / ui_scale;
                            gui_matrix = glm::scale(gui_matrix, Vector3f{ scale, scale, scale });
                        }

                        static auto gui_driver_typedef = sdk::find_type_definition(game_namespace("GUIDriver"));
                        static auto mhrise_npc_head_message_typedef = sdk::find_type_definition(game_namespace("gui.GuiCommonNpcHeadMessage"));
                        static auto mhrise_speech_balloon_typedef = sdk::find_type_definition(game_namespace("gui.GuiCommonNpcSpeechBalloon"));
                        static auto mhrise_head_message_typedef = sdk::find_type_definition(game_namespace("gui.GuiCommonHeadMessage"));
                        static auto mhrise_otomo_head_message_typedef = sdk::find_type_definition(game_namespace("gui.GuiCommonOtomoHeadMessage"));
                        static auto kg_float_icon_behavior = sdk::find_type_definition("app.FloatIconBehavior");
                        static auto kg_general_vital_gauge_behavior = sdk::find_type_definition("app.GeneralVitalGaugeBehavior");

                        static auto gameobject_elements_list = {
                            mhrise_npc_head_message_typedef,
                            mhrise_speech_balloon_typedef,
                            mhrise_head_message_typedef,
                            mhrise_otomo_head_message_typedef,
                            kg_float_icon_behavior,
                            kg_general_vital_gauge_behavior
                        };
                        
                        // Fix position of interaction icons
                        if (name_hash == "GUI_FloatIcon"_fnv || name_hash == "RogueFloatIcon"_fnv || name_hash == "Gui_FloatIcon"_fnv) { // RE2, RE3, RE4
                            if (name_hash == "GUI_FloatIcon"_fnv || name_hash == "Gui_FloatIcon"_fnv) {
                                m_last_interaction_display = std::chrono::steady_clock::now();
                            }
                        
                            fix_2d_position(original_game_object_pos);
                        } else if(gui_driver_typedef != nullptr) { // RE8
                            auto interact_icon_comp = utility::re_component::find(game_object->transform, gui_driver_typedef->get_type());

                            if (interact_icon_comp != nullptr) {
                                auto interact_icon_object = sdk::call_object_func<REGameObject*>(interact_icon_comp, "get_attachTarget", context, interact_icon_comp);

                                if (interact_icon_object != nullptr && interact_icon_object->transform != nullptr) {
                                    // call get_Position on the object
                                    Vector4f interact_icon_position{};
                                    sdk::call_object_func<Vector4f*>(interact_icon_object->transform, "get_Position", &interact_icon_position, context, interact_icon_object->transform);

                                    fix_2d_position(interact_icon_position);
                                }
                            }
                        } else {
                            // MHRise
                            for (auto element_type : gameobject_elements_list) {
                                if (element_type == nullptr) {
                                    continue;
                                }

                                auto element_comp = utility::re_component::find(game_object->transform, element_type->get_type());

                                if (element_comp == nullptr) {
                                    continue;
                                }

                                static auto get_parent_method = sdk::get_object_method(game_object->transform, "get_Parent");
                                auto parent = get_parent_method->call<::RETransform*>(context, game_object->transform);

                                if (parent != nullptr) {
                                    Vector4f offset{};

                                    std::optional<float> custom_ui_scale = std::nullopt;

                                    if (element_type == mhrise_speech_balloon_typedef) {
                                        static auto pos_data_field = mhrise_speech_balloon_typedef->get_field("posData");
                                        static auto npc_message_pos = pos_data_field->get_type()->get_field("NpcMessagePos");

                                        auto pos_data = pos_data_field->get_data<::REManagedObject*>(element_comp);

                                        if (pos_data != nullptr) {
                                            const auto y_offset = npc_message_pos->get_data<float>(pos_data);
                                            offset = Vector4f{0.0f, y_offset, 0.0f, 0.0f};
                                        } else {
                                            offset = Vector4f{0.0f, 1.0f, 0.0f, 0.0f};
                                        }
                                    } else if (element_type == mhrise_npc_head_message_typedef) {
                                        static auto pos_data_field = mhrise_npc_head_message_typedef->get_field("posData");
                                        static auto npc_message_pos = pos_data_field->get_type()->get_field("NpcMessagePos");
                                        
                                        auto pos_data = pos_data_field->get_data<::REManagedObject*>(element_comp);

                                        if (pos_data != nullptr) {
                                            const auto y_offset = npc_message_pos->get_data<float>(pos_data);
                                            offset = Vector4f{0.0f, y_offset, 0.0f, 0.0f};
                                        } else {
                                            offset = Vector4f{0.0f, 1.0f, 0.0f, 0.0f};
                                        }
                                    } else if (element_type == mhrise_head_message_typedef) {
                                        static auto message_pos_y_field = mhrise_head_message_typedef->get_field("MessagePosY");

                                        const auto y_offset = message_pos_y_field->get_data<float>(element_comp);
                                        offset = Vector4f{0.0f, y_offset, 0.0f, 0.0f};
                                    } else if (element_type == mhrise_otomo_head_message_typedef) { //airou and dog
                                        offset = Vector4f{0.0, 1.0f, 0.0f, 0.0f};
                                    } else if (element_type == kg_float_icon_behavior) {
                                        static auto param_field = kg_float_icon_behavior->get_field("_Param");
                                        static auto world_pos_field = param_field != nullptr ? param_field->get_type()->get_field("WorldPos") : nullptr;

                                        if (world_pos_field != nullptr) {
                                            auto param = param_field->get_data<::REManagedObject*>(element_comp);

                                            if (param != nullptr) {
                                                offset = world_pos_field->get_data<Vector4f>(param);
                                                custom_ui_scale = 5.0f;
                                            }
                                        }
                                    } else if (element_type == kg_general_vital_gauge_behavior) {
                                        static auto param_field = kg_general_vital_gauge_behavior->get_field("_OpenParam");
                                        static auto world_pos_field = param_field != nullptr ? param_field->get_type()->get_field("WorldPos") : nullptr;

                                        if (world_pos_field != nullptr) {
                                            auto param = param_field->get_data<::REManagedObject*>(element_comp);

                                            if (param != nullptr) {
                                                offset = world_pos_field->get_data<Vector4f>(param);
                                                custom_ui_scale = 5.0f;
                                            }
                                        }
                                    }

                                    fix_2d_position(sdk::get_transform_position(parent) + offset, true, custom_ui_scale);
                                } else {
                                    fix_2d_position(original_game_object_pos);
                                }
                            }
                        }

                        // ... RE7
#ifdef RE7
                        auto world_pos_attach_comp = utility::re_component::find(game_object->transform, ui_world_pos_attach_typedef->get_type());

                        // Fix the world position of the gui element
                        if (world_pos_attach_comp != nullptr) {
                            const auto& target_pos = *sdk::get_object_field<Vector4f>(world_pos_attach_comp, "_NowTargetPos");
                            
                            fix_2d_position(target_pos);
                        }
#endif
                    }
                }
            }
        }
    } else {
        spdlog::info("VR: on_pre_gui_draw_element: nullptr gameobject");
    }

    return true;
}

void VR::on_gui_draw_element(REComponent* gui_element, void* primitive_context) {
    

    //spdlog::info("VR: on_gui_draw_element");

    auto context = sdk::get_thread_context();

    // Restore elements back to original states
    for (auto& data : g_elements_to_reset) {
        sdk::call_object_func<void*>(data->view, "set_ViewType", context, data->view, (uint32_t)via::gui::ViewType::Screen);
        sdk::call_object_func<void*>(data->view, "set_Overlay", context, data->view, data->overlay);
        sdk::call_object_func<void*>(data->view, "set_Detonemap", context, data->view, data->detonemap);
        
        auto game_object = utility::re_component::get_game_object(data->element);

        if (game_object != nullptr && game_object->transform != nullptr) {
            //sdk::set_transform_position(game_object->transform, data->original_position);

            auto& gui_matrix = game_object->transform->worldTransform;
            gui_matrix[3] = data->original_position;
        }
    }

    g_elements_to_reset.clear();
    inside_gui_draw = false;
}

void VR::on_pre_update_before_lock_scene(void* ctx) {
    /*auto camera = sdk::get_primary_camera();

    if (camera == nullptr) {
        return;
    }

    auto projection_matrix = get_current_projection_matrix(true);

    // Steps towards getting lens flares and volumetric lighting working
    // Get the FOV from the projection matrix
    const auto vfov = glm::degrees(2.0f * std::atan(1.0f / projection_matrix[1][1]));
    const auto aspect = projection_matrix[1][1] / projection_matrix[0][0];
    const auto hfov = vfov * aspect;
    
    spdlog::info("vFOV: {}", vfov);
    spdlog::info("Aspect: {}", aspect);

    sdk::call_object_func<void*>(camera, "set_FOV", sdk::get_thread_context(), camera, vfov);
    sdk::call_object_func<void*>(camera, "set_VerticalEnable", sdk::get_thread_context(), camera, true);
    sdk::call_object_func<void*>(camera, "set_AspectRatio", sdk::get_thread_context(), camera, aspect);*/
}

void VR::on_pre_lightshaft_draw(void* shaft, void* render_context) {
    m_in_lightshaft = true;

    /*static auto transparent_layer_t = sdk::find_type_definition("via.render.layer.Transparent");
    auto transparent_layer = sdk::renderer::find_layer(transparent_layer_t->type);

    spdlog::info("transparent layer: {:x}", (uintptr_t)transparent_layer);

    if (transparent_layer == nullptr) {
        return;
    }

    static auto scene_layer_t = sdk::find_type_definition("via.render.layer.Scene");
    auto scene_layer = transparent_layer->find_parent(scene_layer_t->type);

    spdlog::info("scene layer: {:x}", (uintptr_t)scene_layer);

    if (scene_layer == nullptr) {
        return;
    }

    scene_layer->update();

    spdlog::info("scene layer update: {:x}", (uintptr_t)(*(void***)scene_layer)[sdk::renderer::RenderLayer::UPDATE_VTABLE_INDEX]);*/
}

void VR::on_lightshaft_draw(void* shaft, void* render_context) {
    m_in_lightshaft = false;
}

thread_local bool timed_out = false;

void VR::on_pre_begin_rendering(void* entry) {
    

    auto runtime = get_runtime();

    if (!runtime->loaded) {
        return;
    }

    m_in_render = true;

    // Use the gamepad/motion controller sticks to lerp the standing origin back to the center
    if (m_via_hid_gamepad.update()) {
        auto pad = sdk::call_native_func_easy<REManagedObject*>(m_via_hid_gamepad.object, m_via_hid_gamepad.t, "get_LastInputDevice");

        if (pad != nullptr) {
            // Move direction
            // It's not a Vector2f because via.vec2 is not actually 8 bytes, we don't want stack corruption to occur.
            const auto axis_l = (Vector2f)*utility::re_managed_object::get_field<Vector3f*>(pad, "AxisL");
            const auto axis_r = (Vector2f)*utility::re_managed_object::get_field<Vector3f*>(pad, "AxisR");

            // Lerp the standing origin back to HMD position
            // if the user is moving
            if (glm::length(axis_l) > 0.0f || glm::length(axis_r) > 0.0f) {
                const auto highest_length = std::max<float>(glm::length(axis_l), glm::length(axis_r));
                auto new_pos = get_position(vr::k_unTrackedDeviceIndex_Hmd);

                const auto delta = sdk::Application::get()->get_delta_time();

                new_pos.y = m_standing_origin.y;
                // Don't set the Y because it would look really strange
                m_standing_origin = glm::lerp(m_standing_origin, new_pos, ((float)highest_length * delta) * 0.01f);
            }
        }

        // TODO: do the same thing for the keyboard
        // will probably require some game-specific code
    }

    detect_controllers();

    //actual_frame_count = get_game_frame_count();
    m_frame_count++;
    actual_frame_count = m_frame_count;

    /*if (!inside_on_end) {
        spdlog::info("VR: frame count: {}", m_frame_count);
    } else {
        spdlog::info("VR: frame count: {} (inside on_end)", m_frame_count);
    }*/

    // if we timed out, just return. we're assuming that the rendering will go on as normal
    if (timed_out) {
        if (inside_on_end) {
            spdlog::warn("VR: on_pre_wait_rendering: timed out inside_on_end");
        } else {
            spdlog::warn("VR: on_pre_wait_rendering: timed out");
        }

        return;
    }

    if (runtime->needs_pose_update && inside_on_end) {
        spdlog::info("VR: on_pre_wait_rendering: inside on end!");
    }
    
    // Call WaitGetPoses
    if (is_using_afw() || is_using_afw_foveated() || (!inside_on_end &&  is_left_eye())) {
        update_hmd_state();
    }

    const auto should_update_camera = is_left_eye() || is_using_afw() || is_using_afw_foveated();

    if (!inside_on_end && should_update_camera) {
        update_camera();
    } else if (inside_on_end) {
        update_camera_origin();
    }

    // update our internally stored render matrix
    update_render_matrix();
    //fix_temporal_effects(); // BAD way to do it!
}

void VR::on_begin_rendering(void* entry) {
    //spdlog::info("BeginRendering");
}

void VR::on_pre_end_rendering(void* entry) {
    

    auto runtime = get_runtime();

    if (!runtime->loaded) {
        return;
    }

    if (runtime->ready() && ((is_using_sf() && is_left_eye()) || is_using_afw() || is_using_afw_foveated())) {
        const auto stage = runtime->get_synchronize_stage();

        if (stage == VRRuntime::SynchronizeStage::LATE && runtime->synchronize_frame() == VRRuntime::Error::SUCCESS) {
            if (runtime->is_openxr()) {
                m_openxr->begin_frame();
            }
        }
    }

    auto root_layer = sdk::renderer::get_root_layer();
    if (root_layer != nullptr && m_frame_count > 600) {
        auto [output_parent, output_layer] = root_layer->find_layer_recursive("via.render.layer.Output");
        auto valid_scene_layers = (*output_layer)->find_fully_rendered_scene_layers();
        if (valid_scene_layers.empty()) {
            return;
        }
        if (valid_scene_layers.size() > 0) {
            depthTex[0] = valid_scene_layers[0]->get_depth_stencil_d3d12();
            //motionVectorsState = valid_scene_layers[0]->get_motion_vectors_state();
            if (valid_scene_layers.size() > 1) {
                depthTex[1] = valid_scene_layers[1]->get_depth_stencil_d3d12();
                auto rtv = valid_scene_layers[1]->get_motion_vectors_state()->get_rtv(0).get();
                mvRtvPtr = ((uintptr_t)rtv + 0xE8);
            }
        } 
    }
}

void VR::on_end_rendering(void* entry) {
    

    // we set this because we've enabled asynchronous rendering
    // by the time the next frame (right eye) starts,
    // the frame count might get modified, screwing up our logic
    // so we need a render frame count to compare against
    m_render_frame_count = m_frame_count;

    auto runtime = get_runtime();

    if (!runtime->loaded) {
        return;
    }

    // TODO: Check later if this is even necessary
    if ((!runtime->ready()) && !inside_on_end) {
        restore_camera();

        inside_on_end = false;
        m_in_render = false;
        return;
    }

    if (!inside_on_end) {
        auto app = sdk::Application::get();

        static auto app_type = sdk::find_type_definition("via.Application");
        static auto set_max_delta_time_fn = app_type->get_method("set_MaxDeltaTime");

        // RE8 and onwards...
        // defaults to 2, and will slow the game down if frame rate is too low
        if (set_max_delta_time_fn != nullptr) {
            // static func, no need for app
            set_max_delta_time_fn->call<void*>(sdk::get_thread_context(), 10.0f);
        }
    }

    if (is_using_afw() || is_using_afw_foveated()) {
        restore_camera();
        m_in_render = false;
        return;
    }

    if (is_using_sf() && inside_on_end) {
        return;
    }

    // Only render again on even (left eye) frames
    // We're checking == 1 because at this point, the frame has finished.
    // Meaning the previous frame was a left eye frame.
    if (!inside_on_end && ((is_using_sf() && (m_render_frame_count % 2 == m_left_eye_interval)))) {
        inside_on_end = true;
        
        // Try to render again for the right eye
        // Or for the foveated part when using foveated rendering
        auto app = sdk::Application::get();

        static auto chain = app->generate_chain("WaitRendering", "EndRendering");
        static bool do_once = true;

        if (do_once) {
            do_once = false;

            // Remove these from the chain (std::vector)
            auto entries_to_remove = std::vector<std::string> {
                "WaitRendering",
                "UpdatePhysicsCharacterController",
                "UpdateTelemetry",
                "UpdateMovie", // Causes movies to play twice as fast if ran again
                "UpdateSpeedTree",
                "UpdateHansoft",
                "UpdatePuppet",
                // The dynamics stuff causes a cloth physics step in the right eye
                "BeginRenderingDynamics",
                "BeginDynamics",
                "EndRenderingDynamics",
                "EndDynamics",
                "EndPhysics",
                "RenderDynamics",
#if TDB_VER < 73
                "RenderLandscape",
#endif
                "DevelopRenderer",
                "DrawWidget"
            };

            for (auto& entry : entries_to_remove) {
                chain.erase(std::remove_if(chain.begin(), chain.end(), [&](auto& func) {
                    return entry == func->description;
                }), chain.end());
            }
        }

        sdk::renderer::wait_rendering();
        sdk::renderer::begin_update_primitive();

        //static auto update_geometry = app->get_function("UpdateGeometry");
        static auto begin_update_effect = app->get_function("BeginUpdateEffect");
        static auto update_effect = app->get_function("UpdateEffect");
        static auto end_update_effect = app->get_function("EndUpdateEffect");
        static auto prerender_gui = app->get_function("PrerenderGUI");
        static auto begin_update_primitive = app->get_function("BeginUpdatePrimitive");

        // SO. Let me explain what's happening here.
        // If we try and just render a frame in this naive way in this order:
        // BeginUpdatePrimitive,
        // WaitRendering,
        // BeginRendering,
        // UpdatePrimitive,
        // EndPrimitive,
        // EndRendering,
        // This will end up having a chance to crash when rendering fluid effects for some reason when calling UpdatePrimitive.
        // The crash happens because some pipeline state inside the fluid simulator gets set to null.
        // So, we manually call BeginEffect, and then EndUpdateEffect
        // Which somehow solves the crash.
        // We don't call UpdateEffect because it will make effects appear to run at a higher framerate
        if (begin_update_effect != nullptr) {
            begin_update_effect->func(begin_update_effect->entry);
        }

        /*if (update_effect != nullptr) {
            update_effect->func(update_effect->entry);
        }*/

        if (end_update_effect != nullptr) {
            end_update_effect->func(end_update_effect->entry);
        }

        if (prerender_gui != nullptr) {
            prerender_gui->func(prerender_gui->entry);
        }

        for (auto func : chain) {
            //spdlog::info("Calling {}", func->description);

            func->func(func->entry);
        }

        restore_camera();

        m_in_render = false;
        inside_on_end = false;
    }
}

void VR::on_pre_wait_rendering(void* entry) {
}

void VR::on_wait_rendering(void* entry) {
    

    if (!get_runtime()->loaded) {
        return;
    }

    timed_out = false;

    if (!is_hmd_active()) {
        return;
    }

    //if (is_using_afw_foveated()) {
    //    return;
    //}

    // wait for m_present_finished (std::condition_variable)
    // to be signaled
    // only on the left eye interval because we need the right eye
    // to start render work as soon as possible
    // case 1: sequential frames and rendered frame == right eye (every two frames)
    // case 2: AFW and no foveated rendering (each frame)
    // case 3: AFW and foveated rendering and rendered frame is FR frame
    if ((is_using_sf() && m_render_frame_count % 2 == m_right_eye_interval) || is_using_afw()|| is_using_afw_foveated()) {
        if (WaitForSingleObject(m_present_finished_event, 333) == WAIT_TIMEOUT) {
            timed_out = true;
        }

        ResetEvent(m_present_finished_event);
    }
}

void VR::on_pre_application_entry(void* entry, const char* name, size_t hash) {
    if (!get_runtime()->loaded) {
        return;
    }

    m_camera_duplicator.on_pre_application_entry(entry, name, hash);

    switch (hash) {
        case "UpdateHID"_fnv:
            on_pre_update_hid(entry);
            break;
        case "WaitRendering"_fnv:
            on_pre_wait_rendering(entry);
            break;
        case "BeginRendering"_fnv:
            on_pre_begin_rendering(entry);
            break;
        case "EndRendering"_fnv:
            on_pre_end_rendering(entry);
            break;
        default:
            break;
    }
}

void VR::on_application_entry(void* entry, const char* name, size_t hash) {
    if (!get_runtime()->loaded) {
        return;
    }

    m_camera_duplicator.on_application_entry(entry, name, hash);

    switch (hash) {
        case "UpdateHID"_fnv:
            on_update_hid(entry);
            break;
        case "WaitRendering"_fnv:
            on_wait_rendering(entry);
            break;
        case "BeginRendering"_fnv:
            on_begin_rendering(entry);
            break;
        case "EndRendering"_fnv:
            on_end_rendering(entry);
            break;
        default:
            break;
    }
}

void VR::on_pre_update_hid(void* entry) {
    if (!get_runtime()->loaded || !is_hmd_active()) {
        return;
    }

    update_action_states();
}

void VR::on_update_hid(void* entry) {
    if (!get_runtime()->loaded || !is_hmd_active()) {
        return;
    }

#if not defined(RE2) and not defined(RE3)
    this->openvr_input_to_re_engine();
#endif

#ifdef RE8
    if (get_runtime()->handle_pause) {
        auto padman = sdk::get_managed_singleton<::REManagedObject>(game_namespace("HIDPadManager"));

        if (padman != nullptr) {
            auto merged_pad = sdk::call_object_func_easy<::REManagedObject*>(padman, "get_mergedPad");

            if (merged_pad != nullptr) {
                auto device = sdk::get_object_field<::REManagedObject*>(merged_pad, "Device");

                if (device != nullptr && *device != nullptr) {
                    sdk::call_object_func_easy<void*>(*device, "set_Button", via::hid::GamePadButton::CRight);
                }
            }
        }

        get_runtime()->handle_pause = false;
    }
#endif
}

void VR::openvr_input_to_re2_re3(REManagedObject* input_system) {
    if (!get_runtime()->loaded) {
        return;
    }

    static auto gui_master_type = sdk::find_type_definition(game_namespace("gui.GUIMaster"));
    static auto gui_master_get_instance = gui_master_type->get_method("get_Instance");
    static auto gui_master_get_input = gui_master_type->get_method("get_Input");
    static auto gui_master_input_type = gui_master_get_input->get_return_type();

    // ??????
#ifdef RE2
    static auto input_set_is_trigger_move_up_d = gui_master_input_type->get_method("set_IsTriggerMoveUpD");
    static auto input_set_is_trigger_move_down_d = gui_master_input_type->get_method("set_IsTriggerMoveDownD");
#endif

    auto gui_master = gui_master_get_instance->call<::REManagedObject*>(sdk::get_thread_context());
    auto gui_input = gui_master != nullptr ? 
                     gui_master_get_input->call<::REManagedObject*>(sdk::get_thread_context(), gui_master) : 
                     (::REManagedObject*)nullptr;

    auto ctx = sdk::get_thread_context();

    static auto get_lstick_method = sdk::get_object_method(input_system, "get_LStick");
    static auto get_rstick_method = sdk::get_object_method(input_system, "get_RStick");
    auto lstick = get_lstick_method->call<::REManagedObject*>(ctx);
    auto rstick = get_rstick_method->call<::REManagedObject*>(ctx);

    if (lstick == nullptr || rstick == nullptr) {
        return;
    }

    static auto get_button_bits_method = sdk::get_object_method(input_system, "get_ButtonBits");
    auto button_bits_obj = get_button_bits_method->call<::REManagedObject*>(ctx, input_system);

    if (button_bits_obj == nullptr) {
        return;
    }

    static auto get_active_user_input_unit_method = sdk::get_object_method(input_system, "getActiveUserInputUnit");
    auto input_unit_obj = get_active_user_input_unit_method->call<::REManagedObject*>(ctx, input_system);

    if (input_unit_obj == nullptr) {
        return;
    }

    const auto now = std::chrono::steady_clock::now();
    auto is_using_controller = (now - get_last_controller_update()) <= std::chrono::seconds(10);

    const auto is_grip_down = is_action_active(m_action_grip, m_right_joystick);
    const auto is_trigger_down = is_action_active(m_action_trigger, m_right_joystick);
    const auto is_left_grip_down = is_action_active(m_action_grip, m_left_joystick);
    const auto is_left_trigger_down = is_action_active(m_action_trigger, m_left_joystick);
    const auto is_left_joystick_click_down = is_action_active(m_action_joystick_click, m_left_joystick);
    const auto is_right_joystick_click_down = is_action_active(m_action_joystick_click, m_right_joystick);

    const auto is_minimap_down = is_action_active(m_action_minimap, m_left_joystick) || is_action_active(m_action_minimap, m_right_joystick);
    const auto is_left_a_button_down = is_action_active(m_action_a_button, m_left_joystick);
    const auto is_left_b_button_down = !is_minimap_down && is_action_active(m_action_b_button, m_left_joystick);
    const auto is_right_a_button_down = is_action_active(m_action_a_button, m_right_joystick);
    const auto is_right_b_button_down = is_action_active(m_action_b_button, m_right_joystick);

    const auto is_dpad_up_down = is_action_active(m_action_dpad_up, m_left_joystick) || is_action_active(m_action_dpad_up, m_right_joystick);
    const auto is_dpad_right_down = is_action_active(m_action_dpad_right, m_left_joystick) || is_action_active(m_action_dpad_right, m_right_joystick);
    const auto is_dpad_down_down = is_action_active(m_action_dpad_down, m_left_joystick) || is_action_active(m_action_dpad_down, m_right_joystick);
    const auto is_dpad_left_down = is_action_active(m_action_dpad_left, m_left_joystick) || is_action_active(m_action_dpad_left, m_right_joystick);

    const auto is_weapon_dial_down = is_action_active(m_action_weapon_dial, m_left_joystick) || is_action_active(m_action_weapon_dial, m_right_joystick);
    const auto is_re3_dodge_down = is_action_active(m_action_re3_dodge, m_left_joystick) || is_action_active(m_action_re3_dodge, m_right_joystick);
    const auto is_quickturn_down = is_action_active(m_action_re2_quickturn, m_left_joystick) || is_action_active(m_action_re2_quickturn, m_right_joystick);
    const auto is_reset_view_down = is_action_active(m_action_re2_reset_view, m_left_joystick) || is_action_active(m_action_re2_reset_view, m_right_joystick);
    const auto is_change_ammo_down = is_action_active(m_action_re2_change_ammo, m_left_joystick) || is_action_active(m_action_re2_change_ammo, m_right_joystick);
	const auto is_toggle_flashlight_down = is_action_active(m_action_re2_toggle_flashlight, m_left_joystick) || is_action_active(m_action_re2_toggle_flashlight, m_right_joystick);

    const auto is_left_system_button_down = is_action_active(m_action_system_button, m_left_joystick);
    const auto is_right_system_button_down = is_action_active(m_action_system_button, m_right_joystick);

    
    
#if defined(RE2) || defined(RE3) || defined(RE8)
    if (is_toggle_flashlight_down && !m_was_flashlight_toggle_down) {            
        ManualFlashlight::g_manual_flashlight-> toggle_flashlight();
    }    

    m_was_flashlight_toggle_down = is_toggle_flashlight_down;
#endif


#if defined(RE2) || defined(RE3)
    const auto is_firstperson_toggle_down = is_action_active(m_action_re2_firstperson_toggle, m_left_joystick) || is_action_active(m_action_re2_firstperson_toggle, m_right_joystick);

    if (is_firstperson_toggle_down && !m_was_firstperson_toggle_down) {
        FirstPerson::get()->toggle();
    }

    m_was_firstperson_toggle_down = is_firstperson_toggle_down;
#endif

#if defined(RE2) || defined(RE3)
    const auto is_gripping_weapon = FirstPerson::get()->was_gripping_weapon();
#else
    const auto is_gripping_weapon = false;
#endif

    // Current actual button bits used by the game
    auto& button_bits_down = *sdk::get_object_field<uint64_t>(button_bits_obj, "Down");
    auto& button_bits_on = *sdk::get_object_field<uint64_t>(button_bits_obj, "On");
    auto& button_bits_up = *sdk::get_object_field<uint64_t>(button_bits_obj, "Up");

    // Set button state based on our own history we keep that doesn't get overwritten by the game
    auto set_button_state = [&](app::ropeway::InputDefine::Kind kind, bool state) {
        const auto kind_uint64 = (uint64_t)kind;

        if (state) {
            m_last_controller_update = now;
            is_using_controller = true;

            button_bits_up &= ~kind_uint64;
            m_button_states_up &= ~kind_uint64;

            // if "On" state is not set
            if ((m_button_states_on.to_ullong() & kind_uint64) == 0) {
                if (m_button_states_down.to_ullong() & kind_uint64) {
                    m_button_states_on |= kind_uint64;
                    m_button_states_down &= ~kind_uint64;

                    button_bits_on |= kind_uint64;
                    button_bits_down &= ~kind_uint64;
                } else {
                    m_button_states_on &= ~kind_uint64;
                    m_button_states_down |= kind_uint64;

                    button_bits_on &= ~kind_uint64;
                    button_bits_down |= kind_uint64;
                }
            } else {
                m_button_states_down &= ~kind_uint64;
                button_bits_down &= ~kind_uint64;

                m_button_states_on |= kind_uint64;
                button_bits_on |= kind_uint64;
            }
        } else {
            if (m_button_states_down.to_ullong() & kind_uint64 || m_button_states_on.to_ullong() & kind_uint64) {
                m_button_states_up |= kind_uint64;
                button_bits_up |= kind_uint64;

                m_last_controller_update = now;
                is_using_controller = true;
            } else if (is_using_controller) {
                m_button_states_up &= ~kind_uint64;
                button_bits_up &= ~kind_uint64;
            }

            // Don't want to screw with the user's input if they aren't actively
            // Using their VR controllers
            if (is_using_controller) {
                button_bits_down &= ~kind_uint64;
                m_button_states_down &= ~kind_uint64;
                
                button_bits_on &= ~kind_uint64;
                m_button_states_on &= ~kind_uint64;
            }
        }
    };

    // Right Grip: Aim, UI Right (RB)
    set_button_state(app::ropeway::InputDefine::Kind::HOLD, is_grip_down);
    set_button_state(app::ropeway::InputDefine::Kind::UI_SHIFT_RIGHT, is_grip_down);

    // Left Grip: Alternate aim (grenades, knives, etc), UI left (LB)
    set_button_state(app::ropeway::InputDefine::Kind::SUPPORT_HOLD, is_left_grip_down && !is_gripping_weapon);   
    set_button_state(app::ropeway::InputDefine::Kind::UI_SHIFT_LEFT, is_left_grip_down);

    // Right Trigger (RB): Attack, Alternate UI right (RT), GE_RTrigBottom (quick time event), GE_RTrigTop (another quick time event)
    set_button_state(app::ropeway::InputDefine::Kind::ATTACK, is_trigger_down);
    set_button_state(app::ropeway::InputDefine::Kind::UI_SHIFT_RIGHT_2, is_trigger_down);
    set_button_state((app::ropeway::InputDefine::Kind)18014398509481984, is_trigger_down);
    set_button_state((app::ropeway::InputDefine::Kind)9007199254740992, is_trigger_down);
    //set_button_state((app::ropeway::InputDefine::Kind)4503599627370496, is_trigger_down);

    // Left Trigger (LB): Alternate UI left (LT), DEFENSE (LB)
    set_button_state(app::ropeway::InputDefine::Kind::UI_SHIFT_LEFT_2, is_left_trigger_down);
    set_button_state(app::ropeway::InputDefine::Kind::DEFENSE, is_left_trigger_down);

    // L3: Sprint
    set_button_state(app::ropeway::InputDefine::Kind::JOG1, is_left_joystick_click_down);

    // R3: Reset camera
    set_button_state(app::ropeway::InputDefine::Kind::RESET_CAMERA, is_reset_view_down);

    // Left B: Inventory, PRESS_START
    set_button_state(app::ropeway::InputDefine::Kind::INVENTORY, is_left_b_button_down);
    set_button_state(app::ropeway::InputDefine::Kind::PRESS_START, is_left_b_button_down);

    // Left A: QUICK_TURN, PRESS_START, CANCEL, DIALOG_CANCEL
    set_button_state(app::ropeway::InputDefine::Kind::QUICK_TURN, is_quickturn_down); // unique, unbound by default as it causes issues
    set_button_state(app::ropeway::InputDefine::Kind::PRESS_START, is_left_a_button_down);
    set_button_state(app::ropeway::InputDefine::Kind::CANCEL, is_left_a_button_down);
    set_button_state(app::ropeway::InputDefine::Kind::DIALOG_CANCEL, is_left_a_button_down);
    
    // Right A: Action, ITEM, PRESS_START, DECIDE, DIALOG_DECIDE, (1 << 51)
    set_button_state(app::ropeway::InputDefine::Kind::ACTION, is_right_a_button_down);
    set_button_state(app::ropeway::InputDefine::Kind::ITEM, is_right_a_button_down);
    set_button_state(app::ropeway::InputDefine::Kind::PRESS_START, is_right_a_button_down);
    set_button_state(app::ropeway::InputDefine::Kind::DECIDE, is_right_a_button_down);
    set_button_state(app::ropeway::InputDefine::Kind::DIALOG_DECIDE, is_right_a_button_down);

    // only allow dodging if there's nothing to interact with nearby
    if (!is_right_a_button_down || (now - m_last_interaction_display) >= std::chrono::milliseconds(200)) {
        set_button_state((app::ropeway::InputDefine::Kind)((uint64_t)1 << 51), is_re3_dodge_down); // RE3 dodge
    } else {
        set_button_state((app::ropeway::InputDefine::Kind)((uint64_t)1 << 51), false); // RE3 dodge
    }
    
    // Right B: Reload, Skip Event, UI_EXCHANGE, UI_RESET, (1 << 52) (that one is RE3 only? don't see it in the enum)
    set_button_state(app::ropeway::InputDefine::Kind::RELOAD, is_right_b_button_down);
    set_button_state(app::ropeway::InputDefine::Kind::SKIP_EVENT, is_right_b_button_down);
    set_button_state(app::ropeway::InputDefine::Kind::UI_EXCHANGE, is_right_b_button_down);
    set_button_state(app::ropeway::InputDefine::Kind::UI_RESET, is_right_b_button_down);
    set_button_state((app::ropeway::InputDefine::Kind)((uint64_t)1 << 52), is_right_b_button_down);

    const auto left_axis = get_left_stick_axis();
    const auto right_axis = get_right_stick_axis();
    const auto left_axis_len = glm::length(left_axis);
    const auto right_axis_len = glm::length(right_axis);

    if (!is_weapon_dial_down) {
        // DPad Up: Shortcut Up
        set_button_state(app::ropeway::InputDefine::Kind::SHORTCUT_UP, is_dpad_up_down);
        set_button_state(app::ropeway::InputDefine::Kind::UI_MAP_UP, is_dpad_up_down);
        set_button_state(app::ropeway::InputDefine::Kind::UI_UP, is_dpad_up_down); // IsTriggerMoveUpD in RE3

        // DPad Right: Shortcut Right
        set_button_state(app::ropeway::InputDefine::Kind::SHORTCUT_RIGHT, is_dpad_right_down);

        // DPad Down: Shortcut Down
        set_button_state(app::ropeway::InputDefine::Kind::SHORTCUT_DOWN, is_dpad_down_down);
        set_button_state(app::ropeway::InputDefine::Kind::UI_MAP_DOWN, is_dpad_down_down);
        set_button_state(app::ropeway::InputDefine::Kind::UI_DOWN, is_dpad_down_down); // IsTriggerMoveDownD in RE3

        // DPad Left: Shortcut Left
        set_button_state(app::ropeway::InputDefine::Kind::SHORTCUT_LEFT, is_dpad_left_down);

        // well this was really annoying to figure out
#ifdef RE2
        if (is_dpad_up_down && gui_input != nullptr) {
            input_set_is_trigger_move_up_d->call<void*>(ctx, gui_input, true);
        }

        if (is_dpad_down_down && gui_input != nullptr) {
            input_set_is_trigger_move_down_d->call<void*>(ctx, gui_input, true);
        }
#endif
    } else {
        set_button_state(app::ropeway::InputDefine::Kind::SHORTCUT_UP, left_axis.y > 0.9f);
        set_button_state(app::ropeway::InputDefine::Kind::SHORTCUT_RIGHT, left_axis.x > 0.9f);
        set_button_state(app::ropeway::InputDefine::Kind::SHORTCUT_DOWN, left_axis.y < -0.9f);
        set_button_state(app::ropeway::InputDefine::Kind::SHORTCUT_LEFT, left_axis.x < -0.9f);
    }

    // Change Ammo
    set_button_state(app::ropeway::InputDefine::Kind::CHANGE_BULLET, is_change_ammo_down);

    // MiniMap
    set_button_state(app::ropeway::InputDefine::Kind::MINIMAP, is_minimap_down);

    // Left or Right System Button: Pause
    set_button_state(app::ropeway::InputDefine::Kind::PAUSE, is_left_system_button_down || is_right_system_button_down || get_runtime()->handle_pause);
    get_runtime()->handle_pause = false;

    // Fixes QTE bound to triggers
    if (is_using_controller) {
        const auto left_trigger_state = is_left_trigger_down ? 1.0f : 0.0f;
        const auto right_trigger_state = is_trigger_down ? 1.0f : 0.0f;

        static auto set__analog_l_method = sdk::get_object_method(input_unit_obj, "set__AnalogL");
        static auto set__analog_r_method = sdk::get_object_method(input_unit_obj, "set__AnalogR");
        set__analog_l_method->call<void*>(ctx, input_unit_obj, left_trigger_state);
        set__analog_r_method->call<void*>(ctx, input_unit_obj, right_trigger_state);
    }

    bool moved_sticks = false;
    const auto deadzone = m_joystick_deadzone->value();

    if (left_axis_len > deadzone) {
        moved_sticks = true;

        // Override the left stick's axis values to the VR controller's values
        Vector3f axis{ left_axis.x, left_axis.y, 0.0f };

        static auto update_method = sdk::get_object_method(lstick, "update");
        update_method->call<void*>(ctx, lstick, &axis, &axis);
    }

    if (right_axis_len > deadzone) {
        moved_sticks = true;

        // Override the right stick's axis values to the VR controller's values
        Vector3f axis{ right_axis.x, right_axis.y, 0.0f };

        static auto update_method = sdk::get_object_method(rstick, "update");
        update_method->call<void*>(ctx, rstick, &axis, &axis);
    }

    if (moved_sticks) {
        auto new_pos = get_position(vr::k_unTrackedDeviceIndex_Hmd);

        const auto delta = sdk::Application::get()->get_delta_time();
        const auto highest_length = std::max<float>(glm::length(right_axis), glm::length(left_axis));

        new_pos.y = m_standing_origin.y;
        // Don't set the Y because it would look really strange
        m_standing_origin = glm::lerp(m_standing_origin, new_pos, ((float)highest_length * delta) * 0.01f);
    }

    set_button_state(app::ropeway::InputDefine::Kind::MOVE, left_axis_len > deadzone);
    set_button_state(app::ropeway::InputDefine::Kind::UI_L_STICK, left_axis_len > deadzone);

    set_button_state(app::ropeway::InputDefine::Kind::WATCH, right_axis_len > deadzone);
    set_button_state(app::ropeway::InputDefine::Kind::UI_R_STICK, right_axis_len > deadzone);
    //set_button_state(app::ropeway::InputDefine::Kind::RUN, right_axis_len > 0.01f);

    // Causes the right stick to take effect properly
    if (is_using_controller) {
        static auto set_input_mode_method = sdk::get_object_method(input_system, "set_InputMode");
        set_input_mode_method->call<void*>(ctx, input_system, app::ropeway::InputDefine::InputMode::Pad);
    }
}

void VR::openvr_input_to_re_engine() {
    // TODO: Get the "merged pad" and actually modify some inputs!

    const auto left_axis = get_left_stick_axis();
    const auto right_axis = get_right_stick_axis();
    const auto left_axis_len = glm::length(left_axis);
    const auto right_axis_len = glm::length(right_axis);
    const auto now = std::chrono::steady_clock::now();

    bool moved_sticks = false;

    if (left_axis_len > m_joystick_deadzone->value()) {
        moved_sticks = true;
    }

    if (right_axis_len > m_joystick_deadzone->value()) {
        moved_sticks = true;
    }

    if (moved_sticks) {
        auto new_pos = get_position(vr::k_unTrackedDeviceIndex_Hmd);

        const auto delta = sdk::Application::get()->get_delta_time();
        const auto highest_length = std::max<float>(glm::length(right_axis), glm::length(left_axis));

        new_pos.y = m_standing_origin.y;
        // Don't set the Y because it would look really strange
        m_standing_origin = glm::lerp(m_standing_origin, new_pos, ((float)highest_length * delta) * 0.01f);
        m_last_controller_update = now;
    }

    for (auto& it : m_action_handles) {
        if (is_action_active(it.second, m_left_joystick) || is_action_active(it.second, m_right_joystick)) {
            m_last_controller_update = now;
        }
    }
}

void VR::on_draw_ui() {
    // create VR tree entry in menu (imgui)
    if (get_runtime()->loaded) {
        ImGui::SetNextItemOpen(m_has_hw_scheduling, ImGuiCond_::ImGuiCond_FirstUseEver);
    } else {
        if (m_openvr->error && !m_openvr->dll_missing) {
            ImGui::SetNextItemOpen(true, ImGuiCond_::ImGuiCond_FirstUseEver);
        } else {
            ImGui::SetNextItemOpen(false, ImGuiCond_::ImGuiCond_FirstUseEver);
        }
    }

    if (!ImGui::CollapsingHeader(get_name().data())) {
        return;
    }

    auto display_error = [](auto& runtime, std::string dll_name) {
        if (runtime == nullptr || !runtime->error && runtime->loaded) {
            return;
        }

        if (runtime->error && runtime->dll_missing) {
            ImGui::TextWrapped("%s not loaded: %s not found", runtime->name().data(), dll_name.data());
            ImGui::TextWrapped("Please drop the %s file into the game's directory if you want to use %s", dll_name.data(), runtime->name().data());
        } else if (runtime->error) {
            ImGui::TextWrapped("%s not loaded: %s", runtime->name().data(), runtime->error->c_str());
        } else {
            ImGui::TextWrapped("%s not loaded: Unknown error", runtime->name().data());
        }

        ImGui::Separator();
    };

    display_error(m_openxr, "openxr_loader.dll");
    display_error(m_openvr, "openvr_api.dll");

    if (!get_runtime()->loaded) {
        ImGui::TextWrapped("No runtime loaded.");
        return;
    }

    ImGui::TextWrapped("Hardware scheduling: %s", m_has_hw_scheduling ? "Enabled" : "Disabled");

    if (m_has_hw_scheduling) {
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1.0f, 0.0f, 0.0f, 1.0f));
        ImGui::TextWrapped("WARNING: Hardware-accelerated GPU scheduling is enabled. This will cause the game to run slower.");
        ImGui::TextWrapped("Go into your Windows Graphics settings and disable \"Hardware-accelerated GPU scheduling\"");
        ImGui::PopStyleColor();
    }

    ImGui::Separator();

    ImGui::TextWrapped("VR Runtime: %s", get_runtime()->name().data());
    ImGui::TextWrapped("Render Resolution: %d x %d", get_runtime()->get_width(), get_runtime()->get_height());

    if (get_runtime()->is_openvr()) {
        ImGui::TextWrapped("Resolution can be changed in SteamVR");
    } else if (get_runtime()->is_openxr()) {
        if (ImGui::TreeNode("Bindings")) {
            m_openxr->display_bindings_editor();
            ImGui::TreePop();
        }

        if (m_resolution_scale->draw("Resolution Scale")) {
            m_openxr->resolution_scale = m_resolution_scale->value();
        }
    }
    
    ImGui::Combo("Sync Mode", (int*)&get_runtime()->custom_stage, "Early\0Late\0Very Late\0");
    ImGui::Separator();

    if (ImGui::Button("Set Standing Height")) {
        m_standing_origin.y = get_position(0).y;
    }

    if (ImGui::Button("Set Standing Origin") || m_set_standing_key->is_key_down_once()) {
        m_standing_origin = get_position(0);
    }

    if (ImGui::Button("Recenter View") || m_recenter_view_key->is_key_down_once()) {
        recenter_view();
    }

    if (ImGui::Button("Reinitialize Runtime")) {
        get_runtime()->wants_reinitialize = true;
    }

    //ImGui::DragFloat4("Right Bounds", (float*)&m_right_bounds, 0.005f, -2.0f, 2.0f);
    //ImGui::DragFloat4("Left Bounds", (float*)&m_left_bounds, 0.005f, -2.0f, 2.0f);

    ImGui::Separator();

    m_set_standing_key->draw("Set Standing Origin Key");
    m_recenter_view_key->draw("Recenter View Key");

    ImGui::Separator();

    m_rendering_technique->draw("Rendering Technique");
    if (m_rendering_technique->value() == ALTERNATE_FRAME_WARPING) {
        m_clear_before_framewarp->draw("Clear Before Framewarp");
        m_framewarp_debug->draw("Debug Framewarp");
        m_enable_ui_fix->draw("Enable Framewarp UI Fix");
        m_enable_sharpening->draw("Enable Sharpening");
        m_sharpness->draw("Sharpness");
        m_fix_upscalers_wobbling->draw("Fix Upscalers Wobbling");
        m_fix_item_inspection->draw("Fix Item Inspection Double Vision");
        m_ignore_motion_threshold->draw("Ignore Motion Threshold");
        m_framewarp_mode->draw("Framewarp Mode");
        m_enable_foveated_rendering->draw("Enable Foveated Rendering");
        m_foveated_ratio->draw("Foveated Ratio");
        ImGui::DragFloat("MotionScale X", &m_motion_scale[0], 0.01f, -1.0f, 1.0f);
        ImGui::DragFloat("MotionScale Y", &m_motion_scale[1], 0.01f, -1.0f, 1.0f);
    }
    ImGui::Separator();

    m_decoupled_pitch->draw("Decoupled Camera Pitch");

    if (ImGui::Checkbox("Positional Tracking", &m_positional_tracking)) {
    }

    m_hmd_oriented_audio->draw("Head Oriented Audio");
    m_use_custom_view_distance->draw("Use Custom View Distance");
    m_view_distance->draw("View Distance/FarZ");
    m_motion_controls_inactivity_timer->draw("Inactivity Timer");
    m_joystick_deadzone->draw("Joystick Deadzone");

    m_ui_scale_option->draw("2D UI Scale");
    m_ui_distance_option->draw("2D UI Distance");
    m_world_ui_scale_option->draw("World-Space UI Scale");

    ImGui::DragFloat3("Overlay Rotation", (float*)&m_overlay_rotation, 0.01f, -360.0f, 360.0f);
    ImGui::DragFloat3("Overlay Position", (float*)&m_overlay_position, 0.01f, -100.0f, 100.0f);

    ImGui::Separator();
    ImGui::Text("Graphical Options");

    m_force_fps_settings->draw("Force Uncap FPS");
    m_force_aa_settings->draw("Force Disable TAA");
    m_force_motionblur_settings->draw("Force Disable Motion Blur");
    m_force_vsync_settings->draw("Force Disable V-Sync");
    m_force_lensdistortion_settings->draw("Force Disable Lens Distortion");
    m_force_volumetrics_settings->draw("Force Disable Volumetrics");
    m_force_lensflares_settings->draw("Force Disable Lens Flares");
    m_force_dynamic_shadows_settings->draw("Force Enable Dynamic Shadows");
    m_allow_engine_overlays->draw("Allow Engine Overlays");
    m_enable_asynchronous_rendering->draw("Enable Asynchronous Rendering");

    if (ImGui::TreeNode("Desktop Recording Fix")) {
        ImGui::PushID("Desktop");
        m_desktop_fix->draw("Enabled");
        m_desktop_fix_skip_present->draw("Skip Present");
        ImGui::PopID();
        ImGui::TreePop();
    }

    ImGui::Separator();
    ImGui::Text("Debug info");
    m_camera_duplicator.on_draw_ui();
    

    ImGui::Checkbox("Disable Projection Matrix Override", &m_disable_projection_matrix_override);
    ImGui::Checkbox("Disable GUI Projection Matrix Override", &m_disable_gui_camera_projection_matrix_override);
    ImGui::Checkbox("Disable View Matrix Override", &m_disable_view_matrix_override);
    ImGui::Checkbox("Disable Backbuffer Size Override", &m_disable_backbuffer_size_override);
    ImGui::Checkbox("Disable Temporal Fix", &m_disable_temporal_fix);
    ImGui::Checkbox("Disable Post Effect Fix", &m_disable_post_effect_fix);
    
    const double min_ = 0.0;
    const double max_ = 25.0;
    ImGui::SliderScalar("Prediction Scale", ImGuiDataType_Double, &m_openxr->prediction_scale, &min_, &max_);

    ImGui::DragFloat4("Raw Left", (float*)&m_raw_projections[0], 0.01f, -100.0f, 100.0f);
    ImGui::DragFloat4("Raw Right", (float*)&m_raw_projections[1], 0.01f, -100.0f, 100.0f);

    // convert m_avg_input_delay (std::chrono::nanoseconds) to milliseconds (float)
    auto duration_float = std::chrono::duration<float, std::milli>(m_avg_input_delay).count();

    ImGui::DragFloat("Avg Input Processing Delay (MS)", &duration_float, 0.00001f);
}

void VR::on_device_reset() {
    std::scoped_lock _{m_openxr->sync_mtx};

    m_multipass.eye_textures[0] = nullptr;
    m_multipass.eye_textures[1] = nullptr;

    spdlog::info("VR: on_device_reset");
    m_backbuffer_inconsistency = false;
    if (g_framework->is_dx11()) {
        m_d3d11.on_reset(this);
    }

    if (g_framework->is_dx12()) {
        m_d3d12.on_reset(this);
    }

    m_overlay_component.on_reset();

    // so i guess device resets can happen between begin and end rendering...
    if (m_in_render) {
        spdlog::info("VR: on_device_reset: in_render");

        // what the fuck
        if (m_needs_camera_restore) {
            spdlog::info("VR: on_device_reset: needs_camera_restore");
            restore_camera();
        }
    }

    if (inside_on_end) {
        spdlog::info("VR: on_device_reset: inside_on_end");
    }
}

void VR::on_config_load(const utility::Config& cfg) {
    for (IModValue& option : m_options) {
        option.config_load(cfg);
    }

    // Run the rest of OpenXR initialization code here that depends on config values
    if (get_runtime()->is_openxr() && get_runtime()->loaded) {
        spdlog::info("[VR] Finishing up OpenXR initialization");

        m_openxr->resolution_scale = m_resolution_scale->value();
        initialize_openxr_swapchains();
    }

    if (m_motion_controls_inactivity_timer->value() <= 10.0f) {
        m_motion_controls_inactivity_timer->value() = 30.0f;
    }
}

void VR::on_config_save(utility::Config& cfg) {
    for (IModValue& option : m_options) {
        option.config_save(cfg);
    }
}

std::array<RECamera*, 2> VR::get_cameras() const {
    if (is_using_afw_foveated()) {
        return m_multipass_cameras;
    }

    return std::array<RECamera*, 2>{ sdk::get_primary_camera(), nullptr };
}

Vector4f VR::get_position(uint32_t index) const {
    if (index >= vr::k_unMaxTrackedDeviceCount) {
        return Vector4f{};
    }

    std::shared_lock _{ get_runtime()->pose_mtx };
    std::shared_lock __{ get_runtime()->eyes_mtx };

    return get_position_unsafe(index);
}

Vector4f VR::get_velocity(uint32_t index) const {
    if (index >= vr::k_unMaxTrackedDeviceCount) {
        return Vector4f{};
    }

    std::shared_lock _{ get_runtime()->pose_mtx };

    return get_velocity_unsafe(index);
}

Vector4f VR::get_angular_velocity(uint32_t index) const {
    if (index >= vr::k_unMaxTrackedDeviceCount) {
        return Vector4f{};
    }

    std::shared_lock _{ get_runtime()->pose_mtx };

    return get_angular_velocity_unsafe(index);
}

Vector4f VR::get_position_unsafe(uint32_t index) const {
    if (get_runtime()->is_openvr()) {
        if (index >= vr::k_unMaxTrackedDeviceCount) {
            return Vector4f{};
        }

        auto& pose = get_openvr_poses()[index];
        auto matrix = Matrix4x4f{ *(Matrix3x4f*)&pose.mDeviceToAbsoluteTracking };
        auto result = glm::rowMajor4(matrix)[3];
        result.w = 1.0f;

        return result;
    } else if (get_runtime()->is_openxr()) {
        if (index >= 3) {
            return Vector4f{};
        }

        // HMD position
        if (index == 0 && !m_openxr->stage_views.empty()) {
            return Vector4f{ *(Vector3f*)&m_openxr->view_space_location.pose.position, 1.0f };
        } else if (index > 0) {
            return Vector4f{ *(Vector3f*)&m_openxr->hands[index-1].location.pose.position, 1.0f };
        }

        return Vector4f{};
    } 

    return Vector4f{};
}

Vector4f VR::get_velocity_unsafe(uint32_t index) const {
    if (get_runtime()->is_openvr()) {
        if (index >= vr::k_unMaxTrackedDeviceCount) {
            return Vector4f{};
        }

        const auto& pose = get_openvr_poses()[index];
        const auto& velocity = pose.vVelocity;

        return Vector4f{ velocity.v[0], velocity.v[1], velocity.v[2], 0.0f };
    } else if (get_runtime()->is_openxr()) {
        if (index >= 3) {
            return Vector4f{};
        }

        // todo: implement HMD velocity
        if (index == 0) {
            return Vector4f{};
        }

        return Vector4f{ *(Vector3f*)&m_openxr->hands[index-1].velocity.linearVelocity, 0.0f };
    }

    return Vector4f{};
}

Vector4f VR::get_angular_velocity_unsafe(uint32_t index) const {
    if (get_runtime()->is_openvr()) {
        if (index >= vr::k_unMaxTrackedDeviceCount) {
            return Vector4f{};
        }

        const auto& pose = get_openvr_poses()[index];
        const auto& angular_velocity = pose.vAngularVelocity;

        return Vector4f{ angular_velocity.v[0], angular_velocity.v[1], angular_velocity.v[2], 0.0f };
    } else if (get_runtime()->is_openxr()) {
        if (index >= 3) {
            return Vector4f{};
        }

        // todo: implement HMD velocity
        if (index == 0) {
            return Vector4f{};
        }
    
        return Vector4f{ *(Vector3f*)&m_openxr->hands[index-1].velocity.angularVelocity, 0.0f };
    }

    return Vector4f{};
}

Matrix4x4f VR::get_rotation(uint32_t index) const {
    if (get_runtime()->is_openvr()) {
        if (index >= vr::k_unMaxTrackedDeviceCount) {
            return glm::identity<Matrix4x4f>();
        }

        std::shared_lock _{ get_runtime()->pose_mtx };

        auto& pose = get_openvr_poses()[index];
        auto matrix = Matrix4x4f{ *(Matrix3x4f*)&pose.mDeviceToAbsoluteTracking };
        return glm::extractMatrixRotation(glm::rowMajor4(matrix));
    } else if (get_runtime()->is_openxr()) {
        std::shared_lock _{ get_runtime()->pose_mtx };
        std::shared_lock __{ get_runtime()->eyes_mtx };

        // HMD rotation
        if (index == 0 && !m_openxr->stage_views.empty()) {
            return Matrix4x4f{*(glm::quat*)&m_openxr->view_space_location.pose.orientation};
            //return Matrix4x4f{*(glm::quat*)&m_openxr->stage_views[0].pose.orientation};
        } else if (index > 0) {
            if (index == VRRuntime::Hand::LEFT+1) {
                return Matrix4x4f{*(glm::quat*)&m_openxr->hands[VRRuntime::Hand::LEFT].location.pose.orientation};
            } else if (index == VRRuntime::Hand::RIGHT+1) {
                return Matrix4x4f{*(glm::quat*)&m_openxr->hands[VRRuntime::Hand::RIGHT].location.pose.orientation};
            }
        }

        return glm::identity<Matrix4x4f>();
    }

    return glm::identity<Matrix4x4f>();
}

Matrix4x4f VR::get_transform(uint32_t index) const {
    if (get_runtime()->is_openvr()) {
        if (index >= vr::k_unMaxTrackedDeviceCount) {
            return glm::identity<Matrix4x4f>();
        }

        std::shared_lock _{ get_runtime()->pose_mtx };

        auto& pose = get_openvr_poses()[index];
        auto matrix = Matrix4x4f{ *(Matrix3x4f*)&pose.mDeviceToAbsoluteTracking };
        return glm::rowMajor4(matrix);
    } else if (get_runtime()->is_openxr()) {
        std::shared_lock _{ get_runtime()->pose_mtx };

        // HMD rotation
        if (index == 0 && !m_openxr->stage_views.empty()) {
            auto mat = Matrix4x4f{*(glm::quat*)&m_openxr->view_space_location.pose.orientation};
            mat[3] = Vector4f{*(Vector3f*)&m_openxr->view_space_location.pose.position, 1.0f};
            return mat;
        } else if (index > 0) {
            if (index == VRRuntime::Hand::LEFT+1) {
                auto mat = Matrix4x4f{*(glm::quat*)&m_openxr->hands[VRRuntime::Hand::LEFT].location.pose.orientation};
                mat[3] = Vector4f{*(Vector3f*)&m_openxr->hands[VRRuntime::Hand::LEFT].location.pose.position, 1.0f};
                return mat;
            } else if (index == VRRuntime::Hand::RIGHT+1) {
                auto mat = Matrix4x4f{*(glm::quat*)&m_openxr->hands[VRRuntime::Hand::RIGHT].location.pose.orientation};
                mat[3] = Vector4f{*(Vector3f*)&m_openxr->hands[VRRuntime::Hand::RIGHT].location.pose.position, 1.0f};
                return mat;
            }
        }
    }

    return glm::identity<Matrix4x4f>();
}

vr::HmdMatrix34_t VR::get_raw_transform(uint32_t index) const {
    if (get_runtime()->is_openvr()) {
        if (index >= vr::k_unMaxTrackedDeviceCount) {
            return vr::HmdMatrix34_t{};
        }

        std::shared_lock _{ get_runtime()->pose_mtx };

        auto& pose = get_openvr_poses()[index];
        return pose.mDeviceToAbsoluteTracking;
    } else {
        spdlog::error("VR: get_raw_transform: not implemented for {}", get_runtime()->name());
        return vr::HmdMatrix34_t{};
    }
}

bool VR::is_action_active(vr::VRActionHandle_t action, vr::VRInputValueHandle_t source) const {
    if (!get_runtime()->loaded) {
        return false;
    }
    
    bool active = false;

    if (get_runtime()->is_openvr()) {
        vr::InputDigitalActionData_t data{};
        vr::VRInput()->GetDigitalActionData(action, &data, sizeof(data), source);

        active = data.bActive && data.bState;
    } else if (get_runtime()->is_openxr()) {
        active = m_openxr->is_action_active((XrAction)action, (VRRuntime::Hand)source);
    }

    if (!active && action == m_action_minimap) {
        active = is_action_active(m_action_b_button, m_left_joystick) && is_hand_behind_head(VRRuntime::Hand::LEFT);
    }

    return active;
}

Vector2f VR::get_joystick_axis(vr::VRInputValueHandle_t handle) const {
    if (!get_runtime()->loaded) {
        return Vector2f{};
    }

    if (get_runtime()->is_openvr()) {
        vr::InputAnalogActionData_t data{};
        vr::VRInput()->GetAnalogActionData(m_action_joystick, &data, sizeof(data), handle);

        const auto deadzone = m_joystick_deadzone->value();
        const auto out = Vector2f{ data.x, data.y };

        return glm::length(out) > deadzone ? out : Vector2f{};
    } else if (get_runtime()->is_openxr()) {
        if (handle == (vr::VRInputValueHandle_t)VRRuntime::Hand::LEFT) {
            auto out = m_openxr->get_left_stick_axis();
            return glm::length(out) > m_joystick_deadzone->value() ? out : Vector2f{};
        } else if (handle == (vr::VRInputValueHandle_t)VRRuntime::Hand::RIGHT) {
            auto out = m_openxr->get_right_stick_axis();
            return glm::length(out) > m_joystick_deadzone->value() ? out : Vector2f{};
        }
    }

    return Vector2f{};
}

Vector2f VR::get_left_stick_axis() const {
    return get_joystick_axis(m_left_joystick);
}

Vector2f VR::get_right_stick_axis() const {
    return get_joystick_axis(m_right_joystick);
}

void VR::trigger_haptic_vibration(float seconds_from_now, float duration, float frequency, float amplitude, vr::VRInputValueHandle_t source) {
    if (!get_runtime()->loaded || !is_using_controllers()) {
        return;
    }

    if (get_runtime()->is_openvr()) {
        vr::VRInput()->TriggerHapticVibrationAction(m_action_haptic, seconds_from_now, duration, frequency, amplitude, source);
    } else if (get_runtime()->is_openxr()) {
        m_openxr->trigger_haptic_vibration(duration, frequency, amplitude, (VRRuntime::Hand)source);
    }
}
