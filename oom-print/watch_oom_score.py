#!/usr/bin/env python3

import datetime
from dataclasses import dataclass
import time
import psutil

WATCH = ["gnome-shell", "python3", "stress-ng", "ollama"]
ignore = set()


@dataclass
class ProcInfo:
    name: str
    pid: int
    rss: int
    vms: int
    shared: int
    text: int
    lib: int
    data: int
    dirty: int
    uss: int
    pss: int
    swap: int
    oom_adj: int
    oom_score: int
    oom_score_adj: int

    @classmethod
    def csv_header(cls) -> str:
        print_list = [
            "name",
            "pid",
            "oom_adj",
            "oom_score",
            "oom_score_adj",
            "vms",
        ]
        return ",".join(print_list) + "\n"

    def csv_row(self) -> str:
        return f"{self.name},{self.pid},{self.oom_adj},{self.oom_score},{self.oom_score_adj},{self.vms}\n"


def scan_pids() -> list[int]:
    return psutil.pids()


def filter_relevants():
    pids = set(scan_pids())
    pids = pids - ignore

    ret = []

    for p in pids:
        try:
            pr = psutil.Process(p)
            name = pr.name()
            if name not in WATCH:
                ignore.add(p)
                continue
            meminfo = pr.memory_full_info()

            with open(f"/proc/{p}/oom_adj") as f:
                oom_adj = int(f.read())
            with open(f"/proc/{p}/oom_score") as f:
                oom_score = int(f.read())
            with open(f"/proc/{p}/oom_score_adj") as f:
                oom_score_adj = int(f.read())
        except psutil.NoSuchProcess:
            continue
        except FileNotFoundError:
            continue

        pi = ProcInfo(
            name,
            p,
            meminfo.rss,
            meminfo.vms,
            meminfo.shared,
            meminfo.text,
            meminfo.lib,
            meminfo.data,
            meminfo.dirty,
            meminfo.uss,
            meminfo.pss,
            meminfo.swap,
            oom_adj,
            oom_score,
            oom_score_adj,
        )
        ret.append(pi)
    return ret


if __name__ == "__main__":
    info = filter_relevants()
    for i in info:
        print(f"{i.name:20} {i.pid:8} {i.oom_score:5}")
    with open(f"{datetime.datetime.now()}.csv", "w", encoding="utf-8") as fil:
        fil.write(ProcInfo.csv_header())
        while True:
            info = filter_relevants()
            print(ProcInfo.csv_header())
            for i in info:
                fil.write(i.csv_row())
                print(i.csv_row(), end="")
            print()
            time.sleep(1)
