Polish = Command(
   "polish",
   "pangraph polish <options> [pangraph.json]",
   "polishes a multiple sequence alignment graph",
   """zero or one pangraph file (native json)
      if no file, reads from stdin
      stream can be optionally gzipped.""",
   [
    Arg(
        Int,
        "maximum length",
        (short="-l", long="--length"),
        "cutoff above which we won't realign",
        typemax(Int),
    ),
   ],
   function(args)
       path = parse(Polish, args)
       length(path) > 1 && return 2

       graph = load(path, Polish)

       if !Shell.havecommand("mafft")
           panic("external command mafft not found. please install before running polish step\n")
       end

       accept = function(blk)
           length(blk) ≤ arg(Polish, "-l") && Graphs.depth(blk) > 1
       end
       Graphs.realign!(graph; accept=accept)

       marshal(stdout, graph; fmt=:json)
       return 0
   end
)