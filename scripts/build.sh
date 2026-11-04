#!/bin/bash
# 构建 Release 版 RamDiskMgt.app 与 rdmctl，输出到 build/。
#
# 可选环境变量：
#   RDM_SIGN_IDENTITY="Apple Development: 名字 (TEAMID)"
#       用固定证书签名，默认是 ad-hoc（"-"）。ad-hoc 签名每次构建都不同，钥匙串里的备份密码条目
#       会在每次重新构建后再次询问是否允许访问，登录项也会失效；固定证书没有这些问题。
#   RDM_DIAGNOSTICS=1
#       把 --selftest / --snapshot 等诊断入口编进 Release 产物（Debug 构建默认包含）。
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "需要 xcodegen：brew install xcodegen"; exit 1; }
xcodegen generate --quiet
extra=()
if [[ -n "${RDM_DIAGNOSTICS:-}" ]]; then
  extra+=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) RDM_DIAGNOSTICS')
fi
xcodebuild -project RamDiskMgt.xcodeproj -scheme RamDiskMgt -configuration Release -derivedDataPath build/DerivedData.noindex \
  CODE_SIGN_IDENTITY="${RDM_SIGN_IDENTITY:--}" ${extra[@]+"${extra[@]}"} build -quiet
rm -rf build/RamDiskMgt.app
cp -R build/DerivedData.noindex/Build/Products/Release/RamDiskMgt.app build/
(cd Packages/RamDiskKit && swift build -c release --product rdmctl -q)
cp Packages/RamDiskKit/.build/release/rdmctl build/rdmctl
echo "完成："
echo "  $(pwd)/build/RamDiskMgt.app"
echo "  $(pwd)/build/rdmctl"
