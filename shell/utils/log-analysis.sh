#!/bin/bash
# 脚本名称：log-analysis.sh
# 功能：通用日志分析工具，支持关键词过滤、错误统计、时间范围筛选
# 使用说明：./log-analysis.sh -f <日志文件路径> [选项]
# 版本：1.2
# 适用系统：Linux/Mac OS（完全兼容BSD awk/GNU awk）

# 初始化变量
LOG_FILE=""
KEYWORD=""
COUNT_ONLY=0
ERROR_STAT=0
TIME_RANGE=""
START_TIME=""
END_TIME=""
START_TIMESTAMP=0
END_TIMESTAMP=0
RED='\033[0;31m'
NC='\033[0m'

# 显示帮助信息
show_help() {
    cat << EOF
通用日志分析工具 - 使用说明

用途：筛选或统计日志文件内容，支持关键词过滤、错误行识别、时间范围筛选

使用语法：
  $0 -f <日志文件路径> [选项]

必填参数：
  -f <文件>    指定日志文件路径（必须存在且可读）

可选参数：
  -k <关键词>  筛选包含指定关键词的行，支持正则表达式
  -e           筛选包含ERROR/error/ERR/err的错误行（不区分大小写）
  -t <时间范围> 按时间范围筛选日志，格式为"开始时间,结束时间"
                时间格式要求：YYYY-MM-DD HH:MM:SS
                示例：-t "2025-11-26 00:00:00,2025-11-27 23:59:59"
  -c           仅输出匹配行数，不显示具体日志内容
  -h           显示本帮助信息

使用示例：
  1. 筛选日志中包含"ERROR"的所有行：
     $0 -f /var/log/nginx/error.log -k "ERROR"
  
  2. 统计日志中的错误行数（仅输出数字）：
     $0 -f /var/log/app.log -e -c
  
  3. 筛选指定时间范围内的日志：
     $0 -f /var/log/sys.log -t "2025-11-26 00:00:00,2025-11-27 23:59:59"
  
  4. 组合筛选：指定时间范围+错误行+关键词"timeout"
     $0 -f /var/log/app.log -t "2025-11-26 00:00:00,2025-11-27 23:59:59" -e -k "timeout"

注意事项：
  1. 时间筛选仅匹配日志中符合"YYYY-MM-DD HH:MM:SS"格式的时间戳
  2. 关键词筛选支持标准正则表达式，特殊字符需转义
  3. 错误行标红仅在终端中生效，重定向输出时颜色会自动去除
EOF
}

# 验证时间格式（兼容Linux/Mac，返回0=有效，1=无效）
validate_time() {
    local time_str="$1"
    # 先做格式字符串校验（避免无效格式传入date命令）
    if ! echo "$time_str" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'; then
        return 1
    fi
    # 系统兼容的时间有效性校验
    if [[ "$(uname)" == "Darwin" ]]; then
        date -jf "%Y-%m-%d %H:%M:%S" "$time_str" +%s >/dev/null 2>&1
    else
        date -d "$time_str" +%s >/dev/null 2>&1
    fi
    return $?
}

# 转换时间为时间戳（兼容Linux/Mac）
convert_to_timestamp() {
    local time_str="$1"
    if [[ "$(uname)" == "Darwin" ]]; then
        date -jf "%Y-%m-%d %H:%M:%S" "$time_str" +%s 2>/dev/null
    else
        date -d "$time_str" +%s 2>/dev/null
    fi
}

# 单行时间戳转换（供管道调用，兼容Mac/Linux）
convert_line_timestamp() {
    local time_str="$1"
    if [[ "$(uname)" == "Darwin" ]]; then
        date -jf "%Y-%m-%d %H:%M:%S" "$time_str" +%s 2>/dev/null
    else
        date -d "$time_str" +%s 2>/dev/null
    fi
}

# 日志分析核心函数（彻底重构时间筛选，不依赖awk的mktime）
analyze_log() {
    # 初始化过滤结果（确保非空）
    local filtered_lines=$(cat "$LOG_FILE" 2>/dev/null)
    if [[ -z "$filtered_lines" ]]; then
        echo "0"
        return
    fi

    # 1. 时间范围过滤（重构：不依赖awk内置函数，用外部date命令）
    if [[ -n "$TIME_RANGE" && "$START_TIMESTAMP" -gt 0 && "$END_TIMESTAMP" -gt 0 ]]; then
        local temp_lines=""
        # 逐行处理日志，提取时间戳并比较
        while IFS= read -r line; do
            # 提取行中的YYYY-MM-DD HH:MM:SS格式时间戳
            local line_time=$(echo "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1)
            if [[ -n "$line_time" ]]; then
                # 转换为时间戳
                local line_timestamp=$(convert_line_timestamp "$line_time")
                # 比较时间范围
                if [[ "$line_timestamp" -ge "$START_TIMESTAMP" && "$line_timestamp" -le "$END_TIMESTAMP" ]]; then
                    temp_lines+="$line"$'\n'
                fi
            fi
        done <<< "$filtered_lines"
        filtered_lines="$temp_lines"
    fi

    # 2. 错误行过滤（优化：确保grep返回值不影响后续逻辑）
    if [[ $ERROR_STAT -eq 1 ]]; then
        filtered_lines=$(echo "$filtered_lines" | grep -iE "error|err" 2>/dev/null)
        # 处理grep无匹配的情况
        if [[ $? -eq 1 ]]; then
            filtered_lines=""
        fi
    fi

    # 3. 关键词过滤（优化：正则转义，避免注入）
    if [[ -n "$KEYWORD" ]]; then
        # 转义正则特殊字符
        local safe_keyword=$(echo "$KEYWORD" | sed 's/[\/&*.^$|()\[\]]/\\&/g')
        filtered_lines=$(echo "$filtered_lines" | grep -E "$safe_keyword" 2>/dev/null)
        # 处理grep无匹配的情况
        if [[ $? -eq 1 ]]; then
            filtered_lines=""
        fi
    fi

    # 统计行数（处理空结果边界情况）
    local count=0
    if [[ -n "$filtered_lines" ]]; then
        # 去除最后一行空行（避免wc计数错误）
        filtered_lines=$(echo "$filtered_lines" | sed '/^$/d')
        count=$(echo "$filtered_lines" | wc -l | tr -d '[:space:]')
    fi

    # 输出结果（逻辑优化）
    if [[ $COUNT_ONLY -eq 1 ]]; then
        echo "$count"
    else
        # 错误行标红（仅终端输出时生效）
        if [[ -t 1 ]]; then # 检测是否为终端输出
            echo "$filtered_lines" | awk -v red="$RED" -v nc="$NC" '{
                if ($0 ~ /[Ee]rror|[Ee]rr/) print red $0 nc;
                else print $0;
            }'
        else
            echo "$filtered_lines" # 重定向时不输出颜色
        fi
        # 输出总行数
        echo "总计匹配行数：$count"
    fi
}

# ====================== 主流程逻辑检查与执行 ======================

# 解析命令行参数（优化：处理参数顺序问题）
while getopts "f:k:et:ch" opt; do
    case $opt in
        f) 
            LOG_FILE="$OPTARG" 
            # 提前检查文件是否存在（避免后续冗余判断）
            if [[ ! -f "$LOG_FILE" ]]; then
                echo "错误：指定的日志文件 '$LOG_FILE' 不存在" >&2
                exit 1
            fi
            if [[ ! -r "$LOG_FILE" ]]; then
                echo "错误：没有读取日志文件 '$LOG_FILE' 的权限" >&2
                exit 1
            fi
            ;;
        k) KEYWORD="$OPTARG" ;;
        e) ERROR_STAT=1 ;;
        t) TIME_RANGE="$OPTARG" ;;
        c) COUNT_ONLY=1 ;;
        h) show_help; exit 0 ;;
        \?) 
            echo "错误：无效选项 -$OPTARG" >&2
            echo "使用 '-h' 查看帮助信息" >&2
            exit 1 
            ;;
        :) 
            echo "错误：选项 -$OPTARG 需要传入参数" >&2
            echo "使用 '-h' 查看帮助信息" >&2
            exit 1 
            ;;
    esac
done

# 检查必填参数（兜底检查）
if [[ -z "$LOG_FILE" ]]; then
    echo "错误：必须通过 '-f' 参数指定日志文件路径" >&2
    echo "使用 '-h' 查看帮助信息" >&2
    exit 1
fi

# 解析并验证时间范围（逻辑优化：增加多层校验）
if [[ -n "$TIME_RANGE" ]]; then
    # 分割时间范围
    IFS=',' read -ra TIME_ARRAY <<< "$TIME_RANGE"
    if [[ ${#TIME_ARRAY[@]} -ne 2 ]]; then
        echo "错误：时间范围格式错误，正确格式为\"开始时间,结束时间\"" >&2
        exit 1
    fi
    START_TIME="${TIME_ARRAY[0]}"
    END_TIME="${TIME_ARRAY[1]}"

    # 验证开始时间
    if ! validate_time "$START_TIME"; then
        echo "错误：开始时间 '$START_TIME' 格式无效，要求：YYYY-MM-DD HH:MM:SS" >&2
        exit 1
    fi
    # 验证结束时间
    if ! validate_time "$END_TIME"; then
        echo "错误：结束时间 '$END_TIME' 格式无效，要求：YYYY-MM-DD HH:MM:SS" >&2
        exit 1
    fi

    # 转换为时间戳
    START_TIMESTAMP=$(convert_to_timestamp "$START_TIME")
    END_TIMESTAMP=$(convert_to_timestamp "$END_TIME")

    # 验证时间范围合理性
    if [[ "$START_TIMESTAMP" -gt "$END_TIMESTAMP" ]]; then
        echo "错误：开始时间不能晚于结束时间" >&2
        exit 1
    fi
fi

# 执行核心分析逻辑
analyze_log

exit 0
