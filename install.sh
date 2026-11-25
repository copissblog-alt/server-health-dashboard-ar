#!/usr/bin/env bash
# تثبيت لوحة صحة السيرفر على Ubuntu/Debian مع Nginx. شغّله كـ root من مجلد المشروع:
#   sudo bash install.sh
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "شغّله بـ sudo"; exit 1; }
cd "$(dirname "$0")"

id health >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin health
install -d -m 755 /opt/server-health /etc/server-health
install -m 755 health.sh /opt/server-health/health.sh
install -d -o health -g health -m 755 /var/www/server-health /var/lib/server-health
install -o health -g health -m 644 dashboard/index.html dashboard/app.js dashboard/style.css /var/www/server-health/
[ -f /etc/server-health/health.conf ] || install -m 644 health.conf.example /etc/server-health/health.conf

# كل دقيقة، بمستخدم بلا صلاحيات (لا يحتاج root لقراءة /proc و systemctl is-active)
echo '* * * * * health /opt/server-health/health.sh /etc/server-health/health.conf >/dev/null 2>&1' >/etc/cron.d/server-health
chmod 644 /etc/cron.d/server-health

# كلمة مرور اللوحة (Basic Auth)
if [ ! -f /etc/nginx/server-health.htpasswd ]; then
  pass=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)
  printf 'admin:%s\n' "$(openssl passwd -apr1 "$pass")" >/etc/nginx/server-health.htpasswd
  chown root:www-data /etc/nginx/server-health.htpasswd 2>/dev/null || true
  chmod 640 /etc/nginx/server-health.htpasswd
  echo "اسم المستخدم: admin"
  echo "كلمة المرور:  $pass   (احفظها الآن، لن تظهر مرة أخرى)"
fi

sudo -u health /opt/server-health/health.sh /etc/server-health/health.conf && echo "✔ أول قراءة: /var/www/server-health/status.json"
cat <<'NGINX'

أضف هذا داخل server { } لموقعك في Nginx (على HTTPS)، ثم: nginx -t && systemctl reload nginx

    location /server-health/ {
        alias /var/www/server-health/;
        auth_basic "Server health";
        auth_basic_user_file /etc/nginx/server-health.htpasswd;
        add_header Cache-Control "no-store" always;
        add_header Content-Security-Policy "default-src 'self'; frame-ancestors 'none'" always;
        add_header X-Robots-Tag "noindex" always;
    }

ثم عدّل /etc/server-health/health.conf (الخدمات، النطاقات، تيليجرام).
NGINX
