const CACHE_NAME = gensym(:CACHE) # is now a const symbol (not a variable)
is_precompiling() = ccall(:jl_generating_output, Cint, ()) != 0

struct NativeCompilerParams <: AbstractCompilerParams end
export @declare_cache, @snapshot_cache, @reinit_cache

macro declare_cache()
    var = esc(CACHE_NAME) #this will esc variable from our const symbol
    quote
        #const $esc(CACHE_NAME) function esc is executed when macro is executed, not when code is defined
        # dollar sign means will have the value of esc cachename here
        const $var = $IdDict()
    end
end

macro snapshot_cache()
    var = esc(CACHE_NAME)
    quote
        $snapshot_cache($var)
    end
end

macro reinit_cache()
    var = esc(CACHE_NAME)
    quote
        # will need to keep track of this is CUDA so that GPUCompiler caches are not overfilled
        $reinit_cache($var)
    end
end

"""
Given a function and param types caches the function to the global cache
"""
function precompile_gpucompiler(job)
    method_instance, _ = GPUCompiler.emit_julia(job)
    # populate the cache
    cache = GPUCompiler.ci_cache(job)
    mt = GPUCompiler.method_table(job)
    interp = GPUCompiler.get_interpreter(job)
    if GPUCompiler.ci_cache_lookup(cache, method_instance, job.source.world, typemax(Cint)) === nothing
        GPUCompiler.ci_cache_populate(interp, cache, mt, method_instance, job.source.world, typemax(Cint))
    end
end

"""
Reloads Global Cache from global variable which stores the previous
cached results
"""
function reinit_cache(LOCAL_CACHE)
    if !is_precompiling()
        # need to merge caches at the code instance level
        for key in keys(LOCAL_CACHE)
            if haskey(GPUCompiler.GLOBAL_CI_CACHES, key)
                global_cache = GPUCompiler.GLOBAL_CI_CACHES[key]
                local_cache = LOCAL_CACHE[key]
                for (mi, civ) in (local_cache.dict)
                    # add all code instances to global cache
                    # could move truncating code to set index
                    for ci in civ
                        Core.Compiler.setindex!(global_cache, ci, mi)
                    end
                    # truncation cod3
                    gciv = global_cache.dict[mi]
                    # sort by min world age, then make sure no age ranges overlap
                    sort(gciv, by=x->x.min_world)
                    if length(gciv) > 1
                        for (i, ci) in enumerate(gciv[2:end]) # need to figure what iter through
                            if (ci.min_world <= gciv[i].max_world)
                                gciv[i].max_world = ci.min_world - 1
                            end
                        end
                    end
                    # do I need to invalidate again?
                    #invalidate_code_cache(global_cache, mi, gciv[end].max_world)
                end
            else
                # no conflict at cache level
                GPUCompiler.GLOBAL_CI_CACHES[key] = LOCAL_CACHE[key]
            end
        end
    end
end

"""
Takes a snapshot of the current status of the cache

The cache returned is a deep copy with finite world age endings removed
"""
function snapshot_cache(LOCAL_CACHE)
    cleaned_cache_to_save = IdDict()
    for key in keys(GPUCompiler.GLOBAL_CI_CACHES)
        # Will only keep those elements with infinite ranges
        cleaned_cache_to_save[key] = GPUCompiler.CodeCache(GPUCompiler.GLOBAL_CI_CACHES[key])
    end
    global MY_CACHE #technically don't need the global
    #empty insert
    empty!(LOCAL_CACHE)
    merge!(LOCAL_CACHE, cleaned_cache_to_save)
end
