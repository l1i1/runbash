#!/bin/bash

# 简化版 URL 并发测试脚本 (使用 wget)
# 核心配置
NUMBER=100                # 总请求次数
URL="https://sc.sysri.cn/other/test/IMG20251108113913.jpg"  # 测试URL
MAX_CONCURRENT=100        # 最大并发数
LOG_FILE="download.log"   # 错误日志文件

# 初始化变量
completed=0
prev_percentage=0
count=0

# 清空旧日志
> "$LOG_FILE"

# 并发执行函数
run_request() {
    local url=$1
    # 使用wget静默下载，输出到空设备，仅记录错误
    wget -q -O /dev/null --no-cache "$url" 2>> "$LOG_FILE"
    # 原子操作更新完成数（避免并发冲突）
    ((completed++))
}

# 主测试逻辑
echo "开始并发测试: 总次数=$NUMBER, 最大并发=$MAX_CONCURRENT"
for ((i=0; i<NUMBER; i++)); do
    # 启动后台请求
    run_request "$URL" &
    
    # 控制并发数：当后台进程数达到上限时，等待任意一个完成
    while (( $(jobs -r | wc -l) >= MAX_CONCURRENT )); do
        wait -n
    done

    # 进度显示（仅整数百分比变化时输出）
    percentage=$((completed * 100 / NUMBER))
    if (( percentage > prev_percentage && count < 100 )); then
        echo "进度: $completed/$NUMBER ($percentage%)"
        prev_percentage=$percentage
        ((count++))
    fi
done

# 等待所有剩余后台进程完成
wait
echo -e "\n测试完成！最终进度: $completed/$NUMBER (100%)"

# 显示错误日志（如果有错误）
if [[ -s "$LOG_FILE" ]]; then
    echo -e "\n错误日志内容:"
    cat "$LOG_FILE"
else
    echo -e "\n无错误发生！"
fi
