module Text.Grampa.Combinators (moptional, concatMany, concatSome,
                                flag, count, upto,
                                delimiter, operator, keyword) where

import Control.Applicative(Applicative(..), Alternative(..))
import Data.Monoid.Cancellative (LeftReductiveMonoid)
import Data.Monoid (Monoid, (<>))
import Data.Monoid.Factorial (FactorialMonoid)

import Text.Grampa.Class (MonoidParsing(concatMany, string), 
                          Lexical(LexicalConstraint, lexicalToken, keyword))
import Text.Parser.Combinators (Parsing((<?>)), count)

-- | Attempts to parse a monoidal value, if the argument parser fails returns 'mempty'.
moptional :: (Monoid x, Alternative p) => p x -> p x
moptional p = p <|> pure mempty

-- | One or more argument occurrences like 'some', with concatenated monoidal results.
concatSome :: (Monoid x, Applicative (p s), MonoidParsing p) => p s x -> p s x
concatSome p = (<>) <$> p <*> concatMany p

-- | Returns 'True' if the argument parser succeeds and 'False' otherwise.
flag :: Alternative p => p a -> p Bool
flag p = True <$ p <|> pure False

-- | Parses between 0 and N occurrences of the argument parser in sequence and returns the list of results.
upto :: Alternative p => Int -> p a -> p [a]
upto n p
   | n > 0 = (:) <$> p <*> upto (pred n) p 
             <|> pure []
   | otherwise = pure []

-- | Parses the given delimiter, such as a comma or a brace
delimiter :: (Show s, FactorialMonoid s, LeftReductiveMonoid s,
              Parsing (p g s), MonoidParsing (p g), Lexical g, LexicalConstraint p g s) => s -> p g s s
delimiter s = lexicalToken (string s) <?> ("delimiter " <> show s)

-- | Parses the given operator symbol
operator :: (Show s, FactorialMonoid s, LeftReductiveMonoid s,
             Parsing (p g s), MonoidParsing (p g), Lexical g, LexicalConstraint p g s) => s -> p g s s
operator s = lexicalToken (string s) <?> ("operator " <> show s)
