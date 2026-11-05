#!/usr/bin/env bash
# ============================================================
# sentinel.sh —— 五件保险之三【脚本哨兵】纯 bash 三合一模板
# 一个模板三种巡检，靠参数切换（对应总纲 §7 D1 精神：哨兵用脚本零成本，
# 模型只在有事时醒）：
#   dir   目录守望：目录条目（名字/大小/时间）有没有新增/变动（有变动才响）
#   log   日志守望：日志有没有新错误行（有才响；轮转换文件即重扫）
#   disk  磁盘水位：用量超过水位线才响（水位限 0-100）
# 输出确定性契约：同一状态下，除 date 机械时间戳外输出固定；
# 三态 OK/WARN/CRIT + 一行原因 + 退出码 0/1/2；空闲静默，有事才响。
# 状态写不进去（目录建不了/快照写失败）= CRIT，绝不假报巡检成功。
# 版权许可：SPDX-License-Identifier: Apache-2.0（全文见 LICENSE）
#
# 用法示例：
#   bash sentinel.sh dir  ~/data/
#   bash sentinel.sh log  /var/log/app.log 'ERROR|FATAL'
#   bash sentinel.sh disk /var/data 80
#   写进 cron 每 5 分钟跑一次：*/5 * * * * bash /路径/sentinel.sh disk / 80
# ============================================================

# ---------- 变量置顶 ----------
STATE_DIR="${SENTINEL_STATE:-./sentinel_state}"   # 状态目录（对比快照存这，建不了=CRIT）
TS_FMT='+%Y-%m-%dT%H:%M:%S%z'
# ------------------------------

set -u

# 三态输出：状态|原因 —— 确定性输出，报警只此一处出口
say() {  # $1=OK/WARN/CRIT $2=原因
    printf 'SENTINEL %s %s | %s\n' "$1" "$(date "$TS_FMT")" "$2"
    if [ "$1" != "OK" ]; then echo "哨兵喊了：$2"; fi
    case "$1" in OK) exit 0 ;; WARN) exit 1 ;; CRIT) exit 2 ;; esac
}

# 状态目录建不了=没法对比=没法声称巡检成功 → CRIT
if ! mkdir -p "$STATE_DIR" 2>/dev/null || [ ! -d "$STATE_DIR" ]; then
    say CRIT "状态目录建不了：$STATE_DIR（巡检不可用）"
fi

mode_dir() {  # 目录守望：对比上次快照，条目元数据变动才响
    local dir="${1:?用法: sentinel.sh dir 目录}"
    [ -d "$dir" ] || say CRIT "目录不存在：$dir"
    local snap="$STATE_DIR/dir_$(printf '%s' "$dir" | sha256sum | cut -c1-12).snap"
    local now
    now="$(ls -la "$dir" 2>/dev/null | sha256sum | cut -c1-12)"
    if [ ! -f "$snap" ]; then
        printf '%s\n' "$now" > "$snap" 2>/dev/null || say CRIT "快照写失败：$snap（巡检不可用）"
        say OK "首次建档：$dir（快照已存，下轮起对比）"
    fi
    local old
    old="$(cat "$snap" 2>/dev/null)" || say CRIT "快照读失败：$snap（巡检不可用）"
    if [ "$old" = "$now" ]; then
        say OK "目录无变动：$dir"
    else
        printf '%s\n' "$now" > "$snap" 2>/dev/null || say CRIT "快照更新失败：$snap"
        say WARN "目录有变动：$dir（快照 $old -> $now）"
    fi
}

mode_log() {  # 日志守望：只看新增行里有没有错误模式（有才响）
    local file="${1:?用法: sentinel.sh log 日志文件 [错误模式]}"
    local pat="${2:-ERROR|FATAL|Traceback}"
    [ -f "$file" ] || say CRIT "日志不存在：$file"
    local posf="$STATE_DIR/log_$(printf '%s' "$file" | sha256sum | cut -c1-12).pos"
    local size inode oldpos oldino
    size="$(wc -c < "$file")"
    inode="$(ls -i "$file" 2>/dev/null | awk '{print $1}')"
    oldpos=0; oldino=""
    if [ -f "$posf" ]; then
        read -r oldpos oldino < "$posf" 2>/dev/null || oldpos=0
    fi
    # 轮转/替换检测：日志缩小或 inode 变了 → 从头重扫，不漏看
    if [ "$size" -lt "$oldpos" ] || { [ -n "$oldino" ] && [ "$oldino" != "$inode" ]; }; then oldpos=0; fi
    local hits
    hits="$(tail -c +$((oldpos + 1)) "$file" | grep -Ec "$pat" || true)"
    printf '%s %s\n' "$size" "$inode" > "$posf" 2>/dev/null || say CRIT "位置记录写失败：$posf"
    if [ "$hits" -gt 0 ]; then
        say WARN "日志新增 $hits 行匹配[$pat]：$file"
    else
        say OK "日志无新错：$file"
    fi
}

mode_disk() {  # 磁盘水位：超过水位线才响（水位限 0-100）
    local path="${1:?用法: sentinel.sh disk 路径 [水位百分比]}"
    local level="${2:-80}"
    [ -d "$path" ] || say CRIT "路径不存在：$path"
    printf '%s' "$level" | grep -Eq '^[0-9]+$' || say CRIT "水位须为整数百分比，读到：$level"
    [ "$level" -ge 0 ] && [ "$level" -le 100 ] || say CRIT "水位超出 0-100：$level"
    local use
    use="$(df -P "$path" | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
    printf '%s' "$use" | grep -Eq '^[0-9]+$' || say CRIT "用量读不出：$path"
    if [ "$use" -ge "$level" ]; then
        say WARN "磁盘水位越线：$path 用 ${use}% ≥ ${level}%"
    else
        say OK "磁盘水位正常：$path 用 ${use}% < ${level}%"
    fi
}

case "${1:-}" in
    dir)  shift; mode_dir  "$@" ;;
    log)  shift; mode_log  "$@" ;;
    disk) shift; mode_disk "$@" ;;
    *) cat <<'EOF'
用法：
  bash sentinel.sh dir  目录                 目录条目有变动才响
  bash sentinel.sh log  日志文件 [错误模式]   有新错误行才响
  bash sentinel.sh disk 路径 [水位百分比]     越水位线才响（0-100）
输出：SENTINEL OK|WARN|CRIT | 时间 | 原因（退出码 0/1/2）
EOF
       [ -n "${1:-}" ] && exit 2 || exit 0 ;;
esac
