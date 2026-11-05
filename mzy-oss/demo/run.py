#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 XinWang Contributors, Apache License, Version 2.0
"""
最小实例演示：一条命令 `python3 demo/run.py` 跑通五工具门 + 五现象。
纯标准库、零网络、零配置、全程 ≤15 秒。
五工具门为本地最小实现（函数调用，不启网络服务）：
  xw_search / xw_card_get / xw_event_log / xw_status / xw_time
数据目录 demo/data/，跑完不删。
"""
import hashlib
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.dirname(HERE)
DATA = os.path.join(HERE, "data")          # 数据目录 = demo/data/
SAMPLES = os.path.join(PKG, "samples")
sys.path.insert(0, PKG)

from m1_clock import ClockKernel            # noqa: E402
from m2_axis import InternalAxis, export_events   # noqa: E402
from external_pipe import ExternalPipe      # noqa: E402

# ---------- 五工具门（本地最小实现） ----------

TIME_FIELD_KEYS = {  # 调用方时间字段黑名单：命中即拒收（递归）
    "ts", "time", "timestamp", "created_at", "updated_at", "fired_at",
    "scheduled_at", "time_source", "now", "datetime", "date", "when",
    "epoch", "now_iso", "now_human",
}


def _find_time_field(obj):
    """递归找时间字段，返回命中键名；无命中返回 None。"""
    if isinstance(obj, dict):
        for k, v in obj.items():
            if str(k).lower() in TIME_FIELD_KEYS:
                return k
            hit = _find_time_field(v)
            if hit:
                return hit
    elif isinstance(obj, (list, tuple)):
        for item in obj:
            hit = _find_time_field(item)
            if hit:
                return hit
    return None


def _load_cards():
    cards = []
    for fn in sorted(os.listdir(SAMPLES)):
        if fn.endswith(".json"):
            with open(os.path.join(SAMPLES, fn), encoding="utf-8") as f:
                cards.append(json.load(f))
    return cards


def xw_search(query, top_k=5):
    """关键词检索知识卡：命中列表(id/title/trigger/snippet)；无命中显式空列表。"""
    terms = [t for t in query.replace("|", " ").split() if t]
    hits = []
    for card in _load_cards():
        blob = " ".join([card.get("title", ""), card.get("trigger", ""),
                         " ".join(card.get("keywords", [])), card.get("content", "")])
        if any(t.lower() in blob.lower() for t in terms):
            line = next((l for l in card.get("content", "").splitlines() if l.strip()), "")
            hits.append({"id": card["id"], "title": card["title"],
                         "trigger": card["trigger"], "snippet": line[:40]})
    return hits[:top_k]


def xw_card_get(id):
    """按 id 取整卡（15 字段）；不存在显式 not_found。"""
    for card in _load_cards():
        if card["id"] == id:
            return card
    return {"error": "not_found", "id": id}


def xw_event_log(content=None, source=None, status=None, **extra):
    """事件入轴：时间由内核原子注入；调用方时间字段（含嵌套）一律拒收。"""
    payload = {"content": content, "source": source, "status": status}
    payload.update(extra)
    hit = _find_time_field(payload)
    if hit:
        return {"error": "time_field_rejected", "field": hit}
    ev = AXIS.ingest(content or "", source or "demo", status or "进行中")
    return {"ts": ev["ts"], "time_source": "server", "source": ev["source"],
            "status": ev["status"], "content": ev["content"], "sha": ev["sha"]}


def xw_status():
    """运行状态：事件条数/卡数/完整性校验/运行时长；不出权威时间。"""
    total, _ = export_events(DATA, 1)
    return {"events": total, "cards": len(_load_cards()),
            "integrity_ok": AXIS.verify_integrity(),
            "runtime_sec": round(time.monotonic() - T0, 1)}


def xw_time():
    """唯一取时口：now_iso/now_human 带星期几，time_source=server。"""
    return {"now_iso": KERNEL.now_iso(), "now_human": KERNEL.now_human(),
            "time_source": "server"}


def _data_files():
    """数据目录全量文件集合（用于零新增核对）。"""
    out = set()
    for root, _dirs, files in os.walk(DATA):
        for fn in files:
            out.add(os.path.relpath(os.path.join(root, fn), DATA))
    return out


def main():
    global KERNEL, AXIS, T0
    T0 = time.monotonic()
    KERNEL = ClockKernel(DATA)
    AXIS = InternalAxis(DATA, KERNEL)

    print("========== mzy-oss 最小实例演示 ==========")
    print(f"数据目录: {os.path.relpath(DATA, PKG)}/（跑完不删）\n")

    # ---- 现象① 心跳启动并跳动 ----
    beats = []
    def hb(ev):
        beats.append(ev)
        print(f"[心跳] {ev.fired_at} 第{len(beats)}跳 kind={ev.kind} delay={ev.delay:.2f}s")
    KERNEL.register("demo-heartbeat", hb, {"type": "interval", "seconds": 1})
    print("=== 现象① 心跳启动并跳动 ===")
    KERNEL.start()
    deadline = time.monotonic() + 8
    while len(beats) < 3 and time.monotonic() < deadline:
        time.sleep(0.1)
    KERNEL.stop()
    print(f"你在看什么：时钟内核唤醒线程到点合成事件喂给回调，共跳动 {len(beats)} 跳"
          "（演示用秒级短间隔；线上默认 60 秒一跳）。")

    # ---- 现象② 事件入轴 ----
    print("\n=== 现象② 事件入轴 ===")
    ev_path = os.path.join(DATA, "events.jsonl")
    def ev_lines():
        if not os.path.exists(ev_path):
            return 0
        with open(ev_path, encoding="utf-8") as f:
            return sum(1 for line in f if line.strip())
    before = ev_lines()
    card = xw_event_log("演示事件：跑通一次三角函数公式速查卡", source="demo", status="已完成")
    after = ev_lines()
    print(f"xw_event_log → {json.dumps(card, ensure_ascii=False)}")
    print(f"events.jsonl: {before} 行 → {after} 行（长了 {after - before} 行）")
    bad = xw_event_log("想自带时间戳的事件", source="demo", status="已完成",
                       ts="2020-01-01 00:00")
    print(f"负例（调用方自带时间字段）→ {json.dumps(bad, ensure_ascii=False)}")
    t = xw_time()
    print(f"xw_time → {json.dumps(t, ensure_ascii=False)}")
    print("你在看什么：事件卡的 ts 由服务端原子注入且带星期几；"
          "调用方伪造时间字段一律拒收（time_field_rejected），xw_time 是唯一取时口。")

    # ---- 现象③ 检索命中样卡 ----
    print("\n=== 现象③ xw_search 检索命中样卡 ===")
    hits = xw_search("三角函数 公式")
    print(f"xw_search('三角函数 公式') → {json.dumps(hits, ensure_ascii=False)}")
    one = xw_card_get(hits[0]["id"]) if hits else None
    if one:
        print(f"xw_card_get('{one['id']}') 命中整卡：title={one['title']} "
              f"sha16={one['content_sha256']} 字段数={len(one)}")
    none = xw_search("不存在的关键词_zzz")
    print(f"xw_search('不存在的关键词_zzz') → {json.dumps(none, ensure_ascii=False)}（无卡，零空手）")
    print("你在看什么：关键词命中合成样卡返回摘要，取整卡给全 15 字段；"
          "无命中显式空列表，不藏不装。")

    # ---- 现象④ 完整性校验 ----
    print("\n=== 现象④ 完整性校验通过 ===")
    st = xw_status()
    print(f"xw_status → {json.dumps(st, ensure_ascii=False)}")
    print(f"verify_integrity → {AXIS.verify_integrity()}")
    print("你在看什么：HMAC 封条校验通过——轴文件若被绕程序直改，这里当场露馅。")

    # ---- 现象⑤ 对外管道零留痕 ----
    print("\n=== 现象⑤ external_pipe 过一条消息 ===")
    snap = _data_files()
    pipe = ExternalPipe()
    out = pipe.pass_through("hello-mzy-oss", forward=lambda m: f"[已转发]{m}")
    new_files = _data_files() - snap
    print(f"pass_through → {out}；transited_count={pipe.transited_count}")
    print(f"数据目录新增文件数: {len(new_files)}")
    print("你在看什么：对外管道进→过→出，不落盘不留痕——数据目录零新增就是活证。")

    print("\n========== 演示完毕 ==========")
    print(f"数据目录 {os.path.relpath(DATA, PKG)}/ 已保留（跑完不删），欢迎亲自开箱验货。")


if __name__ == "__main__":
    main()
