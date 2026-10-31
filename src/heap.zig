const std = @import("std");
const v = @import("value.zig");

pub const Heap = struct {
    backing: std.mem.Allocator,
    head: ?*v.Obj = null,
    tail: ?*v.Obj = null,
    bytes_allocated: usize = 0,
    next_gc_threshold: usize = 1024 * 1024,
    gray: std.ArrayList(*v.Obj) = .empty,
    interned: std.StringHashMap(*v.ObjString),

    pub fn init(backing: std.mem.Allocator) Heap {
        return .{
            .backing = backing,
            .interned = std.StringHashMap(*v.ObjString).init(backing),
        };
    }

    pub fn deinit(self: *Heap) void {
        self.gray.deinit(self.backing);
        var cur = self.head;
        while (cur) |obj| {
            const next = obj.next;
            self.freeObject(obj);
            cur = next;
        }
        self.head = null;
        self.tail = null;
        self.interned.deinit();
    }

    /// Raw allocation through the descriptor. Caller initializes payload fields.
    pub fn alloc(self: *Heap, desc: *const v.ObjDescriptor, extra: u32) !*v.Obj {
        const total = @max(desc.fixed_size, desc.min_size) + extra;
        const size: u32 = @intCast(total);
        const raw = try self.backing.alignedAlloc(u8, @alignOf(v.Obj), size);
        const obj: *v.Obj = @ptrCast(@alignCast(raw.ptr));

        obj.* = .{
            .obj_type = desc.obj_type,
            .gc_flags = 0,
            .size = size,
            .next = null,
            .descriptor = desc,
        };

        if (self.tail) |t| {
            t.next = obj;
            self.tail = obj;
        } else {
            self.head = obj;
            self.tail = obj;
        }
        self.bytes_allocated += size;
        return obj;
    }

    /// Content-addressed strings; interned strings are immortal and live to `deinit`.
    pub fn internString(self: *Heap, bytes: []const u8) !*v.ObjString {
        if (self.interned.get(bytes)) |s| return s;

        const owned = try self.backing.dupe(u8, bytes);
        errdefer self.backing.free(owned);

        const obj = try self.alloc(&v.string_descriptor, 0);
        const s: *v.ObjString = @ptrCast(@alignCast(obj));
        s.bytes = owned;
        s.hash = @truncate(std.hash.Wyhash.hash(0, bytes));
        s.obj.gc_flags |= v.Obj.GC_IMMORTAL;
        self.bytes_allocated += owned.len;

        try self.interned.put(owned, s);
        return s;
    }

    pub fn newError(self: *Heap, tag: v.ErrorTag) !*v.ObjError {
        const obj = try self.alloc(&v.error_descriptor, 0);
        const e: *v.ObjError = @ptrCast(@alignCast(obj));
        e.tag = tag;
        return e;
    }

    pub fn shouldCollect(self: *const Heap) bool {
        return self.bytes_allocated >= self.next_gc_threshold;
    }

    pub fn collect(self: *Heap, roots: []const v.Value) !void {
        for (roots) |r| self.markValue(r);
        self.drain();
        self.sweep();
        self.next_gc_threshold = @max(self.bytes_allocated * 2, 1024 * 1024);
    }

    fn markValue(self: *Heap, val: v.Value) void {
        switch (val) {
            .obj => |obj| {
                if (obj.isMarked()) return;
                obj.mark();
                self.gray.append(self.backing, obj) catch return;
            },
            else => {},
        }
    }

    fn drain(self: *Heap) void {
        while (self.gray.pop()) |obj| {
            if (obj.descriptor.trace) |trace| {
                var visitor: v.TraceVisitor = .{
                    .ctx = self,
                    .markFn = struct {
                        fn mark(ctx: *anyopaque, o: *v.Obj) void {
                            const self: *Heap = @ptrCast(@alignCast(ctx));
                            self.markValue(.{ .obj = o });
                        }
                    }.mark,
                };
                trace(obj, &visitor);
            } else {
                for (obj.descriptor.ref_fields) |rf| {
                    const p: *const v.Value = @ptrFromInt(@intFromPtr(obj) + rf.offset);
                    self.markValue(p.*);
                }
            }
        }
    }

    fn sweep(self: *Heap) void {
        var prev: ?*v.Obj = null;
        var cur = self.head;
        while (cur) |obj| {
            const next = obj.next;
            if (obj.isImmortal()) {
                obj.clearMark();
                prev = obj;
                cur = next;
                continue;
            }
            if (obj.isMarked()) {
                obj.clearMark();
                prev = obj;
                cur = next;
            } else {
                if (prev) |p| p.next = next else self.head = next;
                if (self.tail == obj) self.tail = prev;
                self.freeObject(obj);
                cur = next;
            }
        }
    }

    fn freeObject(self: *Heap, obj: *v.Obj) void {
        switch (obj.obj_type) {
            .string => {
                const s: *v.ObjString = @fieldParentPtr("obj", obj);
                self.bytes_allocated -= @sizeOf(v.ObjString) + s.bytes.len;
                self.backing.free(s.bytes);
            },
            .error_obj => {
                self.bytes_allocated -= @sizeOf(v.ObjError);
            },
        }
        const raw: [*]u8 = @ptrCast(obj);
        self.backing.free(raw[0..obj.size]);
    }
};
