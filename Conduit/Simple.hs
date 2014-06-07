{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}

-- | Please see the project README for more details:
--
--   https://github.com/jwiegley/simple-conduit/blob/master/README.md
--
--   Also see this blog article:
--
--   https://www.newartisans.com/2014/06/simpler-conduit-library

module Conduit.Simple where

import           Control.Applicative
import           Control.Concurrent.Async.Lifted
import           Control.Exception.Lifted
import           Control.Monad hiding (mapM)
import           Control.Monad.Base
import           Control.Monad.Catch hiding (bracket)
import           Control.Monad.IO.Class
import           Control.Monad.Morph
import           Control.Monad.Primitive
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Control
import           Control.Monad.Trans.Either
import           Control.Monad.Trans.State
import           Data.Bifunctor
import           Data.Builder
import           Data.ByteString hiding (hPut, putStrLn)
import           Data.IOData
import           Data.MonoTraversable
import           Data.Monoid
import           Data.NonNull as NonNull
import           Data.Sequences as Seq
import           Data.Sequences.Lazy
import qualified Data.Streaming.Filesystem as F
import           Data.Text
import           Data.Textual.Encoding
import           Data.Traversable
import           Data.Vector.Generic hiding (mapM, foldM, modify)
import           Data.Word
import           Prelude hiding (mapM)
import           System.FilePath ((</>))
import           System.IO
import           System.Random.MWC as MWC

-- | In the type variable below, r stands for "result", with much the same
--   meaning as you find in 'ContT'.  a is the type of each element in the
--   "stream".  The type of Source should recall 'foldM':
--
-- @
-- Monad m => (a -> b -> m a) -> a -> [b] -> m a
-- @
--
-- 'EitherT' is used to signal short-circuiting of the pipeline.
type Source m a r    = r -> (r -> a -> EitherT r m r) -> EitherT r m r
type Conduit a m b r = Source m a r -> Source m b r
type Sink a m r      = Source m a r -> m r

-- | Promote any sink to a source.  This can be used as if it were a source
--   transformer (aka, a conduit):
--
-- >>> sinkList $ returnC $ sumC $ mapC (+1) $ sourceList [1..10]
-- [65]
returnC :: Monad m => m a -> Source m a r
returnC f z yield = yield z =<< lift f

-- | Compose a 'Source' and a 'Conduit' into a new 'Source'.  Note that this
--   is just flipped function application, so ($) can be used to achieve the
--   same thing.
infixl 1 $=
($=) :: a -> (a -> b) -> b
($=) = flip ($)
{-# INLINE ($=) #-}

-- | Compose a 'Conduit' and a 'Sink' into a new 'Sink'.  Note that this is
--   just function composition, so (.) can be used to achieve the same thing.
infixr 2 =$
(=$) :: (a -> b) -> (b -> c) -> a -> c
(=$) = flip (.)
{-# INLINE (=$) #-}

-- | Compose a 'Source' and a 'Sink' and compute the result.  Note that this
--   is just flipped function application, so ($) can be used to achieve the
--   same thing.
infixr 0 $$
($$) :: a -> (a -> b) -> b
($$) = flip ($)
{-# INLINE ($$) #-}

-- | Since Sources are not Monads in this library (as they are in the full
--   conduit library), they can be sequentially "chained" using this append
--   operator.  If Source were a newtype, we could make it an instance of
--   Monoid.
infixr 3 <+>
(<+>) :: Monad m => Source m a r -> Conduit a m a r
x <+> y = \r f -> flip y f =<< x r f
{-# INLINE (<+>) #-}

-- | This is just like 'Control.Monad.Trans.Either.bimapEitherT', but it only
--   requires a 'Monad' constraint rather than 'Functor'.
rewrap :: Monad m => (a -> b) -> EitherT a m a -> EitherT b m b
rewrap f k = EitherT $ bimap f f `liftM` runEitherT k
{-# INLINE rewrap #-}

rewrapM :: Monad m => (a -> EitherT b m b) -> EitherT a m a -> EitherT b m b
rewrapM f k = EitherT $ do
    eres <- runEitherT k
    runEitherT $ either f f eres
{-# INLINE rewrapM #-}

resolve :: Monad m => (r -> a -> EitherT r m r) -> r -> a -> m r
resolve await z f = either id id `liftM` runEitherT (await z f)
{-# INLINE resolve #-}

yieldMany :: (Monad m, MonoFoldable mono) => mono -> Source m (Element mono) r
yieldMany xs z yield = ofoldlM yield z xs
{-# INLINE yieldMany #-}

yieldOne :: Monad m => a -> Source m a r
yieldOne x z yield = yield z x
{-# INLINE yieldOne #-}

unfoldC :: Monad m => (b -> Maybe (a, b)) -> b -> Source m a r
unfoldC f i z yield = go i z
  where
    go x y = case f x of
        Nothing      -> return y
        Just (a, x') -> go x' =<< yield y a

enumFromToC :: (Monad m, Enum a, Eq a) => a -> a -> Source m a r
enumFromToC start stop z yield = go start z
  where
    go a r
        | a == stop = return r
        | otherwise = go (succ a) =<< yield r a

iterateC :: Monad m => (a -> a) -> a -> Source m a r
iterateC f i z yield = go i z
  where
    go x y = let x' = f x
             in go x' =<< yield y x'

repeatC :: Monad m => a -> Source m a r
repeatC x z yield = go z where go y = go =<< yield y x
{-# INLINE repeatC #-}

replicateC :: Monad m => Int -> a -> Source m a r
replicateC n x z yield = go n z
  where
    go n' y
        | n' >= 0   = go (n' - 1) =<< yield y x
        | otherwise = return y

sourceLazy :: (Monad m, LazySequence lazy strict) => lazy -> Source m strict r
sourceLazy = yieldMany . toChunks
{-# INLINE sourceLazy #-}

repeatMC :: Monad m => m a -> Source m a r
repeatMC x z yield = go z where go y = go =<< yield y =<< lift x

repeatWhileMC :: Monad m => m a -> (a -> Bool) -> Source m a r
repeatWhileMC m f z yield = go z
  where
    go r = do
        x <- lift m
        if f x
            then go =<< yield r x
            else return r

replicateMC :: Monad m => Int -> m a -> Source m a r
replicateMC n m z yield = go n z
  where
    go n' r | n' > 0 = go (n' - 1) =<< yield r =<< lift m
    go _ r = return r

sourceHandle :: (MonadIO m, IOData a) => Handle -> Source m a r
sourceHandle h z yield = go z
  where
    go y = do
        x <- liftIO $ hGetChunk h
        if onull x
            then return y
            else go =<< yield y x

sourceFile :: (MonadBaseControl IO m, MonadIO m, IOData a)
           => FilePath -> Source m a r
sourceFile path z yield =
    bracket
        (liftIO $ openFile path ReadMode)
        (liftIO . hClose)
        (\h -> sourceHandle h z yield)

sourceIOHandle :: (MonadBaseControl IO m, MonadIO m, IOData a)
               => IO Handle -> Source m a r
sourceIOHandle f z yield =
    bracket
        (liftIO f)
        (liftIO . hClose)
        (\h -> sourceHandle h z yield)

stdinC :: (MonadBaseControl IO m, MonadIO m, IOData a) => Source m a r
stdinC = sourceHandle stdin

initRepeat :: Monad m => m seed -> (seed -> m a) -> Source m a r
initRepeat mseed f z yield =
    lift mseed >>= \seed -> repeatMC (f seed) z yield

initReplicate :: Monad m => m seed -> (seed -> m a) -> Int -> Source m a r
initReplicate mseed f n z yield =
    lift mseed >>= \seed -> replicateMC n (f seed) z yield

sourceRandom :: (Variate a, MonadIO m) => Source m a r
sourceRandom =
    initRepeat (liftIO MWC.createSystemRandom) (liftIO . MWC.uniform)

sourceRandomN :: (Variate a, MonadIO m) => Int -> Source m a r
sourceRandomN =
    initReplicate (liftIO MWC.createSystemRandom) (liftIO . MWC.uniform)

sourceRandomGen :: (Variate a, MonadBase base m, PrimMonad base)
                => Gen (PrimState base) -> Source m a r
sourceRandomGen gen = initRepeat (return gen) (liftBase . MWC.uniform)

sourceRandomNGen :: (Variate a, MonadBase base m, PrimMonad base)
                 => Gen (PrimState base) -> Int -> Source m a r
sourceRandomNGen gen = initReplicate (return gen) (liftBase . MWC.uniform)

sourceDirectory :: (MonadBaseControl IO m, MonadIO m)
                => FilePath -> Source m FilePath r
sourceDirectory dir z yield =
    bracket
        (liftIO (F.openDirStream dir))
        (liftIO . F.closeDirStream)
        (go z)
  where
    go y ds = loop y
      where
        loop r = do
            mfp <- liftIO $ F.readDirStream ds
            case mfp of
                Nothing -> return r
                Just fp -> loop =<< yield r (dir </> fp)

sourceDirectoryDeep :: (MonadBaseControl IO m, MonadIO m)
                    => Bool -> FilePath -> Source m FilePath r
sourceDirectoryDeep followSymlinks startDir z yield =
    start startDir z
  where
    start dir r = sourceDirectory dir r go

    go r fp = do
        ft <- liftIO $ F.getFileType fp
        case ft of
            F.FTFile -> yield r fp
            F.FTFileSym -> yield r fp
            F.FTDirectory -> start fp r
            F.FTDirectorySym
                | followSymlinks -> start fp r
                | otherwise -> return r
            F.FTOther -> return r

dropC :: Monad m => Int -> Source m a (Int, r) -> Source m a r
dropC n await z yield = rewrap snd $ await (n, z) go
  where
    go (n', r) _ | n' > 0 = return (n' - 1, r)
    go (_, r) x = rewrap (0,) $ yield r x

dropCE :: (Monad m, IsSequence seq)
       => Index seq -> Source m seq (Index seq, r) -> Source m seq r
dropCE n await z yield = rewrap snd $ await (n, z) go
  where
    go  (n', r) s
        | onull y   = return (n' - xn, r)
        | otherwise = rewrap (0,) $ yield r y
      where
        (x, y) = Seq.splitAt n' s
        xn = n' - fromIntegral (olength x)

dropWhileC :: Monad m => (a -> Bool) -> Source m a (a -> Bool, r) -> Source m a r
dropWhileC f await z yield = rewrap snd $ await (f, z) go
  where
    go (k, r) x | k x = return (k, r)
    go (_, r) x = rewrap (const False,) $ yield r x

dropWhileCE :: (Monad m, IsSequence seq)
            => (Element seq -> Bool) -> Source m seq (Element seq -> Bool, r)
            -> Source m seq r
dropWhileCE f await z yield = rewrap snd $ await (f, z) go
  where
    go  (k, r) s
        | onull x   = return (k, r)
        | otherwise = rewrap (const False,) $ yield r s
      where
        x = Seq.dropWhile k s

foldC :: (Monad m, Monoid a) => Sink a m a
foldC = foldMapC id

foldCE :: (Monad m, MonoFoldable mono, Monoid (Element mono))
       => Sink mono m (Element mono)
foldCE = foldlC (\acc mono -> acc <> ofoldMap id mono) mempty

foldlC :: Monad m => (a -> b -> a) -> a -> Sink b m a
foldlC f z await = resolve await z ((return .) . f)
{-# INLINE foldlC #-}

foldlCE :: (Monad m, MonoFoldable mono)
        => (a -> Element mono -> a) -> a -> Sink mono m a
foldlCE f = foldlC (ofoldl' f)

foldMapC :: (Monad m, Monoid b) => (a -> b) -> Sink a m b
foldMapC f = foldlC (\acc x -> acc <> f x) mempty

foldMapCE :: (Monad m, MonoFoldable mono, Monoid w)
          => (Element mono -> w) -> Sink mono m w
foldMapCE = foldMapC . ofoldMap

allC :: Monad m => (a -> Bool) -> Source m a All -> m Bool
allC f = liftM getAll `liftM` foldMapC (All . f)

allCE :: (Monad m, MonoFoldable mono)
      => (Element mono -> Bool) -> Source m mono All -> m Bool
allCE = allC . oall

anyC :: Monad m => (a -> Bool) -> Source m a Any -> m Bool
anyC f = liftM getAny `liftM` foldMapC (Any . f)

anyCE :: (Monad m, MonoFoldable mono)
      => (Element mono -> Bool) -> Source m mono Any -> m Bool
anyCE = anyC . oany

andC :: Monad m => Source m Bool All -> m Bool
andC = allC id

andCE :: (Monad m, MonoFoldable mono, Element mono ~ Bool)
      => Source m mono All -> m Bool
andCE = allCE id

orC :: Monad m => Source m Bool Any -> m Bool
orC = anyC id

orCE :: (Monad m, MonoFoldable mono, Element mono ~ Bool)
     => Source m mono Any -> m Bool
orCE = anyCE id

elemC :: (Monad m, Eq a) => a -> Source m a Any -> m Bool
elemC x = anyC (== x)

elemCE :: (Monad m, EqSequence seq) => Element seq -> Source m seq Any -> m Bool
elemCE = anyC . Seq.elem

notElemC :: (Monad m, Eq a) => a -> Source m a All -> m Bool
notElemC x = allC (/= x)

notElemCE :: (Monad m, EqSequence seq) => Element seq -> Source m seq All -> m Bool
notElemCE = allC . Seq.notElem

produceList :: Monad m => ([a] -> b) -> Source m a ([a] -> [a]) -> m b
produceList f await =
    (f . ($ [])) `liftM`
        resolve await id (\front x -> front `seq` return (front . (x:)))
{-# INLINE produceList #-}

sinkLazy :: (Monad m, LazySequence lazy strict)
         => Source m strict ([strict] -> [strict]) -> m lazy
sinkLazy = produceList fromChunks
-- {-# INLINE sinkLazy #-}

sinkList :: Monad m => Source m a ([a] -> [a]) -> m [a]
sinkList = produceList id
{-# INLINE sinkList #-}

sinkVector :: (MonadBase base m, Vector v a, PrimMonad base)
           => Sink a m (v a)
sinkVector = undefined

sinkVectorN :: (MonadBase base m, Vector v a, PrimMonad base)
            => Int -> Sink a m (v a)
sinkVectorN = undefined

sinkBuilder :: (Monad m, Monoid builder, ToBuilder a builder)
            => Sink a m builder
sinkBuilder = foldMapC toBuilder

sinkLazyBuilder :: (Monad m, Monoid builder, ToBuilder a builder,
                    Builder builder lazy)
                => Source m a builder -> m lazy
sinkLazyBuilder = liftM builderToLazy . foldMapC toBuilder

sinkNull :: Monad m => Sink a m ()
sinkNull _ = return ()

awaitNonNull :: (Monad m, MonoFoldable a) => Conduit a m (Maybe (NonNull a)) r
awaitNonNull await z yield = await z $ \r x ->
    maybe (return r) (yield r . Just) (NonNull.fromNullable x)

headCE :: (Monad m, IsSequence seq) => Sink seq m (Maybe (Element seq))
headCE = undefined

-- newtype Pipe a m b = Pipe { runPipe :: Sink a m b }

-- instance Monad m => Functor (Pipe a m) where
--     fmap f (Pipe p) = Pipe $ liftM f . p

-- instance Monad m => Monad (Pipe a m) where
--     return x = Pipe $ \_ -> return x
--     Pipe p >>= f = Pipe $ \await -> do
--         x <- p await
--         runPipe (f x) await

-- dropC' :: Monad m => Int -> Sink a m ()
-- dropC' n await = rewrap snd $ await n go
--   where
--     go (n', r) _ | n' > 0 = return (n' - 1, r)
--     go (_, r) x = rewrap (0,) $ yield r x

-- test :: IO [Int]
-- test = flip runPipe (yieldMany [1..10]) $ do
--     Pipe $ dropC' 2
--     Pipe sinkList

-- leftover :: Monad m => a -> ResumableSource m a r
-- leftover l z _ = lift (modify (Sequence.|> l)) >> return z

-- jww (2014-06-07): These two cannot be implemented without leftover support.
-- peekC :: Monad m => Sink a m (Maybe a)
-- peekC = undefined

-- peekCE :: (Monad m, MonoFoldable mono) => Sink mono m (Maybe (Element mono))
-- peekCE = undefined

lastC :: Monad m => Sink a m (Maybe a)
lastC await = resolve await Nothing (const (return . Just))

lastCE :: (Monad m, IsSequence seq) => Sink seq m (Maybe (Element seq))
lastCE = undefined

lengthC :: (Monad m, Num len) => Sink a m len
lengthC = foldlC (\x _ -> x + 1) 0

lengthCE :: (Monad m, Num len, MonoFoldable mono) => Sink mono m len
lengthCE = foldlC (\x y -> x + fromIntegral (olength y)) 0

lengthIfC :: (Monad m, Num len) => (a -> Bool) -> Sink a m len
lengthIfC f = foldlC (\cnt a -> if f a then cnt + 1 else cnt) 0

lengthIfCE :: (Monad m, Num len, MonoFoldable mono)
           => (Element mono -> Bool) -> Sink mono m len
lengthIfCE f = foldlCE (\cnt a -> if f a then cnt + 1 else cnt) 0

maximumC :: (Monad m, Ord a) => Sink a m (Maybe a)
maximumC await = resolve await Nothing $ \r y ->
    return $ Just $ case r of
        Just x -> max x y
        _      -> y

maximumCE :: (Monad m, OrdSequence seq) => Sink seq m (Maybe (Element seq))
maximumCE = undefined

minimumC :: (Monad m, Ord a) => Sink a m (Maybe a)
minimumC await = resolve await Nothing $ \r y ->
    return $ Just $ case r of
        Just x -> min x y
        _      -> y

minimumCE :: (Monad m, OrdSequence seq) => Sink seq m (Maybe (Element seq))
minimumCE = undefined

-- jww (2014-06-07): These two cannot be implemented without leftover support.
-- nullC :: Monad m => Sink a m Bool
-- nullC = undefined

-- nullCE :: (Monad m, MonoFoldable mono) => Sink mono m Bool
-- nullCE = undefined

sumC :: (Monad m, Num a) => Sink a m a
sumC = foldlC (+) 0

sumCE :: (Monad m, MonoFoldable mono, Num (Element mono))
      => Sink mono m (Element mono)
sumCE = undefined

productC :: (Monad m, Num a) => Sink a m a
productC = foldlC (*) 1

productCE :: (Monad m, MonoFoldable mono, Num (Element mono))
          => Sink mono m (Element mono)
productCE = undefined

findC :: Monad m => (a -> Bool) -> Sink a m (Maybe a)
findC f await = resolve await Nothing $ \r x ->
    if f x then left (Just x) else return r

mapM_C :: Monad m => (a -> m ()) -> Sink a m ()
mapM_C f await = resolve await () (const $ lift . f)
{-# INLINE mapM_C #-}

mapM_CE :: (Monad m, MonoFoldable mono)
        => (Element mono -> m ()) -> Sink mono m ()
mapM_CE = undefined

foldMC :: Monad m => (a -> b -> m a) -> a -> Sink b m a
foldMC f z await = resolve await z (\r x -> lift (f r x))

foldMCE :: (Monad m, MonoFoldable mono)
        => (a -> Element mono -> m a) -> a -> Sink mono m a
foldMCE = undefined

foldMapMC :: (Monad m, Monoid w) => (a -> m w) -> Sink a m w
foldMapMC f = foldMC (\acc x -> (acc <>) `liftM` f x) mempty

foldMapMCE :: (Monad m, MonoFoldable mono, Monoid w)
           => (Element mono -> m w) -> Sink mono m w
foldMapMCE = undefined

sinkFile :: (MonadBaseControl IO m, MonadIO m, IOData a)
         => FilePath -> Sink a m ()
sinkFile fp = sinkIOHandle (liftIO $ openFile fp WriteMode)

sinkHandle :: (MonadIO m, IOData a) => Handle -> Sink a m ()
sinkHandle = mapM_C . hPut

sinkIOHandle :: (MonadBaseControl IO m, MonadIO m, IOData a)
             => IO Handle -> Sink a m ()
sinkIOHandle alloc =
    bracket
        (liftIO alloc)
        (liftIO . hClose)
        . flip sinkHandle

printC :: (Show a, MonadIO m) => Sink a m ()
printC = mapM_C (liftIO . print)

stdoutC :: (MonadIO m, IOData a) => Sink a m ()
stdoutC = sinkHandle stdout

stderrC :: (MonadIO m, IOData a) => Sink a m ()
stderrC = sinkHandle stderr

mapC :: Monad m => (a -> b) -> Conduit a m b r
mapC f await z yield = await z $ \acc x ->
    let y = f x in y `seq` acc `seq` yield acc y
{-# INLINE mapC #-}

mapCE :: (Monad m, Functor f) => (a -> b) -> Conduit (f a) m (f b) r
mapCE = undefined

omapCE :: (Monad m, MonoFunctor mono)
       => (Element mono -> Element mono) -> Conduit mono m mono r
omapCE = undefined

concatMapC :: (Monad m, MonoFoldable mono)
           => (a -> mono) -> Conduit a m (Element mono) r
concatMapC f await z yield = await z $ \r x -> ofoldlM yield r (f x)

concatMapCE :: (Monad m, MonoFoldable mono, Monoid w)
            => (Element mono -> w) -> Conduit mono m w r
concatMapCE = undefined

takeC :: Monad m => Int -> Source m a (Int, r) -> Source m a r
takeC n await z yield = rewrap snd $ await (n, z) go
  where
    go (n', z') x
        | n' > 1    = next
        | n' > 0    = left =<< next
        | otherwise = left (0, z')
      where
        next = rewrap (n' - 1,) $ yield z' x

takeCE :: (Monad m, IsSequence seq) => Index seq -> Conduit seq m seq r
takeCE = undefined

-- | This function reads one more element than it yields, which would be a
--   problem if Sinks were monadic, as they are in conduit or pipes.  There is
--   no such concept as "resuming where the last conduit left off" in this
--   library.
takeWhileC :: Monad m => (a -> Bool) -> Source m a (a -> Bool, r) -> Source m a r
takeWhileC f await z yield = rewrap snd $ await (f, z) go
  where
    go (k, z') x | k x = rewrap (k,) $ yield z' x
    go (_, z') _ = left (const False, z')

takeWhileCE :: (Monad m, IsSequence seq)
            => (Element seq -> Bool) -> Conduit seq m seq r
takeWhileCE = undefined

takeExactlyC :: Monad m => Int -> Conduit a m b r -> Conduit a m b r
takeExactlyC = undefined

takeExactlyCE :: (Monad m, IsSequence a)
              => Index a -> Conduit a m b r -> Conduit a m b r
takeExactlyCE = undefined

concatC :: (Monad m, MonoFoldable mono) => Conduit mono m (Element mono) r
concatC = undefined

filterC :: Monad m => (a -> Bool) -> Conduit a m a r
filterC f await z yield =
    await z $ \r x -> if f x then yield r x else return r

filterCE :: (IsSequence seq, Monad m)
         => (Element seq -> Bool) -> Conduit seq m seq r
filterCE = undefined

mapWhileC :: Monad m => (a -> Maybe b) -> Conduit a m b r
mapWhileC f await z yield = await z $ \z' x ->
    maybe (left z') (yield z') (f x)

conduitVector :: (MonadBase base m, Vector v a, PrimMonad base)
              => Int -> Conduit a m (v a) r
conduitVector = undefined

scanlC :: Monad m => (a -> b -> a) -> a -> Conduit b m a r
scanlC = undefined

concatMapAccumC :: Monad m => (a -> accum -> (accum, [b])) -> accum -> Conduit a m b r
concatMapAccumC = undefined

intersperseC :: Monad m => a -> Source m a (Maybe a, r) -> Source m a r
intersperseC s await z yield = EitherT $ do
    eres <- runEitherT $ await (Nothing, z) $ \(my, r) x ->
        case my of
            Nothing ->
                return (Just x, r)
            Just y  -> do
                r' <- rewrap (Nothing,) $ yield r y
                rewrap (Just x,) $ yield (snd r') s
    case eres of
        Left (_, r)        -> return $ Left r
        Right (Nothing, r) -> return $ Right r
        Right (Just x, r)  -> runEitherT $ yield r x

encodeBase64C :: Monad m => Conduit ByteString m ByteString r
encodeBase64C = undefined

decodeBase64C :: Monad m => Conduit ByteString m ByteString r
decodeBase64C = undefined

encodeBase64URLC :: Monad m => Conduit ByteString m ByteString r
encodeBase64URLC = undefined

decodeBase64URLC :: Monad m => Conduit ByteString m ByteString r
decodeBase64URLC = undefined

encodeBase16C :: Monad m => Conduit ByteString m ByteString r
encodeBase16C = undefined

decodeBase16C :: Monad m => Conduit ByteString m ByteString r
decodeBase16C = undefined

mapMC :: Monad m => (a -> m b) -> Conduit a m b r
mapMC f await z yield = await z (\r x -> yield r =<< lift (f x))
{-# INLINE mapMC #-}

mapMCE :: (Monad m, Traversable f) => (a -> m b) -> Conduit (f a) m (f b) r
mapMCE = undefined

omapMCE :: (Monad m, MonoTraversable mono)
        => (Element mono -> m (Element mono)) -> Conduit mono m mono r
omapMCE = undefined

concatMapMC :: (Monad m, MonoFoldable mono)
            => (a -> m mono) -> Conduit a m (Element mono) r
concatMapMC = undefined

filterMC :: Monad m => (a -> m Bool) -> Conduit a m a r
filterMC f await z yield = await z $ \z' x -> do
    res <- lift $ f x
    if res
        then yield z' x
        else return z'

filterMCE :: (Monad m, IsSequence seq)
          => (Element seq -> m Bool) -> Conduit seq m seq r
filterMCE = undefined

iterMC :: Monad m => (a -> m ()) -> Conduit a m a r
iterMC = undefined

scanlMC :: Monad m => (a -> b -> m a) -> a -> Conduit b m a r
scanlMC = undefined

concatMapAccumMC :: Monad m
                 => (a -> accum -> m (accum, [b])) -> accum -> Conduit a m b r
concatMapAccumMC = undefined

encodeUtf8C :: (Monad m, Utf8 text binary) => Conduit text m binary r
encodeUtf8C = mapC encodeUtf8

decodeUtf8C :: MonadThrow m => Conduit ByteString m Text r
decodeUtf8C = undefined

lineC :: (Monad m, IsSequence seq, Element seq ~ Char)
      => Conduit seq m o r -> Conduit seq m o r
lineC = undefined

lineAsciiC :: (Monad m, IsSequence seq, Element seq ~ Word8)
           => Conduit seq m o r -> Conduit seq m o r
lineAsciiC = undefined

unlinesC :: (Monad m, IsSequence seq, Element seq ~ Char) => Conduit seq m seq r
unlinesC = concatMapC (:[Seq.singleton '\n'])

unlinesAsciiC :: (Monad m, IsSequence seq, Element seq ~ Word8)
              => Conduit seq m seq r
unlinesAsciiC = concatMapC (:[Seq.singleton 10])

linesUnboundedC_ :: (Monad m, IsSequence seq, Eq (Element seq))
                 => Element seq -> Source m seq (r, seq) -> Source m seq r
linesUnboundedC_ sep await z yield = EitherT $ do
    eres <- runEitherT $ await (z, n) go
    case eres of
        Left (r, _)  -> return $ Left r
        Right (r, t)
            | onull t   -> return $ Right r
            | otherwise -> runEitherT $ yield r t
  where
    n = Seq.fromList []

    go (r, t') t
        | onull y = return (r, t <> t')
        | otherwise = do
            r' <- rewrap (, n) $ yield r (t' <> x)
            go r' (Seq.drop 1 y)
      where
        (x, y) = Seq.break (== sep) t

linesUnboundedC :: (Monad m, IsSequence seq, Element seq ~ Char)
                => Source m seq (r, seq) -> Source m seq r
linesUnboundedC = linesUnboundedC_ '\n'

linesUnboundedAsciiC :: (Monad m, IsSequence seq, Element seq ~ Word8)
                     => Source m seq (r, seq) -> Source m seq r
linesUnboundedAsciiC = linesUnboundedC_ 10

-- | The use of 'awaitForever' in this library is just a bit different from
--   conduit:
--
-- >>> awaitForever $ \x yield skip -> if even x then yield x else skip
awaitForever :: Monad m
             => (a -> (b -> EitherT r m r) -> EitherT r m r
                 -> EitherT r m r)
             -> Conduit a m b r
awaitForever f await z yield =
    await z $ \r x -> f x (yield r) (return r)

zipSourceApp :: Monad m => Source m (x -> y) r -> Source m x r -> Source m y r
zipSourceApp f arg z yield = f z $ \r x -> arg r $ \_ y -> yield z (x y)

newtype ZipSource m r a = ZipSource { getZipSource :: Source m a r }

instance Monad m => Functor (ZipSource m r) where
    fmap f (ZipSource p) = ZipSource $ \z yield -> p z $ \r x -> yield r (f x)

instance Monad m => Applicative (ZipSource m r) where
    pure x = ZipSource $ yieldOne x
    ZipSource l <*> ZipSource r = ZipSource (zipSourceApp l r)

-- | Sequence a collection of sources, feeding them all the same input and
--   yielding a collection of their results.
--
-- >>> sinkList $ sequenceSources [yieldOne 1, yieldOne 2, yieldOne 3]
-- [[1,2,3]]
sequenceSources :: (Traversable f, Monad m)
                => f (Source m a r) -> Source m (f a) r
sequenceSources = getZipSource . sequenceA . fmap ZipSource

instance MFunctor (EitherT s) where
  hoist f (EitherT m) = EitherT $ f m

-- | Zip sinks together.  This function may be used multiple times:
--
-- >>> let mySink s await => resolve await () $ \() x -> liftIO $ print $ s <> show x
-- >>> zipSinks sinkList (zipSinks (mySink "foo") (mySink "bar")) $ yieldMany [1,2,3]
-- "foo: 1"
-- "bar: 1"
-- "foo: 2"
-- "bar: 2"
-- "foo: 3"
-- "bar: 3"
-- ([1,2,3],((),()))
zipSinks :: Monad m
         => (Source (StateT (r', s) m) i s  -> StateT (r', s) m r)
         -> (Source (StateT (r', s) m) i s' -> StateT (r', s) m r')
         -> Source m i (s, s') -> m (r, r')
zipSinks x y await = do
    let i = (error "accessing r", error "accessing r'")
    flip evalStateT i $ do
        r <- x $ \rx yieldx -> do
            r' <- lift $ y $ \ry yieldy -> EitherT $ do
                    st <- get
                    eres <- lift $ runEitherT $ await (rx, ry) $ \(rx', ry') u -> do
                        x' <- stripS st $ rewrap (, ry') $ yieldx rx' u
                        y' <- stripS st $ rewrap (rx' ,) $ yieldy ry' u
                        return (fst x', snd y')
                    let (s, s') = either id id eres
                    modify (\(b, _) -> (b, s))
                    return $ Right s'
            lift $ do
                modify (\(_, b) -> (r', b))
                gets snd
        r' <- gets fst
        return (r, r')
  where
    stripS :: (MFunctor t, Monad n) => b1 -> t (StateT b1 n) b -> t n b
    stripS s = hoist (`evalStateT` s)

newtype ZipSink i m r s = ZipSink { getZipSink :: Source m i r -> m s }

instance Monad m => Functor (ZipSink i m r) where
    fmap f (ZipSink k) = ZipSink $ liftM f . k

instance Monad m => Applicative (ZipSink i m r) where
    pure x = ZipSink $ \_ -> return x
    ZipSink f <*> ZipSink x =
         ZipSink $ \await -> f await `ap` x await

-- | Send incoming values to all of the @Sink@ providing, and ultimately
-- coalesce together all return values.
--
-- Implemented on top of @ZipSink@, see that data type for more details.
--
-- Since 1.0.13
sequenceSinks :: (Traversable f, Monad m)
              => f (Source m i r -> m s) -> Source m i r -> m (f s)
sequenceSinks = getZipSink . sequenceA . fmap ZipSink

asyncC :: (MonadBaseControl IO m, Monad m)
       => (a -> m b) -> Conduit a m (Async (StM m b)) r
asyncC f await k yield = do
    res <- async $ await k $ \r x ->
        yield r =<< lift (async (f x))
    wait res
