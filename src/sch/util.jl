"""
    unwrap_nested_exception(err::Exception) -> Bool

Extracts the "core" exception from a nested exception."
"""
unwrap_nested_exception(err::CapturedException) =
    unwrap_nested_exception(err.ex)
unwrap_nested_exception(err::RemoteException) =
    unwrap_nested_exception(err.captured)
unwrap_nested_exception(err) = err

"Prepares the scheduler to schedule `thunk`."
function reschedule_inputs!(state, thunk)
    w = get!(()->Set{Thunk}(), state.waiting, thunk)
    scheduled = false
    for input in thunk.inputs
        istask(input) || continue
        push!(get!(()->Set{Thunk}(), state.waiting_data, input), thunk)
        push!(get!(()->Set{Thunk}(), state.dependents, input), thunk)
        if input in state.errored
            set_failed!(state, input, thunk)
            break # TODO: Allow collecting all error'd inputs
        end
        haskey(state.cache, input) && continue
        if (input in state.running) ||
           (input in state.ready) ||
           reschedule_inputs!(state, input)
            push!(w, input)
            scheduled = true
        end
    end
    if isempty(w) && !(thunk in state.errored)
        # Inputs are ready
        push!(state.ready, thunk)
        return true
    else
        return scheduled
    end
end

"Marks `thunk` and all dependent thunks as failed."
function set_failed!(state, origin, thunk=origin)
    thunk in state.errored && return
    push!(state.errored, thunk)
    filter!(x->x!==thunk, state.ready)
    state.cache[thunk] = ThunkFailedException(thunk, origin, state.cache[origin])
    if haskey(state.futures, thunk)
        for future in state.futures[thunk]
            put!(future, state.cache[thunk]; error=true)
        end
        delete!(state.futures, thunk)
    end
    for dep in state.dependents[thunk]
        if haskey(state.waiting, dep)
            pop!(state.waiting, dep)
        end
        set_failed!(state, origin, dep)
    end
end

"Internal utility, useful for debugging scheduler state."
function print_sch_status(state, thunk)
    iob = IOBuffer()
    print_sch_status(iob, state, thunk)
    seek(iob, 0)
    write(stderr, iob)
end
function print_sch_status(io::IO, state, thunk; offset=0, limit=5)
    function status_string(node)
        status = ""
        if node in state.errored
            status *= "E"
        end
        if node in state.ready
            status *= "r"
        elseif node in state.running
            status *= "R"
        elseif haskey(state.cache, node)
            status *= "C"
        else
            status *= "?"
        end
        status
    end
    offset == 0 && print(io, "($(status_string(thunk))) ")
    println(io, "$(thunk.id): $(thunk.f)")
    for input in thunk.inputs
        input isa Thunk || continue
        status = status_string(input)
        if haskey(state.waiting, thunk) && input in state.waiting[thunk]
            status *= "W"
        end
        if haskey(state.waiting_data, input) && thunk in state.waiting_data[input]
            status *= "w"
        end
        if haskey(state.dependents, input) && thunk in state.dependents[input]
            status *= "d"
        end
        if haskey(state.futures, input)
            status *= "f$(length(state.futures[input]))"
        end
        print(io, repeat(' ', offset+2), "($status) ")
        if limit > 0
            print_sch_status(io, state, input; offset=offset+2, limit=limit-1)
        else
            println(io, "…")
        end
    end
end
