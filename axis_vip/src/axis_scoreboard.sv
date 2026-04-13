class axis_scoreboard extends uvm_scoreboard;

    `uvm_component_utils(axis_scoreboard)

    uvm_analysis_imp_decl(_master)
    uvm_analysis_imp_decl(_slave)

    uvm_analysis_imp_master #(axis_packet, axis_scoreboard) master_export;
    uvm_analysis_imp_slave  #(axis_packet, axis_scoreboard) slave_export;

    protected axis_packet master_queue[$];
    protected axis_packet slave_queue[$];

    int unsigned match_count;
    int unsigned mismatch_count;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        master_export = new("master_export", this);
        slave_export  = new("slave_export",  this);
    endfunction

    function void write_master(axis_packet pkt);
        master_queue.push_back(pkt);
        try_compare();
    endfunction

    function void write_slave(axis_packet pkt);
        slave_queue.push_back(pkt);
        try_compare();
    endfunction

    protected function void try_compare();
        while (master_queue.size() > 0 && slave_queue.size() > 0) begin
            axis_packet expected_pkt = master_queue.pop_front();
            axis_packet actual_pkt   = slave_queue.pop_front();

            if (expected_pkt.compare_payload(actual_pkt)) begin
                match_count++;
                `uvm_info(get_type_name(),
                    $sformatf("MATCH: packet tid=%0h tdest=%0h len=%0d",
                              expected_pkt.tid, expected_pkt.tdest, expected_pkt.packet_length),
                    UVM_HIGH)
            end else begin
                mismatch_count++;
                `uvm_error(get_type_name(),
                    $sformatf("MISMATCH: packet tid=%0h tdest=%0h len=%0d vs len=%0d",
                              expected_pkt.tid, expected_pkt.tdest,
                              expected_pkt.packet_length, actual_pkt.packet_length))
            end
        end
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info(get_type_name(),
            $sformatf("Scoreboard summary: %0d matches, %0d mismatches, %0d master pending, %0d slave pending",
                      match_count, mismatch_count, master_queue.size(), slave_queue.size()),
            UVM_LOW)
        if (master_queue.size() > 0)
            `uvm_error(get_type_name(),
                $sformatf("%0d packets in master queue not received by slave", master_queue.size()))
        if (slave_queue.size() > 0)
            `uvm_error(get_type_name(),
                $sformatf("%0d packets in slave queue not sent by master", slave_queue.size()))
    endfunction

endclass
