module GeneralMetadata

import TOML, JSON3, HTTP, CSV
using DataFrames: DataFrames, DataFrame
using Dates: Dates, DateTime, Date, Day, Millisecond

function manifest_packages(manifest_path)
    collect(keys(TOML.parsefile(manifest_path)["deps"]))
end

# Write your package code here.
function license(packagename)
    JSON3.read(String(HTTP.get("https://juliahub.com/docs/General/$packagename/stable/pkg.json").body)).license
end

function write_csv_for_manifest(manifest_path, output_path)
    pkgs = manifest_packages(manifest_path)
    licenses = [(try license(pkg); catch ex; missing end) for pkg in pkgs]
    CSV.write(output_path, DataFrame(pkg=pkgs, license=licenses))
end

const GENERAL = Ref{String}()
function general_repo()
    isassigned(GENERAL) && return GENERAL[]
    dir = mktempdir()
    run(`git clone https://github.com/JuliaRegistries/General $dir`)
    return GENERAL[] = dir
end
const REGISTRATION_DATES = Ref{Dict{String, Any}}()
registration_dates() = isassigned(REGISTRATION_DATES) ? REGISTRATION_DATES[] :
    (REGISTRATION_DATES[] = isfile(joinpath(@__DIR__, "..", "registration_dates.toml")) ?
        TOML.parsefile(joinpath(@__DIR__, "..", "registration_dates.toml")) : Dict{String, Any}())

function extract_registration_dates(dates = registration_dates(); after=maximum(Iterators.flatmap(values, Iterators.flatmap(values, values(dates))), init=DateTime("2018-08-08T17:02:39")), before=after + Dates.Year(1))
    # This uses --first-parent to get the _availability_ date on master
    cd(general_repo()) do
        commits = split(readchomp(`git rev-list --first-parent --reverse --after=$(after)Z --before=$(before)Z master`), "\n")
        N = length(commits)
        @info "processing $(N) commits from $(commits[begin])..$(commits[end])"
        t = Dates.now()-Dates.Hour(1)
        fastpaths = 0
        for (i, commit) in enumerate(commits)
            fastpaths += process_commit!(dates, commit)
            (Dates.now()-t) > Dates.Second(60) && (println("commit: ", commit, " ($i/$N; $fastpaths/$i fastpaths)"); t = Dates.now())
        end
    end
    return dates
end

function extract_simple_tags_from_diff(commit)
    # Rather than using a general Diff/TOML parser, this just very specifically parses the typical one-package diff
    # to Versions.toml. If we can't match this, then we fall back to checking out and parsing the entire registry (slow!).
    diff = readchomp(`git show --first-parent $commit -U0 --no-commit-id --no-notes --pretty="" -- '*/Versions.toml'`)
    newlines = findall(==('\n'), diff)
    positions = [0; newlines[8:8:end]; length(diff)]
    regex = r"""
        ^\Qdiff --git a/\E(.*)\Q/Versions.toml b/\E\1\Q/Versions.toml
        index \E.*\Q
        --- a/\E\1\Q/Versions.toml
        +++ b/\E\1\Q/Versions.toml
        @@ \E.*\Q
        +
        +["\E(.*)\Q"]
        +git-tree-sha1 = "\E.*\Q"\E$"""
    pkg_vers = Pair{String,String}[]
    for i in 1:length(positions)-1
        chunk = SubString(diff, positions[i]+1, positions[i+1])
        m = match(regex, chunk)
        isnothing(m) && return nothing
        path, ver = m.captures
        push!(pkg_vers, splitpath(path)[end] => ver)
    end
    return pkg_vers
end

function process_commit!(dates, commit)
    # First attempt to direclty extract a new tag from the diff directly
    stamp = readchomp(addenv(`git log $commit -1 --format="%cd" --date=iso-strict-local`, "TZ"=>"UTC"))
    timestamp = parse(DateTime, chopsuffix(chopsuffix(stamp, "+00:00"), "Z"))
    pkg_vers = extract_simple_tags_from_diff(commit)
    if !isnothing(pkg_vers)
        fastpath = true
        for (pkg, ver) in pkg_vers
            if !haskey(dates, pkg)
                dates[pkg] = Dict{String, Any}()
            end
            if haskey(dates[pkg], ver) && dates[pkg][ver]["registered"] != timestamp
                @warn "commit $commit ($timestamp) introduced $pkg $ver, but it's already set to $(dates[pkg][ver]["registered"])"
            else
                dates[pkg][ver] = Dict{String,Any}("registered" => timestamp)
            end
        end
    else
        fastpath = false
        # Checkout the entire state of the repo at this commit
        run(pipeline(`git checkout $commit`, stdout=Base.devnull, stderr=Base.devnull))
        reg = TOML.parsefile("Registry.toml")
        for (uuid, pkginfo) in reg["packages"]
            pkg = pkginfo["name"]
            isfile(joinpath(pkginfo["path"], "Versions.toml")) || continue
            versions = TOML.parsefile(joinpath(pkginfo["path"], "Versions.toml"))
            if !haskey(dates, pkg)
                dates[pkg] = Dict{String, Any}()
            end
            for (ver, info) in versions
                isempty(info) && continue # There has been at least one time when a corrupted entry was commited (a60167d6c29b433119d6fbf051a733fa465e6ae7)
                if !haskey(dates[pkg], ver)
                    dates[pkg][string(ver)] = Dict{String, Any}()
                end
                if !haskey(dates[pkg][string(ver)], "registered")
                    dates[pkg][string(ver)]["registered"] = timestamp
                end
                if get(info, "yanked", false) == true && !haskey(dates[pkg][string(ver)], "yanked")
                    dates[pkg][string(ver)]["yanked"] = timestamp
                end
            end
        end
    end
    return fastpath
end

"""
    normalize_repo(url)

Given a URL to some repository, strip the schema (e.g., https:// or git://) and .git suffix (if they exist)
"""
normalize_repo(url) = chopprefix(chopsuffix(url, ".git"), r"[^:/]+://")

function get_version_from_commit(repo, commit; git_cache=Dict{String,String}())
    try
        dir = get!(git_cache, repo) do
            tmp = mktempdir()
            run(pipeline(`git clone --filter=tree:0 --no-checkout --tags $repo $tmp`, stdout=Base.devnull, stderr=Base.devnull))
            tmp
        end
    catch _
        @warn "Failed to clone repo $repo to get version information for commit $commit"
        return ""
    end
    tag = cd(dir) do
        try
            readchomp(`git tag --points-at $commit`)
        catch _
            try
                run(`git fetch origin $commit`)
                readchomp(`git tag --points-at $commit`)
            catch _
                ""
            end
        end
    end
    # It can be challenging to parse a version number out of a tag; some options here include: v1.2.3 and PCRE2-1.2.3
    # This strips all non-numeric prefixes with up to one digit as long as the digit is not followed by a period.
    # and ignore everything after a newline (multiple tags are newline separated, with the latest first)
    ver = strip(split(chopprefix(tag, r"^[^\d]*(?:\d[^\d.]+)?"), "\n", limit=2)[1])
    return ver
end

function merge_components!(dest, src)
    for (upstream_project, upstream_versions) in src
        if haskey(dest, upstream_project)
            union!(dest[upstream_project], upstream_versions)
        else
            dest[upstream_project] = upstream_versions
        end
    end
    return dest
end

function identify_components(source; repositories, url_patterns, git_cache=Dict{String,String}())
    component_info = Dict{String, Vector{String}}()
    if haskey(source, "url")
        for (upstream_project, upstream_version) in all_matches(url_patterns, source["url"])
            v = isempty(upstream_version) ? ["*"] : [upstream_version]
            haskey(component_info, upstream_project) ?
                union!(component_info[upstream_project], v) :
                component_info[upstream_project] = v
        end
    end
    if haskey(source, "repo") && haskey(source, "hash") && haskey(repositories, normalize_repo(source["repo"]))
        upstream_project = repositories[normalize_repo(source["repo"])]
        commit = source["hash"]
        # Now the hard part are versions...
        ver = get_version_from_commit(source["repo"], commit; git_cache)
        if isempty(ver)
            # try getting it from the prior version
            # lots of projects tag and then make some minor version number fix
            ver = get_version_from_commit(source["repo"], commit*"~"; git_cache)
            !isempty(ver) && @info "$upstream_project: found tag at $commit~"
        end
        if !isempty(ver)
            @info "$upstream_project: got version $(ver) from git repo tag"
            haskey(component_info, upstream_project) ?
                union!(component_info[upstream_project], [ver]) :
                component_info[upstream_project] = [ver]
        else
            @info "$upstream_project: failed to get tag from repo $(source["repo"])"
            component_info[upstream_project] = ["*"]
        end
    end
    return component_info
end

function all_matches(pattern_project_pairs, needle)
    result = Tuple{String,String}[]
    for (pattern, project) in pattern_project_pairs
        m = match(pattern, needle)
        !isnothing(m) && push!(result, (project, m.captures[1]))
    end
    return result
end


end
