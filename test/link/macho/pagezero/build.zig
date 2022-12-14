const std = @import("std");
const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const target: std.zig.CrossTarget = .{ .os_tag = .macos };

    const test_step = b.step("test", "Test");
    test_step.dependOn(b.getInstallStep());

    {
        const exe = b.addExecutable("pagezero", null);
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.addCSourceFile("main.c", &.{});
        exe.linkLibC();
        exe.pagezero_size = 0x4000;

        const check_exe = exe.checkObject(.macho, .{});
        {
            const check = check_exe.root();
            check.match("LC 0");
            check.match("segname __PAGEZERO");
            check.match("vmaddr 0x0");
            check.match("vmsize 0x4000");
        }
        {
            const check = check_exe.root();
            check.match("segname __TEXT");
            check.match("vmaddr 0x4000");
        }

        test_step.dependOn(&check_exe.step);
    }

    {
        const exe = b.addExecutable("no_pagezero", null);
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.addCSourceFile("main.c", &.{});
        exe.linkLibC();
        exe.pagezero_size = 0;

        const check_exe = exe.checkObject(.macho, .{});
        const check = check_exe.root();
        check.match("LC 0");
        check.match("segname __TEXT");
        check.match("vmaddr 0x0");

        test_step.dependOn(&check_exe.step);
    }
}
