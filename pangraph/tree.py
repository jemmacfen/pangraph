import os, sys
import json

from copy import deepcopy

import numpy as np
import matplotlib.pylab as plt

from Bio.Seq import Seq

from .utils import Strand, log, flatten, tryprint, panic
from .graph import Graph

# ------------------------------------------------------------------------
# Global variables

MAXSELFMAPS = 25

# ------------------------------------------------------------------------
# Helper functions

def nodiag(mtx):
    return mtx-np.diag(np.diag(mtx))

def parse(mtx):
    with open(mtx) as fh:
        nrows = int(fh.readline().strip())
        M, r  = np.zeros((nrows, nrows), dtype=float), 0

        del_idxs  = []
        seq_names = []
        for li, line in enumerate(fh):
            e = line.strip().split()
            n = e[0].split('/')[-1][:-3]
            if n not in seq_names:
                seq_names.append(n)
                M[li,:(li+1)] = [float(x) for x in e[1:]]
            else:
                del_idxs.append(li)

    M = np.delete(M, del_idxs, axis=0)
    M = np.delete(M, del_idxs, axis=1)

    # Symmetrize
    M = 1 - M
    M = nodiag(M + M.T)/2

    return M, seq_names

def to_list(dmtx):
    assert len(dmtx.shape) == 2 and dmtx.shape[0] == dmtx.shape[1], "expected a square matrix"

    dlst = []
    for n in range(dmtx.shape[0]):
        dlst.append(list(dmtx[n,:(n+1)]))

    return dlst

# ------------------------------------------------------------------------
# Node and Tree classes

class Node(object):

    # ---------------------------------
    # Internal functions

    def __init__(self, name, parent, dist, children=[]):
        self.name     = name
        self.dist     = dist
        self.parent   = parent
        self.children = children
        self.fapath   = ""
        self.graph    = None

    def __str__(self):
        if self.dist is None:
            return f"{self.name} :: Unknown"
        else:
            return f"{self.name} :: {self.dist:.4f}"

    def __repr__(self):
        return self.__str__()

    # ---------------------------------
    # Static functions

    @classmethod
    def from_dict(cls, d, parent):
        N = Node(d['name'], parent, d['dist'])
        N.children = [Node.from_dict(child, N) for child in d['children']]
        N.fapath = d['fapath']
        N.graph  = Graph.from_dict(d['graph']) if d['graph'] is not None else None

        return N

    # ---------------------------------
    # Class methods

    def is_leaf(self):
        return len(self.children) == 0

    def postorder(self):
        for child in self.children:
            for it in child.postorder():
                yield it
        yield self

    def new_parent(self, parent, dist):
        self.parent = parent
        self.dist   = dist if dist > 0 else 0

    def to_nwk(self, wtr):
        if not self.is_leaf():
            wtr.write("(")
            for i, child in enumerate(self.children):
                if i > 0:
                    wtr.write(",")
                child.to_nwk(wtr)
            wtr.write(")")

        wtr.write(self.name)
        wtr.write(":")
        wtr.write(f"{self.dist:.6f}")

    def to_json(self):
        return {'name'     : self.name,
                'dist'     : self.dist,
                'children' : [ child.to_json() for child in self.children ],
                'fapath'   : self.fapath,
                'graph'    : self.graph.to_dict() if self.graph is not None else None }

class Tree(object):
    # ------------------- 
    # Class constructor
    def __init__(self, bare=False):
        self.root   = Node("ROOT", None, 0) if not bare else None
        self.seqs   = None
        self.leaves = None

    # ------------------- 
    # Static methods

    # Loading from json
    @classmethod
    def from_json(cls, rdr):
        data   = json.load(rdr)
        T      = Tree(bare=True)
        T.root = Node.from_dict(data['tree'], None)

        leafs  = {n.name: n for n in T.get_leafs()}
        T.seqs = {leafs[k]:Seq(v) for k,v in data['seqs'].items()}

        return T

    # our own neighbor joining
    # Biopython implementation is WAY too slow.
    @classmethod
    def nj(cls, mtx, names, verbose=False):
        # -----------------------------
        # internal functions

        def q(D):
            n = D.shape[0]
            Q = (n-2)*D - (np.sum(D,axis=0,keepdims=True) + np.sum(D,axis=1,keepdims=True))
            np.fill_diagonal(Q, np.inf)
            return Q

        def minpair(q):
            i, j = np.unravel_index(np.argmin(q), q.shape)
            qmin = q[i, j]
            if i > j:
                i, j = j, i
            return (i, j), qmin

        def pairdists(D, i, j):
            n  = D.shape[0]
            d1 = .5*D[i,j] + 1/(2*(n-2)) * (np.sum(D[i,:], axis=0) - np.sum(D[j,:], axis=0))
            d2 = D[i,j] - d1

            # remove negative branches while keeping total fixed
            if d1 < 0:
                d2 -= d1
                d1  = 0
            if d2 < 0:
                d1 -= d2
                d2  = 0

            dnew = .5*(D[i,:] + D[j,:] - D[i, j])
            return d1, d2, dnew

        def join(D, debug=False):
            nonlocal idx
            Q = q(D)
            (i, j), qmin = minpair(Q)
            if debug:
                q0min = min(flatten(Q[:]))
                assert abs(qmin-q0min) < 1e-2, f"minimum not found correctly. returned {qmin}, expected {q0min}"
                print(f"{D}\n--> Joining {i} and {j}. d={D[i,j]}")

            node   = Node(f"NODE_{idx:05d}", T.root, None, [T.root.children[i], T.root.children[j]])

            d1, d2, dnew = pairdists(D, i, j)
            node.children[0].new_parent(node, d1)
            node.children[1].new_parent(node, d2)

            D[i, :] = dnew
            D[:, i] = dnew
            D[i, i] = 0
            D = np.delete(D, j, axis=0)
            D = np.delete(D, j, axis=1)
            T.root.children[i] = node
            T.root.children.pop(j)

            idx = idx + 1

            return D

        # -----------------------------
        # body
        assert len(names) == len(set(names)), "non-unique names found"

        T = Tree()
        for name in names:
            T.root.children.append(Node(name, T.root, None, children=[]))
        idx = 0

        while mtx.shape[0] > 2:
            if verbose:
                print(f"--> Matrix size={mtx.shape[0]}. Number of root children={len(T.root.children)}")
            mtx = join(mtx)

        assert mtx.shape[0] == 2
        d = mtx[0, 1]
        T.root.children[0].dist = d/2
        T.root.children[1].dist = d/2

        return T

    # ------------------- 
    # methods 

    def postorder(self):
        return self.root.postorder()

    def get_leafs(self):
        if self.leaves is None:
            self.leaves = [node for node in self.postorder() if node.is_leaf()]

        return self.leaves

    def num_leafs(self):
        if self.leaves is None:
            self.leaves = [node for node in self.postorder() if node.is_leaf()]

        return len(self.leaves)

    def attach(self, seqs):
        leafs = {n.name: n for n in self.get_leafs()}
        self.seqs = {leafs[name]:seq for name,seq in seqs.items()}

    # TODO: move all tryprints to logging 
    def align(self, tmpdir, verbose=False):
        # ---------------------------------------------
        # internal functions
        # Debugging function that will check reconstructed sequence against known real one.
        def check(seqs, G, verbose=False):
            nerror = 0
            uncompressed_length = 0
            for n in self.get_leafs():
                if n.name not in G.seqs:
                    continue

                seq  = seqs[n]
                orig = str(seq[:]).upper()
                tryprint(f"--> Checking {n.name}", verbose=verbose)
                rec  = G.extract(n.name)
                uncompressed_length += len(orig)
                if orig != rec:
                    nerror += 1

                    with open("test.fa", "w+") as out:
                        out.write(f">original\n{orig}\n")
                        out.write(f">reconstructed\n{rec}")

                    for i in range(len(orig)//100):
                        if (orig[i*100:(i+1)*100] != rec[i*100:(i+1)*100]):
                            print("-----------------")
                            print("O:", i, orig[i*100:(i+1)*100])
                            print("G:", i, rec[i*100:(i+1)*100])

                            diffs = [i for i in range(len(rec)) if rec[i] != orig[i]]
                            pos   = [0]
                            blks  = G.seqs[n.name]
                            for b, strand, num in blks:
                                pos.append(pos[-1] + len(G.blks[b].extract(n.name, num)))
                            pos = pos[1:]

                            testseqs = []
                            for b in G.seqs[n.name]:
                                if b[1] == Strand.Plus:
                                    testseqs.append("".join(G.blks[b[0]].extract(n.name, b[2])))
                                else:
                                    testseqs.append("".join(Seq.reverse_complement(G.blks[b[0]].extract(n.name, b[2]))))

                else:
                    tryprint(f"+++ Verified {n.name}", verbose=verbose)

            if nerror == 0:
                tryprint("all sequences correctly reconstructed", verbose=verbose)
                tlength = np.sum([len(x) for x in G.blks.values()])
                tryprint(f"--- total graph length: {tlength}", verbose=verbose)
                tryprint(f"--- total input sequence: {uncompressed_length}", verbose=verbose)
                tryprint(f"--- compression: {uncompressed_length/tlength:1.2f}", verbose=verbose)
            else:
                raise ValueError("bad sequence reconstruction")

        def merge0(node1, node2):
            graph1, fapath1 = node1.graph, node1.fapath
            graph2, fapath2 = node2.graph, node2.fapath

            graph = Graph.fuse(graph1, graph2)
            graph, _ = graph.union(fapath1, fapath2, f"{tmpdir}/{n.name}")

            cutoff = min(graph1.compress_ratio(), graph2.compress_ratio())
            cutoff = max(0, cutoff-.05)
            if (c:=graph.compress_ratio()) < cutoff:
                print(f"SKIPPING {n.name} {c} -- {cutoff}")
                print(f"CHILDREN {n.children[0].name} {n.children[1].name}")
                return None

            for i in range(MAXSELFMAPS):
                tryprint(f"----> merge round {i}", verbose)
                check(self.seqs, graph)
                itr = f"{tmpdir}/{n.name}_iter_{i}"
                with open(f"{itr}.fa", 'w') as fd:
                    graph.write_fasta(fd)
                graph, contin = graph.union(itr, itr, f"{tmpdir}/{n.name}_iter_{i}")
                if not contin:
                    return graph

        def merge1(node, p):
            g1 = merge0(node, p.children[0])
            g2 = merge0(node, p.children[1])
            if g1 and g2:
                if g1.compress_ratio(extensive=True) > g2.compress_ratio(extensive=True):
                    return g1
                return g2
            elif g1:
                return g1
            return g2

        # --------------------------------------------
        # body

        if self.num_leafs() == 1:
            return Graph()

        for i, n in enumerate(self.get_leafs()):
            seq      = self.seqs[n]
            n.graph  = Graph.from_seq(n.name, str(seq).upper())
            n.fapath = f"{tmpdir}/{n.name}"
            tryprint(f"------> Outputting {n.fapath}", verbose=verbose)
            with open(f"{n.fapath}.fa", 'w') as fd:
                n.graph.write_fasta(fd)

        nnodes = 0
        for n in self.postorder():
            if n.is_leaf():
                continue
            nnodes += 1

            n.fapath = f"{tmpdir}/{n.name}"
            log(f"Attempting to fuse {n.children[0].name} with {n.children[1].name} @ {n.name}")

            if n.children[0].graph and n.children[1].graph:
                n.graph = merge0(n.children[0], n.children[1])
                if not n.graph:
                    continue
            elif n.children[0].graph:
                n.graph = merge1(n.children[0], n.children[1])
                if not n.graph:
                    import ipdb; impdb.set_trace()
            elif n.children[1].graph:
                n.graph = merge1(n.children[1], n.children[0])
                if not n.graph:
                    import ipdb; impdb.set_trace()
            else:
                # XXX: will we ever get here...
                continue

            check(self.seqs, n.graph)
            with open(f"{tmpdir}/{n.name}.fa", 'w') as fd:
                n.graph.write_fasta(fd)

            # tryprint(f"-- Blocks: {len(n.graph.blks)}, length: {np.sum([len(b) for b in n.graph.blks.values()])}\n", verbose)
            # log(f"node: {n.name}; dist {n.children[0].dist+ n.children[1].dist}")
            log((f"--> compression ratio: "
                   f"{n.graph.compress_ratio()}"))
            log((f"--> number of blocks: "
                   f"{len(n.graph.blks)}"))
            log((f"--> number of members: "
                   f"{len(n.graph.seqs)}"))
            # log((f"--> compression ratio: child1: "
            #      f"{n.children[0].graph.compress_ratio()}"))
            # log((f"--> compression ratio: child2: "
            #      f"{n.children[1].graph.compress_ratio()}"))

    def write_nwk(self, wtr):
        self.root.to_nwk(wtr)
        wtr.write(";")

    def write_json(self, wtr):
        data = {'tree' : self.root.to_json(), 'seqs': {k.name:str(v) for k,v in self.seqs.items()}}
        wtr.write(json.dumps(data))

# ------------------------------------------------------------------------
# Main point of entry for testing

# if __name__ == "__main__":
#     M, nms = parse("data/kmerdist.txt")
#     T = Tree.nj(M, nms)

#     import pyfaidx as fai
#     seqs = fai.Fasta("data/all_plasmids_filtered.fa")
#     T.align(seqs)

#     print("DUMPING")
#     with open("data/tree.json", "w+") as fd:
#         T.to_json(fd)

#     S1 = json.dumps(T.root.to_json())
#     print("LOADING")
#     with open("data/tree.json", "r") as fd:
#         T = Tree.from_json(fd)

#     S2 = json.dumps(T.root.to_json())

#     print(S1==S2)