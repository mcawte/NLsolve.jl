macro trustregiontrace(stepnorm)
    esc(quote
        if tracing
            dt = Dict()
            if extended_trace
                dt["x"] = copy(x)
                dt["f(x)"] = copy(r)
                dt["g(x)"] = copy(J)
                dt["delta"] = delta
                dt["rho"] = rho
            end
            update!(tr,
                    it,
                    maximum(abs, r),
                    $stepnorm,
                    dt,
                    store_trace,
                    show_trace)
        end
    end)
end

function dogleg!{T}(p::AbstractVector{T}, r::AbstractVector{T}, d::AbstractVector{T},
                    J::AbstractMatrix{T}, delta::Real)
    local p_i
    try
        p_i = J \ r # Gauss-Newton step
    catch e
        if isa(e, Base.LinAlg.LAPACKException) || isa(e, Base.LinAlg.SingularException)
            # If Jacobian is singular, compute a least-squares solution to J*x+r=0
            U, S, V = svd(full(J)) # Convert to full matrix because sparse SVD not implemented as of Julia 0.3
            k = sum(S .> eps())
            mrinv = V * diagm([1./S[1:k]; zeros(eltype(S), length(S)-k)]) * U' # Moore-Penrose generalized inverse of J
            p_i = mrinv * r
        else
            throw(e)
        end
    end
    scale!(p_i, -one(T))

    # Test if Gauss-Newton step is within the region
    if wnorm(d, p_i) <= delta
        copy!(p, p_i)   # accepts equation 4.13 from N&W for this step
    else
        # For intermediate we will use the output array `p` as a buffer to hold
        # the gradient. To make it easy to remember which variable that array
        # is representing we make g an alias to p and use g when we want the
        # gradient

        # compute g = J'r ./ (d .^ 2)
        g = p
        At_mul_B!(g, J, r)
        g .= g ./ d.^2

        # compute Cauchy point
        p_c = - wnorm(d, g)^2 / sum(abs2, J*g) .* g

        if wnorm(d, p_c) >= delta
            # Cauchy point is out of the region, take the largest step along
            # gradient direction
            scale!(g, -delta/wnorm(d, g))

            # now we want to set p = g, but that is already true, so we're done

        else
            # from this point on we will only need p_i in the term p_i-p_c.
            # so we reuse the vector p_i by computing p_i = p_i - p_c and then
            # just so we aren't confused we name that p_diff
            p_i .-= p_c
            p_diff = p_i

            # Compute the optimal point on dogleg path
            b = 2 * wdot(d, p_c, d, p_diff)
            a = wnorm(d, p_diff)^2
            tau = (-b+sqrt(b^2 - 4a*(wnorm(d, p_c)^2 - delta^2)))/(2a)
            p_c .+= tau .* p_diff
            copy!(p, p_c)
        end
    end
end

function trust_region_{T,S}(df::AbstractDifferentiableMultivariateFunction,
                          initial_x::AbstractArray{T},
                          xtol::S,
                          ftol::S,
                          iterations::Integer,
                          store_trace::Bool,
                          show_trace::Bool,
                          extended_trace::Bool,
                          factor::S,
                          autoscale::Bool)

    x = vec(copy(initial_x))     # Current point
    nn = length(x)
    xold = fill(convert(T, NaN), nn) # Old point
    r = similar(x)          # Current residual
    r_new = similar(x)      # New residual
    r_predict = similar(x)  # predicted residual
    p = similar(x)          # Step
    d = similar(x)          # Scaling vector
    J = alloc_jacobian(df, T, nn)    # Jacobian

    # Count function calls
    f_calls, g_calls = 0, 0

    df.fg!(x, r, J)
    f_calls += 1
    g_calls += 1

    check_isfinite(r)

    it = 0
    x_converged, f_converged, converged = assess_convergence(x, xold, r, xtol, ftol)

    delta = convert(S, NaN)
    rho = convert(S, NaN)

    tr = SolverTrace()
    tracing = store_trace || show_trace || extended_trace
    @trustregiontrace convert(T, NaN)

    if autoscale
        for j = 1:nn
            d[j] = norm(view(J, :, j))
            if d[j] == zero(S)
                d[j] = one(S)
            end
        end
    else
        fill!(d, one(S))
    end

    delta = factor * abs(wnorm(d, x))
    if delta == zero(S)
        delta = factor
    end

    eta = convert(S, 1e-4)

    while !converged && it < iterations
        it += 1

        # Compute proposed iteration step
        dogleg!(p, r, d, J, delta)

        copy!(xold, x)
        x .+= p
        df.f!(x, r_new)
        f_calls += 1

        # Ratio of actual to predicted reduction (equation 11.47 in N&W)
        A_mul_B!(r_predict, J, p)
        r_predict .+= r
        rho = (sum(abs2,r) - sum(abs2,r_new)) / (sum(abs2,r) - sum(abs2,r_predict))


        if rho > eta
            # Successful iteration
            r .= r_new
            df.g!(x, J)
            g_calls += 1

            # Update scaling vector
            if autoscale
                for j = 1:nn
                    d[j] = max(convert(S, 0.1) * abs(d[j]), norm(view(J, :, j)))
                end
            end

            x_converged, f_converged, converged = assess_convergence(x, xold, r, xtol, ftol)
        else
            x .-= p
            x_converged, converged = false, false
        end

        @trustregiontrace euclidean(x, xold)

        # Update size of trust region
        if rho < 0.1
            delta = delta/2
        elseif rho >= 0.9
            delta = 2 * wnorm(d, p)
        elseif rho >= 0.5
            delta = max(delta, 2 * wnorm(d, p))
        end
    end

    name = "Trust-region with dogleg"
    if autoscale
        name *= " and autoscaling"
    end
    return SolverResults(name,
                         initial_x, reshape(x, size(initial_x)...), norm(r, Inf),
                         it, x_converged, xtol, f_converged, ftol, tr,
                         f_calls, g_calls)
end

function trust_region{T,S}(df::AbstractDifferentiableMultivariateFunction,
                         initial_x::AbstractArray{T},
                         xtol::S,
                         ftol::S,
                         iterations::Integer,
                         store_trace::Bool,
                         show_trace::Bool,
                         extended_trace::Bool,
                         factor::S,
                         autoscale::Bool)
    trust_region_(df, initial_x, convert(S,xtol), convert(S,ftol), iterations, store_trace, show_trace, extended_trace, convert(S,factor), autoscale)
end
