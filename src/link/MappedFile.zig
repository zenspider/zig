const MappedFile = @This();

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.mapped_file);
const fs = std.fs;
const math = std.math;
const mem = std.mem;
const os = std.os;

const Allocator = mem.Allocator;
const File = fs.File;

tag: Tag,
raw: union {
    mmap: []align(mem.page_size) const u8,
    malloc: []const u8,
},
offset: u64 = 0,

const Tag = enum {
    mmap,
    malloc,
};

const Error = error{
    Overflow,
    InputOutput,
    OutOfMemory,
} || os.MMapError || os.SeekError || os.ReadError;

pub fn map(gpa: Allocator, file: File) Error!MappedFile {
    const file_len = math.cast(usize, try file.getEndPos()) orelse return error.Overflow;
    return mapWithOptions(gpa, file, file_len, 0);
}

pub fn mapWithOptions(gpa: Allocator, file: File, length: usize, offset: u64) Error!MappedFile {
    if (length == 0) {
        return error.InputOutput;
    }
    if (builtin.os.tag == .windows) {
        // TODO equivalent of mmap on Windows
        return malloc(gpa, file, length, offset);
    }
    return mmap(file, length, offset) catch |err| {
        log.debug("couldn't mmap file, failed with error: {s}", .{@errorName(err)});
        return malloc(gpa, file, length, offset);
    };
}

fn malloc(gpa: Allocator, file: File, length: usize, offset: u64) Error!MappedFile {
    const reader = file.reader();
    if (offset > 0) {
        try file.seekTo(offset);
    }
    const raw = try gpa.alloc(u8, length);
    errdefer gpa.free(raw);
    const amt = try reader.readAll(raw);
    if (amt != length) {
        return error.InputOutput;
    }
    return MappedFile{
        .tag = .malloc,
        .raw = .{ .malloc = raw },
    };
}

fn mmap(file: File, length: usize, offset: u64) Error!MappedFile {
    const aligned_offset = mem.alignBackwardGeneric(u64, offset, mem.page_size);
    const adjusted_length = length + (offset - aligned_offset);
    // Mold is using os.PROT.READ | os.PROT.WRITE together with os.MAP.PRIVATE most likely
    // because it is overwriting the mapped memory with some adjusted metadata when parsing
    // object files and relocations. We might want to do the same in the future.
    const raw = try os.mmap(
        null,
        adjusted_length,
        os.PROT.READ,
        os.MAP.SHARED,
        file.handle,
        aligned_offset,
    );
    return MappedFile{
        .tag = .mmap,
        .raw = .{ .mmap = raw },
        .offset = offset - aligned_offset,
    };
}

pub fn unmap(mf: MappedFile, gpa: Allocator) void {
    switch (mf.tag) {
        .mmap => os.munmap(mf.raw.mmap),
        .malloc => gpa.free(mf.raw.malloc),
    }
}

pub fn slice(mf: MappedFile) []const u8 {
    return switch (mf.tag) {
        .mmap => mf.raw.mmap[mf.offset..],
        .malloc => mf.raw.malloc,
    };
}
