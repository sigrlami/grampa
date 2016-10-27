{-# Language TemplateHaskell #-}
-- Adapted from https://wiki.haskell.org/A_practical_Template_Haskell_Tutorial

module Rank2.TH where

import Control.Monad (replicateM)
import Data.Foldable (foldMap)
import Data.Functor
import Data.Monoid ((<>))
import Language.Haskell.TH
import Language.Haskell.TH.Syntax (BangType, VarBangType, getQ, putQ)

import Debug.Trace (trace)

import qualified Rank2

data Deriving = Deriving { tyCon :: Name, tyVar :: Name }

deriveAll ty = foldr f (pure []) [deriveFunctor, deriveApply, deriveAlternative, deriveReassemblable,
                                  deriveFoldable, deriveTraversable]
   where f derive rest = (<>) <$> derive ty <*> rest

deriveFunctor :: Name -> Q [Dec]
deriveFunctor ty = do
   (instanceType, cs) <- reifyConstructors ''Rank2.Functor ty
   sequence [instanceD (return []) instanceType [genFmap cs]]

deriveApply :: Name -> Q [Dec]
deriveApply ty = do
   (instanceType, cs) <- reifyConstructors ''Rank2.Apply ty
   sequence [instanceD (return []) instanceType [genAp cs]]

deriveAlternative :: Name -> Q [Dec]
deriveAlternative ty = do
   (instanceType, cs) <- reifyConstructors ''Rank2.Alternative ty
   sequence [instanceD (return []) instanceType [genEmpty cs, genChoose cs]]

deriveReassemblable :: Name -> Q [Dec]
deriveReassemblable ty = do
   (instanceType, cs) <- reifyConstructors ''Rank2.Reassemblable ty
   sequence [instanceD (return []) instanceType [genReassemble cs]]

deriveFoldable :: Name -> Q [Dec]
deriveFoldable ty = do
   (instanceType, cs) <- reifyConstructors ''Rank2.Foldable ty
   sequence [instanceD (return []) instanceType [genFoldMap cs]]

deriveTraversable :: Name -> Q [Dec]
deriveTraversable ty = do
   (instanceType, cs) <- reifyConstructors ''Rank2.Traversable ty
   sequence [instanceD (return []) instanceType [genTraverse cs]]

reifyConstructors cls ty = do
   (TyConI tyCon) <- reify ty
   (tyConName, tyVars, kind, cs) <- case tyCon of
      DataD _ nm tyVars kind cs _   -> return (nm, tyVars, kind, cs)
      NewtypeD _ nm tyVars kind c _ -> return (nm, tyVars, kind, [c])
      _ -> fail "deriveApply: tyCon may not be a type synonym."
 
   let (KindedTV tyVar (AppT (AppT ArrowT StarT) StarT)) = last tyVars
       instanceType           = conT cls `appT` foldl apply (conT tyConName) (init tyVars)
       apply t (PlainTV name)    = appT t (varT name)
       apply t (KindedTV name _) = appT t (varT name)
 
   putQ (Deriving tyConName tyVar)
   return (instanceType, cs)

genFmap :: [Con] -> Q Dec
genFmap cs = funD 'Rank2.fmap (map genFmapClause cs)

genAp :: [Con] -> Q Dec
genAp cs = funD 'Rank2.ap (map genApClause cs)

genEmpty :: [Con] -> Q Dec
genEmpty (con:_) = funD 'Rank2.empty [genEmptyClause con]

genChoose :: [Con] -> Q Dec
genChoose cs = funD 'Rank2.choose (map genChooseClause cs)

genReassemble :: [Con] -> Q Dec
genReassemble cs = funD 'Rank2.reassemble (map genReassembleClause cs)

genFoldMap :: [Con] -> Q Dec
genFoldMap cs = funD 'Rank2.foldMap (map genFoldMapClause cs)

genTraverse :: [Con] -> Q Dec
genTraverse cs = funD 'Rank2.traverse (map genTraverseClause cs)

genFmapClause :: Con -> Q Clause
genFmapClause (NormalC name fieldTypes) = do
   f          <- newName "f"
   fieldNames <- replicateM (length fieldTypes) (newName "x")
   let pats = [varP f, conP name (map varP fieldNames)]
       body = normalB $ appsE $ conE name : map (newField f) (zip fieldNames fieldTypes)
       newField :: Name -> (Name, BangType) -> Q Exp
       newField f (x, (_, fieldType)) = do
          Just (Deriving typeCon typeVar) <- getQ
          case fieldType of
             AppT ty _ | ty == VarT typeVar -> [| $(varE f) $(varE x) |]
             _ -> [| $(varE x) |]
   clause pats body []
genFmapClause (RecC name fields) = do
   f <- newName "f"
   x <- newName "x"
   let body = normalB $ recConE name $ map (newNamedField f x) fields
       newNamedField :: Name -> Name -> VarBangType -> Q (Name, Exp)
       newNamedField f x (fieldName, _, fieldType) = do
          Just (Deriving typeCon typeVar) <- getQ
          case fieldType of
             AppT ty _ | ty == VarT typeVar -> fieldExp fieldName [| $(varE f) ($(varE fieldName) $(varE x)) |]
             _ -> fieldExp fieldName [| $(varE x) |]
   clause [varP f, varP x] body []
 
genApClause :: Con -> Q Clause
genApClause (NormalC name fieldTypes) = do
   fieldNames1 <- replicateM (length fieldTypes) (newName "x")
   fieldNames2 <- replicateM (length fieldTypes) (newName "y")
   let pats = [conP name (map varP fieldNames1), conP name (map varP fieldNames2)]
       body = normalB $ appsE $ conE name : zipWith newField (zip fieldNames1 fieldNames2) fieldTypes
       newField :: (Name, Name) -> BangType -> Q Exp
       newField (x, y) (_, fieldType) = do
          Just (Deriving typeCon typeVar) <- getQ
          case fieldType of
             AppT ty _ | ty == VarT typeVar -> [| Rank2.apply $(varE x) $(varE y) |]
   clause pats body []
genApClause (RecC name fields) = do
   x <- newName "x"
   y <- newName "y"
   let body = normalB $ recConE name $ map (newNamedField x y) fields
       newNamedField :: Name -> Name -> VarBangType -> Q (Name, Exp)
       newNamedField x y (fieldName, _, fieldType) = do
          Just (Deriving typeCon typeVar) <- getQ
          case fieldType of
             AppT ty _ | ty == VarT typeVar -> fieldExp fieldName [| $(varE fieldName) $(varE x) `Rank2.apply`
                                                                       $(varE fieldName) $(varE y) |]
   clause [varP x, varP y] body []

genEmptyClause :: Con -> Q Clause
genEmptyClause (NormalC name fieldTypes) = clause [] body []
   where body = normalB $ appsE $ conE name : replicate (length fieldTypes) [| empty |]
genEmptyClause (RecC name fields) = clause [] body []
   where body = normalB $ recConE name $ map emptyField fields
         emptyField :: VarBangType -> Q (Name, Exp)
         emptyField (fieldName, _, fieldType) = do
            Just (Deriving typeCon typeVar) <- getQ
            case fieldType of
               AppT ty _ | ty == VarT typeVar -> fieldExp fieldName [| empty |]
 
genChooseClause :: Con -> Q Clause
genChooseClause (NormalC name fieldTypes) = do
   fieldNames1 <- replicateM (length fieldTypes) (newName "x")
   fieldNames2 <- replicateM (length fieldTypes) (newName "y")
   let pats = [conP name (map varP fieldNames1), conP name (map varP fieldNames2)]
       body = normalB $ appsE $ conE name : zipWith newField (zip fieldNames1 fieldNames2) fieldTypes
       newField :: (Name, Name) -> BangType -> Q Exp
       newField (x, y) (_, fieldType) = do
          Just (Deriving typeCon typeVar) <- getQ
          case fieldType of
             AppT ty _ | ty == VarT typeVar -> [| $(varE x) <|> $(varE y) |]
   clause pats body []
genChooseClause (RecC name fields) = do
   x <- newName "x"
   y <- newName "y"
   let body = normalB $ recConE name $ map (newNamedField x y) fields
       newNamedField :: Name -> Name -> VarBangType -> Q (Name, Exp)
       newNamedField x y (fieldName, _, fieldType) = do
          Just (Deriving typeCon typeVar) <- getQ
          case fieldType of
             AppT ty _ | ty == VarT typeVar -> fieldExp fieldName [| $(varE fieldName) $(varE x) <|>
                                                                     $(varE fieldName) $(varE y) |]
   clause [varP x, varP y] body []

genReassembleClause :: Con -> Q Clause
genReassembleClause (RecC name fields) = do
   f <- newName "f"
   x <- newName "x"
   let body = normalB $ recConE name $ map (newNamedField f x) fields
       newNamedField :: Name -> Name -> VarBangType -> Q (Name, Exp)
       newNamedField f x (fieldName, _, fieldType) = do
          Just (Deriving typeCon typeVar) <- getQ
          case fieldType of
             AppT ty _ | ty == VarT typeVar -> fieldExp fieldName [| $(varE f) $(varE fieldName) $(varE x) |]
             _ -> fieldExp fieldName [| $(varE x) |]
   clause [varP f, varP x] body []

genFoldMapClause :: Con -> Q Clause
genFoldMapClause (NormalC name fieldTypes) = do
   f          <- newName "f"
   fieldNames <- replicateM (length fieldTypes) (newName "x")
   let pats = [varP f, conP name (map varP fieldNames)]
       body = normalB $ foldr1 append $ map (newField f) (zip fieldNames fieldTypes)
       append a b = [| $(a) <> $(b) |]
       newField :: Name -> (Name, BangType) -> Q Exp
       newField f (x, (_, fieldType)) = do
          Just (Deriving typeCon typeVar) <- getQ
          case fieldType of
             AppT ty _ | ty == VarT typeVar -> [| $(varE f) $(varE x) |]
             _ -> [| $(varE x) |]
   clause pats body []
genFoldMapClause (RecC name fields) = do
   f <- newName "f"
   x <- newName "x"
   let body = normalB $ foldr1 append $ map (newField f x) fields
       append a b = [| $(a) <> $(b) |]
       newField :: Name -> Name -> VarBangType -> Q Exp
       newField f x (fieldName, _, fieldType) = do
          Just (Deriving typeCon typeVar) <- getQ
          case fieldType of
             AppT ty _ | ty == VarT typeVar -> [| $(varE f) ($(varE fieldName) $(varE x)) |]
             _ -> [| $(varE x) |]
   clause [varP f, varP x] body []

genTraverseClause :: Con -> Q Clause
genTraverseClause (NormalC name fieldTypes) = do
   f          <- newName "f"
   fieldNames <- replicateM (length fieldTypes) (newName "x")
   let pats = [varP f, conP name (map varP fieldNames)]
       body = normalB $ fst $ foldl apply (conE name, False) $ map (newField f) (zip fieldNames fieldTypes)
       apply (a, False) b = ([| $(a) <$> $(b) |], True)
       apply (a, True) b = ([| $(a) <*> $(b) |], True)
       newField :: Name -> (Name, BangType) -> Q Exp
       newField f (x, (_, fieldType)) = do
          Just (Deriving typeCon typeVar) <- getQ
          case fieldType of
             AppT ty _ | ty == VarT typeVar -> [| $(varE f) $(varE x) |]
             _ -> [| $(varE x) |]
   clause pats body []
genTraverseClause (RecC name fields) = do
   f <- newName "f"
   x <- newName "x"
   let body = normalB $ fst $ foldl apply (conE name, False) $ map (newField f x) fields
       apply (a, False) b = ([| $(a) <$> $(b) |], True)
       apply (a, True) b = ([| $(a) <*> $(b) |], True)
       newField :: Name -> Name -> VarBangType -> Q Exp
       newField f x (fieldName, _, fieldType) = do
          Just (Deriving typeCon typeVar) <- getQ
          case fieldType of
             AppT ty _ | ty == VarT typeVar -> [| $(varE f) ($(varE fieldName) $(varE x)) |]
             _ -> [| $(varE x) |]
   clause [varP f, varP x] body []
