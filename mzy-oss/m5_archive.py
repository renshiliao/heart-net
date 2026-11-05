#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 XinWang Contributors, Apache License, Version 2.0
"""
M5 档案馆（仓储）—— 完结事件＋事件卡长存。

- 档案馆＝仓储：存『发生过什么』（event_body 事件本体＋event_card 事件卡），
  落盘长存、不参与代谢、不删；
- 事件层＝本事：记『什么东西＋什么方式跑通』（另册对照，不在本文件）。
- 两账分开、各自独立目录独立文件，绝不混：一个存发生过什么，一个记跑通本事。
"""
import hashlib
import json
import os


class Archive:
    """档案馆账（仓储）：只收事件本体＋事件卡，长存不删。"""

    def __init__(self, data_dir, clock):
        # data_dir 必传：仓储账独立目录，与能力层对照册两账分开
        self.root = os.path.join(data_dir, "archive", "events")
        os.makedirs(self.root, exist_ok=True)
        self.clock = clock

    def deposit(self, event_body: dict, event_card: dict) -> str:
        """收尾出口：事件本体＋事件卡入馆（长存）。返回落盘路径。"""
        key = hashlib.sha256(
            json.dumps(event_body, ensure_ascii=False, sort_keys=True).encode("utf-8")
        ).hexdigest()[:12]
        path = os.path.join(self.root, f"evt-{key}.json")
        entry = {"event_body": event_body, "event_card": event_card,
                 "deposited_at": self.clock.now_iso()}
        with open(path, "w", encoding="utf-8") as f:
            json.dump(entry, f, ensure_ascii=False, indent=1)
        return path

    def all_entries(self):
        """馆内全部条目（文件名，条目）。仓储清点用。"""
        out = []
        for fn in sorted(os.listdir(self.root)):
            with open(os.path.join(self.root, fn), encoding="utf-8") as f:
                out.append((fn, json.load(f)))
        return out
