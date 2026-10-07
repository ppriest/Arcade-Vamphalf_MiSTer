# rtl/sound provenance

The YM2151 + M6295 sound of the vamphalf driver's other boards (`sound_ym_oki`, `vamphalf.cpp:1158`).
All files are GPL-3.0-or-later, as this repository (`LICENSE`).

| Path | Source | Changes |
|---|---|---|
| `jt51/hdl/*.v`, `jt51/LICENSE` | jotego's JT51, the `modules/jt51` checkout of `E:/jtcores` at `985a573dcfc1ff135553a39f7eae21d18ba57cbe` ("chore(rtl): remove stale endmodule labels"); `hdl/` only, without `hdl/filter/` (unused: the core takes the chip's own 16-bit output) | none |
| `jt6295/hdl/jt6295*.v`, `jt6295/LICENSE` | jotego's JT6295 as vendored by `E:/Arcade-Fuuki_MiSTer/rtl/sound/jt6295` (its PROVENANCE: github.com/jotego/jt6295 `master` at `7d76b0be8cd8f85f3ae741178c9830b20e2071a1`), Fuuki at `11df2b818f47ec326d4e603e558da82d9b95a0cb`. Without `jt12_comb.v`, `jt12_interpol.v` and the FIR tables: `INTERPOL = 0` leaves them unused | none |
| `sample_cache.sv`, `oki_rom_bridge.sv` | `E:/Arcade-Fuuki_MiSTer/rtl/sound/` at the same Fuuki commit (the cache itself ported there from the Psikyo core) | none |

jt6295's ROM bus expects a byte within two of its internal slots of the address changing; the bridge holds
each request and the cache keeps a 64-bit granule per channel resident with next-granule prefetch, so that
deadline is met from the cache rather than from SDRAM (Fuuki's `fg2_sound.sv`, and LESSONS_LEARNED there).
