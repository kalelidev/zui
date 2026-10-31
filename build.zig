const std = @import("std");

/// ZUI build configuration.

/// Two kinds of module, with separate link profiles:
///
///   * `zui`      — the framework core. Pure Zig, no system libraries. Its tests
///                  run anywhere, including a machine with no display.
///   * `platform` — OS integration. Links SDL3, xcb and libc. Imported only by
///                  programs that want a window; the core never reaches it.
///
/// Keeping the graphics stack out of `zui` means `zig build test` cannot silently
/// depend on a display server.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ------------------------------------------------------------------
    // Módulo `zui`: núcleo sin dependencias de sistema
    // ------------------------------------------------------------------
    const zui_mod = b.addModule("zui", .{
        .root_source_file = b.path("src/zui.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ------------------------------------------------------------------
    // Módulo `platform`: integración con el SO
    // ------------------------------------------------------------------
    const platform_mod = b.addModule("platform", .{
        .root_source_file = b.path("src/platform/platform.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zui", .module = zui_mod }},
    });

    // SDL3: ventana X11/Wayland detrás de una sola API.
    platform_mod.linkSystemLibrary("SDL3", .{});
    // XCB: backend propio sin dependencias de terceros.
    platform_mod.linkSystemLibrary("xcb", .{});
    platform_mod.linkSystemLibrary("xcb-shm", .{});
    platform_mod.linkSystemLibrary("xcb-keysyms", .{});
    platform_mod.linkSystemLibrary("xcb-image", .{});
    platform_mod.link_libc = true;

    // ------------------------------------------------------------------
    // Tests del núcleo (sin display, sin SDL, sin X11)
    // ------------------------------------------------------------------
    const core_tests = b.addTest(.{ .root_module = zui_mod });
    const run_core_tests = b.addRunArtifact(core_tests);

    // ------------------------------------------------------------------
    // Tests de la plataforma (enlazan SDL3 y xcb; no abren ventana)
    // ------------------------------------------------------------------
    const platform_tests = b.addTest(.{ .root_module = platform_mod });
    const run_platform_tests = b.addRunArtifact(platform_tests);

    const test_step = b.step("test", "Run the core and platform test suites");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_platform_tests.step);

    // ------------------------------------------------------------------
    // Ejemplo sin display: `zui-image` escribe un PPM
    // ------------------------------------------------------------------
    const image_exe = b.addExecutable(.{
        .name = "zui-image",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/image.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zui", .module = zui_mod }},
        }),
    });

    const run_image = b.addRunArtifact(image_exe);
    run_image.addPassthruArgs();
    b.step("image", "Render the example interface to a PPM image")
        .dependOn(&run_image.step);

    // ------------------------------------------------------------------
    // Ejemplos con ventana
    // ------------------------------------------------------------------
    const Example = struct {
        name: []const u8,
        source: []const u8,
        description: []const u8,
    };

    const examples = [_]Example{
        .{ .name = "zui-sdl3", .source = "examples/sdl3.zig", .description = "SDL3 window example" },
        .{ .name = "zui-x11", .source = "examples/x11.zig", .description = "X11/xcb window example" },
    };

    for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.source),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zui", .module = zui_mod },
                    .{ .name = "platform", .module = platform_mod },
                },
            }),
        });

        // Building needs no display; running does. They are separate steps so
        // `zig build` works on a headless machine and CI.
        const build_step_name = if (std.mem.eql(u8, example.name, "zui-sdl3")) "sdl3" else "x11";
        b.step(build_step_name, b.fmt("Build the {s}", .{example.description}))
            .dependOn(&exe.step);

        const run_step_name = if (std.mem.eql(u8, example.name, "zui-sdl3")) "run-sdl3" else "run-x11";
        const run = b.addRunArtifact(exe);
        b.step(run_step_name, b.fmt("Run the {s} (needs a display)", .{example.description}))
            .dependOn(&run.step);

        b.installArtifact(exe);
    }

    // ------------------------------------------------------------------
    // Ejemplo contador interactivo
    // ------------------------------------------------------------------
    const counter_exe = b.addExecutable(.{
        .name = "zui-counter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/counter.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui", .module = zui_mod },
                .{ .name = "platform", .module = platform_mod },
            },
        }),
    });

    const run_counter = b.addRunArtifact(counter_exe);
    b.step("run-counter", "Run the counter (needs a display)")
        .dependOn(&run_counter.step);
    b.installArtifact(counter_exe);

    // ------------------------------------------------------------------
    // Benchmark harness: mide el costo de actualizar el contador
    // ------------------------------------------------------------------
    const bench_exe = b.addExecutable(.{
        .name = "zui-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui", .module = zui_mod },
                .{ .name = "platform", .module = platform_mod },
            },
        }),
    });

    const run_bench = b.addRunArtifact(bench_exe);
    b.step("run-benchmark", "Run the benchmark (needs a display)")
        .dependOn(&run_bench.step);
    b.installArtifact(bench_exe);

    // ------------------------------------------------------------------
    // Ejemplo del README: se compila para que el fragmento publicado no mienta
    // ------------------------------------------------------------------
    const readme_exe = b.addExecutable(.{
        .name = "zui-readme",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/readme.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui", .module = zui_mod },
                .{ .name = "platform", .module = platform_mod },
            },
        }),
    });

    const run_readme = b.addRunArtifact(readme_exe);
    b.step("run-readme", "Run the example printed in README.md (needs a display)")
        .dependOn(&run_readme.step);
    b.installArtifact(readme_exe);

    // ------------------------------------------------------------------
    // Instalación: `zig build` deja los binarios en zig-out/bin
    // ------------------------------------------------------------------
    b.installArtifact(image_exe);
}
