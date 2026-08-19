#include <cuda_runtime.h>
#include <math.h>

extern "C" {

__device__ double grad(int hash, double x, double y, double z) {
    int h = hash & 15;
    double u = h < 8 ? x : y;
    double v = h < 4 ? y : (h == 12 || h == 14 ? x : z);
    return ((h & 1) == 0 ? u : -u) + ((h & 2) == 0 ? v : -v);
}

__device__ double fade(double t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

__device__ double lerp(double a, double b, double t) {
    return a + t * (b - a);
}

__device__ int hash3D(int x, int y, int z, int seed) {
    int n = x + y * 31 + z * 79 + seed * 131;
    n = (n << 13) ^ n;
    return (n * (n * n * 15731 + 789221) + 1376312589) & 0x7fffffff;
}

__device__ double perlin3D(double x, double y, double z, int seed) {
    int ix = (int)floor(x) & 255;
    int iy = (int)floor(y) & 255;
    int iz = (int)floor(z) & 255;
    double fx = x - floor(x);
    double fy = y - floor(y);
    double fz = z - floor(z);
    double u = fade(fx), v = fade(fy), w = fade(fz);

    int p[512];
    for (int i = 0; i < 512; i++) {
        p[i] = hash3D(i, i * 7, i * 13, seed) % 256;
    }

    int aaa = p[p[p[ix] + iy] + iz];
    int aba = p[p[p[ix] + iy + 1] + iz];
    int aab = p[p[p[ix] + iy] + iz + 1];
    int abb = p[p[p[ix] + iy + 1] + iz + 1];
    int baa = p[p[p[ix + 1] + iy] + iz];
    int bba = p[p[p[ix + 1] + iy + 1] + iz];
    int bab = p[p[p[ix + 1] + iy] + iz + 1];
    int bbb = p[p[p[ix + 1] + iy + 1] + iz + 1];

    return lerp(
        lerp(lerp(grad(aaa, fx, fy, fz), grad(baa, fx-1, fy, fz), u),
             lerp(grad(aba, fx, fy-1, fz), grad(bba, fx-1, fy-1, fz), u), v),
        lerp(lerp(grad(aab, fx, fy, fz-1), grad(bab, fx-1, fy, fz-1), u),
             lerp(grad(abb, fx, fy-1, fz-1), grad(bbb, fx-1, fy-1, fz-1), u), v), w);
}

__device__ double fbm3D(double x, double y, double z, int seed, int octaves) {
    double value = 0.0, amplitude = 1.0, frequency = 1.0, maxVal = 0.0;
    for (int i = 0; i < octaves; i++) {
        value += amplitude * perlin3D(x * frequency, y * frequency, z * frequency, seed + i * 1000);
        maxVal += amplitude;
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    return value / maxVal;
}

__device__ double computeDensity(int x, int y, int z, int seed) {
    double px = (double)x * 0.005;
    double py = (double)y * 0.005;
    double pz = (double)z * 0.005;

    double continental = fbm3D(px * 0.5, py * 0.5, pz * 0.5, seed + 1, 4);
    double erosion = fbm3D(px * 1.5, py * 1.5, pz * 1.5, seed + 2, 4);
    double detail = fbm3D(px * 3.0, py * 3.0, pz * 3.0, seed + 3, 6);

    double density = continental * 0.6 + erosion * 0.3 + detail * 0.1;
    double yGradient = ((double)y - 64.0) * 0.025;
    density -= yGradient;

    if (y > 55 && y < 73) {
        double factor = (y - 55.0) / 18.0;
        density = density * (1.0 - factor) + (density - 0.5) * factor;
    }

    return density;
}

__device__ short getBlockForColumn(int x, int y, int z, int minY, int maxY, int seed) {
    int worldY = minY + y;

    if (worldY == minY) return 12;
    if (worldY == minY + 1 && (x + z) % 4 == 0) return 12;

    double density = computeDensity(x, worldY, z, seed);

    if (density > 0.0) {
        double surfaceDepth = 0.0;
        for (int dy = 1; dy <= 8; dy++) {
            double aboveDensity = computeDensity(x, worldY + dy, z, seed);
            if (aboveDensity <= 0.0) {
                surfaceDepth = (double)dy;
                break;
            }
        }

        if (surfaceDepth <= 4.0 && surfaceDepth > 0.0) {
            return (surfaceDepth == 1.0) ? 2 : 3;
        } else if (surfaceDepth <= 8.0 && surfaceDepth > 0.0) {
            return 3;
        } else {
            return 1;
        }
    } else {
        if (worldY <= 63 && worldY > 0) {
            return 8;
        }
        return 0;
    }
}

__global__ void generateTerrainKernel(int chunkX, int chunkZ, int minY, int maxY, int seed, short* output) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int z = blockIdx.y * blockDim.y + threadIdx.y;
    int y = blockIdx.z * blockDim.z + threadIdx.z;

    int sizeX = 16, sizeZ = 16, sizeY = maxY - minY + 1;

    if (x >= sizeX || z >= sizeZ || y >= sizeY) return;

    int worldX = chunkX * 16 + x;
    int worldZ = chunkZ * 16 + z;

    short block = getBlockForColumn(worldX, y, worldZ, minY, maxY, seed);

    int idx = (x * sizeZ + z) * sizeY + y;
    output[idx] = block;
}

} // extern "C"