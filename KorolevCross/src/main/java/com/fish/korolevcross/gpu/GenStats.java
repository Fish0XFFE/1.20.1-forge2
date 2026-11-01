package com.fish.korolevcross.gpu;

import java.util.concurrent.atomic.AtomicLong;

public final class GenStats {
    private static final AtomicLong COUNT = new AtomicLong();
    private static final AtomicLong NANOS = new AtomicLong();
    private static final ThreadLocal<long[]> START = ThreadLocal.withInitial(() -> new long[1]);
    private static volatile boolean logged;

    private GenStats() {
    }

    public static void begin() {
        START.get()[0] = System.nanoTime();
    }

    public static void end() {
        long t0 = START.get()[0];
        if (t0 == 0L) {
            return;
        }
        START.get()[0] = 0L;
        long n = COUNT.incrementAndGet();
        long total = NANOS.addAndGet(System.nanoTime() - t0);
        if (n % 256L == 0L) {
            System.out.println("[korolevcross/] fill: " + n + " chunks, " + (total / 1_000_000L) + " ms total, " + String.format("%.3f", total / 1.0E6 / n) + " ms per chunk");
        }
    }

    public static void report() {
        if (logged) {
            return;
        }
        logged = true;
        long n = COUNT.get();
        if (n == 0L) {
            return;
        }
        System.out.println("[korolevcross/] fill total: " + n + " chunks, " + (NANOS.get() / 1_000_000L) + " ms, " + String.format("%.3f", NANOS.get() / 1.0E6 / n) + " ms per chunk");
    }
}
