using TOML: TOML
using HTTP: HTTP
using JSON: JSON
using Pkg: Pkg, Registry, PackageSpec
using Base64: base64decode

@eval BinaryBuilderBase begin
    # Disable errors when github archives are used
    check_github_archive(url::String) = nothing
end

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
function get_releases(owner, repo)
    response = HTTP.get(string(GITHUB_API_BASE, "/repos/", owner, "/", repo, "/releases"), build_headers())
    if response.status != 200
        error("Failed to fetch advisories: HTTP $(response.status)")
    end

    return JSON3.read(response.body)
end
function get_readme(owner, repo, tree_sha)
    response = HTTP.get(string(GITHUB_API_BASE, "/repos/", owner, "/", repo, "/git/trees/", tree_sha), build_headers())
    if response.status != 200
        error("Failed to fetch advisories: HTTP $(response.status)")
    end

    tree = JSON3.read(response.body)
    readme = filter(x->x.path == "README.md", tree.tree)
    isempty(readme) && return nothing

    blob = JSON3.read(HTTP.get(readme[].url, build_headers()).body)
    blob.encoding == "base64" || return nothing
    return String(base64decode(blob.content))
end
commit_and_path_from_readme(::Nothing) = nothing, nothing
function commit_and_path_from_readme(readme)
    m = match(r"originating \[`build_tarballs\.jl`\]\(https://github\.com/JuliaPackaging/Yggdrasil/blob/([^/]+)/(.*\.jl)\)", readme)
    isnothing(m) && return nothing, nothing
    return (m.captures[1], joinpath(yggy, m.captures[2]))
end
const COMMIT_INFO = Dict{Tuple{String,String,String},Any}()
function find_commit_date_from_tree_sha(owner, repo, tree_sha)
    url = string(GITHUB_API_BASE, "/repos/", owner, "/", repo, "/commits?per_page=100")
    while true
        commits = HTTP.get(url, build_headers())
        for commit in JSON3.read(commits.body)
            info = get!(COMMIT_INFO, (owner,repo,commit.sha)) do
                JSON3.read(HTTP.get(string(GITHUB_API_BASE, "/repos/", owner, "/", repo, "/commits/", commit.sha), build_headers()).body)
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

const yggy = mktempdir()
run(pipeline(`git clone https://github.com/JuliaPackaging/Yggdrasil.git $yggy`, stdout=Base.devnull))

jlls(reg = get_registry()) = filter(((k,v),)->endswith(v.name, "_jll"), reg.pkgs)

majorminorpatch(v::VersionNumber) = string(v.major, ".", v.minor, ".", v.patch)
majorminor(v::VersionNumber) = string(v.major, ".", v.minor)
major(v::VersionNumber) = string(v.major)

metadata_for_jll(jll::String; reg = get_registry()) = metadata_for_jll(only(filter(((k,v),)->v.name==jll, reg.pkgs))[2])
function metadata_for_jll(jll::Registry.PkgEntry, versions = Registry.registry_info(jll).version_info)
    jllinfo = Registry.registry_info(jll)
    jllrepo = jllinfo.repo
    jllname = chopsuffix(jll.name, "_jll")
    m = match(r"github\.com[:/]([^/]+)/(.+?)(?:.git)?$", jllinfo.repo)
    isnothing(m) && error("unknown repo $(jllinfo.repo)")
    org, repo = m.captures
    github_releases = get_releases(org, repo)

    metadata = Dict{String,Any}()
    for (version, versioninfo) in versions
        commit_from_readme, path_from_readme = commit_and_path_from_readme(get_readme(org, repo, string(versioninfo.git_tree_sha1)))
        releasetags = filter(r->endswith(r.tag_name, string(version)), github_releases)
        release_published_at = if length(releasetags) == 1
            only(releasetags).published_at
        elseif isempty(releasetags)
            find_commit_date_from_tree_sha(org, repo, string(versioninfo.git_tree_sha1))
        else
            nothing
        end
        commit, buildscript = "", ""
        metadata[string(version)] = cd(yggy) do
            # First look to the
            commit = @something commit_from_readme strip(read(`git rev-list -n 1 --before=$(release_published_at) master`, String))
            run(pipeline(`git checkout $commit`, stdout=Base.devnull, stderr=Base.devnull))
            buildscript = @something path_from_readme joinpath(yggy, uppercase(jllname[1:1]), jllname, "build_tarballs.jl")
            if !isfile(buildscript)
                # First look for a potentially-deeper nested path, without worrying about case, then consider version numbers
                for searchpath in ("./$(jllname[1])/$jllname/build_tarballs.jl",
                                   "*/$jllname/build_tarballs.jl",
                                   "*/$jllname@$version/build_tarballs.jl",
                                   "*/$jllname@$(majorminorpatch(version))/build_tarballs.jl",
                                   "*/$jllname@$(majorminor(version))/build_tarballs.jl",
                                   "*/$jllname@$(major(version))/build_tarballs.jl")
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
            @info "$jllname@$version: $buildscript @ $commit"
            # Now find the version of BinaryBuilder/Julia to run
            if isfile(".ci/Manifest.toml")
                manifest = TOML.parsefile(".ci/Manifest.toml")
                proj = ".ci"
                if haskey(manifest, "julia") && haskey(manifest["julia"], "version")
                    julia_version = majorminor(VersionNumber(manifest["julia"]["version"])) # ignore patch versions for these
                else
                    # Try to find it from .ci/azp_agent/install_agents.sh (which should be present alongside the manifest)
                    @assert isfile(".ci/azp_agent/install_agents.sh")
                    # Extract Julia version from the install_agents.sh script; this has varied over time (and note there's sometimes commented ones, too)
                    #     JULIA_URL="https://julialang-s3.julialang.org/bin/linux/x64/1.6/julia-1.6.0-linux-x86_64.tar.gz"
                    #     JULIA_URL="https://julialang-s3.julialang.org/bin/linux/x64/1.6/julia-1.6.0-linux-x86_64.tar.gz"
                    #     JULIA_URL="https://julialang-s3.julialang.org/bin/linux/x64/1.6/julia-1.6.0-rc1-linux-x86_64.tar.gz"
                    #     JULIA_URL="https://julialangnightlies-s3.julialang.org/bin/linux/x64/julia-latest-linux64.tar.gz"
                    #     JULIA_URL="https://julialang-s3.julialang.org/bin/linux/x64/1.4/julia-1.4.1-linux-x86_64.tar.gz"
                    #     JULIA_URL="https://julialang-s3.julialang.org/bin/linux/x64/1.4/julia-1.4.0-linux-x86_64.tar.gz"
                    #     JULIA_URL="julialangnightlies-s3.julialang.org/assert_pretesting/linux/x64/1.4/julia-3a22e2fdcf-linux64.tar.gz"
                    julia_match = match(r"^\s*JULIA_URL=\".*?/julia-(.*)-linux", readchomp(".ci/azp_agent/install_agents.sh"))
                    julia_version = if !isnothing(julia_match)
                        if julia_match[1] == "latest" || julia_match[1] == "1.6.0-rc1"
                            # lol. https://github.com/JuliaPackaging/Yggdrasil/blob/e0c5ee45cb0b6aea8006ad25f388ad116da22a01/.ci/azp_agent/install_agents.sh#L54-L57
                            "1.6.0"
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
                end
            else
                # Prior to https://github.com/JuliaPackaging/Yggdrasil/commit/102b6ec47081ccb932e59bd604b02959ffbbdc16, there was no manifest
                # and Julia lived inside a pre-built docker container... from somewhere...
                proj = joinpath(@__DIR__, "yggdrasil_env_pre_2020_02_07") # This has BB v0.2.2 (Jan 2020); there are older buildscripts that predate this, but start here
                julia_version = "1.3.0"
            end
            # Now ask the build script for its meta-json
            bb_meta = mktemp() do (path, io)
                run(`julia +$julia_version --project=$proj $buildscript --meta-json=$path`, stderr=Base.devnull)
                JSON.parse(io)
            end
            return Dict{String,Any}(
                "system" => "Yggdrasil",
                "buildscript" => "https://github.com/JuliaPackaging/Yggdrasil/tree/$commit/$buildscript",
                "version" => TOML.parsefile("scripts/jll_metadata/Manifest.toml")["deps"]["BinaryBuilder"][]["version"],
                "metadata" => bb_meta,
            )
        end
    end
    return metadata
end

function update_metadata(; force = false, max_pkgs=10)
    artifact_metadata = GeneralMetadata.artifact_metadata()
    pkg_count = 0
    for (uuid, pkgentry) in jlls()
        if !haskey(artifact_metadata, pkgentry.name) || force
            @info "populating $(pkgentry.name) from scratch"
            try
                artifact_metadata[pkgentry.name] = metadata_for_jll(pkgentry)
            catch ex
                @error "error getting metadata for $(pkgentry.name)" ex
                ex isa HTTP.Exceptions.StatusError && ex.status == 403 && break
            end
            pkg_count += 1
            pkg_count >= max_pkgs && break
        else
            error("TODO: need to refactor version subset logic for new sharded structure...")
            # toml_versions = keys(artifact_metadata[pkgentry.name])
            # version_info = Registry.registry_info(pkgentry).version_info
            # reg_versions = string.(keys(version_info))
            # missing_versions = setdiff(reg_versions, toml_versions)
            # isempty(missing_versions) && continue
            # @info "updating $(pkgentry.name) for $missing_versions"
            # try
            #     updates = metadata_for_jll(pkgentry, filter(((k,v),)->string(k) in missing_versions, version_info))
            #     merge!(toml[pkgentry.name], updates)
            # catch ex
            #     @error "error getting metadata for $(pkgentry.name) at some versions" ex missing_versions
            #     ex isa HTTP.Exceptions.StatusError && ex.status == 403 && break
            # end
        end
    end
    GeneralMetadata.save_artifact_metadata!(artifact_metadata)
    return artifact_metadata
end

if abspath(PROGRAM_FILE) == @__FILE__
    update_metadata()
end
