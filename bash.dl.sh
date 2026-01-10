#!/bin/bash

# 修复版 URL 并发测试脚本 (使用 wget)
# 核心配置
NUMBER=160                # 总请求次数
URL="https://sc.sysri.cn/other/test/IMG20251108113913.jpg"  # 测试URL
MAX_CONCURRENT=8        # 最大并发数
LOG_FILE="download.log"   # 错误日志文件
TEMP_COUNT="/tmp/wget_test_count"  # 临时计数文件

# 初始化变量/文件
> "$LOG_FILE"             # 清空错误日志
echo 0 > "$TEMP_COUNT"    # 初始化计数文件
prev_percentage=0
count=0

# 单个请求执行函数（后台运行）
run_request() {
    local url=$1
    # wget 静默请求，错误写入日志
    if wget -q -O /dev/null --no-cache "$url" 2>> "$LOG_FILE"; then
        # 原子操作更新计数（避免并发写入冲突）
        echo $(( $(cat "$TEMP_COUNT") + 1 )) > "$TEMP_COUNT"
    fi
}

# 主测试逻辑
echo "开始并发测试: 总次数=$NUMBER, 最大并发=$MAX_CONCURRENT"
for ((i=0; i<NUMBER; i++)); do
    # 启动后台请求
    run_request "$URL" &
    
    # 控制并发数：达到上限时等待任意一个完成
    while (( $(jobs -r | wc -l) >= MAX_CONCURRENT )); do
        wait -n
    done

    # 读取实时完成数并显示进度
    completed=$(cat "$TEMP_COUNT")
    percentage=$((completed * 100 / NUMBER))
    if (( percentage > prev_percentage && count < 100 )); then
        echo "进度: $completed/$NUMBER ($percentage%)"
        prev_percentage=$percentage
        ((count++))
    fi
done

# 等待所有剩余后台进程完成
wait
# 读取最终完成数
final_completed=$(cat "$TEMP_COUNT")
echo -e "\n测试完成！最终进度: $final_completed/$NUMBER (100%)"

# 显示错误日志（如果有错误）
if [[ -s "$LOG_FILE" ]]; then
    echo -e "\n错误日志内容:"
    cat "$LOG_FILE"
else
    echo -e "\n无错误发生！"
fi

# 清理临时文件
rm -f "$TEMP_COUNT"
