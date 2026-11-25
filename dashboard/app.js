// لوحة صحة السيرفر: تقرأ status.json و history.csv اللذين يكتبهما health.sh كل دقيقة
'use strict';
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
// عزل الرقم مع وحدته باتجاه اليسار لليمين، فلا تنقلب "4.8 GB" إلى "GB 4.8" داخل نص عربي
const iso = (s) => '\u2066' + s + '\u2069';
const gb = (kb) => iso(kb >= 1048576 ? (kb / 1048576).toFixed(1) + ' GB' : Math.round(kb / 1024) + ' MB');
const rate = (b) => iso(b >= 1048576 ? (b / 1048576).toFixed(1) + ' MB/s' : b >= 1024 ? Math.round(b / 1024) + ' KB/s' : b + ' B/s');
const pc = (v) => iso(v + '%');

function ago(sec) {
  if (sec < 90) return 'الآن';
  if (sec < 3600) return `قبل ${Math.round(sec / 60)} دقيقة`;
  return `قبل ${Math.round(sec / 3600)} ساعة`;
}

function uptime(s) {
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  const day = d === 1 ? 'يوم' : d === 2 ? 'يومان' : d <= 10 ? `${d} أيام` : `${d} يوماً`;
  return d ? (h ? `${day} و${h} ساعة` : day) : h ? `${h} ساعة و${m} دقيقة` : `${m} دقيقة`;
}

/** مستوى اللون: سليم، تحذير قبل الحد بـ 15، تجاوز الحد */
function level(v, warn) {
  return v >= warn ? 'bad' : v >= warn - 15 ? 'warn' : 'ok';
}

function setCard(id, lvl) {
  const c = $(id);
  c.classList.remove('ok', 'warn', 'bad');
  c.classList.add(lvl);
}

/** رسم خط بسيط: آخر 24 ساعة، متوسط كل 5 دقائق */
function chart(svg, points, max, guide) {
  if (!points.length) { svg.innerHTML = ''; return; }
  const top = Math.max(max, ...points.map((p) => p[1])) || 1;
  const t0 = points[0][0], t1 = points[points.length - 1][0] || t0 + 1;
  const xy = points.map(([t, v]) => `${((t - t0) / Math.max(1, t1 - t0) * 300).toFixed(1)},${(58 - v / top * 56).toFixed(1)}`);
  const g = guide ? `<line x1="0" x2="300" y1="${58 - guide / top * 56}" y2="${58 - guide / top * 56}" class="guide"/>` : '';
  svg.innerHTML = `${g}<polyline points="0,58 ${xy.join(' ')} 300,58" class="area"/><polyline points="${xy.join(' ')}" class="line"/>`;
}

function bucket(rows, col, now) {
  const out = new Map();
  for (const r of rows) {
    if (r.ts < now - 86400) continue;
    const k = Math.floor(r.ts / 300) * 300;
    const b = out.get(k) || [0, 0];
    b[0] += r[col]; b[1]++;
    out.set(k, b);
  }
  return [...out].map(([k, [s, n]]) => [k, s / n]);
}

async function load() {
  let s, rows = [];
  try {
    s = await (await fetch('status.json', { cache: 'no-store' })).json();
    const csv = await (await fetch('history.csv', { cache: 'no-store' })).text();
    const [head, ...lines] = csv.trim().split('\n');
    const cols = head.split(',');
    rows = lines.map((l) => Object.fromEntries(l.split(',').map((v, i) => [cols[i], Number(v)])));
  } catch (e) {
    $('when').textContent = 'تعذر قراءة status.json: هل يعمل health.sh؟';
    return;
  }
  const now = Math.floor(Date.now() / 1000);
  const age = now - s.ts;
  document.title = `${s.server} · صحة السيرفر`;
  $('server').textContent = s.server;
  $('when').textContent = `آخر قراءة ${ago(age)} · يعمل منذ ${uptime(s.uptime)}`;
  const stale = $('stale');
  stale.hidden = age < 180;
  stale.textContent = `آخر قراءة قبل ${Math.round(age / 60)} دقيقة: health.sh لا يعمل (cron؟)، أو السيرفر متوقف. الأرقام أدناه قديمة.`;

  const w = s.warn;
  const loadPer = s.load[0] / s.cores;
  const lv = {
    cpu: level(s.cpu.pct, w.cpu), mem: level(s.mem.pct, w.mem),
    load: loadPer >= w.load ? 'bad' : loadPer >= w.load * 0.75 ? 'warn' : 'ok',
  };
  $('cpu').textContent = pc(s.cpu.pct);
  $('cpu-sub').textContent = `${s.cores} أنوية · انتظار القرص ${pc(s.cpu.iowait)}${s.cpu.steal > 0 ? ` · مسروق ${pc(s.cpu.steal)}` : ''}`;
  $('mem').textContent = pc(s.mem.pct);
  $('mem-sub').textContent = `${gb(s.mem.used_kb)} من ${gb(s.mem.total_kb)} · متاح ${gb(s.mem.available_kb)}${s.swap.total_kb ? ` · swap ${pc(s.swap.pct)}` : ''}`;
  $('load').textContent = s.load[0].toFixed(2);
  $('load-sub').textContent = `5 د: ${s.load[1].toFixed(2)} · 15 د: ${s.load[2].toFixed(2)} · ${s.cores} أنوية`;
  $('net').textContent = iso('↓ ' + rate(s.net.rx_bps));
  $('net-sub').textContent = 'إرسال ' + rate(s.net.tx_bps);
  for (const k of ['cpu', 'mem', 'load']) setCard('c-' + k, lv[k]);

  chart($('ch-cpu'), bucket(rows, 'cpu', now), 100, w.cpu);
  chart($('ch-mem'), bucket(rows, 'mem', now), 100, w.mem);
  chart($('ch-load'), bucket(rows, 'load1', now), s.cores, s.cores);
  chart($('ch-net'), bucket(rows, 'rx', now), 1, 0);

  let worst = Object.values(lv);
  $('disks').innerHTML = s.disks.map((d) => {
    const l = level(Math.max(d.pct, d.inodes_pct), w.disk);
    worst.push(l);
    return `<div class="disk ${l}"><div class="row"><b dir="ltr">${esc(d.mount)}</b><span>${pc(d.pct)} · متبقٍ ${gb(d.avail_kb)}</span></div>
      <div class="bar"><i data-w="${Number(d.pct)}"></i></div>${d.inodes_pct >= 50 ? `<small>عُقد الملفات (inodes): ${pc(d.inodes_pct)}</small>` : ''}</div>`;
  }).join('');
  for (const bar of document.querySelectorAll('.bar i')) bar.style.width = bar.dataset.w + '%'; // تعمل مع CSP التي تمنع style في HTML

  $('services').innerHTML = s.services.length ? s.services.map((x) => {
    worst.push(x.state === 'active' ? 'ok' : 'bad');
    return `<li><span class="dot ${x.state === 'active' ? 'ok' : 'bad'}"></span><span dir="ltr">${esc(x.name)}</span><em>${x.state === 'active' ? 'تعمل' : esc(x.state)}</em></li>`;
  }).join('') : '<li class="muted">لم تُحدَّد خدمات (SERVICES في الإعداد)</li>';
  $('certs').innerHTML = s.certs.length ? s.certs.map((c) => {
    const l = c.days < 0 ? 'bad' : c.days < w.cert_days ? 'bad' : c.days < 30 ? 'warn' : 'ok';
    worst.push(l);
    return `<li><span class="dot ${l}"></span><span dir="ltr">${esc(c.host)}</span><em>${c.days < 0 ? 'لا ترد' : `${c.days} يوماً`}</em></li>`;
  }).join('') : '<li class="muted">لم تُحدَّد نطاقات (CERTS في الإعداد)</li>';

  $('system').innerHTML = [
    ['تحديثات معلّقة', s.updates ? `${s.updates} حزمة` : 'لا يوجد', s.updates > 0 ? 'warn' : 'ok'],
    ['يحتاج إعادة تشغيل', s.reboot_required ? 'نعم' : 'لا', s.reboot_required ? 'warn' : 'ok'],
    ['الذاكرة الفارغة تماماً (MemFree)', gb(s.mem.free_kb), 'ok'],
  ].map(([k, v, l]) => `<li><span class="dot ${l}"></span>${k}<em>${v}</em></li>`).join('');
  $('top').tBodies[0].innerHTML = s.top.map((p) => `<tr><td dir="ltr">${esc(p.name)}</td><td>${pc(p.mem)}</td><td>${pc(p.cpu)}</td></tr>`).join('');

  const o = worst.includes('bad') ? 'bad' : worst.includes('warn') ? 'warn' : 'ok';
  $('overall').className = 'pill ' + (age >= 180 ? 'bad' : o);
  $('overall').textContent = age >= 180 ? 'لا قراءات' : { ok: 'كل شيء سليم', warn: 'انتبه', bad: 'مشكلة' }[o];
}

load();
setInterval(load, 60000);
