{-# LANGUAGE Arrows #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import qualified Conduit as C
import           Conduit.Simple
import           Conduit.Simple.Compat
import           Control.Arrow
import           Control.Monad
import           Control.Monad.IO.Class
import           Criterion.Main (defaultMain, bench, nf)
import           Data.Functor.Identity
import           Data.Monoid
import qualified Data.Vector as V
import qualified Data.Text as T
import           Data.Text.Encoding
import System.IO.Unsafe (unsafePerformIO)

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
        $ (proc x -> do y <- mapC (+1) -< x
                        g <- takeC 1 -< y
                        returnA -< g)
        $ yieldMany ([1..10] :: [Int])
    print (vs :: [Int])

    x <- sinkList $ returnC $ sumC $ mapC (+1) $ yieldMany ([1..10] :: [Int])
    print x

    yieldMany ([1..10] :: [Int]) $$ mapM_C (liftIO . print)

    defaultMain
        [ -- bench "centipede1" $ nf (runIdentity . useThis) ([1..1000000] :: [Int])
        -- , bench "conduit1"   $ nf (runIdentity . useThat) ([1..1000000] :: [Int])
        -- , bench "centipede2" $ nf (runIdentity . useThis) ([1..1000000] :: [Int])
        -- , bench "centipede3" $ nf (runIdentity . useThis2) ([1..1000000] :: [Int])
        -- , bench "conduit2"   $ nf (runIdentity . useThat) ([1..1000000] :: [Int])
        -- ,
          bench "rechunk1"   $ nf (unsafePerformIO . rechunk1)
                                  (replicate 10 [1..10000])
        , bench "rechunk1IO" $ nf (unsafePerformIO . rechunk1IO)
                                  (replicate 10 [1..10000])
        , bench "C.rechunk1" $ nf (unsafePerformIO . conduitRechunk1)
                                  (replicate 10 [1..10000])
        , bench "C.rechunk3" $ nf (unsafePerformIO . conduitRechunk3)
                                  (replicate 10 [1..10000])
        ]
  where
    useThis xs = yieldMany xs $= mapC (+2) $$ sinkList
    useThis2 xs = yieldMany2 xs $= mapC (+2) $$ sinkList2
    useThat xs = C.yieldMany xs C.$= C.mapC (+2) C.$$ C.sinkList

rechunk1 :: [[Int]] -> IO [V.Vector Int]
rechunk1 xs = sourceList xs
         $= concatC
        =$= concatMapC (\x -> [x, x])
        =$= conduitVector 512
         $$ sinkList

rechunk1IO :: [[Int]] -> IO [V.Vector Int]
rechunk1IO xs = sourceList xs
         $= concatC
        =$= concatMapC (\x -> [x, x])
        =$= conduitVector 512
         $$ sinkList

-- rechunk2 =
--     mapC (concatMap $ replicate 2) =$= loop
--   where
--     loop = do
--         x <- takeCE 512 $= foldC
--         unless (null x) $ yield x >> loop

conduitRechunk1 :: [[Int]] -> IO [V.Vector Int]
conduitRechunk1 xs = C.yieldMany xs
        C.$= C.concatC
       C.=$= C.concatMapC (\x -> [x, x])
       C.=$= C.conduitVector 512
        C.$$ C.sinkList

-- conduitRechunk2 :: [[Int]] -> IO [V.Vector Int]
-- conduitRechunk2 xs = C.yieldMany xs
--      C.$= C.mapC (concatMap $ replicate 2)
--     C.=$= loop
--      C.$$ C.sinkList
--   where
--     loop = do
--         x <- C.takeCE 512 C.=$= C.foldC
--         unless (null x) $ C.yield x >> loop

conduitRechunk3 :: [[Int]] -> IO [V.Vector Int]
conduitRechunk3 xs = C.yieldMany xs
    C.$= C.vectorBuilderC 512 (\yield' -> C.mapM_CE (\x -> yield' x >> yield' x))
    C.$$ C.sinkList

yieldMany2 :: Monad m => [a] -> Source m a
yieldMany2 xs = source $ \z yield -> foldM yield z xs
{-# INLINE yieldMany2 #-}

sinkList2 :: Monad m => Sink a m [a]
sinkList2 = liftM (liftM ($ [])) $ sink id $ \r x -> return (r . (x:))
{-# INLINE sinkList2 #-}
