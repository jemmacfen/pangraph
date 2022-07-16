KERNELS = ["mmseqs", "minimap10", "minimap20"]
HGT = [1e-2, 5e-2, 1e-1, 5e-1, 1]
SNPS = [
    0,
    1e-4,
    2e-4,
    3e-4,
    4e-4,
    5e-4,
    6e-4,
    7e-4,
    8e-4,
    9e-4,
    1e-3,
    2e-3,
    3e-3,
    4e-3,
    5e-3,
    6e-3,
    7e-3,
    8e-3,
    9e-3,
    1e-2,
]
SNPS_accplot = [0, 2e-4, 4e-4, 8e-4, 1e-3, 2e-3, 4e-3, 6e-3, 8e-3, 1e-2]
Ntrials = 25
TRIALS = list(range(1, Ntrials + 1))

# pangraph project folder
pgf = "./.."

ker_opt = {
    "mmseqs": "-k mmseqs",
    "minimap10": "-k minimap2 -s 10",
    "minimap20": "-k minimap2 -s 20",
}


rule all:
    input:
        expand("figs/paper-accuracy-{kernel}.png", kernel=list(ker_opt.keys())),
        "figs/paper-accuracycomp.pdf",


rule generate_data:
    message:
        "generating pangraph with hgt = {wildcards.hgt}, snps = {wildcards.snps}, n = {wildcards.n}"
    output:
        graph="synthetic_data/generated/{hgt}_{snps}/known_{n}.json",
        seqs="synthetic_data/generated/{hgt}_{snps}/seqs_{n}.fa",
    params:
        N=100,
        T=50,
        L=50000,
        pgf=pgf,
    shell:
        """
        julia -t 1 --project=. make-sequence.jl -N {params.N} -L {params.L} \
        | julia -t 1 --project={params.pgf} {params.pgf}/src/PanGraph.jl generate \
            -m {wildcards.snps} -r {wildcards.hgt} -t {params.T} -i "1e-2" \
            -o {output.graph} > {output.seqs}
        """


ruleorder: guess_pangraph_mmseqs > guess_pangraph


rule guess_pangraph:
    message:
        """
        reconstructing pangraph with kernel {wildcards.kernel}
        hgt = {wildcards.hgt}, snps = {wildcards.snps}, n = {wildcards.n}
        """
    input:
        rules.generate_data.output.seqs,
    output:
        "synthetic_data/{kernel}/{hgt}_{snps}/guess_{n}.json",
    params:
        ker=lambda w: ker_opt[w.kernel],
        pgf=pgf,
    shell:
        """
        julia -t 1 --project={params.pgf} {params.pgf}/src/PanGraph.jl build \
            --circular -a 0 -b 0 {params.ker} {input} > {output}
        """


rule guess_pangraph_mmseqs:
    message:
        """
        reconstructing pangraph with kernel mmseqs
        hgt = {wildcards.hgt}, snps = {wildcards.snps}, n = {wildcards.n}
        """
    input:
        rules.generate_data.output.seqs,
    output:
        "synthetic_data/mmseqs/{hgt}_{snps}/guess_{n}.json",
    params:
        ker=ker_opt["mmseqs"],
        pgf=pgf,
    conda:
        "../cluster/pangraph_build_env.yml"
    shell:
        """
        julia -t 8 --project={params.pgf} {params.pgf}/src/PanGraph.jl build \
            --circular -a 0 -b 0 {params.ker} {input} > {output}
        """


rule single_accuracy:
    message:
        """
        generating partial accuracy database for:
        kernel = {wildcards.kernel} hgt = {wildcards.hgt}, snps = {wildcards.snps}
        """
    input:
        known=expand(
            "synthetic_data/generated/{{hgt}}_{{snps}}/known_{n}.json", n=TRIALS
        ),
        guess=expand(
            "synthetic_data/{{kernel}}/{{hgt}}_{{snps}}/guess_{n}.json", n=TRIALS
        ),
    output:
        temp("synthetic_data/{kernel}/{hgt}_{snps}/partial_accuracy.jld2"),
    shell:
        """
        julia -t 1 --project=. make-accuracy.jl {output} {input}
        """


rule accuracy_database:
    message:
        "generating accuracy database for kernel {wildcards.kernel}"
    input:
        expand(
            "synthetic_data/{{kernel}}/{hgt}_{snps}/partial_accuracy.jld2",
            hgt=HGT,
            snps=SNPS,
        ),
    output:
        "synthetic_data/results/accuracy-{kernel}.jld2",
    shell:
        """
        julia -t 1 --project=. concatenate-database.jl {output} {input}
        """


rule accuracy_plots:
    message:
        "generating accuracy plot for kernel {wildcards.kernel}"
    input:
        rules.accuracy_database.output,
    output:
        "figs/cdf-accuracy-{kernel}.png",
        "figs/heatmap-accuracy-{kernel}.png",
        "figs/paper-accuracy-{kernel}.png",
        "figs/paper-accuracy-{kernel}.pdf",
    params:
        snps=SNPS_accplot,
    shell:
        """
        julia -t 1 --project=. plot-accuracy.jl {input} figs {params.snps}
        """


rule accuracy_comparison_plots:
    message:
        "generating accuracy comparison plots"
    input:
        expand("synthetic_data/results/accuracy-{kernel}.jld2", kernel=KERNELS),
    output:
        "figs/paper-accuracycomp.pdf",
        "figs/paper-accuracycomp-mutdens.pdf",
        "figs/paper-accuracycomp-scatter.pdf",
    shell:
        """
        julia -t 1 --project=. plot-accuracy-comparison.jl figs {input}
        """
