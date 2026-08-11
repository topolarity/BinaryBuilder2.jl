using BinaryBuilderProducts, JLLGenerator
using BinaryBuilderProducts: resolve_deps

const static_pass_name = "resolve_static_libraries!"

"""
    StaticDepResolution

What the auditor learned about a single declared static dependency edge: whether the
library it names ships a static realization, and which symbols we could actually
observe it providing.  `symbols === nothing` means the edge resolved to a library
whose files are not reachable from here (it lives in another JLL that was not
unpacked), so nothing can be verified against it.
"""
struct StaticDepResolution
    dep::JLLLibraryDep
    has_static::Bool
    symbols::Union{Nothing,Set{String}}
end

"""
    resolve_static_libraries!(scan, pass_results, jll_lib_products, dep_libs; dep_artifact_dirs)

Fill in the static realization of every audited library product, and audit any
archive-only products.

Returns the library products with their static realizations attached, together with
new products for the archives that have no dynamic sibling.
"""
function resolve_static_libraries!(scan::ScanResult,
                                   pass_results::Dict{String,Vector{PassResult}},
                                   jll_lib_products::Vector{JLLLibraryProduct},
                                   dep_libs::Dict{Symbol,Vector{JLLLibraryProduct}};
                                   dep_artifact_dirs::Dict{Symbol,String} = Dict{Symbol,String}())
    if isempty(scan.static_library_products)
        return jll_lib_products
    end

    # Cache the parsed contents of every archive we touch, since a single archive is
    # consulted both for its own audit and as a dependency of others.
    archive_cache = Dict{String,Union{Nothing,ArchiveContents}}()
    function archive_contents(abs_path::String, identifier::String)
        return get!(archive_cache, abs_path) do
            try
                return scan_static_archive(abs_path)
            catch exception
                push_result!(pass_results, static_pass_name, :fail, identifier,
                             "Unable to parse static archive: $(sprint(showerror, exception))")
                return nothing
            end
        end
    end

    # `resolve_dynamic_links!` already told us the SONAME of each of our own library
    # products, which is how we recognize a `DT_NEEDED` entry as one of our own.
    own_soname_map = Dict{String,Symbol}(
        basename(p.dynamic.soname) => p.varname for p in jll_lib_products if p.dynamic !== nothing)

    # Every varname this JLL provides, including archive-only products
    own_varnames = Set{Symbol}(p.varname for p in jll_lib_products)
    for (_, slp) in scan.static_library_products
        if slp.varname !== nothing
            push!(own_varnames, slp.varname)
        end
    end

    ctx = (; scan, pass_results, dep_libs, dep_artifact_dirs, archive_contents,
             own_varnames, jll_lib_products)

    updated_products = JLLLibraryProduct[]
    for product in jll_lib_products
        static_rel_path = get(scan.static_realizations, product.varname, nothing)
        if static_rel_path === nothing
            push!(updated_products, product)
            continue
        end
        slp = scan.static_library_products[static_rel_path]

        # By default the archive inherits the dependency structure the dynamic
        # sibling's DT_NEEDED entries produced, plus the edges onto our own libraries
        # that `resolve_dynamic_links!` dropped as "system" libraries.
        own_dropped, system_dropped = sibling_dropped_edges(scan, product, own_soname_map)
        inherited_deps = unique(vcat(String[generate_toml_dict(d) for d in product.dynamic.deps],
                                     String[string(v) for v in own_dropped]))

        deps, omitted_deps = resolve_deps(slp.deps, inherited_deps)
        system_deps, omitted_system_deps = resolve_deps(slp.system_deps, system_dropped)
        warn_omissions(pass_results, static_rel_path, "dependencies", omitted_deps)
        warn_omissions(pass_results, static_rel_path, "system dependencies", omitted_system_deps)

        jll_deps = JLLLibraryDep[parse_toml_dict(JLLLibraryDep, d) for d in deps]
        resolutions = resolve_static_deps!(ctx, static_rel_path, jll_deps)

        contents = archive_contents(abspath(scan, static_rel_path), static_rel_path)
        roots = contents === nothing ? String[] : contents.roots
        if contents !== nothing
            verify_static_closure!(ctx, static_rel_path, contents, resolutions, product)
        end

        push!(updated_products, JLLLibraryProduct(
            product.varname,
            product.dynamic,
            JLLStaticRealization(static_rel_path;
                                 deps = jll_deps,
                                 system_deps = system_deps,
                                 roots = roots),
        ))
    end

    # Now audit the archive-only products, which have no sibling to learn from.
    static_only_products = JLLLibraryProduct[]
    for (rel_path, slp) in scan.static_library_products
        if slp.varname === nothing
            # Subordinate archives were handled above
            continue
        end
        deps, _ = resolve_deps(slp.deps, String[])
        system_deps, _ = resolve_deps(slp.system_deps, String[])
        jll_deps = JLLLibraryDep[parse_toml_dict(JLLLibraryDep, d) for d in deps]
        resolutions = resolve_static_deps!(ctx, rel_path, jll_deps)

        contents = archive_contents(abspath(scan, rel_path), rel_path)
        roots = contents === nothing ? String[] : contents.roots
        if contents !== nothing
            verify_static_closure!(ctx, rel_path, contents, resolutions, nothing)
        end
        push!(static_only_products, JLLLibraryProduct(
            slp.varname;
            static = JLLStaticRealization(rel_path; deps = jll_deps, system_deps, roots),
        ))
    end
    append!(updated_products, static_only_products)
    sort!(updated_products; by = p -> p.varname)
    return updated_products
end

function warn_omissions(pass_results, rel_path::String, what::String, omitted::Vector{String})
    if isempty(omitted)
        return nothing
    end
    push_result!(pass_results, static_pass_name, :warn, rel_path,
                 "Declared $(what) omit $(length(omitted)) inherited from the dynamic sibling: $(join(omitted, ", "))")
    return nothing
end

"""
    sibling_dropped_edges(scan, product, own_soname_map)

Recover the `DT_NEEDED` entries of the dynamic sibling that `resolve_dynamic_links!`
intentionally dropped, because it does not track libraries we do not redistribute.

A static link has no `DT_NEEDED` of its own to fall back on, so it must name them.
Returns `(own, system)`: the dropped entries that are in fact products of this very
JLL become real dependency edges, and only the genuinely external ones are reported
as system libraries, translated from SONAME into the bare name a linker expects.
"""
function sibling_dropped_edges(scan::ScanResult, product::JLLLibraryProduct,
                               own_soname_map::Dict{String,Symbol})
    rel_path = relpath(scan, product.dynamic.path)
    oh = get(scan.binary_objects, rel_path, nothing)
    if oh === nothing
        return (Symbol[], String[])
    end
    own = Symbol[]
    system = String[]
    for dl in DynamicLinks(oh)
        soname = basename(path(dl))
        if !is_system_library(soname, scan.platform)
            continue
        end
        # A library we ship ourselves is never a "system" library, however much it
        # looks like one from the outside (e.g. `libgcc_s` within CompilerSupportLibraries).
        if haskey(own_soname_map, soname)
            varname = own_soname_map[soname]
            if varname != product.varname
                push!(own, varname)
            end
            continue
        end
        name = system_library_linker_name(soname, scan.platform)
        if name !== nothing
            push!(system, name)
        end
    end
    return (unique(own), sort(unique(system)))
end

"""
    resolve_static_deps!(ctx, rel_path, jll_deps)

Resolve every declared static dependency edge against the libraries we know about.
A dangling edge — one naming a JLL we do not depend on, or a library that JLL does
not provide — is a hard failure, since nothing downstream could ever satisfy it.

Edges that resolve to a library with no static realization are surfaced as warnings:
the link will have to provision that dependency dynamically.
"""
function resolve_static_deps!(ctx, rel_path::String, jll_deps::Vector{JLLLibraryDep})
    resolutions = StaticDepResolution[]
    for dep in jll_deps
        resolution = if dep.mod === nothing
            resolve_own_dep(ctx, rel_path, dep)
        else
            resolve_foreign_dep(ctx, rel_path, dep)
        end
        if resolution === nothing
            continue
        end
        if !resolution.has_static
            # Not an anomaly: linking an archive against a dependency that only ships a
            # shared library is the normal arrangement (libgfortran.a against libgcc_s,
            # say).  It is recorded so that the consumer's provisioning is visible in the
            # audit log, but it must not fail the build, since any non-success result does.
            push_result!(ctx.pass_results, static_pass_name, :success, rel_path,
                         "Static dependency '$(generate_toml_dict(dep))' has no static realization; " *
                         "a static link against this archive will provision it dynamically")
        end
        push!(resolutions, resolution)
    end
    return resolutions
end

function resolve_own_dep(ctx, rel_path::String, dep::JLLLibraryDep)
    if dep.varname ∉ ctx.own_varnames
        push_result!(ctx.pass_results, static_pass_name, :fail, rel_path,
                     "Static dependency '$(dep.varname)' does not name any library product of this build")
        return nothing
    end

    symbols = Set{String}()
    has_static = false
    static_rel_path = get(ctx.scan.static_realizations, dep.varname, nothing)
    if static_rel_path === nothing
        # An archive-only product has no entry in `static_realizations`; find it directly
        for (candidate_path, slp) in ctx.scan.static_library_products
            if slp.varname == dep.varname
                static_rel_path = candidate_path
                break
            end
        end
    end
    if static_rel_path !== nothing
        has_static = true
        contents = ctx.archive_contents(abspath(ctx.scan, static_rel_path), static_rel_path)
        if contents !== nothing
            union!(symbols, contents.defined)
        end
    end

    # A dependency's shared library can satisfy the same references, so fold it in too
    for (lib_rel_path, lib) in ctx.scan.library_products
        if lib.varname != dep.varname
            continue
        end
        oh = get(ctx.scan.binary_objects, lib_rel_path, nothing)
        if oh !== nothing
            defined, _, _ = object_symbols(oh)
            union!(symbols, defined)
        end
    end
    return StaticDepResolution(dep, has_static, symbols)
end

# `dep_libs` and `dep_artifact_dirs` are keyed by the JLL name without its `_jll` suffix,
# while a `JLLLibraryDep` names the module, which carries it.
function dep_libs_key(mod::Symbol)
    name = string(mod)
    return Symbol(endswith(name, "_jll") ? name[1:end-4] : name)
end

function resolve_foreign_dep(ctx, rel_path::String, dep::JLLLibraryDep)
    key = dep_libs_key(dep.mod)
    libs = get(ctx.dep_libs, key, nothing)
    if libs === nothing
        push_result!(ctx.pass_results, static_pass_name, :fail, rel_path,
                     "Static dependency '$(generate_toml_dict(dep))' names '$(dep.mod)', which is not a dependency of this build")
        return nothing
    end
    idx = findfirst(lib -> lib.varname == dep.varname, libs)
    if idx === nothing
        available = join(sort([string(lib.varname) for lib in libs]), ", ")
        push_result!(ctx.pass_results, static_pass_name, :fail, rel_path,
                     "Static dependency '$(generate_toml_dict(dep))' does not name a library product of '$(dep.mod)' " *
                     "(it provides: $(isempty(available) ? "nothing" : available))")
        return nothing
    end
    dep_lib = libs[idx]
    has_static = dep_lib.static !== nothing

    # If the dependency's artifact was unpacked for this build, we can read it and
    # verify against the real thing; otherwise we can only take the edge on trust.
    artifact_dir = get(ctx.dep_artifact_dirs, key, nothing)
    if artifact_dir === nothing || !isdir(artifact_dir)
        return StaticDepResolution(dep, has_static, nothing)
    end

    symbols = Set{String}()
    if has_static
        archive_path = joinpath(artifact_dir, dep_lib.static.path)
        if isfile(archive_path)
            contents = ctx.archive_contents(archive_path, rel_path)
            if contents !== nothing
                union!(symbols, contents.defined)
            end
        end
    end
    lib_path = dep_lib.dynamic === nothing ? nothing : joinpath(artifact_dir, dep_lib.dynamic.path)
    if lib_path !== nothing && isfile(lib_path)
        oh = get_object_handle(lib_path, ctx.scan.platform)
        if oh !== nothing
            defined, _, _ = object_symbols(oh)
            union!(symbols, defined)
        end
    end
    return StaticDepResolution(dep, has_static, isempty(symbols) ? nothing : symbols)
end

"""
    verify_static_closure!(ctx, rel_path, contents, resolutions, sibling)

Check that every symbol the archive leaves undefined can be satisfied by something we
declared: the archive itself, one of its resolved dependencies, or the set of external
symbols the dynamic sibling already resolves at link time (which is exactly its
`DT_NEEDED` libraries plus the C runtime, i.e. the declared system deps).

An unresolved symbol is a failure when every dependency was readable, and a warning
when one was not, since in that case we cannot prove the symbol is genuinely missing.
"""
function verify_static_closure!(ctx, rel_path::String, contents::ArchiveContents,
                                resolutions::Vector{StaticDepResolution},
                                sibling::Union{Nothing,JLLLibraryProduct})
    # Weak undefined symbols legitimately resolve to zero, and linker-synthesized
    # symbols are never provided by a library.
    unresolved = setdiff(contents.undefined, contents.weak_undefined, linker_synthesized_symbols)

    provided = Set{String}()
    unreadable = String[]
    for resolution in resolutions
        if resolution.symbols === nothing
            push!(unreadable, generate_toml_dict(resolution.dep))
        else
            union!(provided, resolution.symbols)
        end
    end

    # The dynamic sibling is our oracle for everything resolved at link time: it was
    # linked successfully against precisely the libraries we are declaring here.
    if sibling !== nothing
        sibling_oh = get(ctx.scan.binary_objects, relpath(ctx.scan, sibling.dynamic.path), nothing)
        if sibling_oh !== nothing
            defined, undefined, _ = object_symbols(sibling_oh; only_external=false)
            union!(provided, defined, undefined)
        end
    end

    setdiff!(unresolved, provided)
    if isempty(unresolved)
        push_result!(ctx.pass_results, static_pass_name, :success, rel_path,
                     "Static closure verified ($(contents.num_objects) objects, $(length(contents.roots)) roots)")
        return nothing
    end

    missing_syms = sort(collect(unresolved))
    preview = join(first(missing_syms, 10), ", ")
    if length(missing_syms) > 10
        preview = string(preview, ", ... (", length(missing_syms) - 10, " more)")
    end

    if sibling === nothing && isempty(resolutions)
        push_result!(ctx.pass_results, static_pass_name, :warn, rel_path,
                     "$(length(missing_syms)) undefined symbols left unverified (no dynamic sibling and no " *
                     "declared dependencies to check against; assumed to come from the declared system " *
                     "dependencies or the C runtime): $(preview)")
    elseif !isempty(unreadable)
        push_result!(ctx.pass_results, static_pass_name, :warn, rel_path,
                     "$(length(missing_syms)) undefined symbols left unverified (could not inspect " *
                     "$(join(unreadable, ", "))): $(preview)")
    else
        push_result!(ctx.pass_results, static_pass_name, :fail, rel_path,
                     "$(length(missing_syms)) undefined symbols are not provided by the archive, its " *
                     "declared dependencies, or the C runtime: $(preview)")
    end
    return nothing
end
