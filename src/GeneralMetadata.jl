module GeneralMetadata

import TOML, JSON3, HTTP, CSV, Pkg, Downloads
using DataFrames: DataFrames, DataFrame
using Dates: Dates, DateTime, Date, Day, Millisecond

## Abstract away some Pkg internals into one common place:
function registered_package_names()
    registry = only(filter(x->x.name == "General", Pkg.Registry.reachable_registries()))
    return Set(x.name for x in values(registry.pkgs))
end

function registered_package_versions(pkgname)
    registry = only(filter(x->x.name == "General", Pkg.Registry.reachable_registries()))
    pkg_info = only(values(filter(((k,v),)->v.name == pkgname, registry.pkgs)))
    if VERSION < v"1.13-"
        Pkg.Registry.init_package_info!(pkg_info)
    else
        Pkg.Registry.init_package_info!(registry, pkg_info)
    end
    return pkg_info.info.version_info
end

function uuid_from_name(pkg_name)
    registry = only(filter(x->x.name == "General", Pkg.Registry.reachable_registries()))
    return only(Pkg.Registry.uuids_from_name(registry, pkg_name))
end

## The main entry point:
function metadata()
    if isdir(joinpath(@__DIR__, "..", "metadata"))
        meta = Dict{String,Any}()
        for (root, _, files) in walkdir(joinpath(@__DIR__, "..", "metadata")), file in files
             path = joinpath(root, file)
             if endswith(path, ".toml")
                pkg = splitext(basename(path))[1]
                meta[pkg] = TOML.parsefile(path)
            end
        end
        return meta
    else
        meta = Dict{String,Any}()
        dates = TOML.parsefile(joinpath(@__DIR__, "..", "registration_dates.toml"))
        artifacts = TOML.parsefile(joinpath(@__DIR__, "..", "artifact_urls.toml"))

        all_registered_names = registered_package_names()
        for package in union(keys(dates), keys(artifacts))
            if !(package in all_registered_names)
                # Remove deleted packages from the metadata (typically a cappened one)
                continue
            end
            reg_info = registered_package_versions(package)
            pkg_dates = get(dates, package, Dict{String,Any}())
            pkg_artifacts = get(artifacts, package, Dict{String,Any}())
            pkg_meta = Dict{String,Any}()
            last_artifacts = nothing
            for version in sort(collect(union(keys(pkg_dates), keys(pkg_artifacts))), by=VersionNumber, rev=true)
                if !(VersionNumber(version) in keys(reg_info))
                    # Remove deleted versions from the metadata (typically a cappened one), but some mistakes, too
                    continue
                end
                pkg_meta[version] = Dict{String,Any}()
                if haskey(pkg_dates, version)
                    pkg_meta[version] = pkg_dates[version]
                end
                if haskey(pkg_artifacts, version)
                    pkg_meta[version]["artifact_urls"] = pkg_artifacts[version]
                    last_artifacts = pkg_artifacts[version]
                elseif !isnothing(last_artifacts)
                    pkg_meta[version]["artifact_urls"] = last_artifacts
                end
            end
            meta[package] = pkg_meta
        end
        return meta
    end
end

function save_metadata!(meta)
    for (pkg_name, pkg_meta) in meta
        output_path = joinpath(@__DIR__, "..", "metadata", string(uppercase(pkg_name[1])), "$pkg_name.toml")
        mkpath(dirname(output_path))
        if isfile(output_path)
            @assert basename(output_path) == "$pkg_name.toml" "Output path $output_path does not match expected package name $pkg_name"
        end
        open(output_path, "w") do io
            TOML.print(io, pkg_meta, sorted = true, by = x->something(tryparse(VersionNumber, x), x))
        end
    end
end

function last_update(meta)
    maximum(get(verinfo, "registered", Dates.DateTime(0)) for (pkg, pkginfo) in meta for (ver, verinfo) in pkginfo)
end

function manifest_packages(manifest_path)
    collect(keys(TOML.parsefile(manifest_path)["deps"]))
end

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

function update_registration_dates!(meta = metadata(); after=maximum(Iterators.map(v->get(v, "registered", Dates.DateTime(0)), Iterators.flatmap(values, values(meta))), init=DateTime("2018-08-08T17:02:39")), before=after + Dates.Year(1))
    # This uses --first-parent to get the _availability_ date on master
    cd(general_repo()) do
        commits = split(readchomp(`git rev-list --first-parent --reverse --after=$(after)Z --before=$(before)Z master`), "\n")
        N = length(commits)
        @info "processing $(N) commits from $(commits[begin])..$(commits[end])"
        t = Dates.now()-Dates.Hour(1)
        fastpaths = 0
        for (i, commit) in enumerate(commits)
            fastpaths += process_commit!(meta, commit)
            (Dates.now()-t) > Dates.Second(60) && (println("commit: ", commit, " ($i/$N; $fastpaths/$i fastpaths)"); t = Dates.now())
        end
    end
    return meta
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
            if !haskey(dates[pkg], ver)
                dates[pkg][ver] = Dict{String, Any}()
            end
            if haskey(dates[pkg][ver], "registered") && dates[pkg][ver]["registered"] != timestamp
                error("commit $commit ($timestamp) introduced $pkg $ver, but it's already set to $(dates[pkg][ver]["registered"])")
            else
                dates[pkg][ver]["registered"] = timestamp
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
    catch ex
        @warn "Failed to clone repo $repo to get version information for commit $commit" ex
        return ""
    end
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

function gather_artifact_urls(uuid, sha)
    url = "https://pkg.julialang.org/package/$(uuid)/$(sha)"
    mktemp() do _, iogz
        Downloads.download(url, iogz)
        seekstart(iogz)
        artifact_toml = untar_file(x->x.path in Artifacts.artifact_names, GzipDecompressorStream(iogz))
        isnothing(artifact_toml) && return String[]

        artifacts = TOML.parse(artifact_toml)
        urls = Set{String}()
        for (_, artifact_info) in artifacts
            # Normalize to a vector of dicts, even if there's only one artifact
            for entry in (artifact_info isa AbstractDict ? [artifact_info] : artifact_info)
                for dl in get(entry, "download", [])
                    push!(urls, dl["url"])
                end
            end
        end
        return sort(collect(urls))
    end
end

function get_artifact_toml(tarball)
    open(tarball) do iogz
        io = GzipDecompressorStream(iogz)
        return untar_file(x->x.path in Artifacts.artifact_names, io)
    end
end

function untar_file(filter, io)
    buf = Vector{UInt8}(undef, Tar.DEFAULT_BUFFER_SIZE)
    result = Ref{Union{Nothing, String}}(nothing)
    Tar.read_tarball(filter, io; buf) do hdr, _
        if hdr.type == :file
            ret = IOBuffer()
            Tar.read_data(io, ret; size=hdr.size, buf)
            result[] = String(take!(ret))
        end
    end
    return result[]
end

function update_artifact_urls!(meta = metadata(); max_downloads=10000)
    download_count = 0
    for (pkg_name, pkg_info) in meta
        pkg_uuid = uuid_from_name(pkg_name)
        reg_info = registered_package_versions(pkg_name)
        for (ver, ver_info) in pkg_info
            haskey(ver_info, "artifact_urls") && continue
            @info "Updating artifact URLs for $pkg_name v$ver"
            artifact_urls = try
                gather_artifact_urls(pkg_uuid, reg_info[VersionNumber(ver)].git_tree_sha1)
            catch ex
                @warn "Failed to gather artifact URLs for $pkg_name version $ver:" ex
                if ex isa Downloads.RequestError && ex.response.status == 404
                    # If we get a 404, skip all subsquent versions of this package, but keep going with other packages.
                    break
                else
                    # For all other errors, ensure we don't hammer with more than 5 retries
                    download_count += max(10, max_downloads÷5)
                    break
                end
            end
            download_count += 1
            ver_info["artifact_urls"] = artifact_urls
        end
        if download_count >= max_downloads
            @warn "Reached maximum download limit of $max_downloads, stopping early."
            break
        end
    end
    return meta
end

end
