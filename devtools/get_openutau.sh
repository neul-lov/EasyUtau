#!/bin/bash
# 최신 OpenUtau Mac 버전을 받아 ./OpenUtau.app 으로 꺼낸다 (CI용).
# 새 OpenUtau dmg는 열 때 사용권 동의를 물어서 yes를 넣어 준다.
set -euo pipefail
tag=$(gh release view -R stakira/OpenUtau --json tagName -q .tagName)
gh release download "$tag" -R stakira/OpenUtau -p "*osx-arm64*.dmg" -O ou.dmg --clobber
(yes || true) | PAGER=cat hdiutil attach ou.dmg -nobrowse -mountpoint /tmp/ou > /dev/null
cp -R /tmp/ou/OpenUtau.app ./
hdiutil detach /tmp/ou > /dev/null
echo "OpenUtau $tag"
