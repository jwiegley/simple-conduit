{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Conduit.Simple.Compat
    ( ($=), (=$), ($$)
    , adaptFrom, adaptTo
    ) where

import Conduit.Simple.Core (Source, source, runSource, unwrap)
import Control.Exception.Lifted (finally)
import Control.Monad (liftM)
import Control.Monad.CC
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Control (MonadBaseControl)
import Control.Monad.Trans.Either (EitherT)

import qualified Data.Conduit.Internal as C (Source, Producer,
                                             ConduitM(..), Pipe(..))

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

-- | Sequence a collection of sources.
--
-- >>> sinkList $ sequenceSources [yieldOne 1, yieldOne 2, yieldOne 3]
-- [[1,2,3]]
sequenceSources :: (Traversable f, Monad m) => f (Source m a) -> Source m (f a)
sequenceSources = sequenceA
{-# INLINE sequenceSources #-}

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
