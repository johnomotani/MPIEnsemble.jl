#!/bin/sh
# Stand-in for mpiexec in the launcher tests: runs the program that follows -n N once for each rank, with
# OMPI_COMM_WORLD_RANK and OMPI_COMM_WORLD_SIZE set as Open MPI sets them. It waits for all the ranks and
# exits 0; the ranks' own exit status is not reported.
if [ "$1" != "-n" ]; then
    echo "fake_mpiexec.sh: expected -n as the first argument" >&2
    exit 2
fi
n=$2
shift 2
rank=0
while [ "$rank" -lt "$n" ]; do
    OMPI_COMM_WORLD_RANK=$rank OMPI_COMM_WORLD_SIZE=$n "$@" &
    rank=$((rank + 1))
done
wait
exit 0
