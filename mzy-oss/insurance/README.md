# 开源版保险机制（insurance/）

- 生成：2026-11-03T03:54:10+08:00（CST，date 机械取时）
- 撰：CC（设计+实装）·复核：Codex（逐件复核+实测）·验收人：老吴
- 依据：设计总纲§7 三问补强（防呆件 D1-D8）、§8 血泪史（哨兵空转烧 10 亿 token 真事故）
- 许可：Apache-2.0（全文见 LICENSE，各文件头 SPDX 一致）

## 这是什么

五件纯脚本/配置的「保险」，保护用户烧不穿 token——**零 token 或省 token**：
计量可见、超限止血、哨兵用脚本不用模型、同题撞墙自动停、配置错先体检。

| # | 件 | 文件 | 干什么 | 对应总纲 |
|---|----|------|--------|----------|
| 1 | 计量表 | `usage_meter.sh` + `usage_report.sh` | 每次 LLM 调用记一行 token 流水（append-only、只记数字不记内容、flock 串行追加）；日报/周报汇总；坏账报行号拒出数 | §7 问一 |
| 2 | 日限额+熔断 | `daily_limit.conf` + `fuse.sh` | 一行日限额；80% 告警、100% 熔断——**只断 LLM 调用，心跳/落盘/哨兵照跑**（花钱的路断了，记忆的路不断）；次日自动复位；读用量/写状态失败一律拒绝放行（fail-closed，exit 3） | §7 问一/D2 |
| 3 | 脚本哨兵 | `sentinel.sh` | 纯 bash 三合一模板（目录守望/日志守望/磁盘水位，参数切换）；输出确定性、空闲静默有事才响 | §7 D1/§8 教训 |
| 4 | 撞墙熔断 | `circuit.sh` | 同题失败 3 次自动熔断该任务+落盘现场+提示上报；敲墙流水=append-only `$sig.knocks`（并发不丢数），熔断/清零/人工复位落 `circuit_events.jsonl` 审计行；坏状态行=报损拒跑 | §7 D2 |
| 5 | 防呆配置体检 | `doctor.sh` | 限额单位/路径存在/端口可达/计量表格式体检；红项指到行号，全绿才许启动 | §7 D3 |

## 用法速查

```bash
# 1 计量表：每次 LLM 调用后记一笔（取不到数记 -1，绝不估数）
bash usage_meter.sh log --in 1200 --out 350 --tool chat
bash usage_report.sh day        # 日报
bash usage_report.sh week       # 周报

# 2 日限额+熔断：限额写进 daily_limit.conf 一行 DAILY_LIMIT=数字
bash fuse.sh gate               # LLM 调用前问路：0=放行 1=熔断 2=80%告警(仍放行)
bash fuse.sh status             # 看今日累计/限额/状态
bash fuse.sh resume             # 手动复位（例外出口，常规是次日自动复位）

# 3 脚本哨兵：三合一，靠第一个参数切
bash sentinel.sh dir  ~/data/            # 目录有变动才响
bash sentinel.sh log  ./live.log 'ERROR|FATAL'   # 有新错误行才响
bash sentinel.sh disk /var/data 80          # 越水位线才响

# 4 撞墙熔断：同题（同签名）失败 3 次自动停
bash circuit.sh check mytask    # 问路 0=可跑 1=已熔断
bash circuit.sh knock mytask    # 失败敲一下
bash circuit.sh ok mytask       # 成功清零
bash circuit.sh reset mytask    # 上报后人工恢复

# 5 体检：全绿才许启动
bash doctor.sh && echo 可以启动
```

接线示例（LLM 调用前后；注意 fuse 退出码语义：**0=放行 2=过80%告警(仍放行) 1=熔断拒绝 3=基础设施错(拒)**）：

```bash
bash fuse.sh gate; rc=$?
[ "$rc" = 1 ] || [ "$rc" = 3 ] && exit 1     # 只在熔断/基础设施错时拒；2=告警仍放行，别误杀
bash circuit.sh check mytask || exit 1       # 撞墙熔断中的任务不跑
# ... 发起 LLM 调用，拿到 provider 的 usage ...
bash usage_meter.sh log --in N --out N --tool chat
bash fuse.sh gate                            # 顺手看是否越 80%/100% 档
```

## 保险声明（三层）

**① 默认保护，为了你好。**
按 README 把 gate/check/usage_meter 接进调用链、sentinel 挂上 cron、doctor 接进启动流程，这套保险即默认生效（未接线不构成保护，装完请先跑一遍 doctor）：计量表默认只记数字不记内容，日限额默认给出示例值，哨兵默认静默有事才响，撞墙 3 次默认熔断，doctor 默认拦下红项。它们在你睡着的时候替你看着钱包——哨兵用脚本（零成本），模型只在有事时醒。这来自真事故：某管家系统哨兵每 2 分钟叫醒模型看一眼「有没有活」，空转 3583 次、单日烧掉 10 亿 token。**默认开着，是为了让你睡得着觉。**

**② 拆保险，后果自负。**
限额调大、熔断用 resume、哨兵不跑、doctor 红项/黄项强行启动——其中 fuse/circuit 的熔断、告警、复位、成功清零都落 `fuse_events.jsonl`/`circuit_events.jsonl` 审计行，普通敲墙落 `$sig.knocks` 敲墙流水（两类落点分开：审计行=状态事件，敲墙流水=失败计数）；调大限额、不跑哨兵、绕过 doctor 本身不留痕，别指望事后追。留痕不拦人：拆了保险再烧穿 token，本套件不替你兜底；provider 侧的硬限额（官方月预算）也请自己去后台设，心网不替代 provider 账单闸。

**③ 只对装保险时负责。**
本保证只覆盖「按 README 接线装好、doctor 全绿（红黄皆无）」的状态。改动本目录脚本、换掉配置格式、把流水文件喂给别的程序改写（usage.jsonl 是 append-only，改写=账本作废）之后的事故，不在负责范围。保险的边界就是这套脚本的边界：它们管 token 烧不穿，不管业务对不对。

## 文件单

| 文件 | 说明 |
|------|------|
| `usage_meter.sh` | 计量表：log 记一笔 / sum 今日小计 |
| `usage_report.sh` | 报表：day 日报 / week 周报（与 sum 同源同数对账） |
| `daily_limit.conf` | 一行日限额 + doctor 体检项（CHECK_PATH/CHECK_PORT） |
| `fuse.sh` | 熔断器：gate/status/resume；80% 告警 100% 熔断；次日自动复位 |
| `sentinel.sh` | 脚本哨兵三合一：dir/log/disk；三态输出 OK/WARN/CRIT（退出码 0/1/2） |
| `circuit.sh` | 撞墙熔断：knock/ok/check/reset；现场落盘 `.scene` |
| `doctor.sh` | 体检：限额单位/路径/端口/计量表格式；红项指行号，全绿 exit 0 |
| `实测记录-20261103.md` | 五件各跑一遍真场景的实测原文 |

## 设计纪律（全五件共守）

- 变量置顶、中文注释、用法示例、Apache-2.0 头——每件文件头部都有。
- 时间戳一律 `date` 机械取时，禁手编。
- 计量表 append-only、**只记数字不记内容**（零内容字段，天然不泄底）；追加=flock 串行+短行 O_APPEND（原子边界：短行、单次 write、O_APPEND、Linux 本地文件系统）。
- 取不到 token 数记 `-1` 且 in/out 成对、整数 ≤15 位，不估数（反幻觉纪律延伸：不编数）。
- 账目不静默：**统一账本 schema·全五件同一契约**（整行校验：日期合法段/时区 ±HHMM、tool 1-32、token=-1 或 0..N ≤15 位禁前导零），坏账报「行号:错误类别」并拒出数/拒放行（fail-closed）。
- 状态迁移 flock 串行：熔断器/撞墙熔断读判写加锁，防并发重复告警；circuit 先检后写（坏状态不边坏边追加）。
- 熔断语义只有一套：**花钱的路断了，记忆的路不断**（心跳/落盘/哨兵不陪葬）。
- 哨兵纯 bash 零成本，空闲静默，确定性输出，绝不叫模型值守。

## 可回灌清单（老吴/老周 自用可取之处）

1. **熔断只断花钱路**——把「LLM 调用闸」与「心跳/落盘/哨兵」拆开：日常自用的 mzy/live 也可在 live.py 调 LLM 前挂 `fuse.sh gate`，断供时记忆代谢不停。回灌点：live.py 对外调用口。
2. **-1 不估数纪律**——provider 不给 usage 就记 -1 成对、单列不混入合计；老周的账目统计可直接换用 `usage_meter.sh` 记账口径，账实相符不靠估。回灌点：usage 账目流水。
3. **次日复位靠「熔断日 vs 今日」比对**——不靠 cron、不靠手翻日历，date 一比即复位；比定时任务少一处会坏的钟。回灌点：任何「次日重置」类状态。
4. **哨兵三态确定性输出**（OK/WARN/CRIT+固定一行原因+退出码 0/1/2）——老吴的巡检脚本可统一这个输出契约，喊不喊一眼可判、可被 cron 吞。回灌点：~/mzy/data 巡检。
5. **doctor 红项指行号**——配置体检直接打「第 N 行」而不是「配置有错」；老吴/老周的 conf 类文件都值得挂一个轻体检。回灌点：各 conf 装机/变更后。
6. **撞墙熔断现场落盘**（`.scene`：进程/磁盘/日志尾巴）——失败 3 次自动停+留现场，给上报省一小时猜谜；老周的长跑任务可挂 `circuit.sh` 防同题反复烧。回灌点：长跑/cron 任务入口。
