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
        zig_0_14 = pkgs.mkShell {
          name = "zig-jpeg-0.14";
          nativeBuildInputs = [
            pkgs.zig_0_14
            pkgs.pinact
          ];
        };
        zig_0_15 = pkgs.mkShell {
          name = "zig-jpeg-0.15";
          nativeBuildInputs = [
            pkgs.zig_0_15
            pkgs.pinact
          ];
        };
        default = self.devShells.${pkgs.system}.zig_0_15;
      });
    };
}
