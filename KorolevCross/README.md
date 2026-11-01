# KorolevCross

Forge 1.20.1 区块密度场 GPU 加速模组。地形与原版逐位一致，加速的部分是地形密度函数求值。

## 原理

原版 `NoiseChunk` 在生成区块时会为每个 `interpolated` 密度函数节点准备一张角点网格：
`(cellCountXZ+1)^2 * (cellCountY+1)` 个双精度值（整区块 5x5x49 = 1225 个），
然后由 `NoiseInterpolator` 做三线性插值。密度函数的 JSON 数据包在这之前已经被原版解析成
`DensityFunction` 对象树，本模组不再重新解析 JSON，而是直接读取这棵活的对象树：

1. `NoiseChunkMixin` 在 `initializeForFirstCellX` 处触发 `ChunkGpu.prepare`。
2. `DfSpec` 用反射遍历密度函数树，把节点、噪声、样条、缓存表序列化成二进制程序。
3. 原生库用 CUDA 一次性求出全部角点的密度值（fp64）。
4. `NoiseInterpolatorMixin` 在 `fillArray` 处用 GPU 结果替换原版逐点求值。
5. 插值、含水层、矿脉、表面规则、雕刻器、结构、群系全部保持原版代码路径。

噪声的置换表和偏移直接取自运行中的 `NormalNoise`/`PerlinNoise`/`ImprovedNoise` 对象，
不依赖世界种子重建，因此数据包或其它模组替换噪声时同样得到原版结果。

任何不支持的节点、旧版区块混合、结构 beardifier、列探测（cellCountXZ=1）都会退回原版 Java 求值，
不会产生错误地形。

## 三个维度

密度函数来自注册表里的 `NoiseRouter`，本模组读取运行中的对象树（与数据包 JSON 同源），
主世界、下界、末地都走同一条 GPU 路径；改过噪声 JSON 的数据包同样被正确识别。
末地岛屿密度（`EndIslandDensityFunction`）已在原生侧实现，末地不再回退。

| 维度 | 插值树节点数 | 末地岛屿 | 一致性校验 |
| --- | --- | --- | --- |
| 主世界 | 93 | 否 | 8192 列以上，0 差异 |
| 下界 | 10 | 否 | 0 差异 |
| 末地 | 12 | 是 | 0 差异 |

结构、洞穴、表面规则、生物群系、矿脉、含水层仍由原版计算，模组只提供密度数值本身。

CUDA 流使用设备允许的最低优先级：客户端渲染优先，密度计算让路，避免抢帧。

## 精度

- 默认 `mixedPrecision=false`：全部角点用 fp64 计算，与原版表达式逐位一致。
- `mixedPrecision=true`：fp16 粗算 -> fp32 复核 -> fp64 收敛的三段流水线，速度更慢，仅在
  需要复用低精度张量计算时才有意义。
- 校验：`debug=true` 时每个区块会把 GPU 结果与原版 `fillArray` 逐值比较，
  实测 8192 列、约 40 万个角点，最大误差 0.0，零不一致。

## 实测

RTX 4050 Laptop 6GB（Ada，fp64 为 fp32 的 1/64），i7 级笔记本 CPU，8 个区块工作线程。

| 项目 | 数值 |
| --- | --- |
| 单次求值 1225 角点，递归实现 | 6826 us |
| 单次求值 1225 角点，线性拓扑求值 | 507 us |
| 单次求值 1225 角点，服务器内 8 线程实测 | 2.4 ms |
| 8 线程并发，平均每次调用 | 324 us |
| 区块填充阶段，原版（同条件对照） | 42.6 ms/区块 |
| 区块填充阶段，GPU（同条件对照） | 40.7 ms/区块 |
| 出生点准备，原版（同条件对照） | 10.7 s |
| 出生点准备，GPU（同条件对照） | 11.0 s |

结论：核函数本身快了 13 倍，但整区块生成只覆盖密度求值这一段，8 个 CPU 线程已经把这部分
填满，端到端差异落在测量噪声内（重复测量在 40.7-45.5 ms/区块、10.7-15.1 s 之间波动）。
要拿到更大收益需要批量提交多个区块的求值，或者使用 fp64 吞吐更高的数据中心显卡。

## CPU 与已有区块

- 密度求值只是区块生成的一段，后面还有表面规则、洞穴、结构、生物群系、光照和区块序列化，
  这些仍在 CPU 上执行，所以整机 CPU 占用不会大幅下降。8 个工作线程本来就把密度这一段吃满了，
  把这段搬到 GPU 只是让这一段不再抢 CPU，不是让整个生成流程变快。
- 已经生成过的区块加载时完全不求密度：只读 region 文件、解析 NBT、装光照数据，
  因此任何密度场的 GPU 化都加速不了它。要加速已有区块需要另一套机制（并行解压与反序列化、
  区域文件预读、光照缓存），与本模组的加速路径无关。
- 单人客户端里 GPU 同时承担渲染，密度求值会和画面抢显卡，收益比专用服务器更小。

## 配置

`config/korolevcross-common.toml`：

- `generation.enabled`：总开关，默认 true。
- `generation.mixedPrecision`：混合精度流水线，默认 false。
- `generation.debug`：逐值一致性校验、统计输出、程序转储，默认 false。

## 构建

原生库（Windows，需要 CUDA Toolkit 与 MSVC）：

```
src/native/build_native.bat
```

产物写入 `src/main/resources/native/Release/korolev_native.dll`，`gradlew build` 会把它打进 jar
的 `native/` 目录。

模组：

```
gradlew build
```

产物 `build/libs/korolevcross-1.9.0.jar`。

## 限制

- 仅 NVIDIA GPU，需要能加载 CUDA 运行时；显卡不可用时自动退回原版，不报错。
- 光线追踪核心（RT core）只加速 BVH 求交，与密度场求值无关，本模组不使用也不伪造。
- 张量核心（Tensor core）只用于 fp16 混合模式，精度优先的默认路径用不到。
- 末地岛屿密度函数、旧版区块混合、结构 beardifier 覆盖的区块走原版，保证正确性优先。
- 服务端优先；客户端单人游戏走同一条 `NoiseChunk` 路径，同样生效。
- 正式环境（SRG 命名）下反射按 `SrgNames` 表从官方名映射到 SRG 名；映射缺失或任何反射/原生失败只会关闭 GPU 加速并回退原版，不会让世界加载失败。
