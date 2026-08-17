# axis_vip/sim/Makefile
# Cross-tool simulation build

TEST ?= axis_sanity_test
SEED ?= random
VERBOSITY ?= UVM_MEDIUM
TOOL ?= vcs

UVM_ARGS = +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(VERBOSITY)
FILELIST = filelist.f

# ---- VCS ----
VCS_OPTS = -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
           -debug_access+all \
           +incdir+../src +incdir+../sequences +incdir+../tests \
           -f $(FILELIST) -l compile.log

vcs_compile:
	vcs $(VCS_OPTS) -o simv

vcs_run: vcs_compile
	./simv $(UVM_ARGS) +ntb_random_seed=$(SEED) -l run.log

# ---- Xcelium ----
XRUN_OPTS = -sv -uvm -64bit -timescale 1ns/1ps \
            +incdir+../src +incdir+../sequences +incdir+../tests \
            -f $(FILELIST) -l compile.log

xcelium_compile:
	xrun -compile $(XRUN_OPTS)

xcelium_run:
	xrun $(XRUN_OPTS) $(UVM_ARGS) -svseed $(SEED) -l run.log

# ---- Questa ----
QUESTA_OPTS = -sv -timescale 1ns/1ps \
              +incdir+../src +incdir+../sequences +incdir+../tests

questa_compile:
	vlib work
	vlog $(QUESTA_OPTS) -f $(FILELIST) -l compile.log

questa_run: questa_compile
	vsim -c -do "run -all; quit" $(UVM_ARGS) -sv_seed $(SEED) work.tb_top -l run.log

# ---- Convenience targets ----
ifeq ($(TOOL),vcs)
compile: vcs_compile
run: vcs_run
else ifeq ($(TOOL),xcelium)
compile: xcelium_compile
run: xcelium_run
else ifeq ($(TOOL),questa)
compile: questa_compile
run: questa_run
endif

regression:
	$(MAKE) run TEST=axis_sanity_test
	$(MAKE) run TEST=axis_backpressure_test
	$(MAKE) run TEST=axis_bandwidth_test
	$(MAKE) run TEST=axis_reset_test
	$(MAKE) run TEST=axis_phase_jump_test
	$(MAKE) run TEST=axis_full_regression_test
	$(MAKE) run TEST=axis_misalign_test

raw_binding_compile:
	vcs -full64 -sverilog -timescale=1ns/1ps -debug_access+all \
		../src/axis_if.sv ../tests/axis_if_raw_binding_tb.sv \
		-top axis_if_raw_binding_tb -o simv_raw_binding \
		-l raw_binding_compile.log
	! grep -Eq 'Warning-\[(ICPSD_W|ICPD_W)\]' raw_binding_compile.log

raw_binding_run: raw_binding_compile
	./simv_raw_binding -l raw_binding_run.log
	grep -Fq 'AXIS_IF_RAW_BINDING_PASS' raw_binding_run.log

raw_modport_compile:
	vcs -full64 -sverilog -timescale=1ns/1ps -debug_access+all \
		../src/axis_if.sv ../tests/axis_if_raw_modport_tb.sv \
		-top axis_if_raw_modport_tb -o simv_raw_modport \
		-l raw_modport_compile.log
	! grep -Eq 'Warning-\[(ICPSD_W|ICPD_W)\]' raw_modport_compile.log

raw_modport_run: raw_modport_compile
	./simv_raw_modport -l raw_modport_run.log
	grep -Fq 'AXIS_IF_RAW_MODPORT_PASS' raw_modport_run.log

clean:
	rm -rf simv simv.dbin simv_raw_binding simv_raw_binding.daidir \
		simv_raw_modport simv_raw_modport.daidir \
		csrc work xcelium.d INCA_libs *.log *.key DVEfiles ucli.key

.PHONY: compile run regression clean vcs_compile vcs_run xcelium_compile \
	xcelium_run questa_compile questa_run raw_binding_compile raw_binding_run \
	raw_modport_compile raw_modport_run
