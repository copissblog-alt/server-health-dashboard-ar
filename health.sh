#!/usr/bin/env bash
# health.sh — يقرأ صحة السيرفر كل دقيقة، ويكتب status.json و history.csv للوحة، وينبّه على تيليجرام.
# التشغيل: health.sh [/path/to/health.conf]     (يشغّله cron كل دقيقة)
set -uo pipefail
export LC_ALL=C

CONF=${1:-/etc/server-health/health.conf}
# القيم الافتراضية — يغيّرها ملف الإعداد
OUT_DIR=/var/www/server-health
STATE_DIR=/var/lib/server-health
SERVICES=""
CERTS=""
WARN_CPU=90
WARN_MEM=90
WARN_DISK=90
WARN_LOAD=2       # الحمل مقسوماً على عدد الأنوية
WARN_CERT_DAYS=14
ALERT_AFTER=3     # دقائق متتالية قبل التنبيه، حتى لا تنبّهك قفزة لحظية
HISTORY_DAYS=7
SERVER_NAME=$(hostname 2>/dev/null || echo server)
TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""
TELEGRAM_API=https://api.telegram.org
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"

PROC=${HEALTH_PROC:-/proc}   # للاختبارات: /proc مزيف
NOW=${HEALTH_NOW:-$(date +%s)}
mkdir -p "$OUT_DIR" "$STATE_DIR" || exit 1
exec 9>"$STATE_DIR/.lock"
flock -n 9 || exit 0          # تشغيل واحد في الوقت نفسه

# ---------- أدوات ----------
jstr() { # نص JSON آمن
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/ }
  s=${s//$'\n'/ }
  printf '"%s"' "$s"
}
pct() { awk -v a="$1" -v b="$2" 'BEGIN { if (b > 0) printf "%.1f", 100 * a / b; else print 0 }'; }
state_get() { cat "$STATE_DIR/$1" 2>/dev/null || true; }
state_set() { printf '%s\n' "$2" >"$STATE_DIR/$1.tmp" && mv "$STATE_DIR/$1.tmp" "$STATE_DIR/$1"; }

# ---------- المعالج ----------
# /proc/stat يعدّ الوقت منذ الإقلاع؛ النسبة = الفرق بين قراءتين. نحفظ القراءة السابقة في ملف حالة.
read_cpu() { awk '/^cpu /{ idle = $5 + $6; total = 0; for (i = 2; i <= 9; i++) total += $i; print total, idle, $6, $9 }' "$PROC/stat"; }
read -r t1 i1 w1 s1 <<<"$(read_cpu)"
prev=$(state_get cpu)
if [ -z "$prev" ]; then # أول تشغيل: نأخذ عينة ثانية بعد ثانية
  sleep 1
  read -r t0 i0 w0 s0 <<<"$t1 $i1 $w1 $s1"
  read -r t1 i1 w1 s1 <<<"$(read_cpu)"
else
  read -r t0 i0 w0 s0 <<<"$prev"
fi
state_set cpu "$t1 $i1 $w1 $s1"
dt=$((t1 - t0))
if [ "$dt" -gt 0 ]; then
  CPU=$(pct $((dt - (i1 - i0))) "$dt")
  IOWAIT=$(pct $((w1 - w0)) "$dt")
  STEAL=$(pct $((s1 - s0)) "$dt")
else
  CPU=0 IOWAIT=0 STEAL=0
fi
CORES=$(grep -c '^processor' "$PROC/cpuinfo" 2>/dev/null || nproc)
[ "$CORES" -gt 0 ] || CORES=1
read -r L1 L5 L15 _ <"$PROC/loadavg"

# ---------- الذاكرة ----------
# المستعمل = الكلي - المتاح (MemAvailable). MemFree يتجاهل ذاكرة الكاش التي يحررها النظام عند الحاجة.
read -r MemTotal MemFree MemAvailable SwapTotal SwapFree <<<"$(awk '{ v[$1] = $2 } END { print v["MemTotal:"] + 0, v["MemFree:"] + 0, v["MemAvailable:"] + 0, v["SwapTotal:"] + 0, v["SwapFree:"] + 0 }' "$PROC/meminfo")"
MEM_USED=$((MemTotal - MemAvailable))
MEM=$(pct "$MEM_USED" "$MemTotal")
SWAP_USED=$((SwapTotal - SwapFree))
SWAP=$(pct "$SWAP_USED" "$SwapTotal")

# ---------- الأقراص ----------
DISKS_JSON=""
ROOT_DISK=0
DISK_PCTS=()
while read -r _ size used avail cap mnt; do
  p=${cap%\%}
  ipct=$(df -P -i "$mnt" 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); print ($5 == "-" ? 0 : $5) }')
  DISKS_JSON+="${DISKS_JSON:+,}{\"mount\":$(jstr "$mnt"),\"size_kb\":$size,\"used_kb\":$used,\"avail_kb\":$avail,\"pct\":$p,\"inodes_pct\":${ipct:-0}}"
  [ "$mnt" = / ] && ROOT_DISK=$p
  DISK_PCTS+=("$mnt=$p" "$mnt (inodes)=${ipct:-0}")  # امتلاء عُقد الملفات يوقف الكتابة مثل امتلاء المساحة
done < <(df -P -k -x tmpfs -x devtmpfs -x squashfs -x overlay -x fuse.rclone 2>/dev/null | awk 'NR > 1 && $2 > 0')

# ---------- الشبكة (بايت في الثانية) ----------
read -r RXB TXB <<<"$(awk 'NR > 2 { gsub(":", " "); if ($1 != "lo") { rx += $2; tx += $10 } } END { printf "%.0f %.0f\n", rx, tx }' "$PROC/net/dev")"
read -r pts prx ptx <<<"$(state_get net)"
state_set net "$NOW $RXB $TXB"
RX=0 TX=0
if [ -n "${pts:-}" ] && [ "$NOW" -gt "$pts" ] && [ "$RXB" -ge "$prx" ]; then
  RX=$(((RXB - prx) / (NOW - pts)))
  TX=$(((TXB - ptx) / (NOW - pts)))
fi

UPTIME=$(awk '{ printf "%d", $1 }' "$PROC/uptime")

# ---------- الخدمات ----------
SERVICES_JSON=""
declare -A SVC=()
for s in $SERVICES; do
  st=$(systemctl is-active "$s" 2>/dev/null)
  st=${st:-unknown}
  SVC[$s]=$st
  SERVICES_JSON+="${SERVICES_JSON:+,}{\"name\":$(jstr "$s"),\"state\":$(jstr "$st")}"
done

# ---------- الشهادات: مرة كل ساعة ----------
CERTS_JSON=$(state_get certs.json)
if [ -n "$CERTS" ] && { [ -z "$CERTS_JSON" ] || [ $((NOW - $(state_get certs.ts || echo 0))) -ge 3600 ]; }; then
  CERTS_JSON=""
  for c in $CERTS; do
    host=${c%%:*}
    port=${c##*:}
    [ "$port" = "$c" ] && port=443
    end=$(timeout 10 openssl s_client -connect "$host:$port" -servername "$host" </dev/null 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    days=-1
    [ -n "$end" ] && days=$((($(date -d "$end" +%s) - NOW) / 86400))
    CERTS_JSON+="${CERTS_JSON:+,}{\"host\":$(jstr "$host"),\"days\":$days}"
  done
  state_set certs.json "$CERTS_JSON"
  state_set certs.ts "$NOW"
fi

# ---------- التحديثات وإعادة التشغيل: مرة كل ساعة ----------
UPDATES=$(state_get updates)
if [ -z "$UPDATES" ] || [ $((NOW - $(state_get updates.ts || echo 0))) -ge 3600 ]; then
  if command -v apt-get >/dev/null; then
    UPDATES=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -c '^Inst ')
  else
    UPDATES=0
  fi
  state_set updates "$UPDATES"
  state_set updates.ts "$NOW"
fi
REBOOT=false
[ -f "${HEALTH_REBOOT_FILE:-/var/run/reboot-required}" ] && REBOOT=true

# ---------- أكثر العمليات استهلاكاً للذاكرة ----------
TOP_JSON=""
while read -r pid comm cpu mem; do
  TOP_JSON+="${TOP_JSON:+,}{\"pid\":$pid,\"name\":$(jstr "$comm"),\"cpu\":$cpu,\"mem\":$mem}"
done < <(ps -eo pid=,comm=,%cpu=,%mem= --sort=-%mem 2>/dev/null | awk '$2 != "ps"' | head -5)

# ---------- status.json (كتابة ثم نقل: اللوحة لا تقرأ ملفاً نصف مكتوب) ----------
cat >"$OUT_DIR/status.json.tmp" <<JSON
{"server":$(jstr "$SERVER_NAME"),"ts":$NOW,"uptime":$UPTIME,"cores":$CORES,
"cpu":{"pct":$CPU,"iowait":$IOWAIT,"steal":$STEAL},
"load":[$L1,$L5,$L15],
"mem":{"total_kb":$MemTotal,"used_kb":$MEM_USED,"available_kb":$MemAvailable,"free_kb":$MemFree,"pct":$MEM},
"swap":{"total_kb":$SwapTotal,"used_kb":$SWAP_USED,"pct":$SWAP},
"disks":[$DISKS_JSON],
"net":{"rx_bps":$RX,"tx_bps":$TX},
"services":[$SERVICES_JSON],
"certs":[$CERTS_JSON],
"updates":${UPDATES:-0},"reboot_required":$REBOOT,
"top":[$TOP_JSON],
"warn":{"cpu":$WARN_CPU,"mem":$WARN_MEM,"disk":$WARN_DISK,"load":$WARN_LOAD,"cert_days":$WARN_CERT_DAYS}}
JSON
mv "$OUT_DIR/status.json.tmp" "$OUT_DIR/status.json"

# ---------- السجل: سطر كل دقيقة، ونقصّه مرة كل ساعة ----------
H="$OUT_DIR/history.csv"
[ -s "$H" ] || echo "ts,cpu,mem,load1,disk,rx,tx" >"$H"
echo "$NOW,$CPU,$MEM,$L1,$ROOT_DISK,$RX,$TX" >>"$H"
if [ $((NOW / 60 % 60)) -eq 0 ]; then
  keep=$((HISTORY_DAYS * 1440))
  { head -1 "$H"; tail -n +2 "$H" | tail -n "$keep"; } >"$H.tmp" && mv "$H.tmp" "$H"
fi

# ---------- التنبيهات ----------
send() {
  [ -n "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] || return 0
  curl -fsS -m 10 -o /dev/null "$TELEGRAM_API/bot$TELEGRAM_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$1" -d parse_mode=HTML
}
# عدد بالعربية: arn 1 دقيقة دقيقتان دقائق ← "دقيقة"، 2 ← "دقيقتان"، 5 ← "5 دقائق"، 15 ← "15 دقيقة"
arn() {
  local n=$1
  if [ "$n" -eq 1 ]; then echo "$2"
  elif [ "$n" -eq 2 ]; then echo "$3"
  elif [ "$n" -le 10 ]; then echo "$n $4"
  else echo "$n $5"; fi
}
human() { # 3725 ثانية ← "ساعة و2 دقيقة"
  local s=$1 parts=()
  ((s >= 86400)) && parts+=("$(arn $((s / 86400)) يوم يومان أيام يوماً)")
  ((s % 86400 >= 3600)) && parts+=("$(arn $((s % 86400 / 3600)) ساعة ساعتان ساعات ساعة)")
  ((s % 3600 >= 60)) && parts+=("$(arn $((s % 3600 / 60)) دقيقة دقيقتان دقائق دقيقة)")
  ((s < 60)) && parts=("أقل من دقيقة")
  local IFS='|'
  local out="${parts[*]}"
  echo "${out//|/ و}"
}
# check KEY BAD(0/1) TEXT AFTER
# ملف الحالة لكل فحص: "عدد الدقائق السيئة المتتالية، وقت البداية، هل نُبِّه"
check() {
  local bad=$2 text=$3 after=${4:-$ALERT_AFTER} f="alert.${1//[^A-Za-z0-9_.-]/_}"
  local n since sent
  read -r n since sent <<<"$(state_get "$f")"
  n=${n:-0} since=${since:-0} sent=${sent:-0}
  if [ "$bad" = 1 ]; then
    [ "$n" -eq 0 ] && since=$NOW
    n=$((n + 1))
    if [ "$sent" = 0 ] && [ "$n" -ge "$after" ]; then
      send "🔴 <b>$SERVER_NAME</b>: $text" && sent=1
    fi
    state_set "$f" "$n $since $sent"
  elif [ "$n" -gt 0 ]; then
    if [ "$sent" = 1 ]; then
      send "✅ <b>$SERVER_NAME</b>: عاد طبيعياً — $text (استمر $(human $((NOW - since))))" || { state_set "$f" "$n $since $sent"; return; }
    fi
    rm -f "$STATE_DIR/$f"
  fi
}
gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }' && echo 1 || echo 0; }

check cpu "$(gt "$CPU" "$WARN_CPU")" "المعالج ${CPU}%"
check mem "$(gt "$MEM" "$WARN_MEM")" "الذاكرة ${MEM}%"
check load "$(gt "$(awk -v l="$L1" -v c="$CORES" 'BEGIN { print l / c }')" "$WARN_LOAD")" "الحمل $L1 على $CORES أنوية"
for d in "${DISK_PCTS[@]}"; do
  check "disk.${d%=*}" "$(gt "${d##*=}" "$WARN_DISK")" "القرص ${d%=*} ${d##*=}%"
done
for s in "${!SVC[@]}"; do
  bad=0
  [ "${SVC[$s]}" = active ] || bad=1
  check "svc.$s" "$bad" "الخدمة $s: ${SVC[$s]}" 2
done
if [ -n "$CERTS_JSON" ]; then
  while IFS=, read -r host days; do
    bad=0
    [ "$days" -lt "$WARN_CERT_DAYS" ] && bad=1
    if [ "$days" -lt 0 ]; then msg="تعذر قراءة شهادة $host (منتهية أو لا يرد)"; else msg="شهادة $host تنتهي بعد $(arn "$days" يوم يومين أيام يوماً)"; fi
    check "cert.$host" "$bad" "$msg" 1
  done < <(sed 's/},{/}\n{/g' <<<"$CERTS_JSON" | sed -E 's/.*"host":"([^"]*)","days":(-?[0-9]+).*/\1,\2/')
fi
exit 0
