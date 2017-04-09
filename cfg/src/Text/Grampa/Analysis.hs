{-# LANGUAGE FlexibleContexts, InstanceSigs, RankNTypes, ScopedTypeVariables #-}
{-# OPTIONS -fno-full-laziness #-}
module Text.Grampa.Analysis (Analysis(..), Grammar, direct, leftRecursive)
where

import Control.Applicative
import Control.Monad (Monad(..), MonadPlus(..))
import Data.Monoid (Monoid(mappend, mempty), (<>))
import Data.Monoid.Cancellative (LeftReductiveMonoid)
import Data.Monoid.Null (MonoidNull(null))
import Data.Monoid.Factorial (FactorialMonoid(factors))
import Data.Monoid.Textual (TextualMonoid)
import qualified Data.Monoid.Textual as Textual
import Data.String (fromString)

import qualified Text.Parser.Char
import Text.Parser.Combinators (Parsing(..))
import Text.Parser.LookAhead (LookAheadParsing(..))

import Text.Grampa.Class (MonoidParsing(..))
import Text.Grampa.Parser (Parser(..))
import qualified Text.Grampa.Parser as Parser

import Prelude hiding (iterate, null, span, takeWhile)

type Grammar g s = g (Analysis g s)
data Analysis g i a = Analysis{index               :: Maybe Int,
                               nullDirect          :: Parser g i a,
                               positiveDirect      :: Parser g i a,
                               recursive           :: Parser g i a,
                               leftRecursiveOn     :: [Int],
                               hasCycle            :: Bool,
                               leftDescendants     :: g (Const Bool),
                               nullable            :: Bool,
                               recursivelyNullable :: g (Analysis g i) -> Bool}

direct :: Analysis g i a -> Parser g i a
direct a = nullDirect a <|> positiveDirect a

leftRecursive :: Bool -> Analysis g i a -> Analysis g i a
leftRecursive z a = Analysis{index= Nothing,
                             nullDirect= nullDirect a,
                             positiveDirect= positiveDirect a,
                             recursive= recursive a,
                             hasCycle= False,
                             leftDescendants= leftDescendants a,
                             leftRecursiveOn= [],
                             nullable= z,
                             recursivelyNullable= const z}

instance Show (Analysis g i a) where
   show a = "Analysis{index= " ++ show (index a)
            ++ ", leftRecursiveOn= " ++ show (leftRecursiveOn a)
            ++ ", nullable= " ++ show (nullable a) ++ "}"

instance Functor (Analysis g i) where
   fmap f a = a{nullDirect= f <$> nullDirect a,
                positiveDirect= f <$> positiveDirect a,
                recursive= f <$> recursive a,
                nullable= nullable a}

instance Applicative (Analysis g i) where
   pure x = Analysis{index= Nothing,
                     nullDirect= pure x,
                     positiveDirect= empty,
                     recursive= empty,
                     hasCycle= False,
                     leftDescendants= error "leftDescendants on pure",
                     leftRecursiveOn= [],
                     nullable= True,
                     recursivelyNullable= const True}
   a <*> b = Analysis{index= Nothing,
                      nullDirect= nullDirect a <*> nullDirect b,
                      positiveDirect= positiveDirect a <*> (direct b <|> recursive b)
                                      <|> nullDirect a <*> positiveDirect b,
                      recursive= nullDirect a <*> recursive b
                                 <|> recursive a <*> (direct b <|> recursive b),
                      hasCycle= hasCycle a || nullable a && hasCycle b,
                      leftDescendants= error "leftDescendants on <*>",
                      leftRecursiveOn= if nullable a then leftRecursiveOn a <> leftRecursiveOn b else leftRecursiveOn a,
                      nullable= nullable a && nullable b,
                      recursivelyNullable= \g-> recursivelyNullable a g && recursivelyNullable b g}

instance Alternative (Analysis g i) where
   empty = Analysis{index= Nothing,
                    nullDirect= empty,
                    positiveDirect= empty,
                    recursive= empty,
                    hasCycle= False,
                    leftDescendants= error "leftDescendants on empty",
                    leftRecursiveOn= [],
                    nullable= False,
                    recursivelyNullable= const False}
   a <|> b = Analysis{index= Nothing,
                      nullDirect= nullDirect a <|> nullDirect b,
                      positiveDirect= positiveDirect a <|> positiveDirect b,
                      recursive= recursive a <|> recursive b,
                      hasCycle= hasCycle a || hasCycle b,
                      leftDescendants= error "leftDescendants on <|>",
                      leftRecursiveOn= leftRecursiveOn a <> leftRecursiveOn b,
                      nullable= nullable a || nullable b,
                      recursivelyNullable= \g-> recursivelyNullable a g || recursivelyNullable b g}
   many a = Analysis{index= Nothing,
                     nullDirect= pure [] <|> nullDirect (some a),
                     positiveDirect= positiveDirect (some a),
                     recursive= recursive (some a),
                     hasCycle= hasCycle a,
                     leftDescendants= leftDescendants a,
                     leftRecursiveOn= leftRecursiveOn a,
                     nullable= True,
                     recursivelyNullable= const True}
   some a = Analysis{index= Nothing,
                     nullDirect= (:[]) <$> nullDirect a,
                     positiveDirect= (:) <$> positiveDirect a <*> many (direct a <|> recursive a),
                     recursive= (:) <$> recursive a <*> many (direct a <|> recursive a),
                     hasCycle= hasCycle a,
                     leftDescendants= leftDescendants a,
                     leftRecursiveOn= leftRecursiveOn a,
                     nullable= nullable a,
                     recursivelyNullable= recursivelyNullable a}

instance Monad (Analysis g i) where
   return = pure
   a >>= cont = Analysis{index= Nothing,
                         nullDirect= nullDirect a >>= nullDirect . cont,
                         positiveDirect= (positiveDirect a >>= (\b-> direct b <|> recursive b) . cont)
                                         <|> (nullDirect a >>= positiveDirect . cont),
                         recursive= (nullDirect a >>= recursive . cont)
                                    <|> (recursive a >>= (\b-> direct b <|> recursive b) . cont),
                         hasCycle= hasCycle a || nullable a,
                         leftDescendants= error "leftDescendants on >>=",
                         leftRecursiveOn= leftRecursiveOn a,
                         nullable= nullable a,
                         recursivelyNullable= \g-> recursivelyNullable a g}
   (>>) = (*>)

instance MonadPlus (Analysis g i) where
   mzero = empty
   mplus = (<|>)

instance Monoid x => Monoid (Analysis g i x) where
   mempty = pure mempty
   mappend = liftA2 mappend

instance MonoidParsing (Analysis g) where
   a <<|> b = Analysis{index= Nothing,
                       nullDirect= nullDirect a <<|> nullDirect b,
                       positiveDirect= positiveDirect a <<|> positiveDirect b,
                       recursive= recursive a <<|> recursive b,
                       hasCycle= hasCycle a || hasCycle b,
                       leftDescendants= error "leftDescendants on <<|>",
                       leftRecursiveOn= leftRecursiveOn a <> leftRecursiveOn b,
                       nullable= nullable a || nullable b,
                       recursivelyNullable= \g-> recursivelyNullable a g || recursivelyNullable b g}
   endOfInput = primitive True endOfInput empty
   getInput = primitive True getInput empty
   anyToken = primitive False empty anyToken
   token x = primitive False empty (token x)
   satisfy predicate = primitive False empty (satisfy predicate)
   satisfyChar predicate = primitive False empty (satisfyChar predicate)
   scan s0 f = primitive True (scan s0 f) empty
   scanChars s0 f = primitive True (scanChars s0 f) empty
   string s
      | null s = primitive True (string s) empty
      | otherwise = primitive False empty (string s)
   takeWhile predicate = primitive True (takeWhile predicate) empty
   takeWhile1 predicate = primitive False empty (takeWhile1 predicate)
   takeCharsWhile predicate = primitive True (takeCharsWhile predicate) empty
   takeCharsWhile1 predicate = primitive False empty (takeCharsWhile1 predicate)
   whiteSpace = primitive True whiteSpace empty
   concatMany a = go{leftRecursiveOn= leftRecursiveOn a,
                     nullable= True,
                     recursivelyNullable= const True,
                     hasCycle= hasCycle a}
      where go = mempty <|> (<>) <$> a <*> go

instance MonoidNull i => Parsing (Analysis g i) where
   try a = a{nullDirect= try (nullDirect a),
             positiveDirect= try (positiveDirect a),
             recursive= try (recursive a)}
   a <?> msg = a{nullDirect= nullDirect a <?> msg,
                 positiveDirect= positiveDirect a <?> msg,
                 recursive= recursive a <?> msg}
{-
                                                {
      leftRecursiveOn= trace ("leftRecursiveOn " <> msg) $ (\r-> trace ("leftRecursiveOn " <> msg <> " = " <> show r) r) $ leftRecursiveOn a,
      nullable= trace ("nullable " <> msg) $ (\r-> trace ("nullable " <> msg <> " = " <> show r) r) $ nullable a,
      recursivelyNullable= trace ("recursivelyNullable " <> msg) (\g-> trace ("recursivelyNullableG " <> msg) $ (\r-> trace ("recursivelyNullable " <> msg <> " = " <> show r) r) $ recursivelyNullable a g),
      hasCycle= trace ("hasCycle " <> msg) (hasCycle a),
      leftDescendants= error ("leftDescendants on " <> msg),
      recursive= trace ("recursive " <> msg) (recursive a),
      nullDirect= trace ("nullDirect " <> msg) (nullDirect a),
      positiveDirect= trace ("positiveDirect " <> msg) (positiveDirect a)}
-}
   notFollowedBy a = a{nullDirect= notFollowedBy (direct a),
                       positiveDirect= empty,
                       recursive= empty} -- notFollowedBy (recursive a)}
   skipMany a = a{positiveDirect= positiveDirect a *> skipMany (direct a <|> recursive a),
                  nullDirect= pure () <|> () <$ nullDirect a,
                  nullable= True,
                  recursivelyNullable= const True,
                  hasCycle= hasCycle a,
                  leftDescendants= error "leftDescendants on skipMany",
                  leftRecursiveOn= leftRecursiveOn a,
                  recursive= recursive a *> skipMany (direct a <|> recursive a)}
   unexpected msg = primitive False empty (unexpected msg)
   eof = endOfInput

instance MonoidNull i => LookAheadParsing (Analysis g i) where
   lookAhead a = a{nullDirect= lookAhead (direct a),
                   positiveDirect= empty,
                   recursive= lookAhead (recursive a)}

instance (Show s, TextualMonoid s) => Text.Parser.Char.CharParsing (Analysis g s) where
   satisfy = satisfyChar
   string s = Textual.toString (error "unexpected non-character") <$> string (fromString s)
   char = satisfyChar . (==)
   notChar = satisfyChar . (/=)
   anyChar = satisfyChar (const True)
   text t = (fromString . Textual.toString (error "unexpected non-character")) <$> string (Textual.fromText t)

primitive :: Bool -> Parser g i a -> Parser g i a -> Analysis g i a
primitive z n p = Analysis{index= Nothing,
                           nullDirect= n,
                           positiveDirect= p,
                           recursive= empty,
                           leftRecursiveOn= [],
                           leftDescendants= error "leftDescendants on primitive",
                           nullable= z,
                           recursivelyNullable= const z}