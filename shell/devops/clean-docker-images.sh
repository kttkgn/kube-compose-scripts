#!/bin/bash
# ==============================================================================
# 脚本名称：clean-docker-images.sh
# 脚本用途：安全清理Docker中停止的容器 + 无任何引用的纯悬空资源（有引用的镜像/卷/网络不清理）
# 核心原则：
#   1. 清理所有停止（退出）的容器（无论是否有卷/网络引用）
#   2. 无任何强制删除操作（不使用-f参数）
#   3. 有引用的镜像/卷/网络不扫描、不清理
# 使用权限：需要Docker执行权限，安装jq工具（脚本自动检测并安装）
# 适用系统：Mac OS / Linux（Ubuntu/Debian/CentOS）
# ==============================================================================

# -------------------------- 全局变量定义 --------------------------
# 颜色定义（用于输出提示）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'          # 重置颜色
KEEP_TAGS=""          # 需要保留的镜像标签（逗号分隔）
DRY_RUN=0             # 预览模式标记（1=仅预览，0=实际清理）

# -------------------------- 函数定义 --------------------------

# 函数：显示帮助信息
show_help() {
    echo -e "\n${GREEN}=== Docker资源清理脚本 ===${NC}"
    echo "用途：清理所有停止的容器 + 无任何引用的纯悬空资源（镜像/卷/网络）"
    echo "使用方法：$0 [选项]"
    echo -e "\n选项说明："
    echo "  --keep <标签>    保留包含指定标签的镜像，多个标签用逗号分隔（例：--keep nginx,mysql）"
    echo "  --dry-run        预览模式：仅显示待清理资源，不执行实际删除操作"
    echo "  -h/--help        显示本帮助信息"
    echo -e "\n使用示例："
    echo "  1. 预览清理（保留nginx和mysql镜像）：$0 --keep nginx,mysql --dry-run"
    echo "  2. 实际清理（保留nginx和mysql镜像）：$0 --keep nginx,mysql"
    echo "  3. 仅显示帮助：$0 -h"
    echo -e "\n注意事项："
    echo "  - 所有停止（退出）的容器都会被清理（无论是否有卷/网络引用）"
    echo "  - 仅清理无容器引用的悬空镜像、无容器关联的卷、无活跃端点的非默认网络"
    echo "  - 系统默认网络（bridge/host/none）永久跳过，不会被清理"
}

# 函数：检查并安装jq工具（JSON解析依赖）
check_jq() {
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}提示：检测到未安装jq工具（JSON解析依赖），正在自动安装...${NC}"
        # 适配不同系统安装jq
        if [[ "$(uname)" == "Darwin" ]]; then
            # Mac系统（依赖brew）
            if command -v brew &> /dev/null; then
                brew install jq >/dev/null 2>&1
                if [[ $? -ne 0 ]]; then
                    echo -e "${RED}错误：Mac系统安装jq失败，请手动执行 brew install jq${NC}"
                    exit 1
                fi
            else
                echo -e "${RED}错误：Mac系统未安装Homebrew，无法自动安装jq，请先安装brew${NC}"
                exit 1
            fi
        elif [[ "$(uname)" == "Linux" ]]; then
            # Linux系统（apt/yum）
            if command -v apt &> /dev/null; then
                sudo apt update >/dev/null 2>&1 && sudo apt install -y jq >/dev/null 2>&1
            elif command -v yum &> /dev/null; then
                sudo yum install -y jq >/dev/null 2>&1
            else
                echo -e "${RED}错误：Linux系统不支持自动安装jq，请手动安装${NC}"
                exit 1
            fi
            if [[ $? -ne 0 ]]; then
                echo -e "${RED}错误：Linux系统安装jq失败，请手动安装${NC}"
                exit 1
            fi
        else
            echo -e "${RED}错误：不支持的操作系统，请手动安装jq工具后重试${NC}"
            exit 1
        fi
        echo -e "${GREEN}提示：jq工具安装成功${NC}"
    fi
}

# 函数：安全解析资源信息（过滤乱码、空值）
# 参数：需要解析的原始字符串
safe_get() {
    local raw_value="$1"
    # 过滤非打印字符、首尾空格，仅保留可显示的ASCII字符
    echo "$raw_value" | tr -cd '[:print:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# 函数：清理所有停止（退出）的容器（核心修改：取消引用检查）
clean_stopped_containers() {
    echo -e "\n${YELLOW}===== 清理所有停止的容器 =====${NC}"
    # 获取所有退出容器ID（过滤乱码、空值）
    local stopped_containers=$(docker ps -aqf "status=exited" | tr -cd '[:alnum:]\n ' | sed '/^$/d')
    local cleaned_count=0

    if [[ -n "$stopped_containers" ]]; then
        # 统计待清理容器数量
        local container_list=($stopped_containers)
        cleaned_count=${#container_list[@]}

        if [[ $DRY_RUN -eq 1 ]]; then
            echo -e "${YELLOW}预览清理停止的容器：共 ${cleaned_count} 个${NC}"
            echo -e "${YELLOW}容器ID列表：$(safe_get "$stopped_containers")${NC}"
        else
            # 清理所有停止的容器（无强制删除，Docker自动跳过有强引用的容器）
            docker rm $stopped_containers >/dev/null 2>&1
            echo -e "${GREEN}已清理 ${cleaned_count} 个停止的容器${NC}"
        fi
    else
        echo "无停止的容器需要清理"
    fi
}

# 函数：清理无引用的悬空镜像
clean_unused_images() {
    echo -e "\n${YELLOW}===== 清理无引用的悬空镜像 =====${NC}"
    # 获取所有悬空镜像ID（过滤乱码、空值）
    local dangling_images=$(docker images -qf "dangling=true" | tr -cd '[:alnum:]\n ' | sed '/^$/d')
    local unused_images=""
    local cleaned_count=0

    if [[ -n "$dangling_images" ]]; then
        # 构建保留镜像的过滤条件（根据--keep参数）
        local keep_images=""
        if [[ -n "$KEEP_TAGS" ]]; then
            local keep_filter=""
            IFS=',' read -ra tags <<< "$KEEP_TAGS"
            for tag in "${tags[@]}"; do
                keep_filter+="--filter=reference=*$tag* "
            done
            # 获取需要保留的镜像ID
            keep_images=$(docker images -q $keep_filter | tr -cd '[:alnum:]\n ' | sed '/^$/d')
        fi

        # 筛选无引用的悬空镜像
        for image in $dangling_images; do
            image=$(safe_get "$image")
            [[ -z "$image" ]] && continue

            # 跳过保留标签的镜像
            if echo "$keep_images" | grep -xF "$image" >/dev/null 2>&1; then
                continue
            fi

            # 检查镜像是否被任何容器引用（运行/退出）
            local container_usage=$(docker ps -aq --filter "ancestor=$image" 2>/dev/null)
            if [[ -z "$container_usage" ]]; then
                unused_images+="$image "
            fi
        done

        # 统计待清理镜像数量
        if [[ -n "$unused_images" ]]; then
            local image_list=($unused_images)
            cleaned_count=${#image_list[@]}
        fi
    fi

    # 执行清理/预览
    if [[ $cleaned_count -gt 0 ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            echo -e "${YELLOW}预览清理无引用镜像：共 ${cleaned_count} 个${NC}"
            echo -e "${YELLOW}镜像ID列表：$(safe_get "$unused_images")${NC}"
        else
            docker rmi $unused_images >/dev/null 2>&1
            echo -e "${GREEN}已清理 ${cleaned_count} 个无引用的悬空镜像${NC}"
        fi
    else
        echo "无无引用的悬空镜像需要清理"
    fi
}

# 函数：清理无引用的卷
clean_unused_volumes() {
    echo -e "\n${YELLOW}===== 清理无引用的卷 =====${NC}"
    # Docker原生dangling=true已表示无容器关联的卷
    local unused_volumes=$(docker volume ls -qf "dangling=true" | tr -cd '[:alnum:]\n ' | sed '/^$/d')
    local cleaned_count=0

    # 统计待清理卷数量
    if [[ -n "$unused_volumes" ]]; then
        local volume_list=($unused_volumes)
        cleaned_count=${#volume_list[@]}
    fi

    # 执行清理/预览
    if [[ $cleaned_count -gt 0 ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            echo -e "${YELLOW}预览清理无引用卷：共 ${cleaned_count} 个${NC}"
            echo -e "${YELLOW}卷ID列表：$(safe_get "$unused_volumes")${NC}"
        else
            docker volume rm $unused_volumes >/dev/null 2>&1
            echo -e "${GREEN}已清理 ${cleaned_count} 个无引用的卷${NC}"
        fi
    else
        echo "无无引用的卷需要清理"
    fi
}

# 函数：清理无引用的网络
clean_unused_networks() {
    echo -e "\n${YELLOW}===== 清理无引用的网络 =====${NC}"
    # 获取系统默认网络ID（bridge/host/none，避免误删）
    local bridge_id=$(docker network inspect bridge -f '{{.Id}}' 2>/dev/null | safe_get)
    local host_id=$(docker network inspect host -f '{{.Id}}' 2>/dev/null | safe_get)
    local none_id=$(docker network inspect none -f '{{.Id}}' 2>/dev/null | safe_get)
    local default_networks="$bridge_id $host_id $none_id"

    # 获取所有悬空网络ID（过滤乱码、空值）
    local dangling_networks=$(docker network ls -qf "dangling=true" | tr -cd '[:alnum:]\n ' | sed '/^$/d')
    local unused_networks=""
    local cleaned_count=0

    if [[ -n "$dangling_networks" ]]; then
        for network in $dangling_networks; do
            network=$(safe_get "$network")
            [[ -z "$network" ]] && continue

            # 跳过系统默认网络
            if echo "$default_networks" | grep -xF "$network" >/dev/null 2>&1; then
                continue
            fi

            # 获取网络详情（JSON格式，屏蔽错误输出）
            local network_detail=$(docker network inspect --format '{{json .}}' "$network" 2>/dev/null)
            [[ -z "$network_detail" ]] && continue

            # 解析网络活跃端点数量（兼容新旧Docker版本）
            local endpoints_count=$(echo "$network_detail" | jq '.Endpoints | length' 2>/dev/null || echo 0)
            [[ "$endpoints_count" == "null" ]] && endpoints_count=$(echo "$network_detail" | jq '.Containers | length' 2>/dev/null || echo 0)
            endpoints_count=$(safe_get "$endpoints_count")

            # 仅筛选：无活跃端点的网络（纯孤立网络）
            if [[ "$endpoints_count" == "0" ]]; then
                unused_networks+="$network "
            fi
        done

        # 统计待清理网络数量
        if [[ -n "$unused_networks" ]]; then
            local network_list=($unused_networks)
            cleaned_count=${#network_list[@]}
        fi
    fi

    # 执行清理/预览
    if [[ $cleaned_count -gt 0 ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            echo -e "${YELLOW}预览清理无引用网络：共 ${cleaned_count} 个${NC}"
            echo -e "${YELLOW}网络ID列表：$(safe_get "$unused_networks")${NC}"
        else
            docker network rm $unused_networks >/dev/null 2>&1
            echo -e "${GREEN}已清理 ${cleaned_count} 个无引用的网络${NC}"
        fi
    else
        echo "无无引用的网络需要清理"
    fi
}

# 函数：输出磁盘使用情况（显示所有分区）
show_disk_usage() {
    echo -e "\n${YELLOW}===== 清理后磁盘使用情况 =====${NC}"
    if [[ "$(uname)" == "Darwin" ]]; then
        # Mac系统：显示所有磁盘分区
        df -h | grep -E "/dev/disk" | awk '{printf "%-15s %-8s %-8s %-8s %-8s %s\n", $1, $2, $3, $4, $5, $NF}'
    else
        # Linux系统：显示所有磁盘分区
        df -h | grep -E "/dev/sd" | awk '{printf "%-15s %-8s %-8s %-8s %-8s %s\n", $1, $2, $3, $4, $5, $NF}'
    fi
}

# -------------------------- 主流程 --------------------------

# 步骤1：解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)
            KEEP_TAGS="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}错误：未知参数 '$1'${NC}"
            show_help
            exit 1
            ;;
    esac
done

# 步骤2：前置检查
# 检查Docker是否运行
if ! docker info >/dev/null 2>&1; then
    echo -e "${RED}错误：Docker服务未运行，请先启动Docker${NC}"
    exit 1
fi
# 检查并安装jq工具
check_jq

# 步骤3：执行资源清理
echo -e "${GREEN}=== 开始清理Docker资源 ===${NC}"
clean_stopped_containers  # 清理所有停止的容器（核心修改）
clean_unused_images       # 清理无引用镜像
clean_unused_volumes      # 清理无引用卷
clean_unused_networks     # 清理无引用网络

# 步骤4：清理完成提示 + 磁盘信息
echo -e "\n${GREEN}=== Docker资源清理完成 ===${NC}"
show_disk_usage

# 步骤5：退出脚本
exit 0
