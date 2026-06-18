// cva6_tlb_scoreboard_bind.sv
// -----------------------------------------------------------------------------
// Direct-bind abstract scoreboard for standalone CVA6 TLB formal verification.
//
// What is tracked:
//   - VPN  : Virtual Page Number
//   - ASID : Address Space Identifier
//   - VMID : Virtual Machine Identifier, used when the RISC-V hypervisor
//            extension is enabled
//   - stage context: {v_i, g_st_enbl_i, s_st_enbl_i}
//   - PTE content inserted into the TLB
//   - optional G-stage PTE content
//   - NAPOT/global/page metadata for abstraction and matching
//
//lifetime is the tracked translation without modeling the complete TLB state.
//
// Current intended use:
//   This scoreboard is meant as a scalable formal scoreboarding approach for
//   TLB verification. It should remain abstract and focused on the key
//   observable correctness question:
//
//       "When the DUT hits for the tracked translation, does it return the
//        translation content that was inserted for that tracked entry?"
//
// -----------------------------------------------------------------------------


module cva6_tlb_scoreboard_bind
  import ariane_pkg::*;
  import cva6_tlb_formal_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input logic flush_i,
    input logic flush_vvma_i,
    input logic flush_gvma_i,

    input logic s_st_enbl_i,
    input logic g_st_enbl_i,
    input logic v_i,

    input tlb_update_cva6_t update_i,

    input logic lu_access_i,
    input logic [CVA6Cfg.ASID_WIDTH-1:0] lu_asid_i,
    input logic [CVA6Cfg.VMID_WIDTH-1:0] lu_vmid_i,
    input logic [CVA6Cfg.VLEN-1:0] lu_vaddr_i,
    input logic [CVA6Cfg.GPLEN-1:0] lu_gpaddr_o,

    input pte_cva6_t lu_content_o,
    input pte_cva6_t lu_g_content_o,
    input logic [CVA6Cfg.PtLevels-2:0] lu_is_page_o,
    input logic lu_hit_o,

    input logic [CVA6Cfg.ASID_WIDTH-1:0] asid_to_be_flushed_i,
    input logic [CVA6Cfg.VMID_WIDTH-1:0] vmid_to_be_flushed_i,
    input logic [CVA6Cfg.VLEN-1:0] vaddr_to_be_flushed_i,
    input logic [CVA6Cfg.GPLEN-1:0] gpaddr_to_be_flushed_i
);

  localparam int unsigned VPN_LEN = CVA6Cfg.VpnLen;

  // ---------------------------------------------------------------------------
  // Tracked abstract identity.
  // ---------------------------------------------------------------------------
  logic track_chosen_q;
  logic [VPN_LEN-1:0] tracked_vpn_q;
  logic [CVA6Cfg.ASID_WIDTH-1:0] tracked_asid_q;
  logic [CVA6Cfg.VMID_WIDTH-1:0] tracked_vmid_q;

  // ---------------------------------------------------------------------------
  // Abstract scoreboard state for the tracked entry.
  // ---------------------------------------------------------------------------
  logic sb_valid_q;
  logic sb_is_napot_64k_q;
  logic [HYP_EXT*2:0] sb_v_st_enbl_q;
  pte_cva6_t sb_content_q;

  function automatic logic pte_content_matches_abstract(
    input pte_cva6_t dut_pte,
    input pte_cva6_t sb_pte,
    input logic      is_napot_64k
    );
    pte_cva6_t dut_masked;
    pte_cva6_t sb_masked;

    begin
      dut_masked = dut_pte;
      sb_masked  = sb_pte;

      // For 64 KiB NAPOT entries, the RTL may patch ppn[3:0]
      // according to the lookup virtual address.
      // This is a known RTL implementation detail that does not affect the abstract
      // identity of the tracked entry, because the scoreboard is meant to track the
      // Therefore, we ignore these low dynamic PPN bits.
      if (CVA6Cfg.SvnapotEn && is_napot_64k) begin
        dut_masked.ppn[3:0] = '0;
        sb_masked.ppn[3:0]  = '0;
      end

      pte_content_matches_abstract = (dut_masked == sb_masked);
    end
  endfunction

  function automatic logic [VPN_LEN-1:0] vpn_from_vaddr(
      input logic [CVA6Cfg.VLEN-1:0] vaddr
  );
    vpn_from_vaddr = vaddr[VPN_LEN+11:12];
  endfunction

  wire [HYP_EXT*2:0] current_v_st_enbl;
  assign current_v_st_enbl =
    (CVA6Cfg.RVH) ? {v_i, g_st_enbl_i, s_st_enbl_i} : '1;

  wire asid_flush_is_zero  = ~(|asid_to_be_flushed_i);
  wire vaddr_flush_is_zero = ~(|vaddr_to_be_flushed_i);

  // Accepted update according to the RTL priority.
  wire effective_tlb_update;
  assign effective_tlb_update =
      update_i.valid
      && !flush_i
      && !flush_vvma_i
      && !flush_gvma_i
      && !lu_hit_o;

  // The first accepted update becomes the abstract entry we track.
  wire tracked_update;
  assign tracked_update =
      effective_tlb_update && !track_chosen_q;

  //If S-stage is enabled, ASID must match unless the PTE is global.
  //If S-stage is disabled, ASID does not matter.
  wire lookup_asid_matches_tracked;
  assign lookup_asid_matches_tracked =
    ((lu_asid_i == tracked_asid_q || sb_content_q.g) && s_st_enbl_i)
    || !s_st_enbl_i;

  //If G-stage is enabled, VMID must match.
  //If G-stage is disabled, VMID does not matter.
  wire lookup_vmid_matches_tracked;
  assign lookup_vmid_matches_tracked =
    (!CVA6Cfg.RVH)
    || ((lu_vmid_i == tracked_vmid_q && g_st_enbl_i) || !g_st_enbl_i);

  wire lookup_stage_matches_tracked;
  assign lookup_stage_matches_tracked =
    (sb_v_st_enbl_q == current_v_st_enbl);

  wire lookup_matches_tracked;
  assign lookup_matches_tracked =
    track_chosen_q
    && lu_access_i
    && (vpn_from_vaddr(lu_vaddr_i) == tracked_vpn_q)
    && lookup_asid_matches_tracked
    && lookup_vmid_matches_tracked
    && lookup_stage_matches_tracked;

  // ---------------------------------------------------------------------------
  // Flush matching for the single tracked scoreboard entry.
  //
  // The RTL has three different flush inputs:
  //   1. flush_i      : SFENCE.VMA  - supervisor virtual-memory flush.
  //   2. flush_vvma_i : HFENCE.VVMA - hypervisor flush of VS-stage translations.
  //   3. flush_gvma_i : HFENCE.GVMA - hypervisor flush of G-stage translations.
  //
  //To decide whether its abstract tracked entry is no longer trustworthy
  //and must be invalidated.
  // ---------------------------------------------------------------------------

  // True when the flush virtual address selects the tracked Virtual Page Number
  // (VPN). This is used by SFENCE.VMA and HFENCE.VVMA address-specific cases.
  // Current scope is normal 4 KiB pages, so comparing the full VPN is enough.
  wire tracked_flush_vpn_matches;
  assign tracked_flush_vpn_matches =
      (vpn_from_vaddr(vaddr_to_be_flushed_i) == tracked_vpn_q);

  // Stage bits stored with the tracked entry:
  //   sb_v_st_enbl_q[0]         = S-stage enabled for this entry.
  //   sb_v_st_enbl_q[HYP_EXT]   = G-stage enabled for this entry.
  //   sb_v_st_enbl_q[HYP_EXT*2] = virtualized/VS mode active for this entry.
  // With HYP_EXT=1, this is {v_i, g_st_enbl_i, s_st_enbl_i}.

  // True when the tracked entry belongs to virtualized/VS mode.
  wire tracked_is_virtualized;
  assign tracked_is_virtualized =
      CVA6Cfg.RVH && sb_v_st_enbl_q[HYP_EXT*2];

  // True when the tracked entry uses the S-stage/VS-stage address translation.
  wire tracked_uses_s_stage;
  assign tracked_uses_s_stage = sb_v_st_enbl_q[0];

  // True when the tracked entry uses G-stage translation.
  wire tracked_uses_g_stage;
  assign tracked_uses_g_stage =
      CVA6Cfg.RVH && sb_v_st_enbl_q[HYP_EXT];
  
  // Split the final flush decision into the three architectural flush signals.
  wire sfence_vma_flush_matches_tracked;
  wire hfence_vvma_flush_matches_tracked;
  wire hfence_gvma_flush_matches_tracked;

  // ---------------------------------------------------------------------------
  // 1) SFENCE.VMA flush cases
  // ---------------------------------------------------------------------------
  // SFENCE.VMA is the normal supervisor virtual-memory TLB flush.
  // It targets non-virtualized S-stage entries.
  // In hypervisor mode, virtualized
  // VS-stage entries are handled by HFENCE.VVMA, not by SFENCE.VMA.
  //
  // Operand interpretation:
  //   vaddr_to_be_flushed_i == 0 means rs1 = x0, so no VPN filter.
  //   asid_to_be_flushed_i  == 0 means rs2 = x0, so no ASID filter.
  //
  // Four cases:
  //   SFENCE.VMA x0,    x0    -> flush all non-virtualized tracked entries.
  //   SFENCE.VMA vaddr, x0    -> flush tracked VPN for all ASIDs, including global.
  //   SFENCE.VMA x0,    asid  -> flush non-global tracked entry for this ASID.
  //   SFENCE.VMA vaddr, asid  -> flush non-global tracked VPN for this ASID.
  // ---------------------------------------------------------------------------
  wire sfence_vma_candidate;
  assign sfence_vma_candidate =
      sb_valid_q &&
      flush_i &&
      (!CVA6Cfg.RVH || !tracked_is_virtualized);

  assign sfence_vma_flush_matches_tracked =
      sfence_vma_candidate &&
      (
        // SFENCE.VMA x0, x0: flush all non-virtualized entries.
        (asid_flush_is_zero && vaddr_flush_is_zero)
        ||
        // SFENCE.VMA vaddr, x0: flush this VPN for all ASIDs.
        // Global entries are also flushed because ASID is x0/no ASID filter.
        (asid_flush_is_zero && !vaddr_flush_is_zero && tracked_flush_vpn_matches)
        ||
        // SFENCE.VMA x0, asid: flush only non-global entries of this ASID.
        (!asid_flush_is_zero && vaddr_flush_is_zero &&
         !sb_content_q.g &&
         (asid_to_be_flushed_i == tracked_asid_q))
        ||
        // SFENCE.VMA vaddr, asid: flush only non-global entry matching VPN+ASID.
        (!asid_flush_is_zero && !vaddr_flush_is_zero &&
         !sb_content_q.g &&
         tracked_flush_vpn_matches &&
         (asid_to_be_flushed_i == tracked_asid_q))
      );

  // ---------------------------------------------------------------------------
  // 2) HFENCE.VVMA flush cases
  // ---------------------------------------------------------------------------
  // HFENCE.VVMA is the hypervisor flush for VS-stage virtual-address
  // translations. It targets entries that were inserted in virtualized mode and
  // use the S/VS-stage. It uses the current VMID context, represented here by
  // lu_vmid_i
  // ---------------------------------------------------------------------------
  wire hfence_vvma_candidate;
  assign hfence_vvma_candidate =
      sb_valid_q &&
      flush_vvma_i &&
      CVA6Cfg.RVH &&
      tracked_is_virtualized &&
      tracked_uses_s_stage;

  // For HFENCE.VVMA, VMID must match when the tracked entry also uses G-stage.
  // If the tracked entry does not use G-stage, VMID is irrelevant.
  wire hfence_vvma_vmid_matches;
  assign hfence_vvma_vmid_matches =
      (!tracked_uses_g_stage) ||
      (lu_vmid_i == tracked_vmid_q);

  assign hfence_vvma_flush_matches_tracked =
      hfence_vvma_candidate &&
      hfence_vvma_vmid_matches &&
      (
        // HFENCE.VVMA x0, x0: flush all VS-stage entries in this VMID context.
        (asid_flush_is_zero && vaddr_flush_is_zero)
        ||
        // HFENCE.VVMA vaddr, x0: flush this VS-stage VPN for all ASIDs.
        (asid_flush_is_zero && !vaddr_flush_is_zero && tracked_flush_vpn_matches)
        ||
        // HFENCE.VVMA x0, asid: flush only non-global VS-stage entries of ASID.
        (!asid_flush_is_zero && vaddr_flush_is_zero &&
         !sb_content_q.g &&
         (asid_to_be_flushed_i == tracked_asid_q))
        ||
        // HFENCE.VVMA vaddr, asid: flush only non-global VS-stage VPN+ASID.
        (!asid_flush_is_zero && !vaddr_flush_is_zero &&
         !sb_content_q.g &&
         tracked_flush_vpn_matches &&
         (asid_to_be_flushed_i == tracked_asid_q))
      );

  // ---------------------------------------------------------------------------
  // 3) HFENCE.GVMA flush cases
  // ---------------------------------------------------------------------------
  // HFENCE.GVMA is the hypervisor flush for G-stage translations. Its address
  // operand is a guest physical address, not the normal virtual address.
  //
  // Current conservative scope:
  //   - Implement only all-address cases:
  //       HFENCE.GVMA x0, x0
  //       HFENCE.GVMA x0, vmid
  //   - Do not yet implement gpaddr-specific cases, because the scoreboard must
  //     first track/derive the guest physical page for the tracked entry.
  // ---------------------------------------------------------------------------
  wire vmid_flush_is_zero;
  wire gpaddr_flush_is_zero;
  assign vmid_flush_is_zero   = ~(|vmid_to_be_flushed_i);
  assign gpaddr_flush_is_zero = ~(|gpaddr_to_be_flushed_i);

  wire hfence_gvma_candidate;
  assign hfence_gvma_candidate =
      sb_valid_q &&
      flush_gvma_i &&
      CVA6Cfg.RVH &&
      tracked_uses_g_stage;

  assign hfence_gvma_flush_matches_tracked =
      hfence_gvma_candidate &&
      (
        // HFENCE.GVMA x0, x0: flush all G-stage entries for all VMIDs.
        (vmid_flush_is_zero && gpaddr_flush_is_zero)
        ||
        // HFENCE.GVMA x0, vmid: flush all G-stage entries for this VMID.
        (!vmid_flush_is_zero && gpaddr_flush_is_zero &&
         (vmid_to_be_flushed_i == tracked_vmid_q))
      );

  // Final scoreboard flush decision. If any architectural flush targets the
  // tracked entry, the scoreboard invalidates sb_valid_q in the next clocked FSM.
  wire flush_matches_tracked;
  assign flush_matches_tracked =
      sfence_vma_flush_matches_tracked ||
      hfence_vvma_flush_matches_tracked ||
      hfence_gvma_flush_matches_tracked;

  // ---------------------------------------------------------------------------
  // Scoreboard FSM
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    //1. Capture the first accepted TLB update.
    //2. Store its VPN, ASID, and PTE content.
    //3. If the tracked entry is flushed, invalidate the scoreboard.
    //4. If any later update happens, invalidate the scoreboard because replacement/shadowing is unknown.
    //5. Only check data while sb_valid_q is still 1.
    if (!rst_ni) begin
      track_chosen_q     <= 1'b0;
      tracked_vpn_q      <= '0;
      tracked_asid_q     <= '0;
      sb_valid_q         <= 1'b0;
      sb_is_napot_64k_q  <= 1'b0;
      sb_v_st_enbl_q     <= '0;
      sb_content_q       <= '0;
      sb_g_content_q     <= '0;
      tracked_vmid_q     <= '0;
    end else begin
      //FLUSH
      if (flush_matches_tracked) begin
        sb_valid_q <= 1'b0;
      //TRACKED UPDATE
      end else if (tracked_update) begin
        track_chosen_q     <= 1'b1;
        tracked_vpn_q      <= update_i.vpn[VPN_LEN-1:0];
        tracked_asid_q     <= update_i.asid;
        tracked_vmid_q     <= update_i.vmid;

        sb_valid_q         <= 1'b1;
        sb_is_napot_64k_q  <= update_i.is_napot_64k;
        sb_v_st_enbl_q     <= update_i.v_st_enbl;
        sb_content_q       <= update_i.content;
        sb_g_content_q     <= update_i.g_content;
      // INVALIDATE FOR NEXT UPDATE
      end else if (sb_valid_q && effective_tlb_update) begin
        sb_valid_q <= 1'b0;
      end
    end
  end


  default clocking cb @(posedge clk_i); endclocking
  default disable iff (!rst_ni);

  // ---------------------------------------------------------------------------
  // Assumptions.
  // ---------------------------------------------------------------------------
  a_at_most_one_flush_kind: assume property (
  $onehot0({flush_i, flush_vvma_i, flush_gvma_i})
  );

  a_no_update_during_any_flush: assume property (
    (flush_i || flush_vvma_i || flush_gvma_i) |-> !update_i.valid
  );

  //The TLB update belongs to the same translation mode that is currently being used.
  a_update_stage_matches_current_context: assume property (
    effective_tlb_update |->
      (update_i.v_st_enbl == current_v_st_enbl)
  );


  // ---------------------------------------------------------------------------
  // Assertions.
  // ---------------------------------------------------------------------------
  p_tracked_data_integrity_on_hit: assert property (
    sb_valid_q &&
    lookup_matches_tracked &&
    lu_hit_o
    |->
    pte_content_matches_abstract(
      lu_content_o,
      sb_content_q,
      sb_is_napot_64k_q
    )
  );

  p_matching_flush_invalidates_scoreboard: assert property (
    flush_matches_tracked
    |->
    ##1 !sb_valid_q
  );

    //remove dependency from flush matches trackes, make it only if sb_valid_q is zero
  p_any_flush_to_tracked_must_miss_after: assert property (
    flush_matches_tracked
    |=>
    (
      (lu_access_i && lookup_matches_tracked && !update_i.valid)
      |->
      !lu_hit_o
    )
  );

  // ---------------------------------------------------------------------------
  // Cover / witness checks.
  // ---------------------------------------------------------------------------

  // Did the environment ever generate an accepted update for the symbolic entry?
  c_effective_update_seen: cover property (
    ##[1:10] effective_tlb_update
  );

  c_scoreboard_valid_seen: cover property (
    ##[1:10] sb_valid_q
  );

  c_tracked_napot_hit_seen: cover property (
    tracked_update &&
    update_i.is_napot_64k
    ##[1:10]
    sb_valid_q &&
    lookup_matches_tracked &&
    lu_hit_o
  );

  c_tracked_update_seen: cover property (
    ##[1:10] tracked_update
  );

c_tracked_update_then_hit: cover property (
    tracked_update
    ##[1:10]
    sb_valid_q &&
    lookup_matches_tracked &&
    lu_hit_o &&
    pte_content_matches_abstract(
      lu_content_o,
      sb_content_q,
      sb_is_napot_64k_q
    )
  );

  c_sfence_vma_flush_seen: cover property (
  ##[1:10]
  sb_valid_q &&
  sfence_vma_flush_matches_tracked
  );

  c_hfence_vvma_flush_seen: cover property (
    ##[1:10]
    sb_valid_q &&
    hfence_vvma_flush_matches_tracked
  );

  c_hfence_gvma_flush_seen: cover property (
    ##[1:10]
    sb_valid_q &&
    hfence_gvma_flush_matches_tracked
  );

  c_rvh_enabled: cover property (
    CVA6Cfg.RVH
    );

    c_hyp_stage_context_seen: cover property (
    CVA6Cfg.RVH &&
    v_i &&
    g_st_enbl_i &&
    s_st_enbl_i
  );

  c_tracked_virtualized_update_seen: cover property (
    tracked_update &&
    update_i.v_st_enbl[HYP_EXT*2] &&
    update_i.v_st_enbl[0]
  );

  c_tracked_g_stage_update_seen: cover property (
    tracked_update &&
    update_i.v_st_enbl[HYP_EXT]
  );

  c_tracked_napot_update_seen: cover property (
    ##[1:10]
    tracked_update &&
    update_i.is_napot_64k
  );

  c_tracked_large_page_update_seen: cover property (
    ##[1:10]
    tracked_update &&
    (|update_i.is_page)
  );

endmodule

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
