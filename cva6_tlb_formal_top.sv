// cva6_tlb_formal_top.sv
// -----------------------------------------------------------------------------
// Minimal formal top wrapper for CVA6 TLB instance.
//
// Purpose:
//   - Instantiate one cva6_tlb with a concrete built CVA6 configuration.
//   - Use shared typedefs from cva6_tlb_formal_pkg.
//   - First step verification: normal non-hypervisor TLB behavior only.
// -----------------------------------------------------------------------------

module cva6_tlb_formal_top
  import ariane_pkg::*;
  import cva6_tlb_formal_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    // Normal TLB controls.
    input logic flush_i,

    // TLB update packet from the abstract/formal environment.
    input tlb_update_cva6_t update_i,

    // Lookup interface.
    input  logic lu_access_i,
    input  logic [CVA6Cfg.ASID_WIDTH-1:0] lu_asid_i,
    input  logic [CVA6Cfg.VLEN-1:0]       lu_vaddr_i,
    output logic [CVA6Cfg.GPLEN-1:0]      lu_gpaddr_o,
    output pte_cva6_t                     lu_content_o,
    output pte_cva6_t                     lu_g_content_o,

    // Normal SFENCE.VMA flush filters.
    input logic [CVA6Cfg.ASID_WIDTH-1:0] asid_to_be_flushed_i,
    input logic [CVA6Cfg.VLEN-1:0]       vaddr_to_be_flushed_i,

    // Lookup result.
    output logic [CVA6Cfg.PtLevels-2:0] lu_is_page_o,
    output logic                        lu_hit_o
);

  // ---------------------------------------------------------------------------
  // Turn off hypervisor-related signals for the first non-RVH verification step.
  // ---------------------------------------------------------------------------

  logic flush_vvma_i;
  logic flush_gvma_i;
  logic s_st_enbl_i;
  logic g_st_enbl_i;
  logic v_i;

  logic [CVA6Cfg.VMID_WIDTH-1:0] lu_vmid_i;
  logic [CVA6Cfg.VMID_WIDTH-1:0] vmid_to_be_flushed_i;
  logic [CVA6Cfg.GPLEN-1:0]      gpaddr_to_be_flushed_i;

  assign flush_vvma_i           = 1'b0;
  assign flush_gvma_i           = 1'b0;

  // Enable normal supervisor translation.
  assign s_st_enbl_i            = 1'b1;

  // Disable guest/hypervisor translation.
  assign g_st_enbl_i            = 1'b0;
  assign v_i                    = 1'b0;

  // Unused hypervisor identifiers/addresses.
  assign lu_vmid_i              = '0;
  assign vmid_to_be_flushed_i   = '0;
  assign gpaddr_to_be_flushed_i = '0;

  // ---------------------------------------------------------------------------
  // TLB under verification.
  // The scoreboard binds into this cva6_tlb instance automatically.
  // ---------------------------------------------------------------------------

  cva6_tlb #(
      .CVA6Cfg          (CVA6Cfg),
      .pte_cva6_t       (pte_cva6_t),
      .tlb_update_cva6_t(tlb_update_cva6_t),
      .TLB_ENTRIES      (TLB_ENTRIES),
      .HYP_EXT          (HYP_EXT)
  ) i_cva6_tlb (
      .clk_i                 (clk_i),
      .rst_ni                (rst_ni),

      .flush_i               (flush_i),
      .flush_vvma_i          (flush_vvma_i),
      .flush_gvma_i          (flush_gvma_i),

      .s_st_enbl_i           (s_st_enbl_i),
      .g_st_enbl_i           (g_st_enbl_i),
      .v_i                   (v_i),

      .update_i              (update_i),

      .lu_access_i           (lu_access_i),
      .lu_asid_i             (lu_asid_i),
      .lu_vmid_i             (lu_vmid_i),
      .lu_vaddr_i            (lu_vaddr_i),

      .lu_gpaddr_o           (lu_gpaddr_o),
      .lu_content_o          (lu_content_o),
      .lu_g_content_o        (lu_g_content_o),

      .asid_to_be_flushed_i  (asid_to_be_flushed_i),
      .vmid_to_be_flushed_i  (vmid_to_be_flushed_i),
      .vaddr_to_be_flushed_i (vaddr_to_be_flushed_i),
      .gpaddr_to_be_flushed_i(gpaddr_to_be_flushed_i),

      .lu_is_page_o          (lu_is_page_o),
      .lu_hit_o              (lu_hit_o)
  );

endmodule