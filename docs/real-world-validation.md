# Real CLI validation

Validated on Linux on 2026-10-06 using the real `hk4e_global` installation in `~/Game/GIGame`.

The protected `~/Game/GenshinImpactGame7.0.tar` is the existing 7.0.0 test backup, including the selected English and Korean voice packs. Its inode, size and modification time stayed unchanged. The executable inside the archive matched the installed 7.0.0 executable and the API MD5 record.

The live API advertised 7.1.0 and a direct update from 7.0.0. No future branch was available, so the real cache-only run selected the live branch; future-branch decisions were covered by focused fixtures.

## Update parameters

```sh
sophon-cli update hk4e_global ~/Game/GIGame --cache-only \
  --cache-directory ~/Game/.sophon-real-cache \
  --state-directory ~/Game/.sophon-real-state \
  --disk-cache-gib 14 --memory-cache-mib 500 \
  --io-policy serialized --max-concurrent-downloads 4 --max-concurrent-writes 1
```

Applying used the same command without `--cache-only`. `--from` was omitted, exercising executable-based detection and saved-source resume.

The real plan contained 108 bundles (10.3936 GiB), 1,224 targets (50.9462 GiB of output), and 11 deletions. Space planning estimated 8.8811 GiB of target growth before deletions and a 0.4014 GiB temporary peak with one writer. Minimum observed free space during applying was 32.0856 GiB.

| Check | Result |
| --- | --- |
| Automatic source detection | 7.0.0, MD5 `09e21d877397dc95556cf952f96f1fa0` |
| SIGINT during cache download | 11,050,387 received bytes recorded; operation remained unfinished |
| SIGKILL after download resume | Recorded prefixes grew from 11,197,969 to 30,359,318 bytes; earlier prefixes retained |
| Cache completion | All 108 bundles cached; no patch or deletion stages ran |
| SIGKILL during patch output | Interrupted a 146,741,995-byte Korean audio target after 700,416 allocated output bytes |
| Next action after interrupted patch | `resumeUpdate`, saved source 7.0.0 and target 7.1.0 |
| SIGINT after patch resume | Nine completed checkpoints retained; active write drained and no `writing` stage remained |
| Final update resume | All 1,224 targets completed; the nine earlier completed targets retained their modification times |
| Broken source fallback | A deliberately modified small block was repaired using installation-manifest chunks |
| Independent output verification | All 1,224 target sizes and MD5s matched; 54,703,067,988 bytes read; all 11 deletions confirmed |
| Next action after update | `none`, installed/live version 7.1.0 |
| Installer SIGKILL | A backed-up executable was truncated for the test; the live-manifest scan found only that file needing repair; two placements were recorded before forced exit |
| Next action after interrupted install | `resumeInstall`, target 7.1.0 |
| Installer resume | Remaining 323 chunks written, zero verification-phase reads, executable MD5 matched `f69da59bdc366df20bd2b598700e9370` |
| TypeScript client | Stdio and HTTP exercised against real CLI processes, including RPC errors, action queries and shutdown ownership |

Temporary copies made for deliberate corruption tests were removed after successful repair. The protected tar was preserved. Cache and checkpoint directories remain available for inspection; detailed reports/logs for this session were recorded under `/tmp/sophon-real-*`.

This validates file transformation and recovery through the real CLI. It does not claim game launch/play testing, macOS execution, or hardware throughput benchmarks.
