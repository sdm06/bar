//! Build-time BDF -> Zig bitmap font compiler.
//!
//! The bar itself never parses anything: it sees a flat table of row masks
//! that are already positioned inside their cell and already integer-scaled.
//! Swapping fonts or changing the scale therefore costs zero at runtime, and
//! no generated source file is ever checked in.
//!
//! Row mask layout: bit `p` of `bitmap[i * height + y]` means "cell column
//! `p` is lit on cell row `y`". Columns outside `0..width` are never set,
//! which lets the blitter shift a whole row with a single shift.

const std = @import("std");

/// Widest cell the u32 row masks can represent.
pub const max_cell_width: u32 = 32;
pub const max_codepoints: usize = 1024;
pub const max_scale: u8 = 4;

pub const Metrics = struct {
    /// Cell width in pixels, after scaling.
    width: u16,
    /// Cell height in pixels, after scaling.
    height: u16,
    /// Rows from the top of the cell down to the baseline.
    ascent: u16,
};

pub const Font = struct {
    metrics: Metrics,
    /// Smallest codepoint present; the table is dense from here upwards.
    first: u21,
    /// Largest codepoint present.
    last: u21,
    advances: []const u16,
    bitmap: []const u32,

    pub fn has(self: Font, cp: u21) bool {
        return cp >= self.first and cp <= self.last;
    }

    pub fn count(self: Font) usize {
        return @as(usize, self.last) - @as(usize, self.first) + 1;
    }

    pub fn advance(self: Font, cp: u21) u16 {
        if (!self.has(cp)) return self.metrics.width;
        return self.advances[cp - self.first];
    }

    /// Cell-relative row mask for `cp`. Absent glyphs are blank.
    pub fn row(self: Font, cp: u21, y: u16) u32 {
        if (!self.has(cp) or y >= self.metrics.height) return 0;
        return self.bitmap[@as(usize, cp - self.first) * self.metrics.height + y];
    }
};

pub const CompileError = error{
    MissingFontBoundingBox,
    MalformedFontBoundingBox,
    MissingEncoding,
    MissingDwidth,
    MissingBbx,
    UnterminatedGlyph,
    CellTooWide,
    BadScale,
    GlyphOutsideCell,
    DuplicateCodepoint,
    CodepointOutOfRange,
    MalformedHex,
    NoGlyphs,
    OutOfMemory,
};

pub const Options = struct {
    /// Integer nearest-neighbour scale, 1..4.
    scale: u8 = 1,
    /// Advance for glyphs with an empty box and no DWIDTH. Zero means the
    /// cell width, which is what fixed-pitch fonts want.
    default_advance: u16 = 0,
};

const Raw = struct {
    encoding: u21,
    advance: u16,
    /// Exactly `cell_height * scale` row masks.
    rows: []u32,
};

const Parser = struct {
    src: []const u8,
    scale: u8,
    cell_w: i32,
    cell_h: i32,
    base: i32,
    fallback_advance: u16,
    out: *std.ArrayList(Raw),
    gpa: std.mem.Allocator,

    fn run(self: *Parser) CompileError!void {
        var lines = std.mem.splitScalar(u8, self.src, '\n');

        var in_glyph = false;
        var saw_encoding = false;
        var encoding: i32 = 0;
        var advance: i32 = 0;
        var have_dwidth = false;
        var box_w: i32 = 0;
        var box_h: i32 = 0;
        var box_x: i32 = 0;
        var box_y: i32 = 0;
        var start: i32 = 0;
        var box_rows: []u32 = &.{};
        var row_index: i32 = 0;
        var stride_bytes: i32 = 0;

        while (lines.next()) |raw_line| {
            const line = trim(raw_line);
            if (line.len == 0) continue;

            if (!in_glyph) {
                if (starts(line, "STARTCHAR")) {
                    in_glyph = true;
                    saw_encoding = false;
                    encoding = 0;
                    advance = 0;
                    have_dwidth = false;
                    box_w = 0;
                    box_h = 0;
                    box_x = 0;
                    box_y = 0;
                    box_rows = &.{};
                    row_index = 0;
                    stride_bytes = 0;
                    start = 0;
                }
                continue;
            }

            if (starts(line, "ENCODING")) {
                encoding = parseInt(afterKeyword(line, "ENCODING")) catch return error.MissingEncoding;
                saw_encoding = true;
            } else if (starts(line, "DWIDTH")) {
                var it = tokenize(afterKeyword(line, "DWIDTH"));
                advance = parseInt(it.next() orelse return error.MissingDwidth) catch
                    return error.MissingDwidth;
                have_dwidth = true;
            } else if (starts(line, "BBX")) {
                var it = tokenize(afterKeyword(line, "BBX"));
                box_w = parseInt(it.next() orelse return error.MissingBbx) catch return error.MissingBbx;
                box_h = parseInt(it.next() orelse return error.MissingBbx) catch return error.MissingBbx;
                box_x = parseInt(it.next() orelse return error.MissingBbx) catch return error.MissingBbx;
                box_y = parseInt(it.next() orelse return error.MissingBbx) catch return error.MissingBbx;
                if (box_w < 0 or box_h < 0) return error.MissingBbx;

                stride_bytes = @divTrunc(box_w + 7, 8);
                // Cell row of the glyph box's top edge, before scaling.
                start = self.base - box_y - box_h + 1;
                if (box_x < 0 or box_x + box_w > self.cell_w) return error.GlyphOutsideCell;
                if (box_h > 0 and (start < 0 or start + box_h > self.cell_h))
                    return error.GlyphOutsideCell;

                if (box_h > 0) {
                    box_rows = self.gpa.alloc(u32, @intCast(box_h)) catch return error.OutOfMemory;
                    @memset(box_rows, 0);
                }
            } else if (starts(line, "BITMAP")) {
                row_index = 0;
            } else if (starts(line, "ENDCHAR")) {
                if (!saw_encoding) return error.MissingEncoding;
                if (encoding < 0 or encoding > 0x10FFFF) return error.CodepointOutOfRange;

                const cells = @as(usize, @intCast(self.cell_h)) * self.scale;
                const rows = self.gpa.alloc(u32, cells) catch return error.OutOfMemory;
                @memset(rows, 0);

                // Vertically scale: replicate each box row `scale` times at
                // its absolute cell position.
                var y: i32 = 0;
                while (y < box_h) : (y += 1) {
                    const dst: usize = @intCast((start + y) * self.scale);
                    const mask = box_rows[@intCast(y)];
                    var k: u8 = 0;
                    while (k < self.scale) : (k += 1) rows[dst + k] = mask;
                }
                self.gpa.free(box_rows);
                box_rows = &.{};

                // DWIDTH and the fallback are both in the font's own units, so
                // they have to be scaled like the cell is. Leaving them alone
                // gave every glyph a 9px advance inside an 18px cell, which
                // made scaled text overlap its own neighbours.
                const raw_advance: i32 = if (have_dwidth) @max(advance, 0) else self.fallback_advance;
                self.out.append(self.gpa, .{
                    .encoding = @intCast(encoding),
                    .advance = @intCast(@min(raw_advance * self.scale, max_cell_width)),
                    .rows = rows,
                }) catch return error.OutOfMemory;
                in_glyph = false;
            } else if (box_h > 0 and row_index < box_h) {
                const bits = parseHexRow(line, @intCast(stride_bytes)) catch return error.MalformedHex;
                // BDF hex is MSB-first over `stride_bytes` bytes, with the
                // glyph's leftmost column on the top bit of the last byte.
                // Flip it into bit-per-column form, scale, then shift into
                // the cell.
                var out_mask: u32 = 0;
                var c: i32 = 0;
                while (c < box_w) : (c += 1) {
                    const src_bit: u5 = @intCast(stride_bytes * 8 - 1 - c);
                    if (bits & (@as(u32, 1) << src_bit) == 0) continue;
                    const scaled_col: i32 = c * self.scale;
                    var k: u8 = 0;
                    while (k < self.scale) : (k += 1)
                        out_mask |= @as(u32, 1) << @intCast(scaled_col + k);
                }
                out_mask <<= @intCast(box_x * self.scale);
                box_rows[@intCast(row_index)] = out_mask;
                row_index += 1;
            }
        }

        if (in_glyph) return error.UnterminatedGlyph;
    }
};

/// Compile BDF source into a dense glyph table. The caller owns the returned
/// slices and must release them with `deinit`.
pub fn compile(
    gpa: std.mem.Allocator,
    src: []const u8,
    options: Options,
) CompileError!Font {
    if (options.scale == 0 or options.scale > max_scale) return error.BadScale;

    const unscaled = parseFontBoundingBox(src) catch return error.MissingFontBoundingBox;
    const cell_w: i32 = unscaled.width * options.scale;
    const cell_h: i32 = unscaled.height * options.scale;
    if (cell_w > @as(i32, max_cell_width)) return error.CellTooWide;

    const metrics = Metrics{
        .width = @intCast(cell_w),
        .height = @intCast(cell_h),
        .ascent = @intCast(unscaled.ascent * options.scale),
    };

    var raw = std.ArrayList(Raw).empty;
    defer {
        for (raw.items) |g| gpa.free(g.rows);
        raw.deinit(gpa);
    }

    var parser = Parser{
        .src = src,
        .scale = options.scale,
        // The parser works in the font's own units and scales on the way into
        // the row masks, so it must be handed the *unscaled* cell. Passing the
        // scaled figures here made every glyph's vertical placement, and the
        // length of `Raw.rows`, come out `scale` times too large.
        .cell_w = @intCast(unscaled.width),
        .cell_h = @intCast(unscaled.height),
        // Baseline row measured from the top of the unscaled cell.
        .base = @intCast(unscaled.ascent),
        // Unscaled, like DWIDTH: `raw_advance` applies the scale.
        .fallback_advance = if (options.default_advance == 0) @as(u16, @intCast(unscaled.width)) else options.default_advance,
        .out = &raw,
        .gpa = gpa,
    };
    try parser.run();

    if (raw.items.len == 0) return error.NoGlyphs;

    var first: u21 = std.math.maxInt(u21);
    var last: u21 = 0;
    for (raw.items) |g| {
        if (g.encoding < first) first = g.encoding;
        if (g.encoding > last) last = g.encoding;
    }
    const count = @as(usize, last) - @as(usize, first) + 1;
    if (count > max_codepoints) return error.CodepointOutOfRange;

    const advances = gpa.alloc(u16, count) catch return error.OutOfMemory;
    errdefer gpa.free(advances);
    const seen = gpa.alloc(bool, count) catch return error.OutOfMemory;
    defer gpa.free(seen);
    @memset(seen, false);

    const bitmap = gpa.alloc(u32, count * metrics.height) catch return error.OutOfMemory;
    errdefer gpa.free(bitmap);
    @memset(bitmap, 0);

    for (raw.items) |g| {
        const idx = @as(usize, g.encoding) - @as(usize, first);
        if (seen[idx]) return error.DuplicateCodepoint;
        seen[idx] = true;
        advances[idx] = g.advance;
        @memcpy(bitmap[idx * metrics.height ..][0..metrics.height], g.rows);
    }

    return .{
        .metrics = metrics,
        .first = first,
        .last = last,
        .advances = advances,
        .bitmap = bitmap,
    };
}

pub fn deinit(gpa: std.mem.Allocator, font: Font) void {
    gpa.free(font.advances);
    gpa.free(font.bitmap);
}

const Unscaled = struct { width: i32, height: i32, ascent: i32 };

fn parseFontBoundingBox(src: []const u8) CompileError!Unscaled {
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw_line| {
        const line = trim(raw_line);
        if (!starts(line, "FONTBOUNDINGBOX")) continue;
        var it = tokenize(afterKeyword(line, "FONTBOUNDINGBOX"));
        const width = parseInt(it.next() orelse return error.MalformedFontBoundingBox) catch
            return error.MalformedFontBoundingBox;
        const height = parseInt(it.next() orelse return error.MalformedFontBoundingBox) catch
            return error.MalformedFontBoundingBox;
        _ = it.next() orelse return error.MalformedFontBoundingBox; // bearing x, unused
        // The y field is the bottom edge relative to the baseline, negative
        // downwards, so it is minus the descent.
        const bottom = parseInt(it.next() orelse return error.MalformedFontBoundingBox) catch
            return error.MalformedFontBoundingBox;
        if (width <= 0 or height <= 0) return error.MalformedFontBoundingBox;
        return .{ .width = width, .height = height, .ascent = height + bottom };
    }
    return error.MissingFontBoundingBox;
}

fn parseHexRow(line: []const u8, want_bytes: u32) CompileError!u32 {
    var v: u32 = 0;
    var n: u32 = 0;
    for (line) |ch| {
        const d: u32 = switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            else => continue,
        };
        v = (v << 4) | d;
        n += 1;
        if (n == 8) break;
    }
    if (n == 0) return error.MalformedHex;
    if (want_bytes > 4 and n < want_bytes * 2) return error.MalformedHex;
    return v;
}

/// Text following `keyword`. BDF keywords are either colon separated
/// (`BBX: 7 10 1 1`) or plain space separated (`FONTBOUNDINGBOX 9 15 0 -3`),
/// so both forms are accepted.
fn afterKeyword(line: []const u8, keyword: []const u8) []const u8 {
    const rest = line[keyword.len..];
    if (std.mem.indexOfScalar(u8, rest, ':')) |colon| return rest[colon + 1 ..];
    return rest;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn starts(haystack: []const u8, needle: []const u8) bool {
    return std.mem.startsWith(u8, haystack, needle);
}

fn tokenize(s: []const u8) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, s, " \t\r");
}

fn parseInt(s: []const u8) error{MalformedFontBoundingBox}!i32 {
    return std.fmt.parseInt(i32, trim(s), 10) catch error.MalformedFontBoundingBox;
}
