// cva6_tlb_formal_pkg.sv
// -----------------------------------------------------------------------------
// Formal package for standalone CVA6 TLB verification.
//
// Purpose:
//   - Build one concrete CVA6 configuration.
//   - Define the PTE = Page Table Entry type.
//   - Define the TLB update packet type.
//   - Let both the formal top and scoreboard use the exact same types.
// -----------------------------------------------------------------------------

package cva6_tlb_formal_pkg;

  // cva6_config_pkg::cva6_cfg is the selected user config.
  // build_config_pkg::build_config(...) computes the full internal CVA6Cfg
  // with derived fields like:
  //   PtLevels
  //   VpnLen
  //   PPNW
  //   ASID_WIDTH
  //   VMID_WIDTH
  localparam config_pkg::cva6_cfg_t CVA6Cfg =
      build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);

  // First proof step: non-hypervisor TLB.
  localparam int unsigned HYP_EXT = 0;

  // Keep small for formal at first.
  // Later you can change this to CVA6Cfg.DataTlbEntries or CVA6Cfg.InstrTlbEntries.
  localparam int unsigned TLB_ENTRIES = 4;

  // PTE = Page Table Entry.
  //
  // Same layout as the local pte_cva6_t used in cva6_mmu.sv.
  typedef struct packed {
    logic n;
    logic [8:0] reserved;
    logic [CVA6Cfg.PPNW-1:0] ppn;
    logic [1:0] rsw;
    logic d;
    logic a;
    logic g;
    logic u;
    logic x;
    logic w;
    logic r;
    logic v;
  } pte_cva6_t;

  // TLB update packet.
  //
  // Same layout as the local tlb_update_cva6_t used in cva6_mmu.sv.
  typedef struct packed {
    logic valid;
    logic is_napot_64k;
    logic [CVA6Cfg.PtLevels-2:0][HYP_EXT:0] is_page;
    logic [CVA6Cfg.VpnLen-1:0] vpn;
    logic [CVA6Cfg.ASID_WIDTH-1:0] asid;
    logic [CVA6Cfg.VMID_WIDTH-1:0] vmid;
    logic [HYP_EXT*2:0] v_st_enbl;
    pte_cva6_t content;
    pte_cva6_t g_content;
  } tlb_update_cva6_t;

endpackage