`timescale 1ns/1ps

module tb_cbd_sampler;
  localparam integer CLK_PERIOD = 10;
  localparam integer COEFFS_PER_CASE = 64;
  localparam integer MAX_WORDS = (COEFFS_PER_CASE * 2 * 3 + 127) / 128;

  reg clk = 1'b0;
  reg rst_n = 1'b0;

  always #(CLK_PERIOD/2) clk = ~clk;

  reg start;
  reg [15:0] n_coeffs;
  reg [127:0] random_in;
  reg random_valid;
  wire random_ready;
  reg [3:0] eta;
  reg coeff_ready;
  wire coeff_valid;
  wire signed [3:0] coeff_data;
  wire coeff_last;

  cbd_sampler #(
    .POLY_LENGTH(COEFFS_PER_CASE),
    .COEFF_COUNTER_WIDTH(16)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .n_coeffs(n_coeffs),
    .random_in(random_in),
    .random_valid(random_valid),
    .random_ready(random_ready),
    .eta(eta),
    .coeff_ready(coeff_ready),
    .coeff_valid(coeff_valid),
    .coeff_data(coeff_data),
    .coeff_last(coeff_last)
  );

  initial begin
    start = 1'b0;
    n_coeffs = COEFFS_PER_CASE;
    random_in = 128'd0;
    random_valid = 1'b0;
    eta = 4'd2;
    coeff_ready = 1'b1;
    #40;
    rst_n = 1'b1;
    @(posedge clk);
    run_case(2, "test/cbd_eta2_rand.hex", "test/cbd_eta2_coeffs.hex");
    run_case(3, "test/cbd_eta3_rand.hex", "test/cbd_eta3_coeffs.hex");
    $display("CBD sampler test completed successfully");
    #20;
    $finish;
  end

  task automatic run_case(
    input integer eta_value,
    input [1023:0] rand_path,
    input [1023:0] coeff_path
  );
    integer rand_words;
    reg [127:0] rand_mem [0:MAX_WORDS-1];
    reg [7:0] coeff_mem [0:COEFFS_PER_CASE-1];
    integer i;
    integer coeff_idx;
    integer word_idx;
    integer expected;
    begin
      rand_words = (COEFFS_PER_CASE * 2 * eta_value + 127) / 128;
      for (i = 0; i < MAX_WORDS; i = i + 1) begin
        rand_mem[i] = 128'd0;
      end
      for (i = 0; i < COEFFS_PER_CASE; i = i + 1) begin
        coeff_mem[i] = 8'd0;
      end

      $readmemh(rand_path, rand_mem);
      $readmemh(coeff_path, coeff_mem);

      eta <= eta_value[3:0];
      start <= 1'b1;
      @(posedge clk);
      start <= 1'b0;

      coeff_idx = 0;
      word_idx = 0;

      while (coeff_idx < COEFFS_PER_CASE) begin
        @(posedge clk);
        if (random_ready && (word_idx < rand_words)) begin
          random_in <= rand_mem[word_idx];
          random_valid <= 1'b1;
          word_idx = word_idx + 1;
        end else begin
          random_valid <= 1'b0;
        end

        if (coeff_valid) begin
          expected = coeff_mem[coeff_idx];
          if (expected >= 128) begin
            expected = expected - 256;
          end
          if ($signed(coeff_data) !== expected) begin
            $display("Mismatch at eta=%0d index=%0d expected=%0d got=%0d", eta_value, coeff_idx, expected, $signed(coeff_data));
            $fatal;
          end
          if ((coeff_idx == COEFFS_PER_CASE-1) && !coeff_last) begin
            $display("Missing coeff_last assertion at final sample (eta=%0d)", eta_value);
            $fatal;
          end
          if ((coeff_idx != COEFFS_PER_CASE-1) && coeff_last) begin
            $display("Unexpected coeff_last before final sample (eta=%0d index=%0d)", eta_value, coeff_idx);
            $fatal;
          end
          coeff_idx = coeff_idx + 1;
        end
      end

      random_valid <= 1'b0;
      repeat (4) @(posedge clk);
    end
  endtask

endmodule
