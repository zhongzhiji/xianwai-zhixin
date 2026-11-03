# 构建状态与可复现边界

当前源码：BT_BAUD = 9600，35 MHz 接收域每位 3646 周期；演示标题为“自由切换”。

上一轮默认布局因 PR0004（326 条未布通网络）失败。本轮显示修订使用 run_label_build.tcl，以 place_option=3、route_option=0 重新构建。新位流与最终 Setup/Hold 结果尚未发布；此前 115200 基线不能作为当前源码构建结果。

历史完整功能回归记录为 31 项 RTL、19 项网关、7 项音游算法、9 项浏览器场景。本次标题修改另通过 4 项定向回归，详见 free-switch-title.md 和 verification/free_switch_title。

这些测试没有操作真实开发板或无线串口，物理交互、无线和端到端时延应由对应实测记录说明。
