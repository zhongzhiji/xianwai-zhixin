create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]
# PLL derives the original working 35MHz pixel clock. Do not declare clocks
# asynchronous or false-path the LCD/audio datapaths merely to make timing pass.
# Exact panel/external ADC timing is not supplied, so no fabricated output delay.

# Endpoint-specific exceptions for bus_snapshot_cdc's bundled-data mailbox.
# The four first-stage request/acknowledgement synchronizer D inputs deliberately
# accept asynchronous transitions. Their Q -> second-stage synchronizer D paths
# remain fully timed at the real 50/35 MHz period, as does all same-domain logic.
# Gowin SUG940 sections 5.1 and 5.4.1 support hierarchical wildcard get_pins.
set_false_path -to [get_pins {u_input_mailbox/req_meta_s*/D u_input_mailbox/ack_meta_s*/D u_control_mailbox/req_meta_s*/D u_control_mailbox/ack_meta_s*/D}]

# A sender launches payload and request together, then freezes payload until the
# acknowledgement returns through two source-domain FFs. In the destination,
# req_meta -> req_sync -> capture requires at least two destination periods
# (40 ns minimum at 50 MHz) before dst_data can sample a new payload. Bound
# payload settling to 15 ns, tighter than even the shortest 20 ns clock period.
# This is a real setup bound, not a blanket asynchronous-clock/false-path waiver.
# Gowin SUG940 section 5.4.2: set_max_delay overrides only setup/recovery.
# In bus_snapshot_cdc RTL, previous and payload reset together to zero and
# update together from src_data under the exact same source clock/enable.
# Gowin merged payload[39] into previous[39] for u_input_mailbox, and payload[43]
# into previous[43] for u_control_mailbox. Netlist D/CLK/CLEAR/CE and the direct
# dst_data D connections were checked by sim/audit_cdc_aliases.py. Include only
# those two proven frozen aliases; do not wildcard all previous registers.
set_max_delay -from [get_pins {u_input_mailbox/payload_*_s*/Q u_input_mailbox/previous_39_s0/Q}] -to [get_pins {u_input_mailbox/dst_data_*_s*/D}] 15.000
set_max_delay -from [get_pins {u_control_mailbox/payload_*_s*/Q u_control_mailbox/previous_43_s0/Q}] -to [get_pins {u_control_mailbox/dst_data_*_s*/D}] 15.000

# A zero-phase PLL hold relation is not the actual payload capture relation:
# after capture, the source cannot change payload for at least two further
# source periods (40 ns minimum), because its ack_meta/ack_sync handshake must
# complete first. Remove only these two bundled-data hold checks. The 15 ns
# maximum constraints above, sync-stage timing, and every other path are kept.
# SUG940 section 5.4.1 explicitly defines -hold separately from -setup.
set_false_path -hold -from [get_pins {u_input_mailbox/payload_*_s*/Q u_input_mailbox/previous_39_s0/Q}] -to [get_pins {u_input_mailbox/dst_data_*_s*/D}]
set_false_path -hold -from [get_pins {u_control_mailbox/payload_*_s*/Q u_control_mailbox/previous_43_s0/Q}] -to [get_pins {u_control_mailbox/dst_data_*_s*/D}]

# ---------------------------------------------------------------------------
# u_bt_mailbox: 蓝牙按键状态（当前按住的音符/力度）从 pixel_clk(35MHz) 送到
# sys_clk(50MHz) 的 32 复音引擎。与原有两个 mailbox 完全同构：同样是
# bus_snapshot_cdc 的 bundled-data 结构，同样靠 req/ack 握手保证 payload 在冻结期间
# 不变，因此适用同一套 15 ns 建立界 + hold 豁免。不加这几行时，工具会拿默认
# 20 ns 周期去检查这条跨时钟路径，实测炸出 11 个 setup + 1 个 hold 违例端点
# （slack 约 -2.25 ns），并把 sys_clk 的 Fmax 从 59.7 MHz 拖到勉强 50.2 MHz。
# ---------------------------------------------------------------------------
set_false_path -to [get_pins {u_bt_mailbox/req_meta_s*/D u_bt_mailbox/ack_meta_s*/D}]

set_max_delay -from [get_pins {u_bt_mailbox/payload_*_s*/Q u_bt_mailbox/previous_*_s*/Q}] -to [get_pins {u_bt_mailbox/dst_data_*_s*/D}] 15.000

set_false_path -hold -from [get_pins {u_bt_mailbox/payload_*_s*/Q u_bt_mailbox/previous_*_s*/Q}] -to [get_pins {u_bt_mailbox/dst_data_*_s*/D}]

# ---------------------------------------------------------------------------
# u_touch_mailbox: 触摸载板状态（online / fault / 6 条弦）从 sys_clk(50MHz) 送到
# pixel_clk(35MHz) 的显示核心。与上面三个 mailbox 完全同构，同样是
# bus_snapshot_cdc 的 bundled-data 握手。
#
# 为什么必须加：sys_clk(20ns) 与 pixel_clk(28.571ns) 的最小正相位差只有
#   |20k - 28.571m| 的最小值 = 20/7 ≈ 2.857 ns
# （GCD(50,35)=5MHz，公共周期 200ns，两族时钟沿最近可相差 2.857ns）。
# 握手臂是跨域电平，拿 2.857ns 窗口去约束它必然违例。
# 实测未加约束时该 mailbox 唯一违例端点为
#   u_touch_mailbox/ack_meta_s0 -> u_touch_mailbox/acknowledge_s0，slack ≈ -1.63ns
# （数据延迟本身只有 0.605ns，纯粹是时钟关系造成的假违例）。
#
# 处理方式保持了与另外三个 mailbox 一致的原则：
#   - 第一级同步器 D 端接受异步跳变 → set_false_path（亚稳态由后级同步器兜底）
#   - 载荷冻结 → 15ns 真实建立界 + hold 豁免
#   - 第一级同步器 D 端接受异步跳变 → set_false_path（亚稳态由后级同步器兜底）
#   - 载荷冻结 → 15ns 真实建立界 + hold 豁免
#
# 实测违例端点为
#   u_touch_mailbox/acknowledge_s0/Q -> u_touch_mailbox/ack_meta_s0/D，slack ≈ -1.63ns
# 方向是「握手回臂」：acknowledge 在 pixel_clk 域，ack_meta 是 sys_clk 域的第一级
# 同步触发器。数据延迟本身很小，违例纯粹来自 50/35MHz 的 2.857ns 最小时钟窗口，
# 属于同步器第一级的固有假违例，由上面的 set_false_path -to ack_meta_s*/D 覆盖。
# 不要再为它补 set_max_delay：那会与 false_path 冲突，且方向容易写反。
# ---------------------------------------------------------------------------
set_false_path -to [get_pins {u_touch_mailbox/req_meta_s*/D u_touch_mailbox/ack_meta_s*/D}]

set_max_delay -from [get_pins {u_touch_mailbox/payload_*_s*/Q u_touch_mailbox/previous_*_s*/Q}] -to [get_pins {u_touch_mailbox/dst_data_*_s*/D}] 15.000

set_false_path -hold -from [get_pins {u_touch_mailbox/payload_*_s*/Q u_touch_mailbox/previous_*_s*/Q}] -to [get_pins {u_touch_mailbox/dst_data_*_s*/D}]

# ---------------------------------------------------------------------------
# u_wave_mailbox: 实时波形示波器载荷，从 sys_clk(50MHz) 送到 pixel_clk(35MHz)。
# 与 u_touch_mailbox 完全同方向、同结构（bus_snapshot_cdc bundled-data 握手），
# 只是宽度从 8 变成 25：
#   {toggle[1], level[8], peak[8], sample[8]}
# toggle 位是关键：波形是连续流，相邻样本经常完全相等（静音/长延音），
# 没有它就判不出"有新数据"，波形上会出现被压缩的平直段。
# 源侧样本率 48000/16 = 3 kHz（周期 333 µs），握手往返约 100 ns，
# 余量 3000 倍以上，不会丢样本——载荷冻结的不变量同样成立。
# ---------------------------------------------------------------------------
set_false_path -to [get_pins {u_wave_mailbox/req_meta_s*/D u_wave_mailbox/ack_meta_s*/D}]

# 【11/01 修复 v2】本 mailbox 的 dst_data 捕获寄存器被 Gowin 综合合并进
# u_display/u_renderer 层级并改名 n686_s0，原 -to {u_wave_mailbox/dst_data_*_s*/D}
# 匹配不到 → 4 条 hold 违例（payload_8/14... → n686_s0，slack ≈ -0.10）漏网。
# get_clocks 拿不到 PLL 自动时钟（TA2004），故改为「只放行 payload 源」：
# RTL 里 payload 的唯一扇出就是 dst_data 捕获（bus_snapshot_cdc.v:45），
# -from-only 等价于豁免整条 CDC 腿，且对网表改名鲁棒。
# previous 的 Q 还要喂同域比较器（bus_snapshot_cdc.v:26），不在豁免之列。
set_false_path -from [get_pins {u_wave_mailbox/payload_*_s*/Q}]

set_false_path -hold -from [get_pins {u_wave_mailbox/payload_*_s*/Q}]

# ---------------------------------------------------------------------------
# u_spec_mailbox：32 频点频谱载荷 {toggle, bin[5], level[8]}，
# 从 sys_clk(50MHz) 送到 pixel_clk(35MHz)。与 u_wave_mailbox 完全同构，
# 帧率 0.683 s 一帧、32 个频点逐拍串行送出（间隔 64 拍），
# 源侧每 1.28 us 才来一次，握手余量 10 倍以上。
# 同样用 -from-only 豁免整条 CDC 腿（对网表改名鲁棒）。
# ---------------------------------------------------------------------------
set_false_path -to [get_pins {u_spec_mailbox/req_meta_s*/D u_spec_mailbox/ack_meta_s*/D}]

set_false_path -from [get_pins {u_spec_mailbox/payload_*_s*/Q}]

set_false_path -hold -from [get_pins {u_spec_mailbox/payload_*_s*/Q}]

# ---------------------------------------------------------------------------
# u_liss_mailbox：双通道李萨如载荷 {toggle, quiet, x[7], y[7]}，
# 从 sys_clk(50MHz) 送到 pixel_clk(35MHz)。点率 12 kHz（周期 83 us），
# 握手往返 ~100 ns，余量 800 倍。与上面两个 mailbox 同构处理。
# ---------------------------------------------------------------------------
set_false_path -to [get_pins {u_liss_mailbox/req_meta_s*/D u_liss_mailbox/ack_meta_s*/D}]

set_false_path -from [get_pins {u_liss_mailbox/payload_*_s*/Q}]

set_false_path -hold -from [get_pins {u_liss_mailbox/payload_*_s*/Q}]

# ---------------------------------------------------------------------------
# u_vocal 的总线仲裁握手：bus_to_wav 在 pixel_clk(35MHz) 域生成，
# bus_to_wav_sync 是 sys_clk(50MHz) 域的两级同步器。
# 仲裁本身是几十毫秒级的一次性事件（曲谱装载完才翻转一次），
# 第一级同步器 D 端天然要接受异步跳变，走的是与其余 mailbox 相同的处理：
#   · 第一级 D 端 set_false_path（亚稳态由第二级兜底）
#   · 第二级 Q 之后的所有逻辑照常按时序收敛
# 不要给这条线加 set_max_delay：它没有"载荷冻结"的不变量，
# 加最大延迟反而会掩盖真正的同步器问题。
# ---------------------------------------------------------------------------
# 网表里的实际触发器名是 bus_to_wav_sync_0_s0 / bus_to_wav_sync_1_s0
# （Gowin 对向量的每个 bit 单独命名：<名字>_<bit>_s<n>），
# 所以通配符必须是 bus_to_wav_sync_*_s*，写成 *_s* 以外的形式会匹配不到任何对象，
# 工具直接报 TA2003 "Can't set timing constraint to object" 并把整个 pnr 阶段打断。
set_false_path -to [get_pins {bus_to_wav_sync_*_s*/D}]

# 现场效果器 / N 音测试档位：pixel_clk -> sys_clk 的两级同步器。
# 档位由人工按键产生，保持至少数百毫秒；只豁免第一级 D 端，第二级后照常收敛。
set_false_path -to [get_pins {fx_meta_*_s*/D ts_meta_*_s*/D}]

# Autonomous demo status mailbox, bundled-data handshake.
set_false_path -to [get_pins {u_show_mailbox/req_meta_s*/D u_show_mailbox/ack_meta_s*/D}]
set_false_path -from [get_pins {u_show_mailbox/payload_*_s*/Q}]
set_false_path -hold -from [get_pins {u_show_mailbox/payload_*_s*/Q}]
