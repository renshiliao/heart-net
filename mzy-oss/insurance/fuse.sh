#!/usr/bin/env bash
# ============================================================
# fuse.sh —— 五件保险之二【日限额+熔断】
# 语义：「花钱的路断了，记忆的路不断」——
#   超限 80% 告警、100% 熔断：只断 LLM 调用，心跳/落盘/哨兵照跑。
#   次日自动复位（熔断日与今日比对，date 机械取时）——
#   复位后仍按今日累计重判：今天若仍超限，会立刻再熔断。
# 失败安全（fail-closed）：读用量/写状态失败一律拒绝放行（exit 3），
#   绝不把「不知道」当「没超限」。
# 版权许可：SPDX-License-Identifier: Apache-2.0（全文见 LICENSE）
#
# 用法示例：
#   bash fuse.sh gate                    # 每次 LLM 调用前问一声：
#                                        #   0=放行 2=过80%告警(仍放行) 1=熔断拒绝 3=基础设施错(拒)
#   bash fuse.sh status                  # 看今日累计/限额/状态
#   bash fuse.sh resume                  # 手动复位（次日 100% 熔断自动复位，此命令是例外出口）
#   DAILY_LIMIT=100 bash fuse.sh gate    # 不改配置文件，临时换限额
# ============================================================

# ---------- 变量置顶 ----------
FUSE_CONF="${FUSE_CONF:-./daily_limit.conf}"  # 配置：一行日限额数字
USAGE_DATA="${USAGE_DATA:-./usage.jsonl}"     # 计量表流水（usage_meter.sh 写的）
FUSE_STATE="${FUSE_STATE:-./fuse_state}"      # 熔断状态目录（自动建，建不了=拒绝放行）
WARN_RATIO=80                                 # 告警档：当日累计 ≥ 限额 80%
TRIP_RATIO=100                                # 熔断档：当日累计 ≥ 限额 100%
TS_FMT='+%Y-%m-%dT%H:%M:%S%z'
# ------------------------------

set -u

# 状态目录先行：建不了就拒绝放行（fail-closed），不许默默继续
if ! mkdir -p "$FUSE_STATE" 2>/dev/null || [ ! -d "$FUSE_STATE" ]; then
    echo "熔断器：状态目录建不了 $FUSE_STATE——拒绝放行（fail-closed，exit 3）" >&2
    exit 3
fi

today() { date '+%Y-%m-%d'; }

# 状态文件原子写：临时文件+mv，防半截文件
atomic_write() {  # $1=文件 $2=内容
    local tmp="$FUSE_STATE/.tmp.$$"
    printf '%s\n' "$2" > "$tmp" && mv "$tmp" "$1"
}

# 读限额：环境变量优先，其次配置文件（DAILY_LIMIT=数字 或裸数字行）
read_limit() {
    if [ -n "${DAILY_LIMIT:-}" ]; then printf '%s' "$DAILY_LIMIT"; return; fi
    [ -f "$FUSE_CONF" ] || { echo "熔断器：配置不存在 $FUSE_CONF（且未设 DAILY_LIMIT 环境变量）——拒绝放行" >&2; exit 3; }
    local v
    v="$(grep -E '^[[:space:]]*DAILY_LIMIT[[:space:]]*=' "$FUSE_CONF" | tail -1 | sed 's/.*=//; s/[[:space:]]//g')"
    [ -n "$v" ] || v="$(grep -Ev '^[[:space:]]*(#|$)' "$FUSE_CONF" | grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' | tail -1 | tr -d '[:space:]')"
    printf '%s' "$v"
}

# 今日累计 in+out（POSIX awk；取不到数的 -1 行不估、不混入）
# 整行 schema 校验（不靠字段子串命中冒充整行合法）：任何非空坏行=「不知道」，
# 一律 fail-closed 拒绝放行（exit 3），绝不当 0
today_total() {
    if [ ! -f "$USAGE_DATA" ]; then printf '0 0\n'; return 0; fi   # 还没记账=真 0，不是失败
    local out
    out="$(awk -v d="$(today)" '
        /^[[:space:]]*$/ { next }
        {
            # 【统一账本 schema·全五件同一契约】整行校验：日期合法段、tool 1-32、token=-1 或 0..N(≤15位禁前导零)
            if ($0 !~ /^\{"ts":"[0-9][0-9][0-9][0-9]-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9][+-]([01][0-9]|2[0-3])[0-5][0-9]","tool":"[A-Za-z0-9_.-]{1,32}","tokens_in":(-1|0|[1-9][0-9]{0,14}),"tokens_out":(-1|0|[1-9][0-9]{0,14})\}$/) {
                bad++; next
            }
            match($0, /"tokens_in":-?[0-9]+/); s = substr($0, RSTART, RLENGTH); sub(/"tokens_in":/, "", s); tin = s+0
            match($0, /"tokens_out":-?[0-9]+/); s = substr($0, RSTART, RLENGTH); sub(/"tokens_out":/, "", s); tout = s+0
            if ((tin == -1) != (tout == -1)) { bad++; next }   # -1 半对=坏账
            match($0, /"ts":"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)
            if (substr($0, RSTART+6, 10) != d) next
            if (tin < 0 || tout < 0) next
            si += tin; so += tout
        }
        END { printf "%d %d %d\n", si+0, so+0, bad+0 }' "$USAGE_DATA")"
    if ! printf '%s' "$out" | grep -Eq '^[0-9]+ [0-9]+ [0-9]+$'; then
        echo "熔断器：用量读取失败 $USAGE_DATA——拒绝放行（fail-closed）" >&2; exit 3
    fi
    local si so bad
    read -r si so bad <<EOF
$out
EOF
    if [ "$bad" -gt 0 ]; then
        echo "熔断器：$USAGE_DATA 有 $bad 行坏账（读不出用量=不知道）——拒绝放行（fail-closed）" >&2; exit 3
    fi
    printf '%s %s\n' "$si" "$so"
}

# 熔断留痕：append-only 事件行（只记数字与状态，不记内容）；写失败=拒绝放行
note() {
    if ! printf '{"ts":"%s","event":"fuse","status":"%s","detail":"%s"}\n' \
        "$(date "$TS_FMT")" "$1" "$2" >> "$FUSE_STATE/fuse_events.jsonl"; then
        echo "熔断器：事件写入失败——拒绝放行（fail-closed）" >&2; exit 3
    fi
}

# 次日自动复位：熔断日已是往日 → 清档后**继续按今日累计重判**（今天仍超会再熔断）
# gate/status 两路共用：复位不该只在问路时发生，看表也得见到新的一天
auto_reset() {
    if [ -f "$FUSE_STATE/tripped" ]; then
        local tripday
        tripday="$(cut -c1-10 "$FUSE_STATE/tripped")"
        if [ "$(today)" != "$tripday" ]; then
            rm -f "$FUSE_STATE/tripped"
            note "复位" "次日自动复位 tripday=$tripday today=$(today)（随后按今日累计重判）"
            echo "熔断器：新的一天（熔断日 $tripday 已过），自动复位（按今日累计重判）。"
        fi
    fi
}

cmd_gate() {
    local limit total_in total_out total totals
    # flock 串行化状态迁移：读判写一体加锁，防并发重复告警/重复熔断
    exec 9>>"$FUSE_STATE/fuse.lock"
    if command -v flock >/dev/null 2>&1; then flock 9; fi
    if ! limit="$(read_limit)"; then exit 3; fi   # 子 shell 里的 exit 3 不会传出来，必须查返回码
    if ! printf '%s' "$limit" | grep -Eq '^[0-9]+$' || [ "$limit" -le 0 ]; then
        echo "熔断器：日限额须为正整数（单位 token/日），读到：'$limit'——拒绝放行" >&2; exit 3
    fi
    # today_total 在子 shell 里跑：必须查返回码，别让 exit 3 困在 $() 里
    if ! totals="$(today_total)"; then exit 3; fi
    read -r total_in total_out <<EOF
$totals
EOF
    total=$((total_in + total_out))

    auto_reset

    if [ -f "$FUSE_STATE/tripped" ]; then
        echo "【已熔断】今日 LLM 调用停走：累计 $total/$limit token（100% 越限）。"
        echo "          花钱的路断了，记忆的路不断：心跳/落盘/哨兵照跑。"
        echo "          次日自动复位；急用可 bash fuse.sh resume（后果自负）。"
        exit 1
    fi

    if [ $((total * 100)) -ge $((limit * TRIP_RATIO)) ]; then
        date '+%Y-%m-%d' > "$FUSE_STATE/tripped" || { echo "熔断器：熔断标记写入失败——拒绝放行" >&2; exit 3; }
        note "熔断" "100% 越限 total=$total limit=$limit"
        echo "【熔断】当日累计 $total 已达限额 $limit 的 100%：LLM 调用即刻停走。"
        echo "        花钱的路断了，记忆的路不断；次日自动复位。"
        exit 1
    fi

    if [ $((total * 100)) -ge $((limit * WARN_RATIO)) ]; then
        if [ ! -f "$FUSE_STATE/warned_$(today)" ]; then
            date "$TS_FMT" > "$FUSE_STATE/warned_$(today)" || { echo "熔断器：告警标记写入失败——拒绝放行" >&2; exit 3; }
            note "告警" "80% 档 total=$total limit=$limit"
            echo "【告警】当日累计 $total 已达限额 $limit 的 80%：该收手了。" >&2
        fi
        exit 2
    fi

    echo "放行：今日累计 $total/$limit token。"
    exit 0
}

cmd_status() {
    local limit total_in total_out total totals
    exec 9>>"$FUSE_STATE/fuse.lock"
    if command -v flock >/dev/null 2>&1; then flock 9; fi
    auto_reset
    if ! limit="$(read_limit)"; then exit 3; fi
    if ! totals="$(today_total)"; then exit 3; fi
    read -r total_in total_out <<EOF
$totals
EOF
    total=$((total_in + total_out))
    echo "日限额=$limit token/日 今日累计=$total（in=$total_in out=$total_out）"
    if [ -f "$FUSE_STATE/tripped" ]; then echo "状态：【已熔断】（$(cat "$FUSE_STATE/tripped")）"; else echo "状态：正常"; fi
}

cmd_resume() {
    exec 9>>"$FUSE_STATE/fuse.lock"
    if command -v flock >/dev/null 2>&1; then flock 9; fi
    rm -f "$FUSE_STATE/tripped" "$FUSE_STATE/warned_$(today)"
    note "复位" "手动 resume"
    echo "熔断器：已手动复位（记入流水：手动复位=拆保险动作，后果自负）。"
}

case "${1:-}" in
    gate)   cmd_gate ;;
    status) cmd_status ;;
    resume) cmd_resume ;;
    *) cat <<'EOF'
用法：
  bash fuse.sh gate     LLM 调用前问路：0=放行 2=过80%告警(仍放行) 1=熔断拒绝 3=基础设施错(拒)
  bash fuse.sh status   看今日累计/限额/熔断状态
  bash fuse.sh resume   手动复位（次日自动复位是常规路，此为例外出口）
EOF
       [ -n "${1:-}" ] && exit 2 || exit 0 ;;
esac
