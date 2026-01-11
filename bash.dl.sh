#!/bin/bash

# URL 并发测试脚本
# 核心配置
NUMBER=3200                # 总请求次数
MAX_CONCURRENT=16        # 最大并发数
URL="https://sc.sysri.cn/_def/other/test/IMG20251108113913.jpg?origpic"  # 测试URL

LOG_FILE="download.log"   # 错误日志文件
TEMP_COUNT="/tmp/wget_test_count"  # 临时计数文件
LOCK_FILE="/tmp/wget_test.lock"    # 锁文件（新增）

# 初始化计时
start_time=$(date +%s)
# 初始化变量/文件
> "$LOG_FILE"             # 清空错误日志
echo 0 > "$TEMP_COUNT"    # 初始化计数文件
prev_percentage=0
count=0

# 安全递增计数函数（使用文件锁避免竞争条件）
increment_counter() {
    local count_file="$1"
    # 使用文件锁确保原子操作
    (
        flock -x 200
        current=$(cat "$count_file")
        echo $((current + 1)) > "$count_file"
    ) 200>"${count_file}.lock"
}

# 单个请求执行函数
run_request() {
    local url=$1
    # 添加超时和重试参数，避免挂起
    if wget -q -O /dev/null --timeout=30 --tries=1 --no-cache "$url" 2>> "$LOG_FILE"; then
        increment_counter "$TEMP_COUNT"
    fi
}

# 主测试逻辑
echo "开始并发测试: 总次数=$NUMBER, 最大并发=$MAX_CONCURRENT"
echo "URL: $URL"
echo "=================================================="

for ((i=1; i<=NUMBER; i++)); do
    # 启动后台请求
    run_request "$URL" &
    
    # 控制并发数
    while (( $(jobs -r | wc -l) >= MAX_CONCURRENT )); do
        wait -n 2>/dev/null || true  # 忽略子进程退出状态
    done

    # 显示进度（每5%或每完成100次显示一次）
    completed=$(cat "$TEMP_COUNT")
    percentage=$((completed * 100 / NUMBER))
    if (( i % 100 == 0 || percentage > prev_percentage + 4 )); then
        if (( percentage != prev_percentage )); then
            echo "进度: $completed/$NUMBER (${percentage}%)"
            prev_percentage=$percentage
        fi
    fi
done

# 等待所有剩余后台进程完成
wait

# 读取最终完成数
final_completed=$(cat "$TEMP_COUNT")

# 计算结束时间和总耗时
end_time=$(date +%s)
total_seconds=$((end_time - start_time))

# 计算失败数和失败率
failed=$((NUMBER - final_completed))
if (( NUMBER > 0 )); then
    # 使用printf进行浮点数计算，避免依赖bc
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

# 输出最终结果
echo -e "\n==================== 测试完成 ===================="
echo "总请求数:         $NUMBER"
echo "最大并发数:       $MAX_CONCURRENT"
echo "成功请求数:       $final_completed"
echo "失败请求数:       $failed"
echo "成功率:           ${success_rate}%"
echo "失败率:           ${fail_rate}%"
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
rm -f "$TEMP_COUNT" "${TEMP_COUNT}.lock"
