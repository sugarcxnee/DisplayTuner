#!/bin/bash
# 检查并准备构建环境;缺少 XcodeGen 时尝试通过 Homebrew 安装
set -euo pipefail

command -v swift >/dev/null 2>&1 || { echo "❌ 未找到 swift,请先安装 Xcode"; exit 1; }
command -v xcodebuild >/dev/null 2>&1 || { echo "❌ 未找到 xcodebuild,请先安装 Xcode 命令行工具"; exit 1; }

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "未找到 XcodeGen,正在通过 Homebrew 安装..."
    brew install xcodegen
  else
    echo "❌ 未找到 XcodeGen,且无 Homebrew 可用。请从 https://github.com/yonaskolb/XcodeGen 安装"
    exit 1
  fi
fi

echo "✅ 构建环境就绪:"
echo "   swift:     $(swift --version | head -1)"
echo "   xcodegen:  $(xcodegen --version)"
