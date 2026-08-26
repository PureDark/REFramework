#define NOMINMAX
#include "RE4VRWhitelist.hpp"

#if defined(RE4)
#include <fstream>
#include <sdk/RETypeDB.hpp>
#include <sdk/REString.hpp>
#include <sdk/RETransform.hpp>
#include <utility/String.hpp>
#include "RE4VRShared.hpp"

std::shared_ptr<RE4VRWhitelist>& RE4VRWhitelist::get() {
    static auto inst = std::make_shared<RE4VRWhitelist>();
    return inst;
}

void RE4VRWhitelist::refresh_types() {
    m_tds.clear();
    for (const auto& n : m_types) {
        if (auto* td = sdk::find_type_definition(n.c_str())) {
            if (auto* rt = td->get_runtime_type()) {
                m_tds.push_back(rt);
            }
        }
    }
}

void RE4VRWhitelist::load_stems() {
    m_prefixes.clear();
    m_contains = {"\xE6\xA8\xBD", "\xE3\x81\x9F\xE3\x82\x8B", "\xE3\x82\xBF\xE3\x83\xAB", "\xE6\x9C\xA8\xE7\xAE\xB1", "\xE7\xAA\x93", "\xE5\xA3\xBA"};
    m_contains_only = {"\xE9\x9D\x92\xE3\x82\xB3\xE3\x82\xA4\xE3\x83\xB3"};
    std::unordered_set<std::string> seen;
    auto add = [&](std::string v) {
        while (!v.empty() && (v.front() == ' ' || v.front() == '\t')) {
            v.erase(v.begin());
        }
        while (!v.empty() && (v.back() == ' ' || v.back() == '\t' || v.back() == '\r')) {
            v.pop_back();
        }
        if (v.empty() || v.front() == '#' || seen.count(v)) {
            return;
        }
        seen.insert(v);
        m_prefixes.push_back(std::move(v));
    };
    auto d = re4vr::load_json_file("re4_vr/re4_vr_breakables.json");
    if (d.contains("stems") && d["stems"].is_array()) {
        for (auto& s : d["stems"]) {
            if (s.is_string()) {
                add(s.get<std::string>());
            }
        }
    }
    auto try_txt = [&](const std::filesystem::path& p) {
        std::ifstream f{p};
        if (!f) {
            return;
        }
        std::string line;
        while (std::getline(f, line)) {
            add(line);
        }
    };
    try_txt(re4vr::data_path("re4_vr/re4_breakable_whitelist.txt"));
    try_txt(re4vr::data_path("re4_breakable_whitelist.txt"));
}

void RE4VRWhitelist::export_globals(sol::state& lua) {
    lua["__re4_wl_require_type"] = m_require_type;
    lua["__re4_coin_off_y"] = m_coin_off_y;
    lua["__re4_vase_off_y"] = m_vase_off_y;
    lua["__re4_snake_off_y"] = m_snake_off_y;
    lua["__re4_animal_off_y"] = m_animal_off_y;
    lua["__re4_mouse_off_y"] = m_mouse_off_y;
    lua["__re4_animal_center_max_d"] = m_animal_center_max_d;
    auto set_list = [&](const char* name, const std::vector<std::string>& v) {
        auto t = lua.create_table();
        for (size_t i = 0; i < v.size(); ++i) {
            t[i + 1] = v[i];
        }
        lua[name] = t;
    };
    set_list("__re4_breakable_name_prefixes", m_prefixes);
    set_list("__re4_breakable_name_only", m_name_only);
    set_list("__re4_breakable_name_contains", m_contains);
    set_list("__re4_breakable_contains_only", m_contains_only);

    lua["__re4_is_real_breakable_prop"] = [this](::REManagedObject* go) { return is_real_breakable_prop(go); };
    lua["__re4_breakable_yoff"] = [this](::REManagedObject* go) { return breakable_yoff(go); };
    lua["__re4_enemy_off_y"] = [this](::REManagedObject* ctx) { return enemy_off_y(ctx); };
    lua["__re4_animal_center"] = [this](::REManagedObject* anim, sol::object fx, sol::object fy, sol::object fz) {
        float x = fx.is<float>() ? fx.as<float>() : (fx.is<double>() ? (float)fx.as<double>() : 0.0f);
        float y = fy.is<float>() ? fy.as<float>() : (fy.is<double>() ? (float)fy.as<double>() : 0.0f);
        float z = fz.is<float>() ? fz.as<float>() : (fz.is<double>() ? (float)fz.as<double>() : 0.0f);
        float ox = x, oy = y, oz = z;
        animal_center(anim, x, y, z, ox, oy, oz);
        return std::make_tuple(ox, oy, oz);
    };
}

bool RE4VRWhitelist::is_real_breakable_prop(::REManagedObject* go) {
    if (!re4vr::obj_ok(go)) {
        return false;
    }
    refresh_types();
    auto ok = re4vr::safe([&]() -> bool {
        auto* tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr);
        bool has_type = false, has_name = false;
        for (int i = 0; i <= 4; ++i) {
            if (!tf) {
                break;
            }
            auto* g = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(tf, "get_GameObject"); }).value_or(nullptr);
            if (g) {
                if (!has_type) {
                    for (auto* td : m_tds) {
                        if (re4vr::safe([&] {
                                return sdk::call_object_func_easy<::REManagedObject*>(g, "getComponent(System.Type)", td);
                            }).value_or(nullptr)) {
                            has_type = true;
                            break;
                        }
                    }
                }
                const auto nm = re4vr::go_name((::REManagedObject*)g);
                if (!nm.empty()) {
                    for (const auto& pre : m_name_only) {
                        if (nm.size() >= pre.size() && nm.compare(0, pre.size(), pre) == 0) {
                            return true;
                        }
                    }
                    for (const auto& w : m_contains_only) {
                        if (!w.empty() && nm.find(w) != std::string::npos) {
                            return true;
                        }
                    }
                    if (!has_name) {
                        for (const auto& pre : m_prefixes) {
                            if (nm.size() >= pre.size() && nm.compare(0, pre.size(), pre) == 0) {
                                has_name = true;
                                break;
                            }
                        }
                    }
                    if (!has_name) {
                        for (const auto& w : m_contains) {
                            if (!w.empty() && nm.find(w) != std::string::npos) {
                                has_name = true;
                                break;
                            }
                        }
                    }
                }
            }
            tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(tf, "get_Parent"); }).value_or(nullptr);
        }
        const bool need_type = (re4vr::lua_not_false("__re4_wl_require_type")) && !m_tds.empty();
        if (!has_name) {
            return false;
        }
        return (!need_type) || has_type;
    });
    return ok.value_or(false);
}

float RE4VRWhitelist::breakable_yoff(::REManagedObject* go) {
    if (!re4vr::obj_ok(go)) {
        return 0.5f;
    }
    auto r = re4vr::safe([&]() -> float {
        auto* tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(go, "get_Transform"); }).value_or(nullptr);
        const std::string coin = "\xE9\x9D\x92\xE3\x82\xB3\xE3\x82\xA4\xE3\x83\xB3";
        const std::string vase = "\xE5\xA3\xBA";
        const std::string small = "\xE5\xB0\x8F";
        const std::string pre = "gm84_508_00_";
        for (int i = 0; i <= 3; ++i) {
            if (!tf) {
                break;
            }
            auto* g = re4vr::safe([&] { return sdk::call_object_func_easy<::REGameObject*>(tf, "get_GameObject"); }).value_or(nullptr);
            const auto nm = re4vr::go_name((::REManagedObject*)g);
            if (!nm.empty()) {
                if (nm.find(coin) != std::string::npos || (nm.size() >= pre.size() && nm.compare(0, pre.size(), pre) == 0)) {
                    return (float)re4vr::lua_number("__re4_coin_off_y").value_or(m_coin_off_y);
                }
                if (nm.find(vase) != std::string::npos && nm.find(small) != std::string::npos) {
                    return (float)re4vr::lua_number("__re4_vase_off_y").value_or(m_vase_off_y);
                }
            }
            tf = re4vr::safe([&] { return sdk::call_object_func_easy<::RETransform*>(tf, "get_Parent"); }).value_or(nullptr);
        }
        return 0.5f;
    });
    return r.value_or(0.5f);
}

float RE4VRWhitelist::enemy_off_y(::REManagedObject* ctx) {
    if (!re4vr::obj_ok(ctx)) {
        return 0.0f;
    }
    auto r = re4vr::safe([&]() -> float {
        auto* td = utility::re_managed_object::get_type_definition(ctx);
        if (!td) {
            return 0.0f;
        }
        const auto tn = std::string{td->get_full_name()};
        if (tn.find("Ch8g2z0") != std::string::npos) {
            return (float)re4vr::lua_number("__re4_snake_off_y").value_or(m_snake_off_y);
        }
        return 0.0f;
    });
    return r.value_or(0.0f);
}

void RE4VRWhitelist::animal_center(::REManagedObject* anim, float fx, float fy, float fz, float& ox, float& oy, float& oz) {
    ox = fx;
    oy = fy;
    oz = fz;
    if (!re4vr::obj_ok(anim)) {
        return;
    }
    auto got = re4vr::safe([&]() -> std::optional<Vector3f> {
        auto* mesh = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(anim, "get_Mesh"); }).value_or(nullptr);
        if (!mesh) {
            return std::nullopt;
        }
        auto* aabb = re4vr::safe([&] { return sdk::call_object_func_easy<::REManagedObject*>(mesh, "get_WorldAABB"); }).value_or(nullptr);
        if (!aabb) {
            return std::nullopt;
        }
        auto* mn = sdk::get_object_field<Vector4f>(aabb, "minpos");
        auto* mx = sdk::get_object_field<Vector4f>(aabb, "maxpos");
        if (!mn || !mx) {
            return std::nullopt;
        }
        if (mn->x > mx->x || mn->y > mx->y || mn->z > mx->z) {
            return std::nullopt;
        }
        return Vector3f{(mn->x + mx->x) * 0.5f, (mn->y + mx->y) * 0.5f, (mn->z + mx->z) * 0.5f};
    });
    if (!got || !*got) {
        return;
    }
    const auto p = **got;
    const float m = (float)re4vr::lua_number("__re4_animal_center_max_d").value_or(m_animal_center_max_d);
    const float dx = p.x - fx, dy = p.y - fy, dz = p.z - fz;
    if (dx * dx + dy * dy + dz * dz > m * m) {
        return;
    }
    ox = p.x;
    oy = p.y;
    oz = p.z;
}

std::optional<std::string> RE4VRWhitelist::on_initialize() {
    load_stems();
    refresh_types();
    return std::nullopt;
}

void RE4VRWhitelist::on_lua_state_created(sol::state& lua) {
    load_stems();
    refresh_types();
    export_globals(lua);
}
#endif
