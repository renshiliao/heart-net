#!/usr/bin/env bash
# ============================================================
# usage_report.sh —— 五件保险之一【计量表】的报表件（配套 usage_meter.sh）
# 汇总 usage.jsonl 出日报/周报：纯 POSIX awk（mawk/gawk 通吃），零 LLM、零 token。
# 账目纪律：与 usage_meter.sh sum 同一套整行 schema 校验；
#   坏账报「行号:错误类别」并拒绝出数（exit 3），绝不静默吞掉。
# 版权许可：SPDX-License-Identifier: Apache-2.0（全文见 LICENSE）
#
# 用法示例：
#   bash usage_report.sh day               # 今天的日报
#   bash usage_report.sh day 2026-11-02    # 指定日
#   bash usage_report.sh week              # 最近 7 天（含今天）周报
#   bash usage_report.sh week 2026-11-02   # 以该日收尾的 7 天
# ============================================================

# ---------- 变量置顶 ----------
USAGE_DATA="${USAGE_DATA:-./usage.jsonl}"   # 流水文件路径
DAYS_BACK=6                                  # 周报窗口：收尾日往前共 7 天
# ------------------------------

set -u

[ -f "$USAGE_DATA" ] || { echo "无流水可报（$USAGE_DATA 不存在）——先用 usage_meter.sh log 记账"; exit 0; }

# 校验+聚合（POSIX awk）：整行 schema + -1 成对 + ≤15 位；坏账输出 E 行，好账按日聚合
check_and_aggregate() {
    awk '
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
            d = substr($0, RSTART+6, 10)
            if (tin+0 < 0) { miss[d]++; next }
            n[d]++; si[d] += tin+0; so[d] += tout+0
        }
        END {
            for (d in n) printf "T %s %d %d %d %d %d\n", d, n[d], si[d], so[d], si[d]+so[d], miss[d]+0
        }' "$USAGE_DATA"
}

print_table() {
    echo "日期        调用  tokens_in  tokens_out  合计   未取到数"
    echo "----------  ----  ---------  ----------  -----  --------"
    local total_n=0 total=0 total_miss=0
    while read -r _ d n si so t miss; do
        [ -n "$d" ] || continue
        printf "%s  %4d  %9d  %10d  %5d  %8d\n" "$d" "$n" "$si" "$so" "$t" "$miss"
        total_n=$((total_n + n)); total=$((total + t)); total_miss=$((total_miss + miss))
    done
    echo "----------  ----  ---------  ----------  -----  --------"
    printf "合计        %4d                     %5d  %8d\n" "$total_n" "$total" "$total_miss"
}

# 校验先行：有坏账就报行号拒出数，不给「挑好账算」的假报表
res="$(check_and_aggregate)"
errs="$(printf '%s\n' "$res" | grep '^E ' || true)"
if [ -n "$errs" ]; then
    echo "计量表：$USAGE_DATA 有坏账，不给数（防脏账）：" >&2
    printf '%s\n' "$errs" | awk '{printf "  第 %s 行：%s\n", $2, $3}' >&2
    exit 3
fi

case "${1:-day}" in
    day)
        want="${2:-$(date '+%Y-%m-%d')}"
        echo "== 日报 $want =="
        printf '%s\n' "$res" | awk -v d="$want" '$2 == d' | sort -k2,2 | print_table
        ;;
    week)
        end="${2:-$(date '+%Y-%m-%d')}"
        start="$(date -d "$end -${DAYS_BACK} day" '+%Y-%m-%d' 2>/dev/null || date -v-"${DAYS_BACK}"d -j -f '%Y-%m-%d' "$end" '+%Y-%m-%d')"
        echo "== 周报 $start ~ $end =="
        printf '%s\n' "$res" | awk -v s="$start" -v e="$end" '$2 >= s && $2 <= e' | sort -k2,2 | print_table
        ;;
    *)
        echo "用法：bash usage_report.sh day [YYYY-MM-DD] | week [YYYY-MM-DD]" >&2
        exit 2 ;;
esac
