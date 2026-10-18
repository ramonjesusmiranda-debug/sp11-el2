# Surface Pro 11 (X1E80100, OLED) at EL2: audio, NPU and deep s2idle

Arch Linux on a Surface Pro 11 booted at EL2 with [slbounce](https://github.com/TravMurav/slbounce),
stable, with the ADSP and CDSP started by Linux ([x1e-dsp](https://github.com/justririll/x1e-dsp)),
working audio and RTC, and s2idle reaching **CXSD + AOSD + DDR LPM for 99.9 % of a 73 min suspend
(~0.26 W, was 1.06 W at EL1)**, no hourly reset. Tested on one unit (X1E80100, OLED, UEFI 175.222.235),
October 2026 (updated 18 October: memlat, findings 11-14). Base kernel: [dwhinham/linux-sp11](https://github.com/dwhinham/linux-sp11) 7.2.8 (`616a9f2`).
Use at your own risk.

| Setup | Audio | NPU | s2idle |
|---|---|---|---|
| EL1 (Gunyah) | yes | no | 1.06 W, no CXSD/DDR LPM |
| EL2, UEFI-left ADSP attached, no CDSP | no | no | 0.28 W, CXSD + DDR, no AOSD |
| **EL2, ADSP + CDSP started by Linux + patch 140** | **yes** | **yes** | **0.26 W, CXSD + AOSD + DDR** |

## Findings

1. **The EL2 lockups 10–30 s after boot were the DCC console.** systemd-getty-generator starts
   `serial-getty@hvc0` whenever hvc0 exists, and hvc0 is `hvc_dcc` (`CONFIG_HVC_DCC=y` on Arch ARM and
   linux-sp11). At EL1 Gunyah traps DCC; at EL2 it goes to the hardware, the TX buffer never drains without a
   JTAG host and `hvc_dcc0_put_chars()` spins forever with IRQs off. Pseudo-NMI backtraces
   (`irqchip.gicv3_pseudo_nmi=1`) showed `pc : hvc_dcc0_put_chars` in 3/3 hung boots. When the stuck CPU handles
   the apps_rsc IRQ you also get `Error sending AMC RPMH requests (-110)` 10 s later.
   **Fix: `systemctl mask serial-getty@hvc0`** (or `CONFIG_HVC_DCC=n`).
2. **Votes that keep DDR out of LPM in s2idle** (traced with the `interconnect:icc_set_bw` event):
   - `icc-bwmon` (CPU bwmon, `24091000.pmu`) has no PM ops and keeps its last vote (800 MB/s peak on ebi).
     Patch 127 adds suspend/resume.
   - `pcie-qcom` keeps 1 kBps on pcie-mem while the link stays up; forcing 0 hangs the SoC. What works on this
     tree is getting the links down: NVMe with ASPM off (full D3 suspend), `pcie_port_pm=force`, ath12k unloaded
     (`packages/sp11-el2/sp11-el2-reposo.sh`).
3. **Timers:** [@aruhier](https://github.com/aruhier)'s patch to park stopped timers (126) is required.
4. **CL5:** the deepest cluster state at runtime caused lockups; it is kept only for system sleep
   (`system-sleep-only` from patch 03, overlay `sp11-el2-cl5-solo-suspension.dtso`). SS1 is removed.
5. **CXSD/AOSD with the Linux-started ADSP (patch 140):** the LPASS **wsa** and **va** macros enable the
   `macro` and `dcodec` clocks (q6prm `LPASS_HW_MACRO`/`LPASS_HW_DCODEC` votes to the ADSP) in probe and only
   release them in remove, so the ADSP keeps LPASS voted and CX never collapses (x1e-sleep's patch 07 fixed this
   for rx/tx only). Releasing them in runtime suspend gives CXSD + AOSD with audio and the CDSP running.
   Measuring this: reading `clk_summary` resumes the macros through `fsgen`; read
   `/sys/kernel/debug/clk/<clk>/clk_enable_count` instead.
6. **RTC / EFI variables at EL2** (patches 128–129, SHM bridge self-owner): without them `qseecom` fails (-22),
   so no efivars and `rtc-pm8xxx` defers forever. With them `rtc0` works (no wake alarm: `qcom,no-alarm`).
7. **Audio silent in apps at EL2 (WirePlumber):** Iris fails to start at EL2 and opening `/dev/video0` returns
   ENOMEM; WirePlumber's V4L2 monitor then leaves its async event queue stuck, so the sound card never gets its
   profile, ports or links — with nothing in the log. Disabling `monitor.v4l2`/`monitor.libcamera`
   (`packages/sp11-el2/90-sp11-wireplumber-sin-video.conf`) fixes it.
8. **x1e-dsp on the SP11:** SoC HW version `0xa0090201` and the ADSP DTB descriptor (`0x0088022b`, `0x201`,
   `0x28000200`) match the Vivobook defaults. Adapted to 7.2.8 (`qcom_pas_*` → `qcom_scm_pas_*`). Stopping the
   CDSP at runtime (`echo stop`) makes the next suspend hang.
9. **Unrelated bug:** `nvme.quirks=VID:DID:...` on the kernel command line hangs the kernel instantly when
   nvme-pci is built in (`quirks_param_set()` allocates during `parse_args`, before mm init).
10. **PSR on the OLED panel** (patch 11): software PSR VSC SDP with the main link kept active: 4.5 W vs 5.2 W idle.

11. **Memory bandwidth on X1E Linux needs memlat.** Without the CPUCP memory-latency governor the CPU never raises
    DDR/LLCC: the `cpu-bwmon` instances stay at their lowest vote (4.8 GB/s) under full load. STREAM triad (12 threads):
    **38 GB/s at EL2, 41 GB/s at EL1 (Gunyah)** — so not an EL2 issue. With the unmerged
    "Qualcomm Generic Vendor Extensions" **RFC v8** (Pragnesh Papaniya / Sibi Sankar,
    `20260724-rfc_v8_scmi_memlat-v1-0-cb732bcff1f4@oss.qualcomm.com`, patches 1-9 as 143-151) it reaches **67 GB/s**;
    DDR/LLCC go back to 547/300 MHz at idle and s2idle is unaffected (CXSD + AOSD + DDR 99.9 % of an 880 s suspend).
    Note: the protocol 0x80 module does not autoload here; `sp11-el2-modulos.service` modprobes it.
    llama.cpp CPU (Q4_0): Qwen3-8B 7 → 21.4 t/s generation; Gemma 4 E4B QAT 28.4 t/s, 209 t/s prompt. A llama.cpp
    build with the Vulkan backend makes the CPU path ~3x slower (weights in GPU-visible memory) — build CPU-only.
12. **PSR WARN at boot** ("driver disabled vblank in self-refresh"): `dpu_crtc_disable()` only checked the old state,
    so it switched vblank off when *entering* self refresh. Patch 142 skips `drm_crtc_vblank_off()` then.
13. **CDSP crash ~33 s after boot** ("fatal error received: sleep_statsi.c:537", remoteproc recovers it, sleep
    unaffected): 4/6 boots with the original x1e-dsp, 2/5 with the socinfo/CDSP DTB descriptor (141), 1/4 with the
    SPMI windows (159). Not fixed; timing is the only constant (~30 s after the CDSP starts).
14. **Iris (video) at EL2 does not work yet** (`kernel-patches/experimental-iris-el2/`, do not use as is): with
    "media: iris: Migrate iommus to iris sub nodes" v5 (4-8) and "Enable Secure PAS support with IOMMU managed by
    Linux" (glymur v11 2/9) ported to 7.2.8, the MS-signed `qcvss8380.mbn` authenticates via PAS, but
    `qcom_scm_mem_protect_video_var` returns -EIO and the failed start left the SoC stalling (GMU/APM/DPU timeouts:
    no desktop). Skipping CP (158) avoids the stall, but CTRL_STATUS stays 0 with no SMMU faults: the VPU never
    starts. The generic `vpu30_p4` is rejected by TZ (-22).

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
  - `128`–`139`: [x1e-dsp](https://github.com/justririll/x1e-dsp) 0001–0012 (Kirill Mitrofanov; 0001–0002 from
    the jglathe tree); `137` and `139` merged on this tree and adapted to the 7.2.8 PAS API
  - `140`: LPASS wsa/va macros drop their votes in runtime suspend (this work)
  - `141`: x1e-dsp b9dc5e8 (ADSP DTB identity from socinfo, CDSP DTB descriptor); `159`: x1e-dsp 59a8430 (SPMI windows)
  - `142`: DPU keeps vblank on when entering self refresh (this work)
  - `143`-`151`: Qualcomm Generic Vendor Extensions + SCMI memlat RFC v8 1-9/10 (unmerged; config
    `QCOM_SCMI_GENERIC_EXT`, `DEVFREQ_GOV_REMOTE`, `SCMI_QCOM_MEMLAT_DEVFREQ` as modules)
  - `experimental-iris-el2/`: 152-158, Iris at EL2 attempt (finding 14) — not in the PKGBUILD
- `packages/sp11-el2` — builds `/boot/sl/el2-dsp.efi` (main: ADSP+CDSP by Linux) and `/boot/sl/el2.efi`
  (UEFI-left ADSP attached, no audio) from the kernel's EL2 DTB + overlays; systemd-boot entries through the UEFI
  shell (`*.nsh` find slbounce on fs0..fs9); sleep hook; module service; WirePlumber drop-in.
- `packages/x1e-sleep-modulos-dkms` — `el1tmr`, `aoss_cxsd_only`, `qcom_adsp_pwr_lmts`, `asus_adsp_sleepstate`
  from justririll/x1e-sleep, as DKMS for `-sp11-el2` kernels.

`slbounce.efi`, `tcblaunch.exe` and the DSP firmware are not included. Comments in the packages are in Spanish.
