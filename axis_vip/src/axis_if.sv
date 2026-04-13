interface axis_if #(
    parameter int TDATA_WIDTH = 32,
    parameter int TID_WIDTH   = 4,
    parameter int TDEST_WIDTH = 4,
    parameter int TUSER_WIDTH = 1,
    parameter bit HAS_TSTRB   = 1,
    parameter bit HAS_TKEEP   = 1,
    parameter bit HAS_TLAST   = 1
)(
    input logic aclk,
    input logic aresetn
);

    logic                       tvalid;
    logic                       tready;
    logic [TDATA_WIDTH-1:0]     tdata;
    logic [TDATA_WIDTH/8-1:0]   tstrb;
    logic [TDATA_WIDTH/8-1:0]   tkeep;
    logic                       tlast;
    logic [TID_WIDTH-1:0]       tid;
    logic [TDEST_WIDTH-1:0]     tdest;
    logic [TUSER_WIDTH-1:0]     tuser;

    // Master clocking block
    clocking master_cb @(posedge aclk);
        default input #1step output #0;
        output tvalid, tdata, tstrb, tkeep, tlast, tid, tdest, tuser;
        input  tready;
    endclocking

    // Slave clocking block
    clocking slave_cb @(posedge aclk);
        default input #1step output #0;
        output tready;
        input  tvalid, tdata, tstrb, tkeep, tlast, tid, tdest, tuser;
    endclocking

    // Monitor clocking block
    clocking monitor_cb @(posedge aclk);
        default input #1step;
        input tvalid, tready, tdata, tstrb, tkeep, tlast, tid, tdest, tuser;
    endclocking

    // Modports
    modport master_mp  (clocking master_cb,  input aclk, aresetn);
    modport slave_mp   (clocking slave_cb,   input aclk, aresetn);
    modport monitor_mp (clocking monitor_cb, input aclk, aresetn);

endinterface
