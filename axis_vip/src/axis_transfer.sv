class axis_transfer extends uvm_sequence_item;

    rand bit [511:0]  tdata;
    rand bit [63:0]   tstrb;
    rand bit [63:0]   tkeep;
    rand bit          tlast;
    rand bit [15:0]   tid;
    rand bit [15:0]   tdest;
    rand bit [127:0]  tuser;
    rand int unsigned delay;

    axis_config cfg;

    `uvm_object_utils_begin(axis_transfer)
        `uvm_field_int(tdata,  UVM_ALL_ON)
        `uvm_field_int(tstrb,  UVM_ALL_ON)
        `uvm_field_int(tkeep,  UVM_ALL_ON)
        `uvm_field_int(tlast,  UVM_ALL_ON)
        `uvm_field_int(tid,    UVM_ALL_ON)
        `uvm_field_int(tdest,  UVM_ALL_ON)
        `uvm_field_int(tuser,  UVM_ALL_ON)
        `uvm_field_int(delay,  UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "axis_transfer");
        super.new(name);
    endfunction

    constraint c_data_width {
        (cfg != null) -> tdata inside {[0 : (1 << cfg.TDATA_WIDTH) - 1]};
    }
    constraint c_strb_width {
        (cfg != null) -> tstrb inside {[0 : (1 << cfg.get_byte_lanes()) - 1]};
    }
    constraint c_keep_width {
        (cfg != null) -> tkeep inside {[0 : (1 << cfg.get_byte_lanes()) - 1]};
    }
    constraint c_tid_width {
        (cfg != null) -> tid inside {[0 : (1 << cfg.TID_WIDTH) - 1]};
    }
    constraint c_tdest_width {
        (cfg != null) -> tdest inside {[0 : (1 << cfg.TDEST_WIDTH) - 1]};
    }
    constraint c_tuser_width {
        (cfg != null) -> tuser inside {[0 : (1 << cfg.TUSER_WIDTH) - 1]};
    }
    constraint c_tkeep_tstrb {
        (cfg != null && cfg.HAS_TSTRB && cfg.HAS_TKEEP) -> (tstrb & ~tkeep) == 0;
    }
    constraint c_delay {
        delay inside {[0:20]};
    }
    constraint c_keep_default {
        soft tkeep == (1 << ((cfg != null) ? cfg.get_byte_lanes() : 4)) - 1;
    }
    constraint c_strb_default {
        soft tstrb == tkeep;
    }

endclass
