open_project "music_pro.gprj"
set_option -include_path [file join audio src]
set_option -top_module top_music_pro
set_option -verilog_std v2001
set_option -output_base_name music_pro_showcase
run syn
run pnr
run close
