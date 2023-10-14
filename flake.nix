{
  description = "zig-ha";

  inputs = {
    nixpkgs = {
      url = "nixpkgs/nixos-unstable";
    };
    flake-utils = {
      url = "github:numtide/flake-utils";
    };
    bash = {
      url = "git+https://git.ocjtech.us/jeff/nixos-bash-prompt-builder.git";
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
    };
  };

  outputs = { self, nixpkgs, flake-utils, bash, ... }@inputs:
    let
      systems = builtins.attrNames inputs.zig.packages;
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
      in
      {
        devShells.default =
          let
            project = "zig-datetime";
            prompt = (
              bash.build_ps1_prompt
                bash.ansi_normal_blue
                "${project} - ${bash.username}@${bash.hostname_short}: ${bash.current_working_directory}"
                "${project}:${bash.current_working_directory}"
            );
            make-shell = import inputs.make-shell {
              inherit system;
              pkgs = pkgs;
            };
          in
          make-shell {
            packages = [
              inputs.zig.packages.${system}.master
              # inputs.zls.packages.${system}.zls
            ];
            env = {
              PS1 = prompt;
            };
          };
      }
    );
}
