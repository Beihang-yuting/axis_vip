class axis_error_inject_seq extends axis_base_seq;

    `uvm_object_utils(axis_error_inject_seq)

    typedef enum {
        ERR_TKEEP_TSTRB_MISMATCH,
        ERR_DATA_ALL_X
    } error_type_e;

    rand error_type_e error_type;

    function new(string name = "axis_error_inject_seq");
        super.new(name);
    endfunction

    task body();
        axis_transfer tr;
        tr = axis_transfer::type_id::create("err_tr");
        tr.cfg = cfg;
        start_item(tr);
        if (!tr.randomize()) `uvm_error(get_type_name(), "Randomization failed")
        case (error_type)
            ERR_TKEEP_TSTRB_MISMATCH: begin
                tr.tkeep = 4'b0000;
                tr.tstrb = 4'b1111;
                tr.tlast = 1;
            end
            ERR_DATA_ALL_X: begin
                tr.tdata = 0;
                tr.tlast = 1;
            end
        endcase
        finish_item(tr);
    endtask

endclass
