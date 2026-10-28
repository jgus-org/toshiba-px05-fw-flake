# toshiba-px05-fw-flake

A Nix flake that provides the tool and the pinned firmware image for flashing **Toshiba PX05 SAS SSDs** (the PX05SVB / PX05SMB / PX05SRB family) to firmware **AS10**, written over the SCSI `WRITE BUFFER` command. The image comes from [Dell's SAS-Drive_Firmware_1DJXX (AS10, A00) DUP](https://dl.dell.com/FOLDER05601935M/2/SAS-Drive_Firmware_1DJXX_LN_AS10_A00_01.BIN), the only public source of AS10 for these drives.

## Outputs

- **`px05-flash`** — the flasher, as `packages.<system>.px05-flash`, `packages.<system>.default` and `apps.<system>.default`. Targets drives by serial number, refuses any drive that is mounted or carries md/zfs/LVM/LUKS state unless told otherwise, prompts per drive, and re-reads the firmware level to verify after each flash.
- **`packages.<system>.firmware`** — the raw AS10 microcode at `AS10_PX05.bin`.
- **`packages.<system>.dup`** — the original Dell DUP, for provenance.
- **`devShells.<system>.default`** — the flasher plus `sg3_utils` and `util-linux`, with the image path exported as `$PX05_FW`.

`formatter` and `checks.formatting` are maintenance outputs.

`<system>` is `x86_64-linux` or `aarch64-linux`. The flasher drives the disk through the host's own SCSI/SAS stack (`/sys/block`, SCSI generic pass-through), so there is nothing to build or run on macOS.

## Consuming it

Run it straight from the flake:

```bash
sudo nix run github:jgus-org/toshiba-px05-fw-flake -- <serial> [<serial> ...]
```

Or take the outputs from a flake input — `inputs.<name>.apps.${system}.default`, `inputs.<name>.packages.${system}.firmware`, `inputs.<name>.devShells.${system}.default`.

## Firmware

AS10 (`1DJXX`, released 2019-09-17) is the last firmware for these drives; it supersedes AS0E/AS0C/AS0B, and the image is identical across the PX05SMB/SVB/SRB family. It is Toshiba's image, packaged by Dell: the build fetches it from Dell, and no blob is committed to this repository.

Two consequences for the consumer. The build needs to reach `dl.dell.com`, so it cannot run on a fully offline builder. And the image is a vendor binary this flake permits in its own package set, so consuming its outputs needs no unfree acceptance of your own.

The build checks the image it carves out of the DUP against a pinned sha256 and fails loudly if Dell ever serves something else, so every successful build hands you the same bytes.

## Supported drives

The flasher only writes drives reporting model `PX05SVB096Y`; any other model — including a sibling capacity of the same family — is reported and skipped. It selects drives by serial number, so list them first:

```bash
lsblk -S -o NAME,SERIAL,MODEL,REV
```

## Flashing

Inventory first — this reads only, and needs no root:

```bash
nix run github:jgus-org/toshiba-px05-fw-flake -- --dry-run <serial> [<serial> ...]
```

This prints each drive's model, current firmware level, and whether it is in use. Drop `--dry-run` to flash, under `sudo`: writing the image needs raw SCSI access to the drive. Options: `--yes` answers the per-drive prompt, `--bin PATH` (or `$PX05_FW`) flashes a different image, `--bpw N` sets the transfer chunk, `--force-in-use` overrides the in-use refusal.

The image is transferred as 64 KiB `WRITE BUFFER` chunks with offsets, and the drive activates it only once the whole image has arrived — a rejected chunk or an interrupted transfer leaves the drive on its existing firmware rather than half-written. A single-shot transfer cannot work on LSI/Broadcom `mpt3sas` HBAs, whose SG_IO path caps one request at 128 scatter-gather segments (~512 KB) against a ~1.2 MB image. If a drive rejects the chunks, a smaller `--bpw` (e.g. `32768`) is the knob.

**Idle drives** (not mounted, and not a member of an md array, zfs pool or LVM group, nor a LUKS container) flash in place. **In-use drives** are refused. To handle them, either boot a minimal NixOS installer so the drives are offline and run the flake from there — the only safe option for the disk a host boots from (add `--extra-experimental-features 'nix-command flakes'` on an installer that has no flakes enabled) — or quiesce them yourself (unmount, `mdadm --stop`, `zpool export`) and pass `--force-in-use`. Flashing a member of a non-redundant array risks the whole array if that drive fails the update; back up first.

After a flash the tool rescans the drive and reads the firmware level back. Some units only update the reported `REV` string after a power cycle, so a `NOTE: … reports FW 'AS0E' (expected AS10)` line is not a failed flash — re-check the drive after the next power cycle before repeating the write.

Dry-run first, then flash one drive and confirm it verifies `AS10` before doing the rest. Keep the machine on stable power for the duration, and do one machine at a time. This is a maintenance release for healthy drives, not a repair for a specific failure — weigh the small risk against the benefit on a drive that is working fine.

See [LICENSE.md](LICENSE.md) for licensing and copyright, and [NOTICE.md](NOTICE.md) for the terms of upstream and distributed artifacts.
