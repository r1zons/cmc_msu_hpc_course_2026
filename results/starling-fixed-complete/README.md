# Starling fixed-placement campaign

432 production measurements from Slurm arrays 11868–11891, collected on
2026-11-19. The 24 rank/thread layouts each have three independent
repetitions for every pair of grid size and domain length.
Single-node jobs ran on pg5 and two-node jobs on pg5 and pg6.

- `measurements.csv`: validated production records only. Solver wall time
  is in seconds; initialization and verification are outside the timer.
- `accounting.psv`: Slurm accounting snapshot, with server-local timestamps
  (UTC+03:00).
- `raw.tar.gz`: original solver outputs, CPU-binding records, Slurm logs,
  manifests, submission ledgers, scripts, build metadata, and binary checksum.
  It also retains the preflight logs, including unsuccessful tests; these
  are not included in the production CSV.
- `validation.txt`: completeness and validation totals.

To reproduce the validation in a scratch directory containing `raw.tar.gz`,
`accounting.psv`, and `collect.py`:

```sh
mkdir raw
tar -xzf raw.tar.gz -C raw
python3 collect.py
```
