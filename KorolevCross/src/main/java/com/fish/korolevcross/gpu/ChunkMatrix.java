package com.fish.korolevcross.gpu;

public class ChunkMatrix {
    private final int x, z, minY, maxY, sizeX, sizeZ, sizeY;
    private final short[][][] blocks;

    public ChunkMatrix(int x, int z, int minY, int maxY) {
        this.x = x; this.z = z; this.minY = minY; this.maxY = maxY;
        this.sizeX = 16; this.sizeZ = 16; this.sizeY = maxY - minY + 1;
        this.blocks = new short[sizeX][sizeZ][sizeY];
    }

    public void generateOnGPU(int seed, int seaLevel) {
        short[][][] result = GPUBridge.generateChunk(x, z, minY, maxY, seed);
        if (result != null) {
            for (int lx = 0; lx < sizeX; lx++) {
                for (int lz = 0; lz < sizeZ; lz++) {
                    System.arraycopy(result[lx][lz], 0, blocks[lx][lz], 0, sizeY);
                }
            }
        }
    }

    public short[][][] getBlocks() { return blocks; }
    public void dispose() {}
    public void buildRTAcceleration() {}
}