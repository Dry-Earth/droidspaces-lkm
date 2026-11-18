// Droidspaces LKM 模块页（Material You / M3，底栏四页签）
//
// 视觉与组件衍生自 misaka5202/nomount 的模块 WebUI（GPL-3.0）；
// 业务逻辑、页面结构与文案为本项目的自写代码。
// exec 走管理器注入的全局 ksu.exec（与 nomount 相同）。

const MOD = '/data/adb/modules/droidspaces_lkm';
const LOG = '/data/adb/droidspaces_lkm.log';
const PACK5 = 'https://github.com/misaka5202/Droidspaces-rootfs-Desktop-builder';
const PACK6 = 'https://github.com/misaka5202/droidspaces-anland6-rootfs';

let _cbId = 0;

function exec(cmd) {
  return new Promise((resolve) => {
    const key = `_dsl_cb_${Date.now()}_${_cbId++}`;
    const done = (errno, stdout, stderr) => {
      delete window[key];
      resolve({ errno, stdout: stdout || '', stderr: stderr || '' });
    };
    window[key] = done;
    try {
      if (typeof ksu !== 'undefined' && typeof ksu.exec === 'function') {
        ksu.exec(cmd, '{}', key);
      } else {
        done(1, '', 'ksu API not found');
      }
    } catch (e) {
      done(1, '', String(e && e.message ? e.message : e));
    }
  });
}

/* ---------------- i18n ---------------- */

const LOCALE_KEY = 'dsl_locale';
let lang = localStorage.getItem(LOCALE_KEY) ||
  ((navigator.language || 'zh').toLowerCase().startsWith('zh') ? 'zh' : 'en');
let strings = {};
const TPL_RE = /{{\s*([^\s}]+)\s*}}/g;

function t(key, reps) {
  let s = strings[key] ?? key;
  if (reps) s = String(s).replace(TPL_RE, (_, k) => (reps[k] ?? ''));
  return s;
}

async function loadLocale(newLang) {
  lang = newLang === 'zh' || newLang === 'en' ? newLang : 'en';
  try {
    const r = await fetch(`./locales/${lang}.json`);
    strings = r.ok ? await r.json() : {};
  } catch {
    strings = {};
  }
  localStorage.setItem(LOCALE_KEY, lang);
  document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
}

function applyI18n() {
  document.querySelectorAll('[data-i18n]').forEach((el) => {
    el.textContent = t(el.dataset.i18n);
  });
}

/* ---------------- 数据命令 ---------------- */

const MODULES = [
  'lkm4ctr', 'devtmpfs_lkm', 'ip6table_nat', 'macvlan',
  'droid_lkm_pids', 'droid_lkm_cpu', 'uart_guard', 'mali_nsfix', 'vkms'
];

const HOME_CMD = [
  `echo "route=$(cat ${MOD}/route 2>/dev/null || echo auto)"`,
  `echo "kernel=$(uname -r)"`,
  `echo "model=$(getprop ro.product.model 2>/dev/null)"`,
  `echo "version=$(grep -m1 '^version=' ${MOD}/module.prop 2>/dev/null | cut -d= -f2)"`,
  `[ -e /dev/mali0 ] && echo mali0=yes || echo mali0=no`,
  `lsmod | grep -q '^mali_kbase' && echo kbase=yes || echo kbase=no`,
  `[ -e /dev/dri/renderD128 ] && echo render=yes || echo render=no`,
  ...MODULES.map((m) =>
    `grep -q '^${m} ' /proc/modules && echo "mod:${m}:yes" || echo "mod:${m}:no"`
  )
].join('; ');

const DIAG_CMD = [
  `echo "route=$(cat ${MOD}/route 2>/dev/null || echo auto)"`,
  `echo "kernel=$(uname -r)"`,
  `echo "model=$(getprop ro.product.model 2>/dev/null)"`,
  `echo`,
  `echo "[modules]"`,
  `lsmod | grep -E '^(lkm4ctr|devtmpfs_lkm|ip6table_nat|macvlan|vkms|droid_lkm_pids|droid_lkm_cpu|uart_guard|mali_nsfix) '`,
  `echo`,
  `echo "[mali_nsfix]"`,
  ...['nshf_active', 'nshf_probe_ok', 'nshf_layout_valid', 'nshf_driver', 'nshf_seen', 'nshf_hits']
    .map((p) => `echo "${p}=$(cat /sys/module/mali_nsfix/parameters/${p} 2>/dev/null)"`),
  `echo`,
  `echo "[nodes]"`,
  `[ -e /dev/mali0 ] && echo mali0=yes || echo mali0=no`,
  `[ -e /dev/dri/renderD128 ] && echo renderD128=yes || echo renderD128=no`,
  `echo`,
  `echo "[log tail]"`,
  `tail -n 40 ${LOG} 2>/dev/null`,
  `echo`,
  `echo "[dmesg]"`,
  `dmesg 2>/dev/null | grep -aE 'mali_nsfix|vkms|droid_lkm' | tail -n 20`
].join('; ');

function parseLines(stdout) {
  const map = {};
  (stdout || '').split('\n').forEach((line) => {
    const i = line.indexOf('=');
    if (i > 0) map[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  });
  return map;
}

/* ---------------- 视图渲染 ---------------- */

const $ = (id) => document.getElementById(id);

function renderHome(d) {
  const route = d.route || 'auto';
  $('routeNow').textContent = route;
  $('routeText').textContent = route;

  const anyLoaded = MODULES.some((m) => d[`mod:${m}`] === 'yes');
  $('status-title').textContent = anyLoaded ? t('status_ok') : t('status_idle');
  $('status-indicator').textContent =
    `${t('route_label')}: ${route} · ${t('kernel_label')}: ${d.kernel || '?'}`;

  $('kernel-version').textContent = d.kernel || '…';
  $('device-model').textContent = d.model || '…';

  $('node-mali0').textContent = d.mali0 === 'yes' ? t('yes') : t('no');
  $('node-mali0').classList.toggle('ok', d.mali0 === 'yes');
  $('node-kbase').textContent = d.kbase === 'yes' ? t('loaded') : t('not_loaded');
  $('node-kbase').classList.toggle('ok', d.kbase === 'yes');
  $('node-render').textContent = d.render === 'yes' ? t('yes') : t('no');
  $('node-render').classList.toggle('ok', d.render === 'yes');

  $('module-list').innerHTML = MODULES.map((m) => {
    const on = d[`mod:${m}`] === 'yes';
    return `<span class="md-chip ${on ? 'status-active' : 'status-inactive'}">${m}</span>`;
  }).join('');

  $('about-version').textContent = d.version || '…';
}

function renderRoute(d) {
  const route = d.route || 'auto';
  document.querySelectorAll('.route-opt').forEach((el) => {
    const active = el.dataset.route === route;
    el.classList.toggle('active', active);
    const chip = el.querySelector('[data-chip]');
    if (chip) {
      chip.textContent = active ? t('selected') : '—';
      chip.className = 'md-chip ' + (active ? 'status-active' : 'status-inactive');
    }
  });
}

let selectedRoute = 'auto';

function markSelected(route) {
  selectedRoute = route;
  document.querySelectorAll('.route-opt').forEach((el) => {
    const active = el.dataset.route === route;
    el.classList.toggle('active', active);
    const chip = el.querySelector('[data-chip]');
    if (chip) {
      chip.textContent = active ? t('selected') : '—';
      chip.className = 'md-chip ' + (active ? 'status-active' : 'status-inactive');
    }
  });
}

async function refreshHome() {
  const r = await exec(HOME_CMD);
  const d = parseLines(r.stdout);
  renderHome(d);
  renderRoute(d);
  selectedRoute = d.route || 'auto';
  return d;
}

async function refreshDiag() {
  const r = await exec(DIAG_CMD);
  $('diag-out').textContent = r.stdout || r.stderr || `exec failed (${r.errno})`;
}

/* ---------------- 交互 ---------------- */

let toastTimer;
function toast(msg) {
  const el = $('toast');
  el.textContent = msg;
  el.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('show'), 2600);
}

async function applyRoute() {
  const r = await exec(`mkdir -p ${MOD} && printf '%s\\n' '${selectedRoute}' > ${MOD}/route`);
  toast(r.errno === 0 ? t('toast_ok') : t('toast_fail'));
  await refreshHome();
}

async function copyDiag() {
  const text = $('diag-out').textContent || '';
  try {
    await navigator.clipboard.writeText(text);
    toast(t('copied'));
  } catch {
    toast('clipboard unavailable');
  }
}

async function openLink(url) {
  const r = await exec(`am start -a android.intent.action.VIEW -d '${url}'`);
  if (r.errno !== 0) toast('open failed');
}

function switchView(target) {
  document.querySelectorAll('.view-content').forEach((el) => {
    el.classList.toggle('active', el.id === target);
  });
  document.querySelectorAll('.nav-item').forEach((el) => {
    el.classList.toggle('active', el.dataset.target === target);
  });
  const tab = target.replace('view-', '');
  $('top-app-bar-title').textContent = t('nav_' + tab);
  if (target === 'view-diag') refreshDiag();
  if (target === 'view-home') refreshHome();
}

/* ---------------- 启动 ---------------- */

(async function init() {
  await loadLocale(lang);
  applyI18n();

  document.querySelectorAll('.nav-item').forEach((el) => {
    el.addEventListener('click', () => switchView(el.dataset.target));
  });
  document.querySelectorAll('.route-opt').forEach((el) => {
    el.addEventListener('click', () => markSelected(el.dataset.route));
  });
  $('apply-route').addEventListener('click', applyRoute);
  $('copy-diag').addEventListener('click', copyDiag);
  $('pack5').addEventListener('click', () => openLink(PACK5));
  $('pack6').addEventListener('click', () => openLink(PACK6));

  const setLang = async (l) => {
    await loadLocale(l);
    applyI18n();
    await refreshHome();
    switchView('view-about');
  };
  $('lang-zh').addEventListener('click', () => setLang('zh'));
  $('lang-en').addEventListener('click', () => setLang('en'));

  await refreshHome();
  $('top-app-bar-title').textContent = t('nav_home');
  document.body.classList.remove('loading');
})();