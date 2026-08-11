# A `static_library` product has no shared library to load, so there is nothing to
# `dlopen` and no `LazyLibrary` to construct; all a JLL wrapper can usefully offer is
# the path to the archive.  What must be linked alongside it (its dependency edges,
# system libraries and initializer roots) is consumer-facing link metadata rather than
# something the wrapper acts on, and lives in the generated `JuliaLibrary.toml`.
function static_library_product_definition(jb, artifact, product)
    var_name, path_var_name, lazy_path_var_name = gen_lazy_artifact_path(jb, artifact, product)
    push!(jb.top_level_blocks, emit_typed_global(
        var_name, String, ""; isconst=false,
    ))
    push!(jb.init_blocks, :(global $(var_name) = $(path_var_name)))
end
