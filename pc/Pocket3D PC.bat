@echo off
rem Doble clic: arranca Pocket3D PC. El iPhone le manda el escaneo en vivo por WiFi.
chcp 65001 >nul
cd /d "%~dp0"
set "PY="
rem El motor 3D (open3d 0.19) existe hasta Python 3.12: si está instalado, se usa ese.
where py >nul 2>nul && py -3.12 -c "" >nul 2>nul && set "PY=py -3.12"
if not defined PY where py >nul 2>nul && set "PY=py -3"
if not defined PY where python >nul 2>nul && set "PY=python"
if not defined PY (
  echo Falta Python. Se abre la descarga: instala Python 3.12 marcando "Add python.exe to PATH" y vuelve a abrir este archivo.
  start "" https://www.python.org/downloads/release/python-31210/
  pause
  exit /b 1
)
echo Preparando (la primera vez descarga el motor 3D, unos minutos)...
%PY% -m pip install --quiet --disable-pip-version-check --user zeroconf numpy "open3d==0.19.0" >nul 2>nul
start "" http://localhost:8765
%PY% pocket3d_pc.py %*
pause
