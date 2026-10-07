create_clock -name clk -period 17.857 [get_ports clk]
derive_clock_uncertainty
set_false_path -from [get_ports {rst spr_* pal_* flip gfx_dv gfx_data*}]
set_false_path -to [get_ports {spr_rd* pal_rd* gfx_* ce_pix vid_* hblank vblank hsync vsync hpos* vpos* frame_start dbg_*}]
