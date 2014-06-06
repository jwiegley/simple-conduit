{ cabal, exceptions, hspec, liftedBase, mmorph, monadControl, mtl
, QuickCheck, transformers, transformersBase, void
, either
}:

cabal.mkDerivation (self: {
  pname = "simple-conduit";
  version = "0.0.1";
  src = ./.;
  buildDepends = [
    exceptions liftedBase mmorph monadControl mtl transformers
    transformersBase void either
  ];
  testDepends = [ hspec mtl QuickCheck transformers void ];
  doCheck = true;
  meta = {
    homepage = "http://github.com/jwiegley/simple-conduit";
    description = "A simplified version of the conduit library";
    license = self.stdenv.lib.licenses.bsd3;
    platforms = self.ghc.meta.platforms;
    maintainers = [ self.stdenv.lib.maintainers.jwiegley ];
  };
})
