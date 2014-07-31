{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Please see the project README for more details:
--
--   https://github.com/jwiegley/simple-conduit/blob/master/README.md
--
--   Also see this blog article:
--
--   https://www.newartisans.com/2014/06/simpler-conduit-library

module Conduit.Simple
    ( Source(..), Conduit, Sink
    , runSource, lowerSource, source, conduit, conduitWith, sink
    , returnC, close, skip, awaitForever
    , yieldMany, sourceList
    , unfoldC
    , enumFromToC
    , iterateC
    , repeatC
    , replicateC
    , sourceLazy
    , repeatMC
    , repeatWhileMC
    , replicateMC
    , sourceHandle
    , sourceFile
    , sourceIOHandle
    , stdinC
    , initRepeat
    , initReplicate
    , sourceRandom
    , sourceRandomN
    , sourceRandomGen
    , sourceRandomNGen
    , sourceDirectory
    , sourceDirectoryDeep
    , dropC
    , dropCE
    , dropWhileC
    , dropWhileCE
    , foldC
    , foldCE
    , foldlC
    , foldlCE
    , foldMapC
    , foldMapCE
    , allC
    , allCE
    , anyC
    , anyCE
    , andC
    , andCE
    , orC
    , orCE
    , elemC
    , elemCE
    , notElemC
    , notElemCE
    , sinkLazy
    , sinkList
    , sinkVector
    , sinkBuilder
    , sinkLazyBuilder
    , sinkNull
    , awaitNonNull
    , headCE
    , lastC
    , lastCE
    , lengthC
    , lengthCE
    , lengthIfC
    , lengthIfCE
    , maximumC
    , maximumCE
    , minimumC
    , minimumCE
    , sumC
    , sumCE
    , productC
    , productCE
    , findC
    , mapM_C
    , mapM_CE
    , foldMC
    , foldMCE
    , foldMapMC
    , foldMapMCE
    , sinkFile
    , sinkHandle
    , sinkIOHandle
    , printC
    , stdoutC
    , stderrC
    , mapC
    , mapCE
    , omapCE
    , concatMapC
    , concatMapCE
    , takeC
    , takeCE
    , takeWhileC
    , takeWhileCE
    , takeExactlyC
    , takeExactlyCE
    , concatC
    , filterC
    , filterCE
    , mapWhileC
    , conduitVector
    , scanlC
    , concatMapAccumC
    , intersperseC
    , encodeBase64C
    , decodeBase64C
    , encodeBase64URLC
    , decodeBase64URLC
    , encodeBase16C
    , decodeBase16C
    , mapMC
    , mapMCE
    , omapMCE
    , concatMapMC
    , filterMC
    , filterMCE
    , iterMC
    , scanlMC
    , concatMapAccumMC
    , encodeUtf8C
    , decodeUtf8C
    , lineC
    , lineAsciiC
    , unlinesC
    , unlinesAsciiC
    , linesUnboundedC_
    , linesUnboundedC, linesC
    , linesUnboundedAsciiC, linesAsciiC
    , sourceMaybeMVar
    , sourceMaybeTMVar
    , asyncC
    , sourceTChan
    , sourceTQueue
    , sourceTBQueue
    , untilMC
    , whileMC
    , zipSinks

    , ($=), (=$), ($$)
    , sequenceSources
    ) where

import           Conduit.Simple.Compat
import           Conduit.Simple.Core
import           Control.Applicative ((<$>))
import           Control.Concurrent.Async.Lifted
import           Control.Concurrent.Lifted hiding (yield)
import           Control.Concurrent.STM
import           Control.Exception.Lifted (bracket)
import           Control.Monad.Base (MonadBase(..))
import           Control.Monad.Catch (MonadThrow)
import           Control.Monad.Cont
import           Control.Monad.Primitive
import           Control.Monad.Trans.Control
import           Control.Monad.Trans.Either (EitherT(..), left)
import           Data.Builder (Builder(builderToLazy), ToBuilder(..))
import           Data.ByteString (ByteString)
import           Data.IOData (IOData(hGetChunk, hPut))
import           Data.List (unfoldr)
import           Data.MonoTraversable (MonoTraversable, MonoFunctor, Element,
                                       MonoFoldable(oall, oany, ofoldMap,
                                                    ofoldl', ofoldlM, olength,
                                                    onull))
import           Data.NonNull as NonNull (NonNull, fromNullable)
import           Data.Semigroup (Any(..), All(..), Monoid(..), Semigroup((<>)))
import           Data.Sequences as Seq (OrdSequence, EqSequence(elem, notElem),
                                        SemiSequence(..), singleton,
                                        IsSequence(break, drop, dropWhile,
                                                   fromList, splitAt))
import           Data.Sequences.Lazy (LazySequence(fromChunks, toChunks))
import qualified Data.Streaming.Filesystem as F
import           Data.Text (Text)
import           Data.Textual.Encoding (Utf8(encodeUtf8))
import           Data.Traversable (Traversable)
import qualified Data.Vector.Generic as V
import qualified Data.Vector.Generic.Mutable as VM
import           Data.Word (Word8)
import           System.FilePath ((</>))
import           System.IO (stdout, stdin, stderr, openFile, hClose,
                            Handle, IOMode(ReadMode, WriteMode))
import           System.Random.MWC as MWC (Gen, Variate(uniform),
                                           createSystemRandom)
-- import           Data.Primitive.MutVar       (MutVar, newMutVar, readMutVar,
--                                               writeMutVar)

yieldMany :: (Monad m, MonoFoldable mono) => mono -> Source m (Element mono)
yieldMany xs = source $ \z yield -> ofoldlM yield z xs
{-# INLINEABLE yieldMany #-}

sourceList :: Monad m => [a] -> Source m a
sourceList xs = source $ \z yield -> foldM yield z xs
{-# INLINEABLE sourceList #-}

unfoldC :: forall m a b. Monad m => (b -> Maybe (a, b)) -> b -> Source m a
unfoldC = (sourceList .) . Data.List.unfoldr
{-# INLINEABLE unfoldC #-}

enumFromToC :: forall m a. (Monad m, Enum a, Eq a) => a -> a -> Source m a
enumFromToC = (sourceList .) . enumFromTo
{-# INLINEABLE enumFromToC #-}

iterateC :: forall m a. Monad m => (a -> a) -> a -> Source m a
iterateC = (sourceList .) . iterate
{-# INLINEABLE iterateC #-}

repeatC :: forall m a. Monad m => a -> Source m a
repeatC = sourceList . Prelude.repeat
{-# INLINEABLE repeatC #-}

replicateC :: forall m a. Monad m => Int -> a -> Source m a
replicateC = (sourceList .) . Prelude.replicate
{-# INLINEABLE replicateC #-}

sourceLazy :: (Monad m, LazySequence lazy strict) => lazy -> Source m strict
sourceLazy = sourceList . toChunks
{-# INLINEABLE sourceLazy #-}

repeatMC :: forall m a. Monad m => m a -> Source m a
repeatMC x = source go
  where
    go :: r -> (r -> a -> EitherT r m r) -> EitherT r m r
    go z yield = loop z
      where
        loop r = loop =<< yield r =<< lift x
{-# INLINEABLE repeatMC #-}

repeatWhileMC :: forall m a. Monad m => m a -> (a -> Bool) -> Source m a
repeatWhileMC m f = source go
  where
    go :: r -> (r -> a -> EitherT r m r) -> EitherT r m r
    go z yield = loop z
      where
        loop r = do
            x <- lift m
            if f x
                then loop =<< yield r x
                else return r
{-# INLINEABLE repeatWhileMC #-}

replicateMC :: forall m a. Monad m => Int -> m a -> Source m a
replicateMC n m = source $ go n
  where
    go :: Int -> r -> (r -> a -> EitherT r m r) -> EitherT r m r
    go i z yield = loop i z
      where
        loop n' r | n' > 0 = loop (n' - 1) =<< yield r =<< lift m
        loop _ r = return r
{-# INLINEABLE replicateMC #-}

sourceHandle :: forall m a. (MonadIO m, IOData a) => Handle -> Source m a
sourceHandle h = source go
  where
    go :: r -> (r -> a -> EitherT r m r) -> EitherT r m r
    go z yield = loop z
      where
        loop y = do
            x <- liftIO $ hGetChunk h
            if onull x
                then return y
                else loop =<< yield y x
{-# INLINEABLE sourceHandle #-}

sourceFile :: (MonadBaseControl IO m, MonadIO m, IOData a)
           => FilePath -> Source m a
sourceFile path = source $ \z yield ->
    liftBaseOp (bracket (openFile path ReadMode) hClose)
        (\h -> runSource (sourceHandle h) z yield)
{-# INLINEABLE sourceFile #-}

sourceIOHandle :: (MonadBaseControl IO m, MonadIO m, IOData a)
               => IO Handle -> Source m a
sourceIOHandle f = source $ \z yield ->
    liftBaseOp (bracket f hClose) $ \h ->
        runSource (sourceHandle h) z yield
{-# INLINEABLE sourceIOHandle #-}

stdinC :: (MonadBaseControl IO m, MonadIO m, IOData a) => Source m a
stdinC = sourceHandle stdin
{-# INLINEABLE stdinC #-}

initRepeat :: Monad m => m seed -> (seed -> m a) -> Source m a
initRepeat mseed f = source $ \z yield ->
    lift mseed >>= \seed -> runSource (repeatMC (f seed)) z yield
{-# INLINEABLE initRepeat #-}

initReplicate :: Monad m => m seed -> (seed -> m a) -> Int -> Source m a
initReplicate mseed f n = source $ \z yield ->
    lift mseed >>= \seed -> runSource (replicateMC n (f seed)) z yield
{-# INLINEABLE initReplicate #-}

sourceRandom :: (Variate a, MonadIO m) => Source m a
sourceRandom =
    initRepeat (liftIO MWC.createSystemRandom) (liftIO . MWC.uniform)
{-# INLINEABLE sourceRandom #-}

sourceRandomN :: (Variate a, MonadIO m) => Int -> Source m a
sourceRandomN =
    initReplicate (liftIO MWC.createSystemRandom) (liftIO . MWC.uniform)
{-# INLINEABLE sourceRandomN #-}

sourceRandomGen :: (Variate a, MonadBase base m, PrimMonad base)
                => Gen (PrimState base) -> Source m a
sourceRandomGen gen = initRepeat (return gen) (liftBase . MWC.uniform)
{-# INLINEABLE sourceRandomGen #-}

sourceRandomNGen :: (Variate a, MonadBase base m, PrimMonad base)
                 => Gen (PrimState base) -> Int -> Source m a
sourceRandomNGen gen = initReplicate (return gen) (liftBase . MWC.uniform)
{-# INLINEABLE sourceRandomNGen #-}

sourceDirectory :: forall m. MonadBaseControl IO m
                => FilePath -> Source m FilePath
sourceDirectory dir = source $ \z yield ->
    liftBaseOp (bracket (F.openDirStream dir) F.closeDirStream)
        (go z yield)
  where
    go :: r -> (r -> FilePath -> EitherT r m r) -> F.DirStream -> EitherT r m r
    go z yield ds = loop z
      where
        loop r = do
            mfp <- liftBase $ F.readDirStream ds
            case mfp of
                Nothing -> return r
                Just fp -> loop =<< yield r (dir </> fp)
{-# INLINEABLE sourceDirectory #-}

sourceDirectoryDeep :: forall m. MonadBaseControl IO m
                    => Bool -> FilePath -> Source m FilePath
sourceDirectoryDeep followSymlinks startDir = source go
  where
    go :: r -> (r -> FilePath -> EitherT r m r) -> EitherT r m r
    go z yield = start startDir z
      where
        start dir r = runSource (sourceDirectory dir) r entry
        entry r fp = do
            ft <- liftBase $ F.getFileType fp
            case ft of
                F.FTFile -> yield r fp
                F.FTFileSym -> yield r fp
                F.FTDirectory -> start fp r
                F.FTDirectorySym
                    | followSymlinks -> start fp r
                    | otherwise -> return r
                F.FTOther -> return r
{-# INLINEABLE sourceDirectoryDeep #-}

dropC :: Monad m => Int -> Conduit a m a
dropC n = conduitWith n go
  where
    go (r, n') _ _ | n' > 0 = return (r, n' - 1)
    go (r, _) yield x       = yield r x
{-# INLINEABLE dropC #-}

{-
dropCGen :: Monad m => Int -> FoldT (r, Int) m a -> FoldT r m a
dropCGen n = foldWith n go
  where
    go (r, n') _ _ | n' > 0 = return (r, n' - 1)
    go (r, _) yield x       = yield r x
-}

dropCE :: (Monad m, IsSequence seq) => Index seq -> Conduit seq m seq
dropCE n = conduitWith n go
  where
    go (r, n') yield s
        | onull y   = return (r, n' - xn)
        | otherwise = yield r y
      where
        (x, y) = Seq.splitAt n' s
        xn = n' - fromIntegral (olength x)
{-# INLINEABLE dropCE #-}

dropWhileC :: Monad m => (a -> Bool) -> Conduit a m a
dropWhileC f = conduitWith f go
  where
    go (r, k) _ x | k x = return (r, k)
    -- Change out the predicate for one that always fails
    go (r, _) yield x = fmap (const (const False)) <$> yield r x
{-# INLINEABLE dropWhileC #-}

dropWhileCE :: (Monad m, IsSequence seq)
            => (Element seq -> Bool)
            -> Conduit seq m seq
dropWhileCE f = conduitWith f go
  where
    go (r, k) yield s
        | onull x   = return (r, k)
        | otherwise = fmap (const (const False)) <$> yield r s
      where
        x = Seq.dropWhile k s
{-# INLINEABLE dropWhileCE #-}

foldC :: (Monad m, Monoid a) => Sink a m a
foldC = foldMapC id
{-# INLINEABLE foldC #-}

foldCE :: (Monad m, MonoFoldable mono, Monoid (Element mono))
       => Sink mono m (Element mono)
foldCE = foldlC (\acc mono -> acc `mappend` ofoldMap id mono) mempty
{-# INLINEABLE foldCE #-}

foldlC :: Monad m => (a -> b -> a) -> a -> Sink b m a
foldlC f z = sink z ((return .) . f)
{-# INLINEABLE foldlC #-}

foldlCE :: (Monad m, MonoFoldable mono)
        => (a -> Element mono -> a) -> a -> Sink mono m a
foldlCE f = foldlC (ofoldl' f)
{-# INLINEABLE foldlCE #-}

foldMapC :: (Monad m, Monoid b) => (a -> b) -> Sink a m b
foldMapC f = foldlC (\acc x -> acc `mappend` f x) mempty
{-# INLINEABLE foldMapC #-}

foldMapCE :: (Monad m, MonoFoldable mono, Monoid w)
          => (Element mono -> w) -> Sink mono m w
foldMapCE = foldMapC . ofoldMap
{-# INLINEABLE foldMapCE #-}

allC :: Monad m => (a -> Bool) -> Sink a m Bool
allC f = liftM getAll `liftM` foldMapC (All . f)
{-# INLINEABLE allC #-}

allCE :: (Monad m, MonoFoldable mono)
      => (Element mono -> Bool) -> Sink mono m Bool
allCE = allC . oall
{-# INLINEABLE allCE #-}

anyC :: Monad m => (a -> Bool) -> Sink a m Bool
anyC f = liftM getAny `liftM` foldMapC (Any . f)
{-# INLINEABLE anyC #-}

anyCE :: (Monad m, MonoFoldable mono)
      => (Element mono -> Bool) -> Sink mono m Bool
anyCE = anyC . oany
{-# INLINEABLE anyCE #-}

andC :: Monad m => Sink Bool m Bool
andC = allC id
{-# INLINEABLE andC #-}

andCE :: (Monad m, MonoFoldable mono, Element mono ~ Bool)
      => Sink mono m Bool
andCE = allCE id
{-# INLINEABLE andCE #-}

orC :: Monad m => Sink Bool m Bool
orC = anyC id
{-# INLINEABLE orC #-}

orCE :: (Monad m, MonoFoldable mono, Element mono ~ Bool)
     => Sink mono m Bool
orCE = anyCE id
{-# INLINEABLE orCE #-}

elemC :: (Monad m, Eq a) => a -> Sink a m Bool
elemC x = anyC (== x)
{-# INLINEABLE elemC #-}

elemCE :: (Monad m, EqSequence seq) => Element seq -> Sink seq m Bool
elemCE = anyC . Seq.elem
{-# INLINEABLE elemCE #-}

notElemC :: (Monad m, Eq a) => a -> Sink a m Bool
notElemC x = allC (/= x)
{-# INLINEABLE notElemC #-}

notElemCE :: (Monad m, EqSequence seq) => Element seq -> Sink seq m Bool
notElemCE = allC . Seq.notElem
{-# INLINEABLE notElemCE #-}

produceList :: Monad m => ([a] -> b) -> Sink a m b
produceList f =
    liftM (f . ($ [])) . sink id (\front x -> return (front . (x:)))
{-# INLINEABLE produceList #-}

sinkLazy :: (Monad m, LazySequence lazy strict) => Sink strict m lazy
sinkLazy = produceList fromChunks
{-# INLINEABLE sinkLazy #-}

sinkList :: Monad m => Sink a m [a]
sinkList = produceList id
{-# INLINEABLE sinkList #-}

sinkVector :: (MonadBase base m, V.Vector v a, PrimMonad base)
           => Sink a m (v a)
sinkVector = undefined
{-# INLINEABLE sinkVector #-}

sinkBuilder :: (Monad m, Monoid builder, ToBuilder a builder)
            => Sink a m builder
sinkBuilder = foldMapC toBuilder
{-# INLINEABLE sinkBuilder #-}

sinkLazyBuilder :: (Monad m, Monoid builder, ToBuilder a builder,
                    Builder builder lazy)
                => Sink a m lazy
sinkLazyBuilder = liftM builderToLazy . foldMapC toBuilder
{-# INLINEABLE sinkLazyBuilder #-}

sinkNull :: Monad m => Sink a m ()
sinkNull _ = return ()
{-# INLINEABLE sinkNull #-}

awaitNonNull :: (Monad m, MonoFoldable a) => Conduit a m (Maybe (NonNull a))
awaitNonNull = conduit $ \r yield x ->
    maybe (return r) (yield r . Just) (NonNull.fromNullable x)
{-# INLINEABLE awaitNonNull #-}

headCE :: (Monad m, IsSequence seq) => Sink seq m (Maybe (Element seq))
headCE = undefined
{-# INLINEABLE headCE #-}

-- jww (2014-06-07): These two cannot be implemented without leftover support.
-- peekC :: Monad m => Sink a m (Maybe a)
-- peekC = undefined

-- peekCE :: (Monad m, MonoFoldable mono) => Sink mono m (Maybe (Element mono))
-- peekCE = undefined

lastC :: Monad m => Sink a m (Maybe a)
lastC = sink Nothing (const (return . Just))
{-# INLINEABLE lastC #-}

lastCE :: (Monad m, IsSequence seq) => Sink seq m (Maybe (Element seq))
lastCE = undefined
{-# INLINEABLE lastCE #-}

lengthC :: (Monad m, Num len) => Sink a m len
lengthC = foldlC (\x _ -> x + 1) 0
{-# INLINEABLE lengthC #-}

lengthCE :: (Monad m, Num len, MonoFoldable mono) => Sink mono m len
lengthCE = foldlC (\x y -> x + fromIntegral (olength y)) 0
{-# INLINEABLE lengthCE #-}

lengthIfC :: (Monad m, Num len) => (a -> Bool) -> Sink a m len
lengthIfC f = foldlC (\cnt a -> if f a then cnt + 1 else cnt) 0
{-# INLINEABLE lengthIfC #-}

lengthIfCE :: (Monad m, Num len, MonoFoldable mono)
           => (Element mono -> Bool) -> Sink mono m len
lengthIfCE f = foldlCE (\cnt a -> if f a then cnt + 1 else cnt) 0
{-# INLINEABLE lengthIfCE #-}

maximumC :: (Monad m, Ord a) => Sink a m (Maybe a)
maximumC = sink Nothing $ \r y -> return $ Just $ maybe y (max y) r
{-# INLINEABLE maximumC #-}

maximumCE :: (Monad m, OrdSequence seq) => Sink seq m (Maybe (Element seq))
maximumCE = undefined
{-# INLINEABLE maximumCE #-}

minimumC :: (Monad m, Ord a) => Sink a m (Maybe a)
minimumC = sink Nothing $ \r y -> return $ Just $ maybe y (min y) r
{-# INLINEABLE minimumC #-}

minimumCE :: (Monad m, OrdSequence seq) => Sink seq m (Maybe (Element seq))
minimumCE = undefined
{-# INLINEABLE minimumCE #-}

-- jww (2014-06-07): These two cannot be implemented without leftover support.
-- nullC :: Monad m => Sink a m Bool
-- nullC = undefined

-- nullCE :: (Monad m, MonoFoldable mono) => Sink mono m Bool
-- nullCE = undefined

sumC :: (Monad m, Num a) => Sink a m a
sumC = foldlC (+) 0
{-# INLINEABLE sumC #-}

sumCE :: (Monad m, MonoFoldable mono, Num (Element mono))
      => Sink mono m (Element mono)
sumCE = undefined
{-# INLINEABLE sumCE #-}

productC :: (Monad m, Num a) => Sink a m a
productC = foldlC (*) 1
{-# INLINEABLE productC #-}

productCE :: (Monad m, MonoFoldable mono, Num (Element mono))
          => Sink mono m (Element mono)
productCE = undefined
{-# INLINEABLE productCE #-}

findC :: Monad m => (a -> Bool) -> Sink a m (Maybe a)
findC f = sink Nothing $ \r x -> if f x then left (Just x) else return r
{-# INLINEABLE findC #-}

mapM_C :: Monad m => (a -> m ()) -> Sink a m ()
mapM_C f = sink () (const $ lift . f)
{-# INLINEABLE mapM_C #-}

mapM_CE :: (Monad m, MonoFoldable mono)
        => (Element mono -> m ()) -> Sink mono m ()
mapM_CE = undefined
{-# INLINEABLE mapM_CE #-}

foldMC :: Monad m => (a -> b -> m a) -> a -> Sink b m a
foldMC f = flip sink ((lift .) . f)
{-# INLINEABLE foldMC #-}

foldMCE :: (Monad m, MonoFoldable mono)
        => (a -> Element mono -> m a) -> a -> Sink mono m a
foldMCE = undefined
{-# INLINEABLE foldMCE #-}

foldMapMC :: (Monad m, Monoid w) => (a -> m w) -> Sink a m w
foldMapMC f = foldMC (\acc x -> (acc `mappend`) `liftM` f x) mempty
{-# INLINEABLE foldMapMC #-}

foldMapMCE :: (Monad m, MonoFoldable mono, Monoid w)
           => (Element mono -> m w) -> Sink mono m w
foldMapMCE = undefined
{-# INLINEABLE foldMapMCE #-}

sinkFile :: (MonadBaseControl IO m, MonadIO m, IOData a)
         => FilePath -> Sink a m ()
sinkFile fp = sinkIOHandle (liftIO $ openFile fp WriteMode)
{-# INLINEABLE sinkFile #-}

sinkHandle :: (MonadIO m, IOData a) => Handle -> Sink a m ()
sinkHandle = mapM_C . hPut
{-# INLINEABLE sinkHandle #-}

sinkIOHandle :: (MonadBaseControl IO m, MonadIO m, IOData a)
             => IO Handle -> Sink a m ()
sinkIOHandle alloc = liftBaseOp (bracket alloc hClose) . flip sinkHandle
{-# INLINEABLE sinkIOHandle #-}

printC :: (Show a, MonadIO m) => Sink a m ()
printC = mapM_C (liftIO . print)
{-# INLINEABLE printC #-}

stdoutC :: (MonadIO m, IOData a) => Sink a m ()
stdoutC = sinkHandle stdout
{-# INLINEABLE stdoutC #-}

stderrC :: (MonadIO m, IOData a) => Sink a m ()
stderrC = sinkHandle stderr
{-# INLINEABLE stderrC #-}

mapC :: Monad m => (a -> b) -> Conduit a m b
mapC = fmap
{-# INLINEABLE mapC #-}

mapCE :: (Monad m, Functor f) => (a -> b) -> Conduit (f a) m (f b)
mapCE = undefined
{-# INLINEABLE mapCE #-}

omapCE :: (Monad m, MonoFunctor mono)
       => (Element mono -> Element mono) -> Conduit mono m mono
omapCE = undefined
{-# INLINEABLE omapCE #-}

concatMapC :: (Monad m, MonoFoldable mono)
           => (a -> mono) -> Conduit a m (Element mono)
concatMapC f = conduit $ \r yield -> ofoldlM yield r . f
{-# INLINEABLE concatMapC #-}

concatMapCE :: (Monad m, MonoFoldable mono, Monoid w)
            => (Element mono -> w) -> Conduit mono m w
concatMapCE = undefined
{-# INLINEABLE concatMapCE #-}

takeC :: Monad m => Int -> Conduit a m a
takeC n = conduitWith n go
  where
    go (z', n') yield x
        | n' > 1    = next
        | n' > 0    = left =<< next
        | otherwise = left (z', 0)
      where
        next = fmap pred <$> yield z' x
{-# INLINEABLE takeC #-}

{-
takeCGen :: Monad m
         => Int -> FoldT (r, Int) (EitherT (r, Int) m) a
         -> FoldT r (EitherT r m) a
takeCGen n = foldWith' n go
  where
    go (z', n') yield x
        | n' > 1    = next
        | n' > 0    = left =<< next
        | otherwise = left (z', 0)
      where
        next = fmap pred <$> yield z' x
-}

takeCE :: (Monad m, IsSequence seq) => Index seq -> Conduit seq m seq
takeCE = undefined
{-# INLINEABLE takeCE #-}

-- | This function reads one more element than it yields, which would be a
--   problem if Sinks were monadic, as they are in conduit or pipes.  There is
--   no such concept as "resuming where the last conduit left off" in this
--   library.
takeWhileC :: Monad m => (a -> Bool) -> Conduit a m a
takeWhileC f = conduitWith f go
  where
    go (z', k) yield x | k x = yield z' x
    go (z', _) _ _           = left (z', const False)
{-# INLINEABLE takeWhileC #-}

takeWhileCE :: (Monad m, IsSequence seq)
            => (Element seq -> Bool) -> Conduit seq m seq
takeWhileCE = undefined
{-# INLINEABLE takeWhileCE #-}

takeExactlyC :: Monad m => Int -> Conduit a m b -> Conduit a m b
takeExactlyC = undefined
{-# INLINEABLE takeExactlyC #-}

takeExactlyCE :: (Monad m, IsSequence a)
              => Index a -> Conduit a m b -> Conduit a m b
takeExactlyCE = undefined
{-# INLINEABLE takeExactlyCE #-}

concatC :: (Monad m, MonoFoldable mono) => Conduit mono m (Element mono)
concatC = awaitForever yieldMany
{-# INLINEABLE concatC #-}

filterC :: Monad m => (a -> Bool) -> Conduit a m a
filterC f = awaitForever $ \x -> if f x then return x else skip
{-# INLINEABLE filterC #-}

filterCE :: (IsSequence seq, Monad m)
         => (Element seq -> Bool) -> Conduit seq m seq
filterCE = undefined
{-# INLINEABLE filterCE #-}

mapWhileC :: Monad m => (a -> Maybe b) -> Conduit a m b
mapWhileC f = awaitForever $ \x -> case f x of Just y -> return y; _ -> close
{-# INLINEABLE mapWhileC #-}

-- | Collect elements into a vector until the size @maxSize@ is reached, then
--   yield that vector downstream.
conduitVector :: (MonadBase base m, V.Vector v a, PrimMonad base)
              => Int -> Conduit a m (v a)
conduitVector maxSize src = source $ \z yield -> do
    mv <- liftBase $ VM.new maxSize
    EitherT $ do
        eres <- runEitherT $ runSource src (z, 0) $ \(r, i :: Int) x -> EitherT $
            if i >= maxSize
            then do
                v <- liftBase $ V.unsafeFreeze mv
                runEitherT $ rewrap (, 0) $ yield r v
            else do
                liftBase $ VM.write mv i x
                return $ Right (r, i + 1)
        case eres of
            Left (z', _) -> return $ Left z'
            Right (z', i)
                | i > 0 -> do
                    v <- V.slice 0 i <$> liftBase (V.unsafeFreeze mv)
                    runEitherT $ yield z' v
                | otherwise -> return $ Right z'
{-# INLINEABLE conduitVector #-}
{-# SPECIALIZE conduitVector :: (V.Vector v a) => Int -> Conduit a IO (v a) #-}

scanlC :: Monad m => (a -> b -> a) -> a -> Conduit b m a
scanlC = undefined
{-# INLINEABLE scanlC #-}

concatMapAccumC :: Monad m => (a -> accum -> (accum, [b])) -> accum -> Conduit a m b
concatMapAccumC = undefined
{-# INLINEABLE concatMapAccumC #-}

intersperseC :: Monad m => a -> Source m a -> Source m a
intersperseC s src = source $ \z yield -> EitherT $ do
    eres <- runEitherT $ runSource src (Nothing, z) $ \(my, r) x ->
        case my of
            Nothing -> return (Just x, r)
            Just y  -> do
                r' <- rewrap (Nothing,) $ yield r y
                rewrap (Just x,) $ yield (snd r') s
    case eres of
        Left (_, r)        -> return $ Left r
        Right (Nothing, r) -> return $ Right r
        Right (Just x, r)  -> runEitherT $ yield r x
{-# INLINEABLE intersperseC #-}

encodeBase64C :: Monad m => Conduit ByteString m ByteString
encodeBase64C = undefined
{-# INLINEABLE encodeBase64C #-}

decodeBase64C :: Monad m => Conduit ByteString m ByteString
decodeBase64C = undefined
{-# INLINEABLE decodeBase64C #-}

encodeBase64URLC :: Monad m => Conduit ByteString m ByteString
encodeBase64URLC = undefined
{-# INLINEABLE encodeBase64URLC #-}

decodeBase64URLC :: Monad m => Conduit ByteString m ByteString
decodeBase64URLC = undefined
{-# INLINEABLE decodeBase64URLC #-}

encodeBase16C :: Monad m => Conduit ByteString m ByteString
encodeBase16C = undefined
{-# INLINEABLE encodeBase16C #-}

decodeBase16C :: Monad m => Conduit ByteString m ByteString
decodeBase16C = undefined
{-# INLINEABLE decodeBase16C #-}

mapMC :: Monad m => (a -> m b) -> Conduit a m b
mapMC f = (>>= lift . f)
{-# INLINEABLE mapMC #-}

mapMCE :: (Monad m, Traversable f) => (a -> m b) -> Conduit (f a) m (f b)
mapMCE = undefined
{-# INLINEABLE mapMCE #-}

omapMCE :: (Monad m, MonoTraversable mono)
        => (Element mono -> m (Element mono)) -> Conduit mono m mono
omapMCE = undefined
{-# INLINEABLE omapMCE #-}

concatMapMC :: (Monad m, MonoFoldable mono)
            => (a -> m mono) -> Conduit a m (Element mono)
concatMapMC f = awaitForever $ yieldMany <=< lift . f
{-# INLINEABLE concatMapMC #-}

filterMC :: Monad m => (a -> m Bool) -> Conduit a m a
filterMC f = awaitForever $ \x -> do
    res <- lift $ f x
    if res
        then return x
        else skip
{-# INLINEABLE filterMC #-}

filterMCE :: (Monad m, IsSequence seq)
          => (Element seq -> m Bool) -> Conduit seq m seq
filterMCE = undefined
{-# INLINEABLE filterMCE #-}

iterMC :: Monad m => (a -> m ()) -> Conduit a m a
iterMC = undefined
{-# INLINEABLE iterMC #-}

scanlMC :: Monad m => (a -> b -> m a) -> a -> Conduit b m a
scanlMC = undefined
{-# INLINEABLE scanlMC #-}

concatMapAccumMC :: Monad m
                 => (a -> accum -> m (accum, [b])) -> accum -> Conduit a m b
concatMapAccumMC = undefined
{-# INLINEABLE concatMapAccumMC #-}

encodeUtf8C :: (Monad m, Utf8 text binary) => Conduit text m binary
encodeUtf8C = mapC encodeUtf8
{-# INLINEABLE encodeUtf8C #-}

decodeUtf8C :: MonadThrow m => Conduit ByteString m Text
decodeUtf8C = undefined
{-# INLINEABLE decodeUtf8C #-}

lineC :: (Monad m, IsSequence seq, Element seq ~ Char)
      => Conduit seq m o -> Conduit seq m o
lineC = undefined
{-# INLINEABLE lineC #-}

lineAsciiC :: (Monad m, IsSequence seq, Element seq ~ Word8)
           => Conduit seq m o -> Conduit seq m o
lineAsciiC = undefined
{-# INLINEABLE lineAsciiC #-}

unlinesC :: (Monad m, IsSequence seq, Element seq ~ Char)
         => Conduit seq m seq
unlinesC = concatMapC (: [Seq.singleton '\n'])
{-# INLINEABLE unlinesC #-}

unlinesAsciiC :: (Monad m, IsSequence seq, Element seq ~ Word8)
              => Conduit seq m seq
unlinesAsciiC = concatMapC (: [Seq.singleton 10])
{-# INLINEABLE unlinesAsciiC #-}

linesUnboundedC_ :: forall m seq. (Monad m, IsSequence seq, Eq (Element seq))
                 => Element seq -> Conduit seq m seq
linesUnboundedC_ sep src = source $ \z yield -> EitherT $ do
    eres <- runEitherT $ runSource src (z, n) (go yield)
    case eres of
        Left (r, _)  -> return $ Left r
        Right (r, t)
            | onull t   -> return $ Right r
            | otherwise -> runEitherT $ yield r t
  where
    n = Seq.fromList []

    go :: (r -> seq -> EitherT r m r) -> (r, seq) -> seq
       -> EitherT (r, seq) m (r, seq)
    go yield = loop
      where
        loop (r, t') t
            | onull y = return (r, t <> t')
            | otherwise = do
                r' <- rewrap (, n) $ yield r (t' <> x)
                loop r' (Seq.drop 1 y)
          where
            (x, y) = Seq.break (== sep) t

linesUnboundedC :: (Monad m, IsSequence seq, Element seq ~ Char)
                => Conduit seq m seq
linesUnboundedC = linesUnboundedC_ '\n'
{-# INLINEABLE linesUnboundedC #-}

linesUnboundedAsciiC :: (Monad m, IsSequence seq, Element seq ~ Word8)
                     => Conduit seq m seq
linesUnboundedAsciiC = linesUnboundedC_ 10
{-# INLINEABLE linesUnboundedAsciiC #-}

linesC :: (Monad m, IsSequence seq, Element seq ~ Char)
                => Conduit seq m seq
linesC = linesUnboundedC
{-# INLINEABLE linesC #-}

linesAsciiC :: (Monad m, IsSequence seq, Element seq ~ Word8)
                     => Conduit seq m seq
linesAsciiC = linesUnboundedAsciiC
{-# INLINEABLE linesAsciiC #-}

-- | Keep taking from an @MVar (Maybe a)@ until it yields 'Nothing'.
sourceMaybeMVar :: forall m a. MonadIO m => MVar (Maybe a) -> Source m a
sourceMaybeMVar var = source go
  where
    go :: r -> (r -> a -> EitherT r m r) -> EitherT r m r
    go z yield = loop z
      where
        loop r = do
            mx <- liftIO $ takeMVar var
            case mx of
                Nothing -> return r
                Just x  -> loop =<< yield r x
{-# INLINEABLE sourceMaybeMVar #-}

-- | Keep taking from an @TMVar (Maybe a)@ until it yields 'Nothing'.
sourceMaybeTMVar :: forall a. TMVar (Maybe a) -> Source STM a
sourceMaybeTMVar var = source go
  where
    go :: r -> (r -> a -> EitherT r STM r) -> EitherT r STM r
    go z yield = loop z
      where
        loop r = do
            mx <- lift $ takeTMVar var
            case mx of
                Nothing -> return r
                Just x  -> loop =<< yield r x
{-# INLINEABLE sourceMaybeTMVar #-}

asyncC :: (MonadBaseControl IO m, Monad m)
       => (a -> m b) -> Conduit a m (Async (StM m b))
asyncC f = awaitForever $ lift . async . f
{-# INLINEABLE asyncC #-}

sourceSTM :: forall container a. (container a -> STM a)
          -> (container a -> STM Bool)
          -> container a
          -> Source STM a
sourceSTM getter tester chan = source go
  where
    go :: r -> (r -> a -> EitherT r STM r) -> EitherT r STM r
    go z yield = loop z
      where
        loop r = do
            x  <- lift $ getter chan
            r' <- yield r x
            mt <- lift $ tester chan
            if mt
                then return r'
                else loop r'
{-# INLINEABLE sourceSTM #-}

-- | A Source for exhausting a TChan, but blocks if it is initially empty.
sourceTChan :: forall a. TChan a -> Source STM a
sourceTChan = sourceSTM readTChan isEmptyTChan
{-# INLINEABLE sourceTChan #-}

sourceTQueue :: forall a. TQueue a -> Source STM a
sourceTQueue = sourceSTM readTQueue isEmptyTQueue
{-# INLINEABLE sourceTQueue #-}

sourceTBQueue :: forall a. TBQueue a -> Source STM a
sourceTBQueue = sourceSTM readTBQueue isEmptyTBQueue
{-# INLINEABLE sourceTBQueue #-}

untilMC :: forall m a. Monad m => m a -> m Bool -> Source m a
untilMC m f = source go
  where
    go :: r -> (r -> a -> EitherT r m r) -> EitherT r m r
    go z yield = loop z
      where
        loop r = do
            x  <- lift m
            r' <- yield r x
            c  <- lift f
            if c then loop r' else return r'
{-# INLINEABLE untilMC #-}

whileMC :: forall m a. Monad m => m Bool -> m a -> Source m a
whileMC f m = source go
  where
    go :: r -> (r -> a -> EitherT r m r) -> EitherT r m r
    go z yield = loop z
      where
        loop r = do
            c <- lift f
            if c
                then lift m >>= yield r >>= loop
                else return r
{-# INLINEABLE whileMC #-}

zipSinks :: forall a m r r'. (MonadBaseControl IO m, MonadIO m)
         => Sink a m r -> Sink a m r' -> Sink a m (r, r')
zipSinks sink1 sink2 src = do
    x <- liftIO newEmptyMVar
    y <- liftIO newEmptyMVar
    withAsync (sink1 $ sourceMaybeMVar x) $ \a ->
        withAsync (sink2 $ sourceMaybeMVar y) $ \b -> do
            _ <- runEitherT $ runSource src () $ \() val -> do
                liftIO $ putMVar x (Just val)
                liftIO $ putMVar y (Just val)
            liftIO $ putMVar x Nothing
            liftIO $ putMVar y Nothing
            waitBoth a b
{-# INLINEABLE zipSinks #-}
