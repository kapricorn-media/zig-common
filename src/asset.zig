const std = @import("std");

const m = @import("zigkm-common-math");
const stb = @import("zigkm-common-stb");

pub const FontCharData = struct {
    offset: m.Vec2,
    size: m.Vec2,
    uvOffset: m.Vec2,
    advanceX: f32,
};

pub const FontLoadData = struct {
    size: f32,
    scale: f32,
    charData: [256]FontCharData,

    const Self = @This();

    pub fn load(self: *Self, atlasSize: usize, fontFileData: []const u8, size: f32, scale: f32, allocator: std.mem.Allocator) ![]const u8
    {
        var tempArena = std.heap.ArenaAllocator.init(allocator);
        defer tempArena.deinit();
        var tempAllocator = tempArena.allocator();

        self.size = size;
        self.scale = scale;

        const width = atlasSize;
        const height = atlasSize;
        var pixelBytes = try allocator.alloc(u8, width * height);
        std.mem.set(u8, pixelBytes, 0);
        var context: stb.stbtt_pack_context = undefined;
        if (stb.stbtt_PackBegin(&context, &pixelBytes[0], @intCast(c_int, width), @intCast(c_int, height), @intCast(c_int, width), 1, &tempAllocator) != 1) {
            return error.stbtt_PackBegin;
        }
        const oversampleN = 1;
        stb.stbtt_PackSetOversampling(&context, oversampleN, oversampleN);

        var charData = try tempAllocator.alloc(stb.stbtt_packedchar, self.charData.len);
        if (stb.stbtt_PackFontRange(&context, &fontFileData[0], 0, size / scale, 0, @intCast(c_int, charData.len), &charData[0]) != 1) {
            return error.stbtt_PackFontRange;
        }

        stb.stbtt_PackEnd(&context);

        for (charData) |cd, i| {
            const sizeF = m.Vec2.initFromVec2i(m.Vec2i.init(cd.x1 - cd.x0, cd.y1 - cd.y0));
            self.charData[i] = FontCharData {
                .offset = m.Vec2.init(cd.xoff, -(sizeF.y + cd.yoff)),
                .size = sizeF,
                .uvOffset = m.Vec2.init(
                    @intToFloat(f32, cd.x0) / @intToFloat(f32, width),
                    @intToFloat(f32, height - cd.y1) / @intToFloat(f32, height), // TODO should do -1 ?
                ),
                .advanceX = cd.xadvance,
            };
        }

        return pixelBytes;
    }
};
