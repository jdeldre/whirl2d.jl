import Base: size


"""
$(TYPEDEF)

A system type that utilizes a grid of `NX` x `NY` dual cells and `N` Lagrange forcing
points to solve the discrete Navier-Stokes equations in vorticity form. The
parameter `isstatic` specifies whether the forcing points remain static in the
grid.

# Fields
- `Re`: Reynolds number
- `U∞`: Tuple of components of free-stream velocity
- `Δx`: Size of each side of a grid cell
- `I0`: Tuple of indices of the primal node corresponding to physical origin
- `Δt`: Time step
- `rk`: Runge-Kutta coefficients
- `L`: Pre-planned discrete Laplacian operator and inverse
- `X̃`: Lagrange point coordinate data (if present), expressed in inertial coordinates
        (if static) or in body-fixed coordinates (if moving)
- `Hmat`: Pre-computed regularization matrix (if present)
- `Emat`: Pre-computed interpolation matrix (if present)
- `Vb`: Buffer space for vector data on Lagrange points
- `Fq`: Buffer space for primal cell edge data
- `Ww`: Buffer space for dual cell edge data
- `Qq`: More buffer space for dual cell edge data
- `_isstore`: flag to specify whether to store regularization/interpolation matrices

# Constructors:

`NavierStokes(Re,Δx,xlimits,ylimits,Δt
              [,U∞ = (0.0, 0.0)][,X̃ = VectorData{0}()]
              [,isstore=false][,isstatic=true]
              [,rk=TimeMarching.RK31])` specifies the Reynolds number `Re`, the grid
              spacing `Δx`, the dimensions of the domain in the tuples `xlimits`
              and `ylimits` (excluding the ghost cells), and the time step size `Δt`.
              The other arguments are optional. Note that `isstore` set to `true`
              would store matrix versions of the operators. This makes the method
              faster, at the cost of storage.

"""
mutable struct NavierStokes{NX, NY, N, isstatic}  #<: System{Unconstrained}
    # Physical Parameters
    "Reynolds number"
    Re::Float64
    "Free stream velocities"
    U∞::Tuple{Float64, Float64}

    # Discretization
    "Grid spacing"
    Δx::Float64
    "Indices of the primal node corresponding to the physical origin"
    I0::Tuple{Int,Int}
    "Time step"
    Δt::Float64
    "Runge-Kutta method"
    rk::TimeMarching.RKParams

    # Operators
    "Laplacian operator"
    L::Fields.Laplacian{NX,NY}

    # Body coordinate data, if present
    # if a static problem, these coordinates are in inertial coordinates
    # if a non-static problem, in their own coordinate systems
    X̃::VectorData{N}

    # Pre-stored regularization and interpolation matrices (if present)
    Hmat::Union{RegularizationMatrix,Nothing}
    Emat::Union{InterpolationMatrix,Nothing}


    # Scratch space

    ## Pre-allocated space for intermediate values
    Vb::VectorData{N}
    Fq::Edges{Primal, NX, NY}
    Ww::Edges{Dual, NX, NY}
    Qq::Edges{Dual, NX, NY}

    # Flags
    _isstore :: Bool

end

function NavierStokes(Re, Δx, xlimits::Tuple{Real,Real},ylimits::Tuple{Real,Real}, Δt;
                       U∞ = (0.0, 0.0), X̃ = VectorData{0}(),
                       isstore = false,
                       isstatic = true,
                       rk::TimeMarching.RKParams=TimeMarching.RK31)
    #NX, NY = dims

    #= set grid spacing and the grid position of the origin
    In case the physical limits are not consistent with an integer number of dual cells, based on
    the given Δx, we adjust them outward a bit in all directions. We also seek to place the
    origin on the corner of a cell.
    =#
    Lx = xlimits[2]-xlimits[1]
    Ly = ylimits[2]-ylimits[1]
    NxL, NxR = floor(Int,xlimits[1]/Δx), ceil(Int,xlimits[2]/Δx)
    NyL, NyR = floor(Int,ylimits[1]/Δx), ceil(Int,ylimits[2]/Δx)
    NX = NxR-NxL+2 # total number of cells include ghost cells
    NY = NyR-NyL+2
    I0 = (1-NxL,1-NyL)

    α = Δt/(Re*Δx^2)

    L = plan_laplacian((NX,NY),with_inverse=true)

    Vb = VectorData(X̃)
    Fq = Edges{Primal,NX,NY}()
    Ww = Edges{Dual, NX, NY}()
    Qq = Edges{Dual, NX, NY}()
    N = length(X̃)÷2

    if length(N) > 0 && isstore && isstatic
      # in this case, X̃ is assumed to be in inertial coordinates
      regop = Regularize(X̃,Δx;I0=I0,issymmetric=true)
      Hmat, Emat = RegularizationMatrix(regop,VectorData{N}(),Edges{Primal,NX,NY}())
    else
      #Hmat = Nullable{RegularizationMatrix}()
      #Emat = Nullable{InterpolationMatrix}()
      Hmat = nothing
      Emat = nothing

    end

    # should be able to set up time marching operator here...

    NavierStokes{NX, NY, N, isstatic}(Re, U∞, Δx, I0, Δt, rk, L, X̃, Hmat, Emat, Vb, Fq, Ww, Qq, isstore)
end

function Base.show(io::IO, sys::NavierStokes{NX,NY,N,isstatic}) where {NX,NY,N,isstatic}
    print(io, "Navier-Stokes system on a grid of size $NX x $NY")
end

# some convenience functions
"""
    size(sys::NavierStokes,d::Int) -> Int

Return the number of indices of the grid used by `sys` along dimension `d`.
"""
size(sys::NavierStokes{NX,NY},d::Int) where {NX,NY} = d == 1 ? NX : NY

"""
    size(sys::NavierStokes) -> Tuple{Int,Int}

Return a tuple of the number of indices of the grid used by `sys`
"""
size(sys::NavierStokes{NX,NY}) where {NX,NY} = (size(sys,1),size(sys,2))

"""
    origin(sys::NavierStokes) -> Tuple{Int,Int}

Return a tuple of the indices of the primal node that corresponds to the
physical origin of the coordinate system used by `sys`. Note that these
indices need not lie inside the range of indices occupied by the grid.
For example, if the range of physical coordinates occupied by the grid
is (1.0,3.0) x (2.0,4.0), then the origin is not inside the grid.
"""
origin(sys::Systems.NavierStokes) = sys.I0

# Basic operators for any Navier-Stokes system

# Integrating factor -- rescale the time-step size
Fields.plan_intfact(Δt,w,sys::NavierStokes{NX,NY}) where {NX,NY} =
        Fields.plan_intfact(Δt/(sys.Re*sys.Δx^2),w)

# RHS of Navier-Stokes (non-linear convective term)
function TimeMarching.r₁(w::Nodes{Dual,NX,NY},t,sys::NavierStokes{NX,NY}) where {NX,NY}

  Ww = sys.Ww
  Qq = sys.Qq
  L = sys.L
  Δx⁻¹ = 1/sys.Δx

  cellshift!(Qq,curl(L\w)) # -velocity, on dual edges
  Qq.u .-= sys.U∞[1]
  Qq.v .-= sys.U∞[2]

  return rmul!(divergence(Qq∘cellshift!(Ww,w)),Δx⁻¹) # -∇⋅(wu)

end

# RHS of Navier-Stokes (non-linear convective term)
function TimeMarching.r₁(w::Nodes{Dual,NX,NY},t,sys::NavierStokes{NX,NY},U∞::RigidBodyMotions.RigidBodyMotion) where {NX,NY}

  Ww = sys.Ww
  Qq = sys.Qq
  L = sys.L
  Δx⁻¹ = 1/sys.Δx

  cellshift!(Qq,curl(L\w)) # -velocity, on dual edges
  _,ċ,_,_,_,_ = U∞(t)
  Qq.u .-= real(ċ)
  Qq.v .-= imag(ċ)

  return rmul!(divergence(Qq∘cellshift!(Ww,w)),Δx⁻¹) # -∇⋅(wu)

end

# Operators for a system with a body

# RHS of a stationary body with no surface velocity
function TimeMarching.r₂(w::Nodes{Dual,NX,NY},t,sys::NavierStokes{NX,NY,N,true}) where {NX,NY,N}
    ΔV = VectorData(sys.X̃)
    ΔV.u .-= sys.U∞[1]
    ΔV.v .-= sys.U∞[2]
    return ΔV
end

function TimeMarching.r₂(w::Nodes{Dual,NX,NY},t,sys::NavierStokes{NX,NY,N,true},U∞::RigidBodyMotions.RigidBodyMotion) where {NX,NY,N}
    ΔV = VectorData(sys.X̃)
    _,ċ,_,_,_,_ = U∞(t)
    ΔV.u .-= real(ċ)
    ΔV.v .-= imag(ċ)
    return ΔV
end

# Constraint operators, using stored regularization and interpolation operators
# B₁ᵀ = CᵀEᵀ, B₂ = -ECL⁻¹
TimeMarching.B₁ᵀ(f,sys::NavierStokes{NX,NY,N,C}) where {NX,NY,N,C} = Curl()*(sys.Hmat*f)
TimeMarching.B₂(w,sys::NavierStokes{NX,NY,N,C}) where {NX,NY,N,C} = -(sys.Emat*(Curl()*(sys.L\w)))

# Constraint operators, using non-stored regularization and interpolation operators
TimeMarching.B₁ᵀ(f::VectorData{N},regop::Regularize,sys::NavierStokes{NX,NY,N,false}) where {NX,NY,N} = Curl()*regop(sys.Fq,f)
TimeMarching.B₂(w::Nodes{Dual,NX,NY},regop::Regularize,sys::NavierStokes{NX,NY,N,false}) where {NX,NY,N} = -(regop(sys.Vb,Curl()*(sys.L\w)))

# Constraint operator constructors
# Constructor using stored operators
TimeMarching.plan_constraints(w::Nodes{Dual,NX,NY},t,sys::NavierStokes{NX,NY,N,true}) where {NX,NY,N} =
                    (f -> TimeMarching.B₁ᵀ(f,sys),w -> TimeMarching.B₂(w,sys))

# Constructor using non-stored operators
function TimeMarching.plan_constraints(w::Nodes{Dual,NX,NY},t,sys::NavierStokes{NX,NY,N,false}) where {NX,NY,N}
  regop = Regularize(sys.X̃,sys.Δx;issymmetric=true)

  return f -> TimeMarching.B₁ᵀ(f,regop,sys),w -> TimeMarching.B₂(w,regop,sys)
end

include("navierstokes/systemutils.jl")

include("navierstokes/movingbody.jl")
