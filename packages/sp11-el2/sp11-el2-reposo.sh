#!/bin/sh
# Surface Pro 11 en EL2 (17-10-2026): para que la DDR entre en autorrefresco y el SoC en CXSD, los dos PCIe tienen que
# cortar el enlace al dormir y soltar su voto de ancho de banda (con el enlace activo dejan 1 kB/s y bajarlo a 0 cuelga):
#  - NVMe: sin ASPM, nvme hace la suspensión completa (D3) y, con pcie_port_pm=force, el puerto raíz también duerme
#  - WiFi (ath12k): se descarga el driver
# Medido: cxsd y DDR LPM el 99,8 % de la suspensión, ~0,28 W (antes 1,06 W).
# Digitalizador SPI (045E:0C83, 23-10-2026): al despertar hace «Spontaneous FW reset!» y pierde el modo IPTS que fija
# iptsd al arrancar (sin recrear hidraw): el Slim Pen deja de mover el cursor. Se reinicia iptsd tras cada reposo;
# --no-block porque un systemctl en segundo plano muere con systemd-sleep y no llegaba a ejecutarse.
case "$(uname -r)" in *sp11-el2*) ;; *) exit 0 ;; esac
N=/sys/bus/pci/devices/0006:01:00.0/link
case "$1" in
  pre)
    nmcli radio wifi off 2>/dev/null
    modprobe -r ath12k_wifi7 ath12k 2>/dev/null
    for a in l1_2_aspm l1_2_pcipm l1_1_pcipm l1_aspm; do [ -w $N/$a ] && echo 0 > $N/$a; done
    ;;
  post)
    for a in l1_aspm l1_1_pcipm l1_2_pcipm l1_2_aspm; do [ -w $N/$a ] && echo 1 > $N/$a; done
    modprobe ath12k_wifi7 2>/dev/null
    nmcli radio wifi on 2>/dev/null
    for h in /sys/bus/spi/devices/spi0.0/001C:045E:0C83.*/hidraw/hidraw*; do
      [ -e "$h" ] || continue
      systemctl --no-block restart "iptsd@dev-$(basename "$h").service" 2>/dev/null
    done
    ;;
esac
exit 0
