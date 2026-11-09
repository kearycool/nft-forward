#!/usr/bin/env bash
# install-nft-forward.sh — nft-forward 一键安装/升级脚本 (2026-11-10)
#
# 用法 (在 VPS 上, 一般在 /root 里运行):
#   bash install-nft-forward.sh
#
# 做的事 (四步, 哪步失败后面就不跑):
#   1. 从 GitHub 拉最新 nft-forward.sh (先下到文件, 校验通过才继续, 不直接管道执行)
#   2. 显示版本号 (语法检查 + 读 SCRIPT_VERSION)
#   3. 安装 / 升级 (bash nft-forward.sh install; 已有规则在 /etc/nft-forward/rules.conf 里, 不会丢)
#   4. 上线前检查 (nft-forward check)
#
# 全程不用你输东西。新机器和升级都用同一行。
# 换仓库地址时改下面的 URL, 或用环境变量: NFT_FORWARD_URL="https://..." bash install-nft-forward.sh
set -euo pipefail

URL="${NFT_FORWARD_URL:-https://raw.githubusercontent.com/kearycool/nft-forward/refs/heads/main/nft-forward.sh}"
FILE="nft-forward.sh"

command -v curl >/dev/null 2>&1 || { echo "错误: 本机没有 curl, 先装: apt-get install -y curl (yum/dnf/apk 用对应命令)"; exit 1; }

echo "== 1/4 下载最新版 =="
curl -fsSL -o "$FILE" "$URL" || { echo "错误: 下载失败, 检查网络或 GitHub 链接 (地址: $URL)"; exit 1; }
[ -s "$FILE" ] || { echo "错误: 下载到的文件是空的, 没装任何东西"; exit 1; }
echo "已下载到: $(pwd)/$FILE"

echo "== 2/4 确认版本 =="
bash -n "$FILE" || { echo "错误: 下载到的脚本语法有问题, 没装任何东西"; exit 1; }
VER=$(grep -m1 '^SCRIPT_VERSION="' "$FILE" | cut -d'"' -f2)
[ -n "$VER" ] || { echo "错误: 下载到的文件里没找到版本号, 没装任何东西"; exit 1; }
echo "下载到的是 nft-forward $VER"

echo "== 3/4 安装/升级 =="
bash "$FILE" install

echo "== 4/4 上线前检查 =="
if nft-forward check; then
    echo
    echo "完成: nft-forward $VER 已装好, 检查通过, 可以加规则了。"
    echo "菜单: nft-forward (或 zf)"
    echo "加规则: nft-forward add <本机端口> <目标IP或域名> [目标端口] [tcp|udp|both]"
else
    echo
    echo "安装已完成, 但检查发现了碰撞风险 (上面标 !! 的), 先处理再加规则。"
    exit 1
fi
