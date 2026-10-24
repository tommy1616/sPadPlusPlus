#!/bin/sh
# 產生 AppIcon.icns 與 Assets.car。
# 有 Xcode 26 且存在 AppIcon.icon 時，走 .icon → actool（macOS 26 滿版圖示）；
# 否則退回舊式 .icns（會被 macOS 26 套白色底座）。
set -e
cd "$(dirname "$0")"

if [ -d AppIcon.icon ] && xcrun --find actool >/dev/null 2>&1; then
    xcrun actool AppIcon.icon \
        --app-icon AppIcon \
        --compile . \
        --minimum-deployment-target 11.0 \
        --platform macosx \
        --target-device mac \
        --output-partial-info-plist /tmp/spad-icon-partial.plist >/dev/null
    echo "完成：AppIcon.icon → Assets.car + AppIcon.icns"
    exit 0
fi

echo "略過 AppIcon.icon（需要 Xcode 26），改用舊式 .icns"
rm -rf AppIcon.iconset && mkdir -p AppIcon.iconset
python3 - <<'PY'
from PIL import Image
src = Image.open('../icons/icon_B.png').convert('RGBA')
specs = [(16,'16x16'),(32,'16x16@2x'),(32,'32x32'),(64,'32x32@2x'),
         (128,'128x128'),(256,'128x128@2x'),(256,'256x256'),(512,'256x256@2x'),
         (512,'512x512'),(1024,'512x512@2x')]
for px, name in specs:
    src.resize((px, px), Image.LANCZOS).save(f'AppIcon.iconset/icon_{name}.png')
PY
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset
echo "完成：AppIcon.icns"
