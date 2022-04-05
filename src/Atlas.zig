//! Implements a texture atlas (https://en.wikipedia.org/wiki/Texture_atlas).
//!
//! The implementation is based on "A Thousand Ways to Pack the Bin - A
//! Practical Approach to Two-Dimensional Rectangle Bin Packing" by Jukka
//! Jylänki. This specific implementation is based heavily on
//! Nicolas P. Rougier's freetype-gl project as well as Jukka's C++
//! implementation: https://github.com/juj/RectangleBinPack
//!
//! Limitations that are easy to fix, but I didn't need them:
//!
//!   * Greyscale support only, no support for RGB or RGBA.
//!   * Written data must be packed, no support for custom strides.
//!   * Texture is always a square, no ability to set width != height. Note
//!     that regions written INTO the atlas do not have to be square, only
//!     the full atlas texture itself.
//!
const Atlas = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Data is the raw texture data.
data: []u8,

/// Width and height of the atlas texture. The current implementation is
/// always square so this is both the width and the height.
size: u32,

nodes: std.ArrayListUnmanaged(Node),

const Node = struct {
    x: u32,
    y: u32,
    width: u32,
};

pub const Error = error{
    /// Atlas cannot fit the desired region. You must enlarge the atlas.
    AtlasFull,
};

pub const Region = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub fn init(alloc: Allocator, size: u32) !Atlas {
    var result = Atlas{
        .data = try alloc.alloc(u8, size * size),
        .size = size,
        .nodes = .{},
    };

    // TODO: figure out optimal prealloc based on real world usage
    try result.nodes.ensureUnusedCapacity(alloc, 64);

    // This sets up our initial state
    result.clear();

    return result;
}

pub fn deinit(self: *Atlas, alloc: Allocator) void {
    self.nodes.deinit(alloc);
    alloc.free(self.data);
    self.* = undefined;
}

/// Reserve a region within the atlas with the given width and height.
///
/// May allocate to add a new rectangle into the internal list of rectangles.
/// This will not automatically enlarge the texture if it is full.
pub fn reserve(self: *Atlas, alloc: Allocator, width: u32, height: u32) !Region {
    // x, y are populated within :best_idx below
    var region: Region = .{ .x = 0, .y = 0, .width = width, .height = height };

    // Find the location in our nodes list to insert the new node for this region.
    var best_idx: usize = best_idx: {
        var best_height: u32 = std.math.maxInt(u32);
        var best_width: u32 = best_height;
        var chosen: ?usize = null;

        var i: usize = 0;
        while (i < self.nodes.items.len) : (i += 1) {
            // Check if our region fits within this node.
            const y = self.fit(i, width, height) orelse continue;

            const node = self.nodes.items[i];
            if ((y + height) < best_height or
                ((y + height) == best_height and
                (node.width > 0 and node.width < best_width)))
            {
                chosen = i;
                best_width = node.width;
                best_height = y + height;
                region.x = node.x;
                region.y = y;
            }
        }

        // If we never found a chosen index, the atlas cannot fit our region.
        break :best_idx chosen orelse return Error.AtlasFull;
    };

    // Insert our new node for this rectangle at the exact best index
    try self.nodes.insert(alloc, best_idx, .{
        .x = region.x,
        .y = region.y + height,
        .width = width,
    });

    // Optimize our rectangles
    var i: usize = best_idx + 1;
    while (i < self.nodes.items.len) : (i += 1) {
        const node = &self.nodes.items[i];
        const prev = self.nodes.items[i - 1];
        if (node.x < (prev.x + prev.width)) {
            const shrink = prev.x + prev.width - node.x;
            node.x += shrink;
            node.width -= shrink;
            if (node.width <= 0) {
                _ = self.nodes.orderedRemove(i);
                i -= 1;
                continue;
            }
        }

        break;
    }
    self.merge();

    return region;
}

/// Attempts to fit a rectangle of width x height into the node at idx.
/// The return value is the y within the texture where the rectangle can be
/// placed. The x is the same as the node.
fn fit(self: Atlas, idx: usize, width: u32, height: u32) ?u32 {
    // If the added width exceeds our texture size, it doesn't fit.
    const node = self.nodes.items[idx];
    if ((node.x + width) > (self.size - 1)) return null;

    // Go node by node looking for space that can fit our width.
    var y = node.y;
    var i = idx;
    var width_left = width;
    while (true) : (i += 1) {
        const n = self.nodes.items[i];
        if (n.y > y) y = n.y;

        // If the added height exceeds our texture size, it doesn't fit.
        if ((y + height) > (self.size - 1)) return null;

        // If we have no more width left (width_left - n.width < 0)
        // then we are done.
        if (n.width >= width_left) break;
        width_left -= n.width;
    }

    return y;
}

/// Merge adjacent nodes with the same y value.
fn merge(self: *Atlas) void {
    var i: usize = 0;
    while (i < self.nodes.items.len - 1) {
        const node = &self.nodes.items[i];
        const next = self.nodes.items[i + 1];
        if (node.y == next.y) {
            node.width += next.width;
            _ = self.nodes.orderedRemove(i + 1);
            continue;
        }

        i += 1;
    }
}

/// Set the data associated with a reserved region. The data is expected
/// to fit exactly within the region.
pub fn set(self: *Atlas, reg: Region, data: []const u8) void {
    assert(reg.x < (self.size - 1));
    assert((reg.x + reg.width) <= (self.size - 1));
    assert(reg.y < (self.size - 1));
    assert((reg.y + reg.height) <= (self.size - 1));

    var i: u32 = 0;
    while (i < reg.height) : (i += 1) {
        const tex_offset = ((reg.y + i) * self.size) + reg.x;
        const data_offset = i * reg.width;
        std.mem.copy(
            u8,
            self.data[tex_offset..],
            data[data_offset .. data_offset + reg.width],
        );
    }
}

// Grow the texture to the new size, preserving all previously written data.
pub fn grow(self: *Atlas, alloc: Allocator, size_new: u32) Allocator.Error!void {
    assert(size_new >= self.size);
    if (size_new == self.size) return;

    // Preserve our old values so we can copy the old data
    const data_old = self.data;
    const size_old = self.size;

    self.data = try alloc.alloc(u8, size_new * size_new);
    defer alloc.free(data_old); // Only defer after new data succeeded
    self.size = size_new; // Only set size after new alloc succeeded
    std.mem.set(u8, self.data, 0);
    self.set(.{
        .x = 0, // don't bother skipping border so we can avoid strides
        .y = 1, // skip the first border row
        .width = size_old,
        .height = size_old - 2, // skip the last border row
    }, data_old[size_old..]);

    // Add our new rectangle for our added righthand space
    try self.nodes.append(alloc, .{
        .x = size_old - 1,
        .y = 1,
        .width = size_new - size_old,
    });
}

// Empty the atlas. This doesn't reclaim any previously allocated memory.
pub fn clear(self: *Atlas) void {
    std.mem.set(u8, self.data, 0);
    self.nodes.clearRetainingCapacity();

    // Add our initial rectangle. This is the size of the full texture
    // and is the initial rectangle we fit our regions in. We keep a 1px border
    // to avoid artifacting when sampling the texture.
    self.nodes.appendAssumeCapacity(.{ .x = 1, .y = 1, .width = self.size - 2 });
}

test "exact fit" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 34); // +2 for 1px border
    defer atlas.deinit(alloc);

    _ = try atlas.reserve(alloc, 32, 32);
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 1, 1));
}

test "doesnt fit" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 32);
    defer atlas.deinit(alloc);

    // doesn't fit due to border
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 32, 32));
}

test "fit multiple" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 32);
    defer atlas.deinit(alloc);

    _ = try atlas.reserve(alloc, 15, 30);
    _ = try atlas.reserve(alloc, 15, 30);
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 1, 1));
}

test "writing data" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 32);
    defer atlas.deinit(alloc);

    const reg = try atlas.reserve(alloc, 2, 2);
    atlas.set(reg, &[_]u8{ 1, 2, 3, 4 });

    // 33 because of the 1px border and so on
    try testing.expectEqual(@as(u8, 1), atlas.data[33]);
    try testing.expectEqual(@as(u8, 2), atlas.data[34]);
    try testing.expectEqual(@as(u8, 3), atlas.data[65]);
    try testing.expectEqual(@as(u8, 4), atlas.data[66]);
}

test "grow" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 4); // +2 for 1px border
    defer atlas.deinit(alloc);

    const reg = try atlas.reserve(alloc, 2, 2);
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 1, 1));

    // Write some data so we can verify that growing doesn't mess it up
    atlas.set(reg, &[_]u8{ 1, 2, 3, 4 });
    try testing.expectEqual(@as(u8, 1), atlas.data[5]);
    try testing.expectEqual(@as(u8, 2), atlas.data[6]);
    try testing.expectEqual(@as(u8, 3), atlas.data[9]);
    try testing.expectEqual(@as(u8, 4), atlas.data[10]);

    // Expand by exactly 1 should fit our new 1x1 block.
    try atlas.grow(alloc, atlas.size + 1);
    _ = try atlas.reserve(alloc, 1, 1);

    // Ensure our data is still set. Not the offsets change due to size.
    try testing.expectEqual(@as(u8, 1), atlas.data[atlas.size + 1]);
    try testing.expectEqual(@as(u8, 2), atlas.data[atlas.size + 2]);
    try testing.expectEqual(@as(u8, 3), atlas.data[atlas.size * 2 + 1]);
    try testing.expectEqual(@as(u8, 4), atlas.data[atlas.size * 2 + 2]);
}
