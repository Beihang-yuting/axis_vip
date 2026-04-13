class axis_slave_driver extends uvm_driver #(axis_transfer);

    `uvm_component_utils(axis_slave_driver)

    virtual axis_if vif;
    axis_config cfg;
    axis_bandwidth_controller bw_ctrl;
    bit in_reset = 0;

    protected bit valid_seen = 0;
    protected int unsigned delay_counter = 0;
    protected int unsigned target_delay = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(axis_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "axis_config not found in config_db")
        if (!uvm_config_db#(virtual axis_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found in config_db")
    endfunction

    task run_phase(uvm_phase phase);
        drive_reset_values();
        forever begin
            if (in_reset) begin
                drive_reset_values();
                valid_seen = 0;
                delay_counter = 0;
                @(posedge vif.aclk);
                continue;
            end
            drive_ready();
            @(vif.slave_cb);
        end
    endtask

    protected task drive_ready();
        bit tvalid_current;
        tvalid_current = vif.slave_cb.tvalid;

        case (cfg.ready_gen_mode)
            READY_ALWAYS: begin
                vif.slave_cb.tready <= 1'b1;
            end
            READY_BEFORE_VALID: begin
                vif.slave_cb.tready <= 1'b1;
            end
            READY_WITH_VALID: begin
                vif.slave_cb.tready <= tvalid_current;
            end
            READY_AFTER_VALID: begin
                if (tvalid_current && !valid_seen) begin
                    valid_seen = 1;
                    target_delay = bw_ctrl.get_ready_delay();
                    delay_counter = 0;
                end
                if (valid_seen) begin
                    if (delay_counter >= target_delay) begin
                        vif.slave_cb.tready <= 1'b1;
                        if (tvalid_current) begin
                            valid_seen = 0;
                            delay_counter = 0;
                        end
                    end else begin
                        vif.slave_cb.tready <= 1'b0;
                        delay_counter++;
                    end
                end else begin
                    vif.slave_cb.tready <= 1'b0;
                end
            end
            READY_WEIGHTED: begin
                vif.slave_cb.tready <= bw_ctrl.should_assert_ready(tvalid_current);
            end
            READY_TOGGLE: begin
                vif.slave_cb.tready <= bw_ctrl.should_assert_ready(tvalid_current);
            end
            READY_PROFILE: begin
                vif.slave_cb.tready <= bw_ctrl.should_assert_ready(tvalid_current);
            end
            default: begin
                vif.slave_cb.tready <= 1'b1;
            end
        endcase
    endtask

    function void drive_reset_values();
        vif.slave_cb.tready <= 1'b0;
    endfunction

    function void set_in_reset(bit rst);
        in_reset = rst;
    endfunction

endclass
