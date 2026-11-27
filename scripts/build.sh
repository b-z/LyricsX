#!/bin/sh
# 在 Xcode 26 / macOS 26 上编译本分支（ad-hoc 签名）。
# 用法：scripts/build.sh [Debug|Release]（默认 Debug）   产物：build/Build/Products/<配置>/LyricsX.app
# 发布：scripts/build.sh Release 之后，产物旁边会生成 LyricsX-<版本>.zip，上传到 GitHub Release。
set -e
CONFIG="${1:-Debug}"
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

# 3. mediaremote-adapter：macOS 15.4+ 读取「正在播放」（含浏览器）必须靠它（BSD-3-Clause）
ADAPTER=build/vendor/mediaremote-adapter
ADAPTER_REV=0e82bf1c44ec39554fbfc402ec88a48c6ae2a0fd
if [ ! -d "$ADAPTER/build/MediaRemoteAdapter.framework" ]; then
  command -v cmake >/dev/null || { echo "需要 cmake：brew install cmake"; exit 1; }
  rm -rf "$ADAPTER" && mkdir -p build/vendor
  git clone -q https://github.com/ungive/mediaremote-adapter.git "$ADAPTER"
  git -C "$ADAPTER" checkout -q "$ADAPTER_REV"
  (cd "$ADAPTER" && mkdir -p build && cd build && cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" && cmake --build . -j8)
fi

# 4. App 本体（CXShim 要用 CombineX 实现，和上游 DevOpen 脚本一致）
CX_COMBINE_IMPLEMENTATION=CombineX xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration "$CONFIG" \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  MACOSX_DEPLOYMENT_TARGET=10.13 build
git checkout -- "LyricsX/Supporting Files/Info.plist"   # 构建脚本会自动改版本号，还原它

APP="build/Build/Products/$CONFIG/LyricsX.app"
codesign --force --deep -s - "$APP"
if [ "$CONFIG" = Release ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
  (cd "$(dirname "$APP")" && rm -f "LyricsX-$VERSION.zip" && ditto -c -k --keepParent LyricsX.app "LyricsX-$VERSION.zip")
  echo "完成：$APP 和 $(dirname "$APP")/LyricsX-$VERSION.zip"
else
  echo "完成：$APP"
fi
