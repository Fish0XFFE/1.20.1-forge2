#pragma once
#include <string>
#include <vector>
#include <cstdint>

struct NoiseParams {
    int firstOctave;
    std::vector<double> amplitudes;
    uint64_t seed;
    std::string name;
};

struct NormalNoiseConfig {
    std::string id;
    NoiseParams params;
    double xzScale;
    double yScale;
};

inline uint64_t mixSeed(uint64_t seed, const std::string& name) {
    uint64_t h = seed;
    for (char c : name) {
        h = h * 6364136223846793005ULL + (uint64_t)c;
        h ^= h >> 33;
    }
    h *= 0xff51afd7ed558ccdULL;
    h ^= h >> 33;
    h *= 0xc4ceb9fe1a85ec53ULL;
    h ^= h >> 33;
    return h;
}

inline int hashString(const std::string& s) {
    int h = 0;
    for (char c : s) {
        h = 31 * h + (int)(unsigned char)c;
    }
    return h;
}