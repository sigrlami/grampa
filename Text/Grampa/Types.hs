{-# LANGUAGE FlexibleContexts, FlexibleInstances, GADTs, InstanceSigs, LambdaCase, KindSignatures,
             RankNTypes, ScopedTypeVariables, UndecidableInstances #-}
module Text.Grampa.Types (Functor1(..), Apply1(..), Alternative1(..), Foldable1(..), Traversable1(..),
                          Reassemblable(..), ResultList(..),
                          Grammar, GrammarBuilder, Parser(..), Identity1(..), Product1(..), Arrow1(..),
                          feed, feedEnd, fixGrammar, fixGrammarInput, iterateMany)
where

import Control.Applicative
import Control.Arrow (first, second)
import Control.Monad.Trans.State (State, evalState, get, modify)
import Data.Function(fix)
import Data.Functor.Classes (Show1(liftShowsPrec))
import Data.Functor.Compose (Compose(Compose, getCompose))
import Data.Monoid (Monoid(mappend, mempty), All(..), (<>))
import Data.Monoid.Null (MonoidNull(null))
import Data.Monoid.Factorial (FactorialMonoid(spanMaybe', splitPrimePrefix, tails))

import Prelude hiding (iterate, null)

-- | Equivalent of 'Functor' for rank 2 data types
class Functor1 g where
   fmap1 :: (forall a. p a -> q a) -> g p -> g q

-- | Equivalent of 'Foldable' for rank 2 data types
class Functor1 g => Foldable1 g where
   foldMap1 :: Monoid m => (forall a. p a -> m) -> g p -> m

-- | Equivalent of 'Traversable' for rank 2 data types
class Foldable1 g => Traversable1 g where
   traverse1 :: Applicative m => (forall a. p a -> m (q a)) -> g p -> m (g q)

data Arrow1 p q a = Arrow1{apply1 :: p a -> q a}

-- | Equivalent of 'Applicative' with no 'pure' method, for rank 2 data types
--
-- > (.) <$> u <*> v <*> w == u <*> (v <*> w)
class Functor1 g => Apply1 g where
   ap1 :: g (Arrow1 p q) -> g p -> g q

-- | Equivalent of 'Applicative' with no 'pure' method, for rank 2 data types
--
-- > choose1 empty1 x == x
-- > choose1 x empty1 == x
-- > x `choose1` (y `choose1` z) == (x `choose1` y) `choose1` z
-- > ap1 empty x == empty
-- > ap1 x (choose1 y z) == choose1 (ap1 x y) (ap1 x z)
-- > ap1 (choose1 x y) z == choose1 (ap1 x z) (ap1 y z)
class Apply1 g => Alternative1 g where
   empty1 :: Alternative p => g p
   choose1 :: Alternative p => g p -> g p -> g p

-- | Subclass of 'Functor' that allows access to parts of the data structure
class Functor1 g => Reassemblable g where
   reassemble :: (forall a. (forall f. g f -> f a) -> g p -> q a) -> g p -> g q

-- | Parser of streams of type `s`, as a part of grammar type `g`, producing a value of type `r`
data Parser g s r = Failure String
                  | Result [(GrammarResults g s, s)] r
                  | Choice (Parser g s r) (Parser g s r)
                  | Delay (Parser g s r) ([(GrammarResults g s, s)] -> Parser g s r)
                  | forall r'. NonTerminal Int (forall f. g f -> f r') (r' -> r) (Parser g s r')
                  | forall r'. Bind (Parser g s r') (r' -> Parser g s r)

-- | Equivalent of 'Data.Functor.Identity' for rank 2 data types
data Identity1 g (f :: * -> *) = Identity1 {runIdentity1 :: g f} deriving (Eq, Ord, Show)

-- | Equivalent of 'Data.Functor.Product' for rank 2 data types
data Product1 g h (f :: * -> *) = Pair {fst1 :: g f,
                                        snd1 :: h f}
                                deriving (Eq, Ord, Show)

type Grammar g s = g (Parser g s)
type GrammarBuilder g g' s = g (Parser g' s) -> g (Parser g' s)

instance (Show r, Show s, Show (Grammar g s), Show (GrammarResults g s)) => Show (Parser g s r) where
   showsPrec _ (Failure s) rest = "(Failure " ++ shows s (")" ++ rest)
   showsPrec prec (Result s r) rest
      | prec > 0 = "(Result " ++ foldr (\(t, s)-> showsPrec (prec - 1) t . shows s) (" " ++ shows r (")" ++ rest)) s
      | otherwise = "Result" ++ rest
   showsPrec prec (Choice p1 p2) rest = "(Choice " ++ showsPrec prec p1 (" " ++ showsPrec prec p2 (")" ++ rest))
   showsPrec prec (Delay e f) rest = "(Delay " ++ showsPrec prec e (")" ++ rest)
   showsPrec prec (Bind p cont) rest = "(Bind " ++ showsPrec prec (const () <$> p) (")" ++ rest)
   showsPrec prec (NonTerminal i get map p) rest
      | prec > 0 = "(NonTerminal " ++ show i ++ " " ++ showsPrec (prec - 1) (map <$> p) (")" ++ rest)
      | otherwise = "(NonTerminal " ++ show i ++ ")" ++ rest

instance (Show s, Show (Grammar g s), Show (GrammarResults g s)) => Show1 (Parser g s) where
   liftShowsPrec sp _ _ (Failure s) rest = "(Failure " ++ shows s (")" ++ rest)
   liftShowsPrec sp _ prec (Result s r) rest
      | prec > 0 = "(Result " ++ foldr (\(t, s)-> showsPrec (prec - 1) t . shows s) (" " ++ sp prec r (")" ++ rest)) s
      | otherwise = "Result" ++ rest
   liftShowsPrec sp sl prec (Choice p1 p2) rest = "(Choice " ++ liftShowsPrec sp sl prec p1 (" " ++ liftShowsPrec sp sl prec p2 (")" ++ rest))
   liftShowsPrec sp sl prec (Delay e f) rest = "(Delay " ++ liftShowsPrec sp sl prec e (")" ++ rest)
   liftShowsPrec sp sl prec (Bind p cont) rest = "(Bind " ++ liftShowsPrec showsPrec showList prec (const () <$> p) (")" ++ rest)
   liftShowsPrec sp sl prec (NonTerminal i get map p) rest
      | prec > 0 = "(NonTerminal " ++ show i ++ " " ++ liftShowsPrec sp sl (prec - 1) (map <$> p) (")" ++ rest)
      | otherwise = "(NonTerminal " ++ show i ++ ")" ++ rest

instance Functor1 g => Functor1 (Identity1 g) where
   fmap1 f (Identity1 g) = Identity1 (fmap1 f g)

instance (Functor1 g, Functor1 h) => Functor1 (Product1 g h) where
   fmap1 f (Pair g h) = Pair (fmap1 f g) (fmap1 f h)

instance Foldable1 g => Foldable1 (Identity1 g) where
   foldMap1 f (Identity1 g) = foldMap1 f g

instance (Foldable1 g, Foldable1 h) => Foldable1 (Product1 g h) where
   foldMap1 f (Pair g h) = foldMap1 f g <> foldMap1 f h

instance Traversable1 g => Traversable1 (Identity1 g) where
   traverse1 f (Identity1 g) = Identity1 <$> traverse1 f g

instance (Traversable1 g, Traversable1 h) => Traversable1 (Product1 g h) where
   traverse1 f (Pair g h) = Pair <$> traverse1 f g <*> traverse1 f h

instance Apply1 g => Apply1 (Identity1 g) where
   ap1 (Identity1 g) (Identity1 h) = Identity1 (ap1 g h)

instance (Apply1 g, Apply1 h) => Apply1 (Product1 g h) where
   ap1 (Pair gf hf) (Pair g h) = Pair (ap1 gf g) (ap1 hf h)

instance Alternative1 g => Alternative1 (Identity1 g) where
   empty1 = Identity1 empty1
   choose1 (Identity1 g) (Identity1 h) = Identity1 (choose1 g h)

instance (Alternative1 g, Alternative1 h) => Alternative1 (Product1 g h) where
   empty1 = Pair empty1 empty1
   choose1 (Pair g1 h1) (Pair g2 h2) = Pair (choose1 g1 g2) (choose1 h1 h2)

instance forall g. Reassemblable g => Reassemblable (Identity1 g) where
   reassemble :: forall p q. (forall a. (forall f. Identity1 g f -> f a) -> Identity1 g p -> q a)
              -> Identity1 g p -> Identity1 g q
   reassemble f ~(Identity1 a) = Identity1 (reassemble f' a)
      where f' :: forall a. (forall f. g f -> f a) -> g p -> q a
            f' get x = f (get . runIdentity1) (Identity1 x)

instance forall g h. (Reassemblable g, Reassemblable h) => Reassemblable (Product1 g h) where
   reassemble :: forall p q. (forall a. (forall f. Product1 g h f -> f a) -> Product1 g h p -> q a)
              -> Product1 g h p -> Product1 g h q
   reassemble f ~(Pair a b) = Pair (reassemble f' a) (reassemble f'' b)
      where f' :: forall a. (forall f. g f -> f a) -> g p -> q a
            f' get x = f (get . fst1) (Pair x b)
            f'' :: forall a. (forall f. h f -> f a) -> h p -> q a
            f'' get x = f (get . snd1) (Pair a x)

-- | Tie the knot on a 'GrammarBuilder' and turn it into a 'Grammar'
fixGrammar :: forall g s. (Reassemblable g, Traversable1 g) => (Grammar g s -> Grammar g s) -> Grammar g s
fixGrammar gf = fix . (. mark) $ gf
   where mark :: g (Parser g s) -> g (Parser g s)
         mark g = evalState (traverse1 f $ reassemble nt g) 0
            where nt :: (forall p. g p -> p r) -> g (Parser g s) -> Parser g s r
                  nt f g = NonTerminal 0 f id (f g)
         f :: Parser g s r -> State Int (Parser g s r)
         f (NonTerminal 0 getP map p) = do modify succ
                                           i <- get
                                           return (NonTerminal i getP map p)

fixGrammarInput :: forall s g. (FactorialMonoid s, Alternative1 g, Traversable1 g) =>
                   Grammar g s -> s -> [(GrammarResults g s, s)]
fixGrammarInput g s = foldr (parseTail g) [] (tails s)
   where parseTail :: (FactorialMonoid s, Alternative1 g, Traversable1 g) =>
                      Grammar g s -> s -> [(GrammarResults g s, s)] -> [(GrammarResults g s, s)]
         parseTail g input parsedTail = parsedInput
            where parsedInput = (grammarResults' g', input):parsedTail
                  g' = fmap1 (feedSelf g' parsedInput) g

grammarResults' :: forall s g. (MonoidNull s, Traversable1 g, Alternative1 g) => Grammar g s -> GrammarResults g s
grammarResults' g = foldr1 choose1 (iterate rf [rn])
   where GrammarDerived rn rf = separate g

iterate :: Foldable1 g => (GrammarResults g s -> GrammarResults g s) -> [GrammarResults g s] -> [GrammarResults g s]
iterate f ns@(n:_) = if getAll (foldMap1 (All . null . resultList) n') then ns else iterate f (n':ns)
   where n' = f n

type GrammarResults g s = g (ResultList g s)
newtype ResultList g s r = ResultList {resultList :: [([(GrammarResults g s, s)], r)]}
data GrammarDerived g s a = GrammarDerived a (GrammarResults g s -> a)
type ParserResults g s r = GrammarDerived g s (ResultList g s r)

instance (Show (g (ResultList g s)), Show s, Show r) => Show (ResultList g s r) where
   show (ResultList l) = "ResultList " ++ show l

instance (Show (g (ResultList g s)), Show s) => Show1 (ResultList g s) where
   liftShowsPrec sp sl prec (ResultList l) rest = "ResultList " ++ sl (snd <$> l) rest

instance Functor (ResultList g s) where
   fmap f (ResultList l) = ResultList ((f <$>) <$> l)
      
instance Applicative (ResultList g s) where
   pure r = ResultList [([], r)]
   ResultList a <*> ResultList b = ResultList (getCompose $ Compose a <*> Compose b)
   
instance Alternative (ResultList g s) where
   empty = ResultList []
   ResultList a <|> ResultList b = ResultList (a <|> b)
   
instance Monoid (ResultList g s r) where
   mempty = ResultList []
   ResultList a `mappend` ResultList b = ResultList (a <> b)

instance Show a => Show (GrammarDerived g s a) where
   show (GrammarDerived a _) = "GrammarDerived (" ++ show a ++ " _)"

instance Monoid a => Monoid (GrammarDerived g s a) where
   mempty = GrammarDerived mempty (const mempty)
   mappend (GrammarDerived a fa) (GrammarDerived b fb) = GrammarDerived (a <> b) (\g-> fa g <> fb g)

instance Functor (GrammarDerived g s) where
   fmap f (GrammarDerived a g) = GrammarDerived (f a) (f . g)

instance Applicative (GrammarDerived g s) where
   pure a = GrammarDerived a (const a)
   GrammarDerived a fa <*> GrammarDerived b fb = GrammarDerived (a b) (\g-> fa g $ fb g)

separate :: forall g s. (MonoidNull s, Traversable1 g, Alternative1 g) =>
            Grammar g s -> GrammarDerived g s (GrammarResults g s)
separate g = traverse1 sep1 g
   
sep1 :: forall g s r. (Monoid s, Traversable1 g, Alternative1 g) => Parser g s r -> ParserResults g s r
sep1 Failure{} = GrammarDerived (ResultList []) (const $ ResultList [])
sep1 (Result s r) = GrammarDerived (ResultList [(s, r)]) (const $ ResultList [])
sep1 (Choice p q) = sep1 p <> sep1 q
sep1 (Delay e _) = sep1 e
sep1 (NonTerminal i get map p) = GrammarDerived (ResultList []) ((map <$>) . get)
sep1 (Bind p cont) = foldMap f pn <> GrammarDerived (ResultList []) pr'
   where GrammarDerived (ResultList pn) pr = sep1 p
         --f :: ([(Grammar g s, s)], r') -> ParserResults g s r
         f (i, r) = sep1 (feed i $ cont r)
         pr' :: GrammarResults g s -> ResultList g s r
         pr' gr = foldr gr2rl empty (resultList $ pr gr)
            where gr2rl ([], r) l = pr2rl gr (sep1 $ cont r) <> l
                  gr2rl (i@((g',_):_), r) l = pr2rl gr (sep1 $ feed i $ cont r) <> l
                  pr2rl g (GrammarDerived rl rf) = rl <> rf g

feedSelf :: Monoid s => Grammar g s -> [(GrammarResults g s, s)] -> Parser g s r -> Parser g s r
feedSelf g input (Choice p q) = feedSelf g input p <|> feedSelf g input q
feedSelf g input (Delay _ f) = f input
feedSelf g input (Failure msg) = Failure msg
feedSelf g input (Result t r) = Result (t <> input) r
feedSelf g _ (NonTerminal i get map _) = NonTerminal i get map (get g)
feedSelf g input (Bind p cont) = feedSelf g input p >>= cont
   
-- | Feeds a chunk of the input to the given parser.
feed :: Monoid s => [(GrammarResults g s, s)] -> Parser g s r -> Parser g s r
feed s (Choice p q) = feed s p <|> feed s q
feed s (Delay _ f) = f s
feed s (Failure msg) = Failure msg
feed s (Result t r) = Result (t <> s) r
feed [] p@NonTerminal{} = p
feed ((rs, s):_) (NonTerminal i get map p) =
   foldr Choice empty ((uncurry Result . second map) <$> resultList (get rs))
feed s (Bind p cont) = feed s p >>= cont

-- | Signals the end of the input.
feedEnd :: (MonoidNull s, Functor1 g) => Parser g s r -> Parser g s r
feedEnd (Choice p q) = feedEnd p <|> feedEnd q
feedEnd (Delay e _) = feedEnd e
feedEnd p = p

instance Functor (Parser g s) where
   fmap f (Choice p q) = Choice (fmap f p) (fmap f q)
   fmap g (Delay e f) = Delay (fmap g e) (fmap g . f)
   fmap f (Failure msg) = Failure msg
   fmap f (Result s r) = Result s (f r)
   fmap f (Bind p cont) = Bind p (fmap f . cont)
   fmap f (NonTerminal i get map p) = NonTerminal i get (f . map) p

instance Monoid s => Applicative (Parser g s) where
   pure = Result []
   Choice p q <*> r = p <*> r <|> q <*> r
   Delay e f <*> p = Delay (e <*> p) ((<*> p) . f)
   Failure msg <*> _ = Failure msg
   Result s r <*> p = r <$> feed s p
   p <*> q = Bind p (<$> q)

instance Monoid s => Alternative (Parser g s) where
   empty = Failure "empty"
   p <|> Failure{} = p
   Failure{} <|> p = p
--   Delay e f <|> p = Delay (e <|> feedEnd p) (\i-> f i <|> feed i p)
--   p <|> Delay e f = Delay (feedEnd p <|> e) (\i-> feed i p <|> f i)
   p <|> q = Choice p q

instance Monoid s => Monad (Parser g s) where
   return = pure
   Result s r >>= f = feed s (f r)
   Choice p q >>= f = (p >>= f) <|> (q >>= f)
   Delay e f >>= g = Delay (e >>= g) ((>>= g) . f)
   Failure msg >>= f = Failure msg
   p >>= cont = Bind p cont
   (>>) = (*>)
   fail = Failure

instance (Functor1 g, MonoidNull s, Monoid x) => Monoid (Parser g s x) where
   mempty = pure mempty
   mappend = liftA2 mappend

iterateMany :: (MonoidNull s, Functor1 g) => Parser g s r -> (Parser g s r -> Parser g s r) -> Parser g s r
iterateMany p f = p >>= (\r-> return r <|> iterateMany (f $ return r) f)
