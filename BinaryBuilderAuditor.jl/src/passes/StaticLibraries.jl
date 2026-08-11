using BinaryBuilderProducts, JLLGenerator
using BinaryBuilderProducts: resolve_deps

const static_pass_name = "resolve_static_libraries!"

"""
    resolve_static_libraries!(scan, pass_results, jll_lib_products)

Fill in the static realization of every audited library product, and audit any
standalone static archives.

Returns `(jll_lib_products, standalone_infos)`, where the returned library products
carry their static metadata and `standalone_infos` describes the archives that have
no dynamic sibling.
"""
function resolve_static_libraries!(scan::ScanResult,
                                   pass_results::Dict{String,Vector{PassResult}},
                                   jll_lib_products::Vector{JLLLibraryProduct})
    if isempty(scan.static_library_products)
        return (jll_lib_products, StaticLibraryInfo[])
    end

    # Cache the parsed contents of every archive in the prefix, since a single
    # archive is consulted both for its own audit and as a dependency of others.
    archive_cache = Dict{String,Union{Nothing,ArchiveContents}}()
    function archive_contents(rel_path::String)
        return get!(archive_cache, rel_path) do
            abs_path = abspath(scan, rel_path)
            try
                return scan_static_archive(abs_path)
            catch exception
                push_result!(pass_results, static_pass_name, :fail, rel_path,
                             "Unable to parse static archive: $(sprint(showerror, exception))")
                return nothing
            end
        end
    end

    updated_products = JLLLibraryProduct[]
    for product in jll_lib_products
        static_rel_path = get(scan.static_realizations, product.varname, nothing)
        if static_rel_path === nothing
            push!(updated_products, product)
            continue
        end
        slp = scan.static_library_products[static_rel_path]

        # By default the archive inherits the dependency structure that the dynamic
        # sibling's DT_NEEDED entries produced.
        inherited_deps = String[generate_toml_dict(d) for d in product.deps]
        inherited_system_deps = sibling_system_deps(scan, product)

        deps, omitted_deps = resolve_deps(slp.deps, inherited_deps)
        system_deps, omitted_system_deps = resolve_deps(slp.system_deps, inherited_system_deps)
        warn_omissions(pass_results, static_rel_path, "dependencies", omitted_deps)
        warn_omissions(pass_results, static_rel_path, "system dependencies", omitted_system_deps)

        jll_deps = JLLLibraryDep[parse_toml_dict(JLLLibraryDep, d) for d in deps]
        contents = archive_contents(static_rel_path)
        roots = contents === nothing ? String[] : contents.roots
        if contents !== nothing
            verify_static_closure!(scan, pass_results, static_rel_path, contents, jll_deps,
                                   archive_contents, product)
        end

        push!(updated_products, JLLLibraryProduct(
            product.varname,
            product.path,
            product.deps;
            flags = product.flags,
            soname = product.soname,
            on_load_callback = product.on_load_callback,
            dlid = product.dlid,
            static_path = static_rel_path,
            static_deps = jll_deps,
            static_system_deps = system_deps,
            static_roots = roots,
        ))
    end

    # Now audit any standalone archives, which have no sibling to learn from.
    standalone_infos = StaticLibraryInfo[]
    for (rel_path, slp) in scan.static_library_products
        if slp.varname === nothing
            # Subordinate archives were handled above
            continue
        end
        deps, _ = resolve_deps(slp.deps, String[])
        system_deps, _ = resolve_deps(slp.system_deps, String[])
        jll_deps = JLLLibraryDep[parse_toml_dict(JLLLibraryDep, d) for d in deps]

        contents = archive_contents(rel_path)
        roots = contents === nothing ? String[] : contents.roots
        if contents !== nothing
            verify_static_closure!(scan, pass_results, rel_path, contents, jll_deps,
                                   archive_contents, nothing)
        end
        push!(standalone_infos, StaticLibraryInfo(slp.varname, rel_path, jll_deps, system_deps, roots))
    end
    sort!(standalone_infos; by = info -> info.path)

    sort!(updated_products; by = p -> p.varname)
    return (updated_products, standalone_infos)
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
    sibling_system_deps(scan, product)

The system libraries that the dynamic sibling links against, which
`resolve_dynamic_links!` intentionally drops on the floor because we do not
redistribute them.  A static link, having no `DT_NEEDED` of its own to fall back on,
must name them explicitly, so we recover the dropped set here and translate each
SONAME into the bare name a linker expects.
"""
function sibling_system_deps(scan::ScanResult, product::JLLLibraryProduct)
    rel_path = relpath(scan, product.path)
    oh = get(scan.binary_objects, rel_path, nothing)
    if oh === nothing
        return String[]
    end
    system_deps = String[]
    for dl in DynamicLinks(oh)
        soname = basename(path(dl))
        if !is_system_library(soname, scan.platform)
            continue
        end
        name = system_library_linker_name(soname, scan.platform)
        if name !== nothing
            push!(system_deps, name)
        end
    end
    return sort(unique(system_deps))
end

"""
    verify_static_closure!(scan, pass_results, rel_path, contents, jll_deps, archive_contents, sibling)

Check that every symbol the archive leaves undefined can be satisfied by something
we have declared: the archive itself, one of its `static_deps` (their archives or
their shared libraries), or the set of external symbols that the dynamic sibling
already resolves at link time (which is exactly its `DT_NEEDED` libraries plus the
C runtime, i.e. the declared system deps).

Dependencies living in *other* JLLs cannot be read from here, so when any of those
are present an unresolved symbol is reported as a warning rather than a failure.
"""
function verify_static_closure!(scan::ScanResult,
                                pass_results::Dict{String,Vector{PassResult}},
                                rel_path::String,
                                contents::ArchiveContents,
                                jll_deps::Vector{JLLLibraryDep},
                                archive_contents::Function,
                                sibling::Union{Nothing,JLLLibraryProduct})
    # Weak undefined symbols legitimately resolve to zero, and linker-synthesized
    # symbols are never provided by a library.
    unresolved = setdiff(contents.undefined, contents.weak_undefined, linker_synthesized_symbols)

    provided = Set{String}()
    unreadable_deps = String[]
    for dep in jll_deps
        if dep.mod !== nothing
            # A dependency in another JLL; we have its metadata but not its files.
            push!(unreadable_deps, generate_toml_dict(dep))
            continue
        end
        union!(provided, intra_prefix_dep_symbols(scan, dep.varname, archive_contents))
    end

    # The dynamic sibling is our oracle for everything resolved at link time: it was
    # linked successfully against precisely the libraries we are declaring here.
    if sibling !== nothing
        sibling_oh = get(scan.binary_objects, relpath(scan, sibling.path), nothing)
        if sibling_oh !== nothing
            defined, undefined, _ = object_symbols(sibling_oh; only_external=false)
            union!(provided, defined, undefined)
        end
    end

    setdiff!(unresolved, provided)
    if isempty(unresolved)
        push_result!(pass_results, static_pass_name, :success, rel_path,
                     "Static closure verified ($(contents.num_objects) objects, $(length(contents.roots)) roots)")
        return nothing
    end

    missing_syms = sort(collect(unresolved))
    preview = join(first(missing_syms, 10), ", ")
    if length(missing_syms) > 10
        preview = string(preview, ", ... (", length(missing_syms) - 10, " more)")
    end

    if sibling === nothing || !isempty(unreadable_deps)
        # We could not see everything the archive is allowed to link against, so we
        # cannot honestly call this a failure.
        reason = sibling === nothing ?
                 "no dynamic sibling to verify against; these are assumed to come from the declared system dependencies or the C runtime" :
                 "could not inspect dependencies $(join(unreadable_deps, ", "))"
        push_result!(pass_results, static_pass_name, :warn, rel_path,
                     "$(length(missing_syms)) undefined symbols left unverified ($(reason)): $(preview)")
    else
        push_result!(pass_results, static_pass_name, :fail, rel_path,
                     "$(length(missing_syms)) undefined symbols are not provided by the archive, its declared dependencies, or the C runtime: $(preview)")
    end
    return nothing
end

"""
    intra_prefix_dep_symbols(scan, varname, archive_contents)

All symbols that a dependency living in this same prefix can provide to a static
link: those of its own archive if it has one, plus those exported by its shared
library (which a static link may equally well resolve against).
"""
function intra_prefix_dep_symbols(scan::ScanResult, varname::Symbol, archive_contents::Function)
    provided = Set{String}()

    static_rel_path = get(scan.static_realizations, varname, nothing)
    if static_rel_path !== nothing
        contents = archive_contents(static_rel_path)
        if contents !== nothing
            union!(provided, contents.defined)
        end
    end

    for (rel_path, lib) in scan.library_products
        if lib.varname != varname
            continue
        end
        oh = get(scan.binary_objects, rel_path, nothing)
        if oh !== nothing
            defined, _, _ = object_symbols(oh)
            union!(provided, defined)
        end
    end
    return provided
end
