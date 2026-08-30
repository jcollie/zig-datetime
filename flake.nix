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
            # Publishes the API documentation to ocj.page; see
            # .forgejo/workflows/test.yaml.
            pkgs.git-pages-cli
          ];

          # Naming cacert above only puts it in the closure; curl still
          # has to be told where the bundle is, so that the shell does not
          # depend on the surrounding system having said so.
          #
          # This does nothing for `zig fetch`, whose trust store is a
          # hardcoded list of system paths that no environment variable
          # can redirect. tools/update-tzdata.sh works around that by
          # downloading with curl and hashing the local file.
          #
          # It has to be the shellHook rather than a plain attribute:
          # `nix develop` manages the certificate variables itself and
          # overwrites an attribute of the same name, but the hook runs
          # afterwards and wins.
          shellHook = ''
            export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            export NIX_SSL_CERT_FILE="$SSL_CERT_FILE"
          '';
        };
        default = self.devShells.${pkgs.system}.zig_0_16;
      });
    };
}
