const std = @import("std");
const builtin = @import("builtin");
const Builder = std.build.Builder;
const LibExeObjectStep = std.build.LibExeObjStep;

pub fn build(b: *Builder) void {
    const test_step = b.step("test", "Test");
    test_step.dependOn(b.getInstallStep());

    for (&[_]std.builtin.Mode{ .ReleaseSafe, .ReleaseFast, .ReleaseSmall }) |mode| {
        const dylib = simpleDylib(b, mode);
        const check_recipe = dylib.checkObject(.macho, .{});
        const check = check_recipe.root();
        check.match("cmd UUID");
        check.match("uuid {x}");
        const uuid = check.get("x");
        uuid.eql("1361d54d7fb6300198375069749cc792");
        test_step.dependOn(&check_recipe.step);
    }
}

fn simpleDylib(b: *Builder, mode: std.builtin.Mode) *LibExeObjectStep {
    const dylib = b.addSharedLibrary("test", null, b.version(1, 0, 0));
    dylib.setBuildMode(mode);
    dylib.setTarget(.{ .os_tag = .macos });
    dylib.addCSourceFile("test.c", &.{});
    dylib.linkLibC();
    // TODO work on Zig-overwritten mtimes for debug info on macOS to always
    // guarantee a fully reproducible build.
    dylib.strip = true;
    return dylib;
}
