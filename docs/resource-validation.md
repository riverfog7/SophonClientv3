# Real game and resource validation

Tested on Linux on 2026-10-07, using the debug SophonCLI through its stdio JSON-RPC transport. Checks and measurements used the actual game manifests and CDN payloads. No game launch or macOS hardware test is claimed.

## ZZZ installation and recovery

The existing `~/Game/ZZZGame` executable matched live version 3.2.0. The API advertises 3.0.0/3.1.0 source tags but sets `enableLdiff` to false, so ZZZ uses installation-manifest verification/repair rather than incremental patching. The next-action decision now checks that capability.

Two known-good files were backed up, then 64 bytes were altered in each: `ZenlessZoneZero.exe` and Korean audio `10100.pck`. The real installer scanned 11,487 selected files (75,212,892,743 bytes), found precisely two damaged chunks, downloaded 2,002,197 bytes, and wrote 2,202,966 bytes. Both repaired whole-file MD5s matched the manifest. The next action returned `none` for 3.2.0. The original ZZZ installation remains healthy.

Fresh full-manifest installs were also forcibly killed after about 100 seconds, retaining 1,022 and 1,243 placement receipts. The CLI returned `resumeInstall`. To finish recovery tests without downloading another complete installation, an isolated workload selected 57 real Korean audio files from the saved manifest: 3,753 distinct chunks, 4,417,418,546 download bytes, and 4,432,376,366 output bytes. These are selected-file tests, not complete fresh installations. SSD and throttled-target runs were forcibly killed and resumed; the saved plans resumed directly in the running phase, and every selected output size/MD5 matched afterward.

## What the budgets cover

`memoryLimit` bounds the reserved bytes of updater original snapshots. It does not cap process RSS, manifests, native patch buffers, installer chunk buffers, HTTP buffers, or the operating system's file cache. In particular, the installer does not use this snapshot pool. Fresh full-plan creation reached about 344 MiB RSS with either a 500 MiB or a 1 MiB setting; repairing the existing installation with a 1 MiB setting peaked at 120 MiB RSS.

`diskLimit` bounds logical payload bytes separately for downloads, transient snapshots, and durable originals. It is not a single combined quota. Filesystem block rounding, journals/state, and target outputs are additional disk usage. With a 1 GiB download pool, the sampled logical maximum stayed below 1,073,741,824 bytes, while allocated payload blocks reached approximately 1,075,658,752 bytes. Limits should include filesystem overhead in the caller's free-space planning.

RAM snapshot admission/release, disk spill, cancellation under pressure, and oversized entries are covered in the existing Swift test file. Measurements below sampled process RSS/CPU and each pool's file sizes about once per second. Peaks are sampled except RSS, which also uses the kernel's process high-water mark.

### Actual patch workload

Three real Genshin 7.0.0 → 7.1.0 bundles supplied ten targets: 279,690,934 patch bytes, 1,839,186,803 original bytes, and 1,952,498,008 output bytes. Originals were extracted read-only from the protected tar into isolated test folders. A saved plan containing those selected entries exercised the real CLI/native patch pipeline. All output hashes matched, with zero repair fallbacks.

| Snapshot limit | Each disk-pool limit | Peak RSS | Sampled snapshot disk peak | Duration |
| --- | --- | --- | --- | --- |
| 500 MiB | 1 GiB | 578 MiB | 411 MiB | 17.1 s |
| 1 MiB | 1 GiB | 109 MiB | 653 MiB | 18.0 s |
| 500 MiB | 200 MiB | 567 MiB | 167 MiB | 19.1 s |

The 200 MiB run completed while download payloads peaked at 171 MiB; the pools together used more than 200 MiB. Low RAM spilled the originals to the fast disk rather than retaining the entire input in RAM.

Small-limit failure checks:

- ZZZ with a 64 KiB disk limit rejected its first 590,654-byte chunk and wrote no target bytes.
- The selected patch run with 1 MiB disk rejected an oversized bundle and preserved all original files.
- In-place mode with 200 MiB disk rejected insufficient durable-original capacity and preserved the original files.
- Cache-only mode with 100 MiB disk rejected the 279,690,934-byte selection before downloading or writing targets.
- A warm-cache run reproduced a bug when lowering its limit to 200 MiB: 279,690,934 cached bytes remained present. The fix trims idle completed entries before pinning payloads; the same run then held 179,509,111 bytes during use and completed successfully. Partial downloads are preserved; active pins or retained partials can prevent reducing the cache and produce an error.

## Slow-storage measurements

No microSD was attached. An owned ext4 loop volume and isolated Linux [cgroup I/O limits](https://docs.kernel.org/admin-guide/cgroup-v2.html#io-interface-files) emulated 20 MiB/s reads/writes and 1,000 IOPS. A flushed 128 MiB probe took 6.43–6.46 seconds. The throttled group used a 512 MiB memory-high threshold and 1 GiB maximum to bound OS buffering; these are test controls, not enforcement of the application's RAM setting. No host-wide I/O or memory limits were changed, and the existing unmounted HDD was not used.

The ZZZ workload used eight download workers, four post-processors, four writers on SSD, and one writer in serialized mode on throttled storage. All cases used a 1 GiB download pool. Throughput is completed payload bytes divided by operation wall time, rather than a whole-host network counter. Cache-hit bytes can count toward progress on resume, so the resumed row measures the remaining workload rather than strictly new network traffic.

| Storage / run | Snapshot setting | Payload rate | Peak RSS | Average CPU | Wall time |
| --- | --- | --- | --- | --- | --- |
| SSD target and cache, full selected workload | 500 MiB | 22.1 MiB/s | 121 MiB | 125% | 190.7 s |
| SSD target and cache, full selected workload | 1 MiB | 19.9 MiB/s | 127 MiB | 122% | 212.0 s |
| Throttled target, SSD cache, resumed remainder | 1 MiB | 16.5 MiB/s | 156 MiB | 106% | 179.9 s |
| Target and cache both throttled, full selected workload | 1 MiB | 7.1 MiB/s | 128 MiB | 47% | 594.2 s |

100% CPU means one logical CPU core. RSS remained stable during the longer throttled transfer, and the sampled download pool stayed within its logical limit throughout all four runs. Slow target writes backpressure a finite pipeline; placing cache and target together on slow storage also adds cache writes/reads to that device's work.

These debug-build measurements are not a microSD benchmark, a promise of release throughput, or a controlled comparison of every setting: some transfers overlapped, and the target-only row resumed a smaller remainder. Profiling nevertheless identified a concrete SSD cost: quota accounting occupied 82% of sampled CPU cycles. Listing names before filtering and using file attributes instead of URL resource conversion reduced that measured share to about 70%, preserving eviction and locking behavior. Directory accounting remains proportional to the number of cached entries.

## Serialized updater on a slow target

The same ten Genshin patch targets ran with cold original-file pages on the throttled loop volume, an SSD cache, a 1 MiB snapshot setting, and 500 MiB per disk pool. Serialized mode used one patch worker. All patch bundles were ready within 7.1 seconds while source reads were underway. The operation finished in 196.7 seconds, peaked at 84.8 MiB RSS, and averaged 20.8% CPU. All ten output hashes matched without repair fallback.

Device counters recorded 1,839,202,304 read bytes and 1,952,550,912 written bytes, consistent with reading the originals once and streaming the new outputs. The one-second trace contained 81 read-only intervals, 90 write-only intervals, and 16 intervals spanning read/write transitions. These samples support the separate phases; they do not resolve sub-second overlap. The implementation serializes target operations and flushes each patch output before the next source read. Cache reads/writes occur on the fast drive.

## Fixes and final checks

- Respect the game's incremental-patch capability in next-action decisions.
- Explain oversized cache entries through localized errors.
- Reduce Foundation overhead in quota scans without changing locking or logical accounting.
- Trim idle completed payloads when a restarted operation lowers its disk limit.
- Keep all new test coverage in the existing test file: 23 cases passed across eight test functions. Strict Swift formatting checks passed.

The authorized untarred Genshin directory was deleted, freeing about 153 GiB. The protected `~/Game/GenshinImpactGame7.0.tar` retained its inode, 156,771,665,920-byte size, and modification time. The existing `GI71` directory was preserved. Owned test installations, temporary volumes, and cgroup limits were removed after verification; the original ZZZ installation and its completed repair checkpoint remain. Free space stayed above 140 GiB during the resource tests.

Detailed one-second samples and operation logs are available in this workspace's host under `/tmp/sophon-resources/`; the setup/measurement harness is `/tmp/sophon-resource-run.py`. [Aggregated measurements](resource-validation.json) accompany this report. Re-running the workload requires constructing the same selected saved plans from the real manifests; it is not part of the normal CLI command interface.
