class axis_phase_jump_test extends axis_base_test;

    `uvm_component_utils(axis_phase_jump_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        axis_burst_seq burst;
        phase.raise_objection(this);
        burst = axis_burst_seq::type_id::create("burst");
        if (!burst.randomize() with {
            num_packets == 4;
            min_pkt_len == 4;
            max_pkt_len == 8;
        }) `uvm_error(get_type_name(), "Randomization failed")
        burst.start(env.master_agent.sqr);
        `uvm_info(get_type_name(), "Requesting phase jump to reset_phase", UVM_LOW)
        #100;
        phase.drop_objection(this);
    endtask

endclass
