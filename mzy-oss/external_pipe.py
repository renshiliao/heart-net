#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 XinWang Contributors, Apache License, Version 2.0
"""
对外管道 —— 纯管道，零留痕。对外管道不落盘、不留痕。

本文件物理隔开于 m2_axis.py（内部版）：不 import 内部版任何写接口，
不打开任何轴文件，消息进→过→出，进程内存也不留副本。
"""


class ExternalPipe:
    """对外管道：pass_through 只做转发，禁止任何形式的落盘/留痕。"""

    def __init__(self):
        # 故意不接收 data_dir：结构上就没有可写的地方
        self._transited = 0  # 仅计数，不是记忆记录

    def pass_through(self, message: str, forward) -> str:
        """进→过→出。forward=下游出口回调。不写任何文件。"""
        out = forward(message)
        self._transited += 1
        return out

    @property
    def transited_count(self):
        """只报条数（流量计），不含任何内容，不算留痕。"""
        return self._transited
