# GeneralMetadata

Aggregate helpful information about Julia's package ecosystem that isn't immediately available
from the General registry itself.

## The data schema

Every Package in the General registry has a `Package.toml` in the`metadata` directory, sharded
into a subdirectory based upon its capitalized first letter (`P`). This TOML has all the registered
versions as its top-level keys. Each version entry has the following fields:

* `registered::DateTime`. Required. It is the timestamp of the registration commit landing on General's `master` branch.
* `yanked::DateTime`. Optional. If yanked, set to the timestamp of the yanking commit landing on General's `master` branch.
* `artifact_urls::Vector{String}`. Optional (but nearly always set). Every download URL within that version's `Artifacts.toml`.
* `artifact_metadata::Vector{<:Dict}`. Optional. A collection of tables, each with the fields:
    * `artifact_urls::Vector{String}`. Required. The artifact_urls for which this entry pertains. Must be a (non-strict) subset of the package's `artifact_urls`.
    * `buildscript::String`. Optional. The URL of the buildscript
    * `metadata::Any`. Optional. An arbitrary blob that contains information about these artifact URLs.
    * `metadata_type::String`. Optional. An identifier for the type of `metadata`, currently only `"BinaryBuilder --meta-json"`
    * `metadata_version::String`. Optional. The version of the metadata schema
    * `metadata_source::String`. Optional. Information about how the given metadata was obtained

## The web API

To allow for programmatic access in non-Julia environments, this powers a simple JSON-based API server.  It currently has the following endpoints:

* GET https://juliaregistries.github.io/GeneralMetadata.jl/api/Example/versions.json
     * provides the version numbers and their registration/yank dates
* GET https://juliaregistries.github.io/GeneralMetadata.jl/api/Example/info.json
     * provides the UUID

The domain and prefix here may change in the future.

## The Julia API

You can use `meta = GeneralMetadata.metadata()` to gather all the information into a single nested dictionary, mapping the package names
to a dictionary of their versions and data. Modifications to this dictionary can be serialized back out with `GeneralMetadata.save_metadata!(meta)`.

## Updates

The goal is for this information to be automatically and regularly updated. All update scripts are non-destructive and
preserve any manually-entered information. All recorded data should be correct. If you notice something wrong, please open an issue.

Additional fields may be added to the TOML data files and web API in the future.

## Yet to do:

* [ ] Package licenses
* [ ] Artifact upstream component identification
* [ ] Artifact upstream component licenses

## Scope

This repository only concerns itself with the General registry; other registries are
explicitly out of scope (and in fact the very structure of this repository is only
possible due to General's naming restrictions). The additional metadata recorded here
should be things that are not easily resolved by the General registry directly.
