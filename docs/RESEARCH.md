# 主会话实测：Droidspaces kABI 补丁变体选择（android15-6.6）

**结论：小米15（6.6.118-android15-8）必须用 `001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch`。**

## 证据链

### 0. 澎湃 OS4 = Android 17 平台，但内核 KMI 仍是 android15-8（关键澄清）

用户指出小米15 最新澎湃 OS4 是 Android 17。**这不改变内核基线选择。**

对用户提供的 OS4 备份 `os4.boot.b.img` 实测：

```
$ strings os4.boot.b.img | grep -aoE "android1[5-9]-[0-9]+" | sort | uniq -c
     10 android15-8          ← 只有 android15-8，零个 android16/android17
$ strings os4.boot.b.img | grep -a security_patch
com.android.build.boot.security_patch
2026-08-01
```

**结论**：平台版本（Android 17 / HyperOS 4）与内核 KMI（`android15-8`）是**两个独立维度**。
Google 的 GKI 契约只要求 KMI 在生命周期内冻结，不要求随平台号升级；
厂商在平台大版本升级时沿用既有 GKI 基线是常规做法。

- 构建基线**仍然是** `common-android15-6.6` + KMI `android15-8` —— 不受 OS4 影响
- OS4 带来的变化在 vendor 侧安全补丁（`2026-08-01`），不在 KMI
- `abogki536571621` 是厂商 fork 的构建编号（abogki = MTK/厂商 AOSP GKI fork）

> [!NOTE]
> 若将来小米真的换到 `android16-6.12`/`android17-*` KMI，`uname -r` 会直接体现。
> 判据永远是 **boot.img 里的 KMI 字符串**，不是系统设置里的 Android 版本号。
> 刷机前用 `strings boot.img | grep -oE "android1[0-9]-[0-9]+"` 复验一次即可。

### 1. 设备事实（从 `/home/master/Downloads/os4.boot.b.img` 提取，confidence: high）

```
Linux version 6.6.118-android15-8-gb9cc6ec16bc8-abogki536571621-4k (kleaf@build-host)
(Android (11368308, +pgo, +bolt, +lto, +mlgo, based on r510928) clang version 18.0.0
```

- GKI `android15-6.6`，KMI = `android15-8`，**4KB page size**（`-4k`）
- boot header **v4**，`kernel_size=36866560`，`ramdisk_size=0`，`header_size=1584`
- `os_version_raw=0`、`cmdline` 为空、`signature_size=0` → 无 vbmeta 内嵌签名，纯 GKI boot 分区
- 内核压缩：gzip（offset 18157704，`1f 8b 08`）

### 2. 上游 `task_struct` 槽位占用实情

> [!IMPORTANT]
> **两个源头结论不同，必须以 googlesource 为准。** aosp-mirror GitHub 镜像严重滞后。

| 源 | sublevel | `task_struct` 已占用槽位 |
|----|----------|--------------------------|
| `aosp-mirror/kernel_common` @ `android15-6.6` (GitHub 镜像) | **6.6.111** | `1` |
| `aosp-mirror/kernel_common` @ `android15-6.6-lts` | **6.6.114** | `1`（KABI 区与上者 diff 一致） |
| **`android.googlesource.com/kernel/common` @ `android15-6.6` HEAD** | **6.6.142** | **`1`, `2`** |

googlesource HEAD（`include/linux/sched.h`，task_struct 内相对行 788-799）：

```c
	ANDROID_KABI_USE(1, struct task_dma_buf_info *dmabuf_info);   // 槽位 1 已占用
	ANDROID_KABI_USE(2, struct {                                  // 槽位 2 也已占用（镜像上还是 RESERVE）
	...
	ANDROID_KABI_RESERVE(3);
	ANDROID_KABI_RESERVE(4);
	ANDROID_KABI_RESERVE(5);
	ANDROID_KABI_RESERVE(6);
	ANDROID_KABI_RESERVE(7);
	ANDROID_KABI_RESERVE(8);
```

**这正是不能硬编码变体名的原因**：上游会持续征用低位槽位。6.6.111 → 6.6.142 之间槽位 2 就被吃掉了。

### 3. 三个变体的 dry-run 实测（`patch -p1 --dry-run -F 3`）

对 **aosp-mirror 6.6.111** 快照：

| 变体 | Hunk #1 | Hunk #2 | 判定 |
|------|---------|---------|------|
| `1_2_3` | 成功 (offset -1) | **FAILED at 1508** | ❌ 槽位 1 冲突 |
| `3_4_5` | 成功 (offset -1) | 成功 (fuzz 2, offset +11) | ⚠️ 可用 |
| `6_7_8` | 成功 (offset -1) | 成功 (fuzz 2, offset +11) | ✅ 推荐 |

对 **googlesource HEAD 6.6.142**（真实构建目标）：

| 变体 | Hunk #1 | Hunk #2 | 判定 |
|------|---------|---------|------|
| `1_2_3` | 成功 (offset -1) | **FAILED at 1508** | ❌ 槽位 1/2 均已占用 |
| `3_4_5` | 成功 (offset -1) | 成功 (**fuzz 3**, offset +14) | ⚠️ fuzz 升高，边界在恶化 |
| `6_7_8` | 成功 (offset -1) | 成功 (fuzz 2, offset +14) | ✅ **唯一稳妥选择** |

`1_2_3` 失败原因即上下文不匹配：补丁期望 `ANDROID_KABI_RESERVE(1);`，实际是 `ANDROID_KABI_USE(1, ...)`。
注意 `3_4_5` 在新版上 fuzz 已达 3（`-F 3` 的上限），再涨一点就会 FAILED——这是它不该被选中的实证理由。

### 4. 为什么在 `3_4_5` 和 `6_7_8` 之间选后者

两者都能 apply。选 `6_7_8` 的理由：**低位槽位（2–5）是 GKI/vendor 后续 backport 更常征用的位置**，
占用最高位的 6/7/8 给未来留出余量，冲突概率最低。这是保守选择，不是功能差异。

### 5. 尺寸匹配验证（槽位 = `u64`，每槽 8 字节）

| 字段 | 定义 | 大小 | 占用槽位 |
|------|------|------|----------|
| `struct sysv_sem` | `include/linux/sem.h:12` → 1 个 `sem_undo_list *` | 8 B | `ANDROID_KABI_USE(6, ...)` |
| `struct sysv_shm` | `include/linux/shm.h:13` → 1 个 `struct list_head` | 16 B | `_ANDROID_KABI_REPLACE(7; 8, ...)` 合并两槽 |

宏均存在于 `include/linux/android_kabi.h`：`ANDROID_KABI_USE`(:129)、`_ANDROID_KABI_REPLACE`(:61,65)。

### 6. fuzz 应用后的实际结果（已验证正确）

`sed -n '1070,1078p'`：

```c
#ifdef CONFIG_SYSVIPC
	// struct sysv_sem			sysvsem;
	// struct sysv_shm			sysvshm;
#endif
```

`grep` 1528-1535：

```c
#ifdef CONFIG_SYSVIPC
	ANDROID_KABI_USE(6, struct sysv_sem sysvsem);
	_ANDROID_KABI_REPLACE(ANDROID_KABI_RESERVE(7); ANDROID_KABI_RESERVE(8), struct sysv_shm sysvshm);
#else
	ANDROID_KABI_RESERVE(6);
	ANDROID_KABI_RESERVE(7);
	ANDROID_KABI_RESERVE(8);
#endif
```

结构正确，`#else` 分支保留，非 SYSVIPC 构建不受影响。

### 7. `002.*posix_mqueue*` 不适用

该补丁标题即 `GKI 5.10 or lower`，改的是 `include/linux/sched/user.h` 的 `struct user_struct`。
6.6 上 `mq_bytes` 已迁出 `user_struct`（转入 `ucounts` 机制），**不要 apply**。

## 对 CI 的要求（不靠人记，自动判定）

CI 必须在 apply 前检测槽位占用，而不是硬编码变体名：

```bash
# 检测 task_struct 里哪些 ANDROID_KABI 槽位已被 USE 占用
awk '/^struct task_struct \{/,/^\};/' include/linux/sched.h \
  | grep -oE 'ANDROID_KABI_USE2?\(([0-9]+)' \
  | grep -oE '[0-9]+' | sort -un
# android15-6.6 预期输出：1
```

若输出包含 6/7/8 → 说明上游动过高位槽，必须改用 `3_4_5` 并重新 dry-run 全部变体择优。
CI 应对候选变体逐个 `patch --dry-run` 并选第一个成功的（顺序：6_7_8 → 3_4_5 → 1_2_3），失败则 fail fast。

### 8. 原厂 sublevel 6.6.118 与 KMI android15-8 的现实约束

| 源 | 当前 sublevel |
|----|---------------|
| 用户原厂 boot.img uname | **6.6.118-android15-8-…-4k** |
| aosp-mirror `android15-6.6` | 6.6.111（镜像滞后，**不要用**） |
| aosp-mirror `android15-6.6-lts` | 6.6.114（镜像滞后，**不要用**） |
| googlesource `android15-6.6` HEAD | **6.6.142** |
| googlesource `android15-6.6-lts` HEAD | **6.6.142** |

> [!WARNING]
> GKI 的 vendor 模块加载检查的是 **KMI 字符串（`android15-8`）**，不是 sublevel。
> sublevel 可以高于原厂（6.6.118 → 6.6.142 是 LTS 安全补丁），只要 `CONFIG_LOCALVERSION` 保留 `-android15-8` 且未破坏 kABI。
> 反过来，sublevel **低于** 原厂（6.6.111）既拿不到安全补丁也无任何兼容性收益——**禁止用滞后镜像**。
>
> 用户选择了「锁定与原厂一致的 android15-8 KMI，sublevel 尽量贴近 6.6.118」。

#### 精确基线已确认：`android15-6.6-2026-01_r1` == 6.6.118（confidence: high）

**不要用 branch HEAD，要用 monthly release tag。** 实测三项特征与原厂 boot.img 完全吻合：

| 特征 | 原厂 boot.img | tag `android15-6.6-2026-01_r1` | 匹配 |
|------|---------------|-------------------------------|------|
| sublevel | `6.6.118` | `Makefile: SUBLEVEL = 118` | ✅ |
| clang | `based on r510928` | `build.config.constants: CLANG_VERSION=r510928` | ✅ |
| page size 后缀 | `-4k` | `gki_defconfig:2: CONFIG_LOCALVERSION="-4k"` | ✅ |

获取方式（manifest monthly 分支 + local_manifest 双重 pin）：

```bash
repo init -u https://android.googlesource.com/kernel/manifest \
          -b common-android15-6.6-2026-01 --depth=1
mkdir -p .repo/local_manifests
cat > .repo/local_manifests/pin.xml <<'LM'
<manifest>
  <remove-project name="kernel/common" />
  <project path="common" name="kernel/common" revision="refs/tags/android15-6.6-2026-01_r1" />
</manifest>
LM
repo sync -c -j$(nproc --all) --no-tags --no-clone-bundle --optimized-fetch --prune
```

**已验证存在的 manifest monthly 分支**（`kernel/manifest` refs/heads，筛 `common-android15-6.6`）：
`2024-07 … 2024-12`、`2025-01 … 2025-10`、**`2026-01`**、`2026-04`、`2026-07`、
以及 `common-android15-6.6`（HEAD，漂移）、`-lts`、`-desktop`、`-sp`、`-partner_predev`、`-pkvm_experimental`。
注意 **2025-11 / 2025-12 / 2026-02 的 monthly tag 不存在**（实测 404），月度发布有跳月，不要假设连续。

其他可选 sublevel（升级路线，KMI 仍为 android15-8）：

| tag | sublevel |
|-----|----------|
| `android15-6.6-2026-01_r1` | **6.6.118**（= 原厂，默认） |
| `android15-6.6-2026-04_r1` | 6.6.127 |
| `android15-6.6-2026-07_r1` | 6.6.139 |
| `common-android15-6.6` HEAD | 6.6.142（漂移，不推荐） |

> [!CAUTION]
> **禁止 aosp-mirror**（6.6.111/6.6.114，滞后）。**禁止跟 branch HEAD**——vermagic/CRC 相对 vendor 模块漂移会 bootloop。

#### 版本字符串的坑（kleaf 特有，来自 lakitu12 workflow 的实战经验）

6.x + kleaf 下 `.scmversion` **已失效**，kleaf 用自己的 localversion 规则
（`build/kleaf/impl/stamp.bzl`）；缺 `--config=stamp` 时会输出字面量 `-maybe-dirty`，
实测文件内容为 `-android15-8-maybe-dirty`（**KMI 尾巴来自同一处**）。
所以自定义内核名要改 `stamp.bzl` 里那个 `echo '-maybe-dirty'`，
**不要设 `CONFIG_LOCALVERSION`**（它会被追加在文件内容之后，顺序错）。
同时 `echo '# CONFIG_LOCALVERSION_AUTO is not set' >> gki_defconfig`。

## 复现方法

```bash
cd /home/master/Documents/DSHWK/mi15-ksu/research
mkdir -p patchtest/include/linux
cp sched-android15-6.6.h patchtest/include/linux/sched.h
cd patchtest
for v in 1_2_3 3_4_5 6_7_8; do
  patch -p1 --dry-run -F 3 < ../droidspaces-patches/001.GKI-below-6.12-fix_sysvipc_kabi_$v.patch
done
```

---

## 9. Root solution facts (verified against upstream repos)

### KernelSU-Next
- Repo API: `https://api.github.com/repos/KernelSU-Next/KernelSU-Next`
- Branches (실측): `stable`, `dev`, `legacy`, `sync-upstream`, + dependabot/*
  → **there is no `next` or `next-susfs` branch**; guides claiming otherwise are stale.
- Latest release: **v3.3.0** (2026-07-03). Earlier: v3.2.0, v3.1.0, v3.0.1, v3.0.0.
- `kernel/Kconfig` (branch `stable`) defines only:
  `KSU` (tristate, `depends on KPROBES && EXT4_FS`), `KSU_DEBUG`,
  `KSU_DISABLE_MANAGER`, `KSU_DISABLE_POLICY`.
  Branch `dev` additionally has `KSU_X86_PATCH_SYSCALL_DISPATCHER` (x86 only, irrelevant here).
- **No hook-mode selection exists on v3.x.** The tree ships
  `kernel/hook/{lsm_hook,setuid_hook,syscall_hook_manager,syscall_event_bridge,tp_marker}.c`,
  `kernel/hook/arm64/{patch_memory,syscall_hook}.c` and `kernel/infra/symbol_resolver.o`.
  Consequence: no `fs/exec.c` / `fs/open.c` edits are needed, and
  `CONFIG_KSU_MANUAL_HOOK` / `CONFIG_KSU_KPROBES_HOOK` / scope-min variants do not apply.
- `kernel/setup.sh` (80 lines): detects `common/drivers` or `drivers`, clones into
  `./KernelSU-Next`, checks out `git describe --abbrev=0 --tags` when given no argument
  (or the supplied commit/tag), symlinks `drivers/kernelsu`, appends
  `obj-$(CONFIG_KSU) += kernelsu/` to `drivers/Makefile` and sources the Kconfig.
  Supports `--cleanup`.
- **KPM is not a KernelSU-Next feature.** No `CONFIG_KPM` anywhere in its Kconfig.

### SukiSU Ultra
- Repo: `SukiSU-Ultra/SukiSU-Ultra`, default branch `main`; branches include
  `builtin`, `dev`, `main`, `susfs_new`, `old`, `module_repository`.
- `kernel/Kconfig` on **`builtin`** (4324 bytes) defines:
  `KSU`, `KSU_FEATURE_ADBROOT`, `KSU_DEBUG`, **`KPM`**, `KSU_SUSFS`,
  `KSU_SUSFS_SUS_PATH`, `KSU_SUSFS_SUS_MOUNT`, `KSU_SUSFS_SUS_KSTAT`,
  `KSU_SUSFS_SPOOF_UNAME`, `KSU_SUSFS_ENABLE_LOG`, `KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS`,
  `KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG`, `KSU_SUSFS_OPEN_REDIRECT`, `KSU_SUSFS_SUS_MAP`.
  On `main` the Kconfig is only 1855 bytes and **lacks the SUSFS symbols** — which is why
  `setup.sh` must be invoked as `bash -s builtin`. Otherwise kconfig silently drops every
  `CONFIG_KSU_SUSFS*` line appended to the defconfig.
- `setup.sh` clones into `./KernelSU` (not `KernelSU-Next`).

### SUSFS
- `gitlab.com/simonpunk/susfs4ksu`, branch **`gki-android15-6.6` confirmed to exist**
  (full branch list also has `-dev` variants and `gki-android16-6.12`).
- `kernel_patches/include/linux/susfs.h`: `SUSFS_VERSION "v2.3.0"`.
- Files: `kernel_patches/fs/susfs.c`, `kernel_patches/include/linux/susfs{,_def}.h`,
  `kernel_patches/50_add_susfs_in_gki-android15-6.6.patch`,
  `kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch` (3005 lines).
- `10_enable_susfs_for_ksu.patch` touches `kernel/Kbuild`, `kernel/Kconfig`,
  `kernel/hook/setuid_hook.c`, `kernel/supercall/dispatch.c`, `kernel/policy/*`,
  `kernel/selinux/*` — i.e. the **KernelSU-Next** layout. It notably *removes*
  `hook/lsm_hook.o`, `hook/syscall_hook_manager.o` and `infra/symbol_resolver.o` from Kbuild,
  so it is tightly coupled to a specific KSU revision. `apply-root.sh` dry-runs it and fails
  loudly with an actionable message instead of half-applying.
  It must **not** be applied to SukiSU `builtin`, which implements SUSFS itself.

## 10. Artifact packaging: mkbootimg over magiskboot

The stock boot image is header v4 with `ramdisk_size=0` — `boot` carries **only** the kernel
(generic ramdisk lives on `init_boot`, vendor ramdisk on `vendor_boot`). Nothing has to be
preserved from the original image, so `boot.img` can be synthesized from scratch with AOSP
`mkbootimg.py`. No magiskboot binary needed, and no dependency on the user's stock dump.

Verified by building a boot.img from the stock `Image` and diffing headers against the
original dump:

| field | stock | rebuilt |
|---|---|---|
| `magic` | `ANDROID!` | `ANDROID!` |
| `kernel_size` | 36866560 | 36866560 |
| `ramdisk_size` | 0 | 0 |
| `header_size` | 1584 | 1584 |
| `header_version` | 4 | 4 |
| `cmdline` | *(empty)* | *(empty)* |

Total file size differs only because the stock dump is padded to the 96 MB partition size.

`mkbootimg.py` needs `gki/generate_gki_certificate.py` alongside it (vendored into
`scripts/gki/`), otherwise it fails with `ModuleNotFoundError: No module named 'gki'`.

## 11. Stock config ground truth

`docs/stock-6.6.118-android15-8.config` (7762 lines) was extracted from the device's own
boot image: the `CONFIG_IKCONFIG` payload sits at `Image` offset 18153600, marked by
`IKCFG_ST` followed by a gzip stream. Python's `gzip` module chokes on the trailing data;
`zlib.decompressobj(16 + zlib.MAX_WBITS)` handles it.

Decisive values found there:

```
CONFIG_LTO_NONE=y            CONFIG_CFI_CLANG=y
CONFIG_MODULE_SIG_PROTECT=y  CONFIG_MODVERSIONS=y
CONFIG_ARM64_4K_PAGES=y      CONFIG_LOCALVERSION="-4k"
CONFIG_KPROBES=y             CONFIG_KALLSYMS_ALL=y      CONFIG_EXT4_FS=y
CONFIG_ANDROID_KABI_RESERVE=y
```

Of the Droidspaces requirements, these are **off in stock** and get flipped:
`SYSVIPC`, `POSIX_MQUEUE`, `PID_NS`, `USER_NS`, `DEVTMPFS`, `CGROUP_DEVICE`, `CGROUP_PIDS`,
`TMPFS_XATTR`, `TMPFS_POSIX_ACL`, `NETFILTER_XT_MATCH_ADDRTYPE`, `NETFILTER_XT_TARGET_LOG`,
`NETFILTER_XT_MATCH_RECENT`, `IP_SET`, `NF_TABLES`.
Absent entirely (selected via dependencies): `IPC_NS`, `CGROUP_NS`, `DEVTMPFS_MOUNT`,
`IP_SET_HASH_IP`, `IP_SET_HASH_NET`, `NETFILTER_XT_SET`, `NETFILTER_XT_TARGET_REJECT`.
Already on: `NAMESPACES`, `UTS_NS`, `NET_NS`, `OVERLAY_FS`, `SECCOMP{,_FILTER}`, `CGROUPS`,
`MEMCG`, `CGROUP_FREEZER`, `VETH`, `BRIDGE`, `NF_NAT`, `EXT4_FS`.

## 12. Two rules taken from prior art, both bootloop-class

From `lakitu12/kernel_dash_droidspaces`, a workflow targeting the *same* 6.6.118-android15-8
profile (its independent choice of the `6_7_8` kABI variant agrees with the probe result here):

1. **`CONFIG_MODULE_SIG_PROTECT` must be turned off.** Stock has it `=y` and that works only
   because Google's signing key is in the stock trusted ring. A self-built kernel trusts just
   its own kleaf key, so every Google-signed `system_dlkm` module exporting a *protected*
   symbol (`rfkill`, `bluetooth`, `mii`, `ppp*`, `usbnet`, `virtio*`) is refused with EACCES,
   silently, at boot → `cfg80211` cannot resolve `rfkill_alloc` → **WiFi and Bluetooth dead**.
   Load-time policy only: no ABI/CRC impact.
2. **LTO and CFI must match stock, not be "improved".** Stock is `LTO_NONE=y` + `CFI_CLANG=y`.
   A different LTO mode changes codegen and symbol CRCs, and `vendor_dlkm` then refuses to
   load → bootloop. Upstream `gki_defconfig` lists only `CFI_CLANG=y`; `LTO_NONE` arrives as
   the Kconfig default, so its absence from the defconfig is expected and correct.

Also: `build/build.sh` **does not exist** on android15-6.6 manifests (the legacy build was
removed), so kleaf/bazel is the only path. `check_defconfig` must be disabled in
`common/BUILD.bazel` because the fragment is appended rather than sorted.

## 13. KernelSU-Next v3.x cannot take the susfs4ksu KSU-side patch (observed in CI)

First real CI run (`34026410717`) failed at *Apply root solution*. The kernel-side SUSFS patch
`50_add_susfs_in_gki-android15-6.6.patch` applied cleanly to all ~25 files, then
`10_enable_susfs_for_ksu.patch` failed its dry-run against KernelSU-Next at its latest tag
(HEAD `3b18216f`, v3.3.0).

Root cause, not an environment problem:

- susfs4ksu's README states its patches are based on **"the original official KernelSU (the one
  from weishu)"** at a release tag.
- `10_enable_susfs_for_ksu.patch` **removes** `hook/lsm_hook.o`, `hook/syscall_event_bridge.o`,
  `hook/syscall_hook_manager.o`, `hook/tp_marker.o`, `hook/arm64/*` and
  `infra/symbol_resolver.o` from `kernel/Kbuild` — exactly the components KernelSU-Next v3.x
  is architected around.
- KernelSU-Next has no kernel-side SUSFS of its own: the only match in its tree is
  `userspace/ksud/src/susfsd.rs`, and `kernel/Kconfig` contains no `KSU_SUSFS` symbol.

Resolution: `ksu-next` + `use_susfs=true` is redirected to `sukisu` in `apply-root.sh`, since
SukiSU Ultra's `builtin` branch defines all 19 `KSU_SUSFS*` Kconfig entries itself and needs no
patch. Verified: `builtin` Kconfig has 19 `KSU_SUSFS` matches, `main` has 0 — which is why the
script now hard-fails if the checked-out root tree lacks those symbols, instead of letting
kconfig silently drop every `CONFIG_KSU_SUSFS*` line.

Also fixed in the same pass:

- **`abi_gki_protected_exports_{aarch64,x86_64}` are now deleted** when SUSFS is enabled.
  susfs4ksu README step 11 requires this on GKI android14+ or "some modules like WiFi will not
  work" — the same failure class `MODULE_SIG_PROTECT=n` addresses, from the other direction.
- **The effective flavor is exported** via `EFFECTIVE_ROOT_FLAVOR` / `EFFECTIVE_USE_KPM`.
  Because the redirect can change the flavor mid-run, later steps must gate on the effective
  value; `verify-build.sh` had additionally been receiving no root env at all, so its
  `CONFIG_KSU` / `CONFIG_KSU_SUSFS` / `CONFIG_KPM` assertions were being skipped silently.

## 14. SukiSU `builtin` tip is not always buildable (observed in CI)

Run `34029222515` compiled for **1095 seconds** and then failed in
`drivers/kernelsu/ksu.o`:

```
kernel/feature/kernel_umount.c:13:20: error: use of undeclared identifier
    'kernel_umount_feature_set'; did you mean 'kernel_umount_feature_get'?
   13 |     .set_handler = kernel_umount_feature_set,
-- SukiSU-Ultra version: 40901 [v4.2.0-e2912817@builtin]
```

Upstream bug, not a configuration problem. Bisected by fetching
`kernel/feature/kernel_umount.c` at each commit that touched it:

| commit | date | state |
|---|---|---|
| `e2912817` (v4.2.0, branch tip) | 2026-09-01 | broken |
| **`d13e8a75`** "Sync with the official KernelSU main repo" | 2026-09-01 | **broke it** |
| `1a884658` "Sync with the official KernelSU main repo" | 2026-08-27 | ok |
| `82f6ada2`, `5168273c`, `ad8949ef` | 2026-04-01 | ok |

`d13e8a75` removed `kernel_umount_feature_set()` but left the
`.set_handler = kernel_umount_feature_set` reference in the handler struct.

`1a884658` turned out to be broken too, in a *different* way — run `34030854430`
(20m40s) failed with:

```
kernel/feature/kernel_umount.c:40:19: error: use of undeclared identifier
    'KSU_FEATURE_WEBVIEW_ZYGOTE_UMOUNT'
```

That enum constant exists in **no** commit on the branch, yet `1a884658` and
`2cf0f72d` reference it twice. The first pin was chosen by inspecting a single
function symbol, which missed the enum problem entirely.

Definitive scan: clone the branch and walk first-parent history, checking *both*
`*_handler` function references and `KSU_FEATURE_*` enum references against their
definitions in `kernel/include/uapi/feature.h`:

| commit | date | verdict |
|---|---|---|
| `e2912817` (v4.2.0, tip) | 2026-09-01 | broken: `kernel_umount_feature_set` |
| `d13e8a75` | 2026-09-01 | broken: `kernel_umount_feature_set` |
| **`6c5603f0`** "fix 2" | 2026-08-27 | **clean — newest good commit** |
| `e987e7d8` "fix" | 2026-08-27 | clean |
| `2cf0f72d` | 2026-08-07 | broken: `KSU_FEATURE_WEBVIEW_ZYGOTE_UMOUNT` |
| `1a884658` | 2026-08-27 | broken: `KSU_FEATURE_WEBVIEW_ZYGOTE_UMOUNT` |
| `4a6d3401` and older | 2026-08-27 | clean |

Resolution: SukiSU defaults to **`6c5603f0`**, verified to carry all 10 `KSU_SUSFS*`
symbols, `KPM`, the `fs/susfs.c` detection in `kernel/Makefile`, and to have every
`KSU_FEATURE_*` reference in the tree resolve. `ksu_ref` overrides it.

The **preflight check now covers both failure modes** — handler functions *and* enum
constants. One caveat that produced a false "every commit is broken" result while
building it: `CONFIG_KSU_FEATURE_ADBROOT` is a Kconfig macro used in `#ifdef`, not an
enum member, so the reference scan must exclude `CONFIG_`-prefixed matches.
Verified: rejects `e2912817`, `d13e8a75`, `1a884658`, `2cf0f72d`; accepts `6c5603f0`
and `4a6d3401`.

## 15. boot.img completion: GKI signature, reverse-engineered from the stock dump

`fastboot boot boot.img` produced a black screen on the device. Diagnosis: that is
**expected** on this platform, not an image defect. GKI v4 splits the boot chain:
DTB in `vendor_boot`, generic ramdisk in `init_boot`, kernel only in `boot`.
`fastboot boot` loads a single image, so the kernel comes up with no DTB and no
init. Nothing is written by `fastboot boot`; the correct test is
`fastboot flash boot` (or the AnyKernel3 zip).

The synthesized boot.img was still an unsigned 35 MB oddity next to the stock
96 MiB signed image, so it was completed to match. The stock layout was parsed
out of `/home/master/Downloads/os4.boot.b.img` and every inference was validated
against real bytes:

```
[header page 4K][kernel page-padded][vbmeta 'boot'][vbmeta 'generic_kernel']
[partition-level vbmeta + AVBf footer][zeros to 100663296]
```

Verified findings:

* `vbmeta 'boot'`: descriptor `image_size` = header page + padded kernel
  (36872192 for stock), `digest = sha256(salt ‖ content)` with **salt =
  hex-decoded `d00df00d`** (4 bytes, not the ASCII string). Recomputed digest
  matches the stock descriptor exactly.
* `vbmeta 'generic_kernel'`: `image_size` = **raw kernel Image** (36866560);
  digest over the kernel file alone, same salt. Matches stock exactly.
* Props on both: `ARCH=arm64`, `BRANCH=` (empty), `KERNEL_RELEASE=<uname -r>`.
* Descriptor arithmetic cross-check: on-disk sizes 368 B (boot: hash desc 176 +
  props 48/40/104) and 376 B (generic_kernel: 184 + same props) — both reproduced
  exactly by the avbtool encode rules (AvbHashDescriptor SIZE 132, round-8 padding;
  AvbPropertyDescriptor SIZE 32, key/value as `!QQ`, NUL-terminated).
* Auth block = hash(32) + sig(512), padded to 576; aux = descriptors + pubkey
  (1032 = 4+4+512+512 for RSA4096), padded to 1408; auth hash = sha256(header ‖ aux)
  — verified `MATCH` on both stock blobs.
* Stock partition tail: standard `AVBf` footer, `orig_image_size=36888576`,
  partition-level vbmeta is RSA2048 (2368 B). Ours is RSA4096 (2240 B) — the one
  intentional deviation; both are structurally valid.
* Regenerating the stock image from the stock kernel via our mkbootimg produces a
  **byte-identical** header + kernel region, and the avbtool-generated embedded
  digests are byte-identical to stock's. Only pubkey/signature bytes differ
  (public AOSP AVB test key vs Xiaomi's release key — an unlocked bootloader
  skips verification, so parity is not required).

Implementation: `scripts/avb/avbtool.py` (vendored AOSP tool; stdlib + openssl
only, no new CI deps) + `scripts/avb/testkey_rsa4096.pem`. `package.sh` now
signs (two embedded vbmetas via `--do_not_append_vbmeta_image`), then adds the
partition-level hash footer with `--partition_size 100663296`, which also pads
the image to the real partition size so `fastboot flash boot` overwrites every
stale byte. The verify block recomputes both digests from the final image.

## 16. Black screen after flash: vendor module CRC parity is impossible - and unnecessary

Symptom: `fastboot flash boot` with the signed image -> black screen right after
the logo (kernel loads, display never comes up).

Root cause chain, established by extracting `__ksymtab`/`__kcrctab` from both the
stock Image and ours (research/ksymtab_crc2.py; entries are PREL32 12-byte
`{value_offset, name_offset, namespace_offset}` relative to their own field
address, `__kcrctab` follows `__ksymtab_strings`):

* Stock exports 7830 symbols; **87.8% of the shared `__crc_` values differ** from
  ours. `module_layout` and `wake_up_process` match, proving the parse is aligned.
* Xiaomi builds their device kernel from MiCode's own tree, not the AOSP tag.
  genksyms CRCs hash source tokens, so no AOSP-tag rebuild can ever reproduce
  the CRCs recorded in their prebuilt vendor_dlkm modules.
* With CONFIG_MODVERSIONS=y the kernel refuses every such module
  ("disagrees about version of symbol") -> display/GPU dead -> black screen.
* Verified non-factors: ANDROID_KABI_USE is CRC-neutral (include/linux/android_kabi.h
  collapses to the original padding field under __GENKSYMS__), and `same_magic()`
  skips the version part of vermagic for modules that carry CRCs.

Fix (three parts, all serving "vendor modules must load"):
1. `CONFIG_MODVERSIONS=n` - skip CRC checks entirely. Safety: genksyms hashes
   source, not layout; binary-layout compatibility is what matters at runtime and
   is guaranteed by the ANDROID_KABI scheme (Droidspaces fills reserved slots;
   offsets/size unchanged). SUSFS verified .c-only (no struct changes), KSU likewise.
2. `trim_nonlisted_kmi = False` - keep every export so modules never hit
   "unknown symbol" against a trimmed table.
3. Kernel release string equals stock (`-gb9cc6ec16bc8-abogki536571621-4k`) so
   even modules without a `__versions` section pass the full vermagic compare.

### 16.1 Correction: MODVERSIONS=n also breaks vermagic - stub check_version() instead

Run 34048958886 still black-screened. The MODVERSIONS=n config skipped the CRC
compare but also removed the "modversions" token from the kernel vermagic
(include/linux/vermagic.h). same_magic() (kernel/module/version.c) skips only
the RELEASE token for CRC-carrying modules; the rest must strcmp equal:
module "SMP preempt mod_unload modversions aarch64" vs kernel
"SMP preempt mod_unload aarch64" -> every module rejected with "Invalid module
format". Same symptom, different gate.

Final scheme: keep CONFIG_MODVERSIONS=y (vermagic byte-identical to stock once
the release string matches; TRIM_UNUSED_KSYMS stays off exactly as stock) and
replace the body of check_version() in kernel/module/version.c with
`return 1`. check_modstruct_version() routes module_layout through the same
stub, so the very first gate ("disagrees about version of symbol
module_layout") is dead too. genksyms still runs; its output is never compared.

## 17. The bootloader enforces the embedded vbmeta even unlocked - ship a zero tail

Test matrix (2026-09-07, all with `fastboot flash boot`):
* flash stock backup os4.boot.b.img            -> boots
* flash stock kernel + our testkey-signed tail -> ABL drops to fastboot

Header and kernel bytes were field-for-field / sha256 identical in both images
(first differing byte: the avbtool release string inside the vbmeta), so the
tail alone is the discriminator. This ABL verifies the boot image's embedded
vbmeta signature even with an unlocked bootloader, and the AOSP test key can
never satisfy it. The community magiskboot/AnyKernel3 flow works because
magiskboot zeroes the tail on repack - with no footer the bootloader skips AVB.

Also discovered: earlier "black screen" reports were an artifact of testing
with `fastboot boot` - on GKI v4 the boot image carries no ramdisk (ramdisk
lives in init_boot), so a temporary boot finds no init and panics. Only
`fastboot flash boot` is a valid test.

Packaging change: boot.img = [4K header][kernel][zeros to partition size].
Verified byte-identical to a hand-built tail-less image. The whole AVB
replication effort (§15) was the wrong turn for an unlocked device.

## 18. What this bootloader actually accepts: a Xiaomi-signed vbmeta blob, stale hash and all

Full on-device matrix (every row flashed with `fastboot flash boot`):

| boot content | embedded tail | vbmeta partition | result |
|---|---|---|---|
| stock kernel | stock signed blob | stock | boots |
| stock kernel | our testkey blob | stock | reboots to fastboot |
| stock kernel | zeroed | stock | reboots to fastboot |
| stock kernel | zeroed | flags=3 (verity+verification disabled) | reboots to fastboot |

So the gate is the embedded vbmeta in the boot image, and the vbmeta partition
flags do not influence it. The decisive evidence came from the device's OTHER
slot, which held a third-party kernel (6.6.77-android15-8-Coolapk@GCross-
Droidspaces). `avbtool info_image` on it:

* Public key sha1 `de5be2a57e0cfbb83ec5c9523806eb6b7a72f809` - identical to the
  stock image's key, i.e. Xiaomi's own AVB key, whose private half is not public.
* Footer says `Original image size: 38031360`, but the hash descriptor inside
  claims `Image Size: 37003264` - the descriptor describes a DIFFERENT image.

A blob signed by Xiaomi's key that does not match the image it is attached to
can only be a verbatim copy of a stock blob. Therefore this ABL verifies the
blob's SIGNATURE and ignores its hash descriptor. (That kernel hangs at the logo
under OS4 - a 6.6.77 kernel against OS4's 6.6.118 vendor modules - which is a
different failure class from a bootloader rejection, and confirms the image was
accepted and executed.)

Packaging consequence (scripts/repack-stock-avb.py, wired into package.sh via
STOCK_BOOT): emit [4K header][kernel][pad to 4K][stock vbmeta blob verbatim]
[zeros][AVBf footer], with the footer's original_image_size and
descriptor_offset moved to our blob offset. Everything else - including the
signature - is stock bytes. Verified locally against both known-accepted images:
same header shape, same footer invariants (orig == desc_off, desc_size 2368,
4K-aligned blob, no kernel/blob overlap) and the same Xiaomi public key.

Also settled earlier in the session: all the "black screen" reports were
`fastboot boot` artifacts. On GKI v4 the boot partition holds no ramdisk, so a
temporary boot has no init and panics. Only `fastboot flash boot` tests anything.
