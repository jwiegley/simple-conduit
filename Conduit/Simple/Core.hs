{-# LANGUAGE DeriveFunctor #-}
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

module Conduit.Simple.Core where

import           Control.Applicative (Alternative((<|>), empty),
                                      Applicative((<*>), pure))
import           Control.Arrow (first)
import           Control.Monad.Catch (MonadThrow(..), MonadMask, MonadCatch)
import qualified Control.Monad.Catch as Catch
import           Control.Monad.Cont
import           Control.Monad.Error.Class (MonadError(..))
import           Control.Monad.Free
import           Control.Monad.Morph (MMonad(..), MFunctor(..))
import           Control.Monad.Reader.Class (MonadReader(..))
import           Control.Monad.State.Class (MonadState(..))
import           Control.Monad.Trans.Either (EitherT(..), left)
import           Control.Monad.Writer.Class (MonadWriter(..))
import           Data.Bifunctor (Bifunctor(bimap))
import           Data.Foldable (Foldable(foldMap))
import           Data.Functor.Identity
import           Data.Semigroup (Monoid(..), Semigroup((<>)))

-- | A Source is a short-circuiting monadic fold.
--
-- 'Source' forms a Monad that behaves as 'ListT'; for example:
--
-- @
-- do x <- yieldMany [1..3]
--    line <- sourceFile "foo.txt"
--    return (x, line)
-- @
--
-- This yields the cross-product of [3] and the lines in the files, but only
-- reading chunks from the file as needed by the sink.
--
-- To skip to the next value in a Source, use the function 'skip' or 'mempty';
-- to close the source, use 'close'.  For example:
--
-- @
-- do x <- yieldMany [1..10]
--    if x == 2 || x == 9
--    then return x
--    else if x < 5
--         then skip
--         else close
-- @
--
-- This outputs the list @[2]@.
--
-- A key difference from the @conduit@ library is that monadic chaining of
-- sources with '>>' follows 'ListT', and not concatenation as in conduit.  To
-- achieve conduit-style behavior, use the Monoid instance:
--
-- >>> sinkList $ yieldMany [1..3] <> yieldMany [4..6]
-- [1,2,3,4,5,6]
newtype Source m a = Source { getSource :: forall r. Cont (r -> EitherT r m r) a }
    deriving Functor

-- | A 'Conduit' is a "Source homomorphism", or simple a mapping between
--   sources.  There is no need for it to be a type synonym, except to save
--   repetition across type signatures.
type Conduit a m b = Source m a -> Source m b

-- | A 'Sink' folds a 'Source' down to its result value.  It is simply a
--   convenient type synonym for functions mapping a 'Source' to some result
--   type.
type Sink a m r = Source m a -> m r

instance Monad m => Semigroup (Source m a) where
    x <> y = source $ \r c -> runSource x r c >>= \r' -> runSource y r' c
    {-# INLINE (<>) #-}

instance Monad m => Monoid (Source m a) where
    mempty  = skip
    {-# INLINE mempty #-}
    mappend = (<>)
    {-# INLINE mappend #-}

instance Monad m => Alternative (Source m) where
    empty = skip
    {-# INLINE empty #-}
    (<|>) = (<>)
    {-# INLINE (<|>) #-}

instance Monad m => MonadPlus (Source m) where
    mzero = skip
    {-# INLINE mzero #-}
    mplus = (<|>)
    {-# INLINE mplus #-}

instance Applicative (Source m) where
    pure  = return
    {-# INLINE pure #-}
    (<*>) = ap
    {-# INLINE (<*>) #-}

instance Monad (Source m) where
    return x = Source $ return x
    {-# INLINE return #-}
    Source m >>= f = Source $ m >>= getSource . f
    {-# INLINE (>>=) #-}

instance MFunctor Source where
    hoist nat m = source $ runSource (hoist nat m)
    {-# INLINE hoist #-}

instance MMonad Source where
    embed f m = source $ runSource (embed f m)
    {-# INLINE embed #-}

instance MonadIO m => MonadIO (Source m) where
    liftIO m = source $ \r yield -> liftIO m >>= yield r
    {-# INLINE liftIO #-}

instance MonadTrans Source where
    lift m = source $ \r yield -> lift m >>= yield r
    {-# INLINE lift #-}

instance (Functor f, MonadFree f m) => MonadFree f (Source m) where
    wrap t = source $ \r h -> wrap $ fmap (\p -> runSource p r h) t
    {-# INLINE wrap #-}

-- jww (2014-06-15): If it weren't for the universally quantified r...
-- instance MonadCont (Source m) where
--     callCC f = source $ \z c -> runSource (f (\x -> source $ \r _ -> c r x)) z c
--     {-# INLINE callCC #-}

instance MonadReader r m => MonadReader r (Source m) where
    ask = lift ask
    {-# INLINE ask #-}
    local f = conduit $ \r yield -> local f . yield r
    {-# INLINE local #-}
    reader = lift . reader
    {-# INLINE reader #-}

instance MonadState s m => MonadState s (Source m) where
    get = lift get
    {-# INLINE get #-}
    put = lift . put
    {-# INLINE put #-}
    state = lift . state
    {-# INLINE state #-}

instance MonadWriter w m => MonadWriter w (Source m) where
    writer = lift . writer
    {-# INLINE writer #-}
    tell = lift . tell
    {-# INLINE tell #-}
    listen = conduit $ \r yield x ->
        listen (return ()) >>= yield r . first (const x)
    {-# INLINE listen #-}
    pass = conduit $ \r yield (x, f) -> pass (return ((), f)) >> yield r x
    {-# INLINE pass #-}

instance MonadError e m => MonadError e (Source m) where
    throwError = lift . throwError
    {-# INLINE throwError #-}
    catchError src f = source $ \z yield -> EitherT $
        runEitherT (runSource src z yield)
            `catchError` \e -> runEitherT (runSource (f e) z yield)
    {-# INLINE catchError #-}

instance MonadThrow m => MonadThrow (Source m) where
    throwM = lift . throwM
    {-# INLINE throwM #-}

instance MonadCatch m => MonadCatch (Source m) where
    catch src f = source $ \z yield -> EitherT $
        runEitherT (runSource src z yield)
            `Catch.catch` \e -> runEitherT (runSource (f e) z yield)
    {-# INLINE catch #-}

instance MonadMask m => MonadMask (Source m) where
    mask a = source $ \z yield -> EitherT $ Catch.mask $ \u ->
        runEitherT $ runSource (a $ \b -> source $ \r yield' ->
            EitherT $ liftM Right $ u $ sink r yield' b) z yield
    {-# INLINE mask #-}
    uninterruptibleMask a =
        source $ \z yield -> EitherT $ Catch.uninterruptibleMask $ \u ->
            runEitherT $ runSource (a $ \b -> source $ \r yield' ->
                EitherT $ liftM Right $ u $ sink r yield' b) z yield
    {-# INLINE uninterruptibleMask #-}

instance Foldable (Source Identity) where
    foldMap f = runIdentity . sink mempty (\r x -> return $ r `mappend` f x)
    {-# INLINE foldMap #-}

-- | Promote any sink to a source.  This can be used as if it were a source
--   transformer (aka, a conduit):
--
-- >>> sinkList $ returnC $ sumC $ mapC (+1) $ yieldMany [1..10]
-- [65]
--
-- Note that 'returnC' is a synonym for 'Control.Monad.Trans.Class.lift'.
returnC :: Monad m => m a -> Source m a
returnC = lift
{-# INLINE returnC #-}

close :: Monad m => Source m a
close = source $ const . left
{-# INLINE close #-}

skip :: Monad m => Source m a
skip = source $ const . return
{-# INLINE skip #-}

runSource :: Source m a -> r -> (r -> a -> EitherT r m r) -> EitherT r m r
runSource (Source (ContT src)) z yield =
    runIdentity (src (\x -> Identity $ \r -> yield r x)) z
{-# INLINE runSource #-}

lowerSource :: (Monad m, Monoid a) => Source m a -> m a
lowerSource src = unwrap $ runSource src mempty ((return .) . mappend)
{-# INLINE lowerSource #-}

source :: (forall r. r -> (r -> a -> EitherT r m r) -> EitherT r m r) -> Source m a
source await = Source $ ContT $ \yield -> Identity $ \z ->
    await z (\r x -> runIdentity (yield x) r)
{-# INLINE source #-}

conduit :: (forall r. r -> (r -> b -> EitherT r m r) -> a -> EitherT r m r)
        -> Conduit a m b
conduit f src = source $ \z c -> runSource src z (`f` c)
{-# INLINE conduit #-}

-- | Most of the time conduits pass the fold variable through unmolested, but
--   sometimes you need to ignore that variable and use your own within a
--   stage of the pipeline.  This is done by wrapping the fold variable in a
--   tuple and then unwrapping it when the conduit is done.  'conduitWith'
--   makes this transparent.
conduitWith :: Monad m
            => s
            -> (forall r. (r, s) -> (r -> b -> EitherT (r, s) m (r, s)) -> a
                -> EitherT (r, s) m (r, s))
            -> Conduit a m b
conduitWith s f src = source $ \z yield ->
    rewrap fst $ runSource src (z, s) $ \(r, t) ->
        f (r, t) (\r' -> rewrap (, t) . yield r')
{-# INLINE conduitWith #-}

unwrap :: Monad m => EitherT a m a -> m a
unwrap k = either id id `liftM` runEitherT k
{-# INLINE unwrap #-}

rewrap :: Monad m => (a -> b) -> EitherT a m a -> EitherT b m b
rewrap f k = EitherT $ bimap f f `liftM` runEitherT k
{-# INLINE rewrap #-}

sink :: forall m a r. Monad m => r -> (r -> a -> EitherT r m r) -> Sink a m r
sink z f src = either id id `liftM` runEitherT (runSource src z f)
{-# INLINE sink #-}

awaitForever :: (a -> Source m b) -> Conduit a m b
awaitForever = flip (>>=)
{-# INLINE awaitForever #-}
