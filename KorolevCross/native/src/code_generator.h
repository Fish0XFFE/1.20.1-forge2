#pragma once
#include "density_parser.h"
#include <string>
#include <sstream>
#include <iomanip>
#include <unordered_map>
#include <vector>

class CodeGenerator {
public:
    CodeGenerator();

    std::string generate(const NoiseSettings& settings);

    void setSeed(uint64_t seed) { m_seed = seed; }

private:
    std::string genNode(const DFNodePtr& node, int& counter, int depth);
    std::string genNoise(const DFNodePtr& node);
    std::string genSpline(const DFNodePtr& node, int& counter);
    std::string genShift(const DFNodePtr& node, int idx, int& counter);
    std::string genBinary(const DFNodePtr& node, const char* op, int& counter);
    std::string genUnary(const DFNodePtr& node, const char* fn, int& counter);
    std::string genClamp(const DFNodePtr& node, int& counter);
    std::string genRangeChoice(const DFNodePtr& node, int& counter);
    std::string genWeirdScaled(const DFNodePtr& node, int& counter);
    std::string genYClamped(const DFNodePtr& node);
    std::string genInterpolated(const DFNodePtr& node, int& counter);
    std::string genCache(const DFNodePtr& node, const std::string& cacheType, int& counter);

    std::string genNoiseCall(const NoiseParams& params, const std::string& x,
                             const std::string& y, const std::string& z);

    void emitNoiseInit(const NoiseParams& params);
    std::string noiseKeyFor(const NoiseParams& params);

    std::unordered_map<std::string, NoiseParams> m_noises;
    std::stringstream m_decls;
    std::stringstream m_defs;
    std::stringstream m_body;
    std::unordered_map<std::string, std::string> m_noiseVar;
    std::unordered_map<std::string, std::string> m_splineVar;
    uint64_t m_seed;
    int m_noiseIdCounter = 0;
    int m_cseCounter = 0;
    bool m_inSpline = false;
};