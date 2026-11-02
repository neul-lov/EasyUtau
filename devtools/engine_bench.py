"""엔진 두 가지 이상을 같은 일로 돌려 시간 · 메모리 · CPU를 비교하고, 만든 소리가 같은지 본다 (CI용, 소리는 내지 않음).

사용: python devtools/engine_bench.py <이름=엔진 폴더[,환경변수=값...]> ... [--rounds 2] [--out bench.json]
  예: old=host,EASYUTAU_REST_MS=30  new=EasyUtau.app/Contents/Resources/engine/host

한 번 도는 일:
  켜기(준비될 때까지) → 새 프로젝트에 섹터 32개 → 발음 → wav 내보내기(처음: 모두 렌더)
  → 음 높이 곡선을 다섯 번 고침 → 다시 내보내기(고친 곳만 렌더) → 15초 쉬기
잰 것: 각 단계 시간, 프로세스 CPU 시간(사용자+시스템), 가장 큰 메모리(RSS), 쉬는 동안 CPU.
소리: worldline은 같은 설정으로 두 번 만들어도 바이트가 같지 않다 (숨소리 잡음 등). 그래서 SHA 대신
첫 'old' 소리와의 스펙트럼 차이(dB, 로그 크기 평균 차)를 재고, 'old'끼리의 차이(같은 엔진의 흔들림)와 견준다.
소리 파일은 임시 폴더에서 비교한 뒤 지운다 (올리지 않는다).
"""
import argparse
import json
import os
import shutil
import statistics
import sys
import tempfile
import threading
import time
import wave
from pathlib import Path

import numpy as np
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


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path)) as w:
        data = w.readframes(w.getnframes())
        width, channels = w.getsampwidth(), w.getnchannels()
    x = np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768 if width == 2 else np.frombuffer(data, dtype="<f4")
    return x.reshape(-1, channels).mean(axis=1) if channels > 1 else x


def spectrum_db(x: np.ndarray, n=2048, hop=512) -> np.ndarray:
    frames = np.lib.stride_tricks.sliding_window_view(x, n)[::hop] * np.hanning(n)
    return 20 * np.log10(np.abs(np.fft.rfft(frames, axis=1)) + 1e-5)


def spectral_diff(a: np.ndarray, b: np.ndarray) -> float:
    """두 소리의 로그 스펙트럼 평균 차 (dB). 소리가 있는 프레임만."""
    m = min(len(a), len(b))
    sa, sb = spectrum_db(a[:m]), spectrum_db(b[:m])
    # 들리는 칸만: 전체에서 가장 큰 소리보다 50 dB 안쪽인 시간 · 주파수 칸
    top = max(sa.max(), sb.max())
    loud = np.maximum(sa, sb) > top - 50
    return float(np.abs(sa[loud] - sb[loud]).mean()) if loud.any() else 0.0


def keep(path: Path, store: Path, tag: str) -> str:
    dest = store / f"{tag}.wav"
    shutil.move(str(path), dest)
    return str(dest)


def one_run(host: Path, env: dict, work: Path, store: Path, tag: str) -> dict:
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
        r["wav_cold"] = keep(wav, store, tag + "-cold")

        t = time.perf_counter()
        for k in range(5):
            xs = list(range(made[k * 3]["position"], made[k * 3 + 1]["position"], 5))
            curve = {"abbr": "pitd", "xs": xs, "ys": [int(40 * ((i % 16) - 8) / 8) for i in range(len(xs))]}
            e.send("setPart", part=part["index"], notes=made, curves=[curve], label="command.pitch.draw")
        r["edits_s"] = time.perf_counter() - t
        t = time.perf_counter()
        e.send("export", path=str(wav), timeout=900)
        r["export_warm_s"] = time.perf_counter() - t
        r["wav_warm"] = keep(wav, store, tag + "-warm")
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
    store = Path(tempfile.mkdtemp(prefix="bench-wav-"))
    for rnd in range(a.rounds):
        # 차례를 돌려 가며 (뒤에 도는 쪽이 디스크 캐시 덕을 보지 않게)
        order = configs if rnd % 2 == 0 else list(reversed(configs))
        for name, host, env in order:
            work = Path(tempfile.mkdtemp(prefix=f"bench-{name}-"))
            try:
                r = one_run(host, env, work, store, f"{name}-{rnd}")
            finally:
                shutil.rmtree(work, ignore_errors=True)
            runs[name].append(r)
            print(f"[{rnd + 1}] {name}: " + ", ".join(f"{k} {v:.2f}" if isinstance(v, float) else f"{k} {v}"
                                                   for k, v in r.items()), flush=True)

    # 소리 비교: 기준 = 첫 설정의 첫 번째 소리
    ref_name = configs[0][0]
    for kind in ("cold", "warm"):
        ref = read_wav(Path(runs[ref_name][0]["wav_" + kind]))
        for name, rs in runs.items():
            for i, r in enumerate(rs):
                path = Path(r.pop("wav_" + kind))
                if name == ref_name and i == 0:
                    continue
                x = read_wav(path)
                r["db_diff_" + kind] = spectral_diff(ref, x)
                r["len_diff_" + kind] = abs(len(x) - len(ref))
    shutil.rmtree(store, ignore_errors=True)

    summary = {}
    for name, rs in runs.items():
        row = {}
        for k in sorted({k for r in rs for k in r}):
            vals = [r[k] for r in rs if k in r]
            row[k] = round(statistics.median(vals), 3)
            if k.startswith("db_diff") or k.startswith("len_diff"):
                row[k] = round(max(vals), 3)  # 소리 차이는 가장 큰 것
        summary[name] = row
    # 같은 엔진끼리의 흔들림보다 크게 다르면 소리가 바뀐 것
    base = max(summary[ref_name].get("db_diff_cold", 0), summary[ref_name].get("db_diff_warm", 0))
    limit = base * 1.5 + 0.2
    same = all(max(row.get("db_diff_cold", 0), row.get("db_diff_warm", 0)) <= limit
               and max(row.get("len_diff_cold", 0), row.get("len_diff_warm", 0)) <= 1024
               for row in summary.values())
    out = {"summary": summary, "same_sound": same, "same_engine_db": base, "limit_db": limit, "runs": runs}
    Path(a.out).write_text(json.dumps(out, indent=1, ensure_ascii=False))

    keys = ["ready_s", "phonemize_s", "export_cold_s", "edits_s", "export_warm_s", "cpu_work_s",
            "cpu_idle_15s", "rss_ready_mb", "rss_peak_mb", "rss_end_mb", "db_diff_cold", "db_diff_warm"]
    print("\n| | " + " | ".join(keys) + " |")
    print("|---|" + "---|" * len(keys))
    for name, row in summary.items():
        print(f"| {name} | " + " | ".join(str(row.get(k, "")) for k in keys) + " |")
    print(f"\n소리 같음: {same} (같은 엔진끼리 흔들림 {base:.3f} dB, 허용 {limit:.3f} dB)")
    if not same:
        sys.exit("설정에 따라 만든 소리가 달라요")


if __name__ == "__main__":
    main()
