# AXIS Interface Reset Initialization Design

**Date:** 2026-08-17

**Scope:** `axis_vip` interface reset behavior and focused VCS regression

**Goal:** Keep canonical `tvalid` low from time zero while active-low reset is
asserted, without hiding a real DUT reset violation or reintroducing clocking/DUT
multiple-driver warnings.

## Background

The existing seven-test UVM regression ends with zero UVM errors and fatals, but
each test emits one SVA error at the first 5 ns clock edge:

```text
[RESET_SIGNAL_CHECK] TVALID asserted during reset
```

The behavior reproduces once on both upstream baseline
`8515b229f0726c1fa1585b878c1e4137913aa275` and the current raw-DUT-binding
branch. It is therefore a pre-existing reset-initialization defect, not a
regression from the private clocking proxy change.

The master clocking output proxy has no driven value before its first clocking
event. Although the UVM master driver assigns reset values at time zero, a
clocking-block output assignment does not make the canonical signal known before
the first checker sample. The reset checker consequently evaluates `!tvalid`
against an unknown value and reports an error.

## Selected design

Gate only the clocking-driver contribution to canonical `tvalid` while the
interface's active-low `aresetn` input is asserted:

```systemverilog
assign tvalid = aresetn ? master_tvalid : 1'b0;
```

No driver, checker, UVM phase, or sideband behavior changes. The canonical AXIS
net remains a resolved net so it can still connect to an RTL DUT:

- On a DUT input link, the VIP presents a deterministic low `tvalid` throughout
  reset, including before UVM phases start.
- On a DUT output link, a conforming DUT also drives low and the resolved value
  remains low.
- If a DUT incorrectly drives high or unknown during reset, resolution against
  the reset-low contribution produces an unknown/high result and the existing
  SVA still fails. The change therefore does not suppress a real DUT violation.
- After reset deassertion, the existing private proxy is passed through
  unchanged, preserving the warning-clean raw binding architecture.

Only `tvalid` is gated. AXI-Stream does not require payload sidebands to be known
when `tvalid` is low, so gating other signals would expand the behavior change
without addressing an observed defect.

## Alternatives rejected

1. **Initialize from the UVM driver or repository testbench.** This fixes only
   environments in which that process starts early enough; third-party
   integrations retain the same time-zero window.
2. **Delay or weaken the reset SVA.** This cleans the log by ignoring the first
   observation instead of making the interface contract correct.
3. **Add a second procedural initializer to the private proxy.** This risks
   reintroducing the procedural/clocking multiple-driver warnings that the raw
   binding branch removes.

## Regression contract

Add a standalone `axis_if` reset-initialization smoke test and Make targets. The
test uses the real `axis_protocol_checker_sva`, enables only the reset-signal
check, keeps `aresetn` asserted across the first clock edges, and requires:

- canonical `tvalid === 1'b0` during reset;
- a unique `AXIS_IF_RESET_INIT_PASS` marker;
- no `[RESET_SIGNAL_CHECK]` diagnostic and no `Error:` line;
- no `ICPSD_W` or `ICPD_W` compile warning.

TDD evidence must show the target failing on the unmodified interface for the
expected reset diagnostic, then passing after the one-line gate. Final
verification reruns scalar raw binding, raw modport binding, the seven UVM tests,
the SHM adapter/unit/endpoint/codec/bridge checks, READY behavior, and all four
SHM/AXIS end-to-end packet cases on the designated VCS host.

## Non-goals

- Changing reset polarity or the `aresetn` port contract.
- Changing AXIS READY generation, UVM phase sequencing, or checker severity.
- Initializing data/sideband signals that are irrelevant while `tvalid` is low.
- Modifying the SHM adapter protocol or endpoint architecture.
