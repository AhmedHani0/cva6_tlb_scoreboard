# CVA6 TLB Scoreboard Formal Verification

This repository contains standalone formal verification setups for CVA6 TLB-related modules using an abstract scoreboard approach.

The current focus is on:

* `cva6_tlb`: private TLB verification.

The verification is done using SystemVerilog Assertions (SVA) and OneSpin.

---

## 1. What Is a TLB?

TLB means **Translation Lookaside Buffer**.

A TLB is a small cache inside the processor that stores recently used address translations. Modern processors usually use virtual memory. Software works with virtual addresses, while memory hardware needs physical addresses. The TLB stores these translations so the processor does not need to walk the page table for every memory access.

In simple terms:

```text
Virtual address comes in
TLB checks if the translation is already cached
If hit: return the translation quickly
If miss: the page table walker must fetch the translation and refill the TLB
```

Important abbreviations:

```text
TLB   = Translation Lookaside Buffer
ITLB  = Instruction Translation Lookaside Buffer
DTLB  = Data Translation Lookaside Buffer
MMU   = Memory Management Unit
PTW   = Page Table Walker
VPN   = Virtual Page Number
ASID  = Address Space Identifier
VMID  = Virtual Machine Identifier
PTE   = Page Table Entry
NAPOT = Naturally Aligned Power-of-Two page encoding
PLRU  = Pseudo-Least Recently Used replacement policy
RVH   = RISC-V Hypervisor extension
```

---

## 2. Repository Goal

The goal of this repository is to formally verify key observable behavior of CVA6 TLB modules without building a second complete TLB model.

The scoreboard does **not** model:

* the full TLB table,
* all physical entries,
* PLRU replacement,
* exact internal hit priority,
* every page-size overlap case,
* a full MMU or PTW implementation.

Instead, it tracks one abstract refill episode and checks that the DUT returns the expected translation content when it later reports a hit for the tracked translation.

The main correctness idea is:

```text
If a lookup misses,
and a later update refills that missed translation,
then a later hit for that tracked translation must return the inserted PTE content.
```

---

## 3. Verification Approach

The private TLB scoreboard uses a two-state abstraction:

```text
MISS state:
  The scoreboard is waiting for a TLB miss or for an update that refills a
  previously observed miss.

TRACKING state:
  The scoreboard has captured one accepted update and is tracking that
  translation.
```

The scoreboard starts in `MISS` state after reset.

It moves from `MISS` to `TRACKING` when an accepted update arrives and that update matches the remembered missed lookup identity.

It moves from `TRACKING` back to `MISS` when:

1. reset occurs,
2. a matching flush targets the tracked entry,
3. any lookup miss is observed.

This gives the abstract flow:

```text
reset
  -> MISS
lookup miss
  -> remember missed VPN / ASID / VMID / stage context
accepted update matching the remembered miss
  -> TRACKING
tracked hit
  -> check returned content
matching flush or new lookup miss
  -> MISS
```

---

## 4. Why This Two-State Scoreboard Was Chosen

In standalone formal verification, `update_i` is unconstrained unless we add an environment contract. Without constraints, the formal tool can inject arbitrary updates that may create duplicate or overlapping TLB entries.

That can produce counterexamples that are not necessarily RTL bugs, but rather unrealistic standalone-environment behavior.

For example:

```text
1. The scoreboard tracks an update for VPN X.
2. Formal injects another arbitrary update.
3. The real TLB may now contain overlapping or duplicate entries.
4. The scoreboard expects one content value.
5. The RTL may hit another physical entry with different content.
```

To avoid modeling the complete TLB table and replacement policy, the scoreboard uses the following environment assumption:

```text
An accepted update is only allowed while the scoreboard is in MISS state,
and the update must match the missed lookup identity remembered by the scoreboard.
```

This models the high-level MMU/PTW behavior:

```text
lookup miss -> shared TLB response -> TLB refill
```

without implementing the full PTW.

---

## 5. Private TLB Verification

Relevant files:

```text
cva6_tlb.sv
cva6_tlb_formal_pkg.sv
cva6_tlb_formal_top.sv
cva6_tlb_scoreboard_bind.sv
run_onespin_tlb.tcl
```

If the repository currently stores the final scoreboard as:

```text
cva6_tlb_scoreboard_final.sv
```

then either rename it before running:

```bash
cp cva6_tlb_scoreboard_final.sv cva6_tlb_scoreboard_bind.sv
```

or update `run_onespin_tlb.tcl` to read the final filename.

---

## 6. Private TLB Scoreboard Properties

### 6.1 Main Data Integrity Property

The main property checks that a tracked hit returns the tracked PTE content:

```text
p_tracked_data_integrity_on_hit
```

Conceptually:

```text
If:
  scoreboard is in TRACKING state,
  scoreboard entry is valid,
  lookup matches the tracked identity,
  DUT reports a hit,

then:
  DUT returned PTE content must match the tracked scoreboard PTE content.
```

NAPOT handling is abstracted by masking dynamic low PPN bits for 64 KiB NAPOT entries instead of duplicating the RTL patching logic.

---

### 6.2 State Transition Properties

The scoreboard also checks that it moves back to `MISS` state when the tracked abstraction is no longer valid.

Examples:

```text
p_matching_flush_moves_to_miss_state
p_lookup_miss_moves_to_miss_state
```

These properties check that:

```text
matching flush -> scoreboard returns to MISS
lookup miss    -> scoreboard returns to MISS
```

---

### 6.3 Environment Assumptions

The main environment assumptions are:

```text
a_at_most_one_flush_kind
a_no_update_during_any_flush
a_update_only_after_scoreboard_miss
a_no_lookup_access_during_update
```

Meaning:

```text
Only one flush kind is active at a time.
No update occurs during a flush.
An update can occur only after a remembered miss.
The update must match the remembered miss identity.
A lookup access and update are not combined in the same cycle.
```

These assumptions are used because the TLB is verified standalone, without the full MMU/PTW environment.

---

## 7. Page Size and G-Stage Output Checks

The main scoreboard proof is the PTE content integrity proof.

Additional derived-output checks may be enabled separately for:

```text
lu_is_page_o
lu_gpaddr_o
lu_g_content_o
```

These are stronger than the main abstract scoreboard property.

They check RTL-derived output formatting related to:

* page size,
* 4 KiB / 2 MiB / 1 GiB pages,
* NAPOT,
* guest physical address generation,
* G-stage PTE output.

These properties should be kept separate from the main content-integrity property because they require more expected-output modeling.

The intended separation is:

```text
Main scoreboard property:
  Does the tracked refill return the correct PTE content?

Derived-output properties:
  Are the page-size, guest-physical-address, and G-stage formatted outputs
  consistent with the tracked update metadata?
```

---

## 8. Flush Handling

The TLB supports three flush families:

```text
flush_i      = SFENCE.VMA
flush_vvma_i = HFENCE.VVMA
flush_gvma_i = HFENCE.GVMA
```

### SFENCE.VMA

Normal supervisor virtual-memory flush.

Handled cases:

```text
SFENCE.VMA x0, x0
SFENCE.VMA vaddr, x0
SFENCE.VMA x0, asid
SFENCE.VMA vaddr, asid
```

### HFENCE.VVMA

Hypervisor flush for VS-stage translations.

Handled similarly to SFENCE.VMA, but for virtualized VS-stage entries.

### HFENCE.GVMA

Hypervisor flush for G-stage translations.

Current conservative scope:

```text
HFENCE.GVMA x0, x0
HFENCE.GVMA x0, vmid
```

Guest-physical-address-specific GVMA cases are not fully modeled in the abstract scoreboard because that would require tracking or deriving the guest physical page identity.

---

## 9. Running the Private TLB Proof

Open OneSpin, then source the private TLB script:

```tcl
source run_onespin_tlb.tcl
```

The script performs the following steps:

```text
1. Read CVA6 packages.
2. Read the local formal package.
3. Read the DUT, formal top, and scoreboard bind.
4. Elaborate cva6_tlb_formal_top.
5. Compile the formal model.
6. Set MV mode.
7. Print all available checks.
8. Run all checks one by one.
```

Make sure the paths inside the TCL script match your local CVA6 checkout and repository location.

---
## 10. Important Verification Scope

This repository does prove:

```text
A tracked TLB refill returns the expected PTE content on a later tracked hit.
The scoreboard moves between MISS and TRACKING states correctly.
Updates are constrained to follow observed misses.
Flushes invalidate the tracked abstraction.
The shared TLB returns tracked content consistently to ITLB/DTLB refill outputs.
```

This repository does not currently prove the complete correctness of:

```text
full TLB table behavior,
PLRU replacement,
all duplicate-entry/overlap priority cases,
complete MMU/PTW behavior,
all guest-physical-address-specific GVMA flush cases.
```

This is intentional. The verification strategy is to keep the scoreboard abstract and focused on observable refill/hit data integrity.

---

## 11. Why This Is Useful

The two-state scoreboard gives a scalable way to verify TLB data integrity without duplicating the entire RTL.

The main benefit is that it avoids turning the scoreboard into a second TLB implementation.

The final abstraction is:

```text
Observe a miss.
Require the update to refill that miss.
Track the refill.
Check that later hits return the tracked content.
Return to miss state on flush or miss.
```

This gives a clean, explainable, and reusable formal verification strategy for CVA6 TLB modules.
