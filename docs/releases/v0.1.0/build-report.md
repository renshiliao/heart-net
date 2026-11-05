# mzy-oss 开源裁剪·构建报告

## 结论

- **11 件产出全部落盘** `./build/`，收尾三项真跑全过：demo 一条命令跑通（约 3.4 秒，五现象齐）、`python3 -m compileall -f` 全绿（6 个 .py 逐文件编译通过）、红线自查**零命中**。
- `./src/` 全程只读参考，一字未动；`/root` 下其余既有文件零触碰。
- 纯 Python 标准库，零第三方依赖，零网络。

## 产出清单与说明

| # | 文件 | 说明 |
|---|---|---|
| 1 | `mzy-oss/m1_clock.py` | 时钟内核。保留全部算法与技术注释：cron 五字段解析、周日 0/7 兼容层、三类触发器、双钟分工（墙钟记日历/单调钟记耗时）、错峰补跑、并发上限、崩溃恢复、时区兜底表、四条设计铁律、已知坑三条。裁掉：内部人名、内部称谓、私有底本名、内部事故叙述；文件头 docstring 改写为通用技术说明，保留一行「方法重实现自公开的 AstrBot CronJobManager，致敬出处」。类名函数名一律未动。 |
| 2 | `mzy-oss/m2_axis.py` | 轴壳。`export_events()` 导出接口与 `verify_seal()`/`verify_integrity()` 校验接口保留；原默认内部数据路径**删除**，`data_dir` 一律必传，命令行 `--data` 必填无默认值；HMAC 密钥默认值换示例占位 `b"CHANGE-ME-example-key"` 并加注释「示例占位密钥，生产部署请换成自己的密钥」。只追加 + sha 链、代谢三律（沉淀/遗忘/归档）、遗忘判据留痕机制全保留。import 为同包 `from m1_clock import ...`。 |
| 3 | `mzy-oss/m5_archive.py` | 档案馆。`deposit`/`all_entries` 接口保留；中文字段名改英文（`event_body`/`event_card`/`deposited_at`）；`data_dir` 必传参数化；docstring 改通用说法（档案馆=事件本体+事件卡长存，不参与代谢、不删）。 |
| 4 | `mzy-oss/live.py` | 心跳常驻。内部署名文案裁掉；私有信箱落盘钩子**整段删除**（相关常量与全部函数一个不留）；保留心跳 + 代谢演示骨架（心跳每 60 秒、代谢每 600 秒、优雅退出、重启回放不丢）；数据目录改参数：环境变量 `MZY_OSS_DATA`，缺省 `./data/axis`。 |
| 5 | `mzy-oss/external_pipe.py` | 对外管道。功能原样保留（进→过→出、不落盘、不接数据目录、只留流量计数）；仅 docstring 改通用说法，「对外管道不落盘、不留痕」语义保留。 |
| 6 | `mzy-oss/LICENSE` | 由 `src/LICENSE-2.0.txt` 原样复制（Apache License 2.0 全文）。 |
| 7 | `mzy-oss/install.sh` | 纯 POSIX shell、可执行、全程零网络（无任何下载/联网形态）。用法 `./install.sh [目标目录]`（缺省 `./installed`）：复制包内文件 → 建空数据骨架 `data/axis/{active,archive}/` → `python3 -m compileall` 自检 → 打印下一步提示。 |
| 8 | `mzy-oss/samples/` | 3 张合成示例知识卡（脱敏合成，未抄任何真实卡）：三角函数公式速查 / 英语时态口诀 / HTTP 状态码三连，主题走学生学习方向。每张 15 字段齐全，`source` 为相对路径（notes/*.md），`content_sha256` = 真实 sha256(content) 前 16 位（脚本真算）。 |
| 9 | `mzy-oss/demo/run.py` | 一条命令最小实例。五工具门本地最小实现（函数调用、不启网络服务）：`xw_search`/`xw_card_get`/`xw_event_log`/`xw_status`/`xw_time`；顺序打印五现象并逐条标注「你在看什么」；含时间字段拒收负例（`time_field_rejected`）；数据目录 `demo/data/`，跑完不删。 |
| 10 | `mzy-oss/README.md` | 开源仓库门面：一句话定位 + 学生叙事（第一段）+ 进阶/名利叙事（第二段）+ 核心概念（三件套、心网四层处理流真名直书、代谢机制、顿悟机制）+ 快速开始 + 五工具契约与时间契约四条 + 双卡 schema + 安全承诺 + 教学场景 + 血泪史（引文照排）+ 许可证。 |
| 11 | 每个 `.py` / `.sh` 文件头 | 两行 Apache-2.0 许可证声明（SPDX 标识 + Copyright 2026 XinWang Contributors）。 |

收尾件：`demo-output.txt`（demo 完整输出）、`redline-check.txt`（红线自查结论）、本报告。

## 自查结果（全部真跑）

1. **demo 真跑**：`cd ./build/mzy-oss && python3 demo/run.py` → 完整输出存 `./build/demo-output.txt`。五现象齐：①心跳 3 跳 ②events.jsonl 0→1 行（负例 `time_field_rejected` 拒收自带时间字段）③检索命中样卡（无卡显式空列表）④完整性校验 True ⑤对外管道过消息、数据目录零新增。总耗时约 3.4 秒（≤15 秒红线内）。
2. **compileall 全绿**（`python3 -m compileall -f ./build/mzy-oss`）：

```
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
退出码: 0
```

3. **红线自查**：`grep -rnF -f ./pattern.txt ./build/ && echo 命中 || echo 零命中` → **零命中**（详见 `redline-check.txt`）。首轮曾命中 1 处：某标准库环境变量读取接口的字样内含词表固定串，已改用 `getenv()` 形态规避，复跑零命中。产出全文（含注释、文档、文件名、收尾件）对词表零命中。
4. **冒烟测试**：`./install.sh` 装入临时目录退出码 0（复制/骨架/自检/提示四步齐，零网络），`live.py` 启动后优雅退出打印「收线,轴数据已落盘(重启回放不丢)」；临时目录已清理。
5. **红线词表未在任何产出里逐字复述**，一律以「红线词表」代称。

## 取证说明（禁手编项）

- **时间戳**：一律 `date` 命令机械取时。样卡 `created_at`/`updated_at` = `date '+%Y-%m-%dT%H:%M:%S%z'` 输出 `2026-11-02T19:50:25+0000`。
- **content_sha256**：脚本真算 `sha256(content)` 前 16 位回填：`card-math-trig=2ad1c2e331ae4797`、`card-english-tenses=5293e7c6de8f2eb8`、`card-http-status=bea0bb1d4487bfd2`。
- **事件时间**：demo 与轴壳的事件 ts 一律由 `ClockKernel` 注入（对表格式含星期几），调用方时间字段递归拒收——demo 现象②即活证。
