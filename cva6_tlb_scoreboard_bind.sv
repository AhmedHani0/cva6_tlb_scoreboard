// cva6_tlb_scoreboard_bind.sv
// -----------------------------------------------------------------------------
// Direct-bind scoreboard for standalone CVA6 TLB verification.
//
// Step 3 scope:
//   - Full abstract scoreboard array with TLB_ENTRIES entries
//   - Non-hypervisor only: RVH/G-stage/V-mode disabled by the formal top
//   - Normal 4 KiB pages only
//   - No NAPOT/Svnapot
//   - No global mappings yet
//   - Scoreboard models the same PLRU replacement policy abstractly
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

    // Full TLB update packet.
    input tlb_update_cva6_t update_i,

    // Lookup interface.
    input logic lu_access_i,
    input logic [CVA6Cfg.ASID_WIDTH-1:0] lu_asid_i,
    input logic [CVA6Cfg.VMID_WIDTH-1:0] lu_vmid_i,
    input logic [CVA6Cfg.VLEN-1:0] lu_vaddr_i,
    input logic [CVA6Cfg.GPLEN-1:0] lu_gpaddr_o,
    input pte_cva6_t lu_content_o,
    input pte_cva6_t lu_g_content_o,

    // Flush filters.
    input logic [CVA6Cfg.ASID_WIDTH-1:0] asid_to_be_flushed_i,
    input logic [CVA6Cfg.VMID_WIDTH-1:0] vmid_to_be_flushed_i,
    input logic [CVA6Cfg.VLEN-1:0] vaddr_to_be_flushed_i,
    input logic [CVA6Cfg.GPLEN-1:0] gpaddr_to_be_flushed_i,

    // Lookup result.
    input logic [CVA6Cfg.PtLevels-2:0] lu_is_page_o,
    input logic lu_hit_o,

    // Optional internal DUT signals connected by bind for sanity/debug checks.
    // not needed for scoreboard comparison.
    input logic [TLB_ENTRIES-1:0] dut_lu_hit,
    input logic [TLB_ENTRIES-1:0] dut_replace_en
);

  localparam int unsigned VPN_LEN    = CVA6Cfg.VpnLen;
  localparam int unsigned PLRU_WIDTH = 2 * (TLB_ENTRIES - 1);

  // ---------------------------------------------------------------------------
  // Abstract scoreboard entry.
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic valid;
    logic [VPN_LEN-1:0] vpn;
    logic [CVA6Cfg.ASID_WIDTH-1:0] asid;
    logic [CVA6Cfg.PtLevels-2:0] is_page;
    logic is_napot_64k;
    logic [HYP_EXT:0] v_st_enbl;
    pte_cva6_t content;
  } sb_entry_t;

  sb_entry_t sb_q [TLB_ENTRIES];

  // ---------------------------------------------------------------------------
  // Helper state for modelling the MMU/shared-TLB/PTW environment.
  // pending_miss_q means: a lookup missed and the environment may later refill it.
  // ---------------------------------------------------------------------------
  logic pending_miss_q;
  logic [VPN_LEN-1:0] pending_vpn_q;
  logic [CVA6Cfg.ASID_WIDTH-1:0] pending_asid_q;

  // ---------------------------------------------------------------------------
  // Scoreboard PLRU = Pseudo Least Recently Used replacement model
  // This is the scoreboard's own abstract copy
  // ---------------------------------------------------------------------------
  logic [PLRU_WIDTH-1:0] sb_plru_tree_q;
  logic [PLRU_WIDTH-1:0] sb_plru_tree_n;
  logic [TLB_ENTRIES-1:0] sb_replace_en;

  // Scoreboard lookup prediction.
  logic [TLB_ENTRIES-1:0] sb_hit;
  pte_cva6_t sb_expected_content;
  logic [CVA6Cfg.PtLevels-2:0] sb_expected_is_page;

  // ---------------------------------------------------------------------------
  // Basic helper wires.
  // ---------------------------------------------------------------------------
  wire asid_flush_is_zero  = ~(|asid_to_be_flushed_i);
  wire vaddr_flush_is_zero = ~(|vaddr_to_be_flushed_i);
  wire flush_all = flush_i && asid_flush_is_zero && vaddr_flush_is_zero;

  // effective_tlb_update = update request that the RTL can actually accept.
  // If flush and update are high together, flush wins in the RTL and the update is ignored.
  wire effective_tlb_update;
  assign effective_tlb_update =
      update_i.valid
      && !flush_i
      && !flush_vvma_i
      && !flush_gvma_i
      && !lu_hit_o;

  // Step 3 only supported update: normal 4 KiB, no NAPOT, no hypervisor.
  wire supported_update;
  assign supported_update =
      effective_tlb_update
      && (update_i.is_page == '0)
      && (update_i.v_st_enbl == '1)
      && (!CVA6Cfg.SvnapotEn || !update_i.is_napot_64k)
      && (HYP_EXT == 0)
      && (!CVA6Cfg.RVH);

  wire lookup_miss;
  assign lookup_miss = lu_access_i && !lu_hit_o;

  // Extract VPN = Virtual Page Number from a virtual address.
  function automatic logic [VPN_LEN-1:0] vpn_from_vaddr(input logic [CVA6Cfg.VLEN-1:0] vaddr);
    vpn_from_vaddr = vaddr[VPN_LEN+11:12];
  endfunction

  function automatic int unsigned count_ones(input logic [TLB_ENTRIES-1:0] vector);
    int unsigned count;
    count = 0;
    foreach (vector[i]) begin
      count += vector[i];
    end
    return count;
  endfunction

  // Step 3A lookup matching: normal 4 KiB pages only.
  function automatic logic entry_matches_lookup(input sb_entry_t entry);
    logic vpn_matches;
    logic asid_matches;
    logic stage_matches;

    vpn_matches   = (entry.vpn == vpn_from_vaddr(lu_vaddr_i));
    asid_matches  = (lu_asid_i == entry.asid) || entry.content.g;
    stage_matches = (entry.v_st_enbl == '1);

    entry_matches_lookup =
        entry.valid
        && lu_access_i
        && s_st_enbl_i
        && !g_st_enbl_i
        && !v_i
        && (entry.is_page == '0)
        && !entry.is_napot_64k
        && vpn_matches
        && asid_matches
        && stage_matches;
  endfunction

  // Step 3A flush matching for normal 4 KiB entries.
  function automatic logic flush_matches_entry(input sb_entry_t entry);
    logic flush_vpn_matches;
    flush_vpn_matches = (vpn_from_vaddr(vaddr_to_be_flushed_i) == entry.vpn);

    if (!entry.valid) begin
      flush_matches_entry = 1'b0;
    end
    // SFENCE.VMA x0, x0: flush all entries.
    else if (asid_flush_is_zero && vaddr_flush_is_zero) begin
      flush_matches_entry = 1'b1;
    end
    // SFENCE.VMA vaddr, x0: flush this VPN for all ASIDs, including global.
    else if (asid_flush_is_zero && !vaddr_flush_is_zero && flush_vpn_matches) begin
      flush_matches_entry = 1'b1;
    end
    // SFENCE.VMA x0, asid: flush non-global entries of this ASID.
    else if (!asid_flush_is_zero && vaddr_flush_is_zero &&
             !entry.content.g &&
             (asid_to_be_flushed_i == entry.asid)) begin
      flush_matches_entry = 1'b1;
    end
    // SFENCE.VMA vaddr, asid: flush non-global entry matching VPN and ASID.
    else if (!asid_flush_is_zero && !vaddr_flush_is_zero &&
             !entry.content.g &&
             flush_vpn_matches &&
             (asid_to_be_flushed_i == entry.asid)) begin
      flush_matches_entry = 1'b1;
    end
    else begin
      flush_matches_entry = 1'b0;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Scoreboard lookup
  // If multiple entries hit, the expected_content loop mimics RTL loop order,
  // Step 3 also asserts that the scoreboard produces at most one hit.
  // ---------------------------------------------------------------------------
  always_comb begin
    sb_hit              = '0;
    sb_expected_content = '0;
    sb_expected_is_page = '0;

    for (int i = 0; i < TLB_ENTRIES; i++) begin
      sb_hit[i] = entry_matches_lookup(sb_q[i]);
      if (sb_hit[i]) begin
        sb_expected_content = sb_q[i].content;
        sb_expected_is_page = sb_q[i].is_page;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Scoreboard PLRU model.
  // This mirrors the RTL PLRU algorithm but uses sb_hit instead of dut_lu_hit.
  // ---------------------------------------------------------------------------
  always_comb begin
    sb_plru_tree_n = sb_plru_tree_q;
    sb_replace_en  = '0;

    // Update PLRU tree on lookup hit.
    for (int unsigned i = 0; i < TLB_ENTRIES; i++) begin
      automatic int unsigned idx_base, shift, new_index;

      if (sb_hit[i] && lu_access_i) begin
        for (int unsigned lvl = 0; lvl < $clog2(TLB_ENTRIES); lvl++) begin
          idx_base  = $unsigned((2 ** lvl) - 1);
          shift     = $clog2(TLB_ENTRIES) - lvl;
          new_index = ~((i >> (shift - 1)) & 32'b1);
          sb_plru_tree_n[idx_base + (i >> shift)] = new_index[0];
        end
      end
    end

    // Decode current PLRU tree into replacement enable vector.
    for (int unsigned i = 0; i < TLB_ENTRIES; i++) begin
      automatic logic en;
      automatic int unsigned idx_base, shift, new_index;

      en = 1'b1;
      for (int unsigned lvl = 0; lvl < $clog2(TLB_ENTRIES); lvl++) begin
        idx_base  = $unsigned((2 ** lvl) - 1);
        shift     = $clog2(TLB_ENTRIES) - lvl;
        new_index = (i >> (shift - 1)) & 32'b1;

        if (new_index[0]) begin
          en &= sb_plru_tree_q[idx_base + (i >> shift)];
        end else begin
          en &= ~sb_plru_tree_q[idx_base + (i >> shift)];
        end
      end
      sb_replace_en[i] = en;
    end
  end

  // ---------------------------------------------------------------------------
  // Full-array scoreboard state update.
  // Priority matches RTL: reset -> flush -> accepted update.
  // PLRU tree updates every cycle from sb_plru_tree_n, matching the RTL style.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int i = 0; i < TLB_ENTRIES; i++) begin
        sb_q[i] <= '0;
      end
      sb_plru_tree_q <= '0;
    end else begin
      sb_plru_tree_q <= sb_plru_tree_n;

      if (flush_i) begin
        for (int i = 0; i < TLB_ENTRIES; i++) begin
          if (flush_matches_entry(sb_q[i])) begin
            sb_q[i].valid <= 1'b0;
          end
        end
      end else if (effective_tlb_update) begin
        for (int i = 0; i < TLB_ENTRIES; i++) begin
          if (sb_replace_en[i]) begin
            sb_q[i].valid        <= 1'b1;
            sb_q[i].vpn          <= update_i.vpn[VPN_LEN-1:0];
            sb_q[i].asid         <= update_i.asid;
            sb_q[i].is_page      <= update_i.is_page;
            sb_q[i].is_napot_64k <= update_i.is_napot_64k;
            sb_q[i].v_st_enbl    <= update_i.v_st_enbl;
            sb_q[i].content      <= update_i.content;
          end
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Pending-miss environment model.
  // A miss creates a pending request. An accepted update resolves it.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pending_miss_q <= 1'b0;
      pending_vpn_q  <= '0;
      pending_asid_q <= '0;
    end else begin
      if (flush_i) begin
        pending_miss_q <= 1'b0;
        pending_vpn_q  <= '0;
        pending_asid_q <= '0;
      end else if (effective_tlb_update) begin
        pending_miss_q <= 1'b0;
      end else if (lookup_miss && !pending_miss_q) begin
        pending_miss_q <= 1'b1;
        pending_vpn_q  <= vpn_from_vaddr(lu_vaddr_i);
        pending_asid_q <= lu_asid_i;
      end
    end
  end

  default clocking cb @(posedge clk_i); endclocking
  default disable iff (!rst_ni);

  // ---------------------------------------------------------------------------
  // Assumptions
  // ---------------------------------------------------------------------------

  // An accepted update must correspond to a previous unresolved miss.
  a_update_only_after_pending_miss: assume property (
    effective_tlb_update |-> pending_miss_q
  );

  // The accepted update must refill the same VPN and ASID that missed.
  a_update_matches_pending_miss: assume property (
    effective_tlb_update |->
      (update_i.vpn[VPN_LEN-1:0] == pending_vpn_q) &&
      (update_i.asid == pending_asid_q)
  );

  // Step 3A: only normal 4 KiB, non-NAPOT, non-hypervisor updates.
  a_only_supported_updates: assume property (
    effective_tlb_update |-> supported_update
  );

  // Step 3A: global mappings are postponed to Step 3B.
  a_step3a_no_global_updates: assume property (
    effective_tlb_update |-> !update_i.content.g
  );

  // During flush, the environment does not also send a refill request.
  a_no_update_during_flush: assume property (
    flush_i |-> !update_i.valid
  );

  // ---------------------------------------------------------------------------
  // Assertions
  // ---------------------------------------------------------------------------

  // Scoreboard itself should not predict two matching entries in Step 3A.
  p_scoreboard_at_most_one_hit: assert property (
    count_ones(sb_hit) <= 1
  );

  // Scoreboard PLRU replacement vector should select exactly one entry.
  p_scoreboard_one_replace_entry: assert property (
    count_ones(sb_replace_en) == 1
  );

  // Optional internal sanity checks for debug only, not pure scoreboard abstraction.
  p_at_most_one_replace_entry: assert property (
    count_ones(dut_replace_en) <= 1
  );

  p_visible_hit_matches_internal_hit_vector: assert property (
    lu_hit_o == (|dut_lu_hit)
  );

  // External scoreboard hit/miss equivalence.
  p_lookup_hit_matches_scoreboard: assert property (
    lu_access_i |-> (lu_hit_o == (|sb_hit))
  );

  // External scoreboard content/page-size equivalence when the model predicts a hit.
  p_lookup_content_matches_scoreboard: assert property (
    lu_access_i && (|sb_hit) |->
      (lu_content_o == sb_expected_content) &&
      (lu_is_page_o == sb_expected_is_page)
  );

  // Full flush: after SFENCE.VMA x0, x0, a lookup in the next cycle must miss
  // unless a new update is accepted in that next cycle.
  p_full_flush_clears_visible_hit: assert property (
    flush_all ##1 (lu_access_i && !effective_tlb_update) |-> !lu_hit_o
  );

  // If VPN X / ASID A missed before and no refill happened yet,
  // looking up VPN X / ASID A again should still miss.
  p_pending_miss_same_lookup_stays_miss_until_refill: assert property (
    pending_miss_q &&
    lu_access_i &&
    (vpn_from_vaddr(lu_vaddr_i) == pending_vpn_q) &&
    (lu_asid_i == pending_asid_q) &&
    !effective_tlb_update
    |->
    !lu_hit_o
  );

  // Cover: miss -> accepted update/refill -> later hit from scoreboard.
  c_miss_update_hit_flow: cover property (
    (lu_access_i && !lu_hit_o)
    ##[1:5]
    supported_update
    ##[1:5]
    (lu_access_i && (|sb_hit) && lu_hit_o && (lu_content_o == sb_expected_content))
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
    .lu_hit_o              (lu_hit_o),

    .dut_lu_hit            (lu_hit),
    .dut_replace_en        (replace_en)
);
