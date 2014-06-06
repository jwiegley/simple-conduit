{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}

-- | Please see the project README for more details:
--
--   https://github.com/jwiegley/simple-conduit/blob/master/README.md

module Conduit.Simple where

import           Control.Exception.Lifted
import           Control.Monad hiding (mapM)
import           Control.Monad.Base
import           Control.Monad.Catch hiding (bracket)
import           Control.Monad.IO.Class
import           Control.Monad.Primitive
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Control
import           Control.Monad.Trans.Either
import           Data.Bifunctor
import           Data.Builder
import           Data.ByteString
-- import Data.Foldable
import           Data.IOData
import           Data.MonoTraversable
import           Data.Monoid
import           Data.NonNull
import           Data.Sequences
import           Data.Sequences.Lazy
import qualified Data.Streaming.Filesystem as F
import           Data.Text
import           Data.Textual.Encoding
import           Data.Traversable
import           Data.Vector.Generic hiding (mapM)
import           Data.Word
import           Prelude hiding (mapM)
import           System.FilePath ((</>))
import           System.IO
import           System.Random.MWC

type Source m a    = forall r. r -> (a -> r -> EitherT r m r) -> EitherT r m r
type Conduit a m b = Source m a -> Source m b
type Sink a m r    = Source m a -> m r

-- | Compose a 'Source' and a 'Conduit' into a new 'Source'.  Note that this
--   is just flipped function application, so ($) can be used to achieve the
--   same thing.
infixl 1 $=
($=) :: Monad m => Source m a -> Conduit a m b -> Source m b
l $= r = r l
{-# INLINE ($=) #-}

-- | Compose a 'Conduit' and a 'Sink' into a new 'Sink'.  Note that this is
--   just function composition, so (.) can be used to achieve the same thing.
infixr 2 =$
(=$) :: Monad m => Conduit a m b -> Sink b m r -> Sink a m r
l =$ r = \await -> r (l await)
{-# INLINE (=$) #-}

-- | Compose a 'Source' and a 'Sink' and compute the result.  Note that this
--   is just flipped function application, so ($) can be used to achieve the
--   same thing.
infixr 0 $$
($$) :: Monad m => Source m a -> Sink a m r -> m r
($$) = flip ($)
{-# INLINE ($$) #-}

-- | Since Sources are not Monads in this library (as they are in the full
--   conduit library), they can be sequentially "chained" using this append
--   operator.  If Source were a newtype, we could make it an instance of
--   Monoid.
infixr 3 <+>
(<+>) :: Monad m => Source m a -> Source m a -> Source m a
x <+> y = \r f -> flip y f =<< x r f
{-# INLINE (<+>) #-}

-- | This is just like 'Control.Monad.Trans.Either.bimapEitherT', but it only
--   requires a 'Monad' constraint rather than 'Functor'.
rewrap :: Monad m => (a -> b) -> EitherT a m a -> EitherT b m b
rewrap f k = EitherT $ bimap f f `liftM` runEitherT k

resolve :: Monad m => (a -> b -> EitherT r m r) -> a -> b -> m r
resolve await z f = either id id `liftM` runEitherT (await z f)

yieldMany :: (Monad m, MonoFoldable mono) => mono -> Source m (Element mono)
yieldMany xs z yield = ofoldlM (flip yield) z xs
{-# INLINE yieldMany #-}

unfoldC :: Monad m => (b -> Maybe (a, b)) -> b -> Source m a
unfoldC f i z yield = go i z
  where
    go x y = case f x of
        Nothing      -> return y
        Just (a, x') -> go x' =<< yield a y

enumFromToC :: (Monad m, Enum a, Eq a) => a -> a -> Source m a
enumFromToC = undefined

iterateC :: Monad m => (a -> a) -> a -> Source m a
iterateC f i z yield = go i z
  where
    go x y = let x' = f x
             in go x' =<< yield x' y

repeatC :: Monad m => a -> Source m a
repeatC x z yield = go z where go y = go =<< yield x y
{-# INLINE repeatC #-}

replicateC :: Monad m => Int -> a -> Source m a
replicateC n x z yield = go n z
  where
    go n' y
        | n' >= 0   = go (n' - 1) =<< yield x y
        | otherwise = return y

sourceLazy :: (Monad m, LazySequence lazy strict) => lazy -> Source m strict
sourceLazy = yieldMany . toChunks
{-# INLINE sourceLazy #-}

repeatMC :: Monad m => m a -> Source m a
repeatMC x z yield = go z where go y = go =<< flip yield y =<< lift x

repeatWhileMC :: Monad m => m a -> (a -> Bool) -> Source m a
repeatWhileMC = undefined

replicateMC :: Monad m => Int -> m a -> Source m a
replicateMC = undefined

sourceHandle :: (MonadIO m, IOData a) => Handle -> Source m a
sourceHandle h z yield = go z
  where
    go y = do
        x <- liftIO $ hGetChunk h
        if onull x
            then return y
            else go =<< yield x y

sourceFile :: (MonadBaseControl IO m, MonadIO m, IOData a)
           => FilePath -> Source m a
sourceFile path z yield =
    bracket
        (liftIO $ openFile path ReadMode)
        (liftIO . hClose)
        (\h -> sourceHandle h z yield)

sourceIOHandle :: (MonadBaseControl IO m, MonadIO m, IOData a)
               => IO Handle -> Source m a
sourceIOHandle f z yield =
    bracket
        (liftIO f)
        (liftIO . hClose)
        (\h -> sourceHandle h z yield)

stdinC :: (MonadBaseControl IO m, MonadIO m, IOData a) => Source m a
stdinC = sourceHandle stdin

sourceRandom :: (Variate a, MonadIO m) => Source m a
sourceRandom = undefined

sourceRandomN :: (Variate a, MonadIO m) => Int -> Source m a
sourceRandomN = undefined

sourceRandomGen :: (Variate a, MonadBase base m, PrimMonad base)
                => Gen (PrimState base) -> Source m a
sourceRandomGen = undefined

sourceRandomNGen :: (Variate a, MonadBase base m, PrimMonad base)
                 => Gen (PrimState base) -> Int -> Source m a
sourceRandomNGen = undefined

sourceDirectory :: (MonadBaseControl IO m, MonadIO m)
                => FilePath -> Source m FilePath
sourceDirectory dir z yield =
    bracket
        (liftIO (F.openDirStream dir))
        (liftIO . F.closeDirStream)
        (go z)
  where
    go y ds = loop y
      where
        loop y' = do
            mfp <- liftIO $ F.readDirStream ds
            case mfp of
                Nothing -> return y'
                Just fp -> loop =<< yield (dir </> fp) y'

sourceDirectoryDeep :: MonadIO m => Bool -> FilePath -> Source m FilePath
sourceDirectoryDeep = undefined

dropC :: Monad m => Int -> Conduit a m a
dropC n await z yield = rewrap snd $ await (n, z) go
  where
    go x (n', z')
        | n' > 0    = return (n' - 1, z')
        | otherwise = rewrap (0,) $ yield x z'

type Consumer a m b = m (a -> b)

dropCE :: (Monad m, IsSequence seq) => Index seq -> Consumer seq m ()
dropCE = undefined

dropWhileC :: Monad m => (a -> Bool) -> Consumer a m ()
dropWhileC = undefined

dropWhileCE :: (Monad m, IsSequence seq) => (Element seq -> Bool) -> Consumer seq m ()
dropWhileCE = undefined

foldC :: (Monad m, Monoid a) => Consumer a m a
foldC = undefined

foldCE :: (Monad m, MonoFoldable mono, Monoid (Element mono))
       => Consumer mono m (Element mono)
foldCE = undefined

foldlC :: Monad m => (a -> b -> a) -> a -> Consumer b m a
foldlC = undefined

foldlCE :: (Monad m, MonoFoldable mono)
        => (a -> Element mono -> a) -> a -> Consumer mono m a
foldlCE = undefined

foldMapC :: (Monad m, Monoid b) => (a -> b) -> Consumer a m b
foldMapC = undefined

foldMapCE :: (Monad m, MonoFoldable mono, Monoid w)
          => (Element mono -> w) -> Consumer mono m w
foldMapCE = undefined

allC :: Monad m => (a -> Bool) -> Consumer a m Bool
allC = undefined

allCE :: (Monad m, MonoFoldable mono)
      => (Element mono -> Bool) -> Consumer mono m Bool
allCE = undefined

anyC :: Monad m => (a -> Bool) -> Consumer a m Bool
anyC = undefined

anyCE :: (Monad m, MonoFoldable mono)
      => (Element mono -> Bool) -> Consumer mono m Bool
anyCE = undefined

andC :: Monad m => Consumer Bool m Bool
andC = undefined

andCE :: (Monad m, MonoFoldable mono, Element mono ~ Bool)
      => Consumer mono m Bool
andCE = undefined

orC :: Monad m => Consumer Bool m Bool
orC = undefined

orCE :: (Monad m, MonoFoldable mono, Element mono ~ Bool)
     => Consumer mono m Bool
orCE = undefined

elemC :: (Monad m, Eq a) => a -> Consumer a m Bool
elemC = undefined

elemCE :: (Monad m, EqSequence seq) => Element seq -> Consumer seq m Bool
elemCE = undefined

notElemC :: (Monad m, Eq a) => a -> Consumer a m Bool
notElemC = undefined

notElemCE :: (Monad m, EqSequence seq) => Element seq -> Consumer seq m Bool
notElemCE = undefined

sinkLazy :: (Monad m, LazySequence lazy strict) => Consumer strict m lazy
sinkLazy = undefined

sinkList :: Monad m => Sink a m [a]
sinkList await =
    ($ []) `liftM` resolve await id (\x front -> return (front . (x:)))
{-# INLINE sinkList #-}

sinkVector :: (MonadBase base m, Vector v a, PrimMonad base)
           => Consumer a m (v a)
sinkVector = undefined

sinkVectorN :: (MonadBase base m, Vector v a, PrimMonad base)
            => Int -> Consumer a m (v a)
sinkVectorN = undefined

sinkBuilder :: (Monad m, Monoid builder, ToBuilder a builder)
            => Consumer a m builder
sinkBuilder = undefined

sinkLazyBuilder :: (Monad m, Monoid builder, ToBuilder a builder,
                    Builder builder lazy)
                => Consumer a m lazy
sinkLazyBuilder = undefined

sinkNull :: Monad m => Consumer a m ()
sinkNull = undefined

awaitNonNull :: (Monad m, MonoFoldable a) => Consumer a m (Maybe (NonNull a))
awaitNonNull = undefined

headCE :: (Monad m, IsSequence seq) => Consumer seq m (Maybe (Element seq))
headCE = undefined

peekC :: Monad m => Consumer a m (Maybe a)
peekC = undefined

peekCE :: (Monad m, MonoFoldable mono) => Consumer mono m (Maybe (Element mono))
peekCE = undefined

lastC :: Monad m => Consumer a m (Maybe a)
lastC = undefined

lastCE :: (Monad m, IsSequence seq) => Consumer seq m (Maybe (Element seq))
lastCE = undefined

lengthC :: (Monad m, Num len) => Consumer a m len
lengthC = undefined

lengthCE :: (Monad m, Num len, MonoFoldable mono) => Consumer mono m len
lengthCE = undefined

lengthIfC :: (Monad m, Num len) => (a -> Bool) -> Consumer a m len
lengthIfC = undefined

lengthIfCE :: (Monad m, Num len, MonoFoldable mono)
           => (Element mono -> Bool) -> Consumer mono m len
lengthIfCE = undefined

maximumC :: (Monad m, Ord a) => Consumer a m (Maybe a)
maximumC = undefined

maximumCE :: (Monad m, OrdSequence seq) => Consumer seq m (Maybe (Element seq))
maximumCE = undefined

minimumC :: (Monad m, Ord a) => Consumer a m (Maybe a)
minimumC = undefined

minimumCE :: (Monad m, OrdSequence seq) => Consumer seq m (Maybe (Element seq))
minimumCE = undefined

nullC :: Monad m => Consumer a m Bool
nullC = undefined

nullCE :: (Monad m, MonoFoldable mono) => Consumer mono m Bool
nullCE = undefined

sumC :: (Monad m, Num a) => Consumer a m a
sumC = undefined

sumCE :: (Monad m, MonoFoldable mono, Num (Element mono))
      => Consumer mono m (Element mono)
sumCE = undefined

productC :: (Monad m, Num a) => Consumer a m a
productC = undefined

productCE :: (Monad m, MonoFoldable mono, Num (Element mono))
          => Consumer mono m (Element mono)
productCE = undefined

findC :: Monad m => (a -> Bool) -> Consumer a m (Maybe a)
findC = undefined

mapM_C :: Monad m => (a -> m ()) -> Sink a m ()
mapM_C f await = do
    _ <- runEitherT $ await () (\a () -> lift (f a))
    return ()
{-# INLINE mapM_C #-}

mapM_CE :: (Monad m, MonoFoldable mono)
        => (Element mono -> m ()) -> Consumer mono m ()
mapM_CE = undefined

foldMC :: Monad m => (a -> b -> m a) -> a -> Consumer b m a
foldMC = undefined

foldMCE :: (Monad m, MonoFoldable mono)
        => (a -> Element mono -> m a) -> a -> Consumer mono m a
foldMCE = undefined

foldMapMC :: (Monad m, Monoid w) => (a -> m w) -> Consumer a m w
foldMapMC = undefined

foldMapMCE :: (Monad m, MonoFoldable mono, Monoid w)
           => (Element mono -> m w) -> Consumer mono m w
foldMapMCE = undefined

sinkFile :: (MonadIO m, IOData a) => FilePath -> Consumer a m ()
sinkFile = undefined

sinkHandle :: (MonadIO m, IOData a) => Handle -> Consumer a m ()
sinkHandle = undefined

sinkIOHandle :: (MonadIO m, IOData a) => IO Handle -> Consumer a m ()
sinkIOHandle = undefined

printC :: (Show a, MonadIO m) => Consumer a m ()
printC = undefined

stdoutC :: (MonadIO m, IOData a) => Consumer a m ()
stdoutC = undefined

stderrC :: (MonadIO m, IOData a) => Consumer a m ()
stderrC = undefined

mapC :: Monad m => (a -> b) -> Conduit a m b
mapC f await z yield = await z (yield . f)
{-# INLINE mapC #-}

mapCE :: (Monad m, Functor f) => (a -> b) -> Conduit (f a) m (f b)
mapCE = undefined

omapCE :: (Monad m, MonoFunctor mono)
       => (Element mono -> Element mono) -> Conduit mono m mono
omapCE = undefined

concatMapC :: (Monad m, MonoFoldable mono)
           => (a -> mono) -> Conduit a m (Element mono)
concatMapC = undefined

concatMapCE :: (Monad m, MonoFoldable mono, Monoid w)
            => (Element mono -> w) -> Conduit mono m w
concatMapCE = undefined

takeC :: Monad m => Int -> Conduit a m a
takeC n await z yield = rewrap snd $ await (n, z) go
  where
    go x (n', z')
        | n' > 1    = next
        | n' > 0    = left =<< next
        | otherwise = left (0, z')
      where
        next = rewrap (n' - 1,) $ yield x z'

takeCE :: (Monad m, IsSequence seq) => Index seq -> Conduit seq m seq
takeCE = undefined

takeWhileC :: Monad m => (a -> Bool) -> Conduit a m a
takeWhileC = undefined

takeWhileCE :: (Monad m, IsSequence seq)
            => (Element seq -> Bool) -> Conduit seq m seq
takeWhileCE = undefined

takeExactlyC :: Monad m => Int -> Conduit a m b -> Conduit a m b
takeExactlyC = undefined

takeExactlyCE :: (Monad m, IsSequence a)
              => Index a -> Conduit a m b -> Conduit a m b
takeExactlyCE = undefined

concatC :: (Monad m, MonoFoldable mono) => Conduit mono m (Element mono)
concatC = undefined

filterC :: Monad m => (a -> Bool) -> Conduit a m a
filterC = undefined

filterCE :: (IsSequence seq, Monad m)
         => (Element seq -> Bool) -> Conduit seq m seq
filterCE = undefined

mapWhileC :: Monad m => (a -> Maybe b) -> Conduit a m b
mapWhileC f await z yield = await z $ \x z' ->
    maybe (left z') (`yield` z') (f x)

conduitVector :: (MonadBase base m, Vector v a, PrimMonad base)
              => Int -> Conduit a m (v a)
conduitVector = undefined

scanlC :: Monad m => (a -> b -> a) -> a -> Conduit b m a
scanlC = undefined

concatMapAccumC :: Monad m => (a -> accum -> (accum, [b])) -> accum -> Conduit a m b
concatMapAccumC = undefined

intersperseC :: Monad m => a -> Conduit a m a
intersperseC = undefined

encodeBase64C :: Monad m => Conduit ByteString m ByteString
encodeBase64C = undefined

decodeBase64C :: Monad m => Conduit ByteString m ByteString
decodeBase64C = undefined

encodeBase64URLC :: Monad m => Conduit ByteString m ByteString
encodeBase64URLC = undefined

decodeBase64URLC :: Monad m => Conduit ByteString m ByteString
decodeBase64URLC = undefined

encodeBase16C :: Monad m => Conduit ByteString m ByteString
encodeBase16C = undefined

decodeBase16C :: Monad m => Conduit ByteString m ByteString
decodeBase16C = undefined

mapMC :: Monad m => (a -> m b) -> Conduit a m b
mapMC f await z yield = await z (\x r -> flip yield r =<< lift (f x))
{-# INLINE mapMC #-}

mapMCE :: (Monad m, Traversable f) => (a -> m b) -> Conduit (f a) m (f b)
mapMCE = undefined

omapMCE :: (Monad m, MonoTraversable mono)
        => (Element mono -> m (Element mono)) -> Conduit mono m mono
omapMCE = undefined

concatMapMC :: (Monad m, MonoFoldable mono)
            => (a -> m mono) -> Conduit a m (Element mono)
concatMapMC = undefined

filterMC :: Monad m => (a -> m Bool) -> Conduit a m a
filterMC f await z yield = await z $ \x z' -> do
    res <- lift $ f x
    if res
        then yield x z'
        else return z'

filterMCE :: (Monad m, IsSequence seq)
          => (Element seq -> m Bool) -> Conduit seq m seq
filterMCE = undefined

iterMC :: Monad m => (a -> m ()) -> Conduit a m a
iterMC = undefined

scanlMC :: Monad m => (a -> b -> m a) -> a -> Conduit b m a
scanlMC = undefined

concatMapAccumMC :: Monad m
                 => (a -> accum -> m (accum, [b])) -> accum -> Conduit a m b
concatMapAccumMC = undefined

encodeUtf8C :: (Monad m, Utf8 text binary) => Conduit text m binary
encodeUtf8C = undefined

decodeUtf8C :: MonadThrow m => Conduit ByteString m Text
decodeUtf8C = undefined

lineC :: (Monad m, IsSequence seq, Element seq ~ Char)
      => Conduit seq m o -> Conduit seq m o
lineC = undefined

lineAsciiC :: (Monad m, IsSequence seq, Element seq ~ Word8)
           => Conduit seq m o -> Conduit seq m o
lineAsciiC = undefined

unlinesC :: (Monad m, IsSequence seq, Element seq ~ Char) => Conduit seq m seq
unlinesC = undefined

unlinesAsciiC :: (Monad m, IsSequence seq, Element seq ~ Word8)
              => Conduit seq m seq
unlinesAsciiC = undefined

linesUnboundedC :: (Monad m, IsSequence seq, Element seq ~ Char)
                => Conduit seq m seq
linesUnboundedC = undefined

linesUnboundedAsciiC :: (Monad m, IsSequence seq, Element seq ~ Word8)
                     => Conduit seq m seq
linesUnboundedAsciiC = undefined
