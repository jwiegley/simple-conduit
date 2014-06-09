{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}

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
import           Control.Concurrent.STM
import           Control.Exception.Lifted
import           Control.Foldl
import           Control.Monad hiding (mapM)
import           Control.Monad.Base
import           Control.Monad.Catch hiding (bracket, catch)
import           Control.Monad.IO.Class
import           Control.Monad.Morph
import           Control.Monad.Primitive
import           Control.Monad.Trans.Cont
import           Control.Monad.Trans.Control
import           Control.Monad.Trans.Either
import           Control.Monad.Trans.State
import           Control.Monad.Trans.Writer
import           Data.Bifunctor
import           Data.Builder
import           Data.ByteString hiding (hPut, putStrLn)
import           Data.Foldable
import           Data.Functor.Identity
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
import           Data.Word
import           Prelude hiding (mapM)
import           System.FilePath ((</>))
import           System.IO
import           System.Random.MWC as MWC
import Debug.Trace

-- | In the type variable below, r stands for "result", with much the same
--   meaning as you find in 'ContT'.  a is the type of each element in the
--   "stream".  The type of Source should recall 'foldM':
--
-- @
-- Monad m => (a -> b -> m a) -> a -> [b] -> m a
-- @
--
-- 'EitherT' is used to signal short-circuiting of the pipeline.
type CollectT r m = ContT () (StateT r m)

type Source m a    = (a -> m ()) -> m ()
type Conduit a m b = Source m a -> Source m b
type Sink a m r    = Source (CollectT r m) a -> m r

-- | When wrapped in a 'SourceWrapper' using 'wrap', Sources offer a number of
--   typeclass instances, one of which is Monad.  As a Monad, it behaves very
--   much list the list monad: the value bound is each element of the
--   iteration in turn.
--
-- @
-- sinkList $ getSource $ do
--     x <- wrap $ yieldMany [1..3]
--     y <- wrap $ yieldMany [4..6]
--     wrap $ yieldOne (x, y)
--
-- ==> [(1,4),(1,5),(1,6),(2,4),(2,5),(2,6),(3,4),(3,5),(3,6)]
-- @
newtype SourceWrapper m a = SourceWrapper { getSource :: Source m a }

wrap :: Source m a -> SourceWrapper m a
wrap = SourceWrapper

instance Monad m => Monoid (SourceWrapper m a) where
    mempty = SourceWrapper $ const $ return ()
    SourceWrapper x `mappend` SourceWrapper y = SourceWrapper $ x <+> y

-- instance Foldable (SourceWrapper (CollectT r Identity)) where
--     foldMap f (SourceWrapper await) =
--         runIdentity $
--             resolve mempty $ await $ \x -> lift $ modify (<> f x)

instance Functor (SourceWrapper m) where
    fmap f (SourceWrapper await) =
        SourceWrapper $ \yield -> await $ \x -> yield (f x)

instance Applicative (SourceWrapper m) where
    pure x = SourceWrapper $ \yield -> yield x
    SourceWrapper f <*> SourceWrapper g =
        SourceWrapper $ \yield ->
            f $ \x ->
                g $ \y ->
                    yield (x y)

instance Monad (SourceWrapper m) where
    return = pure
    SourceWrapper await >>= f =
        SourceWrapper $ \yield ->
            await $ \x ->
                getSource (f x) $ \y ->
                    yield y

newtype SinkWrapper a m r = SinkWrapper { getSink :: SourceWrapper m a -> m r }

instance Monad m => Functor (SinkWrapper a m) where
    fmap f (SinkWrapper k) = SinkWrapper $ \await -> f `liftM` k await

-- | Promote any sink to a source.  This can be used as if it were a source
--   transformer (aka, a conduit):
--
-- >>> sinkList $ returnC $ sumC $ mapC (+1) $ sourceList [1..10]
-- [65]
returnC :: Monad m => m a -> Source m a
returnC f yield = yield =<< f

exit :: Monad m => ContT () m r
exit = ContT $ \_ -> return ()

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

resolve :: Monad m => r -> CollectT r m () -> m r
resolve r m = execStateT (runContT m return) r
{-# INLINE resolve #-}

yieldMany :: (Monad m, MonoFoldable mono) => mono -> Source m (Element mono)
yieldMany xs yield = ofoldlM (const yield) () xs
{-# INLINE yieldMany #-}

yieldOne :: Monad m => a -> Source m a
yieldOne x yield = yield x
{-# INLINE yieldOne #-}

unfoldC :: Monad m => (b -> Maybe (a, b)) -> b -> Source m a
unfoldC f i yield = go i
  where
    go x = case f x of
        Nothing      -> return ()
        Just (a, x') -> yield a >> go x'

enumFromToC :: (Monad m, Enum a, Eq a) => a -> a -> Source m a
enumFromToC start stop yield = go start
  where
    go a
        | a == stop = return ()
        | otherwise = yield a >> go (succ a)

iterateC :: Monad m => (a -> a) -> a -> Source m a
iterateC f i yield = go i
  where
    go x = let x' = f x
           in yield x' >> go x'

repeatC :: Monad m => a -> Source m a
repeatC x yield = forever $ yield x
{-# INLINE repeatC #-}

replicateC :: Monad m => Int -> a -> Source m a
replicateC n x yield = go n
  where
    go n'
        | n' >= 0   = yield x >> go (n' - 1)
        | otherwise = return ()

sourceLazy :: (Monad m, LazySequence lazy strict) => lazy -> Source m strict
sourceLazy = yieldMany . toChunks
{-# INLINE sourceLazy #-}

repeatMC :: Monad m => m a -> Source m a
repeatMC x yield = go where go = x >>= yield >> go

repeatWhileMC :: Monad m => m a -> (a -> Bool) -> Source m a
repeatWhileMC m f yield = go
  where
    go = do
        x <- m
        if f x
            then yield x >> go
            else return ()

replicateMC :: Monad m => Int -> m a -> Source m a
replicateMC n m yield = go n
  where
    go n' | n' > 0 = m >>= yield >> go (n' - 1)
    go _ = return ()

sourceHandle :: (MonadIO m, IOData a) => Handle -> Source m a
sourceHandle h yield = go
  where
    go = do
        x <- liftIO $ hGetChunk h
        if onull x
            then return ()
            else yield x >> go

sourceFile :: (MonadBaseControl IO m, MonadIO m, IOData a)
           => FilePath -> Source m a
sourceFile path yield =
    bracket
        (liftIO $ openFile path ReadMode)
        (liftIO . hClose)
        (\h -> sourceHandle h yield)

sourceIOHandle :: (MonadBaseControl IO m, MonadIO m, IOData a)
               => IO Handle -> Source m a
sourceIOHandle f yield =
    bracket
        (liftIO f)
        (liftIO . hClose)
        (\h -> sourceHandle h yield)

stdinC :: (MonadBaseControl IO m, MonadIO m, IOData a) => Source m a
stdinC = sourceHandle stdin

initRepeat :: Monad m => m seed -> (seed -> m a) -> Source m a
initRepeat mseed f yield =
    mseed >>= \seed -> repeatMC (f seed) yield

initReplicate :: Monad m => m seed -> (seed -> m a) -> Int -> Source m a
initReplicate mseed f n yield =
    mseed >>= \seed -> replicateMC n (f seed) yield

sourceRandom :: (Variate a, MonadIO m) => Source m a
sourceRandom =
    initRepeat (liftIO MWC.createSystemRandom) (liftIO . MWC.uniform)

sourceRandomN :: (Variate a, MonadIO m) => Int -> Source m a
sourceRandomN =
    initReplicate (liftIO MWC.createSystemRandom) (liftIO . MWC.uniform)

sourceRandomGen :: (Variate a, MonadBase base m, PrimMonad base)
                => Gen (PrimState base) -> Source m a
sourceRandomGen gen = initRepeat (return gen) (liftBase . MWC.uniform)

sourceRandomNGen :: (Variate a, MonadBase base m, PrimMonad base)
                 => Gen (PrimState base) -> Int -> Source m a
sourceRandomNGen gen = initReplicate (return gen) (liftBase . MWC.uniform)

sourceDirectory :: (MonadBaseControl IO m, MonadIO m)
                => FilePath -> Source m FilePath
sourceDirectory dir yield =
    bracket
        (liftIO (F.openDirStream dir))
        (liftIO . F.closeDirStream)
        go
  where
    go ds = loop
      where
        loop = do
            mfp <- liftIO $ F.readDirStream ds
            case mfp of
                Nothing -> return ()
                Just fp -> yield (dir </> fp) >> loop

sourceDirectoryDeep :: (MonadBaseControl IO m, MonadIO m)
                    => Bool -> FilePath -> Source m FilePath
sourceDirectoryDeep followSymlinks startDir yield =
    start startDir
  where
    start dir = sourceDirectory dir go

    go fp = do
        ft <- liftIO $ F.getFileType fp
        case ft of
            F.FTFile -> yield fp
            F.FTFileSym -> yield fp
            F.FTDirectory -> start fp
            F.FTDirectorySym
                | followSymlinks -> start fp
                | otherwise -> return ()
            F.FTOther -> return ()

dropC :: Monad m => Int -> Source m a -> Source m a
dropC n await yield = flip evalStateT n $ await (\x -> get >>= go x)
  where
    go _ n' | n' > 0 = modify (n' - 1)
    go x _ = lift $ yield x

dropCE :: (Monad m, IsSequence seq)
       => Index seq -> Source m seq -> Source m seq
dropCE n await yield = flip evalStateT n $ await (\x -> get >>= go x)
  where
    go s n'
        | onull y   = modify (n' - xn)
        | otherwise = lift $ yield y
      where
        (x, y) = Seq.splitAt n' s
        xn = n' - fromIntegral (olength x)

dropWhileC :: Monad m => (a -> Bool) -> Source m a -> Source m a
dropWhileC f await yield = flip evalStateT f $ await (\x -> get >>= go x)
  where
    go x k | k x = return ()
    go x _ = do
        lift $ modify (const False,)
        yield x

dropWhileCE :: (Monad m, IsSequence seq)
            => (Element seq -> Bool) -> Source m seq
            -> Source m seq
dropWhileCE f await yield = flip evalStateT f $ await (\x -> get >>= go x)
  where
    go s k
        | onull x   = return ()
        | otherwise = lift $ modify (const False,) >> yield s
      where
        x = Seq.dropWhile k s

foldC :: (Monad m, Monoid a) => Sink a m a
foldC = foldMapC id

foldCE :: (Monad m, MonoFoldable mono, Monoid (Element mono))
       => Sink mono m (Element mono)
foldCE = foldlC (\acc mono -> acc <> ofoldMap id mono) mempty

foldlC :: Monad m => (a -> b -> a) -> a -> Sink b m a
foldlC f z await = resolve z $ await (\x -> lift $ modify (flip f x))
{-# INLINE foldlC #-}

foldlCE :: (Monad m, MonoFoldable mono)
        => (a -> Element mono -> a) -> a -> Sink mono m a
foldlCE f = foldlC (ofoldl' f)

foldMapC :: (Monad m, Monoid b) => (a -> b) -> Sink a m b
foldMapC f = foldlC (\acc x -> acc <> f x) mempty

foldMapCE :: (Monad m, MonoFoldable mono, Monoid w)
          => (Element mono -> w) -> Sink mono m w
foldMapCE = foldMapC . ofoldMap

allC :: Monad m => (a -> Bool) -> Sink a m Bool
allC f = liftM getAll `liftM` foldMapC (All . f)

allCE :: (Monad m, MonoFoldable mono)
      => (Element mono -> Bool) -> Sink mono m Bool
allCE = allC . oall

anyC :: Monad m => (a -> Bool) -> Sink a m Bool
anyC f = liftM getAny `liftM` foldMapC (Any . f)

anyCE :: (Monad m, MonoFoldable mono)
      => (Element mono -> Bool) -> Sink mono m Bool
anyCE = anyC . oany

andC :: Monad m => Sink Bool m Bool
andC = allC id

andCE :: (Monad m, MonoFoldable mono, Element mono ~ Bool)
      => Sink mono m Bool
andCE = allCE id

orC :: Monad m => Sink Bool m Bool
orC = anyC id

orCE :: (Monad m, MonoFoldable mono, Element mono ~ Bool)
     => Sink mono m Bool
orCE = anyCE id

elemC :: (Monad m, Eq a) => a -> Sink a m Bool
elemC x = anyC (== x)

elemCE :: (Monad m, EqSequence seq) => Element seq -> Sink seq m Bool
elemCE = anyC . Seq.elem

notElemC :: (Monad m, Eq a) => a -> Sink a m Bool
notElemC x = allC (/= x)

notElemCE :: (Monad m, EqSequence seq) => Element seq -> Sink seq m Bool
notElemCE = allC . Seq.notElem

produceList :: Monad m => ([a] -> b) -> Source (CollectT ([a] -> [a]) m) a -> m b
produceList f await =
    (f . ($ [])) `liftM` resolve id (await (\x -> lift $ modify (. (x:))))
{-# INLINE produceList #-}

sinkLazy :: (Monad m, LazySequence lazy strict)
         => Source (CollectT ([strict] -> [strict]) m) strict -> m lazy
sinkLazy = produceList fromChunks
-- {-# INLINE sinkLazy #-}

sinkList :: Monad m => Source (CollectT ([a] -> [a]) m) a -> m [a]
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
                => Source (CollectT builder m) a -> m lazy
sinkLazyBuilder = liftM builderToLazy . foldMapC toBuilder

sinkNull :: Monad m => Sink a m ()
sinkNull _ = return ()

-- jww (2014-06-09): NYI
-- awaitNonNull :: (Monad m, MonoFoldable a) => Conduit a m b
-- awaitNonNull await yield = await $ \x ->
--     maybe (return ()) (yield . Just) (NonNull.fromNullable x)

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

-- leftover :: Monad m => a -> ResumableSource m a
-- leftover l z _ = lift (modify (Sequence.|> l)) >> return z

-- jww (2014-06-07): These two cannot be implemented without leftover support.
-- peekC :: Monad m => Sink a m (Maybe a)
-- peekC = undefined

-- peekCE :: (Monad m, MonoFoldable mono) => Sink mono m (Maybe (Element mono))
-- peekCE = undefined

lastC :: Monad m => Sink a m (Maybe a)
lastC await = resolve Nothing $ await (return . Just)

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

mapC :: Monad m => (a -> b) -> Conduit a m b
mapC f await yield = await $ yield . f
{-# INLINE mapC #-}

mapC' :: Monad m => (a -> b) -> Conduit a m b
mapC' f await yield = await $ \x -> let y = f x in y `seq` yield y
{-# INLINE mapC' #-}

mapCE :: (Monad m, Functor f) => (a -> b) -> Conduit (f a) m (f b)
mapCE = undefined

omapCE :: (Monad m, MonoFunctor mono)
       => (Element mono -> Element mono) -> Conduit mono m mono
omapCE = undefined

concatMapC :: (Monad m, MonoFoldable mono)
           => (a -> mono) -> Conduit a m (Element mono)
concatMapC f await yield = await $ \x -> ofoldlM (const yield) (f x)

concatMapCE :: (Monad m, MonoFoldable mono, Monoid w)
            => (Element mono -> w) -> Conduit mono m w
concatMapCE = undefined

takeC :: Monad m => Int -> Source m a -> Source m a
takeC n await yield = flip evalStateT n $ await (\x -> get >>= go)
  where
    go x n'
        | n' > 1    = next
        | n' > 0    = ContT $ \_ -> next
        | otherwise = exit
      where
        next = modify (n' - 1,) >> yield x

takeCE :: (Monad m, IsSequence seq) => Index seq -> Conduit seq m seq
takeCE = undefined

-- | This function reads one more element than it yields, which would be a
--   problem if Sinks were monadic, as they are in conduit or pipes.  There is
--   no such concept as "resuming where the last conduit left off" in this
--   library.
takeWhileC :: Monad m => (a -> Bool) -> Source m a -> Source m a
takeWhileC f await yield = flip evalStateT f $ await (\x -> get >>= go)
  where
    go x k | k x = yield x
    go _ _ = exit

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
filterC f await yield =
    await $ \x -> if f x then yield x else return ()

filterCE :: (IsSequence seq, Monad m)
         => (Element seq -> Bool) -> Conduit seq m seq
filterCE = undefined

mapWhileC :: Monad m => (a -> Maybe b) -> Conduit a m b
mapWhileC f await yield = await $ \x ->
    maybe exit yield (f x)

conduitVector :: (MonadBase base m, Vector v a, PrimMonad base)
              => Int -> Conduit a m (v a)
conduitVector = undefined

scanlC :: Monad m => (a -> b -> a) -> a -> Conduit b m a
scanlC = undefined

concatMapAccumC :: Monad m => (a -> accum -> (accum, [b])) -> accum -> Conduit a m b
concatMapAccumC = undefined

-- jww (2014-06-09): Resurrect this
-- intersperseC :: Monad m => a -> Source m a -> Source m a
-- intersperseC s await yield = EitherT $ do
--     eres <- runEitherT $ await (Nothing, z) $ \(my, r) x ->
--         case my of
--             Nothing ->
--                 return (Just x, r)
--             Just y  -> do
--                 r' <- rewrap (Nothing,) $ yield r y
--                 rewrap (Just x,) $ yield (snd r') s
--     case eres of
--         Left (_, r)        -> return $ Left r
--         Right (Nothing, r) -> return $ Right r
--         Right (Just x, r)  -> runEitherT $ yield r x

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
mapMC f await yield = await (\x -> yield =<< lift (f x))
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
filterMC f await yield = await $ \x -> do
    res <- f x
    if res
        then yield x
        else return ()

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
encodeUtf8C = mapC encodeUtf8

decodeUtf8C :: MonadThrow m => Conduit ByteString m Text
decodeUtf8C = undefined

lineC :: (Monad m, IsSequence seq, Element seq ~ Char)
      => Conduit seq m o -> Conduit seq m o
lineC = undefined

lineAsciiC :: (Monad m, IsSequence seq, Element seq ~ Word8)
           => Conduit seq m o -> Conduit seq m o
lineAsciiC = undefined

unlinesC :: (Monad m, IsSequence seq, Element seq ~ Char) => Conduit seq m seq
unlinesC = concatMapC (:[Seq.singleton '\n'])

unlinesAsciiC :: (Monad m, IsSequence seq, Element seq ~ Word8)
              => Conduit seq m seq
unlinesAsciiC = concatMapC (:[Seq.singleton 10])

-- jww (2014-06-09): NYI
-- linesUnboundedC_ :: (Monad m, IsSequence seq, Eq (Element seq))
--                  => Element seq -> Source m seq -> Source m seq
-- linesUnboundedC_ sep await yield = EitherT $ do
--     eres <- runEitherT $ await (z, n) go
--     case eres of
--         Left (r, _)  -> return $ Left r
--         Right (r, t)
--             | onull t   -> return $ Right r
--             | otherwise -> runEitherT $ yield r t
--   where
--     n = Seq.fromList []

--     go (r, t') t
--         | onull y = return (r, t <> t')
--         | otherwise = do
--             r' <- rewrap (, n) $ yield r (t' <> x)
--             go r' (Seq.drop 1 y)
--       where
--         (x, y) = Seq.break (== sep) t

-- linesUnboundedC :: (Monad m, IsSequence seq, Element seq ~ Char)
--                 => Source m seq -> Source m seq
-- linesUnboundedC = linesUnboundedC_ '\n'

-- linesUnboundedAsciiC :: (Monad m, IsSequence seq, Element seq ~ Word8)
--                      => Source m seq -> Source m seq
-- linesUnboundedAsciiC = linesUnboundedC_ 10

-- | The use of 'awaitForever' in this library is just a bit different from
--   conduit:
--
-- >>> awaitForever $ \x yield -> if even x then yield x else exit
awaitForever :: Monad m
             => (a -> (b -> m ()) -> m ())
             -> Conduit a m b
awaitForever f await yield = await $ \x -> f x yield

zipSourceApp :: Monad m => Source m (x -> y) -> Source m x -> Source m y
zipSourceApp f arg yield = f $ \x -> arg $ \y -> yield (x y)

-- jww (2014-06-09): finish
-- newtype ZipSource m r a = ZipSource { getZipSource :: Source m a }

-- instance Monad m => Functor (ZipSource m r) where
--     fmap f (ZipSource p) = ZipSource $ \z yield -> p z $ \r x -> yield r (f x)

-- instance Monad m => Applicative (ZipSource m r) where
--     pure x = ZipSource $ yieldOne x
--     ZipSource l <*> ZipSource r = ZipSource (zipSourceApp l r)

-- -- | Sequence a collection of sources.
-- --
-- -- >>> sinkList $ sequenceSources [yieldOne 1, yieldOne 2, yieldOne 3]
-- -- [[1,2,3]]
-- sequenceSources :: (Traversable f, Monad m)
--                 => f (Source m a) -> Source m (f a)
-- sequenceSources = getZipSource . sequenceA . fmap ZipSource

-- -- | Since Sources are not Monads in this library (as they are in the full
-- --   conduit library), they can be sequentially "chained" using this append
-- --   operator.  If Source were a newtype, we could make it an instance of
-- --   Monoid.
infixr 3 <+>
(<+>) :: Monad m => Source m a -> Conduit a m a
x <+> y = \f -> x f >> y f
{-# INLINE (<+>) #-}

-- instance MFunctor (EitherT s) where
--   hoist f (EitherT m) = EitherT $ f m

-- -- | Zip sinks together.  This function may be used multiple times:
-- --
-- -- >>> let mySink s await => resolve await () $ \() x -> liftIO $ print $ s <> show x
-- -- >>> zipSinks sinkList (zipSinks (mySink "foo") (mySink "bar")) $ yieldMany [1,2,3]
-- -- "foo: 1"
-- -- "bar: 1"
-- -- "foo: 2"
-- -- "bar: 2"
-- -- "foo: 3"
-- -- "bar: 3"
-- -- ([1,2,3],((),()))
-- zipSinks :: Monad m
--          => (Source m a  -> m r)
--          -> (Source m a -> m r')
--          -> Source m a -> m (r, r')
-- zipSinks x y await = do
--     let i = (error "accessing r'", error "accessing s")
--     flip evalStateT i $ do
--         r <- x $ \rx yieldx -> do
--             r' <- lift $ y $ \ry yieldy -> EitherT $ do
--                     st <- get
--                     eres <- lift $ runEitherT $ await (rx, ry) $ \(rx', ry') u -> do
--                         x' <- stripS st $ rewrap (, ry') $ yieldx rx' u
--                         y' <- stripS st $ rewrap (rx' ,) $ yieldy ry' u
--                         return (fst x', snd y')
--                     let (s, s') = either id id eres
--                     modify (\(b, _) -> (b, s))
--                     return $ Right s'
--             lift $ do
--                 modify (\(_, b) -> (r', b))
--                 gets snd
--         r' <- gets fst
--         return (r, r')
--   where
--     stripS :: (MFunctor t, Monad n) => b1 -> t (StateT b1 n) b -> t n b
--     stripS s = hoist (`evalStateT` s)

-- jww (2014-06-09): finish
-- newtype ZipSink m r a = ZipSink { getZipSink :: Source (CollectT r m) a -> m r }

-- instance Monad m => Functor (ZipSink m r) where
--     fmap f (ZipSink k) = ZipSink $ liftM f . k

-- instance Monad m => Applicative (ZipSink m r) where
--     pure x = ZipSink $ \_ -> return x
--     ZipSink f <*> ZipSink x = ZipSink $ \await -> f await `ap` x await

-- -- | Send incoming values to all of the @Sink@ providing, and ultimately
-- --   coalesce together all return values.
-- --
-- -- Implemented on top of @ZipSink@, see that data type for more details.
-- sequenceSinks :: (Traversable f, Monad m)
--               => f (Sink a m r) -> Sink a m (f r)
-- sequenceSinks = getZipSink . sequenceA . fmap ZipSink

-- infixr 3 <*>
-- (<*>) :: Monad m
--       => (Source (StateT (r', s) m) i s  -> StateT (r', s) m r)
--       -> (Source (StateT (r', s) m) i s' -> StateT (r', s) m r')
--       -> Source m i (s, s') -> m (r, r')
-- (<*>) = zipSinks
-- {-# INLINE (<*>) #-}

-- zipConduitApp :: Monad m => Conduit a m (x -> y) r -> Conduit a m x r -> Conduit a m y r
-- zipConduitApp f arg yield = f z $ \r x -> arg r $ \_ y -> yield z (x y)

-- newtype ZipConduit a m r b = ZipConduit { getZipConduit :: Conduit a m b }

-- instance Monad m => Functor (ZipConduit a m r) where
--     fmap f (ZipConduit p) = ZipConduit $ \z yield -> p z $ \r x -> yield r (f x)

-- instance Monad m => Applicative (ZipConduit a m r) where
--     pure x = ZipConduit $ yieldOne x
--     ZipConduit l <*> ZipConduit r = ZipConduit (zipConduitApp l r)

-- -- | Sequence a collection of sources.
-- --
-- -- >>> sinkList $ sequenceConduits [yieldOne 1, yieldOne 2, yieldOne 3]
-- -- [[1,2,3]]
-- sequenceConduits :: (Traversable f, Monad m)
--                 => f (Conduit a m b) -> Conduit a m (f b) r
-- sequenceConduits = getZipConduit . sequenceA . fmap ZipConduit

asyncC :: (MonadBaseControl IO m, Monad m)
       => (a -> m b) -> Conduit a m (Async (StM m b))
asyncC f await yield = await $ \x -> yield =<< async (f x)

-- | Convert a 'Control.Foldl.FoldM' fold abstraction into a Sink.
--
--   NOTE: This requires ImpredicativeTypes in the code that uses it.
--
-- >>> fromFoldM (FoldM ((return .) . (+)) (return 0) return) $ yieldMany [1..10]
-- 55
-- jww (2014-06-09): finish
-- fromFoldM :: Monad m => FoldM m a b -> Source m a -> m b
-- fromFoldM (FoldM step initial final) await = do
--     r <- initial
--     flip execStateT r $ do
--         await (\x -> get >>= flip step x >>= put)
--         get >>= lift . final

-- | Convert a Sink into a 'Control.Foldl.FoldM', passing it into a
--   continuation.
--
-- >>> toFoldM sumC (\f -> Control.Foldl.foldM f [1..10])
-- 55
-- jww (2014-06-09): finish
-- toFoldM :: Monad m
--         => Sink a m r -> (FoldM (EitherT r m) a r -> EitherT r m r) -> m r
-- toFoldM sink f = sink $ \yield -> f $ FoldM yield (return ()) return

-- | A Source for exhausting a TChan, but blocks if it is initially empty.
sourceTChan :: TChan a -> Source STM a
sourceTChan chan yield = go
  where
    go = do
        x  <- readTChan chan
        yield x
        mt <- isEmptyTChan chan
        if mt
            then return ()
            else go

sourceTQueue :: TQueue a -> Source STM a
sourceTQueue chan yield = go
  where
    go = do
        x  <- readTQueue chan
        yield x
        mt <- isEmptyTQueue chan
        if mt
            then return ()
            else go

sourceTBQueue :: TBQueue a -> Source STM a
sourceTBQueue chan yield = go
  where
    go = do
        x  <- readTBQueue chan
        yield x
        mt <- isEmptyTBQueue chan
        if mt
            then return ()
            else go

untilMC :: Monad m => m a -> m Bool -> Source m a
untilMC m f yield = go
  where
    go = do
        x <- m
        yield x
        cont <- f
        if cont
            then go
            else return ()

whileMC :: Monad m => m Bool -> m a -> Source m a
whileMC f m yield = go
  where
    go = do
        cont <- f
        if cont
            then m >>= yield >> go
            else return ()

-- jww (2014-06-08): These exception handling functions are useless, since we
-- can only catch downstream exceptions, not upstream as conduit users expect.

-- catchC :: (Exception e, MonadBaseControl IO m)
--        => Source m a -> (e -> Source m a) -> Source m a
-- catchC await handler yield =
--     await z $ \r x -> catch (yield r x) $ \e -> handler e r yield

-- tryAroundC :: (Exception e, MonadBaseControl IO m)
--            => Source m a -> Source m a (Either e r)
-- tryAroundC _ (Left e) _ = return (Left e)
-- tryAroundC await (Right z) yield = rewrap Right go `catch` (return . Left)
--   where
--     go = await z (\r x -> rewrap (\(Right r') -> r') $ yield (Right r) x)

-- tryC :: (Exception e, MonadBaseControl IO m)
--      => Source m a -> Source m a (Either e a)
-- tryC await yield = await z $ \r x ->
--     catch (yield r (Right x)) $ \e -> yield r (Left (e :: SomeException))

-- tryC :: (MonadBaseControl IO m)
--        => Conduit a m b -> Conduit a m (Either SomeException b) r
-- tryC f await = trySourceC (f await)
