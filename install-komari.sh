#!/bin/bash

# Color definitions for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Logging functions (write to stderr so command-substitution is not polluted)
log_info() {
    >&2 echo -e "$1"
}

log_success() {
    >&2 echo -e "${GREEN}$1${NC}"
}

log_error() {
    >&2 echo -e "${RED}$1${NC}"
}

log_step() {
    >&2 echo -e "${YELLOW}$1${NC}"
}


# Global variables
INSTALL_DIR="/opt/komari"
DATA_DIR="/opt/komari"
SERVICE_NAME="komari"
BINARY_PATH="$INSTALL_DIR/komari"
DEFAULT_PORT="25774"
LISTEN_PORT=""
AUTO_MODE=0
GITHUB_API="https://api.github.com/repos/komari-monitor/komari/releases/latest"
VERSION_FILE="$INSTALL_DIR/VERSION"

# Resolve command paths (use full paths for cron). Re-resolve later if install_dependencies installs curl.
CURL_BIN=$(command -v curl || true)
SYSTEMCTL_BIN=$(command -v systemctl || true)
JOURNALCTL_BIN=$(command -v journalctl || true)
AWK_BIN=$(command -v awk || true)
SED_BIN=$(command -v sed || true)
GREP_BIN=$(command -v grep || true)

# Show banner
show_banner() {
    clear
    echo "=============================================================="
    echo "            Komari Monitoring System Installer"
    echo "       https://github.com/komari-monitor/komari"
    echo "=============================================================="
    echo
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 权限运行此脚本"
        exit 1
    fi
}

# Check for systemd
check_systemd() {
    if [ -z "$SYSTEMCTL_BIN" ]; then
        return 1
    else
        return 0
    fi
}

# Detect system architecture
detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64)
            echo "amd64"
            ;;
        aarch64)
            echo "arm64"
            ;;
        i386|i686)
            echo "386"
            ;;
        riscv64)
            echo "riscv64"
            ;;
        *)
            log_error "不支持的架构: $arch"
            exit 1
            ;;
    esac
}

# Check if Komari is already installed
is_installed() {
    if [ -f "$BINARY_PATH" ]; then
        return 0
    else
        return 1
    fi
}

# Read local installed version by invoking the installed binary (preferred)
get_local_version() {
    # Prefer asking the installed binary for its version if it is executable
    if [ -x "$BINARY_PATH" ]; then
        # run the binary and capture the first info-ish line (some builds print to stderr)
        local ver_line
        ver_line=$("$BINARY_PATH" -h 2>&1 | head -n 1) || true

        # Example input:
        # 2026/02/01 14:18:54 [INFO] Komari Monitor 1.1.4 (hash: ...)
        # Extract semantic version like 1.1.4
        local ver
        ver=$(echo "$ver_line" | grep -oE 'Komari Monitor [0-9]+(\.[0-9]+)*' | awk '{print $3}' || true)

        if [ -n "$ver" ]; then
            echo "$ver"
            return 0
        fi
    fi

    # Fallback to VERSION file if binary not present or parsing failed
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE"
        return 0
    fi

    # Nothing found
    echo ""
    return 0
}

# Save local version (tag) normalized (strip leading v)
set_local_version() {
    local tag="$1"
    # normalize tag (remove leading v)
    tag=${tag#v}
    mkdir -p "$INSTALL_DIR"
    echo "$tag" > "$VERSION_FILE"
}

# Query GitHub Releases API for latest tag and asset URL for our arch
# Outputs: tag on stdout (normalized without leading 'v'), sets global LATEST_DOWNLOAD_URL
LATEST_DOWNLOAD_URL=""
get_latest_release_info() {
    local arch tag json code candidate_url url api_message

    arch=$(detect_arch)

    # ensure curl
    CURL_BIN=$(command -v curl || true)
    if [ -z "$CURL_BIN" ]; then
        log_error "curl 未安装，无法检查更新"
        return 1
    fi

    # optional token support
    local curl_auth_args=()
    if [ -n "$GITHUB_TOKEN" ]; then
        curl_auth_args+=(-H "Authorization: token $GITHUB_TOKEN")
    fi

    log_step "从 GitHub 查询最新发布信息..."
    json=$($CURL_BIN -s "${curl_auth_args[@]}" "$GITHUB_API")
    if [ -z "$json" ]; then
        log_error "无法从 GitHub 获取 release 信息 (空响应)"
        return 1
    fi

    # If API returned an error message (rate limit or not found), capture it but continue to try deterministic URL later
    api_message=$(echo "$json" | awk -F'"' '/"message"\s*:/ {print $4; exit}')
    if [ -n "$api_message" ]; then
        log_info "GitHub API message: $api_message"
        # don't fail immediately — try deterministic URL fallback
    fi

    # Extract tag_name using awk (portable)
    tag=$(echo "$json" | awk -F'"' '/"tag_name"\s*:/ {print $4; exit}' || true)
    tag=${tag#v}  # normalize

    # If we have a tag, build deterministic URL and verify it
    if [ -n "$tag" ]; then
        candidate_url="https://github.com/komari-monitor/komari/releases/download/${tag}/komari-linux-${arch}"
        # check HTTP status (follow redirects)
        code=$($CURL_BIN -s -o /dev/null -w "%{http_code}" -L "$candidate_url" || echo "")
        if [ "$code" = "200" ]; then
            LATEST_DOWNLOAD_URL="$candidate_url"
            echo "$tag"
            return 0
        else
            log_info "构造的 URL 返回 HTTP ${code:-NA}, 将尝试从 release JSON 查找资产"
        fi
    fi

    # Parse assets (name -> browser_download_url) using awk to pair name and url
    url=$(echo "$json" | awk -F'"' -v arch="$arch" '
        /"name"\s*:/ { name=$4; next }
        /"browser_download_url"\s*:/ {
            bdurl=$4
            if (name == "komari-linux-"arch) { print bdurl; exit }
            if (name ~ /^komari-linux/ && fallback == "") fallback = bdurl
        }
        END { if (fallback != "") print fallback }
    ' | head -n1)

    # Grep fallback (very tolerant)
    if [ -z "$url" ]; then
        url=$(echo "$json" | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*komari-linux[^"]*' | sed -E 's/.*"([^"]+)".*/\1/' | head -n1 || true)
    fi

    if [ -n "$url" ]; then
        LATEST_DOWNLOAD_URL="$url"
        # echo tag if we have it (may be empty)
        echo "$tag"
        return 0
    fi

    # Final fallback: generic releases/latest/download redirect (should work)
    log_info "未在 release assets 中找到匹配的文件，使用 releases/latest/download 回退 URL"
    LATEST_DOWNLOAD_URL="https://github.com/komari-monitor/komari/releases/latest/download/komari-linux-${arch}"
    echo "$tag"
    return 0
}

# Install dependencies
install_dependencies() {
    log_step "检查并安装依赖..."

    if ! command -v curl >/dev/null 2>&1; then
        if command -v apt >/dev/null 2>&1; then
            log_info "使用 apt 安装依赖..."
            apt update
            apt install -y curl
        elif command -v yum >/dev/null 2>&1; then
            log_info "使用 yum 安装依赖..."
            yum install -y curl
        elif command -v apk >/dev/null 2>&1; then
            log_info "使用 apk 安装依赖..."
            apk add curl
        else
            log_error "未找到支持的包管理器 (apt/yum/apk)"
            exit 1
        fi
        CURL_BIN=$(command -v curl || true)
    fi
}

# Binary installation (interactive and non-interactive)
install_binary() {
    log_step "开始二进制安装..."

    if is_installed; then
        log_info "Komari 已安装。要升级，请使用升级选项。"
        return
    fi

    # 监听端口输入，校验范围 1-65535
    if [ "$AUTO_MODE" -eq 1 ]; then
        LISTEN_PORT="$DEFAULT_PORT"
    else
        while true; do
            read -p "请输入监听端口 [默认: $DEFAULT_PORT]: " input_port
            if [[ -z "$input_port" ]]; then
                LISTEN_PORT="$DEFAULT_PORT"
                break
            elif [[ "$input_port" =~ ^[0-9]+$ ]] && (( input_port >= 1 && input_port <= 65535 )); then
                LISTEN_PORT="$input_port"
                break
            else
                log_error "端口号无效，请输入 1-65535 之间的数字。"
            fi
        done
    fi

    install_dependencies

    local arch
    arch=$(detect_arch)
    log_info "检测到架构: $arch"

    log_step "创建安装目录: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"

    log_step "创建数据目录: $DATA_DIR"
    mkdir -p "$DATA_DIR"

    # Use GitHub API to find the correct download URL and tag
    local latest_tag
    if ! latest_tag=$(get_latest_release_info); then
        log_error "获取最新发布信息失败，使用默认下载 URL 作为回退。"
        local file_name="komari-linux-${arch}"
        LATEST_DOWNLOAD_URL="https://github.com/komari-monitor/komari/releases/latest/download/${file_name}"
        latest_tag=""
    fi

    # ensure URL is non-empty
    if [ -z "$LATEST_DOWNLOAD_URL" ]; then
        log_error "下载 URL 为空，取消安装"
        return 1
    fi

    log_step "下载 Komari 二进制文件..."
    log_info "URL: $LATEST_DOWNLOAD_URL"

    if ! $CURL_BIN -L -o "$BINARY_PATH" "$LATEST_DOWNLOAD_URL"; then
        log_error "下载失败"
        return 1
    fi

    chmod +x "$BINARY_PATH"
    log_success "Komari 二进制文件安装完成: $BINARY_PATH"

    # record installed version if we have the tag
    if [ -n "$latest_tag" ]; then
        set_local_version "$latest_tag"
    fi

    if ! check_systemd; then
        log_step "警告：未检测到 systemd，跳过服务创建。"
        log_step "您可以从命令行手动运行 Komari："
        log_step "    $BINARY_PATH server -l 0.0.0.0:$LISTEN_PORT"
        echo
        log_success "安装完成！"
        return
    fi

    create_systemd_service "$LISTEN_PORT"

    $SYSTEMCTL_BIN daemon-reload
    $SYSTEMCTL_BIN enable ${SERVICE_NAME}.service
    $SYSTEMCTL_BIN start ${SERVICE_NAME}.service

    if $SYSTEMCTL_BIN is-active --quiet ${SERVICE_NAME}.service; then
        log_success "Komari 服务启动成功"
        
        log_step "正在获取初始密码..."
        sleep 5 
        local password=""
        if [ -n "$JOURNALCTL_BIN" ]; then
            password=$($JOURNALCTL_BIN -u ${SERVICE_NAME} --since "1 minute ago" 2>/dev/null | grep "admin account created." | tail -n 1 | sed -e 's/.*admin account created.//')
        fi
        if [ -z "$password" ]; then
            log_error "未能获取初始密码，请检查日志"
        fi
        show_access_info "$password" "$LISTEN_PORT"
    else
        log_error "Komari 服务启动失败"
        log_info "查看日志: $JOURNALCTL_BIN -u ${SERVICE_NAME} -f"
        return 1
    fi
}

# Create systemd service file
create_systemd_service() {
    local port="$1"
    log_step "创建 systemd 服务..."

    local service_file="/etc/systemd/system/${SERVICE_NAME}.service"
    cat > "$service_file" << EOF
[Unit]
Description=Komari Monitor Service
After=network.target

[Service]
Type=simple
ExecStart=${BINARY_PATH} server -l 0.0.0.0:${port}
WorkingDirectory=${DATA_DIR}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    log_success "systemd 服务文件创建完成"
}

# Show access information
show_access_info() {
    local password=$1
    local port=${2:-$DEFAULT_PORT}
    echo
    log_success "安装完成！"
    echo
    log_info "访问信息："
    # hostname -I may be empty on minimal systems; guard it
    local ipaddr
    if command -v hostname >/dev/null 2>&1 && hostname -I >/dev/null 2>&1; then
        ipaddr=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$ipaddr" ]; then
        ipaddr="127.0.0.1"
    fi
    log_info "  URL: http://${ipaddr}:${port}"
    if [ -n "$password" ]; then
        log_info "初始登录信息（仅显示一次）: $password"
    fi
    echo
    log_info "服务管理命令："
    log_info "  状态:  $SYSTEMCTL_BIN status $SERVICE_NAME"
    log_info "  启动:   $SYSTEMCTL_BIN start $SERVICE_NAME"
    log_info "  停止:    $SYSTEMCTL_BIN stop $SERVICE_NAME"
    log_info "  重启: $SYSTEMCTL_BIN restart $SERVICE_NAME"
    log_info "  日志:    $JOURNALCTL_BIN -u $SERVICE_NAME -f"
}

# Upgrade function (interactive and non-interactive)
upgrade_komari() {
    log_step "升级 Komari..."

    if ! is_installed; then
        log_error "Komari 未安装。请先安装它。"
        return 1
    fi

    if ! check_systemd; then
        log_error "未检测到 systemd。无法管理服务。"
        return 1
    fi

    # --- NEW: check remote version before stopping the service ---
    log_step "检查远程版本..."
    local latest_tag
    if ! latest_tag=$(get_latest_release_info); then
        log_error "无法获取最新发布信息，取消升级"
        return 1
    fi
    latest_tag=${latest_tag#v}

    local local_tag
    local_tag=$(get_local_version)
    local_tag=${local_tag#v}

    if [ -n "$local_tag" ] && [ "$local_tag" = "$latest_tag" ]; then
        log_info "已是最新版本：$local_tag"
        return 0
    fi
    # --- end new check ---

    # ensure we have a download URL
    if [ -z "$LATEST_DOWNLOAD_URL" ]; then
        log_error "下载 URL 为空，取消升级"
        return 1
    fi

    log_step "停止 Komari 服务..."
    $SYSTEMCTL_BIN stop ${SERVICE_NAME}.service

    log_step "备份当前二进制文件..."
    cp "$BINARY_PATH" "${BINARY_PATH}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true

    log_step "下载最新版本..."
    if ! $CURL_BIN -L -o "$BINARY_PATH" "$LATEST_DOWNLOAD_URL"; then
        log_error "下载失败，正在从备份恢复"
        latest_backup=$(ls -1t "${BINARY_PATH}.backup."* 2>/dev/null | head -n1)
        if [ -n "$latest_backup" ]; then
            mv "$latest_backup" "$BINARY_PATH" 2>/dev/null || log_error "从备份恢复失败: $latest_backup"
            log_info "已从备份恢复: $latest_backup"
        else
            log_error "未找到备份文件，无法恢复二进制"
        fi
        $SYSTEMCTL_BIN start ${SERVICE_NAME}.service
        return 1
    fi

    chmod +x "$BINARY_PATH"
    set_local_version "$latest_tag"

    log_step "重启 Komari 服务..."
    $SYSTEMCTL_BIN start ${SERVICE_NAME}.service

    if $SYSTEMCTL_BIN is-active --quiet ${SERVICE_NAME}.service; then
        log_success "Komari 升级成功"
    else
        log_error "服务在升级后未能启动"
    fi
}

# Non-interactive: check remote release and install/upgrade if needed.
auto_upgrade_check() {
    log_step "自动检查 Komari 更新（非交互模式）..."

    install_dependencies

    local latest_tag
    if ! latest_tag=$(get_latest_release_info); then
        log_error "无法获取最新发布信息，退出。"
        return 1
    fi
    # normalize tag
    latest_tag=${latest_tag#v}

    local local_tag
    local_tag=$(get_local_version)
    # normalize local_tag (just in case)
    local_tag=${local_tag#v}

    if ! is_installed; then
        log_info "Komari 未安装，开始安装最新版本: $latest_tag"
        AUTO_MODE=1
        LISTEN_PORT="$DEFAULT_PORT"
        install_binary
        return $?
    fi

    if [ -n "$local_tag" ] && [ "$local_tag" = "$latest_tag" ]; then
        log_info "已是最新版本：$local_tag"
        return 0
    fi

    log_info "检测到新版本：$latest_tag (本地: ${local_tag:-未安装})，开始升级..."
    upgrade_komari
}

# Uninstall function
uninstall_komari() {
    log_step "卸载 Komari..."

    if ! is_installed; then
        log_info "Komari 未安装"
        return 0
    fi

    if [ "$AUTO_MODE" -eq 1 ]; then
        log_info "非交互模式：自动确认卸载"
        confirm="Y"
    else
        read -p "这将删除 Komari。您确定吗？(Y/n): " confirm
    fi

    if [[ $confirm =~ ^[Nn]$ ]]; then
        log_info "卸载已取消"
        return 0
    fi

    if check_systemd; then
        log_step "停止并禁用服务..."
        $SYSTEMCTL_BIN stop ${SERVICE_NAME}.service >/dev/null 2>&1
        $SYSTEMCTL_BIN disable ${SERVICE_NAME}.service >/dev/null 2>&1
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        $SYSTEMCTL_BIN daemon-reload
        log_success "systemd 服务已删除"
    fi

    log_step "删除二进制文件..."
    rm -f "$BINARY_PATH"
    # 尝试在目录为空时删除该目录
    rmdir "$INSTALL_DIR" 2>/dev/null || log_info "数据目录 $INSTALL_DIR 不为空，未删除"
    log_success "Komari 二进制文件已删除"

    log_success "Komari 卸载完成"
    log_info "数据文件保留在 $DATA_DIR"
}

# Show service status
show_status() {
    if ! is_installed; then
        log_error "Komari 未安装"
        return
    fi
    if ! check_systemd; then
        log_error "未检测到 systemd。无法获取服务状态。"
        return
    fi
    log_step "Komari 服务状态:"
    $SYSTEMCTL_BIN status ${SERVICE_NAME}.service --no-pager -l
}

# Show service logs
show_logs() {
    if ! is_installed; then
        log_error "Komari 未安装"
        return
    fi
    if ! check_systemd; then
        log_error "未检测到 systemd。无法获取服务日志。"
        return
    fi
    log_step "查看 Komari 服务日志..."
    $JOURNALCTL_BIN -u ${SERVICE_NAME} -f --no-pager
}

# Restart service
restart_service() {
    if ! is_installed; then
        log_error "Komari 未安装"
        return
    fi
    if ! check_systemd; then
        log_error "未检测到 systemd。无法重启服务。"
        return
    fi
    log_step "重启 Komari 服务..."
    $SYSTEMCTL_BIN restart ${SERVICE_NAME}.service
    if $SYSTEMCTL_BIN is-active --quiet ${SERVICE_NAME}.service; then
        log_success "服务重启成功"
    else
        log_error "服务重启失败"
    fi
}

# Stop service
stop_service() {
    if ! is_installed; then
        log_error "Komari 未安装"
        return
    fi
    if ! check_systemd; then
        log_error "未检测到 systemd。无法停止服务。"
        return
    fi
    log_step "停止 Komari 服务..."
    $SYSTEMCTL_BIN stop ${SERVICE_NAME}.service
    log_success "服务已停止"
}


# Main menu
main_menu() {
    show_banner
    echo "请选择操作："
    echo "  1) 安装 Komari"
    echo "  2) 升级 Komari"
    echo "  3) 卸载 Komari"
    echo "  4) 查看状态"
    echo "  5) 查看日志"
    echo "  6) 重启服务"
    echo "  7) 停止服务"
    echo "  8) 退出"
    echo

    read -p "输入选项 [1-8]: " choice

    case $choice in
        1) install_binary ;;
        2) upgrade_komari ;;
        3) uninstall_komari ;;
        4) show_status ;;
        5) show_logs ;;
        6) restart_service ;;
        7) stop_service ;;
        8) exit 0 ;;
        *) log_error "无效选项" ;;
    esac
}

# CLI argument parsing for non-interactive mode
if [ "$1" = "--auto-upgrade" ] || [ "$1" = "--cron" ]; then
    AUTO_MODE=1
    check_root
    auto_upgrade_check
    exit $?
fi

if [ "$1" = "--install-noninteractive" ]; then
    AUTO_MODE=1
    check_root
    install_binary
    exit $?
fi

# Default interactive behavior
check_root
main_menu
