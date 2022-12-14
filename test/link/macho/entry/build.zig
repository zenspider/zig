const std = @import("std");
const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();

    const test_step = b.step("test", "Test");
    test_step.dependOn(b.getInstallStep());

    const exe = b.addExecutable("main", null);
    exe.setTarget(.{ .os_tag = .macos });
    exe.setBuildMode(mode);
    exe.addCSourceFile("main.c", &.{});
    exe.linkLibC();
    exe.entry_symbol_name = "_non_main";

    const check_exe = exe.checkObject(.macho, .{
        .dump_symtab = true,
    });

    {
        const check = check_exe.root();
        check.match("cmd MAIN");
        check.match("entryoff {entryoff}");
        const entryoff = check.get("entryoff");
        entryoff.eq(0x538);
    }
    {
        const check = check_exe.root();
        check.match("{n_value} (__TEXT,__text) external _non_main");
        const n_value = check.get("n_value");
        n_value.eq(0x100000538);
    }

    const run = check_exe.runAndCompare();
    run.expectStdOutEqual("42");
    test_step.dependOn(&run.step);
}
