# لوحة صحة السيرفر بالعربية (Bash + HTML)

سكربت Bash واحد يقرأ صحة سيرفرك كل دقيقة، ولوحة HTML ثابتة تعرضها مع رسوم لآخر 24 ساعة، وتنبيهات على تيليجرام حين يتجاوز شيء حده وحين يعود.

بلا Node ولا Python ولا قاعدة بيانات ولا وكيل (agent) يعمل طوال الوقت: `bash` و`awk` و`curl`، وcron يشغّل السكربت كل دقيقة، وNginx يقدّم ملفات ثابتة.

شرح المشروع كاملاً، وكيف اختبرناه: **https://qeeid.com/server-health-dashboard-bash-source-code/**

## ما تعرضه اللوحة

- **المعالج**: النسبة من فرق قراءتين لـ `/proc/stat`، ومعها انتظار القرص (iowait) والوقت المسروق (steal) الذي يكشف جاراً مزعجاً على VPS
- **الذاكرة**: المستعمل = الكلي − المتاح (`MemAvailable`)، لا `MemFree` الذي يحسب الكاش «مستعملاً»، والـ swap
- **الحمل** مقارنة بعدد الأنوية
- **الأقراص**: المساحة وعُقد الملفات (inodes) لكل قرص
- **الشبكة**: سرعة الاستقبال والإرسال
- **الخدمات**: حالة كل خدمة systemd تحددها (nginx، php-fpm، mariadb...)
- **الشهادات**: الأيام المتبقية لكل نطاق (تُفحص مرة كل ساعة)
- التحديثات المعلّقة، وهل يحتاج السيرفر إعادة تشغيل، وأكثر العمليات استهلاكاً للذاكرة
- شريط أحمر إن توقفت القراءات أكثر من 3 دقائق (cron متوقف أو السيرفر طافٍ)، فلا تطمئنك أرقام قديمة

## التنبيهات

- تنبيه واحد بعد 3 دقائق متتالية فوق الحد (قابلة للتغيير)، لا رسالة كل دقيقة، ولا تنبيه لقفزة لحظية
- رسالة عودة واحدة بالمدة: «عاد طبيعياً — القرص / 50% (استمر 6 دقائق)»
- الخدمة المتوقفة بعد دقيقتين، والشهادة القريبة من الانتهاء فوراً
- إن تعطل تيليجرام وقت التنبيه يعيد المحاولة في الدقيقة التالية

## التثبيت (Ubuntu / Debian مع Nginx)

```bash
git clone https://github.com/copissblog-alt/server-health-dashboard-ar.git
cd server-health-dashboard-ar
sudo bash install.sh
```

السكربت:
- ينشئ مستخدماً بلا صلاحيات اسمه `health`، فلا يحتاج القراءة root
- ينسخ اللوحة إلى `/var/www/server-health`
- يضيف سطر cron كل دقيقة
- ينشئ كلمة مرور للوحة ويطبعها لك
- يطبع لك مقطع Nginx لتضيفه داخل `server { }` لموقعك

ثم عدّل `/etc/server-health/health.conf`: الخدمات، والنطاقات، وحدود التنبيه، وتوكن تيليجرام. وافتح `https://موقعك/server-health/`.

اللوحة محمية بكلمة مرور (Basic Auth)، فافتحها على HTTPS فقط: فيها أسماء خدماتك وعملياتك.

## الاختبارات

```bash
bash tests/run.sh
```

34 اختباراً على `/proc` مزيف وأوامر مزيفة (`df` و`systemctl` و`ps` و`openssl`) وخادم تيليجرام مزيف: حساب المعالج والذاكرة والشبكة، والأقراص وعُقد الملفات، والتنبيه الواحد والعودة بالمدة، والقفزة القصيرة بلا تنبيه، وتعطل تيليجرام، والخدمات، والشهادات وفحصها كل ساعة، وقص السجل، والقفل.

## الهيكل

```
health.sh            القراءة والتنبيه (يشغّله cron كل دقيقة)
dashboard/           اللوحة: index.html و app.js و style.css
health.conf.example  الإعداد
install.sh           التثبيت
tests/               الاختبارات
```

## الترخيص

MIT

---

**Arabic server health dashboard** — one Bash script run by cron every minute writes `status.json` + `history.csv`; a static RTL HTML dashboard shows CPU (iowait/steal), memory (MemAvailable), load, disks + inodes, network, systemd services, TLS expiry, pending updates, 24h charts; deduplicated Telegram alerts with recovery duration. MIT.
