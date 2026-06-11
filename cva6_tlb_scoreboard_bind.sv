// cva6_tlb_scoreboard_bind.sv
// -----------------------------------------------------------------------------
// Direct-bind tracked-entry scoreboard for standalone CVA6 TLB verification.
//
// Main change compared to the anyconst/symbolic-VPN version:
//   - Do not use local anyconst symbolic_vpn/symbolic_asid.
//   - Instead, choose the first accepted TLB update as the tracked symbolic entry.
//   - The first update is still arbitrary from the formal environment, so this
//     keeps the checker abstract without modeling the full TLB table or PLRU.
//
// Scope:
//   - Non-hypervisor.
//   - Normal 4 KiB pages.
//   - No NAPOT/Svnapot.
//   - Data integrity checked only when DUT reports a hit.
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

  // ---------------------------------------------------------------------------
  // Abstract scoreboard state for the tracked entry.
  // ---------------------------------------------------------------------------
  logic sb_valid_q;
  logic [CVA6Cfg.PtLevels-2:0] sb_is_page_q;
  logic sb_is_napot_64k_q;
  logic [HYP_EXT:0] sb_v_st_enbl_q;
  pte_cva6_t sb_content_q;
  pte_cva6_t sb_g_content_q;

  function automatic logic [VPN_LEN-1:0] vpn_from_vaddr(
      input logic [CVA6Cfg.VLEN-1:0] vaddr
  );
    vpn_from_vaddr = vaddr[VPN_LEN+11:12];
  endfunction

  wire asid_flush_is_zero  = ~(|asid_to_be_flushed_i);
  wire vaddr_flush_is_zero = ~(|vaddr_to_be_flushed_i);

  wire flush_all =
      flush_i &&
      asid_flush_is_zero &&
      vaddr_flush_is_zero;

  // Accepted update according to the RTL priority.
  wire effective_tlb_update;
  assign effective_tlb_update =
      update_i.valid
      && !flush_i
      && !flush_vvma_i
      && !flush_gvma_i
      && !lu_hit_o;

  // Current restricted proof scope: normal 4 KiB, non-NAPOT, non-hypervisor.
  wire supported_update;
  assign supported_update =
      effective_tlb_update
      && (update_i.is_page == '0)
      && (update_i.v_st_enbl == '1)
      && (!CVA6Cfg.SvnapotEn || !update_i.is_napot_64k)
      && (HYP_EXT == 0)
      && (!CVA6Cfg.RVH);

  // The first accepted update becomes the abstract entry we track.
  wire tracked_update;
  assign tracked_update =
      supported_update && !track_chosen_q;

  wire lookup_matches_tracked;
  assign lookup_matches_tracked =
      track_chosen_q
      && lu_access_i
      && (vpn_from_vaddr(lu_vaddr_i) == tracked_vpn_q)
      && ((lu_asid_i == tracked_asid_q) || sb_content_q.g);

  wire tracked_flush_vpn_matches;
  assign tracked_flush_vpn_matches =
      (vpn_from_vaddr(vaddr_to_be_flushed_i) == tracked_vpn_q);

  wire flush_matches_tracked;
  assign flush_matches_tracked =
      sb_valid_q
      && flush_i
      && (
          // SFENCE.VMA x0, x0
          (asid_flush_is_zero && vaddr_flush_is_zero)
          ||
          // SFENCE.VMA vaddr, x0
          (asid_flush_is_zero && !vaddr_flush_is_zero && tracked_flush_vpn_matches)
          ||
          // SFENCE.VMA x0, asid; non-global only
          (!asid_flush_is_zero && vaddr_flush_is_zero &&
           !sb_content_q.g &&
           (asid_to_be_flushed_i == tracked_asid_q))
          ||
          // SFENCE.VMA vaddr, asid; non-global only
          (!asid_flush_is_zero && !vaddr_flush_is_zero &&
           !sb_content_q.g &&
           tracked_flush_vpn_matches &&
           (asid_to_be_flushed_i == tracked_asid_q))
      );

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
      sb_is_page_q       <= '0;
      sb_is_napot_64k_q  <= 1'b0;
      sb_v_st_enbl_q     <= '0;
      sb_content_q       <= '0;
      sb_g_content_q     <= '0;
    end else begin
      //FLUSH
      if (flush_matches_tracked) begin
        sb_valid_q <= 1'b0;
      //TRACKED UPDATE
      end else if (tracked_update) begin
        track_chosen_q     <= 1'b1;
        tracked_vpn_q      <= update_i.vpn[VPN_LEN-1:0];
        tracked_asid_q     <= update_i.asid;

        sb_valid_q         <= 1'b1;
        sb_is_page_q       <= update_i.is_page;
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

  // ---------------------------------------------------------------------------
  // Pending Miss Tracking.
  // ---------------------------------------------------------------------------
  logic pending_miss_q;
  logic [VPN_LEN-1:0] pending_vpn_q;
  logic [CVA6Cfg.ASID_WIDTH-1:0] pending_asid_q;

  wire lookup_miss =
      lu_access_i &&
      s_st_enbl_i &&
      !g_st_enbl_i &&
      !v_i &&
      !lu_hit_o;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pending_miss_q  <= 1'b0;
      pending_vpn_q   <= '0;
      pending_asid_q  <= '0;
    end else begin
      if (flush_i || flush_vvma_i || flush_gvma_i) begin
        pending_miss_q <= 1'b0;
      end else if (supported_update) begin
        pending_miss_q <= 1'b0;
      end else if (lookup_miss) begin
        pending_miss_q <= 1'b1;
        pending_vpn_q  <= vpn_from_vaddr(lu_vaddr_i);
        pending_asid_q <= lu_asid_i;
      end
    end
  end

  default clocking cb @(posedge clk_i); endclocking
  default disable iff (!rst_ni);

  // ---------------------------------------------------------------------------
  // Assumptions.
  // ---------------------------------------------------------------------------
  a_only_supported_updates: assume property (
    effective_tlb_update |-> supported_update
  );

  a_no_global_updates_yet: assume property (
    effective_tlb_update |-> !update_i.content.g
  );

  a_no_update_during_flush: assume property (
    flush_i |-> !update_i.valid
  );

  a_update_only_after_pending_miss: assume property (
  supported_update |->
    pending_miss_q &&
    (update_i.vpn[VPN_LEN-1:0] == pending_vpn_q) &&
    (update_i.asid == pending_asid_q)
);

  // ---------------------------------------------------------------------------
  // Assertions.
  // ---------------------------------------------------------------------------
  p_tracked_data_integrity_on_hit: assert property (
    sb_valid_q &&
    lookup_matches_tracked &&
    lu_hit_o
    |->
    (lu_content_o == sb_content_q) &&
    (lu_is_page_o == sb_is_page_q)
  );

  p_full_flush_clears_visible_hit: assert property (
    flush_all
    ##1
    (lu_access_i && !effective_tlb_update)
    |->
    !lu_hit_o
  );

  // ---------------------------------------------------------------------------
  // Cover / witness checks.
  // ---------------------------------------------------------------------------

  c_tracked_update_seen: cover property (
    ##[1:10] tracked_update
  );

  c_tracked_update_then_hit: cover property (
    tracked_update
    ##[1:10]
    sb_valid_q &&
    lookup_matches_tracked &&
    lu_hit_o &&
    (lu_content_o == sb_content_q) &&
    (lu_is_page_o == sb_is_page_q)
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
