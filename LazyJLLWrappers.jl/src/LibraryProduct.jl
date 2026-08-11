# TODO: Decide if this is the best thing to do, or if we should record it in the JLL.toml?
function soname(product)
    if Sys.isapple()
        return "@rpath/$(basename(product["dynamic"]["path"]))"
    else
        return basename(product["dynamic"]["path"])
    end
end

"""
    lazy_library_expr(lazy_path_var_name, deps_expr, flags_expr, product, with_identity)

Build the `LazyLibrary(...)` constructor expression for a library product.
`with_identity` mirrors `hasfield(Libdl.LazyLibrary, :id)`; when set and the
product declares a stable library identity (`dlid`), we pass it along via the
`id` keyword argument (supported on Julia v1.13+).  It is taken as an argument
so that the expression shape is testable on Julia versions whose `LazyLibrary`
does not have that field.
"""
function lazy_library_expr(lazy_path_var_name, deps_expr, flags_expr, product, with_identity::Bool)
    ex = :(LazyLibrary(
        $(lazy_path_var_name),
        dependencies = $(deps_expr),
        flags = $(flags_expr),
    ))
    if with_identity && haskey(product, "dlid")
        push!(ex.args, Expr(:kw, :id, Base.UUID(product["dlid"])))
    end
    return ex
end


function library_product_definition(jb::JLLBlocks, artifact, product)
    # Call `gen_lazy_artifact_path` first to generate our lazy artifact paths
    # and the `path` value itself.  We directly use the `lazy_path_var_name`
    # object itself though, as it can be used even during compilation.
    var_name, path_var_name, lazy_path_var_name = gen_lazy_artifact_path(jb, artifact, product)

    function mod_dot_name(name)
        split_name = split(name, ".")
        if length(split_name) == 1
            # dependency from within this JLL
            return Symbol(name)
        else
            # Dependency from another JLL
            mod, lib = split_name
            return Expr(:., Symbol(mod), QuoteNode(Symbol(lib)))
        end
    end

    if isdefined(Libdl, :LazyLibrary)
        # On Julia v1.11+ we can use `LazyLibrary`
        push!(jb.top_level_blocks, emit_typed_global(
            var_name, LazyLibrary, lazy_library_expr(
                lazy_path_var_name,
                :(LazyJLLWrappers.filter_non_lazy_libraries([$(mod_dot_name.(product["dynamic"]["deps"])...)])),
                Expr(:call, :|, [Expr(:., :Libdl, QuoteNode(f)) for f in Symbol.(product["dynamic"]["flags"])]...),
                product,
                # On Julia v1.13+, `LazyLibrary` can declare a stable identity
                hasfield(LazyLibrary, :id),
            ); isconst=true,
        ))
    else
        # Without `LazyLibrary` support, we export a `String`.  On Julia v1.6+ we
        # will overwrite this
        push!(jb.top_level_blocks, emit_typed_global(
            var_name, String, soname(product); isconst = VERSION < v"1.6.0",
        ))

        # Eagerly dlopen the library (now that the path has been resolved at `__init__()` time)
        push!(jb.init_blocks, :(dlopen($(path_var_name))))

        # Also, invoke the callback function in `__init__()` here.
        if haskey(product["dynamic"], "on_load_callback")
            push!(jb.init_blocks, :($(Symbol(product["dynamic"]["on_load_callback"]))()))
        end

        if VERSION >= v"1.6.0"
            # Update our exported path with the absolute path, on older Julia versions it
            # just stays as the SONAME because we did not have support for non-const library
            # values in `ccall()` invocations.
            push!(jb.init_blocks, :(global $(var_name) = $(path_var_name)))
        end
    end
end
