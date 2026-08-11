using Test, BinaryBuilderAuditor, Base.BinaryPlatforms, ObjectFile, BinaryBuilderToolchains,
      BinaryBuilderProducts, JLLGenerator
using BinaryBuilderAuditor: resolve_dynamic_links!, resolve_static_libraries!, ensure_sonames!,
                            scan_static_archive, read_archive_members, is_static_archive,
                            system_library_linker_name, static_pass_name

# Find the results of a single audit pass, for the given file
function pass_results_for(pass_results, pass_name, rel_path)
    return [r for r in get(pass_results, pass_name, PassResult[]) if r.identifier == rel_path]
end
function has_status(pass_results, pass_name, rel_path, status)
    return any(r.status == status for r in pass_results_for(pass_results, pass_name, rel_path))
end
function messages(pass_results, pass_name, rel_path)
    return join([something(r.message, "") for r in pass_results_for(pass_results, pass_name, rel_path)], "\n")
end

@testset "system_library_linker_name" begin
    linux = Platform("x86_64", "linux")
    @test system_library_linker_name("libm.so.6", linux) == "m"
    @test system_library_linker_name("libpthread.so.0", linux) == "pthread"
    @test system_library_linker_name("/usr/lib/libc.so.6", linux) == "c"
    @test system_library_linker_name("libc.musl-x86_64.so.1", linux) == "c"
    # The dynamic loader is not a library one links against
    @test system_library_linker_name("ld-linux-x86-64.so.2", linux) === nothing
    @test system_library_linker_name("ld-musl-aarch64.so.1", linux) === nothing

    macos = Platform("aarch64", "macos")
    @test system_library_linker_name("libSystem.B.dylib", macos) == "System"
    @test system_library_linker_name("libc++.1.dylib", macos) == "c++"

    windows = Platform("x86_64", "windows")
    @test system_library_linker_name("kernel32.dll", windows) == "kernel32"
    @test system_library_linker_name("libwinpthread-1.dll", windows) == "winpthread"
end

for target_platform in (Platform("x86_64", "linux"), Platform("aarch64", "macos"; os_version=v"20"))
    platform = CrossPlatform(BBHostPlatform() => target_platform)
    toolchain = CToolchain(platform; use_ccache=false)

    source_dir = joinpath(dirname(@__DIR__), "source")
    libplus_c_path = joinpath(source_dir, "libplus.c")
    libmult_c_path = joinpath(source_dir, "libmult.c")
    libctor_c_path = joinpath(source_dir, "libctor.c")
    libextra_c_path = joinpath(source_dir, "libextra.c")

    libplus_soname = versioned_shlib("libplus", 1, target_platform)
    libmult_soname = versioned_shlib("libmult", 2, target_platform)

    # Mach-O prefixes C symbols with an underscore, ELF does not
    mangle(sym) = Sys.isapple(target_platform) ? string("_", sym) : sym

    """
        build_static_prefix(prefix; with_extra)

    Build a prefix containing `libplus` and `libmult` in both their dynamic and static
    realizations.  `libplus`'s archive additionally contains an object with a static
    constructor, so that it has a `root`; if `with_extra` is set, `libmult`'s archive
    also contains an object referencing a symbol nothing provides.
    """
    function build_static_prefix(prefix; with_extra::Bool = false)
        libdir = joinpath(prefix, "lib")
        mkpath(libdir)
        objdir = mktempdir()
        with_toolchains([toolchain]) do _, env
            compile(src) = begin
                obj = joinpath(objdir, string(first(splitext(basename(src))), ".o"))
                run(setenv(`$(env["CC"]) -c -o $(obj) -fPIC $(src)`, env))
                return obj
            end
            plus_o = compile(libplus_c_path)
            mult_o = compile(libmult_c_path)
            ctor_o = compile(libctor_c_path)
            extra_o = compile(libextra_c_path)

            # Dynamic realizations; `libmult` links against `libplus`
            run(setenv(`$(env["CC"]) -o $(joinpath(libdir, libplus_soname)) -shared $(plus_o) $(ctor_o) $(soname_flag(target_platform, libplus_soname))`, env))
            symlink(libplus_soname, joinpath(libdir, "libplus$(dlext(platform))"))
            run(setenv(`$(env["CC"]) -o $(joinpath(libdir, libmult_soname)) -shared $(mult_o) -L $(libdir) -lplus $(soname_flag(target_platform, libmult_soname))`, env))

            # Static realizations
            run(setenv(`$(env["AR"]) crs $(joinpath(libdir, "libplus.a")) $(plus_o) $(ctor_o)`, env))
            mult_members = with_extra ? [mult_o, extra_o] : [mult_o]
            run(setenv(`$(env["AR"]) crs $(joinpath(libdir, "libmult.a")) $(mult_members)`, env))
        end
        # Licenses, so that the full `audit!()` has something to find
        mkpath(joinpath(prefix, "share", "licenses", "libplus"))
        touch(joinpath(prefix, "share", "licenses", "libplus", "LICENSE.md"))
        return libdir
    end

    # Run the dynamic and static passes over a prefix, returning everything of interest
    function run_static_passes(prefix, library_products; static_library_products = StaticLibraryProduct[])
        scan = scan_files(prefix, target_platform, library_products,
                          Dict("prefix" => prefix, "bb_full_target" => triplet(target_platform));
                          static_library_products)
        pass_results = Dict{String,Vector{PassResult}}()
        ensure_sonames!(scan, pass_results)
        jll_lib_products = resolve_dynamic_links!(scan, pass_results, Dict{Symbol,Vector{JLLLibraryProduct}}())
        jll_lib_products, standalone = resolve_static_libraries!(
            scan, pass_results, jll_lib_products, Dict{Symbol,Vector{JLLLibraryProduct}}())
        by_varname = Dict(p.varname => p for p in jll_lib_products)
        return (; scan, pass_results, jll_lib_products, standalone, by_varname)
    end

    @testset "static archive parsing - $(triplet(target_platform))" begin
        mktempdir() do prefix
            libdir = build_static_prefix(prefix)

            @test is_static_archive(joinpath(libdir, "libplus.a"))
            @test !is_static_archive(joinpath(libdir, libplus_soname))
            # Non-archives are simply not archives, rather than an error
            @test scan_static_archive(joinpath(libdir, libplus_soname)) === nothing

            members = read_archive_members(joinpath(libdir, "libplus.a"))
            @test length(members) == 2
            @test Set(basename.([m.name for m in members])) == Set(["libplus.o", "libctor.o"])

            contents = scan_static_archive(joinpath(libdir, "libplus.a"))
            @test contents.num_objects == 2
            @test mangle("plus") ∈ contents.defined
            @test mangle("ctor_status") ∈ contents.defined
            # `set_ctor_ran` is file-local, so it cannot satisfy anyone else's reference
            @test mangle("set_ctor_ran") ∉ contents.defined
            # The member carrying the static constructor shows up as a root
            @test contents.roots == [mangle("ctor_status")]

            # `libmult.a` references `plus`, which it does not define itself
            mult_contents = scan_static_archive(joinpath(libdir, "libmult.a"))
            @test mangle("mult") ∈ mult_contents.defined
            @test mangle("plus") ∈ mult_contents.undefined
            @test isempty(mult_contents.roots)
        end
    end

    @testset "static library inheritance - $(triplet(target_platform))" begin
        mktempdir() do prefix
            build_static_prefix(prefix)

            r = run_static_passes(prefix, [
                LibraryProduct("libplus", :libplus; static=StaticLibraryProduct("libplus.a")),
                LibraryProduct("libmult", :libmult; static=StaticLibraryProduct("libmult.a")),
            ])
            @test success(r.pass_results)
            @test isempty(r.standalone)

            libplus = r.by_varname[:libplus]
            libmult = r.by_varname[:libmult]

            # Both products point at their archives, and keep their dynamic path
            @test libplus.static_path == joinpath("lib", "libplus.a")
            @test libmult.static_path == joinpath("lib", "libmult.a")
            @test libmult.path == joinpath("lib", libmult_soname)

            # `libmult`'s archive inherits the dynamic sibling's resolved JLL edges
            @test libmult.static_deps == [JLLLibraryDep(nothing, :libplus)]
            @test isempty(libplus.static_deps)

            # ... and the system edges that `resolve_dynamic_links!()` drops
            if Sys.islinux(target_platform)
                @test "c" ∈ libplus.static_system_deps
            else
                @test "System" ∈ libplus.static_system_deps
            end
            # System deps are bare linker names, never `-l`-prefixed or versioned
            @test all(!startswith(d, "-l") && !contains(d, ".so") for d in libplus.static_system_deps)

            # The member with a static constructor is recorded as a root
            @test libplus.static_roots == [mangle("ctor_status")]
            @test isempty(libmult.static_roots)

            # The closure of both archives verified cleanly
            @test has_status(r.pass_results, static_pass_name, libplus.static_path, :success)
            @test has_status(r.pass_results, static_pass_name, libmult.static_path, :success)
        end
    end

    @testset "static library declarations - $(triplet(target_platform))" begin
        mktempdir() do prefix
            build_static_prefix(prefix)

            # An explicit list replaces the inherited one entirely, and we warn about
            # the inherited edges it dropped.
            r = run_static_passes(prefix, [
                LibraryProduct("libplus", :libplus; static=StaticLibraryProduct("libplus.a")),
                LibraryProduct("libmult", :libmult;
                               static=StaticLibraryProduct("libmult.a"; deps=String[])),
            ])
            libmult = r.by_varname[:libmult]
            @test isempty(libmult.static_deps)
            @test has_status(r.pass_results, static_pass_name, libmult.static_path, :warn)
            @test contains(messages(r.pass_results, static_pass_name, libmult.static_path), "libplus")

            # The `:inherit` sentinel augments rather than replaces
            r = run_static_passes(prefix, [
                LibraryProduct("libplus", :libplus; static=StaticLibraryProduct("libplus.a")),
                LibraryProduct("libmult", :libmult;
                               static=StaticLibraryProduct("libmult.a"; deps=[:inherit, "Zlib_jll.libz"])),
            ])
            libmult = r.by_varname[:libmult]
            @test libmult.static_deps == [JLLLibraryDep(nothing, :libplus), JLLLibraryDep(:Zlib_jll, :libz)]
            # We could not read `Zlib_jll`, so unresolved symbols are a warning, not a failure
            @test !has_status(r.pass_results, static_pass_name, libmult.static_path, :fail)

            # `system_deps` behaves identically: replacement warns about omissions...
            r = run_static_passes(prefix, [
                LibraryProduct("libplus", :libplus;
                               static=StaticLibraryProduct("libplus.a"; system_deps=String[])),
                LibraryProduct("libmult", :libmult; static=StaticLibraryProduct("libmult.a")),
            ])
            libplus = r.by_varname[:libplus]
            @test isempty(libplus.static_system_deps)
            @test has_status(r.pass_results, static_pass_name, libplus.static_path, :warn)

            # ... and the sentinel augments
            r = run_static_passes(prefix, [
                LibraryProduct("libplus", :libplus;
                               static=StaticLibraryProduct("libplus.a"; system_deps=[:inherit, "rt"])),
                LibraryProduct("libmult", :libmult; static=StaticLibraryProduct("libmult.a")),
            ])
            libplus = r.by_varname[:libplus]
            @test "rt" ∈ libplus.static_system_deps
            @test length(libplus.static_system_deps) > 1
            @test !has_status(r.pass_results, static_pass_name, libplus.static_path, :warn)
        end
    end

    @testset "static closure verification - $(triplet(target_platform))" begin
        mktempdir() do prefix
            # `libmult.a` now contains a member referencing a symbol that nothing in
            # the prefix, the dynamic sibling, or the C runtime provides.
            build_static_prefix(prefix; with_extra=true)

            r = run_static_passes(prefix, [
                LibraryProduct("libplus", :libplus; static=StaticLibraryProduct("libplus.a")),
                LibraryProduct("libmult", :libmult; static=StaticLibraryProduct("libmult.a")),
            ])
            libmult = r.by_varname[:libmult]
            @test !success(r.pass_results)
            @test has_status(r.pass_results, static_pass_name, libmult.static_path, :fail)
            @test contains(messages(r.pass_results, static_pass_name, libmult.static_path),
                           mangle("undefined_extra_symbol"))
            # `libplus` is still perfectly fine
            @test has_status(r.pass_results, static_pass_name, r.by_varname[:libplus].static_path, :success)
        end
    end

    @testset "standalone static library - $(triplet(target_platform))" begin
        mktempdir() do prefix
            build_static_prefix(prefix)

            # A standalone archive has no sibling to inherit from, so it declares
            # everything itself, and unresolved symbols can only ever be a warning.
            r = run_static_passes(prefix,
                LibraryProduct[LibraryProduct("libplus", :libplus)];
                static_library_products = [
                    StaticLibraryProduct("libmult.a"; varname=:libmult_a, deps=["libplus"], system_deps=["c"]),
                ])
            info = only(r.standalone)
            @test info.varname == :libmult_a
            @test info.path == joinpath("lib", "libmult.a")
            @test info.deps == [JLLLibraryDep(nothing, :libplus)]
            @test info.system_deps == ["c"]
            # `libplus` is in the prefix, so `mult`'s reference to `plus` resolves
            @test has_status(r.pass_results, static_pass_name, info.path, :success)

            # Standalone archives are not folded into the dynamic products
            @test all(p.static_path === nothing for p in r.jll_lib_products)
        end
    end
end

@testset "audit! with static libraries" begin
    target_platform = Platform("x86_64", "linux")
    platform = CrossPlatform(BBHostPlatform() => target_platform)
    toolchain = CToolchain(platform; use_ccache=false)
    source_dir = joinpath(@__DIR__, "..", "source")
    libplus_soname = versioned_shlib("libplus", 1, target_platform)

    mktempdir() do prefix
        libdir = joinpath(prefix, "lib")
        mkpath(libdir)
        objdir = mktempdir()
        with_toolchains([toolchain]) do _, env
            plus_o = joinpath(objdir, "libplus.o")
            run(setenv(`$(env["CC"]) -c -o $(plus_o) -fPIC $(joinpath(source_dir, "libplus.c"))`, env))
            run(setenv(`$(env["CC"]) -o $(joinpath(libdir, libplus_soname)) -shared $(plus_o) $(soname_flag(target_platform, libplus_soname))`, env))
            run(setenv(`$(env["AR"]) crs $(joinpath(libdir, "libplus.a")) $(plus_o)`, env))
        end
        mkpath(joinpath(prefix, "share", "licenses", "libplus"))
        touch(joinpath(prefix, "share", "licenses", "libplus", "LICENSE.md"))

        result = audit!(prefix,
                        [LibraryProduct("libplus", :libplus; static=StaticLibraryProduct("libplus.a"))],
                        Dict{Symbol,Vector{JLLLibraryProduct}}();
                        platform=target_platform)
        @test success(result)
        @test isempty(result.static_only_products)
        libplus = only(result.jll_lib_products)
        @test libplus.static_path == joinpath("lib", "libplus.a")
        @test has_static_realization(libplus)
        @test "c" ∈ libplus.static_system_deps

        # A second, read-only audit does not perturb the archive
        pre_treehash = treehash(prefix)
        result = audit!(prefix,
                        [LibraryProduct("libplus", :libplus; static=StaticLibraryProduct("libplus.a"))],
                        Dict{Symbol,Vector{JLLLibraryProduct}}();
                        platform=target_platform, readonly=true)
        @test treehash(prefix) == pre_treehash
        @test success(result)
    end
end
