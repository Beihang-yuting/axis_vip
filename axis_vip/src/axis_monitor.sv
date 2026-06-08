class axis_monitor extends uvm_monitor;

    `uvm_component_utils(axis_monitor)

    axis_vif_t vif;
    axis_config cfg;

    uvm_analysis_port #(axis_transfer) beat_ap;
    uvm_analysis_port #(axis_packet)   packet_ap;

    protected axis_packet in_progress_packets[bit[15:0]];
    protected int unsigned last_beat_time[bit[15:0]];
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
        if (!uvm_config_db#(axis_vif_t)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found in config_db")
    endfunction

    task run_phase(uvm_phase phase);
        fork
            sample_loop();
            timeout_monitor_loop();
        join
    endtask

    protected task sample_loop();
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

    protected task timeout_monitor_loop();
        // Only active in TIMEOUT mode
        forever begin
            @(posedge vif.aclk);
            if (in_reset || cfg.pkt_boundary_mode != PKT_BOUNDARY_TIMEOUT)
                continue;
            begin
                bit [15:0] tids_to_flush[$];
                foreach (last_beat_time[tid]) begin
                    last_beat_time[tid]++;
                    if (last_beat_time[tid] >= cfg.pkt_boundary_timeout_cycles)
                        tids_to_flush.push_back(tid);
                end
                foreach (tids_to_flush[i]) begin
                    bit [15:0] tid = tids_to_flush[i];
                    if (in_progress_packets.exists(tid)) begin
                        packet_ap.write(in_progress_packets[tid]);
                        in_progress_packets.delete(tid);
                    end
                    last_beat_time.delete(tid);
                end
            end
        end
    endtask

    protected function void sample_beat();
        axis_transfer tr = axis_transfer::type_id::create("tr");
        tr.cfg   = cfg;
        tr.tdata = vif.tdata;
        tr.tstrb = cfg.HAS_TSTRB ? vif.tstrb : '1;
        tr.tkeep = cfg.HAS_TKEEP ? vif.tkeep : '1;
        tr.tlast = cfg.HAS_TLAST ? vif.tlast : 1'b0;
        tr.tid   = vif.tid;
        tr.tdest = vif.tdest;
        tr.tuser = vif.tuser;

        beat_ap.write(tr);

        if (!in_progress_packets.exists(tr.tid)) begin
            in_progress_packets[tr.tid] = axis_packet::type_id::create(
                $sformatf("pkt_tid%0d", tr.tid));
        end

        in_progress_packets[tr.tid].add_beat(tr);

        // Packet completion check
        begin
            bit pkt_complete = 0;
            case (cfg.pkt_boundary_mode)
                PKT_BOUNDARY_TLAST:
                    pkt_complete = tr.tlast || !cfg.HAS_TLAST;
                PKT_BOUNDARY_TIMEOUT: begin
                    last_beat_time[tr.tid] = 0;  // Reset timeout counter
                    pkt_complete = 0;  // timeout_monitor_loop handles completion
                end
                PKT_BOUNDARY_FIXED_LEN:
                    pkt_complete = (in_progress_packets[tr.tid].packet_length
                                   >= cfg.pkt_boundary_fixed_length);
            endcase

            if (pkt_complete) begin
                packet_ap.write(in_progress_packets[tr.tid]);
                in_progress_packets.delete(tr.tid);
                last_beat_time.delete(tr.tid);
            end
        end
    endfunction

    protected function void flush_in_progress();
        in_progress_packets.delete();
        last_beat_time.delete();
    endfunction

    function void set_in_reset(bit rst);
        in_reset = rst;
        if (rst) flush_in_progress();
    endfunction

endclass
