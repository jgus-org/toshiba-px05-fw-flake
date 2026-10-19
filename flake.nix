{
  description = "Devshell + bundled firmware for flashing Toshiba PX05 SAS SSDs (PX05SVB/SMB/SRB) to firmware AS10";

  # Standalone toolbox (run via `nix run`/`nix develop github:jgus-org/toshiba-px05-fw-flake`) with its own nixpkgs pin.
  # The proprietary Toshiba firmware is fetched from Dell at build time. Makes no assumptions about the host it flashes
  # — intended for a live machine or a NixOS installer boot.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      treefmt-nix,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          programs.nixfmt.enable = true;
          programs.shfmt.enable = true;
        };

        targetModel = "PX05SVB096Y";
        targetFw = "AS10";

        # Dell DUP 1DJXX (AS10, 2019-09-17): the only public source of the AS10 image. dl.dell.com 403s the default
        # fetcher user-agent, so a browser UA is set.
        dup = pkgs.fetchurl {
          url = "https://dl.dell.com/FOLDER05601935M/2/SAS-Drive_Firmware_1DJXX_LN_AS10_A00_01.BIN";
          hash = "sha256-EJmc2xA3FC9rci4dq88+xr+SRqn1hom+5MqSbwlaqPM=";
          curlOptsList = [
            "--user-agent"
            "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
          ];
          meta.license = pkgs.lib.licenses.unfree;
        };

        # Raw microcode carved from the DUP and validated (Toshiba signature, internal length field, sha256).
        firmware =
          pkgs.runCommand "toshiba-px05-as10-fw"
            {
              nativeBuildInputs = [ pkgs.python3 ];
              meta.license = pkgs.lib.licenses.unfree;
            }
            ''
              mkdir -p $out
              python3 ${./extract.py} ${dup} $out/AS10_PX05.bin
            '';

        # writeShellScriptBin (not writeShellApplication): the flasher needs its own per-drive error handling, so it
        # must not run under writeShellApplication's forced `set -e`. PATH is pinned to absolute store paths so the tool
        # works under `sudo` / `nix run` regardless of the caller's PATH.
        px05-flash = pkgs.writeShellScriptBin "px05-flash" (
          ''
            export PATH=${
              pkgs.lib.makeBinPath [
                pkgs.sg3_utils
                pkgs.util-linux
                pkgs.coreutils
                pkgs.gnugrep
              ]
            }:$PATH
            FW_DEFAULT="${firmware}/AS10_PX05.bin"
            TARGET_MODEL="${targetModel}"
            TARGET_FW="${targetFw}"
          ''
          + builtins.readFile ./px05-flash.sh
        );
      in
      {
        packages = {
          inherit firmware dup px05-flash;
          default = px05-flash;
        };

        formatter = treefmtEval.config.build.wrapper;
        checks.formatting = treefmtEval.config.build.check self;

        apps.default = {
          type = "app";
          program = "${px05-flash}/bin/px05-flash";
          meta.description = "Flash Toshiba PX05 SAS SSDs to ${targetFw}";
        };

        devShells.default = pkgs.mkShellNoCC {
          buildInputs = [
            px05-flash
            pkgs.sg3_utils
            pkgs.util-linux
          ];
          shellHook = ''
            export PX05_FW="${firmware}/AS10_PX05.bin"
            echo "--- Toshiba PX05 ($targetModel) firmware shell — target $targetFw ---"
            echo "Firmware bundled at \$PX05_FW ; flasher: px05-flash (run via sudo)"
            echo
            echo "Inventory (no root):   px05-flash --dry-run <serials...>"
            echo "Flash:                 sudo nix run github:jgus-org/toshiba-px05-fw-flake -- <serials...>"
            echo "  (or, in this shell:  sudo \"\$(command -v px05-flash)\" <serials...>)"
            echo
            echo "Refuses mounted / md / zfs member drives unless --force-in-use. Verifies FW after each."
          '';
        };
      }
    );
}
