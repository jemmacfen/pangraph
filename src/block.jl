module Blocks

using Rematch

import Base:
    show, length, append!, keys, merge!

# internal modules
using ..Intervals
using ..Nodes
using ..Utility: 
    random_id, contiguous_trues,
    uncigar, wcpair, Alignment,
    hamming_align

import ..Graphs:
    pair, reverse_complement, 
    sequence, sequence!

# exports
export SNPMap, InsMap, DelMap # aux types
export Block 
export combine, swap!, check  # operators

# ------------------------------------------------------------------------
# utility types

Maybe{T} = Union{T,Nothing}

# aliases
const SNPMap = Dict{Int,UInt8}
const InsMap = Dict{Tuple{Int,Int},Array{UInt8,1}} 
const DelMap = Dict{Int,Int} 

const AlleleMaps{T} = Union{Dict{Node{T},SNPMap},Dict{Node{T},InsMap},Dict{Node{T},DelMap}} 

show(io::IO, m::SNPMap) = show(io, [ k => Char(v) for (k,v) in m ])
show(io::IO, m::InsMap) = show(io, [ k => String(Base.copy(v)) for (k,v) in m ])

# ------------------------------------------------------------------------
# utility functions

function applyalleles(seq, mutate, insert, delete)
    len = length(seq) - reduce(+,values(delete);init=0) + reduce(+,length(v) for v in values(insert);init=0)
    len ≤ 0 && return UInt8[]

    new = Array{UInt8,1}(undef, len)

    r = 1  # leading edge of read  position
    w = 1  # leading edge of write position
    for locus in allele_positions(mutate, insert, delete)
        δ = first(locus.pos) - r
        if δ > 0
            new[w:w+δ-1] = seq[r:r+δ-1]
            r += δ
            w += δ
        end

        @match locus.kind begin
            :snp => begin
                new[w] = mutate[locus.pos]
                w += 1
                r += 1
            end
            :ins => begin
                ins = insert[locus.pos]
                len = length(ins)
                new[w:w+len-1] = ins
                w += len
            end
            :del => begin
                r += delete[locus.pos] 
            end
              _  => error("unrecognized locus kind")
        end
    end

    if r <= length(seq)
        @assert (length(seq) - r) == (length(new) - w)
        new[w:end] = seq[r:end]
    else
        @assert r == length(seq) + 1 
        @assert w == length(new) + 1
    end

    return new
end

mutable struct Pos
    start::Int
    stop::Int
end

Base.to_index(x::Pos) = x.start:x.stop
advance!(x::Pos)      = x.start=x.stop
copy(x::Pos)          = Pos(x.start,x.stop)

mutable struct PairPos
    qry::Maybe{Pos}
    ref::Maybe{Pos}
end

# TODO: relax hardcoded reliance on cigar suffixes. make symbols instead
const PosPair = NamedTuple{(:qry, :ref), Tuple{Maybe{Pos}, Maybe{Pos}}} 
function partition(alignment; minblock=500)
    qry = Pos(1,1)
    ref = Pos(1,1)

    block   = NamedTuple{(:range, :segment), Tuple{PosPair, Array{PosPair,1}}}[]
    segment = PosPair[]  # segments of current block being constructed

    # ----------------------------
    # internal operators
    
    function finalize_block!()
        length(segment) == 0 && @goto advance

        push!(block, (
            range   = (
                qry = Pos(qry.start,qry.stop-1), 
                ref = Pos(ref.start,ref.stop-1)
            ),
            segment = segment
        ))

        segment = PosPair[]
        
        @label advance
        advance!(qry)
        advance!(ref)
    end

    function qry_block!(pos)
        push!(block, (
            range   = (
                qry = pos,
                ref = nothing
            ),
            segment = PosPair[]
         ))
    end

    function ref_block!(pos)
        push!(block, (
            range   = (
                qry = nothing,
                ref = pos,
            ),
            segment = PosPair[]
         ))
    end

    # ----------------------------
    # see if blocks have a leading unmatched block

    if alignment.qry.start > 1
        qry_block!(Pos(1,alignment.qry.start-1))
        qry = Pos(alignment.qry.start,alignment.qry.start)
    end

    if alignment.ref.start > 1
        ref_block!(Pos(1, alignment.ref.start-1))
        ref = Pos(alignment.ref.start,alignment.ref.start)
    end
    
    # ----------------------------
    # parse cigar within region of overlap
    
    for (len, type) ∈ uncigar(alignment.cigar)
        @match type begin
        'S' || 'H' => begin
            # XXX:  treat soft clips differently?
            # TODO: implement
            error("need to implement soft/hard clipping")
        end
        'M' => begin
            r = Pos(ref.stop-ref.start+1, ref.stop-ref.start+len)
            q = Pos(qry.stop-qry.start+1, qry.stop-qry.start+len)

            push!(segment, (qry=q, ref=r))

            qry.stop += len
            ref.stop += len
        end
        'D' => begin
            if len >= minblock
                finalize_block!()

                ref_block!(Pos(ref.start,ref.stop+len-1))

                ref.stop += len
                advance!(ref)
            else
                push!(segment, (qry=nothing,ref=Pos(ref.stop-ref.start+1, ref.stop-ref.start+len)))
                ref.stop += len
            end
        end
        'I' => begin
            if len >= minblock
                finalize_block!()

                qry_block!(Pos(qry.start,qry.stop+len-1))

                qry.stop += len
                advance!(qry)
            else
                push!(segment, (qry=Pos(qry.stop-qry.start+1,qry.stop-qry.start+len),ref=nothing))
                qry.stop += len
            end
        end
         _  => error("unrecognized cigar string suffix")
        end
    end

    finalize_block!()

    # ----------------------------
    # see if blocks have a trailing unmatched block

    if alignment.qry.stop < alignment.qry.length
        qry_block!(Pos(alignment.qry.stop,alignment.qry.length))
    end

    if alignment.ref.stop < alignment.ref.length
        ref_block!(Pos(alignment.ref.stop,alignment.ref.length))
    end

    return block
end

# ------------------------------------------------------------------------
# Block data structure

mutable struct Block
    uuid     :: String
    sequence :: Array{UInt8}
    gaps     :: Dict{Int,Int}
    mutate   :: Dict{Node{Block},SNPMap}
    insert   :: Dict{Node{Block},InsMap}
    delete   :: Dict{Node{Block},DelMap}
end

function show(io::IO, m::Dict{Node{Block}, T}) where T <: Union{SNPMap, InsMap, DelMap}
    print(io, "{\n")
    for (k,v) in m
        print(io, "\t", k, " => {")
        show(io, v)
        print(io, "}\n")
    end
    print(io, "}\n")
end

# ---------------------------
# constructors

# simple helpers
Block(sequence,gaps,mutate,insert,delete) = Block(random_id(),sequence,gaps,mutate,insert,delete)
Block(sequence) = Block(sequence,Dict{Int,Int}(),Dict{Node{Block},SNPMap}(),Dict{Node{Block},InsMap}(),Dict{Node{Block},DelMap}())
Block()         = Block(UInt8[])

# move alleles
translate(d::Dict{Int,Int}, δ) = Dict(x+δ => v for (x,v) ∈ d) # gaps
translate(d::Dict{Node{Block},InsMap}, δ) = Dict(n => Dict((x+δ,Δ) => v for ((x,Δ),v) ∈ val) for (n,val) ∈ d) # insertions 
translate(dict::T, δ) where T <: AlleleMaps{Block} = Dict(key=>Dict(x+δ => v for (x,v) in val) for (key,val) in dict)

# select alleles within window
lociwithin(dict::T, i) where T <: AlleleMaps{Block} = Dict(
    node => filter((p) -> (i.start ≤ first(first(p)) ≤ i.stop), subdict) 
        for (node, subdict) ∈ dict
)
lociwithin(dict::Dict{Node{Block},DelMap}, i) = Dict(
    node => DelMap(
        locus => min(len, i.stop-locus+1) for (locus, len) in subdict if i.start ≤ locus ≤ i.stop
    ) for (node, subdict) ∈ dict
)

lociwithin(dict::Dict{Int,Int}, i) = Dict(x => v for (x,v) ∈ dict if i.start ≤ x ≤ i.stop)

# merge alleles (recursively)
function merge!(base::T, others::T...) where T <: AlleleMaps{Block}
    # keys not found in base
    for node ∈ Set(k for other in others for k ∈ keys(other) if k ∉ keys(base))
        base[node] = merge((other[node] for other in others if node ∈ keys(other))...)
    end

    # keys found in base
    for node ∈ keys(base)
        merge!(base[node], (other[node] for other in others if node ∈ keys(other))...)
    end

    return base
end

# TODO: rename to concatenate?
# serial concatenate list of blocks
function Block(bs::Block...)
    sequence = vcat((b.sequence for b in bs)...)

    # XXX: should we copy here so as to not mutate bs[1]?
    gaps   = bs[1].gaps
    mutate = bs[1].mutate
    insert = bs[1].insert
    delete = bs[1].delete

    δ = length(bs[1])
    for b in bs[2:end]
        merge!(gaps,   translate(b.gaps,   δ))
        merge!(mutate, translate(b.mutate, δ))
        merge!(insert, translate(b.insert, δ))
        merge!(delete, translate(b.delete, δ))

        δ += length(b)
    end

    return Block(sequence,gaps,mutate,insert,delete)
end

# TODO: rename to slice?
# returns a subslice of block b
function Block(b::Block, slice)
    if (slice.start == 1 && slice.stop == length(b))
        Block(b.sequence,b.gaps,b.mutate,b.insert,b.delete)
    end
    @assert slice.start >= 1 && slice.stop <= length(b)

    sequence = b.sequence[slice]
    subslice(dict, i) = translate(lociwithin(dict,i), 1-i.start)

    gaps = Dict(x-slice.start+1 => δ for (x,δ) ∈ b.gaps if slice.start ≤ x ≤ slice.stop)

    mutate = subslice(b.mutate, slice)
    insert = subslice(b.insert, slice)
    delete = subslice(b.delete, slice)

    return Block(sequence,gaps,mutate,insert,delete)
end

# ---------------------------
# operations

# simple operations
depth(b::Block) = length(b.mutate)
pair(b::Block)  = b.uuid => b

show(io::IO, b::Block) = show(io, (id=b.uuid, depth=depth(b)))

length(b::Block) = length(b.sequence)
length(b::Block, n::Node) = (length(b)
                          + reduce(+, length(i) for i in values(b.insert[n]); init=0)
                          - reduce(+, values(b.delete[n]); init=0))

keys(b::Block) = keys(b.mutate)

# internal structure to allow us to sort all allelic types
Locus = Union{
    NamedTuple{(:pos, :kind), Tuple{Int, Symbol}},
    NamedTuple{(:pos, :kind), Tuple{Tuple{Int,Int}, Symbol}},
}

islesser(a::Int, b::Int)                       = isless(a, b)
islesser(a::Tuple{Int,Int}, b::Int)            = isless(first(a), b)
islesser(a::Int, b::Tuple{Int,Int})            = isless(a, first(b)) || a == first(b) # deletions get priority if @ equal locations
islesser(a::Tuple{Int,Int}, b::Tuple{Int,Int}) = isless(a, b)

islesser(a::Locus, b::Locus) = islesser(a.pos, b.pos)

function allele_positions(snp::SNPMap, ins::InsMap, del::DelMap)
    keys(dict, sym) = [(pos=key, kind=sym) for key in Base.keys(dict)]
    loci = [keys(snp,:snp); keys(ins,:ins); keys(del,:del)]
    sort!(loci, lt=islesser)

    return loci
end
allele_positions(b::Block, n::Node) = allele_positions(b.mutate[n], b.insert[n], b.delete[n])

# complex operations
function reverse_complement(b::Block)
    seq = reverse_complement(b.sequence)
    len = length(seq)

    revcmpl(dict::SNPMap) = Dict(len-locus+1:wcpair[nuc]  for (locus,nuc) in dict)
    revcmpl(dict::DelMap) = Dict(len-locus+1:del for (locus,del) in dict)
    revcmpl(dict::InsMap) = Dict((len-locus+1,b.gaps[locus]-off+1):reverse_complement(ins) for ((locus,off),ins) in dict)

    mutate = Dict(node => revcmpl(snp) for (node, snp) in b.mutate)
    insert = Dict(node => revcmpl(ins) for (node, ins) in b.insert)
    delete = Dict(node => revcmpl(del) for (node, del) in b.delete)
    gaps   = Dict(node => revcmpl(gap) for (node, gap) in b.gaps)

    return Block(seq,gaps,mutate,insert,delete)
end

function sequence(b::Block; gaps=false)
    !gaps && return b.sequence
    
    len = length(b) + sum(values(b.gaps))
    seq = Array{UInt8}(undef, len)

    l, iₛ = 1, 1
    for r in sort(collect(keys(b.gaps)))
        len = r - l
        seq[iₛ:iₛ+len] = b.sequence[l:r]

        iₛ += len + 1
        len = b.gaps[r]
        seq[iₛ:iₛ+len-1] .= UInt8('-')

        l   = r + 1
        iₛ += len
    end

    seq[iₛ:end] = b.sequence[l:end]

    return seq
end

function sequence_gaps!(seq, b::Block, node::Node{Block})
    ref = sequence(b; gaps=true)
    @assert length(seq) == length(ref)

    loci = allele_positions(b, node) 
    Ξ(x) = x + reduce(+,(δ for (l,δ) in b.gaps if l < x); init=0)

    for l in loci
        @match l.kind begin
            :snp => begin
                x         = l.pos
                seq[Ξ(x)] = b.mutate[node][x]
            end
            :ins => begin
                ins = b.insert[node][l.pos]
                len = length(ins)

                x = Ξ(l.pos[1]) # NOTE: insertion occurs 1 nt AFTER the key position
                δ = l.pos[2]

                seq[x+δ+1:x+len+δ] = ins
            end
            :del => begin
                len = b.delete[node][l.pos]
                x   = Ξ(l.pos )

                seq[x:x+len-1] .= UInt8('-')
            end
              _  => error("unrecognized locus kind")
        end
    end

    return seq
end

function sequence_gaps(b::Block, node::Node{Block})
    len = length(b) + sum(values(b.gaps)) # TODO: make alignment_length function?
    seq = Array{UInt8}(undef, len)

    sequence_gaps!(seq, b, node)

    return seq
end

# returns the sequence WITH mutations and indels applied to the consensus for a given tag 
function sequence!(seq, b::Block, node::Node{Block}; gaps=false)
    gaps && return sequence_gaps!(seq, b, node)

    @assert length(seq) == length(b, node)

    ref = sequence(b; gaps=false)

    pos  = (l) -> isa(l.pos, Tuple) ? l.pos[1] : l.pos # dispatch over different key types
    loci = allele_positions(b, node)

    iᵣ, iₛ = 1, 1
    for l in loci
        if (δ = pos(l) - iᵣ) >= 0
            seq[iₛ:iₛ+δ-1] = ref[iᵣ:pos(l)-1]
            iₛ += δ
        end

        @match l.kind begin
            :snp => begin
                seq[iₛ] = b.mutate[node][l.pos]
                iₛ += 1
                iᵣ += δ + 1
            end
            :ins => begin
                # NOTE: insertions are indexed by the position they follow.
                #       since we stop 1 short, we finish here before continuing insertion.
                if δ >= 0
                    seq[iₛ] = ref[pos(l)]
                    iₛ += 1
                end

                ins = b.insert[node][l.pos]
                len = length(ins)

                seq[iₛ:iₛ+len-1] = ins

                iₛ += len
                iᵣ  = pos(l) + 1
            end
            :del => begin
                # NOTE: deletions index the first position of the deletion. 
                #       this is the reason we stop 1 short above
                iᵣ = l.pos + b.delete[node][l.pos]
            end
              _  => error("unrecognized locus kind")
        end
    end

    seq[iₛ:end] = ref[iᵣ:end]

    return seq
end

function sequence(b::Block, node::Node{Block}; gaps=false)
    seq = gaps ? sequence(b; gaps=true) : Array{UInt8}('-'^length(b, node))
    sequence!(seq, b, node; gaps=gaps)
    return seq
end

function gapconsensus(b::Block, x::Int)
    x ∉ keys(b.gaps) && error("invalid index for gap")

    len = b.gaps[x]
    num = sum(1 for insert in values(b.insert) for locus in keys(insert) if first(locus) == x; init=0)
    @assert num > 0

    aln = fill(UInt8('-'), (num, len))

    i = 1
    for node in keys(b)
        for (locus, ins) in b.insert[node]
            first(locus) != x && continue

            aln[i, last(locus)+1:last(locus)+length(ins)] = ins
            i += 1
            break
        end

        i == num + 1 && break
    end

    trymode(data) = length(data) > 0 ? mode(data) : UInt8('-')

    return [ trymode(filter((c) -> c != UInt8('-'), col)) for col in eachcol(aln) ]
end

function append!(b::Block, node::Node{Block}, snp::Maybe{SNPMap}, ins::Maybe{InsMap}, del::Maybe{DelMap})
    @assert node ∉ keys(b)

    if isnothing(snp)
        snp = SNPMap()
    end

    if isnothing(ins)
        ins = InsMap()
    end

    if isnothing(del)
        del = DelMap()
    end

    b.mutate[node] = snp
    b.insert[node] = ins
    b.delete[node] = del
end

function swap!(b::Block, oldkey::Node{Block}, newkey::Node{Block})
    b.mutate[newkey] = pop!(b.mutate, oldkey)
    b.insert[newkey] = pop!(b.insert, oldkey)
    b.delete[newkey] = pop!(b.delete, oldkey)
end

function swap!(b::Block, oldkey::Array{Node{Block}}, newkey::Node{Block})
    mutate = pop!(b.mutate, oldkey[1])
    insert = pop!(b.insert, oldkey[1])
    delete = pop!(b.delete, oldkey[1])

    for key in oldkey[2:end]
        merge!(mutate, pop!(b.mutate, key))
        merge!(insert, pop!(b.insert, key))
        merge!(delete, pop!(b.delete, key))
    end

    b.mutate[newkey] = mutate
    b.insert[newkey] = insert
    b.delete[newkey] = delete 
end

function reconsensus!(b::Block)
    # NOTE: no point to compute this for blocks with 1 or 2 individuals
    depth(b) <= 2 && return false 

    # NOTE: we can't assume that keys(b) will return the same order on subsequent calls
    #       thus we collect into array here for a static ordering of the nodes
    nodes = collect(keys(b))

    ref = sequence(b; gaps=true)
    aln = Array{UInt8}(undef, length(ref), depth(b))
    for (i,node) in enumerate(nodes)
        aln[:,i] = ref
        sequence!(view(aln,:,i), b, node; gaps=true)
    end

    consensus = [mode(view(aln,i,:)) for i in 1:size(aln,1)]
    if all(consensus .== ref) # hot path: if consensus sequence did not change, abort!
        return false
    end

    isdiff = (aln .!= consensus)
    refdel = (consensus .== UInt8('-'))
    alndel = (aln .== UInt8('-'))

    δ = (
        snp = isdiff .& .!refdel .& .!alndel,
        del = isdiff .& .!refdel .&   alndel,
        ins = isdiff .&   refdel .& .!alndel,
    )

    coord   = cumsum(.!refdel)

    refgaps = contiguous_trues(refdel)
    b.gaps  = Dict{Int, Int}(coord[gap.lo] => length(gap) for gap in refgaps)
    
    b.mutate = Dict{Node{Block},SNPMap}( 
            node => SNPMap(
                      coord[l] => aln[l,i] 
                for l in findall(δ.snp[:,i])
            )
        for (i,node) in enumerate(nodes)
    )

    b.delete = Dict{Node{Block},DelMap}( 
            node => DelMap(
                      coord[del.lo] => length(del)
                for del in contiguous_trues(δ.del[:,i])
             )
        for (i,node) in enumerate(nodes)
    )

    Δ(I) = (R = containing(refgaps, I)) == nothing ? 0 : I.lo - R.lo
    b.insert = Dict{Node{Block},InsMap}( 
            node => InsMap(
                      (coord[ins.lo],Δ(ins)) => aln[ins,i] 
                for ins in contiguous_trues(δ.ins[:,i])
             )
        for (i,node) in enumerate(nodes)
    )

    b.sequence = consensus[.!refdel]
    
    @assert all(all(k ≤ length(b.sequence) for k in keys(d)) for d in values(b.mutate)) 
    @assert all(all(k ≤ length(b.sequence) for k in keys(d)) for d in values(b.delete)) 
    @assert all(all(k[1] ≤ length(b.sequence) for k in keys(d)) for d in values(b.insert)) 

    return true
end

# TODO: align consensus sequences within overlapping gaps of qry and ref.
#       right now we parsimoniously stuff all sequences at the beginning of gaps
#       problems:
#           -> independent of alignability
#           -> errors accrue over time
#       this would entail allowing the reference alleles to change!
function rereference(qry::Block, ref::Block, segments)
    combined = (
        gaps   = ref.gaps,
        mutate = ref.mutate,
        insert = ref.insert,
        delete = ref.delete,
    )

    map(dict, from, to) = translate(lociwithin(dict, from), to.start-from.start)

    x = (qry = 1, ref = 1)
    newgaps = Tuple{Int,Int}[]
    for segment in segments
        @match (segment.qry, segment.ref) begin
            (nothing, Δ) => begin # sequence in ref consensus not found in qry consensus
                if (x.qry-1) ∈ keys(qry.gaps) # some insertions in qry have overlapping sequence with ref
                    # TODO: allow for (-) hamming alignments
                    gap = gapconsensus(qry, x.qry-1)
                    pos = hamming_align(ref.sequence[Δ], gap)-1
                    newgap = (Δ.stop, 0)
                    for node ∈ keys(qry)
                        unmatched = IntervalSet((x.ref, x.ref+Δ.stop-Δ.start+1))
                        delkeys = Tuple{Int,Int}[]
                        for ((locus,δ),ins) ∈ qry.insert[node]
                            locus != x.qry-1 && continue

                            push!(delkeys, (locus,δ))

                            start = Δ.start + pos + δ
                            stop  = start + length(ins) - 1
                            if 0 ≤ start ≤ Δ.stop 
                                overhang = stop - Δ.stop # right overhang
                                if overhang > 0 
                                    combined.insert[node][(Δ.stop,0)] = ins[end-overhang+1:end] 
                                    newlen = length(ins[end-overhang+1:end] )
                                    if newlen > last(newgap)
                                        newgap = (Δ.stop, newlen)
                                    end
                                end
                                unmatched = unmatched \ Interval(start, stop+1)
                            elseif start > Δ.stop # we are (right) beyond the matched section, add the remainder as an insertion
                                combined.insert[node][(Δ.stop,start-Δ.stop-1)] = ins
                                newlen = start-Δ.stop+1+length(ins) 
                                if newlen > last(newgap)
                                    newgap = (Δ.stop, newlen)
                                end
                            else # TODO: negative matching
                                error("need to implement")
                            end
                        end

                        for key in delkeys
                            delete!(qry.insert[node], key)
                        end

                        for I in unmatched
                            merge!(combined.delete, Dict(node => Dict(I.lo=>length(I))))
                        end
                    end

                    if last(newgap) > 0
                        push!(newgaps, newgap)
                    end
                else
                    newdeletes = Dict(
                        node => Dict(x.ref=>Δ.stop-Δ.start+1) for node ∈ keys(qry)
                    )
                    merge!(combined.delete, newdeletes)
                end
                x = (qry=x.qry, ref=Δ.stop+1)
            end
            (Δ, nothing) => begin # sequence in qry consensus not found in ref consensus
                mutate = translate(lociwithin(qry.mutate,Δ),1-Δ.start)
                insert = translate(lociwithin(qry.insert,Δ),1-Δ.start)
                delete = translate(lociwithin(qry.delete,Δ),1-Δ.start)

                if (x.ref-1) ∈ keys(ref.gaps) # some sequences in ref have overlapping sequence with qry
                    δ = hamming_align(qry.sequence[Δ], gapconsensus(ref, x.ref-1)) - 1
                else # novel for all qry sequences. apply alleles to consensus and store as insertion
                    δ = 0
                end

                newgap = (x.ref-1, 0)
                newinserts = Dict(let
                    seq = applyalleles(qry.sequence[Δ], mutate[node], insert[node], delete[node])
                    if length(seq) > 0
                        if length(seq) > last(newgap)
                            newgap = (x.ref-1,length(seq)+δ)
                        end
                        node => Dict((x.ref-1,δ) => seq) 
                    else
                        node => InsMap()
                    end
                    end for node ∈ keys(qry)
                )

                if length(newgap) > 0
                    push!(newgaps, newgap)
                end

                merge!(combined.insert, newinserts)

                x = (qry=Δ.stop+1, ref=x.ref)
            end
            (Δq, Δr) => begin # simple translation of alleles of qry -> ref
                merge!(combined.mutate, map(qry.mutate,Δq,Δr))
                merge!(combined.delete, map(qry.delete,Δq,Δr))
                let
                    inserts  = map(qry.insert,Δq,Δr)
                    # TODO: check if insertion at this location exists!
                    #       if so, we need to align the insertions
                    append!(newgaps, (k,v) for (k,v) ∈ map(qry.gaps,Δq,Δr))
                    merge!(combined.insert, inserts)
                end

                x = (qry=Δq.stop+1, ref=Δr.stop+1)
            end
            _ => error("unrecognized segment")
        end
    end

    for (pos, len) in newgaps
        if pos ∈ keys(combined.gaps)
            combined.gaps[pos] = max(len, combined.gaps[pos])
        else
            combined.gaps[pos] = len
        end
    end

    new = Block(
        ref.sequence,
        combined.gaps,
        combined.mutate,
        combined.insert,
        combined.delete
    )

    #=
    check(new; ids=false)

    @assert all(all(k ≤ length(new.sequence) for k in keys(d)) for d in values(new.mutate)) 
    @assert all(all(k ≤ length(new.sequence) for k in keys(d)) for d in values(new.delete)) 
    @assert all(all(k[1] ≤ length(new.sequence) for k in keys(d)) for d in values(new.insert)) 
    =#

    return new
end


function combine(qry::Block, ref::Block, aln::Alignment; minblock=500)
    blocks   = NamedTuple{(:block,:kind),Tuple{Block,Symbol}}[]
    segments = partition(aln; minblock=minblock) # this enforces that indels are less than minblock!

    for (range, segment) ∈ segments
        @match (range.qry, range.ref) begin
            ( nothing, Δ )  => begin
                push!(blocks, (block=Block(ref, Δ), kind=:ref))
            end
            ( Δ, nothing ) => begin
                push!(blocks, (block=Block(qry, Δ), kind=:qry))
            end
            ( Δq, Δr )      => begin
                @assert length(segment) > 0

                # slice both blocks to window of overlap
                r = Block(ref, Δr)
                q = Block(qry, Δq)

                new = rereference(q, r, segment)
                reconsensus!(new)

                push!(blocks, (block=new, kind=:all))
            end
        end
    end

    return blocks
end

function check(b::Block; ids=true)
    @assert !ids || all( n.block == b for n ∈ keys(b) )

    gap = Set(keys(b.gaps))
    ins = Set(first(locus) for insert in values(b.insert) for locus in keys(insert))

    @assert gap == ins

    for node ∈ keys(b)
        for ((x, δ), ins) ∈ b.insert[node]
            if b.gaps[x] < (length(ins) + δ)
                @show b.gaps
                @show b.insert[node]
                @show node
                @show b.gaps[x], (length(ins) + δ)
                @assert false
            end
        end
    end
end

# ------------------------------------------------------------------------
# main point of entry for testing

using Random, Distributions, StatsBase

function generate_alignment(;len=100,num=10,μ=(snp=1e-2,ins=1e-2,del=1e-2),Δ=5)
    ref = Array{UInt8}(random_id(;len=len, alphabet=['A','C','G','T']))
    aln = zeros(UInt8, num, len)

    map = (
        snp = Array{SNPMap}(undef,num),
        ins = Array{InsMap}(undef,num),
        del = Array{DelMap}(undef,num),
    )
    ρ = (
        snp = Poisson(μ.snp*len),
        ins = Poisson(μ.ins*len),
        del = Poisson(μ.del*len),
    )
    n = (
        snp = rand(ρ.snp, num),
        ins = rand(ρ.ins, num),
        del = rand(ρ.del, num),
    )

    for i in 1:num
        aln[i,:] = ref
    end

    # random insertions
    # NOTE: this is the inverse operation as a deletion.
    #       perform operation as a collective.
    inserts = Array{IntervalSet{Int}}(undef, num)

    # first collect all insertion intervals
    for i in 1:num
        inserts[i] = IntervalSet(1, len+1)

        for j in 1:n.ins[i]
            @label getinterval
            start = sample(1:len)
            delta = len-start+1
            stop  = start + min(delta, sample(1:Δ))

            insert = Interval(start, stop)

            if !isdisjoint(inserts[i], insert)
                @goto getinterval # XXX: potential infinite loop
            end

            inserts[i] = inserts[i] ∪ insert
        end
    end

    allinserts = reduce(∪, inserts)

    δ = 1 
    gaps = [begin 
        x  = (I.lo-δ, length(I)) 
        δ += length(I)
        x
    end for I in allinserts]

    for (i, insert) in enumerate(inserts)
        keys = Array{Tuple{Int,Int}}(undef, length(insert))
        vals = Array{Array{UInt8}}(undef, length(insert))
        for (n, a) in enumerate(insert)
            for (j, b) in enumerate(allinserts)
                if a ⊆ b
                    keys[n] = (gaps[j][1], a.lo - b.lo)
                    vals[n] = ref[a]
                    @goto outer
                end
            end
            error("failed to find containing interval!")
            @label outer
        end

        map.ins[i] = InsMap(zip(keys,vals))

        # delete non-overlapping regions
        for j in allinserts \ insert
            aln[i,j] .= UInt8('-')
        end
    end

    idx = collect(1:len)[~allinserts]
    ref = ref[~allinserts]

    for i in 1:num
        index = collect(1:length(idx))
        deleteat!(index, findall(aln[i,idx] .== UInt8('-')))

        # random deletions
        # NOTE: care must be taken to ensure that they don't overlap or merge
        loci = Array{Int}(undef, n.del[i])
        dels = Array{Int}(undef, n.del[i])

        for j in 1:n.del[i]
            @label tryagain
            loci[j] = sample(index)

            while aln[i,max(1, idx[loci[j]]-1)] == UInt8('-')
                loci[j] = sample(index)
            end

            x = idx[loci[j]]

            offset = findfirst(aln[i,x:end] .== UInt8('-'))
            maxgap = isnothing(offset) ? (len-x+1) : (offset-1)

            dels[j] = min(maxgap, sample(1:Δ))

            # XXX: this is a hack to ensure deletions and insertions don't overlap
            if !all(item ∈ idx for item in x:x+dels[j]-1)
                @goto tryagain
            end

            aln[i,x:(x+dels[j]-1)] .= UInt8('-')
            filter!(i->i ∉ loci[j]:(loci[j]+dels[j]-1), index)
        end

        map.del[i] = DelMap(zip(loci,dels))
        
        # random single nucleotide polymorphisms
        # NOTE: we exclude the deleted regions
        loci = sample(index, n.snp[i]; replace=false)
        snps = sample(UInt8['A','C','G','T'], n.snp[i])
        redo = findall(ref[loci] .== snps)

        while length(redo) >= 1
            snps[redo] = sample(UInt8['A','C','G','T'], length(redo))
            redo = findall(ref[loci] .== snps)
        end

        for (locus,snp) in zip(loci,snps)
            aln[i,idx[locus]] = snp
        end

        map.snp[i] = SNPMap(zip(loci,snps))
    end

    return ref, aln, Dict(gaps), map
end

function verify(blk, node, aln)
    local pos = join(["$(i)" for i in 1:10:101], ' '^8)
    local tic = join(["|" for i in 1:10:101], '.'^9)

    ok = true
    for i in 1:size(aln,1)
        seq  = sequence(blk,node[i];gaps=true)
        if size(aln,2) != length(seq)
            println("failure on row $(i), node $(node[i])")
            println("incorrect size!")
            ok = false
            break
        end

        good = aln[i,:] .== seq
        if !all(good)
            ok = false

            err        = copy(seq)
            err[good] .= ' '

            println("failure on row $(i), node $(node[i])")
            println("Loci: ", pos)
            println("      ", tic)
            println("Ref:  ", String(copy(sequence(blk; gaps=true))))
            println("True: ", String(copy(aln[i,:])))
            println("Estd: ", String(copy(seq)))
            println("Diff: ", String(err))
            println("SNPs: ", blk.mutate[node[i]])
            println("Dels: ", blk.delete[node[i]])
            println("Ints: ", blk.insert[node[i]])
            break
        end
        seq  = sequence(blk,node[i];gaps=false)
    end

    return ok
end

function test()
    ref, aln, gap, map = generate_alignment()

    blk = Block(ref)
    blk.gaps = gap

    node = [Node{Block}(blk,true) for i in 1:size(aln,1)]
    for i in 1:size(aln,1)
        append!(blk, node[i], map.snp[i], map.ins[i], map.del[i])
    end

    ok = verify(blk, node, aln)
    if !ok
        error("failure to initialize block correctly")
    end

    reconsensus!(blk)

    ok = verify(blk, node, aln)
    if !ok
        error("failure to reconsensus block correctly")
    end

    return ok 
end

end
