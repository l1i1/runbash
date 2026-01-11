#!/bin/bash
set -euo pipefail

# ================== 用户配置 ==================
N=32                         # 总请求数
CONC=16                       # 并发数
URL="https://tf.sysri.cn/HotPE/Releases/HotPE-V2.8.251018.exe"
FOLLOW="yes"                  # 跟随302跳转
C_TO=10; M_TO=30              # 连接/总超时(秒)

# ================== 初始化 ==================
[[ ${BASH_VERSINFO[0]} -lt 4 || (${BASH_VERSINFO[0]} -eq 4 && ${BASH_VERSINFO[1]} -lt 3) ]] && { echo "需 Bash 4.3+"; exit 1; }
DIR="/dev/shm"; [[ ! -w "$DIR" ]] && DIR="/tmp"
LOG="dl_$$.log"; C="${DIR}/c_$$"; B="${DIR}/b_$$"
trap "rm -f $LOG $C $B *.lock 2>/dev/null" EXIT

# ================== 获取IP ==================
L_IP=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')
P_IP=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || echo "?")
F_IP=$(curl -sIL -w '%{remote_ip}' -o /dev/null --max-time 5 "$URL" 2>/dev/null || echo "?")

# ================== 核心函数 ==================
inc() { (flock -x 200; echo $(($(<$1)+1)) >"$1") 200>"$1.lock"; }
add() { (flock -x 200; echo $(($(<$1)+$2)) >"$1") 200>"$1.lock"; }
fmt() { awk "BEGIN{u=\"B KB MB GB\"; b=$1; for(i=1;i<=4 && b>=1024;i++) b/=1024; printf \"%.2f %s\", b, u[i]}"; }

# ================== 启动测试 ==================
echo 0 >$C; echo 0 >$B
ARGS="--max-time $M_TO --connect-timeout $C_TO -sS"
[[ "$FOLLOW" == "yes" ]] && ARGS="$ARGS -L"
T=$(date +%s); R=0; K=0

echo "开始测试: N=$N, 并发=$CONC"
echo "网络: 本地=$L_IP, 公网=$P_IP, 目标IP=$F_IP(含302)"

# ================== 并发循环 ==================
while((K<N)); do
    while((R<CONC && K<N)); do
        (
            D=$(curl -o /dev/null -w '%{size_download}\n%{http_code}' $ARGS "$URL" 2>>$LOG)
            H=${D#*$'\n'}; S=${D%%$'\n'*}
            [[ "$H" =~ ^[23] ]] && { inc $C; add $B $S; }
        ) &
        ((K++)); ((R++))
    done
    ((R>=CONC)) && { wait -n 2>/dev/null || true; ((R--)); }
done
# ✅ 修复点：忽略后台任务的错误退出码，防止 set -e 终止脚本
wait || true

# ================== 结果输出 ==================
DT=$(($(date +%s)-T)); OK=$(<$C); BY=$(<$B); FL=$((N-OK))
echo -e "\n完成: 成功=$OK 失败=$FL"
echo "流量: $(fmt $BY) | 带宽: $(awk "BEGIN{printf \"%.2f MB/s\", $BY/DT/1024/1024}")"
echo "QPS: $(awk "BEGIN{printf \"%.2f\", $OK/DT}")"
[[ -s $LOG ]] && echo "错误:" && tail -3 $LOG
