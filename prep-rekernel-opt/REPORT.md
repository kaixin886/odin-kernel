# 下一轮 BakaSU 构建备料报告（ReKernel 内建＋动态优化·待机优先＋MGLRU 评估）

备料日期：2026-11-15。范围：只备料，未 push、未改 `.github/workflows`、未动脚手架本体
（`scripts/build-kernel.sh` 只产出了补丁文件）。基线：已验收的 resukisu 变体
（Inkypen 5.4.302 susfs 分支钉版 `50e0141b`＋BakaSU 钉版 `548d1dda`＋SUSFS v2.1.0）。

---

## 方向修订（2026-11-15 21:40 用户拍板，覆盖原静态双档设计）

- **静态双档作废**：原备料二的 smooth（HZ1000 流畅包）／battery（HZ250 省电包）
  分立两包设计取消。用户定案：流畅/省电不做静态分包，改**动态**——日常轻载
  （刷视频）自动省电、游戏重载自动流畅；且**待机省电为最高优先级**。
- **交付只出一包**：resukisu 变体跑一次构建、只出一个动态包。不再出 off 对照包
  ——回滚底牌是用户手里现行已验收的 BakaSU 包（2026-11-15 已刷入在用）。off／
  smooth 本轮不跑；脚本里两层代码保留（smooth 已标注弃用），不删。
- **实现载体不变**：工作流文件不许动（用户手贴），Config layer 入参仍是
  off/smooth/battery——动态配置借 **battery 槽位**落地；battery 只是槽名，
  不是「静态省电档」。
- **动态的设计分工**：内核只给动态底子——schedutil 动态调频（负载信号源是本树的
  **WALT**，见备料二·修订）＋boost 通道保持在场；「哪个应用算游戏」的按应用策略
  不进内核，由用户现成的 Scene 在用户空间完成（游戏应用挂性能配置、其余省电）。
  内核不写死应用名单。
- **优化取舍按「最优」标准复核**：本轮按 odin_defconfig 与树文件逐项复核后收敛，
  完整清单（改／已在场／否决及理由）见备料二·修订的配置清单表与备料四的复扫补充。

## 交付物（本目录）

| 路径 | 内容 |
|---|---|
| `drivers/rekernel/` | ReKernel 进树源码：`rekernel.c`、`rekernel.h`、`Kconfig`、`Makefile` |
| `drivers/wakelock-blocker/` | Boeffla Wakelock Blocker v1.1.0 进树源码：`boeffla_wl_blocker.c`、`.h`（默认名单为空）、`Kconfig`、`Makefile`、`SOURCE.md`（来源记录） |
| `patches/tree-callsites.patch` | 对内核树的调用点补丁（binder.c、signal.c、drivers/Kconfig、drivers/Makefile，共 4 文件 95 行） |
| `patches/wakelock-blocker-callsites.patch` | Wakelock Blocker 的树内挂钩补丁（drivers/base/power/wakeup.c、drivers/Kconfig、drivers/Makefile，共 3 文件 115 行；在 tree-callsites.patch 之后应用） |
| `patches/build-kernel.sh.patch` | 对构建脚本的补丁（135 行）：ReKernel 集成段＋Wakelock Blocker 集成段（拷贝＋挂钩＋空名单硬审计）＋REKERNEL/BOEFFLA_WL_BLOCKER 符号开启＋动态档（battery 槽：schedutil 默认＋BBR 修复＋IDLE_PAGE_TRACKING＋governor/HZ 硬审计；smooth 层保留并标注弃用）＋zram 算法补丁＋rcu_nocbs 激活＋硬审计 |
| `REPORT.md` | 本文件 |

推送时这几项进仓即可（`drivers/` 与 `patches/` 放在仓根的 `prep-rekernel-opt/` 下，
与补丁内引用的 `$ROOT/prep-rekernel-opt/...` 路径一致）。

---

## 备料一：ReKernel 内建＋可开关

### 源码选型：官方 Integrate 版（v8.x 进树形态），不是 LKM HEAD，也不是 KPM 源码

核对了三份源码与 NoActive 客户端的协议面，结论：

- **KPM 8.0.0 源码不能作基底**：它基于 KernelPatch SDK（kfunc 按名查找、task_ext 藏指针、
  `re_offsets.c` 偏移表），进树等于重写脚手架。它只作协议参照。
- **LKM HEAD（11.7 代码）在本树用不了**：它的 binder 事件挂在
  `android_vh_binder_{alloc_new_buf_locked,preset,reply,trans}` 四个 vendor hook 上，
  本树 `include/trace/hooks/binder.h` 只有 restore_priority/set_priority/transaction_init，
  四个全不存在；signal 层用的 `android_vh_do_send_sig_info` 本树同样没有
  （`include/trace/hooks/signal.h` 文件都不存在）。
- **Integrate 版是正解**：这是 Sakion-Team 官方给自编内核的进树形态，自述版本 v8.5，
  与 8.0.0 同一血统——传统 raw netlink（unit 在 22..26 扫描、USER_PORT 100、
  `/proc/rekernel/<unit>` 发现）、事件文本格式逐字节相同、binder 走 binder.c 内直接
  调用点、signal 走 signal.c 内直接调用点、network 走标准 netfilter。零 vendor hook
  依赖，5.4 的 `file_operations` 形态原生兼容（上游 patches.sh 只在新树上才转 proc_ops）。

协议对齐实证（对 KPM 8.0.0 源码与官方客户端库 librekernel 逐项核过）：

- 事件格式：`type=Binder,bindertype={reply|transaction|free_buffer_full},oneway=%d,from_pid=%d,from=%d,target_pid=%d,target=%d;`，
  oneway transaction 追加 `rpc_name=%s,code=%d`；`type=Signal,signal=%d,...`；
  `type=Network,target=%d,proto=ipv%d,data_len=%d;`（target 是 **uid**，已核 KPM 调用点）。
- 语义过滤与 8.0.0 一致：同步 transaction/reply 全报、异步 oneway 只报 code 29..32 并提取
  rpc_name、目标未冻结不报、同 uid 不报、reply 只报系统目标、signal 只报
  SIGKILL/SIGTERM/SIGABRT/SIGQUIT 且目标冻结时。
- 客户端发现：`/proc/rekernel` 下只有纯数字 unit 文件（与 8.0.0 布局一致；
  LKM HEAD 多出的 `version` 文件未引入，避免老客户端朴素解析踩坑）。

### 对上游 Integrate 版的四处定案适配（均已写进源码注释）

1. **network 语义按 8.0.0_network 嫁接**：上游 Integrate 的 netfilter 对所有 app uid 无差别
   上报；用户真机验过的 _network 版是「守护进程先用 MONITOR_NET 命令注册 uid、只报注册的」。
   已把 KPM 8.0.0 的命令解析（payload 两 int：`{type, uid}`，REMOVE_PROC=1 本内建形态下
   为无操作、MONITOR_NET=2 加入 32 槽名单、其余忽略）与名单过滤嫁接进 Integrate 的
   `netlink_rcv_msg` 与 netfilter 钩子。
2. **运行时 sysfs 开关（用户拍板需求）**：`/sys/kernel/rekernel/enabled`，默认 1（开）。
   写 0 后 `rekernel_report()` 与 `sendMessage()` 在入口直接丢弃一切事件——对 NoActive
   等同于没装 ReKernel；写 1 立即恢复。不用 cmdline、不用重刷。
3. **late_initcall 开机建服**：上游只靠首个事件懒启动，`/proc/rekernel` 在那之前不存在；
   内建形态改为开机即建 netlink 服务＋/proc＋sysfs 节点，懒启动保留为兜底。
4. **netlink cfg 改静态命名**：上游导出全局符号 `cfg`，内建有链接冲突风险，改为
   `static rekernel_nl_cfg`。

另有一处**明确不移植**：上游 patches.sh 往 binder.c 里注入的「过期异步事务清理」
（`binder_find_outdated_transaction_ilocked` 等）在本树 binder.c 里**已经原生存在**
（binder_proc_transaction 内的 TF_UPDATE_TXN/is_frozen 处理，行 2925–2955），重复注入
必然符号重定义，故调用点补丁只保留三处：binder.c 的头文件 include、
`rekernel_binder_transaction()` 定义（trace 调用点之前）、trace 调用点前的转发调用；
外加 signal.c 的 include 与 do_send_sig_info 内一处上报。锚点全部在本树钉版文件上
逐行核过（trace 调用 binder.c:3333、do_send_sig_info signal.c:1285 起）。

冻结判定谓词一处替换：上游头文件用 `cgroup_freezing()`，本树 `include/linux/cgroup.h`
没有这个声明；改用本树头文件实际提供的 `cgroup_task_freeze()`（cgroup.h:915）＋
`cgroup_task_frozen()`（:929）＋jobctl 的 `JOBCTL_TRAP_FREEZE`，与上游 LKM 的 <6.1
判定集一致。

### 接线

- `drivers/Kconfig` 末尾 `endmenu` 前加 `source "drivers/rekernel/Kconfig"`；
  `drivers/Makefile` 末尾加 `obj-$(CONFIG_REKERNEL) += rekernel/`。
- 我们的 Kconfig 里 `REKERNEL`/`REKERNEL_NETWORK` 默认 n，**由 build 脚本在 resukisu
  变体显式 `--enable`**——vanilla/finasu 与 resukisu+off 路径逐字节不受影响。
- build 脚本补丁把集成段放在 defconfig 之前（Kconfig 接线必须先于任何 config 步骤），
  并在 olddefconfig 后加硬审计：两个符号没生效直接 FATAL，不许静默出包。

### 静态自验（已跑，结果见文末汇总）

补丁往返一致、符号闭合（binder.c 调的四个 handler 在 rekernel.h 声明、rekernel.c 定义；
signal.c 调的 rekernel_report 同理）、过期事务清理函数定义数补丁前后都是 1（无重复注入）、
与 BakaSU `inline_hook_check` 零冲突：补丁触碰的 4 个文件与必查的 7 个文件
（sys.c/exec.c/open.c/read_write.c/stat.c/reboot.c/input.c）无交集，四个禁查全词
（ksu_vfs_read_hook 等）在全部新文件里零出现。

---

## 备料二：优化双档（流畅 smooth／省电 battery）

> **【已被方向修订覆盖】** 本节的静态双档设计已作废，保留作审计痕迹。现行设计见
> 置顶「方向修订」与本节末尾的「备料二·修订：动态档最终配置清单」。下文逐档表与
> 双档口径不再执行；其中审计发现 #1（BBR 存量 bug）与 zram 取舍说明仍然有效，
> 已被动态档继承。

### 审计发现 #1（存量 bug，本轮顺带修）：两档的 BBR 从来没生效过

证据链：odin_defconfig 里 `# CONFIG_TCP_CONG_ADVANCED is not set`；本树
`net/ipv4/Kconfig` 第 467–709 行是 `if TCP_CONG_ADVANCED` 区，`TCP_CONG_BBR` 和
DEFAULT_* choice 都在里面；旧配置层只开 TCP_CONG_BBR＋DEFAULT_BBR、没开
TCP_CONG_ADVANCED，olddefconfig 把两者**静默丢弃**（defconfig 派生配置里 BBR 符号
干脆不存在）。HZ 与 WQ 两项不受影响、是真生效的。修复：两档都加
`--enable TCP_CONG_ADVANCED`，并在脚本里加硬审计（BBR/DEFAULT_BBR/IDLE_PAGE_TRACKING
任一未生效即 FATAL），杜绝以后再静默丢。

### 审计发现 #2：battery 层的 WQ_POWER_EFFICIENT_DEFAULT 是冗余行

odin_defconfig 里它本来就是 `=y`，脚本那行是空转。保留无害，报告里点明。

### 逐档逐条（符号均已与本树 Kconfig 逐个核过存在性）

共同新增：

| 改动 | 理由（一行） |
|---|---|
| `TCP_CONG_ADVANCED=y` | 修 #1：不开它，BBR 与默认算法选择整个不存在 |
| `IDLE_PAGE_TRACKING=y` | 给用户空间开动态冷页识别通道 `/sys/kernel/mm/page_idle`——冻结后台的冷页能被主动认出并回收，正对「后台多就卡」的症结；不用时零成本。符号在 mm/Kconfig:678，依赖 SYSFS&&MMU 均满足，defconfig 现为关 |

流畅档（smooth）：

| 改动 | 理由 |
|---|---|
| `HZ_1000`（既有） | tick 更细，调度/解冻响应延迟更低 |
| BBR 默认（修复后既有） | 拥塞控制换 BBR，弱网下吞吐与延迟更稳 |
| **zram 默认算法 lzo-rle → lz4** | 解压延迟最低的一档；切应用解冻时整批冷页要从 zram 换入，这条路径对解压速度最敏感，压缩比让位给延迟 |

省电档（battery）：

| 改动 | 理由 |
|---|---|
| HZ 保持 250（既有） | tick 少、唤醒少，待机与轻载更省 |
| `WQ_POWER_EFFICIENT_DEFAULT`（既有，冗余） | workqueue 默认走省电模式 |
| BBR 默认（修复后既有） | 同流畅档 |
| **zram 默认算法 lzo-rle → lz4** | 与流畅档统一（用户 2026-11-15 定案）：解冻换入延迟优先于压缩比，省电由 HZ250 等其他项承担，不靠 zram 压缩比抠内存 |

zram 取舍说明：本 5.4 树**没有** `ZRAM_DEF_COMP_*` Kconfig 选项，默认值硬编码在
`drivers/block/zram/zram_drv.c:44` 的字符串字面量里，所以逐档定算法只能做一行源码
替换——build 脚本补丁里已用带断言的 python 段实现（找不到原行直接 FATAL）。
**算法定案（2026-11-15 用户）：两档统一 lz4**，脚本已简化为无条件替换成 lz4；
备料初版曾按流畅=lz4／省电=zstd 模拟验证过替换机制本身，机制不变、只是取值统一。后端齐全：zcomp.c 含 lzo/lzo-rle/lz4/lz4hc/zstd，
defconfig 里 `CRYPTO_LZ4=y`、`CRYPTO_ZSTD=y`。
**交互提醒（刷完要做）**：Android init/Scene 通常在运行时显式写 `comp_algorithm`，
内核默认值只是兜底——把 Scene 里的算法设置设成 lz4 即可（两档一致），
否则运行时设置会把内核默认盖掉。

已在树中、无需动作的动态机制（核过 defconfig）：`PSI=y`（lmkd 的压力信号已通）、
`PROCESS_RECLAIM=y`（高通的按进程主动回收通道 `/proc/<pid>/reclaim` 已开）、
`MEMCG=y`＋`MEMCG_SWAP`。swappiness/watermark 是运行时 sysctl，用户已由 Scene 在管
（80／100，均合理），构建层不碰。

评估后否决（不进本轮）：KSM（CPU 成本＋需 uksmd 守护，冻结应用去重收益不确定）、
THP（5.4 arm64 延迟抖动，Android 生态默认关）、ZSWAP（FRONTSWAP 关、与 zram 角色重复）、
ZRAM_WRITEBACK（没有用户空间配 backing_dev 时纯惰性，列为未来选项）。

待机功耗面单列备料四（现状表＋定案与否决清单，含本轮复扫补充）。

### 备料二·修订：动态档最终配置清单（现行，2026-11-15 晚复核）

动态机制先说清（全部本地实证）：本树的负载追踪是高通 **WALT**
（`CONFIG_SCHED_WALT=y`，defconfig:92），不是主线 PELT——schedutil 吃的是 WALT 的
窗口负载信号做升/降频决策；`ENERGY_MODEL=y`（:511）＋`SCHED_MC=y`（:384）给 EAS
选核，`UCLAMP_TASK=y`（:136）给用户空间留钳位通道，devfreq 侧总线/GPU 已有
simple_ondemand／bw_hwmon／adreno_tz 动态 governor。也就是说「动态」的骨架在本树
全部现成，配置层真正缺的只有一处：**默认 governor 被 defconfig 定成 PERFORMANCE**
（:549），schedutil 明明已编入（:560）却不是默认（:554 未开）。动态档的核心动作
就是把这个默认翻正，其余为继承项与待机项。

配置清单（battery 槽位＝动态档；证据为 odin_defconfig 行号／树文件）：

| 处置 | 项 | 证据／理由 |
|---|---|---|
| **改** | `CPU_FREQ_DEFAULT_GOV_PERFORMANCE` 关、`CPU_FREQ_DEFAULT_GOV_SCHEDUTIL` 开 | defconfig:549/554/560。动态伸缩本体；保证开机起、且不依赖用户空间 init 是否写 governor，动态调频都在岗。运行时 Scene／power HAL 仍可在此地板之上改策略（设计分工）。olddefconfig 存活由脚本硬审计兜底（见自验第 12 条） |
| **改** | `TCP_CONG_ADVANCED=y`＋`TCP_CONG_BBR=y`＋`DEFAULT_BBR=y`（关 DEFAULT_CUBIC） | 继承审计发现 #1：不开 ADVANCED，BBR 会被 olddefconfig 静默丢弃（存量 bug） |
| **改** | `IDLE_PAGE_TRACKING=y` | 继承备料二：动态冷页识别通道 `/sys/kernel/mm/page_idle`，正对冻结后台场景；mm/Kconfig:678 |
| **改** | 内建 cmdline 追加 `rcu_nocbs=0-7` | 待机核心项，见备料四（口径不变） |
| **改** | zram 默认算法 lzo-rle → lz4（一行源码替换） | 继承用户定案：解冻换入延迟优先于压缩比；Scene 侧需同步设 lz4（运行时会盖内核默认） |
| **改** | 新增 Boeffla Wakelock Blocker v1.1.0 驱动＋`BOEFFLA_WL_BLOCKER=y`（仅 resukisu），**默认名单为空** | 待机主攻面的唯一正面对策（调研笔记候选表 A 项）；本轮只进驱动本体＋wakeup.c 挂钩、名单不预置任何条目，空名单时钩子为 no-op、行为与现行内核零差异。详见下方专节 |
| 不动 | HZ | defconfig 已 `HZ_250=y`／`HZ=250`（:391/394）。NO_HZ_IDLE 下空闲无 tick，HZ 不是待机杠杆；250 保留 schedutil 需要的响应粒度。动态档脚本不写 HZ，仅加审计防漂移 |
| 不动 | `WQ_POWER_EFFICIENT_DEFAULT` | defconfig 本就是 y（:507）；旧 battery 层那行开启是空转，本轮从层里删掉 |
| 已在场 | boost 通道：`MSM_PERFORMANCE=y`＋`MSM_PERFORMANCE_QGKI=y`（:5220/5222） | 触控/输入 boost 的内核侧载体已编入，其参数由用户空间（power HAL／Scene）驱动——正是「游戏自动流畅」的用户空间分工所在，内核层不重复造轮子 |
| 已在场 | PSI（`PSI=y` 且默认启用，:98）、`PROCESS_RECLAIM=y`（:887） | lmkd 压力信号与按进程主动回收通道均已开，本轮复核无误 |
| 已在场 | devfreq 动态 governor 全套（:5313-5322、:3765-3766）、`BUS_AUTO_SUSPEND=y`（:2064） | 总线/GPU 频率与总线运行时挂起已是动态，配置层无可加 |
| **否决** | 移植独立 cpu input boost 驱动（Sultan 系 CPU_INPUT_BOOST／DEVFREQ_BOOST 等） | 本树无此符号（defconfig 全文无）；msm_performance 已提供同类通道，再移植是重复机制＋新代码风险，不合「最优」 |
| **否决** | 静态 governor 锁定（performance／powersave 任一） | 与动态定案直接冲突；schedutil 是唯一符合「轻载省电、重载流畅」的本体 |
| **否决** | HZ 250→1000（旧 smooth 思路）／250→100 | 前者增 tick 唤醒、与待机优先冲突；后者在 NO_HZ_IDLE 下省不到空闲电、只伤响应。smooth 层代码保留但弃用 |
| **否决** | 关 `SCHED_DEBUG` 抠开销 | defconfig 为 y（:6616）。开销无可测证据，自编内核仍在迭代期，保住调度诊断面优先 |
| **否决** | KSM／THP／ZSWAP／ZRAM_WRITEBACK | 维持备料二原否决，理由不变 |

「游戏自动流畅」的完整链条（分工写清）：游戏起负载 → WALT 信号上升 → schedutil
自动升频（内核，无需应用名单）；Scene 的应用配置再在游戏包名上叠用户空间策略。
内核不认识「游戏」、只认识负载——这正是动态优于静态双包之处：刷视频时负载低、
频率自动趴下；待机时 NO_HZ＋rcu_nocbs 把唤醒压到最低（备料四）。

### Wakelock Blocker 进树（空名单，本轮补入）

- **来源与版本**：Boeffla generic wakelock blocker（andip71）**v1.1.0**。副本取自
  blu_spark 血统的 engstk/op7 树 `drivers/base/power/boeffla_wl_blocker.{c,h}`
  （2026-11-15 拉取；完整记录在 `drivers/wakelock-blocker/SOURCE.md`）。选这份副本
  的关键理由：其头文件 `LIST_WL_DEFAULT` 已经是空字符串，与本轮定案天然一致，
  驱动代码零改动（只加了说明注释）。DerpFest sm8250（5.4）树内的同版头文件作旁证
  （其设备名单未采用）；Inkypen 树全文检索 "boeffla" 为 0，无冲突。
- **接入方式**（与 ReKernel 同一形态）：驱动改放 `drivers/wakelock-blocker/`
  自带 Kconfig/Makefile，符号沿用上游名 `BOEFFLA_WL_BLOCKER`、default 改 n，
  脚本只对 resukisu 显式开启＋olddefconfig 后硬审计；wakeup.c 挂钩落在
  `patches/wakelock-blocker-callsites.patch`（在 tree-callsites.patch 之后应用）：
  顶部全局量（`list_wl_search`/`wl_blocker_active`/`wl_blocker_debug`＋
  `wakeup_source_deactivate` 前置声明）、`check_for_block()` 本体（与上游逐字
  一致，已比对）、`wakeup_source_report_event()` 守卫——全部逐字沿用 blu_spark
  的接法，唯一布局差异是头文件引用走相对路径
  `<../../wakelock-blocker/boeffla_wl_blocker.h>`（与 ReKernel 的
  `<../rekernel/rekernel.h>` 同一先例）。
- **空名单语义（本轮的硬定案）**：编译期默认名单 `LIST_WL_DEFAULT ""`、用户名单
  初值为空，`build_search_string()` 拼出的搜索串是 `";;;"`（长度 3），不满足
  `> 5` 条件，`wl_blocker_active` 恒为 false，`check_for_block()` 在名单检查前
  直接放行——**空名单时挂钩是 no-op，挂起行为与现行内核零差异**，本轮进的只是
  「开关本体」。脚本另设一道独立硬审计：头文件里默认名单非空直接 FATAL，
  防以后有人顺手把别机名单抄进来。
- **运行时接口**：`/sys/class/misc/boeffla_wakelock_blocker/` 下
  `wakelock_blocker`（用户名单）与 `wakelock_blocker_default`（默认名单）两个
  可写节点（分号分隔）、`debug`、`version`。两个名单都是运行时量，写错随时
  清空回退，不需要重刷。
- **名单启用留下轮**：本轮不往任何名单里写名字。下一轮先在真机上取
  `/sys/kernel/wakeup_sources` 的待机唤醒排名（至少一整夜），按 odin 实测逐个
  核对后再决定堵谁——不照抄别机名单（风险面见调研笔记：堵错会延迟/丢失通知、
  影响 WiFi 保活与吞吐）。

---

## 备料三：MGLRU 可行性评估

### 证据

- **树内现状**：`mm/vmscan.c`（4602 行）、`mm/workingset.c`、`include/linux/mmzone.h`
  里 `lru_gen` 引用全为 0；`struct lruvec` 是标准 5.4 形态（`lists[NR_LRU_LISTS]`）；
  vmscan.c 里 android_vh/厂商钩子标记为 0——接近主线 5.4，无厂商钩子纠缠（这一条是利好）。
- **page flag 位不是瓶颈（算完的账）**：本树几何——`SECTION_SIZE_BITS=30`（无热插拔）、
  `PA_BITS=48` → SECTIONS_WIDTH=18；MAX_NR_ZONES≤4 → ZONES_WIDTH=2；无 NUMA → NODES=0；
  无 NUMA_BALANCING → LAST_CPUPID=0；KASAN 未开 → KASAN_TAG=0；标准 flags 枚举到约 bit 33
  （NR_PAGEFLAGS≈24 量级）→ **空闲约 20 位**，MGLRU page 版所需约 5–7 位（gen＋tier 编码），
  绰绰有余。同为 VA39 几何的 arm64 5.10 ACK（Pixel 系）已量产 MGLRU，几何层面有先例。
- **真代价在代码面**：主线 6.1 的 MGLRU 是 **folio 化**实现，而 folio 基础设施 5.16+ 才有，
  5.4 移植只能走更早的 **page 版补丁系列**（Yu Zhao v14 时代／ACK 5.10 回移植的血统）；
  ACK 官方只回移植到 5.10/5.15、**从未下放到 5.4**，公开渠道查不到现成的 5.4 全量回移植
  可参照。工作量是数千行 mm 核心改造：lruvec 结构重做、workingset 集成、rmap/页表行走
  老化、memcg 统计接口，全部压在开机关键路径上，按本项目「一轮一刷真机验」的节奏要
  预留多轮迭代，且失败形态是开不了机级别。

### 结论：有条件能上，但本轮不上

条件＝改用 page 版系列作底稿＋单开变体分支＋预留多轮真机迭代预算。本轮改交退路组合
（全部已核实存在/已开，见备料二）：PSI 已开、PROCESS_RECLAIM 已开、本轮新增
IDLE_PAGE_TRACKING、zram 算法逐档定——即「内核给通道、动态识别冷页」，先把用户场景
（NoActive 冻结＋Thanox 压制挂大量后台、切应用卡）的痛点吃掉大头；MGLRU 留作独立
议题，用户点头再单独立项。

---

## 备料四：待机功耗

取证方式：钉版（Inkypen susfs 分支 `50e0141b`）逐文件 raw 拉取——odin_defconfig
全文、drivers/cpuidle/Kconfig＋governors/{Makefile,menu.c,teo.c}、cpuidle/governor.c、
kernel/{time,rcu,power}/Kconfig，存本目录 `inspect/`。先说总判断：**这份 defconfig
是成熟的高通安卓配置，待机相关的机制几乎全是已开状态，本轮真正能新增的只有一项，
其余候选逐项评估后否决（见下）。**量级先行声明：深睡（suspend）耗电由基带与应用
唤醒源主导，内核配置层碰不到；内核侧能抠的只有浅睡/轻载唤醒，量级是每小时
0.0x 个百分点级别——用户历史基线（nologd 后约 0.9%/h）的大头不在这一层。

### 现状表（已开／未开／不存在，逐项实证）

| 面 | 状态 | 实证 |
|---|---|---|
| cpuidle governor 种类 | 树里有 ladder／menu／TEO／haltpoll（KVM 专用） | drivers/cpuidle/Kconfig＋governors/Makefile |
| cpuidle 默认 governor | **menu**（defconfig 只开 menu；且 governor.c 按 rating 选默认，menu 20＞TEO 19，无 cmdline 参数时改不了） | defconfig:527；menu.c:600／teo.c:478 的 rating；governor.c:94-97 |
| cpuidle 驱动 | 高通 LPM（`ARM_QCOM_LPM_CPUIDLE=y`），PSCI OSI 已开（`QGKI_PSCI_OSI_SUPPORT=y`）；通用 ARM_PSCI_CPUIDLE 关是对的（被 LPM 驱动取代） | defconfig:536/535/593 |
| NO_HZ | `NO_HZ_COMMON=y`＋`NO_HZ_IDLE=y`＋`TICK_ONESHOT=y`＋`HIGH_RES_TIMERS=y`，空闲已 tickless；`NO_HZ_FULL` 未开 | defconfig:70-76 |
| RCU offload | 符号已开：`RCU_NOCB_CPU=y`（靠 `RCU_EXPERT=y` 满足依赖）＋`RCU_FAST_NO_HZ=y`；**但本树 rcu/Kconfig 没有 DEFAULT_ALL，NOCB 只对 `rcu_nocbs` 启动参数点名的 CPU 生效**，而 defconfig 内建 cmdline 只有 `cgroup_disable=pressure`（`CMDLINE_EXTEND=y`）——符号开着、激活参数不在本构建链手里 | defconfig:109/119/121/476-478；kernel/rcu/Kconfig:212-224 |
| suspend 通路 | `SUSPEND=y`＋`SUSPEND_FREEZER=y`＋`SUSPEND_SKIP_SYNC=y`＋`PM_SLEEP=y`＋`PM_WAKELOCKS=y` 全开；`PM_AUTOSLEEP` 未开 | defconfig:493-501；kernel/power/Kconfig:127 |
| workqueue 省电 | `WQ_POWER_EFFICIENT_DEFAULT` defconfig 本就是 y（battery 层那行冗余，备料二审计发现 #2 已点明） | defconfig（备料二已核） |
| 其余支撑项 | `CPU_PM=y`、`FREEZER=y`、`ENERGY_MODEL=y`、`SCHED_MC=y`、`UCLAMP_TASK=y`、PSI 已开（备料二）——全齐 | defconfig:510/823/511/384/136 |

### 定案项（一项，动态档携带；本轮只出这一包）

| 改动 | 理由＋量级 |
|---|---|
| 内建 cmdline 追加 `rcu_nocbs=0-7`（动态档 battery 槽；脚本里读-改-写：已带 rcu_nocbs 则跳过，olddefconfig 后硬审计 grep 校验、缺失即 FATAL） | 把已开的 `RCU_NOCB_CPU` 真正激活：RCU 回调从 8 个 CPU 卸到 rcuo 内核线程集中处理，回调不再零碎把 CPU 从浅睡拽出来干活；这是 GKI／lahaina 安卓内核的标准配法，本树 defconfig 特意开了一个专家门控符号却缺激活参数，属于补齐而非新增机制。对动态无可测副作用（回调本就要执行，只是换地方），故动态档携带。量级诚实写：浅睡/轻载唤醒类收益，约 0.0x %/h，深睡段基本无感 |

### 评估否决（七项，不硬塞）

- **CPU_IDLE_GOV_TEO（换默认或只编进来）**：rating 19＜menu 20，编进来也不会成默认，
  纯属惰性重量；要成默认只能靠 `cpuidle.governor=teo` 的 cmdline 覆盖——而 5.4 的 TEO
  是初版（后续主线多轮修补其统计逻辑），menu 是高通调校路径，浅睡收益无一致证据，
  风险不对价。日后想 A/B governor，单开实验包再说。
- **PM_AUTOSLEEP**：现挂起通路已被真机验证能深睡（0.9%/h 量级基线就是它跑出来的）；
  autosleep 只省挂起进入时毫秒级的用户态往返延迟，不改变唤醒频率与唤醒时长——那才是
  待机耗电的决定项。拿已工作的入口换不可测的收益，否决。
- **NO_HZ_FULL**：给隔离 CPU 的 HPC／实时语义，必须配 cmdline 隔离掩码，手机的调度
  形态与交互延迟都不对路（RCU_NOCB 当年要靠 RCU_EXPERT 才开得成，正是它的依赖在
  门控）。否决。
- **battery 档 HZ 250→100**：`NO_HZ_IDLE` 已使真空闲无 tick，HZ 只影响半忙时的 tick
  密度；降到 100 省不到空闲电、只伤响应性。否决。
- **改 CPU_FREQ 默认 governor——本轮修订，口径分开看**：初版曾把「改默认 governor」
  整体否决，理由是它作**待机杠杆**只活在开机早期窗口（运行时被 init／power HAL
  接管）——这条量级判断仍成立，本轮把默认翻成 schedutil **不计待机收益**。但方向
  修订后它的身份变了：schedutil 默认是动态档的**正确性地板**（保证 WALT 驱动的
  动态调频从开机起在岗、不赌用户空间是否写 governor），按此身份纳入（见备料二·
  修订清单）。powersave 默认仍然否决（拉长开机、总能量可能反升，且与动态冲突）。
- **RCU_BOOST**：负载下给 RCU 回调提优先级，与待机无关且微增功耗。否决。
- **PM_WAKELOCKS_GC**：只回收持有者已死的 wakelock 内核对象；死对象不持有唤醒、不
  耗电，与漏电无关。否决。

### 本轮复扫补充（2026-11-15 晚，按「最优」标准再扫一遍）

- **已在场、无动作**：`BUS_AUTO_SUSPEND=y`（:2064，总线运行时挂起）；`PM_DEBUG`
  未开（:504，无调试开销可剥）；suspend 全套见上方现状表。待机侧能收的仍只有
  rcu_nocbs 一项，其余候选要么已在场、要么量级说不清，按标准不收。
- **否决：关 SCHED_DEBUG 抠待机/开销**——无可测证据，诊断面优先（同备料二·修订）。
- **否决：改 cpuidle 默认 governor**——维持对 TEO 的否决：menu 是本树唯一编入且
  rating 最高（20）的默认、高通 LPM 驱动的调校路径，不动。

### 验收方法（刷机后）

- **过夜对比**：动态包 vs 现行已验收包（回滚底牌；刷前先记一晚基线，或用历史
  0.9%/h 量级对照）同条件过夜——同应用集、同 Scene 设置、同 SIM 与信号环境、
  同熄屏起点电量，熄屏 ≥6 小时，记 %/h；**至少两晚取均值**再下结论。预期量级
  0.0x %/h，单晚噪声大于收益是常态：测不出显著差异属正常结论，不算失败。
- **辅证**：`cat /proc/cmdline` 含 `rcu_nocbs=0-7`、rcuo 线程存在；
  `/sys/power/suspend_stats` 的 fail 计数不得较刷前新增；cpuidle 各 state 的 time
  驻留占比（`/sys/devices/system/cpu/cpu*/cpuidle/state*/time`）深睡状态不得倒退。

---

## 静态自验汇总（2026-11-15 本机执行）

1. `tree-callsites.patch`：在钉版树文件的干净副本上 `patch -p1 --dry-run` 通过、实打
   通过，打完与手工编辑版逐文件 `diff` 全 identical。
2. `build-kernel.sh.patch`：同样往返一致；打完的脚本 `bash -n` 语法通过。
3. 符号闭合：`binder_reply_handler`/`binder_trans_handler`/`binder_overflow_handler`/
   `rekernel_report` 均在 rekernel.h 有声明、rekernel.c 有定义；binder.c 里定义 1 处＋
   调用 1 处 `rekernel_binder_transaction`；signal.c 调用 `rekernel_report` 1 处；
   `binder_find_outdated_transaction_ilocked` 定义数补丁前后均为 1（无重复注入）。
4. BakaSU inline_hook_check 不冲突：补丁文件集与必查 7 文件无交集；4 个禁查全词在
   `drivers/rekernel/` 与两个补丁里均为 0 命中。
5. Kconfig/Makefile 闭合：`source "drivers/rekernel/Kconfig"` 落在 drivers/Kconfig:235，
   `obj-$(CONFIG_REKERNEL) += rekernel/` 落在 drivers/Makefile:190，符号定义在
   drivers/rekernel/Kconfig:11/23，脚本开启与审计引用一致。
6. zram 压缩算法替换段：对钉版 zram_drv.c 以 lz4、zstd 各模拟执行一次，第 44 行均
   正确替换、断言逻辑有效（机制验证；最终取值已按用户定案统一为 lz4，脚本为无条件替换）。
7. 配置符号存在性：HZ_250/HZ_1000（kernel/Kconfig.hz）、WQ_POWER_EFFICIENT_DEFAULT
   （init/Kconfig）、TCP_CONG_ADVANCED/TCP_CONG_BBR/DEFAULT_BBR（net/ipv4/Kconfig，
   含 467–709 的 if 包裹关系）、IDLE_PAGE_TRACKING（mm/Kconfig:678，depends SYSFS&&MMU）
   全部逐个核过。
8. 待机功耗段（备料四）：build-kernel.sh.patch 修订后重跑全套往返——dry-run／实打／
   `bash -n`／反向应用／与原稿 diff identical 全过；cmdline 追加段用钉版树原版
   `scripts/config` 对假 .config 实跑模拟：首次运行得
   `CONFIG_CMDLINE="cgroup_disable=pressure rcu_nocbs=0-7"`，二次运行识别已带
   rcu_nocbs 幂等跳过，审计 grep 命中。
9. **修订轮（动态档）**：build-kernel.sh.patch 重新生成（119 行、2 个 hunk）——在
   脚手架副本上先打旧补丁、叠加动态层修订（battery 层重写、smooth 标注弃用、
   governor/HZ 硬审计新增）后重新 diff；往返重验：正向应用与目标稿 identical、
   反向应用与脚手架原稿 identical、打完的脚本 `bash -n` 通过。
10. 修订轮符号核实（全部取自本地 inspect 的 odin_defconfig 原文）：HZ_250=y／
    HZ=250（:391/394）、CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y（:549）／
    DEFAULT_GOV_SCHEDUTIL 未开（:554）／GOV_SCHEDUTIL=y（:560）、SCHED_WALT=y
    （:92）、MSM_PERFORMANCE=y＋MSM_PERFORMANCE_QGKI=y（:5220/5222）、PSI=y
    （:98）、PROCESS_RECLAIM=y（:887）、WQ_POWER_EFFICIENT_DEFAULT=y（:507）、
    SCHED_DEBUG=y（:6616）、PM_DEBUG 未开（:504）；input boost 类符号
    （CPU_INPUT_BOOST／DEVFREQ_BOOST）全文无。
11. inline_hook_check 复核：新补丁只触 `scripts/build-kernel.sh` 一个文件，与必查
    7 文件无交集；4 个禁查全词在新补丁里 0 命中（tree-callsites.patch 本轮未改，
    初版结论不变）。
12. governor 翻转的文本层核实：defconfig 里被翻的两个符号行形态已确认
    （`=y` 与 `# ... is not set`），scripts/config 的 --enable/--disable 可直接
    改写；Kconfig choice 的存活判定见下方未验证标注。
13. **Wakelock Blocker 源码核实**：副本取自 engstk/op7（blu_spark 血统），.c/.h
    文件头与 `BOEFFLA_WL_BLOCKER_VERSION` 均为 v1.1.0；其头文件
    `LIST_WL_DEFAULT` 本就是 `""`（第 28 行），与空名单定案一致；DerpFest
    sm8250（5.4）树的同版头文件作旁证；经 GitHub 代码搜索核 Inkypen 树
    "boeffla" 命中 0，无同名符号/文件冲突。空名单语义按源码复核：两名单皆空
    时搜索串 `";;;"` 长度 3，`build_search_string()` 置
    `wl_blocker_active = false`（.c 第 68 行的 `> 5` 判定）。
14. **Wakelock Blocker 挂钩补丁往返**：`wakelock-blocker-callsites.patch`
    （115 行、3 文件）在模拟 CI 顺序的临时树上验证（基线树文件取自 Inkypen
    susfs 分支原文，先打 tree-callsites 的 Kconfig/Makefile 接线、再打本补丁）：
    正向应用后 wakeup.c/Kconfig/Makefile 与目标稿逐文件 identical，反向应用与
    post-rekernel 基线 identical；植入的 `check_for_block()` 与 engstk 原版
    逐字节比对一致。
15. **build-kernel.sh.patch 扩展重验**：加入 Wakelock Blocker 集成段＋符号开启
    ＋olddefconfig 后审计后重新生成（135 行）；往返重验：正向应用与目标稿
    identical、反向应用与脚手架原稿 identical、打完的脚本 `bash -n` 通过；
    新增的 4 条集成审计 grep（hook 存在、Kconfig 接线、Makefile 接线、默认
    名单为空）对往返后的真实文件逐条模拟，均命中、不会误报 FATAL。
16. **Wakelock Blocker 符号闭合**：驱动 .c 的 3 个 extern
    （`list_wl_search`/`wl_blocker_active`/`wl_blocker_debug`）由挂钩补丁在
    wakeup.c 内定义（打完行 36–38）；`check_for_block` 在 wakeup.c 内定义 1 处
    ＋调用 1 处；其调用的 `wakeup_source_deactivate` 有补丁内前置声明且真身
    在同文件（打完行 715）；`ws->name`/`ws->active` 为本文件原有代码自用
    字段；Kconfig 符号、Makefile obj 行、脚本 --enable 与审计 grep 四处引用
    一致（均 `BOEFFLA_WL_BLOCKER`）。
17. **inline_hook_check 复核（本轮增补后）**：新补丁触碰 wakeup.c、
    drivers/Kconfig、drivers/Makefile、scripts/build-kernel.sh，与必查 7 文件
    仍无交集；4 个禁查全词在 `drivers/wakelock-blocker/` 与两份新/改补丁里
    均为 0 命中。

未做的验证（诚实标注）：没有整树编译——本机没有完整内核树（只逐文件拉取了钉版的
相关文件），rekernel.c 与 boeffla_wl_blocker.c 的首次真实编译都是 CI 第一轮；
这也是预估 3–6 轮迭代的主要来源。
另：governor 默认翻转能否过 olddefconfig 本地同样不可验——依据是 GOV_SCHEDUTIL 已
编入、DEFAULT_GOV_SCHEDUTIL 是同一 choice 的合法成员；脚本已加硬审计（olddefconfig
后 grep 不到 `CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y` 即 FATAL），CI 首轮即见分晓，
不会静默出错误包。

---

## 还差什么才能开构建（不在备料职责内）

1. **推送**：把 `prep-rekernel-opt/`（drivers/rekernel、drivers/wakelock-blocker、
   patches、REPORT.md）连同 `patches/build-kernel.sh.patch` 的应用结果推上
   kaixin886/odin-kernel——等用户回消息
   时按攒批约定发起（补丁本身也可由 CI 前的人工步骤应用，或推送时直接提交打好补丁的
   build-kernel.sh，二选一，推送时定）。
2. **工作流**：现有 build.yaml 的 variant/opts 输入直接够用——本轮只跑一次
   **resukisu＋battery（动态档）**，off/smooth 不跑；工作流无需改（如需改动仍须
   用户手贴，403 限制）。
3. **用户手点 Run workflow** 一次，助手不代触发。回滚底牌＝现行已验收 BakaSU 包
   （已在机上），刷坏直接刷回。
4. **刷机验收**（用户 HKF）：刷入动态包，验收点——BakaSU 管理器照常「工作中」；
   `ls /proc/rekernel` 有数字文件；`cat /sys/kernel/rekernel/enabled` 为 1、写 0 后
   NoActive 不再收到事件、写 1 恢复；NoActive 内 binder 状态显示已连接（完整形态）；
   `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor` 为 schedutil（动态档
   落地标志；若 Scene 配置改写过 governor，以 Scene 侧配置为准对照）；
   `cat /proc/cmdline` 含 `rcu_nocbs=0-7`；冻结一批后台后切应用，对比现行包的
   卡顿感；Scene 里 zram 算法设为 lz4 对齐；刷视频与游戏各跑一段看频率升降
   （Scene 悬浮窗或 cpufreq stats）。待机另按备料四的验收方法与现行包基线做
   过夜 %/h 对比（至少两晚取均值）。Wakelock Blocker 只验「在场且空转」：
   `ls /sys/class/misc/boeffla_wakelock_blocker/` 四个节点齐全、
   `cat .../wakelock_blocker` 与 `.../wakelock_blocker_default` 均为空、
   `version` 显示 1.1.0——本轮不写任何名字。
