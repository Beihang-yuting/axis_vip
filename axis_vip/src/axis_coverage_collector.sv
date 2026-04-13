class axis_coverage_collector extends uvm_subscriber #(axis_transfer);

    `uvm_component_utils(axis_coverage_collector)

    axis_config cfg;

    protected bit       sampled_tvalid;
    protected bit       sampled_tready;
    protected int unsigned sampled_pkt_len;
    protected bit [15:0]   sampled_tid;
    protected bit [15:0]   sampled_tdest;
    protected bit       sampled_tdata_all_zero;
    protected bit       sampled_tdata_all_one;
    protected int unsigned sampled_bp_duration;
    protected int unsigned sampled_handshake_latency;
    protected real      sampled_bandwidth;
    protected bit [2:0] sampled_reset_timing;
    protected axis_valid_gen_mode_e sampled_valid_gen_mode;
    protected axis_ready_gen_mode_e sampled_ready_gen_mode;

    protected int unsigned current_pkt_len;
    protected int unsigned handshake_latency_counter;

    covergroup handshake_cg;
        cp_valid_ready: coverpoint {sampled_tvalid, sampled_tready} {
            bins idle      = {2'b00};
            bins valid_only = {2'b10};
            bins ready_only = {2'b01};
            bins handshake = {2'b11};
        }
        cp_latency: coverpoint sampled_handshake_latency {
            bins zero     = {0};
            bins one      = {1};
            bins short_   = {[2:5]};
            bins medium   = {[6:20]};
            bins long_    = {[21:100]};
            bins very_long = {[101:$]};
        }
    endgroup

    covergroup packet_cg;
        cp_length: coverpoint sampled_pkt_len {
            bins single  = {1};
            bins short_  = {[2:4]};
            bins medium  = {[5:16]};
            bins long_   = {[17:64]};
            bins longer  = {[65:256]};
            bins max_    = {[257:$]};
        }
        cp_tid: coverpoint sampled_tid {
            bins values[] = {[0:15]};
        }
        cp_tdest: coverpoint sampled_tdest {
            bins values[] = {[0:15]};
        }
        cp_tid_x_tdest: cross cp_tid, cp_tdest;
    endgroup

    covergroup backpressure_cg;
        cp_bp_duration: coverpoint sampled_bp_duration {
            bins zero    = {0};
            bins one     = {1};
            bins short_  = {[2:5]};
            bins medium  = {[6:20]};
            bins long_   = {[21:$]};
        }
    endgroup

    covergroup data_cg;
        cp_all_zero: coverpoint sampled_tdata_all_zero {
            bins yes = {1};
            bins no  = {0};
        }
        cp_all_one: coverpoint sampled_tdata_all_one {
            bins yes = {1};
            bins no  = {0};
        }
    endgroup

    covergroup reset_cg;
        cp_timing: coverpoint sampled_reset_timing {
            bins idle         = {0};
            bins mid_transfer = {1};
            bins mid_packet   = {2};
        }
    endgroup

    covergroup bandwidth_cg;
        cp_bw: coverpoint sampled_bandwidth {
            bins zero     = {0};
            bins low      = {[0.001:0.25]};
            bins medium   = {[0.251:0.5]};
            bins high     = {[0.501:0.75]};
            bins very_high = {[0.751:1.0]};
        }
    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        handshake_cg    = new();
        packet_cg       = new();
        backpressure_cg = new();
        data_cg         = new();
        reset_cg        = new();
        bandwidth_cg    = new();
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(axis_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "axis_config not found in config_db")
    endfunction

    function void write(axis_transfer t);
        sampled_tvalid = 1;
        sampled_tready = 1;
        sampled_handshake_latency = handshake_latency_counter;
        handshake_cg.sample();

        sampled_tdata_all_zero = (t.tdata == 0);
        sampled_tdata_all_one  = (t.tdata == ((1 << cfg.TDATA_WIDTH) - 1));
        data_cg.sample();

        current_pkt_len++;
        if (t.tlast || !cfg.HAS_TLAST) begin
            sampled_pkt_len = current_pkt_len;
            sampled_tid     = t.tid;
            sampled_tdest   = t.tdest;
            packet_cg.sample();
            current_pkt_len = 0;
        end

        handshake_latency_counter = 0;
    endfunction

    function void sample_backpressure(int unsigned duration);
        sampled_bp_duration = duration;
        backpressure_cg.sample();
    endfunction

    function void sample_bandwidth(real bw);
        sampled_bandwidth = bw;
        bandwidth_cg.sample();
    endfunction

    function void sample_reset_timing(int unsigned timing);
        sampled_reset_timing = timing[2:0];
        reset_cg.sample();
    endfunction

endclass
