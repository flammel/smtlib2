{-# LANGUAGE FlexibleInstances,OverloadedStrings,MultiParamTypeClasses,TemplateHaskell #-}
module Language.SMTLib2.Instances() where

import Language.SMTLib2.Internals
import Language.SMTLib2.TH
import qualified Data.AttoLisp as L
import qualified Data.Attoparsec.Number as L
import Data.Array
import Data.Word
import Numeric
import Data.Char
import Data.Bits
import Data.Text as T
import Data.Ratio
import Data.Typeable

-- Integer

instance SMTType Integer where
  getSort _ = L.Symbol "Int"
  declareType u = [(typeOf u,return ())]

instance SMTValue Integer where
  unmangle (L.Number (L.I v)) = v
  unmangle (L.List [L.Symbol "-"
                   ,L.Number (L.I v)]) = - v
  unmangle e = error $ "can't unmangle "++show e++" to Integer"
  mangle v
    | v < 0 = L.List [L.Symbol "-"
                     ,L.toLisp (-v)]
    | otherwise = L.toLisp v

instance SMTArith Integer

instance Num (SMTExpr Integer) where
  fromInteger = constant
  (+) x y = plus [x,y]
  (-) = minus
  (*) x y = mult [x,y]
  negate = neg
  abs = abs'

-- Real

instance SMTType (Ratio Integer) where
  getSort _ = L.Symbol "Real"
  declareType u = [(typeOf u,return ())]

instance SMTValue (Ratio Integer) where
  unmangle (L.Number (L.I v)) = fromInteger v
  unmangle (L.Number (L.D v)) = realToFrac v
  unmangle (L.List [L.Symbol "/"
                   ,x
                   ,y]) = unmangle x / unmangle y
  unmangle (L.List [L.Symbol "-",r]) = - (unmangle r)
  mangle v = L.List [L.Symbol "/"
                    ,L.Symbol $ T.pack $ (show $ numerator v)++".0"
                    ,L.Symbol $ T.pack $ (show $ denominator v)++".0"]

instance SMTArith (Ratio Integer)

instance Num (SMTExpr (Ratio Integer)) where
  fromInteger = constant.fromInteger
  (+) x y = plus [x,y]
  (-) = minus
  (*) x y = mult [x,y]
  negate = neg
  abs = abs'

instance Fractional (SMTExpr (Ratio Integer)) where
  (/) = divide
  fromRational = constant

-- Bool

instance SMTType Bool where
  getSort _ = L.Symbol "Bool"
  declareType u = [(typeOf u,return ())]

instance SMTValue Bool where
  unmangle (L.Symbol "true") = True
  unmangle (L.Symbol "false") = False
  mangle True = L.Symbol "true"
  mangle False = L.Symbol "false"

-- Arrays

instance (SMTType idx,SMTType val) => SMTType (Array idx val) where
  getSort u = L.List [L.Symbol "Array"
                     ,getSort (getIdx u)
                     ,getSort (getVal u)]
    where
      getIdx :: Array i v -> i
      getIdx _ = undefined
      getVal :: Array i v -> v
      getVal _ = undefined
  declareType u = [(mkTyConApp (mkTyCon "Data.Array.Array") [],return ())] ++
                  declareType (getIdx u) ++
                  declareType (getVal u)
    where
      getIdx :: Array i v -> i
      getIdx _ = undefined
      getVal :: Array i v -> v
      getVal _ = undefined


-- BitVectors

bv :: Integer -> L.Lisp
bv n = L.List [L.Symbol "_"
              ,L.Symbol "BitVec"
              ,L.Number $ L.I n]

instance SMTType Word8 where
  getSort _ = bv 8
  declareType u = [(typeOf u,return ())]

getBVValue :: Num a => L.Lisp -> a
getBVValue (L.Number (L.I v)) = fromInteger v
getBVValue (L.Symbol s) = case T.unpack s of
  '#':'b':rest -> let [(v,_)] = readInt 2 (\x -> x=='0' || x=='1') (\x -> if x=='0' then 0 else 1) rest in v
  '#':'x':rest -> let [(v,_)] = readHex rest in v

putBVValue :: Bits a => a -> L.Lisp
putBVValue x = L.Symbol (T.pack ('#':'b':[ if testBit x i
                                           then '1'
                                           else '0' | i <- Prelude.reverse [0..((bitSize x)-1)] ]))

instance SMTValue Word8 where
  unmangle = getBVValue
  mangle = putBVValue

instance SMTBV Word8

instance SMTType Word16 where
  getSort _ = bv 16
  declareType u = [(typeOf u,return ())]

instance SMTValue Word16 where
  unmangle = getBVValue
  mangle = putBVValue

instance SMTBV Word16

instance SMTType Word32 where
  getSort _ = bv 32
  declareType u = [(typeOf u,return ())]

instance SMTValue Word32 where
  unmangle = getBVValue
  mangle = putBVValue

instance SMTBV Word32

instance SMTType Word64 where
  getSort _ = bv 64
  declareType u = [(typeOf u,return ())]
  
instance SMTValue Word64 where
  unmangle = getBVValue
  mangle = putBVValue

instance SMTBV Word64

instance Num (SMTExpr Word8) where
  fromInteger = constant.fromInteger
  (+) = bvadd
  (-) = bvsub
  (*) = bvmul

instance Num (SMTExpr Word16) where
  fromInteger = constant.fromInteger
  (+) = bvadd
  (-) = bvsub
  (*) = bvmul

instance Num (SMTExpr Word32) where
  fromInteger = constant.fromInteger
  (+) = bvadd
  (-) = bvsub
  (*) = bvmul

instance Num (SMTExpr Word64) where
  fromInteger = constant.fromInteger
  (+) = bvadd
  (-) = bvsub
  (*) = bvmul

-- Arguments

instance SMTType a => Args (SMTExpr a) a where
  createArgs c = let n1 = T.pack $ "f"++show c
                     v1 = Var n1
                     t1 = getSort $ getUndef v1
                 in (v1,[(n1,t1)],c+1)
  unpackArgs e _ c = let (e',c') = exprToLisp e c
                     in ([e'],c)

instance (SMTType a,SMTType b) => Args (SMTExpr a,SMTExpr b) (a,b) where
  createArgs c = let n1 = T.pack $ "f"++show c
                     n2 = T.pack $ "f"++show (c+1)
                     v1 = Var n1
                     v2 = Var n2
                     t1 = getSort $ getUndef v1
                     t2 = getSort $ getUndef v2
                 in ((v1,v2),[(n1,t1),(n2,t2)],c+2)
  unpackArgs (e1,e2) _ c = let (r1,c1) = exprToLisp e1 c
                               (r2,c2) = exprToLisp e2 c1
                           in ([r1,r2],c2)

instance SMTType a => SMTType (Maybe a) where
  getSort u = L.List [L.Symbol "Maybe",getSort (undef u)]
    where
      undef :: Maybe a -> a
      undef _ = undefined
  declareType u = let rec = declareType (undef u)
                  in [(mkTyConApp (mkTyCon "Maybe") [],
                       declareDatatypes ["a"] [("Maybe",[("Nothing",[]),("Just",[("fromJust",L.Symbol "a")])])])] ++
                     rec
    where
      undef :: Maybe a -> a
      undef _ = undefined

instance SMTValue a => SMTValue (Maybe a) where
  unmangle (L.Symbol "Nothing") = Nothing
  unmangle (L.List [L.Symbol "as"
                   ,L.Symbol "Nothing"
                   ,_]) = Nothing
  unmangle (L.List [L.Symbol "Just"
                   ,res]) = Just $ unmangle res
  mangle u@Nothing = L.List [L.Symbol "as"
                            ,L.Symbol "Nothing"
                            ,getSort u]
  mangle (Just x) = L.List [L.Symbol "Just"
                           ,mangle x]