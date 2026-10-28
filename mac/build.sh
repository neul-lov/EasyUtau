#!/bin/zsh
# EasyUtau.app을 ./build에 만든다. --install을 붙이면 /Applications에도 넣는다.
#
# 앱에는 엔진(EasyUtauEngine.dll)이 들어간다. 엔진은 Mac에 설치된 OpenUtau의 OpenUtau.Core.dll을
# 참조해서 돌기 때문에, 빌드할 때도 OpenUtau가 있어야 한다 (EASYUTAU_OPENUTAU로 다른 곳을 가리킬 수 있다).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"

OU="${EASYUTAU_OPENUTAU:-/Applications/OpenUtau.app}"
if [[ -d "$OU/Contents/MacOS" ]]; then OUDIR="$OU/Contents/MacOS"; else OUDIR="$OU"; fi
if [[ ! -f "$OUDIR/OpenUtau.Core.dll" ]]; then
    echo "OpenUtau를 찾지 못했어요: $OUDIR (OpenUtau.app을 응용 프로그램 폴더에 넣거나 EASYUTAU_OPENUTAU를 정해 주세요)"
    exit 1
fi

# 엔진 (C#): OpenUtau.Core를 참조해서 dll 하나로
dotnet publish "$ROOT/engine/EasyUtauEngine.csproj" -c Release -o build/engine -p:OpenUtauDir="$OUDIR" --nologo
ls -l build/engine/EasyUtauEngine.dll

# Apple Silicon + 인텔 둘 다 (Xcode가 있어야 함). 없으면 이 Mac 것만.
ARCHS=(--arch arm64 --arch x86_64)
if ! swift build -c release "${ARCHS[@]}"; then
    echo "두 가지 칩용 빌드가 안 됐어요 (Xcode가 필요해요). 이 Mac 것만 만들어요."
    ARCHS=()
    swift build -c release
fi

APP=build/EasyUtau.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine"
cp "$(swift build -c release "${ARCHS[@]}" --show-bin-path)/EasyUtau" "$APP/Contents/MacOS/EasyUtau"
lipo -archs "$APP/Contents/MacOS/EasyUtau"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.txt" "$APP/Contents/Resources/"
cp build/engine/EasyUtauEngine.dll "$APP/Contents/Resources/engine/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>EasyUtau</string>
    <key>CFBundleDisplayName</key><string>EasyUtau</string>
    <key>CFBundleIdentifier</key><string>com.neul.easyutau</string>
    <key>CFBundleExecutable</key><string>EasyUtau</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>EasyUtau</string>
            <key>CFBundleURLSchemes</key><array><string>easyutau</string></array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>OpenUtau 프로젝트</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSItemContentTypes</key><array><string>public.data</string></array>
            <key>CFBundleTypeExtensions</key><array><string>ustx</string><string>ust</string><string>vsqx</string><string>mid</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP"
echo "만들었어요: $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/EasyUtau.app
    cp -R "$APP" /Applications/
    echo "/Applications/EasyUtau.app에 넣었어요"
fi
