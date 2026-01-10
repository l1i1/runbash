#!/bin/bash

# URL 并发测试

NUMBER=100  # 下载次数
URL="https://sc.sysri.cn/other/test/IMG20251108113913.jpg"  # 替换为实际的 URL
MAX_CONCURRENT=100  # 最大并行下载数量
isParallel=true    # 并行执行标志，默认为 true
aria2Arg="--allow-overwrite=true --file-allocation=none --disk-cache=0"
isLargeFile=false  # 根据需要设置为 true 或 false

declare -a jobs  # 用于跟踪后台作业的数组
count=0  # 用于记录输出的百分比数量

# 并行下载函数
parallel_download() {
    local job_count=0
    local completed=0
    for url in "$@"; do
        if [[ "$isLargeFile" == "true" ]]; then
            aria2c -s 32 -x 16 -d "/dev" -o "null" "$url" $aria2Arg > "/dev/null" 2>&1 &
            if [ $? -eq 0 ]; then
                ((completed++))
            else
                echo "Aria2c download failed for $url" >> download.log
            fi
        else
            curl -fsSL "$url" > "/dev/null" 2>&1 &
            if [ $? -eq 0 ]; then
                ((completed++))
            else
                echo "Curl download failed for $url" >> download.log
            fi
        fi
        ((job_count++))
        if [[ "$job_count" -ge "$MAX_CONCURRENT" ]]; then
            wait -n
            jobs=($(jobs -r))  # 更新 jobs 数组，移除已完成的作业
            job_count=0
        fi
        # 计算百分比
        percentage=$((completed * 100 / NUMBER))
        # 只有在百分比整数变化且输出数量未超过 100 时才输出
        if [[ $((percentage * 100)) -gt $((prev_percentage * 100)) && $count -lt 100 ]]; then
            echo "Progress: $completed / $NUMBER ($percentage%)"
            ((count++))
            prev_percentage=$percentage
        fi
    done
    if [[ "$job_count" -gt 0 ]]; then
        wait
    fi
}

# 根据 number 字段的值，循环运行下载操作
prev_percentage=0
for ((i=0; i<NUMBER; i++)); do
    if [[ "$isParallel" == "true" ]]; then
        parallel_download "$URL"
    else
        if [[ "$isLargeFile" == "true" ]]; then
            aria2c -s 32 -x 16 -d "/dev" -o "null" "$URL" $aria2Arg > "/dev/null" 2>&1
            if [ $? -eq 0 ]; then
                ((completed++))
            else
                echo "Aria2c sequential download failed" >> download.log
            fi
        else
            curl -fsSL "$URL" > "/dev/null" 2>&1
            if [ $? -eq 0 ]; then
                ((completed++))
            else
                echo "Curl sequential download failed" >> download.log
            fi
        fi
        # 计算百分比
        percentage=$((completed * 100 / NUMBER))
        # 只有在百分比整数变化且输出数量未超过 100 时才输出
        if [[ $((percentage * 100)) -gt $((prev_percentage * 100)) && $count -lt 100 ]]; then
            echo "Progress: $completed / $NUMBER ($percentage%)"
            ((count++))
            prev_percentage=$percentage
        fi
    fi
done

# 如果是并行执行，等待所有后台作业完成
if [[ "$isParallel" == "true" ]]; then
    wait
    echo "All downloads have finished."
fi

# 打印 download.log 的内容
if [ -f "download.log" ]; then
    cat download.log
fi
