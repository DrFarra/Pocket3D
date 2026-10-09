@echo off
rem Doble clic: arranca Pocket3D PC. El iPhone (modo Espacio) le manda el escaneo en vivo por WiFi.
chcp 65001 >nul
cd /d "%~dp0"
set "PY="
where py >nul 2>nul && set "PY=py -3"
if not defined PY where python >nul 2>nul && set "PY=python"
if not defined PY (
  echo Falta Python. Se abre la descarga: instalalo marcando "Add python.exe to PATH" y vuelve a abrir este archivo.
  start "" https://www.python.org/downloads/
  pause
  exit /b 1
)
rem Opcional: para que el iPhone encuentre el PC solo. Si falla, en la app se escribe la IP que aparece abajo.
%PY% -m pip install --quiet --disable-pip-version-check --user zeroconf >nul 2>nul
start "" http://localhost:8765
%PY% pocket3d_pc.py %*
pause
