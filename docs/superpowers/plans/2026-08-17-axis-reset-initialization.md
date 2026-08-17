# AXIS Reset Initialization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make canonical AXIS `tvalid` deterministically low from time zero while `aresetn` is asserted, with a regression that rejects the existing first-edge reset SVA error.

**Architecture:** Keep the private clocking-output proxy and resolved canonical net introduced by the raw-DUT-binding work. Gate only the proxy contribution to canonical `tvalid` during active-low reset, leaving DUT resolution, clocking blocks, UVM drivers, checker severity, READY behavior, and sidebands unchanged.

**Tech Stack:** SystemVerilog, UVM 1.2, GNU Make, Bash, Synopsys VCS W-2024.09-SP1, Git worktrees, System V shared memory.

---

## File map

- Create `axis_vip/tests/axis_if_reset_init_tb.sv`: focused non-UVM interface/SVA regression for the time-zero reset contract.
- Modify `axis_vip/sim/Makefile`: compile/run targets, warning/error gates, cleanup, and phony declarations for the new regression.
- Modify `axis_vip/src/axis_if.sv`: one reset gate on the private master proxy contribution to canonical `tvalid`.
- Test the dependent SHM tree without modifying it: `/home/ryan/workspace/ryan/shm_work/.worktrees/shm-agent-adapter`.

All simulation must run on `ubuntu@10.11.10.53` through `bash -lic` so the configured VCS and license environment is loaded. Authentication must use the approved interactive or preconfigured mechanism; no credential may appear in a command, URL, script, log, or commit.

### Task 1: Add the focused failing reset regression

**Files:**
- Create: `axis_vip/tests/axis_if_reset_init_tb.sv`
- Modify: `axis_vip/sim/Makefile`
- Test: `axis_vip/tests/axis_if_reset_init_tb.sv`

- [ ] **Step 1: Write the reset-initialization test before changing the interface**

Create `axis_vip/tests/axis_if_reset_init_tb.sv` with this complete content:

```systemverilog
`timescale 1ns/1ps

module axis_if_reset_init_tb;
  logic aclk = 1'b0;
  logic aresetn = 1'b0;

  always #5 aclk = ~aclk;

  axis_if #(32,4,4,1,0,1,1) axis_bus (
    .aclk(aclk),
    .aresetn(aresetn)
  );

  axis_protocol_checker_sva checker (
    .aif(axis_bus)
  );

  initial begin
    #1ps;
    axis_bus.chk_en_reset_signal_check = 1'b1;

    repeat (3) begin
      @(negedge aclk);
      if (axis_bus.tvalid !== 1'b0)
        $fatal(1, "tvalid=%b during reset, expected 0", axis_bus.tvalid);
    end

    axis_bus.chk_en_reset_signal_check = 1'b0;
    $display("AXIS_IF_RESET_INIT_PASS");
    $finish;
  end

  initial begin
    #100ns;
    $fatal(1, "timeout waiting for reset initialization checks");
  end
endmodule
```

- [ ] **Step 2: Add exact Make targets and cleanup entries**

Append these targets after `raw_modport_run` in `axis_vip/sim/Makefile`:

```make
reset_init_compile:
	vcs -full64 -sverilog -timescale=1ns/1ps -debug_access+all \
		../src/axis_if.sv ../src/axis_protocol_checker_sva.sv \
		../tests/axis_if_reset_init_tb.sv \
		-top axis_if_reset_init_tb -o simv_reset_init \
		-l reset_init_compile.log
	! grep -Eq 'Warning-\[(ICPSD_W|ICPD_W)\]' reset_init_compile.log

reset_init_run: reset_init_compile
	./simv_reset_init -l reset_init_run.log
	grep -Fq 'AXIS_IF_RESET_INIT_PASS' reset_init_run.log
	! grep -Fq '[RESET_SIGNAL_CHECK]' reset_init_run.log
	! grep -Eq '^Error:' reset_init_run.log
```

Extend the existing `clean` continuation so it reads:

```make
	rm -rf simv simv.dbin simv_raw_binding simv_raw_binding.daidir \
		simv_raw_modport simv_raw_modport.daidir \
		simv_reset_init simv_reset_init.daidir \
		csrc work xcelium.d INCA_libs *.log *.key DVEfiles ucli.key
```

Extend `.PHONY` with `reset_init_compile reset_init_run`.

- [ ] **Step 3: Export the uncommitted worktree to a fresh VCS-host directory**

Run locally from `/home/ryan/workspace/ryan/axis_vip/.worktrees/raw-dut-binding`:

```bash
REMOTE_RESET_RED=$(ssh ubuntu@10.11.10.53 \
  "bash -lic 'mktemp -d /tmp/axis-reset-red.XXXXXX'")
tar -cf - axis_vip | ssh ubuntu@10.11.10.53 \
  "bash -lic 'tar -x -C $REMOTE_RESET_RED'"
```

Expected: the remote directory contains `axis_vip/tests/axis_if_reset_init_tb.sv` and the modified Makefile without requiring a local commit.

- [ ] **Step 4: Verify RED for the intended reset defect**

Run:

```bash
ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd $REMOTE_RESET_RED/axis_vip/sim && make reset_init_run'"
```

Expected: nonzero exit. `reset_init_run.log` contains exactly one or more `[RESET_SIGNAL_CHECK] TVALID asserted during reset` diagnostics and no `AXIS_IF_RESET_INIT_PASS` marker because canonical `tvalid` is unknown before the first clocking-output drive.

Confirm the reason, then clean only this owned temporary directory:

```bash
ssh ubuntu@10.11.10.53 \
  "bash -lic 'grep -F \"[RESET_SIGNAL_CHECK] TVALID asserted during reset\" $REMOTE_RESET_RED/axis_vip/sim/reset_init_run.log; find $REMOTE_RESET_RED -depth -delete'"
```

- [ ] **Step 5: Commit the RED contract**

```bash
git add axis_vip/tests/axis_if_reset_init_tb.sv axis_vip/sim/Makefile
git diff --cached --check
git commit -m "test: reproduce AXIS reset initialization error"
```

### Task 2: Gate the proxy contribution during reset

**Files:**
- Modify: `axis_vip/src/axis_if.sv:39`
- Test: `axis_vip/tests/axis_if_reset_init_tb.sv`

- [ ] **Step 1: Implement the one-line reset gate**

Replace:

```systemverilog
    assign tvalid = master_tvalid;
```

with:

```systemverilog
    assign tvalid = aresetn ? master_tvalid : 1'b0;
```

Do not initialize `master_tvalid`, change the SVA, or gate sideband/READY signals.

- [ ] **Step 2: Export the modified worktree to a second fresh VCS-host directory**

```bash
REMOTE_RESET_GREEN=$(ssh ubuntu@10.11.10.53 \
  "bash -lic 'mktemp -d /tmp/axis-reset-green.XXXXXX'")
tar -cf - axis_vip | ssh ubuntu@10.11.10.53 \
  "bash -lic 'tar -x -C $REMOTE_RESET_GREEN'"
```

- [ ] **Step 3: Verify GREEN and pristine focused output**

```bash
ssh ubuntu@10.11.10.53 \
  "bash -lic 'set -e; cd $REMOTE_RESET_GREEN/axis_vip/sim; make reset_init_run; grep -Fc AXIS_IF_RESET_INIT_PASS reset_init_run.log; if grep -Eq \"Warning-\[(ICPSD_W|ICPD_W)\]|^Error:|\[RESET_SIGNAL_CHECK\]\" reset_init_compile.log reset_init_run.log; then exit 1; fi'"
```

Expected: exit zero, pass-marker count `1`, and no reset diagnostic, runtime `Error:`, `ICPSD_W`, or `ICPD_W`.

Clean the owned verification copy:

```bash
ssh ubuntu@10.11.10.53 \
  "bash -lic 'find $REMOTE_RESET_GREEN -depth -delete'"
```

- [ ] **Step 4: Commit the minimal implementation**

```bash
git add axis_vip/src/axis_if.sv
git diff --cached --check
git commit -m "fix: drive AXIS valid low during reset"
```

### Task 3: Run the complete axis_vip regression on the exact HEAD

**Files:**
- Verify: `axis_vip/src/axis_if.sv`
- Verify: `axis_vip/tests/axis_if_reset_init_tb.sv`
- Verify: `axis_vip/tests/axis_if_raw_binding_tb.sv`
- Verify: `axis_vip/tests/axis_if_raw_modport_tb.sv`

- [ ] **Step 1: Create a fresh archive of committed `HEAD` on the VCS host**

```bash
REMOTE_AXIS_ACCEPT=$(ssh ubuntu@10.11.10.53 \
  "bash -lic 'mktemp -d /tmp/axis-reset-accept.XXXXXX'")
git archive HEAD | ssh ubuntu@10.11.10.53 \
  "bash -lic 'tar -x -C $REMOTE_AXIS_ACCEPT'"
```

- [ ] **Step 2: Run all three interface-level regressions**

```bash
ssh ubuntu@10.11.10.53 \
  "bash -lic 'set -e; cd $REMOTE_AXIS_ACCEPT/axis_vip/sim; make reset_init_run; make raw_binding_run; make raw_modport_run; if grep -Eq \"Warning-\[(ICPSD_W|ICPD_W)\]\" reset_init_compile.log raw_binding_compile.log raw_modport_compile.log; then exit 1; fi'"
```

Expected markers:

```text
AXIS_IF_RESET_INIT_PASS
AXIS_IF_RAW_BINDING_PASS
AXIS_IF_RAW_MODPORT_PASS
```

- [ ] **Step 3: Compile once and run all seven UVM tests with independent logs**

```bash
ssh ubuntu@10.11.10.53 "bash -lic '
  set -e
  cd $REMOTE_AXIS_ACCEPT/axis_vip/sim
  make vcs_compile > reset_accept_compile.console 2>&1
  for test_name in \
    axis_sanity_test axis_backpressure_test axis_bandwidth_test \
    axis_reset_test axis_phase_jump_test axis_full_regression_test \
    axis_misalign_test
  do
    log_name=reset_accept_\${test_name}.log
    ./simv +UVM_TESTNAME=\${test_name} +UVM_VERBOSITY=UVM_LOW \
      +ntb_random_seed=1 -l \${log_name} >/dev/null
    grep -Eq \"UVM_ERROR[[:space:]]*:[[:space:]]*0\" \${log_name}
    grep -Eq \"UVM_FATAL[[:space:]]*:[[:space:]]*0\" \${log_name}
    if grep -Eq \"^Error:|\[RESET_SIGNAL_CHECK\]\" \${log_name}; then
      exit 1
    fi
    printf \"%s PASS\\n\" \${test_name}
  done
'"
```

Expected: seven `PASS` lines, zero UVM errors/fatals, and no SVA reset diagnostic or runtime `Error:` in any log.

- [ ] **Step 4: Clean the owned axis acceptance copy**

```bash
ssh ubuntu@10.11.10.53 \
  "bash -lic 'find $REMOTE_AXIS_ACCEPT -depth -delete'"
```

### Task 4: Re-run dependent SHM adapter and end-to-end acceptance

**Files:**
- Verify only: `/home/ryan/workspace/ryan/shm_work/.worktrees/shm-agent-adapter/shm_switch`
- Verify only: `/home/ryan/workspace/ryan/axis_vip/.worktrees/raw-dut-binding/axis_vip`

- [ ] **Step 1: Run the local shell regression wrapper**

```bash
cd /home/ryan/workspace/ryan/shm_work/.worktrees/shm-agent-adapter
bash shm_switch/tests/test_regression_fixes.sh
git diff --check
```

Expected: `SHM_REGRESSION_FIXES_PASS` and exit zero.

- [ ] **Step 2: Export both exact committed HEADs to one fresh VCS-host root**

```bash
REMOTE_SHM_ACCEPT=$(ssh ubuntu@10.11.10.53 \
  "bash -lic 'mktemp -d /tmp/shm-reset-accept.XXXXXX'")
git -C /home/ryan/workspace/ryan/shm_work/.worktrees/shm-agent-adapter \
  archive HEAD | ssh ubuntu@10.11.10.53 \
  "bash -lic 'mkdir $REMOTE_SHM_ACCEPT/shm; tar -x -C $REMOTE_SHM_ACCEPT/shm'"
git -C /home/ryan/workspace/ryan/axis_vip/.worktrees/raw-dut-binding \
  archive HEAD | ssh ubuntu@10.11.10.53 \
  "bash -lic 'mkdir $REMOTE_SHM_ACCEPT/axis; tar -x -C $REMOTE_SHM_ACCEPT/axis'"
```

- [ ] **Step 3: Run package, adapter, endpoint, codec, bridge, and READY checks**

```bash
ssh ubuntu@10.11.10.53 "bash -lic '
  set -e
  cd $REMOTE_SHM_ACCEPT/shm/shm_switch
  make all
  make dpi VCS_HOME=\${VCS_HOME}
  make uvm_pkg_test VCS_HOME=\${VCS_HOME}
  make uvm_adapter_test VCS_HOME=\${VCS_HOME}
  SHM_KEY=0x6a180100 bash run_vcs_endpoint_test.sh
  make axis_codec_test VCS_HOME=\${VCS_HOME} \
    AXIS_VIP_ROOT=$REMOTE_SHM_ACCEPT/axis/axis_vip
  make -C examples/axis_vip ready-test VCS_HOME=\${VCS_HOME} \
    AXIS_VIP_ROOT=$REMOTE_SHM_ACCEPT/axis/axis_vip
'"
```

Expected: package, all four adapter cases, all three endpoint cases, exact codec marker `assertions=105 subtests=15`, bridge compile plus TX_ONLY/RX_ONLY/BIDIR, and READY marker `input=4 output=4 simultaneous=3` all pass.

- [ ] **Step 4: Run all four SHM/AXIS end-to-end packet cases**

```bash
ssh ubuntu@10.11.10.53 "bash -lic '
  set -e
  cd $REMOTE_SHM_ACCEPT/shm/shm_switch
  SHM_KEY=0x6a181000 \
  AXIS_VIP_ROOT=$REMOTE_SHM_ACCEPT/axis/axis_vip \
    bash run_axis_shm_test.sh
'"
```

Expected cases:

```text
aligned:     8 packets x 64 bytes
partial:     8 packets x 70 bytes
consecutive: 40 packets x 129 bytes
pause:       50 packets x 64 bytes, PAUSE observed
```

Every case must have exact TX/RX frame and byte counters, zero retry/drop counters, zero scoreboard mismatch/pending counts, `DROP 0` on both ports, and zero UVM errors/fatals.

- [ ] **Step 5: Audit logs and resource cleanup before deleting the test copy**

```bash
ssh ubuntu@10.11.10.53 "bash -lic '
  set -e
  cd $REMOTE_SHM_ACCEPT/shm/shm_switch
  if grep -E \"UVM_ERROR[[:space:]]*:[[:space:]]*[1-9]|UVM_FATAL[[:space:]]*:[[:space:]]*[1-9]|^Error:|\[RESET_SIGNAL_CHECK\]\" \
      -- uvm_*.log endpoint_*.log axis_*_uvm.log axis_codec_test.log \
      axis_bridge_*.log examples/axis_vip/ready_test.log
  then
    exit 1
  fi
  if ipcs -m | grep -Eiq \"0x6a180100|0x6a1810(10|20|30|40)\"; then
    exit 1
  fi
  if ipcs -s | grep -Eiq \"0x6a180101|0x6a1810(11|21|31|41)\"; then
    exit 1
  fi
'"
ssh ubuntu@10.11.10.53 \
  "bash -lic 'find $REMOTE_SHM_ACCEPT -depth -delete'"
```

Expected: no matching log anomaly, no selected shared-memory/semaphore key, and the owned remote test copy is removed.

### Task 5: Final repository verification and handoff

**Files:**
- Verify: both isolated worktrees
- Preserve: both feature branches for the user's integration choice

- [ ] **Step 1: Verify both worktrees and exact HEADs**

```bash
git -C /home/ryan/workspace/ryan/axis_vip/.worktrees/raw-dut-binding \
  status --short --branch
git -C /home/ryan/workspace/ryan/axis_vip/.worktrees/raw-dut-binding \
  diff --check
git -C /home/ryan/workspace/ryan/axis_vip/.worktrees/raw-dut-binding \
  rev-parse HEAD
git -C /home/ryan/workspace/ryan/shm_work/.worktrees/shm-agent-adapter \
  status --short --branch
git -C /home/ryan/workspace/ryan/shm_work/.worktrees/shm-agent-adapter \
  diff --check
git -C /home/ryan/workspace/ryan/shm_work/.worktrees/shm-agent-adapter \
  rev-parse HEAD
```

Expected: both feature worktrees clean. Do not merge, push, delete either branch, or rewrite history without the user's explicit choice/authorization.

- [ ] **Step 2: Report dependency order and remaining security gate**

Report that `fix/raw-dut-binding` must be published/merged before the SHM branch that consumes its raw DUT contract. Keep one env, two role agents, two independent `axis_if` instances, and one SHM bridge/endpoint in the user integration.

Also report that the current SHM tree is sanitized but old reachable feature-branch commits still require explicit authorization before history rewriting. Remind the user to rotate previously exposed credentials without repeating their values.
