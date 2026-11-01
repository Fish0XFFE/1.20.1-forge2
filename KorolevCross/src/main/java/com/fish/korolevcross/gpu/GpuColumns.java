package com.fish.korolevcross.gpu;

public final class GpuColumns {
    private final double[] data;
    private final int offset;
    public final int firstCellX;
    public final int cellCountXZ;
    public final int cellCountY;
    private final int rowStride;
    public final boolean endIsland;

    public GpuColumns(double[] data, int offset, int firstCellX, int cellCountXZ, int cellCountY, boolean endIsland) {
        this.data = data;
        this.offset = offset;
        this.firstCellX = firstCellX;
        this.cellCountXZ = cellCountXZ;
        this.cellCountY = cellCountY;
        this.rowStride = cellCountY + 1;
        this.endIsland = endIsland;
    }

    public int columnLength() {
        return rowStride;
    }

    public void copyColumn(int x, int z, double[] dst) {
        int p = offset + (x * (cellCountXZ + 1) + z) * rowStride;
        System.arraycopy(data, p, dst, 0, dst.length);
    }

    public static int pointCount(int cellCountXZ, int cellCountY) {
        int cx = cellCountXZ + 1;
        return cx * cx * (cellCountY + 1);
    }
}
