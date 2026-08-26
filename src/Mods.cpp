#include <algorithm>
#include <array>
#include <string_view>

#include <spdlog/spdlog.h>

#include "mods/BackBufferRenderer.hpp"
#include "mods/APIProxy.hpp"
#include "mods/Camera.hpp"
#include "mods/Graphics.hpp"
#include "mods/DeveloperTools.hpp"
#include "mods/FirstPerson.hpp"
#include "mods/FreeCam.hpp"
#include "mods/Hooks.hpp"
#include "mods/IntegrityCheckBypass.hpp"
#include "mods/ManualFlashlight.hpp"
#include "mods/PluginLoader.hpp"
#include "mods/REFrameworkConfig.hpp"
#include "mods/Scene.hpp"
#include "mods/ScriptRunner.hpp"
#include "mods/VR.hpp"
#include "mods/LooseFileLoader.hpp"
#include "mods/vr/games/RE8VR.hpp"
#if defined(RE4)
#include "mods/vr/games/re4/RE4VRMovement.hpp"
#include "mods/vr/games/re4/RE4VRMenu.hpp"
#include "mods/vr/games/re4/RE4VRStatics.hpp"
#include "mods/vr/games/re4/RE4VRLib.hpp"
#include "mods/vr/games/re4/RE4VRFrameCache.hpp"
#include "mods/vr/games/re4/RE4VRKillswitch.hpp"
#include "mods/vr/games/re4/RE4VRCapacitive.hpp"
#include "mods/vr/games/re4/RE4VRAudio.hpp"
#include "mods/vr/games/re4/RE4VRScope.hpp"
#include "mods/vr/games/re4/RE4VRWhitelist.hpp"
#include "mods/vr/games/re4/RE4VRFirstPerson.hpp"
#include "mods/vr/games/re4/RE4VRBinding.hpp"
#include "mods/vr/games/re4/RE4VRCrosshair.hpp"
#include "mods/vr/games/re4/RE4VRRecoil.hpp"
#include "mods/vr/games/re4/RE4VRGestures.hpp"
#include "mods/vr/games/re4/RE4VRMaterials.hpp"
#include "mods/vr/games/re4/RE4VRMerc.hpp"
#include "mods/vr/games/re4/RE4VRMinecart.hpp"
#include "mods/vr/games/re4/RE4VRUI.hpp"
#include "mods/vr/games/re4/RE4VRWeapons.hpp"
#include "mods/vr/games/re4/RE4VRWeapons2.hpp"
#include "mods/vr/games/re4/RE4VRMotion.hpp"
#include "mods/vr/games/re4/RE4VRArmChain.hpp"
#include "mods/vr/games/re4/RE4VRHolster.hpp"
#include "mods/vr/games/re4/RE4VRReloadAdv.hpp"
#include "mods/vr/games/re4/RE4VRReload.hpp"
#include "mods/vr/games/re4/RE4VRReload2.hpp"
#include "mods/vr/games/re4/RE4VRReload3.hpp"
#include "mods/vr/games/re4/RE4VRReload4.hpp"
#include "mods/vr/games/re4/RE4VRReload5.hpp"
#endif
#include "mods/TemporalUpscaler.hpp"

#include "Mods.hpp"

Mods::Mods() {
    m_mods.emplace_back(BackBufferRenderer::get());
    m_mods.emplace_back(REFrameworkConfig::get());

#if defined(REENGINE_AT)
    m_mods.emplace_back(std::make_unique<IntegrityCheckBypass>());
#endif

#ifndef BAREBONES
    m_mods.emplace_back(Hooks::get());
    m_mods.emplace_back(LooseFileLoader::get());

    m_mods.emplace_back(VR::get());
    m_mods.emplace_back(TemporalUpscaler::get());

#if defined(RE8) || defined(RE7)
    m_mods.emplace_back(RE8VR::get());
#endif

#ifndef RE8
#if defined(RE2) || defined(RE3)
    m_mods.emplace_back(FirstPerson::get());
#endif
#endif

    // All games!!!
    m_mods.emplace_back(Camera::get());
    m_mods.emplace_back(Graphics::get());

#if defined(RE2) || defined(RE3) || defined(RE8)
    m_mods.emplace_back(std::make_unique<ManualFlashlight>());
#endif

    m_mods.emplace_back(std::make_unique<FreeCam>());

#if TDB_VER > 49
    m_mods.emplace_back(std::make_unique<SceneMods>());
#endif

#endif

#ifdef DEVELOPER
    auto dev_tools = std::make_shared<DeveloperTools>();
    m_mods.emplace_back(dev_tools);

    for (auto& tool : dev_tools->get_tools()) {
        m_mods.emplace_back(tool);
    }
#endif

    m_mods.emplace_back(APIProxy::get());
    m_mods.emplace_back(PluginLoader::get());
    m_mods.emplace_back(ScriptRunner::get());

#if defined(RE4)
    // After ScriptRunner. One builtin Mod per former scripts/re4 lua file.
    // Libs/cache/killswitch first; firstperson before movement lag_fix; motion before arm_chain; movement last.
    m_mods.emplace_back(RE4VRMenu::get());
    m_mods.emplace_back(RE4VRStatics::get());
    m_mods.emplace_back(RE4VRLib::get());
    m_mods.emplace_back(RE4VRFrameCache::get());
    m_mods.emplace_back(RE4VRKillswitch::get());
    m_mods.emplace_back(RE4VRCapacitive::get());
    m_mods.emplace_back(RE4VRAudio::get());
    m_mods.emplace_back(RE4VRScope::get());
    m_mods.emplace_back(RE4VRWhitelist::get());
    m_mods.emplace_back(RE4VRFirstPerson::get());
    m_mods.emplace_back(RE4VRBinding::get());
    m_mods.emplace_back(RE4VRCrosshair::get());
    m_mods.emplace_back(RE4VRRecoil::get());
    m_mods.emplace_back(RE4VRGestures::get());
    m_mods.emplace_back(RE4VRMaterials::get());
    m_mods.emplace_back(RE4VRMerc::get());
    m_mods.emplace_back(RE4VRMinecart::get());
    m_mods.emplace_back(RE4VRUI::get());
    m_mods.emplace_back(RE4VRWeapons::get());
    m_mods.emplace_back(RE4VRWeapons2::get());
    m_mods.emplace_back(RE4VRMotion::get());
    m_mods.emplace_back(RE4VRArmChain::get());
    m_mods.emplace_back(RE4VRHolster::get());
    m_mods.emplace_back(RE4VRReloadAdv::get());
    m_mods.emplace_back(RE4VRReload::get());
    m_mods.emplace_back(RE4VRReload2::get());
    m_mods.emplace_back(RE4VRReload3::get());
    m_mods.emplace_back(RE4VRReload4::get());
    m_mods.emplace_back(RE4VRReload5::get());
    m_mods.emplace_back(RE4VRMovement::get());
#endif
}

std::optional<std::string> Mods::on_initialize() const {
    for (auto& mod : m_mods) {
        spdlog::info("{:s}::on_initialize()", mod->get_name().data());

        if (auto e = mod->on_initialize(); e != std::nullopt) {
            spdlog::info("{:s}::on_initialize() has failed: {:s}", mod->get_name().data(), *e);
            return e;
        }
    }

    utility::Config cfg{ (REFramework::get_persistent_dir() / REFrameworkConfig::REFRAMEWORK_CONFIG_NAME).string() };

    for (auto& mod : m_mods) {
        spdlog::info("{:s}::on_config_load()", mod->get_name().data());
        mod->on_config_load(cfg);
    }

    return std::nullopt;
}


std::optional<std::string> Mods::on_initialize_d3d_thread() const {
    auto do_not_hook_d3d = g_framework->acquire_do_not_hook_d3d();

    utility::Config cfg{ (REFramework::get_persistent_dir() / REFrameworkConfig::REFRAMEWORK_CONFIG_NAME).string() };

    // once here to at least setup the values
    for (auto& mod : m_mods) {
        spdlog::info("{:s}::on_config_load()", mod->get_name().data());
        mod->on_config_load(cfg);
    }

    for (auto& mod : m_mods) {
        spdlog::info("{:s}::on_initialize_d3d_thread()", mod->get_name().data());

        if (auto e = mod->on_initialize_d3d_thread(); e != std::nullopt) {
            spdlog::info("{:s}::on_initialize_d3d_thread() has failed: {:s}", mod->get_name().data(), *e);
            return e;
        }
    }

    for (auto& mod : m_mods) {
        spdlog::info("{:s}::on_config_load()", mod->get_name().data());
        mod->on_config_load(cfg);
    }

    return std::nullopt;
}

void Mods::on_pre_imgui_frame() const {
    for (auto& mod : m_mods) {
        mod->on_pre_imgui_frame();
    }
}

void Mods::on_frame() const {
    for (auto& mod : m_mods) {
        mod->on_frame();
    }
}

void Mods::on_present() const {
    for (auto& mod : m_mods) {
        mod->on_early_present();
    }

    for (auto& mod : m_mods) {
        mod->on_present();
    }
}

void Mods::on_post_frame() const {
    for (auto& mod : m_mods) {
        mod->on_post_frame();
    }
}

void Mods::on_draw_ui() const {
    // Only these mods are allowed to draw their tree in the menu, everything else stays hidden.
    // ScriptRunner also draws the "Script Generated UI" tree.
    static const std::array<std::string_view, 3> visible_mods {
        "ScriptRunner",
        "TemporalUpscaler", // shows up as "Upscaler"
        "RE4VRMenu",
    };

    for (auto& mod : m_mods) {
        const auto name = mod->get_name();

        if (std::find(visible_mods.begin(), visible_mods.end(), name) == visible_mods.end()) {
            continue;
        }

        mod->on_draw_ui();
    }
}

void Mods::on_device_reset() const {
    for (auto& mod : m_mods) {
        mod->on_device_reset();
    }
}
