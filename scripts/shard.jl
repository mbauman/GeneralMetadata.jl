# Temporary script to shard metadata into one file per package

using TOML: TOML

dates = TOML.parsefile(joinpath(@__DIR__, "..", "registration_dates.toml"))
artifacts = TOML.parsefile(joinpath(@__DIR__, "..", "artifact_urls.toml"))

for package in union(keys(dates), keys(artifacts))
    output_path = joinpath(@__DIR__, "..", "metadata", string(uppercase(package[1])), "$package.toml")
    mkpath(dirname(output_path))

    pkg_dates = get(dates, package, Dict{String,Any}())
    pkg_artifacts = get(artifacts, package, Dict{String,Any}())
    pkg_meta = Dict{String,Any}()
    last_artifacts = nothing
    for version in sort(collect(union(keys(pkg_dates), keys(pkg_artifacts))), by=VersionNumber, rev=true)
        pkg_meta[version] = Dict{String,Any}()
        if haskey(pkg_dates, version)
            pkg_meta[version]["registration_date"] = pkg_dates[version]["registered"]
        end
        if haskey(pkg_artifacts, version)
            pkg_meta[version]["artifact_urls"] = pkg_artifacts[version]
            last_artifacts = pkg_artifacts[version]
        elseif !isnothing(last_artifacts)
            pkg_meta[version]["artifact_urls"] = last_artifacts
        end
    end
    open(output_path, "w") do io
        TOML.print(io, pkg_meta, sorted = true, by = x->something(tryparse(VersionNumber, x), x))
    end
end