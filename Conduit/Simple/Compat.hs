{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Conduit.Simple.Compat
    ( ($=), (=$), (=$=), ($$)
    , sequenceSources
    -- , adaptFrom, adaptTo
    ) where

import           Conduit.Simple.Core
-- import           Control.Category (Category)
-- import           Control.Exception.Lifted (finally)
-- import           Control.Foldl (PrimMonad, Vector, FoldM(..))
-- import           Control.Monad (liftM)
-- import           Control.Monad.CC hiding (control)
-- import           Control.Monad.Cont
-- import           Control.Monad.Logic
-- import           Control.Monad.Trans.Class (lift)
-- import           Control.Monad.Trans.Control
-- import           Control.Monad.Trans.Either (EitherT(..))
-- import           Control.Monad.Trans.Maybe
-- import           Crypto.Hash
-- import qualified Data.ByteString as B
-- import           Data.Foldable
-- import           Data.Functor.Identity
-- import qualified Data.Machine as M
import           Data.Traversable

-- import qualified Data.Conduit.Internal as C (Source, Producer,
--                                              ConduitM(..), Pipe(..))

-- | Compose a 'Source' and a 'Conduit' into a new 'Source'.  Note that this
--   is just flipped function application, so ($) can be used to achieve the
--   same thing.
infixl 1 $=
($=) :: a -> (a -> b) -> b
($=) = flip ($)

-- | Compose a 'Conduit' and a 'Sink' into a new 'Sink'.  Note that this is
--   just function composition, so (.) can be used to achieve the same thing.
infixr 2 =$
(=$) :: (a -> b) -> (b -> c) -> a -> c
(=$) = flip (.)

-- | Compose two 'Conduit'.  This is also just function composition.
infixr 2 =$=
(=$=) :: (a -> b) -> (b -> c) -> a -> c
(=$=) = flip (.)

-- | Compose a 'Source' and a 'Sink' and compute the result.  Note that this
--   is just flipped function application, so ($) can be used to achieve the
--   same thing.
infixr 0 $$
($$) :: a -> (a -> b) -> b
($$) = flip ($)

-- | Sequence a collection of sources.
--
-- >>> sinkList $ sequenceSources [yieldOne 1, yieldOne 2, yieldOne 3]
-- [[1,2,3]]
sequenceSources :: (Traversable f, Monad m) => f (Source m a) -> Source m (f a)
sequenceSources = sequenceA

{-
-- | Convert a 'Control.Foldl.FoldM' fold abstraction into a Sink.
--
--   NOTE: This requires ImpredicativeTypes in the code that uses it.
--
-- >>> fromFoldM (FoldM ((return .) . (+)) (return 0) return) $ yieldMany [1..10]
-- 55
fromFoldM :: Monad m => FoldM m a b -> Sink a m b
fromFoldM (FoldM step initial final) src =
    initial >>= (\r -> sink r ((lift .) . step) src) >>= final

-- | Convert a Sink into a 'Control.Foldl.FoldM', passing it as a continuation
--   over the elements.
--
-- >>> toFoldM sumC (\f -> Control.Foldl.foldM f [1..10])
-- 55
toFoldM :: Monad m => Sink a m b -> (forall r. FoldM m a r -> m r) -> m b
toFoldM s f = s $ source $ \k yield ->
    EitherT $ liftM Right $ f $
        FoldM (\r x -> either id id `liftM` runEitherT (yield r x))
            (return k) return

-- | Turns any conduit 'Producer' into a simple-conduit 'Source'.
--   Finalization is taken care of, as is processing of leftovers, provided
--   the base monad implements @MonadBaseControl IO@.
adaptFrom :: forall m a. MonadBaseControl IO m => C.Producer m a -> Source m a
adaptFrom (C.ConduitM m) = source go
  where
    go :: r -> (r -> a -> EitherT r m r) -> EitherT r m r
    go z yield = f z m
      where
        f r (C.HaveOutput p c o) = yield r o >>= \r' -> f r' p `finally` lift c
        f r (C.NeedInput _ u)    = f r (u ())
        f r (C.Done ())          = return r
        f r (C.PipeM mp)         = lift mp >>= f r
        f r (C.Leftover p l)     = yield r l >>= flip f p

-- | Turn a non-resource dependent simple-conduit into a conduit 'Source'.
--
--   Finalization data would be lost in this transfer, and so is denied by
--   lack of an instance for @MonadBaseControl IO@.  Further, the resulting
--   pipeline must be run under 'Control.Monad.CC.runCCT', so really this is
--   more a curiosity than anything else.
adaptTo :: MonadDelimitedCont p s m => Source m a -> C.Source m a
adaptTo src = C.ConduitM $ C.PipeM $ reset $ \p ->
    liftM C.Done $ unwrap $ runSource src () $ \() x ->
        lift $ shift p $ \k ->
            return $ C.HaveOutput (C.PipeM $ k (return ())) (return ()) x

fromLogicT :: Monad m => LogicT m a -> Source m a
fromLogicT (LogicT await) = source $ \z yield ->
    lift $ await (go yield) (return z)
  where
    go yield x mr = do
        r <- mr
        eres <- runEitherT $ yield r x
        case eres of
            Left e -> return e   -- no short-circuiting here!
            Right r -> return r

-- toLogicT :: forall m a. Monad m => Source m a -> LogicT m a
-- toLogicT (Source (ContT await)) = LogicT $ \yield mz -> do
--     z <- mz
--     liftM (either id id) . runEitherT $
--         runIdentity (await (\x -> Identity $ liftM lift $ yield x . return)) z

fromMachine :: forall m k a. Monad m => M.MachineT m k a -> Source m a
fromMachine mach = source go
  where
    go :: forall r. r -> (r -> a -> EitherT r m r) -> EitherT r m r
    go z yield = loop mach z
      where
        loop :: M.MachineT m k a -> r -> EitherT r m r
        loop (M.MachineT m) r = do
            step <- lift m
            case step of
                M.Stop        -> return r
                M.Yield x k   -> loop k r >>= flip yield x
                M.Await _ _ e -> loop e r

-- toMachine :: forall m k s a. (Category k, Monad m)
--           => Source m a -> s -> M.MachineT m (k a) s
-- toMachine (Source (ContT await)) seed =
--     M.construct $ M.PlanT
--         (\r -> )
--         (\a mr -> )
--         (\f kz mr -> )
--         (return seed)
--     liftM (either id id) . runEitherT $
--         runIdentity (await go) seed
--   where
--     go :: a -> Identity (s -> EitherT s (M.PlanT (k a) a m) ())
--     go x = Identity $ liftM lift $ \r -> M.yield x

-- | A 'Sink' that hashes a stream of 'B.ByteString'@s@ and creates a digest
--   @d@.
sinkHash :: (Monad m, HashAlgorithm hash) => Sink B.ByteString m (Digest hash)
sinkHash = liftM hashFinalize . sink hashInit ((return .) . hashUpdate)

-- | Hashes the whole contents of the given file in constant memory.  This
--   function is just a convenient wrapper around 'sinkHash'.
hashFile :: (MonadIO m, HashAlgorithm hash) => FilePath -> m (Digest hash)
hashFile = liftIO . sinkHash . sourceFile
-}
