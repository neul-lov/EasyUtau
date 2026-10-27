"""엔진을 켜고 앱이 하는 것과 같은 명령을 보내 본다 (소리는 내지 않고 파일로만 확인).

사용: python devtools/engine_test.py <엔진 폴더 (engine_host.py가 만든 것)> [작업 폴더]

하는 것: 가수 찾기 → 새 프로젝트 → 섹터 넣기 → 발음 맞추기 → 되돌리기/다시 → 저장하고 다시 열기
→ wav로 내보내기(소리가 들어 있는지 확인) → 음 높이 곡선 · 떨림 · 발음 바꾸기.
결과는 숫자로만 보여 준다 (소리 파일은 올리지 않는다).
"""
import json
import os
import struct
import subprocess
import sys
import threading
import time
import wave
from pathlib import Path


class Engine:
    def __init__(self, host: Path, work: Path):
        env = dict(os.environ)
        env["EASYUTAU_NO_AUDIO"] = "1"
        env["EASYUTAU_CACHE"] = str(work / "cache")
        self.proc = subprocess.Popen(
            [str(host / "EasyUtauEngine"), "EasyUtauEngine.dll"],
            cwd=str(host), env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        self.id = 0
        self.replies = {}
        self.events = []
        self.lock = threading.Condition()
        self.errors = []
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._read_err, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                print("엔진이 보낸 알 수 없는 줄:", line[:200])
                continue
            with self.lock:
                if "event" in msg:
                    self.events.append(msg)
                    if msg["event"] == "error":
                        self.errors.append(msg.get("message", ""))
                else:
                    self.replies[msg.get("id")] = msg
                self.lock.notify_all()

    def _read_err(self):
        self.log = []
        for line in self.proc.stderr:
            self.log.append(line.rstrip())

    def wait_event(self, name, timeout=120, where=None):
        end = time.time() + timeout
        with self.lock:
            seen = 0
            while time.time() < end:
                for e in self.events[seen:]:
                    if e["event"] == name and (where is None or where(e)):
                        return e
                seen = len(self.events)
                self.lock.wait(0.2)
        raise TimeoutError(f"{name} 알림이 오지 않았어요")

    def wait_phonemes(self, part, timeout=90):
        """그 파트의 음소가 다 맞을 때까지 (발음 방식이 바뀌면 엔진이 다시 맞춘다). 마지막 결과."""
        end = time.time() + timeout
        last = None
        with self.lock:
            while time.time() < end:
                got = [e for e in self.events if e["event"] == "phonemized" and e.get("part") == part]
                if got:
                    last = got[-1]
                    if not any(p["error"] for p in last["phonemes"]):
                        break
                self.lock.wait(0.2)
        if last is None:
            raise TimeoutError("phonemized 알림이 오지 않았어요")
        return last

    def send(self, cmd, timeout=180, **args):
        self.id += 1
        msg = dict(args)
        msg["id"] = self.id
        msg["cmd"] = cmd
        self.proc.stdin.write(json.dumps(msg, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()
        end = time.time() + timeout
        with self.lock:
            while time.time() < end:
                if self.id in self.replies:
                    reply = self.replies.pop(self.id)
                    if not reply.get("ok"):
                        raise RuntimeError(f"{cmd}: {reply.get('error')}")
                    return reply
                self.lock.wait(0.2)
        raise TimeoutError(f"{cmd} 답이 오지 않았어요")

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=20)
        except Exception:
            self.proc.kill()


def loudness(path: Path):
    """wav의 소리 크기 (0 = 묵음)와 길이(초)."""
    with wave.open(str(path)) as w:
        frames = w.getnframes()
        data = w.readframes(frames)
        width, channels, rate = w.getsampwidth(), w.getnchannels(), w.getframerate()
    if width == 2:
        values = struct.unpack("<%dh" % (len(data) // 2), data[: len(data) // 2 * 2])
        peak = max(abs(v) for v in values) / 32768 if values else 0
        rms = (sum(v * v for v in values) / max(1, len(values))) ** 0.5 / 32768
    else:  # 32비트 실수
        values = struct.unpack("<%df" % (len(data) // 4), data[: len(data) // 4 * 4])
        peak = max(abs(v) for v in values) if values else 0
        rms = (sum(v * v for v in values) / max(1, len(values))) ** 0.5
    return peak, rms, frames / max(1, rate)


def notes(lyrics, start=1920, length=480, tones=(60, 62, 64, 65, 67, 65, 64, 62)):
    out = []
    pos = start
    for i, lyric in enumerate(lyrics):
        out.append({"position": pos, "duration": length, "tone": tones[i % len(tones)], "lyric": lyric,
                    "tuning": 0, "vibrato": {"length": 0, "period": 175, "depth": 25, "in": 10, "out": 10,
                                             "shift": 0, "drift": 0, "volLink": 0},
                    "exps": [], "overrides": []})
        pos += length
    return out


def main():
    host = Path(sys.argv[1]).resolve()
    work = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else Path("out/engine-test").resolve()
    work.mkdir(parents=True, exist_ok=True)
    e = Engine(host, work)
    result = {}
    try:
        ready = e.wait_event("ready", timeout=180)
        print("엔진 준비됨:", json.dumps({k: ready.get(k) for k in ("openutau", "audio", "audioWarning")},
                                   ensure_ascii=False))
        result["openutau"] = ready.get("openutau")

        singers = e.send("singers")["singers"]
        found = [s for s in singers if s["found"]]
        print(f"가수 {len(singers)}명 (쓸 수 있는 음원 {len(found)}개):",
              ", ".join(f"{s['name']}({s['type']})" for s in found[:5]))
        result["singers"] = len(found)
        if not found:
            raise SystemExit("쓸 수 있는 음원이 없어요 (CI라면 음원 받기 단계를 보세요)")
        singer = found[0]

        reply = e.send("new", singer=singer["id"])
        project = reply["project"]
        part = next(p for p in project["parts"] if p["kind"] == "voice")
        print(f"새 프로젝트: 트랙 {len(project['tracks'])}개, 파트 {len(project['parts'])}개, "
              f"가수 {project['tracks'][0]['singer']['name']}, 발음 {project['tracks'][0]['phonemizerName']}")

        lyrics = sys.argv[3].split(",") if len(sys.argv) > 3 else ["あ", "い", "う", "え", "お", "か", "き", "く"]
        made = notes(lyrics)
        reply = e.send("setPart", part=part["index"], notes=made, curves=[], label="command.note.add")
        got = reply["part"]["notes"]
        assert len(got) == len(made), (len(got), len(made))
        # 엔진이 기본 음 넘어가기(포르타멘토) 점을 채워 줬는지
        assert got[0]["pitch"]["data"], "기본 피치 점이 없어요"
        print(f"섹터 {len(got)}개 넣음, 기본 피치 점 {len(got[0]['pitch']['data'])}개")
        if reply.get("notice"):
            print("엔진 알림:", reply["notice"])
        result["phonemizer"] = reply["project"]["tracks"][0]["phonemizerName"]

        phonemes = e.wait_phonemes(part["index"], timeout=180)["phonemes"]
        errors = [p for p in phonemes if p["error"]]
        print(f"발음 {len(phonemes)}개 ({result['phonemizer']}), 음원에 없는 소리 {len(errors)}개: "
              + " ".join(p["phoneme"] for p in phonemes[:12]))
        result["phonemes"] = len(phonemes)
        result["phoneme_errors"] = len(errors)
        assert not errors, "음원에 없는 소리가 있어요 (이대로면 그 섹터는 소리가 안 나요)"

        # 음 높이 곡선 · 떨림 · 발음 바꾸기
        xs = list(range(made[2]["position"], made[3]["position"], 5))
        curve = {"abbr": "pitd", "xs": xs, "ys": [int(60 * ((i % 20) - 10) / 10) for i in range(len(xs))]}
        made[3]["vibrato"] = {"length": 70, "period": 175, "depth": 30, "in": 20, "out": 15,
                              "shift": 0, "drift": 0, "volLink": 0}
        made[4]["overrides"] = [{"index": 0, "offset": 20}]
        e.send("setPart", part=part["index"], notes=made, curves=[curve], label="command.pitch.draw")
        after = e.send("part", part=part["index"])["part"]
        assert any(c["abbr"] == "pitd" for c in after["curves"]), "음 높이 곡선이 저장되지 않았어요"
        assert after["notes"][3]["vibrato"]["length"] == 70
        print("곡선 점", len(next(c for c in after["curves"] if c["abbr"] == "pitd")["xs"]),
              "· 떨림", after["notes"][3]["vibrato"]["depth"], "· 발음 밀기", after["notes"][4]["overrides"])

        # 되돌리기 · 다시 하기
        e.send("undo")
        back = e.send("part", part=part["index"])["part"]
        assert not [c for c in back["curves"] if c["abbr"] == "pitd" and c["xs"]], "되돌리기가 곡선을 되돌리지 않았어요"
        e.send("redo")
        again = e.send("part", part=part["index"])["part"]
        assert any(c["abbr"] == "pitd" for c in again["curves"]), "다시 하기가 되지 않았어요"
        print("되돌리기 · 다시 하기 좋아요")

        # 저장하고 다시 열기 (OpenUtau가 읽는 .ustx)
        path = work / "test.ustx"
        e.send("save", path=str(path))
        assert path.exists() and path.stat().st_size > 200
        e.send("new")
        reopened = e.send("open", path=str(path))["project"]
        part2 = next(p for p in reopened["parts"] if p["kind"] == "voice")
        notes2 = e.send("part", part=part2["index"])["part"]["notes"]
        assert len(notes2) == len(made), (len(notes2), len(made))
        assert [n["lyric"] for n in notes2] == [n["lyric"] for n in made]
        print(f"저장 · 다시 열기 좋아요 ({path.stat().st_size}바이트, 섹터 {len(notes2)}개)")
        result["ustx_bytes"] = path.stat().st_size

        # "저장됨" 표시: 고치면 꺼지고, ⌘Z로 저장한 때까지 되돌리면 다시 켜진다
        assert reopened["saved"], "막 연 파일이 저장 안 함으로 보여요"
        changed = [dict(n) for n in notes2]
        changed[0]["lyric"] = changed[1]["lyric"]
        r = e.send("setPart", part=part2["index"], notes=changed, curves=[], label="command.note.lyric")
        assert not r["project"]["saved"], "고쳤는데 저장됨으로 보여요"
        r = e.send("undo")
        assert r["done"] and r["label"] == "command.note.lyric", r.get("label")
        assert r["project"]["saved"], "저장한 때까지 되돌렸는데 저장 안 함으로 보여요"
        r = e.send("redo")
        assert r["done"] and not r["project"]["saved"]
        e.send("undo")
        r = e.send("undo")
        assert not r["done"] and r["project"]["saved"], "되돌릴 것이 없는데 무언가 되돌렸어요"
        print("저장됨 표시 · 되돌릴 것 없음 좋아요")

        # AutoTuner와 같은 파일 쓰기: AutoTuner(파이썬 yaml)가 읽고 고쳐 쓴 파일을 다시 연다
        try:
            import yaml
        except ImportError:
            yaml = None
            print("pyyaml이 없어서 AutoTuner 호환 확인은 건너뛰어요")
        if yaml:
            data = yaml.safe_load(path.read_text(encoding="utf-8"))
            vp = data["voice_parts"][0]
            assert float(data["tempos"][0]["bpm"]) > 0
            assert all({"position", "duration", "tone", "lyric"} <= set(n) for n in vp["notes"])
            assert [n["lyric"] for n in vp["notes"]] == [n["lyric"] for n in made]
            vp["notes"][0]["lyric"] = "+"
            edited = work / "autotuner-edited.ustx"
            edited.write_text(yaml.safe_dump(data, allow_unicode=True, sort_keys=False), encoding="utf-8")
            again = e.send("open", path=str(edited))["project"]
            part3 = next(p for p in again["parts"] if p["kind"] == "voice")
            notes3 = e.send("part", part=part3["index"])["part"]["notes"]
            assert notes3[0]["lyric"] == "+" and len(notes3) == len(made)
            print("AutoTuner가 읽고 고쳐 쓴 파일 다시 열기 좋아요")
            result["autotuner_compat"] = True
            e.send("open", path=str(path))

        # 내보내기: 실제로 테토가 부른 소리가 들어 있는지 (파일은 올리지 않는다)
        wav = work / "test.wav"
        e.send("export", path=str(wav), timeout=600)
        peak, rms, seconds = loudness(wav)
        print(f"내보낸 소리: {seconds:.1f}초, 가장 큰 소리 {peak:.3f}, 평균 {rms:.4f}")
        result.update(wav_seconds=round(seconds, 2), wav_peak=round(peak, 4), wav_rms=round(rms, 5))
        assert peak > 0.01, "내보낸 소리가 비어 있어요"
        wav.unlink()

        if e.errors:
            print("엔진이 알린 문제:", e.errors[:3])
    finally:
        e.close()
        tail = "\n".join(getattr(e, "log", [])[-25:])
        if tail:
            print("--- 엔진 기록 (끝부분)\n" + tail)
    print("RESULT " + json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
