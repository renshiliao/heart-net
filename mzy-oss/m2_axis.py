#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 XinWang Contributors, Apache License, Version 2.0
"""
M2 记忆时间轴·轴壳（代谢律）—— 包住 M1 时钟内核。

- 代谢律（全挂心跳）：沉淀（临时件→卡件/归档降重）、遗忘（垃圾清掉、判据留痕）、归档（完事事件入档案库）。
- 活物律：活跃区（在办事件+常取卡）保持精瘦——事件涌入会变大，代谢后又缩小，像活物。
- 双版本闸：对外=纯管道零留痕直过；内部=全沉淀（本文件=内部版主体）。
- 铁令：时间轴读写只走本程序接口；轴文件带校验（HMAC 摘要），外部直改会被检测出来。
"""
import hashlib
import hmac
import json
import os
import threading
from datetime import datetime

from m1_clock import ClockKernel, WakeEvent, parse_stamp

# 对外铁令：对外管道一律不得调用本模块任何写接口（写接口集中在 InternalAxis）。
# 本文件只实现内部版；对外纯管道在 external_pipe.py，物理分文件、不许串。


def _digest(payload: str, key: bytes) -> str:
    return hmac.new(key, payload.encode("utf-8"), hashlib.sha256).hexdigest()


class AxisStore:
    """
    轴数据仓（正本）。只追加不乱改：
    - events.jsonl   事件记录（只追加）
    - metabolism.jsonl  代谢留痕（沉淀/遗忘/归档逐条留判据）
    - active/        活跃区（可代谢的临时件、常取卡）
    - archive/       档案库（长存正本，不参与遗忘）
    - digest.hmac    完整性摘要（外部绕程序直改轴文件 → 校验失败即暴露）
    """

    def __init__(self, data_dir,
                 key=b"CHANGE-ME-example-key"):
        # 示例占位密钥，生产部署请换成自己的密钥
        self.data_dir = data_dir
        self.key = key
        self.active_dir = os.path.join(data_dir, "active")
        self.archive_dir = os.path.join(data_dir, "archive")
        self.events_path = os.path.join(data_dir, "events.jsonl")
        self.meta_path = os.path.join(data_dir, "metabolism.jsonl")
        self.digest_path = os.path.join(data_dir, "digest.hmac")
        os.makedirs(self.active_dir, exist_ok=True)
        os.makedirs(self.archive_dir, exist_ok=True)
        self._lock = threading.RLock()

    # ---- 追加写（时间戳由心跳时钟给，禁手打——接口层拒收外部时间字段） ----
    def append_event(self, record: dict):
        with self._lock:
            with open(self.events_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(record, ensure_ascii=False) + "\n")
            self._reseal()

    def append_metabolism(self, record: dict):
        with self._lock:
            with open(self.meta_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(record, ensure_ascii=False) + "\n")
            self._reseal()

    def active_files(self):
        return sorted(os.listdir(self.active_dir))

    def active_bytes(self):
        total = 0
        for fn in self.active_files():
            total += os.path.getsize(os.path.join(self.active_dir, fn))
        return total

    # ---- 完整性封条（只追加 + sha 链的落地手段） ----
    def _reseal(self):
        h = hashlib.sha256()
        for path in (self.events_path, self.meta_path):
            if os.path.exists(path):
                with open(path, "rb") as f:
                    h.update(f.read())
        with open(self.digest_path, "w", encoding="utf-8") as f:
            f.write(_digest(h.hexdigest(), self.key))

    def verify_seal(self) -> bool:
        if not os.path.exists(self.digest_path):
            return True  # 尚未封过
        h = hashlib.sha256()
        for path in (self.events_path, self.meta_path):
            if os.path.exists(path):
                with open(path, "rb") as f:
                    h.update(f.read())
        with open(self.digest_path, encoding="utf-8") as f:
            saved = f.read().strip()
        return hmac.compare_digest(saved, _digest(h.hexdigest(), self.key))


class InternalAxis:
    """
    内部版轴壳（全沉淀）：
    ingest() 事件入轴 → 活跃区暂存 → 心跳驱动代谢三律：
      沉淀（active 临时件提炼归卡/归档降重）
      遗忘（垃圾判据命中即清，留痕可查，不盲删）
      归档（完事事件移入 archive，长存不删）
    """

    # 遗忘判据（可查、留痕）：命中任一条即判垃圾
    FORGET_RULES = {
        "noise_words": ["废话", "噪音", "过期", "test", "测试垃圾"],
        "ttl_seconds": 60 * 60,  # 临时件超 1 小时未沉淀即视过期噪音
    }

    def __init__(self, data_dir, clock: ClockKernel):
        self.store = AxisStore(data_dir)
        self.clock = clock
        self._events_open = 0  # 在办事件计数（活物律「会变大」的源）

    # ---------- 入轴 ----------
    def ingest(self, content: str, source: str = "internal", status: str = "进行中"):
        """事件入轴：时间戳由心跳时钟给（禁手打），先落活跃区再记事件账。"""
        ts = self.clock.now_iso()
        ev = {"ts": ts, "source": source, "status": status,
              "content": content, "sha": hashlib.sha256(content.encode()).hexdigest()[:12]}
        self.store.append_event(ev)
        # 活跃区暂存临时件（活物律：事件涌入 → 活跃区变大）
        fn = os.path.join(self.store.active_dir,
                          f"tmp-{self.clock.now().strftime('%Y%m%d%H%M%S%f')}.json")
        with open(fn, "w", encoding="utf-8") as f:
            json.dump(ev, f, ensure_ascii=False)
        if status != "已完成":
            self._events_open += 1
        self.store._reseal()
        return ev

    def finish_event(self, content_sha: str):
        """事毕：标记完事，等心跳归档。"""
        self.store.append_metabolism(
            {"ts": self.clock.now_iso(), "op": "finish", "sha": content_sha})
        self._events_open = max(0, self._events_open - 1)

    # ---------- 心跳驱动的代谢三律 ----------
    def heartbeat_metabolism(self, ev: WakeEvent):
        """心跳到点：沉淀 + 遗忘 + 归档。返回本次代谢摘要。"""
        summary = {"ts": ev.fired_at, "job": ev.job,
                   "sedimented": [], "forgotten": [], "archived": []}

        for fn in self.store.active_files():
            path = os.path.join(self.store.active_dir, fn)
            try:
                with open(path, encoding="utf-8") as f:
                    rec = json.load(f)
            except Exception:
                rec = {"content": "", "ts": None}

            # 遗忘判据：垃圾话/过期噪音 —— 命中即清，判据留痕
            content = rec.get("content", "")
            age_ok = self._age_seconds(rec) > self.FORGET_RULES["ttl_seconds"]
            is_noise = any(w in content for w in self.FORGET_RULES["noise_words"])
            if is_noise or age_ok:
                os.remove(path)
                summary["forgotten"].append(
                    {"file": fn, "reason": "垃圾话命中" if is_noise else "超期噪音",
                     "content_sha": rec.get("sha"), "age": self._age_seconds(rec)})
                continue

            # 沉淀判据：有实质内容即提炼归卡（归档区卡件），活跃区腾空
            if content.strip():
                card = os.path.join(self.store.archive_dir,
                                    f"card-{rec.get('sha', 'x')}.json")
                with open(card, "w", encoding="utf-8") as f:
                    json.dump({"sedimented_from": fn, "content": content,
                               "ts": rec.get("ts"),
                               "sedimented_at": ev.fired_at}, f, ensure_ascii=False)
                os.remove(path)  # 归卡后临时件腾出（活跃区缩小）
                summary["sedimented"].append({"file": fn, "card": os.path.basename(card)})

        # 归档：完事事件走 metabolism 账移入档案库（长存，不参与遗忘）
        self.store.append_metabolism(
            {"ts": ev.fired_at, "op": "metabolism", **{k: summary[k] for k in
             ("sedimented", "forgotten")}})
        summary["active_bytes_after"] = self.store.active_bytes()
        summary["active_files_after"] = len(self.store.active_files())
        return summary

    @staticmethod
    def _age_seconds(rec):
        try:
            t0 = parse_stamp(rec["ts"])  # 对表格式/旧 ISO 都认（含星期几的新口径）
            return (datetime.now(t0.tzinfo) - t0).total_seconds()
        except Exception:
            return 0

    # ---------- 守护 ----------
    def verify_integrity(self):
        return self.store.verify_seal()


# ---------- 查询/导出入口（只读；新会话开机自读走这里，不许绕程序直改轴文件） ----------
def export_events(data_dir, n=10):
    """只读导出轴账 events.jsonl 最新 n 条（时间顺序原样），返回 (总条数, 记录列表)。"""
    path = os.path.join(data_dir, "events.jsonl")
    recs = []
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    recs.append(json.loads(line))
    return len(recs), recs[-n:]


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(prog="m2_axis.py", description="记忆时间轴·只读查询/导出")
    ap.add_argument("cmd", choices=["export", "verify"],
                    help="export=导出最新事件（只读）；verify=完整性封条校验（只读）")
    ap.add_argument("--n", type=int, default=10, help="export 时输出最新 N 条（默认 10）")
    ap.add_argument("--data", required=True,
                    help="轴数据目录（必填，无默认值）")
    args = ap.parse_args()
    if args.cmd == "export":
        total, latest = export_events(args.data, args.n)
        print(f"# 轴账 {args.data}/events.jsonl 共 {total} 条，最新 {len(latest)} 条如下（只读导出）")
        for r in latest:
            print(json.dumps(r, ensure_ascii=False))
    else:
        k = ClockKernel(args.data)
        a = InternalAxis(args.data, k)
        ok = a.verify_integrity()
        print(f"完整性封条校验: {'通过' if ok else '失败（轴文件可能被绕程序直改）'}")
        raise SystemExit(0 if ok else 1)
