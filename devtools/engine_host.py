"""앱이 하는 것과 같은 방식으로 엔진을 돌릴 폴더를 준비한다 (CI · 손으로 시험할 때).

OpenUtau는 자체 포함(self-contained) 빌드라서 OpenUtau.dll 옆에 런타임이 통째로 들어 있다.
엔진(EasyUtauEngine.dll)을 그 폴더 복사본에 넣고 OpenUtau.dll 자리를 차지하게 하면,
사용자가 깔아 둔 OpenUtau의 .NET 런타임과 OpenUtau.Core를 그대로 쓸 수 있다.

사용: python devtools/engine_host.py <OpenUtau 폴더> <EasyUtauEngine.dll> <만들 폴더>
"""
import json
import shutil
import subprocess
import sys
from pathlib import Path


def prepare(openutau: Path, engine_dll: Path, host: Path) -> Path:
    if host.exists():
        shutil.rmtree(host)
    shutil.copytree(openutau, host, symlinks=True)
    # OpenUtau.deps.json의 runtimepack 부분만 Microsoft.NETCore.App.deps.json으로 옮긴다
    deps = json.loads((host / "OpenUtau.deps.json").read_text(encoding="utf-8-sig"))
    target = deps["runtimeTarget"]["name"]
    packs = {k: v for k, v in deps["targets"][target].items() if k.lower().startswith("runtimepack.")}
    libs = {k: v for k, v in deps.get("libraries", {}).items() if k in packs}
    (host / "Microsoft.NETCore.App.deps.json").write_text(
        json.dumps({"runtimeTarget": deps["runtimeTarget"], "compilationOptions": {},
                    "targets": {target: packs}, "libraries": libs}, indent=1))
    (host / "OpenUtau.deps.json").unlink()
    # OpenUtau의 실행 파일(apphost)을 엔진 이름으로 복사해서 OpenUtau와 다른 프로그램으로 보이게 한다
    # (OpenUtau는 같은 이름의 프로그램이 이미 돌고 있으면 바로 꺼진다)
    shutil.copy2(host / "OpenUtau", host / "EasyUtauEngine")
    shutil.copy2(engine_dll, host / "EasyUtauEngine.dll")
    shutil.copy2(engine_dll, host / "OpenUtau.dll")
    subprocess.run(["xattr", "-dr", "com.apple.quarantine", str(host)], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return host


if __name__ == "__main__":
    ou = Path(sys.argv[1])
    if (ou / "Contents" / "MacOS").is_dir():
        ou = ou / "Contents" / "MacOS"
    print(prepare(ou, Path(sys.argv[2]), Path(sys.argv[3])))
