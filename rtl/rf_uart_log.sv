//============================================================================
//  Ray Force -- self-test page over the HPS UART
//
//  sys_top wires the core's UART_TXD into the HPS UART, so what this sends
//  is readable on the board with
//
//      stty -F /dev/ttyS1 115200 raw -echo
//      cat /dev/ttyS1
//
//  (ttyS0 is the Linux console; ttyS1 is the fabric one.)
//
//  It walks rf_selftest's character port, so the serial output IS the
//  self-test page -- same labels, same values, same PASS/FAIL words, because
//  it reads the same ROM and the same value mux rather than a second copy of
//  the formatting. One row per frame keeps it inside the baud rate (a row is
//  42 bytes, a frame is 17 ms, and 115200 baud carries 195) and repeats the
//  whole page every 28 frames, about twice a second.
//
//  Trailing spaces are trimmed so a capture is readable in a terminal.
//============================================================================

import rf_selftest_pkg::*;

module rf_uart_log #(
    parameter int CLK_HZ = 53_372_000,
    parameter int BAUD   = 115200
) (
    input  logic       clk,
    input  logic       reset,
    input  logic       enable,
    input  logic       vbl_rise,      // one row goes out per frame

    // rf_selftest character port
    output logic [4:0] row,
    output logic [5:0] col,
    input  logic [7:0] char_in,       // valid 2 clocks after (row, col)

    output logic       txd
);

    localparam int DIV = CLK_HZ / BAUD;      // 463 at 53.372 MHz / 115200

    // Row text is fetched into a small buffer first, then shifted out. Doing
    // it that way means the length (for trailing-space trimming) is known
    // before the first byte leaves, and the character port is not held for
    // the whole 3.6 ms a row takes on the wire.
    // MLAB: 40 x 8 bits was landing in a whole M10K block (fit report,
    // 2026-09-09), and M10K is what the design is out of.
    (* ramstyle = "MLAB" *) logic [7:0] buf_mem [0:ST_COLS-1];
    logic [5:0] len;

    typedef enum logic [1:0] { S_IDLE, S_FETCH, S_SEND } state_t;
    state_t state;

    logic [5:0] fetch_i;
    logic [1:0] fetch_wait;
    logic [5:0] send_i;
    logic [1:0] tail;                 // 0 = text, 1 = CR, 2 = LF

    // ---- 8N1 transmitter -------------------------------------------------
    logic [15:0] baud_cnt;
    logic  [3:0] bit_idx;
    logic  [9:0] shifter;             // {stop, data, start}
    logic        busy;
    logic        load;
    logic  [7:0] load_ch;

    always_ff @(posedge clk) begin
        if (reset) begin
            txd      <= 1'b1;
            busy     <= 1'b0;
            baud_cnt <= 16'd0;
            bit_idx  <= 4'd0;
        end else if (!busy) begin
            if (load) begin
                shifter  <= {1'b1, load_ch, 1'b0};
                bit_idx  <= 4'd0;
                baud_cnt <= DIV[15:0] - 16'd1;
                busy     <= 1'b1;
                txd      <= 1'b0;                 // start bit
            end
        end else if (baud_cnt != 16'd0) begin
            baud_cnt <= baud_cnt - 16'd1;
        end else begin
            baud_cnt <= DIV[15:0] - 16'd1;
            shifter  <= {1'b1, shifter[9:1]};
            txd      <= shifter[1];
            if (bit_idx == 4'd9) begin
                busy <= 1'b0;
                txd  <= 1'b1;
            end else begin
                bit_idx <= bit_idx + 4'd1;
            end
        end
    end

    // ---- row walker ------------------------------------------------------
    integer k;

    always_ff @(posedge clk) begin
        if (reset || !enable) begin
            state   <= S_IDLE;
            row     <= 5'd0;
            col     <= 6'd0;
            load    <= 1'b0;
            len     <= 6'd0;
            fetch_i <= 6'd0;
            send_i  <= 6'd0;
            tail    <= 2'd0;
        end else begin
            load <= 1'b0;
            case (state)
                S_IDLE: if (vbl_rise) begin
                    fetch_i    <= 6'd0;
                    col        <= 6'd0;
                    fetch_wait <= 2'd0;
                    len        <= 6'd0;
                    state      <= S_FETCH;
                end

                S_FETCH: begin
                    // char_in is valid two clocks after the address
                    if (fetch_wait != 2'd2) begin
                        fetch_wait <= fetch_wait + 2'd1;
                    end else begin
                        buf_mem[fetch_i] <= char_in;
                        if (char_in != 8'h20) len <= fetch_i + 6'd1;  // trim tail
                        if (fetch_i == ST_COLS[5:0] - 6'd1) begin
                            send_i <= 6'd0;
                            tail   <= 2'd0;
                            state  <= S_SEND;
                        end else begin
                            fetch_i    <= fetch_i + 6'd1;
                            col        <= fetch_i + 6'd1;
                            fetch_wait <= 2'd0;
                        end
                    end
                end

                S_SEND: if (!busy && !load) begin
                    if (tail == 2'd0 && send_i != len) begin
                        load_ch <= buf_mem[send_i];
                        load    <= 1'b1;
                        send_i  <= send_i + 6'd1;
                    end else if (tail == 2'd0) begin
                        load_ch <= 8'h0D;
                        load    <= 1'b1;
                        tail    <= 2'd1;
                    end else if (tail == 2'd1) begin
                        load_ch <= 8'h0A;
                        load    <= 1'b1;
                        tail    <= 2'd2;
                    end else begin
                        row   <= (row == ST_ROWS[4:0] - 5'd1) ? 5'd0 : row + 5'd1;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
