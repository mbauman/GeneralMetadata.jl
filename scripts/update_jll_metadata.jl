using TOML: TOML
using HTTP: HTTP
using JSON: JSON
using Pkg: Pkg, Registry, PackageSpec
using Base64: base64decode
using GeneralMetadata: GeneralMetadata
using Random: shuffle!
using Dates: Dates, DateTime

# Copied from SecurityAdvisories just to make life a little easier, since this runs v1.7
function get_registry(reg=Registry.RegistrySpec(name="General", uuid = "23338594-aafe-5451-b93e-139f81909106"); depot=Pkg.depots1())
    name = joinpath(depot, "registries", reg.name)
    if !ispath(name) && !ispath(name * ".toml")
        Registry.add([reg]; depot)
    end
    if !ispath(name)
        name = name * ".toml"
    end
    ispath(name) || error("Registry $name not found")
    return Registry.RegistryInstance(name)
end
const GITHUB_API_BASE = "https://api.github.com"
function build_headers()
    headers = [
        "Accept" => "application/vnd.github+json",
        "User-Agent" => "JuliaRegistries-GeneralMetadata.jl-Fetcher/1.0"
    ]
    if haskey(ENV, "GITHUB_TOKEN")
        push!(headers, "Authorization" => "Bearer $(ENV["GITHUB_TOKEN"])")
    end
    return headers
end
function get_github_releases(owner, repo)
    response = HTTP.get(string(GITHUB_API_BASE, "/repos/", owner, "/", repo, "/releases"), build_headers())
    if response.status != 200
        error("Failed to fetch advisories: HTTP $(response.status)")
    end

    return JSON.parse(response.body)
end
function get_github_release(owner, repo, name)
    response = HTTP.get(string(GITHUB_API_BASE, "/repos/", owner, "/", repo, "/releases/tags/", name), build_headers())
    if response.status != 200
        error("Failed to fetch release for tag $name: HTTP $(response.status)")
    end

    return JSON.parse(response.body)
end
function commit_from_tagname(owner, repo, tag_name)
    response = HTTP.get(string(GITHUB_API_BASE, "/repos/", owner, "/", repo, "/git/ref/tags/", tag_name), build_headers())
    if response.status != 200
        error("Failed to fetch tag info for $tag_name: HTTP $(response.status)")
    end
    tagsinfo = JSON.parse(response.body)
    if haskey(tagsinfo, "object") && tagsinfo["object"]["type"] == "tag"
        # This is an annotated tag, so we need to dereference it to get the commit SHA
        lightweight_response = HTTP.get(string(GITHUB_API_BASE, "/repos/", owner, "/", repo, "/git/tags/", tagsinfo["object"]["sha"]), build_headers())
        if lightweight_response.status != 200
            error("Failed to fetch lightweight tag info for $tag_name: HTTP $(lightweight_response.status)")
        end
        tagsinfo = JSON.parse(lightweight_response.body)
    end
    # This is a lightweight tag, so the object is the commit
    @assert tagsinfo["object"]["type"] == "commit"
    return tagsinfo["object"]["sha"]
end

function tree_sha_from_tagname(owner, repo, tag_name)
    commit_sha = commit_from_tagname(owner, repo, tag_name)
    response = HTTP.get(string(GITHUB_API_BASE, "/repos/", owner, "/", repo, "/git/commits/", commit_sha), build_headers())
    if response.status != 200
        error("Failed to fetch commit info for $commit_sha: HTTP $(response.status)")
    end
    commitinfo = JSON.parse(response.body)
    return commitinfo["tree"]["sha"]
end

function get_readme(owner, repo, tree_sha)
    response = HTTP.get(string(GITHUB_API_BASE, "/repos/", owner, "/", repo, "/git/trees/", tree_sha), build_headers())
    if response.status != 200
        error("Failed to fetch advisories: HTTP $(response.status)")
    end

    tree = JSON.parse(response.body)
    readme = filter(x->x.path == "README.md", tree.tree)
    isempty(readme) && return nothing

    blob = JSON.parse(HTTP.get(readme[].url, build_headers()).body)
    blob.encoding == "base64" || return nothing
    return String(base64decode(blob.content))
end
commit_and_path_from_readme(::Nothing, jllname, jllversion) = nothing, nothing
function commit_and_path_from_readme(readme, jllname, jllversion)
    # This ensures the version is correct; Yggdrasil didn't always tag the right release
    startswith(readme, "# `$(jllname)_jll.jl` (v$jllversion)") || return nothing, nothing
    m = match(r"originating \[`build_tarballs\.jl`\]\(https://github\.com/JuliaPackaging/Yggdrasil/blob/([^/]+)/(.*\.jl)\)", readme)
    isnothing(m) && return nothing, nothing
    return (m.captures[1], joinpath(yggy, m.captures[2]))
end
const COMMIT_INFO = Dict{Tuple{String,String,String},Any}()
function find_commit_date_from_tree_sha(owner, repo, tree_sha)
    url = string(GITHUB_API_BASE, "/repos/", owner, "/", repo, "/commits?per_page=100")
    while true
        commits = HTTP.get(url, build_headers())
        for commit in JSON.parse(commits.body)
            info = get!(COMMIT_INFO, (owner,repo,commit.sha)) do
                JSON.parse(HTTP.get(string(GITHUB_API_BASE, "/repos/", owner, "/", repo, "/commits/", commit.sha), build_headers()).body)
            end
            if strip(info.commit.tree.sha) == tree_sha
                return info.commit.committer.date
            end
        end
        m = match(r"<([^>]+)>;\s*rel=\"next\"", get(Dict(commits.headers), "Link", ""))
        isnothing(m) && break
        url = m.captures[1]
    end

    error("could not find sha $tree_sha in the commit history of $owner/$repo")
end

function dict(pkg::PackageSpec)
    # effectively Base.show(io::IO, pkg::PackageSpec)
    f = []
    pkg.name !== nothing && push!(f, "name" => string(pkg.name))
    pkg.uuid !== nothing && push!(f, "uuid" => string(pkg.uuid))
    pkg.tree_hash !== nothing && push!(f, "tree_hash" => string(pkg.tree_hash))
    pkg.path !== nothing && push!(f, "path" => string(pkg.path))
    pkg.url !== nothing && push!(f, "url" => string(pkg.url))
    pkg.rev !== nothing && push!(f, "rev" => string(pkg.rev))
    pkg.subdir !== nothing && push!(f, "subdir" => string(pkg.subdir))
    pkg.pinned && push!(f, "pinned" => string(pkg.pinned))
    push!(f, "version" => string(pkg.version))
    if pkg.repo.source !== nothing
        push!(f, "repo/source" => string("\"", pkg.repo.source, "\""))
    end
    if pkg.repo.rev !== nothing
        push!(f, "repo/rev" => string(pkg.repo.rev))
    end
    if pkg.repo.subdir !== nothing
        push!(f, "repo/subdir" => string(pkg.repo.subdir))
    end
    Dict(f)
end

# Backported from Julia (some newer release than 1.7)
function chopsuffix(s::Union{String, SubString{String}},
                    suffix::Union{String, SubString{String}})
    if !isempty(suffix) && endswith(s, suffix)
        astart = ncodeunits(s) - ncodeunits(suffix) + 1
        @inbounds SubString(s, firstindex(s), prevind(s, astart))
    else
        SubString(s)
    end
end
function chopprefix(s::Union{String, SubString{String}},
                    prefix::Union{String, SubString{String}})
    if startswith(s, prefix)
        SubString(s, 1 + ncodeunits(prefix))
    else
        SubString(s)
    end
end

function github_release_artifacts(meta = GeneralMetadata.metadata())
    releases = Pair{Tuple{String,String,DateTime}, Tuple{String,String,String}}[]
    for (pkg, pkgentry) in meta
        for (ver, verinfo) in pkgentry
            haskey(verinfo, "artifact_urls") || continue
            matches = unique(Tuple(String.(m)) for m in match.(r"^https://github.com/([^/]+)/([^/]+)/releases/download/([^/]+)/", verinfo["artifact_urls"]) if m !== nothing)
            if isempty(matches) && any(contains("JuliaBinaryWrappers"), verinfo["artifact_urls"])
                @warn "$pkg@$ver has artifact URLs that look like they should be from GitHub releases but didn't match the expected pattern: $(verinfo["artifact_urls"])"
            end
            for m in matches
                push!(releases, ((pkg, ver, verinfo["registered"]) => m))
            end
        end
    end
    return releases
end

const yggy = mktempdir()
run(pipeline(`git clone https://github.com/JuliaPackaging/Yggdrasil.git $yggy`, stdout=Base.devnull))

jlls(reg = get_registry()) = filter(((k,v),)->endswith(v.name, "_jll"), reg.pkgs)

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
        push!(get!(meta_version_entry, "artifact_metadata", []), jllmeta)
    end
    return meta_version_entry
end

function metadata_for_jll_release(org, repo, tag)
    contains(tag, "-v") || error("unknown tag $tag for $org/$repo")
    jllname, jllversion = split(tag, "-v", limit=2)
    release = get_github_release(org, repo, tag)
    # Currently constrain to releases authored by jlbuild; TODO: relax this with BinaryBuilder2 support and log the author instead
    release["author"]["login"] == "jlbuild" || error("release $(release["html_url"]) is not by jlbuild, got $(release["author"]["login"])")
    # This might be wrong, but commit_and_path_from_readme checks to ensure versions match
    # In cases where it's wrong, _there does exist_ a good link to Yggdrasil in its README... somewhere.
    # But I don't know how to reliably get to it... so we fall back to the Yggdrasil timestamps
    tree_sha = tree_sha_from_tagname(org, repo, release["tag_name"])
    commit_from_readme, path_from_readme = commit_and_path_from_readme(get_readme(org, repo, tree_sha), jllname, jllversion)
    release_published_at = release.published_at
    return cd(yggy) do
        if !isnothing(commit_from_readme)
            commit = commit_from_readme
            method = "README link"
        else
            commit = strip(read(`git rev-list --first-parent -n 1 --before=$(release_published_at) master`, String))
            method = "timestamp"
        end
        run(pipeline(`git checkout $commit`, stdout=Base.devnull, stderr=Base.devnull))
        buildscript = @something path_from_readme joinpath(yggy, uppercase(jllname[1:1]), jllname, "build_tarballs.jl")
        if !isfile(buildscript)
            # First look for a potentially-deeper nested path, without worrying about case, then consider version numbers
            for searchpath in ("./$(jllname[1])/$jllname/build_tarballs.jl",
                                "*/$jllname/build_tarballs.jl",
                                "*/$jllname@$jllversion/build_tarballs.jl",
                                "*/$jllname@$(majorminorpatch(VersionNumber(jllversion)))/build_tarballs.jl",
                                "*/$jllname@$(majorminor(VersionNumber(jllversion)))/build_tarballs.jl",
                                "*/$jllname@$(major(VersionNumber(jllversion)))/build_tarballs.jl")
                pathmatches = split(readchomp(`find . -ipath $searchpath`), "\n", keepempty=false)
                if length(pathmatches) == 1
                    buildscript = joinpath(yggy, pathmatches[1])
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
                run(`julia +$julia_version --project=$proj $(basename(buildscript)) --meta-json=$path`)
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
            "buildscript" => "https://github.com/JuliaPackaging/Yggdrasil/tree/$(commit)$(chopprefix(buildscript,yggy))",
            "metadata_type" => "BinaryBuilder --meta-json",
            "metadata_source" => "retrospective (by $method)",
            "metadata_version" => bb_version,
            "metadata" => bb_meta,
        )
    end
end

function update_jll_metadata(; force = false, timelimit=Dates.Minute(90))
    start_time = Dates.now()
    meta = GeneralMetadata.metadata()
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
    GeneralMetadata.save_metadata!(meta)
    return meta
end

if abspath(PROGRAM_FILE) == @__FILE__
    update_jll_metadata()
end
