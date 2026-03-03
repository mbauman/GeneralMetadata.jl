using TOML: TOML
using JSON: JSON
using DataStructures: DataStructures, OrderedDict
using Pkg: Pkg, Registry

function main()
    allversions = GeneralMetadata.metadata()
    general = only(filter(x->x.uuid==Base.UUID("23338594-aafe-5451-b93e-139f81909106"), Registry.reachable_registries()))
    root = mkpath(joinpath(@__DIR__, "..", "webroot", "api"))
    for (pkg, versions) in allversions
        uuid = Registry.uuids_from_name(general, pkg)
        isempty(uuid) && continue # These are packages that have since been removed from the registry; mostly the cappening
        pkgdir = mkpath(joinpath(root, pkg))
        JSON.json(joinpath(pkgdir, "versions.json"), sort(OrderedDict(versions), by=VersionNumber))
        JSON.json(joinpath(pkgdir, "info.json"), (; name=pkg, uuid=string(only(uuid))))
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
