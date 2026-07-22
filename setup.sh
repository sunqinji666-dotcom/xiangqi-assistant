#!/bin/bash
# XiangqiAssistant 一键启动脚本
# 用法：在 Terminal 里 cd 到项目目录，然后运行 bash setup.sh

set -e
cd "$(dirname "$0")"

echo ""
echo "🔧 XiangqiAssistant 环境准备中..."
echo "================================"

# ── 1. 检查 Xcode Command Line Tools ──────────────────────────────────────────
if ! xcode-select -p &>/dev/null; then
    echo "⚠️  未检测到 Xcode Command Line Tools，正在安装..."
    xcode-select --install
    echo "安装完成后请重新运行此脚本。"
    exit 1
fi
echo "✅ Xcode CLI 已就绪"

# ── 2. 检查 Homebrew ───────────────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
    echo "📦 安装 Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # 让 Homebrew 加入 PATH（Apple Silicon）
    eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
fi
echo "✅ Homebrew 已就绪"

# ── 3. 安装 xcodegen ──────────────────────────────────────────────────────────
if ! command -v xcodegen &>/dev/null; then
    echo "📦 安装 xcodegen..."
    brew install xcodegen
fi
echo "✅ xcodegen 已就绪"

# ── 4. 为引擎文件加可执行权限 ────────────────────────────────────────────────
ENGINE="Sources/XiangqiAssistant/Resources/Engine/pikafish-apple-silicon"
if [ -f "$ENGINE" ]; then
    chmod +x "$ENGINE"
    echo "✅ pikafish 引擎权限已设置"
else
    echo "❌ 找不到引擎文件：$ENGINE"
    echo "   请确认 pikafish-apple-silicon 已放入该目录"
    exit 1
fi

# ── 5. 生成 Xcode 项目 ────────────────────────────────────────────────────────
echo "🔨 生成 XiangqiAssistant.xcodeproj..."
xcodegen generate --spec project.yml
echo "✅ Xcode 项目生成完毕"

# ── 6. 打开 Xcode ─────────────────────────────────────────────────────────────
echo ""
echo "🎉 准备完成！"
echo "================================"
echo ""
echo "接下来在 Xcode 里只需两步："
echo "  1. 顶部菜单选 XiangqiAssistant target → Signing & Capabilities"
echo "     → 选择你的 Team（登录 Apple ID 即可，免费账号可用）"
echo "  2. 按 Cmd+R 运行"
echo ""
echo "首次运行时系统会弹出「屏幕录制」权限请求，点允许即可。"
echo "运行后菜单栏会出现 ⊙ 图标，点击 → 一键校准 开始使用。"
echo ""
open XiangqiAssistant.xcodeproj
