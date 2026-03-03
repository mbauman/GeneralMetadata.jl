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
        JSON.json(joinpath(pkgdir, "versions.json"), sort(OrderedDict(versions), by=VersionNumber))
        JSON.json(joinpath(pkgdir, "info.json"), (; name=pkg, uuid=string(only(uuid))))
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
