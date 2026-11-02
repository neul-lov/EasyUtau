"""앱에 넣을 OpenUtau 엔진 폴더를 만든다 (OpenUtau를 따로 깔지 않아도 EasyUtau가 돌게).

OpenUtau Mac 판(self-contained: .NET 런타임이 통째로 들어 있다)의 프로그램 폴더에서 시작해서
1. engine_host.py와 같은 방법으로 EasyUtauEngine을 OpenUtau.dll 자리에 넣고,
2. 엔진이 쓰지 않는 화면용 파일(Avalonia · Skia · 업데이트 등)을 뺀다:
   엔진에게 직접 물어(--closure) OpenUtau.Core · 기본 발음 방식 · 엔진에서 참조로 닿는 어셈블리만 남기고,
   .NET 런타임 자체와 OpenUtau.Core가 쓰는 네이티브 파일(worldline · onnxruntime · SDL 등)은 그대로 둔다.
3. 메모리 · CPU용 .NET 설정(환경 변수)을 BUNDLE.json의 "env"에 적는다 (--gc 로 고른다).
   엔진 실행 파일은 OpenUtau 실행 파일의 복사본이라 `EasyUtauEngine EasyUtauEngine.dll`처럼 dll을 첫 인자로 받는
   방식으로 돈다. 그래서 runtimeconfig를 고치는 대신, 앱(Engine.swift)과 시험 도구가 켤 때 환경 변수로 넣는다.

사용: python devtools/bundle_engine.py <OpenUtau.app 또는 그 Contents/MacOS> <EasyUtauEngine.dll> <만들 폴더> [--gc 이름]
결과 폴더 안 BUNDLE.json에 OpenUtau 버전 · 뺀 파일 · 크기를 적는다.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from engine_host import prepare  # noqa: E402

# 엔진은 화면을 그리지 않는다: 이 이름이 들어간 네이티브 파일은 Avalonia 화면 전용
UI_NATIVE = ("skiasharp", "harfbuzzsharp", "avalonianative", "libsparkle", "sparkle")

# .NET 설정 묶음 (engine_bench.py로 비교해서 고른다). 소리 결과는 바꾸지 않는 것만.
GC_PRESETS = {
    "default": {},
    # 백그라운드 GC 스레드를 끄고 (엔진은 작은 일만 해서 멈춤이 짧다) 힙을 더 자주 줄인다
    "lean": {"DOTNET_gcConcurrent": "0", "DOTNET_GCConserveMemory": "5"},
    "noconcurrent": {"DOTNET_gcConcurrent": "0"},
    "conserve": {"DOTNET_GCConserveMemory": "5"},
}


def runtime_files(host: Path) -> set:
    """Microsoft.NETCore.App.deps.json에 적힌 .NET 런타임 파일 (지우지 않는다)."""
    deps = json.loads((host / "Microsoft.NETCore.App.deps.json").read_text(encoding="utf-8-sig"))
    target = deps["runtimeTarget"]["name"]
    keep = set()
    for entry in deps["targets"][target].values():
        for kind in ("runtime", "native"):
            for f in (entry.get(kind) or {}):
                keep.add(Path(f).name.lower())
    return keep


def is_managed(path: Path) -> bool:
    """.NET 어셈블리인지 (PE 파일에 CLI 헤더가 있는지)."""
    try:
        data = path.read_bytes()[:4096]
        if data[:2] != b"MZ":
            return False
        pe = int.from_bytes(data[0x3C:0x40], "little")
        if data[pe:pe + 4] != b"PE\0\0":
            return False
        magic = int.from_bytes(data[pe + 24:pe + 26], "little")
        dirs = pe + 24 + (96 if magic == 0x10B else 112)
        cli = dirs + 14 * 8  # 15번째 데이터 디렉터리 = CLR 런타임 헤더
        return int.from_bytes(data[cli:cli + 4], "little") != 0
    except (OSError, IndexError):
        return False


def size_of(folder: Path) -> int:
    return sum(f.stat().st_size for f in folder.rglob("*") if f.is_file() and not f.is_symlink())


def bundle(openutau: Path, engine_dll: Path, out: Path, gc: str) -> dict:
    full = size_of(openutau)
    host = prepare(openutau, engine_dll, out)
    keep_runtime = runtime_files(host)
    closure = subprocess.run([str(host / "EasyUtauEngine"), "EasyUtauEngine.dll", "--closure"], cwd=str(host),
                             capture_output=True, text=True, timeout=120)
    if closure.returncode != 0:
        raise SystemExit("엔진에게 쓰는 파일 목록을 받지 못했어요:\n" + closure.stderr[-2000:])
    needed = {line.strip().lower() for line in closure.stdout.splitlines() if line.strip()}
    if "openutau.core.dll" not in needed or "openutau.plugin.builtin.dll" not in needed:
        raise SystemExit("목록에 OpenUtau.Core · 기본 발음 방식이 없어요:\n" + closure.stdout)
    needed |= {"easyutauengine.dll", "openutau.dll"}

    removed = []
    for f in sorted(host.iterdir()):
        name = f.name.lower()
        if f.is_dir():
            continue
        if name in keep_runtime or name in needed:
            continue
        if name.endswith(".dll") and is_managed(f):
            removed.append(f.name)
            f.unlink()
        elif name.endswith(".dylib") and any(k in name for k in UI_NATIVE):
            removed.append(f.name)
            f.unlink()
    # 하위 폴더는 그대로 둔다 (발음 사전 · 모델 등이 있을 수 있음)

    info = {
        "gc": gc,
        "env": GC_PRESETS[gc],
        "openutau_bytes": full,
        "bundle_bytes": size_of(host),
        "removed": removed,
        "missing_refs": [line[4:].strip() for line in closure.stderr.splitlines() if line.startswith("없음:")],
    }
    (host / "BUNDLE.json").write_text(json.dumps(info, indent=1, ensure_ascii=False))
    return info


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("openutau")
    ap.add_argument("engine_dll")
    ap.add_argument("out")
    ap.add_argument("--gc", default="default", choices=sorted(GC_PRESETS))
    a = ap.parse_args()
    ou = Path(a.openutau)
    if (ou / "Contents" / "MacOS").is_dir():
        ou = ou / "Contents" / "MacOS"
    info = bundle(ou.resolve(), Path(a.engine_dll).resolve(), Path(a.out).resolve(), a.gc)
    print(f"OpenUtau 폴더 {info['openutau_bytes'] / 1e6:.1f} MB → 엔진 폴더 {info['bundle_bytes'] / 1e6:.1f} MB "
          f"(뺀 파일 {len(info['removed'])}개, 설정 {info['gc']})")
    print("뺀 파일:", ", ".join(info["removed"]))
    if info["missing_refs"]:
        print("폴더에 없는 참조 (OpenUtau에도 없던 것):", ", ".join(info["missing_refs"]))
