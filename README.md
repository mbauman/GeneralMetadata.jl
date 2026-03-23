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
    * `metadata::String`. Optional. Either a URL or a path in this repository that points to the build metadata
    * `metadata_type::String`. Optional. An identifier for the type of `metadata`, currently only `"BinaryBuilder --meta-json"`
    * `metadata_version::String`. Optional. The version of the metadata schema
    * `metadata_source::String`. Optional. Information about how the given metadata was obtained
    * `sources::Vector{<:Dict}`. Optional. Extracted information from the build `metadata` to describe the
    sources from which this artifact was created. Each table within has fields:
        * `type::String`. Optional. One of `["file", "archive", "git", "directory", "builddependency"]`, or missing
        * `package::String`. Required for `"builddependency"`.
        * `url::String`. Required for all `type`s (including missing) except `"builddependency"`
        * `hash::String`. Required for all `type`s (including missing) except `"builddependency"` and `"directory"`
        * `upstream::Dict`. Optional. A table describing this resource:
            * `project::String`. Required. Either a Repology or GitHub project URL
            * `version::String`. Optional. The exact upstream version number, if known

## The web API

To allow for programmatic access in non-Julia environments, this powers a simple JSON-based API server.  It currently has the following endpoints:

* GET https://juliaregistries.github.io/GeneralMetadata.jl/api/Example/versions.json
    * provides the version numbers and each one's `registered` date along with, optionally:
        * `"yanked"` date
        * `"has_artifacts"` boolean
        * `"artifact_upstreams"` array of tables of upstream project names and versions
        * `"artifacts_tracked"` boolean if all artifacts have upstream information for all their sources
* GET https://juliaregistries.github.io/GeneralMetadata.jl/api/Example/info.json
     * provides the UUID

The domain and prefix here may change in the future.

## The Julia API

You can use `meta = GeneralMetadata.metadata()` to gather all the information into a single nested dictionary, mapping the package names
to a dictionary of their versions and data. Modifications to this dictionary can be serialized back out with `GeneralMetadata.save_metadata!(meta)`.

## Updates

The goal is for this information to be automatically and regularly updated. All update scripts are non-destructive and
preserve any manually-entered information. All recorded data should be correct. If you notice something wrong, please open
an issue or pull request with the correction.

Additional fields may be added to the TOML data files and web API in the future.

## Contributing

Contributions are very welcome, both to the infrastructure and to the data itself. In particular artifact "upstream" identifaction is
automatically populated and may be wrong. These are only thorougly reviewed upon publication of a [Security Advisory](https://github.com/JuliaLang/SecurityAdvisories.jl).

One category of metadata that is outstanding and for which contributions would be very welcome is licensing information, both of the packages
themselves and their artifacts.

## Scope

This repository only concerns itself with the General registry; other registries are
explicitly out of scope (and in fact the very structure of this repository is only
possible due to General's naming restrictions). The additional metadata recorded here
should be things that are not easily resolved by the General registry directly.
