module CallableGraphs

# Resolve the already locked transitive package explicitly; this probe does not
# change the shared application project or install another dependency version.
const RGF = Base.require(Base.PkgId(Base.UUID("7e49a35a-f44a-4d26-94aa-eba1b4ca6b47"), "RuntimeGeneratedFunctions"))
RGF.init(@__MODULE__)

named(x::Float64) = x + 2.0
make_closure(offset::Float64) = x::Float64 -> x + offset
make_rgf() = RGF.RuntimeGeneratedFunction(@__MODULE__, @__MODULE__, :(x -> x + 2.0))
make_rgf_dropped() = RGF.drop_expr(make_rgf())

# There is intentionally no construction call at top level: a fresh reader has
# the runtime definitions and an empty RGF expression cache before deserialize.
end
