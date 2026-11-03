#!/usr/bin/env bash
# ============================================================================
#  run_all_sim.sh —— 一键跑完全部自检 testbench（回归用）
#
#  为什么要这个脚本：
#    本工程改一处 RTL 很可能牵动别处（踩过：改顶层声明顺序 → 蓝牙曲谱和
#    音游 HUD 被综合器连根优化掉，编译照样过、bitstream 照样生成、功能却没了）。
#    所以**每次动 RTL 之后都要全量跑一遍**，靠"编译能过"是判断不出这类问题的。
#
#  用法（Git Bash）：
#    bash sim/run_all_sim.sh            # 跑全部
#    bash sim/run_all_sim.sh tb_chord   # 只跑某一个
#
#  判定：每个 TB 自己会打印 PASS/FAIL 计数，脚本最后汇总。
#        只要有一个 TB 出现 FAIL 或超时，退出码非 0。
# ============================================================================
set -u
# 编译命令经过 sed 管道时必须保留失败码；否则“编译失败”会被误报成 OK。
set -o pipefail

cd "$(dirname "$0")/.." || exit 1

# iverilog 不一定在 PATH 里，本机默认装在 C:\iverilog
IV="iverilog"
VVP="vvp"
if ! command -v "$IV" >/dev/null 2>&1; then
    if [ -x "/c/iverilog/bin/iverilog.exe" ]; then
        IV="/c/iverilog/bin/iverilog.exe"
        VVP="/c/iverilog/bin/vvp.exe"
    else
        echo "[ERROR] 找不到 iverilog。请安装 Icarus Verilog，"
        echo "        或修改本脚本开头的 IV / VVP 路径。"
        exit 2
    fi
fi

mkdir -p sim/out

# 自检用 TB（dbg_* / tb_*_dbg 是调试用的，不进回归）
TBS="tb_accomp_mix tb_bin2bcd tb_bus_snapshot_cdc tb_chord tb_fall_notes \
     tb_fsr_gate tb_fx_runtime tb_guidance_pipe tb_key_matrix tb_midi_rx tb_pitch_bend \
     tb_rhythm_hud tb_runtime_controls tb_score_capacity tb_sd_score tb_sd_multiblock \
     tb_spectrum_goertzel tb_test_voices tb_touch_carrier tb_uart_baud_check tb_wave_scope \
     tb_lissajous_scope tb_visual_pages tb_latency tb_showcase_director tb_showcase_import tb_showcase_midi_score tb_showcase_transport tb_display_integrity tb_uart_jdy9600"

if [ $# -ge 1 ]; then TBS="$*"; fi

pass_all=0
fail_all=0

for tb in $TBS; do
    src="sim/${tb}.v"
    if [ ! -f "$src" ]; then
        echo "----------------------------------------"
        echo "[FAIL] $tb  (找不到 $src；回归清单缺测试也算失败)"
        fail_all=$((fail_all + 1))
        continue
    fi
    echo "----------------------------------------"
    echo "[RUN ] $tb"

    # 个别 TB 必须显式列出依赖，不能用 -y 自动库搜索：
    #   tb_accomp_mix 实例化 score_accompaniment，后者用 timbre_voice，
    #   而 timbre_voice 定义在 fsr16_engine.v 内部。让 -y 去解析
    #   fsr16_engine.v 时，会撞上 note_freq.vh 在 freq_map.v 与
    #   fsr32_engine.v 两处 include 造成的重复声明，库文件直接解析失败。
    #   显式列这三个文件、不给 -y，就没有这个问题。
    case "$tb" in
        tb_accomp_mix)
            LIBOPT=""
            EXTRA="audio/src/score_accompaniment.v audio/src/fsr16_engine.v audio/src/freq_map.v"
            ;;
        tb_test_voices | tb_latency)
            LIBOPT=""
            EXTRA="audio/src/fsr32_engine.v audio/src/fsr16_engine.v audio/src/vib_lfo.v"
            ;;
        *)
            LIBOPT="-y rtl -y audio/src -y sim"
            EXTRA=""
            ;;
    esac

    # -y 让 iverilog 自己去找被实例化的模块，不用手工列依赖
    if ! "$IV" -g2012 -o "sim/out/${tb}.vvp" -s "$tb" \
            -I rtl -I audio/src -I sim \
            $LIBOPT "$src" $EXTRA 2>&1 | sed 's/^/       /'; then
        echo "[FAIL] $tb 编译失败"
        fail_all=$((fail_all + 1))
        continue
    fi
    out=$("$VVP" "sim/out/${tb}.vvp" 2>&1)
    sim_rc=$?
    echo "$out" | sed 's/^/       /'
    if [ "$sim_rc" -ne 0 ] || echo "$out" | grep -qiE "FAIL=[1-9]|\[FAIL\]|\*\*\* .*FAIL|ERROR: 超时|ERROR:|===== 失败|失败 [1-9]"; then
        echo "[FAIL] $tb (sim_rc=$sim_rc)"
        fail_all=$((fail_all + 1))
    else
        echo "[OK  ] $tb"
        pass_all=$((pass_all + 1))
    fi
done

echo "========================================"
echo "  附加：SD 跨块 TB 再跑一次 SecPerClus=8"
echo "  （真实 FAT32 卡由 Windows 格式化时簇 = 4KB，走的是簇内多扇区分支；"
echo "    默认那次是 SecPerClus=1，走 FAT 簇链分支。两条分支都要覆盖）"
echo "========================================"
if [ -f "sim/out/tb_sd_multiblock.vvp" ]; then
    out=$("$VVP" "sim/out/tb_sd_multiblock.vvp" +spc=8 2>&1)
    sim_rc=$?
    echo "$out" | grep -E "CFG|PASS /|FAIL" | sed 's/^/       /'
    if [ "$sim_rc" -ne 0 ] || echo "$out" | grep -qiE "FAIL=[1-9]|\[FAIL\]|\*\*\* .*FAIL|ERROR:|===== 失败|失败 [1-9]"; then
        echo "[FAIL] tb_sd_multiblock(spc=8) (sim_rc=$sim_rc)"
        fail_all=$((fail_all + 1))
    else
        echo "[OK  ] tb_sd_multiblock(spc=8)"
        pass_all=$((pass_all + 1))
    fi
fi

echo "========================================"
echo "  TB 通过: ${pass_all}    失败: ${fail_all}"
echo "========================================"
[ "$fail_all" -eq 0 ] || exit 1
exit 0
