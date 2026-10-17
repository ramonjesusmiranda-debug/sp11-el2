@echo -off
# Arranque EL2 + DSP (pruebas) de la Surface Pro 11: carga slbounce y lanza la imagen EL2 (busca el ESP en fs0..fs9). 17-10-2026
for %a run (0 9)
  if exist fs%a:\sl\slbounce.efi then
    fs%a:
    cd \sl
    load slbounce.efi
    el2-dsp.efi
  endif
endfor
echo "No se encontró \sl\slbounce.efi"
