// Droidspaces LKM 模块页：显示路线切换 + 诊断 + 懒人包跳转
//
// WebUI 调用走管理器注入的全局 ksu.exec（与 nomount 模块相同的调用方式）。
// 所有命令都在 root shell 里执行，写操作只动 module/route 一个文件。

const MOD = '/data/adb/modules/droidspaces_lkm';
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

const I18N = {
  zh: {
    title: 'Droidspaces LKM',
    subtitle: '显示路线 / 诊断',
    route_label: '显示路线',
    route_desc: '控制 Mali 上是走 waylandbridge（6.x）还是标准合成器（5.x）。改动重启后生效。',
    r_auto: '自动（保持现状）',
    r_a6: 'Anland 6.x：/dev/mali0 + mali_nsfix',
    r_d5: '标准桌面 5.x：vkms render node',
    apply: '应用（重启后生效）',
    diag_label: '诊断',
    pack_label: '懒人包',
    pack5: '5.x RootFS 构建仓库',
    pack6: '6.x Anland RootFS 仓库',
    toast_ok: '已写入 route，重启后生效。',
    toast_fail: '写入失败',
    open_fail: '打开链接失败'
  },
  en: {
    title: 'Droidspaces LKM',
    subtitle: 'Display route / Diagnostics',
    route_label: 'Display route',
    route_desc: 'Choose waylandbridge (6.x) or a standard compositor (5.x) on Mali. Takes effect after reboot.',
    r_auto: 'Auto (current behaviour)',
    r_a6: 'Anland 6.x: /dev/mali0 + mali_nsfix',
    r_d5: 'Standard desktop 5.x: vkms render node',
    apply: 'Apply (reboot required)',
    diag_label: 'Diagnostics',
    pack_label: 'One-click packs',
    pack5: '5.x RootFS builder repo',
    pack6: '6.x Anland RootFS repo',
    toast_ok: 'route written, applies after reboot.',
    toast_fail: 'Failed to write route',
    open_fail: 'Failed to open link'
  }
};

const locale = (navigator.language || 'zh').toLowerCase().startsWith('zh') ? 'zh' : 'en';
const t = (k) => (I18N[locale][k] ?? I18N.en[k] ?? k);

function applyI18n() {
  document.querySelectorAll('[data-i18n]').forEach((el) => {
    el.textContent = t(el.dataset.i18n);
  });
  document.documentElement.lang = locale === 'zh' ? 'zh-CN' : 'en';
}

const DIAG = [
  `echo "route=$(cat ${MOD}/route 2>/dev/null || echo auto)"`,
  `echo "kernel=$(uname -r)"`,
  `[ -e /dev/mali0 ] && echo mali0=yes || echo mali0=no`,
  `lsmod | grep -q '^mali_kbase' && echo mali_kbase=loaded || echo mali_kbase=no`,
  `for p in nshf_active nshf_probe_ok nshf_layout_valid nshf_driver nshf_seen nshf_hits; do echo "$p=$(cat /sys/module/mali_nsfix/parameters/$p 2>/dev/null)"; done`,
  `[ -e /dev/dri/renderD128 ] && echo renderD128=yes || echo renderD128=no`,
  `lsmod | grep -q '^vkms ' && echo vkms=loaded || echo vkms=no`
].join('; ');

async function load() {
  const r = await exec(DIAG);
  document.getElementById('diag').textContent =
    r.stdout || r.stderr || `exec failed (errno ${r.errno})`;

  const m = /^route=(.*)$/m.exec(r.stdout || '');
  const route = m ? m[1].trim() : 'auto';
  const badge = document.getElementById('routeNow');
  badge.textContent = route;
  badge.classList.toggle('on', route !== 'auto');
  document.querySelectorAll('input[name="route"]').forEach((el) => {
    el.checked = el.value === route;
  });
}

let _toastTimer;
function toast(msg, ok) {
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.className = 'toast ' + (ok ? 'ok' : 'fail');
  clearTimeout(_toastTimer);
  _toastTimer = setTimeout(() => {
    el.textContent = '';
    el.className = 'toast';
  }, 4000);
}

async function apply() {
  const sel = document.querySelector('input[name="route"]:checked');
  if (!sel) return;
  const r = await exec(
    `mkdir -p ${MOD} && printf '%s\\n' '${sel.value}' > ${MOD}/route`
  );
  toast(
    r.errno === 0 ? t('toast_ok') : t('toast_fail') + (r.stderr ? '\n' + r.stderr : ''),
    r.errno === 0
  );
  await load();
}

async function openLink(url) {
  const r = await exec(`am start -a android.intent.action.VIEW -d '${url}'`);
  if (r.errno !== 0) toast(t('open_fail') + '\n' + r.stderr, false);
}

window.addEventListener('DOMContentLoaded', () => {
  applyI18n();
  document.getElementById('apply').addEventListener('click', apply);
  document.getElementById('pack5').addEventListener('click', () => openLink(PACK5));
  document.getElementById('pack6').addEventListener('click', () => openLink(PACK6));
  load();
});
