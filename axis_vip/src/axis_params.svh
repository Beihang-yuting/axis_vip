`ifndef AXIS_PARAMS_SVH
`define AXIS_PARAMS_SVH

// ---- Project-wide AXIS interface parameters ----
// Single source of truth for axis_if instantiation across axis_vip
// and downstream consumers (e.g., xilinx_pcie).
// To switch widths, modify only this file.

// Max-width container — accommodates all PG213 widths (64/128/256/512)
// TDATA = max DATA_WIDTH = 512
// TUSER = max per-channel tuser = CQ@512 = 375
`define AXIS_VIF_PARAMS \
    .TDATA_WIDTH (512), \
    .TID_WIDTH   (4),   \
    .TDEST_WIDTH (4),   \
    .TUSER_WIDTH (375), \
    .HAS_TSTRB   (0),   \
    .HAS_TKEEP   (1),   \
    .HAS_TLAST   (1)

`define AXIS_VIF_INST(name, clk, rstn) \
    axis_if #(`AXIS_VIF_PARAMS) name (.aclk(clk), .aresetn(rstn))

`endif
