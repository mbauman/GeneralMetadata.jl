using GeneralMetadata
using Test
using Pkg: Pkg, Registry
using Dates: Dates

@testset "Package coverage" begin
    # Ensure all registry packages are present in the metadata, and that all versions present in the metadata are present in the registry
    meta = GeneralMetadata.metadata()
    all_registered_packages = Pkg.Registry.reachable_registries() |> filter(x->x.name == "General") |> only |> x->x.pkgs
    all_registered_names = Set(values(all_registered_packages) .|> x->x.name)
    in_meta_but_not_registered = Pair{String,String}[]
    for (pkg, pkginfo) in meta
        @test pkg in all_registered_names
        reg_info = GeneralMetadata.registered_package_versions(pkg)
        for (ver, verinfo) in pkginfo
            if !haskey(reg_info, VersionNumber(ver))
                push!(in_meta_but_not_registered, (pkg=>ver))
            end
        end
    end
    @test isempty(in_meta_but_not_registered)

    in_registry_but_not_meta = Pair{String,String}[]
    cd(GeneralMetadata.general_repo()) do
        # Roll the registry back to the commit at the time of the last update
        timestamp = GeneralMetadata.last_update(meta) + Dates.Millisecond(500) # --before is exclusive
        last_commit = split(readchomp(`git rev-list --first-parent --before=$(timestamp)Z master`), "\n")[1]
        run(`git checkout --quiet --force $last_commit`)
        reg = Pkg.Registry.RegistryInstance(GeneralMetadata.general_repo())
        last_update = GeneralMetadata.last_update(meta)
        for (pkguuid, pkginfo) in reg.pkgs
            pkg_name = pkginfo.name
            meta_info = get(meta, pkg_name, Dict{String,Any}())
            reg_info = GeneralMetadata.registered_package_versions(pkguuid)
            for (ver, verinfo) in reg_info
                if !haskey(meta_info, string(ver))
                    push!(in_registry_but_not_meta, (pkg_name=>string(ver)))
                end
            end
         end
     end
     @test isempty(in_registry_but_not_meta)
end
