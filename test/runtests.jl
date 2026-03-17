using GeneralMetadata
using Test
using Pkg: Pkg, Registry
using Dates: Dates, DateTime

@testset "Package coverage" begin
    cd(GeneralMetadata.general_repo()) do
        # Roll the registry back to the commit at the time of the last recorded update
        meta = GeneralMetadata.metadata()
        timestamp = GeneralMetadata.last_update(meta) + Dates.Millisecond(500) # --before is exclusive
        last_commit = split(readchomp(`git rev-list --first-parent --before=$(timestamp)Z master`), "\n")[1]
        run(`git checkout --quiet --force $last_commit`)
        reg = Pkg.Registry.RegistryInstance(GeneralMetadata.general_repo())
        last_update = GeneralMetadata.last_update(meta)

        # Ensure all registry packages are present in the metadata, and that all versions present in the metadata are present in the registry
        all_registered_names = Set(values(reg.pkgs) .|> x->x.name)
        in_meta_but_not_registered = Pair{String,String}[]
        for (pkg, pkginfo) in meta
            @test pkg in all_registered_names
            reg_info = GeneralMetadata.registered_package_versions(pkg; registry=reg)
            for (ver, verinfo) in pkginfo
                if !haskey(reg_info, VersionNumber(ver))
                    push!(in_meta_but_not_registered, (pkg=>ver))
                end
            end
        end
        @test isempty(in_meta_but_not_registered)

        # And vice-versa: all registry metadata packages are present in the registry...
        in_registry_but_not_meta = Pair{String,String}[]
        for (pkguuid, pkginfo) in reg.pkgs
            pkg_name = pkginfo.name
            meta_info = get(meta, pkg_name, Dict{String,Any}())
            reg_info = GeneralMetadata.registered_package_versions(pkguuid; registry=reg)
            for (ver, verinfo) in reg_info
                if !haskey(meta_info, string(ver))
                    push!(in_registry_but_not_meta, (pkg_name=>string(ver)))
                end
            end
         end
         @test isempty(in_registry_but_not_meta)
     end
end

@testset "package TOML schema" begin
    meta = GeneralMetadata.metadata()
    for (pkg, pkginfo) in meta
        @test !isempty(pkginfo)
        for (ver, verinfo) in pkginfo
            # All packages must be registered
            @test haskey(verinfo, "registered")
            @test verinfo["registered"] isa DateTime
            # But yanked is optional
            if haskey(verinfo, "yanked")
                @test verinfo["yanked"] isa DateTime
            end
            # Some packages might be missing artifact URL info, unfortunately
            if haskey(verinfo, "artifact_urls")
                @test verinfo["artifact_urls"] isa Vector
                @test all(x->isa(x, String), verinfo["artifact_urls"])
            end
            # The metadata is either a key to describe all URLs or a mapping for each artifact_url
            if haskey(verinfo, "artifact_metadata")
                @test verinfo["artifact_metadata"] isa Vector
                for ainfo in verinfo["artifact_metadata"]
                    @test ainfo isa Dict
                    @test haskey(ainfo, "artifact_urls") && ainfo["artifact_urls"] isa Vector
                    @test all(x->isa(x, String), ainfo["artifact_urls"])
                    @test all(in(verinfo["artifact_urls"]), ainfo["artifact_urls"])

                    @test haskey(ainfo, "buildscript")
                    @test ainfo["buildscript"] isa String
                    @test haskey(ainfo, "metadata_source")
                    @test ainfo["metadata_source"] isa String
                    @test haskey(ainfo, "metadata_type")
                    @test ainfo["metadata_type"] isa String
                    @test haskey(ainfo, "metadata_version")
                    @test ainfo["metadata_version"] isa String
                    @test haskey(ainfo, "metadata")
                    @test ainfo["metadata"] isa String
                    if !contains(ainfo["metadata"], "://")
                        @test isfile(joinpath(@__DIR__, "..", ainfo["metadata"]))
                    end
                end
            end
        end
    end
end
