"""엔진 두 가지 이상을 같은 일로 돌려 시간 · 메모리 · CPU를 비교하고, 만든 소리가 같은지 본다 (CI용, 소리는 내지 않음).

사용: python devtools/engine_bench.py <이름=엔진 폴더[,환경변수=값...]> ... [--rounds 2] [--out bench.json]
  예: old=host,EASYUTAU_REST_MS=30  new=EasyUtau.app/Contents/Resources/engine/host

한 번 도는 일:
  켜기(준비될 때까지) → 새 프로젝트에 섹터 32개 → 발음 → wav 내보내기(처음: 모두 렌더)
  → 음 높이 곡선을 다섯 번 고침 → 다시 내보내기(고친 곳만 렌더) → 15초 쉬기
잰 것: 각 단계 시간, 프로세스 CPU 시간(사용자+시스템), 가장 큰 메모리(RSS), 쉬는 동안 CPU, 소리 파일 SHA-256.
소리 파일은 비교한 뒤 지운다 (올리지 않는다).
"""
import argparse
import hashlib
import json
import os
import shutil
import statistics
import sys
import tempfile
import threading
import time
from pathlib import Path

import psutil

sys.path.insert(0, str(Path(__file__).resolve().parent))
from engine_test import Engine, notes  # noqa: E402

LYRICS = ["あ", "い", "う", "え", "お", "か", "き", "く", "け", "こ", "さ", "し", "す", "せ", "そ", "た"]


class Sampler:
    """프로세스(와 그 자식)의 메모리 · CPU를 잰다."""

    def __init__(self, pid):
        self.proc = psutil.Process(pid)
        self.peak = 0
        self.stop = False
        threading.Thread(target=self._run, daemon=True).start()

    def _procs(self):
        try:
            return [self.proc] + self.proc.children(recursive=True)
        except psutil.Error:
            return []

    def _run(self):
        while not self.stop:
            rss = 0
            for p in self._procs():
                try:
                    rss += p.memory_info().rss
                except psutil.Error:
                    pass
            self.peak = max(self.peak, rss)
            time.sleep(0.05)

    def cpu(self):
        total = 0.0
        for p in self._procs():
            try:
                t = p.cpu_times()
                total += t.user + t.system
            except psutil.Error:
                pass
        return total


def sha(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        # wav 머리(44바이트)는 빼고 소리 부분만
        f.seek(44)
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:16]


def one_run(host: Path, env: dict, work: Path) -> dict:
    saved = {k: os.environ.get(k) for k in env}
    os.environ.update(env)
    try:
        t0 = time.perf_counter()
        e = Engine(host, work)
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    s = Sampler(e.proc.pid)
    r = {}
    try:
        e.wait_event("ready", timeout=300)
        r["ready_s"] = time.perf_counter() - t0
        r["cpu_ready_s"] = s.cpu()
        r["rss_ready_mb"] = s.peak / 1e6
        singer = next(x for x in e.send("singers")["singers"] if x["found"])
        part = next(p for p in e.send("new", singer=singer["id"])["project"]["parts"] if p["kind"] == "voice")
        made = notes(LYRICS * 2, length=480)
        t = time.perf_counter()
        e.send("setPart", part=part["index"], notes=made, curves=[], label="command.note.add")
        e.wait_phonemes(part["index"], timeout=300)
        r["phonemize_s"] = time.perf_counter() - t

        wav = work / "a.wav"
        t = time.perf_counter()
        e.send("export", path=str(wav), timeout=900)
        r["export_cold_s"] = time.perf_counter() - t
        r["wav_cold"] = sha(wav)
        wav.unlink()

        t = time.perf_counter()
        for k in range(5):
            xs = list(range(made[k * 3]["position"], made[k * 3 + 1]["position"], 5))
            curve = {"abbr": "pitd", "xs": xs, "ys": [int(40 * ((i % 16) - 8) / 8) for i in range(len(xs))]}
            e.send("setPart", part=part["index"], notes=made, curves=[curve], label="command.pitch.draw")
        r["edits_s"] = time.perf_counter() - t
        t = time.perf_counter()
        e.send("export", path=str(wav), timeout=900)
        r["export_warm_s"] = time.perf_counter() - t
        r["wav_warm"] = sha(wav)
        wav.unlink()
        r["cpu_work_s"] = s.cpu()

        before = s.cpu()
        time.sleep(15)
        r["cpu_idle_15s"] = s.cpu() - before
        r["rss_peak_mb"] = s.peak / 1e6
        try:
            r["rss_end_mb"] = psutil.Process(e.proc.pid).memory_info().rss / 1e6
        except psutil.Error:
            pass
        r["errors"] = len(e.errors)
    finally:
        s.stop = True
        e.close()
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("configs", nargs="+")
    ap.add_argument("--rounds", type=int, default=2)
    ap.add_argument("--out", default="bench.json")
    a = ap.parse_args()
    configs = []
    for c in a.configs:
        name, rest = c.split("=", 1)
        parts = rest.split(",")
        env = dict(p.split("=", 1) for p in parts[1:])
        configs.append((name, Path(parts[0]).resolve(), env))

    runs = {name: [] for name, _, _ in configs}
    for rnd in range(a.rounds):
        # 차례를 돌려 가며 (뒤에 도는 쪽이 디스크 캐시 덕을 보지 않게)
        order = configs if rnd % 2 == 0 else list(reversed(configs))
        for name, host, env in order:
            work = Path(tempfile.mkdtemp(prefix=f"bench-{name}-"))
            try:
                r = one_run(host, env, work)
            finally:
                shutil.rmtree(work, ignore_errors=True)
            runs[name].append(r)
            print(f"[{rnd + 1}] {name}: " + ", ".join(f"{k} {v:.2f}" if isinstance(v, float) else f"{k} {v}"
                                                   for k, v in r.items()), flush=True)

    summary = {}
    for name, rs in runs.items():
        row = {}
        for k in rs[0]:
            vals = [r[k] for r in rs if k in r]
            if isinstance(vals[0], (int, float)):
                row[k] = round(statistics.median(vals), 3)
            else:
                row[k] = sorted(set(vals))
        summary[name] = row
    hashes = {name: (row["wav_cold"], row["wav_warm"]) for name, row in summary.items()}
    same = len({json.dumps(h) for h in hashes.values()}) == 1 and all(
        len(row["wav_cold"]) == 1 and len(row["wav_warm"]) == 1 for row in summary.values())
    out = {"summary": summary, "same_sound": same, "runs": runs}
    Path(a.out).write_text(json.dumps(out, indent=1, ensure_ascii=False))

    keys = ["ready_s", "phonemize_s", "export_cold_s", "edits_s", "export_warm_s", "cpu_work_s",
            "cpu_idle_15s", "rss_ready_mb", "rss_peak_mb", "rss_end_mb"]
    print("\n| | " + " | ".join(keys) + " |")
    print("|---|" + "---|" * len(keys))
    for name, row in summary.items():
        print(f"| {name} | " + " | ".join(str(row.get(k, "")) for k in keys) + " |")
    print(f"\n소리 같음: {same}  " + json.dumps(hashes))
    if not same:
        sys.exit("설정에 따라 만든 소리가 달라요")


if __name__ == "__main__":
    main()
