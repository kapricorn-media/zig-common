const std = @import("std");

const m = @import("zigkm-math");
const zigimg = @import("zigimg");

const psd = @import("psd.zig");

fn readIntBigEndian(comptime T: type, data: []const u8) !T
{
    var stream = std.io.fixedBufferStream(data);
    var reader = stream.reader();
    return reader.readInt(T, .big);
}

fn trim(image: zigimg.Image, slice: m.Rect2usize) m.Rect2usize
{
    std.debug.assert(image.pixels == .rgba32); // need alpha channel for current trim
    std.debug.assert(slice.min.x <= image.width and slice.min.y <= image.height);
    std.debug.assert(slice.max.x <= image.width and slice.max.y <= image.height);

    const sliceSize = slice.size();
    var max = slice.min;
    var min = slice.max;
    var y: usize = 0;
    while (y < sliceSize.y) : (y += 1) {
        var x: usize = 0;
        while (x < sliceSize.x) : (x += 1) {
            const pixelCoord = m.add(slice.min, m.Vec2usize.init(x, y));
            const pixelInd = pixelCoord.y * image.width + pixelCoord.x;
            const pixel = image.pixels.rgba32[pixelInd];
            if (pixel.a != 0) {
                max = m.max(max, pixelCoord);
                min = m.min(min, pixelCoord);
            }
        }
    }

    if (min.x > max.x and min.y > max.y) {
        return m.Rect2usize.zero;
    }
    return m.Rect2usize.init(m.add(slice.min, min), m.add(m.add(slice.min, max), m.Vec2usize.one));
}

fn deserializeMapValue(comptime T: type, data: []const u8, value: *T) !usize
{
    switch (@typeInfo(T)) {
        .Int => {
            const valueU64 = try readIntBigEndian(u64, data);
            value.* = @as(T, @intCast(valueU64));
            return 8;
        },
        .Pointer => |tiPtr| {
            switch (tiPtr.size) {
                .Slice => {
                    if (comptime tiPtr.child != u8) {
                        @compileLog("Unsupported slice type", tiPtr.child);
                        unreachable;
                    }
                    const len = try readIntBigEndian(u64, data);
                    if (data.len < len + 8) {
                        return error.BadData;
                    }
                    value.* = data[8..8+len];
                    return 8 + len;
                },
                else => {
                    @compileLog("Unsupported type", T);
                    unreachable;
                },
            }
        },
        .Array => |tiArray| {
            switch (tiArray.child) {
                u8 => {
                    @memcpy(value, data[0..tiArray.len]);
                    return tiArray.len;
                },
                else => {
                    var i: usize = 0;
                    for (value) |*v| {
                        const n = try deserializeMapValue(tiArray.child, data[i..], v);
                        i += n;
                    }
                    return i;
                }
            }
        },
        .Struct => |tiStruct| {
            var i: usize = 0;
            inline for (tiStruct.fields) |f| {
                const n = try deserializeMapValue(f.type, data[i..], &@field(value, f.name));
                i += n;
            }
        },
        else => {
            @compileLog("Unsupported type", T);
            unreachable;
        },
    }

    return 0;
}

fn serializeMapValue(writer: anytype, value: anytype) !void
{
    var buf: [8]u8 = undefined;

    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .Int => {
            const valueU64 = @as(u64, @intCast(value));
            std.mem.writeInt(u64, &buf, valueU64, .big);
            try writer.writeAll(&buf);
        },
        .Pointer => |tiPtr| {
            switch (tiPtr.size) {
                .Slice => {
                    if (comptime tiPtr.child != u8) {
                        @compileLog("Unsupported slice type", tiPtr.child);
                        unreachable;
                    }
                    std.mem.writeInt(u64, &buf, value.len, .big);
                    try writer.writeAll(&buf);
                    try writer.writeAll(value);
                },
                else => {
                    @compileLog("Unsupported type", T);
                    unreachable;
                },
            }
        },
        .Array => |tiArray| {
            switch (tiArray.child) {
                u8 => {
                    try writer.writeAll(&value);
                },
                else => {
                    for (value) |v| {
                        try serializeMapValue(writer, v);
                    }
                }
            }
        },
        .Struct => |tiStruct| {
            inline for (tiStruct.fields) |f| {
                try serializeMapValue(writer, @field(value, f.name));
            }
        },
        else => {
            @compileLog("Unsupported type", T);
            unreachable;
        },
    }
}

pub fn deserializeMap(
    comptime ValueType: type,
    data: []const u8,
    map: *std.StringHashMap(ValueType)) !usize
{
    const numEntries = blk: {
        var stream = std.io.fixedBufferStream(data);
        var reader = stream.reader();
        break :blk try reader.readInt(u64, .big);
    };

    var i: usize = 8;
    var iMax: usize = 0;
    var n: usize = 0;
    while (n < numEntries) : (n += 1) {
        const pathEnd = std.mem.indexOfScalarPos(u8, data, i, 0) orelse return error.BadData;
        const path = data[i..pathEnd];
        if (pathEnd + 1 + 16 > data.len) {
            return error.BadData;
        }
        const intBuf = data[pathEnd+1..pathEnd+1+16];
        var intStream = std.io.fixedBufferStream(intBuf);
        var intReader = intStream.reader();
        const valueIndex = try intReader.readInt(u64, .big);
        const valueSize = try intReader.readInt(u64, .big);
        if (valueIndex > data.len) {
            return error.BadData;
        }
        if (valueIndex + valueSize > data.len) {
            return error.BadData;
        }
        const valueEnd = valueIndex + valueSize;
        const valueBytes = data[valueIndex..valueEnd];
        iMax = @max(iMax, valueEnd);

        i = pathEnd + 1 + 16;

        var v: ValueType = undefined;
        _ = try deserializeMapValue(ValueType, valueBytes, &v);
        try map.put(path, v);
    }

    return @max(iMax, 8);
}

pub fn serializeMap(
    comptime ValueType: type,
    map: std.StringHashMap(ValueType),
    allocator: std.mem.Allocator) ![]const u8
{
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    var writer = out.writer();

    try writer.writeInt(u64, map.count(), .big);
    var mapIt = map.iterator();
    while (mapIt.next()) |entry| {
        try writer.writeAll(entry.key_ptr.*);
        try writer.writeByte(0);
        try writer.writeByteNTimes(0, 16); // filled later
    }
    const endOfKeys = out.items.len;

    var buf: [8]u8 = undefined;
    mapIt = map.iterator();
    var i: usize = @sizeOf(u64); // skip initial map.count()
    while (mapIt.next()) |entry| {
        const dataIndex = out.items.len;
        try serializeMapValue(writer, entry.value_ptr.*);
        const dataSize = out.items.len - dataIndex;

        i = std.mem.indexOfScalarPos(u8, out.items, i, 0) orelse return error.BadData;
        i += 1;
        if (i + 16 > out.items.len) {
            return error.BadData;
        }

        std.mem.writeInt(u64, &buf, dataIndex, .big);
        @memcpy(out.items[i..i+8], &buf);
        std.mem.writeInt(u64, &buf, dataSize, .big);
        @memcpy(out.items[i+8..i+16], &buf);
        i += 16;
        if (i > endOfKeys) {
            return error.BadData;
        }
    }

    return out.toOwnedSlice();
}

test {
    const allocator = std.testing.allocator;

    var map = std.StringHashMap(SourceEntry).init(allocator);
    defer map.deinit();

    var entry: SourceEntry = undefined;
    @memset(&entry.md5Checksum, 6);
    for (&entry.children.buffer) |*e| {
        e.len = 0;
    }
    entry.children.len = 2;
    entry.children.set(0, "hello, world");
    entry.children.set(1, "goodbye, world");

    try map.put("entry1", entry);
    try map.put("entry1234", entry);

    const bytes = try serializeMap(SourceEntry, map, allocator);
    defer allocator.free(bytes);

    var mapOut = std.StringHashMap(SourceEntry).init(allocator);
    defer mapOut.deinit();
    const n = try deserializeMap(SourceEntry, bytes, &mapOut);
    try std.testing.expectEqual(n, bytes.len);
    // var mapOut = try deserializeMap(SourceEntry, bytes, allocator);
    // defer mapOut.deinit();

    try std.testing.expectEqual(map.count(), mapOut.count());
    var mapIt = map.iterator();
    while (mapIt.next()) |e| {
        const key = e.key_ptr.*;
        const v = mapOut.get(key) orelse {
            std.log.err("Missing key {s}", .{key});
            return error.MissingKey;
        };
        const value = e.value_ptr.*;
        try std.testing.expectEqualSlices(u8, &value.md5Checksum, &v.md5Checksum);
        try std.testing.expectEqual(value.children.len, v.children.len);
        for (value.children.buffer, 0..) |_, i| {
            try std.testing.expectEqualStrings(value.children.buffer[i], v.children.buffer[i]);
        }
    }
}

pub const SourceEntry = struct {
    md5Checksum: [16]u8,
    children: std.BoundedArray([]const u8, 32),
};

pub const Data = struct {
    arenaAllocator: std.heap.ArenaAllocator,
    sourceMap: std.StringHashMap(SourceEntry),
    map: std.StringHashMap([]const u8),
    bytes: ?[]const u8,

    const Self = @This();

    pub fn load(self: *Self, allocator: std.mem.Allocator) void
    {
        self.arenaAllocator = std.heap.ArenaAllocator.init(allocator);
        self.sourceMap = std.StringHashMap(SourceEntry).init(self.arenaAllocator.allocator());
        self.map = std.StringHashMap([]const u8).init(self.arenaAllocator.allocator());
        self.bytes = null;
    }

    pub fn loadFromFile(self: *Self, filePath: []const u8, allocator: std.mem.Allocator) !void
    {
        self.load(allocator);
        const selfAllocator = self.arenaAllocator.allocator();

        const cwd = std.fs.cwd();
        const file = try cwd.openFile(filePath, .{});
        defer file.close();
        const fileBytes = try file.readToEndAlloc(selfAllocator, 1024 * 1024 * 1024);

        const n1 = try deserializeMap(SourceEntry, fileBytes, &self.sourceMap);
        const n2 = try deserializeMap([]const u8, fileBytes[n1..], &self.map);
        if (n1 + n2 != fileBytes.len) {
            return error.BadData;
        }
        self.bytes = fileBytes;
    }

    pub fn saveToFile(self: *const Self, filePath: []const u8, allocator: std.mem.Allocator) !void
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const tempAllocator = arena.allocator();

        var file = try std.fs.cwd().createFile(filePath, .{});
        defer file.close();

        const sourceMapSerialized = try serializeMap(SourceEntry, self.sourceMap, tempAllocator);
        try file.writeAll(sourceMapSerialized);
        const mapSerialized = try serializeMap([]const u8, self.map, tempAllocator);
        try file.writeAll(mapSerialized);
    }

    pub fn deinit(self: *Self) void
    {
        self.arenaAllocator.deinit();
    }

    pub fn put(self: *Self, path: []const u8, data: []const u8, tempAllocator: std.mem.Allocator) !void
    {
        const selfAllocator = self.arenaAllocator.allocator();

        var sourceEntry: SourceEntry = undefined;
        var md5 = std.crypto.hash.Md5.init(.{});
        md5.update(data);
        md5.final(&sourceEntry.md5Checksum);
        sourceEntry.children.len = 0;
        // Important to clear all children for serialization logic
        for (&sourceEntry.children.buffer) |*e| {
            e.len = 0;
        }
        const pathDupe = try selfAllocator.dupe(u8, path);

        if (std.mem.endsWith(u8, path, ".psd")) {
            var psdFile: psd.PsdFile = undefined;
            try psdFile.load(data, tempAllocator);
            for (psdFile.layers, 0..) |l, i| {
                if (!l.visible) {
                    continue;
                }
                if (m.eql(l.size, m.Vec2usize.zero)) {
                    continue;
                }

                const layerPath = try std.fmt.allocPrint(selfAllocator, "{s}/{s}.layer", .{path, l.name});
                sourceEntry.children.buffer[sourceEntry.children.len] = layerPath;
                sourceEntry.children.len += 1;

                const layerImage = try zigimg.Image.create(tempAllocator, l.size.x, l.size.y, .rgba32);
                const layerDst = m.Rect2usize.init(m.Vec2usize.zero, l.size);
                _ = try psdFile.layers[i].getPixelDataImage(null, l.topLeft, layerImage, layerDst);

                // Kinda disappointed by this API, unless I'm missing something...
                // I really wanna use a std.ArrayList(u8) writer for this.
                const tempBuf = try tempAllocator.alloc(u8, l.size.x * l.size.y * 4);
                const pngBytes = try layerImage.writeToMemory(tempBuf, .{.png = .{}});
                try self.map.put(layerPath, try selfAllocator.dupe(u8, pngBytes));
                // _ = pngBytes;

                // _ = i;
                // @panic("TODO: reimplement PSD layer stuff");
                // // TODO this is yorstory-specific stuff but whatever
                // const safeAspect = 3;
                // const sizeX = @as(usize, @intFromFloat(@as(f32, @floatFromInt(psdFile.canvasSize.y)) * safeAspect));
                // const parallaxSize = m.Vec2usize.init(sizeX, psdFile.canvasSize.y);
                // const topLeft = m.Vec2i.init(@divTrunc((@as(i32, @intCast(psdFile.canvasSize.x)) - @as(i32, @intCast(sizeX))), 2), 0);
                // var layerImage = try zigimg.Image.create(tempAllocator, parallaxSize.x, parallaxSize.y, .rgba32);
                // @memset(layerImage.pixels.asBytes(), 0);
                // const layerDst = m.Rect2usize.init(m.Vec2usize.zero, parallaxSize);
                // _ = try psdFile.layers[i].getPixelDataImage(null, topLeft, layerImage, layerDst);

                // const sliceAll = m.Rect2usize.init(
                //     m.Vec2usize.zero,
                //     m.Vec2usize.init(layerImage.width, layerImage.height)
                // );
                // const sliceTrim = trim(layerImage, sliceAll);
                // const slice = blk: {
                //     const offsetLeftX = sliceTrim.min.x - sliceAll.min.x;
                //     const offsetRightX = (sliceAll.min.x + sliceAll.size().x) - (sliceTrim.min.x + sliceTrim.size().x);
                //     const offsetMin = @min(offsetLeftX, offsetRightX);
                //     break :blk m.Rect2usize.initOriginSize(
                //         m.Vec2usize.init(sliceAll.min.x + offsetMin, sliceAll.min.y),
                //         m.Vec2usize.init(sliceAll.size().x - offsetMin * 2, sliceAll.size().y),
                //     );
                // };

                // // TODO don't chunk, just save as a PNG
                // const chunkSize = calculateChunkSize(slice.size(), CHUNK_SIZE);
                // const chunked = try imageToPngChunkedFormat(layerImage, slice, chunkSize, allocator);

                // try self.map.put(layerPath, try selfAllocator.dupe(u8, chunked));
                std.log.info("Inserted {s}", .{layerPath});
            }
        } else {
            sourceEntry.children.len = 1;
            sourceEntry.children.set(0, pathDupe);
            try self.map.put(pathDupe, try selfAllocator.dupe(u8, data));
        }

        try self.sourceMap.put(pathDupe, sourceEntry);
    }

    pub fn fileExists(self: *const Self, path: []const u8, md5Checksum: *const [16]u8) bool
    {
        if (self.sourceMap.get(path)) |src| {
            if (std.mem.eql(u8, &src.md5Checksum, md5Checksum)) {
                return true;
            }
        }
        return false;
    }

    fn addIfNewOrUpdatedFilesystem(
        self: *Self, path: []const u8, fileData: []const u8, tempAllocator: std.mem.Allocator) !void
    {
        const md5 = calculateMd5Checksum(fileData);
        if (self.fileExists(path, &md5)) {
            std.log.info("Already in bigdata: {s}", .{path});
            return;
        }

        std.log.info("Inserting {s}", .{path});
        try self.put(path, fileData, tempAllocator);
    }

    pub fn fillFromFilesystem(self: *Self, path: []const u8, allocator: std.mem.Allocator) !void
    {
        const cwd = std.fs.cwd();
        var dir = try cwd.openDir(path, .{});
        defer dir.close();

        var dirIterable = try cwd.openDir(path, .{.iterate = true});
        defer dirIterable.close();

        var walker = try dirIterable.walk(allocator);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) {
                continue;
            }

            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const tempAllocator = arena.allocator();

            const file = try dir.openFile(entry.path, .{});
            defer file.close();
            const fileData = try file.readToEndAlloc(tempAllocator, 1024 * 1024 * 1024);

            const filePath = try std.fmt.allocPrint(tempAllocator, "/{s}", .{entry.path});
            std.mem.replaceScalar(u8, filePath, '\\', '/');
            try self.addIfNewOrUpdatedFilesystem(filePath, fileData, tempAllocator);
        }
    }
};

pub fn calculateMd5Checksum(data: []const u8) [16]u8
{
    var buf: [16]u8 = undefined;
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(data);
    md5.final(&buf);
    return buf;
}
