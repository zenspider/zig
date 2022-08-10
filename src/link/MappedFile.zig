//! Memory mapping utility for large files.
//! Its intended use is to map input object files into memory using `mmap` on supported
//! hosts with a fallback to `malloc` in case the former fails or is unsupported (e.g.,
//! on Windows).

const MappedFile = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const log = std.log.scoped(.mapped_file);
const fs = std.fs;
const math = std.math;
const mem = std.mem;
const os = std.os;

const Allocator = mem.Allocator;
const File = fs.File;

tag: Tag,
raw: union {
    /// Backing memory when mapped directly with `mmap`
    mmap: []align(mem.page_size) const u8,
    /// Backing memory when allocated with `malloc`
    malloc: []const u8,
},
/// Offset into `mmap`ed memory to account for the requirement for
/// the mapped memory to be page size aligned
offset: usize = 0,

const Tag = enum {
    mmap,
    malloc,
};

const Strategy = enum {
    /// Uses `mmap` on supported hosts, fallbacks to `malloc` if `mmap` fails or is unavailable
    auto,
    /// Uses `mmap` only
    mmap,
    /// Uses `malloc` only
    malloc,
};

const Error = error{
    Overflow,
    InputOutput,
    OutOfMemory,
} || os.MMapError || os.SeekError || os.ReadError;

/// Maps the entire file using either `mmap` (preferred), or `malloc` (if the former
/// fails and/or is unavailable).
/// Needs to be free'd using `unmap`.
pub fn map(gpa: Allocator, file: File, strategy: Strategy) Error!MappedFile {
    const file_len = math.cast(usize, try file.getEndPos()) orelse return error.Overflow;
    return mapWithOptions(gpa, file, file_len, 0, strategy);
}

/// Same as `map` however allows to specify the requested mapped length as well as start offset.
/// Note that offset is will be backwards aligned to the first available page boundary.
pub fn mapWithOptions(
    gpa: Allocator,
    file: File,
    length: usize,
    offset: usize,
    strategy: Strategy,
) Error!MappedFile {
    if (length == 0) {
        return error.InputOutput;
    }
    if (builtin.os.tag == .windows) {
        assert(strategy == .auto or strategy == .malloc);
        // TODO equivalent of mmap on Windows
        return malloc(gpa, file, length, offset);
    }
    switch (strategy) {
        .auto => return mmap(file, length, offset) catch |err| {
            log.debug("couldn't mmap file, failed with error: {s}", .{@errorName(err)});
            return malloc(gpa, file, length, offset);
        },
        .mmap => return mmap(file, length, offset),
        .malloc => return malloc(gpa, file, length, offset),
    }
}

fn malloc(gpa: Allocator, file: File, length: usize, offset: usize) Error!MappedFile {
    const reader = file.reader();
    try file.seekTo(offset);
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

fn mmap(file: File, length: usize, offset: usize) Error!MappedFile {
    const aligned_offset = math.cast(usize, mem.alignBackwardGeneric(u64, offset, mem.page_size)) orelse
        return error.Overflow;
    const adjusted_length = length + (offset - aligned_offset);
    const raw = try os.mmap(
        null,
        adjusted_length,
        os.PROT.READ | os.PROT.WRITE,
        os.MAP.PRIVATE,
        file.handle,
        aligned_offset,
    );
    return MappedFile{
        .tag = .mmap,
        .raw = .{ .mmap = raw },
        .offset = offset - aligned_offset,
    };
}

/// Call to unmap/deallocate mapped memory.
pub fn unmap(mf: MappedFile, gpa: Allocator) void {
    if (builtin.os.tag == .windows) {
        assert(mf.tag == .malloc);
        gpa.free(mf.raw.malloc);
    } else switch (mf.tag) {
        .mmap => os.munmap(mf.raw.mmap),
        .malloc => gpa.free(mf.raw.malloc),
    }
}

/// Returns the mapped memory.
/// In case of `mmap`, it takes into account backwards aligned `offset` and thus it is not required
/// to adjust the slice as it is done automatically for the caller.
pub fn slice(mf: MappedFile) []const u8 {
    return switch (mf.tag) {
        .mmap => mf.raw.mmap[mf.offset..],
        .malloc => mf.raw.malloc,
    };
}
