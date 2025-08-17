#!/bin/bash
# 纯净部署脚本路径：/home/v2ray-tproxy/deploy.sh
# 用法：./deploy.sh

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置参数
SERVICE_NAME="v2ray-tproxy"
INSTALL_DIR="/home/v2ray-tproxy"
SERVICE_LINK="/etc/init.d/$SERVICE_NAME"
CONFIG_FILE="$INSTALL_DIR/config.conf"
LOG_IDENTIFIER="v2ray-tproxy"

# 预检查函数
precheck() {
    echo -e "${BLUE}[PRE-CHECK] 运行环境检查...${NC}"
    
    # 检查root权限
    [ "$(id -u)" -eq 0 ] || {
        echo -e "${RED}错误：需要root权限执行此脚本${NC}"
        exit 1
    }

    # 检查必要命令
    for cmd in iptables ip ss; do
        if ! command -v "$cmd" >/dev/null; then
            echo -e "${RED}错误：缺少必要命令 '$cmd'${NC}"
            exit 1
        fi
    done

    # 检查安装目录是否存在
    [ -d "$INSTALL_DIR" ] || {
        echo -e "${RED}错误：安装目录 $INSTALL_DIR 不存在${NC}"
        exit 1
    }
    echo -e "${GREEN}[✓] 环境检查通过${NC}"
}

# 部署函数
deploy() {
    # 进入目录
    cd "$INSTALL_DIR" || {
        echo -e "${RED}[ERROR] 无法进入目录 $INSTALL_DIR${NC}"
        exit 1
    }

    # 设置文件权限
    echo -e "${BLUE}[INFO] 设置文件权限...${NC}"
    chmod 755 v2ray-tproxy.init 2>/dev/null || {
        echo -e "${YELLOW}[WARN] v2ray-tproxy.init 文件不存在${NC}"
    }
    [ -d rules.d ] && chmod 644 rules.d/*.conf
    [ -f config.conf ] && chmod 644 config.conf || {
        echo -e "${YELLOW}[WARN] config.conf 文件不存在${NC}"
    }
}

# 服务管理函数
service_control() {
    echo -e "${BLUE}[INFO] 注册服务...${NC}"
    # 移除旧链接
    [ -L "$SERVICE_LINK" ] && {
        echo -e "${YELLOW}[DEBUG] 移除旧服务链接...${NC}"
        rm -f "$SERVICE_LINK"
    }
    
    # 创建新链接
    ln -sf "$INSTALL_DIR/v2ray-tproxy.init" "$SERVICE_LINK" || {
        echo -e "${RED}[ERROR] 服务链接创建失败${NC}"
        exit 1
    }

    # 启用服务
    echo -e "${BLUE}[INFO] 设置开机启动...${NC}"
    /etc/init.d/$SERVICE_NAME enable || {
        echo -e "${YELLOW}[WARN] 开机启动设置失败${NC}"
    }

    # 启动服务
    echo -e "${BLUE}[INFO] 启动服务...${NC}"
    /etc/init.d/$SERVICE_NAME restart
}

# 验证函数
verify() {
    echo -e "${BLUE}[INFO] 运行验证测试...${NC}"
    sleep 3

    # 加载配置变量
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" || {
        echo -e "${RED}[ERROR] 无法加载配置文件${NC}"
        exit 1
    }

    # 服务状态检查
    echo -e "${YELLOW}=== 服务状态 ===${NC}"
    /etc/init.d/$SERVICE_NAME status

    # 日志检查
    echo -e "${YELLOW}=== 最新日志 (最后5条) ===${NC}"
    logread | grep "$LOG_IDENTIFIER" | tail -n 5

    # 深度检查
    echo -e "${YELLOW}=== 深度检查 ===${NC}"
    
    echo -e "${BLUE}1. iptables规则检查:${NC}"
    iptables -t mangle -L -v -n | grep -A 10 "V2RAY"
    
    echo -e "${BLUE}2. TPROXY检查:${NC}"
    iptables -t mangle -L PREROUTING -n | grep -A 5 "TPROXY"
    
    echo -e "${BLUE}3. 路由标记检查:${NC}"
    ip rule show | grep -A 3 "fwmark"
    
    echo -e "${BLUE}4. 路由表检查:${NC}"
    [ -n "$ROUTE_TABLE" ] && ip route show table "${ROUTE_TABLE:-100}"
    
    echo -e "${BLUE}5. 端口监听检查:${NC}"
    [ -n "$TPROXY_PORT" ] && ss -ulnp | grep -w "${TPROXY_PORT:-12345}"
}

# 主流程
main() {
    precheck
    deploy
    service_control
    verify
    
    echo -e "${GREEN}[SUCCESS] 部署成功完成！${NC}"
    echo -e "建议手动测试访问：curl --connect-timeout 5 -v https://www.google.com"
}

main "$@"