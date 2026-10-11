#!/bin/sh
# netopt 自包含一键安装 (无需再从网络下载其它文件)
# 用法: wget -O /tmp/ia.sh <本文件地址> && sh /tmp/ia.sh
[ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }

echo "[install] 写入 /usr/bin/netopt.sh"
cat > /usr/bin/netopt.sh <<'__NETOPT_SH__'
#!/bin/sh
# netopt.sh - OpenWrt 一键网络优化 v5
# 直连/代理测速(3次取最好) -> 自动算参数 -> 系统调优
# 每台设备单独上下行额度 / 一键平均分配 / 封禁联网 / 每设备统计
# 适用: OpenWrt (ash / busybox sh), 兼容 opkg(旧) 与 apk(新) 包管理器
#
# 安装依赖:
#   netopt.sh deps        # 自动识别 opkg/apk 并安装 (tc ip-full ipset kmod-ifb ...)
#   (手动) 新系统: apk update && apk add tc ip-full ipset kmod-ifb kmod-sched-cake kmod-sched-core kmod-tcp-bbr curl
#   (手动) 旧系统: opkg update && opkg install tc ip-full ipset kmod-ifb kmod-sched-cake kmod-sched-core kmod-tcp-bbr curl
#   scp netopt.sh root@<路由器>:/usr/bin/netopt.sh && chmod +x /usr/bin/netopt.sh
#
# 命令:
#   netopt.sh            菜单
#   netopt.sh before     直连测速(开代理前)
#   netopt.sh after      代理测速 + 自动优化
#   netopt.sh avg        一键平均分配上下行(按设备数)
#   netopt.sh list       列出设备额度(供 LuCI)
#   netopt.sh set-limit <ip> <上行kbit> <下行kbit>
#   netopt.sh set-block <ip> 0|1     封禁/解封联网
#   netopt.sh set-conn <ip> <TCP> [UDP]  该设备 TCP/UDP 最大连接数(0=不限)
#   netopt.sh conn <TCP> [UDP]           全局每台 TCP/UDP 上限
#   netopt.sh oneclick   一键: 装依赖+自检+直连测速+代理测速+优化+开机自启
#   netopt.sh live       每台设备 TCP/UDP 连接数 + 上下行速率 + 累计用量
#   netopt.sh apply / stats / remove / boot-enable / boot-disable / deps / check

CONF="/etc/netopt.conf"
BASE="/etc/netopt.baseline"
PROXY="/etc/netopt.proxied"
CLASSES="/etc/netopt.classes"
CLASSES_DL="/etc/netopt.classes.dl"
DEVICES="/etc/netopt.devices"
IFB_UP="ifb-up"
IFB_DL="ifb-dl"
IPSET="netopt_hosts"
DEFAULT_UP=38
MODE_DEFAULT="htb"
TEST_ROUNDS=3
TARGET_URL="https://speed.cloudflare.com"

log(){ echo "[netopt] $*"; }
die(){ echo "[netopt] 错误: $*" >&2; exit 1; }
[ "$(id -u)" = "0" ] || die "请用 root 运行"

mod_probe(){ modprobe "$1" 2>/dev/null || kmodloader "$1" 2>/dev/null || true; }

load_mods(){
  for m in ifb sch_ingress sch_cake sch_htb act_mirred cls_u32 ip_set ip_set_hash_ip em_ipset tcp_bbr; do mod_probe "$m"; done
  { lsmod 2>/dev/null | grep -q '^ifb' || [ -d /sys/module/ifb ]; } || die "ifb 不可用, 先运行: netopt.sh deps"
  { lsmod 2>/dev/null | grep -q 'sch_cake' || [ -d /sys/module/sch_cake ]; } || die "cake 不可用, 先运行: netopt.sh deps"
}

deps(){
  pkgs="tc ip-full ipset kmod-ifb kmod-sched-cake kmod-sched-core kmod-tcp-bbr curl"
  if command -v apk >/dev/null 2>&1; then
    log "包管理器: apk (新版 OpenWrt)"; apk update && apk add $pkgs
  elif command -v opkg >/dev/null 2>&1; then
    log "包管理器: opkg (旧版 OpenWrt)"; opkg update && opkg install $pkgs
  else die "未找到 apk/opkg"; fi
}

detect_lan(){
  [ -d /sys/class/net/br-lan ] && { echo br-lan; return; }
  for i in $(ls /sys/class/net 2>/dev/null); do
    case "$i" in lo|ifb*|tun*|utun*|wg*|docker*|veth*|ppp*|br-*) continue;; esac
    ip -4 addr show dev "$i" 2>/dev/null | grep -qE 'inet (192\.168|10\.|172\.(1[6-9]|2[0-9]|3[01]))\.' && { echo "$i"; return; }
  done
}
detect_wan(){ ip route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }

list_hosts(){
  lan="$1"
  self=$(ip -4 addr show dev "$lan" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)
  { ip neigh show dev "$lan" 2>/dev/null | awk '/REACHABLE|STALE|DELAY|PROBE/{print $1}'
    [ -f /tmp/dhcp.leases ] && awk '{print $3}' /tmp/dhcp.leases
  } | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u | grep -vx "$self"
}

# ---------- 设备额度文件: "ip up_kbit down_kbit block tcp udp" ----------
dev_line(){ [ -f "$DEVICES" ] && awk -v ip="$1" '$1==ip{print; exit}' "$DEVICES"; }
dev_up(){ dev_line "$1" | awk '{print $2}'; }
dev_dl(){ dev_line "$1" | awk '{print $3}'; }
dev_blk(){ dev_line "$1" | awk '{print $4}'; }
dev_tcp(){ dev_line "$1" | awk '{print $5}'; }
dev_udp(){ dev_line "$1" | awk '{print $6}'; }
dev_set(){
  ip="$1"; u="$2"; d="$3"; b="$4"; t="$5"; q="$6"; tmp=/tmp/netopt.dev.tmp; : > "$tmp"
  [ -f "$DEVICES" ] && awk -v ip="$ip" '$1!=ip' "$DEVICES" >> "$tmp"
  echo "$ip $u $d $b $t $q" >> "$tmp"
  mv "$tmp" "$DEVICES"
}
set_limit(){ ip="$1"; u="$2"; d="$3"; b=$(dev_blk "$ip"); t=$(dev_tcp "$ip"); q=$(dev_udp "$ip"); [ -n "$b" ] || b=0; [ -n "$t" ] || t=0; [ -n "$q" ] || q=0; dev_set "$ip" "$u" "$d" "$b" "$t" "$q"; }
set_block(){ ip="$1"; blk="$2"; u=$(dev_up "$ip"); d=$(dev_dl "$ip"); t=$(dev_tcp "$ip"); q=$(dev_udp "$ip"); [ -n "$u" ] || u=0; [ -n "$d" ] || d=0; [ -n "$t" ] || t=0; [ -n "$q" ] || q=0; dev_set "$ip" "$u" "$d" "$blk" "$t" "$q"; }
set_conn(){ ip="$1"; t="$2"; q="$3"; u=$(dev_up "$ip"); d=$(dev_dl "$ip"); b=$(dev_blk "$ip"); [ -n "$u" ] || u=0; [ -n "$d" ] || d=0; [ -n "$b" ] || b=0; [ -n "$t" ] || t=0; [ -n "$q" ] || q=0; dev_set "$ip" "$u" "$d" "$b" "$t" "$q"; }
eff_tcp(){ c=$(dev_tcp "$1"); if [ -n "$c" ] && [ "$c" -gt 0 ] 2>/dev/null; then echo "$c"; return; fi; g=$(cf CONNLIMIT_TCP); if [ -n "$g" ] && [ "$g" -gt 0 ] 2>/dev/null; then echo "$g"; else echo 0; fi; }
eff_udp(){ c=$(dev_udp "$1"); if [ -n "$c" ] && [ "$c" -gt 0 ] 2>/dev/null; then echo "$c"; return; fi; g=$(cf CONNLIMIT_UDP); if [ -n "$g" ] && [ "$g" -gt 0 ] 2>/dev/null; then echo "$g"; else echo 0; fi; }

cf(){ [ -f "$CONF" ] && sed -n "s/^$1=\"\(.*\)\"$/\1/p" "$CONF"; }
kv(){ [ -f "$1" ] && sed -n "s/^$2=\(.*\)$/\1/p" "$1"; }
total_up(){ t=$(cf UPLOAD); [ -n "$t" ] || { b=$(kv "$BASE" UP); [ -n "$b" ] && t=$((b * 9 / 10)); }; [ -n "$t" ] || t=$DEFAULT_UP; echo "$t"; }
total_dl(){ t=$(cf DOWNLOAD); [ -n "$t" ] || { b=$(kv "$BASE" DOWN); [ -n "$b" ] && t=$((b * 9 / 10)); }; echo "$t"; }
get_mode(){ m=$(cf MODE); [ -n "$m" ] || m="$MODE_DEFAULT"; echo "$m"; }

# ---------- 测速 ----------
measure_best(){
  command -v curl >/dev/null 2>&1 || die "缺少 curl, 先运行: netopt.sh deps"
  bu=0; bd=0; r=1
  while [ "$r" -le "$TEST_ROUNDS" ]; do
    d=$(curl -s -o /dev/null -w '%{speed_download}' "$TARGET_URL/__down?bytes=15000000" 2>/dev/null)
    dd if=/dev/zero of=/tmp/netopt.up bs=1M count=6 2>/dev/null
    u=$(curl -s -o /dev/null -X POST --data-binary @/tmp/netopt.up -w '%{speed_upload}' "$TARGET_URL/__up" 2>/dev/null)
    rm -f /tmp/netopt.up
    d=${d%.*}; u=${u%.*}; [ -n "$d" ] || d=0; [ -n "$u" ] || u=0
    um=$((u * 8 / 1000000)); dm=$((d * 8 / 1000000))
    log "  第${r}/${TEST_ROUNDS}次: 上传 ${um}M / 下载 ${dm}M"
    [ "$um" -gt "$bu" ] && bu=$um
    [ "$dm" -gt "$bd" ] && bd=$dm
    r=$((r + 1))
  done
  log "  取最好: 上传 ${bu}M / 下载 ${bd}M"
  echo "$bu $bd"
}
save_kv(){ printf 'UP=%s\nDOWN=%s\n' "$2" "$3" > "$1"; }

ipset_init(){ command -v ipset >/dev/null 2>&1 || return 1; ipset destroy "$IPSET" 2>/dev/null; ipset create "$IPSET" hash:ip 2>/dev/null || ipset flush "$IPSET" 2>/dev/null; }
ipset_fill(){ for ip in $(list_hosts "$1"); do ipset add "$IPSET" "$ip" 2>/dev/null; done; }

tune(){
  log "系统调优: BBR + fq"
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    grep -q '^net.core.default_qdisc=' /etc/sysctl.conf 2>/dev/null || echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
    grep -q '^net.ipv4.tcp_congestion_control=' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    log "  congestion = $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  else log "  未找到 bbr, 跳过"; fi
  cur=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)
  if [ -n "$cur" ] && [ "$cur" -lt 65536 ]; then
    grep -q '^net.netfilter.nf_conntrack_max=' /etc/sysctl.conf 2>/dev/null || echo 'net.netfilter.nf_conntrack_max=131072' >> /etc/sysctl.conf
    sysctl -w net.netfilter.nf_conntrack_max=131072 >/dev/null 2>&1
    log "  conntrack_max: $cur -> 131072"
  fi
}

# ---------- 限速实现 ----------
mirror_lan(){
  lan="$1"
  ip link add "$IFB_UP" type ifb 2>/dev/null || true
  ip link set "$IFB_UP" up
  tc qdisc add dev "$lan" ingress 2>/dev/null || true
  tc filter add dev "$lan" parent ffff: protocol all prio 1 u32 \
    match u32 0 0 action mirred egress redirect dev "$IFB_UP"
}

apply_up_cake(){ mirror_lan "$1"; tc qdisc add dev "$IFB_UP" root cake bandwidth "$2mbit" dual-srchost nat; : > "$CLASSES"; }

# 上传: br-lan ingress -> ifb, 每台一台 class (rate=ceil=额度)
apply_up_htb(){
  lan="$1"; up="$2"
  mirror_lan "$lan"; ipset_init; ipset_fill "$lan"
  tc qdisc add dev "$IFB_UP" root handle 1: htb default 9999
  tc class add dev "$IFB_UP" parent 1: classid 1:1 htb rate "${up}mbit"
  : > "$CLASSES"
  hosts=$(list_hosts "$lan"); n=$(echo "$hosts" | grep -c .); [ "$n" -lt 1 ] && n=1
  defq=$(( up * 1000 / n )); [ "$defq" -lt 64 ] && defq=64
  i=10
  for ip in $hosts; do
    q=$(dev_up "$ip"); [ -n "$q" ] || q=$defq; [ "$q" -le 0 ] 2>/dev/null && q=$defq
    tc class add dev "$IFB_UP" parent 1:1 classid 1:$i htb rate "${q}kbit" ceil "${q}kbit" 2>/dev/null
    tc filter add dev "$IFB_UP" protocol ip parent 1: prio 1 u32 match ip src "$ip/32" flowid 1:$i
    echo "$ip $i" >> "$CLASSES"
    i=$((i + 1))
  done
  tc class add dev "$IFB_UP" parent 1:1 classid 1:9999 htb rate "${defq}kbit" ceil "${defq}kbit"
  log "  上传 HTB: ${n} 台, 每台按各自额度"
}

# 下载: br-lan egress (dst=设备IP) 每台一台 class
apply_dl_htb(){
  lan="$1"; down="$2"
  tc qdisc del dev "$lan" root 2>/dev/null
  tc qdisc add dev "$lan" root handle 2: htb default 9999
  tc class add dev "$lan" parent 2: classid 2:1 htb rate "${down}mbit"
  : > "$CLASSES_DL"
  hosts=$(list_hosts "$lan"); n=$(echo "$hosts" | grep -c .); [ "$n" -lt 1 ] && n=1
  defd=$(( down * 1000 / n )); [ "$defd" -lt 64 ] && defd=64
  i=10
  for ip in $hosts; do
    q=$(dev_dl "$ip"); [ -n "$q" ] || q=$defd; [ "$q" -le 0 ] 2>/dev/null && q=$defd
    tc class add dev "$lan" parent 2:1 classid 2:$i htb rate "${q}kbit" ceil "${q}kbit" 2>/dev/null
    tc filter add dev "$lan" protocol ip parent 2: prio 1 u32 match ip dst "$ip/32" flowid 2:$i
    echo "$ip $i" >> "$CLASSES_DL"
    i=$((i + 1))
  done
  tc class add dev "$lan" parent 2:1 classid 2:9999 htb rate "${defd}kbit" ceil "${defd}kbit"
  log "  下载 HTB: ${n} 台, 每台按各自额度"
}

apply_dl_cake(){
  wan="$1"; down="$2"
  ip link add "$IFB_DL" type ifb 2>/dev/null || true
  ip link set "$IFB_DL" up
  tc qdisc add dev "$wan" ingress 2>/dev/null || true
  tc filter add dev "$wan" parent ffff: protocol all prio 1 u32 match u32 0 0 action mirred egress redirect dev "$IFB_DL"
  tc qdisc add dev "$IFB_DL" root cake bandwidth "${down}mbit" dual-dsthost nat
}

# 封禁联网: 上传侧丢 src, 下载侧丢 dst
apply_blocks(){
  lan="$1"
  [ -f "$DEVICES" ] || return
  while read -r ip u d b; do
    [ "$b" = "1" ] || continue
    tc filter add dev "$lan" parent ffff: protocol ip prio 0 u32 match ip src "$ip/32" action drop 2>/dev/null
    tc filter add dev "$lan" parent 2: protocol ip prio 0 u32 match ip dst "$ip/32" action drop 2>/dev/null
  done < "$DEVICES"
}

# 连接数限制 (nftables ct count, 每台独立 forward 规则)
apply_conn(){
  command -v nft >/dev/null 2>&1 || { log "  (无 nft, 跳过连接数限制)"; return; }
  nft delete table inet netopt 2>/dev/null
  [ -f "$DEVICES" ] || return
  any=0
  while read -r ip u d b t q; do
    lt=$(eff_tcp "$ip"); lu=$(eff_udp "$ip")
    { [ "$lt" -gt 0 ] 2>/dev/null || [ "$lu" -gt 0 ] 2>/dev/null; } && any=1
  done < "$DEVICES"
  [ "$any" = "1" ] || return
  nft add table inet netopt
  nft add chain inet netopt fwd '{ type filter hook forward priority 0; policy accept; }'
  while read -r ip u d b t q; do
    lt=$(eff_tcp "$ip"); lu=$(eff_udp "$ip")
    if [ "$lt" -gt 0 ] 2>/dev/null; then
      nft add rule inet netopt fwd ip saddr "$ip" meta l4proto tcp ct count over "$lt" counter drop 2>/dev/null
      log "  连接数限制: $ip TCP 最多 ${lt} 条"
    fi
    if [ "$lu" -gt 0 ] 2>/dev/null; then
      nft add rule inet netopt fwd ip saddr "$ip" meta l4proto udp ct count over "$lu" counter drop 2>/dev/null
      log "  连接数限制: $ip UDP 最多 ${lu} 条"
    fi
  done < "$DEVICES"
}

clear_shaping(){
  for ifb in "$IFB_UP" "$IFB_DL"; do
    tc qdisc del dev "$ifb" root 2>/dev/null
    ip link del "$ifb" 2>/dev/null
  done
  lan=$(detect_lan); wan=$(detect_wan)
  [ -n "$lan" ] && { tc qdisc del dev "$lan" ingress 2>/dev/null; tc qdisc del dev "$lan" root 2>/dev/null; }
  [ -n "$wan" ] && tc qdisc del dev "$wan" ingress 2>/dev/null
  command -v ipset >/dev/null 2>&1 && ipset destroy "$IPSET" 2>/dev/null
  command -v nft >/dev/null 2>&1 && nft delete table inet netopt 2>/dev/null
}

apply(){
  up="$1"; down="$2"; mode=$(get_mode)
  if [ -z "$up" ]; then up=$(total_up); fi
  [ -n "$down" ] || down=$(total_dl)
  lang=$(detect_lan); [ -n "$lang" ] || die "未找到 LAN 接口"
  load_mods; clear_shaping
  log "应用: LAN=$lang 上行=${up}Mbit${down:+ 下行=${down}Mbit} 模式=$mode"
  if [ "$mode" = "cake" ]; then
    apply_up_cake "$lang" "$up"
    [ -n "$down" ] && apply_dl_cake "$(detect_wan)" "$down"
  else
    apply_up_htb "$lang" "$up"
    [ -n "$down" ] && apply_dl_htb "$lang" "$down"
  fi
  apply_blocks "$lang"
  apply_conn
  cat > "$CONF" <<EOF
LAN="$lang"
WAN="$(detect_wan)"
UPLOAD="$up"
DOWNLOAD="$down"
MODE="$mode"
CONNLIMIT_TCP="$(cf CONNLIMIT_TCP)"
CONNLIMIT_UDP="$(cf CONNLIMIT_UDP)"
EOF
  log "完成. 'netopt.sh stats' 查看."
}

before(){
  load_mods; log "直连测速 (确保 OpenClash 已关闭) ..."
  set -- $(measure_best); save_kv "$BASE" "$1" "$2"
  log "直连最好: 上传 ${1}Mbit 下载 ${2}Mbit -> $BASE"
  log "打开 OpenClash 后运行选 [2]"
}

after(){
  load_mods
  base_up=$(kv "$BASE" UP); base_dl=$(kv "$BASE" DOWN)
  [ -n "$base_up" ] || { base_up=$DEFAULT_UP; log "无直连基准, 按默认 ${DEFAULT_UP}M (建议先选 [1])"; }
  log "代理测速 (确保 OpenClash 已开启) ..."
  set -- $(measure_best); save_kv "$PROXY" "$1" "$2"
  log "代理最好: 上传 ${1}Mbit 下载 ${2}Mbit"
  shape_up=$((base_up * 9 / 10)); [ "$shape_up" -lt 1 ] && shape_up=$DEFAULT_UP
  shape_dl=""; [ -n "$base_dl" ] && [ "$base_dl" -gt 0 ] && shape_dl=$((base_dl * 9 / 10))
  log "自动计算: 直连上行 ${base_up}M -> 流控 ${shape_up}M${shape_dl:+, 下行 ${shape_dl}M}"
  [ "$base_up" -gt 0 ] && [ "$1" -gt 0 ] && [ "$1" -lt $((base_up / 2)) ] && log "警告: 代理上传($1 M) 远低于直连(${base_up}M), 瓶颈在代理节点"
  tune
  apply "$shape_up" "$shape_dl"
}

# ---------- 设备操作 ----------
cmd_list(){
  lan=$(detect_lan); hosts=$(list_hosts "$lan")
  n=$(echo "$hosts" | grep -c .); [ "$n" -lt 1 ] && n=1
  tu=$(total_up); td=$(total_dl)
  defu=$(( tu * 1000 / n )); defd=0; [ -n "$td" ] && defd=$(( td * 1000 / n ))
  for ip in $hosts; do
    u=$(dev_up "$ip"); [ -n "$u" ] || u=$defu
    d=$(dev_dl "$ip"); [ -n "$d" ] || d=$defd
    b=$(dev_blk "$ip"); [ -n "$b" ] || b=0
    t=$(dev_tcp "$ip"); [ -n "$t" ] || t=0
    q=$(dev_udp "$ip"); [ -n "$q" ] || q=0
    echo "$ip $u $d $b $t $q"
  done
}

cmd_avg(){
  lan=$(detect_lan); hosts=$(list_hosts "$lan")
  n=$(echo "$hosts" | grep -c .); [ "$n" -lt 1 ] && n=1
  tu=$(total_up); td=$(total_dl)
  u=$(( tu * 1000 / n )); d=0; [ -n "$td" ] && d=$(( td * 1000 / n ))
  for ip in $hosts; do set_limit "$ip" "$u" "$d"; done
  log "平均分配: 每台上行 ${u}kbit${td:+, 下行 ${d}kbit} (共 ${n} 台)"
  apply "$tu" "$td"
}

stats(){
  echo "=== 配置 ==="
  if [ -f "$CONF" ]; then
    echo "LAN=$(cf LAN)  WAN=$(cf WAN)  模式=$(cf MODE)"
    echo "流控上行=$(cf UPLOAD)Mbit  流控下行=$(cf DOWNLOAD:-未限)Mbit"
  else echo "(未应用)"; fi
  [ -f "$BASE" ] && echo "直连最好: 上 $(kv "$BASE" UP)M / 下 $(kv "$BASE" DOWN)M"
  [ -f "$PROXY" ] && echo "代理最好: 上 $(kv "$PROXY" UP)M / 下 $(kv "$PROXY" DOWN)M"
  echo; echo "=== 每设备 ==="
  if [ -s "$CLASSES" ]; then
    printf "%-16s %10s %10s %8s %8s %7s %7s\n" "设备IP" "上行MB" "下行MB" "封禁" "上行限速" "TCP上限" "UDP上限"
    while read -r ip cls; do
      b=$(tc -s class show dev "$IFB_UP" classid "1:$cls" 2>/dev/null | awk '/Sent/{print $2; exit}'); [ -n "$b" ] || b=0
      clsd=$(awk -v ip="$ip" '$1==ip{print $2}' "$CLASSES_DL" 2>/dev/null)
      db=0; [ -n "$clsd" ] && { db=$(tc -s class show dev "$(detect_lan)" classid "2:$clsd" 2>/dev/null | awk '/Sent/{print $2; exit}'); [ -n "$db" ] || db=0; }
      rate=$(tc class show dev "$IFB_UP" classid "1:$cls" 2>/dev/null | sed -n 's/.*rate \([0-9]*[KMG]bit\).*/\1/p' | head -1)
      blk=$(dev_blk "$ip"); [ "$blk" = "1" ] || blk=""
      lt=$(eff_tcp "$ip"); [ "$lt" = "0" ] && lt=""
      lu=$(eff_udp "$ip"); [ "$lu" = "0" ] && lu=""
      printf "%-16s %10s %10s %8s %8s %7s %7s\n" "$ip" "$((b / 1048576))" "$((db / 1048576))" "$blk" "${rate:-}" "$lt" "$lu"
    done < "$CLASSES"
  else echo "(未应用或非 HTB 模式)"; fi
}

# ---------- 实时监控: 连接数 + 速率 + 用量 ----------
snap_tc(){
  lan="$1"
  for ip in $(cat /tmp/netopt.devs 2>/dev/null); do
    uc=$(awk -v ip="$ip" '$1==ip{print $2}' "$CLASSES" 2>/dev/null)
    ub=0; [ -n "$uc" ] && { ub=$(tc -s class show dev "$IFB_UP" classid "1:$uc" 2>/dev/null | awk '/Sent/{print $2; exit}'); [ -n "$ub" ] || ub=0; }
    dc=$(awk -v ip="$ip" '$1==ip{print $2}' "$CLASSES_DL" 2>/dev/null)
    db=0; [ -n "$dc" ] && { db=$(tc -s class show dev "$lan" classid "2:$dc" 2>/dev/null | awk '/Sent/{print $2; exit}'); [ -n "$db" ] || db=0; }
    echo "$ip $ub $db"
  done
}

cmd_live(){
  lan=$(detect_lan); [ -n "$lan" ] || die "未找到 LAN"
  ct=""; for f in /proc/net/nf_conntrack /proc/net/ip_conntrack; do [ -r "$f" ] && { ct="$f"; break; }; done
  : > /tmp/netopt.conn
  [ -n "$ct" ] && awk '{p=$3; s=""; for(i=1;i<=NF;i++) if($i ~ /^src=/){s=substr($i,5); break} if(s!=""){k=s" "p; c[k]++; seen[s]=1}} END{for(x in seen) printf "%s %d %d\n", x, (c[x" tcp"]+0), (c[x" udp"]+0)}' "$ct" > /tmp/netopt.conn

  if [ -s "$CLASSES" ]; then awk '{print $1}' "$CLASSES" > /tmp/netopt.devs; else list_hosts "$lan" > /tmp/netopt.devs; fi
  snap_tc "$lan" > /tmp/netopt.s0
  sleep 1
  snap_tc "$lan" > /tmp/netopt.s1

  printf "%-16s %6s %6s %11s %11s %9s %9s\n" "设备IP" "TCP" "UDP" "上行kb/s" "下行kb/s" "上行MB" "下行MB"
  while read -r ip u0 d0; do
    t=$(awk -v ip="$ip" '$1==ip{print $2}' /tmp/netopt.conn); [ -n "$t" ] || t=0
    u=$(awk -v ip="$ip" '$1==ip{print $3}' /tmp/netopt.conn); [ -n "$u" ] || u=0
    u1=$(awk -v ip="$ip" '$1==ip{print $2}' /tmp/netopt.s1); [ -n "$u1" ] || u1=$u0
    d1=$(awk -v ip="$ip" '$1==ip{print $3}' /tmp/netopt.s1); [ -n "$d1" ] || d1=$d0
    ru=$(( (u1 - u0) * 8 / 1000 )); [ "$ru" -lt 0 ] && ru=0
    rd=$(( (d1 - d0) * 8 / 1000 )); [ "$rd" -lt 0 ] && rd=0
    printf "%-16s %6s %6s %11s %11s %9s %9s\n" "$ip" "$t" "$u" "$ru" "$rd" "$((u0 / 1048576))" "$((d0 / 1048576))"
  done < /tmp/netopt.s0
}

# ---------- 环境自检 ----------
check(){
  lan=$(detect_lan); wan=$(detect_wan); warn=0
  echo "===== netopt 环境自检 ====="
  echo "[接口] LAN=${lan:-未找到}  WAN=${wan:-未找到}"

  echo; echo "[内核模块]"
  for m in ifb sch_cake sch_htb act_mirred cls_u32 ip_set ip_set_hash_ip tcp_bbr; do
    if lsmod 2>/dev/null | grep -q "^$m" || [ -d "/sys/module/$m" ]; then echo "  OK   $m"
    else echo "  缺失 $m  (运行: netopt.sh deps)"; warn=1; fi
  done

  echo; echo "[流量分载 flow offloading] (开着会让限速失效, 必须关)"
  fo=$(uci -q get firewall.@defaults[0].flow_offloading)
  foh=$(uci -q get firewall.@defaults[0].flow_offloading_hw)
  if [ "$fo" = "1" ]; then echo "  软件分载: 已开启  <-- 请关闭"; warn=1; else echo "  软件分载: 关闭/未设"; fi
  if [ "$foh" = "1" ]; then echo "  硬件分载: 已开启  <-- 请关闭"; warn=1; else echo "  硬件分载: 关闭/未设"; fi
  if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -qi 'flowtable'; then
    echo "  nft flowtable: 存在  <-- 会绕过 qdisc, 请关硬件分载"; warn=1
  else echo "  nft flowtable: 无"; fi

  echo; echo "[其他限速/QoS 插件] (会与 netopt 打架)"
  if [ -f /etc/config/sqm ] && grep -q "option enabled '1'" /etc/config/sqm 2>/dev/null; then
    echo "  SQM: 已启用  <-- 请关闭"; warn=1
  else echo "  SQM: 未启用"; fi
  if ls /sys/class/net 2>/dev/null | grep -q '^ifb4'; then echo "  发现 SQM 的 ifb4* 设备  <-- 请关闭 SQM"; warn=1; fi
  if ls /etc/init.d 2>/dev/null | grep -q turboacc || pgrep -f turboacc >/dev/null 2>&1; then
    echo "  Turbo ACC: 存在  <-- 其中 FlowOffload 冲突(BBR 无妨), 请关分载"
  else echo "  Turbo ACC: 未发现"; fi

  echo; echo "[现有 qdisc] (看有没有别人在抢)"
  tc qdisc show 2>/dev/null | grep -E 'htb|cake|fq_codel|tbf|hfsc' || echo "  (无 htb/cake/tbf 等)"

  echo; echo "[netopt 当前状态]"
  if ip link show "$IFB_UP" >/dev/null 2>&1; then echo "  上传限速: 已挂 ($IFB_UP)"; else echo "  上传限速: 未挂"; fi
  if [ -n "$lan" ] && tc qdisc show dev "$lan" 2>/dev/null | grep -q 'htb'; then echo "  下载限速: 已挂 ($lan htb)"; else echo "  下载限速: 未挂"; fi
  echo "  拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  command -v ipset >/dev/null 2>&1 && echo "  ipset: $(ipset list "$IPSET" 2>/dev/null | awk '/Number of entries/{print $4}') 台登记"

  echo
  if [ "$warn" = "1" ]; then echo "==> 发现上面标 <-- 的问题, 请先处理, 否则限速可能不生效"
  else echo "==> 环境正常, 可以开始: netopt.sh before / after"; fi
}

remove_all(){ clear_shaping; log "已移除限速/封禁"; }

set_connall(){
  t="$1"; q="$2"; cl=$(cf LAN); cw=$(cf WAN); cu=$(cf UPLOAD); cd=$(cf DOWNLOAD); cm=$(cf MODE)
  [ -n "$q" ] || q="$t"
  cat > "$CONF" <<EOF
LAN="${cl:-$(detect_lan)}"
WAN="${cw:-$(detect_wan)}"
UPLOAD="${cu:-$DEFAULT_UP}"
DOWNLOAD="$cd"
MODE="${cm:-$MODE_DEFAULT}"
CONNLIMIT_TCP="$t"
CONNLIMIT_UDP="$q"
EOF
  log "全局每台连接数上限: TCP=${t} UDP=${q} (0=不限, 重新 apply 生效)"
}

boot_enable(){
  [ -f "$CONF" ] || die "先 apply 一次"
  cat > /etc/hotplug.d/iface/99-netopt <<'HOOK'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
[ -f /etc/netopt.conf ] || exit 0
. /etc/netopt.conf
[ "$DEVICE" = "$LAN" ] || exit 0
[ -x /usr/bin/netopt.sh ] && /usr/bin/netopt.sh apply "$UPLOAD" "$DOWNLOAD" >/dev/null 2>&1
HOOK
  chmod +x /etc/hotplug.d/iface/99-netopt
  log "已开启开机自启"
}
boot_disable(){ rm -f /etc/hotplug.d/iface/99-netopt; log "已关闭开机自启"; }

oneclick(){
  echo "=========================================="
  echo "      netopt 一键网络优化 (完整流程)"
  echo "=========================================="
  log "步骤 1/5: 安装依赖 (自动识别 opkg/apk)"
  deps || log "依赖安装有报错, 继续 (可稍后 netopt.sh check 查看缺什么)"
  log "步骤 2/5: 环境自检"
  check
  echo
  printf ">> 请确保 OpenClash 已【关闭】, 按回车开始直连测速 (Ctrl+C 取消): "
  read -r _
  log "步骤 3/5: 直连测速"
  before
  echo
  printf ">> 现在【打开 OpenClash】, 等它完全启动后按回车开始代理测速: "
  read -r _
  log "步骤 4/5: 代理测速 + 自动优化"
  after
  log "步骤 5/5: 开启开机自启"
  boot_enable
  echo
  stats
  echo
  echo "==> 完成! 不满意可: netopt.sh remove (撤限速) / netopt.sh boot-disable (关自启)"
}

menu(){
  while :; do
    echo
    echo "======== netopt 一键网络优化 ========"
    echo "  1) 直连测速(开代理前)     2) 代理测速+自动优化(开代理后)"
    echo "  3) 只应用限速             4) 查看统计"
    echo "  5) 撤销限速               6) 一键平均分配上下行"
    echo "  7) 给某台限速             8) 封禁/解封某台联网"
    echo "  9) 开机自启              10) 关闭自启"
    echo " 11) 安装依赖(自动 opkg/apk) 12) 环境自检"
    echo " 13) 给某台设连接数上限     14) 全局连接数上限"
    echo " 15) 一键跑完整流程(装依赖+测速+优化)  0) 退出"
    echo " 16) 实时监控(连接数/速率/用量)"
    printf "请选择: "
    read -r c
    case "$c" in
      1) before;;
      2) after;;
      3) printf "上行Mbit (默认%s): " "$(total_up)"; read -r v; [ -n "$v" ] || v=$(total_up); apply "$v" "$(total_dl)";;
      4) stats;;
      5) remove_all;;
      6) cmd_avg;;
      7) printf "设备IP: "; read -r ip; printf "上行kbit: "; read -r u; printf "下行kbit: "; read -r d; set_limit "$ip" "$u" "$d"; apply;;
      8) printf "设备IP: "; read -r ip; printf "封禁? 1=封 0=解 : "; read -r b; set_block "$ip" "$b"; apply;;
      9) boot_enable;;
      10) boot_disable;;
      11) deps;;
      12) check;;
      13) printf "设备IP: "; read -r ip; printf "TCP 最大连接数 (0=不限): "; read -r a; printf "UDP 最大连接数 (0=不限): "; read -r b; set_conn "$ip" "$a" "$b"; apply;;
      14) printf "全局每台 TCP 上限 (0=不限): "; read -r a; printf "全局每台 UDP 上限 (0=不限): "; read -r b; set_connall "$a" "$b"; apply;;
      15) oneclick;;
      16) cmd_live;;
      0|q) break;;
      "") ;;
      *) echo "无效选择";;
    esac
  done
}

case "$1" in
  before) before ;;
  after|auto) after ;;
  apply) shift; apply "$@" ;;
  avg) cmd_avg ;;
  list) cmd_list ;;
  check) check ;;
  live|mon) cmd_live ;;
  set-limit) shift; set_limit "$1" "$2" "$3"; apply ;;
  set-block) shift; set_block "$1" "$2"; apply ;;
  set-conn) shift; set_conn "$1" "$2" "$3"; apply ;;
  conn) shift; set_connall "$1" "$2"; apply ;;
  stats|status) stats ;;
  remove) remove_all ;;
  deps) deps ;;
  boot-enable) boot_enable ;;
  boot-disable) boot_disable ;;
  tune) tune ;;
  "") menu ;;
  oneclick|1click) oneclick ;;
  *) sed -n '2,26p' "$0" ;;
esac
__NETOPT_SH__
chmod +x /usr/bin/netopt.sh

echo "[install] 写入 LuCI 页面"
mkdir -p /www/luci-static/resources/view/netopt /usr/share/luci/menu.d /usr/share/rpcd/acl.d
cat > /www/luci-static/resources/view/netopt/overview.js <<'__OVERVIEW_JS__'
'use strict';
'require view';
'require fs';
'require ui';

var SCRIPT = '/usr/bin/netopt.sh';

function run(args) {
	return fs.exec(SCRIPT, args).then(function(r) {
		return (r.stdout || '') + (r.stderr || '');
	});
}

function parseRows(txt) {
	var rows = [];
	(txt || '').split('\n').forEach(function(line) {
		var p = line.trim().split(/\s+/);
		if (p.length >= 6 && /^\d+\.\d+\.\d+\.\d+$/.test(p[0]))
			rows.push({ ip: p[0], up: parseInt(p[1], 10) || 0, down: parseInt(p[2], 10) || 0, block: p[3] === '1', tcp: parseInt(p[4], 10) || 0, udp: parseInt(p[5], 10) || 0 });
	});
	return rows;
}

function parseLive(txt) {
	var rows = [];
	(txt || '').split('\n').forEach(function(line) {
		var p = line.trim().split(/\s+/);
		if (p.length >= 7 && /^\d+\.\d+\.\d+\.\d+$/.test(p[0]))
			rows.push({ ip: p[0], tcp: p[1], udp: p[2], ru: p[3], rd: p[4], ub: p[5], db: p[6] });
	});
	return rows;
}

return view.extend({
	load: function() {
		return Promise.all([ run(['list']), run(['stats']) ]).then(function(r) {
			return { rows: parseRows(r[0]), stats: r[1] };
		});
	},

	render: function(data) {
		var out = E('pre', {
			'style': 'white-space:pre-wrap;word-break:break-all;background:var(--background-color-low,#f5f5f5);' +
				'border:1px solid var(--border-color,#ccc);border-radius:6px;padding:12px;' +
				'max-height:36vh;overflow:auto;font-size:12px;line-height:1.5'
		}, data.stats || '(无输出)');
		function setOut(t) { out.textContent = t || '(完成, 无输出)'; }

		function btn(label, args) {
			return E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'style': 'margin:0 6px 6px 0',
				'click': function() {
					ui.showModal(label + ' …', [ E('p', { 'class': 'spinning' }, '请稍候…') ]);
					return run(args).then(function(t) { ui.hideModal(); setOut(t); })
						.catch(function(e) { ui.hideModal(); setOut('出错: ' + e); });
				}
			}, label);
		}

		var ctrls = (data.rows || []).map(function(r) {
			var upIn = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'style': 'width:110px', 'value': r.up });
			var dnIn = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'style': 'width:110px', 'value': r.down });
			var cnIn = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'style': 'width:80px', 'value': r.tcp });
			var udIn = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'style': 'width:80px', 'value': r.udp });
			var blk = E('input', { 'type': 'checkbox' });
			if (r.block) blk.checked = true;
			return { ip: r.ip, up: upIn, down: dnIn, conn: cnIn, udp: udIn, blk: blk };
		});

		var tbody = ctrls.map(function(c) {
			return E('tr', {}, [
				E('td', { 'style': 'padding:4px 8px;font-family:monospace' }, c.ip),
				E('td', { 'style': 'padding:4px 8px' }, c.up),
				E('td', { 'style': 'padding:4px 8px' }, c.down),
				E('td', { 'style': 'padding:4px 8px' }, c.conn),
				E('td', { 'style': 'padding:4px 8px' }, c.udp),
				E('td', { 'style': 'padding:4px 8px;text-align:center' }, c.blk)
			]);
		});
		var table = E('table', { 'class': 'table', 'style': 'width:auto' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', {}, '设备 IP'), E('th', {}, '上行(kbit)'), E('th', {}, '下行(kbit)'), E('th', {}, 'TCP上限'), E('th', {}, 'UDP上限'), E('th', {}, '禁止联网')
			])
		].concat(tbody));

		function saveAll() {
			ui.showModal('保存并应用 …', [ E('p', { 'class': 'spinning' }, '正在写入每台额度并应用…') ]);
			var chain = Promise.resolve();
			ctrls.forEach(function(c) {
				chain = chain
					.then(function() { return run(['set-limit', c.ip, String(c.up.value || 0), String(c.down.value || 0)]); })
					.then(function() { return run(['set-block', c.ip, c.blk.checked ? '1' : '0']); })
					.then(function() { return run(['set-conn', c.ip, String(c.conn.value || 0), String(c.udp.value || 0)]); });
			});
			return chain.then(function() { return run(['apply']); })
				.then(function(t) { ui.hideModal(); setOut(t); })
				.catch(function(e) { ui.hideModal(); setOut('出错: ' + e); });
		}

		function avg() {
			ui.showModal('一键平均分配 …', [ E('p', { 'class': 'spinning' }, '按设备数平均分配上下行…') ]);
			return run(['avg']).then(function(t) {
				ui.hideModal(); setOut(t);
				return run(['list']).then(function(listTxt) {
					var nr = parseRows(listTxt);
					ctrls.forEach(function(c) {
						var m = nr.filter(function(x) { return x.ip === c.ip; })[0];
						if (m) { c.up.value = m.up; c.down.value = m.down; c.conn.value = m.tcp; c.udp.value = m.udp; c.blk.checked = m.block; }
					});
				});
			}).catch(function(e) { ui.hideModal(); setOut('出错: ' + e); });
		}

		/* ---- 实时监控表 (自动刷新) ---- */
		var liveBody = E('tbody', {});
		var liveBusy = false;
		function refreshLive() {
			if (liveBusy) return Promise.resolve();
			liveBusy = true;
			return run(['live']).then(function(t) {
				var rows = parseLive(t);
				while (liveBody.firstChild) liveBody.removeChild(liveBody.firstChild);
				rows.forEach(function(r) {
					liveBody.appendChild(E('tr', {}, [
						E('td', { 'style': 'padding:4px 8px;font-family:monospace' }, r.ip),
						E('td', { 'style': 'padding:4px 8px' }, r.tcp),
						E('td', { 'style': 'padding:4px 8px' }, r.udp),
						E('td', { 'style': 'padding:4px 8px' }, r.ru),
						E('td', { 'style': 'padding:4px 8px' }, r.rd),
						E('td', { 'style': 'padding:4px 8px' }, r.ub),
						E('td', { 'style': 'padding:4px 8px' }, r.db)
					]));
				});
			}).catch(function() {}).then(function() { liveBusy = false; });
		}
		var liveTable = E('table', { 'class': 'table', 'style': 'width:auto' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', {}, '设备 IP'), E('th', {}, 'TCP'), E('th', {}, 'UDP'),
				E('th', {}, '上行 kb/s'), E('th', {}, '下行 kb/s'), E('th', {}, '上行 MB'), E('th', {}, '下行 MB')
			]), liveBody
		]);

		refreshLive();
		var liveTimer = setInterval(refreshLive, 4000);
		window.addEventListener('unload', function() { if (liveTimer) clearInterval(liveTimer); });

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, '网络优化 netopt'),
			E('div', { 'class': 'cbi-section' }, [
				E('p', {}, '一键流程: ① 关代理时点“直连测速(基准)” → ② 开代理后点“代理测速+优化”。'),
				E('div', { 'style': 'margin-bottom:10px' }, [
					btn('直连测速(基准)', ['before']),
					btn('代理测速+优化', ['after']),
					btn('刷新统计', ['stats']),
					btn('环境自检', ['check']),
					btn('撤销限速', ['remove']),
					btn('开机自启', ['boot-enable']),
					btn('关闭自启', ['boot-disable'])
				]),

				E('h3', {}, '实时监控（每 4 秒自动刷新）'),
				E('div', { 'style': 'margin-bottom:6px' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': function() { refreshLive(); } }, '立即刷新')
				]),
				liveTable,

				E('h3', {}, '每台设备限速 / 连接数上限 / 封禁'),
				E('p', { 'class': 'cbi-section-descr' }, '单位 kbit；0 = 按平均自动。TCP/UDP 上限分别限制各自并发连接数，0 = 不限。勾选“禁止联网”即阻断该设备。改完点“保存并应用”。'),
				table,
				E('div', { 'style': 'margin:10px 0' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-action', 'style': 'margin-right:6px', 'click': saveAll }, '保存并应用'),
					E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': avg }, '一键平均分配上下行')
				]),

				E('h3', {}, '当前状态'),
				out
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
__OVERVIEW_JS__
cat > /usr/share/luci/menu.d/luci-app-netopt.json <<'__MENU_JSON__'
{
	"admin/services/netopt": {
		"title": "网络优化",
		"order": 60,
		"action": {
			"type": "view",
			"path": "netopt/overview"
		},
		"depends": {
			"acl": {
				"ubus": {
					"file": [ "exec" ]
				}
			}
		}
	}
}
__MENU_JSON__
cat > /usr/share/rpcd/acl.d/luci-app-netopt.json <<'__ACL_JSON__'
{
	"luci-app-netopt": {
		"description": "netopt 网络优化: 查看配置/每设备统计并执行测速与限速",
		"read": {
			"ubus": {
				"file": [ "exec", "read", "stat", "list" ]
			}
		},
		"write": {
			"ubus": {
				"file": [ "exec", "write" ]
			}
		}
	}
}
__ACL_JSON__

echo "[install] 刷新服务"
/etc/init.d/rpcd restart 2>/dev/null
rm -f /tmp/luci-indexcache* 2>/dev/null
/etc/init.d/uhttpd restart 2>/dev/null || /etc/init.d/httpd restart 2>/dev/null

echo "[install] 完成, 进入一键优化"
exec /usr/bin/netopt.sh oneclick
