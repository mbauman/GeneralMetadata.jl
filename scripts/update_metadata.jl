using GeneralMetadata
using TOML

function main()
    meta = GeneralMetadata.metadata()
    GeneralMetadata.update_registration_dates!(meta)
    GeneralMetadata.update_artifact_urls!(meta)
    GeneralMetadata.update_jll_metadata!(meta)
    GeneralMetadata.save_metadata!(meta)
    return meta
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
