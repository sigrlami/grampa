-- | Collection of parsing algorithms with a common interface, operating on grammars represented as records with rank-2
-- field types.
{-# LANGUAGE FlexibleContexts, KindSignatures, OverloadedStrings, RankNTypes, ScopedTypeVariables #-}
module Text.Grampa (
   -- * Parsing methods
   MultiParsing(..),
   offsetContext, offsetLineAndColumn, positionOffset, failureDescription, simply,
   -- * Types
   Grammar, GrammarBuilder, ParseResults, ParseFailure(..), Ambiguous(..), Position,
   -- * Parser combinators and primitives
   GrammarParsing(..), MonoidParsing(..), AmbiguousParsing(..), Lexical(..),
   module Text.Parser.Char,
   module Text.Parser.Combinators,
   module Text.Parser.LookAhead)
where

import Data.List (intersperse)
import Data.Monoid ((<>))
import qualified Data.Monoid.Factorial as Factorial
import Data.Monoid.Factorial (FactorialMonoid)
import Data.String (IsString(fromString))
import Text.Parser.Char (CharParsing(char, notChar, anyChar))
import Text.Parser.Combinators (Parsing((<?>), notFollowedBy, skipMany, skipSome, unexpected))
import Text.Parser.LookAhead (LookAheadParsing(lookAhead))

import qualified Rank2
import Text.Grampa.Class (Lexical(..), MultiParsing(..), GrammarParsing(..), MonoidParsing(..), AmbiguousParsing(..),
                          Ambiguous(..), ParseResults, ParseFailure(..), Position, positionOffset)

-- | A type synonym for a fixed grammar record type @g@ with a given parser type @p@ on input streams of type @s@
type Grammar (g  :: (* -> *) -> *) p s = g (p g s)

-- | A type synonym for an endomorphic function on a grammar record type @g@, whose parsers of type @p@ build grammars
-- of type @g'@, parsing input streams of type @s@
type GrammarBuilder (g  :: (* -> *) -> *)
                    (g' :: (* -> *) -> *)
                    (p  :: ((* -> *) -> *) -> * -> * -> *)
                    (s  :: *)
   = g (p g' s) -> g (p g' s)

-- | Apply the given 'parse' function to the given grammar-free parser and its input.
simply :: (Rank2.Only r (p (Rank2.Only r) s) -> s -> Rank2.Only r f) -> p (Rank2.Only r) s r -> s -> f r
simply parseGrammar p input = Rank2.fromOnly (parseGrammar (Rank2.Only p) input)

-- | Given the textual parse input, the parse failure on the input, and the number of lines preceding the failure to
-- show, produce a human-readable failure description.
failureDescription :: forall s. (Eq s, IsString s, FactorialMonoid s) => s -> ParseFailure -> Int -> s
failureDescription input (ParseFailure pos expected) contextLineCount =
   offsetContext input pos contextLineCount
   <> "expected " <> oxfordComma (fromString <$> expected)
   where oxfordComma :: [s] -> s
         oxfordComma [] = ""
         oxfordComma [x] = x
         oxfordComma [x, y] = x <> " or " <> y
         oxfordComma (x:y:rest) = mconcat (intersperse ", " (x : y : onLast ("or " <>) rest))
         onLast _ [] = []
         onLast f [x] = [f x]
         onLast f (x:xs) = x : onLast f xs

-- | Given the parser input, an offset within it, and desired number of context lines, returns a description of
-- the offset position in English.
offsetContext :: (Eq s, IsString s, FactorialMonoid s) => s -> Int -> Int -> s
offsetContext input offset contextLineCount = 
   foldMap (<> "\n") prevLines <> fromString (replicate column ' ') <> "^\n"
   <> "at line " <> fromString (show $ length allPrevLines) <> ", column " <> fromString (show $ column+1) <> "\n"
   where (allPrevLines, column) = offsetLineAndColumn input offset
         prevLines = reverse (take contextLineCount allPrevLines)

-- | Given the full input and an offset within it, returns all the input lines up to and including the offset
-- in reverse order, as well as the zero-based column number of the offset
offsetLineAndColumn :: (Eq s, IsString s, FactorialMonoid s) => s -> Int -> ([s], Int)
offsetLineAndColumn input pos = context [] pos (Factorial.split (== "\n") input)
  where context revLines restCount []
          | restCount > 0 = (["Error: the offset is beyond the input length"], -1)
          | otherwise = (revLines, restCount)
        context revLines restCount (next:rest)
          | restCount' < 0 = (next:revLines, restCount)
          | otherwise = context (next:revLines) restCount' rest
          where nextLength = Factorial.length next
                restCount' = restCount - nextLength - 1
