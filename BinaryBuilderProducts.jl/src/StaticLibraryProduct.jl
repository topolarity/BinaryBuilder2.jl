"""
    StaticLibraryProduct(paths::Vector{String};
                         varname = nothing,
                         deps = :inherit,
                         system_deps = :inherit)

Declares a `StaticLibraryProduct` that points to a static archive (e.g. `libfoo.a`)
located within the prefix.

A `StaticLibraryProduct` can be used in two ways:

* **Subordinate** (the common case): passed as the `static` keyword argument of a
  [`LibraryProduct`](@ref), declaring that the dynamic library product also has a
  static realization.  In this case `varname` **must not** be given; the identity of
  the library is defined by the parent `LibraryProduct`, and the archive is simply
  another realization of it.

* **Standalone**: given its own `varname`, for libraries that are only ever shipped
  as an archive.  Standalone products have no dynamic sibling to learn from, so both
  `deps` and `system_deps` must be declared explicitly.

Each element of `paths` takes the form `[dirname/]basename[.a]`, where `dirname` and
the extension are both optional; omitting `dirname` prepends `lib` (on all platforms,
as static archives live in `lib` even on Windows), and omitting the extension appends
the platform's static library extension.

## Dependency declaration

Both `deps` (edges onto other JLL libraries, in the `"Pkg_jll.varname"` or bare
`"varname"` form used by `JLLLibraryDep`) and `system_deps` (bare system library
names such as `"m"` or `"pthread"`, with no `-l` prefix) accept the same three
spellings:

* `:inherit` (the default, subordinate products only) — use the set derived from the
  dynamic sibling by the auditor.
* A plain `Vector{String}` — *replace* the inherited set entirely.  Archives can
  legitimately differ from their dynamic siblings; if the replacement omits entries
  that would have been inherited, the auditor emits a warning naming them.
* A `Vector` containing the `:inherit` sentinel (at most once) alongside strings —
  *augment* the inherited set with the given entries.
"""
struct StaticLibraryProduct <: AbstractProduct
    paths::Vector{String}
    # `nothing` when subordinate to a `LibraryProduct`, which supplies the identity.
    varname::Union{Nothing,Symbol}
    deps::Union{Symbol,Vector{Union{Symbol,String}}}
    system_deps::Union{Symbol,Vector{Union{Symbol,String}}}

    function StaticLibraryProduct(paths::Vector{<:AbstractString};
                                  varname::Union{Nothing,Symbol,AbstractString} = nothing,
                                  deps = :inherit,
                                  system_deps = :inherit)
        if varname !== nothing
            varname = Symbol(varname)
            check_varname(varname)
        end
        deps = canonicalize_static_dep_spec(deps, "deps", varname)
        system_deps = canonicalize_static_dep_spec(system_deps, "system_deps", varname)
        return new(string.(paths), varname, deps, system_deps)
    end
end
StaticLibraryProduct(path::AbstractString; kwargs...) = StaticLibraryProduct([path]; kwargs...)

"""
    canonicalize_static_dep_spec(spec, kwarg_name, varname)

Normalize a `deps`/`system_deps` declaration into either the bare `:inherit` symbol
or a `Vector{Union{Symbol,String}}` that contains at most one `:inherit` sentinel.
Throws an `ArgumentError` for standalone products (those with their own `varname`)
that try to inherit, as there is no dynamic sibling to inherit from.
"""
function canonicalize_static_dep_spec(spec, kwarg_name::String, varname::Union{Nothing,Symbol})
    standalone = varname !== nothing
    if isa(spec, Symbol)
        if spec != :inherit
            throw(ArgumentError("Invalid `$(kwarg_name)` sentinel ':$(spec)', only ':inherit' is understood"))
        end
        if standalone
            throw(ArgumentError("Standalone StaticLibraryProduct '$(varname)' cannot use `$(kwarg_name) = :inherit`; there is no dynamic sibling to inherit from, declare the list explicitly"))
        end
        return :inherit
    end
    if !isa(spec, AbstractVector)
        throw(ArgumentError("Invalid `$(kwarg_name)` value $(repr(spec)); expected `:inherit` or a vector"))
    end

    out = Vector{Union{Symbol,String}}()
    num_sentinels = 0
    for entry in spec
        if isa(entry, Symbol)
            if entry != :inherit
                throw(ArgumentError("Invalid `$(kwarg_name)` sentinel ':$(entry)', only ':inherit' is understood"))
            end
            num_sentinels += 1
            push!(out, :inherit)
        elseif isa(entry, AbstractString)
            push!(out, String(entry))
        else
            throw(ArgumentError("Invalid `$(kwarg_name)` entry $(repr(entry)); expected a string or the `:inherit` sentinel"))
        end
    end
    if num_sentinels > 1
        throw(ArgumentError("`$(kwarg_name)` contains the `:inherit` sentinel $(num_sentinels) times, it may appear at most once"))
    end
    if standalone && num_sentinels > 0
        throw(ArgumentError("Standalone StaticLibraryProduct '$(varname)' cannot use the `:inherit` sentinel in `$(kwarg_name)`; there is no dynamic sibling to inherit from"))
    end
    return out
end

"""
    inherits_deps(spec)

Returns `true` if the given canonicalized `deps`/`system_deps` declaration wants the
inherited (auditor-derived) set folded in.
"""
inherits_deps(spec::Symbol) = spec === :inherit
inherits_deps(spec::Vector{Union{Symbol,String}}) = any(isa(e, Symbol) for e in spec)

"""
    declared_deps(spec)

Returns the explicitly declared entries of a canonicalized `deps`/`system_deps`
declaration, with any `:inherit` sentinel stripped out.
"""
declared_deps(::Symbol) = String[]
declared_deps(spec::Vector{Union{Symbol,String}}) = String[e for e in spec if isa(e, String)]

"""
    resolve_deps(spec, inherited::Vector{String})

Apply a canonicalized `deps`/`system_deps` declaration to the set that would be
inherited from the dynamic sibling, returning `(resolved, omitted)` where `omitted`
lists the inherited entries that a replacing declaration dropped on the floor.
"""
function resolve_deps(spec, inherited::Vector{String})
    declared = declared_deps(spec)
    if inherits_deps(spec)
        return (unique(vcat(inherited, declared)), String[])
    end
    return (unique(declared), String[d for d in inherited if d ∉ declared])
end

"""
    static_lib_ext(platform)

The file extension used for static archives on the given platform.  Every platform
we support uses `.a`, including Windows (where we build with MinGW, not MSVC).
"""
static_lib_ext(::AbstractPlatform) = "a"

# Static archives live in `lib` on every platform, unlike dynamic libraries which
# live in `bin` on Windows.
default_product_dir(::Type{StaticLibraryProduct}, platform::AbstractPlatform) = "lib"

"""
    locate(slp::StaticLibraryProduct, prefix::String; env, platform)

If the given static archive exists, return its location relative to `prefix`,
otherwise return `nothing`.
"""
function locate(slp::StaticLibraryProduct, prefix::String;
                env::Dict{String,String} = Dict{String,String}(),
                platform::AbstractPlatform = parse(Platform, env_checked_get(env, "bb_full_target")))
    @debug("Locating StaticLibraryProduct", slp)
    ext = static_lib_ext(platform)
    for path in slp.paths
        path = path_prefix_transformation(StaticLibraryProduct, path, prefix, platform, env)

        # Unlike dynamic libraries, static archives are not versioned, so the only
        # fuzziness we allow is the (single, platform-defined) file extension.
        candidates = [path]
        if !endswith(path, ".$(ext)")
            push!(candidates, string(path, ".", ext))
        end

        for candidate in candidates
            rel_path = prefix_remove(candidate, prefix)
            @debug("Trying", rel_path)
            if isfile(candidate)
                @debug("Found", rel_path)
                return rel_path
            end
        end
    end
    return nothing
end
