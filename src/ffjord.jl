abstract type CNFLayer <: Function end
Flux.trainable(m::CNFLayer) = (m.p,)

"""
Constructs a continuous-time recurrent neural network, also known as a neural
ordinary differential equation (neural ODE), with fast gradient calculation
via adjoints [1] and specialized for density estimation based on continuous
normalizing flows (CNF) [2] with a direct computation of the trace
of the dynamics' jacobian. At a high level this corresponds to the following steps:

1. Parameterize the variable of interest x(t) as a function f(z, θ, t) of a base variable z(t) with known density p_z;
2. Use the transformation of variables formula to predict the density p_x as a function of the density p_z and the trace of the Jacobian of f;
3. Choose the parameter θ to minimize a loss function of p_x (usually the negative likelihood of the data);

!!!note
    This layer has been deprecated in favour of `FFJORD`. Use FFJORD with `monte_carlo=false` instead.

After these steps one may use the NN model and the learned θ to predict the density p_x for new values of x.

```julia
DeterministicCNF(model, tspan, basedist=nothing, monte_carlo=false, args...; kwargs...)
```
Arguments:
- `model`: A Chain neural network that defines the dynamics of the model.
- `basedist`: Distribution of the base variable. Set to the unit normal by default.
- `tspan`: The timespan to be solved on.
- `kwargs`: Additional arguments splatted to the ODE solver. See the
  [Common Solver Arguments](https://diffeq.sciml.ai/dev/basics/common_solver_opts/)
  documentation for more details.
Ref
[1]L. S. Pontryagin, Mathematical Theory of Optimal Processes. CRC Press, 1987.
[2]R. T. Q. Chen, Y. Rubanova, J. Bettencourt, D. Duvenaud. Neural Ordinary Differential Equations. arXiv preprint at arXiv1806.07366, 2019.
[3]W. Grathwohl, R. T. Q. Chen, J. Bettencourt, I. Sutskever, D. Duvenaud. FFJORD: Free-Form Continuous Dynamic For Scalable Reversible Generative Models. arXiv preprint at arXiv1810.01367, 2018.

"""
struct DeterministicCNF{M,P,RE,Distribution,T,A,K} <: CNFLayer
    model::M
    p::P
    re::RE
    basedist::Distribution
    tspan::T
    args::A
    kwargs::K

    function DeterministicCNF(model, tspan, args...;
                              p=nothing, basedist=nothing, kwargs...)
        _p, re = Flux.destructure(model)
        if p === nothing
            p = _p
        end
        if basedist === nothing
            size_input = size(model[1].weight, 2)
            basedist = MvNormal(zeros(size_input), I + zeros(size_input, size_input))
        end
        @warn("This layer has been deprecated in favor of `FFJORD`. Use FFJORD with `monte_carlo=false` instead.")
        new{typeof(model),typeof(p),typeof(re),typeof(basedist),typeof(tspan),typeof(args),typeof(kwargs)}(
            model, p, re, basedist, tspan, args, kwargs)
    end
end

# FIXME: To be removed in future releases
function cnf(du, u, p, t, re)
    z = @view u[1:end - 1]
    m = re(p)
    J = jacobian_fn(m, z)
    trace_jac = length(z) == 1 ? sum(J) : tr(J)
    du[1:end - 1] = m(z)
    du[end] = -trace_jac
end

function (n::DeterministicCNF)(x, p=n.p)
    cnf_ = (du, u, p, t) -> cnf(du, u, p, t, n.re)
    prob = ODEProblem{true}(cnf_, vcat(x, 0f0), n.tspan, p)
    sensealg = InterpolatingAdjoint(autojacvec=false)
    pred = solve(prob, n.args...; sensealg, n.kwargs...)[:, end]
    pz = n.basedist
    z = pred[1:end - 1]
    delta_logp = pred[end]
    logpz = logpdf(pz, z)
    logpx = logpz .- delta_logp
    return logpx[1]
end

"""
Constructs a continuous-time recurrent neural network, also known as a neural
ordinary differential equation (neural ODE), with fast gradient calculation
via adjoints [1] and specialized for density estimation based on continuous
normalizing flows (CNF) [2] with a stochastic approach [2] for the computation of the trace
of the dynamics' jacobian. At a high level this corresponds to the following steps:

1. Parameterize the variable of interest x(t) as a function f(z, θ, t) of a base variable z(t) with known density p_z;
2. Use the transformation of variables formula to predict the density p_x as a function of the density p_z and the trace of the Jacobian of f;
3. Choose the parameter θ to minimize a loss function of p_x (usually the negative likelihood of the data);

After these steps one may use the NN model and the learned θ to predict the density p_x for new values of x.

```julia
FFJORD(model, basedist=nothing, monte_carlo=false, tspan, args...; kwargs...)
```
Arguments:
- `model`: A Chain neural network that defines the dynamics of the model.
- `basedist`: Distribution of the base variable. Set to the unit normal by default.
- `tspan`: The timespan to be solved on.
- `kwargs`: Additional arguments splatted to the ODE solver. See the
  [Common Solver Arguments](https://diffeq.sciml.ai/dev/basics/common_solver_opts/)
  documentation for more details.
Ref
[1]L. S. Pontryagin, Mathematical Theory of Optimal Processes. CRC Press, 1987.
[2]R. T. Q. Chen, Y. Rubanova, J. Bettencourt, D. Duvenaud. Neural Ordinary Differential Equations. arXiv preprint at arXiv1806.07366, 2019.
[3]W. Grathwohl, R. T. Q. Chen, J. Bettencourt, I. Sutskever, D. Duvenaud. FFJORD: Free-Form Continuous Dynamic For Scalable Reversible Generative Models. arXiv preprint at arXiv1810.01367, 2018.

"""
struct FFJORD{M,P,RE,Distribution,T,A,K} <: CNFLayer
    model::M
    p::P
    re::RE
    basedist::Distribution
    tspan::T
    args::A
    kwargs::K

    function FFJORD(model, tspan, args...;
                    p=nothing, basedist=nothing, kwargs...)
        _p, re = Flux.destructure(model)
        if p === nothing
            p = _p
        end
        if basedist === nothing
            size_input = size(model[1].weight, 2)
            basedist = MvNormal(zeros(size_input), I + zeros(size_input, size_input))
        end
        new{typeof(model),typeof(p),typeof(re),typeof(basedist),typeof(tspan),typeof(args),typeof(kwargs)}(
            model, p, re, basedist, tspan, args, kwargs)
    end
end

_norm_batched(x::AbstractMatrix) = sqrt.(sum(x.^2, dims=1))

function jacobian_fn(f, x::AbstractVector)
    y::AbstractVector, back = Zygote.pullback(f, x)
    ȳ(i) = [i == j for j = 1:length(y)]
    vcat([transpose(back(ȳ(i))[1]) for i = 1:length(y)]...)
end

function jacobian_fn(f, x::AbstractMatrix)
    y, back = Zygote.pullback(f, x)
    z = Zygote.@ignore similar(y)
    Zygote.@ignore fill!(z, zero(eltype(x)))
    vec = Zygote.Buffer(x, size(x, 1), size(x, 1), size(x, 2))
    for i in 1:size(y, 1)
        Zygote.@ignore z[i, :] .+= one(eltype(x))
        vec[i, :, :] = back(z)[1]
    end
    return copy(vec)
 end

_trace_batched(x::AbstractArray{T,3}) where T =
    reshape([tr(x[:, :, i]) for i in 1:size(x, 3)], 1, size(x, 3))

function ffjord(u, p, t, re, e=randn(eltype(x), size(x));
                regularize=false, monte_carlo=true)
    m = re(p)
    if regularize
        z = u[1:end - 3, :]
        if monte_carlo
            mz, back = Zygote.pullback(m, z)
            eJ = back(e)[1]
            trace_jac = sum(eJ .* e, dims=1)
        else
            mz = m(z)
            trace_jac = _trace_batched(jacobian_fn(m, z))
        end
        return cat(mz, -trace_jac, sum(abs2, mz, dims=1),
                   _norm_batched(eJ), dims=1)
    else
        z = u[1:end - 1, :]
        if monte_carlo
            mz, back = Zygote.pullback(m, z)
            eJ = back(e)[1]
            trace_jac = sum(eJ .* e, dims=1)
        else
            mz = m(z)
            trace_jac = _trace_batched(jacobian_fn(m, z))
        end
        return cat(mz, -trace_jac, dims=1)
    end
end

# When running on GPU e needs to be passed separately
function (n::FFJORD)(x, p=n.p, e=randn(eltype(x), size(x));
                     regularize=false, monte_carlo=true)
    pz = n.basedist
    sensealg = InterpolatingAdjoint()
    ffjord_ = (u, p, t) -> ffjord(u, p, t, n.re, e; regularize, monte_carlo)
    if regularize
        _z = Zygote.@ignore similar(x, 3, size(x, 2))
        Zygote.@ignore fill!(_z, 0.0f0)
        prob = ODEProblem{false}(ffjord_, vcat(x, _z), n.tspan, p)
        pred = solve(prob, n.args...; sensealg, n.kwargs...)[:, :, end]
        z = pred[1:end - 3, :]
        delta_logp = reshape(pred[end - 2, :], 1, size(pred, 2))
        λ₁ = pred[end - 1, :]
        λ₂ = pred[end, :]
    else
        _z = Zygote.@ignore similar(x, 1, size(x, 2))
        Zygote.@ignore fill!(_z, 0.0f0)
        prob = ODEProblem{false}(ffjord_, vcat(x, _z), n.tspan, p)
        pred = solve(prob, n.args...; sensealg, n.kwargs...)[:, :, end]
        z = pred[1:end - 1, :]
        delta_logp = reshape(pred[end, :], 1, size(pred, 2))
        λ₁ = λ₂ = _z[1, :]
    end

    # logpdf promotes the type to Float64 by default
    logpz = eltype(x).(reshape(logpdf(pz, z), 1, size(x, 2)))
    logpx = logpz .- delta_logp

    return logpx, λ₁, λ₂
end
