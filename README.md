# Multi-level ZRAM with page-type-aware idle compression

A Magisk/KernelSU module that splits swap across three zram devices, each
dedicated to a data profile, with an idle threshold matched to that profile's
lifetime.

## Page-type classification

zram has **no per-page type field**. There is no upstream sysfs that tags a
page as "small" or "hot". So classification is done per *tier*: one zram device
per data profile.

| profile | data | algorithm | size | idle |
|---|---|---|---|---|
| `hot_small` | small, frequently touched | lz4hc | 6% | 120s |
| `hot_large` | large, frequently touched | lz4 | 12% | 300s |
| `cold_large` | large, rarely touched | zstd | 10% | 360s |

Override per tier in `zram.conf` (`t<0..2>_PROFILE`, `t<0..2>_ALGO`,
`t<0..2>_IDLE`, `t<0..2>_SIZE_PCT`).

## Idle compression

Pages untouched longer than a tier's threshold become reclaimable. The kernel
performs the actual page movement; the module arms the mechanism and reports
ratios.

`service.sh --idle` runs ~5 minutes after boot (`IDLE_DELAY`, rate-limited by
`IDLE_INTERVAL`) and:

1. Reports each tier's compression ratio (`orig_data / mem_used_total`).
2. Re-triggers `mark_idle` on every tier.

## Stated limits

- **No in-place re-encoding.** zram has no such node; changing `comp_algorithm`
  only affects pages written afterwards.
- **No writeback "mode" selection.** `/sys/block/zramX/writeback` is a 0/1
  bool. Age/dirty variants are internal zsmalloc flags with no sysfs entry.
- **No per-page tagging.** The table is a per-tier profile.
- **No pre-validation of algorithms.** zram publishes no availability list, so
  the write is the check and a rejected write is reverted.

## Layout

```
runtime/
  module.prop     Magisk module metadata
  service.sh      boot configuration + idle sweep (--idle)
  zram.conf       profile / algorithm / size / idle overrides
```

Install: zip `runtime/` as-is and flash in Magisk/KernelSU/APatch.
Logs: `/data/adb/multizram/service.log`.

## Notes

- POSIX sh only (`/system/bin/sh`); no bashisms.
- `set_algo` reverts on rejection so a rejected algorithm cannot leave a
  device on a partial write.
- Refuses to run against an already-active zram device.
- No binaries; auditable in minutes.
