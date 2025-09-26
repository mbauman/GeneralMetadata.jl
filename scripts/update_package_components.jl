using TOML: TOML
using DataStructures: DefaultOrderedDict, OrderedDict
using CSV: CSV
using DataFrames: DataFrames, DataFrame, groupby, combine, transform, combine, eachrow

function main()
    sql = """
        COPY (SELECT
            (elem.value ->> 0)::integer AS link_type,
            l.url,
            p.repo,
            p.effname,
            p.rawversion,
            p.arch,
            p.origversion,
            p.versionclass
        FROM packages p
        CROSS JOIN LATERAL json_array_elements(p.links) AS elem(value)
        JOIN links l ON l.id = (elem.value ->> 1)::integer
        WHERE (NOT p.shadow='t') AND
              ((elem.value ->> 0)::integer = 1 or (elem.value ->> 0)::integer = 2))
        TO '$pwd/out.csv' WITH (format csv);
    """
    run(`psql -h localhost -p 5433 -c $sql`)
    df = CSV.read("out.csv", DataFrame, header=["link_type",
           "url",
           "repo",
           "effname",
           "arch",
           "rawversion",
           "origversion",
           "versionclass"])
    # We'll only trust download URLs when only one was used for the given package
    # Many packages have more than one download, but then we don't know if that was a (build) dependency
    # or the actual project or perhaps some larger meta-project that vendors lots of deps.
    filtered_df = df |>
        x -> groupby(x, [:repo, :effname, :rawversion, :arch]) |>
        x -> transform(x, :url => (x -> length(unique(x))) => :n_unique_urls) |>
        x -> filter(row -> row.n_unique_urls == 1, x) |>
        # And also remove any rows for which the same URL points at two different effnames:
        x -> groupby(x, :url) |>
        x -> transform(x, :effname => (x -> length(unique(x))) => :n_unique_effnames) |>
        x -> filter(row -> row.n_unique_effnames == 1, x)

    # For repositories (link_type == 2), I know I can ignore versions:
    repo_to_effname = Dict(row.url => row.effname for row in eachrow(filtered_df[filtered_df.link_type .== 2, :]))

    # For downloads (link_type == 1), we may be able to get versions:
    url_groups = combine(groupby(filtered_df[filtered_df.link_type .== 1, :], [:url, :effname]), :origversion => (x -> [unique(x)]) => :versions)
    url_to_effname_versions = Dict(row.url => (row.effname, row.versions) for row in eachrow(url_groups))

    package_components = DefaultOrderedDict{String, Any}(()->DefaultOrderedDict{String, Any}(()->OrderedDict{String, Any}()))

    # Now walk through the JLL metadata to populate it
    jll_metadata = TOML.parsefile(joinpath(@__DIR__, "..", "jll_metadata.toml"))
    git_cache = Dict{String,String}()
    for (jllname, jllinfo) in sort(OrderedDict(jll_metadata))
        for (jllversion, verinfo) in sort(OrderedDict(jllinfo), by=VersionNumber)
            haskey(verinfo, "sources") || continue
            for s in verinfo["sources"]
                if haskey(s, "url") && haskey(url_to_effname_versions, s["url"])
                    (upstream_project, upstream_versions) = url_to_effname_versions[s["url"]]
                    haskey(package_components[jllname][jllversion], upstream_project) ?
                        append!(package_components[jllname][jllversion][upstream_project], upstream_versions) :
                        package_components[jllname][jllversion][upstream_project] = upstream_versions
                end
                if haskey(s, "repo") && haskey(s, "hash") && haskey(repo_to_effname, s["repo"])
                    upstream_project = repo_to_effname[s["repo"]]
                    # Now the hard part are versions...
                    upstream_versions = try
                        dir = get!(git_cache, upstream_project) do
                            tmp = mktempdir()
                            run(pipeline(`git clone $(s["repo"]) $tmp`, stdout=Base.devnull, stderr=Base.devnull))
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
                        @info "$upstream_project: failed to get tag from repo $(s["repo"])" ex
                        package_components[jllname][jllversion][upstream_project] = ["*"]
                    end
                end
            end
        end
    end

    open(package_components_path, "w") do f
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
    return toml
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
