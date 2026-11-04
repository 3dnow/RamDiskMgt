#!/bin/bash
# 构建 Release 版 RamDiskMgt.app 与 rdmctl，输出到 build/。
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "需要 xcodegen：brew install xcodegen"; exit 1; }
xcodegen generate --quiet
xcodebuild -project RamDiskMgt.xcodeproj -scheme RamDiskMgt -configuration Release -derivedDataPath build/DerivedData.noindex build -quiet
rm -rf build/RamDiskMgt.app
cp -R build/DerivedData.noindex/Build/Products/Release/RamDiskMgt.app build/
(cd Packages/RamDiskKit && swift build -c release --product rdmctl -q)
cp Packages/RamDiskKit/.build/release/rdmctl build/rdmctl
echo "完成："
echo "  $(pwd)/build/RamDiskMgt.app"
echo "  $(pwd)/build/rdmctl"
