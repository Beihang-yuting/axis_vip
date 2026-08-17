interface axis_if #(
    parameter int TDATA_WIDTH = 512,   // 默认最大值，兼容 PCIe 256/512 位宽
    parameter int TID_WIDTH   = 4,
    parameter int TDEST_WIDTH = 4,
    parameter int TUSER_WIDTH = 512,   // 默认最大值，兼容 PCIe tuser 各通道宽度
    parameter bit HAS_TSTRB   = 1,
    parameter bit HAS_TKEEP   = 1,
    parameter bit HAS_TLAST   = 1,
    // tkeep 粒度 (per-instance): 默认 per-byte (TDATA/8, 标准 AXIS/ETH 原样)。
    // Xilinx PG213 PCIe 传 TDATA_WIDTH/32 (per-DWORD) 以匹配真实 DUT 的 tkeep。
    parameter int TKEEP_WIDTH = TDATA_WIDTH/8
)(
    input logic aclk,
    input logic aresetn
);

    wire logic                       tvalid;
    wire logic                       tready;
    wire logic [TDATA_WIDTH-1:0]     tdata;
    wire logic [TDATA_WIDTH/8-1:0]   tstrb;
    wire logic [TKEEP_WIDTH-1:0]     tkeep;
    wire logic                       tlast;
    wire logic [TID_WIDTH-1:0]       tid;
    wire logic [TDEST_WIDTH-1:0]     tdest;
    wire logic [TUSER_WIDTH-1:0]     tuser;

    wire logic                       master_tvalid;
    wire logic [TDATA_WIDTH-1:0]     master_tdata;
    wire logic [TDATA_WIDTH/8-1:0]   master_tstrb;
    wire logic [TKEEP_WIDTH-1:0]     master_tkeep;
    wire logic                       master_tlast;
    wire logic [TID_WIDTH-1:0]       master_tid;
    wire logic [TDEST_WIDTH-1:0]     master_tdest;
    wire logic [TUSER_WIDTH-1:0]     master_tuser;
    wire logic                       slave_tready;

    assign tvalid = master_tvalid;
    assign tdata = master_tdata;
    assign tstrb = master_tstrb;
    assign tkeep = master_tkeep;
    assign tlast = master_tlast;
    assign tid = master_tid;
    assign tdest = master_tdest;
    assign tuser = master_tuser;
    assign tready = slave_tready;

    clocking master_cb @(posedge aclk);
        default input #1step output #0;
        output tvalid = master_tvalid;
        output tdata = master_tdata;
        output tstrb = master_tstrb;
        output tkeep = master_tkeep;
        output tlast = master_tlast;
        output tid = master_tid;
        output tdest = master_tdest;
        output tuser = master_tuser;
        input tready;
    endclocking

    clocking slave_cb @(posedge aclk);
        default input #1step output #0;
        output tready = slave_tready;
        input tvalid, tdata, tstrb, tkeep, tlast, tid, tdest, tuser;
    endclocking

    clocking monitor_cb @(posedge aclk);
        default input #0;
        input tvalid, tready, tdata, tstrb, tkeep, tlast, tid, tdest, tuser;
    endclocking

    modport master_mp  (clocking master_cb,  input aclk, aresetn);
    modport slave_mp   (clocking slave_cb,   input aclk, aresetn);
    modport monitor_mp (clocking monitor_cb, input aclk, aresetn);

    modport dut_slave_mp (
        input aclk, aresetn,
        input tvalid, tdata, tstrb, tkeep, tlast, tid, tdest, tuser,
        output tready
    );
    modport dut_master_mp (
        input aclk, aresetn,
        output tvalid, tdata, tstrb, tkeep, tlast, tid, tdest, tuser,
        input tready
    );

    // Protocol checker control signals (set by UVM axis_protocol_checker)
    logic        chk_en_tvalid_stability;
    logic        chk_en_tdata_stability;
    logic        chk_en_tlast_integrity;
    logic        chk_en_tid_consistency;
    logic        chk_en_tdest_consistency;
    logic        chk_en_tkeep_tstrb_relation;
    logic        chk_en_reset_signal_check;
    logic        chk_en_x_z_check;
    logic        chk_en_handshake_timeout;
    int unsigned chk_handshake_timeout_cycles;

    initial begin
        chk_en_tvalid_stability     = 0;
        chk_en_tdata_stability      = 0;
        chk_en_tlast_integrity      = 0;
        chk_en_tid_consistency      = 0;
        chk_en_tdest_consistency    = 0;
        chk_en_tkeep_tstrb_relation = 0;
        chk_en_reset_signal_check   = 0;
        chk_en_x_z_check           = 0;
        chk_en_handshake_timeout    = 0;
        chk_handshake_timeout_cycles = 1000;
    end

endinterface
