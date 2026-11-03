@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
set "PY=%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
if not exist "%PY%" set "PY=python"
echo 弦外之芯 手机控制台
echo 先以离线模式启动。复制下方完整地址到浏览器。
echo 可在网页选择串口和波特率，点击连接；默认 9600 适配新版固件。
echo 旧 115200 固件请在网页选择 115200。浏览器试听须点击按钮后启用。
"%PY%" gateway.py
pause
