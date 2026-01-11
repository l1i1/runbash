#!/bin/bash
# 基础安全配置：仅保留必要的严格检查
set -o nounset  # 未定义变量报错
set -o pipefail # 管道中任意命令失败则整体失败

# ==============================================================================
# ===================== 用户配置区 (根据需要修改) =====================
# ==============================================================================

# --- 测试参数 ---
NUMBER=32                   # 总请求次数
MAX_CONCURRENT=16              # 最大并发数 (建议根据CPU核心数调整)
URL="https://tf.sysri.cn/HotPE/Releases/HotPE-V2.8.251018.exe"  # 测试目标URL

# --- 网络参数 ---
FOLLOW_REDIRECTS="yes"         # 是否跟随 302/301 跳转 (yes/no，建议 yes 以便下载真实文件测试带宽)
RETRY_COUNT=1                  # curl 失败重试次数
RETRY_DELAY=1                  # curl 失败重试间隔(秒)
CONNECT_TIMEOUT=10             # 连接超时时间(秒)
MAX_TIME=30                    # 单个请求最大允许时间(秒)

# --- 路径配置 ---
# 自定义临时文件目录 (留空则自动优先使用 /dev/shm，其次 /tmp)
CUSTOM_TEMP_DIR=""              # 例如: "/tmp" 或 "/home/user/tmp"

# ==============================================================================
# ===================== 配置区结束 (下方为脚本逻辑) =====================
# ==============================================================================

# ===================== 前置检查 =====================
# 1. 检查 Bash 版本（要求 4.3+，支持 wait -n）
if [[ "${BASH_VERSINFO[0]}" -lt 4 || ("${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -lt 3) ]]; then
    echo "错误: 此脚本需要 Bash 4.3 或更高版本"
    echo "当前版本: $BASH_VERSION"
    exit 1
fi

# 2. 检查 curl 是否安装
if ! command -v curl &> /dev/null; then
    echo "错误: 未找到 curl 命令，请先安装。"
    exit 1
fi

# 3. 检查 curl 版本（--retry-all-errors 需要 7.71.0+）
CURL_MIN_VERSION="7.71.0"
CURL_VERSION=$(curl --version | head -n1 | awk '{print $2}')
version_compare() {
    local v1=$1 v2=$2
    [[ "$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -n1)" == "$v2" ]]
}

# 初始化 curl 重试参数（兼容低版本）
if ! version_compare "$CURL_VERSION" "$CURL_MIN_VERSION"; then
    echo "警告: curl 版本低于 7.71.0，--retry-all-errors 不可用，仅重试网络连接错误"
    CURL_RETRY_ARGS="--retry $RETRY_COUNT --retry-delay $RETRY_DELAY"
else
    CURL_RETRY_ARGS="--retry $RETRY_COUNT --retry-delay $RETRY_DELAY --retry-all-errors"
fi

# 处理 302 跳转参数
if [[ "$FOLLOW_REDIRECTS" == "yes" ]]; then
    CURL_REDIRECT_ARGS="-L"
else
    CURL_REDIRECT_ARGS=""
fi

# ===================== IP 获取函数 =====================
# 1. 获取本地IP（支持多种方法）
get_local_ip() {
    local local_ip=""
    
    # 方法1: 使用 ip 命令（Linux通用）
    if command -v ip &> /dev/null; then
        local_ip=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1); exit}}')
    fi
    
    # 方法2: 备选 - 查找非本地回环接口的IP
    if [[ -z "$local_ip" ]] && command -v hostname &> /dev/null; then
        local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    
    # 方法3: 使用 ifconfig
    if [[ -z "$local_ip" ]] && command -v ifconfig &> /dev/null; then
        local_ip=$(ifconfig 2>/dev/null | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1' | head -n1)
    fi
    
    # 方法4: 读取 /proc/net/route
    if [[ -z "$local_ip" && -f /proc/net/route ]]; then
        local_ip=$(awk 'NR>1 && $2=="00000000"{print $1}' /proc/net/route | head -n1 | while read hex; do
            printf "%d.%d.%d.%d\n" 0x${hex:6:2} 0x${hex:4:2} 0x${hex:2:2} 0x${hex:0:2}
        done)
    fi
    
    echo "${local_ip:-未知}"
}

# 2. 获取远程公网IP（多个备用服务）
get_remote_ip() {
    local remote_ip=""
    local services=(
        "https://api.ipify.org"
        "https://ifconfig.me/ip"
        "https://icanhazip.com"
        "https://checkip.amazonaws.com"
        "https://ipecho.net/plain"
    )
    
    for service in "${services[@]}"; do
        remote_ip=$(curl -s --max-time 5 --connect-timeout 3 "$service" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
        if [[ -n "$remote_ip" ]]; then
            break
        fi
    done
    
    echo "${remote_ip:-未知}"
}

# 3. 获取远程主机IP（解析测试URL）
get_remote_host_ip() {
    local url="$1"
    local host=""
    
    # 从URL中提取主机名
    host=$(echo "$url" | sed -e 's|^[^/]*//||' -e 's|/.*$||' -e 's|:.*$||')
    
    # 解析主机IP
    if command -v host &> /dev/null; then
        host -t A "$host" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1
    elif command -v nslookup &> /dev/null; then
        nslookup "$host" 2>/dev/null | grep -Eo 'Address: ([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1
    elif command -v getent &> /dev/null; then
        getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -n1
    else
        echo "未知"
    fi
}

# ===================== 初始化环境变量 =====================
SCRIPT_PID=$$

# 临时文件配置（内存文件优先，保证唯一性）
if [[ -n "$CUSTOM_TEMP_DIR" && -d "$CUSTOM_TEMP_DIR" && -w "$CUSTOM_TEMP_DIR" ]]; then
    TEMP_DIR="$CUSTOM_TEMP_DIR"
else
    TEMP_DIR="/dev/shm"
    [[ ! -w "$TEMP_DIR" ]] && TEMP_DIR="/tmp"  # 内存目录不可写则降级到/tmp
fi

LOG_FILE="download_${SCRIPT_PID}.log"    # 错误日志文件
TEMP_COUNT="${TEMP_DIR}/curl_test_count_${SCRIPT_PID}"  # 成功计数文件
TEMP_BYTES="${TEMP_DIR}/curl_test_bytes_${SCRIPT_PID}"  # 流量统计文件

# 获取IP信息
LOCAL_IP=$(get_local_ip)
REMOTE_PUBLIC_IP=$(get_remote_ip)
REMOTE_HOST_IP=$(get_remote_host_ip "$URL")

# ===================== 全局状态变量 =====================
start_time=$(date +%s)
prev_percentage=0
total_initiated=0         # 已发起请求数
running_jobs=0            # 运行中的任务数（核心优化）
CLEANUP_CALLED=0          # 避免重复清理
TRAP_TRIGGERED=0          # 标记信号触发的清理

# ===================== 核心函数 =====================
# 1. 清理函数（安全、幂等）
cleanup() {
    [[ "$CLEANUP_CALLED" == "1" ]] && return
    CLEANUP_CALLED=1
    
    echo -e "\n清理临时文件..."
    # 清理所有相关文件，添加容错
    rm -f "$TEMP_COUNT" "${TEMP_COUNT}.lock" "$TEMP_BYTES" "${TEMP_BYTES}.lock" 2>/dev/null || true
    # 无错误时自动清理日志，有错误则保留
    [[ ! -s "$LOG_FILE" ]] && rm -f "$LOG_FILE" 2>/dev/null || true
    
    # 仅信号触发时返回错误码
    if [[ "$TRAP_TRIGGERED" == "1" ]]; then
        echo "脚本被强制终止，资源已清理"
        exit 1
    fi
}

# 注册信号捕获（仅中断/终止信号）
trap 'TRAP_TRIGGERED=1; cleanup' SIGINT SIGTERM

# 2. 安全递增计数函数（加锁+超时+容错）
increment_counter() {
    local count_file="$1"
    (
        # 5秒超时避免死锁，失败记录日志
        flock -x -w 5 200 || { echo "[$(date +%F\ %T)] 锁文件超时: $count_file" >> "$LOG_FILE"; return 1; }
        # 读取当前值并清洗（仅保留数字）
        current=$(cat "$count_file" 2>/dev/null || echo 0)
        current=$(echo "$current" | tr -cd '0-9')
        # 安全递增
        echo $(( ${current:-0} + 1 )) > "$count_file"
    ) 200>"${count_file}.lock" 2>/dev/null || true
}

# 3. 安全累加流量函数
add_bytes() {
    local bytes_file="$1"
    local bytes_to_add="$2"
    
    # 清洗输入：仅保留数字，空值默认0
    bytes_to_add=$(echo "$bytes_to_add" | tr -cd '0-9')
    bytes_to_add=${bytes_to_add:-0}
    
    (
        flock -x -w 5 200 || { echo "[$(date +%F\ %T)] 锁文件超时: $bytes_file" >> "$LOG_FILE"; return 1; }
        # 读取当前值并清洗
        current=$(cat "$bytes_file" 2>/dev/null || echo 0)
        current=$(echo "$current" | tr -cd '0-9')
        # 安全累加
        echo $(( ${current:-0} + bytes_to_add )) > "$bytes_file"
    ) 200>"${bytes_file}.lock" 2>/dev/null || true
}

# 4. 格式化流量显示（健壮性增强）
format_bytes() {
    local bytes=$1
    # 清洗输入
    bytes=$(echo "$bytes" | tr -cd '0-9')
    bytes=${bytes:-0}
    
    local units=('B' 'KB' 'MB' 'GB' 'TB')
    local unit=0
    local display_val=$bytes
    
    while (( bytes >= 1024 && unit < ${#units[@]} - 1 )); do
        display_val=$(awk "BEGIN {printf \"%.2f\", $bytes / 1024}")
        bytes=$((bytes / 1024))
        ((unit++))
    done
    
    echo "${display_val} ${units[$unit]}"
}

# 5. 健壮的百分比计算函数
calc_percent() {
    local numerator=$1 denominator=$2
    # 双重清洗，避免非数字导致awk报错
    numerator=$(echo "$numerator" | tr -cd '0-9')
    denominator=$(echo "$denominator" | tr -cd '0-9')
    numerator=${numerator:-0}
    denominator=${denominator:-1}  # 避免除以0
    
    awk "BEGIN {printf \"%.2f\", $numerator / $denominator * 100}"
}

# 6. 单个请求执行函数（使用配置区参数，支持302）
run_request() {
    local url=$1
    local output_info downloaded_bytes http_code

    # 执行curl请求
    # -L: 跟随重定向(支持302)
    # -o /dev/null: 丢弃下载内容（我们只需要统计）
    # -s: 静默模式
    # -w: 输出格式（大小和HTTP码）
    output_info=$(curl -o /dev/null -s -w '%{size_download}\n%{http_code}' \
                  --max-time $MAX_TIME --connect-timeout $CONNECT_TIMEOUT \
                  $CURL_RETRY_ARGS \
                  $CURL_REDIRECT_ARGS \
                  "$url" 2>> "$LOG_FILE")

    # 分割输出（兼容Bash 3.0+）
    IFS=$'\n' read -r downloaded_bytes http_code <<< "$output_info"

    # 仅2xx/3xx视为成功
    if [[ "$http_code" =~ ^[23][0-9]{2}$ ]]; then
        increment_counter "$TEMP_COUNT"
        add_bytes "$TEMP_BYTES" "$downloaded_bytes"
    fi
}

# 7. 精准的并发等待函数（修复running_jobs计数问题）
wait_for_completion() {
    # 仅当达到最大并发时等待
    if (( running_jobs >= MAX_CONCURRENT )); then
        # 精准处理wait -n返回值：区分正常完成/信号中断
        if wait -n 2>/dev/null; then
            # 任务正常完成，递减计数
            ((running_jobs--))
        else
            # wait -n失败（如信号中断/无后台任务），重新计算实际运行数
            running_jobs=$(jobs -r | wc -l)
        fi
    fi
}

# ===================== 初始化文件 =====================
# 所有文件操作添加容错，避免失败终止脚本
> "$LOG_FILE" 2>/dev/null || true
echo 0 > "$TEMP_COUNT" 2>/dev/null || true
echo 0 > "$TEMP_BYTES" 2>/dev/null || true

# ===================== 主测试逻辑 =====================
echo "开始并发测试: 总次数=$NUMBER, 最大并发=$MAX_CONCURRENT, 重试次数=$RETRY_COUNT"
echo "URL: $URL"
echo "跟随跳转: $FOLLOW_REDIRECTS"
echo "临时文件目录: $TEMP_DIR"
echo "=================================================="
echo "网络配置信息:"
echo "  本地IP:          $LOCAL_IP"
echo "  公网IP:          $REMOTE_PUBLIC_IP"
echo "  目标服务器IP:    $REMOTE_HOST_IP"
echo "=================================================="

# 核心循环：发起请求+控制并发
while (( total_initiated < NUMBER )); do
    # 启动新任务（不超过最大并发）
    while (( running_jobs < MAX_CONCURRENT && total_initiated < NUMBER )); do
        ((total_initiated++))
        ((running_jobs++))
        
        # 后台执行请求
        run_request "$URL" &
        
        # 每100次更新进度（减少IO开销）
        if (( total_initiated % 100 == 0 )); then
            # 读取计数时添加容错
            completed=$(cat "$TEMP_COUNT" 2>/dev/null || echo 0)
            percentage=$((total_initiated * 100 / NUMBER))
            
            if (( percentage > prev_percentage + 4 )); then
                current_bytes=$(cat "$TEMP_BYTES" 2>/dev/null || echo 0)
                current_flow=$(format_bytes "$current_bytes")
                echo "进度: 已发起=$total_initiated/$NUMBER (${percentage}%) | 成功=$completed | 已下载: $current_flow"
                prev_percentage=$percentage
            fi
        fi
    done
    
    # 等待任务完成（精准控制并发）
    wait_for_completion
done

# 等待所有剩余后台任务完成
echo -e "\n所有请求已发起，等待剩余进程完成..."
wait
running_jobs=0  # 重置计数

# ===================== 结果统计 =====================
# 读取统计数据（添加容错）
final_completed=$(cat "$TEMP_COUNT" 2>/dev/null || echo 0)
total_bytes=$(cat "$TEMP_BYTES" 2>/dev/null || echo 0)
end_time=$(date +%s)
total_seconds=$((end_time - start_time))
failed=$((NUMBER - final_completed))

# 计算核心指标
success_rate=$(calc_percent "$final_completed" "$NUMBER")
fail_rate=$(calc_percent "$failed" "$NUMBER")
qps=$(awk "BEGIN {printf \"%.2f\", $final_completed / ($total_seconds > 0 ? $total_seconds : 1)}")
avg_bytes=$(( final_completed > 0 ? total_bytes / final_completed : 0 ))
avg_bandwidth=$(awk "BEGIN {printf \"%.2f\", $total_bytes / ($total_seconds > 0 ? $total_seconds : 1) / 1024 / 1024}")

# 格式化输出
formatted_total_bytes=$(format_bytes "$total_bytes")
formatted_avg_bytes=$(format_bytes "$avg_bytes")

# ===================== 输出最终结果 =====================
echo -e "\n==================== 测试完成 ===================="
echo "网络配置:"
echo "  本地IP:          $LOCAL_IP"
echo "  公网IP:          $REMOTE_PUBLIC_IP"
echo "  目标服务器IP:    $REMOTE_HOST_IP"
echo "---------------------------------------------------"
echo "测试配置:"
echo "  总请求数:         $NUMBER"
echo "  最大并发数:       $MAX_CONCURRENT"
echo "  跟随302跳转:      $FOLLOW_REDIRECTS"
echo "  成功请求数:       $final_completed"
echo "  失败请求数:       $failed"
echo "  成功率:           ${success_rate}%"
echo "  失败率:           ${fail_rate}%"
echo "---------------------------------------------------"
echo "网络流量:"
echo "  总网络流量:       $formatted_total_bytes ($total_bytes 字节)"
echo "  平均流量/请求:    $formatted_avg_bytes/请求"
echo "  真实带宽:         ${avg_bandwidth} MB/s"
echo "---------------------------------------------------"
echo "性能指标:"
echo "  总耗时:           ${total_seconds}秒"
echo "  平均QPS:          ${qps}次/秒"
echo "=================================================="

# 显示错误日志（有错误才展示）
if [[ -s "$LOG_FILE" ]]; then
    echo -e "\n错误日志内容 (最后20行):"
    tail -n 20 "$LOG_FILE"
    echo -e "完整日志请查看: $LOG_FILE"
else
    echo -e "\n无错误发生！"
fi

# ===================== 正常退出清理 =====================
cleanup
echo -e "\n测试完成，所有资源已清理！"
exit 0
