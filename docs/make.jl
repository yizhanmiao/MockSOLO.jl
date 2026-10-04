using Documenter, MockSOLO

# checkdocs only catches docstrings missing from the pages, not exports without one.
undocumented = filter(n -> !Docs.hasdoc(MockSOLO, n), names(MockSOLO))
isempty(undocumented) || error("exports without docstrings: $undocumented")

makedocs(;
    sitename = "MockSOLO.jl",
    modules = [MockSOLO],
    remotes = nothing,          # no git remote yet
    checkdocs = :exports,
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", nothing) == "true",
        edit_link = nothing,    # no git remote yet
        repolink = nothing,
    ),
    pages = [
        "Home" => "index.md",
        "Host software" => "hosts.md",
        "Protocol" => "protocol.md",
        "Front panel" => "frontpanel.md",
        "Limitations" => "limitations.md",
        "API reference" => "api.md",
    ],
)
