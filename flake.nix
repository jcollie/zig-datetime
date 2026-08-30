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
      packages =
        system:
        import nixpkgs {
          inherit system;
        };
      forAllSystems = (
        function:
        nixpkgs.lib.genAttrs [
          "aarch64-linux"
          "aarch64-darwin"
          "x86_64-linux"
          "x86_64-darwin"
        ] (system: function (packages system))
      );
    in
    {
      devShells = forAllSystems (pkgs: {
        zig_0_16 = pkgs.mkShell {
          name = "zig-datetime-0.16";
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
          ];
        };
        default = self.devShells.${pkgs.system}.zig_0_16;
      });
    };
}
