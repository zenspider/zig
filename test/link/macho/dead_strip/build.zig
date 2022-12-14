const std = @import("std");
const Builder = std.build.Builder;
const LibExeObjectStep = std.build.LibExeObjStep;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const target: std.zig.CrossTarget = .{ .os_tag = .macos };

    const test_step = b.step("test", "Test the program");
    test_step.dependOn(b.getInstallStep());

    {
        // Without -dead_strip, we expect `iAmUnused` symbol present
        const exe = createScenario(b, mode, target);

        const check_exe = exe.checkObject(.macho, .{
            .dump_symtab = true,
        });
        const check = check_exe.root();
        check.match("{*} (__TEXT,__text) external _iAmUnused");

        const run_cmd = check_exe.runAndCompare();
        run_cmd.expectStdOutEqual("Hello!\n");
        test_step.dependOn(&run_cmd.step);
    }

    {
        // With -dead_strip, no `iAmUnused` symbol should be present
        const exe = createScenario(b, mode, target);
        exe.link_gc_sections = true;

        const check_exe = exe.checkObject(.macho, .{
            .dump_symtab = true,
        });
        const check = check_exe.root();
        check.notPresent("{*} (__TEXT,__text) external _iAmUnused");

        const run_cmd = check_exe.runAndCompare();
        run_cmd.expectStdOutEqual("Hello!\n");
        test_step.dependOn(&run_cmd.step);
    }
}

fn createScenario(b: *Builder, mode: std.builtin.Mode, target: std.zig.CrossTarget) *LibExeObjectStep {
    const exe = b.addExecutable("test", null);
    exe.addCSourceFile("main.c", &[0][]const u8{});
    exe.setBuildMode(mode);
    exe.setTarget(target);
    exe.linkLibC();
    return exe;
}
