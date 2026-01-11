#!/bin/bash
set -o nounset
set -o pipefail

# 前置检查
if [[ "${BASH_VERSINFO[0]}" -lt 4 || ("${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -lt 3) ]]; then
    echo "错误: 需要 Bash 4.3+"
    exit 1
fi

if ! command -v curl &> /dev/null; then
    echo "错误: 需要 curl"
    exit 1
fi

# 初始化
NUMBER=32
MAX_CONCURRENT=32
URL="https://sc.sysri.cn/_def/i/p/1/686d259fb565d.png"
SCRIPT_PID=$$
LOG_FILE="download_${SCRIPT_PID}.log"
TEMP_DIR="/dev/shm"
[[ ! -w "$TEMP_DIR" ]] && TEMP_DIR="/tmp"
TEMP_COUNT="${TEMP_DIR}/curl_test_count_${SCRIPT_PID}"
TEMP_BYTES="${TEMP_DIR}/curl_test_bytes_${SCRIPT_PID}"

# 全局变量
start_time=$(date +%s)
prev_percentage=0
total_initiated=0
running_jobs=0
CLEANUP_CALLED=0
TRAP_TRIGGERED=0

# 获取远程服务器IP
get_remote_ip() {
    local ip=""
    ip=$(curl -o /dev/null -s -w '%{remote_ip}' \
              --max-time 10 --connect-timeout 5 \
              "$URL" 2>> "$LOG_FILE")
    echo "${ip:-未知}"
}

# 获取本机出口IP
get_local_ip() {
    local ip=""
    ip=$(curl -s -4 --max-time 5 ifconfig.me 2>> "$LOG_FILE")
    echo "${ip:-未知}"
}

REMOTE_IP=$(get_remote_ip)
LOCAL_IP=$(get_local_ip)

# 清理函数
cleanup() {
    [[ "$CLEANUP_CALLED" == "1" ]] && return
    CLEANUP_CALLED=1
    rm -f "$TEMP_COUNT" "${TEMP_COUNT}.lock" "$TEMP_BYTES" "${TEMP_BYTES}.lock" 2>/dev/null || true
    [[ ! -s "$LOG_FILE" ]] && rm -f "$LOG_FILE" 2>/dev/null || true
    [[ "$TRAP_TRIGGERED" == "1" ]] && { echo "脚本被强制终止"; exit 1; }
}

trap 'TRAP_TRIGGERED=1; cleanup' SIGINT SIGTERM

# 计数函数
increment_counter() {
    (
        flock -x -w 5 200 || { echo "[$(date '+%F %T')] 锁超时: $1" >> "$LOG_FILE"; return 1; }
        current=$(cat "$1" 2>/dev/null || echo 0)
        current=${current//[^0-9]/}
        echo $(( ${current:-0} + 1 )) > "$1"
    ) 200>"$1.lock" 2>/dev/null || true
}

# 流量统计
add_bytes() {
    local bytes_to_add=${2//[^0-9]/}
    bytes_to_add=${bytes_to_add:-0}
    (
        flock -x -w 5 200 || { echo "[$(date '+%F %T')] 锁超时: $1" >> "$LOG_FILE"; return 1; }
        current=$(cat "$1" 2>/dev/null || echo 0)
        current=${current//[^0-9]/}
        echo $(( ${current:-0} + bytes_to_add )) > "$1"
    ) 200>"$1.lock" 2>/dev/null || true
}

# 请求执行（修复变量作用域问题）
run_request() {
    local temp_output_file="${TEMP_DIR}/curl_output_${SCRIPT_PID}_$$_$RANDOM.tmp"
    local temp_error_file="${TEMP_DIR}/curl_error_${SCRIPT_PID}_$$_$RANDOM.tmp"
    local downloaded_bytes="" http_code="" curl_error line_count=0
    
    # 创建临时文件
    : > "$temp_output_file"
    : > "$temp_error_file"
    
    # 执行curl请求，输出到临时文件
    curl -o /dev/null -s -w '%{size_download}\n%{http_code}' \
         --max-time 30 --connect-timeout 10 \
         --retry 1 --retry-delay 1 \
         "$1" > "$temp_output_file" 2> "$temp_error_file"
    
    # 读取错误信息
    curl_error=$(cat "$temp_error_file" 2>/dev/null)
    
    # 如果有错误，记录到日志
    if [[ -n "$curl_error" ]]; then
        echo "[$(date '+%F %T')] URL: $1 - curl错误: $curl_error" >> "$LOG_FILE"
    fi
    
    # 直接读取文件内容并解析（避免管道子shell问题）
    while IFS= read -r line; do
        if [[ $line_count -eq 0 ]]; then
            downloaded_bytes="$line"
        elif [[ $line_count -eq 1 ]]; then
            http_code="$line"
        fi
        ((line_count++))
    done < "$temp_output_file"
    
    # 清理临时文件
    rm -f "$temp_output_file" "$temp_error_file" 2>/dev/null
    
    # 验证HTTP状态码
    if [[ -z "$http_code" ]]; then
        echo "[$(date '+%F %T')] URL: $1 - 无HTTP状态码返回" >> "$LOG_FILE"
    else
        echo "[$(date '+%F %T')] URL: $1 - HTTP状态码: $http_code" >> "$LOG_FILE"
    fi
    
    # 只有2xx和3xx状态码才算成功
    if [[ "$http_code" =~ ^[23][0-9]{2}$ ]]; then
        increment_counter "$TEMP_COUNT"
        add_bytes "$TEMP_BYTES" "${downloaded_bytes:-0}"
    fi
}

# 并发控制
wait_for_completion() {
    if (( running_jobs >= MAX_CONCURRENT )); then
        wait -n 2>/dev/null && ((running_jobs--)) || running_jobs=$(jobs -r | wc -l)
    fi
}

# 初始化文件
> "$LOG_FILE" 2>/dev/null || true
echo 0 > "$TEMP_COUNT" 2>/dev/null || true
echo 0 > "$TEMP_BYTES" 2>/dev/null || true

# 添加单个请求测试，用于诊断
echo "开始单次请求测试..."
single_test_result=$(curl -o /dev/null -s -w 'HTTP状态码: %{http_code}\n下载大小: %{size_download}字节\n错误信息: %{errormsg}\n' \
                     --max-time 30 --connect-timeout 10 \
                     "$URL" 2>&1)
echo "单次测试结果:"
echo "$single_test_result"
echo "$single_test_result" >> "$LOG_FILE"
echo "单次测试完成"
echo "=================================================="

# 主循环
echo "开始并发测试: 总次数=$NUMBER, 最大并发=$MAX_CONCURRENT"
echo "URL:        $URL"
echo "远程IP:     $REMOTE_IP"
echo "本地IP:     $LOCAL_IP"
echo "临时文件目录: $TEMP_DIR"
echo "=================================================="

while (( total_initiated < NUMBER )); do
    while (( running_jobs < MAX_CONCURRENT && total_initiated < NUMBER )); do
        ((total_initiated++))
        ((running_jobs++))
        run_request "$URL" &
        
        if (( total_initiated % 10 == 0 )); then
            completed=$(cat "$TEMP_COUNT" 2>/dev/null || echo 0)
            percentage=$((total_initiated * 100 / NUMBER))
            current_bytes=$(cat "$TEMP_BYTES" 2>/dev/null || echo 0)
            current_mb_frac=$(awk "BEGIN {printf \"%.2f\", $current_bytes / 1024 / 1024}")
            echo "进度: $total_initiated/$NUMBER (${percentage}%) | 成功=$completed | 流量: ${current_mb_frac}MB | 远程IP: $REMOTE_IP | 本地IP: $LOCAL_IP"
        fi
    done
    wait_for_completion
done

wait
running_jobs=0

# 结果统计
final_completed=$(cat "$TEMP_COUNT" 2>/dev/null || echo 0)
total_bytes=$(cat "$TEMP_BYTES" 2>/dev/null || echo 0)
end_time=$(date +%s)
total_seconds=$((end_time - start_time))
failed=$((NUMBER - final_completed))
avg_bytes=$(( final_completed > 0 ? total_bytes / final_completed : 0 ))

# 计算格式化值
calc_success_rate=$(awk "BEGIN {printf \"%.2f\", $final_completed * 100 / $NUMBER}")
calc_qps=$(awk "BEGIN {printf \"%.2f\", $final_completed / ${total_seconds:-1}}")
calc_bandwidth=$(awk "BEGIN {printf \"%.2f\", $total_bytes / ${total_seconds:-1} / 1024 / 1024}")
calc_total_mb=$(awk "BEGIN {printf \"%.2f\", $total_bytes / 1024 / 1024}")

# 输出结果
echo -e "\n==================== 测试完成 ===================="
echo "远程IP:     $REMOTE_IP"
echo "本地IP:     $LOCAL_IP"
echo "URL:        $URL"
echo "总请求数:   $NUMBER"
echo "成功请求:   $final_completed"
echo "失败请求:   $failed"
echo "成功率:     ${calc_success_rate}%"
echo "---------------------------------------------------"
echo "总流量:     ${calc_total_mb}MB"
echo "平均流量/请求: $avg_bytes 字节"
echo "带宽:       ${calc_bandwidth} MB/s"
echo "---------------------------------------------------"
echo "总耗时:     ${total_seconds}秒"
echo "平均QPS:    ${calc_qps}次/秒"
echo "=================================================="

# 显示详细错误日志
[[ -s "$LOG_FILE" ]] && { 
    echo -e "\n=== 详细错误日志 ==="
    cat "$LOG_FILE"
    echo "====================="
} || echo -e "\n无错误日志"

cleanup
echo -e "\n测试完成"
exit 0
