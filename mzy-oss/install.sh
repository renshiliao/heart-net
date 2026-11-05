#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 XinWang Contributors, Apache License, Version 2.0
# install.sh —— 本地安装脚本：复制包内文件到目标目录 + 建数据骨架 + 语法自检。
# 全程零网络：本脚本不含任何下载/联网动作，装的全是包内自带文件。
# 用法: ./install.sh [目标目录]    （缺省 ./installed）

set -eu

TARGET="${1:-./installed}"
PKG_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

echo "== mzy-oss 安装 =="
echo "包目录: $PKG_DIR"
echo "目标目录: $TARGET"

command -v python3 >/dev/null 2>&1 || {
    echo "错误: 未找到 python3，请先安装 Python 3.8+" >&2
    exit 1
}

# 1) 复制包内文件到目标目录
mkdir -p "$TARGET"
for f in m1_clock.py m2_axis.py m5_archive.py live.py external_pipe.py LICENSE README.md; do
    cp "$PKG_DIR/$f" "$TARGET/$f"
done
cp -R "$PKG_DIR/samples" "$TARGET/samples"
cp -R "$PKG_DIR/demo" "$TARGET/demo"
echo "已复制包内文件到 $TARGET"

# 2) 建空数据骨架 data/axis/{active,archive}/
mkdir -p "$TARGET/data/axis/active" "$TARGET/data/axis/archive"
echo "已建数据骨架 $TARGET/data/axis/{active,archive}/"

# 3) 跑一次 python3 -m compileall 自检
python3 -m compileall -q "$TARGET"
echo "语法自检: python3 -m compileall 通过"

# 4) 下一步提示
echo ""
echo "== 下一步 =="
echo "1. 跑最小实例:  cd $TARGET && python3 demo/run.py"
echo "2. 起心跳常驻:  MZY_OSS_DATA=$TARGET/data/axis python3 $TARGET/live.py"
echo "3. 只读导出:    python3 $TARGET/m2_axis.py export --data $TARGET/data/axis"
echo "4. 生产部署前请把 AxisStore 的示例占位密钥换成你自己的密钥"
echo "安装完成。"
