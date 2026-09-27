#!/bin/bash
# CI 完整测试脚本:SPM 快速测试 + Xcode 工程测试
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> swift test (DisplayTunerCore)"
swift test --parallel

echo "==> xcodegen generate"
xcodegen generate

echo "==> xcodebuild test (DisplayTuner scheme)"
set -o pipefail
xcodebuild -project DisplayTuner.xcodeproj \
  -scheme DisplayTuner \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test 2>&1 | grep -E "Test Suite|Test Case.*(passed|failed)|TEST|error:|warning: .*[Ss]ign" || true
