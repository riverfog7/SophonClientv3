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

## Follow-up: RAM cache, stream counts, and the SSD bottleneck

The follow-up kept game output writes enabled, put downloaded payloads and checkpoints on Linux tmpfs, and raised the original snapshot limit to 2 GiB. That limit exceeds the entire 1,839,186,803-byte original selection, so no original snapshot spilled to disk. This tests removal of physical cache writes using the existing filesystem cache implementation; it does not implement a new in-process download cache. All ten targets continued to be written and hashed normally. Physical write counters were approximately 1,952,510,000 bytes, essentially the target data plus small metadata overhead.

With live downloads, one stream took 21.0 seconds, two took 13.0 seconds, and four took 12.0 seconds. A separate comparison preloaded and verified all patch payloads, prepared cold input files before starting, and ran sequentially without another test doing storage work:

| Concurrent read/write streams | Wall time | Peak process RSS | Average CPU | Output rate |
| --- | --- | --- | --- | --- |
| 1 | 18.4 s | 484 MiB | 89% | 101 MiB/s |
| 2 | 7.6 s | 663 MiB | 157% | 244 MiB/s |
| 4 | 7.3 s | 836 MiB | 169% | 256 MiB/s |

Two streams delivered most of the improvement. Four helped little on this selection while retaining more original data simultaneously. All 30 controlled outputs matched their manifest sizes and hashes. These are SSD results; they do not establish that additional streams improve an actual microSD/HDD.

To investigate the previously observed 22 MiB/s installation rate, a separate 19-file ZZZ selection supplied 1,471 real chunks: 1,719,400,610 download bytes and 1,719,691,788 output bytes. Both storage variants used the same inputs, eight HTTP workers, four writers, and a 1 GiB download-payload quota. The timed transfers ran sequentially. Output verification overlapped part of the debug SSD run, which is a limitation of that comparison; the RAM-backed profile and transfer ran without that extra storage work.

- A 1 GiB SSD probe including `fsync` measured 864 MiB/s writing and 683 MiB/s reading after per-file page-cache eviction. The earlier preparation process also used the same SSD, so these are conservative samples rather than a formal device benchmark.
- Eight direct HTTP/1.1 curl requests at a time downloaded 456 of the same CDN's chunks, totaling 537,989,223 bytes, to `/dev/null` in 9.50 seconds: 54.0 MiB/s. All returned 206 with the expected total byte count.
- The debug CLI with SSD cache completed the 19-file selection in 65.3 seconds: 25.1 MiB/s. Moving its download cache to tmpfs completed in 68.6 seconds: 23.9 MiB/s, while halving physical writes from about 3.45 GB to 1.72 GB. Removing cache data writes did not remove the throughput limitation.
- A 10-second CPU profile of the tmpfs run attributed 72% of sampled cycles to `DownloadCache.reserveSpace`, 45% to Foundation file-attribute queries, and about 34.5% to owner/group name resolution through `getpwuid_r`/`getgrgid_r`. Sorting contributed 7.2%; decompression contributed 1.9%. These inclusive percentages overlap and must not be added together.
- A small optimized metadata probe read the same 921 cache files five times. Foundation attributes took 154 ms for 4,605 calls; raw `lstat` took 7.8 ms. Both queried real file metadata. The latter fills the stat structure but does not perform Foundation dictionary creation, name resolution, or extended-attribute work.

The repository code rescans the cache directory for every new chunk, retrieves full attributes for every payload, constructs candidates, and sorts them while holding the cross-process budget lock. It sorts even when the `where` condition later determines that no eviction is required. The loop is at `DownloadCache.swift:231`; Foundation attributes are called at line 248 and candidate sorting at line 265. With around 900 live payloads, bookkeeping repeats hundreds of metadata queries per megabyte downloaded. Inference, with high confidence: this serialized CPU work is the dominant bottleneck, rather than sequential SSD bandwidth or Zstd decoding.

The upstream [Foundation implementation](https://github.com/swiftlang/swift-foundation/blob/main/Sources/FoundationEssentials/FileManager/FileManager%2BFiles.swift) also shows that a full attribute query performs additional work beyond a size/time stat lookup. The precise measurements above come from this installed Swift toolchain's profile, not an assumption that upstream `main` is identical.

### Fix and retest

The repeated directory scans were replaced with an in-memory occupied-byte count and an ordered list of completed payloads. Reservation, completion, corruption removal, and eviction update this index. A small revision marker is changed before payload mutations while holding the shared budget lock. Another cache instance refreshes after observing a different revision; an interrupted mutation causes the next operation to reconstruct the index from actual files. The local process also queues budget operations before acquiring the shared file lock, removing its own 20 ms polling delays. Range-reset operations keep the reserved partial-file size stable.

On the same 19-file selection:

| Code / cache | Wall time | Average payload rate |
| --- | --- | --- |
| Original quota scans, debug / SSD | 65.3 s | 25.1 MiB/s |
| Original quota scans, debug / RAM filesystem | 68.6 s | 23.9 MiB/s |
| Original quota scans, release / SSD | 59.2 s | 27.7 MiB/s |
| Original quota scans, release / RAM filesystem | 55.1 s | 29.8 MiB/s |
| In-memory index, release / SSD | 38.8 s | 42.3 MiB/s |
| In-memory index, release / RAM filesystem | 36.6 s | 44.8 MiB/s |
| Index plus local budget queue, debug / SSD | 32.6 s | 50.3 MiB/s |

The final debug run sustained **54.3 MiB/s** between the samples nearest 10 and 30 seconds. Other windows gave 53.9–54.6 MiB/s, consistent with the direct CDN control. The entire operation includes metadata startup, initial connection setup, final writes, and CLI shutdown, explaining its lower overall average. The final local-queue change was tested with the freshly built debug CLI; the indexed release rows precede that final change. No further release rebuild was required to establish the steady transfer result.

A late profile of the original release code, after the cache filled, still attributed 70% of sampled cycles to quota scans and 48% to file attributes. That rules out debug optimization alone as the main explanation. The indexed code no longer had those queries among the dominant sampled functions. Cache-payload logical peaks stayed below 1 GiB, and every diagnosis/retest target size and MD5 matched. Coverage remains in the existing Swift test file: 24 cases across eight functions passed, including shared cache indexes, metadata timestamp parity, shrinking limits, cancellation, corruption, and transfer recovery. Strict Swift formatting checks passed.

A real `SIGKILL` test of the indexed/queued downloader retained 310 placement receipts and seven partial payloads. Restart finished the selected installation directly from its saved plan; all 19 output hashes matched, and the download pool remained below 1 GiB. The test data and RAM filesystems were cleaned up afterward; the actual ZZZ installation and protected Genshin tar were preserved.
