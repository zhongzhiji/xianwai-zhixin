@echo off
chcp 65001 >nul
REM ============================================================================
REM  music_pro  一键编译（综合 -> 布局布线 -> 生成 .fs 比特流）
REM  用法：双击本文件，或在命令行运行 build.bat
REM  产物：impl\pnr\music_pro_showcase.fs
REM ============================================================================
setlocal

set "GW_SH=D:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe"

if not exist "%GW_SH%" (
    echo [ERROR] 找不到 Gowin 工具：%GW_SH%
    echo         请修改 build.bat 里的 GW_SH 路径指向你本机的 gw_sh.exe
    goto :fail
)

REM ROM 相对路径以工程根目录为基准，必须先切到本目录
cd /d "%~dp0"
echo ============================================================
echo  music_pro  build start   %DATE% %TIME%
echo  project : %CD%\music_pro.gprj
echo ============================================================

"%GW_SH%" run_all.tcl
if errorlevel 1 (
    echo.
    echo [BUILD FAILED] 详见 build 过程输出
    goto :fail
)

if not exist "impl\pnr\music_pro_showcase.fs" (
    echo [ERROR] 未生成比特流 impl\pnr\music_pro_showcase.fs
    goto :fail
)

echo.
echo ============================================================
echo  BUILD OK  ->  impl\pnr\music_pro_showcase.fs
echo  program.bat 可直接烧录到板子
echo ============================================================
endlocal
exit /b 0

:fail
echo.
echo 编译未成功，请向上翻看 Gowin 的报错信息。
pause
endlocal
exit /b 1
