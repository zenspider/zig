const std = @import("std");
const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();

    const test_step = b.step("test", "Test");
    test_step.dependOn(b.getInstallStep());

    const lib = b.addSharedLibrary("lib", "lib.zig", .unversioned);
    lib.setBuildMode(mode);
    lib.setTarget(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    lib.use_llvm = false;
    lib.use_lld = false;
    lib.strip = false;
    // to make sure the bss segment is emitted, we must import memory
    lib.import_memory = true;
    lib.install();

    const check_lib = lib.checkObject(.wasm, .{});

    {
        // since we import memory, make sure it exists with the correct naming
        const check = check_lib.root();
        check.match("Section import");
        check.match("entries 1");
        check.match("module env"); // default module name is "env"
        check.match("name memory"); // as per linker specification
    }

    {
        // since we are importing memory, ensure it's not exported
        const check = check_lib.root();
        check.match("Section export");
        check.match("entries 1"); // we're exporting function 'foo' so only 1 entry
    }

    {
        // validate the name of the stack pointer
        const check = check_lib.root();
        check.match("Section custom");
        check.match("type data_segment");
        check.match("names 2");
        check.match("index 0");
        check.match("name .rodata");
        check.match("index 1"); // bss section always last
        check.match("name .bss");
    }

    test_step.dependOn(&check_lib.step);
}
