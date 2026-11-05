#!/usr/bin/env bash
# ============================================================
# circuit.sh —— 五件保险之四【撞墙熔断】（对应总纲 §7 D2）
# 同题撞墙 3 次自动熔断该任务：失败就敲一下记数，记满就停 + 落盘现场 + 提示上报。
# 防的就是「同一个问题反复问 LLM 反复撞墙，烧钱无产出」。
# 记数=append-only 敲墙流水数行（O_APPEND 短行追加），天然抗并发丢数；
# 人工 reset/成功 ok 都留 append-only 审计行，不只打屏幕。
# 版权许可：SPDX-License-Identifier: Apache-2.0（全文见 LICENSE）
#
# 用法示例：
#   bash circuit.sh knock 任务签名          # 失败一次敲一下（同题=同签名）
#   bash circuit.sh ok    任务签名          # 成功清零记数（已熔断的任务不许 ok）
#   bash circuit.sh check 任务签名          # 问路：0=可跑 1=已熔断/状态不可用
#   bash circuit.sh reset 任务签名          # 人工确认后恢复（上报后才按=规矩）
#
# 调用方接法（伪码）：
#   bash circuit.sh check mytask || exit     # 熔断中就别跑了
#   do_work || bash circuit.sh knock mytask
#   bash circuit.sh ok mytask
# ============================================================

# ---------- 变量置顶 ----------
CIRCUIT_DIR="${CIRCUIT_DIR:-./circuit_state}"  # 状态目录（记数/熔断/现场/审计都在这）
FAIL_LIMIT=3                                   # 撞墙几次熔断（默认 3，对应 D2）
TS_FMT='+%Y-%m-%dT%H:%M:%S%z'
AUDIT_LOG=""                                   # 审计流水（set -u 下先占位，main 里定值）
# ------------------------------

set -u

# 签名防呆：只收安全字符，防路径注入
valid_sig() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]+$' || { echo "撞墙熔断：任务签名只许字母数字._- ，读到：$1" >&2; exit 2; }; }

# 状态目录建不了=没法记数/判熔断 → fail-closed 拒跑
if ! mkdir -p "$CIRCUIT_DIR" 2>/dev/null || [ ! -d "$CIRCUIT_DIR" ]; then
    echo "撞墙熔断：状态目录建不了 $CIRCUIT_DIR——按已熔断处理，拒跑（fail-closed）" >&2
    exit 1
fi
AUDIT_LOG="$CIRCUIT_DIR/circuit_events.jsonl"

# 审计留痕：append-only 事件行（reset/ok/knock 熔断都记），写失败也照实报
audit() {  # $1=事件 $2=签名 $3=详情
    printf '{"ts":"%s","event":"%s","sig":"%s","detail":"%s"}\n' \
        "$(date "$TS_FMT")" "$1" "$2" "$3" >> "$AUDIT_LOG" 2>/dev/null \
        || echo "撞墙熔断：审计写入失败 $AUDIT_LOG（不影响主路，但请查目录）" >&2
}

# 现场留痕：撞墙那一刻的环境快照（进程/磁盘/日志尾巴），给上报用
snapshot() {  # $1=签名
    {
        echo "== 撞墙现场 $(date "$TS_FMT") sig=$1 =="
        echo "-- 进程 --"; ps 2>/dev/null | head -20
        echo "-- 磁盘 --"; df -h . 2>/dev/null
        echo "-- 最近日志 --"; tail -n 20 ./live.log 2>/dev/null || echo "(无 ./live.log)"
    } >> "$CIRCUIT_DIR/$1.scene"
}

# 当前敲墙次数 = append-only 流水的严格合法行数（抗并发丢数；比「读数-改数-写数」稳）
# 状态完整性：每行必须=「机械时间戳 + knock」；发现任何别的内容=状态损坏，
#   立即报错拒跑（fail-closed），绝不把坏行当一次敲墙
count_knocks() {
    local f="$CIRCUIT_DIR/$sig.knocks"
    if [ ! -f "$f" ]; then echo 0; return; fi
    local bad n
    bad="$(grep -Ev '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4} knock$' "$f" | head -3 || true)"
    if [ -n "$bad" ]; then
        echo "【状态损坏】$f 里有非敲墙行（只认「机械时间戳 knock」）：$bad" >&2
        echo "【状态损坏】任务 $sig 拒跑（fail-closed）——请人工核查 $f 后重建" >&2
        exit 1
    fi
    n="$(wc -l < "$f" | tr -d ' ')"
    echo "$n"
}

sig="${2:-}"

case "${1:-}" in
    knock)
        valid_sig "$sig"
        # flock 临界区：检状态完整性→追加→计数→熔断迁移，全程一把锁（防并发互踩）
        exec 9>>"$CIRCUIT_DIR/circuit.lock"
        if command -v flock >/dev/null 2>&1; then flock 9; fi
        # 先检后写：敲墙流水有坏行=状态不可信，报损拒跑且不改状态（绝不边坏边追加）
        count_knocks >/dev/null || exit 1
        if [ -f "$CIRCUIT_DIR/$sig.tripped" ]; then
            echo "【已熔断】任务 $sig 早已熔断，不再记数（先上报、后 bash circuit.sh reset $sig）"
            exit 1
        fi
        if ! printf '%s %s\n' "$(date "$TS_FMT")" "knock" >> "$CIRCUIT_DIR/$sig.knocks"; then
            echo "【状态写失败】任务 $sig 敲墙流水写不进——按熔断处理，拒跑（fail-closed）" >&2
            exit 1
        fi
        n="$(count_knocks)" || exit 1   # 状态损坏时 count_knocks 拒跑（子 shell exit 不外传，须查返回码）
        if [ "$n" -ge "$FAIL_LIMIT" ]; then
            date "$TS_FMT" > "$CIRCUIT_DIR/$sig.tripped" || { echo "【状态写失败】熔断标记写不进 $sig——拒跑" >&2; exit 1; }
            snapshot "$sig" || echo "【提示】现场文件写入不全 $CIRCUIT_DIR/$sig.scene（不影响熔断）" >&2
            audit "熔断" "$sig" "连撞 $n 次"
            echo "【熔断】任务 $sig 连撞 $n 次（≥$FAIL_LIMIT）：已自动熔断。"
            echo "        现场已落盘 $CIRCUIT_DIR/$sig.scene"
            echo "        请上报问题（附现场文件），人工确认后再 reset。"
            exit 1
        fi
        echo "撞墙记数：$sig 第 $n/$FAIL_LIMIT 次。"
        ;;
    ok)
        valid_sig "$sig"
        exec 9>>"$CIRCUIT_DIR/circuit.lock"
        if command -v flock >/dev/null 2>&1; then flock 9; fi
        # 先检后写：坏状态不许 ok 清数
        count_knocks >/dev/null || exit 1
        # 已熔断的任务不许用 ok 偷偷洗白：熔断只能走 reset（上报后人工恢复）
        if [ -f "$CIRCUIT_DIR/$sig.tripped" ]; then
            echo "【已熔断】任务 $sig 不许 ok 清零——熔断只能上报后 bash circuit.sh reset $sig" >&2
            exit 1
        fi
        if ! : > "$CIRCUIT_DIR/$sig.knocks" 2>/dev/null; then
            echo "【状态写失败】任务 $sig 记数清不了——请查 $CIRCUIT_DIR" >&2; exit 1
        fi
        audit "成功清零" "$sig" "count->0"
        echo "任务 $sig 成功，记数清零（已记审计行）。"
        ;;
    check)
        valid_sig "$sig"
        # 状态完整性先查：敲墙流水有坏行=状态不可信，按熔断处理拒跑（fail-closed）
        count_knocks >/dev/null || exit 1
        if [ -f "$CIRCUIT_DIR/$sig.tripped" ]; then
            echo "【已熔断】任务 $sig 不许跑（现场：$CIRCUIT_DIR/$sig.scene）"
            exit 1
        fi
        echo "任务 $sig 可跑。"
        ;;
    reset)
        valid_sig "$sig"
        exec 9>>"$CIRCUIT_DIR/circuit.lock"
        if command -v flock >/dev/null 2>&1; then flock 9; fi
        rm -f "$CIRCUIT_DIR/$sig.tripped" "$CIRCUIT_DIR/$sig.knocks"
        audit "人工复位" "$sig" "reset by operator"
        echo "任务 $sig 已恢复（人工复位留痕：$(date "$TS_FMT")，审计行已落 $AUDIT_LOG）。"
        ;;
    *)
        cat <<'EOF'
用法：
  bash circuit.sh knock 任务签名   失败记一次，记满 3 次熔断+落盘现场
  bash circuit.sh ok    任务签名   成功清零（已熔断任务不许 ok）
  bash circuit.sh check 任务签名   问路：0=可跑 1=已熔断
  bash circuit.sh reset 任务签名   上报后人工恢复
EOF
        [ -n "${1:-}" ] && exit 2 || exit 0 ;;
esac
