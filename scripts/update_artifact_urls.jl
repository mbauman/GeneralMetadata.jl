using GeneralMetadata
using TOML: TOML
using Pkg: Pkg
using Artifacts: Artifacts
using Tar: Tar
using CodecZlib: GzipDecompressorStream
using Downloads: download
using DataStructures: SortedDict

function gather_artifact_urls(uuid, sha)
    url = "https://pkg.julialang.org/package/$(uuid)/$(sha)"
    mktemp() do _, iogz
        download(url, iogz)
        seekstart(iogz)
        artifact_toml = untar_file(x->x.path in Artifacts.artifact_names, GzipDecompressorStream(iogz))
        isnothing(artifact_toml) && return String[]

        artifacts = TOML.parse(artifact_toml)
        urls = Set{String}()
        for (_, artifact_info) in artifacts
            # Normalize to a vector of dicts, even if there's only one artifact
            for entry in (artifact_info isa AbstractDict ? [artifact_info] : artifact_info)
                for dl in entry["download"]
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

function main(; max_downloads=2000)
    download_count = 0
    artifact_urls_toml = joinpath(@__DIR__, "..", "artifact_urls.toml")
    out = TOML.parsefile(artifact_urls_toml)
    registry = only(filter(x->x.name == "General", Pkg.Registry.reachable_registries()))
    for (pkg_uuid, pkg_info) in registry.pkgs
        Pkg.Registry.init_package_info!(pkg_info)
        pkg_name = pkg_info.name
        pkg_urls = get(out, pkg_name, Dict{String,Any}())
        last_recorded_version = maximum(VersionNumber, keys(pkg_urls); init=VersionNumber("0-"))
        last_recorded_urls = get(pkg_urls, string(last_recorded_version), String[])
        for (version, ver_info) in SortedDict(pkg_info.info.version_info)
            if version <= last_recorded_version
                continue
            end
            @info "Package $pkg_name version $version"
            artifact_urls = try
                gather_artifact_urls(pkg_uuid, ver_info.git_tree_sha1)
            catch ex
                @warn "Failed to gather artifact URLs for $pkg_name version $version+: $ex" ex
                if ex isa Downloads.RequestError && ex.response.status == 404
                    # If we get a 404, skip all subsquent versions of this package, but keep going with other packages.
                    break
                else
                    # For all other errors, we stop entirely to avoid hitting rate limits or other issues
                    download_count = typemax(Int)
                    break
                end
            end
            download_count += 1
            if artifact_urls == last_recorded_urls
                pop!(pkg_urls, string(last_recorded_version), String[])
                pkg_urls[string(version)] = artifact_urls
            else
                pkg_urls[string(version)] = artifact_urls
            end
            last_recorded_version = version
            last_recorded_urls = artifact_urls
        end
        out[pkg_name] = pkg_urls
        if download_count >= max_downloads
            @warn "Reached maximum download limit of $max_downloads, stopping early."
            break
        end
    end

    open(artifact_urls_toml, "w") do f
        println(f, """
            # This file contains the URLs referenced by artifacts included in a particular version of each package.
            # The keys are package name and version, pointing to an array of URLs. To avoid many unnecessary entries,
            # any omitted versions are known to have the same URLs as the next-greater recorded version.
            """)
        TOML.print(f, out,
            inline_tables=IdSet{Dict{String,Any}}(urls for pkgtable in values(out) for urls in values(pkgtable) if length(values(urls)) <= 4),
            sorted = true, by = x->something(tryparse(VersionNumber, x), x))
    end
    return out
end


if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
