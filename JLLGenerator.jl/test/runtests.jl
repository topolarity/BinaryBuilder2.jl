using JLLGenerator, Test, Base.BinaryPlatforms, Libdl, TOML

using JLLGenerator: rtld_symbols, rtld_flags, default_rtld_flags
@testset "RTLD flags" begin
    @test default_rtld_flags & RTLD_LAZY != 0
    @test rtld_symbols(RTLD_LAZY | RTLD_FIRST) == [:RTLD_FIRST, :RTLD_LAZY]
    @test rtld_flags([:RTLD_DEEPBIND, :RTLD_LOCAL, :RTLD_NOLOAD]) == RTLD_DEEPBIND | RTLD_LOCAL | RTLD_NOLOAD

    @test rtld_flags(Symbol[]) == 0x00000000
    @test rtld_symbols(0x00000000) == Symbol[]
    @test rtld_flags(rtld_symbols(default_rtld_flags)) == default_rtld_flags

    @test_throws ArgumentError rtld_flags([:RTLD_THIS_FLAG_DOES_NOT_EXIST])
    @test_throws ArgumentError rtld_symbols(0x80000000)
end

@testset "License names" begin
    if !Sys.isapple()
        for (name, text) in JLLGenerator.license_texts
            poss_names = JLLGenerator.licensecheck(text).licenses_found
            @test length(poss_names) == 1
            @test name == only(poss_names)
        end
    end
end

function roundtrip_jll_through_toml(jll)
    io = IOBuffer()
    TOML.print(io, generate_toml_dict(jll))
    toml_str = String(take!(io))
    d = TOML.parse(toml_str)
    return d, parse_toml_dict(d)
end

mit_license = JLLBuildLicense("LICENSE.md", JLLGenerator.get_license_text("MIT"))

@testset "Hand-crafted XZ_jll" begin
    # Hand-crafted XZ_jll impersonation
    xz_sources = [
        JLLSourceRecord("https://tukaani.org/xz/xz-5.4.3.tar.xz", "92177bef62c3824b4badc524f8abcce54a20b7dbcfb84cde0a2eb8b49159518c"),
    ]
    # These dependencies are not real, but I want to include them anyway for test coverage
    liblzma_deps = [
        JLLLibraryDep(:Glibc_jll, :libc),
    ]
    xz_deps = [
        JLLPackageDependency(:Glibc_jll),
    ]
    jll = JLLInfo(;
        name = "XZ",
        version = v"5.4.3+1",
        builds = [
            JLLBuildInfo(;
                src_version = v"5.4.3",
                deps = xz_deps,
                sources = xz_sources,
                platform = Platform("x86_64", "linux"),
                name = "XZ",
                artifact = JLLArtifactBinding(;
                    treehash = "214deacf44273474118c5fe83871fdfa8039b4ad",
                    download_sources = [
                        JLLArtifactSource(
                            "https://github.com/JuliaBinaryWrappers/XZ_jll.jl/releases/download/XZ-v5.4.3%2B1/XZ.v5.4.3.x86_64-linux-gnu.tar.gz",
                            "70a053a45c76811bbb475aa43e0e0781c9e972d2fb57b67d35aa32a30de90336",
                        ),
                    ],
                ),
                products = [
                    JLLExecutableProduct(:xz, "bin/xz"),
                    JLLFileProduct(:liblzma_a, "lib/liblzma.a"),
                    JLLLibraryProduct(:liblzma, "lib/liblzma.so.5", liblzma_deps),
                ],
                licenses = [mit_license],
            ),
            JLLBuildInfo(;
                src_version = v"5.4.3",
                deps = xz_deps,
                sources = xz_sources,
                platform = Platform("x86_64", "windows"),
                name = "XZ",
                artifact = JLLArtifactBinding(;
                    treehash = "4b8bb762c5118ee8ad81e67b981fe7d6a17fae77",
                    download_sources = [
                        JLLArtifactSource(
                            "https://github.com/JuliaBinaryWrappers/XZ_jll.jl/releases/download/XZ-v5.4.3%2B1/XZ.v5.4.3.x86_64-w64-mingw32.tar.gz",
                            "3f05d8023b1776315c1761a67f87611859e9c8e9b2bd598592133d7d979f8e3e",
                        ),
                    ],
                ),
                products = [
                    JLLExecutableProduct(:xz, "bin/xz.exe"),
                    JLLFileProduct(:liblzma_a, "lib/liblzma.a"),
                    JLLLibraryProduct(:liblzma, "bin/liblzma-5.dll", liblzma_deps),
                ],
                licenses = [mit_license],
            ),
            JLLBuildInfo(;
                src_version = v"5.4.3",
                deps = xz_deps,
                sources = xz_sources,
                platform = Platform("aarch64", "macos"),
                name = "XZ",
                artifact = JLLArtifactBinding(;
                    treehash = "abb153d4516c6a0ee718ea8f8cde9466de07553c",
                    download_sources = [
                        JLLArtifactSource(
                            "https://github.com/JuliaBinaryWrappers/XZ_jll.jl/releases/download/XZ-v5.4.3%2B1/XZ.v5.4.3.aarch64-apple-darwin.tar.gz",
                            "93b6890109b5dc9e6e022888cef5e8d3180a4ea0eae3ceab1ce6f247b5fbc66c",
                        ),
                    ],
                ),
                products = [
                    JLLExecutableProduct(:xz, "bin/xz"),
                    JLLFileProduct(:liblzma_a, "lib/liblzma.a"),
                    JLLLibraryProduct(:liblzma, "lib/liblzma.5.dylib", liblzma_deps),
                ],
                licenses = [mit_license],
            ),
        ],
        julia_compat = "1.7",
    )

    # Turn this into TOML, and back into a Dict:
    d, _ = roundtrip_jll_through_toml(jll)

    # Do some very basic assertions on the contents of this TOML file
    @test d["name"] == "XZ"
    @test d["version"] == "5.4.3+1"
    @test length(d["builds"]) == 3

    for aidx in 1:length(d["builds"])
        @test only(d["builds"][aidx]["deps"])["name"] == "Glibc_jll"
        @test only(d["builds"][aidx]["deps"])["compat"] == "*"
        @test length(d["builds"][aidx]["products"]) == 3
        @test length(d["builds"][aidx]["sources"]) == 1

        prods = d["builds"][aidx]["products"]
        for (prod_name, prod) in prods
            if prod["type"] == "library"
                @test only(prod["dynamic"]["deps"]) == "Glibc_jll.libc"
            end
        end
    end

    # Parse it back in and ensure it's identical
    @test jll == parse_toml_dict(d)

    # Test that `select_platform()` works on the `jll` object itself
    @test select_platform(jll, Platform("x86_64", "linux")).artifact.treehash == "214deacf44273474118c5fe83871fdfa8039b4ad"

    # Generate a JLL on-disk
    mktempdir() do dir
        generate_jll(dir, jll)

        @test isfile(joinpath(dir, "JLL.toml"))
        @test isfile(joinpath(dir, "README.md"))
        @test isfile(joinpath(dir, "LICENSE.md"))
        @test isfile(joinpath(dir, "Project.toml"))
        @test isfile(joinpath(dir, "src", "$(jll.name)_jll.jl"))

        # Parse the TOML back on disk, make sure it matches
        @test jll == parse_toml_dict(TOML.parsefile(joinpath(dir, "JLL.toml")))

        # Test that the Project.toml declares Glibc_jll as a dependency,
        # and that there is a compat bound on Julia itself.
        project = TOML.parsefile(joinpath(dir, "Project.toml"))
        @test project["name"] ==  "XZ_jll"
        @test haskey(project["deps"], "Glibc_jll")
        @test haskey(project["compat"], "julia")

        @test !haskey(project["deps"], "Pkg")
        @test haskey(project["deps"], "Artifacts")
    end
end

@testset "Duplicate dependencies" begin
    function make_dual_deps_constraint(compat1, compat2)
        return JLLInfo(;
            name = "Zlib",
            version = v"1.2.13+1",
            builds = [
                JLLBuildInfo(;
                    src_version = v"1.2.13+1",
                    deps = [
                        JLLPackageDependency(
                            "Glibc_jll",
                            nothing,
                            compat1,
                        ),
                    ],
                    platform = Platform("aarch64", "linux"; libc = "glibc"),
                    name = "Zlib",
                    artifact = JLLArtifactBinding(
                        treehash = "0c6c284985577758b3a339c6215c9d4e3d71420e",
                        download_sources = [],
                    ),
                    products = [],
                    licenses = [mit_license],
                ),
                JLLBuildInfo(;
                    src_version = v"1.2.13+1",
                    deps = [
                        JLLPackageDependency(
                            "Glibc_jll",
                            nothing,
                            compat2,
                        ),
                    ],
                    platform = Platform("aarch64", "linux"; libc = "musl"),
                    name = "Zlib",
                    artifact = JLLArtifactBinding(
                        treehash = "377fed6108dca72651d7cb705a0aee7ce28d4a5b",
                        download_sources = [],
                    ),
                    products = [],
                    licenses = [mit_license],
                ),
            ]
        )
    end

    # This should throw an error because the compat bounds on `Glibc_jll` are messed up.
    jll = make_dual_deps_constraint("2.12.2 - 2.17", "2.19 - 2.24")
    mktempdir() do dir
        @test_throws ArgumentError generate_jll(dir, jll)
    end

    # This should be just fine, because it is an overlap in the compats.
    jll = make_dual_deps_constraint("2.12.2 - 2.17", "2.15 - 2.24")
    mktempdir() do dir
        generate_jll(dir, jll)

        @test isfile(joinpath(dir, "Project.toml"))
        project = TOML.parsefile(joinpath(dir, "Project.toml"))
        @test project["compat"]["Glibc_jll"] == "2.15 - 2.17"

        # Because this JLL doesn't have any exotic platforms, it defaults to Julia v1.0
        # and therefore depends on `Pkg`
        @test project["compat"]["julia"] == "1.0"
        @test haskey(project["deps"], "Pkg")
        @test !haskey(project["deps"], "Artifacts")
    end
end

@testset "Missing Dependency" begin
    # This throws an error because we declare our library as depending on `Glibc_jll.libc`,
    # but we don't declare a dependency on `Glibc_jll`.
    @test_throws ArgumentError JLLInfo(;
        name = "Zlib",
        version = v"1.2.13+1",
        builds = [
            JLLBuildInfo(;
                src_version = v"1.2.13+1",
                platform = Platform("aarch64", "linux"; libc = "glibc"),
                name = "Zlib",
                artifact = JLLArtifactBinding(
                    treehash = "0c6c284985577758b3a339c6215c9d4e3d71420e",
                    download_sources = [],
                ),
                products = [
                    JLLLibraryProduct(
                        :libz,
                        "bin\\libz.dll",
                        [JLLLibraryDep("Glibc_jll", "libc")],
                        flags = [:RTLD_LAZY, :RTLD_DEEPBIND],
                    ),
                ],
                licenses = [mit_license],
            ),
        ]
    )
end

@testset "Missing Licenses" begin
    @test_throws ArgumentError JLLInfo(;
        name = "Zlib",
        version = v"1.2.13+1",
        builds = [
            JLLBuildInfo(;
                src_version = v"1.2.13+1",
                platform = Platform("aarch64", "linux"; libc = "glibc"),
                name = "Zlib",
                artifact = JLLArtifactBinding(
                    treehash = "0c6c284985577758b3a339c6215c9d4e3d71420e",
                    download_sources = [],
                ),
                products = [],
                licenses = [],
            ),
        ]
    )
end

@testset "Intra-JLL library dependency" begin
    function make_intra_jll_dependency(incoherent)
        return JLLInfo(;
            name = "CompilerSupportLibraries",
            version = v"1.0.5+1",
            builds = [
                JLLBuildInfo(;
                    src_version = v"1.0.5+1",
                    platform = Platform("aarch64", "macos"; libgfortran_version = "5.0.0"),
                    name = "CompilerSupportLibraries",
                    artifact = JLLArtifactBinding(;
                        treehash = "f9547d56705c03a6e887a01aeb0f0b6b030b7060",
                        download_sources = [
                            JLLArtifactSource(
                                "https://github.com/JuliaBinaryWrappers/CompilerSupportLibraries_jll.jl/releases/download/CompilerSupportLibraries-v1.0.5+1/CompilerSupportLibraries.v1.0.5.aarch64-apple-darwin-libgfortran5.tar.gz",
                                "c7d0330a55d3b32fbe1b6f73c43e9b9d6649f23b6d9034efd5e107b1d537ab53",
                            ),
                        ],
                    ),
                    products = [
                        JLLLibraryProduct(
                            :libgcc_s,
                            "lib/libgcc_s.1.1.dylib",
                            [],
                            flags = [:RTLD_LAZY, :RTLD_DEEPBIND],
                        ),
                        JLLLibraryProduct(
                            :libquadmath,
                            "lib/libquadmath.1.dylib",
                            incoherent ? [JLLLibraryDep(nothing, :does_not_exist)] : [],
                            flags = [:RTLD_LAZY, :RTLD_DEEPBIND],
                        ),
                        JLLLibraryProduct(
                            :libgfortran,
                            "lib/libgfortran.5.dylib",
                            [JLLLibraryDep(nothing, :libgcc_s), JLLLibraryDep(nothing, :libquadmath)],
                            flags = [:RTLD_LAZY, :RTLD_DEEPBIND],
                        ),
                        JLLLibraryProduct(
                            :libstdcxx,
                            "lib/libstdc++.6.dylib",
                            [JLLLibraryDep(nothing, :libgcc_s)],
                            flags = [:RTLD_LAZY, :RTLD_DEEPBIND],
                        ),
                    ],
                    licenses = [mit_license],
                ),
            ],
        )
    end

    # Test that a properly-generated JLL can refer to its own products in its library dependencies:
    jll = make_intra_jll_dependency(false)
    d, new_jll = roundtrip_jll_through_toml(jll)

    products = only(d["builds"])["products"]
    @test length([p for (_, p) in products if p["type"] == "library" && length(p["dynamic"]["deps"]) > 0]) == 2

    # Also test that this roundtripped properly
    @test jll == new_jll

    # Test that an improperly-generated JLL throws an error if it can't resolve one of its own products
    @test_throws ArgumentError make_intra_jll_dependency(true)
end

@testset "on-load callbacks" begin
    function make_on_load_callback(incoherent)
        return jll = JLLInfo(;
            name = "libblastrampoline",
            version = v"5.8.0+1",
            builds = [
                JLLBuildInfo(;
                    src_version = v"5.8.0+1",
                    deps = [],
                    sources = [],
                    platform = Platform("aarch64", "macos"; ),
                    name = "libblastrampoline",
                    artifact = JLLArtifactBinding(;
                        treehash = "214e75bb92aa2acc9de8ff89f8d1aaeeba8fd26d",
                        download_sources = [
                            JLLArtifactSource(
                                "https://github.com/JuliaBinaryWrappers/libblastrampoline_jll.jl/releases/download/libblastrampoline-v5.8.0+1/libblastrampoline.v5.8.0.aarch64-apple-darwin.tar.gz",
                                "2b241d3105f62bfae7ce56b4d7957a4a17272e743e2e23a57ccec1ee36140aac",
                            ),
                        ],
                    ),
                    products = [
                        JLLLibraryProduct(
                            :libblastrampoline,
                            "lib/libblastrampoline.5.4.0.dylib",
                            [];
                            flags = [:RTLD_LAZY, :RTLD_DEEPBIND],
                            on_load_callback = incoherent ? :callback_does_not_exist : :libblastrampoline_on_load_callback,
                        ),
                    ],
                    callback_defs = Dict(
                        :libblastrampoline_on_load_callback => """
                        function libblastrampoline_on_load_callback()
                            println("this is our callback!")
                        end
                        """
                    ),
                    licenses = [mit_license],
                ),
            ],
        )
    end

    jll = make_on_load_callback(false)
    d, new_jll = roundtrip_jll_through_toml(jll)
    @test contains(only(d["builds"])["callback_defs"]["libblastrampoline_on_load_callback"], "this is our callback")
    @test jll == new_jll

    # Trying to declare a library product with a non-existant on-load callback fails
    @test_throws ArgumentError make_on_load_callback(true)
end

using UUIDs: UUIDs
using JLLGenerator: uuid5
@testset "uuid5" begin
    # RFC 4122 version-5 test vector: uuid5(NAMESPACE_DNS, "python.org")
    ns_dns = Base.UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
    u = uuid5(ns_dns, "python.org")
    @test u == Base.UUID("886313e1-3b8a-5372-9b90-0c9aee199e5d")

    # Agrees with the stdlib implementation, unlike `jll_specific_uuid5()`
    key = "libzstd"
    @test uuid5(ns_dns, key) == UUIDs.uuid5(ns_dns, key)
    @test JLLGenerator.jll_specific_uuid5(ns_dns, key) != UUIDs.uuid5(ns_dns, key)

    # Version and variant fields are properly set
    @test UUIDs.uuid_version(uuid5(ns_dns, key)) == 5
end

@testset "Library identity (dlid)" begin
    # Identity is a property of the library, not of any one build's realization of it,
    # so it is stated once at the top level and appears nowhere in a build.
    lp = JLLLibraryProduct(:libzstd, "lib/libzstd.so.1", [])
    @test !haskey(generate_toml_dict(lp), "dlid")

    function make_zlib_jll(products; kwargs...)
        return JLLInfo(;
            name = "Zlib",
            version = v"1.2.13+1",
            builds = [
                JLLBuildInfo(;
                    src_version = v"1.2.13+1",
                    platform = Platform("aarch64", "linux"; libc = "glibc"),
                    name = "Zlib",
                    artifact = JLLArtifactBinding(
                        treehash = "0c6c284985577758b3a339c6215c9d4e3d71420e",
                        download_sources = [],
                    ),
                    products,
                    licenses = [mit_license],
                ),
            ],
            kwargs...,
        )
    end

    # Assembling a `JLLInfo` names every library it provides
    jll = make_zlib_jll([JLLLibraryProduct(:libz, "lib/libz.so.1", [])])
    @test jll.products == Dict(:libz => uuid5(Base.UUID(jll), "libz"))

    d, new_jll = roundtrip_jll_through_toml(jll)
    @test d["products"]["libz"]["dlid"] == string(jll.products[:libz])
    # ... and nothing about identity leaks into the build
    @test !haskey(only(d["builds"])["products"]["libz"], "dlid")
    @test new_jll == jll

    # Only libraries are named; an executable has no identity
    jll = make_zlib_jll([
        JLLLibraryProduct(:libz, "lib/libz.so.1", []),
        JLLExecutableProduct(:zlib_tool, "bin/zlib_tool"),
    ])
    @test sort(collect(keys(jll.products))) == [:libz]

    # An explicitly-supplied identity is honored rather than recomputed
    dlid = Base.UUID("d91c531c-5cb2-4b4c-b32b-3f7ad0f81f0f")
    jll = make_zlib_jll([JLLLibraryProduct(:libz, "lib/libz.so.1", [])];
                        products = Dict(:libz => dlid))
    @test jll.products[:libz] == dlid
    @test roundtrip_jll_through_toml(jll)[2] == jll

    # A library realized by a build but missing from the identity table is incoherent
    @test_throws ArgumentError make_zlib_jll([JLLLibraryProduct(:libz, "lib/libz.so.1", [])];
                                             products = Dict{Symbol,Base.UUID}())
end

@testset "Realization groups" begin
    # A library with both realizations nests each one under its own group
    lp = JLLLibraryProduct(:libgfortran, "lib/libgfortran.so.5.0.0",
                           [JLLLibraryDep(nothing, :libquadmath)];
                           soname = "libgfortran.so.5",
                           static_path = "lib/libgfortran.a",
                           static_deps = [JLLLibraryDep(nothing, :libquadmath)],
                           static_system_deps = ["c", "m"],
                           static_roots = ["ctor"])
    @test has_dynamic_realization(lp) && has_static_realization(lp)
    d = generate_toml_dict(lp)
    @test d["type"] == "library"
    # Nothing about a realization leaks to the top level any more
    @test !any(haskey(d, k) for k in ("path", "soname", "flags", "deps", "static_path"))
    @test d["dynamic"]["path"] == "lib/libgfortran.so.5.0.0"
    @test d["dynamic"]["soname"] == "libgfortran.so.5"
    @test d["dynamic"]["deps"] == ["libquadmath"]
    @test d["static"]["path"] == "lib/libgfortran.a"
    @test d["static"]["system_deps"] == ["c", "m"]
    @test d["static"]["roots"] == ["ctor"]
    @test parse_toml_dict(JLLLibraryProduct, "libgfortran", d) == lp

    # A library with only a shared realization has no `static` group at all
    dyn_only = JLLLibraryProduct(:libz, "lib/libz.so.1", [])
    @test !has_static_realization(dyn_only)
    @test !haskey(generate_toml_dict(dyn_only), "static")
    @test parse_toml_dict(JLLLibraryProduct, "libz", generate_toml_dict(dyn_only)) == dyn_only

    # ... and one with only an archive has no `dynamic` group, which is how a consumer
    # knows that asking to load it is an error rather than an oversight
    static_only = JLLLibraryProduct(:libfoo;
        static = JLLStaticRealization("lib/libfoo.a";
                                      deps = [JLLLibraryDep(nothing, :libz)],
                                      system_deps = ["m"]))
    @test !has_dynamic_realization(static_only)
    d2 = generate_toml_dict(static_only)
    @test d2["type"] == "library"
    @test !haskey(d2, "dynamic")
    @test d2["static"]["path"] == "lib/libfoo.a"
    @test parse_toml_dict(AbstractJLLProduct, "libfoo", d2) == static_only

    # A product must be realized somehow
    @test_throws ArgumentError JLLLibraryProduct(:libnothing)
    # Static metadata still needs an archive to hang off of
    @test_throws ArgumentError JLLLibraryProduct(:libz, "lib/libz.so.1", []; static_system_deps=["m"])

    # `library_deps` spans every realization
    @test library_deps(lp) == [JLLLibraryDep(nothing, :libquadmath)]
    @test library_deps(static_only) == [JLLLibraryDep(nothing, :libz)]

    function make_jll(products)
        return JLLInfo(; name = "Demo", version = v"1.0.0", builds = [
            JLLBuildInfo(;
                src_version = v"1.0.0",
                platform = Platform("x86_64", "linux"),
                name = "Demo",
                artifact = JLLArtifactBinding(
                    treehash = "0c6c284985577758b3a339c6215c9d4e3d71420e",
                    download_sources = [],
                ),
                products,
                licenses = [mit_license],
            ),
        ])
    end

    # Both realizations' edges are held to the same coherence standard
    @test_throws ArgumentError make_jll([
        JLLLibraryProduct(:libfoo; static = JLLStaticRealization("lib/libfoo.a";
                                                deps = [JLLLibraryDep(nothing, :nope)])),
    ])
    @test_throws ArgumentError make_jll([
        JLLLibraryProduct(:libfoo, "lib/libfoo.so", [JLLLibraryDep(:Zlib_jll, :libz)]),
    ])

    # An archive-only product gets a stable identity like any other library, and a
    # library product may depend on it
    jll = make_jll([
        JLLLibraryProduct(:libfoo; static = JLLStaticRealization("lib/libfoo.a")),
        JLLLibraryProduct(:libbar, "lib/libbar.so.1", [];
                          static_path = "lib/libbar.a",
                          static_deps = [JLLLibraryDep(nothing, :libfoo)]),
    ])
    @test jll.products[:libfoo] == JLLGenerator.uuid5(Base.UUID(jll), "libfoo")
    _, new_jll = roundtrip_jll_through_toml(jll)
    @test new_jll == jll
end

@testset "Build location" begin
    binding = JLLArtifactBinding(treehash = "0c6c284985577758b3a339c6215c9d4e3d71420e",
                                 download_sources = [])
    mkbuild(; kwargs...) = JLLBuildInfo(; src_version = v"1.0.0",
                                        platform = Platform("x86_64", "linux"),
                                        name = "Demo",
                                        products = [JLLLibraryProduct(:libz, "lib/libz.so.1", [])],
                                        licenses = [mit_license], kwargs...)

    # Anything we generate lives in an artifact, and says so
    build = mkbuild(; artifact = binding)
    @test build.location == "artifact"
    @test generate_toml_dict(build)["location"] == "artifact"

    # A hand-written record whose libraries ship with the package is `bundled`, and
    # binds no artifact at all
    bundled = mkbuild()
    @test bundled.location == "bundled"
    d = generate_toml_dict(bundled)
    @test d["location"] == "bundled"
    @test !haskey(d, "artifact")

    # The location and the binding must agree in both directions
    @test_throws ArgumentError mkbuild(; location = "artifact")
    @test_throws ArgumentError mkbuild(; artifact = binding, location = "bundled")
    @test_throws ArgumentError mkbuild(; artifact = binding, location = "somewhere-else")

    # ... and a bundled build cannot be generated into a package, since there is
    # nothing to bind into `Artifacts.toml`
    jll = JLLInfo(; name = "Demo", version = v"1.0.0", builds = [bundled])
    mktempdir() do dir
        @test_throws ArgumentError generate_jll(dir, jll)
    end

    # A bundled library is found by soname when it declares no path
    r = parse_toml_dict(JLLDynamicRealization,
                        Dict("soname" => "libz.so.1", "deps" => [], "flags" => String[]))
    @test r.path == "libz.so.1"
    @test r.soname == "libz.so.1"
end

@testset "JLL.toml format marker" begin
    jll = JLLInfo(; name = "Demo", version = v"1.0.0", builds = [
        JLLBuildInfo(; src_version = v"1.0.0", platform = Platform("x86_64", "linux"),
                     name = "Demo",
                     artifact = JLLArtifactBinding(
                        treehash = "0c6c284985577758b3a339c6215c9d4e3d71420e",
                        download_sources = []),
                     products = [JLLLibraryProduct(:libz, "lib/libz.so.1", [])],
                     licenses = [mit_license])])
    d = generate_toml_dict(jll)
    # A string version, in the style of `manifest_format`
    @test d["jll_format"] == "2.0"
    @test d["jll_format"] isa String
    @test parse_toml_dict(d) == jll

    # A record from before the format break is refused outright rather than misread
    legacy = copy(d); delete!(legacy, "jll_format")
    @test_throws ArgumentError parse_toml_dict(legacy)
    # ... as is one from a future major version
    future = copy(d); future["jll_format"] = "3.0"
    @test_throws ArgumentError parse_toml_dict(future)
    nonsense = copy(d); nonsense["jll_format"] = "not-a-version"
    @test_throws ArgumentError parse_toml_dict(nonsense)

    # Every generated JLL requires a wrapper that understands the v2 format
    mktempdir() do dir
        generate_jll(dir, jll)
        on_disk = TOML.parsefile(joinpath(dir, "JLL.toml"))
        @test on_disk["jll_format"] == "2.0"
        # Products are keyed by name, so a name cannot be duplicated by construction
        @test haskey(only(on_disk["builds"])["products"], "libz")
        @test !haskey(only(on_disk["builds"])["products"]["libz"], "name")
        @test TOML.parsefile(joinpath(dir, "Project.toml"))["compat"]["LazyJLLWrappers"] == "2.0.0"
        # The projection is gone; JuliaC consumes `JLL.toml` directly now
        @test !isfile(joinpath(dir, "JuliaLibrary.toml"))
    end
end

# Test that we can generate all of the stdlib JLLs in `contrib/`
@testset "stdlib JLL generation" begin
    include(joinpath(dirname(@__DIR__), "contrib", "gen_julia_jlls.jl"))
end

@testset "jll_auto_upgrade_helper" begin
    # Just make sure this tool doesn't bitrot too bad:
    mktempdir() do dir
        contrib_dir = joinpath(dirname(@__DIR__), "contrib")
        run(`$(Base.julia_cmd()) --project=$(contrib_dir) -e 'import Pkg; Pkg.instantiate()'`)

        test_repos = [
            ("https://github.com/JuliaBinaryWrappers/Zlib_jll.jl", "2c0602d8ec8557ee3f0beb7fd60b324bfc5def82"),
            ("https://github.com/JuliaBinaryWrappers/GMP_jll.jl", "76b821798c26f25ce230cbfd2237da63255b3931"),
            ("https://github.com/JuliaBinaryWrappers/p7zip_jll.jl", "10fd1c830f63c9095104d4bce34afac8171b31c2"),
            ("https://github.com/JuliaBinaryWrappers/CompilerSupportLibraries_jll.jl", "7aeb8eeda1cb109833b8f81d23045fd0e9e31eed"),
        ]
        for (url, commit) in test_repos
            jllinfo_def = readchomp(`$(Base.julia_cmd()) --project=$(contrib_dir) $(contrib_dir)/jll_auto_upgrade_helper.jl $(url) $(commit)`)

            # Just assume no library dependencies for this simple test
            jllinfo_def = replace(jllinfo_def, "<deps>" => "")
            
            # Try constructing the JLLInfo object:
            m = Module()
            Core.eval(m, :(using JLLGenerator))
            Core.eval(m, Meta.parse(jllinfo_def))

            # Round-trip the JLLInfo object to TOML and ensure it comes back clean:
            jll = Core.eval(m, :jll)
            @test jll == roundtrip_jll_through_toml(jll)[2]
        end
    end
end

@testset "Upgrade" begin
    zlib_products = [
        JLLLibraryProduct(:libz, "lib/libz.so.1", []),
    ]
    old_zlib_jll = JLLInfo(;
        name = "Zlib",
        version = v"1.2.13+1",
        builds = [
            JLLBuildInfo(;
                src_version = v"1.2.13+1",
                deps = [],
                platform = Platform("aarch64", "linux"; libc = "glibc"),
                name = "Zlib",
                artifact = JLLArtifactBinding(
                    treehash = "0c6c284985577758b3a339c6215c9d4e3d71420e",
                    download_sources = [],
                ),
                products = zlib_products,
                licenses = [mit_license],
            ),
            JLLBuildInfo(;
                src_version = v"1.2.13+1",
                deps = [],
                platform = Platform("aarch64", "linux"; libc = "musl"),
                name = "Zlib",
                artifact = JLLArtifactBinding(
                    treehash = "377fed6108dca72651d7cb705a0aee7ce28d4a5b",
                    download_sources = [],
                ),
                products = zlib_products,
                licenses = [mit_license],
            ),
        ]
    )

    new_zlib_jll = JLLInfo(;
        name = "Zlib",
        version = v"1.2.13+1",
        builds = [
            JLLBuildInfo(;
                src_version = v"1.2.13+1",
                deps = [],
                platform = Platform("aarch64", "linux"; libc = "glibc"),
                name = "Zlib",
                artifact = JLLArtifactBinding(
                    treehash = "0c6c284985577758b3a339c6215c9d4e3d71420e",
                    download_sources = [],
                ),
                products = zlib_products,
                licenses = [mit_license],
            ),
        ]
    )

    mktempdir() do dir
        mkpath(joinpath(dir, ".git"))
        touch(joinpath(dir, ".git", "bar"))
        generate_jll(dir, old_zlib_jll)
        touch(joinpath(dir, "foo.txt"))

        @test isfile(joinpath(dir, "foo.txt"))
        @test isfile(joinpath(dir, ".git", "bar"))
        jll_dict = parse_toml_dict(TOML.parsefile(joinpath(dir, "JLL.toml")))
        @test length(jll_dict.builds) == 2

        # Ensure that if we generate_jll() into the same location
        # we clear out extraneous files (but not `.git/*`) and
        # lose all previous content.
        generate_jll(dir, new_zlib_jll)
        jll_dict = parse_toml_dict(TOML.parsefile(joinpath(dir, "JLL.toml")))
        @test !isfile(joinpath(dir, "foo.txt"))
        @test isfile(joinpath(dir, ".git", "bar"))
        @test length(jll_dict.builds) == 1
    end
end

# Ensure that all of our example JLLInfos are valid and roundtrip properly.
@testset "Example JLLInfos" begin
    for example_file in readdir(joinpath(dirname(@__DIR__), "contrib", "example_jllinfos"); join=true)
        jll = include(example_file)
        @test roundtrip_jll_through_toml(jll)[2] == jll
    end
end

using BinaryBuilderSources, Base.BinaryPlatforms, Pkg
using BinaryBuilderSources: PkgSpec
@testset "JLLSource TOML loading" begin
    # `Ncurses_jll` was published before the v2 format, so its `JLL.toml` describes its
    # library products in the old flat shape.  Loading it must fail loudly rather than
    # silently misread every library path; it becomes readable again once regenerated.
    jll = JLLSource(PkgSpec(;
        name = "Ncurses_jll",
        uuid = "68e3532b-a499-55ff-9963-d1c0c0748b3a",
        tree_hash = Base.SHA1("f801fa135e0e3aa5b7ff026ff8b5fdcfefefdb3c"),
        repo=Pkg.Types.GitRepo(
            rev="3574bb57a8e29d239be1228fadbc1951ff7d50c6",
            source="https://github.com/staticfloat/Ncurses_jll.jl",
        ),
    ), Platform("aarch64", "linux"))

    mktempdir() do prefix
        prepare(jll; depot=prefix, ignore_empty_registries=true)
        @test_throws ArgumentError parse_toml_dict(jll; depot=prefix)
    end
end
