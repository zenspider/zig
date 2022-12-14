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
    lib.install();

    const check_lib = lib.checkObject(.wasm, .{});
    {
        const check = check_lib.root();
        check.match("Section data");
        check.match("entries 2"); // rodata & data, no bss because we're exporting memory
    }
    {
        const check = check_lib.root();
        check.match("Section custom");
    }
    {
        const check = check_lib.root();
        check.match("name name"); // names custom section
    }
    {
        const check = check_lib.root();
        check.match("type data_segment");
        check.match("names 2");
        check.match("index 0");
        check.match("name .rodata");
        check.match("index 1");
        check.match("name .data");
    }
    test_step.dependOn(&check_lib.step);
}
