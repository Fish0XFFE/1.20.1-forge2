package com.fish.korolevcross.gpu;

import com.fish.korolevcross.KorolevCross;
import com.fish.korolevcross.config.ModConfig;
import it.unimi.dsi.fastutil.objects.ObjectListIterator;
import net.minecraft.core.QuartPos;
import net.minecraft.world.level.levelgen.Beardifier;
import net.minecraft.world.level.levelgen.DensityFunction;
import net.minecraft.world.level.levelgen.DensityFunctions;
import net.minecraft.world.level.levelgen.NoiseChunk;
import net.minecraft.world.level.levelgen.blending.Blender;

import java.lang.reflect.Field;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;

public final class ChunkGpu {
    public static final ThreadLocal<Integer> CELL_X = new ThreadLocal<>();

    private static final Map<Key, Program> PROGRAMS = new ConcurrentHashMap<>();
    private static final AtomicBoolean BROKEN = new AtomicBoolean();
    private static final AtomicBoolean WARNED = new AtomicBoolean();
    private static final AtomicBoolean DUMPED = new AtomicBoolean();
    private static volatile long chunks;
    private static volatile long nanos;
    private static final java.util.concurrent.atomic.AtomicLong UNITS = new java.util.concurrent.atomic.AtomicLong();
    private static final java.util.concurrent.atomic.AtomicLong SPEC_NS = new java.util.concurrent.atomic.AtomicLong();
    private static final java.util.concurrent.atomic.AtomicLong GATHER_NS = new java.util.concurrent.atomic.AtomicLong();
    private static final java.util.concurrent.atomic.AtomicLong COMPUTE_NS = new java.util.concurrent.atomic.AtomicLong();

    private ChunkGpu() {
    }

    public static long acceleratedChunks() {
        return chunks;
    }

    public static long spentNanos() {
        return nanos;
    }

    public static boolean isBroken() {
        return BROKEN.get();
    }

    public static void prepare(NoiseChunk chunk) {
        if (BROKEN.get() || !ModConfig.enabled() || !NativeBridge.isAvailable()) {
            return;
        }
        try {
            if (chunk.getBlender() != Blender.empty()) {
                return;
            }
            View v = View.of(chunk);
            if (v.cellWidth * v.cellCountXZ != 16) {
                return;
            }
            if (beardifier(v.beardifier)) {
                return;
            }
            long start = System.nanoTime();
            int mode = ModConfig.mixedPrecision() ? 1 : 0;
            int units = 0;
            long specNanos = 0;
            long gatherNanos = 0;
            long computeNanos = 0;
            for (Object o : v.interpolators) {
                if (!(o instanceof GpuValuesHolder holder)) {
                    continue;
                }
                DensityFunction root = ((DensityFunctions.MarkerOrMarked) o).wrapped();
                long t0 = System.nanoTime();
                DfSpec spec;
                try {
                    spec = DfSpec.build(root);
                } catch (DfSpec.Unsupported unsupported) {
                    continue;
                }
                long t1 = System.nanoTime();
                double[] flats = gather(spec, v);
                if (flats == null) {
                    continue;
                }
                long t2 = System.nanoTime();
                if (ModConfig.debug() && DUMPED.compareAndSet(false, true)) {
                    dump(spec, flats, v);
                }
                Program program = program(spec);
                if (program == null) {
                    return;
                }
                double[] out = new double[GpuColumns.pointCount(v.cellCountXZ, v.cellCountY)];
                int rc = NativeBridge.compute(program.handle, v.firstCellX, v.firstCellZ, v.cellWidth,
                        v.cellHeight, v.cellNoiseMinY, v.cellCountXZ, v.cellCountY, flats, out, mode);
                if (rc != 0) {
                    fail("native compute failed: " + NativeBridge.getLastError());
                    return;
                }
                long t3 = System.nanoTime();
                holder.korolev$setColumns(new GpuColumns(out, 0, v.firstCellX, v.cellCountXZ, v.cellCountY, spec.endIsland));
                specNanos += t1 - t0;
                gatherNanos += t2 - t1;
                computeNanos += t3 - t2;
                units++;
            }
            if (units > 0) {
                chunks++;
                nanos += System.nanoTime() - start;
                SPEC_NS.addAndGet(specNanos);
                GATHER_NS.addAndGet(gatherNanos);
                COMPUTE_NS.addAndGet(computeNanos);
                long done = UNITS.incrementAndGet();
                if ((done & 127) == 0) {
                    logStats(done);
                }
            }
        } catch (Throwable t) {
            if (WARNED.compareAndSet(false, true)) {
                KorolevCross.LOGGER.warn("korolevcross: gpu prepare failed, falling back to vanilla generation", t);
            }
        }
    }


    private static void logStats(long done) {
        long spec = SPEC_NS.get();
        long gather = GATHER_NS.get();
        long compute = COMPUTE_NS.get();
        double per = 1.0 / done;
        KorolevCross.LOGGER.info(String.format(
                "korolevcross: %d interpolators spec=%.1fus gather=%.1fus compute=%.1fus total=%.1fus per chunk",
                done, spec * per / 1000.0, gather * per / 1000.0, compute * per / 1000.0,
                (spec + gather + compute) * per / 1000.0));
    }


    private static void dump(DfSpec spec, double[] flats, View v) {
        try {
            java.nio.file.Path dir = java.nio.file.Path.of("korolevcross-debug");
            java.nio.file.Files.createDirectories(dir);
            java.nio.file.Files.write(dir.resolve("spec.bin"), spec.bytes);
            java.nio.ByteBuffer buffer = java.nio.ByteBuffer.allocate(flats.length * 8).order(java.nio.ByteOrder.LITTLE_ENDIAN);
            buffer.asDoubleBuffer().put(flats);
            java.nio.file.Files.write(dir.resolve("flats.bin"), buffer.array());
            String meta = v.firstCellX + " " + v.firstCellZ + " " + v.cellWidth + " " + v.cellHeight + " "
                    + v.cellNoiseMinY + " " + v.cellCountXZ + " " + v.cellCountY + " " + spec.flatCount;
            java.nio.file.Files.writeString(dir.resolve("meta.txt"), meta);
            KorolevCross.LOGGER.info("korolevcross: dumped program spec, nodes={} flats={}", spec.nodeCount, spec.flatCount);
        } catch (Throwable ignored) {
        }
    }
    private static void fail(String message) {
        if (BROKEN.compareAndSet(false, true)) {
            KorolevCross.LOGGER.error("korolevcross: {}, chunk generation will stay vanilla", message);
        }
    }

    private static Program program(DfSpec spec) {
        Key key = new Key(spec.bytes);
        Program existing = PROGRAMS.get(key);
        if (existing != null) {
            return existing;
        }
        long handle = NativeBridge.createProgram(spec.bytes);
        if (handle == 0L) {
            fail("createProgram failed: " + NativeBridge.getLastError());
            return null;
        }
        Program program = new Program(handle, spec.flatCount);
        Program raced = PROGRAMS.putIfAbsent(new Key(spec.bytes), program);
        if (raced != null) {
            NativeBridge.destroyProgram(handle);
            return raced;
        }
        if (ModConfig.debug()) {
            KorolevCross.LOGGER.info("korolevcross: new program nodes={} flats={} island={}",
                    spec.nodeCount, spec.flatCount, spec.endIsland);
        }
        return program;
    }

    private static double[] gather(DfSpec spec, View v) {
        int size = v.cellCountXZ + 1;
        double[] data = new double[spec.flatCount * size * size];
        int p = 0;
        for (double[][] values : spec.flats) {
            for (int i = 0; i < size; i++) {
                int qx = QuartPos.fromBlock((v.firstCellX + i) * v.cellWidth) - v.firstNoiseX;
                if (qx < 0 || qx >= values.length) {
                    return null;
                }
                for (int j = 0; j < size; j++) {
                    int qz = QuartPos.fromBlock((v.firstCellZ + j) * v.cellWidth) - v.firstNoiseZ;
                    if (qz < 0 || qz >= values[qx].length) {
                        return null;
                    }
                    data[p++] = values[qx][qz];
                }
            }
        }
        return data;
    }

    private static boolean beardifier(Object beardifier) {
        if (!(beardifier instanceof Beardifier)) {
            return false;
        }
        try {
            ObjectListIterator<?> pieces = (ObjectListIterator<?>) BeardFields.PIECES.get(beardifier);
            ObjectListIterator<?> junctions = (ObjectListIterator<?>) BeardFields.JUNCTIONS.get(beardifier);
            return pieces.hasNext() || junctions.hasNext();
        } catch (Throwable e) {
            return true;
        }
    }

    private static final class BeardFields {
        static final Field PIECES = Fields.get(Beardifier.class, "pieceIterator");
        static final Field JUNCTIONS = Fields.get(Beardifier.class, "junctionIterator");
    }

    private static final class Program {
        final long handle;
        final int flatCount;

        Program(long handle, int flatCount) {
            this.handle = handle;
            this.flatCount = flatCount;
        }
    }

    private static final class Key {
        final byte[] bytes;
        final int hash;

        Key(byte[] bytes) {
            this.bytes = bytes;
            this.hash = Arrays.hashCode(bytes);
        }

        @Override
        public int hashCode() {
            return hash;
        }

        @Override
        public boolean equals(Object other) {
            return other instanceof Key key && hash == key.hash && Arrays.equals(bytes, key.bytes);
        }
    }

    private static final class View {
        final int cellWidth;
        final int cellHeight;
        final int cellCountXZ;
        final int cellCountY;
        final int cellNoiseMinY;
        final int firstCellX;
        final int firstCellZ;
        final int firstNoiseX;
        final int firstNoiseZ;
        final Object beardifier;
        final List<?> interpolators;

        private View(NoiseChunk chunk) {
            Class<?> type = NoiseChunk.class;
            this.cellWidth = intField(type, "cellWidth", chunk);
            this.cellHeight = intField(type, "cellHeight", chunk);
            this.cellCountXZ = intField(type, "cellCountXZ", chunk);
            this.cellCountY = intField(type, "cellCountY", chunk);
            this.cellNoiseMinY = intField(type, "cellNoiseMinY", chunk);
            this.firstCellX = intField(type, "firstCellX", chunk);
            this.firstCellZ = intField(type, "firstCellZ", chunk);
            this.firstNoiseX = intField(type, "firstNoiseX", chunk);
            this.firstNoiseZ = intField(type, "firstNoiseZ", chunk);
            this.beardifier = objectField(type, "beardifier", chunk);
            this.interpolators = (List<?>) objectField(type, "interpolators", chunk);
        }

        private static int intField(Class<?> type, String name, NoiseChunk chunk) {
            try {
                return field(type, name).getInt(chunk);
            } catch (IllegalAccessException e) {
                throw new IllegalStateException(e);
            }
        }

        private static Object objectField(Class<?> type, String name, NoiseChunk chunk) {
            try {
                return field(type, name).get(chunk);
            } catch (IllegalAccessException e) {
                throw new IllegalStateException(e);
            }
        }

        static View of(NoiseChunk chunk) {
            return new View(chunk);
        }

        private static Field field(Class<?> type, String name) {
            return FIELDS.computeIfAbsent(name, n -> Fields.get(type, n));
        }

        private static final Map<String, Field> FIELDS = new ConcurrentHashMap<>();
    }
}
