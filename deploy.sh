#!/bin/sh
# 一键部署脚本路径：/home/v2ray-tproxy/deploy.sh
# 用法：sh deploy.sh [git_repo_url] (首次部署需提供git地址)

# 配置参数
SERVICE_NAME="v2ray-tproxy"
INSTALL_DIR="/home/v2ray-tproxy"
SERVICE_LINK="/etc/init.d/$SERVICE_NAME"

# 检查是否首次部署
if [ -n "$1" ] && [ ! -d "$INSTALL_DIR/.git" ]; then
    echo "[INFO] 首次部署，正在克隆仓库..."
    git clone "$1" "$INSTALL_DIR" || {
        echo "[ERROR] Git克隆失败！"
        exit 1
    }
fi

# 进入目录
cd "$INSTALL_DIR" || {
    echo "[ERROR] 无法进入目录 $INSTALL_DIR"
    exit 1
}

# 更新代码（如果已克隆）
if [ -d .git ]; then
    echo "[INFO] 拉取最新代码..."
    git pull || {
        echo "[WARN] Git拉取失败，继续使用现有代码"
    }
fi

# 设置文件权限
echo "[INFO] 设置文件权限..."
chmod 755 v2ray-tproxy.init
chmod 644 rules.d/*.conf
chmod 644 config.conf

# 注册服务
echo "[INFO] 注册服务..."
if [ -L "$SERVICE_LINK" ]; then
    echo "[DEBUG] 移除旧服务链接..."
    rm -f "$SERVICE_LINK"
fi
ln -sf "$INSTALL_DIR/v2ray-tproxy.init" "$SERVICE_LINK"

# 启用开机启动
echo "[INFO] 设置开机启动..."
/etc/init.d/$SERVICE_NAME enable

# 启动服务
echo "[INFO] 启动服务..."
/etc/init.d/$SERVICE_NAME restart

# 测试功能
echo "[INFO] 运行测试..."
sleep 3
echo "=== 服务状态 ==="
/etc/init.d/$SERVICE_NAME status
echo "=== 最新日志 ==="
logread | grep "$SERVICE_NAME" | tail -n 5
echo "=== 规则检查 ==="
iptables -t mangle -L PREROUTING -n --line-numbers | head -n 15
ip rule list | grep "$SERVICE_NAME"

echo "[SUCCESS] 部署完成！"