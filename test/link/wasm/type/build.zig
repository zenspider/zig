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
    const check = check_lib.root();
    check.match("Section type");
    // only 2 entries, although we have 3 functions.
    // This is to test functions with the same function signature
    // have their types deduplicated.
    check.match("entries 2");
    check.match("params 1");
    check.match("type i32");
    check.match("returns 1");
    check.match("type i64");
    check.match("params 0");
    check.match("returns 0");

    test_step.dependOn(&check_lib.step);
}
