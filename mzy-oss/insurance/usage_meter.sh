#!/usr/bin/env bash
# ============================================================
# usage_meter.sh —— 五件保险之一【计量表】
# 每次 LLM 调用后记一行 token 流水到 usage.jsonl：
#   append-only（只追加不改写）、只记用量元数据不记内容、零 token 成本。
# 版权许可：SPDX-License-Identifier: Apache-2.0（全文见 LICENSE）
#
# 用法示例：
#   bash usage_meter.sh log --in 1200 --out 350 --tool chat
#   bash usage_meter.sh log --in -1 --out -1 --tool chat   # 取不到数记 -1，绝不估数
#   bash usage_meter.sh sum                                # 今日小计
#
# 记录格式（JSONL，一行一次调用，零内容字段）：
#   {"ts":"2026-11-03T03:30:00+0800","tool":"chat","tokens_in":1200,"tokens_out":350}
#
# 原子边界（正式契约）：短行、单次 write、O_APPEND、Linux 本地文件系统，
#   并用 flock 把单行追加串行化——两种机制齐上，防并发交错。
# 账目纪律：坏行不静默——sum 对每行做整行 schema 校验，坏账报
#   「行号:错误类别」并拒绝出数（exit 3），绝不把坏账吞掉或当 0。
# ============================================================

# ---------- 变量置顶 ----------
USAGE_DATA="${USAGE_DATA:-./usage.jsonl}"   # 流水文件路径（可用环境变量换）
LOCKFILE=""                                  # flock 锁文件（main 里随 USAGE_DATA 定值）
TS_FMT='+%Y-%m-%dT%H:%M:%S%z'               # 时间戳一律 date 机械取时，禁手编
TOOL_PAT='^[A-Za-z0-9_.-]{1,32}$'           # tool 白名单：只收安全字符，防脏 JSON
# ------------------------------

set -u

LOCKFILE="${USAGE_DATA}.lock"   # 追加串行锁（flock），与数据文件分开

# 记一行流水：token 只收 0..N（≤15 位，禁前导零）或成对 -1（-1=provider 没给数，不估数）
cmd_log() {
    local tin="" tout="" tool="unknown"
    while [ $# -gt 0 ]; do
        case "$1" in
            --in)   tin="${2:-}";  shift 2 ;;
            --out)  tout="${2:-}"; shift 2 ;;
            --tool) tool="${2:-}"; shift 2 ;;
            *) echo "计量表：不明参数 $1" >&2; exit 2 ;;
        esac
    done
    [ -n "$tin" ]  || { echo "计量表：缺 --in" >&2;  exit 2; }
    [ -n "$tout" ] || { echo "计量表：缺 --out" >&2; exit 2; }
    # 防呆：token 只收 -1 或非负整数 ≤15 位禁前导零（-2/超长/007 之类一律拒）
    printf '%s' "$tin"  | grep -Eq '^(-1|0|[1-9][0-9]{0,14})$' || { echo "计量表：--in 须为非负整数(≤15位,禁前导零)或 -1" >&2; exit 2; }
    printf '%s' "$tout" | grep -Eq '^(-1|0|[1-9][0-9]{0,14})$' || { echo "计量表：--out 须为非负整数(≤15位,禁前导零)或 -1" >&2; exit 2; }
    # 防呆：-1 必须 in/out 成对（一半没数一半有数=脏数据）
    if { [ "$tin" = "-1" ] && [ "$tout" != "-1" ]; } || { [ "$tout" = "-1" ] && [ "$tin" != "-1" ]; }; then
        echo "计量表：-1 必须 in/out 成对（都不估数）" >&2; exit 2
    fi
    # 防呆：tool 白名单，防引号注入弄脏 JSON
    printf '%s' "$tool" | grep -Eq "$TOOL_PAT" || { echo "计量表：--tool 只收字母数字._- （≤32 字符）" >&2; exit 2; }
    # 防呆：父目录先建好；写失败必须显式失败，绝不假报成功
    mkdir -p "$(dirname "$USAGE_DATA")" 2>/dev/null
    [ -d "$(dirname "$USAGE_DATA")" ] || { echo "计量表：目录建不了 $(dirname "$USAGE_DATA")" >&2; exit 3; }
    local ts
    ts="$(date "$TS_FMT")"
    # 显式三步判定（不靠复合重定向的返回码）：开锁文件→取 flock→写数据，任一失败 exit 3
    exec 9>>"$LOCKFILE" 2>/dev/null || { echo "计量表：锁文件开不了 $LOCKFILE（没记上，不算数）" >&2; exit 3; }
    if command -v flock >/dev/null 2>&1; then
        flock 9 || { echo "计量表：加锁失败（没记上，不算数）" >&2; exit 3; }
    fi
    if ! printf '{"ts":"%s","tool":"%s","tokens_in":%s,"tokens_out":%s}\n' "$ts" "$tool" "$tin" "$tout" >> "$USAGE_DATA"; then
        echo "计量表：写入失败 $USAGE_DATA（没记上，不算数）" >&2; exit 3
    fi
    echo "计量表：已记一笔 in=$tin out=$tout tool=$tool -> $USAGE_DATA"
}

# 今日小计（与 usage_report.sh day 同源同数；POSIX awk，mawk/gawk 通吃）
# 校验：整行 schema + -1 成对 + ≤15 位；坏账报「行号:错误类别」，有一条就不给数
cmd_sum() {
    [ -f "$USAGE_DATA" ] || { echo "今日无流水（$USAGE_DATA 不存在）"; return 0; }
    local today out errs
    today="$(date '+%Y-%m-%d')"
    out="$(awk -v d="$today" '
        /^[[:space:]]*$/ { next }
        {
            # 【统一账本 schema·全五件同一契约】整行校验：日期合法段(月01-12/日01-31/时00-23/分秒00-59/时区±HHMM)、
            # tool 1-32 安全字符、token=-1 或 0..N(≤15位禁前导零)——结构不对=坏账，不静默
            if ($0 !~ /^\{"ts":"[0-9][0-9][0-9][0-9]-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9][+-]([01][0-9]|2[0-3])[0-5][0-9]","tool":"[A-Za-z0-9_.-]{1,32}","tokens_in":(-1|0|[1-9][0-9]{0,14}),"tokens_out":(-1|0|[1-9][0-9]{0,14})\}$/) {
                printf "E %d 结构不合规(含日期/时区/tool/整数)\n", NR; next
            }
            match($0, /"tokens_in":-?[0-9]+/); s = substr($0, RSTART, RLENGTH); sub(/"tokens_in":/, "", s); tin = s
            match($0, /"tokens_out":-?[0-9]+/); s = substr($0, RSTART, RLENGTH); sub(/"tokens_out":/, "", s); tout = s
            if ((tin == -1) != (tout == -1)) { printf "E %d -1必须成对\n", NR; next }
            match($0, /"ts":"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)
            if (substr($0, RSTART+6, 10) != d) next
            if (tin+0 < 0) { miss++; next }
            n++; si += tin+0; so += tout+0
        }
        END { printf "T %d %d %d %d\n", n+0, si+0, so+0, miss+0 }' "$USAGE_DATA")"
    errs="$(printf '%s\n' "$out" | grep '^E ' || true)"
    if [ -n "$errs" ]; then
        echo "计量表：$USAGE_DATA 有坏账，不给数（防脏账）：" >&2
        printf '%s\n' "$errs" | awk '{printf "  第 %s 行：%s\n", $2, $3}' >&2
        exit 3
    fi
    printf '%s\n' "$out" | awk -v d="$today" '$1 == "T" {
        printf "%s 调用=%d 次 tokens_in=%d tokens_out=%d 合计=%d（取不到数 %d 行单列）\n", d, $2, $3, $4, $3+$4, $5
    }'
}

case "${1:-}" in
    log) shift; cmd_log "$@" ;;
    sum) cmd_sum ;;
    *) cat <<'EOF'
用法：
  bash usage_meter.sh log --in N --out N [--tool 名称]   记一笔调用流水
  bash usage_meter.sh sum                                今日小计
说明：--in/--out 为 provider 返回的 usage 数字（非负整数 ≤15 位）；
      取不到写 -1（成对），不估数。坏账不静默：sum 报行号并拒绝出数。
EOF
       [ -n "${1:-}" ] && exit 2 || exit 0 ;;
esac
