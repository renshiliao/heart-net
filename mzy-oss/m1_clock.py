#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 XinWang Contributors, Apache License, Version 2.0
"""
M1 时钟内核 —— 调度内核：持久化任务库 + 唤醒线程 + 错峰补跑，纯标准库实现。
方法重实现自公开的 AstrBot CronJobManager，致敬出处。

照抄精华六条：
  1) 周日=0/7 兼容层（dow 归一化，支持 *、*/N、a、a-b、a-b/N 五种写法）
  2) 逐任务 IANA 时区（无效时区降级系统时区并告警）
  3) 持久化+重启回放（先写库再注册调度；重启 sync_from_db 装载，任务不丢）
  4) 错峰补跑（misfire_grace_time 宽限内补执行，超时记「错过」留痕）
  5) 删除并发防护（删除标记+引用计数 drain，防「删除中又冒出新执行」）
  6) 主动唤醒回调（到点内核线程合成唤醒事件喂给处理器，非纯被动轮询）
内核补一条 AstrBot 没有的：interval 相对计时器（演示亚分钟心跳用）。

四条设计铁律：
  铁律1 单一时间源：墙钟只有一个取法 self.now()（IANA 时区 Asia/Shanghai，
        展示带 %Y-%m-%d %H:%M (%Z) + weekday 星期几）
  铁律2 每轮重取，注入不查询：时间随每次事件实时注入（now_iso/now_human 现取现用）
  铁律3 两种钟严格分开：日历时间用墙钟 datetime.now(时区)；
        超时/耗时/限流/心跳间隔一律单调钟 time.monotonic()（防 NTP 跳变）。
        计时路径不许出现 time.time()——唯一例外：跨重启量停摆时长
        （进程生死之间单调钟归零，只能用墙钟量日历时刻过了多久）。
  铁律4 注入带星期几：时间格式含 weekday（如「2026-11-01 01:20 (CST) 周六」）

已知坑清单补三条：
  ① max_instances 并发上限（默认 1，超限记「跳过」留痕，不排队不堆积）
  ② 停机补发（重启 sync_from_db 时 next_run 已过期、宽限内补跑，超宽限记「错过」）
  ③ 崩溃卡 running 恢复（重启 _running 计数清零、残留 running 标记留痕恢复）
"""
import json
import os
import threading
import time
import logging
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

try:
    from zoneinfo import ZoneInfo
except Exception:  # 极端缺库环境兜底
    ZoneInfo = None

log = logging.getLogger("m1.clock")

# ---------- 时区解析兜底表 ----------
# 背景：部分精简环境缺系统 tz 数据（无 /usr/share/zoneinfo、无 pip 包 tzdata），
# zoneinfo.ZoneInfo("Asia/Shanghai") 必然抛 ZoneInfoNotFoundError，旧逻辑把
# 「有效时区但查不到数据」误判成「无效时区」，每次调用刷一条告警。
# 处理：解析不出 IANA 数据时按固定 UTC+8 认 Asia/Shanghai（时区本身有效，
# 等价于 datetime.timezone(timedelta(hours=8), 'CST')），不再误报警。
# 真正的未知名才告警降级系统时区；时刻与系统 date 输出一致（本机系统时区=UTC+8）。
FIXED_ZONES = {
    "Asia/Shanghai": timezone(timedelta(hours=8), "CST"),
    "PRC": timezone(timedelta(hours=8), "CST"),
    "CST": timezone(timedelta(hours=8), "CST"),
    "UTC": timezone.utc,
}


def resolve_zone(name=None):
    """IANA 时区名 → tzinfo（单一收口）：
    ① zoneinfo 有数据就用真 IANA；② 缺数据但名字在固定表里→固定 UTC+8（不告警）；
    ③ 真·未知名→告警并降级系统时区（真实错误照报）。"""
    name = name or FORMAT["tz"]
    if ZoneInfo is not None:
        try:
            return ZoneInfo(name)
        except Exception:
            pass  # 缺 tz 数据≠无效时区，走兜底表
    if name in FIXED_ZONES:
        return FIXED_ZONES[name]
    log.warning("无效时区 %s，降级系统时区", name)
    return datetime.now().astimezone().tzinfo


# ---------- 对表口径（FORMAT 定死，全包统一口径；改动=口径变更） ----------
FORMAT = {
    # 时间源时区（IANA 名，单一时间源铁律的「单一」在此定死）
    "tz": "Asia/Shanghai",
    # 展示/注入时间格式（带时区缩写，如 2026-11-01 01:20 (CST)）
    "time_fmt": "%Y-%m-%d %H:%M (%Z)",
    # 星期名，按下标对齐 datetime.weekday()（周一=0 … 周日=6）
    "weekdays": ("周一", "周二", "周三", "周四", "周五", "周六", "周日"),
}


def stamp(dt):
    """墙钟 datetime → 对表格式「2026-11-01 01:20 (CST) 周六」（含星期几）。"""
    return dt.strftime(FORMAT["time_fmt"]) + " " + FORMAT["weekdays"][dt.weekday()]


def parse_stamp(text):
    """解析时间戳（容错）：对表格式「2026-11-01 01:20 (CST) 周六」与旧 ISO 都认。
    返回 aware datetime；naive 输入按 FORMAT['tz'] 补时区。"""
    if text is None:
        raise ValueError("时间戳为空")
    s = str(text).strip()
    for w in FORMAT["weekdays"]:  # 剥掉尾部星期几（新格式）
        if s.endswith(w):
            s = s[: -len(w)].rstrip()
            break
    dt = None
    try:
        dt = datetime.fromisoformat(s)  # 旧 ISO 格式
    except ValueError:
        head = s.split(" (")[0]  # 去掉 (CST) 时区缩写
        for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"):
            try:
                dt = datetime.strptime(head, fmt)
                break
            except ValueError:
                continue
    if dt is None:
        raise ValueError(f"无法解析时间戳: {text!r}")
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=resolve_zone(FORMAT["tz"]))  # 与 now() 同一收口
    return dt


# ---------- 周日=0/7 兼容层（AstrBot _normalize_crontab_day_of_week 同款语义） ----------
def _parse_field(expr, lo, hi, name):
    """解析 cron 字段：支持 *、*/N、a、a-b、a-b/N 与逗号列表。"""
    vals = set()
    for part in str(expr).split(","):
        part = part.strip()
        step = 1
        if "/" in part:
            part, s = part.split("/", 1)
            step = int(s)
            if step <= 0:
                raise ValueError(f"cron {name} 字段步长非法: {expr}")
        if part == "*":
            a, b = lo, hi
        elif "-" in part:
            a, b = part.split("-", 1)
            a, b = int(a), int(b)
        else:
            a = b = int(part)
        if a < lo or b > hi or a > b:
            raise ValueError(f"cron {name} 字段越界: {expr}")
        vals.update(range(a, b + 1, step))
    return vals


def normalize_day_of_week(expr):
    """标准 crontab 星期（0/7=周日）→ Python weekday（周一=0，周日=6）。"""
    raw = _parse_field(expr, 0, 7, "dow")
    mapping = {0: 6, 1: 0, 2: 1, 3: 2, 4: 3, 5: 4, 6: 5, 7: 6}
    return {mapping[v] for v in raw}


class CronTrigger:
    """绝对周期触发器：五字段 cron（分 时 日 月 周），在任务自身时区的墙钟上步进。"""

    def __init__(self, expr):
        self.expr = expr
        parts = expr.split()
        if len(parts) != 5:
            raise ValueError(f"cron 表达式须为五字段: {expr!r}")
        self.minutes = _parse_field(parts[0], 0, 59, "minute")
        self.hours = _parse_field(parts[1], 0, 23, "hour")
        self.doms = _parse_field(parts[2], 1, 31, "dom")
        self.months = _parse_field(parts[3], 1, 12, "month")
        self.dows = normalize_day_of_week(parts[4])  # 周日兼容层在此收口

    def next_fire(self, after):
        """after 之后的下一个触发时刻（分钟粒度日历步进，返回 aware datetime）。"""
        t = after.replace(second=0, microsecond=0) + timedelta(minutes=1)
        limit = t + timedelta(days=366)
        while t < limit:
            if (t.month in self.months and t.day in self.doms
                    and t.weekday() in self.dows
                    and t.hour in self.hours and t.minute in self.minutes):
                return t
            t += timedelta(minutes=1)
        raise ValueError(f"cron {self.expr!r} 一年内无触发点")


class IntervalTrigger:
    """相对计时器（内核扩展）：每隔 N 秒触发。计时基准=单调钟（铁律3）。"""

    def __init__(self, seconds):
        if seconds <= 0:
            raise ValueError("interval 秒数须为正")
        self.seconds = float(seconds)

    def next_fire(self, after):
        return after + timedelta(seconds=self.seconds)


class DateTrigger:
    """绝对时刻触发器（一次性）。"""

    def __init__(self, at_iso):
        self.at = datetime.fromisoformat(at_iso)

    def next_fire(self, after):
        t = self.at
        if t.tzinfo is None:
            t = t.replace(tzinfo=after.tzinfo)
        return t if t > after else None  # 过期即不再触发


@dataclass
class WakeEvent:
    """主动唤醒事件：内核到点合成、喂给处理器（虚拟消息语义）。
    时间字段一律对表格式（含星期几，铁律4）；delay 用单调钟量（铁律3）。"""
    job: str
    kind: str            # timer=准点 / catchup=错峰补跑
    scheduled_at: str    # 原定时刻（对表格式）
    fired_at: str        # 实际唤醒时刻（对表格式，每轮重取现注入）
    delay: float         # 迟到秒数（单调钟）


class ClockKernel:
    """
    时钟内核：持久化任务库 + 唤醒线程。
    - register：先写库、再注册调度（保证崩溃不丢任务）
    - sync_from_db：重启回放装载，停机补发（坑②），残留 running 恢复（坑③）
    - delete：删除并发防护（删除标记 + 引用计数 drain）
    - max_instances：同任务并发执行上限（坑①，超限记「跳过」留痕）
    """

    def __init__(self, data_dir, default_tz=FORMAT["tz"],
                 misfire_grace_time=300, tick=0.2):
        self.data_dir = data_dir
        os.makedirs(data_dir, exist_ok=True)
        self.store_path = os.path.join(data_dir, "jobs.json")
        self.runs_path = os.path.join(data_dir, "runs.jsonl")
        self.default_tz = default_tz
        self.misfire_grace_time = misfire_grace_time  # 错峰宽限（秒）
        self.tick = tick
        self._jobs = {}          # name -> job 字典
        self._handlers = {}      # name -> 进程内回调（basic 任务不持久化的部分）
        self._running = {}       # name -> 在跑执行数（并发上限/删除防护引用计数）
        self._deleting = set()   # 删除中标记
        self._stop = threading.Event()
        self._thread = None
        self._lock = threading.RLock()

    # ---------- 时区 ---------- （墙钟唯一取法=now()，铁律1）
    def _zone(self, name=None):
        return resolve_zone(name or self.default_tz)  # 时区解析收口（兜底表见文件头）

    def now(self, tz_name=None):
        """墙钟『现在』——日历时间唯一取法（每轮重取，注入不查询）。"""
        return datetime.now(self._zone(tz_name))

    def now_human(self, tz_name=None):
        """给模型注入用的『现在』：对表格式含星期几（注入是发牌不是摸牌）。"""
        return stamp(self.now(tz_name))

    def now_iso(self, tz_name=None):
        """事件时间戳取法（对表口径：输出含星期几，与 now_human 同格式）。"""
        return self.now_human(tz_name)

    # ---------- 持久化 ----------
    def _persist(self):
        # trigger 对象不可序列化；next_run_mono 是进程内单调截止点，跨进程无意义——都不落库
        out = {name: {k: v for k, v in jd.items()
                      if k not in ("trigger", "next_run_mono")}
               for name, jd in self._jobs.items()}
        tmp = self.store_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"jobs": out}, f, ensure_ascii=False, indent=1)
        os.replace(tmp, self.store_path)  # 原子落盘

    def _log_run(self, entry):
        with open(self.runs_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")

    # ---------- 注册 / 删除 ----------
    # register 定义在文件后部（含 trigger_desc 落库的完整版）

    def attach_handler(self, name, handler):
        """重启回放前重挂进程内回调（handler 不持久化，重开进程后挂回同名任务）。"""
        with self._lock:
            self._handlers[name] = handler

    def delete(self, name):
        """删除并发防护：打删除标记 → 等在跑执行 drain → 删未来执行与库行。"""
        with self._lock:
            self._deleting.add(name)
        deadline = time.monotonic() + 10  # 铁律3：超时判定用单调钟
        while time.monotonic() < deadline:
            with self._lock:
                if self._running.get(name, 0) == 0:
                    break
            time.sleep(0.05)
        with self._lock:
            self._jobs.pop(name, None)
            self._handlers.pop(name, None)
            self._deleting.discard(name)
            self._persist()
        self._log_run({"ts": self.now_iso(), "ev": "delete", "job": name})

    # ---------- 重启回放 ----------
    def sync_from_db(self):
        """崩溃/重启后回放：装载持久化任务；
        - 坑②停机补发：停摆期间错过、宽限内的错峰补跑，超宽限记「错过」留痕
        - 坑③ running 恢复：残留 running 标记留痕、计数清零（旧进程已死，计数无主）
        """
        if not os.path.exists(self.store_path):
            return []
        with open(self.store_path, encoding="utf-8") as f:
            data = json.load(f)
        replayed, catchups = [], []
        wall_now = self.now().timestamp()   # 墙钟：判『原定日历时刻过没过』（跨重启只有墙钟）
        mono_now = time.monotonic()         # 单调钟：登记本进程内的计时截止点
        for name, jd in data.get("jobs", {}).items():
            if not jd.get("persistent", True):
                continue  # basic 任务 handler 是进程内对象，不回放
            if name not in self._handlers:
                # 没挂回调（如旧进程残留行）——留痕后跳过（注释说留痕就要真留）
                self._log_run({"ts": self.now_iso(), "ev": "sync_skip_no_handler",
                               "job": name})
                continue
            # 坑③崩溃卡 running 恢复：残留标记留痕，计数一律清零
            stale = jd.get("running", 0)
            if stale:
                self._log_run({"ts": self.now_iso(), "ev": "recover_stale_running",
                               "job": name, "was_running": stale})
            job = {
                "name": name,
                "trigger": self._rebuild_trigger(jd),
                "trigger_desc": jd["trigger_desc"],  # 原样带回，防回放时抹掉可重建描述
                "tz": jd.get("tz", self.default_tz),
                "persistent": True,
                "misfire_grace_time": jd.get("misfire_grace_time",
                                             self.misfire_grace_time),
                "max_instances": jd.get("max_instances", 1),
                "next_run": jd.get("next_run"),
                "next_run_mono": None,
                "run_count": jd.get("run_count", 0),
                "running": 0,
            }
            self._jobs[name] = job
            self._running[name] = 0  # 坑③：崩溃残留的在跑计数清零
            replayed.append(name)
            # 坑②停机补发：next_run 已过期 → 宽限内补一次，超宽限记「错过」
            if job["next_run"] and wall_now >= job["next_run"]:
                late = wall_now - job["next_run"]  # 跨重启停摆时长（墙钟量日历差，注：唯一例外）
                if late <= job["misfire_grace_time"]:
                    catchups.append(name)
                    self._fire(job, catchup=True, delay=late)
                else:
                    self._log_run({"ts": self.now_iso(), "ev": "missed_beyond_grace",
                                   "job": name, "scheduled": job["next_run"],
                                   "late": round(late, 1)})
                self._advance(job, mono_now)  # 补完/记完推进，防重复补
            elif job["next_run"]:
                self._set_deadline(job, job["next_run"], mono_now)  # 未到点：登记截止点
        self._persist()
        self._log_run({"ts": self.now_iso(), "ev": "sync_from_db",
                       "replayed": replayed, "catchups": catchups})
        return replayed

    def _rebuild_trigger(self, jd):
        """从库行重建触发器对象（trigger 对象不序列化，存可重建的描述）。"""
        t = jd["trigger_desc"]
        if t["type"] == "cron":
            return CronTrigger(t["expr"])
        if t["type"] == "interval":
            return IntervalTrigger(t["seconds"])
        return DateTrigger(t["at"])

    # ---------- 两种钟的分工登记（铁律3 的落地点） ----------
    def _set_deadline(self, job, nxt_epoch, mono_now=None):
        """登记下次触发：墙钟存日历时刻（落库用），单调钟存进程内截止点（计时用）。"""
        if mono_now is None:
            mono_now = time.monotonic()
        job["next_run"] = nxt_epoch
        if nxt_epoch is None:
            job["next_run_mono"] = None
        else:
            remain = nxt_epoch - self.now().timestamp()  # 日历时刻→剩余时长（换算一次）
            job["next_run_mono"] = mono_now + max(0.0, remain)

    def _advance(self, job, mono_now):
        """推进下次触发（铁律3）：interval 是相对间隔→纯单调钟步进（防 NTP 跳变
        把心跳拉长压短）；cron/date 是日历时刻→墙钟步进（跳变该跳就跳）。"""
        trig = job["trigger"]
        if isinstance(trig, IntervalTrigger):
            base = max(mono_now, job.get("next_run_mono") or mono_now)
            job["next_run_mono"] = base + trig.seconds  # 晚到不补堆：从『现在』再隔 N 秒
            job["next_run"] = self.now().timestamp() + (job["next_run_mono"] - mono_now)
        else:
            nxt = trig.next_fire(self.now(job["tz"]))
            self._set_deadline(job, nxt.timestamp() if nxt else None, mono_now)

    # ---------- 唤醒线程 ----------
    def start(self, replay=True):
        if replay:
            self.sync_from_db()
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, name="M1-心跳线程", daemon=True)
        self._thread.start()
        log.info("时钟内核启动：%d 个任务在表", len(self._jobs))

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=5)

    def _loop(self):
        while not self._stop.is_set():
            mono = time.monotonic()  # 铁律3：心跳间隔/迟到判定一律单调钟
            with self._lock:
                jobs = list(self._jobs.values())
            for job in jobs:
                if job["name"] in self._deleting or job.get("next_run_mono") is None:
                    continue
                if mono >= job["next_run_mono"]:
                    delay = mono - job["next_run_mono"]  # 迟到秒数＝单调钟量
                    if delay <= job["misfire_grace_time"]:
                        self._fire(job, catchup=delay > 1.0, delay=delay)  # 迟到超 1 秒记错峰补跑
                    else:
                        self._log_run({"ts": self.now_iso(), "ev": "missed_beyond_grace",
                                       "job": job["name"], "delay": round(delay, 1)})
                    with self._lock:
                        self._advance(job, mono)
                        self._persist()
            time.sleep(self.tick)

    def _fire(self, job, catchup=False, delay=None):
        """主动唤醒：合成 WakeEvent 喂给回调。
        坑①并发上限检查＋引用计数登记（删除防护/崩溃恢复标记在此落盘）。"""
        name = job["name"]
        if name in self._deleting:
            return  # 删除中又冒出的执行，掐掉
        with self._lock:
            max_inst = job.get("max_instances", 1)
            running = self._running.get(name, 0)
            if running >= max_inst:
                # 坑①并发上限：超限记「跳过」留痕（不排队、不堆积）
                self._log_run({"ts": self.now_iso(), "ev": "skip_over_max",
                               "note": "跳过（同任务并发超上限）", "job": name,
                               "running": running, "max_instances": max_inst})
                return
            self._running[name] = running + 1
            job["running"] = self._running[name]  # 坑③：在跑标记随库落盘，崩溃后可恢复
            job["run_count"] += 1
            self._persist()
        if delay is None:  # 迟到秒数用单调钟量（铁律3）
            delay = max(0.0, time.monotonic() - (job.get("next_run_mono") or time.monotonic()))
        zone = self._zone(job["tz"])
        ev = WakeEvent(
            job=name,
            kind="catchup" if catchup else "timer",
            scheduled_at=stamp(datetime.fromtimestamp(job["next_run"], zone)),
            fired_at=self.now_iso(job["tz"]),  # 铁律2：每轮重取，现注入
            delay=max(0.0, float(delay)),
        )
        threading.Thread(target=self._run_handler, args=(job, ev),
                         name=f"唤醒-{name}", daemon=True).start()

    def _run_handler(self, job, ev):
        name = job["name"]
        try:
            handler = self._handlers.get(name)
            if handler:
                handler(ev)
            self._log_run({"ts": self.now_iso(), "ev": "fire", "job": name,
                           "kind": ev.kind, "delay": round(ev.delay, 2)})
        except Exception:
            log.exception("任务 %s 回调异常", name)
            self._log_run({"ts": self.now_iso(), "ev": "error", "job": name})
        finally:
            with self._lock:
                self._running[name] = self._running.get(name, 1) - 1
                job["running"] = max(0, self._running[name])  # 坑③：在跑标记同步落盘
                self._persist()

    # ---------- 序列化辅助 ----------
    @staticmethod
    def trigger_desc(trigger):
        """把触发器存成可重建的描述（先写库的「库」里放的就是它）。"""
        if isinstance(trigger, CronTrigger):
            return {"type": "cron", "expr": trigger.expr}
        if isinstance(trigger, IntervalTrigger):
            return {"type": "interval", "seconds": trigger.seconds}
        return {"type": "date", "at": trigger.at.isoformat()}

    def register(self, name, handler, trigger, tz=None,  # noqa: F811 —— 含 desc 落库
                 persistent=True, misfire_grace_time=None, max_instances=1):
        if isinstance(trigger, dict):
            t = trigger
            if t["type"] == "cron":
                trigger = CronTrigger(t["expr"])
            elif t["type"] == "interval":
                trigger = IntervalTrigger(t["seconds"])
            elif t["type"] == "date":
                trigger = DateTrigger(t["at"])
            else:
                raise ValueError(f"未知触发器类型: {t['type']}")
        nxt = trigger.next_fire(self.now(tz))  # 铁律1：墙钟只从 now() 取
        job = {
            "name": name,
            "trigger": trigger,
            "trigger_desc": self.trigger_desc(trigger),
            "tz": str(tz or self.default_tz),
            "persistent": persistent,
            "misfire_grace_time": misfire_grace_time or self.misfire_grace_time,
            "max_instances": int(max_instances),
            "next_run": nxt.timestamp() if nxt else None,
            "next_run_mono": None,
            "run_count": 0,
            "running": 0,
        }
        with self._lock:
            self._jobs[name] = job
            self._handlers[name] = handler
            self._running[name] = 0
            self._set_deadline(job, job["next_run"])
            self._persist()
        self._log_run({"ts": self.now_iso(), "ev": "register", "job": name,
                       "trigger": job["trigger_desc"],
                       "max_instances": int(max_instances)})
        return job
