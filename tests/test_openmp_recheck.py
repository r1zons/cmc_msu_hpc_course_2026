"""Local mocks only: no LSF access or numerical solves."""
import csv
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RecheckTests(unittest.TestCase):
    def test_generated_jobs_and_analysis(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            (repo / "scripts/polus").mkdir(parents=True)
            (repo / "build").mkdir()
            (repo / "conda/etc/profile.d").mkdir(parents=True)
            (repo / "conda/lib").mkdir()
            shutil.copy(ROOT / "scripts/polus/submit_openmp_recheck.sh", repo / "scripts/polus")
            config = (ROOT / "scripts/polus/config.sh").read_text()
            config = config.replace("/polusfs/modules/anaconda/anaconda3-2023.03", str(repo / "conda"))
            (repo / "scripts/polus/config.sh").write_text(config)
            (repo / "conda/etc/profile.d/conda.sh").write_text(f'conda() {{ export CONDA_PREFIX="{repo}/conda"; }}\n')
            solver = repo / "build/wave_solver"
            solver.write_text(f'''#!{sys.executable}
import sys, math
a=dict(zip(sys.argv[1::2], sys.argv[2::2]))
l=float(a['--lx']); T=float(a['--time']); dt=T/20
theta=2*math.asin(dt*math.sqrt(12*128**2/l**2)*math.sin(math.pi/256)/2)
error=abs(math.cos(20*theta)-math.cos(math.pi*math.sqrt(3)/l*T))
values=dict(n=128,node_count=129**3,lx=l,ly=l,lz=l,physical_final_time=T,time_steps=20,tau=dt,openmp_threads=a['--threads'],solve_wall_seconds=.01,max_absolute_error=error)
for k,v in values.items(): print(str(k)+'='+str(v))
''')
            solver.chmod(0o755)
            (repo / "bsub").write_text("#!/bin/sh\ncat >/dev/null\necho 'Job <123> is submitted.'\n")
            (repo / "bsub").chmod(0o755)
            env = dict(os.environ, PATH=str(repo)+os.pathsep+os.environ['PATH'])
            submit = repo / "scripts/polus/submit_openmp_recheck.sh"
            subprocess.run(['bash', str(submit), '--dry-run'], env=env, check=True, stdout=subprocess.DEVNULL)
            self.assertFalse((repo / 'results').exists())
            subprocess.run(['bash', str(submit)], env=env, check=True, stdout=subprocess.DEVNULL)
            campaign = next((repo / 'results/polus/openmp_recheck').iterdir())
            original_manifest = (campaign / 'manifest.csv').read_bytes()
            subprocess.run(['bash', str(submit)], env=env, check=True, stdout=subprocess.DEVNULL)
            self.assertEqual(len(list((repo / 'results/polus/openmp_recheck').iterdir())), 2)
            self.assertEqual((campaign / 'manifest.csv').read_bytes(), original_manifest)
            jobs = sorted((campaign / 'jobs').glob('*.lsf'))
            self.assertEqual(len(jobs), 3)
            for job in jobs:
                text = job.read_text()
                for directive in ('#BSUB -x', '#BSUB -q short', '#BSUB -W 00:10', '#BSUB -R "span[hosts=1]"', '#BSUB -m polus-c4-ib.bmc.hpc.cs.msu.ru'):
                    self.assertIn(directive, text)
                self.assertIn('#BSUB -n '+('20' if job.stem == 'C' else '16'), text)
                subprocess.run(['bash', '-n', str(job)], check=True)
                subprocess.run(['bash', str(job)], env=dict(env, LSB_JOBID='123', LSB_HOSTS='polus-c4'), check=True, stdout=subprocess.DEVNULL)
            self.assertEqual(len(list((campaign/'measurements').glob('*.meta'))), 36)
            analyze = [sys.executable, str(ROOT/'scripts/analyze_openmp_recheck.py'), str(campaign)]
            subprocess.run(analyze, check=True, stdout=subprocess.DEVNULL)
            with (campaign/'analysis/summary.csv').open() as handle:
                rows = list(csv.DictReader(handle))
            self.assertTrue(all(r['valid_repetitions']=='10' and float(r['median'])==.01 for r in rows))
            raw_before = {p.name: p.read_bytes() for p in (campaign/'measurements').iterdir()}
            subprocess.run(analyze, check=True, stdout=subprocess.DEVNULL)
            self.assertEqual(raw_before, {p.name: p.read_bytes() for p in (campaign/'measurements').iterdir()})
            path = next((campaign/'measurements').glob('A_measured_1.*.meta'))
            path.write_text(path.read_text().replace('exit_code=0', 'exit_code=9'))
            self.assertNotEqual(subprocess.run(analyze, stdout=subprocess.DEVNULL).returncode, 0)
            shutil.copy(path, path.with_name('A_measured_1.job456.meta'))
            self.assertNotEqual(subprocess.run(analyze, stdout=subprocess.DEVNULL).returncode, 0)
            path.unlink()
            path.with_name('A_measured_1.job456.meta').unlink()
            self.assertNotEqual(subprocess.run(analyze, stdout=subprocess.DEVNULL).returncode, 0)


if __name__ == '__main__':
    unittest.main()
