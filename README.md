# Mi15 Droidspaces Kernel

GitHub Actions builds of a **GKI android15-6.6** kernel for the **Xiaomi 15 (dada, sm8750)**
with [Droidspaces](https://github.com/Re-s/Droidspaces-OSS) container support and a choice of
root solution (KernelSU-Next or SukiSU Ultra, optionally with SUSFS).

Artifacts include a ready-to-flash **`boot.img`**, so a build can be boot-tested with a single
`fastboot` command.

## Target device

Everything here is pinned to one device profile, verified by extracting it from a stock
boot image dump rather than assumed:

| | |
|---|---|
| Stock kernel | `6.6.118-android15-8-gb9cc6ec16bc8-abogki536571621-4k` |
| GKI branch | `android15-6.6`, **KMI `android15-8`** |
| Page size | **4 KB** (`CONFIG_ARM64_4K_PAGES=y`, `CONFIG_LOCALVERSION="-4k"`) |
| boot.img | header **v4**, `ramdisk_size=0` (kernel only) |
| Toolchain | AOSP clang `r510928` |
| Security patch | `2026-08-01` |

> **HyperOS 4 / Android 17 does not change this.** The platform version and the kernel KMI are
> independent: the OS4 dump contains `android15-8` and no `android16`/`android17` KMI string at
> all. Vendors routinely carry an existing GKI baseline across a platform upgrade. The KMI in
> `uname -r` is the deciding fact, not the Android version in Settings.

## Usage

Actions → **Build Mi15 Droidspaces Kernel** → *Run workflow*.

| Input | Default | Notes |
|---|---|---|
| `kernel_tag` | `android15-6.6-2026-01_r1` | Source baseline. `…2026-01_r1` = **6.6.118, identical to stock**. Also `…2026-04_r1` (6.6.127) and `…2026-07_r1` (6.6.139) |
| `root_flavor` | `ksu-next` | `ksu-next` / `sukisu` / `none` |
| `ksu_ref` | *(empty)* | Pin the root solution to a tag/commit; empty = latest tag |
| `use_susfs` | `true` | SUSFS root hiding (susfs4ksu `gki-android15-6.6`, v2.3.0). **Forces `root_flavor=sukisu`** — see below |
| `use_kpm` | `false` | KPM — **SukiSU Ultra only**, ignored for `ksu-next` |
| `use_droidspaces` | `true` | Droidspaces kABI patch + config set |
| `kernel_name` | `-Mi15-DS` | Replaces kleaf's `-maybe-dirty` placeholder in `uname -r` |
| `formats` | `bootimg,anykernel,image` | Any comma subset |
| `make_release` | `false` | Publish a GitHub Release |

### Flashing

> **Use `fastboot flash boot`, never `fastboot boot`.** This is a GKI v4 device:
> the DTB lives in `vendor_boot` and the generic ramdisk in `init_boot`, while
> `boot.img` carries only the kernel. `fastboot boot boot.img` loads a single
> image into RAM, so the kernel starts with **no device tree and no init** —
> the result is a black screen even though the kernel itself is fine. Nothing is
> written to the device by `fastboot boot`; long-press power (or `fastboot reboot`)
> to recover.

```bash
# unlocked bootloader required
fastboot flash boot boot.img
fastboot reboot
```

Keep the stock `boot.img`. If the device does not boot, `fastboot flash boot <stock>.img`
restores it — the kernel lives only in `boot`, so nothing else is touched.

`boot.img` is padded to the real partition size (96 MiB) and carries the full GKI
signature set (embedded `boot` + `generic_kernel` vbmetas, partition-level AVB
footer), byte-layout-verified against the stock dump — see `docs/RESEARCH.md §15`.
It is signed with the public AOSP AVB test key; an unlocked bootloader skips
verification, so this is for structural parity and a clean overwrite, not trust.

The AnyKernel3 zip is the alternative route (recovery, or the KSU/SukiSU in-app flasher).

After booting, verify Droidspaces with `su -c droidspaces check`, or in-app via
**Settings → Requirements → Check Requirements**.

## Why root_flavor matters

The two root solutions are not interchangeable, and the difference is not cosmetic:

- **KernelSU-Next** (v3.x) has **no hook-mode choice**. Its `kernel/Kconfig` exposes only
  `KSU`, `KSU_DEBUG`, `KSU_DISABLE_MANAGER`, `KSU_DISABLE_POLICY`. Hooks are built in
  (`kernel/hook/{lsm_hook,syscall_hook,setuid_hook}.c` plus a runtime symbol resolver), so
  there are no `fs/*.c` edits and no `CONFIG_KSU_MANUAL_HOOK` / `KSU_KPROBES_HOOK` to pick
  from — older guides describing those options predate v3.x. `CONFIG_KSU` requires
  `KPROBES && EXT4_FS`, both already `=y` in stock.
  Branches are `stable` / `dev` / `legacy`; **there is no `next` branch**.
- **SUSFS requires SukiSU Ultra.** susfs4ksu's KSU-side patch
  (`10_enable_susfs_for_ksu.patch`) is written against weishu's original KernelSU layout —
  it *deletes* `hook/lsm_hook.o`, `hook/syscall_hook_manager.o` and `infra/symbol_resolver.o`
  from `kernel/Kbuild`, which are precisely the files KernelSU-Next v3.x is built on. KSU Next
  also ships no kernel-side SUSFS of its own (only `userspace/ksud/src/susfsd.rs`). So
  `root_flavor=ksu-next` + `use_susfs=true` is **automatically redirected to `sukisu`**, which
  implements SUSFS natively. Set `use_susfs=false` to genuinely stay on KernelSU-Next.
- **SukiSU Ultra** is what provides **KPM**. It is integrated from its `builtin` branch, which
  is the one carrying the `KSU_SUSFS*` symbols; the latest release tag on `main` lacks them and
  kconfig would silently drop every SUSFS option.

## Repository layout

```
.github/workflows/build.yml     CI entry point (9 workflow_dispatch inputs)
scripts/apply-droidspaces.sh    kABI patch (variant auto-selected) + config fragment
scripts/apply-root.sh           KernelSU-Next / SukiSU Ultra + SUSFS
scripts/fix-gki-config.sh       stock-environment alignment + kernel naming
scripts/verify-build.sh         post-build gates, read from the built Image
scripts/package.sh              boot.img / AnyKernel3 zip / raw Image
scripts/mkbootimg.py            AOSP mkbootimg (vendored)
patches/droidspaces/            upstream kABI patches + config fragment
docs/stock-*.config             stock kernel config, extracted from the device
docs/RESEARCH.md                verified findings and the reasoning behind each choice
```

## Safety notes

The build refuses to produce an image rather than hand you a brick:

- The Droidspaces kABI patch variant is **probed, not hardcoded** — upstream keeps claiming
  `task_struct` padding slots (slot 1 at 6.6.111, slots 1 **and** 2 by 6.6.142), so a fixed
  choice silently rots. If no variant fits, the build fails.
- `verify-build.sh` reads the config back out of the built `Image` (`CONFIG_IKCONFIG`) and
  asserts LTO/CFI parity with stock, `MODULE_SIG_PROTECT` off, 4K pages, the KMI string, and
  the Droidspaces mandatory set.
- Source is pinned to an exact tag via `local_manifests`; branch HEADs drift and a
  vermagic/CRC drift against vendor modules means a bootloop.

Flashing a custom kernel requires an unlocked bootloader, trips integrity attestation, and
carries real risk of an unbootable device. You are responsible for having a working backup.

## Credits

- [Droidspaces-OSS](https://github.com/Re-s/Droidspaces-OSS) — container runtime and the kABI patches
- [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next), [SukiSU Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra)
- [susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) by simonpunk
- [AnyKernel3](https://github.com/osm0sis/AnyKernel3) by osm0sis
- Prior art for the 6.6.118-android15-8 profile: `WildKernels/GKI_KernelSU_SUSFS`, `lakitu12/kernel_dash_droidspaces`
