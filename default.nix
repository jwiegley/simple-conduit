{ cabal, exceptions, hspec, liftedBase, mmorph, monadControl, mtl
, QuickCheck, transformers, transformersBase, void, criterion
, either, bifunctors, chunkedData, monoTraversable, text, foldl

, primitive, streamingCommons, vector, filepath, mwcRandom
, liftedAsync, stm

, conduit, conduitExtra, conduitCombinators
}:

cabal.mkDerivation (self: {
  pname = "simple-conduit";
  version = "0.2.0";
  src = ./.;
  buildDepends = [
    exceptions liftedBase mmorph monadControl mtl transformers
    transformersBase void either bifunctors chunkedData monoTraversable
    primitive streamingCommons vector filepath mwcRandom liftedAsync
    foldl stm
  ];
  testDepends = [
    hspec mtl QuickCheck transformers void text criterion
    # jww (2014-06-06): Remove these once things get stable
    conduit conduitExtra conduitCombinators
  ];
  doCheck = true;
  configureFlags = "--enable-benchmarks";
  meta = {
    homepage = "http://github.com/jwiegley/simple-conduit";
    description = "A simplified version of the conduit library";
    license = self.stdenv.lib.licenses.bsd3;
    platforms = self.ghc.meta.platforms;
    maintainers = [ self.stdenv.lib.maintainers.jwiegley ];
  };
})
