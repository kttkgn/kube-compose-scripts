#!/bin/bash
set -eo pipefail

# ==============================================================================
# MacOS专用性能监控脚本（稳定版）
# 功能：实时监控CPU/内存/磁盘/网络资源使用率，支持自定义监控时长、采样间隔等
# 适用系统：MacOS (Darwin)
# 使用示例：
#   基础使用：./perf_monitor_mac.sh
#   自定义时长/间隔：./perf_monitor_mac.sh --duration 60 --interval 3
#   指定输出日志：./perf_monitor_mac.sh --output /tmp/perf.log
#   指定监控分区/接口：./perf_monitor_mac.sh --disk /System/Volumes/Data --interface en1
# ==============================================================================

# -------------------------- 全局参数初始化 --------------------------
# 默认监控时长（秒）
DURATION=30
# 默认采样间隔（秒）
INTERVAL=2
# 日志输出文件路径（空则仅控制台输出）
OUTPUT_FILE=""
# 默认网络监控接口（MacOS优先en0）
INTERFACE="en0"
# 默认磁盘监控分区
DISK_PARTITION="/"
# 监控启动时间戳（用于计算运行时长）
START_TIME=$(date +%s)

# -------------------------- 终端颜色定义 --------------------------
# 红色（错误）
RED='\033[31m'
# 绿色（正常输出）
GREEN='\033[32m'
# 黄色（警告）
YELLOW='\033[33m'
# 蓝色（信息）
BLUE='\033[34m'
# 重置颜色
NC='\033[0m'

# -------------------------- 日志输出函数 --------------------------
# 功能：输出信息级日志（纯文本，避免颜色干扰文件日志）
# 参数：$1 - 日志内容
log_info() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] $1"
}

# 功能：输出警告级日志
# 参数：$1 - 日志内容
log_warn() {
    echo -e "${YELLOW}[$(date +"%Y-%m-%d %H:%M:%S")] [WARN] $1${NC}"
}

# 功能：输出错误级日志并退出
# 参数：$1 - 日志内容
log_error() {
    echo -e "${RED}[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] $1${NC}"
    exit 1
}

# -------------------------- 命令行参数解析 --------------------------
# 功能：解析用户传入的命令行参数，覆盖默认配置
while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration)
            # 校验时长为正整数
            if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
                log_error "监控时长必须为正整数，当前输入：$2"
            fi
            DURATION="$2"
            shift 2
            ;;
        --interval)
            # 校验间隔为正整数
            if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
                log_error "采样间隔必须为正整数，当前输入：$2"
            fi
            INTERVAL="$2"
            shift 2
            ;;
        --output)
            # 设置日志输出文件，自动创建上级目录
            OUTPUT_FILE="$2"
            OUTPUT_DIR=$(dirname "$OUTPUT_FILE")
            mkdir -p "$OUTPUT_DIR" || log_error "日志目录创建失败：$OUTPUT_DIR"
            log_info "监控日志将输出至：$OUTPUT_FILE"
            shift 2
            ;;
        --interface)
            # 指定网络监控接口
            INTERFACE="$2"
            # 校验接口是否存在
            if ! netstat -ibn | grep -q "^$INTERFACE"; then
                log_warn "指定的网络接口[$INTERFACE]不存在，将使用默认接口en0"
                INTERFACE="en0"
            fi
            shift 2
            ;;
        --disk)
            # 指定磁盘监控分区
            DISK_PARTITION="$2"
            # 校验分区是否挂载
            if ! df -h "$DISK_PARTITION" &>/dev/null; then
                log_error "磁盘分区[$DISK_PARTITION]未挂载或不存在"
            fi
            shift 2
            ;;
        --help)
            # 输出帮助信息
            echo -e "${BLUE}===== MacOS性能监控脚本使用帮助 =====${NC}"
            echo "用法：$0 [可选参数]"
            echo "可选参数："
            echo "  --duration <秒>      监控总时长（默认：30秒）"
            echo "  --interval <秒>      采样间隔（默认：2秒）"
            echo "  --output <路径>      监控日志输出文件（示例：/tmp/perf.log）"
            echo "  --interface <接口>   网络监控接口（默认：en0）"
            echo "  --disk <分区>        磁盘监控分区（默认：/）"
            echo "  --help               显示此帮助信息"
            echo -e "${BLUE}=====================================${NC}"
            exit 0
            ;;
        *)
            # 未知参数报错并退出
            log_error "未知参数：$1，使用--help查看帮助信息"
            ;;
    esac
done

# -------------------------- 网络流量基线初始化 --------------------------
# 功能：获取指定网络接口的初始收发字节数（用于计算流量差值）
# 参数：无（使用全局变量INTERFACE）
# 返回：标准输出 "接收字节 发送字节"
get_net_stats() {
    netstat -ibn | awk -v iface="$INTERFACE" '
        # 仅匹配指定接口+数字索引行（过滤汇总行/空行）
        $1 == iface && $2 ~ /^[0-9]+$/ {
            rx = $7;  # 接收字节数
            tx = $10; # 发送字节数
            print rx + 0, tx + 0;  # 转为数字，空值默认0
            exit;     # 仅取第一行有效数据，避免多输出
        }
    '
}

# 初始化网络基线（兜底空值为0）
net_base=$(get_net_stats)
NET_RX_BASE=${net_base%% *}  # 初始接收字节
NET_TX_BASE=${net_base##* }  # 初始发送字节
NET_RX_BASE=${NET_RX_BASE:-0}
NET_TX_BASE=${NET_TX_BASE:-0}
NET_LAST_TIME=$(date +%s)    # 基线获取时间戳

# -------------------------- 核心监控逻辑 --------------------------
# 功能：单次采样并输出CPU/内存/磁盘/网络使用率
# 参数：无
monitor() {
    # 当前采样时间（格式化）
    local current_time=$(date +"%Y-%m-%d %H:%M:%S")

    # 1. CPU使用率计算（提取user+sys占比，精准反映总负载）
    local cpu_usage=$(top -l 1 -n 0 | awk '/CPU usage/ {
        user = substr($3, 1, length($3)-1) + 0;  # 去掉%号并转为数字
        sys = substr($5, 1, length($5)-1) + 0;   # 去掉%号并转为数字
        total = user + sys;
        # 限制CPU使用率范围（0-100%）
        printf "%.0f", (total > 100 ? 100 : (total < 0 ? 0 : total));
    }')
    # 兜底：获取失败时默认0%
    cpu_usage=${cpu_usage:-0}

    # 2. 内存使用率计算（活跃+非活跃内存 / 总内存）
    local mem_total=$(sysctl -n hw.memsize)          # 总物理内存（字节）
    local pages_active=$(vm_stat | awk '/Pages active/ {gsub(/:/,""); print $3 + 0}')   # 活跃内存页数
    local pages_inactive=$(vm_stat | awk '/Pages inactive/ {gsub(/:/,""); print $3 + 0}') # 非活跃内存页数
    local page_size=$(sysctl -n hw.pagesize)         # 内存页大小（字节）
    local mem_used=$(( (pages_active + pages_inactive) * page_size ))  # 已用内存（字节）
    # 计算使用率（保留1位小数）
    mem_usage=$(echo "scale=1; if($mem_total==0) 0 else $mem_used / $mem_total * 100" | bc)
    # 兜底：获取失败时默认0.0%
    mem_usage=${mem_usage:-0.0}

    # 3. 磁盘使用率计算（过滤非数字字符，避免格式异常）
    local disk_usage=$(df -h "$DISK_PARTITION" 2>/dev/null | awk '
        NR==2 {
            gsub(/%/, "", $5);        # 去掉%号
            gsub(/[^0-9]/, "", $5);   # 过滤所有非数字字符
            print $5 + 0;             # 转为数字，空值默认0
        }
    ')
    # 兜底：获取失败时默认0%
    disk_usage=${disk_usage:-0}

    # 4. 网络流量计算（基于基线差值，单位：KB/s）
    local net_rx=0 net_tx=0
    local current_ts=$(date +%s)
    # 获取当前网络收发字节数
    net_curr=$(get_net_stats)
    NET_RX_CURR=${net_curr%% *}
    NET_TX_CURR=${net_curr##* }
    NET_RX_CURR=${NET_RX_CURR:-0}
    NET_TX_CURR=${NET_TX_CURR:-0}
    
    # 计算时间差（秒）
    local time_diff=$(( current_ts - NET_LAST_TIME ))
    if [ "$time_diff" -gt 0 ]; then
        # 计算每秒收发流量（字节→KB），避免负数（网络重置场景）
        net_rx=$(( (NET_RX_CURR - NET_RX_BASE) / time_diff / 1024 ))
        net_tx=$(( (NET_TX_CURR - NET_TX_BASE) / time_diff / 1024 ))
        net_rx=$(( net_rx < 0 ? 0 : net_rx ))
        net_tx=$(( net_tx < 0 ? 0 : net_tx ))
    fi

    # 更新网络基线（用于下次采样）
    NET_RX_BASE=$NET_RX_CURR
    NET_TX_BASE=$NET_TX_CURR
    NET_LAST_TIME=$current_ts

    # 格式化输出（严格对齐，保证可读性）
    local output
    output=$(printf "[%s] CPU: %3s%% | 内存: %5s%% | 磁盘(%s): %3s%% | 网络(%s)接收: %5sKB/s | 发送: %5sKB/s" \
        "$current_time" \
        "$cpu_usage" \
        "$mem_usage" \
        "$DISK_PARTITION" \
        "$disk_usage" \
        "$INTERFACE" \
        "$net_rx" \
        "$net_tx")

    # 控制台输出（绿色高亮）
    echo -e "${GREEN}${output}${NC}"
    # 日志文件输出（纯文本，无颜色）
    if [ -n "$OUTPUT_FILE" ]; then
        echo "$output" >> "$OUTPUT_FILE"
    fi
}

# -------------------------- 程序入口 --------------------------
# 输出监控配置信息（友好提示）
log_info "===== 性能监控启动配置 ====="
log_info "系统类型：Darwin (MacOS)"
log_info "监控总时长：${DURATION}秒"
log_info "采样间隔：${INTERVAL}秒"
log_info "监控磁盘分区：${DISK_PARTITION}"
log_info "监控网络接口：${INTERFACE}"
if [ -n "$OUTPUT_FILE" ]; then
    log_info "日志输出路径：${OUTPUT_FILE}"
fi
log_info "=============================="
echo -e "${BLUE}提示：按Ctrl+C可提前终止监控${NC}"

# 核心监控循环（持续采样直到达到指定时长）
while true; do
    # 执行单次采样
    monitor || log_warn "本次采样出现异常，将继续下一次采样"

    # 计算已运行时长
    current_ts=$(date +%s)
    elapsed=$(( current_ts - START_TIME ))

    # 达到指定时长则退出循环
    if [ "$elapsed" -ge "$DURATION" ]; then
        break
    fi

    # 按指定间隔休眠（精准控制采样频率）
    sleep $INTERVAL
done

# 监控结束提示
log_info "===== 性能监控正常结束 ====="
if [ -n "$OUTPUT_FILE" ]; then
    log_info "完整监控日志已保存至：${OUTPUT_FILE}"
fi
echo -e "${GREEN}提示：可使用 'cat $OUTPUT_FILE' 查看完整监控记录${NC}"
