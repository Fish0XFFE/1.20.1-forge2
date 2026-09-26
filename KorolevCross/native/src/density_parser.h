#pragma once
#include "noise_params.h"
#include "json.hpp"
#include <memory>
#include <string>
#include <vector>
#include <unordered_map>

struct DFNode;
using DFNodePtr = std::shared_ptr<DFNode>;

struct SplinePoint {
    double location;
    DFNodePtr value;
    DFNodePtr derivative;
};

struct DFNode {
    std::string type;
    double constant = 0.0;
    NoiseParams noise;
    DFNodePtr arg1;
    DFNodePtr arg2;
    DFNodePtr input;
    DFNodePtr argument;
    DFNodePtr alpha;
    DFNodePtr minArg;
    DFNodePtr maxArg;
    std::vector<SplinePoint> splinePoints;
    double minVal = 0.0;
    double maxVal = 1.0;
    double fromY = 0.0;
    double toY = 0.0;
    double fromValue = 0.0;
    double toValue = 0.0;
    double xzScale = 1.0;
    double yScale = 1.0;
    std::string noiseKey;
    bool isConstant = false;
};

struct NoiseSettings {
    std::string name;
    DFNodePtr finalDensity;
    DFNodePtr initialDensityWithoutJaggedness;
    DFNodePtr barrierNoise;
    DFNodePtr fluidLevelFloodednessNoise;
    DFNodePtr fluidLevelSpreadNoise;
    DFNodePtr lavaNoise;
    int seaLevel = 63;
    int minY = -64;
    int height = 384;
    bool aquifersEnabled = true;
    bool oreVeinsEnabled = true;
    bool useLegacyRandomSource = false;
    std::vector<std::string> noiseRouterNames;
    std::unordered_map<std::string, DFNodePtr> noiseRouter;
    std::unordered_map<std::string, NoiseParams> noiseDefinitions;
};

class DensityParser {
public:
    static void registerDensityFunction(const std::string& id, const nlohmann::json& j);
    static void registerNoise(const std::string& id, const nlohmann::json& j);
    static void clearCache();

    static NoiseSettings parseNoiseSettings(const nlohmann::json& noiseSettings,
                                            const nlohmann::json& noiseRouter,
                                            const std::string& name);
    static DFNodePtr parseNode(const nlohmann::json& j, int depth = 0);
    static NoiseParams parseNoiseParams(const nlohmann::json& j);

private:
    static DFNodePtr makeConstant(double value);
    static DFNodePtr parseNoise(const nlohmann::json& j);
    static DFNodePtr parseSpline(const nlohmann::json& j);
    static DFNodePtr parseYClampedGradient(const nlohmann::json& j);
    static DFNodePtr parseConstant(const nlohmann::json& j);
    static DFNodePtr parseShift(const nlohmann::json& j, const std::string& type);
    static DFNodePtr parseBinary(const nlohmann::json& j, const std::string& type);
    static DFNodePtr parseUnary(const nlohmann::json& j, const std::string& type);
    static DFNodePtr parseClamp(const nlohmann::json& j);
    static DFNodePtr parseRangeChoice(const nlohmann::json& j);
    static DFNodePtr parseWeirdScaledSampler(const nlohmann::json& j);
    static DFNodePtr resolveReference(const std::string& ref, int depth);
    static NoiseParams resolveNoiseParams(const nlohmann::json& j);
};