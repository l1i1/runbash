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
NUMBER=320000
MAX_CONCURRENT=32
URL="https://www.8uid.com/wp-content/uploads/2024/06/20240630005115267-%E9%9A%90%E7%A7%81%E6%94%BF%E7%AD%96.png"
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

# 获取远程服务器IP（目标URL解析后的IP）
get_remote_ip() {
    local ip=""
    ip=$(curl -o /dev/null -s -w '%{remote_ip}' \
              --max-time 10 --connect-timeout 5 \
              "$URL" 2>> "$LOG_FILE")
    echo "${ip:-未知}"
}

# 获取本机出口IP（公网IP）
get_local_ip() {
    local ip=""
    # 优先尝试 ifconfig.me，失败可换成 icanhazip.com 等服务
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

# 请求执行
run_request() {
    local output_info downloaded_bytes http_code
    output_info=$(curl -o /dev/null -s -w '%{size_download}\n%{http_code}' \
                  --max-time 30 --connect-timeout 10 \
                  --retry 1 --retry-delay 1 \
                  "$1" 2>> "$LOG_FILE")
    IFS=$'\n' read -r downloaded_bytes http_code <<< "$output_info"
    [[ "$http_code" =~ ^[23][0-9]{2}$ ]] && { increment_counter "$TEMP_COUNT"; add_bytes "$TEMP_BYTES" "$downloaded_bytes"; }
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
        
        if (( total_initiated % 100 == 0 )); then
            completed=$(cat "$TEMP_COUNT" 2>/dev/null || echo 0)
            percentage=$((total_initiated * 100 / NUMBER))
            if (( percentage > prev_percentage + 4 )); then
                current_bytes=$(cat "$TEMP_BYTES" 2>/dev/null || echo 0)
                current_mb=$((current_bytes / 1024 / 1024))
                current_mb_frac=$(awk "BEGIN {printf \"%.2f\", $current_bytes / 1024 / 1024}")
                echo "进度: $total_initiated/$NUMBER (${percentage}%) | 成功=$completed | 流量: ${current_mb_frac}MB | 远程IP: $REMOTE_IP | 本地IP: $LOCAL_IP"
                prev_percentage=$percentage
            fi
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

# 计算格式化值（避免嵌套引号问题）
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

[[ -s "$LOG_FILE" ]] && { echo -e "\n错误日志最后20行:"; tail -n 20 "$LOG_FILE"; } || echo -e "\n无错误发生"

cleanup
echo -e "\n测试完成"
exit 0
