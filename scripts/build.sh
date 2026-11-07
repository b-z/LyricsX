#!/bin/sh
# 在 Xcode 26 / macOS 26 上编译本分支（Debug，ad-hoc 签名）。
# 用法：scripts/build.sh   产物：build/Build/Products/Debug/LyricsX.app
set -e
cd "$(dirname "$0")/.."

# 1. Carthage 依赖（老版本库需要提高部署目标、关闭 warnings-as-errors 和签名）
if [ ! -d Carthage/Build/Mac/Sparkle.framework ]; then
  XCODE_XCCONFIG_FILE="$PWD/scripts/carthage-xcode26.xcconfig" carthage bootstrap --platform macOS --cache-builds
fi

# 2. Carthage 编出来的 SnapKit 带的是 iOS 头文件，按 macOS SDK 重新编一次
if grep -q UIKit Carthage/Build/Mac/SnapKit.framework/Headers/SnapKit-Swift.h 2>/dev/null; then
  xcodebuild -project Carthage/Checkouts/SnapKit/SnapKit.xcodeproj -scheme SnapKit -configuration Release \
    -sdk macosx -derivedDataPath build/snapkit MACOSX_DEPLOYMENT_TARGET=10.13 ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
  rm -rf Carthage/Build/Mac/SnapKit.framework
  cp -R build/snapkit/Build/Products/Release/SnapKit.framework Carthage/Build/Mac/
fi

# 3. App 本体（CXShim 要用 CombineX 实现，和上游 DevOpen 脚本一致）
CX_COMBINE_IMPLEMENTATION=CombineX xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  MACOSX_DEPLOYMENT_TARGET=10.13 build
git checkout -- "LyricsX/Supporting Files/Info.plist"   # 构建脚本会自动改版本号，还原它

codesign --force --deep -s - build/Build/Products/Debug/LyricsX.app
echo "完成：build/Build/Products/Debug/LyricsX.app"
