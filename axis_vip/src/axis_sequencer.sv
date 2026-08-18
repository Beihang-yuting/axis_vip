class axis_sequencer extends uvm_sequencer #(axis_transfer);

    `uvm_component_utils(axis_sequencer)

    axis_config cfg;
    // Legacy compatibility read view: OR of reset and phase-drain freezes.
    // Update freeze state only through the two reason-specific setters.
    bit reset_active = 0;
    string last_seq_type_name;

    protected bit reset_freeze_active = 0;
    protected bit phase_drain_freeze_active = 0;
    protected int unsigned driver_owned_items = 0;
    protected uvm_event admission_open_evt;
    protected uvm_event driver_idle_evt;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        admission_open_evt = new("admission_open_evt");
        driver_idle_evt = new("driver_idle_evt");
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

    protected function void refresh_admission_state();
        bit was_active = reset_active;
        reset_active = reset_freeze_active || phase_drain_freeze_active;
        if (reset_active)
            admission_open_evt.reset();
        else if (was_active)
            admission_open_evt.trigger();
    endfunction

    function void set_reset_active(bit active);
        reset_freeze_active = active;
        refresh_admission_state();
    endfunction

    function void set_phase_drain_active(bit active);
        phase_drain_freeze_active = active;
        refresh_admission_state();
    endfunction

    function bit is_phase_drain_active();
        return phase_drain_freeze_active;
    endfunction

    virtual task wait_for_grant(
        uvm_sequence_base sequence_ptr,
        int item_priority = -1,
        bit lock_request = 0
    );
        while (reset_active)
            admission_open_evt.wait_ptrigger();
        super.wait_for_grant(sequence_ptr, item_priority, lock_request);
    endtask

    // Driver ownership starts when get_next_item() returns and ends only after
    // item_done().  has_do_available() does not cover this interval.
    function void begin_driver_item();
        if (driver_owned_items == 0)
            driver_idle_evt.reset();
        driver_owned_items++;
    endfunction

    function void end_driver_item();
        if (driver_owned_items == 0) begin
            `uvm_fatal(get_type_name(),
                "Driver item ownership underflow")
            return;
        end
        driver_owned_items--;
        if (driver_owned_items == 0)
            driver_idle_evt.trigger();
    endfunction

    function int unsigned get_driver_owned_count();
        return driver_owned_items;
    endfunction

    task wait_for_driver_idle();
        while (driver_owned_items != 0)
            driver_idle_evt.wait_ptrigger();
    endtask

    task restart_last_sequence();
        uvm_object_wrapper seq_type;
        uvm_sequence_base  seq;
        uvm_factory factory;

        if (last_seq_type_name == "") begin
            `uvm_info(get_type_name(), "No sequence to restart after hot-reset", UVM_MEDIUM)
            return;
        end

        factory = uvm_factory::get();
        seq_type = factory.find_wrapper_by_name(last_seq_type_name);
        if (seq_type == null) begin
            `uvm_error(get_type_name(),
                $sformatf("Cannot find sequence type '%s' for hot-reset restart",
                          last_seq_type_name))
            return;
        end

        $cast(seq, seq_type.create_object(last_seq_type_name));
        if (seq == null) begin
            `uvm_error(get_type_name(), "Failed to create sequence for hot-reset restart")
            return;
        end

        `uvm_info(get_type_name(),
            $sformatf("Hot-reset: restarting sequence '%s'", last_seq_type_name), UVM_LOW)
        fork
            seq.start(this);
        join_none
    endtask

endclass
