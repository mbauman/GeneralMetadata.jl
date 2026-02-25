using TOML: TOML
using DataStructures: DefaultOrderedDict, OrderedDict
using CSV: CSV
using DataFrames: DataFrames, DataFrame, groupby, combine, transform, combine, eachrow

using GeneralMetadata: identify_components, merge_components!, normalize_repo

function main()
    # Load Repology data and reshape for efficiency
    repology_info = TOML.parsefile(joinpath(@__DIR__, "..", "repology_info.toml"))
    additional_info = TOML.parsefile(joinpath(@__DIR__, "..", "additional_info.toml"))
    repositories = Dict{String, String}()
    url_patterns = Pair{Regex, String}[]
    @info "loading repology info"
    for (proj, info) in repology_info
        if haskey(info, "repositories")
            for repo in info["repositories"]
                haskey(repositories, repo) && proj != repositories[repo] && @warn "$proj and $(repositories[repo]) are dups"
                repositories[normalize_repo(repo)] = proj
            end
        end
        if haskey(info, "url_patterns")
            for pattern in info["url_patterns"]
                # Allow both http and https, ignore compression format, and ignore case
                # The auto-generated patterns we want to fixup most use \Q and \E literal flags
                push!(url_patterns,
                    Regex(
                        replace(pattern,
                            r"^\^\\Qhttps?://"i => "^https?\\Q://",
                            r"\.(?:7z|bz2|bzip2|bz|gz|lz|lzma|rar|tar|tbz2|tbz|tgz|xz|z|zip)\\E\$$"i =>
                            ".\\E(?:7z|bz2|bzip2|bz|gz|lz|lzma|rar|tar|tbz2|tbz|tgz|xz|z|zip)\$"
                        ), "i") => proj)
            end
        end
    end

    @info "adding additional info"
    for (proj, info) in additional_info
        if haskey(info, "repositories")
            for repo in info["repositories"]
                # Allow repositories both with and without a git suffix
                repositories[chopsuffix(repo, ".git")] = proj
                repositories[chopsuffix(repo, ".git")*".git"] = proj
            end
        end
        if haskey(info, "url_patterns")
            for pattern in info["url_patterns"]
                # And allow both http and https
                push!(url_patterns, (Regex(replace(pattern, r"https?://" => "http\\Es?\\Q://"), "i") => proj))
            end
        end
    end

    @info "updating package components"
    package_components_toml = joinpath(@__DIR__, "..", "package_components.toml")
    package_components = TOML.parsefile(package_components_toml)

    jll_metadata = TOML.parsefile(joinpath(@__DIR__, "..", "jll_metadata.toml"))
    git_cache = Dict{String,String}()
    for (jllname, jllinfo) in sort(OrderedDict(jll_metadata))
        for (jllversion, verinfo) in sort(OrderedDict(jllinfo), by=VersionNumber)
            haskey(verinfo, "sources") || continue
            haskey(package_components, jllname) && haskey(package_components[jllname], jllversion) && continue
            for source in verinfo["sources"]
                components = identify_components(source; repositories, url_patterns, git_cache)
                if !isempty(components)
                    merge_components!(get!(get!(package_components, jllname, Dict{String,Any}()), jllversion, Dict{String,Any}()), components)
                end
            end
        end
    end

    @info "standardizing representations"
    # Flatten arrays of versions if they are not needed
    for (_, pkginfo) in package_components, (_, components) in pkginfo, (component, component_versions) in components
        if component_versions isa AbstractArray
            if length(component_versions) == 1
                components[component] = only(component_versions)
            elseif "*" in component_versions
                components[component] = "*"
            end
        end
    end

    # If a JLL has a component at _one_ version, ensure it's there on all versions by default:
    for (pkg, pkginfo) in package_components
        components = unique(Iterators.flatten(keys.(values(pkginfo))))
        for version in keys(jll_metadata[pkg])
            !haskey(pkginfo, version) && (pkginfo[version] = Dict{String, Any}())
            for component in components
                component in keys(pkginfo[version]) && continue
                pkginfo[version][component] = "*"
            end
        end
    end

    @info "writing output"
    open(package_components_toml, "w") do f
        println(f, """
            # This file contains the mapping between a Julia package version and the upstream project(s) it directly provides.
            # The keys are package name and version, pointing to a table that maps from an included upstream project name
            # (as defined in upstream_project_info.toml) and its version(s). Typically versions can simply be a string, but
            # in rare cases packages may include more than one copy of an upstream project at differing versions. In such cases,
            # an array of multiple versions can be specified.
            #
            # This file is automatically updated, based upon the sources recorded in jll_metadata.toml; comments are not preserved.
            # The automatic update script (`scripts/update_package_components.jl`) assumes that if a project is included at _some_
            # package version, then it should have definitions (perhaps manually entered) at all versions. To explicitly state that
            # the project is not incorporated and prevent such suggestions, use an empty array.""")
        TOML.print(f, package_components,
            inline_tables=IdSet{Dict{String,Any}}(vertable for jlltable in values(package_components) for vertable in values(jlltable) if length(values(vertable)) <= 2),
            sorted = true, by = x->something(tryparse(VersionNumber, x), x))
    end
    return package_components
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
