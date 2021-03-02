
module ContractionSequenceOptimization

  using
    ITensors,
    IterTools

  export depth_first_constructive,
         breadth_first_constructive

  function _dim(is::Vector{<: Index})
    isempty(is) && return 1
    return mapreduce(dim, *, is)
  end

  # `is` could be Vector{Int} for BitSet
  function _dim(is, ind_dims::Vector{Int})
    isempty(is) && return 1
    dim = 1
    for i in is
      dim *= ind_dims[i]
    end
    return dim
  end

  function remove_common_pair!(isR, N1, n1)
    if n1 > N1
      return
    end
    N = length(isR)
    is1 = isR[n1]
    is2 = @view isR[N1+1:N]
    n2 = findfirst(==(is1), is2)
    if isnothing(n2)
      n1 += 1
      remove_common_pair!(isR, N1, n1)
    else
      deleteat!(isR, (n1, N1+n2))
      N1 -= 1
      remove_common_pair!(isR, N1, n1)
    end
  end

  function contract_inds(is1, is2)
    IndexT = eltype(is1)
    N1 = length(is1)
    N2 = length(is2)
    isR = IndexT[]
    for n1 in 1:N1
      i1 = is1[n1]
      n2 = findfirst(==(i1), is2)
      if isnothing(n2)
        push!(isR, i1)
      end
    end
    for n2 in 1:N2
      i2 = is2[n2]
      n1 = findfirst(==(i2), is1)
      if isnothing(n1)
        push!(isR, dag(i2))
      end
    end
    return isR
  end

  # Return the noncommon indices and the cost of contraction
  # Recursively removes pairs of indices that are common
  # between the IndexSets (TODO: use this for symdiff in ITensors.jl)
  function contract_inds_cost(is1is2::Tuple{Vector{Int}, Vector{Int}}, ind_dims::Vector{Int})
    is1, is2 = is1is2
    N1 = length(is1)
    isR = vcat(is1, is2)
    remove_common_pair!(isR, N1, 1)
    cost = Int(sqrt(_dim(is1, ind_dims) * _dim(is2, ind_dims) * _dim(isR, ind_dims)))
    return isR, cost
  end

  function contract_inds_cost(is1::Vector{IndexT}, is2::Vector{IndexT}) where {IndexT <: Index}
    N1 = length(is1)

    # This is pretty slow
    #isR = vcat(is1, is2)
    #remove_common_pair!(isR, N1, 1)

    isR = contract_inds(is1, is2)

    cost = Int(sqrt(_dim(is1) * _dim(is2) * _dim(isR)))
    return isR, cost
  end

  function optimize_contraction_sequence(T1::ITensor, T2::ITensor, T3::ITensor)
    return optimize_contraction_sequence(inds(T1), inds(T2), inds(T3))
  end

  function optimize_contraction_sequence(is1::IndexSet, is2::IndexSet, is3::IndexSet)
    N1 = length(is1)
    N2 = length(is2)
    N3 = length(is3)
    dim2 = dim(is2)
    dim3 = dim(is3)
    dim11 = 1
    dim12 = 1
    dim31 = 1
    @inbounds for n1 in 1:N1
      i1 = is1[n1]
      n2 = findfirst(==(i1), is2)
      if isnothing(n2)
        n3 = findfirst(==(i1), is3)
        if isnothing(n3)
          dim11 *= dim(i1)
          continue
        end
        dim31 *= dim(i1)
        continue
      end
      dim12 *= dim(i1)
    end
    dim23 = 1
    @inbounds for n2 in 1:length(is2)
      i2 = is2[n2]
      n3 = findfirst(==(i2), is3)
      if !isnothing(n3)
        dim23 *= dim(i2)
      end
    end
    dim22 = dim2 ÷ (dim12 * dim23)
    dim33 = dim3 ÷ (dim23 * dim31)
    external_dims1 = (dim11, dim22, dim33)
    internal_dims1 = (dim12, dim23, dim31)
    external_dims2 = (dim22, dim33, dim11)
    internal_dims2 = (dim23, dim31, dim12)
    external_dims3 = (dim33, dim11, dim22)
    internal_dims3 = (dim31, dim12, dim23)
    cost1 = compute_cost(external_dims1, internal_dims1)
    cost2 = compute_cost(external_dims2, internal_dims2)
    cost3 = compute_cost(external_dims3, internal_dims3)
    mincost, which_sequence = findmin((cost1, cost2, cost3))
    sequence = three_tensor_contraction_sequence(which_sequence)
    return sequence, mincost
  end

  function compute_cost(external_dims::Tuple{Int, Int, Int},
                        internal_dims::Tuple{Int, Int, Int})
    dim11, dim22, dim33 = external_dims
    dim12, dim23, dim31 = internal_dims
    cost12 = dim11 * dim22 * dim12 * dim23 * dim31
    return cost12 + dim11 * dim22 * dim33 * dim31 * dim23
  end

  function three_tensor_contraction_sequence(which_sequence::Int)::Vector{Any}
    @assert 1 ≤ which_sequence ≤ 3
    return if which_sequence == 1
      Any[3, [1, 2]]
    elseif which_sequence == 2
      Any[1, [2, 3]]
    else
      Any[2, [3, 1]]
    end
  end

  # Converts the indices to integer labels
  # and returns a Vector that takes those labels
  # and returns the original integer dimensions
  function inds_to_ints(T::Vector{Vector{IndexT}}) where {IndexT <: Index}
    N = length(T)
    ind_to_int = Dict{IndexT, Int}()
    ints = Vector{Int}[Vector{Int}(undef, length(T[n])) for n in 1:N]
    ind_dims = Vector{Int}(undef, sum(length, T))
    x = 0
    @inbounds for n in 1:N
      T_n = T[n]
      ints_n = ints[n]
      for j in 1:length(ints_n)
        i = T_n[j]
        i_label = get!(ind_to_int, i) do
          x += 1
          ind_dims[x] = dim(i)
          x
        end
        ints_n[j] = i_label
      end
    end
    resize!(ind_dims, x)
    return ints, ind_dims
  end

  # Converts the indices to integer labels stored in BitSets
  # and returns a Vector that takes those labels
  # and returns the original integer dimensions
  function inds_to_bitsets(T::Vector{Vector{IndexT}}) where {IndexT <: Index}
    N = length(T)
    ind_to_int = Dict{IndexT, Int}()
    ints = map(_ -> BitSet(), 1:N)
    ind_dims = Vector{Int}(undef, sum(length, T))
    x = 0
    @inbounds for n in 1:N
      T_n = T[n]
      for j in 1:length(T_n)
        i = T_n[j]
        i_label = get!(ind_to_int, i) do
          x += 1
          ind_dims[x] = dim(i)
          x
        end
        push!(ints[n], i_label)
      end
    end
    resize!(ind_dims, x)
    return ints, ind_dims
  end

  # Convert a contraction sequence in pair form to tree format
  function pair_sequence_to_tree(pairs::Vector{Pair{Int, Int}}, N::Int)
    trees = Any[1:N...]
    for p in pairs
      push!(trees, Any[trees[p[1]], trees[p[2]]])
    end
    return trees[end]
  end

  function _depth_first_constructive!(optimal_sequence, optimal_cost, cost_cache, sequence, T, ind_dims, remaining, cost)
    if length(remaining) == 1
      # Only should get here if the contraction was the best
      # Otherwise it would have hit the `continue` below
      @assert cost ≤ optimal_cost[]
      optimal_cost[] = cost
      optimal_sequence .= sequence
    end
    for aᵢ in 1:length(remaining)-1, bᵢ in aᵢ+1:length(remaining)
      a = remaining[aᵢ]
      b = remaining[bᵢ]
      Tᵈ, current_cost = get!(cost_cache, (T[a], T[b])) do
        contract_inds_cost((T[a], T[b]), ind_dims)
      end
      new_cost = cost + current_cost
      if new_cost ≥ optimal_cost[]
        continue
      end
      new_sequence = push!(copy(sequence), a => b)
      new_T = push!(copy(T), Tᵈ)
      new_remaining = deleteat!(copy(remaining), (aᵢ, bᵢ))
      push!(new_remaining, length(new_T))
      _depth_first_constructive!(optimal_sequence, optimal_cost, cost_cache, new_sequence, new_T, ind_dims, new_remaining, new_cost)
    end
  end

  # No caching
  function _depth_first_constructive!(optimal_sequence, optimal_cost, sequence, T, remaining, cost)
    if length(remaining) == 1
      # Only should get here if the contraction was the best
      # Otherwise it would have hit the `continue` below
      @assert cost ≤ optimal_cost[]
      optimal_cost[] = cost
      optimal_sequence .= sequence
    end
    for aᵢ in 1:length(remaining)-1, bᵢ in aᵢ+1:length(remaining)
      a = remaining[aᵢ]
      b = remaining[bᵢ]
      Tᵈ, current_cost = contract_inds_cost(T[a], T[b])
      new_cost = cost + current_cost
      if new_cost ≥ optimal_cost[]
        continue
      end
      new_sequence = push!(copy(sequence), a => b)
      new_T = push!(copy(T), Tᵈ)
      new_remaining = deleteat!(copy(remaining), (aᵢ, bᵢ))
      push!(new_remaining, length(new_T))
      _depth_first_constructive!(optimal_sequence, optimal_cost, new_sequence, new_T, new_remaining, new_cost)
    end
  end

  function depth_first_constructive(T::Vector{<: ITensor}; enable_caching::Bool = false)
    if length(T) == 1
      return Any[1], 0
    elseif length(T) == 2
      return Any[1 2], 0
    elseif length(T) == 3
      return optimize_contraction_sequence(T[1], T[2], T[3])
    end
    indsT = [inds(Tₙ) for Tₙ in T]
    return depth_first_constructive(indsT; enable_caching = enable_caching)
  end

  function depth_first_constructive(T::Vector{IndexSetT}; enable_caching::Bool = false) where {IndexSetT <: IndexSet}
    N = length(T)
    IndexT = eltype(IndexSetT)
    Tinds = Vector{IndexT}[Vector{IndexT}(undef, length(T[n])) for n in 1:N]
    for n in 1:N
      T_n = T[n]
      Tinds_n = Tinds[n]
      for j in 1:length(Tinds_n)
        Tinds_n[j] = T_n[j]
      end
    end
    return depth_first_constructive(Tinds; enable_caching = enable_caching)
  end

  function depth_first_constructive(T::Vector{Vector{IndexT}}; enable_caching = enable_caching) where {IndexT <: Index}
    return if enable_caching
      T′, ind_dims = inds_to_ints(T)
      depth_first_constructive_caching(T′, ind_dims)
    else
      depth_first_constructive_no_caching(T)
    end
  end

  # TODO: use the initial sequence as a guess sequence, which
  # can be used to prune the tree
  function depth_first_constructive_caching(T::Vector{Vector{Int}}, ind_dims::Vector{Int})
    optimal_cost = Ref(typemax(Int))
    optimal_sequence = Vector{Pair{Int, Int}}(undef, length(T)-1)
    # Memoize index contractions and costs that have already been seen
    cost_cache = Dict{Tuple{Vector{Int}, Vector{Int}}, Tuple{Vector{Int}, Int}}()
    _depth_first_constructive!(optimal_sequence, optimal_cost, cost_cache, Pair{Int, Int}[], T, ind_dims, collect(1:length(T)), 0)
    return pair_sequence_to_tree(optimal_sequence, length(T)), optimal_cost[]
  end

  function depth_first_constructive_no_caching(T::Vector{Vector{IndexT}}) where {IndexT <: Index}
    optimal_cost = Ref(typemax(Int))
    optimal_sequence = Vector{Pair{Int, Int}}(undef, length(T)-1)
    _depth_first_constructive!(optimal_sequence, optimal_cost, Pair{Int, Int}[], T, collect(1:length(T)), 0)
    return pair_sequence_to_tree(optimal_sequence, length(T)), optimal_cost[]
  end

  function contraction_cost(T::Vector{Vector{IndexT}}, a::Vector{Int},
                            b::Vector{Int}) where {IndexT <: Index}
    # The set of tensor indices `a` and `b`
    Tᵃ = T[a]
    Tᵇ = T[b]

    # XXX TODO: this should use a cache to store the results
    # of the contraction
    indsTᵃ = symdiff(Tᵃ...)
    indsTᵇ = symdiff(Tᵇ...)
    indsTᵃTᵇ = symdiff(indsTᵃ, indsTᵇ)
    cost = Int(sqrt(prod(_dim(indsTᵃ) * prod(_dim(indsTᵇ) * _dim(indsTᵃTᵇ)))))
    return cost
  end

  function contraction_cost(T::Vector{BitSet}, dims::Vector{Int}, a::BitSet,
                            b::BitSet) where {IndexT <: Index}
    # The set of tensor indices `a` and `b`
    Tᵃ = [T[aₙ] for aₙ in a]
    Tᵇ = [T[bₙ] for bₙ in b]

    # XXX TODO: this should use a cache to store the results
    # of the contraction
    indsTᵃ = symdiff(Tᵃ...)
    indsTᵇ = symdiff(Tᵇ...)
    indsTᵃTᵇ = symdiff(indsTᵃ, indsTᵇ)
    dim_a = _dim(indsTᵃ, dims)
    dim_b = _dim(indsTᵇ, dims)
    dim_ab = _dim(indsTᵃTᵇ, dims)
    cost = Int(sqrt(Base.Checked.checked_mul(dim_a, dim_b, dim_ab)))
    return cost
  end

  function contraction_cost!(inds_cache::Dict{BitSet, BitSet},
                             T::Vector{BitSet}, dims::Vector{Int}, a::BitSet,
                             b::BitSet, ab::BitSet) where {IndexT <: Index}
    # The set of tensor indices `a` and `b`
    Tᵃ = [T[aₙ] for aₙ in a]
    Tᵇ = [T[bₙ] for bₙ in b]

    # XXX TODO: this should use a cache to store the results
    # of the contraction
    #indsTᵃ = symdiff(Tᵃ...)
    #indsTᵇ = symdiff(Tᵇ...)

    indsTᵃ = inds_cache[a]
    indsTᵇ = inds_cache[b]

    indsTᵃTᵇ = symdiff(indsTᵃ, indsTᵇ)

    inds_cache[ab] = indsTᵃTᵇ

    dim_a = _dim(indsTᵃ, dims)
    dim_b = _dim(indsTᵇ, dims)
    dim_ab = _dim(indsTᵃTᵇ, dims)
    cost = Int(sqrt(Base.Checked.checked_mul(dim_a, dim_b, dim_ab)))
    return cost
  end

  #
  # Breadth-first constructive approach
  #

  function breadth_first_constructive(T::Vector{<: ITensor})
    if length(T) == 1
      return Any[1], 0
    elseif length(T) == 2
      return Any[1 2], 0
    elseif length(T) == 3
      return optimize_contraction_sequence(T[1], T[2], T[3])
    end
    indsT = [inds(Tₙ) for Tₙ in T]
    return breadth_first_constructive(indsT)
  end

  function breadth_first_constructive(T::Vector{IndexSetT}) where {IndexSetT <: IndexSet}
    N = length(T)
    IndexT = eltype(IndexSetT)
    Tinds = Vector{IndexT}[Vector{IndexT}(undef, length(T[n])) for n in 1:N]
    for n in 1:N
      T_n = T[n]
      Tinds_n = Tinds[n]
      for j in 1:length(Tinds_n)
        Tinds_n[j] = T_n[j]
      end
    end
    Tlabels, Tdims = inds_to_bitsets(Tinds)
    return breadth_first_constructive(Tlabels, Tdims)
  end

  function _cmp(A::BitSet, B::BitSet)
    for (a, b) in zip(A, B)
      if !isequal(a, b)
        return isless(a, b) ? -1 : 1
      end
    end
    return cmp(length(A), length(B))
  end

  # Returns true when `A` is less than `B` in lexicographic order.
  _isless(A::BitSet, B::BitSet) = _cmp(A, B) < 0
 
  function breadth_first_constructive(T::Vector{BitSet}, dims::Vector{Int})
    n = length(T)

    # `S[c]` is the set of all objects made up by
    # contracting `c` unique tensors from `S¹`,
    # the set of `n` tensors which make of `T`
    S = Vector{Vector{BitSet}}(undef, n)
    for c in 1:n
      S[c] = map(BitSet, IterTools.subsets(1:n, c))
    end

    # A cache of the optimal costs of contracting a set of
    # tensors, for example [1, 2, 3].
    # Make sure they are sorted before hashing.
    cost_cache = Dict{BitSet, Int}()

    # TODO: a cache of the uncontracted indices of a set of
    # tensors
    inds_cache = Dict{BitSet, BitSet}()
    for i in 1:n
      inds_cache[BitSet([i])] = T[i]
    end

    # A cache of the best sequence found
    sequence_cache = Dict{BitSet, Vector{Any}}()

    # c is the total number of tensors being contracted
    # in the current sequence
    for c in 2:n
      # For each pair of sets Sᵈ, Sᶜ⁻ᵈ, 1 ≤ d ≤ ⌊c/2⌋
      for d in 1:c÷2
        for a in S[d], b in S[c-d]
          valid_sequence = false
          if !any(x -> any(==(x), a), b)
            # Check that each element of S¹ appears
            # at most once in (TᵃTᵇ).
            ab = union(a, b)
            valid_sequence = true
          end
          if d == c-d && _isless(b, a)
            # Also, when d == c-d, check that b > a so that
            # that case (a,b) and (b,a) are not repeated
            valid_sequence = false
          end
          if valid_sequence
            # Determine the cost μ of contracting Tᵃ, Tᵇ
            μ = contraction_cost!(inds_cache, T, dims, a, b, ab)
            if length(a) > 1
              μ += cost_cache[a]
            end
            if length(b) > 1
              μ += cost_cache[b]
            end
            old_cost = get(cost_cache, ab, typemax(Int))
            if μ < old_cost
              cost_cache[ab] = μ
              if length(a) == 1
                sequence_a = only(a)
              else
                sequence_a = sequence_cache[a]
              end
              if length(b) == 1
                sequence_b = only(b)
              else
                sequence_b = sequence_cache[b]
              end
              sequence_cache[ab] = Any[sequence_a, sequence_b]
            end

          end
        end
      end
    end
    return sequence_cache[BitSet(1:n)], cost_cache[BitSet(1:n)]
  end

end # module ContractionSequenceOptimization

