{-# LANGUAGE OverloadedStrings #-}

module Main where

import qualified Conduit as C
import           Conduit.Simple
import           Conduit.Simple.Compat
import           Control.Monad
import           Control.Monad.IO.Class
import           Criterion.Main (defaultMain, bench, nf)
import           Data.Functor.Identity
import           Data.Monoid
import           Data.Text as T
import           Data.Text.Encoding

main :: IO ()
main = do
    xs <- yieldMany [1..10] $= mapC (+2) $$ sinkList
    print (xs :: [Int])

    ys <- yieldMany [1..10] $$ mapC (+2) =$ sinkList
    print (ys :: [Int])

    zs <- yieldMany [1..10] $= dropC 5 $= mapC (+2) $$ sinkList
    print (zs :: [Int])

    ws <- yieldMany [1..10] $= takeC 5 $= mapC (+2) $$ sinkList
    print (ws :: [Int])

    us <- (sourceFile "simple-conduit.cabal" <> sourceFile "README.md")
        $= takeC 1
        $$ sinkList
    print (T.unpack (decodeUtf8 (Prelude.head us)))

    vs <- sinkList
        $ mapC (<> "Hello")
        $ takeC 1
        $ sourceFile "simple-conduit.cabal" <> sourceFile "README.md"
    print (T.unpack (decodeUtf8 (Prelude.head vs)))

    x <- sinkList $ returnC $ sumC $ mapC (+1) $ yieldMany ([1..10] :: [Int])
    print x

    yieldMany ([1..10] :: [Int]) $$ mapM_C (liftIO . print)

    defaultMain [
        bench "centipede1" $ nf (runIdentity . useThis) ([1..1000000] :: [Int])
      , bench "conduit1"   $ nf (runIdentity . useThat) ([1..1000000] :: [Int])
      , bench "centipede2" $ nf (runIdentity . useThis) ([1..1000000] :: [Int])
      , bench "centipede3" $ nf (runIdentity . useThis2) ([1..1000000] :: [Int])
      , bench "conduit2"   $ nf (runIdentity . useThat) ([1..1000000] :: [Int])
      ]
  where
    useThis xs = yieldMany xs $= mapC (+2) $$ sinkList
    useThis2 xs = yieldMany2 xs $= mapC (+2) $$ sinkList2
    useThat xs = C.yieldMany xs C.$= C.mapC (+2) C.$$ C.sinkList

yieldMany2 :: Monad m => [a] -> Source m a
yieldMany2 xs = source $ \z yield -> foldM yield z xs
{-# INLINE yieldMany2 #-}

sinkList2 :: Monad m => Sink a m [a]
sinkList2 = liftM (liftM ($ [])) $ sink id $ \r x -> return (r . (x:))
{-# INLINE sinkList2 #-}
