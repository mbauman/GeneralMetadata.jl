using TOML: TOML
using DataStructures: DefaultOrderedDict, OrderedDict
using CSV: CSV
using DataFrames: DataFrames, DataFrame, groupby, combine, transform, combine, eachrow

function first_match(pattern_project_pairs, needle)
    for (pattern, project) in pattern_project_pairs
        m = match(pattern, needle)
        !isnothing(m) && return (project, m.captures[1])
    end
    return nothing
end

function main()
    # Load Repology data and reshape for efficiency
    repology_info = TOML.parsefile(joinpath(@__DIR__, "..", "repology_info.toml"))
    repositories = Dict{String, String}()
    url_patterns = Pair{Regex, String}[]
    for (proj, info) in repology_info
        if haskey(info, "repositories")
            for repo in info["repositories"]
                repositories[repo] = proj
            end
        end
        if haskey(info, "url_patterns")
            for pattern in info["url_patterns"]
                push!(url_patterns, (Regex(pattern) => proj))
            end
        end
    end
    # Now walk through the JLL metadata to populate the package_components
    jll_metadata = TOML.parsefile(joinpath(@__DIR__, "..", "jll_metadata.toml"))
    package_components = DefaultOrderedDict{String, Any}(()->DefaultOrderedDict{String, Any}(()->OrderedDict{String, Any}()))
    git_cache = Dict{String,String}()
    @time for (jllname, jllinfo) in sort(OrderedDict(jll_metadata))
        for (jllversion, verinfo) in sort(OrderedDict(jllinfo), by=VersionNumber)
            haskey(verinfo, "sources") || continue
            for s in verinfo["sources"]
                if haskey(s, "url")
                    m = first_match(url_patterns, s["url"])
                    if !isnothing(m)
                        (upstream_project, upstream_version) = m
                        haskey(package_components[jllname][jllversion], upstream_project) ?
                            push!(package_components[jllname][jllversion][upstream_project], upstream_version) :
                            package_components[jllname][jllversion][upstream_project] = [upstream_version]
                    end
                end
                if haskey(s, "repo") && haskey(s, "hash") && haskey(repositories, s["repo"])
                    upstream_project = repositories[s["repo"]]
                    commit = s["hash"]
                    # Now the hard part are versions...
                    try
                        dir = get!(git_cache, upstream_project) do
                            tmp = mktempdir()
                            run(pipeline(`git clone --bare --filter=blob:none $(s["repo"]) $tmp`, stdout=Base.devnull, stderr=Base.devnull))
                            tmp
                        end
                        tag = cd(dir) do
                            t = try readchomp(`git tag --points-at $commit`) catch _ "" end
                            if isempty(t)
                                t = try readchomp(`git tag --points-at $commit\~`) catch _ "" end
                                !isempty(t) && @info "$upstream_project: found tag at $commit~;\n\n$(readchomp(`git show --format=oneline $commit`))"
                            end
                            t
                        end
                        # It can be challenging to parse a version number out of a tag; some options here include: v1.2.3 and PCRE2-1.2.3
                        # This strips all non-numeric prefixes with up to one digit as long as the digit is not followed by a period.
                        # and ignore everything after a newline
                        ver = strip(split(chopprefix(tag, r"^[^\d]*(?:\d[^\d.]+)?"), "\n", limit=2)[1])
                        @assert !isempty(ver)
                        @info "$upstream_project: got version $(ver) from git tag $tag"
                        haskey(package_components[jllname][jllversion], upstream_project) ?
                            push!(package_components[jllname][jllversion][upstream_project], ver) :
                            package_components[jllname][jllversion][upstream_project] = [ver]
                    catch ex
                        ex isa InterruptException && return package_components
                        @info "$upstream_project: failed to get tag from repo $(s["repo"])" ex
                        package_components[jllname][jllversion][upstream_project] = ["*"]
                    end
                end
            end
        end
    end

    open(joinpath(@__DIR__, "..", "package_components.toml"), "w") do f
        println("""
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
            inline_tables=IdSet{Dict{String,Any}}(vertable for jlltable in values(package_components) for vertable in values(jlltable) if length(values(vertable)) <= 2))
    end
    return package_components
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
