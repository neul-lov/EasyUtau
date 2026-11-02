#!/bin/bash
# OpenUtau Mac 판(Apple Silicon)을 받아 ./OpenUtau.app 으로 꺼낸다 (CI용).
# 앱에 넣는 엔진의 재료라서 버전을 고정한다 (OPENUTAU_TAG로 바꿀 수 있다. latest = 최신 정식판).
# 새 OpenUtau dmg는 열 때 사용권 동의를 물어서 yes를 넣어 준다.
set -euo pipefail
tag="${OPENUTAU_TAG:-0.1.576}"
if [[ "$tag" == "latest" ]]; then
    tag=$(gh release view -R stakira/OpenUtau --json tagName -q .tagName)
fi
gh release download "$tag" -R stakira/OpenUtau -p "*osx-arm64*.dmg" -O ou.dmg --clobber
(yes || true) | PAGER=cat hdiutil attach ou.dmg -nobrowse -mountpoint /tmp/ou > /dev/null
cp -R /tmp/ou/OpenUtau.app ./
hdiutil detach /tmp/ou > /dev/null
echo "OpenUtau $tag"
