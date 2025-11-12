from datetime import datetime
from time import sleep
import sys

# dorado v7.4 and later
# from pybasecall_client_lib.helper_functions import package_read
# from pybasecall_client_lib.pyclient import PyBasecallClient as pclient

# dorado v7.2 or below
from pyguppy_client_lib.helper_functions import package_read
from pyguppy_client_lib.pyclient import PyGuppyClient as pclient

#guppy

import pyslow5

BATCH_SZ = 1024

def calibration(digitisation, range):
    """
    input:
        digitisation: float
        range: float
    output:
        scale: float
    """
    return range / digitisation

def pass_reads_batch(reads: list, client: pclient):
    n_tries = 10
    while n_tries > 0:
        res = client.pass_reads(reads)
        if res:
            break
        else:
            n_tries -= 1
            sleep(.1)
    if n_tries == 0:
        raise RuntimeError("Could not send read batch")


def pass_reads(reads: list, client: pclient):
    for read in reads:
        n_tries = 10
        while n_tries > 0:
            res = client.pass_read(read)
            if res:
                break
            else:
                n_tries -= 1
                sleep(.1)
        if n_tries == 0:
            raise RuntimeError("Could not send read")


def process_completed_reads(client, out, n_sent):
    """Process completed reads from the client and write to output."""
    while n_sent > 0:
        completed_reads = client.get_completed_reads()
        if not completed_reads:
            sleep(0.1)
            continue

        for calls in completed_reads:
            for call in calls:
                try:
                    read_id = call['metadata']['read_id']
                    sequence = call['datasets']['sequence']
                    out.write(f">{read_id}\n{sequence}\n")
                    n_sent -= 1
                except Exception as error:
                    print("An exception occurred in stage 1:", type(error).__name__, "-", error)


def basecall(blow5_in, fasta_out, address="ipc:///tmp/.guppy/5555", config="dna_r9.4.1_450bps_fast"):
    STATUS_UPDATE_INTERVAL = 5.0  # Introduced constant for clarity
    print("Trying to connect to basecall server at {} ... ".format(address))
    client = pclient(address=address, config=config, priority=pclient.high_priority, connection_timeout=3000)
    client.connect()
    print(client.get_protocol_version())
    print(client.get_software_version())

    s5 = pyslow5.Open(blow5_in, 'r')
    out = open(fasta_out, 'w')

    requests = []
    read_count = 0
    n_sent = 0
    last_status_update = datetime.now()

    try:
        for read in s5.seq_reads():
            req = package_read(read_id=read['read_id'],
                               raw_data=read['signal'], daq_offset=read['offset'],
                               daq_scaling=calibration(read['digitisation'], read['range']),
                               read_tag=read_count)
            requests.append(req)
            read_count += 1
            n_sent += 1

            if n_sent == BATCH_SZ:
                pass_reads_batch(requests, client)
                requests.clear()
                process_completed_reads(client, out, n_sent)
                n_sent = 0
                # Check for status update
                if (datetime.now() - last_status_update).total_seconds() > STATUS_UPDATE_INTERVAL:
                    print(f"{read_count} reads processed")
                    last_status_update = datetime.now()

        # Process remaining requests
        if len(requests) > 0:
            pass_reads_batch(requests, client)
            requests.clear()
            process_completed_reads(client, out, n_sent)
    finally:
        out.close()

    print(f"{read_count} reads processed")
