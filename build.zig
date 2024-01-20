const std = @import("std");
const builtin = @import("builtin");

pub const utils = @import("build_utils.zig");

const bsslSrcs = @import("src/bearssl/srcs.zig");

pub fn setupApp(
    b: *std.build.Builder,
    bZigkm: *std.build.Builder,
    options: struct {
        name: []const u8,
        srcApp: []const u8,
        srcServer: []const u8,
        target: std.zig.CrossTarget,
        optimize: std.builtin.OptimizeMode,
        // custom_entrypoint: ?[]const u8 = null,
        // deps: ?[]const std.Build.Module.Import = null,
        // res_dirs: ?[]const []const u8 = null,
        // watch_paths: ?[]const []const u8 = null,
        // mach_core_mod: ?*std.Build.Module = null,
    },
) !void {
    _ = bZigkm;

    // Server setup
    const serverOutputPath = "server";
    const httpz = b.dependency("httpz", .{
        .target = options.target,
        .optimize = options.optimize,
    });

    const targetWasm = std.zig.CrossTarget {.cpu_arch = .wasm32, .os_tag = .freestanding};
    const zigkmCommon = b.anonymousDependency("deps/zigkm-common", @import("build.zig"), .{
        .target = options.target,
        .optimize = options.optimize,
    });
    const zigkmCommonWasm = b.anonymousDependency("deps/zigkm-common", @import("build.zig"), .{
        .target = targetWasm,
        .optimize = options.optimize,
    });

    const server = b.addExecutable(.{
        .name = options.name,
        .root_source_file = .{.path = options.srcServer},
        .target = options.target,
        .optimize = options.optimize,
    });
    // server.addIncludePath(.{.path = "deps/zigkm-common/deps/stb"});
    server.linkLibrary(zigkmCommon.artifact("zigkm-stb-lib"));
    server.linkLibrary(zigkmCommon.artifact("zigkm-bearssl-lib"));
    server.addModule("zigkm-stb", zigkmCommon.module("zigkm-stb"));
    server.addModule("zigkm-app", zigkmCommon.module("zigkm-app"));
    server.addModule("zigkm-auth", zigkmCommon.module("zigkm-auth"));
    server.addModule("zigkm-google", zigkmCommon.module("zigkm-google"));
    server.addModule("zigkm-platform", zigkmCommon.module("zigkm-platform"));
    server.addModule("zigkm-serialize", zigkmCommon.module("zigkm-serialize"));
    server.addModule("httpz", httpz.module("httpz"));

    const wasm = b.addSharedLibrary(.{
        .name = "app",
        .root_source_file = .{.path = options.srcApp},
        .target = targetWasm,
        .optimize = options.optimize,
    });
    wasm.addModule("zigkm-math", zigkmCommonWasm.module("zigkm-math"));
    wasm.addModule("zigkm-serialize", zigkmCommonWasm.module("zigkm-serialize"));
    wasm.addIncludePath(.{.path = "deps/zigkm-common/deps/stb"});
    wasm.addCSourceFiles(&[_][]const u8{
        "deps/zigkm-common/deps/stb/stb_image_impl.c",
        "deps/zigkm-common/deps/stb/stb_image_write_impl.c",
        "deps/zigkm-common/deps/stb/stb_rect_pack_impl.c",
        "deps/zigkm-common/deps/stb/stb_truetype_impl.c",
    }, &[_][]const u8{"-std=c99"});
    wasm.linkLibC();
    wasm.addModule("zigkm-stb", zigkmCommonWasm.module("zigkm-stb"));
    wasm.addModule("zigkm-app", zigkmCommonWasm.module("zigkm-app"));
    wasm.addIncludePath(.{.path = "deps/zigkm-common/src/app"}); // TODO move to lib?
    wasm.addModule("zigkm-platform", zigkmCommonWasm.module("zigkm-platform"));
    // wasm.linkLibrary(zigkmCommonWasm.artifact("zigkm-stb-lib"));
    prepKmWasm(wasm);

    const buildServerStep = b.step("server_build", "Build server");
    const installServerStep = b.addInstallArtifact(server, .{
        .dest_dir = .{.override = .{.custom = serverOutputPath}}
    });
    buildServerStep.dependOn(&installServerStep.step);

    const installWasmStep = b.addInstallArtifact(wasm, .{
        .dest_dir = .{.override = .{.custom = serverOutputPath}}
    });
    buildServerStep.dependOn(&installWasmStep.step);

    const packageServerStep = b.step("server_package", "Package server");
    packageServerStep.dependOn(buildServerStep);
    packageServerStep.dependOn(&b.addInstallDirectory(.{
        .source_dir = .{.path = "deps/zigkm-common/src/app/static"},
        .install_dir = .{.custom = "server-temp/static"},
        .install_subdir = "",
    }).step);
    packageServerStep.dependOn(&b.addInstallDirectory(.{
        .source_dir = .{.path = "src/server_static"},
        .install_dir = .{.custom = "server-temp/static"},
        .install_subdir = "",
    }).step);
    packageServerStep.dependOn(&b.addInstallDirectory(.{
        .source_dir = .{.path = "scripts/server"},
        .install_dir = .{.custom = "server"},
        .install_subdir = "scripts",
    }).step);
    packageServerStep.dependOn(&b.addInstallArtifact(zigkmCommon.artifact("genbigdata"), .{
        .dest_dir = .{.override = .{.custom = "tools"}}
    }).step);
    packageServerStep.makeFn = stepPackageServer;

    if (builtin.os.tag == .macos) {
        const targetAppIos = comptime if (iosSimulator)
            std.zig.CrossTarget {
                .cpu_arch = null,
                .os_tag = .ios,
                .os_version_min = .{.semver = iosMinVersion},
                .abi = .simulator,
            }
        else
            std.zig.CrossTarget {
                .cpu_arch = .aarch64,
                .os_tag = .ios,
                .os_version_min = .{.semver = iosMinVersion},
                .abi = null,
            };

        const targetAppIosResolved = try std.zig.system.NativeTargetInfo.detect(targetAppIos);
        const zigkmCommonIos = b.anonymousDependency("deps/zigkm-common", @import("build.zig"), .{
            .target = targetAppIos,
            .optimize = options.optimize,
        });

        const lib = b.addStaticLibrary(.{
            .name = "applib",
            .root_source_file = .{.path = options.srcApp},
            .target = targetAppIos,
            .optimize = options.optimize
        });
        try addSdkPaths(b, lib, targetAppIosResolved.target);
        lib.addIncludePath(.{.path = "deps/zigkm-common/src/app"});
        lib.addIncludePath(.{.path = "deps/zigkm-common/deps/stb"});
        lib.addCSourceFiles(&[_][]const u8{
            // "deps/zigkm-common/deps/stb/stb_image_impl.c",
            // "deps/zigkm-common/deps/stb/stb_image_write_impl.c",
            "deps/zigkm-common/deps/stb/stb_rect_pack_impl.c",
            "deps/zigkm-common/deps/stb/stb_truetype_impl.c",
        }, &[_][]const u8{"-std=c99"});
        // lib.linkLibrary(zigkmCommonIos.artifact("zigkm-stb-lib"));
        lib.addModule("zigkm-math", zigkmCommonIos.module("zigkm-math"));
        lib.addModule("zigkm-stb", zigkmCommonIos.module("zigkm-stb"));
        lib.addModule("zigkm-app", zigkmCommonIos.module("zigkm-app"));
        lib.addModule("zigkm-platform", zigkmCommonIos.module("zigkm-platform"));
        lib.bundle_compiler_rt = true;

        const appPath = getAppBuildPath();
        const buildAppIosStep = b.step("app_build", "Build and install app");
        const appInstallStep = b.addInstallArtifact(lib, .{
            .dest_dir = .{.override = .{.custom = iosAppOutputPath}}
        });
        const installDataStep = b.addInstallDirectory(.{
            .source_dir = .{.path = "data"},
            .install_dir = .{.custom = appPath},
            .install_subdir = "",
        });
        const installDataIosStep = b.addInstallDirectory(.{
            .source_dir = .{.path = "data_ios"},
            .install_dir = .{.custom = appPath},
            .install_subdir = "",
        });
        buildAppIosStep.dependOn(&appInstallStep.step);
        buildAppIosStep.dependOn(&installDataStep.step);
        buildAppIosStep.dependOn(&installDataIosStep.step);

        const packageAppStep = b.step("app_package", "Package app");
        packageAppStep.dependOn(buildAppIosStep);
        packageAppStep.makeFn = stepWrapper(stepPackageApp, targetAppIos);

        const runAppStep = b.step("app_run", "Run app on connected device");
        runAppStep.dependOn(packageAppStep);
        runAppStep.makeFn = stepWrapper(stepRun, targetAppIos);
    }
}

pub fn build(b: *std.build.Builder) !void
{
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // const zigimg = b.dependency("zigimg", .{
    //     .target = target,
    //     .optimize = optimize,
    // });
    const zigimg = b.anonymousDependency("deps/zigimg", @import("deps/zigimg/build.zig"), .{
        .target = target,
        .optimize = optimize,
    });
    const zigimgModule = zigimg.module("zigimg");

    // zigkm-math
    const mathModule = b.addModule("zigkm-math", .{
        .source_file = .{.path = "src/math.zig"}
    });

    // zigkm-serialize
    const serializeModule = b.addModule("zigkm-serialize", .{
        .source_file = .{.path = "src/serialize.zig"}
    });

    // zigkm-platform
    const platformModule = b.addModule("zigkm-platform", .{
        .source_file = .{.path = "src/platform/platform.zig"},
    });

    // zigkm-stb
    const stbModule = b.addModule("zigkm-stb", .{
        .source_file = .{.path = "src/stb/stb.zig"}
    });
    const stbLib = b.addStaticLibrary(.{
        .name = "zigkm-stb-lib",
        .target = target,
        .optimize = optimize,
    });
    stbLib.addIncludePath(.{.path = "deps/stb"});
    stbLib.addCSourceFiles(&[_][]const u8{
        "deps/stb/stb_image_impl.c",
        "deps/stb/stb_image_write_impl.c",
        "deps/stb/stb_rect_pack_impl.c",
        "deps/stb/stb_truetype_impl.c",
    }, &[_][]const u8{"-std=c99"});
    stbLib.linkLibC();
    stbLib.installHeadersDirectory("deps/stb", "");
    b.installArtifact(stbLib);

    // zigkm-app
    const appModule = b.addModule("zigkm-app", .{
        .source_file = .{.path = "src/app/app.zig"},
        .dependencies = &[_]std.build.ModuleDependency {
            .{.name = "zigkm-math", .module = mathModule},
            .{.name = "zigkm-platform", .module = platformModule},
            .{.name = "zigkm-stb", .module = stbModule},
            .{.name = "zigimg", .module = zigimgModule},
        },
    });

    // zigkm-bearssl
    const bsslModule = b.addModule("zigkm-bearssl", .{
        .source_file = .{.path = "src/bearssl/bearssl.zig"}
    });
    const bsslLib = b.addStaticLibrary(.{
        .name = "zigkm-bearssl-lib",
        .target = target,
        .optimize = optimize,
    });
    bsslLib.addIncludePath(.{.path = "deps/BearSSL/inc"});
    bsslLib.addIncludePath(.{.path = "deps/BearSSL/src"});
    bsslLib.addCSourceFiles(
        &bsslSrcs.srcs,
        &[_][]const u8{
            "-Wall",
            "-DBR_LE_UNALIGNED=0", // this prevent BearSSL from using undefined behaviour when doing potential unaligned access
        },
    );
    bsslLib.linkLibC();
    if (target.isWindows()) {
        bsslLib.linkSystemLibrary("advapi32");
    }
    bsslLib.installHeadersDirectory("deps/BearSSL/inc", "");
    b.installArtifact(bsslLib);

    // zigkm-google
    const googleModule = b.addModule("zigkm-google", .{
        .source_file = .{.path = "src/google/google.zig"},
        .dependencies = &[_]std.build.ModuleDependency {
            .{.name = "zigkm-bearssl", .module = bsslModule},
        },
    });

    // zigkm-auth
    const authModule = b.addModule("zigkm-auth", .{
        .source_file = .{.path = "src/auth.zig"},
        .dependencies = &[_]std.build.ModuleDependency {
            .{.name = "zigkm-google", .module = googleModule},
            .{.name = "zigkm-serialize", .module = serializeModule},
        }
    });
    _ = authModule;

    // tools
    const genbigdata = b.addExecutable(.{
        .name = "genbigdata",
        .root_source_file = .{.path = "src/tools/genbigdata.zig"},
        .target = target,
        .optimize = optimize,
    });
    genbigdata.addModule("zigkm-stb", stbModule);
    genbigdata.addModule("zigkm-app", appModule);
    genbigdata.addIncludePath(.{.path = "deps/stb"});
    genbigdata.linkLibrary(stbLib);
    b.installArtifact(genbigdata);

    const gmail = b.addExecutable(.{
        .name = "gmail",
        .root_source_file = .{.path = "src/tools/gmail.zig"},
        .target = target,
        .optimize = optimize,
    });
    gmail.addModule("zigkm-google", googleModule);
    gmail.linkLibrary(bsslLib);
    b.installArtifact(gmail);

    // tests
    const runTests = b.step("test", "Run all tests");
    const testSrcs = [_][]const u8 {
        "src/auth.zig",
        "src/serialize.zig",
        "src/app/bigdata.zig",
        "src/app/tree.zig",
        "src/app/ui.zig",
        "src/app/uix.zig",
        // "src/google/login.zig",
    };
    for (testSrcs) |src| {
        const testCompile = b.addTest(.{
            .root_source_file = .{
                .path = src,
            },
            .target = target,
            .optimize = optimize,
        });
        testCompile.addModule("zigkm-app", appModule);
        testCompile.addModule("zigkm-math", mathModule);

        const testRun = b.addRunArtifact(testCompile);
        testRun.has_side_effects = true;
        runTests.dependOn(&testRun.step);
    }
}


fn isTermOk(term: std.ChildProcess.Term) bool
{
    switch (term) {
        std.ChildProcess.Term.Exited => |value| {
            return value == 0;
        },
        else => {
            return false;
        }
    }
}

fn checkTermStdout(execResult: std.ChildProcess.ExecResult) ?[]const u8
{
    const ok = isTermOk(execResult.term);
    if (!ok) {
        std.log.err("{}", .{execResult.term});
        if (execResult.stdout.len > 0) {
            std.log.info("{s}", .{execResult.stdout});
        }
        if (execResult.stderr.len > 0) {
            std.log.err("{s}", .{execResult.stderr});
        }
        return null;
    }
    return execResult.stdout;
}

pub fn execCheckTermStdoutWd(argv: []const []const u8, cwd: ?[]const u8, allocator: std.mem.Allocator) ?[]const u8
{
    const result = std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd
    }) catch |err| {
        std.log.err("exec error: {}", .{err});
        return null;
    };
    return checkTermStdout(result);
}

pub fn execCheckTermStdout(argv: []const []const u8, allocator: std.mem.Allocator) ?[]const u8
{
    return execCheckTermStdoutWd(argv, null, allocator);
}

fn stepWrapper(comptime stepFunction: anytype,
               comptime target: std.zig.CrossTarget) fn(*std.build.Step, *std.Progress.Node) anyerror!void
{
    // No nice Zig syntax for this yet... this will look better after
    // https://github.com/ziglang/zig/issues/1717
    return struct
    {
        fn f(self: *std.build.Step, node: *std.Progress.Node) anyerror!void
        {
            _ = self; _ = node;
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            return stepFunction(target, arena.allocator());
        }
    }.f;
}

const iosCertificate = "Apple Distribution: Jose Rico (PP87JX664B)"; // TODO move out
const iosSimulator = true; // TODO move out
const iosAppOutputPath = "app_ios";
const iosSdkFlavor = if (iosSimulator) "iphonesimulator" else "iphoneos";
const iosMinVersion = std.SemanticVersion {.major = 15, .minor = 0, .patch = 0};
const metalMinVersion = std.SemanticVersion {.major = 2, .minor = 4, .patch = 0};
const iosMinVersionString = std.fmt.comptimePrint("{}.{}", .{
    iosMinVersion.major, iosMinVersion.minor
});
const metalMinVersionString = std.fmt.comptimePrint("{}.{}", .{
    metalMinVersion.major, metalMinVersion.minor
});

fn getAppBuildPath() []const u8
{
    return iosAppOutputPath ++ "/Payload/update.app";
}

fn stepPackageAppIos(target: std.zig.CrossTarget, allocator: std.mem.Allocator) !void
{
    _ = target;
    std.log.info("Packaging app for iOS", .{});

    const appPathFull = "zig-out/" ++ comptime getAppBuildPath();
    const appBuildDirFull = "zig-out/" ++ iosAppOutputPath;

    // Compile native code (Objective-C, maybe we can do Swift in the future)
    std.log.info("Compiling native code", .{});
    if (execCheckTermStdout(&[_][]const u8 {
        "./scripts/ios/compile_native.sh",
        iosSdkFlavor, iosMinVersionString, appPathFull, appBuildDirFull
    }, allocator) == null) {
        return error.nativeCompile;
    }

    // Compile and link metal shaders
    std.log.info("Compiling shaders", .{});
    const metalTarget = if (iosSimulator) "air64-apple-ios" ++ iosMinVersionString ++ "-simulator" else "air64-apple-ios" ++ iosMinVersionString;
    if (execCheckTermStdout(&[_][]const u8 {
        "xcrun", "-sdk", iosSdkFlavor,
        "metal",
        "-Werror",
        "-target", metalTarget,
        "-std=ios-metal" ++ metalMinVersionString,
        "-mios-version-min=" ++ iosMinVersionString,
        // "-std=metal3.0",
        "-c", "deps/zigkm-common/src/app/ios/shaders.metal",
        "-o", appBuildDirFull ++ "/shaders.air"
    }, allocator) == null) {
        return error.metalCompile;
    }
    std.log.info("Linking shaders", .{});
    if (execCheckTermStdout(&[_][]const u8 {
        "xcrun", "-sdk", iosSdkFlavor,
        "metallib",
        appBuildDirFull ++ "/shaders.air",
        "-o", appPathFull ++ "/default.metallib"
    }, allocator) == null) {
        return error.metalLink;
    }

    if (!iosSimulator) {
        std.log.info("Running codesign", .{});
        if (execCheckTermStdout(&[_][]const u8 {
            "codesign", "-s", iosCertificate, "--entitlements", "scripts/ios/update.entitlements", appPathFull
        }, allocator) == null) {
            return error.codesign;
        }

        std.log.info("zipping .ipa archive", .{});
        if (execCheckTermStdoutWd(&[_][]const u8 {
            "zip", "-r", "update.ipa", "Payload"
        }, appBuildDirFull, allocator) == null) {
            return error.ipaZip;
        }
    }
}

fn stepPackageApp(target: std.zig.CrossTarget, allocator: std.mem.Allocator) !void
{
    // TODO non-iOS
    try stepPackageAppIos(target, allocator);
}

fn stepRunIos(target: std.zig.CrossTarget, allocator: std.mem.Allocator) !void
{
    _ = target;
    std.log.info("Running app for iOS", .{});

    const appBuildDirFull = "zig-out/" ++ iosAppOutputPath;
    const appPathFull = "zig-out/" ++ comptime getAppBuildPath();

    if (iosSimulator) {
        const installArgs = &[_][]const u8 {
            "xcrun", "simctl", "install", "booted", appPathFull
        };
        if (execCheckTermStdout(installArgs, allocator) == null) {
            return error.xcrunInstallError;
        }

        const launchArgs = &[_][]const u8 {
            "xcrun", "simctl", "launch", "booted", "app.clientupdate.update"
        };
        if (execCheckTermStdout(launchArgs, allocator) == null) {
            return error.xcrunLaunchError;
        }
    } else {
        const installerArgs = &[_][]const u8 {
            "ideviceinstaller", "-i", appBuildDirFull ++ "/update.ipa"
        };
        if (execCheckTermStdout(installerArgs, allocator) == null) {
            return error.install;
        }
    }
}

fn stepRun(target: std.zig.CrossTarget, allocator: std.mem.Allocator) !void
{
    // TODO non-iOS
    try stepRunIos(target, allocator);
}

fn addSdkPaths(b: *std.Build, compileStep: *std.Build.CompileStep, target: std.Target) !void
{
    const sdk = std.zig.system.darwin.getSdk(b.allocator, target) orelse {
        std.log.warn("No iOS SDK found, skipping", .{});
        return;
    };
    std.log.info("SDK path: {s}", .{sdk.path});
    if (b.sysroot == null) {
        // b.sysroot = sdk.path;
    }

    // const sdkPath = b.sysroot.?;
    const frameworkPath = try std.fmt.allocPrint(b.allocator, "{s}/System/Library/Frameworks", .{sdk.path});
    const includePath = try std.fmt.allocPrint(b.allocator, "{s}/usr/include", .{sdk.path});
    const libPath = try std.fmt.allocPrint(b.allocator, "{s}/usr/lib", .{sdk.path});

    compileStep.addFrameworkPath(.{.path = frameworkPath});
    compileStep.addSystemIncludePath(.{.path = includePath});
    compileStep.addLibraryPath(.{.path = libPath});
    // _ = compileStep;
}

fn stepPackageServer(step: *std.build.Step, node: *std.Progress.Node) !void
{
    _ = step;
    _ = node;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.log.info("Generating bigdata file archive...", .{});

    const genBigdataArgs = &[_][]const u8 {
        "./zig-out/tools/genbigdata", "./zig-out/server-temp/static", "./zig-out/server/static.bigdata",
    };
    if (execCheckTermStdout(genBigdataArgs, allocator) == null) {
        return error.genbigdata;
    }
}

fn prepKmWasm(compile: *std.Build.Step.Compile) void
{
    compile.export_symbol_names = &[_][]const u8 {
        "onInit",
        "onAnimationFrame",
        "onMouseMove",
        "onMouseDown",
        "onMouseUp",
        "onMouseWheel",
        "onKeyDown",
        "onTouchStart",
        "onTouchMove",
        "onTouchEnd",
        "onTouchCancel",
        "onPopState",
        "onDeviceOrientation",
        "onHttp",
        "onLoadedFont",
        "onLoadedTexture",
        "loadFontData",
    };
    compile.stack_protector = false;
    compile.disable_stack_probing = true;
}
