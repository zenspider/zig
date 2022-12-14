const std = @import("../std.zig");
const assert = std.debug.assert;
const build = std.build;
const fs = std.fs;
const macho = std.macho;
const math = std.math;
const mem = std.mem;
const testing = std.testing;

const CheckObjectStep = @This();

const Allocator = mem.Allocator;
const Builder = build.Builder;
const Step = build.Step;
const EmulatableRunStep = build.EmulatableRunStep;

pub const base_id = .check_object;

step: Step,
builder: *Builder,
source: build.FileSource,
max_bytes: usize = 20 * 1024 * 1024,
nodes: std.ArrayList(*Node),
dump_symtab: bool = false,
obj_format: std.Target.ObjectFormat,
opts: Options,

pub const Options = struct {
    dump_symtab: bool = false,
};

pub fn create(
    builder: *Builder,
    source: build.FileSource,
    obj_format: std.Target.ObjectFormat,
    opts: Options,
) *CheckObjectStep {
    const gpa = builder.allocator;
    const self = gpa.create(CheckObjectStep) catch unreachable;
    self.* = .{
        .builder = builder,
        .step = Step.init(.check_file, "CheckObject", gpa, make),
        .source = source.dupe(builder),
        .nodes = std.ArrayList(*Node).init(gpa),
        .obj_format = obj_format,
        .opts = opts,
    };
    self.source.addStepDependencies(&self.step);
    return self;
}

/// Runs and (optionally) compares the output of a binary.
/// Asserts `self` was generated from an executable step.
pub fn runAndCompare(self: *CheckObjectStep) *EmulatableRunStep {
    const dependencies_len = self.step.dependencies.items.len;
    assert(dependencies_len > 0);
    const exe_step = self.step.dependencies.items[dependencies_len - 1];
    const exe = exe_step.cast(std.build.LibExeObjStep).?;
    const emulatable_step = EmulatableRunStep.create(self.builder, "EmulatableRun", exe);
    emulatable_step.step.dependOn(&self.step);
    return emulatable_step;
}

pub const Node = struct {
    b: *Builder,
    tag: Tag,
    parent: ?*Node,
    payload: Payload,
    children: std.ArrayList(*Node),

    const Tag = enum {
        root,
        match,
        not_present,
        get,
        eql,
        eq,
        gte,
    };

    const Payload = union {
        str: []const u8,
        int: u64,
    };

    fn child(self: *Node, tag: Tag, payload: Payload) *Node {
        const node = self.b.allocator.create(Node) catch unreachable;
        node.* = .{
            .b = self.b,
            .tag = tag,
            .payload = payload,
            .parent = self,
            .children = std.ArrayList(*Node).init(self.b.allocator),
        };
        self.children.append(node) catch unreachable;
        return node;
    }

    pub fn match(self: *Node, payload: []const u8) void {
        _ = self.child(.match, .{ .str = self.b.dupe(payload) });
    }

    pub fn notPresent(self: *Node, payload: []const u8) void {
        _ = self.child(.not_present, .{ .str = self.b.dupe(payload) });
    }

    pub fn get(self: *Node, payload: []const u8) *Node {
        return self.child(.get, .{ .str = self.b.dupe(payload) });
    }

    pub fn eql(self: *Node, payload: []const u8) void {
        _ = self.child(.eql, .{ .str = self.b.dupe(payload) });
    }

    pub fn eq(self: *Node, payload: u64) void {
        _ = self.child(.eq, .{ .int = payload });
    }

    pub fn gte(self: *Node, payload: u64) void {
        _ = self.child(.gte, .{ .int = payload });
    }

    /// Will return true if the `phrase` was found in the `haystack`.
    /// Some examples include:
    ///
    /// LC 0                     => will match in its entirety
    /// vmaddr {vmaddr}          => will match `vmaddr` and then extract the following value as u64
    ///                             and save under `vmaddr` global name (see `global_vars` param)
    /// name {*}libobjc{*}.dylib => will match `name` followed by a token which contains `libobjc` and `.dylib`
    ///                             in that order with other letters in between
    fn doMatch(self: *Node, haystack: []const u8, global_vars: anytype) !bool {
        assert(self.tag == .match or self.tag == .not_present);

        var candidate_var: ?struct { name: []const u8, value: []const u8 } = null;
        var hay_it = mem.tokenize(u8, mem.trim(u8, haystack, " "), " ");
        var needle_it = mem.tokenize(u8, mem.trim(u8, self.payload.str, " "), " ");

        while (needle_it.next()) |needle_tok| {
            const hay_tok = hay_it.next() orelse return false;

            if (mem.indexOf(u8, needle_tok, "{*}")) |index| {
                // We have fuzzy matchers within the search pattern, so we match substrings.
                var start = index;
                var n_tok = needle_tok;
                var h_tok = hay_tok;
                while (true) {
                    n_tok = n_tok[start + 3 ..];
                    const inner = if (mem.indexOf(u8, n_tok, "{*}")) |sub_end|
                        n_tok[0..sub_end]
                    else
                        n_tok;
                    if (mem.indexOf(u8, h_tok, inner) == null) return false;
                    start = mem.indexOf(u8, n_tok, "{*}") orelse break;
                }
            } else if (mem.startsWith(u8, needle_tok, "{")) {
                const closing_brace = mem.indexOf(u8, needle_tok, "}") orelse return error.MissingClosingBrace;
                if (closing_brace != needle_tok.len - 1) return error.ClosingBraceNotLast;

                const name = needle_tok[1..closing_brace];
                if (name.len == 0) return error.MissingBraceValue;
                const value = hay_tok;
                candidate_var = .{
                    .name = name,
                    .value = value,
                };
            } else {
                if (!mem.eql(u8, hay_tok, needle_tok)) return false;
            }
        }

        if (candidate_var) |v| {
            try global_vars.putNoClobber(v.name, v.value);
        }

        return true;
    }

    fn getVariable(self: *Node, global_vars: anytype) ![]const u8 {
        const parent_node = self.parent orelse return error.IsRoot;
        if (parent_node.tag != .get) return error.InvalidNode;
        return global_vars.get(parent_node.payload.str).?; // We already verified it exists
    }

    fn doEql(self: *Node, global_vars: anytype) !bool {
        assert(self.tag == .eql);
        return mem.eql(u8, self.payload.str, try self.getVariable(global_vars));
    }

    fn doCmp(self: *Node, tag: Tag, global_vars: anytype) !bool {
        const variable = try std.fmt.parseInt(u64, try self.getVariable(global_vars), 0);
        return switch (tag) {
            .eq => self.payload.int == variable,
            .gte => self.payload.int <= variable,
            else => unreachable,
        };
    }

    fn next(self: *Node, lines: anytype, global_vars: anytype) anyerror!void {
        switch (self.tag) {
            .match => {
                while (lines.next()) |line| {
                    if (try self.doMatch(line, global_vars)) break;
                } else {
                    std.debug.print(
                        \\
                        \\========= Expected to find: ==========================
                        \\{s}
                        \\
                    , .{self.payload.str});
                    return error.TestFailed;
                }
            },
            .not_present => {
                while (lines.next()) |line| {
                    if (try self.doMatch(line, global_vars)) {
                        std.debug.print(
                            \\
                            \\========= Expected not to find: ===================
                            \\{s}
                            \\
                        , .{self.payload.str});
                        return error.TestFailed;
                    }
                }
            },
            .get => {
                _ = global_vars.get(self.payload.str) orelse {
                    std.debug.print(
                        \\
                        \\========= Variable was not extracted: ===========
                        \\{s}
                        \\
                    , .{self.payload.str});
                    return error.TestFailed;
                };
            },
            .eql => if (!(try self.doEql(global_vars))) {
                const given = self.getVariable(global_vars) catch unreachable;
                std.debug.print(
                    \\
                    \\========= Variable does not match expected value: ===========
                    \\{s} != {s}
                    \\
                , .{ self.payload.str, given });
                return error.TestFailed;
            },
            .eq, .gte => if (!(try self.doCmp(self.tag, global_vars))) {
                const given = self.getVariable(global_vars) catch unreachable;
                std.debug.print(
                    \\
                    \\========= Variable does not match expected value: ===========
                    \\0x{x} {s} 0x{x}
                    \\
                , .{ self.payload.int, @tagName(self.tag), std.fmt.parseInt(u64, given, 0) catch unreachable });
                return error.TestFailed;
            },
            .root => {},
        }

        for (self.children.items) |child_node| {
            try child_node.next(lines, global_vars);
        }
    }
};

pub fn root(self: *CheckObjectStep) *Node {
    const node = self.builder.allocator.create(Node) catch unreachable;
    node.* = .{
        .b = self.builder,
        .tag = .root,
        .payload = undefined,
        .parent = null,
        .children = std.ArrayList(*Node).init(self.builder.allocator),
    };
    self.nodes.append(node) catch unreachable;
    return node;
}

fn make(step: *Step) !void {
    const self = @fieldParentPtr(CheckObjectStep, "step", step);

    const gpa = self.builder.allocator;
    const src_path = self.source.getPath(self.builder);
    const contents = try fs.cwd().readFileAllocOptions(
        gpa,
        src_path,
        self.max_bytes,
        null,
        @alignOf(u64),
        null,
    );

    const output = switch (self.obj_format) {
        .macho => try MachODumper.parseAndDump(gpa, contents, self.opts),
        .elf => @panic("TODO elf parser"),
        .coff => @panic("TODO coff parser"),
        .wasm => try WasmDumper.parseAndDump(gpa, contents, self.opts),
        else => unreachable,
    };

    var vars = std.StringHashMap([]const u8).init(gpa);

    for (self.nodes.items) |root_node| {
        var it = mem.tokenize(u8, output, "\r\n");
        root_node.next(&it, &vars) catch |err| switch (err) {
            error.TestFailed => {
                std.debug.print(
                    \\========= Parsed file: =======
                    \\{s}
                    \\
                , .{output});
                return err;
            },
            else => {
                std.debug.print("Unexpected error occurred!\n", .{});
                return err;
            },
        };
    }
}

const MachODumper = struct {
    const LoadCommandIterator = macho.LoadCommandIterator;
    const symtab_label = "symtab";

    fn parseAndDump(gpa: Allocator, bytes: []align(@alignOf(u64)) const u8, opts: Options) ![]const u8 {
        var stream = std.io.fixedBufferStream(bytes);
        const reader = stream.reader();

        const hdr = try reader.readStruct(macho.mach_header_64);
        if (hdr.magic != macho.MH_MAGIC_64) {
            return error.InvalidMagicNumber;
        }

        var output = std.ArrayList(u8).init(gpa);
        const writer = output.writer();

        var symtab: []const macho.nlist_64 = undefined;
        var strtab: []const u8 = undefined;
        var sections = std.ArrayList(macho.section_64).init(gpa);
        var imports = std.ArrayList([]const u8).init(gpa);

        var it = LoadCommandIterator{
            .ncmds = hdr.ncmds,
            .buffer = bytes[@sizeOf(macho.mach_header_64)..][0..hdr.sizeofcmds],
        };
        var i: usize = 0;
        while (it.next()) |cmd| {
            switch (cmd.cmd()) {
                .SEGMENT_64 => {
                    const seg = cmd.cast(macho.segment_command_64).?;
                    try sections.ensureUnusedCapacity(seg.nsects);
                    for (cmd.getSections()) |sect| {
                        sections.appendAssumeCapacity(sect);
                    }
                },
                .SYMTAB => if (opts.dump_symtab) {
                    const lc = cmd.cast(macho.symtab_command).?;
                    symtab = @ptrCast(
                        [*]const macho.nlist_64,
                        @alignCast(@alignOf(macho.nlist_64), &bytes[lc.symoff]),
                    )[0..lc.nsyms];
                    strtab = bytes[lc.stroff..][0..lc.strsize];
                },
                .LOAD_DYLIB,
                .LOAD_WEAK_DYLIB,
                .REEXPORT_DYLIB,
                => {
                    try imports.append(cmd.getDylibPathName());
                },
                else => {},
            }

            try dumpLoadCommand(cmd, i, writer);
            try writer.writeByte('\n');

            i += 1;
        }

        if (opts.dump_symtab) {
            try writer.print("{s}\n", .{symtab_label});
            for (symtab) |sym| {
                if (sym.stab()) continue;
                const sym_name = mem.sliceTo(@ptrCast([*:0]const u8, strtab.ptr + sym.n_strx), 0);
                if (sym.sect()) {
                    const sect = sections.items[sym.n_sect - 1];
                    try writer.print("0x{x} ({s},{s})", .{
                        sym.n_value,
                        sect.segName(),
                        sect.sectName(),
                    });
                    if (sym.ext()) {
                        try writer.writeAll(" external");
                    }
                    try writer.print(" {s}\n", .{sym_name});
                } else if (sym.undf()) {
                    const ordinal = @divTrunc(@bitCast(i16, sym.n_desc), macho.N_SYMBOL_RESOLVER);
                    const import_name = blk: {
                        if (ordinal <= 0) {
                            if (ordinal == macho.BIND_SPECIAL_DYLIB_SELF)
                                break :blk "self import";
                            if (ordinal == macho.BIND_SPECIAL_DYLIB_MAIN_EXECUTABLE)
                                break :blk "main executable";
                            if (ordinal == macho.BIND_SPECIAL_DYLIB_FLAT_LOOKUP)
                                break :blk "flat lookup";
                            unreachable;
                        }
                        const full_path = imports.items[@bitCast(u16, ordinal) - 1];
                        const basename = fs.path.basename(full_path);
                        assert(basename.len > 0);
                        const ext = mem.lastIndexOfScalar(u8, basename, '.') orelse basename.len;
                        break :blk basename[0..ext];
                    };
                    try writer.writeAll("(undefined)");
                    if (sym.weakRef()) {
                        try writer.writeAll(" weak");
                    }
                    if (sym.ext()) {
                        try writer.writeAll(" external");
                    }
                    try writer.print(" {s} (from {s})\n", .{
                        sym_name,
                        import_name,
                    });
                } else unreachable;
            }
        }

        return output.toOwnedSlice();
    }

    fn dumpLoadCommand(lc: macho.LoadCommandIterator.LoadCommand, index: usize, writer: anytype) !void {
        // print header first
        try writer.print(
            \\LC {d}
            \\cmd {s}
            \\cmdsize {d}
        , .{ index, @tagName(lc.cmd()), lc.cmdsize() });

        switch (lc.cmd()) {
            .SEGMENT_64 => {
                const seg = lc.cast(macho.segment_command_64).?;
                try writer.writeByte('\n');
                try writer.print(
                    \\segname {s}
                    \\vmaddr 0x{x}
                    \\vmsize 0x{x}
                    \\fileoff 0x{x}
                    \\filesz 0x{x}
                , .{
                    seg.segName(),
                    seg.vmaddr,
                    seg.vmsize,
                    seg.fileoff,
                    seg.filesize,
                });

                for (lc.getSections()) |sect| {
                    try writer.writeByte('\n');
                    try writer.print(
                        \\sectname {s}
                        \\addr 0x{x}
                        \\size 0x{x}
                        \\offset 0x{x}
                        \\align 0x{x}
                    , .{
                        sect.sectName(),
                        sect.addr,
                        sect.size,
                        sect.offset,
                        sect.@"align",
                    });
                }
            },

            .ID_DYLIB,
            .LOAD_DYLIB,
            .LOAD_WEAK_DYLIB,
            .REEXPORT_DYLIB,
            => {
                const dylib = lc.cast(macho.dylib_command).?;
                try writer.writeByte('\n');
                try writer.print(
                    \\name {s}
                    \\timestamp {d}
                    \\current version 0x{x}
                    \\compatibility version 0x{x}
                , .{
                    lc.getDylibPathName(),
                    dylib.dylib.timestamp,
                    dylib.dylib.current_version,
                    dylib.dylib.compatibility_version,
                });
            },

            .MAIN => {
                const main = lc.cast(macho.entry_point_command).?;
                try writer.writeByte('\n');
                try writer.print(
                    \\entryoff 0x{x}
                    \\stacksize 0x{x}
                , .{ main.entryoff, main.stacksize });
            },

            .RPATH => {
                try writer.writeByte('\n');
                try writer.print(
                    \\path {s}
                , .{
                    lc.getRpathPathName(),
                });
            },

            .UUID => {
                const uuid = lc.cast(macho.uuid_command).?;
                try writer.writeByte('\n');
                try writer.print("uuid {x}", .{std.fmt.fmtSliceHexLower(&uuid.uuid)});
            },

            else => {},
        }
    }
};

const WasmDumper = struct {
    const symtab_label = "symbols";

    fn parseAndDump(gpa: Allocator, bytes: []const u8, opts: Options) ![]const u8 {
        if (opts.dump_symtab) {
            @panic("TODO: Implement symbol table parsing and dumping");
        }

        var fbs = std.io.fixedBufferStream(bytes);
        const reader = fbs.reader();

        const buf = try reader.readBytesNoEof(8);
        if (!mem.eql(u8, buf[0..4], &std.wasm.magic)) {
            return error.InvalidMagicByte;
        }
        if (!mem.eql(u8, buf[4..], &std.wasm.version)) {
            return error.UnsupportedWasmVersion;
        }

        var output = std.ArrayList(u8).init(gpa);
        errdefer output.deinit();
        const writer = output.writer();

        while (reader.readByte()) |current_byte| {
            const section = std.meta.intToEnum(std.wasm.Section, current_byte) catch |err| {
                std.debug.print("Found invalid section id '{d}'\n", .{current_byte});
                return err;
            };

            const section_length = try std.leb.readULEB128(u32, reader);
            try parseAndDumpSection(section, bytes[fbs.pos..][0..section_length], writer);
            fbs.pos += section_length;
        } else |_| {} // reached end of stream

        return output.toOwnedSlice();
    }

    fn parseAndDumpSection(section: std.wasm.Section, data: []const u8, writer: anytype) !void {
        var fbs = std.io.fixedBufferStream(data);
        const reader = fbs.reader();

        try writer.print(
            \\Section {s}
            \\size {d}
        , .{ @tagName(section), data.len });

        switch (section) {
            .type,
            .import,
            .function,
            .table,
            .memory,
            .global,
            .@"export",
            .element,
            .code,
            .data,
            => {
                const entries = try std.leb.readULEB128(u32, reader);
                try writer.print("\nentries {d}\n", .{entries});
                try dumpSection(section, data[fbs.pos..], entries, writer);
            },
            .custom => {
                const name_length = try std.leb.readULEB128(u32, reader);
                const name = data[fbs.pos..][0..name_length];
                fbs.pos += name_length;
                try writer.print("\nname {s}\n", .{name});

                if (mem.eql(u8, name, "name")) {
                    try parseDumpNames(reader, writer, data);
                } else if (mem.eql(u8, name, "producers")) {
                    try parseDumpProducers(reader, writer, data);
                } else if (mem.eql(u8, name, "target_features")) {
                    try parseDumpFeatures(reader, writer, data);
                }
                // TODO: Implement parsing and dumping other custom sections (such as relocations)
            },
            .start => {
                const start = try std.leb.readULEB128(u32, reader);
                try writer.print("\nstart {d}\n", .{start});
            },
            else => {}, // skip unknown sections
        }
    }

    fn dumpSection(section: std.wasm.Section, data: []const u8, entries: u32, writer: anytype) !void {
        var fbs = std.io.fixedBufferStream(data);
        const reader = fbs.reader();

        switch (section) {
            .type => {
                var i: u32 = 0;
                while (i < entries) : (i += 1) {
                    const func_type = try reader.readByte();
                    if (func_type != std.wasm.function_type) {
                        std.debug.print("Expected function type, found byte '{d}'\n", .{func_type});
                        return error.UnexpectedByte;
                    }
                    const params = try std.leb.readULEB128(u32, reader);
                    try writer.print("params {d}\n", .{params});
                    var index: u32 = 0;
                    while (index < params) : (index += 1) {
                        try parseDumpType(std.wasm.Valtype, reader, writer);
                    } else index = 0;
                    const returns = try std.leb.readULEB128(u32, reader);
                    try writer.print("returns {d}\n", .{returns});
                    while (index < returns) : (index += 1) {
                        try parseDumpType(std.wasm.Valtype, reader, writer);
                    }
                }
            },
            .import => {
                var i: u32 = 0;
                while (i < entries) : (i += 1) {
                    const module_name_len = try std.leb.readULEB128(u32, reader);
                    const module_name = data[fbs.pos..][0..module_name_len];
                    fbs.pos += module_name_len;
                    const name_len = try std.leb.readULEB128(u32, reader);
                    const name = data[fbs.pos..][0..name_len];
                    fbs.pos += name_len;

                    const kind = std.meta.intToEnum(std.wasm.ExternalKind, try reader.readByte()) catch |err| {
                        std.debug.print("Invalid import kind\n", .{});
                        return err;
                    };

                    try writer.print(
                        \\module {s}
                        \\name {s}
                        \\kind {s}
                    , .{ module_name, name, @tagName(kind) });
                    try writer.writeByte('\n');
                    switch (kind) {
                        .function => {
                            try writer.print("index {d}\n", .{try std.leb.readULEB128(u32, reader)});
                        },
                        .memory => {
                            try parseDumpLimits(reader, writer);
                        },
                        .global => {
                            try parseDumpType(std.wasm.Valtype, reader, writer);
                            try writer.print("mutable {}\n", .{0x01 == try std.leb.readULEB128(u32, reader)});
                        },
                        .table => {
                            try parseDumpType(std.wasm.RefType, reader, writer);
                            try parseDumpLimits(reader, writer);
                        },
                    }
                }
            },
            .function => {
                var i: u32 = 0;
                while (i < entries) : (i += 1) {
                    try writer.print("index {d}\n", .{try std.leb.readULEB128(u32, reader)});
                }
            },
            .table => {
                var i: u32 = 0;
                while (i < entries) : (i += 1) {
                    try parseDumpType(std.wasm.RefType, reader, writer);
                    try parseDumpLimits(reader, writer);
                }
            },
            .memory => {
                var i: u32 = 0;
                while (i < entries) : (i += 1) {
                    try parseDumpLimits(reader, writer);
                }
            },
            .global => {
                var i: u32 = 0;
                while (i < entries) : (i += 1) {
                    try parseDumpType(std.wasm.Valtype, reader, writer);
                    try writer.print("mutable {}\n", .{0x01 == try std.leb.readULEB128(u1, reader)});
                    try parseDumpInit(reader, writer);
                }
            },
            .@"export" => {
                var i: u32 = 0;
                while (i < entries) : (i += 1) {
                    const name_len = try std.leb.readULEB128(u32, reader);
                    const name = data[fbs.pos..][0..name_len];
                    fbs.pos += name_len;
                    const kind_byte = try std.leb.readULEB128(u8, reader);
                    const kind = std.meta.intToEnum(std.wasm.ExternalKind, kind_byte) catch |err| {
                        std.debug.print("invalid export kind value '{d}'\n", .{kind_byte});
                        return err;
                    };
                    const index = try std.leb.readULEB128(u32, reader);
                    try writer.print(
                        \\name {s}
                        \\kind {s}
                        \\index {d}
                    , .{ name, @tagName(kind), index });
                    try writer.writeByte('\n');
                }
            },
            .element => {
                var i: u32 = 0;
                while (i < entries) : (i += 1) {
                    try writer.print("table index {d}\n", .{try std.leb.readULEB128(u32, reader)});
                    try parseDumpInit(reader, writer);

                    const function_indexes = try std.leb.readULEB128(u32, reader);
                    var function_index: u32 = 0;
                    try writer.print("indexes {d}\n", .{function_indexes});
                    while (function_index < function_indexes) : (function_index += 1) {
                        try writer.print("index {d}\n", .{try std.leb.readULEB128(u32, reader)});
                    }
                }
            },
            .code => {}, // code section is considered opaque to linker
            .data => {
                var i: u32 = 0;
                while (i < entries) : (i += 1) {
                    const index = try std.leb.readULEB128(u32, reader);
                    try writer.print("memory index 0x{x}\n", .{index});
                    try parseDumpInit(reader, writer);
                    const size = try std.leb.readULEB128(u32, reader);
                    try writer.print("size {d}\n", .{size});
                    try reader.skipBytes(size, .{}); // we do not care about the content of the segments
                }
            },
            else => unreachable,
        }
    }

    fn parseDumpType(comptime WasmType: type, reader: anytype, writer: anytype) !void {
        const type_byte = try reader.readByte();
        const valtype = std.meta.intToEnum(WasmType, type_byte) catch |err| {
            std.debug.print("Invalid wasm type value '{d}'\n", .{type_byte});
            return err;
        };
        try writer.print("type {s}\n", .{@tagName(valtype)});
    }

    fn parseDumpLimits(reader: anytype, writer: anytype) !void {
        const flags = try std.leb.readULEB128(u8, reader);
        const min = try std.leb.readULEB128(u32, reader);

        try writer.print("min 0x{x}\n", .{min});
        if (flags != 0) {
            try writer.print("max 0x{x}\n", .{try std.leb.readULEB128(u32, reader)});
        }
    }

    fn parseDumpInit(reader: anytype, writer: anytype) !void {
        const byte = try std.leb.readULEB128(u8, reader);
        const opcode = std.meta.intToEnum(std.wasm.Opcode, byte) catch |err| {
            std.debug.print("invalid wasm opcode '{d}'\n", .{byte});
            return err;
        };
        switch (opcode) {
            .i32_const => try writer.print("i32.const 0x{x}\n", .{try std.leb.readILEB128(i32, reader)}),
            .i64_const => try writer.print("i64.const 0x{x}\n", .{try std.leb.readILEB128(i64, reader)}),
            .f32_const => try writer.print("f32.const 0x{x}\n", .{@bitCast(f32, try reader.readIntLittle(u32))}),
            .f64_const => try writer.print("f64.const 0x{x}\n", .{@bitCast(f64, try reader.readIntLittle(u64))}),
            .global_get => try writer.print("global.get 0x{x}\n", .{try std.leb.readULEB128(u32, reader)}),
            else => unreachable,
        }
        const end_opcode = try std.leb.readULEB128(u8, reader);
        if (end_opcode != std.wasm.opcode(.end)) {
            std.debug.print("expected 'end' opcode in init expression\n", .{});
            return error.MissingEndOpcode;
        }
    }

    fn parseDumpNames(reader: anytype, writer: anytype, data: []const u8) !void {
        while (reader.context.pos < data.len) {
            try parseDumpType(std.wasm.NameSubsection, reader, writer);
            const size = try std.leb.readULEB128(u32, reader);
            const entries = try std.leb.readULEB128(u32, reader);
            try writer.print(
                \\size {d}
                \\names {d}
            , .{ size, entries });
            try writer.writeByte('\n');
            var i: u32 = 0;
            while (i < entries) : (i += 1) {
                const index = try std.leb.readULEB128(u32, reader);
                const name_len = try std.leb.readULEB128(u32, reader);
                const pos = reader.context.pos;
                const name = data[pos..][0..name_len];
                reader.context.pos += name_len;

                try writer.print(
                    \\index {d}
                    \\name {s}
                , .{ index, name });
                try writer.writeByte('\n');
            }
        }
    }

    fn parseDumpProducers(reader: anytype, writer: anytype, data: []const u8) !void {
        const field_count = try std.leb.readULEB128(u32, reader);
        try writer.print("fields {d}\n", .{field_count});
        var current_field: u32 = 0;
        while (current_field < field_count) : (current_field += 1) {
            const field_name_length = try std.leb.readULEB128(u32, reader);
            const field_name = data[reader.context.pos..][0..field_name_length];
            reader.context.pos += field_name_length;

            const value_count = try std.leb.readULEB128(u32, reader);
            try writer.print(
                \\field_name {s}
                \\values {d}
            , .{ field_name, value_count });
            try writer.writeByte('\n');
            var current_value: u32 = 0;
            while (current_value < value_count) : (current_value += 1) {
                const value_length = try std.leb.readULEB128(u32, reader);
                const value = data[reader.context.pos..][0..value_length];
                reader.context.pos += value_length;

                const version_length = try std.leb.readULEB128(u32, reader);
                const version = data[reader.context.pos..][0..version_length];
                reader.context.pos += version_length;

                try writer.print(
                    \\value_name {s}
                    \\version {s}
                , .{ value, version });
                try writer.writeByte('\n');
            }
        }
    }

    fn parseDumpFeatures(reader: anytype, writer: anytype, data: []const u8) !void {
        const feature_count = try std.leb.readULEB128(u32, reader);
        try writer.print("features {d}\n", .{feature_count});

        var index: u32 = 0;
        while (index < feature_count) : (index += 1) {
            const prefix_byte = try std.leb.readULEB128(u8, reader);
            const name_length = try std.leb.readULEB128(u32, reader);
            const feature_name = data[reader.context.pos..][0..name_length];
            reader.context.pos += name_length;

            try writer.print("{c} {s}\n", .{ prefix_byte, feature_name });
        }
    }
};
