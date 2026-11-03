# 右上角标题文字更新

本次仅将自动演示工程右上角首行统一显示为“自由切换”，并补齐“由”“换”字形。下方播放状态、TEST INPUT 标识、页面、导演、音频和输入处理不变；它没有新增模式切换按钮。非自动演示工程仍使用原有标题逻辑。

新增 tb_showcase_title：检查 7 页 × 2 自动状态 × 3 练习状态的 4 个标题字符，下方播放/暂停/演奏/静音状态，以及非展示模式原有标题和 TEST INPUT 页脚。测试还导出真实 renderer 的 140×62 像素区域。

执行方式：`python tools/run_rtl.py tb_showcase_title tb_display_integrity tb_showcase_transport tb_runtime_controls`，四项通过。原有字库的 276 个映射与 4008 个显式初始化行逐项保持一致，新增两个字共 40 行。

当前是源码与仿真更新，尚未烧录。上一轮 9600 默认布局构建因 326 条未布通网络失败；本轮使用 run_label_build.tcl 的 place_option=3、route_option=0 重试，仍需检查最终布线与时序报告。没有将旧位流作为本次文字更新产物发布。
