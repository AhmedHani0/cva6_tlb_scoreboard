// cva6_tlb_scoreboard_bind.sv
// -----------------------------------------------------------------------------
// Direct-bind symbolic-entry scoreboard for standalone CVA6 TLB verification.
//
//   - One symbolic tracked TLB translation.
//   - No full TLB table modeling.
//   - Data integrity is checked only when the DUT reports a hit.
//   - If the DUT misses for the symbolic address, the checker does not require
//     a hit, because the symbolic translation may never have been inserted,
//     may have been replaced, or may have been flushed.
//   - Cover property is used to witness: symbolic update -> later symbolic hit.
//   - Current scope: non-hypervisor, normal 4 KiB pages, no NAPOT/Svnapot.
//
// Abbreviations:
//   TLB   = Translation Lookaside Buffer.
//   VPN   = Virtual Page Number.
//   ASID  = Address Space Identifier.
//   VMID  = Virtual Machine Identifier.
//   PTE   = Page Table Entry.
//   NAPOT = Naturally Aligned Power Of Two.
//   PLRU  = Pseudo Least Recently Used.
// -----------------------------------------------------------------------------

module cva6_tlb_scoreboard_bind
  import ariane_pkg::*;
  import cva6_tlb_formal_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    // Flush inputs.
    input logic flush_i,
    input logic flush_vvma_i,
    input logic flush_gvma_i,

    // Translation-stage inputs.
    input logic s_st_enbl_i,
    input logic g_st_enbl_i,
    input logic v_i,

    // Full TLB update/refill packet.
    input tlb_update_cva6_t update_i,

    // Lookup interface.
    input logic lu_access_i,
    input logic [CVA6Cfg.ASID_WIDTH-1:0] lu_asid_i,
    input logic [CVA6Cfg.VMID_WIDTH-1:0] lu_vmid_i,
    input logic [CVA6Cfg.VLEN-1:0] lu_vaddr_i,
    input logic [CVA6Cfg.GPLEN-1:0] lu_gpaddr_o,

    // Lookup result.
    input pte_cva6_t lu_content_o,
    input pte_cva6_t lu_g_content_o,
    input logic [CVA6Cfg.PtLevels-2:0] lu_is_page_o,
    input logic lu_hit_o,

    // Flush filters.
    input logic [CVA6Cfg.ASID_WIDTH-1:0] asid_to_be_flushed_i,
    input logic [CVA6Cfg.VMID_WIDTH-1:0] vmid_to_be_flushed_i,
    input logic [CVA6Cfg.VLEN-1:0] vaddr_to_be_flushed_i,
    input logic [CVA6Cfg.GPLEN-1:0] gpaddr_to_be_flushed_i
);

  // ---------------------------------------------------------------------------
  // Local constants.
  // ---------------------------------------------------------------------------
  localparam int unsigned VPN_LEN = CVA6Cfg.VpnLen;

  // ---------------------------------------------------------------------------
  // Symbolic identity of the one abstract entry we track.
  //
  // These are free formal variables. The stability assumptions below make
  // OneSpin choose one arbitrary VPN/ASID/VMID and keep it fixed throughout
  // the proof. This is the symbolic address/context we care about.
  // ---------------------------------------------------------------------------
  logic [VPN_LEN-1:0] symbolic_vpn;
  logic [CVA6Cfg.ASID_WIDTH-1:0] symbolic_asid;
  logic [CVA6Cfg.VMID_WIDTH-1:0] symbolic_vmid;

  // ---------------------------------------------------------------------------
  // Abstract scoreboard state for the symbolic entry.
  //
  // sb_valid_q:
  //   The checker has observed an accepted update for the symbolic identity.
  //
  // sb_content_q:
  //   The S-stage PTE that was last updated for the symbolic identity.
  //
  // sb_g_content_q:
  //   The G-stage PTE stored for future hypervisor extension support.
  //   In the current non-hypervisor scope, it is stored but not asserted.
  //
  // sb_is_page_q:
  //   Page-size information returned by the TLB on lookup.
  //
  // sb_is_napot_64k_q:
  //   Stored for future NAPOT extension support.
  //
  // sb_v_st_enbl_q:
  //   Stored translation-stage-enable information.
  // ---------------------------------------------------------------------------
  logic sb_valid_q;
  logic [CVA6Cfg.PtLevels-2:0] sb_is_page_q;
  logic sb_is_napot_64k_q;
  logic [HYP_EXT:0] sb_v_st_enbl_q;
  pte_cva6_t sb_content_q;
  pte_cva6_t sb_g_content_q;

  // ---------------------------------------------------------------------------
  // Helper function: extract VPN from a virtual address.
  //
  // For normal 4 KiB pages, the lower 12 bits are the page offset and are not
  // part of the VPN.
  // ---------------------------------------------------------------------------
  function automatic logic [VPN_LEN-1:0] vpn_from_vaddr(
      input logic [CVA6Cfg.VLEN-1:0] vaddr
  );
    vpn_from_vaddr = vaddr[VPN_LEN+11:12];
  endfunction

  // ---------------------------------------------------------------------------
  // Basic helper wires.
  // ---------------------------------------------------------------------------
  wire asid_flush_is_zero  = ~(|asid_to_be_flushed_i);
  wire vaddr_flush_is_zero = ~(|vaddr_to_be_flushed_i);

  wire flush_all =
      flush_i &&
      asid_flush_is_zero &&
      vaddr_flush_is_zero;

  // effective_tlb_update:
  //   An update request that the TLB can actually accept.
  //
  // RTL priority:
  //   If flush and update are high in the same cycle, flush wins and the update
  //   is ignored by the TLB.
  wire effective_tlb_update;

  assign effective_tlb_update =
      update_i.valid
      && !flush_i
      && !flush_vvma_i
      && !flush_gvma_i
      && !lu_hit_o;

  // supported_update:
  //   Current restricted proof scope: normal 4 KiB, non-NAPOT, non-hypervisor.
  //
  // This assumption keeps the current symbolic checker focused. Page-size,
  // NAPOT, and hypervisor extensions can be added later by extending the
  // symbolic matching functions.
  wire supported_update;

  assign supported_update =
      effective_tlb_update
      && (update_i.is_page == '0)
      && (update_i.v_st_enbl == '1)
      && (!CVA6Cfg.SvnapotEn || !update_i.is_napot_64k)
      && (HYP_EXT == 0)
      && (!CVA6Cfg.RVH);

  // update_matches_symbolic:
  //   The accepted TLB update/refill is for the symbolic identity.
  //
  // Only in this case do we update the scoreboard. Updates for all other
  // addresses/ASIDs/VMIDs are ignored by the abstract checker.
  wire update_matches_symbolic;

  assign update_matches_symbolic =
      effective_tlb_update
      && (update_i.vpn[VPN_LEN-1:0] == symbolic_vpn)
      && (update_i.asid == symbolic_asid)
      && (update_i.vmid == symbolic_vmid);

  // lookup_matches_symbolic:
  //   The current lookup request is for the symbolic identity.
  //
  // In this 4 KiB scope, full VPN equality is used.
  // ASID match follows the normal rule:
  //   - non-global PTE: ASID must match
  //   - global PTE: ASID may differ
  wire lookup_matches_symbolic;

  assign lookup_matches_symbolic =
      lu_access_i
      && (vpn_from_vaddr(lu_vaddr_i) == symbolic_vpn)
      && ((lu_asid_i == symbolic_asid) || sb_content_q.g);

  // Flush matching for the symbolic entry.
  wire symbolic_flush_vpn_matches;

  assign symbolic_flush_vpn_matches =
      (vpn_from_vaddr(vaddr_to_be_flushed_i) == symbolic_vpn);

  // flush_matches_symbolic:
  //   A normal SFENCE.VMA flush invalidates the symbolic scoreboard entry.
  //
  // Normal flush cases:
  //   SFENCE.VMA x0, x0:
  //     flush all entries.
  //
  //  SFENCE.VMA vaddr, x0:
  //     flush matching virtual address for all ASIDs, including global entries.
  //
  //  SFENCE.VMA x0, asid:
  //     flush non-global entries matching this ASID.
  //
  //  SFENCE.VMA vaddr, asid:
  //     flush non-global entries matching this VPN and ASID.
  wire flush_matches_symbolic;

  assign flush_matches_symbolic =
      sb_valid_q
      && flush_i
      && (
          // SFENCE.VMA x0, x0
          (asid_flush_is_zero && vaddr_flush_is_zero)
          ||
          // SFENCE.VMA vaddr, x0
          (asid_flush_is_zero && !vaddr_flush_is_zero &&
           symbolic_flush_vpn_matches)
          ||
          // SFENCE.VMA x0, asid; non-global only
          (!asid_flush_is_zero && vaddr_flush_is_zero &&
           !sb_content_q.g &&
           (asid_to_be_flushed_i == symbolic_asid))
          ||
          // SFENCE.VMA vaddr, asid; non-global only
          (!asid_flush_is_zero && !vaddr_flush_is_zero &&
           !sb_content_q.g &&
           symbolic_flush_vpn_matches &&
           (asid_to_be_flushed_i == symbolic_asid))
      );

  // ---------------------------------------------------------------------------
  // Symbolic scoreboard state update.
  //
  // Priority:
  //   reset -> matching flush -> accepted matching update
  //
  // If a flush and update happen together
  // flush wins in the RTL. Therefore the scoreboard also ignores that update.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sb_valid_q        <= 1'b0;
      sb_is_page_q      <= '0;
      sb_is_napot_64k_q <= 1'b0;
      sb_v_st_enbl_q    <= '0;
      sb_content_q      <= '0;
      sb_g_content_q    <= '0;
    end else begin
      if (flush_matches_symbolic) begin
        sb_valid_q <= 1'b0;
      end else if (update_matches_symbolic) begin
        sb_valid_q        <= 1'b1;
        sb_is_page_q      <= update_i.is_page;
        sb_is_napot_64k_q <= update_i.is_napot_64k;
        sb_v_st_enbl_q    <= update_i.v_st_enbl;
        sb_content_q      <= update_i.content;
        sb_g_content_q    <= update_i.g_content;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Default clock/reset for SVA.
  // ---------------------------------------------------------------------------
  default clocking cb @(posedge clk_i); endclocking
  default disable iff (!rst_ni);

  // ---------------------------------------------------------------------------
  // Assumptions.
  // ---------------------------------------------------------------------------

  // The symbolic identity is arbitrary but stable.
  // OneSpin may choose any VPN/ASID/VMID, but once chosen it must not change.
  a_symbolic_vpn_stable: assume property (
    $stable(symbolic_vpn)
  );

  a_symbolic_asid_stable: assume property (
    $stable(symbolic_asid)
  );

  a_symbolic_vmid_stable: assume property (
    $stable(symbolic_vmid)
  );

  // Current proof scope:
  // every accepted update is a normal 4 KiB, non-NAPOT, non-hypervisor update.
  a_only_supported_updates: assume property (
    effective_tlb_update |-> supported_update
  );

  // Current scope:
  // global mappings are postponed to a later step.
  a_no_global_updates_yet: assume property (
    effective_tlb_update |-> !update_i.content.g
  );

  // Environment contract:
  // during a flush, the surrounding MMU/PTW/shared-TLB environment does not
  // also present a refill.
  a_no_update_during_flush: assume property (
    flush_i |-> !update_i.valid
  );

  // ---------------------------------------------------------------------------
  // Assertions.
  // ---------------------------------------------------------------------------

  // Data-integrity property:
  //
  // If the scoreboard has observed an accepted update for the symbolic identity,
  // and the current lookup is for that symbolic identity, and the DUT says hit,
  // then the returned PTE and page-size information must match the scoreboard.
  //
  // Important:
  // This property does NOT require a hit. If the DUT misses, we do not fail,
  // because the symbolic translation may have been replaced or may not be present
  // in the TLB. This avoids modeling PLRU replacement.
  p_symbolic_data_integrity_on_hit: assert property (
    sb_valid_q &&
    lookup_matches_symbolic &&
    lu_hit_o
    |->
    (lu_content_o == sb_content_q) &&
    (lu_is_page_o == sb_is_page_q)
  );

  // Full-flush sanity property:
  //
  // After SFENCE.VMA x0, x0, the next-cycle lookup should not hit unless a new
  // effective update is accepted in that next cycle.
  //
  // This is a visible black-box sanity property, not a PLRU/full-table check.
  p_full_flush_clears_visible_hit: assert property (
    flush_all
    ##1
    (lu_access_i && !effective_tlb_update)
    |->
    !lu_hit_o
  );

  // ---------------------------------------------------------------------------
  // Cover / witness.
  // ---------------------------------------------------------------------------

  // Witness property:
  //
  // Ask OneSpin to find one trace where:
  //   1. the TLB accepts an update for the symbolic identity,
  //   2. later there is a lookup for the symbolic identity,
  //   3. the DUT hits,
  //   4. the returned content matches the scoreboard.
  //
  // This demonstrates that the tracked-entry hit scenario is reachable. It is
  // not an assertion that a hit must always happen.
  c_symbolic_update_then_hit: cover property (
    update_matches_symbolic
    ##[1:5]
    sb_valid_q &&
    lookup_matches_symbolic &&
    lu_hit_o &&
    (lu_content_o == sb_content_q)
  );

endmodule

// -----------------------------------------------------------------------------
// Direct bind into cva6_tlb.
// -----------------------------------------------------------------------------

bind cva6_tlb cva6_tlb_scoreboard_bind i_cva6_tlb_scoreboard_bind (
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
