// CBD sampler with pipelined popcount
// Generates polynomial coefficients following the central binomial distribution.
module cbd_sampler #(
  parameter integer POLY_LENGTH = 256,
  parameter integer COEFF_COUNTER_WIDTH = 16
) (
  input  wire                        clk,
  input  wire                        rst_n,
  input  wire                        start,
  input  wire [COEFF_COUNTER_WIDTH-1:0] n_coeffs,
  input  wire [127:0]                random_in,
  input  wire                        random_valid,
  output wire                        random_ready,
  input  wire [3:0]                  eta,
  input  wire                        coeff_ready,
  output wire                        coeff_valid,
  output reg  signed [3:0]           coeff_data,
  output reg                         coeff_last
);

  localparam integer MAX_ETA = 3;
  localparam integer MAX_BITS = MAX_ETA * 2;

  reg active;
  reg [COEFF_COUNTER_WIDTH-1:0] remaining_coeffs;

  wire start_pulse = start & ~active;

  // Manage coefficient counter
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active <= 1'b0;
      remaining_coeffs <= {COEFF_COUNTER_WIDTH{1'b0}};
    end else begin
      if (start_pulse) begin
        active <= 1'b1;
        remaining_coeffs <= n_coeffs;
      end else if (coeff_valid && coeff_ready) begin
        if (remaining_coeffs > 0) begin
          remaining_coeffs <= remaining_coeffs - 1'b1;
        end
        if (remaining_coeffs <= 1) begin
          active <= 1'b0;
        end
      end
    end
  end

  wire [2:0] eta_eff = (eta == 4'd3) ? 3 : 2;
  wire [3:0] bits_per_sample = {1'b0, eta_eff} << 1; // 2*eta

  // Randomness buffer
  reg [255:0] rand_buffer;
  reg [8:0]   bits_available;

  wire load_random = random_valid && random_ready;

  wire pipeline_consuming;
  wire [3:0] consume_bits = bits_per_sample;

  reg [255:0] next_buffer;
  reg [8:0]   next_bits_available;

  always @* begin
    reg [255:0] buffer_tmp;
    reg [8:0]   available_tmp;

    buffer_tmp = rand_buffer;
    available_tmp = bits_available;

    if (pipeline_consuming) begin
      buffer_tmp = buffer_tmp >> consume_bits;
      available_tmp = available_tmp - consume_bits;
    end

    if (load_random) begin
      buffer_tmp[available_tmp +: 128] = random_in;
      available_tmp = available_tmp + 9'd128;
    end

    next_buffer = buffer_tmp;
    next_bits_available = available_tmp;
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rand_buffer <= 256'd0;
      bits_available <= 9'd0;
    end else begin
      rand_buffer <= next_buffer;
      bits_available <= next_bits_available;
    end
  end

  assign random_ready = (bits_available <= 9'd128);

  // Stage 0 -> Stage 1 pipeline
  reg stage1_valid;
  reg [MAX_BITS-1:0] stage1_bits;
  reg [2:0]          stage1_eta;

  wire stage1_ready;
  assign pipeline_consuming = active && (remaining_coeffs != 0) && (bits_available >= bits_per_sample) && stage1_ready;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stage1_valid <= 1'b0;
      stage1_bits  <= {MAX_BITS{1'b0}};
      stage1_eta   <= 3'd0;
    end else begin
      if (stage1_ready) begin
        stage1_valid <= pipeline_consuming;
        if (pipeline_consuming) begin
          stage1_bits <= rand_buffer[MAX_BITS-1:0];
          stage1_eta  <= eta_eff;
        end
      end
    end
  end

  // Stage 2: LUT based popcount for each half
  reg stage2_valid;
  reg [2:0] stage2_sum_a;
  reg [2:0] stage2_sum_b;
  wire stage2_ready;

  function automatic [2:0] popcount4;
    input [3:0] value;
    case (value)
      4'h0: popcount4 = 3'd0;
      4'h1, 4'h2, 4'h4, 4'h8: popcount4 = 3'd1;
      4'h3, 4'h5, 4'h6, 4'h9, 4'hA, 4'hC: popcount4 = 3'd2;
      4'h7, 4'hB, 4'hD, 4'hE: popcount4 = 3'd3;
      default: popcount4 = 3'd4;
    endcase
  endfunction

  wire stage1_fire = stage1_valid && stage2_ready;

  always @(posedge clk or negedge rst_n) begin : stage2_proc
    reg [3:0] a_bits;
    reg [3:0] b_bits;
    if (!rst_n) begin
      stage2_valid <= 1'b0;
      stage2_sum_a <= 3'd0;
      stage2_sum_b <= 3'd0;
    end else begin
      if (stage2_ready) begin
        stage2_valid <= stage1_fire;
        if (stage1_fire) begin
          a_bits = 4'd0;
          b_bits = 4'd0;
          if (stage1_eta == 3'd2) begin
            a_bits = {2'b00, stage1_bits[1:0]};
            b_bits = {2'b00, stage1_bits[3:2]};
          end else begin
            a_bits = {1'b0, stage1_bits[2:0]};
            b_bits = {1'b0, stage1_bits[5:3]};
          end
          stage2_sum_a <= popcount4(a_bits);
          stage2_sum_b <= popcount4(b_bits);
        end
      end
    end
  end

  // Stage 3: difference and register output
  reg stage3_valid;
  wire stage3_ready = (!stage3_valid) || coeff_ready;

  assign stage1_ready = (!stage1_valid) || stage2_ready;
  assign stage2_ready = (!stage2_valid) || stage3_ready;

  wire stage2_fire = stage2_valid && stage3_ready;

  wire signed [3:0] diff_calc = $signed({1'b0, stage2_sum_a}) - $signed({1'b0, stage2_sum_b});
  wire coeff_is_last = (remaining_coeffs == 1);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stage3_valid <= 1'b0;
      coeff_data   <= 4'sd0;
      coeff_last   <= 1'b0;
    end else begin
      if (stage3_ready) begin
        stage3_valid <= stage2_fire;
      end
      if (stage2_fire) begin
        coeff_data <= diff_calc;
        coeff_last <= coeff_is_last;
      end
    end
  end

  assign coeff_valid = stage3_valid;

endmodule
