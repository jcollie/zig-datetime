# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  description = "zig-datetime";

  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    };
    # The toolchain is the official 0.17.0 release binary, packaged by the
    # overlay, rather than nixpkgs' Zig, which has no 0.17 yet.
    zig = {
      url = "git+https://git.jcollie.dev/jeff/zig-overlay.git";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        zon2nix.follows = "zon2nix";
      };
    };
    # Reads `build.zig.zon`, follows every transitive dependency, and writes a
    # Nix expression for the lot. A Nix build has no network and the Zig
    # package manager wants one; this is the bridge. Not the `zon2nix` in
    # nixpkgs, which is a different program taking different options.
    zon2nix = {
      url = "github:jcollie/zon2nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        zig.follows = "zig";
      };
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      zig,
      zon2nix,
      ...
    }:

    let
      inherit (nixpkgs) lib;
      makePackages =
        system:
        import nixpkgs {
          inherit system;
        };
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;
      zigFor = system: zig.packages.${system}."0.17.0";
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = makePackages system;
        in
        {
          # Every package either manifest names, this one's and upstream/'s,
          # as a farm laid out the way `zig build --system` reads one. The
          # workflows realise it and hand it to Zig, so that the dependencies
          # come through Nix and the niks3 cache rather than from the network.
          # Regenerate it with
          #
          #     nix develop -c zon2nix --17 --nix=build.zig.zon.nix \
          #         build.zig.zon upstream/build.zig.zon
          #
          # The expression asks for `zig_0_17`, which nixpkgs does not have,
          # so it is handed the overlay's.
          zig-deps = pkgs.callPackage ./build.zig.zon.nix { zig_0_17 = zigFor system; };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = makePackages system;
          default = pkgs.mkShell {
            name = "zig-datetime";
            nativeBuildInputs = [
              (zigFor system)
              pkgs.pinact
              # Writes build.zig.zon.nix; see `zig-deps` above. Wrapped so
              # that the Zig it shells out to for `zig env` is this one, and
              # never missing: without a Zig on PATH it stops having written
              # nothing, which leaves the old file looking untouched.
              (pkgs.symlinkJoin {
                name = "zon2nix";
                paths = [ zon2nix.packages.${pkgs.stdenv.hostPlatform.system}.zon2nix ];
                nativeBuildInputs = [ pkgs.makeWrapper ];
                postBuild = ''
                  wrapProgram $out/bin/zon2nix \
                    --prefix PATH : ${lib.makeBinPath [ (zigFor system) ]}
                '';
              })
              # Used by tools/update-tzdata.sh and by the Forgejo workflow
              # that runs it. Named here rather than relied on from the
              # ambient environment, so a CI runner gets the same set.
              pkgs.cacert
              pkgs.curl
              pkgs.git
              pkgs.jq
              # Publishes the API documentation to jcollie.page; see
              # .forgejo/workflows/test.yaml.
              pkgs.git-pages-cli
              # Checks the SPDX headers; see REUSE.toml.
              pkgs.reuse
              # Runs moment.js as the oracle the format and parse tests
              # are checked against; see tools/oracle.js. moment itself is
              # pinned in build.zig.zon rather than taken from here, so
              # that the version the tests compare against is fixed.
              pkgs.nodejs
              # The same job for Go's time layouts: `go` is both the
              # oracle for src/golayout.zig and where the reference
              # behaviour is read from. See tools/oracle_go.go.
              pkgs.go
              # And the same again for the CLDR patterns, where ICU is
              # the reference implementation of UTS #35. The C++ in
              # tools/oracle_cldr.cpp is compiled by Zig rather than by a
              # toolchain of its own; pkg-config is how Zig finds the
              # headers and the library, and without it on PATH it
              # silently looks for a library called `libicu-i18n` that
              # does not exist. `icu.dev` carries the headers and the
              # `.pc` files, `icu` the library itself.
              pkgs.icu.dev
              pkgs.icu
              pkgs.pkg-config
              # And again for the .NET format strings and PowerShell's
              # Get-Date: `pwsh` runs the cmdlet itself, and the .NET under
              # it is the reference for src/dotnet.zig. See
              # upstream/src/oracle_powershell.ps1.
              pkgs.powershell
            ];
          };
        in
        {
          inherit default;

          # The Windows half of `src/tzdb.zig` calls into Win32 and so can
          # only be run on Windows, which here means under Wine:
          #
          #     nix develop .#windows -c zig build test \
          #         -Dtarget=x86_64-windows -Dembed-tzdata -fwine
          #
          # Wine is a large thing to carry for one file, and nothing else
          # here needs it, so it is a shell of its own rather than part of
          # the one everyone uses. `wine64` rather than `wine` because the
          # target above is 64-bit; note that Wine builds a prefix for the
          # first architecture it sees and then refuses the other, so a
          # `~/.wine` left over from 32-bit use has to be pointed away from
          # with WINEPREFIX. See .forgejo/workflows/test.yaml.
          windows = pkgs.mkShell {
            name = "zig-datetime-windows";
            inputsFrom = [ default ];
            nativeBuildInputs = [ pkgs.wine64 ];
          };
        }
      );
    };
}
