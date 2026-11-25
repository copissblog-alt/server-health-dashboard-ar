#!/usr/bin/env bash
# اختبارات health.sh على /proc مزيف وأوامر مزيفة (df و systemctl و ps و openssl) وتيليجرام مزيف.
# التشغيل: bash tests/run.sh     (يحتاج python3 للتحقق من JSON ولخادم تيليجرام المزيف)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'kill $TG 2>/dev/null; rm -rf "$T"' EXIT
PASS=0 FAIL=0
ok() { if [ "$2" = 0 ]; then PASS=$((PASS + 1)); echo "PASS $1"; else FAIL=$((FAIL + 1)); echo "FAIL $1 ${3:-}"; fi; }
is() { [ "$2" = "$3" ]; ok "$1" $? "(got '$2', want '$3')"; }

# ---- /proc مزيف ----
P=$T/proc; mkdir -p $P/net
cpu() { echo "cpu  $1 0 $2 $3 $4 0 0 $5 0 0" >$P/stat; } # user system idle iowait steal
cpu 600 200 1000 100 100
printf 'processor\t: 0\nprocessor\t: 1\n' >$P/cpuinfo
echo "0.50 0.40 0.30 1/100 999" >$P/loadavg
mem() { printf 'MemTotal: 1000000 kB\nMemFree: %s kB\nMemAvailable: %s kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' "$1" "$2" >$P/meminfo; }
mem 50000 600000
net() { printf 'Inter-|\n face |\n    lo: 999 0 0 0 0 0 0 0 999 0 0 0 0 0 0 0\n  eth0: %s 0 0 0 0 0 0 0 %s 0 0 0 0 0 0 0\n' "$1" "$2" >$P/net/dev; }
net 1000000 500000
echo "93784.12 100.00" >$P/uptime

# ---- أوامر مزيفة ----
B=$T/bin; mkdir -p $B
cat >$B/df <<'X'
#!/bin/sh
if [ "$2" = "-i" ]; then echo "Filesystem Inodes IUsed IFree IUse% Mounted"; echo "/dev/vda 100 10 90 $(cat $FAKE/inodes) $3"; exit; fi
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/vda 100000000 $(cat $FAKE/used) 1000 $(cat $FAKE/disk)% /"
echo "/dev/vdb 5000000 1000000 4000000 20% /var/lib/mysql"
X
cat >$B/systemctl <<'X'
#!/bin/sh
cat "$FAKE/svc.$2" 2>/dev/null || echo active
X
cat >$B/ps <<'X'
#!/bin/sh
echo "  101 mariadbd 2.5 31.0"; echo "  202 php-fpm8.3 1.0 12.5"; echo "  303 ps 0.0 0.1"
X
cat >$B/openssl <<'X'
#!/bin/sh
echo call >>"$FAKE/openssl.calls"
case "$1" in x509) echo "notAfter=$(date -u -d "@$(( $(cat $FAKE/now) + $(cat $FAKE/certdays) * 86400 + 3600 ))" '+%b %e %H:%M:%S %Y GMT')";; *) echo cert;; esac
X
cat >$B/apt-get <<'X'
#!/bin/sh
echo "Inst openssl [3.0.2] (3.0.13 Ubuntu)"; echo "Inst curl [8.5] (8.6 Ubuntu)"
X
chmod +x $B/*
export FAKE=$T PATH="$B:$PATH" HEALTH_PROC=$P HEALTH_REBOOT_FILE=$T/reboot-required
echo 50 >$T/disk; echo 50000000 >$T/used; echo 5% >$T/inodes; echo 90 >$T/certdays

# ---- تيليجرام مزيف ----
PORT=$((20000 + RANDOM % 20000))
python3 "$ROOT/tests/fake_tg.py" $T/tg.log $PORT & TG=$!
touch $T/tg.log
cat >$T/h.conf <<X
OUT_DIR=$T/out
STATE_DIR=$T/state
SERVER_NAME="web-1"
SERVICES="nginx mariadb"
CERTS="example.com"
ALERT_AFTER=3
HISTORY_DAYS=1
TELEGRAM_TOKEN=T
TELEGRAM_CHAT_ID=42
TELEGRAM_API=http://127.0.0.1:$PORT
X
sleep 0.5
NOW=1800000000   # مضاعف 3600: يبدأ على رأس ساعة
run() { NOW=$((NOW + 60)); echo $NOW >$T/now; HEALTH_NOW=$NOW bash "$ROOT/health.sh" $T/h.conf; }
J() { python3 -c "import json,sys; d=json.load(open('$T/out/status.json')); print($1)"; }
msgs() { wc -l <$T/tg.log | tr -d ' '; }

# أول تشغيل بلا قراءة سابقة: يأخذ عينة ثانية بعد ثانية
cpu 600 200 1000 100 100
run
cpu 1100 300 1300 200 100   # الفرق: المجموع 1000، الخامل (idle+iowait) 400 → 60%
run
python3 -c "import json; json.load(open('$T/out/status.json'))"; ok "status.json is valid JSON" $?
is "CPU % from the difference of two /proc/stat readings" "$(J "d['cpu']['pct']")" "60.0"
is "iowait %" "$(J "d['cpu']['iowait']")" "10.0"
is "memory uses MemAvailable, not MemFree (40%, not 95%)" "$(J "d['mem']['pct']")" "40.0"
is "cores from cpuinfo" "$(J "d['cores']")" "2"
is "load" "$(J "d['load']")" "[0.5, 0.4, 0.3]"
is "two disks, root 50%" "$(J "[x['mount'] for x in d['disks']], d['disks'][0]['pct']")" "['/', '/var/lib/mysql'] 50"
is "uptime seconds" "$(J "d['uptime']")" "93784"
is "top processes without ps itself" "$(J "[p['name'] for p in d['top']]")" "['mariadbd', 'php-fpm8.3']"
is "pending updates counted" "$(J "d['updates']")" "2"
is "certificate days" "$(J "d['certs'][0]['days']")" "90"
net 7000000 3500000
run
is "network bytes/s from the difference" "$(J "d['net']['rx_bps'], d['net']['tx_bps']")" "100000 50000"
is "lo is ignored" "$(J "d['net']['rx_bps'] < 200000")" "True"
is "no alerts while healthy" "$(msgs)" "0"
is "history: header + one line per run" "$(wc -l <$T/out/history.csv | tr -d ' ')" "4"

# قفزة دقيقتين ثم عودة: لا تنبيه
echo 95 >$T/disk; run; run; echo 50 >$T/disk; run
is "2-minute spike does not alert (ALERT_AFTER=3)" "$(msgs)" "0"

# 6 دقائق فوق الحد: تنبيه واحد فقط، ثم رسالة عودة واحدة بالمدة
echo 95 >$T/disk
for i in 1 2 3 4 5 6; do run; done
is "6 minutes at 95% -> exactly one alert" "$(msgs)" "1"
grep -q "🔴 <b>web-1</b>: القرص / 95%" $T/tg.log; ok "alert text names the server and the disk" $?
echo 50 >$T/disk; run; run
is "back to normal -> one recovery message" "$(msgs)" "2"
grep -q "✅ .*عاد طبيعياً.*استمر 6 دقائق" $T/tg.log; ok "recovery says how long it lasted" $?

# خدمة متوقفة: تنبيه بعد دقيقتين، وتيليجرام معطل وقتها: يعيد المحاولة في الدقيقة التالية
echo failed >$T/svc.mariadb
touch $T/tg.log.down
run; run
is "telegram down -> nothing delivered yet" "$(msgs)" "2"
rm $T/tg.log.down
run
is "delivered on the next run" "$(msgs)" "3"
grep -q "الخدمة mariadb: failed" $T/tg.log; ok "service alert text" $?
is "dashboard shows the failed service" "$(J "[s['state'] for s in d['services']]")" "['active', 'failed']"
rm $T/svc.mariadb; run
is "service recovered message" "$(msgs)" "4"
grep -q "عاد طبيعياً — الخدمة mariadb: active (استمر 3 دقائق)" $T/tg.log; ok "recovery duration in Arabic plural (3 دقائق)" $?

# الذاكرة: MemFree صغير جداً لكن المتاح كبير → لا تنبيه
mem 10000 700000; for i in 1 2 3 4; do run; done
is "low MemFree with plenty available does not alert" "$(msgs)" "4"

# inodes ممتلئة والمساحة فارغة
echo 97% >$T/inodes; for i in 1 2 3; do run; done
grep -q "القرص / (inodes) 97%" $T/tg.log; ok "inodes full alerts even with free space" $?
echo 5% >$T/inodes; run

# الشهادة: تُفحص مرة كل ساعة، وتنبّه فوراً إن قلّت عن 14 يوماً
calls=$(wc -l <$T/openssl.calls)
run
is "certificate not re-checked within the hour" "$(wc -l <$T/openssl.calls)" "$calls"
echo 10 >$T/certdays
NOW=$((NOW + 3600)); run
grep -q "شهادة example.com تنتهي بعد 10 أيام" $T/tg.log; ok "certificate expiring soon alerts" $?

# السجل يُقص على رأس الساعة إلى HISTORY_DAYS
for i in $(seq 1 1500); do echo "$i,1,1,1,1,0,0"; done >>$T/out/history.csv
NOW=$(( (NOW / 3600 + 1) * 3600 - 60 )); run
is "history trimmed to 1 day (1440 lines + header)" "$(wc -l <$T/out/history.csv | tr -d ' ')" "1441"

touch $T/reboot-required; run
is "reboot-required flag" "$(J "d['reboot_required']")" "True"

# قفل: تشغيلان معاً، الثاني يخرج بهدوء
exec 8>$T/state/.lock; flock 8
HEALTH_NOW=$((NOW + 60)) bash "$ROOT/health.sh" $T/h.conf; ok "second concurrent run exits quietly" $?
before=$(J "d['ts']"); is "and changes nothing" "$before" "$NOW"
flock -u 8

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
