const std = @import("std");
const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const target: std.zig.CrossTarget = .{ .os_tag = .macos };

    const test_step = b.step("test", "Test");
    test_step.dependOn(b.getInstallStep());

    const dylib = b.addSharedLibrary("a", null, b.version(1, 0, 0));
    dylib.setBuildMode(mode);
    dylib.setTarget(target);
    dylib.addCSourceFile("a.c", &.{});
    dylib.linkLibC();
    dylib.install();

    const check_dylib = dylib.checkObject(.macho, .{});
    {
        const check = check_dylib.root();
        check.match("cmd ID_DYLIB");
        check.match("name @rpath/liba.dylib");
        check.match("timestamp 2");
        check.match("current version 0x10000");
        check.match("compatibility version 0x10000");
    }

    test_step.dependOn(&check_dylib.step);

    const exe = b.addExecutable("main", null);
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addCSourceFile("main.c", &.{});
    exe.linkSystemLibrary("a");
    exe.linkLibC();
    exe.addLibraryPath(b.pathFromRoot("zig-out/lib/"));
    exe.addRPath(b.pathFromRoot("zig-out/lib"));

    const check_exe = exe.checkObject(.macho, .{});
    {
        const check = check_exe.root();
        check.match("cmd LOAD_DYLIB");
        check.match("name @rpath/liba.dylib");
        check.match("timestamp 2");
        check.match("current version 0x10000");
        check.match("compatibility version 0x10000");
    }
    {
        const check = check_exe.root();
        check.match("cmd RPATH");
        check.match(std.fmt.allocPrint(b.allocator, "path {s}", .{b.pathFromRoot("zig-out/lib")}) catch unreachable);
    }

    const run = check_exe.runAndCompare();
    run.cwd = b.pathFromRoot(".");
    run.expectStdOutEqual("Hello world");
    test_step.dependOn(&run.step);
}
