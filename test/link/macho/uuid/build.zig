const std = @import("std");
const builtin = @import("builtin");
const Builder = std.build.Builder;
const LibExeObjectStep = std.build.LibExeObjStep;

pub fn build(b: *Builder) void {
    const test_step = b.step("test", "Test");
    test_step.dependOn(b.getInstallStep());

    for (&[_]struct { mode: std.builtin.Mode, uuid: []const u8 }{
        .{ .mode = .ReleaseSafe, .uuid = "6d0003ac18b137b99f315ff453e07d05" },
        // .{ .mode = .ReleaseFast, .uuid = "30a45d10ba003a33bd57a4e98d3a6f6b" },
        // .{ .mode = .ReleaseSmall, .uuid = "1361d54d7fb6300198375069749cc792" },
    }) |exp| {
        {
            const dylib = simpleDylib(b, exp.mode);
            const check_recipe = dylib.checkObject(.macho, .{});
            const check = check_recipe.root();
            check.match("cmd UUID");
            check.match("uuid {x}");
            const uuid = check.get("x");
            uuid.eql(exp.uuid);
            test_step.dependOn(&check_recipe.step);
        }
        {
            // repeating the build should produce the same UUID
            const dylib = simpleDylib(b, exp.mode);
            const check_recipe = dylib.checkObject(.macho, .{});
            const check = check_recipe.root();
            check.match("cmd UUID");
            check.match("uuid {x}");
            const uuid = check.get("x");
            uuid.eql(exp.uuid);
            test_step.dependOn(&check_recipe.step);
        }
    }
}

fn simpleDylib(b: *Builder, mode: std.builtin.Mode) *LibExeObjectStep {
    const dylib = b.addSharedLibrary("test", null, b.version(1, 0, 0));
    dylib.setBuildMode(mode);
    dylib.setTarget(.{ .os_tag = .macos });
    dylib.addCSourceFile("test.c", &.{});
    dylib.linkLibC();
    return dylib;
}
