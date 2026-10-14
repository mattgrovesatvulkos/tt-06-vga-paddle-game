/*
 * Paddle ball for VGA: keep the ball in play.
 *
 * To play, open Inspect > VGA output and press Run. Use the switches under the
 * picture, or the keyboard:
 *   ui_in[0]  paddle left    (Left arrow, A or 1)
 *   ui_in[1]  paddle right   (Right arrow, D or 2)
 *
 * The ball bounces off the walls and the ceiling. Catch it on the paddle to
 * score: the green bar grows with every catch, and the ball speeds up as it
 * grows. Where the ball lands on the paddle decides which way it leaves, so you
 * can aim. Miss it and the screen flashes red before a new game starts.
 *
 * How this file is laid out:
 *   1. SETTINGS   Colours, sizes and speeds. Change anything here and press Run.
 *   2. WIRING     The pins and the sync generator. Leave this as it is.
 *   3. THE GAME   The rules: the paddle, the bounces, catches and misses.
 *   4. DRAWING    The colour of every pixel, from where things are.
 */

`default_nettype none

module tt_um_mattgrovesatvulkos_06_vga_paddle_game (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // ========================================================================
    // 1. SETTINGS
    //    Change these freely. Nothing below needs editing when you do.
    // ========================================================================

    // Colours. Six bits: two for red, two for green, two for blue (6'bRRGGBB).
    // Each pair goes from 00 (off) to 11 (full), so 6'b110000 is pure red.
    localparam [5:0] BALL_COLOUR       = 6'b111100;   // yellow
    localparam [5:0] PADDLE_COLOUR     = 6'b001111;   // cyan
    localparam [5:0] WALL_COLOUR       = 6'b111111;   // white
    localparam [5:0] GRID_COLOUR       = 6'b000101;   // the faint lines behind the game
    localparam [5:0] BACKGROUND_COLOUR = 6'b000001;   // deep blue
    localparam [5:0] SCORE_COLOUR      = 6'b001100;   // green

    // Sizes, in pixels. The screen is 640 wide and 480 tall.
    localparam [9:0] BALL_SIZE = 10'd12;   // the ball is a square this big
    localparam [9:0] PADDLE_W  = 10'd96;   // a wider paddle is easier
    localparam [9:0] PADDLE_H  = 10'd10;

    // Speeds, in pixels per frame. There are 60 frames every second.
    localparam [9:0] PADDLE_STEP = 10'd6;  // how far the paddle moves sideways
    localparam [3:0] START_SPEED = 4'd3;   // how fast the ball moves at the start: 12 at most

    // The ball gets one pixel per frame faster each time the score reaches one of these.
    localparam [5:0] FASTER_AT_1 = 6'd8;
    localparam [5:0] FASTER_AT_2 = 6'd16;
    localparam [5:0] FASTER_AT_3 = 6'd24;

    // How long the red flash lasts after a miss, in frames. 63 at most.
    localparam [5:0] MISS_FRAMES = 6'd40;

    // The court. These numbers fit together, so change them as a set.
    localparam [9:0] SCREEN_W     = 10'd640;
    localparam [9:0] SCREEN_H     = 10'd480;
    localparam [9:0] CEILING      = 10'd24;    // the ball turns back here
    localparam [9:0] PADDLE_Y     = 10'd444;   // how far down the screen the paddle sits
    localparam [9:0] BALL_START_Y = 10'd120;   // how far down the ball starts each game

    // ========================================================================
    // 2. WIRING
    //    The pins and the monitor's timing. Leave this section as it is.
    // ========================================================================

    wire       hsync;
    wire       vsync;
    wire       video_active;
    wire [9:0] pix_x;          // the pixel being drawn now: 0 to 639 across
    wire [9:0] pix_y;          // and 0 to 479 down

    hvsync_generator hvsync_gen (
        .clk(clk),
        .reset(~rst_n),
        .hsync(hsync),
        .vsync(vsync),
        .display_on(video_active),
        .hpos(pix_x),
        .vpos(pix_y)
    );

    wire move_left  = ui_in[0] & ~ui_in[1];
    wire move_right = ui_in[1] & ~ui_in[0];

    // High for one clock as each frame ends. The game moves on once per frame.
    reg  vsync_q;
    wire new_frame = vsync_q & ~vsync;

    // ========================================================================
    // 3. THE GAME
    //    A few registers hold where everything is. They change once per frame.
    // ========================================================================

    reg [9:0]  ball_x;         // top left corner of the ball
    reg [9:0]  ball_y;
    reg        going_right;    // which way the ball is moving, sideways ...
    reg        going_down;     // ... and up or down
    reg [9:0]  paddle_x;       // left edge of the paddle
    reg [5:0]  score;          // catches this game, up to 63
    reg [5:0]  miss_timer;     // frames of flash left after a miss, 0 while playing
    reg [15:0] random;         // shifts every clock, so its value looks random

    // Worked out from the settings, so they stay right when you change a size.
    localparam [9:0] PADDLE_MAX   = SCREEN_W - PADDLE_W;           // as far right as the paddle goes
    localparam [9:0] PADDLE_START = (SCREEN_W - PADDLE_W) >> 1;    // the paddle starts in the middle
    localparam [9:0] BALL_START_X = (SCREEN_W - BALL_SIZE) >> 1;   // and so does the ball
    localparam [9:0] BALL_HALF    = BALL_SIZE >> 1;
    localparam [9:0] PADDLE_HALF  = PADDLE_W >> 1;

    // How far the ball moves this frame: faster as the score grows.
    wire [3:0] speed = (score >= FASTER_AT_3) ? START_SPEED + 4'd3 :
                       (score >= FASTER_AT_2) ? START_SPEED + 4'd2 :
                       (score >= FASTER_AT_1) ? START_SPEED + 4'd1 : START_SPEED;
    wire [9:0] step = {6'd0, speed};

    // Does the ball land on the paddle this frame, or go past it?
    wire [9:0] ball_bottom  = ball_y + BALL_SIZE;
    wire       over_paddle  = (ball_x + BALL_SIZE > paddle_x) && (ball_x < paddle_x + PADDLE_W);
    wire       reaches_line = (ball_bottom + step >= PADDLE_Y) && (ball_bottom <= PADDLE_Y + PADDLE_H);
    wire       hit_paddle   = going_down && over_paddle && reaches_line;
    wire       falls_out    = going_down && !hit_paddle && (ball_bottom + step >= SCREEN_H);

    // A catch left of the paddle's middle sends the ball left, and right of it, right.
    wire       right_half   = (ball_x + BALL_HALF >= paddle_x + PADDLE_HALF);

    always @(posedge clk) begin
        random  <= {random[14:0], random[15] ^ random[13] ^ random[12] ^ random[10]};
        vsync_q <= vsync;

        if (~rst_n) begin
            ball_x      <= BALL_START_X;
            ball_y      <= BALL_START_Y;
            going_right <= 1'b1;
            going_down  <= 1'b1;
            paddle_x    <= PADDLE_START;
            score       <= 6'd0;
            miss_timer  <= 6'd0;
            random      <= 16'hACE1;
        end else if (new_frame) begin
            if (miss_timer != 6'd0) begin
                // ---- after a miss: count the flash down, then start a new game
                miss_timer <= miss_timer - 6'd1;
                if (miss_timer == 6'd1) begin
                    ball_x      <= BALL_START_X;
                    ball_y      <= BALL_START_Y;
                    going_right <= random[0];
                    going_down  <= 1'b1;
                    score       <= 6'd0;
                end
            end else begin
                // ---- the paddle: move sideways, and stop at the edge of the screen
                if (move_left)  paddle_x <= (paddle_x > PADDLE_STEP) ? paddle_x - PADDLE_STEP : 10'd0;
                if (move_right) paddle_x <= (paddle_x < PADDLE_MAX - PADDLE_STEP) ? paddle_x + PADDLE_STEP : PADDLE_MAX;

                // ---- the ball, sideways: bounce off the two walls
                if (going_right) begin
                    if (ball_x + BALL_SIZE + step >= SCREEN_W) begin
                        going_right <= 1'b0;
                        ball_x      <= SCREEN_W - BALL_SIZE;
                    end else begin
                        ball_x <= ball_x + step;
                    end
                end else begin
                    if (ball_x <= step) begin
                        going_right <= 1'b1;
                        ball_x      <= 10'd0;
                    end else begin
                        ball_x <= ball_x - step;
                    end
                end

                // ---- the ball, up and down: a catch, a miss, or a bounce off the ceiling
                if (hit_paddle) begin
                    going_down  <= 1'b0;
                    ball_y      <= PADDLE_Y - BALL_SIZE;
                    going_right <= right_half;
                    if (score != 6'd63) score <= score + 6'd1;
                end else if (falls_out) begin
                    miss_timer <= MISS_FRAMES;
                end else if (going_down) begin
                    ball_y <= ball_y + step;
                end else if (ball_y <= CEILING + step) begin
                    going_down <= 1'b1;
                    ball_y     <= CEILING;
                end else begin
                    ball_y <= ball_y - step;
                end
            end
        end
    end

    // ========================================================================
    // 4. DRAWING
    //    One question for each thing on screen: is this pixel inside it?
    // ========================================================================

    wire in_ball   = (pix_x >= ball_x)   && (pix_x < ball_x + BALL_SIZE) &&
                     (pix_y >= ball_y)   && (pix_y < ball_y + BALL_SIZE);
    wire in_paddle = (pix_x >= paddle_x) && (pix_x < paddle_x + PADDLE_W) &&
                     (pix_y >= PADDLE_Y) && (pix_y < PADDLE_Y + PADDLE_H);

    // The two side walls, and the ceiling line the ball turns back at.
    wire in_wall   = (pix_x < 10'd4) || (pix_x >= SCREEN_W - 10'd4) ||
                     ((pix_y >= CEILING - 10'd4) && (pix_y < CEILING));

    // The score bar: eight pixels longer for every catch.
    wire in_score  = (pix_y >= 10'd8) && (pix_y < 10'd16) &&
                     (pix_x >= 10'd8) && (pix_x < 10'd8 + {1'b0, score, 3'b000});

    // A line every 64 pixels, across and down.
    wire in_grid   = (pix_x[5:0] == 6'd0) || (pix_y[5:0] == 6'd0);

    // The first line that matches wins, so anything higher up is drawn on top
    // of anything lower down. Move a line to change what covers what.
    reg [5:0] colour;
    always @(*) begin
        if (~video_active)  colour = 6'b000000;
        else if (in_score)  colour = SCORE_COLOUR;
        else if (in_ball)   colour = BALL_COLOUR;
        else if (in_paddle) colour = PADDLE_COLOUR;
        else if (in_wall)   colour = WALL_COLOUR;
        else if (in_grid)   colour = GRID_COLOUR;
        else                colour = BACKGROUND_COLOUR;
    end

    // The miss flash: for four frames in every eight, full red with green and blue dimmed.
    wire       flash = (miss_timer != 6'd0) && miss_timer[2];
    wire [5:0] shown = flash ? {2'b11, 1'b0, colour[3], 1'b0, colour[1]} : colour;

    // ---- to the pins, in the order the TinyVGA adapter expects. Leave as it is.
    wire [1:0] R = shown[5:4];
    wire [1:0] G = shown[3:2];
    wire [1:0] B = shown[1:0];

    assign uo_out  = {hsync, B[0], G[0], R[0], vsync, B[1], G[1], R[1]};
    assign uio_out = 8'h00;
    assign uio_oe  = 8'h00;

    wire _unused_ok = &{ena, uio_in, ui_in[7:2]};

endmodule
