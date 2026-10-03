using Documenter, MockSOLO

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
        "API reference" => "api.md",
    ],
)
