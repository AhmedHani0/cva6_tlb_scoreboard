// cva6_tlb_scoreboard_bind.sv
// -----------------------------------------------------------------------------
// Direct-bind abstract scoreboard for standalone CVA6 TLB formal verification.
//
// Verification idea:
//   This scoreboard intentionally does not model the full TLB table, PLRU
//   replacement, all physical entries, or page-size/NAPOT/G-stage hit priority.
//
//   Instead, it models one abstract refill episode:
//
//      MISS state:
//        The scoreboard has observed or is waiting for a TLB miss.
//        A TLB update is allowed only in this state and must match the missed
//        lookup identity.
//
//      TRACKING state:
//        The scoreboard tracks the update that refilled the missed translation.
//        If the DUT later reports a hit for this tracked identity, the returned
//        PTE content must match the tracked PTE content.
//
//   The scoreboard returns to MISS state on:
//      1. reset,
//      2. a flush that targets the tracked entry,
//      3. any lookup miss.
//
// Why this abstraction:
//   A standalone TLB has unconstrained update_i inputs. Without an environment
//   rule, formal can inject arbitrary updates that create duplicate or
//   overlapping entries. This scoreboard avoids building a second TLB model by
//   requiring updates to follow an observed miss.
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

  typedef enum logic {
    SB_MISS,
    SB_TRACKING
  } sb_state_e;

  sb_state_e sb_state_q;

  wire sb_in_miss_state;
  wire sb_in_tracking_state;

  assign sb_in_miss_state     = (sb_state_q == SB_MISS);
  assign sb_in_tracking_state = (sb_state_q == SB_TRACKING);

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
  logic [CVA6Cfg.PtLevels-2:0][HYP_EXT:0] sb_is_page_q;
  pte_cva6_t sb_content_q;
  pte_cva6_t sb_g_content_q;

  // ---------------------------------------------------------------------------
  // Miss identity remembered by the scoreboard.
  // ---------------------------------------------------------------------------
  logic miss_valid_q;
  logic [VPN_LEN-1:0] miss_vpn_q;
  logic [CVA6Cfg.ASID_WIDTH-1:0] miss_asid_q;
  logic [CVA6Cfg.VMID_WIDTH-1:0] miss_vmid_q;
  logic [HYP_EXT*2:0] miss_stage_q;

  // ---------------------------------------------------------------------------
  // Helpers.
  // ---------------------------------------------------------------------------
  function automatic logic [VPN_LEN-1:0] vpn_from_vaddr(
      input logic [CVA6Cfg.VLEN-1:0] vaddr
  );
    vpn_from_vaddr = vaddr[VPN_LEN+11:12];
  endfunction

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

      // For 64 KiB NAPOT entries, the RTL may patch ppn[3:0] according
      // to the lookup virtual address. The scoreboard remains abstract by
      // masking these dynamic low PPN bits instead of duplicating the RTL
      // patching logic.
      if (CVA6Cfg.SvnapotEn && is_napot_64k) begin
        dut_masked.ppn[3:0] = '0;
        sb_masked.ppn[3:0]  = '0;
      end

      pte_content_matches_abstract =
          (dut_masked.ppn == sb_masked.ppn) &&
          (dut_masked.rsw == sb_masked.rsw) &&
          (dut_masked.n   == sb_masked.n)   &&
          (dut_masked.d   == sb_masked.d)   &&
          (dut_masked.a   == sb_masked.a)   &&
          (dut_masked.g   == sb_masked.g)   &&
          (dut_masked.u   == sb_masked.u)   &&
          (dut_masked.x   == sb_masked.x)   &&
          (dut_masked.w   == sb_masked.w)   &&
          (dut_masked.r   == sb_masked.r)   &&
          (dut_masked.v   == sb_masked.v);
    end
  endfunction

  wire [HYP_EXT*2:0] current_v_st_enbl;
  assign current_v_st_enbl =
      (CVA6Cfg.RVH) ? {v_i, g_st_enbl_i, s_st_enbl_i} : '1;

  wire lookup_miss;
  assign lookup_miss =
      lu_access_i &&
      !lu_hit_o;

  // Accepted update according to the RTL priority.
  wire effective_tlb_update;
  assign effective_tlb_update =
      update_i.valid &&
      !flush_i &&
      !flush_vvma_i &&
      !flush_gvma_i &&
      !lu_hit_o;

  // A tracked update is an accepted update while the scoreboard is in MISS.
  wire tracked_update;
  assign tracked_update =
      effective_tlb_update &&
      sb_in_miss_state;

  // ---------------------------------------------------------------------------
  // Update must match the stored miss identity.
  // ---------------------------------------------------------------------------
  wire update_matches_miss_identity;

  assign update_matches_miss_identity =
      miss_valid_q &&
      (update_i.vpn[VPN_LEN-1:0] == miss_vpn_q) &&
      (!miss_stage_q[0] ||
       (update_i.asid == miss_asid_q)) &&
      (!CVA6Cfg.RVH ||
       !miss_stage_q[HYP_EXT] ||
       (update_i.vmid == miss_vmid_q)) &&
      (update_i.v_st_enbl == miss_stage_q);

  // ---------------------------------------------------------------------------
  // Lookup matching for the tracked abstract entry.
  // ---------------------------------------------------------------------------
  wire lookup_asid_matches_tracked;
  assign lookup_asid_matches_tracked =
      (!sb_v_st_enbl_q[0]) ||
      (lu_asid_i == tracked_asid_q);

  wire lookup_vmid_matches_tracked;
  assign lookup_vmid_matches_tracked =
      (!CVA6Cfg.RVH) ||
      (!sb_v_st_enbl_q[HYP_EXT]) ||
      (lu_vmid_i == tracked_vmid_q);

  wire lookup_stage_matches_tracked;
  assign lookup_stage_matches_tracked =
      (sb_v_st_enbl_q == current_v_st_enbl);

  wire lookup_matches_tracked;
  assign lookup_matches_tracked =
      sb_in_tracking_state &&
      track_chosen_q &&
      lu_access_i &&
      (vpn_from_vaddr(lu_vaddr_i) == tracked_vpn_q) &&
      lookup_asid_matches_tracked &&
      lookup_vmid_matches_tracked &&
      lookup_stage_matches_tracked;

  // ---------------------------------------------------------------------------
  // Flush matching for the tracked scoreboard entry.
  // ---------------------------------------------------------------------------
  wire asid_flush_is_zero;
  wire vaddr_flush_is_zero;
  wire vmid_flush_is_zero;
  wire gpaddr_flush_is_zero;

  assign asid_flush_is_zero  = ~(|asid_to_be_flushed_i);
  assign vaddr_flush_is_zero = ~(|vaddr_to_be_flushed_i);
  assign vmid_flush_is_zero  = ~(|vmid_to_be_flushed_i);
  assign gpaddr_flush_is_zero = ~(|gpaddr_to_be_flushed_i);

  wire tracked_flush_vpn_matches;
  assign tracked_flush_vpn_matches =
      (vpn_from_vaddr(vaddr_to_be_flushed_i) == tracked_vpn_q);

  wire tracked_is_virtualized;
  assign tracked_is_virtualized =
      CVA6Cfg.RVH && sb_v_st_enbl_q[HYP_EXT*2];

  wire tracked_uses_s_stage;
  assign tracked_uses_s_stage =
      sb_v_st_enbl_q[0];

  wire tracked_uses_g_stage;
  assign tracked_uses_g_stage =
      CVA6Cfg.RVH && sb_v_st_enbl_q[HYP_EXT];

  wire sfence_vma_flush_matches_tracked;
  wire hfence_vvma_flush_matches_tracked;
  wire hfence_gvma_flush_matches_tracked;

  // SFENCE.VMA: normal supervisor virtual-memory flush.
  wire sfence_vma_candidate;
  assign sfence_vma_candidate =
      sb_in_tracking_state &&
      track_chosen_q &&
      flush_i &&
      (!CVA6Cfg.RVH || !tracked_is_virtualized);

  assign sfence_vma_flush_matches_tracked =
      sfence_vma_candidate &&
      (
        // SFENCE.VMA x0, x0
        (asid_flush_is_zero && vaddr_flush_is_zero)
        ||
        // SFENCE.VMA vaddr, x0
        (asid_flush_is_zero && !vaddr_flush_is_zero && tracked_flush_vpn_matches)
        ||
        // SFENCE.VMA x0, asid
        (!asid_flush_is_zero && vaddr_flush_is_zero &&
         !sb_content_q.g &&
         (asid_to_be_flushed_i == tracked_asid_q))
        ||
        // SFENCE.VMA vaddr, asid
        (!asid_flush_is_zero && !vaddr_flush_is_zero &&
         !sb_content_q.g &&
         tracked_flush_vpn_matches &&
         (asid_to_be_flushed_i == tracked_asid_q))
      );

  // HFENCE.VVMA: hypervisor flush for VS-stage translations.
  wire hfence_vvma_candidate;
  assign hfence_vvma_candidate =
      sb_in_tracking_state &&
      track_chosen_q &&
      flush_vvma_i &&
      CVA6Cfg.RVH &&
      tracked_is_virtualized &&
      tracked_uses_s_stage;

  wire hfence_vvma_vmid_matches;
  assign hfence_vvma_vmid_matches =
      (!tracked_uses_g_stage) ||
      (lu_vmid_i == tracked_vmid_q);

  assign hfence_vvma_flush_matches_tracked =
      hfence_vvma_candidate &&
      hfence_vvma_vmid_matches &&
      (
        // HFENCE.VVMA x0, x0
        (asid_flush_is_zero && vaddr_flush_is_zero)
        ||
        // HFENCE.VVMA vaddr, x0
        (asid_flush_is_zero && !vaddr_flush_is_zero && tracked_flush_vpn_matches)
        ||
        // HFENCE.VVMA x0, asid
        (!asid_flush_is_zero && vaddr_flush_is_zero &&
         !sb_content_q.g &&
         (asid_to_be_flushed_i == tracked_asid_q))
        ||
        // HFENCE.VVMA vaddr, asid
        (!asid_flush_is_zero && !vaddr_flush_is_zero &&
         !sb_content_q.g &&
         tracked_flush_vpn_matches &&
         (asid_to_be_flushed_i == tracked_asid_q))
      );

  // HFENCE.GVMA: hypervisor flush for G-stage translations.
  // Current conservative scope: all-address cases only.
  wire hfence_gvma_candidate;
  assign hfence_gvma_candidate =
      sb_in_tracking_state &&
      track_chosen_q &&
      flush_gvma_i &&
      CVA6Cfg.RVH &&
      tracked_uses_g_stage;

  assign hfence_gvma_flush_matches_tracked =
      hfence_gvma_candidate &&
      (
        // HFENCE.GVMA x0, x0
        (vmid_flush_is_zero && gpaddr_flush_is_zero)
        ||
        // HFENCE.GVMA x0, vmid
        (!vmid_flush_is_zero && gpaddr_flush_is_zero &&
         (vmid_to_be_flushed_i == tracked_vmid_q))
      );

  wire flush_matches_tracked;
  assign flush_matches_tracked =
      sfence_vma_flush_matches_tracked ||
      hfence_vvma_flush_matches_tracked ||
      hfence_gvma_flush_matches_tracked;

  wire any_flush;
  assign any_flush =
      flush_i || flush_vvma_i || flush_gvma_i;

  // ---------------------------------------------------------------------------
  // Scoreboard FSM.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sb_state_q          <= SB_MISS;

      track_chosen_q      <= 1'b0;
      tracked_vpn_q       <= '0;
      tracked_asid_q      <= '0;
      tracked_vmid_q      <= '0;

      sb_valid_q          <= 1'b0;
      sb_is_napot_64k_q   <= 1'b0;
      sb_v_st_enbl_q      <= '0;
      sb_content_q        <= '0;
      sb_is_page_q       <= '0;
      sb_g_content_q     <= '0;

      miss_valid_q        <= 1'b0;
      miss_vpn_q          <= '0;
      miss_asid_q         <= '0;
      miss_vmid_q         <= '0;
      miss_stage_q        <= '0;

    end else begin
      unique case (sb_state_q)

        SB_MISS: begin
          sb_valid_q <= 1'b0;

          // A flush while waiting for a refill cancels the old remembered miss.
          if (any_flush) begin
            miss_valid_q <= 1'b0;

          // The refill/update for the remembered miss starts tracking.
          end else if (effective_tlb_update) begin
            track_chosen_q     <= 1'b1;
            tracked_vpn_q      <= update_i.vpn[VPN_LEN-1:0];
            tracked_asid_q     <= update_i.asid;
            tracked_vmid_q     <= update_i.vmid;

            sb_valid_q         <= 1'b1;
            sb_is_napot_64k_q  <= update_i.is_napot_64k;
            sb_v_st_enbl_q     <= update_i.v_st_enbl;
            sb_content_q       <= update_i.content;
            sb_is_page_q       <= update_i.is_page;
            sb_g_content_q     <= update_i.g_content;

            miss_valid_q       <= 1'b0;
            sb_state_q         <= SB_TRACKING;

          // Remember the most recent miss while waiting for the update.
          end else if (lookup_miss) begin
            miss_valid_q <= 1'b1;
            miss_vpn_q   <= vpn_from_vaddr(lu_vaddr_i);
            miss_asid_q  <= lu_asid_i;
            miss_vmid_q  <= lu_vmid_i;
            miss_stage_q <= current_v_st_enbl;
          end
        end

        SB_TRACKING: begin
          // A matching flush invalidates the tracked entry and returns to MISS.
          if (flush_matches_tracked) begin
            sb_state_q     <= SB_MISS;
            sb_valid_q     <= 1'b0;
            track_chosen_q <= 1'b0;
            miss_valid_q   <= 1'b0;

          // Any observed lookup miss means the current tracked abstraction is no
          // longer the refill candidate. Move to MISS and remember this miss.
          end else if (lookup_miss) begin
            sb_state_q     <= SB_MISS;
            sb_valid_q     <= 1'b0;
            track_chosen_q <= 1'b0;

            miss_valid_q   <= 1'b1;
            miss_vpn_q     <= vpn_from_vaddr(lu_vaddr_i);
            miss_asid_q    <= lu_asid_i;
            miss_vmid_q    <= lu_vmid_i;
            miss_stage_q   <= current_v_st_enbl;
          end
        end

        default: begin
          sb_state_q     <= SB_MISS;
          sb_valid_q     <= 1'b0;
          track_chosen_q <= 1'b0;
          miss_valid_q   <= 1'b0;
        end

      endcase
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
    any_flush |-> !update_i.valid
  );

  // Standalone TLB/MMU environment contract:
  // An accepted TLB update is only allowed while the scoreboard is in MISS
  // state and must correspond to the missed lookup identity stored by the
  // scoreboard.
  a_update_only_after_scoreboard_miss: assume property (
    effective_tlb_update |->
      sb_in_miss_state &&
      update_matches_miss_identity
  );

  // Optional but recommended for this simple model:
  // Do not combine a new lookup miss and a refill update in the same cycle.
  // This avoids ambiguity about whether the update belongs to an older miss or
  // the new same-cycle miss.
  a_no_lookup_access_during_update: assume property (
    effective_tlb_update |->
      !lu_access_i
  );

  // ---------------------------------------------------------------------------
  // Assertions.
  // ---------------------------------------------------------------------------

    p_tracked_data_integrity_on_hit: assert property (
      sb_in_tracking_state &&
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

    p_matching_flush_moves_to_miss_state: assert property (
      flush_matches_tracked
      |->
      ##1 (sb_in_miss_state && !sb_valid_q)
    );

    p_lookup_miss_moves_to_miss_state: assert property (
      sb_in_tracking_state &&
      lookup_miss
      |->
      ##1 (sb_in_miss_state && !sb_valid_q)
    );

    p_any_flush_to_tracked_must_miss_after: assert property (
      flush_matches_tracked &&!sb_valid_q && lu_access_i && lookup_matches_tracked && !update_i.valid)
        |->
        !lu_hit_o
    );
  // ---------------------------------------------------------------------------
  // Cover / witness checks.
  // ---------------------------------------------------------------------------

  c_lookup_miss_seen: cover property (
    ##[1:10] lookup_miss
  );

  c_miss_then_update_then_tracking: cover property (
    lookup_miss
    ##[1:10]
    effective_tlb_update
    ##1
    sb_in_tracking_state &&
    sb_valid_q
  );

  c_tracked_update_then_hit: cover property (
    tracked_update
    ##[1:10]
    sb_in_tracking_state &&
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
    sb_in_tracking_state &&
    sb_valid_q &&
    sfence_vma_flush_matches_tracked
  );

  c_hfence_vvma_flush_seen: cover property (
    ##[1:10]
    sb_in_tracking_state &&
    sb_valid_q &&
    hfence_vvma_flush_matches_tracked
  );

  c_hfence_gvma_flush_seen: cover property (
    ##[1:10]
    sb_in_tracking_state &&
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

  c_tracked_napot_update_seen: cover property (
    tracked_update &&
    update_i.is_napot_64k
  );

  c_tracked_large_page_update_seen: cover property (
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
    .lu_is_page_o          (lu_is_page_o),
    .lu_hit_o              (lu_hit_o),

    .asid_to_be_flushed_i  (asid_to_be_flushed_i),
    .vmid_to_be_flushed_i  (vmid_to_be_flushed_i),
    .vaddr_to_be_flushed_i (vaddr_to_be_flushed_i),
    .gpaddr_to_be_flushed_i(gpaddr_to_be_flushed_i)
);