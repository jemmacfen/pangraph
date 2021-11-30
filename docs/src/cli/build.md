# Build

## Description
Build a multiple sequence alignment pangraph.

## Options
Name | Type | Short Flag | Long Flag | Description
:-------------- | :------- | :------ | :------- | :-------------------------
minimum length | Integer | l | len | minimum block size for alignment graph (in nucleotides)
block junction cost | Float | b | beta | energy cost for interblock diversity due to alignment merger,
circular genomes | Boolean | c | circular | toggle if input genomes are circular
distance calculator | String | d | distance-backend | only accepts "native" or "mash"

## Arguments
Expects one or more fasta files.
Multiple records within one file are treated as separate genomes
Fasta files can be optionally gzipped.

## Output
Prints the constructed pangraph as a JSON to _stdout_.