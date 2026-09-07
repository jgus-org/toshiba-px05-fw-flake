# toshiba-px05-fw-flake

A self-contained `nix` toolbox + **pinned firmware** for flashing **Toshiba PX05 SAS SSDs** (the PX05SVB/SMB/SRB family) to firmware **AS10** via the SCSI `WRITE BUFFER` command.

```bash
sudo nix run github:jgus-org/toshiba-px05-fw-flake -- --dry-run <serial> [<serial> ...]
```

Standalone (like `github:jgus-org/connectx3-flake`), with its own `nixpkgs` pin. The firmware is fetched by `fetchurl` from Dell at build time — no blob committed here, nothing to download by hand. Makes no assumptions about the host: runs on a live machine or a NixOS installer boot.

## What it provides

- **`px05-flash`** (`apps.default`) — the flasher. Targets drives **by serial number**, refuses any drive that is mounted / an md or zfs member (unless `--force-in-use`), prompts per drive, and re-reads the firmware to verify after each flash.
- **`packages.firmware`** — the raw AS10 microcode (`AS10_PX05.bin`), carved from the Dell DUP. The extraction self-verifies the Toshiba `PM04DHWF` signature, the image's internal length field, and a known sha256, so the build fails loudly if the upstream package ever changes.
- **`packages.dup`** — the original Dell DUP (provenance).
- **`devShells.default`** — `px05-flash` + `sg3_utils` + `util-linux`, with `$PX05_FW` exported.

## Firmware

| | Version | Source |
|---|---|---|
| Image | AS10 (`1DJXX`, 2019-09-17) | Dell DUP `SAS-Drive_Firmware_1DJXX_LN_AS10_A00_01.BIN` |

AS10 is the latest firmware for these drives (it supersedes AS0E/AS0C/AS0B). The image is identical across the PX05SMB/SVB/SRB family. The flake targets model `PX05SVB096Y` and skips anything else — change `targetModel` in `flake.nix` for a sibling capacity/variant. The firmware is Toshiba's proprietary property, fetched from Dell at build time, not redistributed here. Dell's CDN rejects the default fetcher user-agent, so `fetchurl` sets a browser UA.

## Method

`sg_write_buffer --mode=7 --bpw=65536` — chunked "download microcode with offsets". A single-shot transfer (mode 5) fails on LSI/Broadcom `mpt3sas` HBAs, whose SG_IO path caps one request at 128 scatter-gather segments (~512 KB) while the image is ~1.2 MB; 64 KB chunks stay well under. The drive accumulates the chunks and activates only once the complete image is received, so a rejected chunk or interruption is discarded — the drive stays on its current firmware rather than ending up half-written. Tune the chunk with `--bpw`.

## Usage

The tool selects drives **by serial number**. List your drives' serials and current firmware first:

```bash
lsblk -S -o NAME,SERIAL,MODEL,REV
```

Then dry-run before writing (no root needed for the inventory):

```bash
sudo nix run github:jgus-org/toshiba-px05-fw-flake -- --dry-run <serial> [<serial> ...]
```

It prints each drive's model, current firmware, and whether it's in use. To flash, drop `--dry-run`:

```bash
sudo nix run github:jgus-org/toshiba-px05-fw-flake -- <serial> [<serial> ...]
```

**Idle drives** (not mounted, not an md/zfs/LVM member) flash in place. **In-use drives** are refused by default — handle them one of two ways:

- **Boot a minimal NixOS installer** so the drives are offline, then run the flake from there. This is the cleanest option and the only safe one for the disk a host boots from. Enable flakes on the installer if needed: add `--extra-experimental-features 'nix-command flakes'`.
- **Quiesce them yourself** — unmount filesystems, `mdadm --stop` the array, `zpool export` the pool — then pass `--force-in-use`. Flashing a member of a non-redundant array (e.g. RAID0) risks the whole array if a drive fails the update; back up first.

## Safety

- Dry-run first; flash one drive and confirm it verifies `AS10` before doing the rest.
- Ensure stable power for the duration; do one machine at a time.
- This is a maintenance-release update for healthy drives, not a fix for a specific failure — weigh the small risk against the benefit for drives that are working fine.
