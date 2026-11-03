# Display-only title change; keep synthesis, clock and pin constraints intact.
# Placement option 3 is a routing retry after the previous default placement
# left 326 unrouted nets. A generated bitstream must still pass timing review.
open_project "music_pro.gprj"
set_option -include_path [file join audio src]
set_option -top_module top_music_pro
set_option -verilog_std v2001
set_option -output_base_name music_pro_showcase
set_option -place_option 3
set_option -route_option 0
run syn
run pnr
run close
