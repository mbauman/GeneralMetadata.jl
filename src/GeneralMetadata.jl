module GeneralMetadata

import TOML, JSON3, HTTP, CSV
using DataFrames: DataFrames, DataFrame
using Dates: Dates, DateTime, Date, Day, Millisecond

function manifest_packages(manifest_path)
    collect(keys(TOML.parsefile(manifest_path)["deps"]))
end

# Write your package code here.
function license(packagename)
    JSON3.read(String(HTTP.get("https://juliahub.com/docs/General/$packagename/stable/pkg.json").body)).license
end

function write_csv_for_manifest(manifest_path, output_path)
    pkgs = manifest_packages(manifest_path)
    licenses = [(try license(pkg); catch ex; missing end) for pkg in pkgs]
    CSV.write(output_path, DataFrame(pkg=pkgs, license=licenses))
end

const GENERAL = Ref{String}()
function general_repo()
    isassigned(GENERAL) && return GENERAL[]
    dir = mktempdir()
    run(`git clone https://github.com/JuliaRegistries/General $dir`)
    return GENERAL[] = dir
end
const REGISTRATION_DATES = Ref{Dict{String, Any}}()
registration_dates() = isassigned(REGISTRATION_DATES) ? REGISTRATION_DATES[] :
    (REGISTRATION_DATES[] = isfile(joinpath(@__DIR__, "..", "registration_dates.toml")) ?
        TOML.parsefile(joinpath(general_repo()), "registration_dates.toml") : Dict{String, Any}())

function extract_registration_dates(dates = registration_dates(); since=maximum(Iterators.flatten(values.(values(dates))), init=DateTime("2018-08-08T23:59:59.999")), upto=Dates.now(Dates.UTC))
    cd(general_repo()) do
        store_missing_dates!(dates, before=since, value=Date(since))
        for day = (DateTime(Date(since) + Day(1)) - Millisecond(1)):Day(1):(DateTime(Date(upto) + Day(1)) - Millisecond(1))
            store_missing_dates!(dates, before=day, value=Date(day))
        end
    end
    return dates
end

"""
    store_missing_dates!(dates; before, value)

Given a registration date structure and within the context of a git repo (as the pwd),
consider all versions registered before `before` *and not already in `dates` to have a
registration date of `value`.
"""
function store_missing_dates!(dates; before, value)
    start = strip(read(`git rev-list -n 1 --before=$(before) master`, String))
    run(`git checkout $start`)
    reg = TOML.parsefile("Registry.toml")
    for (uuid, pkginfo) in reg["packages"]
        pkg = pkginfo["name"]
        isfile(joinpath(pkginfo["path"], "Versions.toml")) || continue
        versions = TOML.parsefile(joinpath(pkginfo["path"], "Versions.toml"))
        if !haskey(dates, pkg)
            dates[pkg] = Dict{String, Any}()
        end
        for ver in keys(versions)
            haskey(dates[pkg], ver) && continue
            dates[pkg][string(ver)] = Date(value)
        end
    end
end

end
