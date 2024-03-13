{
  description = "zig-datetime";

  inputs = {
    nixpkgs = {
      url = "nixpkgs/nixos-unstable";
    };
    flake-utils = {
      url = "github:numtide/flake-utils";
    };
    make-shell = {
      url = "github:ursi/nix-make-shell";
    };
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zls = {
      url = "github:zigtools/zls";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.zig-overlay.follows = "zig";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    zig,
    zls,
    ...
  } @ inputs:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {
          inherit system;
        };
      in {
        devShells.default = let
          project = "zig-datetime";
          make-shell = import inputs.make-shell {
            inherit system;
            pkgs = pkgs;
          };
        in
          make-shell {
            packages = [
              pkgs.zon2nix
              zig.packages.${pkgs.system}.master
              zls.packages.${pkgs.system}.zls
            ];
            env = {
              name = project;
            };
          };
      }
    );
}
