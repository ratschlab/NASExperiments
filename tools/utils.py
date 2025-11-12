import os
# import re
import urllib.request
# from collections import namedtuple
from os import listdir, uname
import random

# import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import pyfastx
from pyfastx import Fasta
from tqdm import tqdm
import pyfastx
# from numba import jit, njit
import pyslow5
import argparse
import sys
from time import localtime, strftime


def info(*args, **kwargs):
    msg = ("[{}]\x1B[32mINFO:".format(strftime("%H:%M:%S", localtime())),) + args + ("\x1B[0m",)
    print(*msg, file=sys.stderr, **kwargs)


def status(*args, **kwargs):
    msg = ("\r[{}]\x1B[35mSTATUS:".format(strftime("%H:%M:%S", localtime())),) + args + ("\x1B[0m",)
    print(*msg, file=sys.stderr, end='', **kwargs)


def error(*args, **kwargs):
    msg = ("[{}]\x1B[31mERROR:".format(strftime("%H:%M:%S", localtime())),) + args + ("\x1B[0m",)
    print(*msg, file=sys.stderr, **kwargs)
    raise RuntimeError()


# The paths depend on where I am running it.
# TODO - change this so that it uses come config file to set these values
if uname()[0] == "Linux":
    lib_report_path = "/scratch/bacteria/library_report_standard.tsv"
    ref_data_folder = "/scratch/bacteria/refs"
elif uname()[0] == "Darwin":
    lib_report_path = "./data/library_report_standard.tsv"
    ref_data_folder = "./data/refs"


def __get_species_name(x: str):
    """
    Get the species name from the 'Sequence Name' column in KRAKEN library report
    :param x: the value in the 'Sequence Name' column of KRAKEN library report. Its format is assumed to be
        ">[Taxonomy ID] [Genus] [species] [variants and other info]"
    :return: species name
    """
    tokens = x.split()
    return tokens[1] + ' ' + tokens[2]


def __get_tax_id(x: str):
    """
    Get the taxonomy id from the 'Sequence Name' column in KRAKEN library report
    :param x: the value in the 'Sequence Name' column of KRAKEN library report. Its format is assumed to be
        ">[Taxonomy ID] [Genus] [species] [variants and other info]"
    :return: taxonomy id of the species
    """
    tokens = x.split(maxsplit=1)
    return tokens[0][1:]


def load_library_report():
    """
    Load KRAKEN library report into a dataframe and preprocess it
    :return: the dataframe containing the KRAKEN library report
    """
    df = pd.read_csv(lib_report_path, delimiter="\t")

    df = df[df['#Library'] != 'UniVec_Core']
    df['taxid'] = None
    df['species'] = None

    df['taxid'] = df['Sequence Name'].apply(__get_tax_id)
    df['species'] = df['Sequence Name'].apply(__get_species_name)
    print(df.head())
    print(df.describe())

    return df


def choose_species(df:pd.DataFrame, n_species: int, library: list, s=None, seed: int = None) -> pd.DataFrame:
    """
    Choose a set of species
    :param df: Dataframe with KRAKEN library report information
    :param n_species: Number of species to choose
    :param library: A list of libraries to choose from
    :param s: If s is None, choose randomly. If s is an integer choose from the s-th row in the dataframe.
    If s is a list of ints, choose the specified rows (locations not indices) in the dataframe.
    If s is a list of strings, choose the specified species.
    :param seed: seed for random number if s is None (ignored is s is not None)
    :return: a dataframe slice with the chosen species
    """
    df1 = df[df['#Library'].isin(library)]
    if s is None:
        # randomly choose the species
        print("Randomly choosing %d species" % n_species)
        samples = np.random.default_rng(seed=seed).choice(a=df1.index, size=n_species, replace=False)
        return df1.loc[samples]
    elif type(s) is int:
        # choose the n_species species staring from s
        if s + n_species >= len(df1.index):
            raise ValueError('Arguments will cause out of bounds exception')
        print("Choosing %d species starting from index %d" % (n_species, s))
        return df1.iloc[[i for i in range(s, s + n_species)]]
    elif type(s) is list:
        # choose the species specifed either by name or by row-number (not index)
        if all(type(x) == int for x in s):
            if max(s) >= len(df1.index):
                raise ValueError('Arguments will cause out of bounds exception')
            return df1.iloc[s]
        elif all(type(x) == str for x in s):
            return df1[df1['species'].isin(s)]
        else:
            raise ValueError('Expected a list of ints or strings')
    else:
        raise ValueError('Expected an int or a list of ints of strings')


def shuffle_ids(df: pd.DataFrame, seed: int = None) -> list:
    """
    Shuffle the indices of the dataframe slice
    :param df: dataframe slice
    :param seed: seed for numpy random generator
    :return: a shuffled list of the indices of the dataframe slice
    """
    # get indexes and shuffle
    ids = df.index.to_list()
    np.random.default_rng(seed).shuffle(ids)
    return ids


def sample_refs_for_read(shuffled_ids: list, n: int, p: float, seed=None) -> list:
    """
    Decide which reference a particular random read belongs to. This method sets the abundances from the chosen species set.
    The abundances are drawn from a log-series distribution.
    :param shuffled_ids: a shuffled list of the indices of the dataframe slice
    :param n: number of reads to sample
    :param p: used by numpy to generate log series distribution
    :param seed: seed used bu numpy random generator
    :return: a list of indices of the dataframe slice, from each of which exactly one read is to be drawn
    """
    rng = np.random.default_rng(seed)
    nr = len(shuffled_ids)
    read_ref_ids = [0] * n
    c = 0
    with tqdm(total=n, desc='Sampling read locations in species') as pbar:
        while c < n:
            retries = 15
            while retries:
                i = rng.logseries(p)
                if i < nr:
                    break
                else:
                    retries -= 1
            if retries:
                read_ref_ids[c] = shuffled_ids[i - 1]
                c += 1
                pbar.update()
            else:
                raise RuntimeError(
                    "Error sampling reads from references. Either increase number of species or decrease p")
    return read_ref_ids


def download_ref_files(df: pd.DataFrame, data_folder = None, start=0):
    """
    Download the reference genomes if not already there
    :param df: dataframe slice
    :return: None
    """
    if data_folder is None:
        data_folder = ref_data_folder
    refs = listdir(data_folder)
    c = 0
    i = 0
    n = len(df.index)
    failures = []
    for index, row in df.iterrows():
        if i >= start:
            filename = row['taxid'] + ".genomic.fna.gz"
            if not (filename in refs):
                filepath = data_folder + "/" + filename
                link = row['URL']
                print("[%d/%d] Downloading %s into %s ..." % (i+1, n, link, filename), end='')
                try:
                    urllib.request.urlretrieve(link, filepath)
                    print(". Done")
                except:
                    print(". Error")
                    failures.append(row['taxid'])
                c += 1
        i += 1
    print("\nDownloaded %d files. %d files were already present." % (c, len(df.index) - c))
    print("%d files could not be downloaded." % len(failures))


class RefIdx:
    complement = {'A': 'T', 'C': 'G', 'G': 'C', 'T': 'A'}

    def __init__(self, taxid: str):
        self.taxid = taxid
        self.sequences = {}
        self.rng = np.random.default_rng()

        filename = taxid + ".genomic.fna.gz"
        filepath = ref_data_folder + '/' + filename
        for name, seq in Fasta(filepath, build_index=False):
            self.sequences[name] = seq

        self.ids = list(self.sequences.keys())

    def get_sample_sequence(self, rdlen:int) -> tuple:
        self.rng.shuffle(self.ids)
        for id in self.ids:
            slen = len(self.sequences[id])
            if slen > rdlen:
                # sample a read and return
                end = slen - rdlen
                startpos = self.rng.integers(end)
                endpos = startpos + rdlen
                complement = self.rng.choice(1)
                if not complement:
                    return id, self.sequences[id][startpos:endpos]
                else:
                    return id, "".join(
                        self.complement.get(base, base) for base in reversed(self.sequences[id])[startpos:endpos])
        return None


def sample_reads(df: pd.DataFrame, read_refs: list, outfilepath: str,
                 gamma_shape: float = 2., gamma_scale: int = 1000, seeds: list = None):
    """
    Sample reads from the given reference genomes
    :param df: dataframe slice
    :param read_refs: a list of indices of the dataframe slice, from each of which exactly one read is to be drawn
    :param outfilepath: the path to the output file
    :param gamma_shape: used to numpy gamma distribution generator
    :param gamma_scale: used to numpy gamma distribution generator
    :param seeds: list of seeds for random number generators. The first one is for read lengths (gamma),
        the second for read positions (uniform), the third for sequence and strand (uniform).
        If the length of the list is less than 3, it's padded with Nones
    :return: None
    """
    if seeds is None:
        seeds = [None] * 3
    elif (type(seeds) is not list) or (not all(((type(x) == int) or (x is None)) for x in seeds)):
        raise TypeError("seeds must be a list of integers (or None)")
    while len(seeds) < 3:
        seeds.append(None)

    rng = [np.random.default_rng(x) for x in seeds[:3]]

    n_reads = len(read_refs)
    sorted_refs = sorted(read_refs)

    curr_ref_id = -1
    i = 0
    ref_idx = None

    with open(outfilepath, mode='w+') as outfile:
        with tqdm(total=n_reads, desc="Generating reads") as pbar:
            while i < n_reads:
                if curr_ref_id != sorted_refs[i]:
                    curr_ref_id = sorted_refs[i]
                    taxid = df.loc[curr_ref_id].taxid
                    ref_idx = RefIdx(taxid)

                retries = 10
                while retries:
                    rdlen = int(rng[0].gamma(shape=gamma_shape, scale=gamma_scale))
                    seq_id, read = ref_idx.get_sample_sequence(rdlen)
                    if read is not None:
                        outfile.write(">{}|{}|{}|{}\n{}\n".format(
                            taxid, seq_id, i, rdlen, read))
                        break
                if retries == 0:
                    raise RuntimeError("Kept trying to generate reads but encountered too short reference sequences.")
                i += 1
                pbar.update()
    return


def generate_bacterial_sample(df:pd.DataFrame, outfile: str, n_reads, n_species: int = 100):
    """
    Generate a set of reads from a bacterial community.
    :param df: Dataframe with Kraken library report
    :param n_reads: the number of reads to simulate
    :param n_species: the number of species to include in the dataset
    :param outfile: the output (fasta) file to write sequences to
    :return: None
    """
    seeds = [1, 2, 3]
    p = 0.9
    dfs = choose_species(df, n_species, library=['bacteria'], seed=seeds[0])
    sids = shuffle_ids(dfs, seed=seeds[1])
    read_refs = sample_refs_for_read(sids, n_reads, p, seed=seeds[2])
    # plt.hist(read_refs, bins=100)
    # plt.show()
    uniq_refs = np.unique(read_refs)
    print("# unique species =", len(uniq_refs))
    download_ref_files(dfs.loc[uniq_refs])
    sample_reads(dfs, read_refs, outfile)
    return


def split_human_gut_repr_refs():
    """
    Split the single reference file from https://www.nature.com/articles/s41467-022-31502-1
    into multiple files, one per representative species. There are 3594 representative species
    :return:
    """
    filename = '/scratch/HumanGut/Rep_all.fa'
    outdir = '/scratch/HumanGut/RefSplits/'

    with tqdm(total=3594) as pbar:
        for name, seq in pyfastx.Fasta(filename, build_index=False, uppercase=True):
            tokens = name.split('_')
            ref_id = tokens[1]
            contig_id = tokens[3]
            outfilename = outdir + 'Rep_{}.fna'.format(ref_id)
            with open(outfilename, 'a') as outfile:
                outfile.write(">C_{}\n".format(contig_id))
                outfile.write("{}\n".format(seq))
            pbar.update(1)


def select_species_from_clusters(clusterFname, outfilename):
    """
    Select one species from each cluster formed using RabbitTClust.
    :param clusterFname: the name of the cluster file created by RabbitTClust
    :param outfilename: the name of the output file, where 1 species is selected from each cluster
    :return:
    """

    cluster = []
    with open(outfilename, 'w') as f_out:
        with open(clusterFname, 'r') as f_in:
            for line in f_in:
                if line.startswith('the cluster'):
                    if len(cluster) > 0:
                        # select a species from the previous cluster and write it. then clear cluster
                        row = random.choice(cluster)
                        tokens = row.split()
                        if len(tokens) < 6:
                            raise ValueError("Malformed row : {}".format(row))
                        fname = tokens[3]
                        f_out.write('{}\n'.format(fname))
                        cluster.clear()
                else:
                    row = line.strip()
                    if row:
                        # add species to cluster
                        cluster.append(row)

        if len(cluster) > 0:
            # select a species from the previous cluster and write it. then clear cluster
            row = random.choice(cluster)
            tokens = row.split()
            if len(tokens) < 6:
                raise ValueError("Malformed row : {}".format(row))
            fname = tokens[3]
            f_out.write('{}\n'.format(fname))
            cluster.clear()
            pass


def check_cluster_sanity(species_list_fname):
    """
    check that no species is selected twice in the previous step
    :param species_list_fname: the name of the file where one species is selected from each cluster
    :return:
    """

    # Initialize an empty list to store the extracted numbers
    filenames = []

    # Iterate over each line and store file
    with open(species_list_fname, 'r') as f_in:
        for line in f_in:
            filenames.append(line.strip())

    if len(filenames) != len(set(filenames)):
        raise ValueError("A species is repeated")
    else:
        print("All OK!!")


def get_file_sizes(file_list):
    """Helper function to get sizes of files."""
    return [os.path.getsize(file.strip()) for file in file_list]


def greedy_partition_files(file_list):
    """Partition files into two groups with roughly equal total sizes using a greedy heuristic."""
    file_sizes = get_file_sizes(file_list)

    # Combine file sizes with their corresponding filenames
    files_with_sizes = list(zip(file_list, file_sizes))

    # Sort files by size in descending order
    files_with_sizes.sort(key=lambda x: x[1], reverse=True)

    group1 = []
    group2 = []
    group1_size = 0
    group2_size = 0

    for file, size in files_with_sizes:
        if group1_size <= group2_size:
            group1.append(file.strip())
            group1_size += size
        else:
            group2.append(file.strip())
            group2_size += size

    return group1, group2


def concatenate_files(input_file_list, output_file):
    n_species, n_sequences, n_bases = 0, 0, 0
    with open(output_file, 'w') as f_out:
        for filename in input_file_list:
            header_prefix = os.path.splitext(os.path.basename(filename))[0]
            for name, seq in pyfastx.Fasta(filename, build_index=False, uppercase=True):
                f_out.write('>{}_{}\n'.format(header_prefix, name))
                f_out.write('{}\n'.format(seq))
                n_sequences += 1
                n_bases += len(seq)
            n_species += 1
    print(
        "Community: #Species = {}, #Sequence = {}, #Bases = {}G".format(n_species, n_sequences, n_bases / (10 ** 9)))


def create_communities(species_list_fname, community_0_fname, community_1_fname):
    """
    Create 2 random partitions from the list of species obtained in the previous step
    and then append and then create one fastq file for each partition (community)
    :return:
    """
    with open(species_list_fname, 'r') as f:
        files = f.readlines()

    group1, group0 = greedy_partition_files(files)
    concatenate_files(group0, community_0_fname)
    concatenate_files(group1, community_1_fname)


def get_signal_count():
    """
    Prints the number of reads in a slow5/blow5 file
    :return:
    """

    input_filename = '/scratch/HumanGut/blow5-180/signals_d0.1_Comm_1.blow5'

    b5_in = pyslow5.Open(input_filename, 'r')
    num_reads = 0
    with tqdm(total=8371628) as pbar:
        for _ in b5_in.seq_reads_multi(threads=8, batchsize=1024):
            num_reads += 1
            pbar.update(1)

    print("number of reads: {}".format(num_reads))


def truncate_signal(input_filename, output_filename, signal_length=1600):
    """
    Take a blow5 file and create another one where the input signals are truncated to the specified length
    :return:
    """

    # signal_length = 1600    # 1600 for .4s (~180 bp), 3200 for .8s (~360 bp)
    # input_filename = '/scratch/HumanGut/blow5-400/signals_d0.1_Comm_1.blow5'
    # output_filename = '/scratch/HumanGut/blow5-180/signals_d0.1_Comm_1.blow5'
    signal_length = int(signal_length)

    # open files for reading and writing
    b5_in = pyslow5.Open(input_filename, 'r')
    b5_out = pyslow5.Open(output_filename, 'w')

    i = 0
    count = 0
    for read in b5_in.seq_reads():
        if read['len_raw_signal'] >= signal_length:
            read['len_raw_signal'] = signal_length
            read['signal'] = read['signal'][:signal_length]

            b5_out.write_header(b5_in.get_all_headers())
            b5_out.write_record(read)
            count += 1
        i = i + 1
        if i % 10000 == 0:
            print('Processed {} signals'.format(count))

    print("\n{} of {} signals copied".format(count, i))
    b5_out.close()
    b5_in.close()


def generate_reverse_complement_fasta(input_filename: str, output_filename: str):
    assert input_filename != output_filename
    complement = {'A': 'T', 'C': 'G', 'G': 'C', 'T': 'A'}
    with open(output_filename, 'w') as f_out:
        for name, seq in pyfastx.Fasta(input_filename, build_index=False, uppercase=True):
            f_out.write('>{}_WCC\n{}\n'.format(
                name, "".join(complement.get(base, base) for base in reversed(seq))))
    print('Done')


def generate_fwd_and_rev_fasta(input_filename: str, output_filename: str):
    assert input_filename != output_filename
    complement = {'A': 'T', 'C': 'G', 'G': 'C', 'T': 'A'}
    i = 0
    with open(output_filename, 'w') as f_out:
        for name, seq in pyfastx.Fasta(input_filename, build_index=False, uppercase=True):
            f_out.write('>{}+\n{}\n'.format(name, seq))
            f_out.write('>{}-\n{}\n'.format(
                name, "".join(complement.get(base, base) for base in reversed(seq))))
            i += 1
            status(i)
    print('\nDone')


def split_fasta(input_filename: str, output_filebase: str, n_seq: int = 1000):
    i, j = 0, 0
    f_out = None
    for name, seq in pyfastx.Fasta(input_filename, build_index=False, uppercase=True):
        if i % n_seq == 0:
            if f_out: f_out.close()
            output_filename = '{}_{}.fasta'.format(output_filebase, j)
            f_out = open(output_filename, 'w')
            j += 1
            status('Processed', i, 'reads')
        f_out.write('>{}+\n{}\n'.format(name, seq))
        i += 1
    if f_out: f_out.close()
    print()
    info('Processed', i, 'reads')

