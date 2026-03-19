module GeneralMetadata

import TOML, JSON, HTTP, CSV, Pkg, Downloads, Tar, Artifacts
using DataFrames: DataFrames, DataFrame
using Dates: Dates, DateTime, Date, Day, Millisecond
using CodecZlib: GzipDecompressorStream
using DataStructures: DataStructures, DefaultDict

include("GitHub.jl")

# Abstract away some Pkg internals into one common place:
function registered_package_names()
    registry = general_registry()
    return Set(x.name for x in values(registry.pkgs))
end

_init_package_info!(registry, pkgentry) = if VERSION < v"1.13-"
        Pkg.Registry.init_package_info!(pkgentry)
    else
        Pkg.Registry.init_package_info!(registry, pkgentry)
    end

registered_package_versions(pkgname; registry=general_registry()) = registered_package_versions(uuid_from_name(pkgname); registry)
function registered_package_versions(pkguuid::Base.UUID; registry = general_registry())
    pkgentry = registry[pkguuid]
    _init_package_info!(registry, pkgentry)
    return pkgentry.info.version_info
end

registered_package_repo(pkgname; registry=general_registry()) = registered_package_repo(uuid_from_name(pkgname); registry)
function registered_package_repo(pkguuid::Base.UUID; registry = general_registry())
    pkgentry = registry[pkguuid]
    _init_package_info!(registry, pkgentry)
    return pkgentry.info.repo
end

registered_package_repo_subdir(pkgname; registry=general_registry()) = registered_package_repo_subdir(uuid_from_name(pkgname); registry)
function registered_package_repo_subdir(pkguuid::Base.UUID; registry = general_registry())
    pkgentry = registry[pkguuid]
    _init_package_info!(registry, pkgentry)
    return pkgentry.info.subdir
end

function uuid_from_name(pkg_name)
    registry = general_registry()
    return only(Pkg.Registry.uuids_from_name(registry, pkg_name))
end

# The main entry point:
function metadata()
    meta = Dict{String,Any}()
    for (root, _, files) in walkdir(joinpath(@__DIR__, "..", "metadata")), file in files
            path = joinpath(root, file)
            if endswith(path, ".toml")
            pkg = splitext(basename(path))[1]
            meta[pkg] = TOML.parsefile(path)
        end
    end
    return meta
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
    JSON.parse(HTTP.get("https://juliahub.com/docs/General/$packagename/stable/pkg.json").body).license
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
general_registry() = Pkg.Registry.RegistryInstance(general_repo())

const YGGDRASIL = Ref{String}()
function yggdrasil_repo()
    isassigned(YGGDRASIL) && return YGGDRASIL[]
    dir = mktempdir()
    run(`git clone https://github.com/JuliaPackaging/Yggdrasil $dir`)
    return YGGDRASIL[] = dir
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

function package_repository(uuid)
    registry = general_registry()
    return registry[uuid].info.repo
end

function gather_artifact_urls(uuid, sha)
    repo_url = registered_package_repo(uuid)
    subdir = registered_package_repo_subdir(uuid)
    artifact_paths = isnothing(subdir) ? Artifacts.artifact_names : joinpath.(subdir, Artifacts.artifact_names)
    m = match(r"^https?://github\.com/([^/]+)/([^/]+?)(?:.git)?$", repo_url)
    artifact_toml = try
        org, repo = m.captures
        GitHub.get_file(org, repo, sha, in(artifact_paths))
    catch _
        # Fallback to getting it from the storage server
        try
            mktemp() do _, iogz
                Downloads.download("https://pkg.julialang.org/package/$(uuid)/$(sha)", iogz)
                seekstart(iogz)
                untar_file(x->x.path in Artifacts.artifact_names, GzipDecompressorStream(iogz))
            end
        catch ex
            # Fallback fallback to cloning the entire repo and checking out the commit
            startswith(repo_url, "https://github.com") && rethrow(ex) # Trust that we've already tried this GitHub repo via API
            mktempdir() do dir
                run(`git clone $repo_url $dir`)
                subdir = @something registered_package_repo_subdir(uuid) "."
                cd(dir) do
                    # fetch the files directly from its tree sha
                    toml_path = filter(in(artifact_paths), split(readchomp(`git ls-tree -r --name-only $sha $subdir`), "\n"))
                    isempty(toml_path) ? nothing : readchomp(`git cat-file blob $sha:$(only(toml_path))`)
                end
            end
        end
    end
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

# JLL Metadata
commit_and_path_from_readme(::Nothing, jllname, jllversion) = nothing, nothing
function commit_and_path_from_readme(readme, jllname, jllversion)
    # This ensures the version is correct; Yggdrasil didn't always tag the right release
    startswith(readme, "# `$(jllname)_jll.jl` (v$jllversion)") || return nothing, nothing
    m = match(r"originating \[`build_tarballs\.jl`\]\(https://github\.com/JuliaPackaging/Yggdrasil/blob/([^/]+)/(.*\.jl)\)", readme)
    isnothing(m) && return nothing, nothing
    return (m.captures[1], m.captures[2])
end

majorminorpatch(v::VersionNumber) = string(v.major, ".", v.minor, ".", v.patch)
majorminor(v::VersionNumber) = string(v.major, ".", v.minor)
major(v::VersionNumber) = string(v.major)

drop_nothings(d::AbstractDict) = Dict(k => drop_nothings(v) for (k, v) in d if v !== nothing)
drop_nothings(A::AbstractArray) = [drop_nothings(v) for v in A if v !== nothing]
drop_nothings(v) = v

# From https://github.com/JuliaPackaging/BinaryBuilder.jl/blob/58b87b84742baad7f50a4866aff0c7f2a6a290d9/src/Declarative.jl#L1-L25
# merge multiple JSON objects garnered via `--meta-json`
function merge_json_objects(objs::Vector)
    merged = Dict()
    for obj in objs
        for k in keys(obj)
            if !haskey(merged, k)
                merged[k] = obj[k]
            else
                if merged[k] != obj[k]
                    if !isa(merged[k], Array)
                        merged[k] = [merged[k]]
                    end

                    if isa(obj[k], Array)
                        append!(merged[k], obj[k])
                    else
                        push!(merged[k], obj[k])
                    end
                    merged[k] = unique(merged[k])
                end
            end
        end
    end
    return merged
end

function separate_reconstructed_artifact_metadata!(jllmeta)
    jllmeta["metadata"] isa String && return jllmeta # already a string pointing to some location
    # Extract the metadata blob itself and place it into the reconstructed_artifact_metadata directory
    repo, commit, path = match(r"^https://github.com/(?:[^/]+)/([^/]+)/tree/([^/]+)/(.*)$", jllmeta["buildscript"])
    jllmeta_metapath = joinpath("reconstructed_artifact_metadata", repo, lowercase(path), commit * ".toml")
    jllmeta_file = joinpath(@__DIR__, "..", jllmeta_metapath)
    if isfile(jllmeta_file) &&
        replace(sprint((io,x)->TOML.print(io, x, sorted=true), jllmeta["metadata"]), r"\"/tmp/jl_[^/]+/" => "\"") !=
        replace(sprint((io,x)->TOML.print(io, x, sorted=true), TOML.parsefile(jllmeta_file)), r"\"/tmp/jl_[^/]+/" => "\"")
        # temp foldernames sometimes get serialized to metadata; ignore those differences
        error("reconstructing buildscript $(jllmeta["buildscript"]) generated two different metadata blobs")
    end
    mkpath(dirname(jllmeta_file))
    open(jllmeta_file, "w") do f
        TOML.print(f, jllmeta["metadata"], sorted=true)
    end
    jllmeta["metadata"] = jllmeta_metapath
    return jllmeta
end

function add_jll_artifact_metadata!(meta_version_entry)
    urls = meta_version_entry["artifact_urls"]
    releases = Dict{Tuple{String,String,String}, Vector{String}}()
    for url in urls
        m = match(r"^https://github.com/([^/]+)/([^/]+)/releases/download/([^/]+)/", url)
        isnothing(m) && continue
        push!(get!(releases, Tuple(m), String[]), url)
    end
    for ((org, repo, tag), urls) in releases
        org == "JuliaBinaryWrappers" || continue
        jllmeta = metadata_for_jll_release(org, repo, tag)
        jllmeta["artifact_urls"] = urls
        separate_reconstructed_artifact_metadata!(jllmeta)
        push!(get!(meta_version_entry, "artifact_metadata", []), jllmeta)
    end
    return meta_version_entry
end

function metadata_for_jll_release(org, repo, tag)
    contains(tag, "-v") || error("unknown tag $tag for $org/$repo")
    jllname, jllversion = split(tag, "-v", limit=2)
    release = GitHub.get_release(org, repo, tag)
    # Currently constrain to releases authored by jlbuild; TODO: relax this with BinaryBuilder2 support and log the author instead
    release["author"]["login"] == "jlbuild" || error("release $(release["html_url"]) is not by jlbuild, got $(release["author"]["login"])")
    # This might be wrong, but commit_and_path_from_readme checks to ensure versions match
    # In cases where it's wrong, _there does exist_ a good link to Yggdrasil in its README... somewhere.
    # But I don't know how to reliably get to it... so we fall back to the Yggdrasil timestamps
    tree_sha = GitHub.tree_sha_from_tagname(org, repo, release["tag_name"])
    commit_from_readme, path_from_readme = commit_and_path_from_readme(GitHub.get_readme(org, repo, tree_sha), jllname, jllversion)
    release_published_at = release.published_at
    return cd(yggdrasil_repo()) do
        if !isnothing(commit_from_readme)
            commit = commit_from_readme
            method = "README link"
        else
            commit = strip(read(`git rev-list --first-parent -n 1 --before=$(release_published_at) master`, String))
            method = "timestamp"
        end
        try
            run(pipeline(`git checkout $commit`, stdout=Base.devnull, stderr=Base.devnull))
        catch _
            # Sometimes a README link points to a commit that's on a fork or somesuch; sometimes origin knows this
            run(pipeline(`git fetch origin $commit`, stdout=Base.devnull, stderr=Base.devnull))
            run(pipeline(`git checkout $commit`, stdout=Base.devnull, stderr=Base.devnull))
        end
        buildscript = @something path_from_readme joinpath(uppercase(jllname[1:1]), jllname, "build_tarballs.jl")
        if !isfile(buildscript)
            # First look for a potentially-deeper nested path, without worrying about case, then consider version numbers
            for searchpath in ("./$(jllname[1])/$jllname/build_tarballs.jl",
                                "*/$jllname/build_tarballs.jl",
                                "*/$jllname@$jllversion/build_tarballs.jl",
                                "*/$jllname@$(majorminorpatch(VersionNumber(jllversion)))/build_tarballs.jl",
                                "*/$jllname@$(majorminor(VersionNumber(jllversion)))/build_tarballs.jl",
                                "*/$jllname@$(major(VersionNumber(jllversion)))/build_tarballs.jl",
                                "*/$jllname@v$jllversion/build_tarballs.jl",
                                "*/$jllname@v$(majorminorpatch(VersionNumber(jllversion)))/build_tarballs.jl",
                                "*/$jllname@v$(majorminor(VersionNumber(jllversion)))/build_tarballs.jl",
                                "*/$jllname@v$(major(VersionNumber(jllversion)))/build_tarballs.jl")
                pathmatches = split(readchomp(`find . -ipath $searchpath`), "\n", keepempty=false)
                if length(pathmatches) == 1
                    buildscript = pathmatches[1]
                    break
                elseif length(pathmatches) > 1
                    error("found multiple build scripts for $jllname at Ygg $commit, got $pathmatches")
                end
            end
        end
        !isfile(buildscript) && error("could not find build script for $jllname at Ygg $commit")
        @info "$jllname@$jllversion: $buildscript @ $commit"
        # Now find the version of BinaryBuilder/Julia to run
        if isfile(".ci/Manifest.toml")
            manifest = TOML.parsefile(".ci/Manifest.toml")
            proj = abspath(".ci")
            if haskey(manifest, "julia_version")
                julia_version = majorminor(VersionNumber(manifest["julia_version"])) # ignore patch versions for these
            elseif isfile(".ci/azp_agent/install_agents.sh")
                # Try to find it from .ci/azp_agent/install_agents.sh (which should be present alongside the manifest)
                # Extract Julia version from the install_agents.sh script; this has varied over time (and note there's sometimes commented ones, too)
                #     JULIA_URL="https://julialang-s3.julialang.org/bin/linux/x64/1.6/julia-1.6.0-linux-x86_64.tar.gz"
                #     JULIA_URL="https://julialang-s3.julialang.org/bin/linux/x64/1.6/julia-1.6.0-linux-x86_64.tar.gz"
                #     JULIA_URL="https://julialang-s3.julialang.org/bin/linux/x64/1.6/julia-1.6.0-rc1-linux-x86_64.tar.gz"
                #     JULIA_URL="https://julialangnightlies-s3.julialang.org/bin/linux/x64/julia-latest-linux64.tar.gz"
                #     JULIA_URL="https://julialang-s3.julialang.org/bin/linux/x64/1.4/julia-1.4.1-linux-x86_64.tar.gz"
                #     JULIA_URL="https://julialang-s3.julialang.org/bin/linux/x64/1.4/julia-1.4.0-linux-x86_64.tar.gz"
                #     JULIA_URL="julialangnightlies-s3.julialang.org/assert_pretesting/linux/x64/1.4/julia-3a22e2fdcf-linux64.tar.gz"
                julia_match = match(r"^\s*JULIA_URL=\".*?/julia-(.*)-linux"m, readchomp(".ci/azp_agent/install_agents.sh"))
                julia_version = if !isnothing(julia_match)
                    if julia_match[1] == "1.6.0-rc1"
                        "1.6.0"
                    elseif julia_match[1] == "latest"
                        # ugh. https://github.com/JuliaPackaging/Yggdrasil/blob/e0c5ee45cb0b6aea8006ad25f388ad116da22a01/.ci/azp_agent/install_agents.sh#L54-L57
                        # We have to guess based on the behaviors here; we don't have easy access to every nightly. Fortunately this only
                        # happened during the 1.6-DEV period, but there are periods where neither release 1.6 nor 1.5 work
                        if DateTime(chopsuffix(release_published_at, "Z")) > DateTime(2021, 2, 18, 23, 18, 14)
                            # 1.6.0 begins working after https://github.com/JuliaPackaging/Yggdrasil/pull/2593 (ARGS not defined error)
                            "1.6.0"
                        else
                            # 1.6.0-beta1 still had the old scoping behaviors that worked prior to that
                            "1.6.0-beta1"
                        end
                    elseif julia_match[1] == "3a22e2fdcf"
                        # This was https://github.com/JuliaLang/julia/commit/3a22e2fdcf, a v1.4-rc2 pre-release
                        "1.4.0"
                    else
                        julia_match[1]
                    end
                else
                    # Prior to https://github.com/JuliaPackaging/Yggdrasil/commit/5ce813311a8066095115635e05e8805efccfd873, this was in run_agent.sh (or not included at all)
                    "1.3.0"
                end
            else
                julia_version = "1.3.0"
            end
        else
            # Prior to https://github.com/JuliaPackaging/Yggdrasil/commit/102b6ec47081ccb932e59bd604b02959ffbbdc16, there was no manifest
            # and Julia lived inside a pre-built docker container... from somewhere...
            proj = joinpath(@__DIR__, "yggdrasil_env_pre_2020_02_07") # This has BB v0.2.2 (Jan 2020); there are older buildscripts that predate this, but start here
            julia_version = "1.3.0"
        end
        # Now ask the build script for its meta-json
        bb_meta = mktemp() do path, io
            @info "julia +$julia_version --project=$proj -e 'using Pkg; Pkg.instantiate()'"
            buf = IOBuffer()
            run(pipeline(`julia +$julia_version --project=$proj -e 'using Pkg; Pkg.instantiate()'`, stdout=buf, stderr=buf))
            output = String(take!(buf))
            if contains(output, "Error: ")
                @warn "got error during Pkg.instantiate() for $proj at $commit, output was:\n\n$output"
            end
            @info "julia +$julia_version --project=$proj $buildscript --meta-json=...'"
            cd(dirname(buildscript)) do
                run(addenv(`julia +$julia_version --project=$proj $(basename(buildscript)) --meta-json=$path`, "YGGDRASIL" => "true", "BUILD_BUILDNUMBER" => rsplit(jllversion, "+", limit=2)[end]))
            end
            drop_nothings(merge_json_objects(JSON.parse(io, jsonlines=true)))
        end
        bb_version = begin
            manifest = TOML.parsefile("$proj/Manifest.toml")
            haskey(manifest, "deps") ? manifest["deps"]["BinaryBuilder"][]["version"] : manifest["BinaryBuilder"][]["version"]
        end
        if bb_meta["name"] != jllname || majorminorpatch(VersionNumber(bb_meta["version"])) != majorminorpatch(VersionNumber(jllversion))
            # Some old buildscripts were committed _after_ the release publication, which means we got the wrong version of the buildscript.
            error("metadata mismatch: buildscript defines version=$(bb_meta["name"])@$(bb_meta["version"]), tag is $jllname@$jllversion")
        end
        return Dict{String,Any}(
            "buildscript" => "https://github.com/JuliaPackaging/Yggdrasil/tree/$(commit)/$(chopprefix(normpath(buildscript), "/"))",
            "metadata_type" => "BinaryBuilder --meta-json",
            "metadata_source" => "retrospective (by $method)",
            "metadata_version" => bb_version,
            "metadata" => bb_meta,
        )
    end
end

function update_jll_metadata!(meta; force = false, timelimit=Dates.Minute(90))
    start_time = Dates.now()
    entries = []
    for (pkg, pkgentry) in meta
        for (ver, verinfo) in pkgentry
            haskey(verinfo, "artifact_urls") && push!(entries, verinfo)
        end
    end
    sort!(entries, by=x->x["registered"], rev=true)
    failures = []
    for entry in entries
        if !haskey(entry, "artifact_urls") || isempty(entry["artifact_urls"])
            continue
        end
        if haskey(entry, "artifact_metadata") && !force
            continue
        end
        if DateTime(2020, 9, 9) < entry["registered"] < DateTime(2020, 10, 19)
            # Skip versions registered during the dark ages when Yggdrasil was pulling some -latest that doesn't work with v1.5 or v1.6-beta1
            # TODO: find a good version here!
            continue
        end
        (Dates.now() - start_time) > timelimit && ( @info "timelimit of $timelimit reached, stopping here"; break)
        try
            add_jll_artifact_metadata!(entry)
        catch ex
            @error "error getting metadata for $(entry["artifact_urls"][1:begin])..." ex
            push!(failures, "$(entry["artifact_urls"][1:begin])... => $ex")
            ex isa HTTP.Exceptions.StatusError && ex.status == 403 && (start_time = Dates.now() - timelimit; break)
        end
    end
    if length(failures) > 0
        @warn "encountered $(length(failures)) failures:"
        println(join(replace.(failures, ('\n'=>" ",)), "\n"))
    end
    return meta
end

function extract_jll_sources!(meta)
    for (pkg, pkgentry) in meta
        for (ver, verinfo) in pkgentry
            for artifactmeta in get(verinfo, "artifact_metadata", [])
                haskey(artifactmeta, "metadata") || continue
                haskey(artifactmeta, "sources") && continue
                meta_contents = if contains(artifactmeta["metadata"], "://")
                    String(HTTP.get(artifactmeta["metadata"]).body)
                else
                    read(joinpath(@__DIR__, "..", artifactmeta["metadata"]), String)
                end
                srcs = parse_artifact_metadata_sources(meta_contents, artifactmeta)
                if !isnothing(srcs)
                   artifactmeta["sources"] = srcs
                end
            end
        end
    end
    return meta
end

function parse_artifact_metadata_sources(contents, artifactmeta)
    type = get(artifactmeta, "metadata_type", missing)
    if type == "BinaryBuilder --meta-json"
        buildscript = get(artifactmeta, "buildscript", missing)
        meta = TOML.parse(contents)
        # The sources field has changed a number of times, but it's always a vector
        sources = []
        meta_srcs = get(meta, "sources", [])
        @assert isa(meta_srcs, Vector) "expected \"sources\" to be a Vector, got $(typeof(meta_srcs))"
        for src in meta_srcs
            # There are three flavors here:
            # * Strings are paths to bundled directores
            # * Dicts of url => hash pairs (old versions)
            # * Dicts with a "type" field (new versions)
            #    - Possible types are "directory", "file", "archive", and "git"
            @assert src isa Union{AbstractString, AbstractDict} "expected sources to be either strings or dicts, got $(typeof(src))"
            if src isa AbstractString || (haskey(src, "type") && src["type"] == "directory")
                dir = src isa AbstractString ? src : src["path"]
                # This is a path to a bundled directory, resolve this to an Yggdrasil URL
                # Sometimes these directories included a /tmp/jl_xxx prefix but still used a real Yggy path
                dir = chopprefix(dir, r"^/tmp/jl_[^/]+") # intentially preserve leading / in this case
                prefix, commit, path = match(r"^(.*)(/[a-f0-9]{40}/)(.*)$", buildscript) # because we resolve it relative to the buildscript, we need to preserve the path after the commit
                yggy_path = dirname(path)
                url = string(prefix, commit, normpath(joinpath(yggy_path, dir)))
                r = HTTP.get(url, status_exception=false)
                r.status == 200 || error("failed to resolve bundled directory $src to $url")
                push!(sources, Dict("type"=>"directory", "url" => url))
            elseif (haskey(src, "type") && src["type"] in ("git", "file", "archive"))
                 push!(sources, Dict("type" => src["type"], "url" => src["url"], "hash" => src["hash"]))
            elseif haskey(src, "type")
                error("unknown source with fields $(keys(src)) and type $(src["type"])")
            else
                for (url, hash) in src
                    @assert occursin(r"^[a-f0-9]{40}$", hash) || occursin(r"^[a-f0-9]{64}$", hash)
                    push!(sources, Dict("url" => url, "hash" => hash))
                end
            end
        end
        # We also want to include build dependencies as sources, since those are often incorporated into the end result
        # and are not otherwise dependencies that would be tracked separately
        meta_deps = get(meta, "dependencies", [])
        @assert meta_deps isa Vector "expected \"dependencies\" to be a Vector, got $(typeof(meta_deps))"
        for dep in meta_deps
            # Old versions used some String dependencies, but those are not build-only dependencies
            if dep isa AbstractDict && haskey(dep, "type") && dep["type"] == "builddependency"
                push!(sources, Dict("type" => "builddependency", "package" => dep["name"]))
                # TODO: need to resolve the version...
            end
        end
        return unique(sources)
    else
        @warn "unknown metadata type $type with version $version, cannot parse sources"
        return nothing
    end
end

end
