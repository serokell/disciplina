with import (fetchTarball "https://github.com/serokell/nixpkgs/archive/master.tar.gz") {
  config.allowUnfree = true;
  overlays = [ (import "${fetchGit "git@github.com:/serokell/serokell-overlay"}/pkgs") ];
};

with haskell.lib;

let
  getAttrs = attrs: set: lib.genAttrs attrs (name: set.${name});
in

buildStackApplication rec {
  packages = [
    "disciplina-core" "disciplina-witness" "disciplina-educator"
    "disciplina-wallet" "disciplina-tools"
  ];

  # Running hpack manually before the build is required
  # because of the problem in stack2nix -- it builds every
  # subpackage in a separate environment, thus moving
  # hpack directory out of the scope.
  #
  # See: https://github.com/input-output-hk/stack2nix/pull/107

  src = runCommand "source" { cwd = lib.cleanSource ./.; } ''
    cp --no-preserve=mode,ownership -r $cwd $out

    for f in $out/{core,witness,educator,tools,wallet}; do
      ${haskellPackages.hpack}/bin/hpack $f
    done
  '';

  ghc = haskell.compiler.ghc822;

  overrides = 
    final: previous: 
    let overridingSet = (super: with final; {
          configureFlags = [ "--ghc-option=-Werror" ];
          doCheck = true;
          testDepends = [ hspec tasty tasty-discover tasty-hspec ];
        }); 
        overrideModule = prev: overrideCabal prev (overridingSet final);
    in {
      rocksdb-haskell = dependCabal previous.rocksdb-haskell [ rocksdb ];
    } // (lib.mapAttrs (lib.const overrideModule) (getAttrs packages previous));
}
