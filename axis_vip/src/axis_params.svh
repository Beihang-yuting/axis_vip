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

// ---- Transaction 容器宽度（item 最大宽度，不随接口参数变化）----
`define AXIS_MAX_TDATA  512
`define AXIS_MAX_TUSER  512
`define AXIS_MAX_TID    16
`define AXIS_MAX_TDEST  16

`define AXIS_VIF_INST(name, clk, rstn) \
    axis_if #(`AXIS_VIF_PARAMS) name (.aclk(clk), .aresetn(rstn))

`endif
