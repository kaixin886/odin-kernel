# 魔改内核参考调研（odin 动态包增补候选）

调研日期：2026-11-15。目标机：小米 MIX 4（odin，骁龙 888 Plus / lahaina，
Inkypen 5.4.302 树，LineageOS 24）。目标优先级：**待机省电第一**，其次动态响应
（轻载省电/游戏自动升频），再次内存管理（用户重度冻结后台、冷页多）。

证据等级：★★＝仓库源码/defconfig 原文实证；★＝官方特性列表/changelog 原文；
☆＝二手转述或仅仓库描述，未逐项核源码，结论里已标注。

本文件只做调研与取舍，不含刷机步骤；不涉及 SELinux 伪造/隐藏类内容。

---

## 一、来源清单

### odin 本机型
| 来源 | 说明 | 等级 |
|---|---|---|
| Inkypen79/kernel_xiaomi_odin（lineage-24.0） | 本项目基线树；odin_defconfig 与关键源文件已逐项 grep 核查（见第三节） | ★★ |
| SetsuNeko/kernel_xiaomi_odin | Inkypen 的 fork，主线差异在 susfs 分支（最高 v2.1.0），未见额外优化特性集 | ★ |
| onijiang0/mix4-odin-kernel | 仓库描述：5.4.281＋SukiSU＋WALT＋「odin_mode」＋「cpu-boost kernelized」；但当前 README 已改作触屏中断风暴排查记录，旧 B11 内核自述有兼容性问题、不可通用——特性细节仅描述级证据 | ☆ |

### 小米 11 系列（venus 小米11 / mars 11 Pro / star 11 Ultra / haydn K40 Pro，同 SM8350）
| 来源 | 说明 | 等级 |
|---|---|---|
| MiYume0721/android_kernel_xiaomi_sm8350_miyume（HoshinoNeko Kernel） | venus/mars/star/haydn 统一树，5.4.302；venus_defconfig 原文已核（见候选表） | ★★ |
| C-L-Org/venus-kernel-finaisu | venus 5.4.302＋FinaSU 构建线，基线即 MiYume 树；仓库描述自称「power-optimized (schedutil + PELT)」——注意其基线是小米原厂系树（PELT 口径），与 odin 的 WALT 树不是同一调度血统，配置不可直接照搬 | ☆ |
| Demon000/kernel_xiaomi_sm8350 | venus 的 CAF rebase 树（LineageOS 维护者），属基线型而非特性型 | ★ |
| kamikaonashi/kernel_xiaomi_sm8350 / -venus-test | venus/mars/star WIP 树；其配套 ROM（BananaDroid）changelog 称「kernel optimizations for faster deepsleep and less idle drain」，具体项未公开逐条核实 | ☆ |

### lahaina 同代（OnePlus 9 系列，同 SM8350 / 5.4）
| 来源 | 说明 | 等级 |
|---|---|---|
| arter97/android_kernel_oneplus_sm8350＋XDA 帖（r26 系列 changelog） | 本轮最有价值的同 SoC 参考：f2fs/BFQ 主线回移植、MGLRU 回移植、主动压缩回移植、SimpleLMK 实测教训均有 changelog 原文 | ★ |
| engstk/blu_spark（github.com/engstk/op9，LOS 系，现行维护） | 特性列表原文含「Wakelock blockers available」「FS fsync toggle」「msm_performance touchboost / tweaked cpu_boost」「250HZ」 | ★ |
| kristofpetho/Omega kernel（OP9，已停更） | 以「明确拒绝 wakelock blocker」著称，作为风险反证纳入 | ★ |
| dev-sm8350/McQuaid（OP9，2025 年仍更新） | 以上游跟踪为主，特性面与本课题关系不大，仅作生态存续参考 | ☆ |

### 跨机型经典（特性发源地）
| 来源 | 招牌项（与本课题相关者） |
|---|---|
| Sultan（kerneltoast） | Simple LMK、CPU Input Boost、DEVFREQ Boost、EAS 能量模型调校、SLUB per-cpu partial 关闭；独立仓 kerneltoast/simple_lmk（按内核版本分分支）★★ |
| Boeffla（andip71） | 通用 Wakelock Blocker 驱动 v1.1.0、dyn_sync_cntrl（动态 fsync 的接口实现亦出自其手）★★ |
| faux123 | Dynamic FSync 本体 ★ |
| franciscofranco | FKM 把 wakelock/fsync 等做成运行时开关的范式；其内核的降压（UV）按任务要求只入「不建议」 |
| SmurfKernel 等 4.x 世代特性堆叠型 | Anxiety I/O、Simple LMK 选配等——多为 4.x 时代产物，5.4 落地性差，仅作谱系参考 ☆ |

---

## 二、odin 树落地性核查（本机实证，非转述）

对 Inkypen lineage-24.0 钉版的 odin_defconfig 与源文件逐项核查结果：

- 调度：`SCHED_WALT=y`、`UCLAMP_TASK=y`、`ENERGY_MODEL=y`、`MSM_PERFORMANCE=y(+QGKI)`
  ——动态骨架齐全（与现行备料结论一致）。
- I/O：`MQ_IOSCHED_DEADLINE=y`、`MQ_IOSCHED_KYBER=y`、`IOSCHED_BFQ=y` 三调度器全编入；
  block/Kconfig.iosched 无 DEFAULT 选择项，5.4 块层对 UFS 默认即 mq-deadline。
- 电源：`PM_WAKELOCKS=y`、`PM_WAKELOCKS_LIMIT=0`；wakeup 子系统为标准 5.4 形态，
  Boeffla 类按名拦截驱动有明确的挂载面（wakeup_source 激活路径）。
- f2fs：`F2FS_FS=y`，`F2FS_FS_COMPRESSION` 在树内 Kconfig **有符号**但 defconfig 未开；
  fs/f2fs/gc.c 中 ATGC/age_threshold 命中 0 ——本树 f2fs 无 ATGC（该特性在更新的主线
  f2fs 才有），GC 睡眠参数均为 sysfs 运行时面。
- mm：`mm/page_alloc.c` 含 watermark_boost_factor（7 处命中，符号在场）；
  无 MGLRU（与备料三一致）；无主动压缩（proactive compaction 是 5.8+ 主线特性，
  本树 5.4 无）。
- 无以下符号/文件：Boeffla blocker、Dynamic FSync、Simple LMK、独立 cpu input boost
  ——均为「需移植」而非「需打开」。

对照组（MiYume venus_defconfig 原文，★★）：`ZRAM_DEF_COMP_LZ4=y`（注意：小米原厂系
树有 ZRAM_DEF_COMP 符号，与 odin 树「默认值是 zram_drv.c 字面量」不同，不可照搬
其配置写法）、`ZRAM_WRITEBACK=y`、`F2FS_FS_COMPRESSION=y`、`LTO_CLANG_THIN=y`、
`SCHED_WALT=y`。即：同 SoC 的小米 11 系魔改树在 defconfig 层打开了 f2fs 压缩与
zram writeback——但打开符号只是入场券，实际生效仍需 ROM 侧配合（见候选表）。

---

## 三、候选表

契合度按「待机第一／动态第二／内存第三」的目标权重评。

### A. wakelock 屏蔽类（待机主攻面）

| 特性 | 干什么 | 谁在用（来源） | odin 5.4 落地性 | 契合度 | 风险 |
|---|---|---|---|---|---|
| Boeffla Wakelock Blocker v1.1.0 | 在 wakeup_source 激活路径按名字拦截指定内核 wakelock，使其不能阻止挂起；名单经 `/sys/class/misc/boeffla_wakelock_blocker/wakelock_blocker` 运行时可改（分号分隔）；出厂默认名单专打高通网络族：qcom_rx_wakelock、wlan、wlan_wow_wl、wlan_extscan_wl、netmgr_wl、NETLINK（扩展名单另有 IPA_WS、wlan_pno_wl 等） | Boeffla 本家（OnePlus 系，★★）；被大量 4.9–5.4 世代内核移植（Cruel/Exynos9820、fsociety/Pixel 5 等 ★）；lahaina 同代现行内核 blu_spark OP9 特性列表明列「Wakelock blockers available」（★，其实现文件位置未逐一核实） | 驱动主体小、依赖面只有 wakeup 子系统；odin 树为标准 5.4 wakeup 形态，需整驱动移植＋在激活路径挂钩，非开符号。移植难度低–中 | **高**（待机第一目标的唯一正面对策；且名单运行时可调，可先空名单进树、取证后再逐个启用，等于给下一轮留好开关） | 堵错会延迟/丢失通知、影响 WiFi 保活与吞吐——Omega 作者 kristofpetho 因此公开拒绝此特性（「wakelocks 存在即有其理由，堵了反而可能更耗电」★）；Boeffla 本人亦标注 expert only。对策：默认名单必须按 odin 真机 `/sys/kernel/wakeup_sources` 实测排名逐个核对，不照抄别机名单 |
| 驱动级 wakelock 削减补丁（qcacld 关 rx wakelock、IPA 不持锁等） | 直接改 wlan/IPA 驱动源码，让其少拿或不拿 wakelock | Mystic/AGNi 等 sdm660 世代内核 changelog 有「qcacld: disable qcom_rx_wakelock」「msm: ipa: Do not acquire wakelocks」条目（★，非 lahaina） | lahaina 的 qcacld-3.0/IPA3 在 Inkypen 树内的对应点未逐一核实 | 中（与 blocker 是同一问题的「改源头」路线，更彻底但不可逆） | 改驱动行为不可运行时回退；WiFi 吞吐/漫游/热点均可能受影响。未取证前不动 |

### B. fsync 类

| 特性 | 干什么 | 谁在用 | odin 落地性 | 契合度 | 风险 |
|---|---|---|---|---|---|
| Dynamic FSync（faux123）＋dyn_sync_cntrl（andip71） | 亮屏时把 fsync 降级为异步写、灭屏时强制全量 flush 并恢复同步语义，换 I/O 延迟与少量功耗；开关 `/sys/kernel/dyn_fsync/Dyn_fsync_active` | 3.x/4.x 世代广谱采用（★★ 谱系）；现代 lahaina 特性型内核已罕见（blu_spark 只保留静态 fsync 开关） | 需移植：钩 vfs_fsync 路径＋屏幕状态通知；原版基于 earlysuspend，现代树要改挂 DRM/fb 通知链，工作量中 | 低（收益是亮屏 I/O 延迟，与待机第一目标基本无关） | **数据完整性前科明确**：原版曾有「未启用也触发」的 bug 导致数据丢失（Pengus77 定位并修复，后续版本靠加 reboot/panic 强制 flush 通知器补救，★）。F2FS＋现代负载下 fsync 成本远低于 2013 年代，收益/风险比差 |
| 静态 fsync 开关（blu_spark 式） | 一个 sysfs 布尔，关掉即全局禁 fsync | blu_spark OP9 特性列表（★） | 移植量小于动态版 | 低 | 关掉即裸奔，掉电必丢数据；开着等于没装。不产生价值 |

### C. I/O 调度与 F2FS

| 特性 | 干什么 | 谁在用 | odin 落地性 | 契合度 | 风险 |
|---|---|---|---|---|---|
| 默认调度器选择（mq-deadline 现状） | UFS 的请求合并/排序策略 | arter97 OP9 曾由 BFQ 改投三星 SSG（r21，理由：CPU 开销更低，★） | odin 三调度器（mq-deadline/kyber/BFQ）**已全编入**，默认即 mq-deadline；切换是运行时动作（Scene/init），内核层无事可做 | 中（现状已合理） | 无。SSG 移植属三星树特有代码，为它移植不值 |
| BFQ 主线回移植 | 把 5.4 自带 BFQ 更新到主线新版（公平性/交互延迟修复） | arter97 OP9（★，特性列表明列） | 整目录替换级移植，中–大 | 低–中（UFS＋mq-deadline 已够用，BFQ 在 Android 上主要利好 eMMC/重载交错） | 块层回归风险与体积不合比例 |
| f2fs 主线回移植＋GC workaround | 把 f2fs 更新到主线新版（其 OP9 线一路跟到 v6.4 的 f2fs 修复），并含 arter97 自加的一处「让 GC 更好地执行」的 workaround | arter97 OP9（★★ changelog 连续多版） | 同 SoC 5.4 已有完整先例，但属整子系统替换大工程；odin 树现 f2fs 无 ATGC，新版可一并带入 ATGC 等 | 中（长期文件系统健康与后台 GC 行为，间
...[truncated 19277 chars]