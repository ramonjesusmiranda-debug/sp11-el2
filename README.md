# Surface Pro 11 (X1E80100, OLED) at EL2 with deep s2idle

Arch Linux on a Surface Pro 11 booted at EL2 with [slbounce](https://github.com/TravMurav/slbounce),
stable, with s2idle reaching **CXSD and DDR LPM for 99.8 % of the suspend (~0.28 W, was 1.06 W at EL1)**.
Tested on one unit (X1E80100, OLED, UEFI 175.222.235), October 2026. Base kernel:
[dwhinham/linux-sp11](https://github.com/dwhinham/linux-sp11) 7.2.8 (`616a9f2`). Use at your own risk.

## Findings

1. **The EL2 lockups 10–30 s after boot were the DCC console.** systemd starts `serial-getty@hvc0`,
   and hvc0 is `hvc_dcc` (`CONFIG_HVC_DCC=y`). At EL1 Gunyah traps DCC; at EL2 it goes to the hardware,
   the TX buffer never drains without a JTAG host and `hvc_dcc0_put_chars()` spins forever with IRQs off.
   Pseudo-NMI backtraces (`irqchip.gicv3_pseudo_nmi=1`) showed `pc : hvc_dcc0_put_chars` in 3/3 hung
   boots. When the stuck CPU is the one handling the apps_rsc IRQ you also get
   `Error sending AMC RPMH requests (-110)` about 10 s later. **Fix: `systemctl mask serial-getty@hvc0`.**
   Before: 3/3 boots hung; after: 0 in every boot since.
2. **Votes that keep DDR out of LPM in s2idle** (traced with the `interconnect:icc_set_bw` event):
   - `icc-bwmon` (CPU bwmon, `24091000.pmu`) has no PM ops and keeps its last vote (800 MB/s peak on ebi).
     Patch 127 adds suspend/resume.
   - `pcie-qcom` keeps 1 kBps on pcie-mem while the link stays up. Forcing it to 0 hangs the SoC on entry.
     What works is getting both links down so `icc_disable()` runs: NVMe with ASPM off (nvme does a full
     D3 suspend), `pcie_port_pm=force` so the root port reaches D3hot, and ath12k unloaded
     (`packages/sp11-el2/sp11-el2-reposo.sh`).
3. **Timers:** [@aruhier](https://github.com/aruhier)'s patch to park stopped timers (126) is required;
   without it the firmware returns from DRIPS in microseconds.
4. **CL5:** the deepest cluster state at runtime caused lockups; it is kept only for system sleep
   (`system-sleep-only` from patch 03, overlay `sp11-el2-cl5-solo-suspension.dtso`). SS1 is removed.
5. **AOSD is never entered** — the CDSP is not running at EL2 here (disabled in the DT).
6. **Unrelated bug:** `nvme.quirks=VID:DID:...` on the kernel command line hangs the kernel instantly when
   nvme-pci is built in (`quirks_param_set()` allocates during `parse_args`, before mm init).
7. **PSR on the OLED panel** (patch 11): the stock msm PSR1 sequence flickers/blanks on this Samsung panel
   (sink needs training on exit, never reacts to the hardware VSC generator on the DP 1.4.1 controller).
   Keeping the main link active and sending the PSR VSC SDP from GENERIC0 works: 4.5 W vs 5.2 W idle.

## Contents

- `kernel-patches/` — patches on top of linux-sp11 7.2.8 and the `PKGBUILD` used:
  - `01`–`09`: from [justririll/x1e-sleep](https://github.com/justririll/x1e-sleep) (some adapted)
  - `10`: platform_profile on DT boots, from dwhinham/linux-sp11#2 (GeneralPawz)
  - `11`: msm DP PSR with software VSC (this work)
  - `111`–`124`: smp2p, remoteproc attach and `x1-el2` DT, from
    [jglathe/linux_ms_dev_kit](https://github.com/jglathe/linux_ms_dev_kit)
  - `125`: cpuidle-psci `deep_off` parameter (debugging aid, this work)
  - `126`: park stopped arch timers, by Anthony Ruhier
    ([gist](https://gist.github.com/aruhier/08932aea5eb29e3fca832b3c8b471bf7))
  - `127`: icc-bwmon PM ops + opt-in zero PCIe vote in s2idle (this work)
- `packages/sp11-el2` — builds `/boot/sl/el2.efi` (kernel EL2 DTB + overlays), systemd-boot entry through the
  UEFI shell (`el2.nsh` finds slbounce on fs0..fs9), sleep hook, module service.
- `packages/x1e-sleep-modulos-dkms` — `el1tmr`, `aoss_cxsd_only`, `qcom_adsp_pwr_lmts`,
  `asus_adsp_sleepstate` from justririll/x1e-sleep, as DKMS for `-sp11-el2` kernels.

`slbounce.efi` and `tcblaunch.exe` are not included. Comments in the packages are in Spanish.
