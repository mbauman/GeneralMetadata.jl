using GeneralMetadata

function main()
    dates = GeneralMetadata.extract_registration_dates()
    open(joinpath(@__DIR__, "..", "registration_dates.toml"), "w") do io
        TOML.print(io, dates, sorted=true, by=x->something(tryparse(x, VersionNumber), x))
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
