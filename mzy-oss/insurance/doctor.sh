#!/usr/bin/env bash
# ============================================================
# doctor.sh —— 五件保险之五【防呆配置体检】（对应总纲 §7 D3）
# 装机后一键体检：限额单位 / 路径存在 / 端口可达 / 计量表格式。
# 红项直接指到配置文件行号；**全绿才许启动**：
#   exit 0=全绿可启动 | 1=有红项 | 2=无红项但有黄项（不算全绿，补好再启动）。
# 纪律：doctor 只**读**配置做校验，绝不求值配置——
#   host/port 先过白名单校验再用，配置内容进不了任何 shell 求值口。
# 版权许可：SPDX-License-Identifier: Apache-2.0（全文见 LICENSE）
#
# 用法示例：
#   bash doctor.sh                          # 体检 ./daily_limit.conf
#   bash doctor.sh /path/to/daily_limit.conf
#   bash doctor.sh && echo 可以启动          # 全绿才启动的接法
# ============================================================

# ---------- 变量置顶 ----------
CONF="${1:-./daily_limit.conf}"          # 要体检的配置文件
USAGE_DATA="${USAGE_DATA:-usage.jsonl}"  # 计量表文件（相对路径以配置目录为基准）
WARNINGS=0                                # 黄项计数
ERRORS=0                                  # 红项计数
HOST_PAT='^[A-Za-z0-9._-]+$'              # host 白名单：点/横线/字母数字，禁 shell 元字符
# ------------------------------

set -u

ok()   { echo "[OK]   $*"; }
warn() { echo "[WARN] $*"; WARNINGS=$((WARNINGS + 1)); }
# 红项出口：$1=行号（0=文件级，无行号，不打假「第 0 行」）$2=说明
fail() {
    if [ "$1" = 0 ]; then echo "[FAIL] $2"; else echo "[FAIL] 第 $1 行：$2"; fi
    ERRORS=$((ERRORS + 1))
}

# 带行号读配置某键的最后一次出现（行号内容一起返回，红项指行用）
# grep -En 的分隔符是第一个冒号：前段=行号，后段=行内容
find_line() {  # $1=正则 $2=文件 -> 输出 "行号|行内容"
    grep -En "$1" "$2" | tail -1 | awk -F: '{n=$1; sub(/^[^:]*:/,""); print n "|" $0}'
}

# 端口探活：host/port 先过白名单与区间校验，再 argv 传参探活——配置内容不进 shell 求值
port_probe() {  # $1=host $2=port -> 0=通 1=不通 2=写法非法
    local host="$1" port="$2"
    printf '%s' "$host" | grep -Eq "$HOST_PAT" || return 2
    printf '%s' "$port" | grep -Eq '^[0-9]+$' || return 2
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 2
    if command -v nc >/dev/null 2>&1; then
        nc -z -w 2 "$host" "$port" >/dev/null 2>&1
    else
        timeout 2 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" 2>/dev/null
    fi
}

echo "== 体检开始：$CONF  $(date '+%Y-%m-%d %H:%M:%S') =="

# ---- 检查一：配置文件在不在 ----
if [ ! -f "$CONF" ]; then
    fail 0 "配置文件不存在：$CONF"
    echo "== 体检收口：红 $ERRORS 黄 $WARNINGS —— 不许启动 =="
    exit 1
fi
CONF_DIR="$(cd "$(dirname "$CONF")" 2>/dev/null && pwd || dirname "$CONF")"

# ---- 检查二：限额单位（必须是正整数，单位 token/日；填字符串/小数/负数=红）----
line="$(find_line '^[[:space:]]*DAILY_LIMIT[[:space:]]*=' "$CONF")"
if [ -z "$line" ]; then
    line="$(grep -En '^[[:space:]]*[0-9]+[[:space:]]*$' "$CONF" | tail -1 | awk -F: '{n=$1; sub(/^[^:]*:/,""); print n "|" $0}')"
fi
if [ -z "$line" ]; then
    fail 0 "找不到日限额行（DAILY_LIMIT=数字 或裸数字行），限额没设=熔断器没牙"
else
    ln="${line%%|*}"; content="${line#*|}"
    val="$(printf '%s' "$content" | sed 's/.*=//; s/[[:space:]]//g')"
    case "$val" in
        ''|*[!0-9]*)   fail "$ln" "日限额须为纯整数（单位 token/日），读到 '$val'——填 100 就是 100 token，不是 100 万" ;;
        0)             fail "$ln" "日限额为 0=一调用就熔断，若有意请改用 fuse.sh 手动管" ;;
        *)             ok "日限额=$val token/日（第 $ln 行）" ;;
    esac
fi

# ---- 检查三：路径存在（CHECK_PATH=逗号分隔；坏路径红项指到该配置行）----
line="$(find_line '^[[:space:]]*CHECK_PATH[[:space:]]*=' "$CONF")"
if [ -n "$line" ]; then
    ln="${line%%|*}"; content="${line#*|}"
    paths="$(printf '%s' "$content" | sed 's/.*=//')"
    IFS=',' read -r -a arr <<< "$paths"
    for p in "${arr[@]}"; do
        p="$(printf '%s' "$p" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -n "$p" ] || continue
        # 相对路径以配置文件所在目录为基准（与计量表同一基准）
        case "$p" in /*) full="$p" ;; *) full="$CONF_DIR/${p#./}" ;; esac
        if [ -e "$full" ]; then ok "路径在：$p（第 $ln 行）"; else fail "$ln" "路径不存在：$p（查过 $full）"; fi
    done
else
    fail 0 "没写 CHECK_PATH 行——关键件清单没登记，不算全绿（防手滑漏文件）"
fi

# ---- 检查四：端口可达（CHECK_PORT=host:port 逗号分隔；不通红项指行）----
line="$(find_line '^[[:space:]]*CHECK_PORT[[:space:]]*=' "$CONF")"
if [ -n "$line" ]; then
    ln="${line%%|*}"; content="${line#*|}"
    ports="$(printf '%s' "$content" | sed 's/.*=//')"
    IFS=',' read -r -a arr <<< "$ports"
    for hp in "${arr[@]}"; do
        hp="$(printf '%s' "$hp" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -n "$hp" ] || continue
        host="${hp%:*}"; port="${hp##*:}"
        port_probe "$host" "$port"
        rc=$?
        case "$rc" in
            0) ok "端口通：$hp（第 $ln 行）" ;;
            2) fail "$ln" "端口写法错：$hp（要 host:port，port 为 1-65535 数字，host 只收字母数字._-；本版只支持 IPv4/主机名，不支持 IPv6）" ;;
            *) fail "$ln" "端口不通：$hp（服务没起或地址错）" ;;
        esac
    done
else
    ok "没配 CHECK_PORT，跳过端口体检"
fi

# ---- 检查五：计量表可读（有流水就做整行 schema 校验：结构/≤15位/整数/-1 成对；坏行逐条报 行号:类别）----
case "$USAGE_DATA" in /*) usage_full="$USAGE_DATA" ;; *) usage_full="$CONF_DIR/${USAGE_DATA#./}" ;; esac
if [ -f "$usage_full" ]; then
    bad_report="$(awk '
        /^[[:space:]]*$/ { next }
        {
            # 【统一账本 schema·全五件同一契约】整行校验：日期合法段、tool 1-32、token=-1 或 0..N(≤15位禁前导零)
            if ($0 !~ /^\{"ts":"[0-9][0-9][0-9][0-9]-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9][+-]([01][0-9]|2[0-3])[0-5][0-9]","tool":"[A-Za-z0-9_.-]{1,32}","tokens_in":(-1|0|[1-9][0-9]{0,14}),"tokens_out":(-1|0|[1-9][0-9]{0,14})\}$/) {
                printf "第 %d 行：结构不合规(含日期/时区/tool/整数)\n", NR; next
            }
            match($0, /"tokens_in":-?[0-9]+/); s = substr($0, RSTART, RLENGTH); sub(/"tokens_in":/, "", s); tin = s
            match($0, /"tokens_out":-?[0-9]+/); s = substr($0, RSTART, RLENGTH); sub(/"tokens_out":/, "", s); tout = s
            if ((tin == -1) != (tout == -1)) { printf "第 %d 行：-1必须成对\n", NR; next }
        }' "$usage_full")"
    if [ -n "$bad_report" ]; then
        # 每个坏行单独一条红项，各带真实行号与类别（不打假「第 0 行」）
        while IFS= read -r brline; do
            [ -n "$brline" ] || continue
            brnum="${brline%%行*}"; brnum="${brnum#第 }"; brnum="${brnum% }"
            fail "$brnum" "计量表 $usage_full：${brline#*行：}"
        done <<EOF
$bad_report
EOF
    else
        ok "计量表格式全过：$usage_full"
    fi
else
    ok "计量表还没建（$usage_full），首次记账时会自动建"
fi

# ---- 收口：全绿才许启动（黄项也不算全绿）----
echo "== 体检收口：红 $ERRORS 黄 $WARNINGS =="
if [ "$ERRORS" -gt 0 ]; then
    echo "有红项，不许启动——按上面行号改好再体检。"
    exit 1
fi
if [ "$WARNINGS" -gt 0 ]; then
    echo "无红项但有黄项，不算全绿——补好再启动。"
    exit 2
fi
echo "全绿，可以启动。"
exit 0
