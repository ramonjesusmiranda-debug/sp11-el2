# Surface Pro 11 (X1E80100, OLED) at EL2: audio, NPU, video decoding, cameras, keyboard backlight and deep s2idle

Arch Linux on a Surface Pro 11 booted at EL2 with [slbounce](https://github.com/TravMurav/slbounce),
stable, with the ADSP and CDSP started by Linux ([x1e-dsp](https://github.com/justririll/x1e-dsp)),
working audio, RTC, Iris hardware video decoding, the three cameras (front, rear and IR with Howdy), Surface Pro Flex
keyboard backlight and s2idle reaching **CXSD + AOSD + DDR LPM for 99.9 % of a 73 min suspend
(~0.26 W, was 1.06 W at EL1)**, no hourly reset. Tested on one unit (X1E80100, OLED, UEFI 175.222.235),
October 2026 (updated 25 October: Iris at EL2, cameras, Firefox hardware decoding, pmic_glink sleep fix; 23 October: CDSP
generic firmware fix, DPU/PCIe/USB fixes, keyboard backlight). Base kernel: [dwhinham/linux-sp11](https://github.com/dwhinham/linux-sp11) 7.2.11 (`d6333a4`).
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
7. **Audio silent in apps at EL2 (WirePlumber):** before patch 177, Iris failed to start at EL2 and opening
   `/dev/video0` returned ENOMEM; WirePlumber's V4L2 monitor then leaves its async event queue stuck, so the sound card never gets its
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
14. **Iris (video decoding) at EL2 works (patch 177).** At EL2 TZ authenticates the Iris firmware (PAS 9) but does
    not handle `MEM_PROTECT_VIDEO_VAR` / `SET_REMOTE_STATE`: on Windows the CSRT routes them to QcSkExt8380 in VTL1,
    which programs the VPU memory windows and releases its reset. Patch 177 does the same from the driver (own
    `video-firmware` context bank, PAS load + IOMMU mapping, FW/CPA/non-pixel windows, SEC_SID, fuses by SMC, VPU
    CPU out of reset; resume repeats the boot). Results with `ffmpeg -c:v *_v4l2m2m` against software decoding,
    frame by frame: H.264 300/300, HEVC and VP9 identical, AV1 149/150 (the first frame is lost). 8 h of s2idle with
    `qcom_iris` loaded, decoding still fine afterwards. The old attempt in `experimental-iris-el2/` is superseded and
    the blacklist is gone.
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

17. **Cameras (patches 180–198, `libcamera-sp11`, `vd55g0-dkms`, `howdy-sp11`):** front Sony IMX681 on C-PHY
    (CSIPHY2, trio 0, 2.406 Gsym/s), rear OV13858 on D-PHY (CSIPHY1) and the IR ST VD55G0 (CSIPHY0). Base: Linaro's
    CSI2 PHY v18 + camss v20 + x1e80100 CCI/CAMSS dtsi (Bryan O'Donoghue) and the IMX681 parts of
    ooaklee/linux_ms_dev_kit-sp11 PR #22, with C-PHY ported to the v18 PHY driver. Front and rear give 30.0 fps in
    `cam`; full resolution (4216×3136 rear, 3832×2640 front) needs `cma=512M` (set by `sp11-el2`). Patch 198:
    regulator voltages that are not a valid LDO step (l16b, l2m) took PMIC B down, and the WiFi with it.
    libcamera 0.7.2 needs the IMX681 helper (`libcamera-sp11`). The VD55G0 has a vd55g1-like register map with the
    context block at 0x044c and the FSM at 0x2c; `vd55g0-dkms` gives 644×604 Y8 at 63 fps, and the overlay
    `sp11-el2-camara-ir.dtso` drives the IR emitter (PM8550 flash channels 1 and 4) and the privacy LED. Howdy with
    manual exposure unlocks in 0.85 s (3/3).
18. **Firefox hardware decoding with Iris (`packages/ffmpeg-v4l2drm`):** Firefox opens `h264_v4l2m2m` but needs
    `AV_PIX_FMT_DRM_PRIME`, which upstream FFmpeg 9.0 does not output, so it fell back to software. The package is
    Arch ARM's FFmpeg 9.0.2 + the LibreELEC `v4l2-drmprime` series + two fixes on top of it:
    - `0003`: Firefox sets neither `pkt_timebase` nor `time_base`, so every frame came out with `AV_NOPTS_VALUE` and
      Firefox painted ~10 of 30 fps; it now falls back to the V4L2 microsecond timebase.
    - `0004`: when a looping video goes back to the start (the series' `flush` + seek), Iris raises a source change
      with the same format; `DECODER_CMD START` was sent before the LAST capture buffer was dequeued, Iris refuses it
      with EBUSY and the decoder stayed silent. It is now resent when the LAST buffer arrives. Drain + flush + seek
      test: 300/1/1 frames before, 300/300/300 after. Upstream FFmpeg without the series has no `flush` in v4l2m2m
      and does not reach this path.
    The import is zero-copy, but CPU use does not drop yet (H.264 ~60 % vs 62–72 % in software, HEVC ~76 % vs ~55 %,
    the extra in Firefox's main process, not profiled yet). mpv with v4l2m2m is the efficient path for now.
19. **USB-C hub across suspend (patch 199):** during a suspend `ps883x_retimer` failed to write over i2c with the
    controller asleep (`-13`, `pmic_glink_altmode: failed to setup retimer`), and connecting a hub afterwards made
    `xhci-hcd` die ("HC died") ~6 s after enumeration. Patch 199 is 1/4 of tvlad744's RFC "pmic_glink: hold back
    notifications over system sleep". With it a hub (Realtek + r8153) works from a cold boot; across suspend it is not
    verified yet.
20. **Slim Pen 2:** pairs over Bluetooth LE; BlueZ exposes its Battery Service only while the pen is connected
    (KDE's Bluetooth settings show the percentage then; UPower does not list it while idle).

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
  - `177`: Iris VPU boot at EL2 (this work, finding 14)
  - `180`–`192`: CSI2 C-PHY/D-PHY driver v18, phy core helpers, camss PHY API, x1e80100 CCI/CAMSS (Bryan O'Donoghue, Linaro)
  - `193`–`198`: SP11 camera DT, IMX681 (ooaklee PR #22), X1E C-PHY, ov13858 OF support, LDO voltages (this work)
  - `199`: pmic_glink hold back notifications over system sleep, 1/4 of the RFC (Vladyslav Tymoshchuk)
  - `experimental-iris-el2/`: 152-158, old Iris attempt — superseded by 177, not in the PKGBUILD
- `packages/sp11-el2` — builds `/boot/sl/el2-dsp.efi` (main: ADSP+CDSP by Linux with generic CDSP firmware) and `/boot/sl/el2.efi`
  (UEFI-left ADSP attached, no audio) from the kernel's EL2 DTB + overlays; systemd-boot entries through the UEFI
  shell (`*.nsh` find slbounce on fs0..fs9); sleep hook; module service; WirePlumber and UCM drop-ins.
- `packages/ffmpeg-v4l2drm` — FFmpeg 9.0.2 with DRM_PRIME output for Firefox (finding 18).
- `packages/libcamera-sp11`, `packages/vd55g0-dkms`, `packages/howdy-sp11` — cameras and face unlock (finding 17;
  Howdy also needs `python-dlib` from the AUR).
- `packages/x1e-sleep-modulos-dkms` — `el1tmr`, `aoss_cxsd_only`, `qcom_adsp_pwr_lmts`, `asus_adsp_sleepstate`
  from justririll/x1e-sleep, as DKMS for `-sp11-el2` kernels.

`slbounce.efi`, `tcblaunch.exe` and the DSP firmware are not included. Comments in the packages are in Spanish.
