#define NOMINMAX
#include "RE4VRStatics.hpp"

#if defined(RE4)
#include <sdk/RETypeDB.hpp>
#include "RE4VRShared.hpp"

std::shared_ptr<RE4VRStatics>& RE4VRStatics::get() {
    static auto inst = std::make_shared<RE4VRStatics>();
    return inst;
}

void RE4VRStatics::on_lua_state_created(sol::state& lua) {
    auto t = lua.create_table();
    t["generate"] = [&lua](const std::string& typename_, sol::optional<bool> double_ended) {
        auto out = lua.create_table();
        auto* td = sdk::find_type_definition(typename_);
        if (!td) {
            return out;
        }
        const bool de = double_ended.value_or(false);
        for (auto* field : td->get_fields()) {
            if (!field || !field->is_static()) {
                continue;
            }
            const auto name = std::string{field->get_name()};
            const auto value = field->get_data<int32_t>(nullptr);
            out[name] = value;
            if (de) {
                out[value] = name;
            }
        }
        return out;
    };
    lua["package"]["loaded"]["utility/Statics"] = t;
}
#endif
