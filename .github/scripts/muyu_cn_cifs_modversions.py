#!/usr/bin/env python3
"""Let Xiaomi's CN cifs.ko load on a GKI android14-6.1 kernel.

muyu's vendor_boot lists cifs_arc4.ko, cifs_md4.ko and cifs.ko in the
first-stage modules.load. If any of them fails to load, first-stage init
aborts and the device hangs at the boot logo.

On the Global ROM those modules are built against GKI and match. The CN ROMs
run Xiaomi's "-mi" OKI kernel instead, and its mm/swapfile.c exports two
symbols with different modversions CRCs than GKI:

  __page_file_index: GKI 0x39ba4984, CN cifs.ko wants 0x12d686c5
  add_swap_extent:   GKI 0x2a731aba, CN cifs.ko wants 0x3da4a325
  (OS4.0.3.0.XOYCNXM, 6.1.157-android14-11-g2de7246565ac-mi)

Every other symbol the CN vendor_boot, vendor_dlkm and system_dlkm modules
import matches GKI. cifs only calls these two for swap files on an SMB share.

This patches kernel/module/version.c so that, for the module named "cifs"
only, a CRC mismatch on exactly these two symbols is logged and accepted.
Every other mismatch is still rejected. Safe to re-run.

Usage: muyu_cn_cifs_modversions.py <kernel/common>
"""

import os
import sys

MARK = "muyu_cn_cifs_crc_ok"

HELPER = f"""
/*
 * Xiaomi muyu CN ROMs build vendor_boot's first-stage cifs.ko against their
 * "-mi" OKI kernel, which exports these mm/swapfile.c symbols with CRCs that
 * differ from GKI. A rejected first-stage module aborts init, so accept the
 * mismatch for cifs and these two symbols only.
 */
static bool {MARK}(const struct load_info *info, const char *symname)
{{
\tstatic const char * const syms[] = {{ "__page_file_index", "add_swap_extent" }};
\tunsigned int k;

\tif (!info->name || strcmp(info->name, "cifs") != 0)
\t\treturn false;
\tfor (k = 0; k < ARRAY_SIZE(syms); k++) {{
\t\tif (strcmp(symname, syms[k]) == 0) {{
\t\t\tpr_info("%s: accepting vendor CRC for %s\\n", info->name, symname);
\t\t\treturn true;
\t\t}}
\t}}
\treturn false;
}}

"""

FUNC_ANCHOR = "int check_version(const struct load_info *info,"
CALL_ANCHOR = "\t\tpr_debug(\"Found checksum %X vs module %lX\\n\","
CALL = f"\t\tif ({MARK}(info, symname))\n\t\t\treturn 1;\n"


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: muyu_cn_cifs_modversions.py <kernel/common>")
    path = os.path.join(sys.argv[1], "kernel", "module", "version.c")
    src = open(path, encoding="utf-8", newline="").read()

    if MARK in src:
        print(f"[=] {path}: already patched")
        return
    if src.count(FUNC_ANCHOR) != 1 or src.count(CALL_ANCHOR) != 1:
        sys.exit(f"[-] {path}: check_version() anchors not found; refusing to guess")

    src = src.replace(FUNC_ANCHOR, HELPER.lstrip("\n") + FUNC_ANCHOR, 1)
    src = src.replace(CALL_ANCHOR, CALL + CALL_ANCHOR, 1)
    open(path, "w", encoding="utf-8", newline="").write(src)
    print(f"[+] {path}: cifs may load with CN vendor CRCs for its two swap symbols")


if __name__ == "__main__":
    main()
