const std = @import("std");
const Builder = std.build.Builder;
const LibExeObjectStep = std.build.LibExeObjStep;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const target: std.zig.CrossTarget = .{ .os_tag = .macos };

    const test_step = b.step("test", "Test the program");
    test_step.dependOn(b.getInstallStep());

    const dylib = b.addSharedLibrary("a", null, b.version(1, 0, 0));
    dylib.setTarget(target);
    dylib.setBuildMode(mode);
    dylib.addCSourceFile("a.c", &.{});
    dylib.linkLibC();
    dylib.install();

    const exe = b.addExecutable("test", null);
    exe.addCSourceFile("main.c", &[0][]const u8{});
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.linkLibC();
    exe.linkSystemLibraryWeak("a");
    exe.addLibraryPath(b.pathFromRoot("zig-out/lib"));
    exe.addRPath(b.pathFromRoot("zig-out/lib"));

    const check_exe = exe.checkObject(.macho, .{
        .dump_symtab = true,
    });

    {
        const check = check_exe.root();
        check.match("cmd LOAD_WEAK_DYLIB");
        check.match("name @rpath/liba.dylib");
    }
    {
        const check = check_exe.root();
        check.match("(undefined) weak external _a (from liba)");
        check.match("(undefined) weak external _asStr (from liba)");
    }

    const run_cmd = check_exe.runAndCompare();
    run_cmd.expectStdOutEqual("42 42");
    test_step.dependOn(&run_cmd.step);
}
