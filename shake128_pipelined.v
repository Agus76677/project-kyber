// Pipelined SHAKE128 implementation based on Keccak-f[1600]
// Provides a 128-bit squeeze output with a three stage datapath
// dividing absorption, partial permutation, and finalization.

`timescale 1ns/1ps

module shake128_pipelined #(
  parameter integer RATE = 1344
) (
  input  wire               clk,
  input  wire               rst_n,
  input  wire               init,

  input  wire               in_valid,
  input  wire [RATE-1:0]    in_block,
  input  wire               in_last,
  output wire               in_ready,

  output wire               busy,
  output wire               out_valid,
  output wire [127:0]       out_data,
  input  wire               out_ready
);

  localparam integer CAPACITY = 1600 - RATE;
  localparam integer TOTAL_WIDTH = 1600;

  // Current Keccak state
  reg [TOTAL_WIDTH-1:0] current_state;
  reg                    state_busy;

  // Stage registers
  reg [TOTAL_WIDTH-1:0] stage0_state;
  reg                   stage0_valid;
  reg                   stage0_last;

  reg [TOTAL_WIDTH-1:0] stage1_state;
  reg                   stage1_valid;
  reg                   stage1_last;

  reg [TOTAL_WIDTH-1:0] stage2_state;
  reg                   stage2_valid;
  reg                   stage2_last;

  reg [TOTAL_WIDTH-1:0] stage3_state;
  reg                   stage3_valid;
  reg                   stage3_last;

  reg [127:0]           out_data_r;
  reg                   out_valid_r;

  assign out_data  = out_data_r;
  assign out_valid = out_valid_r;

  wire absorb_fire = in_valid & in_ready;

  assign busy = state_busy | stage0_valid | stage1_valid | stage2_valid |
                stage3_valid | out_valid_r;

  assign in_ready = (!state_busy) && (!stage0_valid) && (!stage1_valid) &&
                    (!stage2_valid) && (!stage3_valid) && (!out_valid_r);

  integer idx_byte;

  // Absorption stage: XOR the input block into the rate portion of the state
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stage0_state <= {TOTAL_WIDTH{1'b0}};
      stage0_valid <= 1'b0;
      stage0_last  <= 1'b0;
    end else begin
      if (init) begin
        stage0_state <= {TOTAL_WIDTH{1'b0}};
        stage0_valid <= 1'b0;
        stage0_last  <= 1'b0;
      end else begin
        stage0_valid <= 1'b0;
        if (absorb_fire) begin
          stage0_state <= current_state;
          for (idx_byte = 0; idx_byte < RATE/8; idx_byte = idx_byte + 1) begin
            stage0_state[idx_byte*8 +: 8] <= current_state[idx_byte*8 +: 8] ^
                                             in_block[idx_byte*8 +: 8];
          end
          stage0_valid <= 1'b1;
          stage0_last  <= in_last;
        end
      end
    end
  end

  // Stage1: first half of the Keccak rounds
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stage1_state <= {TOTAL_WIDTH{1'b0}};
      stage1_valid <= 1'b0;
      stage1_last  <= 1'b0;
    end else begin
      if (init) begin
        stage1_state <= {TOTAL_WIDTH{1'b0}};
        stage1_valid <= 1'b0;
        stage1_last  <= 1'b0;
      end else begin
        stage1_valid <= stage0_valid;
        stage1_last  <= stage0_last;
        if (stage0_valid) begin
          stage1_state <= keccak_rounds_half(stage0_state, 1'b0);
        end
      end
    end
  end

  // Stage2: second half of the Keccak rounds
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stage2_state <= {TOTAL_WIDTH{1'b0}};
      stage2_valid <= 1'b0;
      stage2_last  <= 1'b0;
    end else begin
      if (init) begin
        stage2_state <= {TOTAL_WIDTH{1'b0}};
        stage2_valid <= 1'b0;
        stage2_last  <= 1'b0;
      end else begin
        stage2_valid <= stage1_valid;
        stage2_last  <= stage1_last;
        if (stage1_valid) begin
          stage2_state <= keccak_rounds_half(stage1_state, 1'b1);
        end
      end
    end
  end

  // Stage3: register the permutation output and drive squeezing
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stage3_state <= {TOTAL_WIDTH{1'b0}};
      stage3_valid <= 1'b0;
      stage3_last  <= 1'b0;
    end else begin
      if (init) begin
        stage3_state <= {TOTAL_WIDTH{1'b0}};
        stage3_valid <= 1'b0;
        stage3_last  <= 1'b0;
      end else begin
        stage3_valid <= stage2_valid;
        stage3_last  <= stage2_last;
        if (stage2_valid) begin
          stage3_state <= stage2_state;
        end
      end
    end
  end

  // Track the current state and busy flag
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      current_state <= {TOTAL_WIDTH{1'b0}};
      state_busy    <= 1'b0;
    end else begin
      if (init) begin
        current_state <= {TOTAL_WIDTH{1'b0}};
        state_busy    <= 1'b0;
      end else begin
        if (absorb_fire) begin
          state_busy <= 1'b1;
        end
        if (stage2_valid) begin
          current_state <= stage2_state;
          state_busy    <= 1'b0;
        end
      end
    end
  end

  // Output management and squeezing
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_data_r  <= 128'b0;
      out_valid_r <= 1'b0;
    end else begin
      if (init) begin
        out_data_r  <= 128'b0;
        out_valid_r <= 1'b0;
      end else begin
        if (out_valid_r && out_ready) begin
          out_valid_r <= 1'b0;
        end
        if (stage3_valid && stage3_last) begin
          out_data_r  <= stage3_state[127:0];
          out_valid_r <= 1'b1;
        end
      end
    end
  end

  // ========= Keccak permutation helpers =========

  function automatic [1599:0] keccak_rounds_half;
    input [1599:0] in_state;
    input          upper_half; // 0 for first 12 rounds, 1 for last 12
    reg   [1599:0] s;
    integer        i;
    integer        start_round;
    begin
      s = in_state;
      start_round = upper_half ? 12 : 0;
      for (i = 0; i < 12; i = i + 1) begin
        s = keccak_round(s, keccak_rc(start_round + i));
      end
      keccak_rounds_half = s;
    end
  endfunction

  function automatic [1599:0] keccak_round;
    input [1599:0] state_in;
    input [63:0]   rc;
    reg   [1599:0] a_theta;
    reg   [1599:0] a_rhopi;
    reg   [1599:0] a_chi;
    begin
      a_theta  = theta(state_in);
      a_rhopi  = rho_pi(a_theta);
      a_chi    = chi(a_rhopi);
      a_chi[63:0] = a_chi[63:0] ^ rc;
      keccak_round = a_chi;
    end
  endfunction

  function automatic [1599:0] theta;
    input [1599:0] state_in;
    reg   [63:0]   c[0:4];
    reg   [63:0]   d[0:4];
    reg   [1599:0] result;
    integer x, y;
    begin
      for (x = 0; x < 5; x = x + 1) begin
        c[x] = 64'b0;
        for (y = 0; y < 5; y = y + 1) begin
          c[x] = c[x] ^ state_in[lane_index(x, y) +: 64];
        end
      end
      for (x = 0; x < 5; x = x + 1) begin
        d[x] = c[(x + 4) % 5] ^ rol64(c[(x + 1) % 5], 1);
      end
      result = state_in;
      for (x = 0; x < 5; x = x + 1) begin
        for (y = 0; y < 5; y = y + 1) begin
          result[lane_index(x, y) +: 64] =
              state_in[lane_index(x, y) +: 64] ^ d[x];
        end
      end
      theta = result;
    end
  endfunction

  function automatic [1599:0] rho_pi;
    input [1599:0] state_in;
    reg   [1599:0] result;
    integer x, y;
    integer new_x, new_y;
    begin
      result = {1600{1'b0}};
      for (x = 0; x < 5; x = x + 1) begin
        for (y = 0; y < 5; y = y + 1) begin
          new_x = y;
          new_y = (2 * x + 3 * y) % 5;
          result[lane_index(new_x, new_y) +: 64] =
              rol64(state_in[lane_index(x, y) +: 64], rho_offset(x, y));
        end
      end
      rho_pi = result;
    end
  endfunction

  function automatic [1599:0] chi;
    input [1599:0] state_in;
    reg   [1599:0] result;
    integer x, y;
    begin
      result = state_in;
      for (y = 0; y < 5; y = y + 1) begin
        for (x = 0; x < 5; x = x + 1) begin
          result[lane_index(x, y) +: 64] = state_in[lane_index(x, y) +: 64] ^
            ((~state_in[lane_index((x + 1) % 5, y) +: 64]) &
              state_in[lane_index((x + 2) % 5, y) +: 64]);
        end
      end
      chi = result;
    end
  endfunction

  function automatic integer lane_index;
    input integer x;
    input integer y;
    begin
      lane_index = ((5 * y) + x) * 64;
    end
  endfunction

  function automatic [63:0] rol64;
    input [63:0] data;
    input integer offset;
    begin
      if (offset == 0)
        rol64 = data;
      else
        rol64 = (data << offset) | (data >> (64 - offset));
    end
  endfunction

  function automatic integer rho_offset;
    input integer x;
    input integer y;
    begin
      case ((5 * y) + x)
        0:  rho_offset = 0;
        1:  rho_offset = 36;
        2:  rho_offset = 3;
        3:  rho_offset = 41;
        4:  rho_offset = 18;
        5:  rho_offset = 1;
        6:  rho_offset = 44;
        7:  rho_offset = 10;
        8:  rho_offset = 45;
        9:  rho_offset = 2;
        10: rho_offset = 62;
        11: rho_offset = 6;
        12: rho_offset = 43;
        13: rho_offset = 15;
        14: rho_offset = 61;
        15: rho_offset = 28;
        16: rho_offset = 55;
        17: rho_offset = 25;
        18: rho_offset = 21;
        19: rho_offset = 56;
        20: rho_offset = 27;
        21: rho_offset = 20;
        22: rho_offset = 39;
        23: rho_offset = 8;
        24: rho_offset = 14;
        default: rho_offset = 0;
      endcase
    end
  endfunction

  function automatic [63:0] keccak_rc;
    input integer index;
    begin
      case (index)
        0:  keccak_rc = 64'h0000000000000001;
        1:  keccak_rc = 64'h0000000000008082;
        2:  keccak_rc = 64'h800000000000808a;
        3:  keccak_rc = 64'h8000000080008000;
        4:  keccak_rc = 64'h000000000000808b;
        5:  keccak_rc = 64'h0000000080000001;
        6:  keccak_rc = 64'h8000000080008081;
        7:  keccak_rc = 64'h8000000000008009;
        8:  keccak_rc = 64'h000000000000008a;
        9:  keccak_rc = 64'h0000000000000088;
        10: keccak_rc = 64'h0000000080008009;
        11: keccak_rc = 64'h000000008000000a;
        12: keccak_rc = 64'h000000008000808b;
        13: keccak_rc = 64'h800000000000008b;
        14: keccak_rc = 64'h8000000000008089;
        15: keccak_rc = 64'h8000000000008003;
        16: keccak_rc = 64'h8000000000008002;
        17: keccak_rc = 64'h8000000000000080;
        18: keccak_rc = 64'h000000000000800a;
        19: keccak_rc = 64'h800000008000000a;
        20: keccak_rc = 64'h8000000080008081;
        21: keccak_rc = 64'h8000000000008080;
        22: keccak_rc = 64'h0000000080000001;
        23: keccak_rc = 64'h8000000080008008;
        default: keccak_rc = 64'h0;
      endcase
    end
  endfunction

endmodule
