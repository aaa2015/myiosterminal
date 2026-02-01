#!/bin/bash

# iOS Terminal - SSH 安装脚本
# 用法: ./install_via_ssh.sh <iPad_IP地址>
# 示例: ./install_via_ssh.sh 192.168.1.100

set -e

IPAD_IP="${1:-}"
APP_NAME="iOSTerminal.app"
IPA_FILE="iOSTerminal.ipa"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ -z "$IPAD_IP" ]; then
    echo -e "${YELLOW}用法: $0 <iPad_IP地址>${NC}"
    echo "示例: $0 192.168.1.100"
    echo ""
    echo "请确保:"
    echo "  1. iPad 已越狱并安装了 OpenSSH"
    echo "  2. iPad 和 Mac 在同一网络"
    echo "  3. 知道 iPad 的 IP 地址 (设置 -> Wi-Fi -> 点击已连接网络)"
    exit 1
fi

echo -e "${GREEN}===== iOS Terminal SSH 安装脚本 =====${NC}"
echo ""

# 检查 IPA 文件
if [ ! -f "$IPA_FILE" ]; then
    echo -e "${RED}错误: 找不到 $IPA_FILE${NC}"
    echo "请先运行构建命令生成 IPA 文件"
    exit 1
fi

# 解压 IPA
echo -e "${YELLOW}[1/5] 解压 IPA 文件...${NC}"
rm -rf temp_install
mkdir -p temp_install
unzip -q "$IPA_FILE" -d temp_install

# 检查是 rootless 还是 rootful 越狱
echo -e "${YELLOW}[2/5] 检测越狱类型...${NC}"
echo "正在连接到 $IPAD_IP ..."

# 尝试检测越狱类型
IS_ROOTLESS=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no root@"$IPAD_IP" "[ -d /var/jb ] && echo 'yes' || echo 'no'" 2>/dev/null || echo "no")

if [ "$IS_ROOTLESS" = "yes" ]; then
    echo -e "${GREEN}检测到 Rootless 越狱 (Dopamine/palera1n)${NC}"
    INSTALL_PATH="/var/jb/Applications"
else
    echo -e "${GREEN}检测到 Rootful 越狱${NC}"
    INSTALL_PATH="/Applications"
fi

# 上传应用
echo -e "${YELLOW}[3/5] 上传应用到 iPad...${NC}"
scp -r -o StrictHostKeyChecking=no temp_install/Payload/"$APP_NAME" root@"$IPAD_IP":"$INSTALL_PATH/"

# 设置权限
echo -e "${YELLOW}[4/5] 设置权限...${NC}"
ssh -o StrictHostKeyChecking=no root@"$IPAD_IP" << EOF
chown -R mobile:mobile "$INSTALL_PATH/$APP_NAME"
chmod 755 "$INSTALL_PATH/$APP_NAME/iOSTerminal"
chmod 755 "$INSTALL_PATH/$APP_NAME"
EOF

# 刷新图标缓存
echo -e "${YELLOW}[5/5] 刷新应用图标缓存...${NC}"
ssh -o StrictHostKeyChecking=no root@"$IPAD_IP" << EOF
if [ -f /var/jb/usr/bin/uicache ]; then
    /var/jb/usr/bin/uicache -p "$INSTALL_PATH/$APP_NAME"
elif [ -f /usr/bin/uicache ]; then
    /usr/bin/uicache -p "$INSTALL_PATH/$APP_NAME"
else
    echo "uicache 未找到，请手动注销重新登录"
fi
EOF

# 清理
rm -rf temp_install

echo ""
echo -e "${GREEN}===== 安装完成! =====${NC}"
echo ""
echo "现在可以在 iPad 主屏幕上找到 Terminal 应用"
echo ""
echo -e "${YELLOW}提示: 如果应用闪退，可能需要安装 AppSync Unified${NC}"
