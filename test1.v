
// ============================================================================
// sdram_dualport_stress_writer.v  (BRAM framebuffer, 320x240)
// 3D cube: TOP chess + 4 sides SMPTE (procedural textures, rotate with cube)
// Target : Xilinx Spartan-6 XC6SLX150
// Tool   : Xilinx ISE 14.7
// HDL    : Verilog-2001
//
// BRAM mode: outputs ONLY
//   output reg WR
//   output reg [18:0] WrAddr
//   output reg [31:0] WrData
//
// Pixel format: RGB8880 = 0xRRGGBB00
// Addressing  : 1 pixel per 32-bit word, linear (WrAddr increments sequentially)
//              WrAddr = y*FRAME_W + x
//
// Pacing:
//   - WR asserted for WR_HOLD_CLKS cycles (address+data stable)
//   - WR low for WRITE_GAP_CLKS cycles between pixels
//
// Notes:
//   - Bottom face is intentionally BLACK (not drawn).
//   - No SDRAM/framestore ports exist in this BRAM-only build.
// ============================================================================

`timescale 1ns/1ps

module sdram_dualport_stress_writer #(
    parameter integer CLK_HZ         = 25_000_000,
    parameter integer FRAME_W        = 320,
    parameter integer FRAME_H        = 240,

    parameter integer WRITE_GAP_CLKS = 2,
    parameter integer WR_HOLD_CLKS   = 2,

    // Cube size in object space (larger => larger cube)
    parameter integer CUBE_SIZE      = 19500,

    // Projection shift (bigger => smaller on screen). For 320x240, 8 matches the 640x480 look.
    parameter integer PROJ_SHR       = 8,

    // Slight vertical squash (15/16) helps if output path makes image look taller.
    parameter integer Y_SQUASH_EN    = 0
)(
    input  wire        clk,

    output reg         WR,
    output reg [18:0]  WrAddr,
    output reg [31:0]  WrData
);

    // ----------------------------
    // Virtual texture space (keep SMPTE exactly the same as your 640x480 reference)
    // ----------------------------
    localparam integer TEX_W = 640;
    localparam integer TEX_H = 480;
    localparam integer UMAX  = TEX_W - 1; // 639
    localparam integer VMAX  = TEX_H - 1; // 479

    // ----------------------------
    // Screen center (320x240)
    // ----------------------------
    localparam integer CX0 = FRAME_W/2;       // 160
    localparam integer CY0 = (FRAME_H/2) + 6; // small bias down so TOP is clearly visible

    // Cube size (object coords)
    localparam integer Q_SIZE = CUBE_SIZE;

    // Fixed pitch tilt so TOP is visible (Q1.14)
    localparam integer C_PITCH = 15400;  // cos(~20deg)
    localparam integer S_PITCH = 5600;   // sin(~20deg)

    // Reduce edge-function magnitude so multipliers stay smaller
    localparam integer EDGE_SHR = 0;

    // One-second counter
    localparam integer ONE_SEC_CLKS = CLK_HZ;
    localparam integer FRAME_WORDS  = FRAME_W * FRAME_H;

    // ----------------------------
    // Scan/address registers
    // ----------------------------
    reg [8:0]  sx;      // 0..319
    reg [7:0]  sy;      // 0..(FRAME_H-1)
    reg [18:0] addr;    // 0..(FRAME_WORDS-1)

    // Write pacing
    reg        st_gap;      // 0 = HOLD, 1 = GAP
    reg [15:0] gap_cnt;
    reg [15:0] hold_cnt;

    // Rotation
    reg [7:0]  rot_phase;

    // FPS measurement (internal, shown on screen)
    reg [31:0] sec_cnt;
    reg [31:0] frames_this_sec;
    reg [7:0]  fps_meas;
    reg [3:0]  fps_d2, fps_d1, fps_d0;

    // ----------------------------
    // Color packer (0xRRGGBB00)
    // ----------------------------
    function [31:0] pack_rgb0;
        input [7:0] r;
        input [7:0] g;
        input [7:0] b;
        begin
            pack_rgb0 = {r,g,b,8'h00};
        end
    endfunction

    // ----------------------------
    // 8-bit to 3-digit BCD (for FPS overlay)
    // ----------------------------
    function [11:0] bin8_to_bcd3;
        input [7:0] bin;
        integer i;
        reg [19:0] sh;
        begin
            sh = 20'd0;
            sh[7:0] = bin;
            for (i = 0; i < 8; i = i + 1) begin
                if (sh[11:8]  >= 5) sh[11:8]  = sh[11:8]  + 4'd3;
                if (sh[15:12] >= 5) sh[15:12] = sh[15:12] + 4'd3;
                if (sh[19:16] >= 5) sh[19:16] = sh[19:16] + 4'd3;
                sh = sh << 1;
            end
            bin8_to_bcd3 = sh[19:8];
        end
    endfunction

    // ----------------------------
    // Simple 8x8 font (scaled 2x2 => 16x16)
    // Supported: 'F','P','S',':','0'..'9'
    // ----------------------------
    function [7:0] font8_row;
        input [7:0] ch;
        input [2:0] row;
        begin
            font8_row = 8'h00;
            case (ch)
                "F": begin
                    case (row)
                        3'd0: font8_row = 8'b11111110;
                        3'd1: font8_row = 8'b11000000;
                        3'd2: font8_row = 8'b11111100;
                        3'd3: font8_row = 8'b11000000;
                        3'd4: font8_row = 8'b11000000;
                        3'd5: font8_row = 8'b11000000;
                        3'd6: font8_row = 8'b11000000;
                        default: font8_row = 8'b00000000;
                    endcase
                end
                "P": begin
                    case (row)
                        3'd0: font8_row = 8'b11111100;
                        3'd1: font8_row = 8'b11000110;
                        3'd2: font8_row = 8'b11000110;
                        3'd3: font8_row = 8'b11111100;
                        3'd4: font8_row = 8'b11000000;
                        3'd5: font8_row = 8'b11000000;
                        3'd6: font8_row = 8'b11000000;
                        default: font8_row = 8'b00000000;
                    endcase
                end
                "S": begin
                    case (row)
                        3'd0: font8_row = 8'b01111110;
                        3'd1: font8_row = 8'b11000000;
                        3'd2: font8_row = 8'b01111100;
                        3'd3: font8_row = 8'b00000110;
                        3'd4: font8_row = 8'b11111100;
                        3'd5: font8_row = 8'b00000000;
                        3'd6: font8_row = 8'b00000000;
                        default: font8_row = 8'b00000000;
                    endcase
                end
                ":": begin
                    case (row)
                        3'd0: font8_row = 8'b00000000;
                        3'd1: font8_row = 8'b00011000;
                        3'd2: font8_row = 8'b00011000;
                        3'd3: font8_row = 8'b00000000;
                        3'd4: font8_row = 8'b00011000;
                        3'd5: font8_row = 8'b00011000;
                        3'd6: font8_row = 8'b00000000;
                        default: font8_row = 8'b00000000;
                    endcase
                end
                "0": begin
                    case (row)
                        3'd0: font8_row = 8'b01111100;
                        3'd1: font8_row = 8'b11000110;
                        3'd2: font8_row = 8'b11001110;
                        3'd3: font8_row = 8'b11010110;
                        3'd4: font8_row = 8'b11100110;
                        3'd5: font8_row = 8'b11000110;
                        3'd6: font8_row = 8'b01111100;
                        default: font8_row = 8'b00000000;
                    endcase
                end
                "1": begin
                    case (row)
                        3'd0: font8_row = 8'b00011000;
                        3'd1: font8_row = 8'b00111000;
                        3'd2: font8_row = 8'b00011000;
                        3'd3: font8_row = 8'b00011000;
                        3'd4: font8_row = 8'b00011000;
                        3'd5: font8_row = 8'b00011000;
                        3'd6: font8_row = 8'b01111110;
                        default: font8_row = 8'b00000000;
                    endcase
                end
                "2": begin
                    case (row)
                        3'd0: font8_row = 8'b01111100;
                        3'd1: font8_row = 8'b11000110;
                        3'd2: font8_row = 8'b00000110;
                        3'd3: font8_row = 8'b00011100;
                        3'd4: font8_row = 8'b01110000;
                        3'd5: font8_row = 8'b11000000;
                        3'd6: font8_row = 8'b11111110;
                        default: font8_row = 8'b00000000;
                    endcase
                end
                "3": begin
                    case (row)
                        3'd0: font8_row = 8'b01111100;
                        3'd1: font8_row = 8'b11000110;
                        3'd2: font8_row = 8'b00000110;
                        3'd3: font8_row = 8'b00111100;
                        3'd4: font8_row = 8'b00000110;
                        3'd5: font8_row = 8'b11000110;
                        3'd6: font8_row = 8'b01111100;
                        default: font8_row = 8'b00000000;
                    endcase
                end
                "4": begin
                    case (row)
                        3'd0: font8_row = 8'b00001100;
                        3'd1: font8_row = 8'b00011100;
                        3'd2: font8_row = 8'b00101100;
                        3'd3: font8_row = 8'b01001100;
                        3'd4: font8_row = 8'b11111110;
                        3'd5: font8_row = 8'b00001100;
                        3'd6: font8_row = 8'b00001100;
                        default: font8_row = 8'b00000000;
                    endcase
                end
                "5": begin
                    case (row)
                        3'd0: font8_row = 8'b11111110;
                        3'd1: font8_row = 8'b11000000;
                        3'd2: font8_row = 8'b11111100;
                        3'd3: font8_row = 8'b00000110;
                        3'd4: font8_row = 8'b00000110;
                        3'd5: font8_row = 8'b11000110;
                        3'd6: font8_row = 8'b01111100;
                        default: font8_row = 8'b00000000;
                    endcase
                end
                "6": begin
                    case (row)
                        3'd0: font8_row = 8'b00111100;
                        3'd1: font8_row = 8'b01100000;
                        3'd2: font8_row = 8'b11000000;
                        3'd3: font8_row = 8'b11111100;
                        3'd4: font8_row = 8'b11000110;
                        3'd5: font8_row = 8'b11000110;
                        3'd6: font8_row = 8'b01111100;
                        default: font8_row = 8'b00000000;
                    endcase
                end
                "7": begin
                    case (row)
                        3'd0: font8_row = 8'b11111110;
                        3'd1: font8_row = 8'b00000110;
                        3'd2: font8_row = 8'b00001100;
                        3'd3: font8_row = 8'b00011000;
                        3'd4: font8_row = 8'b00110000;
                        3'd5: font8_row = 8'b01100000;
                        3'd6: font8_row = 8'b01100000;
                        default: font8_row = 8'b00000000;
                    endcase
                end
                "8": begin
                    case (row)
                        3'd0: font8_row = 8'b01111100;
                        3'd1: font8_row = 8'b11000110;
                        3'd2: font8_row = 8'b11000110;
                        3'd3: font8_row = 8'b01111100;
                        3'd4: font8_row = 8'b11000110;
                        3'd5: font8_row = 8'b11000110;
                        3'd6: font8_row = 8'b01111100;
                        default: font8_row = 8'b00000000;
                    endcase
                end
                "9": begin
                    case (row)
                        3'd0: font8_row = 8'b01111100;
                        3'd1: font8_row = 8'b11000110;
                        3'd2: font8_row = 8'b11000110;
                        3'd3: font8_row = 8'b01111110;
                        3'd4: font8_row = 8'b00000110;
                        3'd5: font8_row = 8'b00001100;
                        3'd6: font8_row = 8'b01111000;
                        default: font8_row = 8'b00000000;
                    endcase
                end
                default: font8_row = 8'h00;
            endcase
        end
    endfunction

    // Overlay "FPS:ddd" (white) at top-middle, 16x16 font
    function [31:0] overlay_fps;
        input [31:0] base;
        input [8:0]  x;
        input [7:0]  y;
        input [3:0]  d2;
        input [3:0]  d1;
        input [3:0]  d0;
        reg [9:0] xo;
        reg [9:0] yo;
        reg [3:0] char_i;
        reg [3:0] col16;
        reg [3:0] row16;
        reg [7:0] ch;
        reg [7:0] bits8;
        reg       bit_on;
        reg [2:0] row8;
        reg [2:0] col8;
        begin
            xo = (FRAME_W >> 1) - 10'd56; // 112px total
            yo = 10'd0;

            overlay_fps = base;

            if (({1'b0,x} >= xo) && ({1'b0,x} < (xo + 10'd112)) && ({2'b00,y} >= yo) && ({2'b00,y} < (yo + 10'd16))) begin
                char_i = ({1'b0,x} - xo) >> 4;   // 0..6
                col16  = ({1'b0,x} - xo) & 4'hF; // 0..15
                row16  = ({2'b00,y} - yo) & 4'hF;

                ch = 8'd32;
                case (char_i)
                    4'd0: ch = "F";
                    4'd1: ch = "P";
                    4'd2: ch = "S";
                    4'd3: ch = ":";
                    4'd4: ch = (d2 <= 4'd9) ? (8'd48 + d2) : 8'd48;
                    4'd5: ch = (d1 <= 4'd9) ? (8'd48 + d1) : 8'd48;
                    default: ch = (d0 <= 4'd9) ? (8'd48 + d0) : 8'd48;
                endcase

                row8  = row16[3:1];
                col8  = col16[3:1];
                bits8 = font8_row(ch, row8);

                bit_on = bits8[7 - col8];
                if (bit_on) overlay_fps = pack_rgb0(8'hFF,8'hFF,8'hFF);
            end
        end
    endfunction

    // ----------------------------
    // Fixed-point multiply: coord * trig(Q1.14) => coord
    // Uses 18x18 signed multiply to map to DSP48
    // ----------------------------
    function integer mul_q;
        input integer a;
        input integer b; // Q1.14
        reg signed [17:0] aa;
        reg signed [17:0] bb;
        reg signed [35:0] pp;
        begin
            aa = a[17:0];
            bb = b[17:0];
            pp = aa * bb;
            mul_q = (pp >>> 14);
        end
    endfunction

    // ----------------------------
    // 256-step yaw LUT (Q1.14) (same structure as your V5)
    // ----------------------------
    function [15:0] yaw_cos;
        input [7:0] idx;
        begin
            case (idx)
                8'd0: yaw_cos = 16'sd16384;
                8'd1: yaw_cos = 16'sd16379;
                8'd2: yaw_cos = 16'sd16364;
                8'd3: yaw_cos = 16'sd16340;
                8'd4: yaw_cos = 16'sd16305;
                8'd5: yaw_cos = 16'sd16261;
                8'd6: yaw_cos = 16'sd16207;
                8'd7: yaw_cos = 16'sd16143;
                8'd8: yaw_cos = 16'sd16069;
                8'd9: yaw_cos = 16'sd15986;
                8'd10: yaw_cos = 16'sd15893;
                8'd11: yaw_cos = 16'sd15791;
                8'd12: yaw_cos = 16'sd15679;
                8'd13: yaw_cos = 16'sd15557;
                8'd14: yaw_cos = 16'sd15426;
                8'd15: yaw_cos = 16'sd15286;
                8'd16: yaw_cos = 16'sd15137;
                8'd17: yaw_cos = 16'sd14978;
                8'd18: yaw_cos = 16'sd14811;
                8'd19: yaw_cos = 16'sd14635;
                8'd20: yaw_cos = 16'sd14449;
                8'd21: yaw_cos = 16'sd14256;
                8'd22: yaw_cos = 16'sd14053;
                8'd23: yaw_cos = 16'sd13842;
                8'd24: yaw_cos = 16'sd13623;
                8'd25: yaw_cos = 16'sd13395;
                8'd26: yaw_cos = 16'sd13160;
                8'd27: yaw_cos = 16'sd12916;
                8'd28: yaw_cos = 16'sd12665;
                8'd29: yaw_cos = 16'sd12406;
                8'd30: yaw_cos = 16'sd12140;
                8'd31: yaw_cos = 16'sd11866;
                8'd32: yaw_cos = 16'sd11585;
                8'd33: yaw_cos = 16'sd11297;
                8'd34: yaw_cos = 16'sd11003;
                8'd35: yaw_cos = 16'sd10702;
                8'd36: yaw_cos = 16'sd10394;
                8'd37: yaw_cos = 16'sd10080;
                8'd38: yaw_cos = 16'sd9760;
                8'd39: yaw_cos = 16'sd9434;
                8'd40: yaw_cos = 16'sd9102;
                8'd41: yaw_cos = 16'sd8765;
                8'd42: yaw_cos = 16'sd8423;
                8'd43: yaw_cos = 16'sd8076;
                8'd44: yaw_cos = 16'sd7723;
                8'd45: yaw_cos = 16'sd7366;
                8'd46: yaw_cos = 16'sd7005;
                8'd47: yaw_cos = 16'sd6639;
                8'd48: yaw_cos = 16'sd6270;
                8'd49: yaw_cos = 16'sd5897;
                8'd50: yaw_cos = 16'sd5520;
                8'd51: yaw_cos = 16'sd5139;
                8'd52: yaw_cos = 16'sd4756;
                8'd53: yaw_cos = 16'sd4370;
                8'd54: yaw_cos = 16'sd3981;
                8'd55: yaw_cos = 16'sd3590;
                8'd56: yaw_cos = 16'sd3196;
                8'd57: yaw_cos = 16'sd2801;
                8'd58: yaw_cos = 16'sd2404;
                8'd59: yaw_cos = 16'sd2006;
                8'd60: yaw_cos = 16'sd1606;
                8'd61: yaw_cos = 16'sd1205;
                8'd62: yaw_cos = 16'sd804;
                8'd63: yaw_cos = 16'sd402;
                8'd64: yaw_cos = 16'sd0;
                8'd65: yaw_cos = -16'sd402;
                8'd66: yaw_cos = -16'sd804;
                8'd67: yaw_cos = -16'sd1205;
                8'd68: yaw_cos = -16'sd1606;
                8'd69: yaw_cos = -16'sd2006;
                8'd70: yaw_cos = -16'sd2404;
                8'd71: yaw_cos = -16'sd2801;
                8'd72: yaw_cos = -16'sd3196;
                8'd73: yaw_cos = -16'sd3590;
                8'd74: yaw_cos = -16'sd3981;
                8'd75: yaw_cos = -16'sd4370;
                8'd76: yaw_cos = -16'sd4756;
                8'd77: yaw_cos = -16'sd5139;
                8'd78: yaw_cos = -16'sd5520;
                8'd79: yaw_cos = -16'sd5897;
                8'd80: yaw_cos = -16'sd6270;
                8'd81: yaw_cos = -16'sd6639;
                8'd82: yaw_cos = -16'sd7005;
                8'd83: yaw_cos = -16'sd7366;
                8'd84: yaw_cos = -16'sd7723;
                8'd85: yaw_cos = -16'sd8076;
                8'd86: yaw_cos = -16'sd8423;
                8'd87: yaw_cos = -16'sd8765;
                8'd88: yaw_cos = -16'sd9102;
                8'd89: yaw_cos = -16'sd9434;
                8'd90: yaw_cos = -16'sd9760;
                8'd91: yaw_cos = -16'sd10080;
                8'd92: yaw_cos = -16'sd10394;
                8'd93: yaw_cos = -16'sd10702;
                8'd94: yaw_cos = -16'sd11003;
                8'd95: yaw_cos = -16'sd11297;
                8'd96: yaw_cos = -16'sd11585;
                8'd97: yaw_cos = -16'sd11866;
                8'd98: yaw_cos = -16'sd12140;
                8'd99: yaw_cos = -16'sd12406;
                8'd100: yaw_cos = -16'sd12665;
                8'd101: yaw_cos = -16'sd12916;
                8'd102: yaw_cos = -16'sd13160;
                8'd103: yaw_cos = -16'sd13395;
                8'd104: yaw_cos = -16'sd13623;
                8'd105: yaw_cos = -16'sd13842;
                8'd106: yaw_cos = -16'sd14053;
                8'd107: yaw_cos = -16'sd14256;
                8'd108: yaw_cos = -16'sd14449;
                8'd109: yaw_cos = -16'sd14635;
                8'd110: yaw_cos = -16'sd14811;
                8'd111: yaw_cos = -16'sd14978;
                8'd112: yaw_cos = -16'sd15137;
                8'd113: yaw_cos = -16'sd15286;
                8'd114: yaw_cos = -16'sd15426;
                8'd115: yaw_cos = -16'sd15557;
                8'd116: yaw_cos = -16'sd15679;
                8'd117: yaw_cos = -16'sd15791;
                8'd118: yaw_cos = -16'sd15893;
                8'd119: yaw_cos = -16'sd15986;
                8'd120: yaw_cos = -16'sd16069;
                8'd121: yaw_cos = -16'sd16143;
                8'd122: yaw_cos = -16'sd16207;
                8'd123: yaw_cos = -16'sd16261;
                8'd124: yaw_cos = -16'sd16305;
                8'd125: yaw_cos = -16'sd16340;
                8'd126: yaw_cos = -16'sd16364;
                8'd127: yaw_cos = -16'sd16379;
                8'd128: yaw_cos = -16'sd16384;
                8'd129: yaw_cos = -16'sd16379;
                8'd130: yaw_cos = -16'sd16364;
                8'd131: yaw_cos = -16'sd16340;
                8'd132: yaw_cos = -16'sd16305;
                8'd133: yaw_cos = -16'sd16261;
                8'd134: yaw_cos = -16'sd16207;
                8'd135: yaw_cos = -16'sd16143;
                8'd136: yaw_cos = -16'sd16069;
                8'd137: yaw_cos = -16'sd15986;
                8'd138: yaw_cos = -16'sd15893;
                8'd139: yaw_cos = -16'sd15791;
                8'd140: yaw_cos = -16'sd15679;
                8'd141: yaw_cos = -16'sd15557;
                8'd142: yaw_cos = -16'sd15426;
                8'd143: yaw_cos = -16'sd15286;
                8'd144: yaw_cos = -16'sd15137;
                8'd145: yaw_cos = -16'sd14978;
                8'd146: yaw_cos = -16'sd14811;
                8'd147: yaw_cos = -16'sd14635;
                8'd148: yaw_cos = -16'sd14449;
                8'd149: yaw_cos = -16'sd14256;
                8'd150: yaw_cos = -16'sd14053;
                8'd151: yaw_cos = -16'sd13842;
                8'd152: yaw_cos = -16'sd13623;
                8'd153: yaw_cos = -16'sd13395;
                8'd154: yaw_cos = -16'sd13160;
                8'd155: yaw_cos = -16'sd12916;
                8'd156: yaw_cos = -16'sd12665;
                8'd157: yaw_cos = -16'sd12406;
                8'd158: yaw_cos = -16'sd12140;
                8'd159: yaw_cos = -16'sd11866;
                8'd160: yaw_cos = -16'sd11585;
                8'd161: yaw_cos = -16'sd11297;
                8'd162: yaw_cos = -16'sd11003;
                8'd163: yaw_cos = -16'sd10702;
                8'd164: yaw_cos = -16'sd10394;
                8'd165: yaw_cos = -16'sd10080;
                8'd166: yaw_cos = -16'sd9760;
                8'd167: yaw_cos = -16'sd9434;
                8'd168: yaw_cos = -16'sd9102;
                8'd169: yaw_cos = -16'sd8765;
                8'd170: yaw_cos = -16'sd8423;
                8'd171: yaw_cos = -16'sd8076;
                8'd172: yaw_cos = -16'sd7723;
                8'd173: yaw_cos = -16'sd7366;
                8'd174: yaw_cos = -16'sd7005;
                8'd175: yaw_cos = -16'sd6639;
                8'd176: yaw_cos = -16'sd6270;
                8'd177: yaw_cos = -16'sd5897;
                8'd178: yaw_cos = -16'sd5520;
                8'd179: yaw_cos = -16'sd5139;
                8'd180: yaw_cos = -16'sd4756;
                8'd181: yaw_cos = -16'sd4370;
                8'd182: yaw_cos = -16'sd3981;
                8'd183: yaw_cos = -16'sd3590;
                8'd184: yaw_cos = -16'sd3196;
                8'd185: yaw_cos = -16'sd2801;
                8'd186: yaw_cos = -16'sd2404;
                8'd187: yaw_cos = -16'sd2006;
                8'd188: yaw_cos = -16'sd1606;
                8'd189: yaw_cos = -16'sd1205;
                8'd190: yaw_cos = -16'sd804;
                8'd191: yaw_cos = -16'sd402;
                8'd192: yaw_cos = 16'sd0;
                8'd193: yaw_cos = 16'sd402;
                8'd194: yaw_cos = 16'sd804;
                8'd195: yaw_cos = 16'sd1205;
                8'd196: yaw_cos = 16'sd1606;
                8'd197: yaw_cos = 16'sd2006;
                8'd198: yaw_cos = 16'sd2404;
                8'd199: yaw_cos = 16'sd2801;
                8'd200: yaw_cos = 16'sd3196;
                8'd201: yaw_cos = 16'sd3590;
                8'd202: yaw_cos = 16'sd3981;
                8'd203: yaw_cos = 16'sd4370;
                8'd204: yaw_cos = 16'sd4756;
                8'd205: yaw_cos = 16'sd5139;
                8'd206: yaw_cos = 16'sd5520;
                8'd207: yaw_cos = 16'sd5897;
                8'd208: yaw_cos = 16'sd6270;
                8'd209: yaw_cos = 16'sd6639;
                8'd210: yaw_cos = 16'sd7005;
                8'd211: yaw_cos = 16'sd7366;
                8'd212: yaw_cos = 16'sd7723;
                8'd213: yaw_cos = 16'sd8076;
                8'd214: yaw_cos = 16'sd8423;
                8'd215: yaw_cos = 16'sd8765;
                8'd216: yaw_cos = 16'sd9102;
                8'd217: yaw_cos = 16'sd9434;
                8'd218: yaw_cos = 16'sd9760;
                8'd219: yaw_cos = 16'sd10080;
                8'd220: yaw_cos = 16'sd10394;
                8'd221: yaw_cos = 16'sd10702;
                8'd222: yaw_cos = 16'sd11003;
                8'd223: yaw_cos = 16'sd11297;
                8'd224: yaw_cos = 16'sd11585;
                8'd225: yaw_cos = 16'sd11866;
                8'd226: yaw_cos = 16'sd12140;
                8'd227: yaw_cos = 16'sd12406;
                8'd228: yaw_cos = 16'sd12665;
                8'd229: yaw_cos = 16'sd12916;
                8'd230: yaw_cos = 16'sd13160;
                8'd231: yaw_cos = 16'sd13395;
                8'd232: yaw_cos = 16'sd13623;
                8'd233: yaw_cos = 16'sd13842;
                8'd234: yaw_cos = 16'sd14053;
                8'd235: yaw_cos = 16'sd14256;
                8'd236: yaw_cos = 16'sd14449;
                8'd237: yaw_cos = 16'sd14635;
                8'd238: yaw_cos = 16'sd14811;
                8'd239: yaw_cos = 16'sd14978;
                8'd240: yaw_cos = 16'sd15137;
                8'd241: yaw_cos = 16'sd15286;
                8'd242: yaw_cos = 16'sd15426;
                8'd243: yaw_cos = 16'sd15557;
                8'd244: yaw_cos = 16'sd15679;
                8'd245: yaw_cos = 16'sd15791;
                8'd246: yaw_cos = 16'sd15893;
                8'd247: yaw_cos = 16'sd15986;
                8'd248: yaw_cos = 16'sd16069;
                8'd249: yaw_cos = 16'sd16143;
                8'd250: yaw_cos = 16'sd16207;
                8'd251: yaw_cos = 16'sd16261;
                8'd252: yaw_cos = 16'sd16305;
                8'd253: yaw_cos = 16'sd16340;
                8'd254: yaw_cos = 16'sd16364;
                8'd255: yaw_cos = 16'sd16379;
                default: yaw_cos = 16'sd16384;
            endcase
        end
    endfunction

    function [15:0] yaw_sin;
        input [7:0] idx;
        begin
            case (idx)
                8'd0: yaw_sin = 16'sd0;
                8'd1: yaw_sin = 16'sd402;
                8'd2: yaw_sin = 16'sd804;
                8'd3: yaw_sin = 16'sd1205;
                8'd4: yaw_sin = 16'sd1606;
                8'd5: yaw_sin = 16'sd2006;
                8'd6: yaw_sin = 16'sd2404;
                8'd7: yaw_sin = 16'sd2801;
                8'd8: yaw_sin = 16'sd3196;
                8'd9: yaw_sin = 16'sd3590;
                8'd10: yaw_sin = 16'sd3981;
                8'd11: yaw_sin = 16'sd4370;
                8'd12: yaw_sin = 16'sd4756;
                8'd13: yaw_sin = 16'sd5139;
                8'd14: yaw_sin = 16'sd5520;
                8'd15: yaw_sin = 16'sd5897;
                8'd16: yaw_sin = 16'sd6270;
                8'd17: yaw_sin = 16'sd6639;
                8'd18: yaw_sin = 16'sd7005;
                8'd19: yaw_sin = 16'sd7366;
                8'd20: yaw_sin = 16'sd7723;
                8'd21: yaw_sin = 16'sd8076;
                8'd22: yaw_sin = 16'sd8423;
                8'd23: yaw_sin = 16'sd8765;
                8'd24: yaw_sin = 16'sd9102;
                8'd25: yaw_sin = 16'sd9434;
                8'd26: yaw_sin = 16'sd9760;
                8'd27: yaw_sin = 16'sd10080;
                8'd28: yaw_sin = 16'sd10394;
                8'd29: yaw_sin = 16'sd10702;
                8'd30: yaw_sin = 16'sd11003;
                8'd31: yaw_sin = 16'sd11297;
                8'd32: yaw_sin = 16'sd11585;
                8'd33: yaw_sin = 16'sd11866;
                8'd34: yaw_sin = 16'sd12140;
                8'd35: yaw_sin = 16'sd12406;
                8'd36: yaw_sin = 16'sd12665;
                8'd37: yaw_sin = 16'sd12916;
                8'd38: yaw_sin = 16'sd13160;
                8'd39: yaw_sin = 16'sd13395;
                8'd40: yaw_sin = 16'sd13623;
                8'd41: yaw_sin = 16'sd13842;
                8'd42: yaw_sin = 16'sd14053;
                8'd43: yaw_sin = 16'sd14256;
                8'd44: yaw_sin = 16'sd14449;
                8'd45: yaw_sin = 16'sd14635;
                8'd46: yaw_sin = 16'sd14811;
                8'd47: yaw_sin = 16'sd14978;
                8'd48: yaw_sin = 16'sd15137;
                8'd49: yaw_sin = 16'sd15286;
                8'd50: yaw_sin = 16'sd15426;
                8'd51: yaw_sin = 16'sd15557;
                8'd52: yaw_sin = 16'sd15679;
                8'd53: yaw_sin = 16'sd15791;
                8'd54: yaw_sin = 16'sd15893;
                8'd55: yaw_sin = 16'sd15986;
                8'd56: yaw_sin = 16'sd16069;
                8'd57: yaw_sin = 16'sd16143;
                8'd58: yaw_sin = 16'sd16207;
                8'd59: yaw_sin = 16'sd16261;
                8'd60: yaw_sin = 16'sd16305;
                8'd61: yaw_sin = 16'sd16340;
                8'd62: yaw_sin = 16'sd16364;
                8'd63: yaw_sin = 16'sd16379;
                8'd64: yaw_sin = 16'sd16384;
                8'd65: yaw_sin = 16'sd16379;
                8'd66: yaw_sin = 16'sd16364;
                8'd67: yaw_sin = 16'sd16340;
                8'd68: yaw_sin = 16'sd16305;
                8'd69: yaw_sin = 16'sd16261;
                8'd70: yaw_sin = 16'sd16207;
                8'd71: yaw_sin = 16'sd16143;
                8'd72: yaw_sin = 16'sd16069;
                8'd73: yaw_sin = 16'sd15986;
                8'd74: yaw_sin = 16'sd15893;
                8'd75: yaw_sin = 16'sd15791;
                8'd76: yaw_sin = 16'sd15679;
                8'd77: yaw_sin = 16'sd15557;
                8'd78: yaw_sin = 16'sd15426;
                8'd79: yaw_sin = 16'sd15286;
                8'd80: yaw_sin = 16'sd15137;
                8'd81: yaw_sin = 16'sd14978;
                8'd82: yaw_sin = 16'sd14811;
                8'd83: yaw_sin = 16'sd14635;
                8'd84: yaw_sin = 16'sd14449;
                8'd85: yaw_sin = 16'sd14256;
                8'd86: yaw_sin = 16'sd14053;
                8'd87: yaw_sin = 16'sd13842;
                8'd88: yaw_sin = 16'sd13623;
                8'd89: yaw_sin = 16'sd13395;
                8'd90: yaw_sin = 16'sd13160;
                8'd91: yaw_sin = 16'sd12916;
                8'd92: yaw_sin = 16'sd12665;
                8'd93: yaw_sin = 16'sd12406;
                8'd94: yaw_sin = 16'sd12140;
                8'd95: yaw_sin = 16'sd11866;
                8'd96: yaw_sin = 16'sd11585;
                8'd97: yaw_sin = 16'sd11297;
                8'd98: yaw_sin = 16'sd11003;
                8'd99: yaw_sin = 16'sd10702;
                8'd100: yaw_sin = 16'sd10394;
                8'd101: yaw_sin = 16'sd10080;
                8'd102: yaw_sin = 16'sd9760;
                8'd103: yaw_sin = 16'sd9434;
                8'd104: yaw_sin = 16'sd9102;
                8'd105: yaw_sin = 16'sd8765;
                8'd106: yaw_sin = 16'sd8423;
                8'd107: yaw_sin = 16'sd8076;
                8'd108: yaw_sin = 16'sd7723;
                8'd109: yaw_sin = 16'sd7366;
                8'd110: yaw_sin = 16'sd7005;
                8'd111: yaw_sin = 16'sd6639;
                8'd112: yaw_sin = 16'sd6270;
                8'd113: yaw_sin = 16'sd5897;
                8'd114: yaw_sin = 16'sd5520;
                8'd115: yaw_sin = 16'sd5139;
                8'd116: yaw_sin = 16'sd4756;
                8'd117: yaw_sin = 16'sd4370;
                8'd118: yaw_sin = 16'sd3981;
                8'd119: yaw_sin = 16'sd3590;
                8'd120: yaw_sin = 16'sd3196;
                8'd121: yaw_sin = 16'sd2801;
                8'd122: yaw_sin = 16'sd2404;
                8'd123: yaw_sin = 16'sd2006;
                8'd124: yaw_sin = 16'sd1606;
                8'd125: yaw_sin = 16'sd1205;
                8'd126: yaw_sin = 16'sd804;
                8'd127: yaw_sin = 16'sd402;
                8'd128: yaw_sin = 16'sd0;
                8'd129: yaw_sin = -16'sd402;
                8'd130: yaw_sin = -16'sd804;
                8'd131: yaw_sin = -16'sd1205;
                8'd132: yaw_sin = -16'sd1606;
                8'd133: yaw_sin = -16'sd2006;
                8'd134: yaw_sin = -16'sd2404;
                8'd135: yaw_sin = -16'sd2801;
                8'd136: yaw_sin = -16'sd3196;
                8'd137: yaw_sin = -16'sd3590;
                8'd138: yaw_sin = -16'sd3981;
                8'd139: yaw_sin = -16'sd4370;
                8'd140: yaw_sin = -16'sd4756;
                8'd141: yaw_sin = -16'sd5139;
                8'd142: yaw_sin = -16'sd5520;
                8'd143: yaw_sin = -16'sd5897;
                8'd144: yaw_sin = -16'sd6270;
                8'd145: yaw_sin = -16'sd6639;
                8'd146: yaw_sin = -16'sd7005;
                8'd147: yaw_sin = -16'sd7366;
                8'd148: yaw_sin = -16'sd7723;
                8'd149: yaw_sin = -16'sd8076;
                8'd150: yaw_sin = -16'sd8423;
                8'd151: yaw_sin = -16'sd8765;
                8'd152: yaw_sin = -16'sd9102;
                8'd153: yaw_sin = -16'sd9434;
                8'd154: yaw_sin = -16'sd9760;
                8'd155: yaw_sin = -16'sd10080;
                8'd156: yaw_sin = -16'sd10394;
                8'd157: yaw_sin = -16'sd10702;
                8'd158: yaw_sin = -16'sd11003;
                8'd159: yaw_sin = -16'sd11297;
                8'd160: yaw_sin = -16'sd11585;
                8'd161: yaw_sin = -16'sd11866;
                8'd162: yaw_sin = -16'sd12140;
                8'd163: yaw_sin = -16'sd12406;
                8'd164: yaw_sin = -16'sd12665;
                8'd165: yaw_sin = -16'sd12916;
                8'd166: yaw_sin = -16'sd13160;
                8'd167: yaw_sin = -16'sd13395;
                8'd168: yaw_sin = -16'sd13623;
                8'd169: yaw_sin = -16'sd13842;
                8'd170: yaw_sin = -16'sd14053;
                8'd171: yaw_sin = -16'sd14256;
                8'd172: yaw_sin = -16'sd14449;
                8'd173: yaw_sin = -16'sd14635;
                8'd174: yaw_sin = -16'sd14811;
                8'd175: yaw_sin = -16'sd14978;
                8'd176: yaw_sin = -16'sd15137;
                8'd177: yaw_sin = -16'sd15286;
                8'd178: yaw_sin = -16'sd15426;
                8'd179: yaw_sin = -16'sd15557;
                8'd180: yaw_sin = -16'sd15679;
                8'd181: yaw_sin = -16'sd15791;
                8'd182: yaw_sin = -16'sd15893;
                8'd183: yaw_sin = -16'sd15986;
                8'd184: yaw_sin = -16'sd16069;
                8'd185: yaw_sin = -16'sd16143;
                8'd186: yaw_sin = -16'sd16207;
                8'd187: yaw_sin = -16'sd16261;
                8'd188: yaw_sin = -16'sd16305;
                8'd189: yaw_sin = -16'sd16340;
                8'd190: yaw_sin = -16'sd16364;
                8'd191: yaw_sin = -16'sd16379;
                8'd192: yaw_sin = -16'sd16384;
                8'd193: yaw_sin = -16'sd16379;
                8'd194: yaw_sin = -16'sd16364;
                8'd195: yaw_sin = -16'sd16340;
                8'd196: yaw_sin = -16'sd16305;
                8'd197: yaw_sin = -16'sd16261;
                8'd198: yaw_sin = -16'sd16207;
                8'd199: yaw_sin = -16'sd16143;
                8'd200: yaw_sin = -16'sd16069;
                8'd201: yaw_sin = -16'sd15986;
                8'd202: yaw_sin = -16'sd15893;
                8'd203: yaw_sin = -16'sd15791;
                8'd204: yaw_sin = -16'sd15679;
                8'd205: yaw_sin = -16'sd15557;
                8'd206: yaw_sin = -16'sd15426;
                8'd207: yaw_sin = -16'sd15286;
                8'd208: yaw_sin = -16'sd15137;
                8'd209: yaw_sin = -16'sd14978;
                8'd210: yaw_sin = -16'sd14811;
                8'd211: yaw_sin = -16'sd14635;
                8'd212: yaw_sin = -16'sd14449;
                8'd213: yaw_sin = -16'sd14256;
                8'd214: yaw_sin = -16'sd14053;
                8'd215: yaw_sin = -16'sd13842;
                8'd216: yaw_sin = -16'sd13623;
                8'd217: yaw_sin = -16'sd13395;
                8'd218: yaw_sin = -16'sd13160;
                8'd219: yaw_sin = -16'sd12916;
                8'd220: yaw_sin = -16'sd12665;
                8'd221: yaw_sin = -16'sd12406;
                8'd222: yaw_sin = -16'sd12140;
                8'd223: yaw_sin = -16'sd11866;
                8'd224: yaw_sin = -16'sd11585;
                8'd225: yaw_sin = -16'sd11297;
                8'd226: yaw_sin = -16'sd11003;
                8'd227: yaw_sin = -16'sd10702;
                8'd228: yaw_sin = -16'sd10394;
                8'd229: yaw_sin = -16'sd10080;
                8'd230: yaw_sin = -16'sd9760;
                8'd231: yaw_sin = -16'sd9434;
                8'd232: yaw_sin = -16'sd9102;
                8'd233: yaw_sin = -16'sd8765;
                8'd234: yaw_sin = -16'sd8423;
                8'd235: yaw_sin = -16'sd8076;
                8'd236: yaw_sin = -16'sd7723;
                8'd237: yaw_sin = -16'sd7366;
                8'd238: yaw_sin = -16'sd7005;
                8'd239: yaw_sin = -16'sd6639;
                8'd240: yaw_sin = -16'sd6270;
                8'd241: yaw_sin = -16'sd5897;
                8'd242: yaw_sin = -16'sd5520;
                8'd243: yaw_sin = -16'sd5139;
                8'd244: yaw_sin = -16'sd4756;
                8'd245: yaw_sin = -16'sd4370;
                8'd246: yaw_sin = -16'sd3981;
                8'd247: yaw_sin = -16'sd3590;
                8'd248: yaw_sin = -16'sd3196;
                8'd249: yaw_sin = -16'sd2801;
                8'd250: yaw_sin = -16'sd2404;
                8'd251: yaw_sin = -16'sd2006;
                8'd252: yaw_sin = -16'sd1606;
                8'd253: yaw_sin = -16'sd1205;
                8'd254: yaw_sin = -16'sd804;
                8'd255: yaw_sin = -16'sd402;
                default: yaw_sin = 16'sd0;
            endcase
        end
    endfunction

    wire [15:0] c_yaw_w = yaw_cos(rot_phase);
    wire [15:0] s_yaw_w = yaw_sin(rot_phase);

    wire signed [31:0] c_yaw_i = {{16{c_yaw_w[15]}}, c_yaw_w};
    wire signed [31:0] s_yaw_i = {{16{s_yaw_w[15]}}, s_yaw_w};

    // ----------------------------
    // Cube base vertices
    // 0(-x,-y,-z) 1(+x,-y,-z) 2(-x,+y,-z) 3(+x,+y,-z)
    // 4(-x,-y,+z) 5(+x,-y,+z) 6(-x,+y,+z) 7(+x,+y,+z)
    // ----------------------------
    function integer vtx_x;
        input [2:0] vid;
        begin
            case (vid)
                3'd0: vtx_x = -Q_SIZE;
                3'd1: vtx_x =  Q_SIZE;
                3'd2: vtx_x = -Q_SIZE;
                3'd3: vtx_x =  Q_SIZE;
                3'd4: vtx_x = -Q_SIZE;
                3'd5: vtx_x =  Q_SIZE;
                3'd6: vtx_x = -Q_SIZE;
                default: vtx_x =  Q_SIZE;
            endcase
        end
    endfunction

    function integer vtx_y;
        input [2:0] vid;
        begin
            case (vid)
                3'd0: vtx_y = -Q_SIZE;
                3'd1: vtx_y = -Q_SIZE;
                3'd2: vtx_y =  Q_SIZE;
                3'd3: vtx_y =  Q_SIZE;
                3'd4: vtx_y = -Q_SIZE;
                3'd5: vtx_y = -Q_SIZE;
                3'd6: vtx_y =  Q_SIZE;
                default: vtx_y =  Q_SIZE;
            endcase
        end
    endfunction

    function integer vtx_z;
        input [2:0] vid;
        begin
            case (vid)
                3'd0: vtx_z = -Q_SIZE;
                3'd1: vtx_z = -Q_SIZE;
                3'd2: vtx_z = -Q_SIZE;
                3'd3: vtx_z = -Q_SIZE;
                3'd4: vtx_z =  Q_SIZE;
                3'd5: vtx_z =  Q_SIZE;
                3'd6: vtx_z =  Q_SIZE;
                default: vtx_z =  Q_SIZE;
            endcase
        end
    endfunction

    // Rotate: yaw around Y, then fixed pitch around X
    function integer rot_x;
        input [2:0] vid;
        integer x,z;
        begin
            x = vtx_x(vid);
            z = vtx_z(vid);
            rot_x = mul_q(x, c_yaw_i) + mul_q(z, s_yaw_i);
        end
    endfunction

    function integer rot_z1;
        input [2:0] vid;
        integer x,z;
        begin
            x = vtx_x(vid);
            z = vtx_z(vid);
            rot_z1 = -mul_q(x, s_yaw_i) + mul_q(z, c_yaw_i);
        end
    endfunction

    function integer rot_y;
        input [2:0] vid;
        integer y,z1;
        begin
            y  = vtx_y(vid);
            z1 = rot_z1(vid);
            rot_y = mul_q(y, C_PITCH) - mul_q(z1, S_PITCH);
        end
    endfunction

    function integer rot_z;
        input [2:0] vid;
        integer y,z1;
        begin
            y  = vtx_y(vid);
            z1 = rot_z1(vid);
            rot_z = mul_q(y, S_PITCH) + mul_q(z1, C_PITCH);
        end
    endfunction

    // Projection (no clamp)
    function signed [11:0] proj_x;
        input integer xr;
        integer scr;
        begin
            scr = CX0 + (xr >>> PROJ_SHR);
            proj_x = scr[11:0];
        end
    endfunction

    function signed [11:0] proj_y;
        input integer yr;
        integer yy;
        integer scr;
        begin
            yy = (yr >>> PROJ_SHR);
            if (Y_SQUASH_EN != 0) begin
                // yy = yy * 15/16 = yy - (yy>>4)
                yy = yy - (yy >>> 4);
            end
            scr = CY0 - yy;
            proj_y = scr[11:0];
        end
    endfunction

    // Projected vertices
    wire signed [11:0] sX0 = proj_x(rot_x(3'd0));
    wire signed [11:0] sY0 = proj_y(rot_y(3'd0));
    wire signed [11:0] sX1 = proj_x(rot_x(3'd1));
    wire signed [11:0] sY1 = proj_y(rot_y(3'd1));
    wire signed [11:0] sX2 = proj_x(rot_x(3'd2));
    wire signed [11:0] sY2 = proj_y(rot_y(3'd2));
    wire signed [11:0] sX3 = proj_x(rot_x(3'd3));
    wire signed [11:0] sY3 = proj_y(rot_y(3'd3));
    wire signed [11:0] sX4 = proj_x(rot_x(3'd4));
    wire signed [11:0] sY4 = proj_y(rot_y(3'd4));
    wire signed [11:0] sX5 = proj_x(rot_x(3'd5));
    wire signed [11:0] sY5 = proj_y(rot_y(3'd5));
    wire signed [11:0] sX6 = proj_x(rot_x(3'd6));
    wire signed [11:0] sY6 = proj_y(rot_y(3'd6));
    wire signed [11:0] sX7 = proj_x(rot_x(3'd7));
    wire signed [11:0] sY7 = proj_y(rot_y(3'd7));

    // Depths
    wire signed [31:0] z0r = rot_z(3'd0);
    wire signed [31:0] z1r = rot_z(3'd1);
    wire signed [31:0] z2r = rot_z(3'd2);
    wire signed [31:0] z3r = rot_z(3'd3);
    wire signed [31:0] z4r = rot_z(3'd4);
    wire signed [31:0] z5r = rot_z(3'd5);
    wire signed [31:0] z6r = rot_z(3'd6);
    wire signed [31:0] z7r = rot_z(3'd7);

    wire signed [31:0] fz_pos_avg = (z4r + z5r + z6r + z7r) >>> 2; // +Z face
    wire signed [31:0] fz_neg_avg = (z0r + z1r + z2r + z3r) >>> 2; // -Z face
    wire signed [31:0] fx_pos_avg = (z1r + z3r + z5r + z7r) >>> 2; // +X face
    wire signed [31:0] fx_neg_avg = (z0r + z2r + z4r + z6r) >>> 2; // -X face

    wire sel_z_pos = (fz_pos_avg >= fz_neg_avg);
    wire sel_x_pos = (fx_pos_avg >= fx_neg_avg);

    wire signed [31:0] z_face_avg = sel_z_pos ? fz_pos_avg : fz_neg_avg;
    wire signed [31:0] x_face_avg = sel_x_pos ? fx_pos_avg : fx_neg_avg;
    wire x_is_near = (x_face_avg > z_face_avg);

    // ----------------------------
    // Edge function (signed)
    // ----------------------------
    function signed [31:0] edge_fn;
        input signed [11:0] px; input signed [11:0] py;
        input signed [11:0] ax; input signed [11:0] ay;
        input signed [11:0] bx; input signed [11:0] by;
        reg signed [12:0] dx, dy;
        reg signed [12:0] pax, pay;
        reg signed [17:0] a1,b1,a2,b2;
        reg signed [35:0] p1,p2;
        reg signed [35:0] e;
        begin
            dx  = bx - ax;
            dy  = by - ay;
            pax = px - ax;
            pay = py - ay;

            a1 = {{5{pax[12]}}, pax};
            b1 = {{5{dy[12]}},  dy};
            a2 = {{5{pay[12]}}, pay};
            b2 = {{5{dx[12]}},  dx};

            p1 = a1 * b1;
            p2 = a2 * b2;
            e  = p1 - p2;

            edge_fn = (e >>> EDGE_SHR);
        end
    endfunction

    // ----------------------------
    // Triangle UV numerator (no division)
    // Returns:
    //   hit   : inside triangle
    //   den   : positive area (scaled)
    //   u_num : u*den   (unsigned)
    //   v_num : v*den   (unsigned)
    // ----------------------------
    task tri_uv_num;
        input  [8:0]  px;
        input  [7:0]  py;
        input  signed [11:0] ax; input signed [11:0] ay;
        input  signed [11:0] bx; input signed [11:0] by;
        input  signed [11:0] cx; input signed [11:0] cy;
        input  [9:0]  au; input [9:0] av;
        input  [9:0]  bu; input [9:0] bv;
        input  [9:0]  cu; input [9:0] cv;
        output reg      hit;
        output reg [31:0] u_num;
        output reg [31:0] v_num;
        output reg [17:0] den;

        reg signed [31:0] w0l,w1l,w2l,areal;
        reg signed [31:0] tmp_abs;
        reg [17:0] w0,w1,w2,area;

        reg signed [11:0] pxs,pys;

        reg [35:0] uu;
        reg [35:0] vv;
        begin
            pxs = {3'b000, px}; // 12-bit signed, positive
            pys = {4'b0000, py};

            w0l   = edge_fn(pxs,pys, bx,by, cx,cy);
            w1l   = edge_fn(pxs,pys, cx,cy, ax,ay);
            w2l   = edge_fn(pxs,pys, ax,ay, bx,by);
            areal = edge_fn(ax,ay, bx,by, cx,cy);

            hit   = 1'b0;
            u_num = 32'd0;
            v_num = 32'd0;
            den   = 18'd1;

            if (areal == 0) begin
                hit = 1'b0;
                den = 18'd1;
                w0 = 18'd0; w1 = 18'd0; w2 = 18'd0; area = 18'd1;
            end else if (areal >= 0) begin
                area = areal[17:0];
                den  = area;
                if ((w0l >= 0) && (w1l >= 0) && (w2l >= 0)) hit = 1'b1;
                w0 = w0l[17:0];
                w1 = w1l[17:0];
                w2 = w2l[17:0];
            end else begin
                tmp_abs = -areal;
                area = tmp_abs[17:0];
                den  = area;
                if ((w0l <= 0) && (w1l <= 0) && (w2l <= 0)) begin
                    hit = 1'b1;
                    w0l = -w0l; w1l = -w1l; w2l = -w2l;
                end
                w0 = w0l[17:0];
                w1 = w1l[17:0];
                w2 = w2l[17:0];
            end

            if (hit) begin
                uu = (w0 * au) + (w1 * bu) + (w2 * cu);
                vv = (w0 * av) + (w1 * bv) + (w2 * cv);
                u_num = uu[31:0];
                v_num = vv[31:0];
            end
        end
    endtask

    // ----------------------------
    // SMPTE color bars from UV numerator (u_num = u*den, v_num = v*den)
    // Thresholds are in virtual 640x480 coordinate space.
    // ----------------------------
    function [31:0] smpte_from_uvnum;
        input [31:0] u_num;
        input [31:0] v_num;
        input [17:0] den;
        reg [7:0] r,g,b;
        reg [47:0] den_mul;
        begin
            r=8'h00; g=8'h00; b=8'h00;

            // V regions: 0..359, 360..419, 420..479
            den_mul = den * 48'd360;
            if ({16'd0,v_num} < den_mul) begin
                // Top: 7 bars. Bar edges at ~0, 91, 183, 274, 366, 457, 549, 639
                if ({16'd0,u_num} < den*48'd91)       begin r=8'hFF; g=8'hFF; b=8'hFF; end // WHITE
                else if ({16'd0,u_num} < den*48'd183) begin r=8'hFF; g=8'hFF; b=8'h00; end // YELLOW
                else if ({16'd0,u_num} < den*48'd274) begin r=8'h00; g=8'hFF; b=8'hFF; end // CYAN
                else if ({16'd0,u_num} < den*48'd366) begin r=8'h00; g=8'hFF; b=8'h00; end // GREEN
                else if ({16'd0,u_num} < den*48'd457) begin r=8'hFF; g=8'h00; b=8'hFF; end // MAGENTA
                else if ({16'd0,u_num} < den*48'd549) begin r=8'hFF; g=8'h00; b=8'h00; end // RED
                else                                  begin r=8'h00; g=8'h00; b=8'hFF; end // BLUE
            end else if ({16'd0,v_num} < (den*48'd420)) begin
                // Middle: blue/black/magenta/black/cyan/black/gray
                if ({16'd0,u_num} < den*48'd91)       begin r=8'h00; g=8'h00; b=8'hFF; end // BLUE
                else if ({16'd0,u_num} < den*48'd183) begin r=8'h00; g=8'h00; b=8'h00; end // BLACK
                else if ({16'd0,u_num} < den*48'd274) begin r=8'hFF; g=8'h00; b=8'hFF; end // MAGENTA
                else if ({16'd0,u_num} < den*48'd366) begin r=8'h00; g=8'h00; b=8'h00; end // BLACK
                else if ({16'd0,u_num} < den*48'd457) begin r=8'h00; g=8'hFF; b=8'hFF; end // CYAN
                else if ({16'd0,u_num} < den*48'd549) begin r=8'h00; g=8'h00; b=8'h00; end // BLACK
                else                                  begin r=8'h80; g=8'h80; b=8'h80; end // GRAY
            end else begin
                // Bottom region: simple dark ramp blocks
                if ({16'd0,u_num} < den*48'd213)       begin r=8'h00; g=8'h21; b=8'h5A; end
                else if ({16'd0,u_num} < den*48'd426)  begin r=8'hFF; g=8'hFF; b=8'hFF; end
                else if ({16'd0,u_num} < den*48'd533)  begin r=8'h32; g=8'h32; b=8'h32; end
                else                                   begin r=8'h00; g=8'h00; b=8'h00; end
            end

            smpte_from_uvnum = pack_rgb0(r,g,b);
        end
    endfunction

    // ----------------------------
    // Chessboard from UV numerator (top face)
    // ----------------------------
    function [31:0] chess_from_uvnum;
    input [31:0] u_num;
    input [31:0] v_num;
    input [17:0] den;
    // Stable chessboard in the same virtual 640x480 UV space as SMPTE.
    // u = u_num/den in [0..639], v = v_num/den in [0..479]
    // 8x8 tiles -> 80px wide, 60px tall.
    reg [35:0] uu;
    reg [35:0] vv;
    reg [3:0] ux;
    reg [3:0] vy;
    reg tile;
    begin
        uu = {4'd0, u_num};
        vv = {4'd0, v_num};

        // tile X index (0..7) using den-scaled thresholds
        if (uu < (den * 18'd80)) ux = 4'd0;
        else if (uu < (den * 18'd160)) ux = 4'd1;
        else if (uu < (den * 18'd240)) ux = 4'd2;
        else if (uu < (den * 18'd320)) ux = 4'd3;
        else if (uu < (den * 18'd400)) ux = 4'd4;
        else if (uu < (den * 18'd480)) ux = 4'd5;
        else if (uu < (den * 18'd560)) ux = 4'd6;
        else ux = 4'd7;

        // tile Y index (0..7) using den-scaled thresholds
        if (vv < (den * 18'd60)) vy = 4'd0;
        else if (vv < (den * 18'd120)) vy = 4'd1;
        else if (vv < (den * 18'd180)) vy = 4'd2;
        else if (vv < (den * 18'd240)) vy = 4'd3;
        else if (vv < (den * 18'd300)) vy = 4'd4;
        else if (vv < (den * 18'd360)) vy = 4'd5;
        else if (vv < (den * 18'd420)) vy = 4'd6;
        else vy = 4'd7;

        tile = ux[0] ^ vy[0];
        chess_from_uvnum = tile ? pack_rgb0(8'hFF,8'hFF,8'hFF)
                                : pack_rgb0(8'h00,8'h00,8'h00);
    end
endfunction

    // ----------------------------
    // Face vertex selection (screen coords)
    // ----------------------------
    // Z face (choose +Z or -Z by depth)
    wire signed [11:0] zA_x = sel_z_pos ? sX4 : sX0;
    wire signed [11:0] zA_y = sel_z_pos ? sY4 : sY0;
    wire signed [11:0] zB_x = sel_z_pos ? sX5 : sX1;
    wire signed [11:0] zB_y = sel_z_pos ? sY5 : sY1;
    wire signed [11:0] zC_x = sel_z_pos ? sX7 : sX3;
    wire signed [11:0] zC_y = sel_z_pos ? sY7 : sY3;
    wire signed [11:0] zD_x = sel_z_pos ? sX6 : sX2;
    wire signed [11:0] zD_y = sel_z_pos ? sY6 : sY2;

    // X face (choose +X or -X by depth)
    wire signed [11:0] xA_x = sel_x_pos ? sX1 : sX0;
    wire signed [11:0] xA_y = sel_x_pos ? sY1 : sY0;
    wire signed [11:0] xB_x = sel_x_pos ? sX3 : sX2;
    wire signed [11:0] xB_y = sel_x_pos ? sY3 : sY2;
    wire signed [11:0] xC_x = sel_x_pos ? sX7 : sX6;
    wire signed [11:0] xC_y = sel_x_pos ? sY7 : sY6;
    wire signed [11:0] xD_x = sel_x_pos ? sX5 : sX4;
    wire signed [11:0] xD_y = sel_x_pos ? sY5 : sY4;

    // Top face (+Y): vertices 2,3,7,6
    wire signed [11:0] tA_x = sX2;
    wire signed [11:0] tA_y = sY2;
    wire signed [11:0] tB_x = sX3;
    wire signed [11:0] tB_y = sY3;
    wire signed [11:0] tC_x = sX7;
    wire signed [11:0] tC_y = sY7;
    wire signed [11:0] tD_x = sX6;
    wire signed [11:0] tD_y = sY6;

    // UV mapping (full texture)
    wire [9:0] U0 = 10'd0;
    wire [9:0] U1 = UMAX[9:0];
    wire [9:0] V0 = 10'd0;
    wire [9:0] V1 = VMAX[9:0];

    // -------------------------------------------------------------------------
// Rasterization engine: evaluate 6 triangles per pixel using ONE shared
// barycentric/UV unit. This dramatically reduces replicated multipliers and
// prevents timing-related "blanking/glitching".
//
// Triangle evaluation order (same painter order as before):
//   0-1: FAR side (SMPTE)
//   2-3: NEAR side (SMPTE)
//   4-5: TOP face (CHESS) [drawn last => occludes sides]
//
// Each pixel takes 6 clocks (tri_step 0..5). BRAM write happens on step 5.
// -------------------------------------------------------------------------

reg [2:0] tri_step;     // 0..5
reg [7:0] pix8_acc;     // accumulated pixel color (RGB332)

// FAR/NEAR face selection
wire far_is_z  = x_is_near;   // if X face is near, Z is far
wire near_is_z = ~x_is_near;

wire signed [11:0] fA_x = far_is_z  ? zA_x : xA_x;
wire signed [11:0] fA_y = far_is_z  ? zA_y : xA_y;
wire signed [11:0] fB_x = far_is_z  ? zB_x : xB_x;
wire signed [11:0] fB_y = far_is_z  ? zB_y : xB_y;
wire signed [11:0] fC_x = far_is_z  ? zC_x : xC_x;
wire signed [11:0] fC_y = far_is_z  ? zC_y : xC_y;
wire signed [11:0] fD_x = far_is_z  ? zD_x : xD_x;
wire signed [11:0] fD_y = far_is_z  ? zD_y : xD_y;

wire signed [11:0] nA_x = far_is_z  ? xA_x : zA_x;
wire signed [11:0] nA_y = far_is_z  ? xA_y : zA_y;
wire signed [11:0] nB_x = far_is_z  ? xB_x : zB_x;
wire signed [11:0] nB_y = far_is_z  ? xB_y : zB_y;
wire signed [11:0] nC_x = far_is_z  ? xC_x : zC_x;
wire signed [11:0] nC_y = far_is_z  ? xC_y : zC_y;
wire signed [11:0] nD_x = far_is_z  ? xD_x : zD_x;
wire signed [11:0] nD_y = far_is_z  ? xD_y : zD_y;

// Inputs to shared triangle unit (selected by tri_step)
reg signed [11:0] tri_ax, tri_ay, tri_bx, tri_by, tri_cx, tri_cy;
reg [9:0] tri_au, tri_av, tri_bu, tri_bv, tri_cu, tri_cv;
reg       tri_is_chess;

always @* begin
    tri_ax = 12'sd0; tri_ay = 12'sd0; tri_bx = 12'sd0; tri_by = 12'sd0; tri_cx = 12'sd0; tri_cy = 12'sd0;
    tri_au = 10'd0;  tri_av = 10'd0;  tri_bu = 10'd0;  tri_bv = 10'd0;  tri_cu = 10'd0;  tri_cv = 10'd0;
    tri_is_chess = 1'b0;

    case (tri_step)
        // FAR side (A,B,C) then (A,C,D)  [SMPTE]
        3'd0: begin
            tri_is_chess = 1'b0;
            tri_ax = fA_x; tri_ay = fA_y; tri_bx = fB_x; tri_by = fB_y; tri_cx = fC_x; tri_cy = fC_y;
            if (far_is_z) begin
                // Z face: U along X, V along Y
                tri_au = U0;   tri_av = V0;   tri_bu = U1;   tri_bv = V0;   tri_cu = U1;   tri_cv = V1;
            end else begin
                // X face: U along Z, V along Y  (rotate mapping so SMPTE bars stay "vertical")
                tri_au = U0;   tri_av = V0;   tri_bu = U0;   tri_bv = V1;   tri_cu = U1;   tri_cv = V1;
            end
        end
        3'd1: begin
            tri_is_chess = 1'b0;
            tri_ax = fA_x; tri_ay = fA_y; tri_bx = fC_x; tri_by = fC_y; tri_cx = fD_x; tri_cy = fD_y;
            if (far_is_z) begin
                // Z face: (A,C,D) with consistent UVs
                tri_au = U0;   tri_av = V0;   tri_bu = U1;   tri_bv = V1;   tri_cu = U0;   tri_cv = V1;
            end else begin
                // X face: (A,C,D) with rotated mapping
                // A = (U0,V0), C = (U1,V1), D = (U1,V0)
                tri_au = U0;   tri_av = V0;   tri_bu = U1;   tri_bv = V1;   tri_cu = U1;   tri_cv = V0;
            end
        end

        // NEAR side (A,B,C) then (A,C,D) [SMPTE]
        3'd2: begin
            tri_is_chess = 1'b0;
            tri_ax = nA_x; tri_ay = nA_y; tri_bx = nB_x; tri_by = nB_y; tri_cx = nC_x; tri_cy = nC_y;
            if (near_is_z) begin
                // Z face
                tri_au = U0;   tri_av = V0;   tri_bu = U1;   tri_bv = V0;   tri_cu = U1;   tri_cv = V1;
            end else begin
                // X face (rotated mapping)
                tri_au = U0;   tri_av = V0;   tri_bu = U0;   tri_bv = V1;   tri_cu = U1;   tri_cv = V1;
            end
        end
        3'd3: begin
            tri_is_chess = 1'b0;
            tri_ax = nA_x; tri_ay = nA_y; tri_bx = nC_x; tri_by = nC_y; tri_cx = nD_x; tri_cy = nD_y;
            if (near_is_z) begin
                // Z face
                tri_au = U0;   tri_av = V0;   tri_bu = U1;   tri_bv = V1;   tri_cu = U0;   tri_cv = V1;
            end else begin
                // X face (rotated mapping)
                // A = (U0,V0), C = (U1,V1), D = (U1,V0)
                tri_au = U0;   tri_av = V0;   tri_bu = U1;   tri_bv = V1;   tri_cu = U1;   tri_cv = V0;
            end
        end

        // TOP (A,B,C) then (A,C,D) [CHESS]
        3'd4: begin
            tri_is_chess = 1'b1;
            tri_ax = tA_x; tri_ay = tA_y; tri_bx = tB_x; tri_by = tB_y; tri_cx = tC_x; tri_cy = tC_y;
            tri_au = U0;   tri_av = V0;   tri_bu = U1;   tri_bv = V0;   tri_cu = U1;   tri_cv = V1;
        end
        default: begin
            tri_is_chess = 1'b1;
            tri_ax = tA_x; tri_ay = tA_y; tri_bx = tC_x; tri_by = tC_y; tri_cx = tD_x; tri_cy = tD_y;
            tri_au = U0;   tri_av = V0;   tri_bu = U1;   tri_bv = V1;   tri_cu = U0;   tri_cv = V1;
        end
    endcase
end

// Shared triangle evaluator (one instance)
wire        tri_hit;
wire [31:0] tri_u_num;
wire [31:0] tri_v_num;
wire [17:0] tri_den;

tri_uv_unit #(
    .EDGE_SHR(EDGE_SHR)
) u_tri (
    .px(sx),
    .py(sy),
    .ax(tri_ax), .ay(tri_ay),
    .bx(tri_bx), .by(tri_by),
    .cx(tri_cx), .cy(tri_cy),
    .au(tri_au), .av(tri_av),
    .bu(tri_bu), .bv(tri_bv),
    .cu(tri_cu), .cv(tri_cv),
    .hit(tri_hit),
    .u_num(tri_u_num),
    .v_num(tri_v_num),
    .den(tri_den)
);

// Convert procedural face color to RGB332 and accumulate
wire [31:0] tri_rgb0 = tri_is_chess ? chess_from_uvnum(tri_u_num,tri_v_num,tri_den)
                                    : smpte_from_uvnum(tri_u_num,tri_v_num,tri_den);
wire [7:0]  tri_pix8 = rgb8880_to_rgb332(tri_rgb0);
wire [7:0]  pix8_next = tri_hit ? tri_pix8 : pix8_acc;

        // =========================================================================
    // Internal double-buffer (8bpp RGB332) + safe copy-out to external VideoRAM
    //
    // - Renderer writes a full frame into an internal BRAM buffer (RGB332).
    // - Copy engine transfers the last completed buffer to your external BRAM
    //   using the SAME 3 outputs as original V7: WR / WrAddr / WrData (RGB8880).
    //
    // This makes the external VideoRAM update "chunky" but deterministic, and
    // it avoids the unstable single-cycle write pulses that caused flashing.
    // =========================================================================

    // Internal pixel format: RGB332
    function [7:0] rgb8880_to_rgb332;
        input [31:0] rgb0;
        reg [7:0] r,g,b;
        begin
            r = rgb0[31:24];
            g = rgb0[23:16];
            b = rgb0[15:8];
            rgb8880_to_rgb332 = {r[7:5], g[7:5], b[7:6]};
        end
    endfunction

    function [31:0] rgb332_to_rgb8880;
        input [7:0] c;
        reg [2:0] r3, g3;
        reg [1:0] b2;
        reg [7:0] r8, g8, b8;
        begin
            r3 = c[7:5];
            g3 = c[4:2];
            b2 = c[1:0];
            r8 = {r3, r3, r3[2:1]};      // 3->8
            g8 = {g3, g3, g3[2:1]};      // 3->8
            b8 = {b2, b2, b2, b2};       // 2->8
            rgb332_to_rgb8880 = {r8,g8,b8,8'h00};
        end
    endfunction

    // Two internal BRAM buffers (ping-pong)
    // Note: XST/ISE infers BRAM for large reg memories.
    (* ram_style = "block" *) reg [7:0] buf0 [0:FRAME_WORDS-1];
    (* ram_style = "block" *) reg [7:0] buf1 [0:FRAME_WORDS-1];

    reg render_buf;        // 0/1: buffer currently being rendered into
    reg ready0, ready1;    // buffer completed and waiting to be copied

    // Copy engine
    reg        copy_busy;
    reg        copy_buf;          // buffer being copied out
    reg [18:0] copy_index;        // 0..FRAME_WORDS-1

    reg [2:0]  cst;
    localparam [2:0]
        CST_IDLE  = 3'd0,
        CST_READ  = 3'd1,   // issue BRAM read (sync)
        CST_WAIT  = 3'd2,   // allow read data to register
        CST_SETUP = 3'd3,   // load external outputs (WR=0)
        CST_HOLD  = 3'd4,   // WR=1 for WR_HOLD_CLKS cycles (addr+data stable)
        CST_GAP   = 3'd5;   // WR=0 for WRITE_GAP_CLKS cycles

 

    reg [7:0]  rd_q0, rd_q1;   // registered BRAM read data
    wire [7:0] rd_q = (copy_buf == 1'b0) ? rd_q0 : rd_q1;
    // Render write data: computed by rasterizer (pix8_next)
    // Internal BRAM: render write + copy read (on different buffers)
    always @(posedge clk) begin
        // Render writes (one pixel per 6 clocks; write occurs on tri_step==5)
        if (!render_buf_blocked && (tri_step == 3'd5)) begin
            if (render_buf == 1'b0) buf0[addr] <= pix8_next;
            else                  buf1[addr] <= pix8_next;
        end

        // Copy read (sync) - only when active and only on the selected buffer
        if (copy_busy && (cst == CST_READ)) begin
            if (copy_buf == 1'b0) rd_q0 <= buf0[copy_index];
            else                  rd_q1 <= buf1[copy_index];
        end
    end

    // Render control: scan the whole frame continuously, but do NOT overwrite
    // a buffer that is "ready" (waiting for copy-out).
    wire buf0_locked = ready0 || (copy_busy && (copy_buf == 1'b0));
    wire buf1_locked = ready1 || (copy_busy && (copy_buf == 1'b1));
    wire render_buf_blocked = (render_buf == 1'b0) ? buf0_locked : buf1_locked;

    // =========================================================================
    // Init
    // =========================================================================
    initial begin
        WR       = 1'b0;
        WrAddr   = 19'd0;
        WrData   = 32'd0;

        sx       = 9'd0;
        sy       = 8'd0;
        addr     = 19'd0;
        tri_step = 3'd0;
        pix8_acc = 8'h00;

        render_buf = 1'b0;
        ready0     = 1'b0;
        ready1     = 1'b0;

        copy_busy  = 1'b0;
        copy_buf   = 1'b0;
        copy_index = 19'd0;
        cst        = CST_IDLE;

        hold_cnt = 16'd0;
        gap_cnt  = 16'd0;

        rot_phase = 8'd0;

        // Disable FPS-related regs (kept in file but unused)
        sec_cnt         = 32'd0;
        frames_this_sec = 32'd0;
        fps_meas        = 8'd0;
        fps_d2          = 4'd0;
        fps_d1          = 4'd0;
        fps_d0          = 4'd0;
    end

    // =========================================================================
    // Top-level control:
    //  - Renderer fills internal buffer (one pixel per clock), then marks it ready.
    //  - Copy engine copies ready buffer to external VideoRAM with safe WR pulses.
    // =========================================================================
    always @(posedge clk) begin
        // -------------------------------------------------------------
        
// (1) Render engine: only advance when current render buffer is free
        // -------------------------------------------------------------
        if (!render_buf_blocked) begin
            // Evaluate one triangle per clock. On tri_step==5 we complete the pixel and write it.
            if (tri_step == 3'd5) begin
                // Pixel complete: BRAM write happens in BRAM always block above (bufX[addr] <= pix8_next)
                tri_step <= 3'd0;
                pix8_acc <= 8'h00;

                if ((sx == FRAME_W-1) && (sy == FRAME_H-1)) begin
                    // frame finished
                    if (render_buf == 1'b0) ready0 <= 1'b1;
                    else                    ready1 <= 1'b1;

                    // next frame: try switch to the other buffer
                    if (render_buf == 1'b0) render_buf <= 1'b1;
                    else                    render_buf <= 1'b0;

                    // reset scan
                    sx   <= 9'd0;
                    sy   <= 8'd0;
                    addr <= 19'd0;

                    // rotate one step per rendered frame
                    rot_phase <= rot_phase + 8'd1;
                end else begin
                    // advance to next pixel
                    if (sx == FRAME_W-1) begin
                        sx <= 9'd0;
                        sy <= sy + 1'b1;
                    end else begin
                        sx <= sx + 1'b1;
                    end

                    if (addr == (FRAME_WORDS-1)) addr <= 19'd0;
                    else                         addr <= addr + 1'b1;
                end
            end else begin
                tri_step <= tri_step + 3'd1;
                pix8_acc <= pix8_next;
            end
        end// If render buffer is blocked (ready but not yet copied), we simply HOLD
        // sx/sy/addr until copy frees it. This gives "stable output" priority.

        // -------------------------------------------------------------
        // (2) Copy engine: state machine
        // -------------------------------------------------------------
        if (!copy_busy) begin
            // Start copying if any buffer is ready
            if (ready0) begin
                copy_busy  <= 1'b1;
                copy_buf   <= 1'b0;
                copy_index <= 19'd0;
                cst        <= CST_READ;
                // ready0 stays asserted during copy; cleared when copy completes
                WR         <= 1'b0;
            end else if (ready1) begin
                copy_busy  <= 1'b1;
                copy_buf   <= 1'b1;
                copy_index <= 19'd0;
                cst        <= CST_READ;
                // ready1 stays asserted during copy; cleared when copy completes
                WR         <= 1'b0;
            end else begin
                WR <= 1'b0;
            end
        end else begin
            // Copy in progress
            case (cst)
                CST_READ: begin
                    // Sync read happens in BRAM always block; move on.
                    cst <= CST_WAIT;
                end

                CST_WAIT: begin
                    // Allow rd_q to settle (registered)
                    cst <= CST_SETUP;
                end

                CST_SETUP: begin
                    // Load output address+data (WR low)
                    WR     <= 1'b0;
                    WrAddr <= copy_index;
                    WrData <= rgb332_to_rgb8880(rd_q);

                    // Prepare hold/gap counters
                    if (WR_HOLD_CLKS > 1) hold_cnt <= WR_HOLD_CLKS - 1;
                    else hold_cnt <= 0;

                    cst <= CST_HOLD;
                end

                CST_HOLD: begin
                    // Hold WR high, keep addr+data stable
                    WR <= 1'b1;
                    if (hold_cnt == 0) begin
                        WR <= 1'b0;
                        // Load gap counter
                        if (WRITE_GAP_CLKS > 0) gap_cnt <= WRITE_GAP_CLKS - 1;
                        else gap_cnt <= 0;
                        cst <= CST_GAP;
                    end else begin
                        hold_cnt <= hold_cnt - 1'b1;
                    end
                end

                CST_GAP: begin
                    WR <= 1'b0;
                    if (WRITE_GAP_CLKS == 0) begin
                        // no gap
                        if (copy_index == (FRAME_WORDS-1)) begin
                                if (copy_buf == 1'b0) ready0 <= 1'b0;
                                else                   ready1 <= 1'b0;
                                copy_busy <= 1'b0;
                                cst       <= CST_IDLE;
                            end else begin
                            copy_index <= copy_index + 1'b1;
                            cst <= CST_READ;
                        end
                    end else begin
                        if (gap_cnt == 0) begin
                            if (copy_index == (FRAME_WORDS-1)) begin
                                if (copy_buf == 1'b0) ready0 <= 1'b0;
                                else                   ready1 <= 1'b0;
                                copy_busy <= 1'b0;
                                cst       <= CST_IDLE;
                            end else begin
                                copy_index <= copy_index + 1'b1;
                                cst <= CST_READ;
                            end
                        end else begin
                            gap_cnt <= gap_cnt - 1'b1;
                        end
                    end
                end

                default: begin
                    cst <= CST_IDLE;
                end
            endcase
        end
    end

endmodule

// ============================================================================
// tri_uv_unit: shared barycentric + UV numerator calculator
// - Outputs u_num = u * den, v_num = v * den, den = triangle area (scaled)
// - 'hit' indicates pixel inside triangle (including edges)
// - Designed for Verilog-2001 / Spartan-6, no SystemVerilog.
// ============================================================================

module tri_uv_unit #(
    parameter integer EDGE_SHR = 3
)(
    input      [8:0] px,
    input      [7:0] py,
    input signed [11:0] ax, input signed [11:0] ay,
    input signed [11:0] bx, input signed [11:0] by,
    input signed [11:0] cx, input signed [11:0] cy,
    input      [9:0] au, input      [9:0] av,
    input      [9:0] bu, input      [9:0] bv,
    input      [9:0] cu, input      [9:0] cv,
    output reg        hit,
    output reg [31:0] u_num,
    output reg [31:0] v_num,
    output reg [17:0] den
);

    // Oriented edge function (signed):
    // edge(p,a,b) = ((p-a) x (b-a)) >> EDGE_SHR
    function signed [31:0] edge_pab;
        input signed [11:0] pxs; input signed [11:0] pys;
        input signed [11:0] ax0; input signed [11:0] ay0;
        input signed [11:0] bx0; input signed [11:0] by0;
        reg signed [12:0] dx, dy;
        reg signed [12:0] pax, pay;
        reg signed [17:0] a1, b1, c1, d1;
        reg signed [35:0] p1, p2;
        reg signed [35:0] e;
        begin
            dx  = bx0 - ax0;
            dy  = by0 - ay0;
            pax = pxs - ax0;
            pay = pys - ay0;

            a1 = {{5{pax[12]}}, pax};
            b1 = {{5{dy[12]}},  dy};
            c1 = {{5{pay[12]}}, pay};
            d1 = {{5{dx[12]}},  dx};
            p1 = a1 * b1;
            p2 = c1 * d1;
            e  = p1 - p2;

            edge_pab = (e >>> EDGE_SHR);
        end
    endfunction

    reg signed [11:0] pxs, pys;
    reg signed [31:0] w0l, w1l, w2l, areal;
    reg signed [31:0] w0a, w1a, w2a, area_abs;

    reg [17:0] w0, w1, w2, area;
    reg [35:0] m0, m1, m2;
    reg [37:0] sum_u;
    reg [37:0] sum_v;

    always @* begin
        // defaults
        hit   = 1'b0;
        u_num = 32'd0;
        v_num = 32'd0;
        den   = 18'd1;

        pxs = {3'b000, px}; // 0..319
        pys = {4'b0000, py}; // 0..239

        // Barycentric edge functions (same style as original V20):
        w0l   = edge_pab(pxs,pys, bx,by, cx,cy);
        w1l   = edge_pab(pxs,pys, cx,cy, ax,ay);
        w2l   = edge_pab(pxs,pys, ax,ay, bx,by);
        areal = edge_pab(ax,ay, bx,by, cx,cy);

        if (areal == 0) begin
            hit = 1'b0;
            den = 18'd1;
        end else if (areal[31] == 1'b0) begin
            // area > 0 : inside if all >= 0
            if ((w0l >= 0) && (w1l >= 0) && (w2l >= 0)) begin
                hit = 1'b1;

                area = areal[17:0];
                den  = area;

                w0 = w0l[17:0];
                w1 = w1l[17:0];
                w2 = w2l[17:0];

                m0 = w0 * au; m1 = w1 * bu; m2 = w2 * cu;
                sum_u = m0 + m1 + m2;

                m0 = w0 * av; m1 = w1 * bv; m2 = w2 * cv;
                sum_v = m0 + m1 + m2;

                u_num = sum_u[31:0];
                v_num = sum_v[31:0];
            end
        end else begin
            // area < 0 : inside if all <= 0, then negate weights so they are positive
            if ((w0l <= 0) && (w1l <= 0) && (w2l <= 0)) begin
                hit = 1'b1;

                area_abs = -areal;
                area = area_abs[17:0];
                den  = area;

                w0a = -w0l; w1a = -w1l; w2a = -w2l;
                w0 = w0a[17:0];
                w1 = w1a[17:0];
                w2 = w2a[17:0];

                m0 = w0 * au; m1 = w1 * bu; m2 = w2 * cu;
                sum_u = m0 + m1 + m2;

                m0 = w0 * av; m1 = w1 * bv; m2 = w2 * cv;
                sum_v = m0 + m1 + m2;

                u_num = sum_u[31:0];
                v_num = sum_v[31:0];
            end
        end
    end

endmodule

