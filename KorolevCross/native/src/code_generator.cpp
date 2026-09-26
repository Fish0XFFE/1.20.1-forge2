#include "code_generator.h"
#include <sstream>
#include <cmath>
#include <iomanip>
#include <cstdint>

CodeGenerator::CodeGenerator() : m_seed(0) {}

std::string CodeGenerator::noiseKeyFor(const NoiseParams& p) {
    std::stringstream ss;
    ss << "n_" << p.firstOctave << "_";
    for (double a : p.amplitudes) ss << a << "_";
    return ss.str();
}

void CodeGenerator::emitNoiseInit(const NoiseParams& params) {
    std::string key = noiseKeyFor(params);
    if (m_noises.count(key)) return;

    NoiseParams p = params;
    p.seed = mixSeed(m_seed, key);
    m_noises[key] = p;

    int id = m_noiseIdCounter++;

    if (p.amplitudes.empty()) p.amplitudes.push_back(1.0);
    if (p.amplitudes.size() > 16) p.amplitudes.resize(16);

    m_decls << "static __device__ double amp_" << id << "[" << p.amplitudes.size() << "] = {";
    for (size_t i = 0; i < p.amplitudes.size(); i++) {
        if (i > 0) m_decls << ",";
        m_decls << std::setprecision(17) << p.amplitudes[i];
    }
    m_decls << "};\n";

    m_decls << "static __device__ int perm_" << id << "[512] = {\n";
    int perm[512];
    for (int i = 0; i < 256; i++) perm[i] = i;
    uint64_t state = p.seed;
    for (int i = 255; i > 0; i--) {
        state = state * 6364136223846793005ULL + 1442695040888963407ULL;
        int j = (int)((state >> 33) % (uint64_t)(i + 1));
        int tmp = perm[i]; perm[i] = perm[j]; perm[j] = tmp;
    }
    for (int i = 0; i < 256; i++) perm[256 + i] = perm[i];

    for (int i = 0; i < 512; i++) {
        m_decls << perm[i];
        if (i < 511) m_decls << ",";
        if ((i + 1) % 32 == 0) m_decls << "\n";
    }
    m_decls << "};\n";
}

std::string CodeGenerator::genNoiseCall(const NoiseParams& params,
                                        const std::string& x,
                                        const std::string& y,
                                        const std::string& z) {
    std::string key = noiseKeyFor(params);
    emitNoiseInit(params);
    int id = -1;
    int idx = 0;
    for (auto& pair : m_noises) {
        if (pair.first == key) { id = idx; break; }
        idx++;
    }

    std::stringstream ss;
    ss << "normal_noise(perm_" << id << ","
       << params.firstOctave << ","
       << x << "," << y << "," << z << ","
       << "amp_" << id << "," << params.amplitudes.size() << ")";
    return ss.str();
}

std::string CodeGenerator::genNode(const DFNodePtr& node, int& counter, int depth) {
    if (!node) return "0.0";
    if (depth > 96) return "0.0";

    if (node->isConstant) {
        std::stringstream ss;
        ss << std::setprecision(17) << node->constant;
        return ss.str();
    }

    if (node->type == "noise") return genNoise(node);
    if (node->type == "spline") return genSpline(node, counter);
    if (node->type == "shift_a") return genShift(node, 0, counter);
    if (node->type == "shift_b") return genShift(node, 1, counter);
    if (node->type == "shift") return genShift(node, 2, counter);
    if (node->type == "add") return genBinary(node, "+", counter);
    if (node->type == "mul") return genBinary(node, "*", counter);
    if (node->type == "min") return genBinary(node, "MIN", counter);
    if (node->type == "max") return genBinary(node, "MAX", counter);
    if (node->type == "clamp") return genClamp(node, counter);
    if (node->type == "range_choice") return genRangeChoice(node, counter);
    if (node->type == "weird_scaled_sampler") return genWeirdScaled(node, counter);
    if (node->type == "y_clamped_gradient") return genYClamped(node);
    if (node->type == "abs") return "fabs(" + genNode(node->argument, counter, depth + 1) + ")";
    if (node->type == "square") {
        std::string a = genNode(node->argument, counter, depth + 1);
        return "((" + a + ")*(" + a + "))";
    }
    if (node->type == "cube") {
        std::string a = genNode(node->argument, counter, depth + 1);
        return "((" + a + ")*(" + a + ")*(" + a + "))";
    }
    if (node->type == "half_negative") {
        std::string a = genNode(node->argument, counter, depth + 1);
        return "((" + a + ")>0?(" + a + "):((" + a + ")*0.5))";
    }
    if (node->type == "quarter_negative") {
        std::string a = genNode(node->argument, counter, depth + 1);
        return "((" + a + ")>0?(" + a + "):((" + a + ")*0.25))";
    }
    if (node->type == "squeeze") {
        std::string a = genNode(node->argument, counter, depth + 1);
        return "squeeze(" + a + ")";
    }
    if (node->type == "invert") {
        std::string a = genNode(node->argument, counter, depth + 1);
        return "(1.0-(" + a + "))";
    }
    if (node->type == "interpolated") return genInterpolated(node, counter);
    if (node->type == "flat_cache" || node->type == "cache_2d" ||
        node->type == "cache_once" || node->type == "cache_all_in_cell")
        return genCache(node, node->type, counter);
    if (node->type == "blend_density") return genNode(node->argument, counter, depth + 1);

    if (node->type == "shifted_noise") {
        std::string shiftXExpr = node->arg1 ? genNode(node->arg1, counter, depth + 1) : "0.0";
        std::string shiftYExpr = node->arg2 ? genNode(node->arg2, counter, depth + 1) : "0.0";
        std::string shiftZExpr = node->input ? genNode(node->input, counter, depth + 1) : "0.0";

        std::stringstream ss;
        ss << "shifted_noise(";
        ss << "nx + (" << shiftXExpr << "),";
        ss << "ny + (" << shiftYExpr << "),";
        ss << "nz + (" << shiftZExpr << "),";
        ss << std::setprecision(17) << node->xzScale << "," << node->yScale;
        ss << ")";
        return ss.str();
    }

    if (node->type == "old_blended_noise") return genNoise(node);
    if (node->type == "end_islands") return "end_islands(wx,wy,wz)";
    if (node->type == "reference") return node->noiseKey;

    return "0.0";
}

std::string CodeGenerator::genNoise(const DFNodePtr& node) {
    std::string key = noiseKeyFor(node->noise);
    auto it = m_noiseVar.find(key);
    if (it != m_noiseVar.end()) return it->second;

    emitNoiseInit(node->noise);
    int id = -1, idx = 0;
    for (auto& pair : m_noises) {
        if (pair.first == key) { id = idx; break; }
        idx++;
    }

    std::string var = "nz" + std::to_string(m_cseCounter++);
    m_body << "    double " << var << " = normal_noise(perm_" << id << ","
           << node->noise.firstOctave << ",nx,ny,nz,amp_" << id << ","
           << node->noise.amplitudes.size() << ");\n";
    m_noiseVar[key] = var;
    return var;
}

std::string CodeGenerator::genBinary(const DFNodePtr& node, const char* op, int& counter) {
    std::string a = genNode(node->arg1, counter, 0);
    std::string b = genNode(node->arg2, counter, 0);
    std::stringstream ss;
    if (std::string(op) == "MIN") ss << "fmin(" << a << "," << b << ")";
    else if (std::string(op) == "MAX") ss << "fmax(" << a << "," << b << ")";
    else ss << "(" << a << op << b << ")";
    return ss.str();
}

std::string CodeGenerator::genUnary(const DFNodePtr& node, const char* fn, int& counter) {
    return std::string(fn) + "(" + genNode(node->argument, counter, 0) + ")";
}

std::string CodeGenerator::genClamp(const DFNodePtr& node, int& counter) {
    std::stringstream ss;
    ss << "fmin(fmax(" << genNode(node->input, counter, 0) << ","
       << std::setprecision(17) << node->minVal << "),"
       << node->maxVal << ")";
    return ss.str();
}

std::string CodeGenerator::genYClamped(const DFNodePtr& node) {
    std::stringstream ss;
    ss << "y_clamped_gradient(wy," << std::setprecision(17)
       << node->fromY << "," << node->toY << ","
       << node->fromValue << "," << node->toValue << ")";
    return ss.str();
}

std::string CodeGenerator::genShift(const DFNodePtr& node, int idx, int& counter) {
    std::stringstream ss;
    ss << "shift_" << idx << "(wx,wz)";
    return ss.str();
}

std::string CodeGenerator::genSpline(const DFNodePtr& node, int& counter) {
    int id = counter++;
    std::string prefix = "sp" + std::to_string(id) + "_";

    std::vector<double> locs;
    for (auto& p : node->splinePoints) locs.push_back(p.location);
    if (locs.empty()) return "0.0";

    bool saved = m_inSpline;
    m_inSpline = true;

    std::string coordExpr = node->input ? genNode(node->input, counter, 0) : "0.0";

    for (size_t i = 0; i < node->splinePoints.size(); i++) {
        std::string vExpr = node->splinePoints[i].value
            ? genNode(node->splinePoints[i].value, counter, 0)
            : "0.0";
        m_body << "    double " << prefix << "v" << i << " = " << vExpr << ";\n";

        std::string dExpr = "0.0";
        if (node->splinePoints[i].derivative) {
            dExpr = genNode(node->splinePoints[i].derivative, counter, 0);
        }
        m_body << "    double " << prefix << "d" << i << " = " << dExpr << ";\n";
    }

    std::string t = prefix + "t";
    m_body << "    double " << t << " = " << coordExpr << ";\n";

    m_inSpline = saved;

    std::stringstream expr;
    expr << std::setprecision(17);
    expr << "((" << t << ")<=" << locs[0] << "? " << prefix << "v0 : (";

    size_t last = node->splinePoints.size() - 1;
    for (size_t i = 0; i + 1 < node->splinePoints.size(); i++) {
        double lo = locs[i], hi = locs[i+1];
        double span = hi - lo;
        expr << "((" << t << ")<" << hi << ")? ((" << prefix << "v" << (i+1)
             << ")-(" << prefix << "v" << i << "))*(((" << t << ")-" << lo << ")/"
             << span << ") + (" << prefix << "v" << i << ") + ((" << t << ")-" << lo
             << ")/" << span << "*(1.0-((" << t << ")-" << lo << ")/" << span
             << ")*((" << prefix << "d" << i << ")*(1.0-((" << t << ")-" << lo << ")/"
             << span << ")+(" << prefix << "d" << (i+1) << ")*(((" << t << ")-" << lo
             << ")/" << span << "))*" << span << ") : ";
    }
    expr << prefix << "v" << last;
    for (size_t i = 0; i + 1 < node->splinePoints.size(); i++) expr << ")";
    expr << ")";

    return expr.str();
}

std::string CodeGenerator::genInterpolated(const DFNodePtr& node, int& counter) {
    return genNode(node->argument, counter, 0);
}

std::string CodeGenerator::genCache(const DFNodePtr& node, const std::string& cacheType, int& counter) {
    return genNode(node->argument, counter, 0);
}

std::string CodeGenerator::genRangeChoice(const DFNodePtr& node, int& counter) {
    std::string in = genNode(node->input, counter, 0);
    std::string a = genNode(node->arg1, counter, 0);
    std::string b = genNode(node->arg2, counter, 0);
    std::stringstream ss;
    ss << "((" << in << ") >= " << std::setprecision(17) << node->minVal
       << " && (" << in << ") < " << node->maxVal
       << " ? (" << a << ") : (" << b << "))";
    return ss.str();
}

std::string CodeGenerator::genWeirdScaled(const DFNodePtr& node, int& counter) {
    return genNoiseCall(node->noise, "nx", "ny", "nz");
}

std::string CodeGenerator::generate(const NoiseSettings& settings) {
    m_noises.clear();
    m_decls.str("");
    m_defs.str("");
    m_body.str("");
    m_noiseVar.clear();
    m_splineVar.clear();
    m_noiseIdCounter = 0;
    m_cseCounter = 0;
    m_inSpline = false;

    int counter = 0;

    std::stringstream base;
    base << "__device__ double fade(double t){return t*t*t*(t*(t*6.0-15.0)+10.0);}\n";
    base << "__device__ double lerp(double a,double b,double t){return a+t*(b-a);}\n";
    base << "__device__ double grad(int h,double x,double y,double z){\n";
    base << "int g=h&15;double u=g<8?x:y;double v=g<4?y:((g==12||g==14)?x:z);\n";
    base << "return ((g&1)==0?u:-u)+((g&2)==0?v:-v);}\n\n";

    base << "__device__ double perlin(int* p,double x,double y,double z){\n";
    base << "int ix=(int)floor(x)&255;int iy=(int)floor(y)&255;int iz=(int)floor(z)&255;\n";
    base << "double fx=x-floor(x);double fy=y-floor(y);double fz=z-floor(z);\n";
    base << "double u=fade(fx),v=fade(fy),w=fade(fz);\n";
    base << "int aaa=p[p[p[ix]+iy]+iz];int aba=p[p[p[ix]+iy+1]+iz];\n";
    base << "int aab=p[p[p[ix]+iy]+iz+1];int abb=p[p[p[ix]+iy+1]+iz+1];\n";
    base << "int baa=p[p[p[ix+1]+iy]+iz];int bba=p[p[p[ix+1]+iy+1]+iz];\n";
    base << "int bab=p[p[p[ix+1]+iy]+iz+1];int bbb=p[p[p[ix+1]+iy+1]+iz+1];\n";
    base << "return lerp(lerp(lerp(grad(aaa,fx,fy,fz),grad(baa,fx-1,fy,fz),u),\n";
    base << "lerp(grad(aba,fx,fy-1,fz),grad(bba,fx-1,fy-1,fz),u),v),\n";
    base << "lerp(lerp(grad(aab,fx,fy,fz-1),grad(bab,fx-1,fy,fz-1),u),\n";
    base << "lerp(grad(abb,fx,fy-1,fz-1),grad(bbb,fx-1,fy-1,fz-1),u),v),w);}\n\n";

    base << "__device__ double normal_noise(int* p,int firstOctave,double x,double y,double z,double* amp,int n){\n";
    base << "double v=0.0;double a=1.0;double m=0.0;\n";
    base << "for(int i=0;i<n;i++){\n";
    base << "int oct=firstOctave+i;\n";
    base << "double s=pow(2.0,-oct);\n";
    base << "double px=x*s;double py=y*s;double pz=z*s;\n";
    base << "double nx=px+(double)((oct+i*7)*131);\n";
    base << "double ny=py+(double)((oct+i*13)*71);\n";
    base << "double nz=pz+(double)((oct+i*19)*43);\n";
    base << "v+=a*perlin(p,nx,ny,nz);m+=a;a*=0.5;}\n";
    base << "return v/m;}\n\n";

    base << "__device__ double squeeze(double v){\n";
    base << "double c=v<0?(v< -0.5?0.0:(v>-0.5?v:0.0)):v;\n";
    base << "double c2=v>0?(v>0.5?1.0:(v<0.5?v:0.0)):c;\n";
    base << "return c2;}\n\n";

    int permShift[512];
    for (int i = 0; i < 256; i++) permShift[i] = i;
    uint64_t shiftSeed = m_seed ^ 0x9E3779B97F4A7C15ULL;
    for (int i = 255; i > 0; i--) {
        shiftSeed = shiftSeed * 6364136223846793005ULL + 1442695040888963407ULL;
        int j = (int)((shiftSeed >> 33) % (uint64_t)(i + 1));
        int tmp = permShift[i]; permShift[i] = permShift[j]; permShift[j] = tmp;
    }
    for (int i = 0; i < 256; i++) permShift[256 + i] = permShift[i];

    base << "static __device__ int perm_shift[512] = {";
    for (int i = 0; i < 512; i++) {
        base << permShift[i];
        if (i < 511) base << ",";
        if ((i + 1) % 32 == 0) base << "\n";
    }
    base << "};\n";
    base << "static __device__ double amp_shift_4[4] = {1.0,1.0,1.0,0.0};\n";
    base << "static __device__ double amp_shift_1[1] = {1.0};\n\n";

    base << "__device__ double shifted_noise(double sx, double sy, double sz, double xzScale, double yScale) {\n";
    base << "    double px = sx * xzScale;\n";
    base << "    double py = sy * yScale;\n";
    base << "    double pz = sz * xzScale;\n";
    base << "    return normal_noise(perm_shift, -7, px, py, pz, amp_shift_1, 1);\n";
    base << "}\n\n";

    base << "__device__ double y_clamped_gradient(double y,double fromY,double toY,double fromV,double toV){\n";
    base << "double t=(y-fromY)/(toY-fromY);t=t<0?0:(t>1?1:t);return fromV+t*(toV-fromV);}\n\n";

    base << "__device__ double shift_0(double x,double z){return normal_noise(perm_shift,-3,x,0.0,z,amp_shift_4,4);}\n";
    base << "__device__ double shift_1(double x,double z){return normal_noise(perm_shift,-3,z,x,0.0,amp_shift_4,4);}\n";
    base << "__device__ double shift_2(double x,double z){return normal_noise(perm_shift,-3,x,z,0.0,amp_shift_4,4);}\n";
    base << "__device__ double end_islands(double x,double y,double z){return 0.0;}\n\n";

    std::string finalDensity = genNode(settings.finalDensity, counter, 0);
    std::string finalBody = m_body.str();

    m_body.str("");
    m_noiseVar.clear();
    m_cseCounter = 0;

    std::string initialDensity = settings.initialDensityWithoutJaggedness
        ? genNode(settings.initialDensityWithoutJaggedness, counter, 0)
        : "0.0";
    std::string initialBody = m_body.str();

    std::stringstream out;
    out << base.str();
    out << m_decls.str() << "\n";
    out << m_defs.str() << "\n";

    out << "__device__ double evaluate(double wx,double wy,double wz){\n";
    out << "    double x=wx, y=wy, z=wz;\n";
    out << "    double nx=x, ny=y, nz=z;\n";
    out << "    (void)nx;(void)ny;(void)nz;(void)x;(void)y;(void)z;\n";
    out << finalBody;
    out << "    return " << finalDensity << ";\n";
    out << "}\n";

    out << "__device__ double evaluate_initial(double wx,double wy,double wz){\n";
    out << "    double x=wx, y=wy, z=wz;\n";
    out << "    double nx=x, ny=y, nz=z;\n";
    out << "    (void)nx;(void)ny;(void)nz;(void)x;(void)y;(void)z;\n";
    out << initialBody;
    out << "    return " << initialDensity << ";\n";
    out << "}\n";

    return out.str();
}