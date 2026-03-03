using GeneralMetadata
using Test
using Pkg: Pkg, Registry
using Dates: Dates

@testset "GeneralMetadata.jl" begin
    # Ensure all registry packages are present in the metadata, and that all versions present in the metadata are present in the registry
    meta = GeneralMetadata.metadata()
    all_registered_packages = Pkg.Registry.reachable_registries() |> filter(x->x.name == "General") |> only |> x->x.pkgs
    all_registered_names = Set(values(all_registered_packages) .|> x->x.name)
    for (pkg, pkginfo) in meta
        @test pkg in all_registered_names
        reg_info = GeneralMetadata.registered_package_versions(pkg)
        for (ver, verinfo) in pkginfo
            @test haskey(reg_info, VersionNumber(ver))
        end
    end
    cd(GeneralMetadata.general_repo()) do
        # Roll the registry back to the commit at the time of the last update
        timestamp = GeneralMetadata.last_update(meta) + Dates.Millisecond(500) # --before is exclusive
        last_commit = split(readchomp(`git rev-list --first-parent --before=$(timestamp)Z master`), "\n")[1]
        run(`git checkout --quiet --force $last_commit`)
        reg = Pkg.Registry.RegistryInstance(GeneralMetadata.general_repo())
        last_update = GeneralMetadata.last_update(meta)
        for (pkg, pkginfo) in reg.pkgs
            pkg_name = pkginfo.name
            @test haskey(meta, pkg_name)
            meta_info = meta[pkg_name]
            reg_info = GeneralMetadata.registered_package_versions(pkg)
            for (ver, verinfo) in reg_info.version_info
                @test haskey(meta_info, string(ver))
            end
         end
     end
end
