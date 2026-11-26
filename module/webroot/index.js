// Droidspaces LKM 模块页（四页签：主页 / 路线 / 诊断 / 关于）
// 页面结构、样式与逻辑均为本项目独立编写。
// 与系统交互只走管理器注入的全局 ksu.exec。

const MOD = '/data/adb/modules/droidspaces_lkm';
const LOG = '/data/adb/droidspaces_lkm.log';
const PACK5 = 'https://github.com/misaka5202/Droidspaces-rootfs-Desktop-builder';
const PACK6 = 'https://github.com/misaka5202/droidspaces-anland6-rootfs';

const ROUTES = ['auto', 'anland6', 'desktop5'];
const MODULES = [
  'lkm4ctr', 'devtmpfs_lkm', 'ip6table_nat', 'macvlan',
  'droid_lkm_pids', 'droid_lkm_cpu', 'uart_guard', 'mali_nsfix', 'vkms'
];

const $ = (id) => document.getElementById(id);

/* ======================= shell 桥接 ======================= */

let cbSeq = 0;

function sh(cmd, timeoutMs = 15000) {
  return new Promise((resolve) => {
    const cb = `__dsl_${(cbSeq++).toString(36)}`;
    let timer = 0;
    let settled = false;

    const settle = (errno, stdout, stderr) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      delete window[cb];
      resolve({ errno, stdout: stdout ?? '', stderr: stderr ?? '' });
    };

    window[cb] = settle;
    timer = setTimeout(() => settle(124, '', 'timeout'), timeoutMs);

    try {
      if (typeof ksu !== 'undefined' && typeof ksu.exec === 'function') {
        ksu.exec(cmd, '{}', cb);
      } else {
        settle(1, '', 'ksu API not found');
      }
    } catch (e) {
      settle(1, '', String(e?.message ?? e));
    }
  });
}

/* ======================= i18n =======================
 * 新增语言：在 locales/ 放一份 <code>.json，并在 LANGS 里登记一行。
 * 缺失的键自动回退到英文，再回退到键名本身。
 */

const LANGS = [
  { code: 'en',    name: 'English',          htmlLang: 'en' },
  { code: 'zh',    name: '简体中文',          htmlLang: 'zh-CN' },
  { code: 'zh-TW', name: '繁體中文',          htmlLang: 'zh-TW' },
  { code: 'ja',    name: '日本語',            htmlLang: 'ja' },
  { code: 'ko',    name: '한국어',            htmlLang: 'ko' },
  { code: 'ru',    name: 'Русский',          htmlLang: 'ru' },
  { code: 'uk',    name: 'Українська',       htmlLang: 'uk' },
  { code: 'es',    name: 'Español',          htmlLang: 'es' },
  { code: 'pt-BR', name: 'Português (Brasil)', htmlLang: 'pt-BR' },
  { code: 'de',    name: 'Deutsch',          htmlLang: 'de' },
  { code: 'fr',    name: 'Français',         htmlLang: 'fr' },
  { code: 'it',    name: 'Italiano',         htmlLang: 'it' },
  { code: 'tr',    name: 'Türkçe',           htmlLang: 'tr' },
  { code: 'pl',    name: 'Polski',           htmlLang: 'pl' },
  { code: 'id',    name: 'Bahasa Indonesia', htmlLang: 'id' },
  { code: 'vi',    name: 'Tiếng Việt',       htmlLang: 'vi' },
  { code: 'th',    name: 'ไทย',              htmlLang: 'th' },
  { code: 'hi',    name: 'हिन्दी',             htmlLang: 'hi' },
  { code: 'ar',    name: 'العربية',          htmlLang: 'ar', rtl: true }
];
const LANG_STORE = 'dsl_locale';
const FALLBACK = 'en';

let lang = FALLBACK;
let dict = {};

function matchLang(tag) {
  const p = String(tag || '').toLowerCase();
  if (!p) return null;
  if (/^zh-(tw|hk|mo|hant)/.test(p)) return 'zh-TW';
  const exact = LANGS.find((l) => l.code.toLowerCase() === p);
  if (exact) return exact.code;
  const base = p.split('-')[0];
  const hit = LANGS.find((l) => l.code.toLowerCase().split('-')[0] === base);
  return hit ? hit.code : null;
}

function pickLang() {
  let saved = null;
  try { saved = localStorage.getItem(LANG_STORE); } catch { /* 存储不可用 */ }
  // 'system' 是「跟随系统」：不用缓存，每次按 navigator 重新检测
  if (saved !== 'system' && LANGS.some((l) => l.code === saved)) return saved;
  const prefs = navigator.languages?.length ? navigator.languages : [navigator.language];
  for (const p of prefs) {
    const hit = matchLang(p);
    if (hit) return hit;
  }
  return FALLBACK;
}

async function fetchLocale(code) {
  try {
    const r = await fetch(`./locales/${code}.json`);
    return r.ok ? await r.json() : {};
  } catch {
    return {};
  }
}

function t(key, vars) {
  let s = dict[key];
  if (s === undefined) {
    console.warn('[i18n] missing key:', key);
    s = key;
  }
  return vars ? s.replace(/{{\s*(\w+)\s*}}/g, (_, k) => vars[k] ?? '') : s;
}

async function setLang(code) {
  const wantSystem = code === 'system';
  const next = wantSystem ? pickLang()
                          : (LANGS.some((l) => l.code === code) ? code : FALLBACK);
  const [base, cur] = await Promise.all([
    fetchLocale(FALLBACK),
    next === FALLBACK ? {} : fetchLocale(next)
  ]);
  dict = { ...base, ...cur };
  lang = next;
  // 记住「跟随系统」这个选择本身，而不是记住当时解析出的语言
  try { localStorage.setItem(LANG_STORE, wantSystem ? 'system' : lang); } catch { /* 忽略 */ }
  const meta = LANGS.find((l) => l.code === lang);
  document.documentElement.lang = meta.htmlLang;
  document.documentElement.dir = meta.rtl ? 'rtl' : 'ltr';
}

// data-i18n="key" 写文本；data-i18n-attr="aria-label:key;title:key" 写属性
function applyI18n() {
  document.querySelectorAll('[data-i18n]').forEach((el) => {
    el.textContent = t(el.dataset.i18n);
  });
  document.querySelectorAll('[data-i18n-attr]').forEach((el) => {
    el.dataset.i18nAttr.split(';').forEach((pair) => {
      const [attr, key] = pair.split(':').map((s) => s.trim());
      if (attr && key) el.setAttribute(attr, t(key));
    });
  });
  document.title = t('app.title');
}

const routeName = (r) => (dict[`route.short.${r}`] ?? r);

/* ======================= 数据命令 ======================= */

const HOME_CMD = [
  `echo "route=$(cat ${MOD}/route 2>/dev/null || echo auto)"`,
  `echo "kernel=$(uname -r)"`,
  `echo "model=$(getprop ro.product.model 2>/dev/null)"`,
  `echo "version=$(grep -m1 '^version=' ${MOD}/module.prop 2>/dev/null | cut -d= -f2)"`,
  `[ -e /dev/mali0 ] && echo mali0=yes || echo mali0=no`,
  `lsmod | grep -q '^mali_kbase' && echo kbase=yes || echo kbase=no`,
  `[ -e /dev/dri/renderD128 ] && echo render=yes || echo render=no`,
  ...MODULES.map((m) =>
    `grep -q '^${m} ' /proc/modules && echo "mod:${m}=yes" || echo "mod:${m}=no"`
  )
].join('; ');

const DIAG_CMD = [
  `echo "route=$(cat ${MOD}/route 2>/dev/null || echo auto)"`,
  `echo "kernel=$(uname -r)"`,
  `echo "model=$(getprop ro.product.model 2>/dev/null)"`,
  `echo`,
  `echo "[modules]"`,
  `lsmod | grep -E '^(${MODULES.join('|')}) '`,
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

// 模块开关页：每个模块两行 —— sw:<name>=<1|0|-> (ko_switch 里的意图, -=未设置走默认)
// 和 ld:<name>=<yes|no> (当前是否已加载)。
const MODULES_CMD = [
  ...MODULES.map((m) =>
    `v=$(grep -E '^${m}=' ${MOD}/ko_switch 2>/dev/null | tail -1 | cut -d= -f2); ` +
    `case "$v" in 1|0) : ;; *) v=- ;; esac; echo "sw:${m}=$v"`
  ),
  ...MODULES.map((m) =>
    `grep -q '^${m} ' /proc/modules && echo "ld:${m}=yes" || echo "ld:${m}=no"`
  )
].join('; ');

function parseKv(stdout) {
  const out = {};
  String(stdout).split('\n').forEach((line) => {
    const i = line.indexOf('=');
    if (i > 0) out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  });
  return out;
}

/* ======================= 渲染 ======================= */

let lastHome = null;
let selectedRoute = 'auto';
// 每个模块的开关意图：'' = 跟随默认/路线，'1' = 强制加载，'0' = 强制不加载。
// 只在「模块」页刷新时由 ko_switch 内容初始化；用户改动后驻留在内存，
// 点「应用」才落盘 —— 与路线页 selectedRoute 的模式一致。
let moduleSel = {};
let lastModules = null;

function setNode(id, on, yesKey, noKey) {
  const el = $(id);
  el.textContent = t(on ? yesKey : noKey);
  el.classList.toggle('ok', on);
}

function renderHome(d) {
  lastHome = d;
  const route = ROUTES.includes(d.route) ? d.route : 'auto';
  const anyLoaded = MODULES.some((m) => d[`mod:${m}`] === 'yes');

  $('routeNow').textContent = routeName(route);
  $('routeText').textContent = routeName(route);
  $('status-title').textContent = t(anyLoaded ? 'state.running' : 'state.idle');
  $('status-indicator').textContent =
    `${t('info.route')}: ${routeName(route)} · ${t('info.kernel')}: ${d.kernel || '?'}`;
  $('hero').classList.toggle('is-bad', !anyLoaded);
  $('hero-icon').setAttribute('href', anyLoaded ? '#i-ok' : '#i-warn');

  $('kernel-version').textContent = d.kernel || '…';
  $('device-model').textContent = d.model || '…';
  $('about-version').textContent = d.version || '…';

  setNode('node-mali0', d.mali0 === 'yes', 'state.yes', 'state.no');
  setNode('node-kbase', d.kbase === 'yes', 'state.loaded', 'state.notLoaded');
  setNode('node-render', d.render === 'yes', 'state.yes', 'state.no');

  $('module-list').innerHTML = MODULES.map((m) => {
    const on = d[`mod:${m}`] === 'yes';
    return `<span class="chip ${on ? 'on' : 'off'}">${m}</span>`;
  }).join('');
}

function markSelected(route) {
  selectedRoute = route;
  document.querySelectorAll('.opt').forEach((el) => {
    const on = el.dataset.route === route;
    el.classList.toggle('is-on', on);
    const chip = el.querySelector('[data-chip]');
    if (chip) {
      chip.textContent = on ? t('route.selected') : '—';
      chip.className = `chip ${on ? 'on' : 'off'}`;
    }
  });
}

/* 模块开关页渲染：每行 [名称 + 加载状态] + [默认/开/关] 三段选择。
 * 意图来自 moduleSel（''/1/0）；当前加载状态来自 lastModules，仅作信息展示。
 * lkm4ctr 被显式关掉时弹警告条（它是容器 namespace 的前提）。 */
const SW_OPTS = ['', '1', '0'];
const swLabel = (v) => t(v === '' ? 'modules.default' : v === '1' ? 'modules.on' : 'modules.off');

function renderModules(d) {
  lastModules = d;
  const host = $('module-switches');
  host.innerHTML = MODULES.map((m) => {
    const ld = d[`ld:${m}`] === 'yes';
    const seg = SW_OPTS.map((v) =>
      `<button type="button" class="seg-btn" data-m="${m}" data-v="${v}">${swLabel(v)}</button>`
    ).join('');
    return (
      `<div class="row sw-row">` +
        `<span class="sw-name"><b>${m}</b>` +
          `<small>${t('modules.state')} · ${t(ld ? 'state.loaded' : 'state.notLoaded')}</small></span>` +
        `<span class="seg" data-seg="${m}">${seg}</span>` +
      `</div>`
    );
  }).join('');
  // 重新绑定：语言切换或刷新后 DOM 是新的
  host.querySelectorAll('.seg-btn').forEach((b) => {
    b.addEventListener('click', () => setSwitch(b.dataset.m, b.dataset.v));
  });
  markSwitches();
  const lkmOff = moduleSel.lkm4ctr === '0';
  $('lkm4ctr-warn').hidden = !lkmOff;
}

function setSwitch(name, val) {
  moduleSel[name] = val;
  markSwitches();
  $('lkm4ctr-warn').hidden = !(moduleSel.lkm4ctr === '0');
}

function markSwitches() {
  document.querySelectorAll('#module-switches .seg-btn').forEach((b) => {
    b.classList.toggle('is-on', (moduleSel[b.dataset.m] ?? '') === b.dataset.v);
  });
}

function buildLangSelect() {
  const btn = $('lang-select');
  const menu = $('lang-menu');

  // 「跟随系统」置顶；选中后清掉语言缓存，按 navigator 重新解析
  const sysLabel = t('about.language.system') || 'System default';
  const items = [{ code: 'system', name: sysLabel }, ...LANGS];
  menu.replaceChildren(...items.map((l) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'md-menu-item';
    b.setAttribute('role', 'option');
    b.dataset.lang = l.code;
    b.innerHTML = `<span>${l.name}</span><svg class="ic ic-check" aria-hidden="true"><use href="#i-check"/></svg>`;
    b.addEventListener('click', () => {
      closeLangMenu();
      changeLang(l.code);
    });
    return b;
  }));

  btn.addEventListener('click', (e) => {
    e.stopPropagation();
    if (menu.hidden) openLangMenu(); else closeLangMenu();
  });
  // 点外部 / Esc 关闭；不会和底栏、页面点击抢事件
  document.addEventListener('click', (e) => {
    if (!menu.hidden && !menu.contains(e.target) && e.target !== btn) closeLangMenu();
  });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') closeLangMenu();
  });

  markLang();
}

function openLangMenu() {
  $('lang-menu').hidden = false;
  $('lang-select').setAttribute('aria-expanded', 'true');
}

function closeLangMenu() {
  $('lang-menu').hidden = true;
  $('lang-select').setAttribute('aria-expanded', 'false');
}

function markLang() {
  const meta = LANGS.find((l) => l.code === lang);
  $('lang-label').textContent = meta ? meta.name : lang;
  $('lang-select').setAttribute('aria-label', t('about.language'));
  document.querySelectorAll('.md-menu-item').forEach((el) => {
    const on = el.dataset.lang === lang;
    el.classList.toggle('is-on', on);
    el.setAttribute('aria-selected', on ? 'true' : 'false');
  });
}

/* 界面风格：md3 / miuix */

const UIS = ['md3', 'miuix'];
const UI_STORE = 'dsl_ui';

function pickUi() {
  try {
    const s = localStorage.getItem(UI_STORE);
    if (UIS.includes(s)) return s;
  } catch { /* 忽略 */ }
  return 'md3';
}

function applyUi(ui) {
  const name = UIS.includes(ui) ? ui : 'md3';
  document.documentElement.dataset.ui = name;
  try { localStorage.setItem(UI_STORE, name); } catch { /* 忽略 */ }
  document.querySelectorAll('#ui-switch .seg-btn').forEach((b) => {
    b.classList.toggle('is-on', b.dataset.ui === name);
  });
  requestAnimationFrame(() => {
    const m = document.querySelector('meta[name="theme-color"]');
    if (m) m.content = getComputedStyle(document.body).backgroundColor;
  });
}

/* ======================= 数据刷新 ======================= */

async function refreshHome() {
  const r = await sh(HOME_CMD);
  const d = parseKv(r.stdout);
  renderHome(d);
  markSelected(ROUTES.includes(d.route) ? d.route : 'auto');
}

async function refreshDiag() {
  const r = await sh(DIAG_CMD);
  $('diag-out').textContent = r.stdout || r.stderr || t('diag.execFailed', { code: r.errno });
}

// 模块开关页：意图（sw:）用来初始化选择，加载状态（ld:）只做展示。
// 每次进入页面都重新读文件，保证和磁盘上的 ko_switch 一致。
async function refreshModules() {
  const r = await sh(MODULES_CMD);
  const d = parseKv(r.stdout);
  moduleSel = {};
  MODULES.forEach((m) => {
    const v = d[`sw:${m}`];
    moduleSel[m] = (v === '1' || v === '0') ? v : '';
  });
  renderModules(d);
}

async function applyModules() {
  // 只把显式选择了开/关的键写进 ko_switch；「跟随默认」的模块不落盘 ——
  // service.sh 里缺键 = 走旧开关/route/默认，这正是「跟随」的语义。
  const lines = MODULES
    .filter((m) => moduleSel[m] === '1' || moduleSel[m] === '0')
    .map((m) => `${m}=${moduleSel[m]}`);
  let cmd;
  if (lines.length) {
    // 模块名与 0/1 都是固定白名单字符，拼进 printf 的格式串安全；
    // printf 会把 \n 解释成真正的换行，逐条写入 ko_switch。
    cmd = `mkdir -p ${MOD} && printf '${lines.join('\\n')}\\n' > ${MOD}/ko_switch && sync`;
  } else {
    // 全部跟随默认 = 删除文件；service.sh 见不到文件即全走默认。
    cmd = `rm -f ${MOD}/ko_switch && sync`;
  }
  const r = await sh(cmd);
  toast(t(r.errno === 0 ? 'modules.toast.saved' : 'modules.toast.saveFailed'));
  await refreshModules();
}

/* ======================= 交互 ======================= */

let toastTimer = 0;
function toast(msg) {
  const el = $('toast');
  el.textContent = msg;
  el.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('show'), 2600);
}

async function applyRoute() {
  if (!ROUTES.includes(selectedRoute)) return;
  const r = await sh(`mkdir -p ${MOD} && printf '%s\\n' '${selectedRoute}' > ${MOD}/route`);
  toast(t(r.errno === 0 ? 'toast.saved' : 'toast.saveFailed'));
  await refreshHome();
}

async function copyDiag() {
  const text = $('diag-out').textContent || '';
  try {
    await navigator.clipboard.writeText(text);
    toast(t('toast.copied'));
    return;
  } catch { /* 非安全上下文时走回退 */ }
  const ta = document.createElement('textarea');
  ta.value = text;
  ta.style.cssText = 'position:fixed;opacity:0;pointer-events:none';
  document.body.appendChild(ta);
  ta.select();
  let ok = false;
  try { ok = document.execCommand('copy'); } catch { /* 忽略 */ }
  ta.remove();
  toast(t(ok ? 'toast.copied' : 'toast.copyFailed'));
}

async function openLink(url) {
  const r = await sh(`am start -a android.intent.action.VIEW -d '${url}'`);
  if (r.errno !== 0) toast(t('toast.openFailed'));
}

function syncAppbar() {
  $('appbar').classList.toggle('is-on', $('scroller').scrollTop > 48);
}

let currentView = 'view-home';

function switchView(target) {
  currentView = target;
  document.querySelectorAll('.page').forEach((el) => {
    el.classList.toggle('is-active', el.id === target);
  });
  document.querySelectorAll('.tab').forEach((el) => {
    el.classList.toggle('is-active', el.dataset.target === target);
  });
  $('appbar-title').textContent = t(`tab.${target.replace('view-', '')}`);
  $('scroller').scrollTop = 0;
  syncAppbar();
  if (target === 'view-diag') refreshDiag();
  if (target === 'view-home') refreshHome();
  if (target === 'view-modules') refreshModules();
}

// 切换语言只重绘文本，不重新执行 shell 命令
async function changeLang(code) {
  if (code === lang) return;
  await setLang(code);
  applyI18n();
  markLang();
  markSelected(selectedRoute);
  if (lastHome) renderHome(lastHome);
  if (lastModules) renderModules(lastModules);
  $('appbar-title').textContent = t(`tab.${currentView.replace('view-', '')}`);
}

/* ======================= 平台判定 =======================
 * 非 MTK（含高通等）隐藏「切换路线」底栏：路线只对 Mali 有意义，
 * 装到别的平台只会让人误以为可以切换。
 */
async function platformIsMtk() {
  const r = await sh([
    'getprop ro.board.platform',
    'getprop ro.soc.model',
    'getprop ro.hardware'
  ].join('; '));
  const s = String(r.stdout || '').toLowerCase();
  return /mtk|mediatek|(^|[^a-z])mt[0-9]/.test(s);
}

function hideRouteTabIfNotMtk() {
  const tab = document.querySelector('.tab[data-target="view-route"]');
  if (tab) tab.remove();
}

/* ======================= 启动 ======================= */

(async function boot() {
  await setLang(pickLang());
  applyI18n();
  buildLangSelect();
  if (!(await platformIsMtk())) hideRouteTabIfNotMtk();
  document.querySelectorAll('#ui-switch .seg-btn').forEach((b) => {
    b.addEventListener('click', () => applyUi(b.dataset.ui));
  });
  applyUi(pickUi());

  document.querySelectorAll('.tab').forEach((el) => {
    el.addEventListener('click', () => switchView(el.dataset.target));
  });
  document.querySelectorAll('.opt').forEach((el) => {
    el.addEventListener('click', () => markSelected(el.dataset.route));
  });
  $('scroller').addEventListener('scroll', syncAppbar, { passive: true });
  $('apply-route').addEventListener('click', applyRoute);
  $('apply-modules').addEventListener('click', applyModules);
  $('copy-diag').addEventListener('click', copyDiag);
  $('pack5').addEventListener('click', () => openLink(PACK5));
  $('pack6').addEventListener('click', () => openLink(PACK6));

  $('appbar-title').textContent = t('tab.home');
  await refreshHome();
  document.body.classList.remove('booting');
})();
