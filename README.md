# Surface Pro 11 (X1E80100, OLED) at EL2: audio, NPU, keyboard backlight and deep s2idle

Arch Linux on a Surface Pro 11 booted at EL2 with [slbounce](https://github.com/TravMurav/slbounce),
stable, with the ADSP and CDSP started by Linux ([x1e-dsp](https://github.com/justririll/x1e-dsp)),
working audio, RTC, Surface Pro Flex keyboard backlight and s2idle reaching **CXSD + AOSD + DDR LPM for 99.9 % of a 73 min suspend
(~0.26 W, was 1.06 W at EL1)**, no hourly reset. Tested on one unit (X1E80100, OLED, UEFI 175.222.235),
October 2026 (updated 23 October: CDSP generic firmware fix, DPU/PCIe/USB fixes, Surface Pro Flex keyboard backlight). Base kernel: [dwhinham/linux-sp11](https://github.com/dwhinham/linux-sp11) 7.2.8 (`616a9f2`).
Use at your own risk.

| Setup | Audio | NPU | s2idle |
|---|---|---|---|
| EL1 (Gunyah) | yes | no | 1.06 W, no CXSD/DDR LPM |
| EL2, UEFI-left ADSP attached, no CDSP | no | no | 0.28 W, CXSD + DDR, no AOSD |
| **EL2, ADSP + CDSP started by Linux + patch 140 + generic CDSP fw** | **yes** | **yes** | **0.26 W, CXSD + AOSD + DDR** |

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
   nvme-pci is built in (`quirks_param_set()` allocates during `parse_args`, before mm init). Fixed in patch 175
   (`device_param_cb`, proposed by Maurizio Lombardi on linux-nvme).
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
12. **DPU PSR race and runtime suspend clock (patches 160–161):** Earlier patch 142 was retired after review showed
    it left vblank enabled on self-refresh exit. Instead, patch 160 (by [@michaelburch](https://github.com/michaelburch))
    increments `frame_pending` before `prepare_for_kickoff()`, eliminating all `[dpu error] crtc108 wait for frame done failed;frame_pending1`
    errors during PSR transitions, and patch 161 (by [@aruhier](https://github.com/aruhier)) lowers the DPU core clock
    to 19.2 MHz XO during runtime suspend.
13. **CDSP crash ~33 s after boot (`sleep_statsi.c:537`) — FIXED by generic linux-firmware CDSP image:**
    With Microsoft's `qcom/x1e80100/microsoft/Denali/qccdsp8380.mbn` (`CDSP.HT.2.9.c1-00046.1`), the CDSP crashed
    ~33 s after boot in **8/13 boots (61.5 %)**. Switching `remoteproc_cdsp` via DT overlay (`sp11-el2-cdsp-generico.dtso`,
    suggested by `@mmediouni`) to the generic upstream `qcom/x1e80100/cdsp.mbn` (`CDSP.HT.2.9.c1-00094` from `linux-firmware`)
    resulted in **0/15 crashes (0.0 %)** with `fastrpc` and deep s2idle working normally.
14. **Iris (video) at EL2 does not work yet** (`kernel-patches/experimental-iris-el2/`, do not use as is; `qcom_iris`
    is blacklisted by `sp11-el2-blacklist.conf` to avoid boot log noise).
15. **Surface Pro Keyboard (`045E:09AE`) backlight (patch 176):**
    The Surface Pro Keyboard exposes its backlight over SSAM HID (`0019:045E:09AE`, Consumer Page `0x0c` Usage `0x07`;
    sibling `0019:045E:09B0` is the Slim Pen charging cradle):
    - Feature Report `0xd5` (Usage `0x0517`, unit Candela) returns the 4 discrete brightness values: `[0xd5, 0x00, 0x03, 0x06, 0x0c]`.
    - Feature Report `0xd6` (Usage `0x007b`) reads the current brightness value (`0`, `3`, `6`, `12`).
    - Output Report `0xd5` (Usage `0x007b`) sets the brightness value (`[0xd5, val]`).
    - Input Report `0xd5` (Usage `0x0515`, Keyboard Brightness Next) fires `[0xd5, 0x01]` when the F5 backlight key is pressed.
    Patch 176 registers `/sys/class/leds/surface::kbd_backlight` (`max_brightness = 3`, `LED_BRIGHT_HW_CHANGED`) in
    `surface_hid_core` and cycles/notifies UPower & KDE PowerDevil on F5 key press.
16. **PCIe `gic-mem` vote and idle DDR clock (patches 170–174):**
    Adds the `gic-mem` (`MASTER_GIC1 -> SLAVE_EBI1`, 1 kB/s) interconnect path from [@aruhier](https://github.com/aruhier)
    so `ath12k` MSI interrupts are not lost when the display is off and DDR drops to idle, while capping `opp-peak-kBps`
    on `pcie-mem` to `250000 kB/s` so active PCIe links do not pin DDR at 2092 MHz at idle.

## Contents

- `kernel-patches/` — patches on top of linux-sp11 7.2.8 and the `PKGBUILD` used:
  - `01`–`09`: from [justririll/x1e-sleep](https://github.com/justririll/x1e-sleep) (`06` updated to Oleg Keri v2 `disable_irq`)
  - `10`: platform_profile on DT boots, from dwhinham/linux-sp11#2 (GeneralPawz)
  - `11`: msm DP PSR with software VSC (this work)
  - `111`–`124`: smp2p, remoteproc attach and `x1-el2` DT, from
    [jglathe/linux_ms_dev_kit](https://github.com/jglathe/linux_ms_dev_kit)
  - `125`: cpuidle-psci `deep_off` parameter (debugging aid, this work)
  - `126`: park stopped arch timers, by Anthony Ruhier
  - `127`: icc-bwmon PM ops + opt-in zero PCIe vote in s2idle (this work)
  - `128`–`139`: [x1e-dsp](https://github.com/justririll/x1e-dsp) 0001–0012 (Kirill Mitrofanov)
  - `140`: LPASS wsa/va macros drop their votes in runtime suspend (this work)
  - `141`, `159`: x1e-dsp b9dc5e8 and 59a8430
  - `143`–`151`: Qualcomm Generic Vendor Extensions + SCMI memlat RFC v8 1-9/10
  - `160`–`161`: DPU `frame_pending` race fix (Michael Burch) and 19.2 MHz runtime suspend clock (Anthony Ruhier)
  - `162`–`167`: USB `usb_1_ss0` NOC clocks, `dwc3-qcom` PM, xHCI debugfs, `ps883x` and `msm/dp` runtime PM (Anthony Ruhier)
  - `168`–`169`: LPASS WSA macro regcache and v2.5 compander fixes (Srinivas Kandagatla)
  - `170`–`174`: PCIe OPP tables + `gic-mem` vote (capped at 250 MB/s), WCN7850 LTR quirk, `t-power-on-us`
  - `175`: `nvme.quirks` built-in boot hang fix (`device_param_cb`, Maurizio Lombardi)
  - `176`: Surface Pro Flex Keyboard (`045E:09AE`) backlight LED class (`surface::kbd_backlight`) and SAM BAT `0x1a` event (this work)
  - `experimental-iris-el2/`: 152-158, Iris at EL2 attempt (finding 14) — not in the PKGBUILD
- `packages/sp11-el2` — builds `/boot/sl/el2-dsp.efi` (main: ADSP+CDSP by Linux with generic CDSP firmware) and `/boot/sl/el2.efi`
  (UEFI-left ADSP attached, no audio) from the kernel's EL2 DTB + overlays; systemd-boot entries through the UEFI
  shell (`*.nsh` find slbounce on fs0..fs9); sleep hook; module service; WirePlumber and UCM drop-ins.
- `packages/x1e-sleep-modulos-dkms` — `el1tmr`, `aoss_cxsd_only`, `qcom_adsp_pwr_lmts`, `asus_adsp_sleepstate`
  from justririll/x1e-sleep, as DKMS for `-sp11-el2` kernels.

`slbounce.efi`, `tcblaunch.exe` and the DSP firmware are not included. Comments in the packages are in Spanish.
