module GitHub

import HTTP, JSON, URIs
using Base64: base64decode


const API_BASE = "https://api.github.com"
function build_headers()
    headers = [
        "Accept" => "application/vnd.github+json",
        "User-Agent" => "JuliaRegistries-GeneralMetadata.jl-Fetcher/1.0"
    ]
    if haskey(ENV, "GITHUB_TOKEN")
        push!(headers, "Authorization" => "Bearer $(ENV["GITHUB_TOKEN"])")
    end
    return headers
end
function get_tags(owner, repo)
    response = HTTP.get(string(API_BASE, "/repos/", owner, "/", repo, "/tags"), build_headers())
    if response.status != 200
        error("Failed to fetch tags: HTTP $(response.status)")
    end

    return JSON.parse(response.body)
end
function get_releases(owner, repo)
    response = HTTP.get(string(API_BASE, "/repos/", owner, "/", repo, "/releases"), build_headers())
    if response.status != 200
        error("Failed to fetch releases: HTTP $(response.status)")
    end

    return JSON.parse(response.body)
end
function get_release(owner, repo, name)
    response = HTTP.get(string(API_BASE, "/repos/", owner, "/", repo, "/releases/tags/", name), build_headers())
    if response.status != 200
        error("Failed to fetch release for tag $name: HTTP $(response.status)")
    end

    return JSON.parse(response.body)
end
function commit_from_tagname(owner, repo, tag_name)
    response = HTTP.get(string(API_BASE, "/repos/", owner, "/", repo, "/git/ref/tags/", tag_name), build_headers())
    if response.status != 200
        error("Failed to fetch tag info for $tag_name: HTTP $(response.status)")
    end
    tagsinfo = JSON.parse(response.body)
    if haskey(tagsinfo, "object") && tagsinfo["object"]["type"] == "tag"
        # This is an annotated tag, so we need to dereference it to get the commit SHA
        lightweight_response = HTTP.get(string(API_BASE, "/repos/", owner, "/", repo, "/git/tags/", tagsinfo["object"]["sha"]), build_headers())
        if lightweight_response.status != 200
            error("Failed to fetch lightweight tag info for $tag_name: HTTP $(lightweight_response.status)")
        end
        tagsinfo = JSON.parse(lightweight_response.body)
    end
    # This is a lightweight tag, so the object is the commit
    @assert tagsinfo["object"]["type"] == "commit"
    return tagsinfo["object"]["sha"]
end

function tree_sha_from_tagname(owner, repo, tag_name)
    commit_sha = commit_from_tagname(owner, repo, tag_name)
    response = HTTP.get(string(API_BASE, "/repos/", owner, "/", repo, "/git/commits/", commit_sha), build_headers())
    if response.status != 200
        error("Failed to fetch commit info for $commit_sha: HTTP $(response.status)")
    end
    commitinfo = JSON.parse(response.body)
    return commitinfo["tree"]["sha"]
end

get_readme(owner, repo, tree_sha) = get_file(owner, repo, tree_sha, ==("README.md"))
function get_file(owner, repo, tree_sha, path_filter)
    response = HTTP.get(string(API_BASE, "/repos/", owner, "/", repo, "/git/trees/", tree_sha), build_headers())
    if response.status != 200
        error("Failed to fetch file: HTTP $(response.status)")
    end

    tree = JSON.parse(response.body)
    file = filter(x->path_filter(x.path), tree.tree)
    isempty(file) && return nothing

    blob = JSON.parse(HTTP.get(file[].url, build_headers()).body)
    blob.encoding == "base64" || return nothing
    return String(base64decode(blob.content))
end

is_sha(str) = length(str) in (40, 64) && occursin(r"^[a-f0-9]+$", str)

# It can be challenging to parse a version number out of a tag; some options here include: v1.2.3 and PCRE2-1.2.3
# This strips all non-numeric prefixes with up to one digit as long as the digit is not followed by a period.
# and ignore everything after a newline (multiple tags are newline separated, with the latest first)
function normalize_tag(tag)
    is_sha(tag) && return nothing
    tag = URIs.unescapeuri(tag)
    ver = chopprefix(tag, r"^[^\d]*(?:\d[^\d.]+)?")
    return length(ver) < 3 ? nothing : ver
end

function identify_upstream(url)
    # This only supports HTTP URLs for now; all yggdrasil sources use these exclusively to date
    m = match(r"^https?://github\.com/([^/]+)/([^/@]+)(.*)?$", url)
    isnothing(m) && return (nothing, nothing)
    owner, repo, rest = m.captures
    repo = chopsuffix(repo, ".git")
    proj = "github.com/$owner/$repo"
    rest = replace(rest, r"//+" => "/") # normalize multiple slashes to a single slash
    # Now look into the rest to see if it looks like a release download or archive and find its tag
    # possible patterns:
    # /archive/refs/tags/releases/$tag.$ext
    # /archive/refs/tags/$tag.$ext
    # /archive/releases/$tag.$ext
    # /archive/$tag.ext
    # /releases/download/$tag/$filename
    # /archive/$tag/$filename
    tag_name = ""
    m = match(r"^/(?:archive/refs/tags/releases|archive/refs/tags|archive/releases|archive)/([^/]+)\.(tar\.gz|zip)$", rest)
    if !isnothing(m)
        tag_name = m.captures[1]
    else
        m = match(r"^/(?:releases/download|archive)/([^/]+)/([^/]+)$", rest)
        if !isnothing(m)
            tag_name = m.captures[1]
        end
    end
    # Note that there are a few git shas that show up as tag_names in some current sources... and while we could
    # look to see if those resolve to a tagged commit, that'd be even rarer (no current sources do so, in fact)
    tag = normalize_tag(tag_name)
    return isnothing(tag) ? (proj, nothing) : (proj, tag) # union split
end

end
