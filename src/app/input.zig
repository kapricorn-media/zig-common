const std = @import("std");

const m = @import("zigkm-math");

pub const PointerSource = enum {
    Mouse,
    Touch,
};

pub const InputState = struct
{
    mouseState: MouseState,
    keyboardState: KeyboardState,
    deviceState: DeviceState,
    touchState: TouchState,
    pointerSource: PointerSource,

    const Self = @This();

    pub fn clear(self: *Self) void
    {
        self.mouseState.clear();
        self.keyboardState.clear();
        self.touchState.clear();
        self.pointerSource = .Mouse;
    }

    pub fn updateStart(self: *Self) void
    {
        self.touchState.updateStart();
    }

    pub fn updateEnd(self: *Self) void
    {
        self.mouseState.clear();
        self.keyboardState.clear();
        self.touchState.updateEnd();
    }

    pub fn addClickEvent(self: *Self, event: ClickEvent) void
    {
        self.mouseState.addClickEvent(event);
        self.pointerSource = .Mouse;
    }

    pub fn addWheelDelta(self: *Self, delta: m.Vec2i) void
    {
        self.mouseState.wheelDelta = m.add(self.mouseState.wheelDelta, delta);
    }

    pub fn addKeyEvent(self: *Self, event: KeyEvent) void
    {
        self.keyboardState.addKeyEvent(event);
    }

    pub fn addUtf32(self: *Self, utf32: []const u32) void
    {
        self.keyboardState.addUtf32(utf32);
    }

    pub fn addTouchEvent(self: *Self, event: TouchEvent) void
    {
        self.touchState.addTouchEvent(event);
        self.pointerSource = .Touch;
    }
};

pub const ClickType = enum {
    Left,
    Middle,
    Right,
    Other,
};

pub const ClickEvent = struct {
    pos: m.Vec2i,
    clickType: ClickType,
    down: bool,
};

pub const MouseState = struct {
    pos: m.Vec2i,
    wheelDelta: m.Vec2i,
    clickEvents: std.BoundedArray(ClickEvent, 64),

    const Self = @This();

    fn clear(self: *Self) void
    {
        self.wheelDelta = m.Vec2i.zero;
        self.clickEvents.len = 0;
    }

    fn addClickEvent(self: *Self, event: ClickEvent) void
    {
        var e = self.clickEvents.addOne() catch return;
        e.* = event;
    }
};

pub const KeyEvent = struct {
    keyCode: i32,
    down: bool,
};

pub const KeyboardState = struct {
    keyEvents: std.BoundedArray(KeyEvent, 64),
    utf32: std.BoundedArray(u32, 4096),

    const Self = @This();

    fn clear(self: *Self) void
    {
        self.keyEvents.len = 0;
        self.utf32.len = 0;
    }

    fn addKeyEvent(self: *Self, event: KeyEvent) void
    {
        var k = self.keyEvents.addOne() catch return;
        k.* = event;
    }

    fn addUtf32(self: *Self, utf32: []const u32) void
    {
        self.utf32.appendSlice(utf32) catch return;
    }

    pub fn keyDown(self: Self, keyCode: i32) bool
    {
        const keyEvents = self.keyEvents[0..self.numKeyEvents];
        var latestDown = false;
        for (keyEvents) |e| {
            if (e.keyCode == keyCode) {
                latestDown = e.down;
            }
        }
        return latestDown;
    }
};

pub const DeviceState = struct {
    angles: m.Vec3,
};

pub const TouchPhase = enum
{
    Begin,
    Still,
    Move,
    End,
    Cancel,
};

pub const TouchEvent = struct
{
    id: u64,
    pos: m.Vec2i,
    tapCount: u32,
    phase: TouchPhase,
};

const ActiveTouch = struct
{
    id: u64,
    new: bool, // new this frame?
    ending: bool, // ending this frame?
    updated: bool, // updated this frame? internal
    posStart: m.Vec2i,
    i: u32, // index of current pos
    n: u32, // number of active elements in pos
    pos: [10]m.Vec2i,

    const Self = @This();

    pub fn isTap(self: *const Self) bool
    {
        // TODO: actually, if we started in one point, scrolled, then came back to that point,
        // we should still not count that as a tap...
        const thresholdPixels = 10;
        const pos = self.getPos();
        return m.magSq(m.sub(pos, self.posStart)) < (thresholdPixels * thresholdPixels);
    }

    pub fn getPos(self: *const Self) m.Vec2i
    {
        std.debug.assert(self.i < self.pos.len);
        std.debug.assert(self.n != 0);
        std.debug.assert(self.n <= self.pos.len);

        return self.pos[self.i];
    }

    pub fn getPrevPos(self: *const Self) ?m.Vec2i
    {
        std.debug.assert(self.i < self.pos.len);
        std.debug.assert(self.n <= self.pos.len);

        if (self.n <= 1) {
            return null;
        }
        const prevInd = if (self.i == 0) self.pos.len - 1 else self.i - 1;
        return self.pos[prevInd];
    }

    pub fn getWeightedVel(self: *const Self) m.Vec2
    {
        std.debug.assert(self.i < self.pos.len);
        std.debug.assert(self.n != 0);
        std.debug.assert(self.n <= self.pos.len);

        const weights = [10]f32 {
            0.5,
            3.0,
            2.0,
            1.5,
            1.0,
            0.75,
            0.5,
            0.4,
            0.3,
            0.2,
        };

        var mean = m.Vec2.zero;

        var i = self.i;
        var n: u32 = 0;
        while (n < self.n - 1) : (n += 1) {
            const iPrev = if (i == 0) @as(u32, @intCast(self.pos.len - 1)) else i - 1;
            const delta = m.sub(self.pos[i], self.pos[iPrev]);
            mean = m.add(mean, m.multScalar(delta.toVec2(), weights[n]));
            i = iPrev;
        }

        return m.divScalar(mean, @as(f32, @floatFromInt(self.n)));
    }

    fn addPos(self: *Self, pos: m.Vec2i) void
    {
        std.debug.assert(self.i < self.pos.len);
        std.debug.assert(self.n <= self.pos.len);

        var newIndex = self.i + 1;
        if (newIndex >= self.pos.len) {
            newIndex = 0;
        }
        self.pos[newIndex] = pos;
        self.i = newIndex;

        if (self.n < self.pos.len) {
            self.n += 1;
        }
    }
};

pub const TouchState = struct
{
    touchEvents: std.BoundedArray(TouchEvent, 4096),
    activeTouches: std.BoundedArray(ActiveTouch, 64),

    const Self = @This();

    fn clear(self: *Self) void
    {
        self.touchEvents.len = 0;
        self.activeTouches.len = 0;
    }

    fn addTouchEvent(self: *Self, event: TouchEvent) void
    {
        var e = self.touchEvents.addOne() catch return;
        e.* = event;
    }

    fn updateStart(self: *Self) void
    {
        for (self.activeTouches.slice()) |*t| {
            t.updated = false;
        }

        for (self.touchEvents.slice()) |e| {
            var foundIndex: usize = self.activeTouches.len;
            for (self.activeTouches.slice(), 0..) |touch, j| {
                if (e.id == touch.id) {
                    foundIndex = j;
                    break;
                }
            }

            if (foundIndex != self.activeTouches.len) {
                switch (e.phase) {
                    .Begin => {
                        std.log.err("begin phase on active touch event", .{});
                    },
                    .Still, .Move => {
                        self.activeTouches.buffer[foundIndex].addPos(e.pos);
                        self.activeTouches.buffer[foundIndex].updated = true;
                    },
                    .End, .Cancel => {
                        self.activeTouches.buffer[foundIndex].addPos(e.pos);
                        self.activeTouches.buffer[foundIndex].updated = true;
                        self.activeTouches.buffer[foundIndex].ending = true;
                    },
                }
            } else {
                if (e.phase != .Begin) {
                    std.log.err("missed begin for touch", .{});
                    continue;
                }
                var t = self.activeTouches.addOne() catch {
                    std.log.err("No more space for active touches", .{});
                    continue;
                };
                t.* = .{
                    .id = e.id,
                    .new = true,
                    .ending = false,
                    .updated = true,
                    .posStart = e.pos,
                    .i = 0,
                    .n = 0,
                    .pos = undefined,
                };
                t.addPos(e.pos);
            }
        }

        for (self.activeTouches.slice()) |*t| {
            if (!t.updated) {
                t.addPos(t.getPos());
            }
        }
    }

    fn updateEnd(self: *Self) void
    {
        var i: usize = 0;
        while (i < self.activeTouches.len) {
            if (self.activeTouches.buffer[i].ending) {
                self.activeTouches.buffer[i] = self.activeTouches.buffer[self.activeTouches.len - 1];
                self.activeTouches.len -= 1;
                continue; // don't increment i
            }

            self.activeTouches.buffer[i].new = false;
            // self.activeTouches[i].addPos(
            // self.activeTouches[i].posPrev = self.activeTouches[i].pos;
            i += 1;
        }

        self.touchEvents.len = 0;
        // self.numUtf32 = 0;
    }
};
