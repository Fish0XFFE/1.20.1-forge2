#include "density_parser.h"
#include <stdexcept>
#include <cmath>
#include <mutex>
#include <cstdio>

static std::unordered_map<std::string, nlohmann::json> g_densityFunctionCache;
static std::unordered_map<std::string, nlohmann::json> g_noiseCache;
static std::mutex g_cacheMutex;

void DensityParser::registerDensityFunction(const std::string& id, const nlohmann::json& j) {
    std::lock_guard<std::mutex> lock(g_cacheMutex);
    std::string key = id;
    if (key.rfind("minecraft:", 0) == 0) key = key.substr(10);
    g_densityFunctionCache[key] = j;
}

void DensityParser::registerNoise(const std::string& id, const nlohmann::json& j) {
    std::lock_guard<std::mutex> lock(g_cacheMutex);
    std::string key = id;
    if (key.rfind("minecraft:", 0) == 0) key = key.substr(10);
    g_noiseCache[key] = j;
}

void DensityParser::clearCache() {
    std::lock_guard<std::mutex> lock(g_cacheMutex);
    g_densityFunctionCache.clear();
    g_noiseCache.clear();
}

DFNodePtr DensityParser::makeConstant(double value) {
    auto n = std::make_shared<DFNode>();
    n->type = "constant";
    n->constant = value;
    n->isConstant = true;
    return n;
}

DFNodePtr DensityParser::resolveReference(const std::string& ref, int depth) {
    std::string key = ref;
    if (key.rfind("minecraft:", 0) == 0) key = key.substr(10);

    nlohmann::json dfCopy;
    nlohmann::json noiseCopy;
    bool foundDF = false;
    bool foundNoise = false;

    {
        std::lock_guard<std::mutex> lock(g_cacheMutex);
        auto it = g_densityFunctionCache.find(key);
        if (it != g_densityFunctionCache.end()) {
            dfCopy = it->second;
            foundDF = true;
        } else {
            auto nit = g_noiseCache.find(key);
            if (nit != g_noiseCache.end()) {
                noiseCopy = nit->second;
                foundNoise = true;
            }
        }
    }

    if (foundDF) {
        return parseNode(dfCopy, depth + 1);
    }
    if (foundNoise) {
        auto n = std::make_shared<DFNode>();
        n->type = "noise";
        n->noise = parseNoiseParams(noiseCopy);
        n->noiseKey = key;
        return n;
    }

    fprintf(stderr, "[KorolevCross] unresolved reference: %s, using constant 0\n", ref.c_str());
    return makeConstant(0.0);
}

NoiseParams DensityParser::resolveNoiseParams(const nlohmann::json& j) {
    if (j.is_string()) {
        std::string key = j.get<std::string>();
        if (key.rfind("minecraft:", 0) == 0) key = key.substr(10);
        std::lock_guard<std::mutex> lock(g_cacheMutex);
        auto it = g_noiseCache.find(key);
        if (it != g_noiseCache.end()) {
            return parseNoiseParams(it->second);
        }
        fprintf(stderr, "[KorolevCross] unresolved noise reference: %s\n", key.c_str());
        NoiseParams p;
        p.firstOctave = -7;
        p.amplitudes = {1.0};
        p.seed = 0;
        return p;
    }
    return parseNoiseParams(j);
}

DFNodePtr DensityParser::parseNode(const nlohmann::json& j, int depth) {
    if (depth > 128) return makeConstant(0.0);

    if (j.is_number()) {
        return makeConstant(j.get<double>());
    }

    if (j.is_string()) {
        return resolveReference(j.get<std::string>(), depth);
    }

    if (j.is_boolean()) {
        return makeConstant(j.get<bool>() ? 1.0 : 0.0);
    }

    if (j.is_null()) {
        return makeConstant(0.0);
    }

    if (j.is_array()) {
        return makeConstant(0.0);
    }

    if (!j.is_object()) {
        return makeConstant(0.0);
    }

    if (!j.contains("type")) {
        if (j.size() == 1) {
            auto it = j.begin();
            return parseNode(it.value(), depth + 1);
        }
        if (j.empty()) {
            return makeConstant(0.0);
        }
        fprintf(stderr, "[KorolevCross] object without type field, using constant 0\n");
        return makeConstant(0.0);
    }

    if (!j["type"].is_string()) {
        return makeConstant(0.0);
    }

    std::string type = j["type"].get<std::string>();

    if (type == "minecraft:noise" || type == "noise") return parseNoise(j);
    if (type == "minecraft:spline" || type == "spline") return parseSpline(j);
    if (type == "minecraft:y_clamped_gradient" || type == "y_clamped_gradient") return parseYClampedGradient(j);
    if (type == "minecraft:constant" || type == "constant") return parseConstant(j);
    if (type == "minecraft:shift_a" || type == "shift_a") return parseShift(j, "shift_a");
    if (type == "minecraft:shift_b" || type == "shift_b") return parseShift(j, "shift_b");
    if (type == "minecraft:shift" || type == "shift") return parseShift(j, "shift");
    if (type == "minecraft:add" || type == "add") return parseBinary(j, "add");
    if (type == "minecraft:mul" || type == "mul") return parseBinary(j, "mul");
    if (type == "minecraft:min" || type == "min") return parseBinary(j, "min");
    if (type == "minecraft:max" || type == "max") return parseBinary(j, "max");
    if (type == "minecraft:clamp" || type == "clamp") return parseClamp(j);
    if (type == "minecraft:range_choice" || type == "range_choice") return parseRangeChoice(j);
    if (type == "minecraft:weird_scaled_sampler" || type == "weird_scaled_sampler") return parseWeirdScaledSampler(j);

    if (type == "minecraft:shifted_noise" || type == "shifted_noise") {
        auto n = std::make_shared<DFNode>();
        n->type = "shifted_noise";
        n->noise = resolveNoiseParams(j.at("noise"));

        auto parseShiftField = [&](const std::string& key) -> DFNodePtr {
            if (!j.contains(key)) return nullptr;
            const auto& v = j[key];
            if (v.is_string()) {
                return resolveReference(v.get<std::string>(), depth + 1);
            } else if (v.is_number()) {
                return makeConstant(v.get<double>());
            } else if (v.is_object()) {
                return parseNode(v, depth + 1);
            }
            return nullptr;
        };

        n->arg1 = parseShiftField("shift_x");
        n->arg2 = parseShiftField("shift_y");
        n->input = parseShiftField("shift_z");

        n->xzScale = j.value("xz_scale", 1.0);
        n->yScale = j.value("y_scale", 1.0);
        return n;
    }

    if (type == "minecraft:blend_offset" || type == "blend_offset") return makeConstant(0.0);
    if (type == "minecraft:blend_alpha" || type == "blend_alpha") return makeConstant(1.0);
    if (type == "minecraft:blend_density" || type == "blend_density") {
        auto n = std::make_shared<DFNode>();
        n->type = "blend_density";
        n->argument = parseNode(j.at("argument"), depth + 1);
        return n;
    }

    if (type == "minecraft:interpolated" || type == "interpolated") {
        auto n = std::make_shared<DFNode>();
        n->type = "interpolated";
        n->argument = parseNode(j.at("argument"), depth + 1);
        return n;
    }
    if (type == "minecraft:flat_cache" || type == "flat_cache") {
        auto n = std::make_shared<DFNode>();
        n->type = "flat_cache";
        n->argument = parseNode(j.at("argument"), depth + 1);
        return n;
    }
    if (type == "minecraft:cache_2d" || type == "cache_2d") {
        auto n = std::make_shared<DFNode>();
        n->type = "cache_2d";
        n->argument = parseNode(j.at("argument"), depth + 1);
        return n;
    }
    if (type == "minecraft:cache_once" || type == "cache_once") {
        auto n = std::make_shared<DFNode>();
        n->type = "cache_once";
        n->argument = parseNode(j.at("argument"), depth + 1);
        return n;
    }
    if (type == "minecraft:cache_all_in_cell" || type == "cache_all_in_cell") {
        auto n = std::make_shared<DFNode>();
        n->type = "cache_all_in_cell";
        n->argument = parseNode(j.at("argument"), depth + 1);
        return n;
    }
    if (type == "minecraft:old_blended_noise" || type == "old_blended_noise") {
        auto n = std::make_shared<DFNode>();
        n->type = "old_blended_noise";
        n->xzScale = j.value("xz_scale", 0.25);
        n->yScale = j.value("y_scale", 0.125);
        return n;
    }
    if (type == "minecraft:end_islands" || type == "end_islands") {
        auto n = std::make_shared<DFNode>();
        n->type = "end_islands";
        return n;
    }
    if (type == "minecraft:abs" || type == "abs") return parseUnary(j, "abs");
    if (type == "minecraft:square" || type == "square") return parseUnary(j, "square");
    if (type == "minecraft:cube" || type == "cube") return parseUnary(j, "cube");
    if (type == "minecraft:half_negative" || type == "half_negative") return parseUnary(j, "half_negative");
    if (type == "minecraft:quarter_negative" || type == "quarter_negative") return parseUnary(j, "quarter_negative");
    if (type == "minecraft:squeeze" || type == "squeeze") return parseUnary(j, "squeeze");
    if (type == "minecraft:invert" || type == "invert") return parseUnary(j, "invert");

    fprintf(stderr, "[KorolevCross] unknown density function type: %s, using constant 0\n", type.c_str());
    return makeConstant(0.0);
}

DFNodePtr DensityParser::parseConstant(const nlohmann::json& j) {
    auto n = std::make_shared<DFNode>();
    n->type = "constant";
    n->constant = j.at("value").get<double>();
    n->isConstant = true;
    return n;
}

DFNodePtr DensityParser::parseNoise(const nlohmann::json& j) {
    auto n = std::make_shared<DFNode>();
    n->type = "noise";
    n->noise = resolveNoiseParams(j.at("noise"));
    n->xzScale = j.value("xz_scale", 1.0);
    n->yScale = j.value("y_scale", 1.0);
    return n;
}

NoiseParams DensityParser::parseNoiseParams(const nlohmann::json& j) {
    NoiseParams p;
    p.firstOctave = j.value("firstOctave", -7);
    p.amplitudes.clear();
    if (j.contains("amplitudes") && j["amplitudes"].is_array()) {
        for (auto& a : j["amplitudes"]) p.amplitudes.push_back(a.get<double>());
    }
    if (p.amplitudes.empty()) {
        p.amplitudes.push_back(1.0);
    }
    p.seed = 0;
    return p;
}

DFNodePtr DensityParser::parseSpline(const nlohmann::json& j) {
    auto n = std::make_shared<DFNode>();
    n->type = "spline";
    auto& sp = j.at("spline");
    if (sp.contains("coordinate")) n->input = parseNode(sp.at("coordinate"), 1);
    if (sp.contains("points") && sp["points"].is_array()) {
        for (auto& pt : sp["points"]) {
            SplinePoint point;
            point.location = pt.at("location").get<double>();
            point.value = parseNode(pt.at("value"), 1);
            if (pt.contains("derivative")) point.derivative = parseNode(pt.at("derivative"), 1);
            n->splinePoints.push_back(point);
        }
    }
    return n;
}

DFNodePtr DensityParser::parseYClampedGradient(const nlohmann::json& j) {
    auto n = std::make_shared<DFNode>();
    n->type = "y_clamped_gradient";
    n->fromY = j.at("from_y").get<double>();
    n->toY = j.at("to_y").get<double>();
    n->fromValue = j.at("from_value").get<double>();
    n->toValue = j.at("to_value").get<double>();
    return n;
}

DFNodePtr DensityParser::parseShift(const nlohmann::json& j, const std::string& type) {
    auto n = std::make_shared<DFNode>();
    n->type = type;
    if (j.contains("argument")) n->argument = parseNode(j.at("argument"), 1);
    return n;
}

DFNodePtr DensityParser::parseBinary(const nlohmann::json& j, const std::string& type) {
    auto n = std::make_shared<DFNode>();
    n->type = type;
    if (j.contains("argument1")) n->arg1 = parseNode(j["argument1"], 1);
    if (j.contains("argument2")) n->arg2 = parseNode(j["argument2"], 1);
    if (j.contains("left")) n->arg1 = parseNode(j["left"], 1);
    if (j.contains("right")) n->arg2 = parseNode(j["right"], 1);
    if (!n->arg1) n->arg1 = makeConstant(0.0);
    if (!n->arg2) n->arg2 = makeConstant(0.0);
    return n;
}

DFNodePtr DensityParser::parseUnary(const nlohmann::json& j, const std::string& type) {
    auto n = std::make_shared<DFNode>();
    n->type = type;
    if (j.contains("argument")) {
        n->argument = parseNode(j.at("argument"), 1);
    } else {
        n->argument = makeConstant(0.0);
    }
    return n;
}

DFNodePtr DensityParser::parseClamp(const nlohmann::json& j) {
    auto n = std::make_shared<DFNode>();
    n->type = "clamp";
    n->input = j.contains("input") ? parseNode(j.at("input"), 1) : makeConstant(0.0);
    n->minVal = j.value("min", -1.0);
    n->maxVal = j.value("max", 1.0);
    return n;
}

DFNodePtr DensityParser::parseRangeChoice(const nlohmann::json& j) {
    auto n = std::make_shared<DFNode>();
    n->type = "range_choice";
    n->input = j.contains("input") ? parseNode(j.at("input"), 1) : makeConstant(0.0);
    n->minVal = j.value("min_inclusive", -1.0);
    n->maxVal = j.value("max_exclusive", 1.0);
    n->arg1 = j.contains("when_in_range") ? parseNode(j.at("when_in_range"), 1) : makeConstant(0.0);
    n->arg2 = j.contains("when_out_of_range") ? parseNode(j.at("when_out_of_range"), 1) : makeConstant(0.0);
    return n;
}

DFNodePtr DensityParser::parseWeirdScaledSampler(const nlohmann::json& j) {
    auto n = std::make_shared<DFNode>();
    n->type = "weird_scaled_sampler";
    n->input = j.contains("input") ? parseNode(j.at("input"), 1) : makeConstant(0.0);
    n->noise = resolveNoiseParams(j.at("noise"));
    n->noiseKey = j.value("rarity_value_mapper", "type_1");
    return n;
}

NoiseSettings DensityParser::parseNoiseSettings(
    const nlohmann::json& ns,
    const nlohmann::json& router,
    const std::string& name) {

    NoiseSettings settings;
    settings.name = name;

    if (ns.contains("sea_level")) settings.seaLevel = ns["sea_level"].get<int>();
    if (ns.contains("noise") && ns["noise"].is_object()) {
        auto& noise = ns["noise"];
        settings.minY = noise.value("min_y", -64);
        settings.height = noise.value("height", 384);
    }
    if (ns.contains("aquifers_enabled")) settings.aquifersEnabled = ns["aquifers_enabled"].get<bool>();
    if (ns.contains("ore_veins_enabled")) settings.oreVeinsEnabled = ns["ore_veins_enabled"].get<bool>();
    if (ns.contains("legacy_random_source")) settings.useLegacyRandomSource = ns["legacy_random_source"].get<bool>();

    if (router.contains("final_density"))
        settings.finalDensity = parseNode(router.at("final_density"));
    if (router.contains("initial_density_without_jaggedness"))
        settings.initialDensityWithoutJaggedness = parseNode(router.at("initial_density_without_jaggedness"));
    if (router.contains("barrier"))
        settings.barrierNoise = parseNode(router.at("barrier"));
    if (router.contains("fluid_level_floodedness"))
        settings.fluidLevelFloodednessNoise = parseNode(router.at("fluid_level_floodedness"));
    if (router.contains("fluid_level_spread"))
        settings.fluidLevelSpreadNoise = parseNode(router.at("fluid_level_spread"));
    if (router.contains("lava"))
        settings.lavaNoise = parseNode(router.at("lava"));

    static const char* routerKeys[] = {
        "temperature", "vegetation", "continents", "erosion", "depth", "ridges",
        "initial_density_without_jaggedness", "final_density", "barrier",
        "fluid_level_floodedness", "fluid_level_spread", "lava",
        "vein_toggle", "vein_ridged", "vein_gap"
    };
    for (const char* key : routerKeys) {
        if (router.contains(key)) {
            settings.noiseRouterNames.push_back(key);
            settings.noiseRouter[key] = parseNode(router.at(key));
        }
    }

    return settings;
}