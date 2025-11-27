#!/bin/bash
# ==============================================================================
# 树莓派性能监控脚本（生产级）
# 功能：监控CPU、内存、磁盘、网络流量，适配树莓派Ubuntu 24.04+，兼容常规Linux
# 特性：
#   1. 自动检测活跃网络接口（优先无线wlan0，其次有线eth0）
#   2. 精准采集树莓派CPU/内存使用率（适配ARM架构）
#   3. 网络流量从/proc/net/dev读取（内核原生统计，无第三方依赖）
#   4. 支持后台运行、自定义监控时长/间隔、日志输出
# 使用示例：
#   基础监控：          ./perf_monitor.sh
#   指定时长/间隔：     ./perf_monitor.sh --duration 60 --interval 5
#   指定网络接口：      ./perf_monitor.sh --interface wlan0
#   后台运行+日志：     ./perf_monitor.sh --daemon --output /tmp/perf.log
#   查看帮助：          ./perf_monitor.sh --help
# ==============================================================================
set -eo pipefail

# -------------------------- 全局配置（无需修改） --------------------------
# 默认监控时长（秒）
DURATION=30
# 默认采样间隔（秒）
INTERVAL=2
# 日志输出文件（空则仅终端输出）
OUTPUT_FILE=""
# 网络接口（自动检测，可手动指定）
INTERFACE=""
# 监控磁盘分区
DISK_PARTITION="/"
# 后台运行模式标识
DAEMON_MODE=false
# 脚本启动时间戳
START_TIME=$(date +%s)
# 树莓派标识（自动检测）
IS_RASPI=false
if grep -q "raspberrypi" /proc/cpuinfo 2>/dev/null || grep -q "Raspberry Pi" /sys/firmware/devicetree/base/model 2>/dev/null; then
    IS_RASPI=true
fi

# -------------------------- 颜色定义（终端输出美化） --------------------------
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
NC='\033[0m'

# -------------------------- 日志函数（统一输出格式） --------------------------
# 信息日志（蓝色）
log_info() {
    echo -e "${BLUE}[INFO] $(date +"%Y-%m-%d %H:%M:%S") $1${NC}"
}

# 警告日志（黄色）
log_warn() {
    echo -e "${YELLOW}[WARN] $(date +"%Y-%m-%d %H:%M:%S") $1${NC}"
}

# 错误日志（红色，退出脚本）
log_error() {
    echo -e "${RED}[ERROR] $(date +"%Y-%m-%d %H:%M:%S") $1${NC}"
    exit 1
}

# -------------------------- 参数解析（处理命令行输入） --------------------------
parse_params() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --duration)
                if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
                    log_error "监控时长必须为正整数，当前输入：$2"
                fi
                DURATION="$2"
                shift 2
                ;;
            --interval)
                if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
                    log_error "采样间隔必须为正整数，当前输入：$2"
                fi
                INTERVAL="$2"
                shift 2
                ;;
            --output)
                OUTPUT_FILE="$2"
                OUTPUT_DIR=$(dirname "$OUTPUT_FILE")
                if [ ! -d "$OUTPUT_DIR" ] && ! mkdir -p "$OUTPUT_DIR"; then
                    log_error "日志目录创建失败：$OUTPUT_DIR"
                fi
                shift 2
                ;;
            --interface)
                INTERFACE="$2"
                shift 2
                ;;
            --disk)
                DISK_PARTITION="$2"
                if ! df -h "$DISK_PARTITION" &>/dev/null; then
                    log_error "磁盘分区不存在：$DISK_PARTITION"
                fi
                shift 2
                ;;
            --daemon)
                DAEMON_MODE=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "未知参数：$1（使用--help查看帮助）"
                ;;
        esac
    done
}

# -------------------------- 帮助信息（--help触发） --------------------------
show_help() {
    echo "==================================== 性能监控脚本 ===================================="
    echo "用法：$0 [可选参数]"
    echo "核心功能：监控CPU、内存、磁盘使用率，网络收发流量（适配树莓派ARM架构）"
    echo "------------------------------------------------------------------------------------------"
    echo "可选参数："
    echo "  --duration <秒>      监控总时长，默认30秒（示例：--duration 60）"
    echo "  --interval <秒>      采样间隔，默认2秒（示例：--interval 5）"
    echo "  --output <文件>      监控日志输出路径（示例：--output /tmp/perf.log）"
    echo "  --interface <接口>   指定网络接口（示例：--interface wlan0/eth0）"
    echo "  --disk <分区>        指定监控磁盘分区，默认/（示例：--disk /home）"
    echo "  --daemon             后台运行模式（日志默认输出到/tmp/perf_monitor_*.log）"
    echo "  --help/-h            显示此帮助信息"
    echo "------------------------------------------------------------------------------------------"
    echo "使用示例："
    echo "  ./perf_monitor.sh --duration 60 --interval 5 --output /tmp/perf.log"
    echo "  ./perf_monitor.sh --daemon --interface wlan0 --duration 300"
    echo "==================================== 脚本结束 ==================================="
}

# -------------------------- 后台运行处理 --------------------------
handle_daemon() {
    if $DAEMON_MODE; then
        log_info "后台运行模式启动，进程ID：$$"
        # 后台模式默认日志路径
        if [ -z "$OUTPUT_FILE" ]; then
            OUTPUT_FILE="/tmp/perf_monitor_$(date +%Y%m%d_%H%M%S).log"
            log_info "后台模式默认日志文件：$OUTPUT_FILE"
        fi
        # 后台执行脚本，重定向输出
        nohup "$0" --duration "$DURATION" --interval "$INTERVAL" \
            --output "$OUTPUT_FILE" --interface "$INTERFACE" --disk "$DISK_PARTITION" \
            >/dev/null 2>&1 &
        exit 0
    fi
}

# -------------------------- 活跃网络接口检测 --------------------------
# 功能：自动检测有数据传输的网络接口，优先选wlan0（树莓派常用无线）
detect_active_interface() {
    # 手动指定接口则直接验证
    if [ -n "$INTERFACE" ]; then
        if ! ip link show "$INTERFACE" &>/dev/null; then
            log_error "指定的网络接口不存在：$INTERFACE"
        fi
        log_info "使用手动指定接口：$INTERFACE"
        return
    fi

    # 读取所有非回环网络接口
    local interfaces=$(cat /proc/net/dev | grep -E '^ *[a-zA-Z0-9]+:' | awk -F: '{gsub(/ /,""); print $1}' | grep -E 'eth|wlan|enp|ens|bond')
    local active_if=""
    local max_diff=0

    # 等待1秒，检测字节数变化（判断活跃接口）
    sleep 1
    for iface in $interfaces; do
        if [ "$iface" = "lo" ]; then continue; fi
        # 读取接口总收发字节数
        local stats=$(grep -E "^ *$iface:" /proc/net/dev | awk '{print $2 + $10}')
        local total_bytes=${stats:-0}
        # 记录字节数最多的接口（活跃接口）
        if [ "$total_bytes" -gt "$max_diff" ]; then
            max_diff=$total_bytes
            active_if=$iface
        fi
    done

    # 兜底逻辑：树莓派优先wlan0，其次eth0
    if [ -n "$active_if" ]; then
        INTERFACE="$active_if"
        log_info "自动检测到活跃接口：$INTERFACE"
    else
        if $IS_RASPI; then
            INTERFACE="wlan0"
            if ! ip link show "$INTERFACE" &>/dev/null; then
                INTERFACE="eth0"
            fi
        else
            INTERFACE="eth0"
        fi
        log_warn "未检测到活跃接口，使用默认接口：$INTERFACE"
    fi
}

# -------------------------- 依赖检查 --------------------------
check_dependencies() {
    # 核心依赖工具列表
    local required_tools=("top" "df" "date" "sleep" "free" "ip" "bc" "awk" "grep")
    # 树莓派额外依赖vmstat（CPU/内存采集）
    if $IS_RASPI; then
        required_tools+=("vmstat")
    fi

    # 检查每个工具是否存在
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            local install_cmd=""
            if command -v apt &>/dev/null; then
                install_cmd="apt update && apt install -y $tool"
            elif command -v yum &>/dev/null; then
                install_cmd="yum install -y $tool"
            fi
            log_error "缺少核心依赖工具：$tool，请执行安装命令：$install_cmd"
        fi
    done
}

# -------------------------- CPU使用率采集（树莓派专属） --------------------------
get_raspi_cpu_usage() {
    # 方法1：vmstat采集（树莓派ARM架构更稳定）
    local idle=$(vmstat 1 2 | tail -n1 | awk '{print $15}')
    if [[ "$idle" =~ ^[0-9]+$ ]]; then
        echo $((100 - idle))
        return
    fi

    # 方法2：top采集（备用方案）
    local cpu_line=$(top -bn2 -d 0.1 | grep -E '^%Cpu|^%cpu' | tail -n1)
    local idle=$(echo "$cpu_line" | awk '{
        for(i=1;i<=NF;i++) {
            if ($i ~ /id,|id%|id$/) {
                gsub(/[^0-9]/, "", $i);
                print $i;
                exit;
            }
        }
    }')
    if [[ "$idle" =~ ^[0-9]+$ ]]; then
        echo $((100 - idle))
        return
    fi

    # 兜底值
    echo 0
}

# -------------------------- 内存使用率采集（树莓派专属） --------------------------
get_raspi_mem_usage() {
    # 方法1：free命令采集（MB级，避免字节级解析误差）
    local mem_info=$(free -m | grep -E '^Mem:')
    local total=$(echo "$mem_info" | awk '{print $2}')
    local used=$(echo "$mem_info" | awk '{print $3}')
    
    if [[ "$total" =~ ^[0-9]+$ && "$used" =~ ^[0-9]+$ && "$total" -gt 0 ]]; then
        echo "scale=1; $used / $total * 100" | bc
        return
    fi

    # 方法2：vmstat采集（备用方案）
    local mem_total=$(vmstat -s | grep 'total memory' | awk '{print $1}')
    local mem_used=$(vmstat -s | grep 'used memory' | awk '{print $1}')
    if [[ "$mem_total" =~ ^[0-9]+$ && "$mem_used" =~ ^[0-9]+$ && "$mem_total" -gt 0 ]]; then
        echo "scale=1; $mem_used / $mem_total * 100" | bc
        return
    fi

    # 兜底值
    echo "0.0"
}

# -------------------------- CPU使用率采集（常规Linux） --------------------------
get_linux_cpu_usage() {
    local cpu_line=$(top -bn1 | grep -E '^%Cpu|^%cpu' | head -n1)
    local idle=$(echo "$cpu_line" | awk '{
        for(i=1;i<=NF;i++) {
            if ($i ~ /id,|id%|id$|idle/) {
                gsub(/[^0-9.]/, "", $i);
                print $i;
                exit;
            }
        }
    }')
    
    if [[ "$idle" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "$(echo "100 - $idle" | bc | cut -d. -f1)"
        return
    fi
    echo 0
}

# -------------------------- 内存使用率采集（常规Linux） --------------------------
get_linux_mem_usage() {
    local mem_total=$(free -b | grep -E '^Mem:' | awk '{print $2}' | grep -E '^[0-9]+$')
    local mem_used=$(free -b | grep -E '^Mem:' | awk '{print $3}' | grep -E '^[0-9]+$')
    
    if [[ -n "$mem_total" && -n "$mem_used" && "$mem_total" -gt 0 ]]; then
        echo "scale=1; $mem_used / $mem_total * 100" | bc
        return
    fi
    echo "0.0"
}

# -------------------------- 网络字节数读取（内核原生/proc/net/dev） --------------------------
get_net_bytes() {
    local iface="$1"
    # /proc/net/dev格式：接口名: 接收字节 接收包数 ... 发送字节 发送包数 ...
    local stats=$(grep -E "^ *$iface:" /proc/net/dev | awk '{print $2, $10}')
    local rx_bytes=$(echo "$stats" | awk '{print $1}')
    local tx_bytes=$(echo "$stats" | awk '{print $2}')
    
    # 兜底值（避免空值）
    rx_bytes=${rx_bytes:-0}
    tx_bytes=${tx_bytes:-0}
    
    echo "$rx_bytes $tx_bytes"
}

# -------------------------- 网络流量计算（KB/s，保留1位小数） --------------------------
calculate_net_speed() {
    local iface="$1"
    local interval="$2"
    
    # 第一次读取字节数
    read rx1 tx1 <<< $(get_net_bytes "$iface")
    # 等待采样间隔
    sleep "$interval"
    # 第二次读取字节数
    read rx2 tx2 <<< $(get_net_bytes "$iface")
    
    # 计算字节数差值（避免负数，接口重置时）
    local rx_diff=$((rx2 - rx1))
    local tx_diff=$((tx2 - tx1))
    if [ "$rx_diff" -lt 0 ]; then rx_diff=0; fi
    if [ "$tx_diff" -lt 0 ]; then tx_diff=0; fi
    
    # 转换为KB/s，保留1位小数
    local rx_speed=$(echo "scale=1; $rx_diff / 1024 / $interval" | bc)
    local tx_speed=$(echo "scale=1; $tx_diff / 1024 / $interval" | bc)
    
    # 格式兜底（确保数值合法）
    if ! [[ "$rx_speed" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then rx_speed="0.0"; fi
    if ! [[ "$tx_speed" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then tx_speed="0.0"; fi
    
    echo "$rx_speed $tx_speed"
}

# -------------------------- 监控核心逻辑 --------------------------
monitor() {
    local current_time=$(date +"%Y-%m-%d %H:%M:%S")
    local cpu_usage=0
    local mem_usage="0.0"
    local disk_usage=0
    local net_rx="0.0"
    local net_tx="0.0"
    local interval=$1

    # 1. 采集CPU使用率（区分树莓派/常规Linux）
    if $IS_RASPI; then
        cpu_usage=$(get_raspi_cpu_usage)
    else
        cpu_usage=$(get_linux_cpu_usage)
    fi
    if ! [[ "$cpu_usage" =~ ^[0-9]+$ ]]; then
        cpu_usage=0
    fi

    # 2. 采集内存使用率（区分树莓派/常规Linux）
    if $IS_RASPI; then
        mem_usage=$(get_raspi_mem_usage)
    else
        mem_usage=$(get_linux_mem_usage)
    fi
    if ! [[ "$mem_usage" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        mem_usage="0.0"
    fi

    # 3. 采集磁盘使用率
    local df_output=$(df -h "$DISK_PARTITION" 2>/dev/null | awk 'NR==2 {print $5}')
    if [[ "$df_output" =~ ^[0-9]+%?$ ]]; then
        disk_usage=$(echo "$df_output" | tr -d '%')
    fi
    if ! [[ "$disk_usage" =~ ^[0-9]+$ ]]; then
        disk_usage=0
    fi

    # 4. 采集网络流量
    if [ -n "$INTERFACE" ]; then
        read net_rx net_tx <<< $(calculate_net_speed "$INTERFACE" "$interval")
    fi

    # 格式化输出（对齐美化）
    local output
    output=$(printf "[%s] CPU: %3s%% | 内存: %5s%% | 磁盘(%s):  %3s%% | 网络(%s)接收: %6.1fKB/s | 发送: %6.1fKB/s" \
        "$current_time" \
        "$cpu_usage" \
        "$mem_usage" \
        "$DISK_PARTITION" \
        "$disk_usage" \
        "${INTERFACE:-禁用}" \
        "$net_rx" \
        "$net_tx")

    # 终端输出（绿色）
    echo -e "${GREEN}$output${NC}"
    # 日志文件输出（无颜色）
    if [ -n "$OUTPUT_FILE" ]; then
        echo "$(printf "[%s] CPU: %3s%% | 内存: %5s%% | 磁盘(%s):  %3s%% | 网络(%s)接收: %6.1fKB/s | 发送: %6.1fKB/s" \
            "$current_time" "$cpu_usage" "$mem_usage" "$DISK_PARTITION" "$disk_usage" "${INTERFACE:-禁用}" "$net_rx" "$net_tx")" >> "$OUTPUT_FILE"
    fi
}

# -------------------------- 主流程执行 --------------------------
main() {
    # 1. 解析命令行参数
    parse_params "$@"
    
    # 2. 处理后台运行
    handle_daemon
    
    # 3. 检查核心依赖
    check_dependencies
    
    # 4. 检测活跃网络接口
    detect_active_interface
    
    # 5. 输出监控配置信息（简洁版）
    log_info "==================================== 性能监控启动 ==================================="
    log_info "系统信息：$(uname -s) $(uname -r) | $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
    log_info "设备类型：$(if $IS_RASPI; then echo "树莓派（ARM架构专属采集）"; else echo "常规Linux服务器"; fi)"
    log_info "监控配置：时长${DURATION}秒 | 间隔${INTERVAL}秒 | 磁盘分区${DISK_PARTITION} | 网络接口${INTERFACE}"
    log_info "------------------------------------------------------------------------------------------"

    # 6. 核心监控循环
    end_time=$((START_TIME + DURATION))
    while [ $(date +%s) -lt $end_time ]; do
        # 执行采样（容错：单轮采样失败不终止）
        monitor "$INTERVAL" || log_warn "本轮采样出现异常，将继续下一次采样"
        
        # 精准休眠（避免重复sleep）
        current_time=$(date +%s)
        next_time=$((current_time + INTERVAL))
        if [ $next_time -lt $end_time ]; then
            sleep $((next_time - current_time))
        fi
    done

    # 7. 监控结束提示
    log_info "------------------------------------------------------------------------------------------"
    log_info "性能监控结束 | 日志文件：${OUTPUT_FILE:-未指定}"
    log_info "==================================== 监控完成 ==================================="
}

# 启动主流程
main "$@"
