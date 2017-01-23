{ mkDerivation, base, bifunctors, bytestring, chunked-data
, containers, either, exceptions, filepath, free, lifted-async
, lifted-base, mmorph, monad-control, mono-traversable, mtl
, mwc-random, primitive, semigroups, stdenv, stm, streaming-commons
, text, transformers, transformers-base, vector
}:
mkDerivation {
  pname = "simple-conduit";
  version = "0.5.1";
  src = ./.;
  libraryHaskellDepends = [
    base bifunctors bytestring chunked-data containers either
    exceptions filepath free lifted-async lifted-base mmorph
    monad-control mono-traversable mtl mwc-random primitive semigroups
    stm streaming-commons text transformers transformers-base vector
  ];
  homepage = "http://github.com/jwiegley/simple-conduit";
  description = "A simple streaming I/O library based on monadic folds";
  license = stdenv.lib.licenses.bsd3;
}
