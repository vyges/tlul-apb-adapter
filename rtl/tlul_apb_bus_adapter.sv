// tlul_apb_bus_adapter — TL-UL → APB sub-bus adapter (1×N fan-out)
//
// Combines a tlul_apb_adapter (TL-UL slave → APB master conversion) with an
// APB address decoder + read-data mux. Presents one TL-UL host port and N
// independent APB slave port-triplets (psel, prdata, pready). Standard APB
// signals (penable, pwrite, paddr, pwdata, pstrb, pprot) are broadcast.
//
// Parameterised over slave count via NUM_SLAVES; per-slave address ranges
// come from the ADDR_BASES / ADDR_MASKS parameter arrays. The combined
// module is intended to be hardened as a single LEF/GDS macro per SoC
// (with NUM_SLAVES + addresses set at instantiation), keeping the wrapper
// integration trivially small.
//
// Vyges-original IP. Composes tlul_apb_adapter (this repo) with a soft
// address-decode + mux block.
`ifndef TLUL_APB_BUS_ADAPTER_SV
`define TLUL_APB_BUS_ADAPTER_SV

module tlul_apb_bus_adapter #(
  parameter int unsigned NUM_SLAVES   = 1,
  parameter int unsigned AW           = 32,
  parameter int unsigned DW           = 32,
  parameter int unsigned DBW          = DW / 8,
  parameter int unsigned SOURCE_WIDTH = 8,
  parameter bit          APB4_EN      = 1'b1,
  // Per-slave address windows. ADDR_BASES[i] = base; ADDR_MASKS[i] is the
  // 1-bits mask of the slave's address range (e.g. 32'h00000fff for 4 KB).
  // A slave is selected when (paddr & ~ADDR_MASKS[i]) == ADDR_BASES[i].
  parameter logic [AW-1:0] ADDR_BASES [NUM_SLAVES] = '{default: '0},
  parameter logic [AW-1:0] ADDR_MASKS [NUM_SLAVES] = '{default: 32'h0000_0fff}
) (
  input  logic clk_i,
  input  logic rst_ni,

  // ── TL-UL host channel (flat signals, matches tlul_apb_adapter) ──────────
  input  logic                    tl_a_valid_i,
  input  logic [2:0]              tl_a_opcode_i,
  input  logic [2:0]              tl_a_param_i,
  input  logic [1:0]              tl_a_size_i,
  input  logic [SOURCE_WIDTH-1:0] tl_a_source_i,
  input  logic [AW-1:0]           tl_a_address_i,
  input  logic [DBW-1:0]          tl_a_mask_i,
  input  logic [DW-1:0]           tl_a_data_i,
  output logic                    tl_a_ready_o,

  output logic                    tl_d_valid_o,
  output logic [2:0]              tl_d_opcode_o,
  output logic [1:0]              tl_d_param_o,
  output logic [1:0]              tl_d_size_o,
  output logic [SOURCE_WIDTH-1:0] tl_d_source_o,
  output logic                    tl_d_error_o,
  output logic [DW-1:0]           tl_d_data_o,
  input  logic                    tl_d_ready_i,

  // ── APB slave fan-out (indexed) ──────────────────────────────────────────
  // Broadcast signals — same to every slave.
  output logic                    penable_o,
  output logic                    pwrite_o,
  output logic [AW-1:0]           paddr_o,
  output logic [DW-1:0]           pwdata_o,
  output logic [DBW-1:0]          pstrb_o,
  output logic [2:0]              pprot_o,
  // Per-slave signals — psel one-hot, prdata/pready muxed back.
  output logic [NUM_SLAVES-1:0]      psel_o,
  input  logic [NUM_SLAVES*DW-1:0]   prdata_flat_i,
  input  logic [NUM_SLAVES-1:0]      pready_i,
  input  logic [NUM_SLAVES-1:0]      pslverr_i
);

  // ── Internal APB master bus (from tlul_apb_adapter) ─────────────────────
  logic            apb_psel;
  logic            apb_penable;
  logic            apb_pwrite;
  logic [AW-1:0]   apb_paddr;
  logic [DW-1:0]   apb_pwdata;
  logic [DBW-1:0]  apb_pstrb;
  logic [2:0]      apb_pprot;
  logic [DW-1:0]   apb_prdata;
  logic            apb_pready;
  logic            apb_pslverr;

  tlul_apb_adapter #(
    .AW           (AW),
    .DW           (DW),
    .DBW          (DBW),
    .SOURCE_WIDTH (SOURCE_WIDTH),
    .APB4_EN      (APB4_EN)
  ) u_adapter (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .tl_a_valid_i   (tl_a_valid_i),
    .tl_a_opcode_i  (tl_a_opcode_i),
    .tl_a_param_i   (tl_a_param_i),
    .tl_a_size_i    (tl_a_size_i),
    .tl_a_source_i  (tl_a_source_i),
    .tl_a_address_i (tl_a_address_i),
    .tl_a_mask_i    (tl_a_mask_i),
    .tl_a_data_i    (tl_a_data_i),
    .tl_a_ready_o   (tl_a_ready_o),
    .tl_d_valid_o   (tl_d_valid_o),
    .tl_d_opcode_o  (tl_d_opcode_o),
    .tl_d_param_o   (tl_d_param_o),
    .tl_d_size_o    (tl_d_size_o),
    .tl_d_source_o  (tl_d_source_o),
    .tl_d_error_o   (tl_d_error_o),
    .tl_d_data_o    (tl_d_data_o),
    .tl_d_ready_i   (tl_d_ready_i),
    .apb_psel_o     (apb_psel),
    .apb_penable_o  (apb_penable),
    .apb_pwrite_o   (apb_pwrite),
    .apb_paddr_o    (apb_paddr),
    .apb_pwdata_o   (apb_pwdata),
    .apb_pstrb_o    (apb_pstrb),
    .apb_pprot_o    (apb_pprot),
    .apb_prdata_i   (apb_prdata),
    .apb_pready_i   (apb_pready),
    .apb_pslverr_i  (apb_pslverr)
  );

  // ── Broadcast APB phase signals to every slave ──────────────────────────
  assign penable_o = apb_penable;
  assign pwrite_o  = apb_pwrite;
  assign paddr_o   = apb_paddr;
  assign pwdata_o  = apb_pwdata;
  assign pstrb_o   = apb_pstrb;
  assign pprot_o   = apb_pprot;

  // ── Per-slave psel decode (one-hot when in range) ───────────────────────
  for (genvar i = 0; i < NUM_SLAVES; i = i + 1) begin : g_decode
    assign psel_o[i] = apb_psel &&
        ((apb_paddr & ~ADDR_MASKS[i]) == ADDR_BASES[i]);
  end

  // ── prdata / pready / pslverr mux from selected slave ───────────────────
  // psel_o is one-hot by construction (address ranges must not overlap).
  // Default (no match) returns 0 / ready / no-error to avoid bus stalls.
  always_comb begin
    apb_prdata  = '0;
    apb_pready  = 1'b1;
    apb_pslverr = 1'b0;
    for (int i = 0; i < NUM_SLAVES; i = i + 1) begin
      if (psel_o[i]) begin
        apb_prdata  = prdata_flat_i[i*DW +: DW];
        apb_pready  = pready_i[i];
        apb_pslverr = pslverr_i[i];
      end
    end
  end

endmodule

`endif // TLUL_APB_BUS_ADAPTER_SV
