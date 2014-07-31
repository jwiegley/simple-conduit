module Main

data Identity a = Id a

runIdentity : Identity a -> a
runIdentity (Id a) = a

instance Functor Identity where
  map f (Id x) = Id (f x)

instance Applicative Identity where
  pure = Id
  (Id f) <$> (Id x) = Id (f x)

instance Monad Identity where
  (Id m) >>= f = f m

data Source : {r : Type} -> (m : Type -> Type) -> (a : Type) -> Type where
  Src : (r -> (r -> a -> m r) -> m r) -> Source {r} m a

runSource : {r : Type} -> Source {r} m a -> r -> (r -> a -> m r) -> m r
runSource (Src await) = await

Conduit : {r : Type} -> Type -> (Type -> Type) -> Type -> Type
Conduit {r} a m b = Source {r} m a -> Source {r} m b

Sink : {r : Type} -> Type -> (Type -> Type) -> Type -> Type
Sink {r} a m s = Source {r} m a -> m s

instance Functor (Source {r} m) where
    map f (Src await) = Src $ \z, yield => await z (\r => yield r . f)

foldM : Monad m => (r -> a -> m r) -> r -> List a -> m r
foldM f z []        = return z
foldM f z (x :: xs) = f z x >>= flip (foldM f) xs

source : {r : Type} -> (r -> (r -> a -> m r) -> m r) -> Source {r} m a
source = Src

sourceList : Monad m => List a -> Source m a
sourceList xs = source $ \z, yield => foldM yield z xs

mapC : Monad m => {r : Type} -> (a -> b) -> Conduit {r} a m b
mapC = map

sinkList : Monad m => Sink {r = List a} a m (List a)
sinkList (Src await) = await Prelude.List.Nil (\xs, x => return (x :: xs))

main : IO ()
main = print $ runIdentity $ sinkList $ mapC (+1) $ sourceList [1..10]
