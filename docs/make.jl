using Documenter, MockSOLO

# checkdocs only catches docstrings missing from the pages, not exports without one.
undocumented = filter(n -> !Docs.hasdoc(MockSOLO, n), names(MockSOLO))
isempty(undocumented) || error("exports without docstrings: $undocumented")

makedocs(;
    sitename = "MockSOLO.jl",
    modules = [MockSOLO],
    repo = Remotes.GitHub("yizhanmiao", "MockSOLO.jl"),
    checkdocs = :exports,
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://yizhanmiao.github.io/MockSOLO.jl",
        edit_link = "main",
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

deploydocs(; repo = "github.com/yizhanmiao/MockSOLO.jl.git", devbranch = "main")
