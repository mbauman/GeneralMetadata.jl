using TOML: TOML
using JSON: JSON
using DataStructures: DataStructures, OrderedDict
using Pkg: Pkg, Registry
using GeneralMetadata: GeneralMetadata

function main()
    allversions = GeneralMetadata.metadata()
    root = mkpath(joinpath(@__DIR__, "..", "webroot", "api"))
    for (pkg, versions) in allversions
        uuid = GeneralMetadata.uuid_from_name(pkg)
        pkgdir = mkpath(joinpath(root, pkg))
        versioninfo = OrderedDict{String,Any}()
        for (ver, info) in versions
            # Registration dates
            versioninfo[ver]["registered"] = info["registered"]
            if haskey(info, "yanked")
                versioninfo[ver]["yanked"] = info["yanked"]
            end
            # Artifact information
            if haskey(info, "artifact_urls")
                versioninfo[ver]["has_artifacts"] = isempty(info["artifact_urls"])
                if haskey(info, "artifact_metadata")
                    components = []
                    tracked_urls = Set{String}(info["artifact_urls"])
                    for m in info["artifact_metadata"]
                        all_tracked = true
                        for src in get(m, "sources", [])
                            if haskey(src, "upstream")
                                push!(components, src["upstream"])
                            else
                                all_tracked = false
                            end
                        end
                        all_tracked && setdiff!(tracked_urls, m["artifact_urls"])
                    end
                    versioninfo[ver]["artifacts_tracked"] = isempty(tracked_urls)
                    versioninfo[ver]["artifact_upstreams"] = components
                end
            end

        end
        versioninfo = sort(versioninfo, by=VersionNumber)
        JSON.json(joinpath(pkgdir, "versions.json"), versioninfo)
        JSON.json(joinpath(pkgdir, "info.json"), (; name=pkg, uuid=string(uuid)))
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
