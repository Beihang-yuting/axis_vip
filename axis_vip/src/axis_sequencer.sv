class axis_sequencer extends uvm_sequencer #(axis_transfer);

    `uvm_component_utils(axis_sequencer)

    axis_config cfg;
    bit reset_active = 0;
    string last_seq_type_name;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(axis_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "axis_config not found in config_db")
    endfunction

    function void flush_pending();
        stop_sequences();
        `uvm_info(get_type_name(), "Flushed pending transactions due to reset", UVM_MEDIUM)
    endfunction

    function void set_reset_active(bit active);
        reset_active = active;
    endfunction

endclass
