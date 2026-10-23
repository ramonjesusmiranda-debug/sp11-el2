@echo -off
# Arranque EL2 + DSP con el CDSP genérico de linux-firmware (PRUEBA): carga slbounce y lanza la imagen. 19-10-2026
for %a run (0 9)
  if exist fs%a:\sl\slbounce.efi then
    fs%a:
    cd \sl
    load slbounce.efi
    el2-dsp-cdspgen.efi
  endif
endfor
echo "No se encontró \sl\slbounce.efi"
