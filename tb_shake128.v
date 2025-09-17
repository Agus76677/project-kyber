`timescale 1ns/1ps

module tb_shake128;
  localparam integer RATE = 1344;

  reg clk;
  reg rst_n;
  reg init;
  reg in_valid;
  reg [RATE-1:0] in_block;
  reg in_last;
  wire in_ready;
  wire busy;
  wire out_valid;
  wire [127:0] out_data;
  reg out_ready;

  shake128_pipelined dut (
    .clk(clk),
    .rst_n(rst_n),
    .init(init),
    .in_valid(in_valid),
    .in_block(in_block),
    .in_last(in_last),
    .in_ready(in_ready),
    .busy(busy),
    .out_valid(out_valid),
    .out_data(out_data),
    .out_ready(out_ready)
  );

  localparam [127:0] EXP_EMPTY = 128'h7f9c2ba4e88f827d616045507605853e;
  localparam [127:0] EXP_ABC   = 128'h5881092dd818bf5cf8a3ddb793fbcba7;

  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end

  initial begin
    rst_n = 0;
    init = 0;
    in_valid = 0;
    in_block = {RATE{1'b0}};
    in_last = 0;
    out_ready = 1;
    #40;
    rst_n = 1;

    run_case_empty();
    run_case_abc();

    #100;
    $display("All tests completed");
    $finish;
  end

  task automatic run_case_empty;
    reg [RATE-1:0] block;
    begin
      block = {RATE{1'b0}};
      block[7:0] = 8'h1f;
      block[RATE-8 +: 8] = 8'h80;
      execute_test(block, EXP_EMPTY, "empty message");
    end
  endtask

  task automatic run_case_abc;
    reg [RATE-1:0] block;
    begin
      block = {RATE{1'b0}};
      block[7:0]   = 8'h61;
      block[15:8]  = 8'h62;
      block[23:16] = 8'h63;
      block[31:24] = 8'h1f;
      block[RATE-8 +: 8] = 8'h80;
      execute_test(block, EXP_ABC, "message 'abc'");
    end
  endtask

  task automatic execute_test(
    input [RATE-1:0] block,
    input [127:0] expected,
    input [8*32-1:0] label
  );
    reg [127:0] result;
    begin
      @(posedge clk);
      init <= 1'b1;
      @(posedge clk);
      init <= 1'b0;

      while (!in_ready) @(posedge clk);
      @(posedge clk);
      in_valid <= 1'b1;
      in_last  <= 1'b1;
      in_block <= block;
      @(posedge clk);
      in_valid <= 1'b0;
      in_last  <= 1'b0;
      in_block <= {RATE{1'b0}};

      wait(out_valid);
      result = out_data;
      if (result !== expected) begin
        $display("[%0t] %0s FAILED. Expected %h, got %h", $time, label, expected, result);
        $stop;
      end else begin
        $display("[%0t] %0s PASSED. Output = %h", $time, label, result);
      end

      @(posedge clk);
    end
  endtask
endmodule
