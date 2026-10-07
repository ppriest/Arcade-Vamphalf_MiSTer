/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * 93C46 serial EEPROM, 64 x 16 bits (MAME EEPROM_93C46_16BIT), as MAME's
 * eeprom_serial_base_device / eeprom_serial_93cxx_device behave, the
 * reference the game's boot is compared against. From Arcade-KonamiGX_MiSTer
 * (rtl/memory/PROVENANCE.md).
 *
 *   IN_RESET          until CS rises
 *   WAIT_FOR_START    DO = 1 ("ready"); a rising CLK with DI = 1 starts a command
 *   WAIT_FOR_COMMAND  2 opcode + 6 address bits, on rising CLK
 *   READING_DATA      DO starts at the dummy 0; each rising CLK shifts: the first
 *                     loads the word (MSB first), later ones shift in 1s
 *   WAIT_FOR_DATA     16 data bits on rising CLK, then the write happens
 *   WAIT_FOR_COMPLETION  until CS falls
 *   CS falling always returns to IN_RESET. DO is 1 in every state but
 *   READING_DATA (tristate with a pull-up).
 *
 * Commands (93Cxx decode): 10 READ, 01 WRITE, 11 ERASE, 00 + top address
 * bits 00 LOCK, 01 WRITEALL, 10 ERASEALL, 11 UNLOCK. Writes and erases are
 * refused while locked; the part powers up locked, as MAME's does.
 *
 * BUSY, as MAME's eeprom_base_device: a WRITE, ERASE, WRITEALL or ERASEALL
 * that goes through holds the part busy for MAME's default times (the
 * driver sets none): 1.75 ms, 1 ms, 8 ms and 8 ms. While busy, DO reads 0 in
 * WAIT_FOR_START (MAME's do_read gives ready there) and a start bit is
 * ignored.
 *
 * The contents are the 128-byte image MAME saves in nvram/<set>/eeprom, big
 * endian words: load_we/load_addr/load_data write it (the .mra's default
 * image, then the saved .nvm), rd_addr/rd_data read it back for the save,
 * and `written` pulses when a command changes it.
 */

module vh_eeprom93c46 #(
    parameter CLK_KHZ = 48000,      // clk, for the busy times
    parameter WRITE_US = 1750,      // MAME's defaults (eeprom.cpp); a driver may set its own
    parameter ERASE_US = 1000
) (
    input             rst,
    input             blank,         // sweep the array to all ones
    input             clk,
    input             cs,
    input             sk,        // CLK
    input             di,
    output            dout,

    output     [63:0] dbg,           // { mem[63], mem[1], mem[0], 6'b0, sweep, locked, st }: the probe
    input             load_we,   // image load, one word
    input      [ 5:0] load_addr,
    input      [15:0] load_data,
    input      [ 5:0] rd_addr,       // the save's read port
    output     [15:0] rd_data,
    output reg        written        // a WRITE, ERASE, WRITEALL or ERASEALL changed the array
);

localparam [2:0] S_RESET = 0, S_START = 1, S_CMD = 2, S_READ = 3, S_DATA = 4, S_DONE = 5;

reg  [15:0] mem [0:63];
// Blank (all ones, a new part) while `blank` is high: a sweep writes every
// word, because the array is built as registers whose power-up value the
// fitter may choose (Power-Up Don't Care), and a game whose EEPROM check only
// reads failed it on the board while Verilator, which honours an initial
// value, passed. The sweep free-runs while blank is high, so it needs no
// power-up value of its own. The top holds blank from configuration until
// the ROM download starts, and the set's default image (MAME's "eeprom"
// region, ioctl index 2) is loaded during the download; the benches hold
// it through rst and load after.
reg  [5:0]  sweep;
reg  [ 2:0] st;
reg         cs_l, sk_l, locked;
reg  [ 7:0] cmd;
reg  [ 4:0] nbits;
reg  [31:0] shreg;
reg  [ 5:0] addr;
reg  [ 1:0] op;           // 0 read, 1 write, 2 writeall
localparam [19:0] T_WRITE = CLK_KHZ * WRITE_US / 1000, T_ERASE = CLK_KHZ * ERASE_US / 1000, T_ALL = CLK_KHZ * 8;
reg  [19:0] busy;         // clocks until ready
wire        ready = busy == 20'd0;

assign dout = st == S_READ ? shreg[31] : st == S_START ? ready : 1'b1;

wire cs_rise = cs && !cs_l, cs_fall = !cs && cs_l;
wire sk_rise = sk && !sk_l;
wire [7:0] cmd_n = { cmd[6:0], di };

integer i;
// the NVRAM save's read port
assign rd_data = mem[rd_addr];
always @(posedge clk) begin
    written <= 1'b0;
    if( !ready ) busy <= busy - 20'd1;
    if( blank ) begin
        sweep <= sweep + 6'd1;
        mem[sweep] <= 16'hffff;
    end
    if( load_we ) mem[load_addr] <= load_data;
    if( rst ) begin
        st     <= S_RESET;
        cs_l   <= 0;
        sk_l   <= 0;
        locked <= 1;
        busy   <= 20'd0;
    end else begin
        cs_l <= cs;
        sk_l <= sk;
        if( cs_fall ) st <= S_RESET;
        else case( st )
            S_RESET: if( cs_rise ) st <= S_START;
            // MAME ignores a CLK edge at the same moment as the CS rise
            S_START: if( sk_rise && di && !cs_rise && ready ) begin
                cmd <= 0; nbits <= 0; st <= S_CMD;
            end
            S_CMD: if( sk_rise ) begin
                cmd   <= cmd_n;
                nbits <= nbits + 5'd1;
                if( nbits == 5'd7 ) begin
                    nbits <= 0;
                    addr  <= cmd_n[5:0];
                    case( cmd_n[7:6] )
                        2'b10: begin shreg <= 0; st <= S_READ; end          // READ
                        2'b01: begin shreg <= 0; op <= 1; st <= S_DATA; end // WRITE
                        2'b11: begin                                          // ERASE
                            if( !locked ) begin mem[cmd_n[5:0]] <= 16'hffff; written <= 1'b1; busy <= T_ERASE; end
                            st <= locked ? S_RESET : S_DONE;
                        end
                        default: case( cmd_n[5:4] )
                            2'b00: begin locked <= 1; st <= S_DONE; end       // LOCK
                            2'b01: begin shreg <= 0; op <= 2; st <= S_DATA; end // WRITEALL
                            2'b10: begin                                      // ERASEALL
                                if( !locked ) begin
                                    for( i=0; i<64; i=i+1 ) mem[i] <= 16'hffff;
                                    written <= 1'b1;
                                    busy    <= T_ALL;
                                end
                                st <= locked ? S_RESET : S_DONE;
                            end
                            default: begin locked <= 0; st <= S_DONE; end     // UNLOCK
                        endcase
                    endcase
                end
            end
            S_READ: if( sk_rise ) begin
                nbits <= nbits + 5'd1;
                shreg <= nbits == 5'd0 ? { mem[addr], 16'hffff } : { shreg[30:0], 1'b1 };
            end
            S_DATA: if( sk_rise ) begin
                shreg <= { shreg[30:0], di };
                nbits <= nbits + 5'd1;
                if( nbits == 5'd15 ) begin
                    if( !locked ) begin
                        if( op == 2'd2 ) for( i=0; i<64; i=i+1 ) mem[i] <= { shreg[14:0], di };
                        else mem[addr] <= { shreg[14:0], di };
                        written <= 1'b1;
                        busy    <= op == 2'd2 ? T_ALL : T_WRITE;
                    end
                    st <= locked ? S_RESET : S_DONE;
                end
            end
            default: ;          // S_DONE: until CS falls
        endcase
    end
end

assign dbg = { mem[63], mem[1], mem[0], 6'd0, sweep, locked, st };

endmodule
