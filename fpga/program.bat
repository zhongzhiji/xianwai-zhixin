@echo off
chcp 65001 >nul
REM ============================================================================
REM  music_pro  一键烧录（SRAM，掉电丢失，适合频繁调试）
REM  用法：双击本文件前请先确认板子已通过 USB-JTAG 连接并上电
REM ============================================================================
setlocal

set "CLI=D:\Gowin\Gowin_V1.9.12.04_x64\Programmer\bin\programmer_cli.exe"
set "FS=%~dp0impl\pnr\music_pro_showcase.fs"
if not exist "%FS%" set "FS=%~dp0music_pro_showcase.fs"

if not exist "%CLI%" (
    echo [ERROR] 找不到烧录工具：%CLI%
    echo         请修改 program.bat 里的 CLI 路径
    goto :fail
)
if not exist "%FS%" (
    echo [ERROR] 找不到比特流：%FS%
    echo         请先运行 build.bat 完成编译
    goto :fail
)

echo ============================================================
echo  music_pro  program start   %DATE% %TIME%
echo  file    : %FS%
echo ============================================================

"%CLI%" --device GW5AST-138C --operation_index 2 --fsFile "%FS%"
if errorlevel 1 (
    echo [PROGRAM FAILED] 请检查：
    echo   1. 板子 USB-JTAG 是否已连接并上电
    echo   2. 是否被其它 Gowin Programmer 实例占用
    goto :fail
)

echo.
echo ============================================================
echo  PROGRAM OK - FPGA 已开始运行（SRAM 模式，重启后需重新烧录）
echo ============================================================
endlocal
exit /b 0

:fail
echo.
pause
endlocal
exit /b 1
