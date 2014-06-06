module Main where

import qualified Conduit as C
import           Conduit.Simple
import           Control.Monad.IO.Class
import           Criterion.Main (defaultMain, bench, nf)
import           Data.Functor.Identity
import           Data.Text as T
import           Data.Text.Encoding

main :: IO ()
main = do
    xs <- sourceList [1..10] $= mapC (+2) $$ sinkList
    print (xs :: [Int])

    ys <- sourceList [1..10] $$ mapC (+2) =$ sinkList
    print (ys :: [Int])

    zs <- sourceList [1..10] $= dropC 5 $= mapC (+2) $$ sinkList
    print (zs :: [Int])

    ws <- sourceList [1..10] $= takeC 5 $= mapC (+2) $$ sinkList
    print (ws :: [Int])

    us <- (sourceFile "simple-conduit.cabal" <+> sourceFile "README.md")
        $= takeC 1
        $$ sinkList
    print (T.unpack (decodeUtf8 (Prelude.head us)))

    vs <- sinkList
        $ takeC 1
        $ sourceFile "simple-conduit.cabal" <+> sourceFile "README.md"
    print (T.unpack (decodeUtf8 (Prelude.head vs)))

    sourceList ([1..10] :: [Int]) $$ mapM_C (liftIO . print)

    defaultMain [
        bench "centipede1" $ nf (runIdentity . useThis) ([1..1000000] :: [Int])
      , bench "conduit1"   $ nf (runIdentity . useThat) ([1..1000000] :: [Int])
      , bench "centipede2" $ nf (runIdentity . useThis) ([1..1000000] :: [Int])
      , bench "conduit2"   $ nf (runIdentity . useThat) ([1..1000000] :: [Int])
      ]
  where
    useThis xs = sourceList xs $= mapC (+2) $$ sinkList
    useThat xs = C.yieldMany xs C.$= C.mapC (+2) C.$$ C.sinkList
