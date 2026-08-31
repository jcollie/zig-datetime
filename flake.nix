# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  description = "zig-datetime";

  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
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
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = makePackages system;
          default = pkgs.mkShell {
            name = "zig-datetime";
            nativeBuildInputs = [
              pkgs.zig_0_16
              pkgs.pinact
              # Used by tools/update-tzdata.sh and by the Forgejo workflow
              # that runs it. Named here rather than relied on from the
              # ambient environment, so a CI runner gets the same set.
              pkgs.cacert
              pkgs.curl
              pkgs.git
              pkgs.jq
              # Publishes the API documentation to ocj.page; see
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
