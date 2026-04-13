class axis_monitor extends uvm_monitor;

    `uvm_component_utils(axis_monitor)

    virtual axis_if vif;
    axis_config cfg;

    uvm_analysis_port #(axis_transfer) beat_ap;
    uvm_analysis_port #(axis_packet)   packet_ap;

    protected axis_packet in_progress_packets[bit[15:0]];
    bit in_reset = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        beat_ap   = new("beat_ap",   this);
        packet_ap = new("packet_ap", this);
        if (!uvm_config_db#(axis_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "axis_config not found in config_db")
        if (!uvm_config_db#(virtual axis_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found in config_db")
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            if (in_reset) begin
                flush_in_progress();
                @(posedge vif.aclk);
                continue;
            end
            @(vif.monitor_cb);
            if (vif.monitor_cb.tvalid && vif.monitor_cb.tready) begin
                sample_beat();
            end
        end
    endtask

    protected function void sample_beat();
        axis_transfer tr = axis_transfer::type_id::create("tr");
        tr.cfg   = cfg;
        tr.tdata = vif.monitor_cb.tdata;
        tr.tstrb = cfg.HAS_TSTRB ? vif.monitor_cb.tstrb : '1;
        tr.tkeep = cfg.HAS_TKEEP ? vif.monitor_cb.tkeep : '1;
        tr.tlast = cfg.HAS_TLAST ? vif.monitor_cb.tlast : 1'b0;
        tr.tid   = vif.monitor_cb.tid;
        tr.tdest = vif.monitor_cb.tdest;
        tr.tuser = vif.monitor_cb.tuser;

        beat_ap.write(tr);

        if (!in_progress_packets.exists(tr.tid)) begin
            in_progress_packets[tr.tid] = axis_packet::type_id::create(
                $sformatf("pkt_tid%0d", tr.tid));
        end

        in_progress_packets[tr.tid].add_beat(tr);

        if (tr.tlast || !cfg.HAS_TLAST) begin
            packet_ap.write(in_progress_packets[tr.tid]);
            in_progress_packets.delete(tr.tid);
        end
    endfunction

    protected function void flush_in_progress();
        in_progress_packets.delete();
    endfunction

    function void set_in_reset(bit rst);
        in_reset = rst;
        if (rst) flush_in_progress();
    endfunction

endclass
