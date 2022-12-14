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
    lib.stack_size = std.wasm.page_size * 2; // set an explicit stack size
    lib.install();

    const check_lib = lib.checkObject(.wasm, .{});

    {
        // ensure global exists and its initial value is equal to explitic stack size
        const check = check_lib.root();
        check.match("Section global");
        check.match("entries 1");
        check.match("type i32"); // on wasm32 the stack pointer must be i32
        check.match("mutable true"); // must be able to mutate the stack pointer
        check.match("i32.const {stack_pointer}");
        const stack_pointer = check.get("stack_pointer");
        stack_pointer.eq(lib.stack_size.?);
    }

    {
        // validate memory section starts after virtual stack
        const check = check_lib.root();
        check.match("Section data");
        check.match("i32.const {data_start}");
        const data_start = check.get("data_start");
        data_start.eq(lib.stack_size.?);
    }

    {
        // validate the name of the stack pointer
        const check = check_lib.root();
        check.match("Section custom");
        check.match("type global");
        check.match("names 1");
        check.match("index 0");
        check.match("name __stack_pointer");
    }

    test_step.dependOn(&check_lib.step);
}
