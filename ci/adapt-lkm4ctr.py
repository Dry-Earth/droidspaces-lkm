#!/usr/bin/env python3
"""Adapt the vendored lkm4ctr sources to this vendor kernel's overlayfs ABI.

hummer's 6.6 kernel backports the newer file-based backing_file_open():

    struct file *backing_file_open(const struct file *user_file, int flags,
                                   const struct path *real_path,
                                   const struct cred *cred);

lkm4ctr chooses its call by LINUX_VERSION_CODE, so 6.6 falls into the
path-based branch and fails to compile.  Detect the declaration in the target
kernel and rewrite that one call site.
"""
import re
import sys
from pathlib import Path


def main() -> None:
    kernel = Path(sys.argv[1])
    lkm = Path(sys.argv[2])

    header = kernel / 'include/linux/fs.h'
    if not header.is_file():
        print(f'adapt: {header} not found, skipping')
        return
    text = header.read_text(errors='replace')
    m = re.search(r'backing_file_open\s*\(\s*(?:const\s+)?struct\s+(file|path)\s*\*', text)
    if not m:
        print('adapt: backing_file_open not found in fs.h, skipping')
        return
    kind = m.group(1)
    print(f'adapt: backing_file_open takes const struct {kind} *')

    file_c = lkm / 'vendor/fs/overlayfs/file.c'
    if not file_c.is_file():
        raise SystemExit(f'{file_c} missing')
    src = file_c.read_text()
    if kind == 'file':
        old = 'backing_file_open(&file->f_path, flags, realpath,'
        new = 'backing_file_open(file, flags, realpath,'
        if old not in src:
            if new in src:
                print('adapt: already file-based')
                return
            raise SystemExit('adapt: expected path-based call site not found')
        file_c.write_text(src.replace(old, new))
        print('adapt: rewrote 6.6 branch to pass struct file *')
    else:
        print('adapt: kernel already uses the path-based ABI, no change')


if __name__ == '__main__':
    main()
