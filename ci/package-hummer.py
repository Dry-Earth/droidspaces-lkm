#!/usr/bin/env python3
"""Package the hummer exact-KDIR build with this repository's KernelSU module.

The module template is the upstream one; only module.prop is adjusted so the
installed module cannot be replaced by the generic upstream update channel,
and so the description names the exact kernel release it was built for.
"""
import argparse
import hashlib
import json
import re
import struct
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / 'module'
SCRIPTS = ('module.prop', 'customize.sh', 'post-fs-data.sh', 'service.sh',
           'uninstall.sh', 'action.sh', 'boot-completed.sh')
REQUIRED = ('lkm4ctr',)
OPTIONAL = ('devtmpfs_lkm', 'macvlan', 'ip6table_nat', 'vkms',
            'droid_lkm_pids', 'droid_lkm_cpu', 'uart_guard')


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def check_arm64(path: Path) -> bytes:
    data = path.read_bytes()
    if len(data) < 64 or data[:6] != b'\x7fELF\x02\x01':
        raise SystemExit(f'{path}: not ELF64 little-endian')
    if struct.unpack_from('<H', data, 18)[0] != 183:
        raise SystemExit(f'{path}: not AArch64')
    return data


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--kos', type=Path, required=True)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--release', required=True)
    ap.add_argument('--kernel-sha', default='')
    ap.add_argument('--kmi', default='android15-6.6')
    args = ap.parse_args()

    built = {}
    suffix = f'-{args.kmi}.ko'
    for ko in sorted(args.kos.glob('*.ko')):
        name = ko.name
        if not name.endswith(suffix):
            continue
        built[name[:-len(suffix)]] = (name, check_arm64(ko))
    missing = [m for m in REQUIRED if m not in built]
    if missing:
        raise SystemExit(f'missing mandatory modules: {missing}')
    absent = [m for m in OPTIONAL if m not in built]
    if absent:
        print(f'warning: modules not built: {absent}')

    prop = (TEMPLATE / 'module.prop').read_text()
    version = re.search(r'^version=(.*)$', prop, re.M).group(1).strip()
    prop = re.sub(r'^updateJson=.*\n', '', prop, flags=re.M)
    prop = re.sub(r'^name=.*$', 'name=Droidspaces LKM (hummer)', prop, count=1, flags=re.M)
    prop = re.sub(r'^version=.*$', f'version={version}-hummer', prop, count=1, flags=re.M)
    prop = re.sub(
        r'^description=.*$',
        f'description=Exact build for OnePlus Ace 5 Pro (hummer), kernel '
        f'{args.release}. PID/IPC/UTS namespaces, devtmpfs, macvlan, IPv6 NAT, '
        f'virtual DRM, cgroup CPU/PID limits.',
        prop, count=1, flags=re.M)

    files = {'module.prop': prop.encode()}
    for name in SCRIPTS[1:]:
        files[name] = (TEMPLATE / name).read_bytes()
    for stem, (name, data) in built.items():
        files[f'ko/{name}'] = data

    manifest = {stem: {'file': name, 'sha256': sha(data)}
                for stem, (name, data) in sorted(built.items())}
    info = {
        'kmi': args.kmi,
        'release': args.release,
        'kernel_sha': args.kernel_sha,
        'modules': manifest,
        'missing_optional': absent,
    }
    files['build-info.json'] = (json.dumps(info, indent=2) + '\n').encode()
    files['build-info.txt'] = (
        f'target:   OnePlus Ace 5 Pro (hummer)\n'
        f'kmi:      {args.kmi}\n'
        f'release:  {args.release}\n'
        f'kernel:   {args.kernel_sha}\n'
        f'modules:  {len(built)}\n'
        f'missing:  {" ".join(absent) or "none"}\n'
    ).encode()

    checksums = ''.join(f'{sha(data)}  ko/{name}\n'
                        for stem, (name, data) in sorted(built.items()))
    files['ko/SHA256SUMS'] = checksums.encode()

    args.output.mkdir(parents=True, exist_ok=True)
    archive = args.output / f'droidspaces-lkm-hummer-arm64.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for name, data in sorted(files.items()):
            entry = zipfile.ZipInfo(name, date_time=(2026, 11, 15, 0, 0, 0))
            entry.create_system = 3
            executable = name.endswith('.sh')
            entry.external_attr = (0o100755 if executable else 0o100644) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(entry, data)
    (args.output / 'SHA256SUMS').write_text(f'{sha(archive.read_bytes())}  {archive.name}\n')
    print(archive)
    print('sha256:', sha(archive.read_bytes()))
    print('modules:', ', '.join(sorted(built)))


if __name__ == '__main__':
    main()
