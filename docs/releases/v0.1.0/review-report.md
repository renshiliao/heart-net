# mzy-oss 开源裁剪复核报告

- 复核时间（`date` 机械取时）：`2026-11-02T20:08:42+0000`
- 复核范围：`./build/` 全树
- 源侧保护：`./src/` 只读，未修改

## 复核结论

### 三关结论

| 关口 | 判定 | 结论 |
|---|---|---|
| 第一关·红线 | **[过]** | 包体、注释、docstring、README、样例卡 JSON、demo 输出、文件名与目录名、报告类文件均按最终状态复跑，红线词表**零命中**。未发现真实内部数据路径、真实密钥样值或真实卡文切片；HMAC 示例值含 `CHANGE-ME` 并明示占位，样例卡均为合成件。 |
| 第二关·许可 | **[过]** | `LICENSE` 为完整 Apache License 2.0，且与只读源侧许可正文哈希一致；全部 `.py`/`.sh` 均有 SPDX 与 Copyright 两行声明头；README 已明确提及许可证。 |
| 第三关·演示 | **[过]** | 一条命令实跑退出码 0；五现象齐，伪造时间字段负例真打印 `time_field_rejected`；`compileall` 全绿；接口、必传参数、占位密钥、活体裁剪和对外管道裁剪均通过保真检查。 |

### README 专项逐项结论

| 专项 | 判定 | 改动记录 |
|---|---|---|
| ① 一句话定位与两段价值叙事 | **[过]** | 保留“给 AI 装上记忆和时间感的轻量框架”定位；学生叙事覆盖学了就忘、重点抓不住、笔记散乱，以及可检索/可换绑/可复用、攒卡、考前检索、跑通进本事账；进阶叙事与名利叙事完整。删去容易形成性能夸口的短时表述。 |
| ② 核心概念 | **[过]** | 时钟内核、记忆时间轴、事件卡功能语，以及元层/知识层/能力层/事件层真名均完整；代谢三律、活跃区活物化、跨卡相撞与跑通进本事账均写明。无缺项。 |
| ③ 快速开始 | **[过]** | `python3 demo/run.py` 为唯一演示命令，并明确离线、零配置、零 API key；删除未必要的耗时数字。 |
| ④ 五工具契约与时间契约 | **[过]** | 五工具参数、返回和错误语义齐全；强化 `xw_status` 不提供权威时间、`xw_time` 不接受调用方时间参数。递归拒收、服务端原子注入、唯一取时口、墙钟/单调钟分离四条齐全。 |
| ⑤ 双卡 schema | **[过]** | 知识卡对外版 15 字段、事件卡对外版 6 字段均逐项列明，可选扩展 `event_id`、`tags`、`content_sha256` 齐全。无改动。 |
| ⑥ 安全承诺 | **[过]** | 只列三样不泄内容；对外零留痕、数据全本地、当前发布物开源免费 Apache-2.0 三条硬承诺齐全。 |
| ⑦ 教学场景 | **[过]** | 老师整理教学重点、学生建立个人知识库两个场景均写明。无改动。 |
| ⑧ 保险声明 | **[过]** | 新增独立章节，写明计量表、日限额 + 熔断、脚本巡检、撞墙熔断；三层意涵分别为默认保护、拆除自负、只对装着保险时的体验负责。 |
| ⑨ 血泪史 | **[过]** | 删除额外条目；只保留规定的两句核心表达，不添枝节。 |
| ⑩ 口径铁律 | **[过]** | 删除速度夸口与省钱口号；补明“工具不是魔法，需要动手能力”、不暗示装了变天才、不承诺永远免费或装了就怎样；补明面向所有人、骨架可魔改、默认保护兜底、下限靠设计、上限留给用户。除 ⑨ 指定核心原句外未列额外用量数字。README 无人物化名或外号字样。 |

## 实跑证据

### 第一关：红线实跑

命令：

```bash
grep -rnF -f ./pattern.txt ./build/ && echo 命中 || echo 零命中
```

输出原文：

```text
零命中
```

### 第三关：演示实跑

命令：

```bash
cd ./build/mzy-oss && python3 demo/run.py
```

完整输出原文：

```text
========== mzy-oss 最小实例演示 ==========
数据目录: demo/data/（跑完不删）

=== 现象① 心跳启动并跳动 ===
[心跳] 2026-11-03 04:08 (CST) 周二 第1跳 kind=timer delay=0.01s
[心跳] 2026-11-03 04:08 (CST) 周二 第2跳 kind=timer delay=0.02s
[心跳] 2026-11-03 04:08 (CST) 周二 第3跳 kind=timer delay=0.02s
你在看什么：时钟内核唤醒线程到点合成事件喂给回调，共跳动 3 跳（演示用秒级短间隔；线上默认 60 秒一跳）。

=== 现象② 事件入轴 ===
xw_event_log → {"ts": "2026-11-03 04:08 (CST) 周二", "time_source": "server", "source": "demo", "status": "已完成", "content": "演示事件：跑通一次三角函数公式速查卡", "sha": "7f44c1cea022"}
events.jsonl: 0 行 → 1 行（长了 1 行）
负例（调用方自带时间字段）→ {"error": "time_field_rejected", "field": "ts"}
xw_time → {"now_iso": "2026-11-03 04:08 (CST) 周二", "now_human": "2026-11-03 04:08 (CST) 周二", "time_source": "server"}
你在看什么：事件卡的 ts 由服务端原子注入且带星期几；调用方伪造时间字段一律拒收（time_field_rejected），xw_time 是唯一取时口。

=== 现象③ xw_search 检索命中样卡 ===
xw_search('三角函数 公式') → [{"id": "card-math-trig", "title": "高等数学三角函数公式速查", "trigger": "三角函数|公式|sin|cos|二倍角", "snippet": "# 三角函数公式速查"}]
xw_card_get('card-math-trig') 命中整卡：title=高等数学三角函数公式速查 sha16=2ad1c2e331ae4797 字段数=15
xw_search('不存在的关键词_zzz') → []（无卡，零空手）
你在看什么：关键词命中合成样卡返回摘要，取整卡给全 15 字段；无命中显式空列表，不藏不装。

=== 现象④ 完整性校验通过 ===
xw_status → {"events": 1, "cards": 3, "integrity_ok": true, "runtime_sec": 3.3}
verify_integrity → True
你在看什么：HMAC 封条校验通过——轴文件若被绕程序直改，这里当场露馅。

=== 现象⑤ external_pipe 过一条消息 ===
pass_through → [已转发]hello-mzy-oss；transited_count=1
数据目录新增文件数: 0
你在看什么：对外管道进→过→出，不落盘不留痕——数据目录零新增就是活证。

========== 演示完毕 ==========
数据目录 demo/data/ 已保留（跑完不删），欢迎亲自开箱验货。
```

退出码：`0`。

五现象逐项：

- 心跳跳动：**[过]**，三跳均真打印。
- 事件入轴：**[过]**，`events.jsonl` 从零行到一行。
- 检索命中：**[过]**，命中合成样卡并取得 15 字段整卡，无命中显式空列表。
- 完整性校验通过：**[过]**，`integrity_ok=true` 且 `verify_integrity → True`。
- 对外管道零新增：**[过]**，消息转发成功且数据目录新增文件数为零。
- 负例拒收：**[过]**，调用方自带时间字段时真打印 `{"error": "time_field_rejected", "field": "ts"}`。

与 `./build/demo-output.txt` 对照：

- 标准化机械时间、心跳短间隔和单调耗时后，结构与非动态文字**一致**；复核程序返回“退出码: 0、stderr: 空、标准化对照: 一致”。
- 原始动态差异仅限：心跳机械时间、`delay` 小数和 `runtime_sec` 小数；这些值由机械时钟、短等待和单调计时实时产生，不构成内容差异。

### 第三关：编译实跑

命令：

```bash
python3 -m compileall ./build/mzy-oss
```

完整输出原文：

```text
Listing './build/mzy-oss'...
Listing './build/mzy-oss/demo'...
Listing './build/mzy-oss/demo/data'...
Listing './build/mzy-oss/demo/data/active'...
Listing './build/mzy-oss/demo/data/archive'...
Compiling './build/mzy-oss/demo/run.py'...
Compiling './build/mzy-oss/external_pipe.py'...
Compiling './build/mzy-oss/live.py'...
Compiling './build/mzy-oss/m1_clock.py'...
Compiling './build/mzy-oss/m2_axis.py'...
Compiling './build/mzy-oss/m5_archive.py'...
Listing './build/mzy-oss/samples'...
```

退出码：`0`，六个 Python 文件逐文件编译通过。

## 许可与保真检查

| 检查项 | 判定 | 证据 |
|---|---|---|
| Apache License 2.0 全文 | **[过]** | `LICENSE` 共 202 行；与只读源侧许可正文 SHA-256 同为 `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`。 |
| `.py`/`.sh` 声明头 | **[过]** | 七个 Python/Shell 文件均有连续的 `SPDX-License-Identifier: Apache-2.0` 与 `Copyright 2026 XinWang Contributors, Apache License, Version 2.0` 两行。 |
| README 许可证 | **[过]** | README 独立许可证章节明确写 Apache License 2.0 并链接 `LICENSE`。 |
| `m2_axis.py` 接口 | **[过]** | `export_events`、`verify_seal`、`verify_integrity` 均在；`AxisStore`、`InternalAxis`、`export_events` 的 `data_dir` 均必传且无默认值。 |
| HMAC 示例占位 | **[过]** | 示例密钥含 `CHANGE-ME`，相邻中文注释明示生产部署替换；未发现真实密钥样值。 |
| `live.py` 裁剪 | **[过]** | 无私有管线函数、常量或落盘钩子残留；只保留心跳、代谢、参数化数据目录与优雅退出。 |
| `external_pipe.py` 裁剪 | **[过]** | 不接收 `data_dir`，不导入文件系统模块，不写文件；仅保留消息转发与流量计数。 |
| 样例卡合成性 | **[过]** | 三张卡的标识与标题在只读源侧零命中；三张均为 15 字段，`content_sha256` 与正文真算值一致。 |
| 路径与敏感值 | **[过]** | 包内未发现用户目录或真实内部数据路径，未发现账号密码或真实密钥赋值；演示只使用包内相对演示目录。 |

## 问题与修正清单

1. **README 保险章节不完整**：原有内容未覆盖四类默认保护，也未清楚拆出三层责任意涵。已新增“保险声明”，逐层补齐。
2. **README 血泪史原含额外条目**：已压缩为规定的两句核心表达，删除其余枝节内容。
3. **README 有速度夸口和省钱口号**：已删除，不夸功效、不喊省钱。
4. **README 缺口径反向说明**：已补“工具不是魔法，需要动手能力”、不暗示装了变天才、不承诺永远免费或装了就怎样，并补齐开源定位。
5. **五工具错误语义有两处不够明确**：已强化 `xw_status` 不提供权威时间、`xw_time` 不接受调用方时间参数。
6. **未发现红线、许可、接口保真、密钥占位、样例合成性或裁剪残留问题**，无需改动代码。

## 终判

三关全部通过，README 十项专项全部通过；红线在最终报告落盘后仍以规定命令复跑至零命中，演示与编译均真跑全绿。

**REVIEW_VERDICT: PASS**
