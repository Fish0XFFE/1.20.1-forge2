#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <jni.h>
#include <windows.h>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#define KOROLEV_MAGIC 0x4B564431

struct KvLevel {
    int present;
    unsigned char perm[256];
    double xo, yo, zo;
};

struct KvPerlin {
    int firstOctave;
    int levelCount;
    double inputFactor;
    double valueFactor;
    const double* amps;
    const KvLevel* levels;
};

struct KvNoise {
    int kind;
    double valueFactor;
    const KvPerlin* pa;
    const KvPerlin* pb;
    const KvPerlin* pc;
    const int* perm;
    double b0, b1, b2, b3, b4;
};

struct KvNode {
    int type;
    int i0, i1, i2, i3;
    double d0, d1, d2, d3;
};

struct KvSpline {
    int nPoints;
    int coordNode;
    const float* loc;
    const float* der;
    const int* vals;
};

struct KvProgram {
    const KvNode* nodes;
    const KvSpline* splines;
    const KvNoise* noises;
    int nodeCount;
    int splineCount;
    int noiseCount;
    int flatCount;
    int root;
};

struct KvCtx {
    const double* flats;
    int flatSize;
    int i;
    int j;
    int bx, by, bz;
};

template<class T> struct TR;

template<> struct TR<double> {
    __device__ static __forceinline__ double from(double v) { return v; }

    __device__ static __forceinline__ double to(double v) { return v; }
};

template<> struct TR<float> {
    __device__ static __forceinline__ float from(double v) { return (float) v; }

    __device__ static __forceinline__ double to(float v) { return (double) v; }
};

template<> struct TR<__half> {
    __device__ static __forceinline__ __half from(double v) { return __float2half((float) v); }

    __device__ static __forceinline__ double to(__half v) { return (double) __half2float(v); }
};

template<class T> __device__ __forceinline__ T tc(double v) { return TR<T>::from(v); }

template<class T> __device__ __forceinline__ double td(T v) { return TR<T>::to(v); }

__device__ __forceinline__ int kvFloor(double d) {
    int i = (int) d;
    return d < (double) i ? i - 1 : i;
}

__device__ __forceinline__ long long kvLFloor(double d) {
    long long i = (long long) d;
    return d < (double) i ? i - 1 : i;
}

__device__ __forceinline__ double kvWrap(double v) {
    return v - (double) kvLFloor(v / 3.3554432E7 + 0.5) * 3.3554432E7;
}

__device__ __constant__ int KV_GRAD[16][3] = {
        {1,  1,  0},
        {-1, 1,  0},
        {1,  -1, 0},
        {-1, -1, 0},
        {1,  0,  1},
        {-1, 0,  1},
        {1,  0,  -1},
        {-1, 0,  -1},
        {0,  1,  1},
        {0,  -1, 1},
        {0,  1,  -1},
        {0,  -1, -1},
        {1,  1,  0},
        {0,  -1, 1},
        {-1, 1,  0},
        {0,  -1, -1}
};

template<class T> __device__ __forceinline__ T kvLerp(T t, T a, T b) {
    return a + t * (b - a);
}

template<class T> __device__ __forceinline__ T kvSmoothstep(T t) {
    return t * t * t * (t * (t * tc<T>(6.0) - tc<T>(15.0)) + tc<T>(10.0));
}

template<class T> __device__ __forceinline__ T kvLerp2(T x, T y, T v00, T v10, T v01, T v11) {
    return kvLerp<T>(y, kvLerp<T>(x, v00, v10), kvLerp<T>(x, v01, v11));
}

template<class T> __device__ __forceinline__ T kvLerp3(T x, T y, T z, T v000, T v100, T v010, T v110, T v001, T v101, T v011, T v111) {
    return kvLerp<T>(z, kvLerp2<T>(x, y, v000, v100, v010, v110), kvLerp2<T>(x, y, v001, v101, v011, v111));
}

__device__ __forceinline__ int kvPerm(const KvLevel& l, int i) {
    return (int) l.perm[i & 255];
}

template<class T> __device__ __forceinline__ T kvGradDot(int idx, T x, T y, T z) {
    const int* g = KV_GRAD[idx & 15];
    return tc<T>((double) g[0]) * x + tc<T>((double) g[1]) * y + tc<T>((double) g[2]) * z;
}

template<class T> __device__ T kvImprovedNoise(const KvLevel& l, double x, double y, double z, double yScale, double yFrac) {
    double d0 = x + l.xo;
    double d1 = y + l.yo;
    double d2 = z + l.zo;
    int i = kvFloor(d0);
    int j = kvFloor(d1);
    int k = kvFloor(d2);
    double f0 = d0 - (double) i;
    double f1 = d1 - (double) j;
    double f2 = d2 - (double) k;
    double sub;
    if (yScale != 0.0) {
        double pick;
        if (yFrac >= 0.0 && yFrac < f1) {
            pick = yFrac;
        } else {
            pick = f1;
        }
        sub = (double) kvFloor(pick / yScale + 1.0E-7f) * yScale;
    } else {
        sub = 0.0;
    }
    T fx = tc<T>(f0);
    T fy = tc<T>(f1 - sub);
    T fz = tc<T>(f2);
    T yOrig = tc<T>(f1);

    int i0 = kvPerm(l, i);
    int j0 = kvPerm(l, i + 1);
    int k0 = kvPerm(l, i0 + j);
    int m0 = kvPerm(l, i0 + j + 1);
    int i1 = kvPerm(l, j0 + j);
    int j1 = kvPerm(l, j0 + j + 1);

    T d0v = kvGradDot<T>(kvPerm(l, k0 + k), fx, fy, fz);
    T d1v = kvGradDot<T>(kvPerm(l, i1 + k), fx - tc<T>(1.0), fy, fz);
    T d2v = kvGradDot<T>(kvPerm(l, m0 + k), fx, fy - tc<T>(1.0), fz);
    T d3v = kvGradDot<T>(kvPerm(l, j1 + k), fx - tc<T>(1.0), fy - tc<T>(1.0), fz);
    T d4v = kvGradDot<T>(kvPerm(l, k0 + k + 1), fx, fy, fz - tc<T>(1.0));
    T d5v = kvGradDot<T>(kvPerm(l, i1 + k + 1), fx - tc<T>(1.0), fy, fz - tc<T>(1.0));
    T d6v = kvGradDot<T>(kvPerm(l, m0 + k + 1), fx, fy - tc<T>(1.0), fz - tc<T>(1.0));
    T d7v = kvGradDot<T>(kvPerm(l, j1 + k + 1), fx - tc<T>(1.0), fy - tc<T>(1.0), fz - tc<T>(1.0));

    return kvLerp3<T>(kvSmoothstep<T>(fx), kvSmoothstep<T>(yOrig), kvSmoothstep<T>(fz),
                      d0v, d1v, d2v, d3v, d4v, d5v, d6v, d7v);
}

template<class T> __device__ T kvPerlin(const KvPerlin& p, double x, double y, double z) {
    T acc = tc<T>(0.0);
    double input = p.inputFactor;
    double value = p.valueFactor;
    for (int i = 0; i < p.levelCount; i++) {
        const KvLevel& l = p.levels[i];
        if (l.present != 0) {
            T n = kvImprovedNoise<T>(l, kvWrap(x * input), kvWrap(y * input), kvWrap(z * input), 0.0, 0.0);
            acc = acc + tc<T>(p.amps[i]) * n * tc<T>(value);
        }
        input *= 2.0;
        value /= 2.0;
    }
    return acc;
}

template<class T> __device__ T kvNormalNoise(const KvNoise& n, double x, double y, double z) {
    T a = kvPerlin<T>(*n.pa, x, y, z);
    T b = kvPerlin<T>(*n.pb, x * 1.0181268882175227, y * 1.0181268882175227, z * 1.0181268882175227);
    return (a + b) * tc<T>(n.valueFactor);
}

template<class T> __device__ T kvBlendedNoise(const KvNoise& n, int bx, int by, int bz) {
    double xzMultiplier = 684.412 * n.b0;
    double yMultiplier = 684.412 * n.b1;
    double xzFactor = n.b2;
    double yFactor = n.b3;
    double d0 = (double) bx * xzMultiplier;
    double d1 = (double) by * yMultiplier;
    double d2 = (double) bz * xzMultiplier;
    double d3 = d0 / xzFactor;
    double d4 = d1 / yFactor;
    double d5 = d2 / xzFactor;
    double d6 = yMultiplier * n.b4;
    double d7 = d6 / yFactor;
    double d8 = 0.0;
    double d9 = 0.0;
    double d10 = 0.0;
    double d11 = 1.0;

    for (int i = 0; i < 8; i++) {
        int idx = n.pc->levelCount - 1 - i;
        if (idx >= 0) {
            const KvLevel& l = n.pc->levels[idx];
            if (l.present != 0) {
                T v = kvImprovedNoise<T>(l, kvWrap(d3 * d11), kvWrap(d4 * d11), kvWrap(d5 * d11), d7 * d11, d4 * d11);
                d10 += td<T>(v) / d11;
            }
        }
        d11 /= 2.0;
    }

    double d16 = (d10 / 10.0 + 1.0) / 2.0;
    bool flag1 = d16 >= 1.0;
    bool flag2 = d16 <= 0.0;
    d11 = 1.0;

    for (int j = 0; j < 16; j++) {
        double d12 = kvWrap(d0 * d11);
        double d13 = kvWrap(d1 * d11);
        double d14 = kvWrap(d2 * d11);
        double d15 = d6 * d11;
        if (!flag1) {
            int idx = n.pa->levelCount - 1 - j;
            if (idx >= 0) {
                const KvLevel& l = n.pa->levels[idx];
                if (l.present != 0) {
                    d8 += td<T>(kvImprovedNoise<T>(l, d12, d13, d14, d15, d1 * d11)) / d11;
                }
            }
        }
        if (!flag2) {
            int idx = n.pb->levelCount - 1 - j;
            if (idx >= 0) {
                const KvLevel& l = n.pb->levels[idx];
                if (l.present != 0) {
                    d9 += td<T>(kvImprovedNoise<T>(l, d12, d13, d14, d15, d1 * d11)) / d11;
                }
            }
        }
        d11 /= 2.0;
    }

    double lo = d8 / 512.0;
    double hi = d9 / 512.0;
    double mixed;
    if (d16 < 0.0) {
        mixed = lo;
    } else if (d16 > 1.0) {
        mixed = hi;
    } else {
        mixed = lo + d16 * (hi - lo);
    }
    return tc<T>(mixed / 128.0);
}

__device__ int kvBinarySearch(const float* loc, int len, float f) {
    int mn = 0;
    int i = len - mn;
    while (i > 0) {
        int j = i / 2;
        int k = mn + j;
        if (f < loc[k]) {
            i = j;
        } else {
            mn = k + 1;
            i -= j + 1;
        }
    }
    return mn;
}

__device__ int kvBadKind = -1;
__device__ int kvBadValue = -1;

template<class T> __device__ T kvEval(const KvProgram& pg, const KvCtx& c, int idx);

__device__ __forceinline__ bool kvGuard(const KvProgram& pg, int kind, int value, int limit) {
    if (value < 0 || value >= limit) {
        kvBadKind = kind;
        kvBadValue = value;
        return false;
    }
    return true;
}

template<class T> __device__ float kvSplineValue(const KvProgram& pg, const KvCtx& c, int node) {
    return (float) td<T>(kvEval<T>(pg, c, node));
}

__device__ __forceinline__ float kvLinearExtend(float v, float loc, float val, float der) {
    return der == 0.0f ? val : val + der * (v - loc);
}

template<class T> __device__ float kvSpline(const KvProgram& pg, const KvCtx& c, int si) {
    const KvSpline& s = pg.splines[si];
    float f = kvSplineValue<T>(pg, c, s.coordNode);
    int i = kvBinarySearch(s.loc, s.nPoints, f) - 1;
    int j = s.nPoints - 1;
    if (i < 0) {
        return kvLinearExtend(f, s.loc[0], kvSplineValue<T>(pg, c, s.vals[0]), s.der[0]);
    }
    if (i == j) {
        return kvLinearExtend(f, s.loc[j], kvSplineValue<T>(pg, c, s.vals[j]), s.der[j]);
    }
    float f1 = s.loc[i];
    float f2 = s.loc[i + 1];
    float f3 = (f - f1) / (f2 - f1);
    float f4 = s.der[i];
    float f5 = s.der[i + 1];
    float f6 = kvSplineValue<T>(pg, c, s.vals[i]);
    float f7 = kvSplineValue<T>(pg, c, s.vals[i + 1]);
    float f8 = f4 * (f2 - f1) - (f7 - f6);
    float f9 = -f5 * (f2 - f1) + (f7 - f6);
    return (f6 + f3 * (f7 - f6)) + f3 * (1.0f - f3) * (f8 + f3 * (f9 - f8));
}

__device__ __forceinline__ double kvRarity(int kind, double v) {
    if (kind == 1) {
        if (v < -0.5) return 0.75;
        if (v < 0.0) return 1.0;
        return v < 0.5 ? 1.5 : 2.0;
    }
    if (v < -0.75) return 0.5;
    if (v < -0.5) return 0.75;
    if (v < 0.5) return 1.0;
    return v < 0.75 ? 2.0 : 3.0;
}

__device__ __forceinline__ float kvSqrtF(float v) {
    return (float) sqrt((double) v);
}

__device__ __forceinline__ float kvAbsF(float v) {
    return v < 0.0f ? -v : v;
}

__device__ __forceinline__ float kvClampF(float v, float lo, float hi) {
    return v < lo ? lo : fminf(v, hi);
}

__device__ __forceinline__ double kvSimplexCorner(int g, double x, double y, double z) {
    double t = 0.5 - x * x - y * y - z * z;
    if (t < 0.0) return 0.0;
    t *= t;
    return t * t * kvGradDot(g, x, y, z);
}

__device__ __forceinline__ double kvSimplex2D(const KvNoise& n, double x, double y) {
    const double f2 = 0.3660254037844386;
    const double g2 = 0.21132486540518713;
    double s = (x + y) * f2;
    int i = kvFloor(x + s);
    int j = kvFloor(y + s);
    double t = (double) (i + j) * g2;
    double x0 = x - ((double) i - t);
    double y0 = y - ((double) j - t);
    int a;
    int b;
    if (x0 > y0) {
        a = 1;
        b = 0;
    } else {
        a = 0;
        b = 1;
    }
    double x1 = x0 - (double) a + g2;
    double y1 = y0 - (double) b + g2;
    double x2 = x0 - 1.0 + 2.0 * g2;
    double y2 = y0 - 1.0 + 2.0 * g2;
    int ii = i & 255;
    int jj = j & 255;
    int g0 = n.perm[(ii + n.perm[jj]) & 255] % 12;
    int g1 = n.perm[(ii + a + n.perm[(jj + b) & 255]) & 255] % 12;
    int g3 = n.perm[(ii + 1 + n.perm[(jj + 1) & 255]) & 255] % 12;
    double d0 = kvSimplexCorner(g0, x0, y0, 0.0);
    double d1 = kvSimplexCorner(g1, x1, y1, 0.0);
    double d2 = kvSimplexCorner(g3, x2, y2, 0.0);
    return 70.0 * (d0 + d1 + d2);
}

__device__ __forceinline__ float kvEndIslandHeight(const KvNoise& n, int px, int pz) {
    int i = px / 2;
    int j = pz / 2;
    int k = px % 2;
    int l = pz % 2;
    float f = 100.0f - kvSqrtF((float) (px * px + pz * pz)) * 8.0f;
    f = kvClampF(f, -100.0f, 80.0f);
    for (int i1 = -12; i1 <= 12; i1++) {
        for (int j1 = -12; j1 <= 12; j1++) {
            long long k1 = (long long) i + i1;
            long long l1 = (long long) j + j1;
            if (k1 * k1 + l1 * l1 > 4096LL && kvSimplex2D(n, (double) k1, (double) l1) < -0.9) {
                float f1 = fmodf(kvAbsF((float) k1) * 3439.0f + kvAbsF((float) l1) * 147.0f, 13.0f) + 9.0f;
                float f2 = (float) (k - i1 * 2);
                float f3 = (float) (l - j1 * 2);
                float f4 = 100.0f - kvSqrtF(f2 * f2 + f3 * f3) * f1;
                f4 = kvClampF(f4, -100.0f, 80.0f);
                f = fmaxf(f, f4);
            }
        }
    }
    return f;
}

template<class T> __device__ __forceinline__ T kvEndIsland(const KvProgram& pg, const KvCtx& c, int noiseIndex) {
    const KvNoise& n = pg.noises[noiseIndex];
    float h = kvEndIslandHeight(n, c.bx / 8, c.bz / 8);
    return tc<T>(((double) h - 8.0) / 128.0);
}

template<class T> __device__ T kvEval(const KvProgram& pg, const KvCtx& c, int idx) {
    if (!kvGuard(pg, 1, idx, pg.nodeCount)) return tc<T>(0.0);
    const KvNode& n = pg.nodes[idx];
    switch (n.type) {
        case 0:
            return tc<T>(n.d0);
        case 1: {
            double t = ((double) c.by - (double) n.i0) / ((double) n.i1 - (double) n.i0);
            if (t < 0.0) return tc<T>(n.d0);
            if (t > 1.0) return tc<T>(n.d1);
            return tc<T>(n.d0) + tc<T>(t) * (tc<T>(n.d1) - tc<T>(n.d0));
        }
        case 2:
            if (!kvGuard(pg, 2, n.i0, pg.noiseCount)) return tc<T>(0.0);
            return kvNormalNoise<T>(pg.noises[n.i0], (double) c.bx * n.d0, (double) c.by * n.d1, (double) c.bz * n.d0);
        case 3: {
            if (!kvGuard(pg, 3, n.i0, pg.noiseCount)) return tc<T>(0.0);
            const KvNoise& nz = pg.noises[n.i0];
            double x;
            double y;
            double z;
            if (n.i1 == 1) {
                x = (double) c.bx;
                y = 0.0;
                z = (double) c.bz;
            } else if (n.i1 == 2) {
                x = (double) c.bz;
                y = (double) c.bx;
                z = 0.0;
            } else {
                x = (double) c.bx;
                y = (double) c.by;
                z = (double) c.bz;
            }
            return kvNormalNoise<T>(nz, x * 0.25, y * 0.25, z * 0.25) * tc<T>(4.0);
        }
        case 4: {
            if (!kvGuard(pg, 4, n.i0, pg.noiseCount)) return tc<T>(0.0);
            const KvNoise& nz = pg.noises[n.i0];
            T sx = kvEval<T>(pg, c, n.i1);
            T sy = kvEval<T>(pg, c, n.i2);
            T sz = kvEval<T>(pg, c, n.i3);
            double x = (double) c.bx * n.d0 + td<T>(sx);
            double y = (double) c.by * n.d1 + td<T>(sy);
            double z = (double) c.bz * n.d0 + td<T>(sz);
            return kvNormalNoise<T>(nz, x, y, z);
        }
        case 5: {
            T in = kvEval<T>(pg, c, n.i0);
            if (!kvGuard(pg, 5, n.i1, pg.noiseCount)) return tc<T>(0.0);
            double rarity = kvRarity(n.i2, td<T>(in));
            double x = (double) c.bx / rarity;
            double y = (double) c.by / rarity;
            double z = (double) c.bz / rarity;
            T v = kvNormalNoise<T>(pg.noises[n.i1], x, y, z);
            if (v < tc<T>(0.0)) v = tc<T>(0.0) - v;
            return tc<T>(rarity) * v;
        }
        case 6:
            return kvEval<T>(pg, c, n.i0) + kvEval<T>(pg, c, n.i1);
        case 7:
            return kvEval<T>(pg, c, n.i0) * kvEval<T>(pg, c, n.i1);
        case 8: {
            T a = kvEval<T>(pg, c, n.i0);
            T b = kvEval<T>(pg, c, n.i1);
            return a < b ? a : b;
        }
        case 9: {
            T a = kvEval<T>(pg, c, n.i0);
            T b = kvEval<T>(pg, c, n.i1);
            return a > b ? a : b;
        }
        case 10: {
            T in = kvEval<T>(pg, c, n.i0);
            return n.i1 != 0 ? in * tc<T>(n.d0) : in + tc<T>(n.d0);
        }
        case 11: {
            T in = kvEval<T>(pg, c, n.i0);
            if (in < tc<T>(n.d0)) return tc<T>(n.d0);
            T hi = tc<T>(n.d1);
            return in < hi ? in : hi;
        }
        case 12: {
            T in = kvEval<T>(pg, c, n.i0);
            switch (n.i1) {
                case 0:
                    return in < tc<T>(0.0) ? tc<T>(0.0) - in : in;
                case 1:
                    return in * in;
                case 2:
                    return in * in * in;
                case 3:
                    return in > tc<T>(0.0) ? in : in * tc<T>(0.5);
                case 4:
                    return in > tc<T>(0.0) ? in : in * tc<T>(0.25);
                default: {
                    T cl = in;
                    if (cl < tc<T>(-1.0)) cl = tc<T>(-1.0);
                    if (cl > tc<T>(1.0)) cl = tc<T>(1.0);
                    return cl / tc<T>(2.0) - cl * cl * cl / tc<T>(24.0);
                }
            }
        }
        case 13: {
            T in = kvEval<T>(pg, c, n.i0);
            double v = td<T>(in);
            return v >= n.d0 && v < n.d1 ? kvEval<T>(pg, c, n.i1) : kvEval<T>(pg, c, n.i2);
        }
        case 14:
            if (!kvGuard(pg, 6, n.i0, pg.splineCount)) return tc<T>(0.0);
            return tc<T>((double) kvSpline<T>(pg, c, n.i0));
        case 15:
            return kvEval<T>(pg, c, n.i0);
        case 16:
            return tc<T>(1.0);
        case 17:
            return tc<T>(0.0);
        case 18: {
            int size = c.flatSize;
            long long at = (long long) n.i0 * size * size + (long long) c.i * size + c.j;
            if (n.i0 < 0 || n.i0 >= pg.flatCount || c.i < 0 || c.i >= size || c.j < 0 || c.j >= size) {
                kvBadKind = 7;
                kvBadValue = n.i0;
                return tc<T>(0.0);
            }
            double v = c.flats[at];
            return tc<T>(v);
        }
        case 19:
            if (!kvGuard(pg, 8, n.i0, pg.noiseCount)) return tc<T>(0.0);
            return kvBlendedNoise<T>(pg.noises[n.i0], c.bx, c.by, c.bz);
        case 20:
            if (!kvGuard(pg, 9, n.i0, pg.noiseCount)) return tc<T>(0.0);
            return kvEndIsland<T>(pg, c, n.i0);
        default:
            return tc<T>(0.0);
    }
}

#define KV_LOCAL_MAX 192

template<class T> __device__ float kvSplineLinear(const KvProgram& pg, const KvCtx& c, int si, const T* v) {
    const KvSpline& s = pg.splines[si];
    float f = (float) td<T>(v[s.coordNode]);
    int i = kvBinarySearch(s.loc, s.nPoints, f) - 1;
    int j = s.nPoints - 1;
    if (i < 0) {
        return kvLinearExtend(f, s.loc[0], (float) td<T>(v[s.vals[0]]), s.der[0]);
    }
    if (i == j) {
        return kvLinearExtend(f, s.loc[j], (float) td<T>(v[s.vals[j]]), s.der[j]);
    }
    float f1 = s.loc[i];
    float f2 = s.loc[i + 1];
    float f3 = (f - f1) / (f2 - f1);
    float f4 = s.der[i];
    float f5 = s.der[i + 1];
    float f6 = (float) td<T>(v[s.vals[i]]);
    float f7 = (float) td<T>(v[s.vals[i + 1]]);
    float f8 = f4 * (f2 - f1) - (f7 - f6);
    float f9 = -f5 * (f2 - f1) + (f7 - f6);
    return (f6 + f3 * (f7 - f6)) + f3 * (1.0f - f3) * (f8 + f3 * (f9 - f8));
}

template<class T> __device__ __forceinline__ T kvNodeValue(const KvProgram& pg, const KvCtx& c, const KvNode& n, const T* v) {
    switch (n.type) {
        case 0:
            return tc<T>(n.d0);
        case 1: {
            double t = ((double) c.by - (double) n.i0) / ((double) n.i1 - (double) n.i0);
            if (t < 0.0) return tc<T>(n.d0);
            if (t > 1.0) return tc<T>(n.d1);
            return tc<T>(n.d0) + tc<T>(t) * (tc<T>(n.d1) - tc<T>(n.d0));
        }
        case 2:
            return kvNormalNoise<T>(pg.noises[n.i0], (double) c.bx * n.d0, (double) c.by * n.d1, (double) c.bz * n.d0);
        case 3: {
            const KvNoise& nz = pg.noises[n.i0];
            double x;
            double y;
            double z;
            if (n.i1 == 1) {
                x = (double) c.bx;
                y = 0.0;
                z = (double) c.bz;
            } else if (n.i1 == 2) {
                x = (double) c.bz;
                y = (double) c.bx;
                z = 0.0;
            } else {
                x = (double) c.bx;
                y = (double) c.by;
                z = (double) c.bz;
            }
            return kvNormalNoise<T>(nz, x * 0.25, y * 0.25, z * 0.25) * tc<T>(4.0);
        }
        case 4: {
            const KvNoise& nz = pg.noises[n.i0];
            double x = (double) c.bx * n.d0 + td<T>(v[n.i1]);
            double y = (double) c.by * n.d1 + td<T>(v[n.i2]);
            double z = (double) c.bz * n.d0 + td<T>(v[n.i3]);
            return kvNormalNoise<T>(nz, x, y, z);
        }
        case 5: {
            T in = v[n.i0];
            double rarity = kvRarity(n.i2, td<T>(in));
            double x = (double) c.bx / rarity;
            double y = (double) c.by / rarity;
            double z = (double) c.bz / rarity;
            T val = kvNormalNoise<T>(pg.noises[n.i1], x, y, z);
            if (val < tc<T>(0.0)) val = tc<T>(0.0) - val;
            return tc<T>(rarity) * val;
        }
        case 6:
            return v[n.i0] + v[n.i1];
        case 7:
            return v[n.i0] * v[n.i1];
        case 8: {
            T a = v[n.i0];
            T b = v[n.i1];
            return a < b ? a : b;
        }
        case 9: {
            T a = v[n.i0];
            T b = v[n.i1];
            return a > b ? a : b;
        }
        case 10: {
            T in = v[n.i0];
            return n.i1 != 0 ? in * tc<T>(n.d0) : in + tc<T>(n.d0);
        }
        case 11: {
            T in = v[n.i0];
            if (in < tc<T>(n.d0)) return tc<T>(n.d0);
            T hi = tc<T>(n.d1);
            return in < hi ? in : hi;
        }
        case 12: {
            T in = v[n.i0];
            switch (n.i1) {
                case 0:
                    return in < tc<T>(0.0) ? tc<T>(0.0) - in : in;
                case 1:
                    return in * in;
                case 2:
                    return in * in * in;
                case 3:
                    return in > tc<T>(0.0) ? in : in * tc<T>(0.5);
                case 4:
                    return in > tc<T>(0.0) ? in : in * tc<T>(0.25);
                default: {
                    T cl = in;
                    if (cl < tc<T>(-1.0)) cl = tc<T>(-1.0);
                    if (cl > tc<T>(1.0)) cl = tc<T>(1.0);
                    return cl / tc<T>(2.0) - cl * cl * cl / tc<T>(24.0);
                }
            }
        }
        case 13:
            return td<T>(v[n.i0]) >= n.d0 && td<T>(v[n.i0]) < n.d1 ? v[n.i1] : v[n.i2];
        case 14:
            if (n.i0 < 0 || n.i0 >= pg.splineCount) return tc<T>(0.0);
            return tc<T>((double) kvSplineLinear<T>(pg, c, n.i0, v));
        case 15:
            return v[n.i0];
        case 16:
            return tc<T>(1.0);
        case 17:
            return tc<T>(0.0);
        case 18: {
            int size = c.flatSize;
            if (n.i0 < 0 || n.i0 >= pg.flatCount || c.i < 0 || c.i >= size || c.j < 0 || c.j >= size) {
                return tc<T>(0.0);
            }
            return tc<T>(c.flats[(long long) n.i0 * size * size + (long long) c.i * size + c.j]);
        }
        case 19:
            return kvBlendedNoise<T>(pg.noises[n.i0], c.bx, c.by, c.bz);
        case 20:
            return kvEndIsland<T>(pg, c, n.i0);
        default:
            return tc<T>(0.0);
    }
}

template<class T> __device__ T kvEvalLinear(const KvProgram& pg, const KvCtx& c) {
    if (pg.nodeCount > KV_LOCAL_MAX || pg.root < 0 || pg.root >= pg.nodeCount) {
        return kvEval<T>(pg, c, pg.root < 0 ? 0 : pg.root);
    }
    T v[KV_LOCAL_MAX];
    for (int i = 0; i < pg.nodeCount; i++) {
        v[i] = kvNodeValue<T>(pg, c, pg.nodes[i], v);
    }
    return v[pg.root];
}

__device__ __forceinline__ void kvPoint(int idx, int cxz, int cy, int cw, int ch, int cny, int fcx, int fcz, KvCtx& c) {
    int cy1 = cy + 1;
    int cx1 = cxz + 1;
    int k = idx % cy1;
    int t = idx / cy1;
    int j = t % cx1;
    int i = t / cx1;
    c.i = i;
    c.j = j;
    c.bx = (fcx + i) * cw;
    c.by = (cny + k) * ch;
    c.bz = (fcz + j) * cw;
}

__global__ void kvKernelExact(KvProgram pg, int cxz, int cy, int cw, int ch, int cny, int fcx, int fcz,
                              const double* flats, int flatSize, int points, double* out) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= points) return;
    KvCtx c;
    c.flats = flats;
    c.flatSize = flatSize;
    kvPoint(idx, cxz, cy, cw, ch, cny, fcx, fcz, c);
    out[idx] = td<double>(kvEvalLinear<double>(pg, c));
}

__global__ void kvKernelHalf(KvProgram pg, int cxz, int cy, int cw, int ch, int cny, int fcx, int fcz,
                             const double* flats, int flatSize, int points, __half* v16, unsigned char* flags) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= points) return;
    KvCtx c;
    c.flats = flats;
    c.flatSize = flatSize;
    kvPoint(idx, cxz, cy, cw, ch, cny, fcx, fcz, c);
    __half v = kvEvalLinear<__half>(pg, c);
    v16[idx] = v;
    float f = __half2float(v);
    flags[idx] = (isfinite(f) && fabsf(f) >= 4.0f) ? 1 : 0;
}

__global__ void kvKernelFloat(KvProgram pg, int cxz, int cy, int cw, int ch, int cny, int fcx, int fcz,
                              const double* flats, int flatSize, int points, float* v32, unsigned char* flags,
                              float band) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= points) return;
    if (flags[idx] != 1) return;
    KvCtx c;
    c.flats = flats;
    c.flatSize = flatSize;
    kvPoint(idx, cxz, cy, cw, ch, cny, fcx, fcz, c);
    float v = (float) td<float>(kvEvalLinear<float>(pg, c));
    if (isfinite(v) && fabsf(v) >= band) {
        v32[idx] = v;
        flags[idx] = 2;
    } else {
        flags[idx] = 0;
    }
}

__global__ void kvKernelResolve(KvProgram pg, int cxz, int cy, int cw, int ch, int cny, int fcx, int fcz,
                                const double* flats, int flatSize, int points, const float* v32,
                                const unsigned char* flags, double* out) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= points) return;
    if (flags[idx] == 2) {
        out[idx] = (double) v32[idx];
        return;
    }
    KvCtx c;
    c.flats = flats;
    c.flatSize = flatSize;
    kvPoint(idx, cxz, cy, cw, ch, cny, fcx, fcz, c);
    out[idx] = td<double>(kvEvalLinear<double>(pg, c));
}

struct Reader {
    const unsigned char* data;
    size_t len;
    size_t pos;

    bool ok(size_t n) const { return pos + n <= len; }

    int readI() {
        int v = 0;
        memcpy(&v, data + pos, 4);
        pos += 4;
        return v;
    }

    double readD() {
        double v = 0;
        memcpy(&v, data + pos, 8);
        pos += 8;
        return v;
    }

    float readF() {
        float v = 0;
        memcpy(&v, data + pos, 4);
        pos += 4;
        return v;
    }
};

struct HostSpline {
    int nPoints;
    int coordNode;
    int locOff;
    int derOff;
    int valOff;
};

struct Program;

struct HostPerlin {
    int firstOctave;
    int levelCount;
    double inputFactor;
    double valueFactor;
    std::vector<double> amps;
    std::vector<KvLevel> levels;
};

struct HostNoise {
    int kind;
    double valueFactor;
    std::vector<HostPerlin> perlins;
    std::vector<int> perm;
    double b[5];
};

struct Program {
    KvProgram prog{};
    std::vector<KvNode> hNodes;
    std::vector<HostSpline> hSplines;
    std::vector<float> hFloats;
    std::vector<int> hInts;
    std::vector<HostNoise> hNoises;

    KvNode* dNodes = nullptr;
    KvSpline* dSplines = nullptr;
    float* dFloats = nullptr;
    int* dInts = nullptr;
    KvPerlin* dPerlins = nullptr;
    KvLevel* dLevels = nullptr;
    double* dAmps = nullptr;
    KvNoise* dNoises = nullptr;
    int* dPerms = nullptr;

    ~Program() {
        if (dNodes) cudaFree(dNodes);
        if (dSplines) cudaFree(dSplines);
        if (dFloats) cudaFree(dFloats);
        if (dInts) cudaFree(dInts);
        if (dPerlins) cudaFree(dPerlins);
        if (dLevels) cudaFree(dLevels);
        if (dAmps) cudaFree(dAmps);
        if (dNoises) cudaFree(dNoises);
        if (dPerms) cudaFree(dPerms);
    }
};

struct Scratch {
    double* flats = nullptr;
    size_t flatsCap = 0;
    double* out = nullptr;
    float* v32 = nullptr;
    unsigned char* flags = nullptr;
    __half* v16 = nullptr;
    size_t cap = 0;
    cudaStream_t stream = nullptr;

    ~Scratch() {
        if (flats) cudaFree(flats);
        if (out) cudaFree(out);
        if (v32) cudaFree(v32);
        if (flags) cudaFree(flags);
        if (v16) cudaFree(v16);
        if (stream) cudaStreamDestroy(stream);
    }
};

static thread_local Scratch* t_scratch = nullptr;

static Scratch& scratch() {
    if (t_scratch == nullptr) {
        t_scratch = new Scratch();
    }
    if (t_scratch->stream == nullptr) {
        int least = 0;
        int greatest = 0;
        cudaDeviceGetStreamPriorityRange(&least, &greatest);
        cudaStreamCreateWithPriority(&t_scratch->stream, cudaStreamNonBlocking, least);
        if (t_scratch->stream == nullptr) {
            cudaStreamCreateWithFlags(&t_scratch->stream, cudaStreamNonBlocking);
        }
    }
    return *t_scratch;
}

static SRWLOCK g_lock = SRWLOCK_INIT;
static std::vector<Program*> g_programs;
static char g_error[1024] = {0};
static bool g_cudaReady = false;
static int g_stackSize = 0;

static int depthOf(const Program* p, int idx, std::vector<int>& memo) {
    int count = (int) p->hNodes.size();
    if (idx < 0 || idx >= count) {
        return 0;
    }
    if (memo[idx] >= 0) {
        return memo[idx];
    }
    memo[idx] = 0;
    const KvNode& n = p->hNodes[idx];
    int d = 0;
    switch (n.type) {
        case 4:
            d = depthOf(p, n.i1, memo);
            if (depthOf(p, n.i2, memo) > d) d = depthOf(p, n.i2, memo);
            if (depthOf(p, n.i3, memo) > d) d = depthOf(p, n.i3, memo);
            break;
        case 5:
        case 10:
        case 11:
        case 12:
        case 15:
            d = depthOf(p, n.i0, memo);
            break;
        case 6:
        case 7:
        case 8:
        case 9:
            d = depthOf(p, n.i0, memo);
            if (depthOf(p, n.i1, memo) > d) d = depthOf(p, n.i1, memo);
            break;
        case 13:
            d = depthOf(p, n.i0, memo);
            if (depthOf(p, n.i1, memo) > d) d = depthOf(p, n.i1, memo);
            if (depthOf(p, n.i2, memo) > d) d = depthOf(p, n.i2, memo);
            break;
        case 14:
            if (n.i0 >= 0 && n.i0 < (int) p->hSplines.size()) {
                const HostSpline& s = p->hSplines[n.i0];
                d = depthOf(p, s.coordNode, memo);
                for (int k = 0; k < s.nPoints; k++) {
                    int at = s.valOff + k;
                    if (at >= 0 && at < (int) p->hInts.size()) {
                        int child = depthOf(p, p->hInts[at], memo);
                        if (child > d) d = child;
                    }
                }
            }
            break;
        default:
            break;
    }
    memo[idx] = d + 1;
    return d + 1;
}

static int programDepth(const Program* p, int root) {
    std::vector<int> memo(p->hNodes.size(), -1);
    return depthOf(p, root, memo);
}

static void ensureStack(int depth) {
    long need = (long) depth * 512 + 16384;
    if (need < 32768) need = 32768;
    if (need > 1048576) need = 1048576;
    if (need <= g_stackSize) {
        return;
    }
    long want = need;
    while (want >= 16384) {
        if (cudaDeviceSetLimit(cudaLimitStackSize, (size_t) want) == cudaSuccess) {
            g_stackSize = (int) want;
            break;
        }
        want /= 2;
    }
    cudaGetLastError();
}

struct LockGuard {
    LockGuard() {
        AcquireSRWLockExclusive(&g_lock);
    }

    ~LockGuard() {
        ReleaseSRWLockExclusive(&g_lock);
    }
};

struct Failure {
    const char* msg;
};

static void setError(const char* msg) {
    strncpy_s(g_error, sizeof(g_error), msg ? msg : "", _TRUNCATE);
}

static void setCudaError(const char* where, cudaError_t err) {
    _snprintf_s(g_error, sizeof(g_error), _TRUNCATE, "%s: %s", where, cudaGetErrorString(err));
}

static void copyToDevice(void** dst, const void* src, size_t bytes, const char* what) {
    if (bytes == 0) {
        *dst = nullptr;
        return;
    }
    if (cudaMalloc(dst, bytes) != cudaSuccess) {
        std::fprintf(stderr, "[kv] malloc failed %s\n", what);
        throw Failure{"cudaMalloc failed"};
    }
    if (cudaMemcpy(*dst, src, bytes, cudaMemcpyHostToDevice) != cudaSuccess) {
        std::fprintf(stderr, "[kv] memcpy failed %s\n", what);
        throw Failure{"cudaMemcpy failed"};
    }
    cudaError_t e = cudaDeviceSynchronize();
    if (e != cudaSuccess) {
        std::fprintf(stderr, "[kv] sync after %s failed: %s\n", what, cudaGetErrorString(e));
        throw Failure{"cuda sync failed"};
    }
    std::fprintf(stderr, "[kv] uploaded %s bytes=%zu\n", what, bytes);
}

static bool readPerlin(Reader& r, HostPerlin& hp) {
    hp.firstOctave = r.readI();
    hp.levelCount = r.readI();
    hp.inputFactor = r.readD();
    hp.valueFactor = r.readD();
    if (hp.levelCount < 0 || hp.levelCount > 64) return false;
    hp.amps.resize(hp.levelCount);
    for (int a = 0; a < hp.levelCount; a++) hp.amps[a] = r.readD();
    hp.levels.resize(hp.levelCount);
    for (int l = 0; l < hp.levelCount; l++) {
        KvLevel& lv = hp.levels[l];
        lv.present = r.readI();
        if (lv.present != 0) {
            if (!r.ok(256 + 24)) return false;
            memcpy(lv.perm, r.data + r.pos, 256);
            r.pos += 256;
            lv.xo = r.readD();
            lv.yo = r.readD();
            lv.zo = r.readD();
        } else {
            memset(lv.perm, 0, 256);
            lv.xo = lv.yo = lv.zo = 0.0;
        }
    }
    return true;
}

extern "C" {

JNIEXPORT jint JNICALL Java_com_fish_korolevcross_gpu_NativeBridge_nativeInit(JNIEnv*, jclass) {
    LockGuard guard;
    cudaError_t err = cudaFree(nullptr);
    if (err != cudaSuccess) {
        setCudaError("cuda init", err);
        return -1;
    }
    int devices = 0;
    cudaGetDeviceCount(&devices);
    if (devices <= 0) {
        setError("no CUDA device");
        return -2;
    }
    cudaDeviceSetLimit(cudaLimitPrintfFifoSize, 1024 * 1024);
    cudaGetLastError();
    g_cudaReady = true;
    g_error[0] = 0;
    return 0;
}

JNIEXPORT jstring JNICALL Java_com_fish_korolevcross_gpu_NativeBridge_nativeDeviceName(JNIEnv* env, jclass) {
    char name[256] = {0};
    int dev = 0;
    cudaDeviceProp prop{};
    if (cudaGetDevice(&dev) != cudaSuccess || cudaGetDeviceProperties(&prop, dev) != cudaSuccess) {
        return env->NewStringUTF("unknown");
    }
    std::snprintf(name, sizeof(name) - 1, "%s", prop.name);
    return env->NewStringUTF(name);
}

JNIEXPORT jlong JNICALL Java_com_fish_korolevcross_gpu_NativeBridge_createProgram(JNIEnv* env, jclass, jbyteArray spec) {
    LockGuard guard;
    if (!g_cudaReady) {
        setError("cuda not initialized");
        return 0;
    }
    jsize len = env->GetArrayLength(spec);
    std::vector<unsigned char> buf((size_t) len);
    env->GetByteArrayRegion(spec, 0, len, reinterpret_cast<jbyte*>(buf.data()));

    Reader r{buf.data(), (size_t) len, 0};
    if (!r.ok(24)) {
        setError("truncated header");
        return 0;
    }
    int magic = r.readI();
    int version = r.readI();
    if (magic != KOROLEV_MAGIC || version != 1) {
        setError("bad program magic");
        return 0;
    }
    int nodeCount = r.readI();
    int noiseCount = r.readI();
    int flatCount = r.readI();
    int splineCount = r.readI();
    if (nodeCount < 0 || nodeCount > 1000000 || splineCount < 0 || splineCount > 100000 ||
        noiseCount < 0 || noiseCount > 10000 || flatCount < 0 || flatCount > 10000) {
        setError("bad program counts");
        return 0;
    }
    if (!r.ok((size_t) nodeCount * 52 + (size_t) splineCount * 20)) {
        setError("truncated program");
        return 0;
    }

    Program* p = new Program();
    p->hNodes.resize(nodeCount);
    for (int i = 0; i < nodeCount; i++) {
        KvNode& n = p->hNodes[i];
        n.type = r.readI();
        n.i0 = r.readI();
        n.i1 = r.readI();
        n.i2 = r.readI();
        n.i3 = r.readI();
        n.d0 = r.readD();
        n.d1 = r.readD();
        n.d2 = r.readD();
        n.d3 = r.readD();
    }
    p->hSplines.resize(splineCount);
    for (int i = 0; i < splineCount; i++) {
        HostSpline& s = p->hSplines[i];
        s.nPoints = r.readI();
        s.coordNode = r.readI();
        s.locOff = r.readI();
        s.derOff = r.readI();
        s.valOff = r.readI();
    }
    int floatCount = r.readI();
    if (floatCount < 0 || !r.ok((size_t) floatCount * 4)) {
        setError("truncated float pool");
        delete p;
        return 0;
    }
    p->hFloats.resize(floatCount);
    if (floatCount > 0) {
        memcpy(p->hFloats.data(), r.data + r.pos, (size_t) floatCount * 4);
        r.pos += (size_t) floatCount * 4;
    }
    int intCount = r.readI();
    if (intCount < 0 || !r.ok((size_t) intCount * 4)) {
        setError("truncated int pool");
        delete p;
        return 0;
    }
    p->hInts.resize(intCount);
    if (intCount > 0) {
        memcpy(p->hInts.data(), r.data + r.pos, (size_t) intCount * 4);
        r.pos += (size_t) intCount * 4;
    }

    p->hNoises.resize(noiseCount);
    for (int i = 0; i < noiseCount; i++) {
        HostNoise& n = p->hNoises[i];
        n.kind = r.readI();
        if (n.kind == 0) {
            n.valueFactor = r.readD();
            n.perlins.resize(2);
            if (!readPerlin(r, n.perlins[0]) || !readPerlin(r, n.perlins[1])) {
                setError("truncated noise");
                delete p;
                return 0;
            }
        } else if (n.kind == 1) {
            for (int b = 0; b < 5; b++) n.b[b] = r.readD();
            n.perlins.resize(3);
            for (int pi = 0; pi < 3; pi++) {
                if (!readPerlin(r, n.perlins[pi])) {
                    setError("truncated noise");
                    delete p;
                    return 0;
                }
            }
        } else if (n.kind == 2) {
            for (int b = 0; b < 3; b++) n.b[b] = r.readD();
            n.perm.resize(512);
            for (int pi = 0; pi < 512; pi++) n.perm[pi] = r.readI();
        } else {
            setError("unknown noise kind");
            delete p;
            return 0;
        }
    }
    int root = r.readI();

    try {
        int depth = programDepth(p, root);
        ensureStack(depth);
        std::fprintf(stderr, "[kv] program depth=%d stack=%d\n", depth, g_stackSize);
        int levelTotal = 0;
        int ampTotal = 0;
        int perlinTotal = 0;
        for (const HostNoise& hn : p->hNoises) {
            perlinTotal += (int) hn.perlins.size();
            for (const HostPerlin& hp : hn.perlins) {
                levelTotal += hp.levelCount;
                ampTotal += hp.levelCount;
            }
        }

        if (!p->hNodes.empty()) copyToDevice((void**) &p->dNodes, p->hNodes.data(), p->hNodes.size() * sizeof(KvNode), "nodes");
        if (!p->hFloats.empty()) copyToDevice((void**) &p->dFloats, p->hFloats.data(), p->hFloats.size() * sizeof(float), "floats");
        if (!p->hInts.empty()) copyToDevice((void**) &p->dInts, p->hInts.data(), p->hInts.size() * sizeof(int), "ints");

        std::vector<KvSpline> devSplines(p->hSplines.size());
        for (size_t i = 0; i < p->hSplines.size(); i++) {
            const HostSpline& s = p->hSplines[i];
            devSplines[i].nPoints = s.nPoints;
            devSplines[i].coordNode = s.coordNode;
            devSplines[i].loc = p->dFloats + s.locOff;
            devSplines[i].der = p->dFloats + s.derOff;
            devSplines[i].vals = p->dInts + s.valOff;
        }
        if (!devSplines.empty()) copyToDevice((void**) &p->dSplines, devSplines.data(), devSplines.size() * sizeof(KvSpline), "splines");

        std::vector<KvLevel> levels;
        std::vector<double> amps;
        levels.reserve(levelTotal);
        amps.reserve(ampTotal);
        std::vector<KvPerlin> perlins;
        perlins.reserve(perlinTotal);
        std::vector<int> perlinAmpOff;
        std::vector<int> perlinLevelOff;
        for (const HostNoise& hn : p->hNoises) {
            for (const HostPerlin& hp : hn.perlins) {
                perlinLevelOff.push_back((int) levels.size());
                perlinAmpOff.push_back((int) amps.size());
                for (int l = 0; l < hp.levelCount; l++) levels.push_back(hp.levels[l]);
                for (int a = 0; a < hp.levelCount; a++) amps.push_back(hp.amps[a]);
                KvPerlin kp{};
                kp.firstOctave = hp.firstOctave;
                kp.levelCount = hp.levelCount;
                kp.inputFactor = hp.inputFactor;
                kp.valueFactor = hp.valueFactor;
                kp.amps = nullptr;
                kp.levels = nullptr;
                perlins.push_back(kp);
            }
        }
        if (!levels.empty()) copyToDevice((void**) &p->dLevels, levels.data(), levels.size() * sizeof(KvLevel), "levels");
        if (!amps.empty()) copyToDevice((void**) &p->dAmps, amps.data(), amps.size() * sizeof(double), "amps");
        for (size_t i = 0; i < perlins.size(); i++) {
            perlins[i].amps = p->dAmps + perlinAmpOff[i];
            perlins[i].levels = p->dLevels + perlinLevelOff[i];
        }
        if (!perlins.empty()) copyToDevice((void**) &p->dPerlins, perlins.data(), perlins.size() * sizeof(KvPerlin), "perlins");

        std::vector<int> perms;
        std::vector<int> permOff(p->hNoises.size(), -1);
        for (size_t i = 0; i < p->hNoises.size(); i++) {
            if (!p->hNoises[i].perm.empty()) {
                permOff[i] = (int) perms.size();
                perms.insert(perms.end(), p->hNoises[i].perm.begin(), p->hNoises[i].perm.end());
            }
        }
        if (!perms.empty()) copyToDevice((void**) &p->dPerms, perms.data(), perms.size() * sizeof(int), "perms");

        std::vector<KvNoise> noises;
        noises.reserve(p->hNoises.size());
        int perlinIdx = 0;
        for (size_t ni = 0; ni < p->hNoises.size(); ni++) {
            const HostNoise& hn = p->hNoises[ni];
            KvNoise kn{};
            kn.kind = hn.kind;
            kn.valueFactor = hn.valueFactor;
            if (!hn.perlins.empty()) {
                kn.pa = p->dPerlins + perlinIdx;
                kn.pb = p->dPerlins + (hn.perlins.size() > 1 ? perlinIdx + 1 : perlinIdx);
                kn.pc = p->dPerlins + (hn.perlins.size() > 2 ? perlinIdx + 2 : perlinIdx);
            }
            kn.perm = permOff[ni] >= 0 ? p->dPerms + permOff[ni] : nullptr;
            perlinIdx += (int) hn.perlins.size();
            kn.b0 = hn.b[0];
            kn.b1 = hn.b[1];
            kn.b2 = hn.b[2];
            kn.b3 = hn.b[3];
            kn.b4 = hn.b[4];
            noises.push_back(kn);
        }
        if (!noises.empty()) copyToDevice((void**) &p->dNoises, noises.data(), noises.size() * sizeof(KvNoise), "noises");

        p->prog.nodes = p->dNodes;
        p->prog.splines = p->dSplines;
        p->prog.noises = p->dNoises;
        p->prog.nodeCount = nodeCount;
        p->prog.splineCount = splineCount;
        p->prog.noiseCount = noiseCount;
        p->prog.flatCount = flatCount;
        p->prog.root = root;
    } catch (const Failure& e) {
        setError(e.msg);
        delete p;
        return 0;
    } catch (...) {
        setError("unknown error while uploading program");
        delete p;
        return 0;
    }

    g_programs.push_back(p);
    g_error[0] = 0;
    return (jlong) (intptr_t) p;
}

JNIEXPORT jint JNICALL Java_com_fish_korolevcross_gpu_NativeBridge_compute(JNIEnv* env, jclass, jlong handle,
                                                                           jint firstCellX, jint firstCellZ,
                                                                           jint cellWidth, jint cellHeight,
                                                                           jint cellNoiseMinY, jint cellCountXZ,
                                                                           jint cellCountY, jdoubleArray flats,
                                                                           jdoubleArray out, jint mode) {
    if (!g_cudaReady || handle == 0) {
        setError("cuda not ready");
        return -1;
    }
    Program* p = (Program*) (intptr_t) handle;
    int cx1 = cellCountXZ + 1;
    int cy1 = cellCountY + 1;
    size_t points = (size_t) cx1 * cx1 * cy1;
    size_t flatSize = (size_t) cx1;
    size_t flatTotal = flatSize * flatSize * (size_t) p->prog.flatCount;

    Scratch& s = scratch();

    if (flatTotal > s.flatsCap) {
        if (s.flats) cudaFree(s.flats);
        s.flats = nullptr;
        if (cudaMalloc((void**) &s.flats, flatTotal * sizeof(double)) != cudaSuccess) {
            setCudaError("cudaMalloc flats", cudaGetLastError());
            return -2;
        }
        s.flatsCap = flatTotal;
    }
    if (points > s.cap) {
        if (s.out) cudaFree(s.out);
        if (s.v32) cudaFree(s.v32);
        if (s.flags) cudaFree(s.flags);
        if (s.v16) cudaFree(s.v16);
        s.out = nullptr;
        s.v32 = nullptr;
        s.flags = nullptr;
        s.v16 = nullptr;
        if (cudaMalloc((void**) &s.out, points * sizeof(double)) != cudaSuccess) return -4;
        if (cudaMalloc((void**) &s.v32, points * sizeof(float)) != cudaSuccess) return -4;
        if (cudaMalloc((void**) &s.flags, points) != cudaSuccess) return -4;
        if (cudaMalloc((void**) &s.v16, points * sizeof(__half)) != cudaSuccess) return -4;
        s.cap = points;
    }

    std::vector<double> hFlats(flatTotal);
    if (flatTotal > 0) env->GetDoubleArrayRegion(flats, 0, (jsize) flatTotal, hFlats.data());

    cudaError_t err = cudaMemcpyAsync(s.flats, hFlats.data(), flatTotal * sizeof(double), cudaMemcpyHostToDevice, s.stream);
    if (err != cudaSuccess) {
        setCudaError("cudaMemcpyAsync flats", err);
        return -3;
    }

    int threads = 64;
    int blocks = (int) ((points + threads - 1) / threads);

    if (mode == 0) {
        kvKernelExact<<<blocks, threads, 0, s.stream>>>(p->prog, cellCountXZ, cellCountY, cellWidth, cellHeight, cellNoiseMinY,
                                                        firstCellX, firstCellZ, s.flats, (int) flatSize, (int) points, s.out);
    } else {
        kvKernelHalf<<<blocks, threads, 0, s.stream>>>(p->prog, cellCountXZ, cellCountY, cellWidth, cellHeight, cellNoiseMinY,
                                                       firstCellX, firstCellZ, s.flats, (int) flatSize, (int) points, s.v16,
                                                       s.flags);
        kvKernelFloat<<<blocks, threads, 0, s.stream>>>(p->prog, cellCountXZ, cellCountY, cellWidth, cellHeight, cellNoiseMinY,
                                                        firstCellX, firstCellZ, s.flats, (int) flatSize, (int) points, s.v32,
                                                        s.flags, 1.5f);
        kvKernelResolve<<<blocks, threads, 0, s.stream>>>(p->prog, cellCountXZ, cellCountY, cellWidth, cellHeight, cellNoiseMinY,
                                                          firstCellX, firstCellZ, s.flats, (int) flatSize, (int) points, s.v32,
                                                          s.flags, s.out);
    }

    err = cudaStreamSynchronize(s.stream);
    if (err != cudaSuccess) {
        setCudaError("kernel", err);
        return -5;
    }

    std::vector<double> host(points);
    err = cudaMemcpyAsync(host.data(), s.out, points * sizeof(double), cudaMemcpyDeviceToHost, s.stream);
    if (err == cudaSuccess) {
        err = cudaStreamSynchronize(s.stream);
    }
    if (err != cudaSuccess) {
        setCudaError("cudaMemcpy result", err);
        return -6;
    }
    env->SetDoubleArrayRegion(out, 0, (jsize) points, host.data());
    g_error[0] = 0;
    return 0;
}

JNIEXPORT void JNICALL Java_com_fish_korolevcross_gpu_NativeBridge_destroyProgram(JNIEnv*, jclass, jlong handle) {
    LockGuard guard;
    Program* p = (Program*) (intptr_t) handle;
    if (!p) return;
    for (size_t i = 0; i < g_programs.size(); i++) {
        if (g_programs[i] == p) {
            g_programs.erase(g_programs.begin() + i);
            break;
        }
    }
    delete p;
}

JNIEXPORT jstring JNICALL Java_com_fish_korolevcross_gpu_NativeBridge_getLastError(JNIEnv* env, jclass) {
    LockGuard guard;
    return env->NewStringUTF(g_error);
}

JNIEXPORT void JNICALL Java_com_fish_korolevcross_gpu_NativeBridge_nativeShutdown(JNIEnv*, jclass) {
    LockGuard guard;
    for (Program* p : g_programs) delete p;
    g_programs.clear();
    cudaDeviceReset();
    g_cudaReady = false;
}

}
