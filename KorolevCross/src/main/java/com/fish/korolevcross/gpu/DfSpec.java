package com.fish.korolevcross.gpu;

import it.unimi.dsi.fastutil.doubles.DoubleList;
import net.minecraft.util.CubicSpline;
import net.minecraft.world.level.levelgen.DensityFunction;
import net.minecraft.world.level.levelgen.DensityFunctions;
import net.minecraft.world.level.levelgen.synth.BlendedNoise;
import net.minecraft.world.level.levelgen.synth.ImprovedNoise;
import net.minecraft.world.level.levelgen.synth.NormalNoise;
import net.minecraft.world.level.levelgen.synth.PerlinNoise;
import net.minecraft.world.level.levelgen.synth.SimplexNoise;

import java.lang.reflect.Field;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.concurrent.ConcurrentHashMap;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;

public final class DfSpec {
    public static final int MAGIC = 0x4B564431;
    public static final int VERSION = 1;

    private static final int T_CONSTANT = 0;
    private static final int T_Y_GRAD = 1;
    private static final int T_NOISE = 2;
    private static final int T_SHIFT = 3;
    private static final int T_SHIFTED = 4;
    private static final int T_WEIRD = 5;
    private static final int T_ADD = 6;
    private static final int T_MUL = 7;
    private static final int T_MIN = 8;
    private static final int T_MAX = 9;
    private static final int T_MUL_ADD = 10;
    private static final int T_CLAMP = 11;
    private static final int T_MAPPED = 12;
    private static final int T_RANGE = 13;
    private static final int T_SPLINE = 14;
    private static final int T_BLEND_DENSITY = 15;
    private static final int T_ALPHA = 16;
    private static final int T_OFFSET = 17;
    private static final int T_FLAT = 18;
    private static final int T_BLENDED = 19;
    private static final int T_END_ISLAND = 20;

    private static final Map<Class<?>, Map<String, Field>> FIELDS = new ConcurrentHashMap<>();

    public final byte[] bytes;
    public final List<double[][]> flats;
    public final int flatCount;
    public final int nodeCount;
    public final boolean endIsland;

    private DfSpec(byte[] bytes, List<double[][]> flats, int flatCount, int nodeCount, boolean endIsland) {
        this.bytes = bytes;
        this.flats = flats;
        this.flatCount = flatCount;
        this.nodeCount = nodeCount;
        this.endIsland = endIsland;
    }

    public static final class Unsupported extends RuntimeException {
        public Unsupported(String message) {
            super(message);
        }
    }

    public static DfSpec build(DensityFunction root) {
        return new Builder().build(root);
    }

    private static Object get(Object target, String name) {
        Class<?> type = target.getClass();
        Map<String, Field> fields = FIELDS.computeIfAbsent(type, c -> new ConcurrentHashMap<>());
        Field f = fields.computeIfAbsent(name, n -> {
            try {
                return Fields.get(type, n);
            } catch (Throwable e) {
                throw new Unsupported("field " + n + " on " + type.getName());
            }
        });
        try {
            return f.get(target);
        } catch (IllegalAccessException e) {
            throw new Unsupported("field access " + name + " on " + type.getName());
        }
    }

    private static int getInt(Object target, String name) {
        return (Integer) get(target, name);
    }

    private static double getDouble(Object target, String name) {
        return (Double) get(target, name);
    }

    private static String typeName(Object enumValue) {
        return ((Enum<?>) enumValue).name();
    }

    private static final class Node {
        int type;
        int i0;
        int i1;
        int i2;
        int i3;
        double d0;
        double d1;
        double d2;
        double d3;
    }

    private static final class LevelDef {
        boolean present;
        byte[] perm;
        double xo;
        double yo;
        double zo;
    }

    private static final class PerlinDef {
        int firstOctave;
        double inputFactor;
        double valueFactor;
        double[] amps;
        LevelDef[] levels;
    }

    private static final class NoiseDef {
        int kind;
        double valueFactor;
        double[] b = new double[5];
        int[] perm512;
        PerlinDef[] perlins;
    }

    private static final class SplineDef {
        int nPoints;
        int coordNode;
        int locOff;
        int derOff;
        int valOff;
    }

    private static final class Builder {
        private final List<Node> nodes = new ArrayList<>();
        private final IdentityHashMap<DensityFunction, Integer> nodeIds = new IdentityHashMap<>();
        private final List<double[][]> flats = new ArrayList<>();
        private final IdentityHashMap<double[][], Integer> flatIds = new IdentityHashMap<>();
        private final List<NoiseDef> noises = new ArrayList<>();
        private final IdentityHashMap<NormalNoise, Integer> normalNoiseIds = new IdentityHashMap<>();
        private final IdentityHashMap<BlendedNoise, Integer> blendedNoiseIds = new IdentityHashMap<>();
        private final IdentityHashMap<SimplexNoise, Integer> simplexIds = new IdentityHashMap<>();
        private final List<SplineDef> splines = new ArrayList<>();
        private float[] floatPool = new float[256];
        private int floatCount;
        private int[] intPool = new int[256];
        private int intCount;

        DfSpec build(DensityFunction root) {
            int rootNode = node(root);
            int noiseBytes = 0;
            for (NoiseDef n : noises) {
                noiseBytes += 4;
                if (n.kind == 0) {
                    noiseBytes += 8;
                } else if (n.kind == 1) {
                    noiseBytes += 40;
                } else {
                    noiseBytes += 24 + 2048;
                }
                for (PerlinDef p : n.perlins) {
                    noiseBytes += 24 + 8 * p.amps.length;
                    for (LevelDef l : p.levels) {
                        noiseBytes += 4;
                        if (l.present) {
                            noiseBytes += 256 + 24;
                        }
                    }
                }
            }
            int size = 24 + nodes.size() * 52 + splines.size() * 20 + 8 + 4 * floatCount + 4 * intCount + noiseBytes + 4;
            ByteBuffer bb = ByteBuffer.allocate(size + 1024).order(ByteOrder.LITTLE_ENDIAN);
            bb.putInt(MAGIC);
            bb.putInt(VERSION);
            bb.putInt(nodes.size());
            bb.putInt(noises.size());
            bb.putInt(flats.size());
            bb.putInt(splines.size());
            for (Node n : nodes) {
                bb.putInt(n.type);
                bb.putInt(n.i0);
                bb.putInt(n.i1);
                bb.putInt(n.i2);
                bb.putInt(n.i3);
                bb.putDouble(n.d0);
                bb.putDouble(n.d1);
                bb.putDouble(n.d2);
                bb.putDouble(n.d3);
            }
            for (SplineDef s : splines) {
                bb.putInt(s.nPoints);
                bb.putInt(s.coordNode);
                bb.putInt(s.locOff);
                bb.putInt(s.derOff);
                bb.putInt(s.valOff);
            }
            bb.putInt(floatCount);
            for (int i = 0; i < floatCount; i++) {
                bb.putFloat(floatPool[i]);
            }
            bb.putInt(intCount);
            for (int i = 0; i < intCount; i++) {
                bb.putInt(intPool[i]);
            }
            for (NoiseDef n : noises) {
                bb.putInt(n.kind);
                if (n.kind == 0) {
                    bb.putDouble(n.valueFactor);
                } else if (n.kind == 1) {
                    for (int i = 0; i < 5; i++) {
                        bb.putDouble(n.b[i]);
                    }
                } else {
                    for (int i = 0; i < 3; i++) {
                        bb.putDouble(n.b[i]);
                    }
                    for (int v : n.perm512) {
                        bb.putInt(v);
                    }
                }
                for (PerlinDef p : n.perlins) {
                    bb.putInt(p.firstOctave);
                    bb.putInt(p.amps.length);
                    bb.putDouble(p.inputFactor);
                    bb.putDouble(p.valueFactor);
                    for (double a : p.amps) {
                        bb.putDouble(a);
                    }
                    for (LevelDef l : p.levels) {
                        bb.putInt(l.present ? 1 : 0);
                        if (l.present) {
                            bb.put(l.perm);
                            bb.putDouble(l.xo);
                            bb.putDouble(l.yo);
                            bb.putDouble(l.zo);
                        }
                    }
                }
            }
            bb.putInt(rootNode);
            if (bb.position() != size) {
                throw new IllegalStateException("spec size mismatch " + bb.position() + " expected " + size);
            }
            boolean endIsland = false;
            for (Node n : nodes) {
                if (n.type == T_END_ISLAND) {
                    endIsland = true;
                    break;
                }
            }
            return new DfSpec(Arrays.copyOf(bb.array(), size), flats, flats.size(), nodes.size(), endIsland);
        }

        private int add(Node n) {
            nodes.add(n);
            return nodes.size() - 1;
        }

        private Node node(int type) {
            Node n = new Node();
            n.type = type;
            return n;
        }

        private int node(DensityFunction f) {
            Integer cached = nodeIds.get(f);
            if (cached != null) {
                return cached;
            }
            DensityFunction alias = alias(f.getClass().getSimpleName(), f);
            if (alias != null) {
                int id = node(alias);
                nodeIds.put(f, id);
                return id;
            }
            if (f instanceof DensityFunctions.Spline spline) {
                int id = splineNode(spline.spline());
                nodeIds.put(f, id);
                return id;
            }
            Node n = convert(f);
            int id = add(n);
            nodeIds.put(f, id);
            return id;
        }

        private DensityFunction alias(String name, DensityFunction f) {
            switch (name) {
                case "Cache2D":
                    return (DensityFunction) get(f, "function");
                case "CacheOnce":
                    return (DensityFunction) get(f, "function");
                case "CacheAllInCell":
                    return (DensityFunction) get(f, "noiseFiller");
                case "HolderHolder":
                    return ((DensityFunctions.HolderHolder) f).function().value();
                case "Marker":
                    return ((DensityFunctions.MarkerOrMarked) f).wrapped();
                default:
                    return null;
            }
        }

        private Node convert(DensityFunction f) {
            String name = f.getClass().getSimpleName();
            switch (name) {
                case "Constant": {
                    Node n = node(T_CONSTANT);
                    n.d0 = getDouble(f, "value");
                    return n;
                }
                case "YClampedGradient": {
                    Node n = node(T_Y_GRAD);
                    n.i0 = getInt(f, "fromY");
                    n.i1 = getInt(f, "toY");
                    n.d0 = getDouble(f, "fromValue");
                    n.d1 = getDouble(f, "toValue");
                    return n;
                }
                case "Noise": {
                    Node n = node(T_NOISE);
                    n.i0 = noiseId((DensityFunction.NoiseHolder) get(f, "noise"));
                    n.d0 = getDouble(f, "xzScale");
                    n.d1 = getDouble(f, "yScale");
                    return n;
                }
                case "Shift": {
                    Node n = node(T_SHIFT);
                    n.i0 = noiseId((DensityFunction.NoiseHolder) get(f, "offsetNoise"));
                    n.i1 = 0;
                    return n;
                }
                case "ShiftA": {
                    Node n = node(T_SHIFT);
                    n.i0 = noiseId((DensityFunction.NoiseHolder) get(f, "offsetNoise"));
                    n.i1 = 1;
                    return n;
                }
                case "ShiftB": {
                    Node n = node(T_SHIFT);
                    n.i0 = noiseId((DensityFunction.NoiseHolder) get(f, "offsetNoise"));
                    n.i1 = 2;
                    return n;
                }
                case "ShiftedNoise": {
                    Node n = node(T_SHIFTED);
                    n.i0 = noiseId((DensityFunction.NoiseHolder) get(f, "noise"));
                    n.i1 = node((DensityFunction) get(f, "shiftX"));
                    n.i2 = node((DensityFunction) get(f, "shiftY"));
                    n.i3 = node((DensityFunction) get(f, "shiftZ"));
                    n.d0 = getDouble(f, "xzScale");
                    n.d1 = getDouble(f, "yScale");
                    return n;
                }
                case "WeirdScaledSampler": {
                    Node n = node(T_WEIRD);
                    n.i0 = node((DensityFunction) get(f, "input"));
                    n.i1 = noiseId((DensityFunction.NoiseHolder) get(f, "noise"));
                    String mapper = typeName(get(f, "rarityValueMapper"));
                    n.i2 = mappers(mapper);
                    return n;
                }
                case "BlendedNoise":
                    return blendedNode((BlendedNoise) f);

                case "BlendDensity": {
                    Node n = node(T_BLEND_DENSITY);
                    n.i0 = node((DensityFunction) get(f, "input"));
                    return n;
                }
                case "BlendAlpha":
                    return node(T_ALPHA);
                case "BlendOffset":
                    return node(T_OFFSET);
                case "FlatCache": {
                    Node n = node(T_FLAT);
                    n.i0 = flatId((double[][]) get(f, "values"));
                    return n;
                }
                case "Cache2D":
                case "CacheOnce":
                case "CacheAllInCell":
                case "HolderHolder":
                case "Marker":
                    throw new Unsupported("unaliased wrapper " + name);
                case "Ap2": {
                    String op = typeName(get(f, "type"));
                    Node n = node(opAdd(op));
                    n.i0 = node((DensityFunction) get(f, "argument1"));
                    n.i1 = node((DensityFunction) get(f, "argument2"));
                    return n;
                }
                case "MulOrAdd": {
                    Node n = node(T_MUL_ADD);
                    n.i0 = node((DensityFunction) get(f, "input"));
                    n.i1 = "MUL".equals(typeName(get(f, "specificType"))) ? 1 : 0;
                    n.d0 = getDouble(f, "argument");
                    return n;
                }
                case "Clamp": {
                    Node n = node(T_CLAMP);
                    n.i0 = node((DensityFunction) get(f, "input"));
                    n.d0 = getDouble(f, "minValue");
                    n.d1 = getDouble(f, "maxValue");
                    return n;
                }
                case "Mapped": {
                    Node n = node(T_MAPPED);
                    n.i0 = node((DensityFunction) get(f, "input"));
                    n.i1 = mapType(typeName(get(f, "type")));
                    return n;
                }
                case "RangeChoice": {
                    Node n = node(T_RANGE);
                    n.i0 = node((DensityFunction) get(f, "input"));
                    n.i1 = node((DensityFunction) get(f, "whenInRange"));
                    n.i2 = node((DensityFunction) get(f, "whenOutOfRange"));
                    n.d0 = getDouble(f, "minInclusive");
                    n.d1 = getDouble(f, "maxExclusive");
                    return n;
                }
                case "NoiseInterpolator":
                    throw new Unsupported("nested noise interpolator");
                case "BeardifierMarker":
                    throw new Unsupported("beardifier marker inside interpolated subtree");
                case "EndIslandDensityFunction":
                    return node(T_END_ISLAND, simplexId((SimplexNoise) get(f, "islandNoise")));
                default:
                    throw new Unsupported(f.getClass().getName());
            }
        }

        private static int opAdd(String op) {
            switch (op) {
                case "ADD":
                    return T_ADD;
                case "MUL":
                    return T_MUL;
                case "MIN":
                    return T_MIN;
                case "MAX":
                    return T_MAX;
                default:
                    throw new Unsupported("ap2 " + op);
            }
        }

        private static int mapType(String type) {
            switch (type) {
                case "ABS":
                    return 0;
                case "SQUARE":
                    return 1;
                case "CUBE":
                    return 2;
                case "HALF_NEGATIVE":
                    return 3;
                case "QUARTER_NEGATIVE":
                    return 4;
                case "SQUEEZE":
                    return 5;
                default:
                    throw new Unsupported("mapped " + type);
            }
        }

        private static int mappers(String name) {
            if ("TYPE1".equals(name)) {
                return 1;
            }
            if ("TYPE2".equals(name)) {
                return 2;
            }
            throw new Unsupported("rarity " + name);
        }

        private int flatId(double[][] values) {
            Integer id = flatIds.get(values);
            if (id != null) {
                return id;
            }
            flats.add(values);
            int index = flats.size() - 1;
            flatIds.put(values, index);
            return index;
        }

        private int noiseId(DensityFunction.NoiseHolder holder) {
            NormalNoise noise = holder.noise();
            if (noise == null) {
                throw new Unsupported("unbound noise holder");
            }
            Integer cached = normalNoiseIds.get(noise);
            if (cached != null) {
                return cached;
            }
            NoiseDef def = new NoiseDef();
            def.kind = 0;
            def.valueFactor = getDouble(noise, "valueFactor");
            PerlinNoise first = (PerlinNoise) get(noise, "first");
            PerlinNoise second = (PerlinNoise) get(noise, "second");
            def.perlins = new PerlinDef[]{perlin(first), perlin(second)};
            noises.add(def);
            int index = noises.size() - 1;
            normalNoiseIds.put(noise, index);
            return index;
        }

        private int simplexId(SimplexNoise noise) {
            Integer cached = simplexIds.get(noise);
            if (cached != null) {
                return cached;
            }
            NoiseDef def = new NoiseDef();
            def.kind = 2;
            def.b[0] = getDouble(noise, "xo");
            def.b[1] = getDouble(noise, "yo");
            def.b[2] = getDouble(noise, "zo");
            def.perm512 = (int[]) get(noise, "p");
            def.perlins = new PerlinDef[0];
            noises.add(def);
            int index = noises.size() - 1;
            simplexIds.put(noise, index);
            return index;
        }

        private Node blendedNode(BlendedNoise noise) {
            Integer cached = blendedNoiseIds.get(noise);
            if (cached != null) {
                return node(T_BLENDED, cached);
            }
            NoiseDef def = new NoiseDef();
            def.kind = 1;
            def.b[0] = getDouble(noise, "xzScale");
            def.b[1] = getDouble(noise, "yScale");
            def.b[2] = getDouble(noise, "xzFactor");
            def.b[3] = getDouble(noise, "yFactor");
            def.b[4] = getDouble(noise, "smearScaleMultiplier");
            def.perlins = new PerlinDef[]{
                    perlin((PerlinNoise) get(noise, "minLimitNoise")),
                    perlin((PerlinNoise) get(noise, "maxLimitNoise")),
                    perlin((PerlinNoise) get(noise, "mainNoise"))
            };
            noises.add(def);
            int index = noises.size() - 1;
            blendedNoiseIds.put(noise, index);
            return node(T_BLENDED, index);
        }

        private Node node(int type, int i0) {
            Node n = node(type);
            n.i0 = i0;
            return n;
        }

        private PerlinDef perlin(PerlinNoise noise) {
            PerlinDef def = new PerlinDef();
            def.firstOctave = getInt(noise, "firstOctave");
            def.inputFactor = getDouble(noise, "lowestFreqInputFactor");
            def.valueFactor = getDouble(noise, "lowestFreqValueFactor");
            ImprovedNoise[] levels = (ImprovedNoise[]) get(noise, "noiseLevels");
            DoubleList amps = (DoubleList) get(noise, "amplitudes");
            def.amps = new double[levels.length];
            for (int i = 0; i < levels.length; i++) {
                def.amps[i] = i < amps.size() ? amps.getDouble(i) : 0.0;
            }
            def.levels = new LevelDef[levels.length];
            for (int i = 0; i < levels.length; i++) {
                LevelDef level = new LevelDef();
                ImprovedNoise improved = levels[i];
                if (improved != null) {
                    level.present = true;
                    level.perm = (byte[]) get(improved, "p");
                    level.xo = improved.xo;
                    level.yo = improved.yo;
                    level.zo = improved.zo;
                }
                def.levels[i] = level;
            }
            return def;
        }

        private int splineNode(CubicSpline<?, ?> spline) {
            if (spline instanceof CubicSpline.Constant<?, ?> constant) {
                Node n = node(T_CONSTANT);
                n.d0 = constant.value();
                return add(n);
            }
            if (spline instanceof CubicSpline.Multipoint<?, ?> multi) {
                int index = multipoint(multi);
                Node n = node(T_SPLINE);
                n.i0 = index;
                return add(n);
            }
            throw new Unsupported("cubic spline " + spline.getClass().getName());
        }

        @SuppressWarnings({"unchecked", "rawtypes"})
        private int multipoint(CubicSpline.Multipoint<?, ?> multi) {
            CubicSpline.Multipoint raw = multi;
            Object coordinate = raw.coordinate();
            if (!(coordinate instanceof DensityFunctions.Spline.Coordinate sc)) {
                throw new Unsupported("spline coordinate " + coordinate.getClass().getName());
            }
            int coordNode = node(sc.function().value());
            float[] locations = raw.locations();
            float[] derivatives = raw.derivatives();
            List<?> values = raw.values();
            int n = locations.length;
            int[] valueNodes = new int[n];
            for (int i = 0; i < n; i++) {
                valueNodes[i] = splineNode((CubicSpline<?, ?>) values.get(i));
            }
            SplineDef def = new SplineDef();
            def.nPoints = n;
            def.coordNode = coordNode;
            def.locOff = addFloats(locations);
            def.derOff = addFloats(derivatives);
            def.valOff = addInts(valueNodes);
            splines.add(def);
            return splines.size() - 1;
        }

        private int addFloats(float[] data) {
            int off = floatCount;
            if (floatCount + data.length > floatPool.length) {
                float[] grown = new float[Math.max(floatPool.length * 2, floatCount + data.length)];
                System.arraycopy(floatPool, 0, grown, 0, floatCount);
                floatPool = grown;
            }
            System.arraycopy(data, 0, floatPool, floatCount, data.length);
            floatCount += data.length;
            return off;
        }

        private int addInts(int[] data) {
            int off = intCount;
            if (intCount + data.length > intPool.length) {
                int[] grown = new int[Math.max(intPool.length * 2, intCount + data.length)];
                System.arraycopy(intPool, 0, grown, 0, intCount);
                intPool = grown;
            }
            System.arraycopy(data, 0, intPool, intCount, data.length);
            intCount += data.length;
            return off;
        }
    }
}
