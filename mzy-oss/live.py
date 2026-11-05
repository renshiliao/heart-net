#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 XinWang Contributors, Apache License, Version 2.0
"""
记忆时间轴·活体启动 —— 心跳常驻 + 事件入轴走轴壳接口。
用法: MZY_OSS_DATA=./data/axis nohup python3 live.py >> ./data/live.log 2>&1 &
数据目录：环境变量 MZY_OSS_DATA，缺省 ./data/axis（相对当前目录）。
"""
import os, sys, time, signal
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m1_clock import ClockKernel
from m2_axis import InternalAxis

DATA = os.getenv("MZY_OSS_DATA", os.path.join(".", "data", "axis"))
alive = True


def on_sig(*a):
    global alive
    alive = False


signal.signal(signal.SIGTERM, on_sig)
signal.signal(signal.SIGINT, on_sig)


def main():
    kernel = ClockKernel(DATA)
    axis = InternalAxis(DATA, kernel)

    # 心跳: 每60秒一跳(活体的呼吸)
    def hb(ev):
        n = len([f for f in os.listdir(axis.store.active_dir) if f.endswith('.json')])
        print(f"[心跳] {ev.fired_at} 活跃区={n}件", flush=True)
    kernel.register("heartbeat", hb, {"type": "interval", "seconds": 60})

    # 代谢: 每10分钟代谢一次(沉淀+遗忘+归档)
    def metab(ev):
        s = axis.heartbeat_metabolism(ev)
        print(f"[代谢] 沉淀{len(s.get('sedimented', []))} 遗忘{len(s.get('forgotten', []))} 归档{len(s.get('archived', []))}", flush=True)
    kernel.register("metabolism", metab, {"type": "interval", "seconds": 600})

    print("[活体] 记忆时间轴心跳已起", flush=True)
    print(f"[活体] 轴数据: {DATA}", flush=True)
    # 注入示范（铁律2/4）：现在=每轮重取、带星期几（发牌不是摸牌）
    print(f"[活体] 现在: {kernel.now_human()}（注入格式含星期几）", flush=True)
    kernel.start()
    while alive:
        time.sleep(1)
    kernel.stop()
    print("[活体] 收线,轴数据已落盘(重启回放不丢)", flush=True)


if __name__ == "__main__":
    main()
