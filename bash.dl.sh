#!/bin/bash

# URL 并发测试脚本
# 核心配置
NUMBER=3200                # 总请求次数
MAX_CONCURRENT=16          # 最大并发数
URL="https://sc.sysri.cn/_def/other/test/IMG20251108113913.jpg?origpic"  # 测试URL

LOG_FILE="download.log"    # 错误日志文件
TEMP_COUNT="/tmp/curl_test_count"  # 临时计数文件
TEMP_BYTES="/tmp/curl_test_bytes"  # 流量统计文件
LOCK_FILE="/tmp/curl_test.lock"    # 锁文件

# 初始化计时
start_time=$(date +%s)
# 初始化变量/文件
> "$LOG_FILE"             # 清空错误日志
echo 0 > "$TEMP_COUNT"    # 初始化计数文件
echo 0 > "$TEMP_BYTES"    # 初始化流量统计文件
prev_percentage=0

# 检查 curl 是否安装
if ! command -v curl &> /dev/null; then
    echo "错误: 未找到 curl 命令，请先安装。"
    exit 1
fi

# 安全递增计数函数
increment_counter() {
    local count_file="$1"
    (
        flock -x 200
        current=$(cat "$count_file")
        echo $((current + 1)) > "$count_file"
    ) 200>"${count_file}.lock"
}

# 安全累加流量函数
add_bytes() {
    local bytes_file="$1"
    local bytes_to_add="$2"
    # 确保是纯数字
    bytes_to_add=${bytes_to_add//[^0-9]/}
    
    (
        flock -x 200
        current=$(cat "$bytes_file" 2>/dev/null || echo 0)
        current=${current//[^0-9]/}
        echo $((current + bytes_to_add)) > "$bytes_file"
    ) 200>"${bytes_file}.lock"
}

# 格式化流量显示 (修复了浮点数判断错误的版本)
format_bytes() {
    local bytes=$1
    local units=('B' 'KB' 'MB' 'GB' 'TB')
    local unit=0
    local display_val=$bytes
    
    # 使用整数进行循环判断，避免浮点数报错
    while (( bytes >= 1024 && unit < ${#units[@]} - 1 )); do
        # 计算显示用的浮点数值
        display_val=$(awk "BEGIN {printf \"%.2f\", $bytes / 1024}")
        # 更新 bytes 用于下一次整数判断
        bytes=$((bytes / 1024))
        ((unit++))
    done
    
    echo "${display_val} ${units[$unit]}"
}

# 核心修改：使用 Curl 的单个请求执行函数
run_request() {
    local url=$1
    local output_info
    local http_code
    local downloaded_bytes

    # 使用 curl 获取数据：
    # -o /dev/null    : 丢弃内容，不写磁盘（消除 I/O 瓶颈）
    # -s              : 静默模式，不显示进度条
    # -w              : 自定义输出格式
    # %{size_download}: 下载的字节数
    # %{http_code}    : HTTP 状态码
    # --max-time 30   : 最长等待时间
    # 2>> "$LOG_FILE" : 将错误信息重定向到日志
    
    output_info=$(curl -o /dev/null -s -w '%{size_download}\n%{http_code}' \
                  --max-time 30 --connect-timeout 10 "$url" 2>> "$LOG_FILE")

    # 解析输出 (第一行是字节数，第二行是状态码)
    downloaded_bytes=$(echo "$output_info" | head -n1)
    http_code=$(echo "$output_info" | tail -n1)

    # 判断逻辑: 
    # 1. http_code 必须是数字
    # 2. 状态码在 200-399 之间视为成功
    if [[ "$http_code" =~ ^[0-9]+$ ]] && (( http_code >= 200 && http_code < 400 )); then
        increment_counter "$TEMP_COUNT"
        # 累加流量
        add_bytes "$TEMP_BYTES" "$downloaded_bytes"
    fi
}

# 主测试逻辑
echo "开始并发测试: 总次数=$NUMBER, 最大并发=$MAX_CONCURRENT"
echo "=================================================="

for ((i=1; i<=NUMBER; i++)); do
    # 启动后台请求
    run_request "$URL" &
    
    # 控制并发数
    while (( $(jobs -r | wc -l) >= MAX_CONCURRENT )); do
        wait -n 2>/dev/null || true
    done

    # 显示进度
    completed=$(cat "$TEMP_COUNT")
    percentage=$((completed * 100 / NUMBER))
    if (( i % 100 == 0 || percentage > prev_percentage + 4 )); then
        if (( percentage != prev_percentage )); then
            current_bytes=$(cat "$TEMP_BYTES")
            current_flow=$(format_bytes "$current_bytes")
            echo "进度: $completed/$NUMBER (${percentage}%) | 已下载流量: $current_flow"
            prev_percentage=$percentage
        fi
    fi
done

# 等待所有剩余后台进程完成
wait

# 读取最终完成数和总流量
final_completed=$(cat "$TEMP_COUNT")
total_bytes=$(cat "$TEMP_BYTES"))

# 计算结束时间和总耗时
end_time=$(date +%s)
total_seconds=$((end_time - start_time))

# 计算失败数和失败率
failed=$((NUMBER - final_completed))
if (( NUMBER > 0 )); then
    success_rate=$(awk "BEGIN {printf \"%.2f\", $final_completed / $NUMBER * 100}")
    fail_rate=$(awk "BEGIN {printf \"%.2f\", $failed / $NUMBER * 100}")
else
    success_rate=0.00
    fail_rate=0.00
fi

# 计算平均QPS
if (( total_seconds > 0 )); then
    qps=$(awk "BEGIN {printf \"%.2f\", $final_completed / $total_seconds}")
else
    qps=0.00
fi

# 计算平均流量/请求
if (( final_completed > 0 )); then
    avg_bytes=$(awk "BEGIN {printf \"%.0f\", $total_bytes / $final_completed}")
else
    avg_bytes=0
fi

# 计算平均带宽 (MB/s)
if (( total_seconds > 0 )); then
    avg_bandwidth=$(awk "BEGIN {printf \"%.2f\", $total_bytes / $total_seconds / 1024 / 1024}")
else
    avg_bandwidth=0.00
fi

# 格式化流量显示
formatted_total_bytes=$(format_bytes "$total_bytes")
formatted_avg_bytes=$(format_bytes "$avg_bytes")

# 输出最终结果
echo -e "\n==================== 测试完成 ===================="
echo "总请求数:         $NUMBER"
echo "最大并发数:       $MAX_CONCURRENT"
echo "成功请求数:       $final_completed"
echo "失败请求数:       $failed"
echo "成功率:           ${success_rate}%"
echo "失败率:           ${fail_rate}%"
echo "---------------------------------------------------"
echo "总网络流量:       $formatted_total_bytes ($total_bytes 字节)"
echo "平均流量/请求:    $formatted_avg_bytes/请求"
echo "真实带宽:         ${avg_bandwidth} MB/s"
echo "---------------------------------------------------"
echo "总耗时:           ${total_seconds}秒"
echo "平均QPS:          ${qps}次/秒"
echo "=================================================="

# 显示错误日志
if [[ -s "$LOG_FILE" ]]; then
    echo -e "\n错误日志内容 (最后20行):"
    tail -n 20 "$LOG_FILE"
    echo -e "完整日志请查看: $LOG_FILE"
else
    echo -e "\n无错误发生！"
fi

# 清理临时文件
rm -f "$TEMP_COUNT" "${TEMP_COUNT}.lock" "$TEMP_BYTES" "${TEMP_BYTES}.lock"
