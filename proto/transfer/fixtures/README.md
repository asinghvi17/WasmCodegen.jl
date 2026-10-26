StagedBuildOnlyBad is copied verbatim from the supplied
inputs/juliac-proto/fixtures/StagedBuildOnlyBad. Its dynamic initializer is the
original failing control. SetupOnlyTypes is a new negative transfer control:
a state of a package-defined type cannot deserialize when that package is
unavailable to the runtime reader.
