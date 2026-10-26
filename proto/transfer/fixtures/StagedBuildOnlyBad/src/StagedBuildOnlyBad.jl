module StagedBuildOnlyBad
const CALLBACK = Ref{Any}(sin)
function __init__()
    CALLBACK[](1.0)
    nothing
end
end
