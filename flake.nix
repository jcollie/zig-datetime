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
        in
        {
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
            ];
          };
        }
      );
    };
}
