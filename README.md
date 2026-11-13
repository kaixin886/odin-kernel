# odin-kernel

为小米 MIX 4（odin）自编的 LineageOS 24 内核：在 Inkypen 的原版内核源码
（`Inkypen79/kernel_xiaomi_odin`，lineage-24.0 分支，Linux 5.4.302）基础上，
分层集成 FinaSU（KernelSU 分支）与 SUSFS，并可选叠加一层保守的流畅度配置。

## 设计原则

- **只换内核本体**：最终交付的 boot 镜像沿用当前 ROM 原版 boot.img 的
  ramdisk 与设备树（dtb），仅替换其中的 kernel Image，变量最少、可回滚。
- **分层构建、逐层验证**：变体之间互不连累，哪一层出问题就摘掉哪一层。
  1. `vanilla`：原版内核原样编通，验证工具链与源码树；
  2. `finasu`：集成 FinaSU 本体（内置模式，Tracepoint 挂钩，不开 SUSFS）；
  3. `finasu-susfs`：再叠加 SUSFS 内核补丁（开发中）；
  4. `opts` 开关（与变体正交）：流畅度配置层，可单独开/关对比。
- **工具链对齐**：使用与 Inkypen 相同的 AOSP clang r574158
  （其 odin_defconfig 中记录的编译器版本），ThinLTO 配置与原版一致。

## 前置事实（已核查）

- Inkypen 现行内核**未**编入 KernelSU / SUSFS（无 drivers/kernelsu、
  无 susfs 文件、odin_defconfig 无 CONFIG_KSU）。
- FinaSU 内置集成的硬性要求在本机 defconfig 中**已全部满足**：
  `CONFIG_KPROBES=y`、`CONFIG_KALLSYMS_ALL=y`、`CONFIG_EXT4_FS=y`、
  `CONFIG_THREAD_INFO_IN_TASK=y`。
- FinaSU 管理器有签名校验：内核编译时必须写入官方管理器 APK 的证书
  大小与 SHA-256（`KSU_EXPECTED_SIZE` / `KSU_EXPECTED_HASH`）。
  构建脚本会从官方 Release 的管理器 APK 自动提取（见
  `scripts/extract_manager_cert.py`），提取失败则构建直接报错，不产出
  「能开机但管理器不认」的半成品。

## 优化配置层（opts，三档互斥）

只动有明确机制收益、且可独立回滚的配置项：

- `smooth`（流畅档）：调度时钟 `HZ 250 → 1000`，节拍从 4ms 细到 1ms，
  唤醒与抢占更跟手；代价是空闲唤醒变多、浅待机略费电。
- `battery`（省电档）：HZ 保持 250 不动（与流畅档互斥的原因就在这里）；
  打开 `WQ_POWER_EFFICIENT_DEFAULT`，让未标记的内核工作队列走省电
  路径，少叫醒忙核。它挤的是刚锁屏、被消息周期性唤醒这类**浅待机**
  时段的无效唤醒；整夜深睡时内核配置几乎不起作用，掉电主要由基带
  待机与应用唤醒源决定——省电档的预期收益在零点几个百分点/小时量级。
- 两档都把默认 TCP 拥塞控制改为 BBR（原版已编入 BBR 时生效）：
  空闲零成本，只影响传输中的吞吐与延迟稳定性。

不碰的：调度器本体（原版已是高通 WALT）、-O3、来路不明的「优化补丁」。

## 使用

GitHub Actions → `build-kernel` → Run workflow，选择 variant 与 opts。
产物（Image、.config、版本串）在该次运行的 Artifacts 中。

## 安全与恢复

- 真机第一次永远先 `fastboot boot` 试启动，确认能进系统再正式刷入。
- 手边常备当前 ROM 的原版 boot.img：任何异常，fastboot 刷回即恢复。
- ROM 更新内核后，本仓产物即过期，需按新版源码重新构建。
